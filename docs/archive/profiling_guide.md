# 🔬 Profiling and Memory Analysis Guide (franky / Zig 0.17-dev)

**Document Status:** Practical workflow + technical reference
**Target Version:** 0.17-dev
**Purpose:** Reproducible workflow for capturing CPU hotspots and memory allocation profiles from franky's test binaries, producing SVG flamegraphs via `inferno`.

---

## TL;DR — one command

```bash
zig build profile -- --binary franky-test
```

`zig build profile` rebuilds FP-preserved binaries (`test-profile`), then drives `perf`/`heaptrack`/`inferno`. Output: `zig-out/profile/<binary>/<unix_ms>/`.

Manual workflow:
```bash
zig build test-profile -Doptimize=ReleaseSafe
# CPU:
perf record -F 997 --call-graph fp -o perf.data -- ./zig-out/bin/franky-test
perf script --input perf.data | inferno-collapse-perf | inferno-flamegraph > cpu.svg
# Memory:
heaptrack ./zig-out/bin/franky-test
heaptrack_print -p 0 -a 0 -T 0 --flamegraph-cost-type peak -F mem-peak.folded -f heaptrack.franky-test.*.zst
inferno-flamegraph --countname=bytes --colors=mem mem-peak.folded > mem-peak.svg
```

---

## 1. Why profile the test suite?

franky's existing test suite (1041+ tests across unit-test + 6 integration binaries) exercises all 7 LLM-provider stream parsers, all 7 coding tools, full agent-loop flows, session round-trip, web UI. Profiling this gives representative data on day one. Narrow via `--test-filter <pattern>`.

Integration test binaries (`franky-agent_loop_test`, `franky-kitchen_sink_test`, etc.) are most allocation-heavy. Profile `franky-test` first for breadth; switch to specific integration binary once bottleneck is known.

---

## 2. Prerequisites

| Tool | Linux | macOS | Notes |
|---|---|---|---|
| Zig 0.17-dev | required | required | Same as `build.zig.zon` |
| `perf` | `apt install linux-tools-$(uname -r)` | n/a — use Instruments/dtrace | Needs `kernel.perf_event_paranoid ≤ 1` or root |
| `heaptrack` | `apt install heaptrack` / `brew install heaptrack` | yes (CLI, no display needed) | `heaptrack` capture + `heaptrack_print -F` extract |
| `inferno` | `cargo install inferno` | `cargo install inferno` | `inferno-collapse-perf` + `inferno-flamegraph` |
| `addr2line` | bundled with binutils | bundled with llvm | Resolves stack addresses to symbols |

---

## 3. Build setup

`zig build test-profile -Doptimize=ReleaseSafe` produces FP-preserved binaries at `zig-out/bin/`: `franky-test`, `franky-agent_loop_test`, `franky-agent_class_test`, `franky-gitignore_test`, `franky-parallel_tools_test`, `franky-kitchen_sink_test`, `franky-replay_test`.

`test-profile` uses a separate module from regular `test` step; overrides only `omit_frame_pointer = false`.

### Optimization mode

| Mode | Use when |
|---|---|
| `Debug` | Hunting wrong-answer regressions; stacks most precise but allocation pattern unrealistic |
| **`ReleaseSafe`** *(recommended)* | First-pass profiling; production-like inlining + DWARF |
| `ReleaseFast` | Validating hotspot after maximum inlining; stacks degrade |
| `ReleaseSmall` | Rarely useful |

### 3.5 The `franky-profile` driver

`zig build profile -- [options]`:
- `--binary NAME` — default `franky-test`
- `--mode MODE` — `cpu` | `mem` | `both` (default)
- `--out-dir PATH` — default `zig-out/profile/<binary>/<unix_ms>`
- `--freq HZ` — perf sampling frequency (default 997)
- `--list` — list installed binaries
- `-h, --help`

**Filtering tests:** Zig 0.17 standalone test binary doesn't accept `--test-filter` at runtime — it's a compile-time flag. Use `-Dprofile-filter=PATTERN` (accumulates; forwarded to `addTest({ .filters = ... })`).

Driver steps: preflight (verify tools), OS/kernel checks, CPU pipeline (perf.data → cpu.folded → cpu.svg), memory pipeline (4 cost dimensions), summary.

Output layout: `perf.data`, `cpu.folded`, `cpu.svg`, `heaptrack.*.zst`, `mem-{peak,leaked,allocations,temporary}.{folded,svg}`.

Differential analysis: run with two `--out-dir`s, then `inferno-diff-folded before/cpu.folded after/cpu.folded | inferno-flamegraph > cpu-diff.svg`.

---

## 4. CPU flamegraph

### 4.1 Capture

Three call-graph modes (all require `omit_frame_pointer = false`):

| Mode | perf.data size | Stack depth | Overhead | When |
|---|---|---|---|---|
| **`fp`** *(default)* | ~50–100 MB | full | low | First choice |
| `lbr` | ~30–60 MB | 16–32 entries | very low | Intel Haswell+ / AMD Zen+; limited depth |
| `dwarf` (or `dwarf,N`) | ~1 GB+ | full | high | Last resort when optimizer inlined past fp recovery |

- 997 Hz is prime to avoid timer-interrupt aliasing.
- For long runs, add `--mmap-pages 2048`.
- `[unknown]` frames after `fp` → rebuild with `-Doptimize=Debug` or fall back to `dwarf`.

### 4.2 Convert to flamegraph

```bash
perf script --input perf.data | inferno-collapse-perf > cpu.folded
inferno-flamegraph cpu.folded > cpu.svg
```

### 4.3 Narrowing scope (compile-time filter)

```bash
zig build test-profile -Doptimize=ReleaseSafe -Dprofile-filter=edit
perf record -F 997 --call-graph fp -o perf.data -- ./zig-out/bin/franky-test
```

### 4.4 Differential

Capture before/after, then `inferno-diff-folded before.folded after.folded | inferno-flamegraph --colors red > cpu-diff.svg`. Red = grew, blue = shrank.

---

## 5. Memory profile (heaptrack + inferno)

### 5.1 Capture

```bash
heaptrack ./zig-out/bin/franky-test
# Writes: heaptrack.franky-test.<pid>.zst (~5–50 MB)
```

Overhead: ~2–5× slowdown. Narrow with `-Dprofile-filter` first.

### 5.2 SVG flamegraphs via `heaptrack_print` + inferno

One trace produces four flamegraphs:

| Cost | Question | When |
|---|---|---|
| `peak` | "What was holding memory at high-water mark?" | Hunting OOMs / large RSS |
| `leaked` | "Which call paths allocated bytes never freed?" | Pinpointing leaks |
| `allocations` | "Which call paths make the most malloc calls?" | Finding malloc churn |
| `temporary` | "Which call paths allocate then free shortly after?" | Identifying arena candidates |

Single-cost example:
```bash
heaptrack_print -p 0 -a 0 -T 0 --flamegraph-cost-type peak -F mem-peak.folded -f heaptrack.franky-test.*.zst
inferno-flamegraph --title "franky-test — peak heap" --countname=bytes --colors=mem mem-peak.folded > mem-peak.svg
```

All four: shell loop in §5.2.3 of original doc.

### 5.2.4 What to expect for franky

- **`peak`** — provider response buffers (`sse.zig`, `partial_json.zig`) + transcript `ArrayList`.
- **`leaked`** — should be empty/near-empty (GPA already fails on leaks).
- **`temporary`** — `std.fmt.allocPrint` callers, JSON parse paths, short-lived `dupe()`s. Arena candidates.

### 5.2.5 Heaptrack version note

`heaptrack_print --print-flamegraph` ships in heaptrack 1.4+. `.zst` needs `zstd` on `$PATH`; otherwise falls back to `.gz`.

### 5.3 Headless text reports (no inferno)

```bash
heaptrack_print heaptrack.franky-test.*.zst         # full
heaptrack_print --print-leaks heaptrack.*.zst        # leaks only
heaptrack_print --print-peaks heaptrack.*.zst        # peak allocators
heaptrack_print --print-temporary heaptrack.*.zst    # short-lived allocs
```

### 5.4 Built-in Zig allocator trace

`std.heap.GeneralPurposeAllocator(.{ .verbose_log = true })` logs every alloc/free with stack trace. Already uses GPA with `.safety = true` — leak reports print at end of every test run.

---

## 6. Profiling specific scenarios

### 6.1 Single agent-loop turn

```bash
zig build profile -Dprofile-filter=parallel -- --binary franky-agent_loop_test --mode cpu
```

### 6.2 Tool-call hot paths

```bash
zig build profile -Dprofile-filter="edit tool"
zig build profile -Dprofile-filter="grep tool"
zig build profile -Dprofile-filter="find tool"
```

Profile in `ReleaseFast` to catch what the optimized build keeps in the hot loop.

---

## 7. Zig-specific gotchas

### 7.1 Allocator visibility

`heaptrack` hooks C `malloc`/`free`. GPA uses `mmap`/`munmap` for large allocs + free list for small ones — may under-count small Zig allocations. Switch to `std.heap.c_allocator` for profiling runs only.

### 7.2 ArenaAllocator + heaptrack

Arena allocates few large pages; heaptrack sees the large allocs but not per-object slicing inside. Expected, not a bug. For per-object visibility, wrap arena in custom debug allocator.

### 7.3 Frame-pointer preservation

`--call-graph fp` only works because `test-profile` sets `omit_frame_pointer = false`. Verify with:
```bash
objdump -d ./zig-out/bin/franky-test | head -50 | grep -E "push.*rbp|mov.*rsp.*rbp"
```
If missing, fall back to `--call-graph dwarf,16384`.

### 7.4 errdefer + signals

Test panic/abort: perf still records captured data; heaptrack handles abort gracefully via shutdown hook. `errdefer` chains run normally.

---

## 9. Reference

| Step | Command |
|---|---|
| One-shot (CPU + 4-cost memory) | `zig build profile -- --binary franky-test` |
| One-shot, narrowed | `zig build profile -Dprofile-filter=parallel -- --binary franky-agent_loop_test` |
| Verify tools / list binaries | `zig build profile -- --check` / `zig build profile -- --list` |
| Build profilable tests | `zig build test-profile -Doptimize=ReleaseSafe` |
| Build profilable tests, filtered | `zig build test-profile -Dprofile-filter=PATTERN` |
| Capture CPU (recommended) | `perf record -F 997 --call-graph fp -o perf.data -- <binary>` |
| Capture CPU (LBR) | `perf record -F 997 --call-graph lbr -o perf.data -- <binary>` |
| Capture CPU (DWARF) | `perf record -F 997 --call-graph dwarf,16384 -o perf.data -- <binary>` |
| CPU → folded | `perf script --input perf.data \| inferno-collapse-perf > cpu.folded` |
| CPU → SVG | `inferno-flamegraph cpu.folded > cpu.svg` |
| Capture memory | `heaptrack <binary>` → `heaptrack.*.zst` |
| Memory → folded (one cost) | `heaptrack_print -p 0 -a 0 -T 0 --flamegraph-cost-type <cost> -F mem.folded -f <trace>` |
| Memory → SVG | `inferno-flamegraph --countname=bytes --colors=mem mem.folded > mem.svg` |
| Differential CPU | `inferno-diff-folded before.folded after.folded \| inferno-flamegraph > diff.svg` |
