# Post-v1.0 refactoring decision record

> **Stale snapshot — captured pre-v1.30.0.** `src/coding/oauth/` and `src/coding/modes/login.zig` deleted in v1.30.0; LOC tables and Option A/B refactor plans for those trees are moot. Kept as historical record.

**Status: open — captured 2026-04-27 at v1.15.2 (798/798 tests).**
**Companion to:** `refactor.md` (closed v1.3.0 internal refactor history).

Three candidate refactoring directions for the v1 mode layer. None scheduled; catalog with recommendation.

## Context

- v1.15.2. v2 deferred-work catalog (`../spec/v2.md`) has §1.7 RPC method-surface depth open — dispatcher in `src/coding/modes/rpc.zig` ships only `ping`, `version`, `role`, `prompt`, `abort`, `permission/resolve`. Full §I.1 catalog (~16 methods) not wired, though every method has working in-process implementation.
- User asked: "would unifying TUI and Web UI behind RPC give one backend / two frontends?" → mostly no; real unification opportunity is at service-struct layer, not transport.

## Current mode-layer LOC

| File | Lines | Prod | Tests |
|---|---|---|---|
| `src/coding/modes/proxy.zig` | 4087 | ~2386 | ~1701 (55 tests) |
| `src/coding/modes/interactive.zig` | 2956 | — | — |
| `src/coding/modes/print.zig` | 1588 | — | — |
| `src/coding/modes/rpc.zig` | 671 | — | — |
| `src/coding/modes/login.zig` | 355 | — | — |
| **mode total** | **9657** | | |

`Session` struct + `initSession` + `persistSession` duplicated across `rpc.zig`, `proxy.zig`, `interactive.zig` — same shape, slightly different fields. This is the load-bearing duplication.

## Option A — Phases 1+2: extract `AgentService`, then fill §I.1

**Phase 1.** Extract `src/coding/agent_service.zig` owning shared session shape (agent + registry + provider + role gate + permission store + transcript). Mode `Session` structs become thin adapters. No behavior change.

**Phase 2.** Wire missing §I.1 methods in `rpc.zig` against new service. ~30-50 LOC per method.

**Phase 3 (optional).** `proxy.zig` adopts same service for `/session/*`, `/compact`, `/retry`, `/edit`.

**Phase 4 (doc-only).** Record "TUI as out-of-process RPC client" idea in `../spec/v2.md`.

**Net LOC delta:** +300 to +1100. Phase 2 pure addition; Phase 3 saves less than Phase 2 adds.

| File | Before | After (est) | Δ |
|---|---|---|---|
| `agent_service.zig` (new) | 0 | ~600-800 | +600-800 |
| `rpc.zig` | 671 | ~1100-1300 | +400-600 |
| `proxy.zig` | 4087 | ~3500-3800 | -300-600 |
| `interactive.zig` | 2956 | ~2800-2900 | -50-150 |

**Pros:** Single source of truth for agent orchestration; bugs like v1.7.6→v1.7.11 chain become structurally impossible; reduces mode-file coupling; closes v2 §1.7; tests narrow.

**Cons:** Net LOC up; indirection (tracing bugs crosses files); abstraction-tax risk; one-time test churn (30-60 mode tests). **Effort:** ~1-2 weeks.

## Option B — Phase 2 only: wire §I.1 directly in rpc.zig

Skip service extraction. Wire each missing §I.1 method directly against existing in-process APIs.

**Pros:** Closes v2 §1.7; no architectural risk; ~3-5 days; each method ships independently.

**Cons:** `Session` triplicate stays; adds ~400-600 LOC to `rpc.zig` without structural payoff; Phase 1 harder later. **Effort:** ~3-5 days.

## Option C — Focused proxy.zig diet (no architectural change) — ✅ partially shipped v1.20.0

**Status (2026-04-28):** Two extractions landed, three deferred. v1.20.0 shipped:
- `proxyHttpClient` + `runProxyHttpRequest` test fixture (replaces 11 duplicated client-thread blocks)
- `ProxyTestSession.initFor` bundle (collapses cfg + environ_map + session boilerplate across 12 HTTP tests)

Net −188 LOC, 878/878 tests green. Remaining cleanups (slash-handler unification, endpoint dispatcher, renderer merge, JSON-helper extraction) deferred as medium-risk-for-marginal-return.

Five plausible cleanups:

| Cleanup | Realistic savings | Risk |
|---|---|---|
| Merge `renderTranscriptMarkdown` + `renderTranscriptForUi` | ~100-150 | Low |
| Unify slash-command handlers with `interactive.zig` | ~150-250 | Medium |
| Extract endpoint-handler boilerplate dispatcher | ~50-100 | Low |
| Test fixtures for 55 SSE-based tests | ~200-400 | Low |
| Misc JSON helpers to shared file | ~20-50 | Trivial |
| **Realistic total** | **~500-950** | |

**Pros:** Lowest risk; real net LOC reduction; tightens web-UI/TUI parity via slash-command unification.

**Cons:** Doesn't close any v2 catalog item; `Session` triplicate stays; doesn't reduce mode-to-internals coupling.

## Recommendation

**Option A Phase 1 first** (extract `AgentService`), then decide Phase 2 vs Option B based on how clean the extraction is. Option C cleanups can happen anytime in parallel (low-risk, proxy.zig only).
