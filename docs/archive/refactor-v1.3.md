# Refactoring — grounded plan (v1.3.0 internal)

Grounded in code audit of v1.2.0 tree. Supersedes original generic plan — several items already done (error taxonomy, provider registry pattern, TUI MVC split) or low-value.

## Audit — real redundancy by the numbers

| Finding | Count | LOC impact |
|---|---|---|
| `toolError` / `err` helper duplicated across built-in tools | 7 × 7 LOC | ~49 identical lines |
| `writeTranscript` vs `writeBranchTranscript` | ~90% shared body | ~60 lines duplicated |
| Provider fetch + error-mapping boilerplate | 5 × ~30 LOC | ~150 near-identical lines |
| `paintFrame*` wrapper chain (onion-layered params) | 4 functions | ~30 boilerplate lines |
| `testIo()` helper | 28 copies | ~84 lines |
| `src/coding/modes/interactive.zig` size | 2503 lines | largest file by 2× |

Baseline: 615 tests at v1.0.0; 628 at v1.2.0.

## Status of original plan's recommendations

| Item | Status | Why |
|---|---|---|
| 1.1 Centralize utilities | ✅ rescoped | Real duplications are `toolError` (7×) and `testIo` (28×) |
| 1.2 Standardize error handling | ✅ already done | `src/ai/errors.zig` has `Code` enum + `ErrorDetails`; shipped v0.3, tightened v1.7.1 |
| 1.3 Review DTOs | — defer | No systemic issue surfaced |
| 2.1 Simplify provider interface | ✅ already done | `Registry.register({api, provider, stream_fn})` + single `StreamFn` pointer |
| 2.2 Decouple TUI components | ✅ already done | `text_buffer`/`editor`/`diff_renderer` already clean MVC |
| 2.3 Group CLI tools under system_wrappers | ✗ skip | Tools already in `src/coding/tools/`; rebadging adds zero value |
| 3.1 Minimize allocations | — defer | Profiler-guided; not this refactor |
| 3.2 Lifecycle review | ✅ already idiomatic | Zig `defer` usage consistent throughout |

## v1.3.0 refactoring plan — R1 through R6

Six phases, each self-contained commit with verified tests + measurable LOC win. Ordered low-risk → high-risk.

### R1 — Shared `toolError` helper
- Create `src/coding/tools/common.zig` with `pub fn toolError(alloc, code, msg) !at.ToolResult`
- Delete 7 private copies; replace with `common.toolError(…)`
- **Savings: ~49 LOC, zero behavior change.**

### R2 — Collapse `writeTranscript` / `writeBranchTranscript`
- Extract shared body into `renderTranscriptJson(buf, alloc, io, store_dir, transcript, branch)`
- Top-level fns become thin path-builders
- **Savings: ~40 LOC in `src/coding/session.zig`.**

### R3 — Single `paintFrame(buf, scrollback, editor, cfg)` with Config struct
- Replace 4 wrappers with one function + `PaintConfig` struct (status, palette, scroll_offset, search_query, no_color — all defaulted)
- **Savings: ~30 LOC + clearer intent at call sites.**

### R4 — Shared test `testIo()` helper
- Move to `src/test_helpers.zig` exported via `franky.test_helpers`
- Delete 28 copies
- **Savings: ~84 LOC.**

### R5 — Provider fetch-and-drain template
- Extract "build FetchOptions, call `fetchWithRetryAndTimeoutsAndHooks`, map HTTP errors to `error_ev` events, hand body bytes to caller" into `http.providerFetch(ctx, opts)`
- Each provider `streamFn` shrinks to: build body → call template → hand bytes to SSE translator
- **Savings: ~100–150 LOC across 5 providers. Risk: medium** (hot-path, but well-covered by tests).

### R6 — Split `interactive.zig` into logical sub-modules *(separate session)*
Target: `mod.zig` (~100), `session.zig` (~300), `history.zig` (~200), `paint.zig` (~400), `handlers.zig` (~500), `repl.zig` (~500), `tests.zig` (~200). 2503-line file → ~7 files averaging 300 LOC. Risk: medium-low; imports reshuffle, logic identical.

## What we skip intentionally

- **Provider SDK / Model registry consolidation** — `Registry + StreamFn + ai.types.Model` already clean contract. Per-provider JSON body builders reflect actual wire-format differences.
- **`compaction.zig` / `branching.zig` split** — each has one coherent responsibility.
- **Centralize HTTP retry** — already centralized in `ai/http.zig` (v1.3.1).
- **Tool schema builders** — each tool's JSON schema is unique; no shared pattern.

## Success criteria for v1.3.0

- Build: green. Tests: ≥ 628 passing. LOC: net ~−400 across R1–R5. User-visible behavior: **zero changes**.

## Post-v1.3.0 candidates (out of scope)

- R6 as above.
- OSC 52 clipboard, Alt-Enter multi-line, render throttling (documented in `tui-roadmap.md`).
- Profiler-guided allocation reductions.
