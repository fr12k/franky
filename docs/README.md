# franky docs

The whole map.

## spec/ — authoritative version-by-version contract

| File | Purpose |
|---|---|
| [`spec/v2.md`](spec/v2.md) | **Active v2.x spec — start here for current work.** Open backlog + new v2.x rows. The v2.x line opened 2026-05-01 at 2.0.0. Items in §1–§4 are the carry-over backlog from the v1.x line; new shipped work is logged in the §6 "items shipped after the v1.0.0 cut" row table. |
| [`spec/v1.md`](spec/v1.md) | **Concluded v1 spec — historical reference.** Architecture (§1-§14), implementation reference (§A-§S), per-version row table for v1.0.0 → v1.31.0. Most rows ✅; rows for features that shipped earlier in v1.x and were later removed carry `❌ removed in vX.Y.Z`. Read-only as of 2026-05-01 — edits are limited to factual fixes + `❌` flips when a v1.x feature is later removed. Source code `§` markers continue to point here for v1-introduced subsystems. |
| [`spec/v0.md`](spec/v0.md) | Frozen v0.* development history. Read for "when and how did feature X land in v0.*?" — append-only from here. |
| [`spec/v3.md`](spec/v3.md) | Open spec for next-major work past v2.x. Items here imply user-visible UX surface or extend a v1/v2 primitive substantially enough to need spec-level design before implementation. |

## design/ — design proposals

| Subdir | Status |
|---|---|
| [`design/open/`](design/open/) | Pending review or partial implementation. Each file marks decisions with `✓ accept` / `→ <override>` / `?`. |
| [`design/decided/`](design/decided/) | Historical record of resolved designs. The shipped behavior lives in `spec/v1.md`'s row table — these docs are the *paper trail* of how those rows came to be. |

## limits/ — capacity & design-parameter notes

| File | Topic |
|---|---|
| [`limits/stream-channel-capacity.md`](limits/stream-channel-capacity.md) | The provider→reducer stream channel: capacity choice, the single-thread deadlock history, and how to read the `stream_channel_high_watermark` log line. |

## archive/ — stale snapshots

Not consulted day-to-day; kept so `git log --follow` works for old PRs.

| File | Era |
|---|---|
| [`archive/refactor-v0.md`](archive/refactor-v0.md) | v0 era refactoring plan. |
| [`archive/refactor-v1.3.md`](archive/refactor-v1.3.md) | v1.3.0 internal refactoring plan. |
| [`archive/refactor-v1.15.md`](archive/refactor-v1.15.md) | v1.15.2 audit decisions. |
| [`archive/profiling_guide.md`](archive/profiling_guide.md) | Profiling guide (CPU flamegraph, memory dimensions). |
| [`archive/design/`](archive/design/) | Archived design RFCs (presets, subagent, web UI, guardrails, etc.). |

## Per-version history

Per-version history lives in the spec row tables themselves:
the implementation-status table at the top of [`spec/v1.md`](spec/v1.md)
is the spec-level view for the v1.x line (each row marks current ✅/❌
state), and [`spec/v2.md`](spec/v2.md) §6 is the chronological view for
items shipped after the v1.0.0 cut.