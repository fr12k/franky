# Design & Implementation Plan: Expose Session Metadata to the Bash Tool

> Franky port of [earendil-works/pi#6967](https://github.com/earendil-works/pi/pull/6967)
> "feat(coding-agent): expose session metadata to bash tools"

## 1. Goal

Let commands run by the LLM-callable `bash` tool (and factory-created bash
variants) see the active session's metadata as environment variables, so
subprocesses and helper scripts can identify the session, its on-disk file,
the selected provider/model, and the reasoning level without the agent
having to thread that information manually.

| Variable | Source | Unset when |
|---|---|---|
| `FRANKY_SESSION_ID` | `SessionState.session_id` / synthesized rpc id | never (always set when exposure enabled) |
| `FRANKY_SESSION_FILE` | `<parent_dir>/<session_id>/transcript.json` absolute path | ephemeral / rpc sessions (no parent dir) |
| `FRANKY_PROVIDER` | `ProviderInfo.provider_name` / `ResolvedConfig.provider_name` | no model selected |
| `FRANKY_MODEL` | `ProviderInfo.model_id` / `ResolvedConfig.model_id` | no model selected |
| `FRANKY_REASONING_LEVEL` | `cfg.thinking` (`ai.types.ThinkingLevel`, `@tagName`) | `thinking == .off` |

Pi uses the `PI_*` prefix; franky uses `FRANKY_*` to match the existing
`FRANKY_BASH_SPILL_DIR` / `FRANKY_HOME` / `FRANKY_TRAILER` conventions
already in the tree.

Values are resolved immediately before each command starts, so a mid-session
model or reasoning-level change is reflected on the *next* bash call without
restarting. Inherited `FRANKY_SESSION_*` / `FRANKY_PROVIDER` / `FRANKY_MODEL`
/ `FRANKY_REASONING_LEVEL` values are cleared first so a nested franky
process cannot inherit stale parent-session metadata.

Injection is opt-out: factory-created bash tools expose the session
environment by default; `expose_session_environment: false` disables it and
*also* scrubs inherited values (mirrors pi's `exposeSessionEnvironment`).

This mirrors pi's behavior but adapts to franky's architecture:

- **No `ExtensionContext` / per-tool `promptGuidelines`** — franky tools get
  their guidance only through `AgentTool.description`. The hint is appended
  to the bash tool description string instead.
- **No `wrapToolDefinition` / nested-context-forwarding fix** — franky's
  `AgentTool.execute` is a plain function pointer with an opaque `ctx`
  field; there is no wrapper layer to fix. The session metadata is carried
  on the same `SessionBashState`/`BashCtx` struct that already backs the
  tool, so it flows through naturally.
- **Two execute paths** — franky has `execute` (simple, inherits parent env
  verbatim) and `executeWithCtx` (§R path, already builds a filtered
  `Environ.Map` from the workspace env-denylist). Both must inject.

## 2. Architecture mapping (pi → franky)

| pi concept | franky equivalent |
|---|---|
| `ExtensionContext` (sessionManager, model, thinkingLevel) | `SessionBashState` session-metadata fields + `BashCtx` |
| `ctx.sessionManager.getSessionId()` | `state.session_id` (new field) |
| `ctx.sessionManager.getSessionFile()` | `state.session_file` (new field, absolute transcript.json path) |
| `ctx.model.provider` / `ctx.model.id` | `state.provider` / `state.model` (new fields) |
| `ctx.thinkingLevel` | `state.thinking_level` (new field, `?ai.types.ThinkingLevel`) |
| `resolveSpawnContext(..., ctx)` env block | new `injectSessionEnv()` helper called in both `execute` and `executeWithCtx` |
| `exposeSessionEnvironment` option on `createBashTool` | `expose_session_environment: bool` field on `SessionBashState` (default `true`) |
| `wrapToolDefinition` context-forwarding fix | **N/A** — franky has no wrapper; ctx is the struct pointer directly |
| `promptGuidelines` / system-prompt snippet | append one line to the bash tool `description` string |
| `PI_CODING_AGENT=true` process marker | **out of scope** — separate follow-up; franky has no equivalent today |

## 3. Data model

### 3.1 Extend `SessionBashState`

`src/coding/tools/bash.zig` — `SessionBashState` (currently `cwd_buf`,
`default_timeout_ms_override`, `session_dir_buf`).

Add fields:

```zig
pub const SessionBashState = struct {
    allocator: std.mem.Allocator,
    cwd_buf: std.ArrayList(u8) = .empty,
    default_timeout_ms_override: ?u64 = null,
    session_dir_buf: std.ArrayList(u8) = .empty,

    /// v0.30.0 — session metadata injected into the child env of bash
    /// commands as FRANKY_SESSION_ID / FRANKY_SESSION_FILE / FRANKY_PROVIDER
    /// / FRANKY_MODEL / FRANKY_REASONING_LEVEL. Owned by the state; cleared
    /// by `clearSessionMetadata()` before each `setSessionMetadata()` call.
    /// `expose_session_environment = false` scrubs inherited values too.
    session_id_buf: std.ArrayList(u8) = .empty,
    session_file_buf: std.ArrayList(u8) = .empty,
    provider_buf: std.ArrayList(u8) = .empty,
    model_buf: std.ArrayList(u8) = .empty,
    thinking_level: ?ai.types.ThinkingLevel = null,
    expose_session_environment: bool = true,
    has_session_metadata: bool = false, // any of the bufs non-empty

    // ... existing methods ...
};
```

Add methods mirroring `setSessionDir`:

```zig
/// Record the session identity + model state for env injection.
/// `session_file` may be null (ephemeral / rpc). `provider`/`model` may
/// be null when no model is selected. `thinking` is stored as-is; `.off`
/// means FRANKY_REASONING_LEVEL is omitted.
pub fn setSessionMetadata(
    self: *SessionBashState,
    session_id: []const u8,
    session_file: ?[]const u8,
    provider: ?[]const u8,
    model: ?[]const u8,
    thinking: ai.types.ThinkingLevel,
) !void { ... }

pub fn clearSessionMetadata(self: *SessionBashState) void { ... }
```

`deinit()` must free the three new bufs.

### 3.2 Why `SessionBashState` and not `BashCtx`

Both execute paths already recover a `?*SessionBashState`:

- `execute` (bash.zig:343): `const state: ?*SessionBashState = if (self.ctx) |c| @ptrCast(@alignCast(c)) else null;`
- `executeWithCtx` (bash.zig:472): `const bash_ctx: ?*BashCtx = ...; const state: ?*SessionBashState = if (bash_ctx) |bc| bc.state else null;`

So putting the metadata on `SessionBashState` covers **all four mode wiring
sites** (print/proxy/rpc use `toolWithState` or `toolWithStateAndWorkspace`,
both of which reach `state`), with one helper. `BashCtx` only adds a
`workspace` pointer; it does not need the metadata.

### 3.3 `FRANKY_SESSION_FILE` path construction

Pi exposes the session JSONL path. Franky's on-disk layout is
`<parent_dir>/<session_id>/transcript.json` (see `session/mod.zig:66` and
`persistence.zig` — the directory holds `session.json` + `transcript.json`).
The mode driver that already computes the session dir for
`setSessionDir` will compute the absolute `transcript.json` path and pass it
to `setSessionMetadata`. Ephemeral/rpc sessions pass `null` → variable is
unset (matches pi's "unset for ephemeral sessions").

## 4. Env injection

### 4.1 The five variable names

```zig
const SESSION_ENV_VARS = [_][]const u8{
    "FRANKY_SESSION_ID",
    "FRANKY_SESSION_FILE",
    "FRANKY_PROVIDER",
    "FRANKY_MODEL",
    "FRANKY_REASONING_LEVEL",
};
```

### 4.2 `injectSessionEnv` helper

```zig
/// Mutates `env` in place: scrubs any inherited SESSION_ENV_VARS, then, if
/// `state` is non-null and `state.expose_session_environment`, sets the
/// variables from `state`'s metadata bufs. `FRANKY_SESSION_FILE` and
/// `FRANKY_PROVIDER`/`FRANKY_MODEL` are only set when non-empty;
/// `FRANKY_REASONING_LEVEL` is omitted when `thinking_level == .off`.
/// Returns the map so the caller can pass it to `.environ_map`.
fn injectSessionEnv(
    allocator: std.mem.Allocator,
    env: *std.process.Environ.Map,
    state: ?*const SessionBashState,
) !void {
    // 1. Always scrub inherited values (stale-metadata guard).
    for (SESSION_ENV_VARS) |name| _ = env.remove(name);
    if (state) |s| if (s.expose_session_environment and s.has_session_metadata) {
        if (s.session_id_buf.items.len > 0)
            try env.put("FRANKY_SESSION_ID", s.session_id_buf.items);
        if (s.session_file_buf.items.len > 0)
            try env.put("FRANKY_SESSION_FILE", s.session_file_buf.items);
        if (s.provider_buf.items.len > 0)
            try env.put("FRANKY_PROVIDER", s.provider_buf.items);
        if (s.model_buf.items.len > 0)
            try env.put("FRANKY_MODEL", s.model_buf.items);
        if (s.thinking_level) |t| if (t != .off)
            try env.put("FRANKY_REASONING_LEVEL", t.toString());
    };
}
```

`Environ.Map.remove` and `.put` are the stdlib `std.process.Environ.Map`
API (already used by the env-denylist filter). When `expose_session_environment`
is false we still scrub — that matches pi's "When disabled, Pi removes
inherited values" semantics and prevents nested franky processes from
leaking the parent session.

### 4.3 `execute` path (simple — currently inherits parent env verbatim)

Today (bash.zig:421-440) `std.process.run` is called with no
`.environ_map` → parent env inherited. Change to:

```zig
// Build a child env: copy parent, inject/scrub session metadata.
var parent_env = try std.process.getEnvMap(allocator);
defer parent_env.deinit();
try injectSessionEnv(allocator, &parent_env, state);

const result = std.process.run(allocator, io, .{
    .argv = &argv,
    .cwd = ...,
    .stdout_limit = ...,
    .stderr_limit = ...,
    .timeout = timeout,
    .environ_map = &parent_env,
}) catch |err| switch (err) { ... };
```

`state` is already recovered at the top of `execute` (bash.zig:354). When
`state` is null (the `tool()` factory with no ctx) `injectSessionEnv` still
scrubs inherited `FRANKY_SESSION_*` values, which is the safe default.

`runBackground` (bash.zig:207-213) needs the same treatment for
consistency — it currently inherits the parent env verbatim too.

### 4.4 `executeWithCtx` path (§R — already builds `filtered_env`)

Today (bash.zig:558-584):

```zig
var filtered_env: ?std.process.Environ.Map = if (workspace) |ws|
    try workspace_mod.filteredEnv(allocator, ws)
else
    null;
defer if (filtered_env) |*m| m.deinit();
...
.environ_map = if (filtered_env) |*m| m else null,
```

Change to always have a mutable map so we can inject:

```zig
var filtered_env: std.process.Environ.Map = if (workspace) |ws|
    try workspace_mod.filteredEnv(allocator, ws)
else
    try std.process.getEnvMap(allocator);
defer filtered_env.deinit();
try injectSessionEnv(allocator, &filtered_env, state);
...
.environ_map = &filtered_env,
```

`state` is already recovered at bash.zig:478. This means the no-workspace
branch now also gets a filtered env (it used to inherit verbatim) — but the
only difference is the five `FRANKY_*` scrubs/injections, which is exactly
the behavior we want.

## 5. Wiring the metadata at each mode

The metadata is set on the same `SessionBashState` instance that
`setSessionDir` is called on, immediately after it, at each mode's existing
wiring site. All four modes already have `provider`, `model`, `thinking`
in scope there (see the research table below).

### 5.1 print mode — `src/coding/modes/print.zig:294-297`

```zig
if (session_state.parent_dir) |parent| {
    session_dir_path = std.fs.path.join(allocator, &.{ parent, session_state.id() }) catch null;
    if (session_dir_path) |sd| {
        resolved.bash_state.setSessionDir(sd) catch {};
+       const tfile = try std.fs.path.join(allocator, &.{ sd, "transcript.json" });
+       defer allocator.free(tfile);
+       resolved.bash_state.setSessionMetadata(
+           session_state.id(), tfile,
+           resolved.provider_name, resolved.model_id,
+           cfg.thinking,
+       ) catch {};
    }
}
```

For the no-`parent_dir` (ephemeral) branch, still call `setSessionMetadata`
with `session_file = null` so `FRANKY_SESSION_ID`/`PROVIDER`/`MODEL` are
exposed.

### 5.2 proxy mode — `src/coding/modes/proxy.zig:741-744`

```zig
if (session.parent_dir) |parent| {
    if (std.fs.path.join(allocator, &.{ parent, session.session_id })) |sd| {
        defer allocator.free(sd);
        session.bash_state.setSessionDir(sd) catch {};
+       const tfile = try std.fs.path.join(allocator, &.{ sd, "transcript.json" });
+       defer allocator.free(tfile);
+       session.bash_state.setSessionMetadata(
+           session.session_id, tfile,
+           session.provider.provider_name, session.provider.model_id,
+           session.cfg.thinking,
+       ) catch {};
    }
} else {
+   session.bash_state.setSessionMetadata(
+       session.session_id, null,
+       session.provider.provider_name, session.provider.model_id,
+       session.cfg.thinking,
+   ) catch {};
}
```

### 5.3 rpc mode — `src/coding/modes/rpc.zig:290-295`

rpc has no persistent `session_id` — it synthesizes `rpc-<startup_ms>`.
Expose that as `FRANKY_SESSION_ID`, `null` session file:

```zig
const sd = try std.fs.path.join(allocator, &.{ hr, rpc_id });
defer allocator.free(sd);
session.bash_state.setSessionDir(sd) catch {};
+session.bash_state.setSessionMetadata(
+    rpc_id, null,
+    session.provider.provider_name, session.provider.model_id,
+    session.cfg.thinking,
+) catch {};
```

### 5.4 interactive mode — `src/coding/modes/interactive.zig`

Interactive mode **does not call `setSessionDir` today** and has no
`session_id`/`parent_dir` on `SessionBinding`. Two sub-changes:

1. **Thread session identity into `SessionBinding`.** `SessionBinding`
   (interactive.zig:1694-1745) needs `session_id: ?[]const u8 = null` and
   `parent_dir: ?[]const u8 = null` fields, set where the binding is
   initialized (the same place `provider` is resolved, ~interactive.zig:1927).
   When a session is resumed/branched, update these. (If interactive mode
   truly never persists, leave both null → only `FRANKY_PROVIDER`/`MODEL`/
   `REASONING_LEVEL` are set; this is still a win and matches pi's
   "ephemeral → FRANKY_SESSION_FILE unset" semantics.)

2. **Call `setSessionMetadata` in the tool-array builder** right before
   `all_tools` is constructed (interactive.zig:1830):

   ```zig
   +binding.bash_state.setSessionMetadata(
   +    binding.session_id orelse "", binding.session_file,
   +    binding.provider.provider_name, binding.provider.model_id,
   +    binding.cfg.thinking,
   +) catch {};
    const all_tools: [9]at.AgentTool = if (binding.workspace) |*ws| .{
       ...
       tools_mod.bash.toolWithStateAndWorkspace(&binding.bash_ctx),
       ...
   ```
   
   Use `""` (empty) for session_id when absent so `FRANKY_SESSION_ID` is
   omitted rather than empty.

### 5.5 Availability matrix (from research)

| Mode | session_id | session_file (transcript.json) | provider | model | thinking |
|------|-----------|-------------------------------|----------|-------|----------|
| print | `session_state.id()` | `<parent>/<id>/transcript.json` | `resolved.provider_name` | `resolved.model_id` | `cfg.thinking` |
| proxy | `session.session_id` | `<parent>/<id>/transcript.json` | `session.provider.provider_name` | `session.provider.model_id` | `session.cfg.thinking` |
| rpc | `rpc-<ms>` (synthetic) | `null` | `session.provider.provider_name` | `session.provider.model_id` | `session.cfg.thinking` |
| interactive | `binding.session_id` (new) | `binding.session_file` (new) | `binding.provider.provider_name` | `binding.provider.model_id` | `binding.cfg.thinking` |

All are `[]const u8` except `thinking` which is `ai.types.ThinkingLevel`
(enum: `off, minimal, low, medium, high, xhigh`; `.toString()` returns
`@tagName`).

## 6. System-prompt / tool-description hint

Franky has **no per-tool `promptGuidelines` mechanism** (confirmed: zero
matches for `promptGuidelines`/`promptSnippet` across `src/`). Tool guidance
reaches the LLM only through `AgentTool.description`, which is copied into
the API tool schema by `cloneTools()` (loop.zig:2072-2091).

Append one sentence to the bash tool `description` in all three factory
functions (`tool`, `toolWithState`, `toolWithStateAndWorkspace`) — gated on
`expose_session_environment`:

> "Commands also receive `FRANKY_SESSION_ID`, `FRANKY_SESSION_FILE`,
> `FRANKY_PROVIDER`, `FRANKY_MODEL`, and `FRANKY_REASONING_LEVEL` describing
> the current session; inspect those instead of inferring the model from the
> system prompt."

Because `AgentTool` is a static struct built once at wiring time, the
description is fixed for the session — which is fine since the *values* are
re-resolved per command (the variables are populated at spawn time, not at
description time). When `expose_session_environment = false`, omit the
sentence.

A follow-up can add a `docs/environment-variables.md` page mirroring pi's,
linked from `README.md` and `docs/index.md`. Not required for the code
change.

## 7. Opt-out (`expose_session_environment`)

`SessionBashState.expose_session_environment` defaults to `true`. There is
no `createBashTool` factory in franky (tools are built via
`tool*` functions), so the opt-out is set on the state struct before wiring:

```zig
bash_state.expose_session_environment = false;
```

The existing `tool-execution-component`-style tests (in `test/`) that pass
mock operations should set this to `false` to keep the env deterministic —
mirrors pi's `tool-execution-component.test.ts` change
(`exposeSessionEnvironment: false` on the test-only bash tool).

## 8. Tests

Mirror pi's two test additions, adapted to franky's Zig test style
(`test "..."` blocks, the `test_h.threadedIo()` pattern already in
`bash.zig`):

1. **`bash.zig` unit test — "session env injected"**: build a
   `SessionBashState`, call `setSessionMetadata("s1", "/tmp/s1/transcript.json",
   "anthropic", "claude-sonnet-4-5", .high)`, run `bash` with `command =
   "printf '%s\\n' $FRANKY_SESSION_ID $FRANKY_SESSION_FILE $FRANKY_PROVIDER
   $FRANKY_MODEL $FRANKY_REASONING_LEVEL"`, assert the five lines.

2. **`bash.zig` unit test — "opt-out scrubs inherited"**: set
   `expose_session_environment = false`, pre-seed the parent env with
   `FRANKY_SESSION_ID=stale` (via `std.process.getEnvMap` + `put` in the
   test harness), run a command, assert the output does **not** contain
   `stale` and the vars are absent.

3. **`bash.zig` unit test — "thinking off omits FRANKY_REASONING_LEVEL"**:
   `setSessionMetadata(..., .off)`, assert `FRANKY_REASONING_LEVEL` is unset.

4. **`bash.zig` unit test — "ephemeral session omits FRANKY_SESSION_FILE"**:
   `session_file = null`, assert the var is absent.

5. **Mode-level test (optional, heavier)**: in `test/`, an integration test
   that runs `print` mode against a temp session dir and asserts the bash
   output contains the session id + transcript path — mirrors pi's
   `sdk-session-manager.test.ts` "exposes current session state to the
   built-in bash tool".

## 9. Implementation order (small, reviewable commits)

1. **`SessionBashState` metadata fields + `setSessionMetadata`/
   `clearSessionMetadata` + `deinit` bufs.** (bash.zig only)
2. **`injectSessionEnv` helper + `SESSION_ENV_VARS`.** (bash.zig only)
3. **Wire `execute`, `executeWithCtx`, `runBackground` to build a child env
   and call `injectSessionEnv`.** (bash.zig only) — this is the behavioral
   core; with no metadata set it only scrubs inherited values (safe).
4. **Append the description hint** to the three `tool*` factories, gated on
   `expose_session_environment`. (bash.zig only)
5. **Wire `setSessionMetadata` in print, proxy, rpc modes** at the existing
   `setSessionDir` call sites. (3 small edits)
6. **Interactive mode**: add `session_id`/`session_file` to `SessionBinding`,
   call `setSessionMetadata` before the tool array. (interactive.zig)
7. **Tests** (step 8) + a `CHANGELOG`-style note in `README.md` env-var
   table.
8. **`docs/environment-variables.md`** (new page, linked from README +
   docs/index) — documentation-only, can land separately.

Each step compiles and passes existing tests independently; step 3 is the
first one with user-visible behavior.

## 10. Out of scope / follow-ups

- **`FRANKY_CODING_AGENT=true` process marker** (pi's `PI_CODING_AGENT`).
  Franky has no equivalent today; adding it touches the CLI/RPC entry
  points and is a separate change.
- **`AgentHarness` bash tool** — pi's PR notes it does not yet address the
  harness bash tool. Franky's `subagent` tool spawns a nested agent; the
  nested agent's bash tool will inherit the *scrubbed* env (good) and set
  its own metadata from the nested session (good) once the nested session
  wires `setSessionMetadata`. No extra work needed beyond ensuring the
  subagent path goes through a mode driver (it does).
- **Per-tool `promptGuidelines` infrastructure** — not needed for this
  feature; the `description` append is sufficient. If franky later grows a
  prompt-guidelines layer, the hint can move there.

## 11. Risks / notes

- **`std.process.getEnvMap` cost**: the `execute` path currently avoids
  building an env map (inherits verbatim). After the change it allocates a
  full env copy per bash call. This is the same cost `executeWithCtx`
  already pays when a workspace is present, and bash calls are
  I/O-bound, not env-copy-bound. Acceptable.
- **`Environ.Map` API**: confirm `std.process.Environ.Map` exposes
  `.remove`, `.put`, `.getEnvMap` on the franky Zig version
  (`0.17.0-dev`). The env-denylist (`security/env_denylist.zig`) already
  uses the same API, so it is available.
- **String ownership**: the new bufs on `SessionBashState` are owned and
  freed in `deinit`. The mode drivers pass `[]const u8` slices that are
  themselves arena/allocator-owned for the session lifetime, so a
  `dupe`-into-buf in `setSessionMetadata` (like `setSessionDir` already
  does) is the safe pattern.
- **Interactive mode session identity**: if threading `session_id` into
  `SessionBinding` turns out to be invasive, the safe fallback (step 6)
  is to expose only `FRANKY_PROVIDER`/`MODEL`/`REASONING_LEVEL` in
  interactive mode and leave the session-id/file unset. This still matches
  pi's "unset for ephemeral sessions" semantics and is a strict
  improvement.