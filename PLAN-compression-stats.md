# Plan: Compression Statistics

## Goal

Add compression statistics (bytes before/after, items compressed/passthrough) to the session state, expose them via the `/usage` endpoint, and render them in the web UI status-line popover and interactive mode status line — similar to how tool usage counts and token sums are already displayed.

## Motivation

Users need visibility into how much context-window space compression is saving. Without stats, compression is a black box — the LLM sees `<<<ccr:...>>>` markers but the user has no idea how many bytes were saved.

## Design

### 1. CompressionStats struct (`src/coding/compression.zig`)

Add a public struct to track per-session compression metrics:

```zig
pub const CompressionStats = struct {
    /// Total bytes of tool output text before compression.
    bytes_before: u64 = 0,
    /// Total bytes of tool output text after compression.
    bytes_after: u64 = 0,
    /// Number of text blocks that were compressed.
    items_compressed: u64 = 0,
    /// Number of text blocks that passed through (too small, incompressible, etc).
    items_passthrough: u64 = 0,
    /// Number of text blocks that failed compression (fell back to passthrough).
    items_failed: u64 = 0,
};
```

### 2. Update `compressToolResult` to accept optional stats pointer

Add a `maybe_stats: ?*CompressionStats` parameter to `compressToolResult`. When non-null, update the counters:

- On successful compression: `bytes_before += input.len`, `bytes_after += compressed.len`, `items_compressed += 1`
- On min-bytes passthrough: `items_passthrough += 1`
- On min-ratio gate passthrough: `items_passthrough += 1`
- On compression error: `items_failed += 1`, `items_passthrough += 1` (original passed through)

### 3. Add `compression_stats` to proxy Session struct

In `src/coding/modes/proxy.zig`, add to the `Session` struct:

```zig
/// v3.0 — compression statistics for the status line.
compression_stats: compression_mod.CompressionStats = .{},
```

Initialize in both `initSession` and `testSessionInit`.

### 4. Track stats in the agent loop drain

In `src/coding/modes/proxy.zig`, in the `runOneTurnInternal` function where `tool_execution_end` events are drained (around line 2309), pass the session's `compression_stats` pointer through to the loop config.

The loop config already has `compression` and `ccr_store` fields. Add a `compression_stats` field to `loop.Config` in `src/agent/loop.zig`:

```zig
/// v3.0 — optional stats collector for compression metrics.
compression_stats: ?*compression_mod.CompressionStats = null,
```

Then in both the sequential and parallel tool result paths, pass `config.compression_stats` to `compressToolResult`.

### 5. Expose via `/usage` endpoint

In `src/coding/modes/proxy.zig`, in `respondUsage` (line 2651), append compression stats to the JSON response:

```json
{
  "guardrails": 2,
  "tools": {"bash": 4, "read": 5},
  "inputTokens": 1234,
  "outputTokens": 567,
  "compression": {
    "bytesBefore": 50000,
    "bytesAfter": 8000,
    "saved": 42000,
    "ratio": 0.84,
    "itemsCompressed": 12,
    "itemsPassthrough": 3,
    "itemsFailed": 0
  }
}
```

### 6. Render in web UI status line

In `src/coding/modes/web/app.js`, update `refreshStatusLineUsage` (line 2849) to show compression savings in the status line:

```
12s · 5 tools · in 1.2k / out 567 · saved 42k (84%)
```

Update `renderStatusPopover` (line 2756) to add a "Compression" section:

```
Session usage
  Tool calls: 5
    bash: 4
    read: 1
  Guards: 2
  Tokens (cumulative)
    Input: 1.2k
    Output: 567
  Compression
    Saved: 42k (84%)
    Compressed: 12 blocks
    Passthrough: 3 blocks
```

### 7. Render in interactive mode status line

In `src/coding/modes/interactive.zig`, in the status line builder (around line 609), add compression savings when available.

## Files to modify

| File | Change |
|------|--------|
| `src/coding/compression.zig` | Add `CompressionStats` struct, add `maybe_stats` param to `compressToolResult` |
| `src/agent/loop.zig` | Add `compression_stats` field to `Config`, pass to `compressToolResult` |
| `src/coding/modes/proxy.zig` | Add `compression_stats` to `Session`, wire into loop config, add to `respondUsage` |
| `src/coding/modes/web/app.js` | Update `refreshStatusLineUsage` and `renderStatusPopover` |
| `src/coding/modes/interactive.zig` | Add compression savings to status line |
| `src/coding/modes/print.zig` | Wire compression_stats into loop config |
| `src/coding/modes/rpc.zig` | Wire compression_stats into loop config |

## Testing

- Unit test for `CompressionStats` accumulation
- Integration test verifying `/usage` returns compression stats
- Visual verification of web UI status line and popover

## Order of implementation

1. `CompressionStats` struct + `compressToolResult` wiring
2. `loop.Config` field + pass-through in both paths
3. Proxy mode: Session field + `/usage` endpoint
4. Web UI: status line + popover
5. Interactive mode: status line
6. Print + RPC modes: wire stats
