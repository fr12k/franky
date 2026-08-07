# HIGH — Do First Refactoring Plan

Four top-priority findings, ordered by safety and impact. Each phase stays green at every step (`zig build test`).

| Phase | Finding | Status |
|-------|---------|--------|
| 1 | Make `cancel` non-optional (§3.1) | ⏳ Pending |
| 2 | Consolidate JSON Helpers (§1.1) | ✅ Complete |
| 3 | Extract Workspace Canonicalization (§1.2) | ⏳ Pending |
| 4 | Add Tests for Destructive Tools (§2.1) | ⏳ Pending |

---

## Phase 1: Make `cancel` non-optional (§3.1)

**Goal:** Remove `orelse unreachable` anti-pattern from 5 providers by making `StreamOptions.cancel` a required, non-optional pointer.

- **File:** `src/ai/registry.zig:31` — change `cancel: ?*stream_mod.Cancel = null` → `cancel: *stream_mod.Cancel`
- Remove `orelse unreachable` at: `anthropic.zig:589`, `openai_chat.zig:532`, `openai_responses.zig:381`, `google_gemini.zig:393`, `google_vertex.zig:96`
- Fix call sites constructing bare `StreamOptions{}`: `agent/agent.zig:56`, `coding/compaction.zig:265`, `ai/http.zig` (test side), `ai/providers/openai_gateway.zig` (tests)

**Impact:** Type system enforces invariant. Removes 5 latent panic sites.

---

## Phase 2: Consolidate JSON Helpers (§1.1) ✅ COMPLETE

Deleted ~150 lines of duplicated `appendJson*` functions across 4 provider files. Canonical versions in `src/ai/utils.zig`.

| File | Import Added | Calls Replaced | Functions Deleted | Net Lines |
|------|-------------|----------------|-------------------|-----------|
| `src/ai/providers/anthropic.zig` | `utils = @import("../utils.zig")` | 21 | `appendJsonStr`, `appendJsonInt`, `appendJsonFloat` | −28 |
| `src/ai/providers/openai_chat.zig` | *(already imported)* | 18 | `appendJsonStr`, `appendJsonRaw`, `appendJsonInt`, `appendJsonFloat` | −35 |
| `src/ai/providers/openai_responses.zig` | *(already imported)* | 14 | `appendJsonStr`, `appendJsonInt`, `appendJsonFloat` | −30 |
| `src/ai/providers/google_gemini.zig` | `utils = @import("../utils.zig")` | 12 | `appendJsonStr`, `appendJsonInt`, `appendJsonFloat` | −29 |
| `src/ai/providers/google_vertex.zig` | — | — | — | 0 *(re-exports `gemini.buildRequestJson`)* |

**Total deletion: ~122 lines.** Verified: `zig ast-check` ✅, `zig build test` ✅, `zig build` ✅.

---

## Phase 3: Extract Workspace Canonicalization (§1.2)

**Goal:** Delete ~80 lines of identical workspace-safety boilerplate across 7 tools by adding shared helper in `tools/common.zig`.

Add `resolveWorkspacePath(allocator, ctx, user_path)` to `common.zig` — returns `{ path, owned }`. Replace 12-line block in each tool with 4-line call.

**Files:** `read.zig`, `write.zig`, `edit.zig`, `ls.zig`, `find.zig`, `grep.zig`, `bash.zig`.

**Impact:** Path safety logic in one place; workspace escape bug fixes are single-edit.

---

## Phase 4: Add Tests for Destructive Tools (§2.1)

### 4a — edit.zig (priority)
`replaceOnce` basic, zero-length new string, `replaceAll` multiple matches, `applyEdits` conflict/ambiguous/no-match/atomic-write paths.

### 4b — bash.zig
Trailer parsing, trailer collision, `SessionBashState` setCwd/getCwd round-trip, timeout enforcement, output chunking/1 MiB cap, exit code capture.

### 4c — permissions.zig
`check` deny-list precedence over allow-list and `yes_to_all`, `fingerprintBash` path stripping, `extractBashCommand` with escaped quotes and malformed input.

**Impact:** Highest confidence insurance against regressions in destructive operations.

---

## Notes

- `google_vertex.zig` already correct — re-exports `gemini.buildRequestJson` and `gemini.runFromSse`.
- Phase 1 should come first (type-level change affecting `StreamOptions` construction sites).
- Phases 2 (✅ done) and 3 are pure deletions + import changes — same risk profile (low).
- Phase 4 is additive and naturally validates preceding phases.
