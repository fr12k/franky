# Refactoring Plan — Tool Management Consolidation

**Goal:** Eliminate redundant tool-management code across the four run modes
(`print`, `interactive`, `proxy`, `rpc`) by routing all modes through the
existing `config.resolve()` pipeline (or a shared helper extracted from it).
**Primary outcome:** less code in total.

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

**Only `print.zig` (line 220) calls `config.resolve()`.** The other three
modes — `rpc.zig`, `proxy.zig`, `interactive.zig` — each re-implement the
same pipeline independently, resulting in ~300 lines of duplicated
tool-construction logic spread across 3 files.

### 1.1 Where the duplication lives

| Block | `config.zig` (canonical) | `rpc.zig` | `proxy.zig` | `interactive.zig` |
|---|---|---|---|---|
| Base-9 tool array | 1055–1114 | 176–186 | 634–644 | 1887–1907 |
| Role filtering | 1116–1124 | 187 | 645 | 1913–1914 |
| Extension merge | 1156–1162, 1244–1254 | ❌ missing | 843–847, 878–882 | 281–330 (two-phase) |
| Preset registry + subagent ctx | 1224–1243 | 386–417 | 830–877 | 2068–2093 |
| Final tool append | 1244–1265 | 418–424 | 878–889 | 2096–2107 |
| Memory tools | 1260–1262 | ❌ missing | ❌ missing | 2103–2105 |
| Settings overlay | internal to resolve | 196+ | 651–660 | 1846 |
| finishTask tool | 1257 | 696–701 (per-prompt) | 886 | 2100 |

### 1.2 What each mode duplicates vs. what it uniquely needs

| Aspect | rpc | proxy | interactive |
|---|---|---|---|
| Same base-9 tools | ✅ identical set | ✅ identical set | ✅ identical set |
| Workspace variants | ❌ always plain | ❌ always plain | ✅ full if/else |
| Role filtering | ✅ same `filterTools` | ✅ same | ✅ same |
| Extensions | ❌ not loaded | ✅ loaded | ✅ loaded (2-phase) |
| `subagent` tool | ✅ | ✅ | ✅ |
| `listPresets` tool | ✅ | ✅ | ✅ |
| `finishTask` tool | ✅ (per-prompt, 696) | ✅ | ✅ |
| `ccr_retrieve` tool | ✅ | ✅ | ✅ |
| `memory_search/save` | ❌ **missing** | ❌ **missing** | ✅ |
| **Unique need** | `progress_fn` for JSON-RPC event forwarding; per-prompt `finishTask` append | per-prompt `prompter` slot in subagent ctx | per-turn re-bind of tools; memory tools |

**Key finding (minimax-m3):** rpc and proxy are **missing features** that
`config.resolve()` provides (extensions in rpc; memory tools in rpc+proxy).
This is not just cosmetic duplication — it's a latent feature gap.

---

## 2. Root Cause: The "Stable Address" Problem

The fundamental blocker preventing the other 3 modes from calling
`config.resolve()` is **pointer stability**. `config.resolve()` allocates
tools on its own arena and wires ctx pointers to its own internal state
(`bash_ctx`, `read_ctx`, `web_search_ctx`, `subagent_ctx`). But rpc/proxy/
interactive need tool ctx pointers to reference **session-owned state**
(`session.bash_state`, `session.ccr_ctx`, `session.permission_store`),
which is initialized *after* config resolution would run.

Additionally:
- **rpc** needs a `progress_fn` (`subagentProgressForward`) in its
  subagent ctx for JSON-RPC event forwarding.
- **proxy** needs a `permission_prompter_slot` pointing at
  `session.current_prompter` (set per-prompt).
- **interactive** re-binds tools every turn to ensure the current prompter
  is injected; it also wires memory tools (which config.resolve does too).

These are **late-binding** concerns, not fundamental architectural
incompatibilities.

---

## 3. Proposed Structure: Two-Phase Tool Builder

Extract the tool pipeline from `config.resolve()` into reusable pieces
that all 4 modes can call, with late-binding hooks for the mode-specific
parts.

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
- **Replaces:** rpc.zig 176–187, proxy.zig 634–645, interactive.zig 1887–1914,
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
- **Replaces:** rpc.zig 418–424, proxy.zig 878–889, interactive.zig 2096–2107,
  config.zig 1244–1265.

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

## 4. Estimated Line Reduction

| File | Current LOC | Lines removed | Lines added (calls) | Net |
|---|---|---|---|---|
| `config.zig` | 1409 | ~70 (extracted to helpers) | ~90 (new `buildBaseToolSet` + `finalizeToolSet` + `ToolBindingCtx`) | +20 |
| `print.zig` | 3097 | ~10 (use helpers internally) | ~5 | −5 |
| `rpc.zig` | 954 | ~120 (base tools 176–186, filter 187, settings 196+, subagent 386–417, final 418–424, per-prompt finishTask 696–701) | ~25 | −95 |
| `proxy.zig` | 5712 | ~110 (base 634–644, filter 645, subagent 830–877, final 878–889) | ~25 | −85 |
| `interactive.zig` | 3559 | ~100 (base 1887–1907, filter, subagent 2068–2093, final 2096–2107, ext merge 313–327) | ~25 | −75 |
| **Total** | 14731 | **~410** | **~150** | **−260** |

**Conservative estimate: ~250 lines net reduction.**
**Optimistic estimate (if memory/extension gaps in rpc/proxy are treated as
"just call resolve" rather than feature additions): ~300+ lines.**

Additional benefit: rpc and proxy **gain** extension + memory tool support
they're currently missing — a feature win, not just code reduction.

---

## 5. Risk + Effort Assessment (per mode)

### rpc.zig — Difficulty: Medium

| Risk | Severity | Mitigation |
|---|---|---|
| `progress_fn` in subagent ctx (JSON-RPC event forwarding) | Medium | Add `progress_fn` + `progress_userdata` fields to `ToolBindingCtx` / subagent ctx factory |
| Per-prompt `finishTask` append (696–701) | Low | Move into `finalizeToolSet` (called once at session init, not per-prompt — check if per-prompt is truly needed) |
| No workspace variant (always plain) | Low | `buildBaseToolSet` handles both; rpc passes `null` workspace |
| Missing extensions | Low (feature gap) | Fixing this adds extensions to rpc — verify no test breaks |
| Missing memory tools | Low (feature gap) | Same as above |

### proxy.zig — Difficulty: Medium

| Risk | Severity | Mitigation |
|---|---|---|
| Per-prompt `current_prompter` slot in subagent ctx | Medium | Subagent ctx is built once at session init; `permission_prompter_slot` is a `?*Prompter` pointer field that's updated per-prompt — already works via pointer-to-slot |
| Missing memory tools | Low (feature gap) | Adding them is a feature improvement |
| Session-owned `bash_state` / `web_search_ctx` | Low | Build base tools with `null` ctx, then patch ctx pointers post-session-init (same as print's ccr patching at 271–276) |

### interactive.zig — Difficulty: High

| Risk | Severity | Mitigation |
|---|---|---|
| Per-turn tool re-binding | High | This is the hardest — interactive rebuilds `final_tools` every turn (2096–2107). If `finalizeToolSet` is called once at session init, the per-turn rebind must be preserved. **Solution:** call `finalizeToolSet` once; per-turn changes only affect `subagent_ctx` fields (prompter slot), not the tool array itself. Verify the tool array is stable across turns. |
| Two-phase extension merge (281–330) | Medium | Extensions loaded outside `SessionBinding.init`, then appended. Consolidate into `buildBaseToolSet` + `finalizeToolSet` flow. |
| Memory state init duplicated (1984–2015 ≈ config 1190–1221) | Medium | Extract memory init into a shared helper too (bonus deduplication) |

---

## 6. Recommended Refactoring Order

Based on risk levels (lowest first):

### Phase 1 — Extract helpers from `config.zig` (Low risk, no behavior change)
1. Extract `buildBaseToolSet()` from config.zig 1055–1124.
2. Extract `finalizeToolSet()` + `ToolBindingCtx` from config.zig 1244–1265.
3. Have `config.resolve()` internally call these helpers.
4. **Validate:** all 881 tests pass, print mode unchanged.

### Phase 2 — Consolidate `rpc.zig` (Medium risk, feature gain)
1. Replace rpc.zig 176–187 with `buildBaseToolSet()`.
2. Replace rpc.zig 418–424 with `finalizeToolSet()`.
3. Add `progress_fn` hook to `ToolBindingCtx` for JSON-RPC forwarding.
4. Decide: keep per-prompt `finishTask` (696–701) or move to init-time.
5. **Bonus:** rpc gains extension support + memory tools (if desired).
6. **Validate:** run rpc mode tests.

### Phase 3 — Consolidate `proxy.zig` (Medium risk, feature gain)
1. Replace proxy.zig 634–645 with `buildBaseToolSet()`.
2. Replace proxy.zig 878–889 with `finalizeToolSet()`.
3. Verify `permission_prompter_slot` pointer stability (already pointer-to-slot).
4. **Bonus:** proxy gains memory tool support.
5. **Validate:** run proxy mode tests + manual web UI smoke test.

### Phase 4 — Consolidate `interactive.zig` (High risk, preserve per-turn semantics)
1. Replace interactive.zig 1887–1914 with `buildBaseToolSet()`.
2. Replace interactive.zig 2096–2107 with `finalizeToolSet()`.
3. Verify the tool array is stable across turns (subagent ctx fields are
   updated per-turn via pointer, not the array itself).
4. Consolidate the two-phase extension merge (281–330) into the standard flow.
5. **Bonus:** extract shared memory-init helper (1984–2015 ≈ config 1190–1221).
6. **Validate:** run interactive mode tests + manual TUI smoke test.

---

## 7. Validation Strategy

The repo has ~881 tests. Relevant test coverage:

```bash
# Find mode-specific tests
grep -rln 'test "' src/coding/modes/
grep -rn 'test "' src/coding/modes/rpc.zig      # rpc tests
grep -rn 'test "' src/coding/modes/proxy.zig    # proxy tests
grep -rn 'test "' src/coding/modes/interactive.zig # interactive tests
grep -rn 'test "' src/coding/config.zig        # config resolver tests
```

**Per-phase validation:**
1. After Phase 1: `zig build test` — all 881 tests must pass (no behavior change).
2. After Phase 2: `zig build test` + manual rpc smoke test (`echo '{"method":"ping"}' | franky --mode rpc`).
3. After Phase 3: `zig build test` + manual proxy smoke test (`franky --mode proxy` + curl).
4. After Phase 4: `zig build test` + manual interactive smoke test (`franky --mode interactive` + type a prompt).

**Regression watch:** the `ccr_retrieve` ctx late-binding (config.zig 1259,
print.zig 271–276) must be preserved in all modes — tools with `null` ctx
get patched after session init. Verify each mode does this.

---

## 8. Summary

| Metric | Value |
|---|---|
| Duplicated tool-building lines across 3 modes | ~410 |
| New helper code in config.zig | ~150 |
| **Net line reduction** | **~260 lines** |
| Modes consolidated | 4 of 4 (print already done) |
| Feature gaps fixed (bonus) | rpc: extensions, memory; proxy: memory |
| Risk level | Medium (rpc, proxy) / High (interactive) |
| Phases | 4 (extract → rpc → proxy → interactive) |

The refactoring achieves the goal of **less code in total** while also
**closing feature gaps** (rpc/proxy missing extensions/memory tools) and
**establishing a single source of truth** for tool management.