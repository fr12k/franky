//! bash tool — §C.4 of the spec.
//!
//! Schema: `{command, cwd?, timeoutMs?, description?}`.
//!
//! Invokes the command through `/bin/sh -c <wrapped>`. The wrapper
//! appends a one-line printf trailer so we can recover `$PWD` after
//! the command finishes — `cd subdir && pwd` updates the session's
//! working directory so the *next* `bash` call lands in `subdir`.
//!
//! Behaviors delivered in this milestone (v0.4.0):
//!   - **Cwd trailer** parsed out of stdout; `SessionBashState.cwd`
//!     is updated on successful invocations; subsequent calls
//!     inherit the new cwd automatically when the caller instantiates
//!     the tool via `toolWithState(&state)`.
//!   - Existing 1 MiB/stream output cap; exit-code / signal reporting;
//!     timeout escalation — all unchanged.
//!
//! Deferred (see the port log for v0.4.0):
//!   - Incremental stdout/stderr streaming via `on_update` — needs a
//!     `Child.spawn` + pipe-reader rewrite; not a schema change.
//!   - `background: true` + session-scoped process tracking.
//!   - `$SHELL`-trust enforcement with `bash_shell_untrusted` refusal
//!     — lands in v0.4.2 alongside the env denylist.

const std = @import("std");
const ct = @import("../types.zig");
const at = ct.agent.types;
const ai = ct.ai;
const workspace_mod = @import("workspace.zig");
const common = @import("common.zig");
const truncate_mod = @import("truncate.zig");

pub const parameters_json: []const u8 =
    \\{
    \\  "type": "object",
    \\  "required": ["command"],
    \\  "properties": {
    \\    "command": {"type": "string", "description": "The shell command to run (parsed by /bin/sh -c)."},
    \\    "cwd": {"type": "string", "description": "Working directory for the command. Defaults to the session cwd (if any) else the agent's cwd."},
    \\    "timeoutMs": {"type": "integer", "minimum": 1, "description": "Hard timeout in milliseconds (default 120000)."},
    \\    "background": {"type": "boolean", "description": "Run detached; returns immediately with {pid, outputFile}. Default false."},
    \\    "resetCwd": {"type": "boolean", "description": "Clear the session-tracked cwd before resolving the working directory for this call (so it falls back to the agent's startup cwd unless an explicit `cwd` arg is given). Use this if a prior command's `cd` left the session in an unwanted directory. Default false."},
    \\    "description": {"type": "string", "description": "Short human-readable description of what the command does."}
    \\  },
    \\  "additionalProperties": false
    \\}
;

pub const default_timeout_ms: u64 = 120_000;
/// v1.27.0 — bumped from 1 MiB to 8 MiB to give the spill-to-disk
/// path more headroom before `std.process.run` bails with
/// `error.StreamTooLong`. The in-memory cap is the absolute hard
/// limit — outputs over 8 MiB will still surface as
/// `bash_output_too_large`. Outputs in the 50 KB → 8 MiB range now
/// trigger truncation + on-disk spill instead.
pub const max_output_bytes: usize = 8 * 1024 * 1024;
/// v1.7.4 — chunk size for incremental `on_update` emission when
/// captured output exceeds this. Matches §C.4's "64 KB chunks".
pub const chunk_bytes: usize = 64 * 1024;
/// v1.27.0 — directory for the `truncated → on-disk spill` files.
/// Each spill file is named `franky-bash-<call_id>.log` and contains
/// the full pre-truncation `[stdout]…[stderr]…` formatted output.
/// `/tmp` matches pi-mono's convention and avoids tying spill files
/// to the session lifecycle (so they're inspectable after process
/// exit). Override via env var `FRANKY_BASH_SPILL_DIR` if needed.
pub const spill_dir_default: []const u8 = "/tmp";
/// Byte string appended to stdout by the wrapped command so `execute`
/// can recover the new cwd. Prefixed with `\n` to guarantee it lands
/// on its own line even when the user's command doesn't trailing-
/// newline its output. We use `lastIndexOf` at parse time so the
/// marker's accidental appearance in legitimate output does not trip
/// the parser.
pub const trailer_marker: []const u8 = "<<<FRANKY_TRAILER>>>cwd=";

// ─── shared session state ─────────────────────────────────────────

/// Per-session cwd bookkeeping. Instantiate once, pass to
/// `toolWithState`, and share the pointer across sessions in the same
/// agent lifetime. Thread-hostile — `execute` is sequential (tool's
/// `execution_mode = .sequential`) so we don't need a mutex.
pub const SessionBashState = struct {
    allocator: std.mem.Allocator,
    cwd_buf: std.ArrayList(u8) = .empty,
    /// v1.19.0 — settings-layer override for the per-call default
    /// timeout. Null = use module-level `default_timeout_ms`. The
    /// per-call `timeoutMs` arg always wins regardless.
    default_timeout_ms_override: ?u64 = null,
    /// v1.27.2 — directory under which bash output spill files
    /// land (`<session_dir>/bash/<call_id>.log`). Set by mode
    /// drivers after the session is materialized. Null falls back
    /// to `/tmp/franky-bash-<call_id>.log` so `--no-session`,
    /// rpc, and proxy bash invocations still get a spill path.
    session_dir_buf: std.ArrayList(u8) = .empty,

    // ─── session metadata for env injection (v0.30.0) ───────────
    /// The parent-process env map to clone for each bash command when no
    /// workspace filter applies (the `execute` path). Set by mode drivers
    /// alongside `setSessionMetadata`. Null → `execute` inherits the
    /// parent env verbatim (legacy behavior) and only scrubs the five
    /// `FRANKY_*` session vars.
    parent_env: ?*const std.process.Environ.Map = null,
    /// Owned copies of the session identity + model state. Empty buf →
    /// the corresponding `FRANKY_*` variable is omitted. `thinking_level`
    /// `.off` → `FRANKY_REASONING_LEVEL` is omitted.
    session_id_buf: std.ArrayList(u8) = .empty,
    session_file_buf: std.ArrayList(u8) = .empty,
    provider_buf: std.ArrayList(u8) = .empty,
    model_buf: std.ArrayList(u8) = .empty,
    thinking_level: ai.types.ThinkingLevel = .off,
    /// When true (default), the five `FRANKY_*` session vars are injected
    /// into the child env. When false, inherited values are still scrubbed
    /// so nested franky processes do not leak stale parent metadata.
    expose_session_environment: bool = true,
    has_session_metadata: bool = false,
    /// v0.30.0 — owns the session-env hint appended to the bash tool
    /// description when `expose_session_environment` is on, so `deinit`
    /// can free it. Empty when the hint is disabled.
    description_extra_buf: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) SessionBashState {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SessionBashState) void {
        self.cwd_buf.deinit(self.allocator);
        self.session_dir_buf.deinit(self.allocator);
        self.session_id_buf.deinit(self.allocator);
        self.session_file_buf.deinit(self.allocator);
        self.provider_buf.deinit(self.allocator);
        self.model_buf.deinit(self.allocator);
        self.description_extra_buf.deinit(self.allocator);
    }

    pub fn setCwd(self: *SessionBashState, dir: []const u8) !void {
        self.cwd_buf.clearRetainingCapacity();
        try self.cwd_buf.appendSlice(self.allocator, dir);
    }

    pub fn getCwd(self: *const SessionBashState) ?[]const u8 {
        if (self.cwd_buf.items.len == 0) return null;
        return self.cwd_buf.items;
    }

    /// v1.27.2 — record the session's on-disk directory so bash
    /// spills can land under it. Caller passes the materialized
    /// `<parent_dir>/<session_id>` path (the directory that holds
    /// `session.json` + `transcript.json`); `bash/` is added by
    /// the spill writer on demand.
    pub fn setSessionDir(self: *SessionBashState, dir: []const u8) !void {
        self.session_dir_buf.clearRetainingCapacity();
        try self.session_dir_buf.appendSlice(self.allocator, dir);
    }

    pub fn getSessionDir(self: *const SessionBashState) ?[]const u8 {
        if (self.session_dir_buf.items.len == 0) return null;
        return self.session_dir_buf.items;
    }

    pub fn defaultTimeoutMs(self: *const SessionBashState) u64 {
        return self.default_timeout_ms_override orelse default_timeout_ms;
    }

    /// v0.30.0 — record the session identity + selected model state so the
    /// bash tool can inject `FRANKY_SESSION_ID` / `FRANKY_SESSION_FILE` /
    /// `FRANKY_PROVIDER` / `FRANKY_MODEL` / `FRANKY_REASONING_LEVEL` into
    /// the child env of each command. `session_file` may be null (ephemeral
    /// / rpc sessions). `provider`/`model` may be null when no model is
    /// selected. `thinking` `.off` means `FRANKY_REASONING_LEVEL` is
    /// omitted. Replaces any previously-set metadata.
    pub fn setSessionMetadata(
        self: *SessionBashState,
        session_id: ?[]const u8,
        session_file: ?[]const u8,
        provider: ?[]const u8,
        model: ?[]const u8,
        thinking: ai.types.ThinkingLevel,
    ) !void {
        self.session_id_buf.clearRetainingCapacity();
        self.session_file_buf.clearRetainingCapacity();
        self.provider_buf.clearRetainingCapacity();
        self.model_buf.clearRetainingCapacity();
        if (session_id) |s| if (s.len > 0) try self.session_id_buf.appendSlice(self.allocator, s);
        if (session_file) |s| if (s.len > 0) try self.session_file_buf.appendSlice(self.allocator, s);
        if (provider) |s| if (s.len > 0) try self.provider_buf.appendSlice(self.allocator, s);
        if (model) |s| if (s.len > 0) try self.model_buf.appendSlice(self.allocator, s);
        self.thinking_level = thinking;
        self.has_session_metadata = self.session_id_buf.items.len > 0 or
            self.session_file_buf.items.len > 0 or
            self.provider_buf.items.len > 0 or
            self.model_buf.items.len > 0 or
            thinking != .off;
    }
};

/// v0.30.0 — the five `FRANKY_*` session-metadata env vars injected into
/// the child env of bash commands. Always scrubbed from the inherited env
/// first (so a nested franky process never leaks stale parent metadata);
/// re-added from `SessionBashState` when `expose_session_environment` is on.
const SESSION_ENV_VARS = [_][]const u8{
    "FRANKY_SESSION_ID",
    "FRANKY_SESSION_FILE",
    "FRANKY_PROVIDER",
    "FRANKY_MODEL",
    "FRANKY_REASONING_LEVEL",
};

/// v0.30.0 — scrub inherited `FRANKY_*` session vars, then, when exposure
/// is enabled and metadata is present, set them from `state`. Mutates
/// `env` in place. Used by both `execute` and `executeWithCtx`.
fn injectSessionEnv(
    env: *std.process.Environ.Map,
    state: ?*const SessionBashState,
) void {
    for (SESSION_ENV_VARS) |name| _ = env.swapRemove(name);
    const s = state orelse return;
    if (!s.expose_session_environment or !s.has_session_metadata) return;
    if (s.session_id_buf.items.len > 0)
        env.put("FRANKY_SESSION_ID", s.session_id_buf.items) catch {};
    if (s.session_file_buf.items.len > 0)
        env.put("FRANKY_SESSION_FILE", s.session_file_buf.items) catch {};
    if (s.provider_buf.items.len > 0)
        env.put("FRANKY_PROVIDER", s.provider_buf.items) catch {};
    if (s.model_buf.items.len > 0)
        env.put("FRANKY_MODEL", s.model_buf.items) catch {};
    if (s.thinking_level != .off)
        env.put("FRANKY_REASONING_LEVEL", s.thinking_level.toString()) catch {};
}

/// v0.30.0 — short hint appended to the bash tool description when session
/// env exposure is on, so the model knows to inspect `FRANKY_*` vars.
const session_env_hint = " Commands also receive FRANKY_SESSION_ID, FRANKY_SESSION_FILE, FRANKY_PROVIDER, FRANKY_MODEL, and FRANKY_REASONING_LEVEL describing the current session; inspect those instead of inferring the model from the system prompt.";

/// Resolves the effective per-call default timeout for both the
/// state-only and ctx-bearing execution paths. Used in places where
/// only `BashCtx` is in hand.
pub fn resolveDefaultTimeoutMs(state: ?*SessionBashState) u64 {
    if (state) |s| return s.defaultTimeoutMs();
    return default_timeout_ms;
}

pub fn tool() at.AgentTool {
    return .{
        .name = "bash",
        .description = "Run a shell command (via /bin/sh -c). Reports stdout/stderr + exit code; cwd persists across calls via SessionBashState when wired. Output truncates to last 2000 lines / 50 KB; full output spills to <session>/bash/<call_id>.log (or /tmp fallback). Pipe through `head`/`tail`/`grep` or redirect to a file rather than dumping unbounded output.",
        .parameters_json = parameters_json,
        .execution_mode = .sequential,
        .execute = execute,
    };
}

pub fn toolWithState(state: *SessionBashState) at.AgentTool {
    // v0.30.0 — append the session-env hint to the description when
    // exposure is on. The hint is stored in `description_extra_buf`
    // (session-scoped, freed by `deinit`) so it lives as long as the
    // tool. Falls back to the static base string on allocation failure.
    const base = "Run a shell command (via /bin/sh -c). Cwd persists via SessionBashState across calls; the result includes a `[cwd]` footer so drift after an in-place `cd` is visible. Pass `resetCwd: true` to clear the tracked cwd before the call. Output truncates to last 2000 lines / 50 KB with on-disk spill — pipe through `head`/`tail`/`grep` for long output.";
    const desc: []const u8 = if (state.expose_session_environment) blk: {
        state.description_extra_buf.clearRetainingCapacity();
        state.description_extra_buf.appendSlice(state.allocator, base) catch break :blk base;
        state.description_extra_buf.appendSlice(state.allocator, session_env_hint) catch break :blk base;
        break :blk state.description_extra_buf.items;
    } else base;
    return .{
        .name = "bash",
        .description = desc,
        .parameters_json = parameters_json,
        .execution_mode = .sequential,
        .ctx = @ptrCast(state),
        .execute = execute,
    };
}

/// Full §R bash: session-tracked cwd + workspace-scope check on
/// `cwd` arg + env filtered via denylist + shell-trust policy.
/// `ctx` carries a `BashCtx` so the single `ctx` slot can feed
/// both `SessionBashState` and `Workspace`.
pub const BashCtx = struct {
    state: ?*SessionBashState = null,
    workspace: ?*const workspace_mod.Workspace = null,
};

pub fn toolWithStateAndWorkspace(ctx: *BashCtx) at.AgentTool {
    // v0.30.0 — append the session-env hint when exposure is on. Stored
    // in the state's `description_extra_buf` (freed by `deinit`).
    const base = "Run a shell command with session-tracked cwd + workspace path-safety + env denylist + shell-trust policy. Result includes a `[cwd]` footer so cwd drift is visible; pass `resetCwd: true` to clear the tracked cwd before the call. Output truncates to last 2000 lines / 50 KB with on-disk spill — pipe through `head`/`tail`/`grep` for long output.";
    const desc: []const u8 = blk: {
        const s = ctx.state orelse break :blk base;
        if (!s.expose_session_environment) break :blk base;
        s.description_extra_buf.clearRetainingCapacity();
        s.description_extra_buf.appendSlice(s.allocator, base) catch break :blk base;
        s.description_extra_buf.appendSlice(s.allocator, session_env_hint) catch break :blk base;
        break :blk s.description_extra_buf.items;
    };
    return .{
        .name = "bash",
        .description = desc,
        .parameters_json = parameters_json,
        .execution_mode = .sequential,
        .ctx = @ptrCast(ctx),
        .execute = executeWithCtx,
    };
}

/// v1.7.4 — detach-and-return bash execution. Forks the command
/// via `nohup … &` into a separate process group, captures the
/// PID via `$!`, and returns `{pid, outputFile}` immediately.
/// Session-scoped supervision (status polling, cleanup on session
/// close) is a v1.8 follow-up; today the user can `tail -f` the
/// output file manually or issue a follow-up bash call.
///
/// Command delivery avoids shell-quote escaping by using argv
/// passing: the outer shell receives `sh -c WRAPPER __franky
/// $command $outfile`, exposing the user's command as `$1` and
/// the output file as `$2` inside the wrapper. This is
/// escape-safe for any byte sequence the user might pass.
fn runBackground(
    allocator: std.mem.Allocator,
    io: std.Io,
    command: []const u8,
    cwd: ?[]const u8,
    state: ?*SessionBashState,
) !at.ToolResult {
    const ts: i64 = ai.stream.nowMillis();
    const out_file = try std.fmt.allocPrint(allocator, "/tmp/franky_bg_{d}.out", .{ts});
    defer allocator.free(out_file);

    const wrapper = "nohup sh -c \"$1\" sh > \"$2\" 2>&1 < /dev/null & echo $!";

    // v0.30.0 — build a child env so session metadata is injected into
    // background commands too (same pattern as execute/executeWithCtx).
    var child_env: ?std.process.Environ.Map = if (state) |s|
        if (s.parent_env) |pe| try pe.clone(allocator) else null
    else
        null;
    defer if (child_env) |*m| m.deinit();
    if (child_env) |*m| injectSessionEnv(m, state);

    const argv = [_][]const u8{ "/bin/sh", "-c", wrapper, "__franky_bg", command, out_file };
    const result = std.process.run(allocator, io, .{
        .argv = &argv,
        .cwd = if (cwd) |c| std.process.Child.Cwd{ .path = c } else .inherit,
        .stdout_limit = std.Io.Limit.limited(256),
        .stderr_limit = std.Io.Limit.limited(1024),
        .environ_map = if (child_env) |*m| m else null,
    }) catch |err| return common.toolError(allocator, "bash_spawn_failed", @errorName(err));
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const pid_str = std.mem.trim(u8, result.stdout, " \t\n\r");
    const body = try std.fmt.allocPrint(
        allocator,
        "background pid={s} outputFile={s}\n(use `tail -f {s}` or a follow-up bash call to read output; " ++
            "session-supervised status polling lands in v1.8)\n",
        .{ pid_str, out_file, out_file },
    );

    const arr = try allocator.alloc(ai.types.ContentBlock, 1);
    arr[0] = .{ .text = .{ .text = body } };
    return .{ .content = arr };
}

/// v1.7.4 — chunked `on_update` emission. Posts 64 KB slices of
/// `bytes` to `on_update` as `ToolUpdate` JSON events. The final
/// result still carries the full captured output; consumers that
/// want real-time progress read the updates; transcript consumers
/// read the result. Non-allocating per-chunk except for the small
/// JSON envelope.
fn emitChunked(
    allocator: std.mem.Allocator,
    on_update: at.OnUpdate,
    bytes: []const u8,
) void {
    if (on_update.call == null) return;
    if (bytes.len <= chunk_bytes) return;
    var seq: u32 = 0;
    var i: usize = 0;
    while (i < bytes.len) : (i += chunk_bytes) {
        const end = @min(i + chunk_bytes, bytes.len);
        const json = std.fmt.allocPrint(
            allocator,
            "{{\"kind\":\"stdout\",\"seq\":{d},\"bytes\":{d},\"offset\":{d}}}",
            .{ seq, end - i, i },
        ) catch return;
        defer allocator.free(json);
        on_update.push(.{ .json = json });
        seq += 1;
    }
}

/// Result of checking whether a path refers to an existing directory.
/// Used by `resolveCwd` to decide whether to auto-clear a stale
/// session cwd — only `gone` triggers that behaviour; `unknown`
/// means we couldn't confirm the directory is missing (e.g. permission
/// error) and should let the spawn attempt proceed normally.
const DirCheck = enum { exists, gone, unknown };

/// Check whether `path` refers to an existing directory.
/// Returns `.exists` when `statFile` succeeds and the entry is a
/// directory, `.gone` when the path is confirmed absent (ENOENT or
/// ENOTDIR), and `.unknown` for any other error (EACCES, I/O, etc.)
/// where the directory might still exist but we can't prove it.
fn checkDir(io: std.Io, path: []const u8) DirCheck {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return .gone,
        else => return .unknown,
    };
    if (stat.kind == .directory) return .exists;
    // Path exists but is not a directory (e.g. regular file).
    return .gone;
}

/// Resolve the effective cwd for a bash invocation.
///
/// When a session-tracked cwd is stale (the directory was deleted by a
/// prior command, e.g. `rm -rf /tmp/workdir` while the cwd still points
/// there), `std.process.run` would fail with `error.FileNotFound` because
/// the child's `chdir` fails. This was previously misreported as
/// "bash_shell_missing: /bin/sh not found".
///
/// This function:
///   - When the cwd directory exists: returns it unchanged.
///   - When no cwd is set: returns `null` (inherit parent's cwd).
///   - For **stale session-tracked** cwds confirmed `.gone`: clears the
///     stale cwd from state and returns `null`. This matches how
///     interactive shells behave when their cwd is deleted.
///   - For **unknown** cwd status (e.g. permission error): returns
///     the cwd as-is and lets the spawn attempt proceed. If the
///     directory truly doesn't exist, the spawn's `FileNotFound`
///     will produce an improved error message.
///   - For **explicit** cwd args confirmed `.gone`: returns
///     `error.CwdNotFound` so the caller can surface a clear error.
///   - For **explicit** cwd args with `.unknown` status: also returns
///     `error.CwdNotFound`, since the user-specified directory is
///     unusable regardless of whether it's missing or inaccessible.
const CwdResolveError = error{CwdNotFound};

fn resolveCwd(
    io: std.Io,
    cwd_from_arg: ?[]const u8,
    state: ?*SessionBashState,
) CwdResolveError!?[]const u8 {
    // No cwd at all — just inherit.
    const cwd_opt: ?[]const u8 = cwd_from_arg orelse if (state) |s| s.getCwd() else null;
    if (cwd_opt == null) return null;

    // Fast path: directory exists — nothing to fix.
    switch (checkDir(io, cwd_opt.?)) {
        .exists => return cwd_opt,
        .gone => {}, // fall through to stale-cwd handling
        .unknown => {
            // Can't confirm the directory is gone (e.g. permission error).
            // For session-tracked cwds: don't clear it — let the spawn
            // attempt proceed. If it truly doesn't exist, the spawn will
            // fail with FileNotFound which now has an improved message.
            // For explicit cwd args: treat as unusable.
            if (cwd_from_arg != null) return error.CwdNotFound;
            return cwd_opt;
        },
    }

    // Directory is confirmed gone. Decide what to do based on source.
    const had_explicit_cwd = cwd_from_arg != null;
    if (had_explicit_cwd) {
        // The model explicitly asked for this directory and it doesn't
        // exist. Surface a clear error rather than letting the spawn
        // fail with a misleading "shell not found".
        return error.CwdNotFound;
    }

    // Stale session-tracked cwd. Clear it and fall back to inherit.
    if (state) |s| s.cwd_buf.clearRetainingCapacity();
    return null;
}

fn execute(
    self: *const at.AgentTool,
    allocator: std.mem.Allocator,
    io: std.Io,
    call_id: []const u8,
    args_json: []const u8,
    cancel: *ai.stream.Cancel,
    on_update: at.OnUpdate,
) anyerror!at.ToolResult {
    _ = cancel;

    const state: ?*SessionBashState = if (self.ctx) |c| @ptrCast(@alignCast(c)) else null;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const json_to_parse = common.repairConcatJson(arena.allocator(), args_json) orelse args_json;
    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), json_to_parse, .{});
    const root = parsed.value;

    const command_val = root.object.get("command") orelse
        return common.toolError(allocator, "invalid_args", "missing command");
    if (command_val != .string) return common.toolError(allocator, "invalid_args", "command must be a string");
    const command = command_val.string;
    if (command.len == 0) return common.toolError(allocator, "invalid_args", "command cannot be empty");

    const cwd_arg_opt: ?[]const u8 = if (root.object.get("cwd")) |v|
        (if (v == .string) v.string else null)
    else
        null;

    // `resetCwd: true` clears the session-tracked cwd before this
    // call resolves its effective working directory — see §C.4
    // visibility/escape-hatch addendum.
    const reset_cwd: bool = if (root.object.get("resetCwd")) |v|
        (v == .bool and v.bool)
    else
        false;
    if (reset_cwd) {
        if (state) |s| s.cwd_buf.clearRetainingCapacity();
    }

    // Precedence: explicit `cwd` arg > session-tracked cwd > inherit.
    // v1.28.0 — resolveCwd validates the directory exists. If the
    // session-tracked cwd is stale (directory was deleted by a prior
    // command), it is cleared and we fall back to inherited cwd.
    const cwd_opt = resolveCwd(io, cwd_arg_opt, state) catch |err| switch (err) {
        error.CwdNotFound => return common.toolError(allocator, "bash_cwd_missing", "working directory does not exist"),
    };

    // v1.7.4 — `background: true` detaches and returns.
    const background: bool = if (root.object.get("background")) |v|
        (v == .bool and v.bool)
    else
        false;
    if (background) return try runBackground(allocator, io, command, cwd_opt, state);

    const eff_default_ms: u64 = resolveDefaultTimeoutMs(state);
    const timeout_ms: u64 = if (root.object.get("timeoutMs")) |v| blk: {
        if (v == .integer and v.integer >= 1) break :blk @intCast(v.integer);
        break :blk eff_default_ms;
    } else eff_default_ms;

    const timeout: std.Io.Timeout = .{ .duration = .{
        .raw = std.Io.Duration.fromMilliseconds(@intCast(timeout_ms)),
        .clock = .awake,
    } };

    // Wrap the user command so $PWD is captured after the command
    // exits. Grouping + preserving `$?` keeps exit-code semantics
    // identical to the unwrapped form.
    const wrapped = try std.fmt.allocPrint(
        allocator,
        "{{ {s}\n}}\n__franky_rc=$?\nprintf '\\n{s}%s\\n' \"$PWD\"\nexit $__franky_rc\n",
        .{ command, trailer_marker },
    );
    defer allocator.free(wrapped);

    const argv = [_][]const u8{ "/bin/sh", "-c", wrapped };

    // v0.30.0 — build a child env so session metadata can be injected and
    // inherited `FRANKY_*` vars scrubbed. When a `SessionBashState` is
    // wired, clone its `parent_env` (if set) into a mutable map, inject,
    // and pass it to the child. When `state` is null (the stateless
    // `tool()` factory, used only in tests), inherit the parent env
    // verbatim as before — we cannot inject without a parent_env base.
    var child_env: ?std.process.Environ.Map = if (state) |s|
        if (s.parent_env) |pe| try pe.clone(allocator) else null
    else
        null;
    defer if (child_env) |*m| m.deinit();
    if (child_env) |*m| injectSessionEnv(m, state);

    const result = std.process.run(allocator, io, .{
        .argv = &argv,
        .cwd = if (cwd_opt) |c| std.process.Child.Cwd{ .path = c } else .inherit,
        .stdout_limit = std.Io.Limit.limited(max_output_bytes),
        .stderr_limit = std.Io.Limit.limited(max_output_bytes),
        .timeout = timeout,
        .environ_map = if (child_env) |*m| m else null,
    }) catch |err| switch (err) {
        error.StreamTooLong => return common.toolError(allocator, "bash_output_too_large", "output exceeded 8 MiB cap; redirect to a file or pipe through head/tail"),
        // v1.28.0 — FileNotFound can mean either the shell binary
        // is missing or the cwd directory doesn't exist. Since we now
        // pre-validate the cwd via resolveCwd, the cwd case should be
        // rare here (only for explicit cwd args that we couldn't auto-
        // clear). Keep the error code for backward compat but improve
        // the message.
        error.FileNotFound => return common.toolError(allocator, "bash_shell_missing", "/bin/sh not found or working directory does not exist"),
        error.AccessDenied, error.PermissionDenied => return common.toolError(allocator, "access_denied", "cannot execute /bin/sh"),
        else => |e| return common.toolError(allocator, "bash_spawn_failed", @errorName(e)),
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const parsed_trailer = parseTrailer(result.stdout);

    // Only update the shared cwd on successful exit — a failing
    // command's `cd` is not "taken". This matches interactive-shell
    // semantics where the shell refuses to descend on error.
    if (termOk(result.term)) {
        if (state) |s| if (parsed_trailer.cwd) |new_cwd| {
            s.setCwd(new_cwd) catch {}; // state update is best-effort
        };
    }

    // v1.7.4 — chunked `on_update` emission for large captures so
    // consumers that want progress see ≤ 64 KiB slices instead of
    // a single giant tool_execution_end payload.
    emitChunked(allocator, on_update, parsed_trailer.clean_stdout);

    const session_dir: ?[]const u8 = if (state) |s| s.getSessionDir() else null;
    // Surface the session-tracked cwd in the result so drift after
    // an in-place `cd` is visible to the caller. Only emitted when
    // a SessionBashState is wired — the stateless `tool()` factory
    // has no cwd to drift, so its result format is unchanged.
    const reported_cwd: ?[]const u8 = if (state) |s| s.getCwd() else null;
    return try formatResult(allocator, io, call_id, session_dir, reported_cwd, result, parsed_trailer.clean_stdout);
}

/// Full §R.5/§R.6 bash: session state + workspace-scope path-check
/// on `cwd` arg + filtered env + shell-trust policy. Distinct from
/// `execute` so the simpler factories keep the simpler code path.
fn executeWithCtx(
    self: *const at.AgentTool,
    allocator: std.mem.Allocator,
    io: std.Io,
    call_id: []const u8,
    args_json: []const u8,
    cancel: *ai.stream.Cancel,
    on_update: at.OnUpdate,
) anyerror!at.ToolResult {
    _ = cancel;

    const bash_ctx: ?*BashCtx = if (self.ctx) |c| @ptrCast(@alignCast(c)) else null;
    const state: ?*SessionBashState = if (bash_ctx) |bc| bc.state else null;
    const workspace: ?*const workspace_mod.Workspace = if (bash_ctx) |bc| bc.workspace else null;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const json_to_parse = common.repairConcatJson(arena.allocator(), args_json) orelse args_json;
    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), json_to_parse, .{});
    const root = parsed.value;

    const command_val = root.object.get("command") orelse
        return common.toolError(allocator, "invalid_args", "missing command");
    if (command_val != .string) return common.toolError(allocator, "invalid_args", "command must be a string");
    const command = command_val.string;
    if (command.len == 0) return common.toolError(allocator, "invalid_args", "command cannot be empty");

    const cwd_arg_opt: ?[]const u8 = if (root.object.get("cwd")) |v|
        (if (v == .string) v.string else null)
    else
        null;

    // §R: canonicalize explicit cwd arg through the workspace.
    var canon_cwd: ?[]u8 = null;
    defer if (canon_cwd) |p| allocator.free(p);
    const cwd_from_arg: ?[]const u8 = if (cwd_arg_opt) |p| blk: {
        if (workspace) |ws| {
            const r = try workspace_mod.canonicalizeOrError(allocator, ws, p);
            switch (r) {
                .ok => |c| {
                    canon_cwd = c.abs;
                    break :blk c.abs;
                },
                .err => |e| return common.toolError(allocator, e.code, e.message),
            }
        }
        break :blk p;
    } else null;

    // `resetCwd: true` clears the session-tracked cwd before this
    // call resolves its effective working directory.
    const reset_cwd: bool = if (root.object.get("resetCwd")) |v|
        (v == .bool and v.bool)
    else
        false;
    if (reset_cwd) {
        if (state) |s| s.cwd_buf.clearRetainingCapacity();
    }

    // Precedence: explicit `cwd` arg > session-tracked cwd > inherit.
    // v1.28.0 — resolveCwd validates the directory exists. If the
    // session-tracked cwd is stale (directory was deleted by a prior
    // command), it is cleared and we fall back to inherited cwd.
    const cwd_opt = resolveCwd(io, cwd_from_arg, state) catch |err| switch (err) {
        error.CwdNotFound => return common.toolError(allocator, "bash_cwd_missing", "working directory does not exist"),
    };

    // v1.7.4 — `background: true` detaches and returns.
    const background: bool = if (root.object.get("background")) |v|
        (v == .bool and v.bool)
    else
        false;
    if (background) return try runBackground(allocator, io, command, cwd_opt, state);

    const eff_default_ms: u64 = resolveDefaultTimeoutMs(state);
    const timeout_ms: u64 = if (root.object.get("timeoutMs")) |v| blk: {
        if (v == .integer and v.integer >= 1) break :blk @intCast(v.integer);
        break :blk eff_default_ms;
    } else eff_default_ms;

    const timeout: std.Io.Timeout = .{ .duration = .{
        .raw = std.Io.Duration.fromMilliseconds(@intCast(timeout_ms)),
        .clock = .awake,
    } };

    // §R.5 shell choice + §R.6 env filter.
    const shell = if (workspace) |ws| workspace_mod.chosenShell(ws, ws.host_env) else "/bin/sh";
    // v0.30.0 — build a mutable env map so session metadata can be
    // injected/scrubbed, but only when we have a base to start from.
    // When a workspace filter applies, start from it; otherwise clone
    // the session's `parent_env` (if set) so the child still inherits
    // PATH etc. When neither is available, pass null so std.process.run
    // inherits the parent env verbatim (legacy behavior) — we cannot
    // scrub/inject without a base, but that only happens when a mode
    // driver forgot to set `parent_env`, which all four do.
    var filtered_env: ?std.process.Environ.Map = if (workspace) |ws|
        (try workspace_mod.filteredEnv(allocator, ws)) orelse std.process.Environ.Map.init(allocator)
    else if (state) |s| if (s.parent_env) |pe| try pe.clone(allocator) else null
    else
        null;
    defer if (filtered_env) |*m| m.deinit();
    if (filtered_env) |*m| injectSessionEnv(m, state);

    // Wrap the user command so $PWD is captured after the command
    // exits. Grouping + preserving `$?` keeps exit-code semantics
    // identical to the unwrapped form.
    const wrapped = try std.fmt.allocPrint(
        allocator,
        "{{ {s}\n}}\n__franky_rc=$?\nprintf '\\n{s}%s\\n' \"$PWD\"\nexit $__franky_rc\n",
        .{ command, trailer_marker },
    );
    defer allocator.free(wrapped);

    const argv = [_][]const u8{ shell, "-c", wrapped };

    const result = std.process.run(allocator, io, .{
        .argv = &argv,
        .cwd = if (cwd_opt) |c| std.process.Child.Cwd{ .path = c } else .inherit,
        .stdout_limit = std.Io.Limit.limited(max_output_bytes),
        .stderr_limit = std.Io.Limit.limited(max_output_bytes),
        .timeout = timeout,
        .environ_map = if (filtered_env) |*m| m else null,
    }) catch |err| switch (err) {
        error.StreamTooLong => return common.toolError(allocator, "bash_output_too_large", "output exceeded 8 MiB cap; redirect to a file or pipe through head/tail"),
        // v1.28.0 — FileNotFound can mean either the shell binary
        // is missing or the cwd directory doesn't exist. resolveCwd
        // pre-validates for session-tracked cwds; explicit cwd args
        // that don't exist will still reach this path.
        error.FileNotFound => return common.toolError(allocator, "bash_shell_missing", "shell not found or working directory does not exist"),
        error.AccessDenied, error.PermissionDenied => return common.toolError(allocator, "access_denied", "cannot execute shell"),
        else => |e| return common.toolError(allocator, "bash_spawn_failed", @errorName(e)),
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const parsed_trailer = parseTrailer(result.stdout);

    if (termOk(result.term)) {
        if (state) |s| if (parsed_trailer.cwd) |new_cwd| {
            s.setCwd(new_cwd) catch {};
        };
    }

    emitChunked(allocator, on_update, parsed_trailer.clean_stdout);
    const session_dir: ?[]const u8 = if (state) |s| s.getSessionDir() else null;
    const reported_cwd: ?[]const u8 = if (state) |s| s.getCwd() else null;
    return try formatResult(allocator, io, call_id, session_dir, reported_cwd, result, parsed_trailer.clean_stdout);
}

pub const TrailerResult = struct {
    clean_stdout: []const u8,
    cwd: ?[]const u8,
};

/// Scan stdout for the trailer emitted by our wrapper; return the
/// stdout sans trailer and the captured cwd (if any). Uses
/// `lastIndexOf` so legitimate output that happens to echo the marker
/// does not confuse the parser.
pub fn parseTrailer(stdout: []const u8) TrailerResult {
    const idx = std.mem.lastIndexOf(u8, stdout, trailer_marker) orelse {
        return .{ .clean_stdout = stdout, .cwd = null };
    };
    const after = stdout[idx + trailer_marker.len ..];
    const eol = std.mem.indexOfScalar(u8, after, '\n') orelse after.len;
    const cwd_val = after[0..eol];

    // Strip the trailer plus any leading `\n` our wrapper emitted.
    var strip_start = idx;
    if (strip_start > 0 and stdout[strip_start - 1] == '\n') strip_start -= 1;
    return .{ .clean_stdout = stdout[0..strip_start], .cwd = cwd_val };
}

/// Format the run's full output (term line + `[stdout]…[stderr]…`),
/// then apply `truncateTail` so over-long captures don't dominate
/// the agent's context. When truncation kicks in (v1.27.0):
///   1. Open `<spill_dir>/franky-bash-<call_id>.log` and write the
///      FULL pre-truncation text. Best-effort — a write failure
///      degrades to "no spill, just truncated text" rather than
///      failing the whole tool call.
///   2. Append an actionable trailer to the truncated content with
///      the spill path and line range so the model can `cat` it back
///      if it actually needs the elided content.
///
/// Tail-truncation rather than head-truncation because errors (the
/// thing the model usually needs) typically land at the end of the
/// stream — `error: foo` from a failed compile, `Killed` from OOM,
/// the final exit-status trailer, etc.
fn formatResult(
    allocator: std.mem.Allocator,
    io: std.Io,
    call_id: []const u8,
    session_dir: ?[]const u8,
    reported_cwd: ?[]const u8,
    result: std.process.RunResult,
    clean_stdout: []const u8,
) !at.ToolResult {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    const term_line = try termLine(allocator, result.term);
    defer allocator.free(term_line);
    try buf.appendSlice(allocator, term_line);
    try buf.append(allocator, '\n');

    if (clean_stdout.len > 0) {
        try buf.appendSlice(allocator, "[stdout]\n");
        try buf.appendSlice(allocator, clean_stdout);
        if (clean_stdout[clean_stdout.len - 1] != '\n') try buf.append(allocator, '\n');
    }
    if (result.stderr.len > 0) {
        try buf.appendSlice(allocator, "[stderr]\n");
        try buf.appendSlice(allocator, result.stderr);
        if (result.stderr[result.stderr.len - 1] != '\n') try buf.append(allocator, '\n');
    }
    if (clean_stdout.len == 0 and result.stderr.len == 0) {
        try buf.appendSlice(allocator, "(no output)\n");
    }
    // Cwd footer — placed at the END so tail-truncation preserves
    // it even for very large outputs. Only emitted when a
    // SessionBashState was passed in (callers without state have no
    // cwd to drift).
    if (reported_cwd) |cwd| {
        try buf.appendSlice(allocator, "[cwd] ");
        try buf.appendSlice(allocator, cwd);
        try buf.append(allocator, '\n');
    }

    const trunc = truncate_mod.truncateTail(buf.items, .{});
    const is_error = !termOk(result.term);

    if (!trunc.truncated) {
        const text = try allocator.dupe(u8, buf.items);
        const arr = try allocator.alloc(ai.types.ContentBlock, 1);
        arr[0] = .{ .text = .{ .text = text } };
        return .{ .content = arr, .is_error = is_error };
    }

    // Truncated: best-effort spill the FULL formatted text, then
    // append an actionable trailer pointing at the spill path. Spill
    // failure degrades gracefully — we still return the truncated
    // content with a trailer that omits the path.
    const spill_path = trySpillBashOutput(allocator, io, call_id, session_dir, buf.items);
    defer if (spill_path) |p| allocator.free(p);

    const start_line = trunc.total_lines - trunc.output_lines + 1;
    const end_line = trunc.total_lines;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, trunc.content);
    try out.append(allocator, '\n');
    try out.append(allocator, '\n');

    const trailer: []u8 = blk: {
        if (trunc.last_line_partial) {
            // Edge case: a single line larger than the byte cap — show
            // the tail of that line and a hint about its true size.
            const last_line_len: usize = ll: {
                const last_nl = std.mem.lastIndexOfScalar(u8, buf.items, '\n');
                if (last_nl) |i| break :ll buf.items.len - i - 1;
                break :ll buf.items.len;
            };
            const line_size = try truncate_mod.formatSize(allocator, last_line_len);
            defer allocator.free(line_size);
            const shown_size = try truncate_mod.formatSize(allocator, trunc.output_bytes);
            defer allocator.free(shown_size);
            break :blk if (spill_path) |p|
                try std.fmt.allocPrint(
                    allocator,
                    "[Showing last {s} of line {d} (line is {s}). Full output: {s}]\n",
                    .{ shown_size, end_line, line_size, p },
                )
            else
                try std.fmt.allocPrint(
                    allocator,
                    "[Showing last {s} of line {d} (line is {s}). Spill failed; full output unavailable.]\n",
                    .{ shown_size, end_line, line_size },
                );
        }
        const by = trunc.truncated_by orelse break :blk try allocator.dupe(u8, "");
        const cap_size = if (by == .bytes) try truncate_mod.formatSize(allocator, trunc.max_bytes) else try allocator.dupe(u8, "");
        defer allocator.free(cap_size);
        break :blk if (spill_path) |p| switch (by) {
            .lines => try std.fmt.allocPrint(
                allocator,
                "[Showing lines {d}-{d} of {d}. Full output: {s}]\n",
                .{ start_line, end_line, trunc.total_lines, p },
            ),
            .bytes => try std.fmt.allocPrint(
                allocator,
                "[Showing lines {d}-{d} of {d} ({s} limit). Full output: {s}]\n",
                .{ start_line, end_line, trunc.total_lines, cap_size, p },
            ),
        } else switch (by) {
            .lines => try std.fmt.allocPrint(
                allocator,
                "[Showing lines {d}-{d} of {d}. Spill failed; full output unavailable.]\n",
                .{ start_line, end_line, trunc.total_lines },
            ),
            .bytes => try std.fmt.allocPrint(
                allocator,
                "[Showing lines {d}-{d} of {d} ({s} limit). Spill failed; full output unavailable.]\n",
                .{ start_line, end_line, trunc.total_lines, cap_size },
            ),
        };
    };
    defer allocator.free(trailer);
    try out.appendSlice(allocator, trailer);

    const text = try allocator.dupe(u8, out.items);
    const arr = try allocator.alloc(ai.types.ContentBlock, 1);
    arr[0] = .{ .text = .{ .text = text } };
    return .{ .content = arr, .is_error = is_error };
}

/// Best-effort write of `full_output` to a spill file the model
/// can read back later. Returns the path on success (caller frees)
/// or null on any failure; the caller must keep working from the
/// truncated output regardless.
///
/// **v1.27.2 — session-aware spill location.**
///   - When `session_dir` is non-null, the spill lands at
///     `<session_dir>/bash/<call_id>.log`. The `bash/` subdir is
///     created on demand. This ties the spill lifecycle to the
///     session — when the session directory is removed (manual
///     `rm`, future `--gc-sessions`), spill files go with it.
///   - When `session_dir` is null (rpc/proxy uses `bash.tool()`
///     without a session, or `--no-session` print/interactive
///     runs), falls back to `/tmp/franky-bash-<call_id>.log`
///     matching v1.27.0 behavior.
fn trySpillBashOutput(
    allocator: std.mem.Allocator,
    io: std.Io,
    call_id: []const u8,
    session_dir: ?[]const u8,
    full_output: []const u8,
) ?[]u8 {
    if (session_dir) |sd| {
        // `<session_dir>/bash/<call_id>.log` — create the subdir
        // on demand. createDirPath is idempotent (treats already-
        // exists as success), so calling it per-spill is cheap.
        const subdir = std.fmt.allocPrint(allocator, "{s}/bash", .{sd}) catch return spillTmp(allocator, io, call_id, full_output);
        defer allocator.free(subdir);
        std.Io.Dir.cwd().createDirPath(io, subdir) catch return spillTmp(allocator, io, call_id, full_output);

        const path = std.fmt.allocPrint(allocator, "{s}/{s}.log", .{ subdir, call_id }) catch return spillTmp(allocator, io, call_id, full_output);
        var f = std.Io.Dir.cwd().createFile(io, path, .{}) catch {
            allocator.free(path);
            return spillTmp(allocator, io, call_id, full_output);
        };
        defer f.close(io);
        f.writeStreamingAll(io, full_output) catch {
            allocator.free(path);
            return spillTmp(allocator, io, call_id, full_output);
        };
        return path;
    }
    return spillTmp(allocator, io, call_id, full_output);
}

/// `/tmp` fallback for `trySpillBashOutput`. Used when no session
/// dir is available or when the session-dir write fails.
fn spillTmp(allocator: std.mem.Allocator, io: std.Io, call_id: []const u8, full_output: []const u8) ?[]u8 {
    const path = std.fmt.allocPrint(allocator, "{s}/franky-bash-{s}.log", .{ spill_dir_default, call_id }) catch return null;
    var f = std.Io.Dir.cwd().createFile(io, path, .{}) catch {
        allocator.free(path);
        return null;
    };
    defer f.close(io);
    f.writeStreamingAll(io, full_output) catch {
        allocator.free(path);
        return null;
    };
    return path;
}

fn termOk(t: std.process.Child.Term) bool {
    return switch (t) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn termLine(allocator: std.mem.Allocator, t: std.process.Child.Term) ![]u8 {
    return switch (t) {
        .exited => |code| std.fmt.allocPrint(allocator, "[exit] code={d}", .{code}),
        .signal => |sig| std.fmt.allocPrint(allocator, "[signal] {t}", .{sig}),
        .stopped => |sig| std.fmt.allocPrint(allocator, "[stopped] {t}", .{sig}),
        .unknown => |v| std.fmt.allocPrint(allocator, "[unknown] term={d}", .{v}),
    };
}


// ─── tests ────────────────────────────────────────────────────────────

const testing = std.testing;
const test_h = @import("../../test_helpers.zig");

test "bash tool: echo stdout success" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const gpa = testing.allocator;
    var cancel: ai.stream.Cancel = .{};

    const t = tool();
    var res = try t.execute(
        &t,
        gpa,
        io,
        "id-1",
        \\{"command":"echo hello-from-bash"}
        ,
        &cancel,
        .{},
    );
    defer res.deinit(gpa);
    try testing.expect(!res.is_error);
    const txt = res.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, txt, "[exit] code=0") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "hello-from-bash") != null);
}

test "bash tool: non-zero exit is error" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const gpa = testing.allocator;
    var cancel: ai.stream.Cancel = .{};

    const t = tool();
    var res = try t.execute(
        &t,
        gpa,
        io,
        "id-2",
        \\{"command":"exit 7"}
        ,
        &cancel,
        .{},
    );
    defer res.deinit(gpa);
    try testing.expect(res.is_error);
    try testing.expect(std.mem.indexOf(u8, res.content[0].text.text, "[exit] code=7") != null);
}

test "bash tool: rejects missing command" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const gpa = testing.allocator;
    var cancel: ai.stream.Cancel = .{};

    const t = tool();
    var res = try t.execute(
        &t,
        gpa,
        io,
        "id-3",
        \\{}
        ,
        &cancel,
        .{},
    );
    defer res.deinit(gpa);
    try testing.expect(res.is_error);
    try testing.expect(std.mem.indexOf(u8, res.content[0].text.text, "invalid_args") != null);
}

// ─── v0.4.0 additions ─────────────────────────────────────────────

test "parseTrailer: extracts cwd and strips trailer from stdout" {
    const raw = "hello world\n" ++ trailer_marker ++ "/tmp/franky\n";
    const r = parseTrailer(raw);
    try testing.expectEqualStrings("hello world", r.clean_stdout);
    try testing.expectEqualStrings("/tmp/franky", r.cwd.?);
}

test "parseTrailer: returns original stdout when marker absent" {
    const raw = "plain output\n";
    const r = parseTrailer(raw);
    try testing.expectEqualStrings(raw, r.clean_stdout);
    try testing.expect(r.cwd == null);
}

test "parseTrailer: lastIndexOf semantics survive marker-in-output" {
    // If the user's own output happens to echo the marker, only the
    // trailer emitted by our wrapper (last occurrence) counts.
    const raw = "user printed " ++ trailer_marker ++ "/bogus\n" ++
        "more output\n" ++
        trailer_marker ++ "/real/pwd\n";
    const r = parseTrailer(raw);
    try testing.expectEqualStrings("/real/pwd", r.cwd.?);
    try testing.expect(std.mem.indexOf(u8, r.clean_stdout, "more output") != null);
}

test "bash tool: wrapper hides trailer from reported stdout" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const gpa = testing.allocator;
    var cancel: ai.stream.Cancel = .{};

    const t = tool();
    var res = try t.execute(
        &t,
        gpa,
        io,
        "id-hide",
        \\{"command":"echo visible; echo done"}
        ,
        &cancel,
        .{},
    );
    defer res.deinit(gpa);
    const txt = res.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, txt, "visible") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "done") != null);
    // The trailer itself must never reach the caller.
    try testing.expect(std.mem.indexOf(u8, txt, trailer_marker) == null);
}

test "bash tool: SessionBashState propagates cwd across calls" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const gpa = testing.allocator;
    var cancel: ai.stream.Cancel = .{};

    // Seed two nested tmpdirs so `cd` lands somewhere real.
    const base = "/tmp/franky_bash_cwd_test";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, base);
    try std.Io.Dir.cwd().createDirPath(io, base ++ "/sub");

    // Resolve `base` through the filesystem so comparisons work on
    // targets where /tmp is a symlink (macOS: /tmp → /private/tmp).
    // `$PWD` inside the bash wrapper reports the resolved path.
    const resolved_sub = try resolveSubPath(gpa, io, base, "sub");
    defer gpa.free(resolved_sub);

    var state = SessionBashState.init(gpa);
    defer state.deinit();
    try state.setCwd(base);

    const t = toolWithState(&state);

    // First call: `pwd` should report the seeded cwd.
    var r1 = try t.execute(&t, gpa, io, "id-a", "{\"command\":\"pwd\"}", &cancel, .{});
    defer r1.deinit(gpa);
    try testing.expect(std.mem.indexOf(u8, r1.content[0].text.text, base) != null);

    // Second call: `cd sub && pwd` should change state.cwd to the
    // nested dir, and the reported pwd must reflect it.
    var r2 = try t.execute(&t, gpa, io, "id-b", "{\"command\":\"cd sub && pwd\"}", &cancel, .{});
    defer r2.deinit(gpa);
    const pwd_txt = r2.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, pwd_txt, base ++ "/sub") != null);
    try testing.expectEqualStrings(resolved_sub, state.getCwd().?);

    // Third call (no cd): should start in the previously-captured
    // cwd, proving cwd *persists* between invocations.
    var r3 = try t.execute(&t, gpa, io, "id-c", "{\"command\":\"pwd\"}", &cancel, .{});
    defer r3.deinit(gpa);
    try testing.expect(std.mem.indexOf(u8, r3.content[0].text.text, base ++ "/sub") != null);
}

test "bash tool: failed command does not promote its cwd into the session" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const gpa = testing.allocator;
    var cancel: ai.stream.Cancel = .{};

    const base = "/tmp/franky_bash_failcd_test";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, base);

    var state = SessionBashState.init(gpa);
    defer state.deinit();
    try state.setCwd(base);
    const before = try gpa.dupe(u8, state.getCwd().?);
    defer gpa.free(before);

    const t = toolWithState(&state);
    var res = try t.execute(&t, gpa, io, "id-fail", "{\"command\":\"exit 1\"}", &cancel, .{});
    defer res.deinit(gpa);
    try testing.expect(res.is_error);
    try testing.expectEqualStrings(before, state.getCwd().?);
}

test "bash tool: honors explicit cwd arg over session-tracked cwd" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const gpa = testing.allocator;
    var cancel: ai.stream.Cancel = .{};

    const base = "/tmp/franky_bash_cwd_override";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, base);
    try std.Io.Dir.cwd().createDirPath(io, base ++ "/a");
    try std.Io.Dir.cwd().createDirPath(io, base ++ "/b");

    const resolved_b = try resolveSubPath(gpa, io, base, "b");
    defer gpa.free(resolved_b);

    var state = SessionBashState.init(gpa);
    defer state.deinit();
    try state.setCwd(base ++ "/a");

    const t = toolWithState(&state);
    const args = try std.fmt.allocPrint(gpa,
        \\{{"command":"pwd","cwd":"{s}"}}
    , .{base ++ "/b"});
    defer gpa.free(args);

    var r = try t.execute(&t, gpa, io, "id-ov", args, &cancel, .{});
    defer r.deinit(gpa);
    try testing.expect(std.mem.indexOf(u8, r.content[0].text.text, base ++ "/b") != null);
    // Session cwd should NOT have shifted to `/a`'s explicit override;
    // the trailer in that run reports `/b`, which updates state.
    try testing.expectEqualStrings(resolved_b, state.getCwd().?);
}

test "bash tool: result includes [cwd] footer when state is wired" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_bash_cwd_footer";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, base);

    var state = SessionBashState.init(gpa);
    defer state.deinit();
    try state.setCwd(base);

    var cancel: ai.stream.Cancel = .{};
    const t = toolWithState(&state);
    var res = try t.execute(&t, gpa, io, "id-foot", "{\"command\":\"echo ok\"}", &cancel, .{});
    defer res.deinit(gpa);

    const txt = res.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, txt, "[cwd] ") != null);
    // Footer reflects the post-call session cwd (which the wrapper's
    // trailer set via $PWD — matches `base` here).
    try testing.expect(std.mem.indexOf(u8, txt, base) != null);
}

test "bash tool: stateless tool() omits [cwd] footer (output unchanged)" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var cancel: ai.stream.Cancel = .{};
    const t = tool();
    var res = try t.execute(&t, gpa, io, "id-nostate", "{\"command\":\"echo ok\"}", &cancel, .{});
    defer res.deinit(gpa);

    try testing.expect(std.mem.indexOf(u8, res.content[0].text.text, "[cwd] ") == null);
}

test "bash tool: resetCwd clears session-tracked cwd before resolving" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    // Seed two dirs: one we'll cd into and abandon, one we expect to
    // land in after reset (= the agent process's cwd, captured via
    // a follow-up `pwd`).
    const base = "/tmp/franky_bash_resetcwd";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, base);

    var state = SessionBashState.init(gpa);
    defer state.deinit();
    try state.setCwd(base);

    var cancel: ai.stream.Cancel = .{};
    const t = toolWithState(&state);

    // Sanity: state.getCwd() reflects the seeded cwd.
    try testing.expect(state.getCwd() != null);

    // resetCwd:true wipes the tracked cwd before the call resolves
    // its working directory. The command runs in the inherited
    // (agent process) cwd, NOT in `base`.
    var r = try t.execute(
        &t,
        gpa,
        io,
        "id-reset",
        "{\"command\":\"pwd\",\"resetCwd\":true}",
        &cancel,
        .{},
    );
    defer r.deinit(gpa);

    const txt = r.content[0].text.text;
    // The pwd output should NOT be the abandoned `base`. It will be
    // whatever the test-runner's cwd is — we don't assert the exact
    // path (it varies by build host), only that drift is gone.
    try testing.expect(std.mem.indexOf(u8, txt, base) == null);
    // Post-call, state.cwd_buf holds the inherited cwd (the trailer
    // captured $PWD). It is non-null but != `base`.
    try testing.expect(state.getCwd() != null);
    try testing.expect(!std.mem.eql(u8, state.getCwd().?, base));
}

/// v1.3.2 — resolve `<base>/<sub>` through `std.Io.Dir.realPathFile`
/// so test comparisons survive targets where /tmp is a symlink
/// (macOS: /tmp → /private/tmp, so `pwd` and `$PWD` report the
/// resolved form). Returns an owned slice on `gpa`.
fn resolveSubPath(gpa: std.mem.Allocator, io: std.Io, base: []const u8, sub: []const u8) ![]u8 {
    var dir = try std.Io.Dir.cwd().openDir(io, base, .{});
    defer dir.close(io);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try dir.realPathFile(io, sub, &buf);
    return try gpa.dupe(u8, buf[0..n]);
}

test "SessionBashState.getCwd returns null when unset" {
    var state = SessionBashState.init(testing.allocator);
    defer state.deinit();
    try testing.expect(state.getCwd() == null);
    try state.setCwd("/tmp/x");
    try testing.expectEqualStrings("/tmp/x", state.getCwd().?);
}

test "SessionBashState.defaultTimeoutMs honors override" {
    var state = SessionBashState.init(testing.allocator);
    defer state.deinit();
    // Default = module-level constant when override unset.
    try testing.expectEqual(default_timeout_ms, state.defaultTimeoutMs());
    try testing.expectEqual(default_timeout_ms, resolveDefaultTimeoutMs(&state));
    // Set the settings-layer override; resolver picks it up.
    state.default_timeout_ms_override = 30_000;
    try testing.expectEqual(@as(u64, 30_000), state.defaultTimeoutMs());
    try testing.expectEqual(@as(u64, 30_000), resolveDefaultTimeoutMs(&state));
    // Null state → module default.
    try testing.expectEqual(default_timeout_ms, resolveDefaultTimeoutMs(null));
}

// ─── v1.7.4 — background + chunked emission ─────────────────────

const UpdateCollector = struct {
    count: std.atomic.Value(u32) = .init(0),
    total_bytes: std.atomic.Value(u64) = .init(0),

    fn onUpdate(ud: ?*anyopaque, update: at.ToolUpdate) void {
        const self: *UpdateCollector = @ptrCast(@alignCast(ud.?));
        _ = self.count.fetchAdd(1, .monotonic);
        _ = self.total_bytes.fetchAdd(update.json.len, .monotonic);
    }
};

test "bash tool: chunked on_update fires for large captures" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    // Generate ~200 KiB of output so chunking fires (≥ 64 KiB).
    var cancel: ai.stream.Cancel = .{};
    var collector: UpdateCollector = .{};
    const t = tool();
    const args = "{\"command\":\"yes 'franky-long-output' | head -c 200000\"}";
    var res = try t.execute(&t, gpa, io, "c-1", args, &cancel, .{
        .ctx = @ptrCast(&collector),
        .call = UpdateCollector.onUpdate,
    });
    defer res.deinit(gpa);

    // 200 KiB / 64 KiB = 4 chunks emitted.
    const n = collector.count.load(.monotonic);
    try testing.expect(n >= 2);
}

test "bash tool: chunked on_update is silent for small captures" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var cancel: ai.stream.Cancel = .{};
    var collector: UpdateCollector = .{};
    const t = tool();
    var res = try t.execute(&t, gpa, io, "c-1", "{\"command\":\"echo hi\"}", &cancel, .{
        .ctx = @ptrCast(&collector),
        .call = UpdateCollector.onUpdate,
    });
    defer res.deinit(gpa);

    try testing.expectEqual(@as(u32, 0), collector.count.load(.monotonic));
}

test "bash tool: background: true returns pid + outputFile, command runs detached" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var cancel: ai.stream.Cancel = .{};
    const t = tool();
    // Command creates a sentinel file after a brief sleep. We check
    // that the bash call returns right away (before the sleep ends),
    // then the sentinel appears once the backgrounded command
    // completes.
    const args = "{\"command\":\"sleep 0.2; echo done > /tmp/franky_bg_test_sentinel\",\"background\":true}";
    const t0 = ai.stream.nowMillis();
    var res = try t.execute(&t, gpa, io, "c-1", args, &cancel, .{});
    const elapsed = ai.stream.nowMillis() - t0;
    defer res.deinit(gpa);

    // Returned quickly (well under the 200ms sleep inside the command).
    try testing.expect(elapsed < 150);

    // Result carries the expected shape.
    try testing.expect(std.mem.indexOf(u8, res.content[0].text.text, "background pid=") != null);
    try testing.expect(std.mem.indexOf(u8, res.content[0].text.text, "outputFile=") != null);

    // Wait for the backgrounded command to complete, then verify
    // the sentinel.
    const deadline = ai.stream.nowMillis() + 2_000;
    while (ai.stream.nowMillis() < deadline) {
        var f = std.Io.Dir.cwd().openFile(io, "/tmp/franky_bg_test_sentinel", .{}) catch |e| switch (e) {
            error.FileNotFound => {
                // Sleep 50ms instead of busy-polling to avoid burning CPU.
                const ts = std.c.timespec{ .sec = 0, .nsec = 50_000_000 };
                _ = std.c.nanosleep(&ts, null);
                continue;
            },
            else => break,
        };
        f.close(io);
        break;
    }
    // Clean up.
    std.Io.Dir.cwd().deleteFile(io, "/tmp/franky_bg_test_sentinel") catch {};
}

test "bash tool: large output is tail-truncated and spilled to disk (v1.27.0)" {
    // Generate ~80 KB of output (above the 50 KB truncation threshold)
    // and verify:
    //   - the result body is truncated (much smaller than the full)
    //   - the truncation trailer points at /tmp/franky-bash-<call_id>.log
    //   - that file exists and contains the FULL formatted output
    //   - the trailer is "[Showing lines …]" with the right line range
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const call_id = "spill-test-1";
    const spill_path = "/tmp/franky-bash-" ++ call_id ++ ".log";
    // Best-effort cleanup before + after so a stale file from a
    // previous failed run can't poison this one.
    std.Io.Dir.cwd().deleteFile(io, spill_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, spill_path) catch {};

    var cancel: ai.stream.Cancel = .{};
    const t = tool();
    // 4000 lines × 20 bytes each = ~80 KB. Crosses the 2000-line cap
    // from `truncate.default_max_lines` AND the 50 KB byte cap.
    const args =
        \\{"command":"i=1; while [ $i -le 4000 ]; do printf 'line%04d=padding%s\n' \"$i\" 'xxxxxxxxxxxxxxxxxxxx'; i=$((i+1)); done"}
    ;
    var res = try t.execute(&t, gpa, io, call_id, args, &cancel, .{});
    defer res.deinit(gpa);

    const txt = res.content[0].text.text;
    // Truncated — should be FAR shorter than the ~80 KB raw output.
    try testing.expect(txt.len < 60 * 1024);
    // Trailer mentions the spill path and a line range.
    try testing.expect(std.mem.indexOf(u8, txt, "Full output: ") != null);
    try testing.expect(std.mem.indexOf(u8, txt, spill_path) != null);
    try testing.expect(std.mem.indexOf(u8, txt, "[Showing lines ") != null);

    // Tail truncation kept the LAST lines, not the first. Line 4000
    // should be present in the visible body; line 1 should not.
    try testing.expect(std.mem.indexOf(u8, txt, "line4000=") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "line0001=") == null);

    // Spill file exists and has the full content (line 1 is in there).
    var f = try std.Io.Dir.cwd().openFile(io, spill_path, .{});
    defer f.close(io);
    const len = try f.length(io);
    // Full output is much larger than the truncated body.
    try testing.expect(len > 70 * 1024);
    const full = try gpa.alloc(u8, @intCast(len));
    defer gpa.free(full);
    _ = try f.readPositionalAll(io, full, 0);
    try testing.expect(std.mem.indexOf(u8, full, "line0001=") != null);
    try testing.expect(std.mem.indexOf(u8, full, "line4000=") != null);
}

test "bash tool: small output is not truncated, no spill file (v1.27.0)" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const call_id = "spill-test-2";
    const spill_path = "/tmp/franky-bash-" ++ call_id ++ ".log";
    std.Io.Dir.cwd().deleteFile(io, spill_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, spill_path) catch {};

    var cancel: ai.stream.Cancel = .{};
    const t = tool();
    var res = try t.execute(
        &t,
        gpa,
        io,
        call_id,
        \\{"command":"echo hello"}
        ,
        &cancel,
        .{},
    );
    defer res.deinit(gpa);

    const txt = res.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, txt, "hello") != null);
    // No truncation trailer.
    try testing.expect(std.mem.indexOf(u8, txt, "Full output: ") == null);
    try testing.expect(std.mem.indexOf(u8, txt, "[Showing lines ") == null);

    // No spill file was created.
    if (std.Io.Dir.cwd().openFile(io, spill_path, .{})) |f| {
        var f_local = f;
        f_local.close(io);
        try testing.expect(false); // should not exist
    } else |_| {
        // Expected — file does not exist.
    }
}

test "bash tool: spill lands in <session_dir>/bash/<call_id>.log when state has session dir (v1.27.2)" {
    // With a SessionBashState that's been pointed at an on-disk
    // session directory, large bash output should spill to
    // `<session_dir>/bash/<call_id>.log` instead of `/tmp`.
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const session_dir = "/tmp/franky_session_spill_test";
    _ = std.Io.Dir.cwd().deleteTree(io, session_dir) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, session_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, session_dir);

    const call_id = "spill-session-1";
    const session_spill_path = session_dir ++ "/bash/" ++ call_id ++ ".log";
    const tmp_spill_path = "/tmp/franky-bash-" ++ call_id ++ ".log";
    // Pre-clean both possible locations to make sure the test is
    // observing this run's output, not a leftover.
    std.Io.Dir.cwd().deleteFile(io, session_spill_path) catch {};
    std.Io.Dir.cwd().deleteFile(io, tmp_spill_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, tmp_spill_path) catch {};

    var state = SessionBashState.init(gpa);
    defer state.deinit();
    try state.setSessionDir(session_dir);

    var cancel: ai.stream.Cancel = .{};
    const t = toolWithState(&state);
    // Same fixture as the v1.27.0 spill test — ~80 KB of output.
    const args =
        \\{"command":"i=1; while [ $i -le 4000 ]; do printf 'line%04d=padding%s\n' \"$i\" 'xxxxxxxxxxxxxxxxxxxx'; i=$((i+1)); done"}
    ;
    var res = try t.execute(&t, gpa, io, call_id, args, &cancel, .{});
    defer res.deinit(gpa);

    const txt = res.content[0].text.text;
    // Trailer points at the SESSION-dir path, not the /tmp fallback.
    try testing.expect(std.mem.indexOf(u8, txt, session_spill_path) != null);
    try testing.expect(std.mem.indexOf(u8, txt, tmp_spill_path) == null);

    // The session-dir file exists and has the full content.
    var f = try std.Io.Dir.cwd().openFile(io, session_spill_path, .{});
    defer f.close(io);
    const len = try f.length(io);
    try testing.expect(len > 70 * 1024);

    // The /tmp fallback was NOT used.
    if (std.Io.Dir.cwd().openFile(io, tmp_spill_path, .{})) |bad_f| {
        var bf = bad_f;
        bf.close(io);
        try testing.expect(false); // /tmp file should not exist when session dir was set
    } else |_| {
        // Expected.
    }
}

test "bash tool: spill falls back to /tmp when state has no session dir (v1.27.2)" {
    // Mirror of the above but `setSessionDir` is never called —
    // SessionBashState reports no session dir. Spill must land at
    // `/tmp/franky-bash-<call_id>.log` (the v1.27.0 fallback).
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const call_id = "spill-session-fallback";
    const tmp_spill_path = "/tmp/franky-bash-" ++ call_id ++ ".log";
    std.Io.Dir.cwd().deleteFile(io, tmp_spill_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, tmp_spill_path) catch {};

    var state = SessionBashState.init(gpa);
    defer state.deinit();
    // No setSessionDir call.

    var cancel: ai.stream.Cancel = .{};
    const t = toolWithState(&state);
    const args =
        \\{"command":"i=1; while [ $i -le 4000 ]; do printf 'line%04d=padding%s\n' \"$i\" 'xxxxxxxxxxxxxxxxxxxx'; i=$((i+1)); done"}
    ;
    var res = try t.execute(&t, gpa, io, call_id, args, &cancel, .{});
    defer res.deinit(gpa);

    const txt = res.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, txt, tmp_spill_path) != null);

    var f = try std.Io.Dir.cwd().openFile(io, tmp_spill_path, .{});
    defer f.close(io);
    const len = try f.length(io);
    try testing.expect(len > 70 * 1024);
}

test "checkDir: returns .exists for existing directories" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    try testing.expect(checkDir(io, "/tmp") == .exists);
    try testing.expect(checkDir(io, "/") == .exists);
}

test "checkDir: returns .gone for non-existent paths" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    try testing.expect(checkDir(io, "/no/such/directory/ever") == .gone);
}

test "checkDir: returns .gone for regular files" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    // Create a temp file and verify checkDir returns .gone for it.
    const tmp_path = "/tmp/franky_test_checkDir_file";
    const f = std.Io.Dir.cwd().createFile(io, tmp_path, .{}) catch |err| {
        // If we cannot create the file (e.g. permissions), skip.
        if (err == error.AccessDenied) return error.SkipZigTest;
        return err;
    };
    f.close(io);
    defer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
    try testing.expect(checkDir(io, tmp_path) == .gone);
}

test "resolveCwd: null arg + null state returns null" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const result = try resolveCwd(io, null, null);
    try testing.expect(result == null);
}

test "resolveCwd: stale session cwd is cleared and returns null" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;
    var state = SessionBashState.init(gpa);
    defer state.deinit();
    // Set cwd to a non-existent path.
    try state.setCwd("/no/such/directory/ever");
    const result = try resolveCwd(io, null, &state);
    // Stale cwd is auto-cleared; returns null (inherit).
    try testing.expect(result == null);
    // State cwd should be cleared.
    try testing.expect(state.getCwd() == null);
}

test "resolveCwd: existing session cwd is preserved" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;
    var state = SessionBashState.init(gpa);
    defer state.deinit();
    try state.setCwd("/tmp");
    const result = try resolveCwd(io, null, &state);
    try testing.expect(result != null);
    try testing.expectEqualStrings("/tmp", result.?);
}

test "resolveCwd: explicit cwd pointing to non-existent dir returns error.CwdNotFound" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const result = resolveCwd(io, "/no/such/directory/ever", null);
    try testing.expectError(error.CwdNotFound, result);
}

test "resolveCwd: explicit cwd pointing to existing dir is returned" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const result = try resolveCwd(io, "/tmp", null);
    try testing.expect(result != null);
    try testing.expectEqualStrings("/tmp", result.?);
}

// ─── v0.30.0 session-env tests ────────────────────────────────────

/// Helper: build a minimal parent env map with PATH so the shell can run.
fn buildTestEnvMap(allocator: std.mem.Allocator) !std.process.Environ.Map {
    var m = std.process.Environ.Map.init(allocator);
    try m.put("PATH", "/usr/bin:/bin");
    try m.put("FRANKY_SESSION_ID", "stale-parent-value"); // scrubbed
    return m;
}

test "session env: injectSessionEnv sets FRANKY_* from state" {
    const gpa = testing.allocator;
    var env = try buildTestEnvMap(gpa);
    defer env.deinit();

    var state = SessionBashState.init(gpa);
    defer state.deinit();
    try state.setSessionMetadata("s1", "/tmp/s1/transcript.json", "anthropic", "claude-sonnet-4-5", .high);

    injectSessionEnv(&env, &state);

    try testing.expectEqualStrings("s1", env.get("FRANKY_SESSION_ID").?);
    try testing.expectEqualStrings("/tmp/s1/transcript.json", env.get("FRANKY_SESSION_FILE").?);
    try testing.expectEqualStrings("anthropic", env.get("FRANKY_PROVIDER").?);
    try testing.expectEqualStrings("claude-sonnet-4-5", env.get("FRANKY_MODEL").?);
    try testing.expectEqualStrings("high", env.get("FRANKY_REASONING_LEVEL").?);
}

test "session env: thinking .off omits FRANKY_REASONING_LEVEL" {
    const gpa = testing.allocator;
    var env = try buildTestEnvMap(gpa);
    defer env.deinit();

    var state = SessionBashState.init(gpa);
    defer state.deinit();
    try state.setSessionMetadata("s2", null, "openai", "gpt-4o", .off);

    injectSessionEnv(&env, &state);

    try testing.expectEqualStrings("s2", env.get("FRANKY_SESSION_ID").?);
    try testing.expect(env.get("FRANKY_SESSION_FILE") == null);
    try testing.expect(env.get("FRANKY_REASONING_LEVEL") == null);
}

test "session env: expose_session_environment=false scrubs inherited values" {
    const gpa = testing.allocator;
    var env = try buildTestEnvMap(gpa);
    defer env.deinit();

    var state = SessionBashState.init(gpa);
    defer state.deinit();
    state.expose_session_environment = false;
    try state.setSessionMetadata("s3", "/tmp/s3/transcript.json", "google-gemini", "gemini-pro", .medium);

    injectSessionEnv(&env, &state);

    // Even with metadata set, exposure disabled → all five scrubbed.
    try testing.expect(env.get("FRANKY_SESSION_ID") == null);
    try testing.expect(env.get("FRANKY_SESSION_FILE") == null);
    try testing.expect(env.get("FRANKY_PROVIDER") == null);
    try testing.expect(env.get("FRANKY_MODEL") == null);
    try testing.expect(env.get("FRANKY_REASONING_LEVEL") == null);
}

test "session env: null state still scrubs inherited FRANKY_* vars" {
    const gpa = testing.allocator;
    var env = try buildTestEnvMap(gpa);
    defer env.deinit();

    injectSessionEnv(&env, null);

    // The stale parent value must be gone.
    try testing.expect(env.get("FRANKY_SESSION_ID") == null);
    // Non-FRANKY vars are untouched.
    try testing.expect(env.get("PATH") != null);
}

test "session env: bash execute injects FRANKY_* into child env" {
    // End-to-end: a bash command run through toolWithState sees the
    // session metadata as env vars. Requires a parent_env on the state
    // so the child shell inherits PATH.
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var parent_env = try buildTestEnvMap(gpa);
    defer parent_env.deinit();

    var state = SessionBashState.init(gpa);
    defer state.deinit();
    state.parent_env = &parent_env;
    try state.setSessionMetadata("e2e-1", "/tmp/e2e/transcript.json", "anthropic", "claude-sonnet-4-5", .high);

    var cancel: ai.stream.Cancel = .{};
    const t = toolWithState(&state);
    const args =
        \\{"command":"printf '%s\n%s\n%s\n%s\n%s\n' \"$FRANKY_SESSION_ID\" \"$FRANKY_SESSION_FILE\" \"$FRANKY_PROVIDER\" \"$FRANKY_MODEL\" \"$FRANKY_REASONING_LEVEL\""}
    ;
    var res = try t.execute(&t, gpa, io, "e2e-1", args, &cancel, .{});
    defer res.deinit(gpa);

    const txt = res.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, txt, "e2e-1") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "/tmp/e2e/transcript.json") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "anthropic") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "claude-sonnet-4-5") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "high") != null);
    // The stale inherited value must NOT appear.
    try testing.expect(std.mem.indexOf(u8, txt, "stale-parent-value") == null);
}