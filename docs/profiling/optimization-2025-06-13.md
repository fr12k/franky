# Profiling Analysis: 2025-06-13

**Profile target:** `franky-test` (test runner)
**Profile path:** `zig-out/profile/franky-test/1781337112781`
**Data sources:** `perf` (CPU), `heaptrack` (memory), `DebugAllocator` (allocation sites)
**Analysis date:** 2025-06-13

---

## Executive Summary

**No memory leaks detected.** The test run shows 375 allocations vs 373 deallocations (the 2-net are `pthread_create` TLS, expected). Peak RSS is ~1.3 KB. Total allocated: ~154 KB.

**Three real CPU hotspots** need attention. The rest is DebugAllocator DWARF-unwinding overhead (expected in debug mode) and virtio-fs syscall latency (infrastructure, not code).

---

## 🔴 Issue 1: Channel ring buffer zeroing (top CPU consumer)

**Evidence:** The #1 franky-test CPU consumer is `Channel.init` → `allocator.alloc(T, capacity)` → `compiler_rt.memset` (3M+ samples), and `Channel.deinit` → `allocator.free` → `compiler_rt.memset` (2M+ samples). The `alloc` zeroes the entire ring buffer, and `DebugAllocator.free` also zeroes on free.

**Root cause** (`src/ai/channel.zig:47`):

```zig
.ring = try allocator.alloc(T, capacity),
```

`allocator.alloc` zeroes memory. The ring buffer doesn't need zeroing — `head`/`tail`/`len` track what's live. For a channel with capacity 1024 and `T = StreamEvent` (~200 bytes), that's 200 KB of zeroed memory per channel init, then zeroed again on free.

**Fix:** Use a non-zeroing allocation:

```zig
const byte_len = @sizeOf(T) * capacity;
const ptr = try allocator.rawAlloc(byte_len, @alignOf(T), @returnAddress());
.ring = @as([*]T, @ptrCast(@alignCast(ptr)))[0..capacity];
```

Or, if `rawAlloc` is too low-level, use `allocator.alignedAlloc(u8, @alignOf(T), byte_len)` and cast — the key is avoiding the `memset` that `alloc(T, capacity)` inserts.

**Impact:** Eliminates ~5M memset samples per channel-heavy test. This is the single biggest CPU win available.

---

## 🔴 Issue 2: grep tool allocating writer per match line

**Evidence:** `grepFile` → `out.print(allocator, ...)` for every match and context line. Each call goes through `Io.Writer.Allocating.ensureTotalCapacityPrecise` → `DebugAllocator` → `mmap`/`munmap`. The `fmt.allocPrint` path alone accounts for 5+ separate 1M-sample stacks.

**Root cause** (`src/coding/tools/grep.zig:620,634`):

```zig
try out.print(allocator, "{s}:{d}:{s}{s}\n", .{ path, line_no, t.text, suffix });
```

The allocating writer re-checks capacity on every `print` call. For a file with thousands of matches, this means thousands of capacity checks and potential reallocations. Each reallocation triggers `DebugAllocator` → `mmap`/`munmap` syscalls.

**Fix:** Pre-allocate the output buffer to a reasonable capacity before the match loop:

```zig
// In grepFile, before the match loop:
try out.ensureTotalCapacity(allocator, 64 * 1024);
```

This avoids repeated capacity checks for the common case. For files with more matches, the writer will still grow, but the growth is amortized.

**Impact:** Eliminates thousands of capacity-check → reallocation → syscall chains per grep invocation. Most noticeable on broad searches with many matches.

---

## 🔴 Issue 3: gitignore stack reloaded per tool call

**Evidence:** `coding.instructions.scanForest` → `walkForAgentsMd` → `gitignore.loadFromTree` → `loadFromTreeNamed` → `fileExists` → `openat64` syscall. Multiple `openat64` calls per test, each traversing virtio-fs. The `grepTree` function also calls `loadIgnoreStacks` on every invocation.

**Root cause** (`src/coding/gitignore.zig:182-185`):

```zig
// TODO(§6.9 perf): the stack is reloaded per call. For sessions
// with many edits on large repos this re-walks the tree each time.
// Cache at the `Workspace` level (invalidate on `.contextignore`
// mtime change) when profiling warrants it.
```

Every `grep`, `find`, `ls`, and `instructions.scan` call re-walks the entire directory tree looking for `.gitignore` and `.contextignore` files. On a large repo with many nested directories, this is hundreds of `openat` syscalls per tool invocation.

**Fix:** Implement the existing TODO — cache the `IgnoreStacks` at the `Workspace` level with mtime-based invalidation:

1. Add `gitignore_mtime: ?i64` and `contextignore_mtime: ?i64` fields to `Workspace`.
2. On `loadIgnoreStacks`, check if the cached stacks are still fresh by comparing mtimes.
3. Only re-walk when an ignore file has changed.

**Impact:** Reduces `openat64` syscalls from O(directory count) per tool call to O(1) per session. Most noticeable on repos with deep directory trees.

---

## 🟡 Issue 4: DebugAllocator DWARF unwinding overhead

**Evidence:** `Progress.start` → `debug.ConfigurableTrace` → `debug.captureCurrentStackTrace` → `debug.Dwarf.unwindFrame` → `multi_array_list.MultiArrayList`. This appears in 10+ separate 1M-sample stacks. Every allocation/free in `DebugAllocator` captures a stack trace, which requires DWARF section parsing and frame unwinding.

**Impact:** ~20% of total CPU samples in the test run are DWARF unwinding overhead. This is **not a code bug** — it's the cost of using `DebugAllocator` in debug mode.

**Mitigation:**

- For production builds, use `ReleaseSafe` or a non-debug allocator. The overhead disappears.
- For test runs where allocation profiling is not needed, consider using `std.heap.GeneralPurposeAllocator(.{})` instead of `DebugAllocator`.
- No code change to application logic is needed — just be aware that debug-mode profiling overweights allocation sites.

---

## 🟡 Issue 5: `grepFile` reads entire file into memory

**Evidence:** `grepFile` → `allocator.alloc(u8, len)` for the full file content, then builds a `ArrayList(usize)` of line start positions.

**Root cause** (`src/coding/tools/grep.zig:544-560`):

```zig
const buf = try allocator.alloc(u8, @intCast(len));
// ...
var line_starts: std.ArrayList(usize) = .empty;
// ...
while (i < bytes.len) : (i += 1) {
    if (bytes[i] == '\n') try line_starts.append(allocator, i + 1);
}
```

For a file at the `max_file_bytes` cap (8 MB), this allocates 8 MB for content + ~8 MB for line start indices (one `usize` per line). That's 16 MB peak per file.

**Mitigation:** The `max_file_bytes` cap already limits impact. For very large files, a streaming approach (read in chunks, match incrementally) would reduce peak memory, but the current cap keeps this bounded. Low priority unless profiling shows memory pressure from large-file greps.

---

## ✅ Not issues

| Check | Result |
|-------|--------|
| Memory leaks | **None detected** — 0 leaked allocations from franky-test code |
| Memory growth | **Bounded** — peak RSS ~1.3 KB, total allocated ~154 KB |
| Temporary allocations | **Minimal** — 1 temp from `Channel.init` (73 KB), 1 from `loadFromTreeNamed` |
| Thread contention | **None visible** — no lock-contention stacks in top hotspots |
| virtio-fs latency | **Infrastructure, not code** — `virtqueue_get_buf` / `vm_notify` stacks are virtio-fs overhead on this particular host |

---

## Recommended action items (priority order)

| Priority | Issue | File | Effort | Impact |
|----------|-------|------|--------|--------|
| P0 | Channel ring buffer zeroing | `src/ai/channel.zig:47` | 1 hour | Eliminates ~5M memset samples |
| P0 | Pre-allocate grep output buffer | `src/coding/tools/grep.zig` | 30 min | Eliminates thousands of reallocation chains |
| P1 | Cache gitignore stacks at Workspace | `src/coding/gitignore.zig:182-185` | 2 hours | Reduces openat64 syscalls from O(dirs) to O(1) |
| P2 | Use ReleaseSafe for production | Build config | 5 min | Eliminates ~20% DWARF unwinding overhead |
| P3 | Streaming grep for large files | `src/coding/tools/grep.zig:544` | 4 hours | Reduces peak memory for 8 MB files |

---

## Raw data summary

| Metric | Value |
|--------|-------|
| Total CPU samples (franky-test) | ~50 M |
| Total allocations | 375 |
| Total deallocations | 373 |
| Net leaked | 2 (pthread TLS, expected) |
| Total allocated bytes | ~154 KB |
| Peak RSS | ~1.3 KB |
| Heaptrack events | 5,423 lines |
| Largest single allocation | 73,728 bytes (Channel ring) |
