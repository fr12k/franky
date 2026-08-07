# Refactoring Plan — Tool Management Consolidation + Interactive Mode Removal

**Goal:** Eliminate redundant tool-management code AND remove interactive
mode entirely, reducing the codebase from 4 run modes to 3 (`print`,
`proxy`, `rpc`) and routing all remaining modes through the existing
`config.resolve()` pipeline. **Primary outcome:** significantly less code
in total.

**Assessment conducted by 3 models (ollama-cloud):**
- `deepseek-v4-flash` — redundancy analysis
- `gemma4:31b` — refactoring structure + line estimates
- `minimax-m3` — risk + effort assessment

---

## 1. Problem Statement

`config.zig` already contains a complete, well-structured `resolve()`
function (lines 952–1340) that builds the entire tool set through a
deterministic pipeline:

```
base 9 tools → workspace/plain variant → role filter → extension merge
            → append [subagent, listPresets, finishTask, ccr_retrieve,
                      memory_search, memory_save]
```

**Only `print.zig` (line 220) calls `config.resolve()`.** The other two
tool-bearing modes — `rpc.zig`, `proxy.zig` — each re-implement the same
pipeline independently, resulting in ~200 lines of duplicated
tool-construction logic spread across 2 files.

**Additionally**, the `interactive` mode (a raw-terminal TUI REPL,
`src/coding/modes/interactive.zig`, 3,559 lines) will be **removed
entirely**. It is the most complex, highest-risk mode to maintain, is the
sole consumer of the entire `src/tui/` library (2,380 lines) and
`src/coding/terminal.zig` (265 lines), and has zero mode-level integration
tests. Its functionality (multi-turn conversation with a UI) is fully
covered by `proxy` mode (web UI served by the built-in HTTP server).

### 1.1 Where the tool-building duplication lives (post-interactive-removal)

| Block | `config.zig` (canonical) | `rpc.zig` | `proxy.zig` |
|---|---|---|---|
| Base-9 tool array | 1055–1114 | 176–186 | 634–644 |
| Role filtering | 1116–1124 | 187 | 645 |
| Extension merge | 1156–1162, 1244–1254 | ❌ missing | 843–847, 878–882 |
| Preset registry + subagent ctx | 1224–1243 | 386–417 | 830–877 |
| Final tool append | 1244–1265 | 418–424 | 878–889 |
| Memory tools | 1260–1262 | ❌ missing | ❌ missing |
| Settings overlay | internal to resolve | 196+ | 651–660 |
| finishTask tool | 1257 | 696–701 (per-prompt) | 886 |

### 1.2 What each remaining mode duplicates vs. what it uniquely needs

| Aspect | rpc | proxy |
|---|---|---|
| Same base-9 tools | ✅ identical set | ✅ identical set |
| Workspace variants | ❌ always plain | ❌ always plain |
| Role filtering | ✅ same `filterTools` | ✅ same |
| Extensions | ❌ not loaded | ✅ loaded |
| `subagent` tool | ✅ | ✅ |
| `listPresets` tool | ✅ | ✅ |
| `finishTask` tool | ✅ (per-prompt, 696) | ✅ |
| `ccr_retrieve` tool | ✅ | ✅ |
| `memory_search/save` | ❌ **missing** | ❌ **missing** |
| **Unique need** | `progress_fn` for JSON-RPC event forwarding; per-prompt `finishTask` | per-prompt `prompter` slot in subagent ctx |

**Key finding:** rpc and proxy are **missing features** that
`config.resolve()` already provides (extensions in rpc; memory tools in
both). Consolidating fixes these latent gaps.

---

## 2. Root Cause: The "Stable Address" Problem

The fundamental blocker preventing rpc/proxy from calling `config.resolve()`
is **pointer stability**. `config.resolve()` allocates tools on its own arena
and wires ctx pointers to its own internal state (`bash_ctx`, `read_ctx`,
`web_search_ctx`, `subagent_ctx`). But rpc/proxy need tool ctx pointers to
reference **session-owned state** (`session.bash_state`, `session.ccr_ctx`,
`session.permission_store`), which is initialized *after* config resolution
would run.

Additionally:
- **rpc** needs a `progress_fn` (`subagentProgressForward`) in its subagent
  ctx for JSON-RPC event forwarding.
- **proxy** needs a `permission_prompter_slot` pointing at
  `session.current_prompter` (set per-prompt).

These are **late-binding** concerns, not fundamental architectural
incompatibilities.

> **Note on ctx pointers:** Each `AgentTool` carries a `ctx: ?*anyopaque`
> field — a type-erased pointer to session-owned state (workspace path-safety,
> bash cwd tracking, subagent session handle, CCR store, memory DB, etc.).
> These pointers are genuinely needed (the workspace ctx is the sandbox
> safety switch; the subagent ctx is the entire parent-session handle). What
> is *not* needed is the duplicated code that wires them up — that's what
> this refactoring eliminates. The pointers stay; the 2 independent copies
> of the wiring code go away.

---

## 3. Proposed Structure: Two-Phase Tool Builder

Extract the tool pipeline from `config.resolve()` into reusable pieces
that all 3 remaining modes can call, with late-binding hooks for the
mode-specific parts.

### 3.1 `buildBaseToolSet` (static phase)

```zig
pub fn buildBaseToolSet(
    allocator: std.mem.Allocator,
    role: role_mod.Role,
    workspace: ?*tools_mod.workspace.Workspace,
    bash_ctx: ?*tools_mod.bash.BashCtx,
    bash_state: ?*tools_mod.bash.SessionBashState,
    read_ctx: ?*tools_mod.read.ReadCtx,
    web_search_ctx: ?*tools_mod.web_search.WebSearchCtx,
) ![]const at.AgentTool
```

- Builds the base 9 tools with workspace-or-plain variants.
- Applies role filtering.
- Returns the filtered slice.
- **Replaces:** rpc.zig 176–187, proxy.zig 634–645,
  config.zig 1055–1124 (internal callers use this too).

### 3.2 `finalizeToolSet` (late-binding phase)

```zig
pub const ToolBindingCtx = struct {
    base_tools: []const at.AgentTool,
    ext_tools: []const at.AgentTool,         // may be empty
    subagent_ctx: *tools_mod.subagent.Ctx,
    preset_registry: *tools_mod.subagent.PresetRegistry,
    guardrail_state: *agent.guardrails.GuardrailState,
    ccr_ctx: ?*anyopaque,                     // patched by mode
    memory_state: ?*MemoryState,
};

pub fn finalizeToolSet(
    allocator: std.mem.Allocator,
    ctx: ToolBindingCtx,
) ![]const at.AgentTool
```

- Copies `base_tools` + `ext_tools` into a new slice.
- Appends `subagent`, `listPresets`, `finishTask`, `ccr_retrieve`.
- Appends `memory_search` + `memory_save` when `memory_state != null`.
- **Replaces:** rpc.zig 418–424, proxy.zig 878–889, config.zig 1244–1265.

### 3.3 Mode integration

Each mode's flow becomes:

```
1. config.resolve() → ResolvedConfig  (print already does this)
   OR  buildBaseToolSet()              (for modes needing session-owned ctx)
2. Initialize Session struct (owns bash_state, ccr_ctx, etc.)
3. Build subagent ctx with mode-specific hooks (progress_fn, prompter_slot)
4. finalizeToolSet(base_tools, ext_tools, subagent_ctx, ...) → final tools
5. Wire ccr_retrieve ctx pointer (late bind to session.ccr_ctx)
```

---

## 4. Interactive Mode Removal

### 4.1 What gets deleted

Interactive mode is a raw-terminal TUI REPL. It is the **sole consumer** of
several modules that exist only to serve it:

| Component | File(s) | Lines | Used by any other mode? |
|---|---|---|---|
| Interactive mode driver | `src/coding/modes/interactive.zig` | 3,559 | No |
| TUI library | `src/tui/*.zig` (9 files) | 2,380 | No |
| Terminal raw-mode wrapper | `src/coding/terminal.zig` | 265 | No |
| TUI/terminal module exports | `src/root.zig:14,41`, `src/coding/mod.zig:24,29,108,111` | ~6 | No |

**Total lines deleted:** **~6,210 lines**

### 4.2 What stays (shared, used by other modes)

These are referenced by interactive mode comments but are **not**
interactive-specific — they're used by proxy/rpc too and must stay:

| Component | File | Why it stays |
|---|---|---|
| Slash command framework | `src/coding/slash.zig` (262) | Proxy mode uses it (`POST /command` route, 30+ handlers in proxy.zig) |
| Permission prompter | `src/coding/security/permissions.zig` | Proxy + rpc use `PermissionPrompter` + `current_prompter` slot |
| Session creation | `src/coding/session/create.zig` | print/rpc/proxy all call `SessionState.init` |
| Diagnostics | `src/coding/diagnostics.zig` | Uses `mode_name` as a free-form display string, not the Mode enum — only test fixtures pass `"interactive"` |
| Improvement reports | `src/coding/improvement.zig` | Same — `mode` field is a parsed JSON string, not the enum |
| Skills | `src/coding/skills.zig` | Comments mention "proxy + interactive" but the code is proxy-shared |

### 4.3 Code changes required for removal

| File | Change |
|---|---|
| `src/coding/config/cli.zig:27` | Remove `.interactive` from `pub const Mode = enum { print, interactive, rpc, proxy }` → `enum { print, rpc, proxy }` |
| `src/coding/config/cli.zig:630` | Remove `else if (std.mem.eql(u8, v, "interactive")) cfg.mode = .interactive` |
| `src/coding/config/cli.zig:15,695,719` | Update help/usage text: remove `interactive` from mode list |
| `src/coding/modes/print.zig:191–196` | Remove the `if (cfg.mode == .interactive)` dispatch block |
| `src/coding/mod.zig:24` | Remove `pub const interactive = @import("modes/interactive.zig")` |
| `src/coding/mod.zig:108` | Remove `_ = modes.interactive` keepalive |
| `src/coding/mod.zig:29` | Remove `pub const terminal = @import("terminal.zig")` |
| `src/coding/mod.zig:111` | Remove `_ = terminal` keepalive |
| `src/root.zig:14` | Remove `pub const tui = @import("tui/mod.zig")` |
| `src/root.zig:41` | Remove `_ = tui` keepalive |
| `src/coding/config/profiles.zig:613` | Remove `if (std.mem.eql(u8, s, "interactive")) return .interactive` |
| `src/coding/config/profiles.zig:1354` | Remove test `try testing.expectEqual(cli.Mode.interactive, ...)` |
| `src/coding/skills.zig:322,349` | Update comments: remove "interactive" mentions |
| `src/coding/review.zig:3` | Update comment: remove "interactive" mention |
| `src/agent/guardrails/finish_task.zig:31` | Update tool description: remove "and interactive modes" |
| `src/coding/security/permissions.zig:13,592` | Update comments/error text: remove "interactive" mentions |
| `src/coding/session/create.zig:5` | Update comment: remove "interactive.zig" mention |
| `src/agent/loop.zig:204` | Update comment: remove "interactive prompts the user" |
| `src/coding/tools/subagent.zig:638,957` | Update comments: remove "interactive" from the list of modes that set prompter_slot |
| `README.md` | Update: "three run modes" instead of "four", remove `interactive` from mode list |
| `AGENTS.md:19` | Update: "3 (print/rpc/proxy)" instead of "4" |
| `docs/EXTENSION.md` | Remove interactive-mode examples |
| Delete files | `src/coding/modes/interactive.zig`, `src/tui/` (9 files), `src/coding/terminal.zig` |

### 4.4 Behavioral impact

- Users who ran `franky --mode interactive` (the TUI REPL) will get an
  `UnknownMode` error. **Mitigation:** the CLI error message should suggest
  `--mode proxy` (web UI) as the replacement for interactive multi-turn
  sessions.
- `franky` with no `--mode` flag still defaults to `print` — unchanged.
- No test coverage is lost: `interactive.zig` has 0 mode-level integration
  tests (confirmed: `grep -c "test \"" src/coding/modes/interactive.zig` = 0).

---

## 5. Estimated Line Reduction

### 5.1 Interactive mode removal

| Component | Lines |
|---|---|
| `src/coding/modes/interactive.zig` | −3,559 |
| `src/tui/*.zig` (9 files) | −2,380 |
| `src/coding/terminal.zig` | −265 |
| Module-export + dispatch cleanup | −~30 |
| **Subtotal** | **−~6,234** |

### 5.2 Tool consolidation (remaining 3 modes)

| File | Current LOC | Lines removed | Lines added (calls) | Net |
|---|---|---|---|---|
| `config.zig` | 1409 | ~70 (extracted to helpers) | ~90 (new helpers) | +20 |
| `print.zig` | 3097 | ~10 | ~5 | −5 |
| `rpc.zig` | 954 | ~120 | ~25 | −95 |
| `proxy.zig` | 5712 | ~110 | ~25 | −85 |
| **Subtotal** | | **~240** | **~145** | **−165** |

### 5.3 Grand total

| Metric | Value |
|---|---|
| Interactive mode removal | −~6,234 lines |
| Tool consolidation (3 modes) | −~165 lines |
| **Total net reduction** | **~6,400 lines** |
| Codebase before | ~72,214 lines (114 Zig files) |
| Codebase after | **~65,800 lines (~103 files)** |
| Modes | 4 → 3 |
| Feature gaps fixed (bonus) | rpc: extensions, memory; proxy: memory |

---

## 6. Risk + Effort Assessment (per phase)

### Phase 1 — Extract helpers from `config.zig` (Low risk)
1. Extract `buildBaseToolSet()` from config.zig 1055–1124.
2. Extract `finalizeToolSet()` + `ToolBindingCtx` from config.zig 1244–1265.
3. Have `config.resolve()` internally call these helpers.
4. **Validate:** all tests pass, print mode unchanged.

### Phase 2 — Remove interactive mode (Low–Medium risk)
1. Delete `interactive.zig`, `src/tui/`, `terminal.zig`.
2. Remove `.interactive` from the `Mode` enum + parser + help text.
3. Remove the interactive dispatch block in `print.zig:191–196`.
4. Clean up module exports in `root.zig` + `coding/mod.zig`.
5. Update comments/doc strings in ~10 files (mechanical, no behavior change).
6. Update `README.md`, `AGENTS.md`, `docs/EXTENSION.md`.
7. **Validate:** `zig build test` — no test references interactive mode's
   `Mode.interactive` enum value except `profiles.zig:1354` (remove that
   test line). All other `interactive` references are comment strings or
   free-form display labels in diagnostics/improvement tests (unaffected).

| Risk | Severity | Mitigation |
|---|---|---|
| Breaking users who rely on `--mode interactive` | Medium | CLI error message suggests `--mode proxy`; proxy's web UI covers the use case |
| Orphaned import in `mod.zig` / `root.zig` | Low | Remove the `_ = modes.interactive` / `_ = tui` keepalive lines |
| Hidden TUI dependency in another file | Low | Verified: `grep -rln "tui" src` outside `src/tui/` and `interactive.zig` returns only `root.zig` (the export) |

### Phase 3 — Consolidate `rpc.zig` (Medium risk, feature gain)
1. Replace rpc.zig 176–187 with `buildBaseToolSet()`.
2. Replace rpc.zig 418–424 with `finalizeToolSet()`.
3. Add `progress_fn` hook to `ToolBindingCtx` for JSON-RPC forwarding.
4. Decide: keep per-prompt `finishTask` (696–701) or move to init-time.
5. **Bonus:** rpc gains extension support + memory tools (if desired).
6. **Validate:** run rpc mode tests.

### Phase 4 — Consolidate `proxy.zig` (Medium risk, feature gain)
1. Replace proxy.zig 634–645 with `buildBaseToolSet()`.
2. Replace proxy.zig 878–889 with `finalizeToolSet()`.
3. Verify `permission_prompter_slot` pointer stability (already pointer-to-slot).
4. **Bonus:** proxy gains memory tool support.
5. **Validate:** run proxy mode tests + manual web UI smoke test.

---

## 7. Recommended Refactoring Order

Based on risk levels (lowest first):

```
Phase 1: Extract helpers in config.zig        (Low risk, no behavior change)
Phase 2: Remove interactive mode entirely     (Low–Medium, -6,234 lines)
Phase 3: Consolidate rpc.zig                  (Medium, +features, -95 lines)
Phase 4: Consolidate proxy.zig                (Medium, +features, -85 lines)
```

**Phase 2 (interactive removal) before Phase 3/4 (tool consolidation)**
is intentional: removing interactive first eliminates the highest-risk
consolidation target (the minimax-m3 model rated interactive "High"
difficulty due to per-turn tool re-binding). Once it's gone, the
remaining consolidation is just rpc + proxy — both Medium difficulty.

---

## 8. Validation Strategy

The repo has ~881 tests. Relevant test coverage:

```bash
# Find mode-specific tests
grep -rln 'test "' src/coding/modes/
grep -rn 'test "' src/coding/config.zig
# Check no test depends on Mode.interactive (except the one profiles test line)
grep -rn 'interactive' src/coding/config/profiles.zig  # line 613, 1354
```

**Per-phase validation:**
1. After Phase 1: `zig build test` — all tests pass (no behavior change).
2. After Phase 2: `zig build test` — confirm compilation succeeds with
   interactive removed; verify `--mode interactive` gives a clean error.
3. After Phase 3: `zig build test` + manual rpc smoke test
   (`echo '{"method":"ping"}' | franky --mode rpc`).
4. After Phase 4: `zig build test` + manual proxy smoke test
   (`franky --mode proxy` + curl `/health` + `/prompt`).

**Regression watch:** the `ccr_retrieve` ctx late-binding (config.zig 1259,
print.zig 271–276) must be preserved in all modes — tools with `null` ctx
get patched after session init. Verify each mode does this.

---

## 9. Summary — Actual Results

**All 4 phases completed and committed. All tests pass.**

| Metric | Planned | Actual |
|---|---|---|
| Interactive mode removal | −~6,234 lines | −6,320 lines |
| Tool consolidation (rpc + proxy) | −~165 lines | −63 lines (rpc −20, proxy −23) |
| New helper code in config.zig | ~145 lines | +76 lines net (config.zig 1409→1485) |
| **Total net reduction** | **~6,400 lines** | **6,189 lines** |
| Codebase before | 72,214 lines / 114 files | |
| Codebase after | ~65,800 lines / ~103 files | **66,025 lines / 103 files** |
| Modes | 4 → 3 | ✅ 4 → 3 (print, proxy, rpc) |
| Files deleted | 11 | ✅ 11 (interactive.zig, 9 TUI files, terminal.zig) |
| Risk level | Low → Medium | ✅ No issues encountered |
| Phases | 4 | ✅ All 4 completed |

### Commits

1. `a5815c1` — `refactor(config): extract buildBaseToolSet + finalizeToolSet helpers`
2. `bca4bb4` — `refactor(modes): remove interactive mode entirely (-6320 lines)`
3. `37e87c6` — `refactor(rpc): consolidate tool building via buildBaseToolSet + finalizeToolSet`
4. `ae26ca3` — `refactor(proxy): consolidate tool building via buildBaseToolSet + finalizeToolSet`

The refactoring achieved **~8.6% codebase reduction** by removing the
untested, highest-complexity mode and consolidating the remaining tool
management into a single source of truth. A latent bug was also fixed
in rpc.zig (per-prompt finishTask append growing session.tools every
turn — now added once at init via finalizeToolSet).