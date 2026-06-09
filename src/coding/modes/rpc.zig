//! `--mode rpc` dispatcher — §I + §5.5.
//!
//! Reads JSON-RPC 2.0 frames (LSP Content-Length framing) from
//! stdin, dispatches to session methods, writes responses +
//! event notifications back to stdout.
//!
//! Supported methods:
//!   - `ping`                  → `{"pong":true}`
//!   - `version`               → `{"franky":"<ver>","role":"<r>","sandbox":<bool>}`
//!   - `role`                  → role + permitted tools + sandbox flag
//!   - `prompt({text})`        → runs one agent turn; streams each
//!     `AgentEvent` as a `event` notification (`method: "event"`)
//!     with the JSON payload from `agent.proxy.encodeEventJson`.
//!     Replies with `{"done":true}` when the turn ends.
//!   - `abort`                 → fires the cancel flag (best-effort;
//!     only interrupts between turns in this pass).
//!
//! The dispatcher is single-threaded — one request at a time, no
//! concurrent prompts. Mid-turn cancellation + streaming multiple
//! prompts requires an event channel with a background worker,
//! which is a v1.5 follow-up.

const std = @import("std");
const franky = @import("../../root.zig");
const ai = franky.ai;
const agent = franky.agent;
const at = agent.types;
const rpc = franky.coding.rpc;
const cli_mod = franky.coding.cli;
const config_mod = franky.coding.config.resolver;
const print_mode = @import("print.zig");
const tools_mod = franky.coding.tools;
const role_mod = franky.coding.role;
const permissions_mod = franky.coding.permissions;

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    environ_map: *std.process.Environ.Map,
    cfg: *cli_mod.Config,
) !void {
    const stdin = std.Io.File.stdin();
    const stdout = std.Io.File.stdout();

    // Session state shared across RPC calls. Init in-place
    // because the faux-provider pointer gets stored in the
    // registry as userdata — moving `session` by value after
    // init would leave a dangling pointer (same trap interactive
    // mode hit in v0.11.3).
    var session: Session = undefined;
    try initSession(&session, allocator, io, environ, environ_map, cfg);
    defer session.deinit();

    // Note: `--log-per-session` is a no-op in rpc mode. RPC mode
    // multiplexes virtual sessions through JSON-RPC `session.create`
    // — there is no single outer session id to route the log file
    // to. Use `--log-file <path>` to capture rpc logs.

    // Read frames in a loop.
    var read_buf: std.ArrayList(u8) = .empty;
    defer read_buf.deinit(allocator);
    var cursor: usize = 0;
    var scratch: [4096]u8 = undefined;

    while (true) {
        // Try to read a frame from the current buffer.
        const span = rpc.readFrame(read_buf.items, cursor) catch |err| {
            try writeErrorFrame(allocator, io, stdout, null, err);
            continue;
        };
        if (span) |s| {
            const body = read_buf.items[s.body_start..s.body_end];
            try dispatchOne(allocator, io, stdout, &session, body);
            cursor = s.body_end;
            // Compact if we've consumed a lot.
            if (cursor > 16 * 1024) {
                const remaining = read_buf.items[cursor..];
                std.mem.copyForwards(u8, read_buf.items[0..remaining.len], remaining);
                read_buf.items.len = remaining.len;
                cursor = 0;
            }
            continue;
        }
        // Need more bytes.
        const n = std.posix.read(stdin.handle, &scratch) catch |err| switch (err) {
            error.WouldBlock => 0,
            else => break,
        };
        if (n == 0) break; // EOF
        try read_buf.appendSlice(allocator, scratch[0..n]);
    }
}

const Session = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    resolved: *config_mod.ResolvedConfig,
    registry: *ai.registry.Registry,
    faux: *ai.providers.faux.FauxProvider,
    provider: print_mode.ProviderInfo,
    tools: []const at.AgentTool,
    role_arena: std.heap.ArenaAllocator,
    role_gate: *role_mod.RoleGate,
    permission_store: *permissions_mod.Store,
    session_gates: permissions_mod.SessionGates = .{},
    /// v1.11.3 — set during `runPrompt` so the dispatcher's
    /// `permission/resolve` arm can find the live prompter. Null
    /// outside a prompt; resolve calls then return a "no
    /// pending prompt" error.
    current_prompter: ?*permissions_mod.PermissionPrompter = null,
    /// v1.11.3 — guard against `prompt` re-entry while a prompt
    /// is already running. The drain loop interleaves stdin reads
    /// to pick up `permission/resolve`/`abort`; rejecting nested
    /// `prompt` keeps the worker count bounded.
    in_prompt: bool = false,
    system_prompt: []u8,
    transcript: agent.loop.Transcript,
    cfg: *cli_mod.Config,
    environ_map: *std.process.Environ.Map,
    cancel: ai.stream.Cancel = .{},
    /// v1.19.0 — resolved per-tool-prompt toggle. CLI `--prompts`
    /// wins; otherwise honors settings.json `prompts: bool`.
    prompts_enabled: bool = false,
    /// v1.27.3 — bash-tool session state. RPC mode doesn't persist
    /// transcripts to disk, but it can still spill bash output to
    /// `<FRANKY_HOME>/sessions/rpc-<pid>-<startup_ms>/bash/<call_id>.log`
    /// when `FRANKY_HOME`/`HOME` is set. Falls back to `/tmp` when
    /// neither env var is set. Address stable for the rpc process's
    /// lifetime — referenced by `bash.toolWithState`.
    bash_state: *tools_mod.bash.SessionBashState,
    web_search_ctx: tools_mod.web_search.WebSearchCtx = .{},
    guardrail_state: *agent.guardrails.GuardrailState,

    fn deinit(self: *Session) void {
        self.transcript.deinit();
        self.allocator.free(self.system_prompt);
        self.role_arena.deinit();
        // v2.22 Phase 3 — resolved owns registry, faux, bash_state,
        // guardrail_state, permission_store, role_gate, tools, etc.
        self.resolved.deinit();
    }
};

fn initSession(
    session: *Session,
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    environ_map: *std.process.Environ.Map,
    cfg: *cli_mod.Config,
) !void {
    // ── Step 1: Unified config resolution ─────────────────────
    // v2.22 Phase 3 — call the shared config resolver instead of
    // duplicating settings loading, registry setup, tool building,
    // permission store, preset registry, guardrails, etc. inline.
    const resolved = try allocator.create(config_mod.ResolvedConfig);
    errdefer allocator.destroy(resolved);
    resolved.* = try config_mod.resolve(allocator, io, cfg, environ, environ_map, &.{});

    // ── Step 2: RPC-specific role arena ───────────────────────
    var role_arena = std.heap.ArenaAllocator.init(allocator);
    errdefer role_arena.deinit();

    // ── Step 3: Build session from resolved config ────────────
    session.* = .{
        .allocator = allocator,
        .io = io,
        .resolved = resolved,
        .registry = &resolved.registry,
        .faux = resolved.faux_provider,
        .provider = .{
            .provider_name = resolved.provider_name,
            .api_tag = resolved.api_tag,
            .model_id = resolved.model_id,
            .api_key = resolved.api_key,
            .auth_token = resolved.auth_token,
            .base_url = resolved.base_url,
            .context_window = resolved.context_window,
            .max_output = resolved.max_output,
            .capabilities = resolved.capabilities,
        },
        .tools = resolved.tools,
        .role_arena = role_arena,
        .role_gate = resolved.role_gate,
        .permission_store = resolved.permission_store,
        .system_prompt = undefined,
        .transcript = agent.loop.Transcript.init(allocator),
        .cfg = cfg,
        .environ_map = environ_map,
        .prompts_enabled = resolved.prompts_enabled,
        .bash_state = resolved.bash_state,
        .guardrail_state = resolved.guardrail_state,
    };
    session.web_search_ctx = .{ .environ_map = session.environ_map };
    session.session_gates = .{
        .role = session.role_gate,
        .permissions = if (session.prompts_enabled) session.permission_store else null,
    };

    // ── Step 4: RPC-specific bash session dir ─────────────────
    // v1.27.3 — synthesize a process-scoped session dir for bash spills.
    {
        const home_root = if (environ.getPosix("FRANKY_HOME")) |h|
            try std.fs.path.join(allocator, &.{ h, "sessions" })
        else if (environ.getPosix("HOME")) |h|
            try std.fs.path.join(allocator, &.{ h, ".franky", "sessions" })
        else
            null;
        if (home_root) |hr| {
            defer allocator.free(hr);
            const startup_ms: i64 = ai.stream.nowMillis();
            const rpc_id = try std.fmt.allocPrint(allocator, "rpc-{d}", .{startup_ms});
            defer allocator.free(rpc_id);
            const sd = try std.fs.path.join(allocator, &.{ hr, rpc_id });
            defer allocator.free(sd);
            session.bash_state.setSessionDir(sd) catch {};
        }
    }

    // ── Step 5: Subagent ctx + preset_registry ────────────────
    // v1.24.0 — append subagent + list_subagent_presets tools.
    {
        const ra = role_arena.allocator();

        const params_json = try tools_mod.subagent.buildParametersJson(ra, &resolved.preset_registry);

        const subagent_ctx = try ra.create(tools_mod.subagent.Ctx);
        const parent_session_dir: ?[]const u8 = if (session.bash_state.getSessionDir()) |sd|
            try ra.dupe(u8, sd)
        else
            null;
        subagent_ctx.* = .{
            .registry = session.registry,
            .environ = environ,
            .environ_map = environ_map,
            .parent_tools = session.tools,
            .parent_role = session.role_gate.role,
            .parent_profile = cfg.profile orelse "",
            .presets = &resolved.preset_registry,
            .parameters_json_owned = params_json,
            .permission_store = if (session.prompts_enabled) session.permission_store else null,
            .permission_prompter_slot = &session.current_prompter,
            .parent_session_dir = parent_session_dir,
            // §6.6 — forward sub-agent events as JSON-RPC `event` notifications.
            .progress_fn = subagentProgressForward,
            .progress_userdata = session,
        };
        const final_tools = try ra.alloc(at.AgentTool, session.tools.len + 2);
        @memcpy(final_tools[0..session.tools.len], session.tools);
        final_tools[session.tools.len] = tools_mod.subagent.toolWithCtx(subagent_ctx);
        final_tools[session.tools.len + 1] = tools_mod.subagent.listPresetsToolWithCtx(&resolved.preset_registry);
        session.tools = final_tools;
    }

    session.system_prompt = try print_mode.buildSystemPromptIo(allocator, io, environ, cfg);
}

fn fauxShim(ctx: ai.registry.StreamCtx) anyerror!void {
    const fp: *ai.providers.faux.FauxProvider = @ptrCast(@alignCast(ctx.userdata.?));
    try fp.runSync(ctx.io, ctx.context, ctx.out);
}

// ─── §6.6 — sub-agent progress forwarding ────────────────────────
//
// Called from the sub-agent's worker thread. Encodes a
// `tool_execution_update` event and emits it as a JSON-RPC
// `event` notification on stdout (matching the pattern the
// `runPrompt` drain loop uses for every other event).
fn subagentProgressForward(
    userdata: ?*anyopaque,
    call_id: []const u8,
    update_json: []const u8,
) void {
    const session: *Session = @ptrCast(@alignCast(userdata.?));
    const allocator = session.allocator;
    const io = session.io;

    const owned_call_id = allocator.dupe(u8, call_id) catch return;
    const owned_update = allocator.dupe(u8, update_json) catch {
        allocator.free(owned_call_id);
        return;
    };
    const ev: at.AgentEvent = .{ .tool_execution_update = .{
        .call_id = owned_call_id,
        .update_json = owned_update,
    } };
    defer ev.deinit(allocator);

    const payload = agent.proxy.encodeEventJson(allocator, ev) catch return;
    defer allocator.free(payload);

    const notif = std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"method\":\"event\",\"params\":{s}}}",
        .{payload},
    ) catch return;
    defer allocator.free(notif);

    writeFrameToStdout(io, std.Io.File.stdout(), notif) catch {};
}

fn dispatchOne(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: std.Io.File,
    session: *Session,
    body: []const u8,
) !void {
    var req = rpc.parseRequest(allocator, body) catch |err| {
        try writeErrorFrame(allocator, io, stdout, null, err);
        return;
    };
    defer rpc.freeRequest(allocator, &req);

    if (std.mem.eql(u8, req.method, "ping")) {
        try writeResultFrame(allocator, io, stdout, req.id, "{\"pong\":true}");
        return;
    }
    if (std.mem.eql(u8, req.method, "version")) {
        const sandboxed = role_mod.detectSandboxFromMap(session.environ_map);
        const payload = try std.fmt.allocPrint(
            allocator,
            "{{\"franky\":\"{s}\",\"role\":\"{s}\",\"sandbox\":{s}}}",
            .{ franky.version, session.role_gate.role.toString(), if (sandboxed) "true" else "false" },
        );
        defer allocator.free(payload);
        try writeResultFrame(allocator, io, stdout, req.id, payload);
        return;
    }
    if (std.mem.eql(u8, req.method, "role")) {
        try writeRoleResult(allocator, io, stdout, session, req.id);
        return;
    }
    if (std.mem.eql(u8, req.method, "abort")) {
        session.cancel.fire();
        try writeResultFrame(allocator, io, stdout, req.id, "{\"aborted\":true}");
        return;
    }
    if (std.mem.eql(u8, req.method, "permission/resolve")) {
        try handleResolve(allocator, io, stdout, session, req);
        return;
    }
    if (std.mem.eql(u8, req.method, "prompt")) {
        if (session.in_prompt) {
            try writeErrorFrame(allocator, io, stdout, req.id, error.PromptInFlight);
            return;
        }
        try runPrompt(allocator, io, stdout, session, req);
        return;
    }
    try writeErrorFrame(allocator, io, stdout, req.id, error.UnknownMethod);
}

/// In-prompt frame dispatcher — used by `runPrompt`'s inline
/// stdin pump. Only `permission/resolve`, `abort`, and `ping` make
/// sense while a prompt is in flight; everything else (notably
/// nested `prompt`) gets rejected with `error.PromptInFlight`.
///
/// This is a dedicated function rather than a re-entrant call to
/// `dispatchOne` because Zig 0.16 rejects the inferred-error-set
/// cycle (`dispatchOne` → `runPrompt` → `dispatchOne`). Restricting
/// the mid-prompt surface is also a real safety win — a nested
/// `prompt` would spawn a second worker, and `version`/`role`
/// answers don't change mid-turn.
fn dispatchInPromptFrame(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: std.Io.File,
    session: *Session,
    body: []const u8,
) !void {
    var req = rpc.parseRequest(allocator, body) catch |err| {
        try writeErrorFrame(allocator, io, stdout, null, err);
        return;
    };
    defer rpc.freeRequest(allocator, &req);

    if (std.mem.eql(u8, req.method, "permission/resolve")) {
        try handleResolve(allocator, io, stdout, session, req);
        return;
    }
    if (std.mem.eql(u8, req.method, "abort")) {
        session.cancel.fire();
        try writeResultFrame(allocator, io, stdout, req.id, "{\"aborted\":true}");
        return;
    }
    if (std.mem.eql(u8, req.method, "ping")) {
        try writeResultFrame(allocator, io, stdout, req.id, "{\"pong\":true}");
        return;
    }
    try writeErrorFrame(allocator, io, stdout, req.id, error.PromptInFlight);
}

/// `permission/resolve({call_id, resolution})` — wakes the worker
/// thread suspended inside `before_tool_call` (§5.11). Valid only
/// while a prompt is in flight; replies with an error otherwise.
fn handleResolve(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: std.Io.File,
    session: *Session,
    req: rpc.Request,
) !void {
    const prompter = session.current_prompter orelse {
        try writeErrorFrame(allocator, io, stdout, req.id, error.NoPendingPrompt);
        return;
    };
    const params = req.params_raw orelse {
        try writeErrorFrame(allocator, io, stdout, req.id, error.InvalidParams);
        return;
    };
    const call_id = extractStringField(params, "call_id") orelse {
        try writeErrorFrame(allocator, io, stdout, req.id, error.InvalidParams);
        return;
    };
    const resolution_str = extractStringField(params, "resolution") orelse {
        try writeErrorFrame(allocator, io, stdout, req.id, error.InvalidParams);
        return;
    };
    const resolution = permissions_mod.Resolution.fromString(resolution_str) orelse {
        try writeErrorFrame(allocator, io, stdout, req.id, error.InvalidParams);
        return;
    };
    prompter.resolve(call_id, resolution) catch {
        // The only error `resolve` returns is `error.NotPending`
        // (call_id no longer in the pending map — usually because
        // the worker already moved on / the prompter was torn
        // down). Surface it to the client either way.
        try writeErrorFrame(allocator, io, stdout, req.id, error.NotPending);
        return;
    };
    try writeResultFrame(allocator, io, stdout, req.id, "{\"ok\":true}");
}

/// Tiny ad-hoc string-field extractor for the resolve handler's
/// JSON params. Mirrors `extractPromptText` below — we don't pull
/// in a full parser for two-field bodies.
fn extractStringField(json: []const u8, field: []const u8) ?[]const u8 {
    var search_buf: [64]u8 = undefined;
    if (field.len + 2 > search_buf.len) return null;
    var i: usize = 0;
    search_buf[i] = '"';
    i += 1;
    @memcpy(search_buf[i .. i + field.len], field);
    i += field.len;
    search_buf[i] = '"';
    i += 1;
    const key = search_buf[0..i];
    const k = std.mem.indexOf(u8, json, key) orelse return null;
    var p = k + key.len;
    while (p < json.len and (json[p] == ' ' or json[p] == ':' or json[p] == '\t')) : (p += 1) {}
    if (p >= json.len or json[p] != '"') return null;
    p += 1;
    const start = p;
    while (p < json.len) : (p += 1) {
        if (json[p] == '\\') {
            p += 1;
            continue;
        }
        if (json[p] == '"') return json[start..p];
    }
    return null;
}

fn runPrompt(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: std.Io.File,
    session: *Session,
    req: rpc.Request,
) !void {
    const text = extractPromptText(req.params_raw) orelse {
        try writeErrorFrame(allocator, io, stdout, req.id, error.InvalidParams);
        return;
    };

    // Append user message to transcript.
    const content = try allocator.alloc(ai.types.ContentBlock, 1);
    content[0] = .{ .text = .{ .text = try allocator.dupe(u8, text) } };
    try session.transcript.append(.{
        .role = .user,
        .content = content,
        .timestamp = ai.stream.nowMillis(),
    });

    // Seed faux if needed. Both `reply` and `faux_events` MUST live
    // at function scope — the faux provider stores the event slice by
    // reference and the worker thread reads it asynchronously. If we
    // scoped them to an `if` block, `defer free(reply)` would fire on
    // block exit and the stack slot would be reused before the worker
    // reads it, producing 0xAA poison bytes downstream. See print.zig
    // for the same pattern.
    const faux_reply: ?[]u8 = if (std.mem.eql(u8, session.provider.provider_name, "faux"))
        try std.fmt.allocPrint(allocator, "you said: {s}", .{text})
    else
        null;
    defer if (faux_reply) |r| allocator.free(r);

    var faux_events: [1]ai.providers.faux.Event = undefined;
    if (faux_reply) |r| {
        faux_events[0] = .{ .text = .{ .text = r, .chunk_size = 8 } };
        try session.faux.push(.{ .events = faux_events[0..] });
    }

    // Run the loop; stream events as notifications.
    var ch = try agent.loop.AgentChannel.initWithDrop(allocator, 16384, at.AgentEvent.deinit, allocator);
    defer ch.deinit();

    // v1.11.3 — per-turn prompter so the worker can suspend on
    // `ask`. The dispatcher's `permission/resolve` arm reads
    // `session.current_prompter` to wake it.
    var prompter = permissions_mod.PermissionPrompter.init(allocator, io, &ch);
    defer prompter.deinit();
    if (session.prompts_enabled) {
        session.session_gates.prompter = &prompter;
    }
    defer session.session_gates.prompter = null;
    session.current_prompter = &prompter;
    defer session.current_prompter = null;
    session.in_prompt = true;
    defer session.in_prompt = false;

    session.cancel = .{}; // reset per-prompt

    // §6.10 — extend tools with finish_task guardrail tool.
    {
        const tools_with_guardrail = try allocator.alloc(at.AgentTool, session.tools.len + 1);
        @memcpy(tools_with_guardrail[0..session.tools.len], session.tools);
        tools_with_guardrail[session.tools.len] = session.guardrail_state.finishTaskTool();
        session.tools = tools_with_guardrail;
    }

    const worker_args: WorkerArgs = .{
        .allocator = allocator,
        .io = io,
        .transcript = &session.transcript,
        .config = .{
            .model = .{
                .id = session.provider.model_id,
                .provider = session.provider.provider_name,
                .api = session.provider.api_tag,
                .context_window = session.provider.context_window,
                .max_output = session.provider.max_output,
                .capabilities = session.provider.capabilities,
            },
            .system_prompt = session.system_prompt,
            .tools = session.tools,
            .registry = session.registry,
            .cancel = &session.cancel,
            .hook_userdata = @ptrCast(&session.session_gates),
            .guardrails = session.guardrail_state,
            .role_denied = permissions_mod.SessionGates.roleDenied,
            .before_tool_call = permissions_mod.SessionGates.beforeToolCall,
            .text_tool_call_fallback = session.cfg.text_tool_call_fallback,
            .nudge_on_autocontinue = session.cfg.autocontinue,
            .max_turns = print_mode.resolveMaxTurnsFromMap(session.cfg, session.environ_map) orelse @as(u32, 100),
            .stream_options = .{
                .api_key = session.provider.api_key,
                .auth_token = session.provider.auth_token,
                .base_url = session.provider.base_url,
                .environ_map = session.environ_map,
                .thinking = session.cfg.thinking,
                .timeouts = print_mode.resolveTimeoutsFromMap(session.cfg, session.environ_map),
                .retry_policy = print_mode.resolveRetryPolicyFromMap(session.cfg, null),
                .http_trace_dir = print_mode.resolveHttpTraceDirFromMap(session.cfg, session.environ_map),
            },
        },
        .ch = &ch,
    };
    const worker = try std.Thread.spawn(.{}, workerMain, .{worker_args});
    defer worker.join();

    // v1.11.3 — interleave channel + stdin so a client can send
    // `permission/resolve` (or `abort`) while the worker is
    // suspended on a permission prompt. Outer-loop blocking on
    // stdin would deadlock — the user can't unblock a prompt if
    // we never read their reply.
    const stdin = std.Io.File.stdin();
    var inflight: std.ArrayList(u8) = .empty;
    defer inflight.deinit(allocator);
    var inflight_cursor: usize = 0;
    var scratch: [4096]u8 = undefined;

    drain: while (true) {
        switch (ch.tryNext(io)) {
            .closed => break :drain,
            .event => |ev| {
                const payload = agent.proxy.encodeEventJson(allocator, ev) catch {
                    ev.deinit(allocator);
                    continue;
                };
                defer allocator.free(payload);
                const notif = std.fmt.allocPrint(
                    allocator,
                    "{{\"jsonrpc\":\"2.0\",\"method\":\"event\",\"params\":{s}}}",
                    .{payload},
                ) catch {
                    ev.deinit(allocator);
                    continue;
                };
                defer allocator.free(notif);
                writeFrameToStdout(io, stdout, notif) catch {};
                ev.deinit(allocator);
            },
            .empty => {
                // Non-blocking stdin pump.
                const n = std.posix.read(stdin.handle, &scratch) catch |err| switch (err) {
                    error.WouldBlock => 0,
                    else => 0,
                };
                if (n > 0) try inflight.appendSlice(allocator, scratch[0..n]);
                while (true) {
                    const span = rpc.readFrame(inflight.items, inflight_cursor) catch break;
                    if (span) |s| {
                        const body = inflight.items[s.body_start..s.body_end];
                        try dispatchInPromptFrame(allocator, io, stdout, session, body);
                        inflight_cursor = s.body_end;
                        if (inflight_cursor > 16 * 1024) {
                            const remaining = inflight.items[inflight_cursor..];
                            std.mem.copyForwards(u8, inflight.items[0..remaining.len], remaining);
                            inflight.items.len = remaining.len;
                            inflight_cursor = 0;
                        }
                    } else break;
                }
                io.sleep(.fromMilliseconds(5), .awake) catch {};
            },
        }
    }

    try writeResultFrame(allocator, io, stdout, req.id, "{\"done\":true}");
}

const WorkerArgs = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    transcript: *agent.loop.Transcript,
    config: agent.loop.Config,
    ch: *agent.loop.AgentChannel,
};

fn workerMain(args: WorkerArgs) void {
    agent.loop.agentLoop(args.allocator, args.io, args.transcript, args.config, args.ch);
}

fn extractPromptText(params: ?[]const u8) ?[]const u8 {
    if (params == null) return null;
    // Minimal parse: look for `"text":"..."` in the params blob.
    const haystack = params.?;
    const key = "\"text\":\"";
    const start = std.mem.indexOf(u8, haystack, key) orelse return null;
    const val_start = start + key.len;
    const val_end = std.mem.indexOfScalarPos(u8, haystack, val_start, '"') orelse return null;
    return haystack[val_start..val_end];
}

// ─── frame writers ──────────────────────────────────────────────

/// `role` JSON-RPC method — exposes the bound role + tool list +
/// sandbox detection so RPC clients can render a status pill
/// without inferring it from `tool_execution_end`'s `role_denied`.
fn writeRoleResult(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: std.Io.File,
    session: *Session,
    id: ?rpc.Id,
) !void {
    const sandboxed = role_mod.detectSandboxFromMap(session.environ_map);
    const body = try role_mod.renderRoleStatusJson(
        allocator,
        session.role_gate.role,
        session.role_gate.set,
        sandboxed,
        session.provider.provider_name,
        session.provider.model_id,
        &.{},
    );
    defer allocator.free(body);
    try writeResultFrame(allocator, io, stdout, id, body);
}

fn writeResultFrame(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: std.Io.File,
    id: ?rpc.Id,
    result_json: []const u8,
) !void {
    const body = switch (id orelse rpc.Id{ .string = "" }) {
        .string => |s| try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":\"{s}\",\"result\":{s}}}", .{ s, result_json }),
        .number => |n| try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{s}}}", .{ n, result_json }),
    };
    defer allocator.free(body);
    try writeFrameToStdout(io, stdout, body);
}

fn writeErrorFrame(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: std.Io.File,
    id: ?rpc.Id,
    err: anyerror,
) !void {
    const msg = @errorName(err);
    const body = switch (id orelse rpc.Id{ .string = "" }) {
        .string => |s| try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":\"{s}\",\"error\":{{\"code\":-32603,\"message\":\"{s}\"}}}}", .{ s, msg }),
        .number => |n| try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":{{\"code\":-32603,\"message\":\"{s}\"}}}}", .{ n, msg }),
    };
    defer allocator.free(body);
    try writeFrameToStdout(io, stdout, body);
}

fn writeFrameToStdout(io: std.Io, stdout: std.Io.File, body: []const u8) !void {
    // LSP framing: "Content-Length: N\r\n\r\n<body>".
    //
    // Use writeStreamingAll here — we explicitly want append-to-stream
    // semantics. A fresh `std.Io.File.Writer` per call tracks a file
    // position starting at 0, which on pipes causes every frame to
    // stomp on the previous one at offset 0 and the shortest (final
    // "result") frame overwrites preceding event frames. Same trap
    // interactive mode hit with writeAllFd on macOS.
    var hdr_buf: [64]u8 = undefined;
    const hdr = std.fmt.bufPrint(&hdr_buf, "Content-Length: {d}\r\n\r\n", .{body.len}) catch unreachable;
    stdout.writeStreamingAll(io, hdr) catch {};
    stdout.writeStreamingAll(io, body) catch {};
}

// ─── tests ──────────────────────────────────────────────────────

const testing = std.testing;

test "extractPromptText: finds text field in params" {
    const p = "{\"text\":\"hello world\"}";
    try testing.expectEqualStrings("hello world", extractPromptText(p).?);
}

test "extractPromptText: missing field → null" {
    try testing.expect(extractPromptText("{\"other\":\"x\"}") == null);
    try testing.expect(extractPromptText(null) == null);
}

test "extractStringField: pulls call_id + resolution from resolve params" {
    const body = "{\"call_id\":\"c-42\",\"resolution\":\"allow_once\"}";
    try testing.expectEqualStrings("c-42", extractStringField(body, "call_id").?);
    try testing.expectEqualStrings("allow_once", extractStringField(body, "resolution").?);
}

test "extractStringField: missing field → null" {
    try testing.expect(extractStringField("{}", "call_id") == null);
    try testing.expect(extractStringField("{\"other\":1}", "call_id") == null);
}

test "extractStringField: tolerates whitespace + extra fields" {
    const body = "{ \"call_id\" :  \"c-1\" , \"resolution\":\"deny_once\", \"x\":1 }";
    try testing.expectEqualStrings("c-1", extractStringField(body, "call_id").?);
    try testing.expectEqualStrings("deny_once", extractStringField(body, "resolution").?);
}

test "extractStringField: ignores escaped quote inside string" {
    const body = "{\"call_id\":\"c\\\"x\"}";
    // The extractor doesn't unescape; it just walks past `\"`.
    try testing.expectEqualStrings("c\\\"x", extractStringField(body, "call_id").?);
}
