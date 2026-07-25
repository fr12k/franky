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
const print_mode = @import("print.zig");
const tools_mod = franky.coding.tools;
const role_mod = franky.coding.role;
const permissions_mod = franky.coding.permissions;
const compression_mod = franky.coding.compression;

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
    registry: ai.registry.Registry,
    faux: ai.providers.faux.FauxProvider,
    provider: print_mode.ProviderInfo,
    tools: []const at.AgentTool,
    role_arena: std.heap.ArenaAllocator,
    role_gate: role_mod.RoleGate,
    permission_store: permissions_mod.Store,
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
    /// v0.30.0 — process-scoped session id (e.g. `rpc-<ms>`) used for
    /// bash spill dir + `FRANKY_SESSION_ID` env injection. Owned by the
    /// session arena; empty when `FRANKY_HOME`/`HOME` is unset.
    session_id: []const u8 = "",
    /// v1.19.0 — resolved per-tool-prompt toggle. CLI `--prompts`
    /// wins; otherwise honors settings.json `prompts: bool`.
    prompts_enabled: bool = false,
    /// v1.27.3 — bash-tool session state. RPC mode doesn't persist
    /// transcripts to disk, but it can still spill bash output to
    /// `<FRANKY_HOME>/sessions/rpc-<pid>-<startup_ms>/bash/<call_id>.log`
    /// when `FRANKY_HOME`/`HOME` is set. Falls back to `/tmp` when
    /// neither env var is set. Address stable for the rpc process's
    /// lifetime — referenced by `bash.toolWithState`.
    bash_state: tools_mod.bash.SessionBashState,
    web_search_ctx: tools_mod.web_search.WebSearchCtx = .{},
    /// §6.10 — harness-enforced guardrails (stuck detection, compilation guard,
    /// finish_task). Wired at session init; passed to loop.Config in runPrompt.
    guardrail_state: agent.guardrails.GuardrailState = undefined,
    /// v3.0 — session-scoped CCR store for reversible compression.
    ccr_store: compression_mod.CcrSessionStore = undefined,
    /// v3.0 — compression statistics.
    compression_stats: compression_mod.CompressionStats = .{},
    /// v3.0 — CCR context bundling store + stats for ccr_retrieve tool.
    ccr_ctx: compression_mod.CcrContext = undefined,

    fn deinit(self: *Session) void {
        self.transcript.deinit();
        self.allocator.free(self.system_prompt);
        self.bash_state.deinit();
        self.guardrail_state.deinit();
        self.ccr_store.deinit();
        self.registry.deinit();
        self.faux.deinit();
        self.permission_store.deinit();
        self.role_arena.deinit();
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
    const active_role = if (cfg.role) |s|
        role_mod.Role.fromString(s) catch |err| switch (err) {
            error.UnknownRole => return print_mode.exitWithMessage(io, "unknown --role; pick one of read, plan, code, full\n", 2),
        }
    else
        role_mod.Role.plan;
    const role_gate = role_mod.RoleGate.init(active_role);
    var role_arena = std.heap.ArenaAllocator.init(allocator);
    errdefer role_arena.deinit();
    const all_tools = [_]at.AgentTool{
        tools_mod.read.tool(),
        tools_mod.write.tool(),
        tools_mod.edit.tool(),
        tools_mod.bash.tool(),
        tools_mod.ls.tool(),
        tools_mod.find.tool(),
        tools_mod.grep.tool(),
        tools_mod.web_search.tool(),
        tools_mod.web_fetch.tool(),
    };
    const filtered = try role_mod.filterTools(role_arena.allocator(), &all_tools, role_gate.set);
    // v1.24.0 — subagent wiring deferred until after permission_store
    // is built (we need its address). See the `final_tools` block below.

    var permission_store = permissions_mod.Store.init(allocator);
    errdefer permission_store.deinit();
    var prompts_enabled: bool = cfg.prompts;
    // v1.19.0 — settings-layer overlay first; CLI overlay below.
    {
        var settings = try print_mode.loadSettingsForOverlay(allocator, io, environ);
        defer settings.deinit();
        try print_mode.applyPermissionsSettingsOverlay(&permission_store, &settings);
        prompts_enabled = print_mode.resolvePromptsDefault(cfg, &settings);
        print_mode.applyMaxTurnsSettingsOverlay(cfg, &settings);

        // v2.16 — pre-render the review config block for system-prompt injection.
        // Only populate when profiles are configured so the block is non-empty.
        if (settings.review_profiles.len > 0) {
            const ca = cfg.arena.allocator();
            // Build a comma-separated profile list for readability.
            var pb: std.ArrayList(u8) = .empty;
            defer pb.deinit(ca);
            for (settings.review_profiles, 0..) |p, i| {
                if (i > 0) try pb.appendSlice(ca, ", ");
                try pb.appendSlice(ca, p);
            }
            const profiles_csv = try pb.toOwnedSlice(ca);
            defer ca.free(profiles_csv);
            cfg.review_config_block = try std.fmt.allocPrint(
                ca,
                "## Review configuration\n" ++
                    "profiles: {s}\n" ++
                    "min_models: {d}\n" ++
                    "max_models: {d}\n" ++
                    "timeout_ms: {d}",
                .{
                    profiles_csv,
                    settings.review_min_models,
                    settings.review_max_models,
                    settings.review_timeout_ms,
                },
            );
        }
    }
    if (cfg.yes) permission_store.yes_to_all = true;
    if (cfg.allow_tools_csv) |s| try permission_store.addAllowList(s);
    if (cfg.deny_tools_csv) |s| try permission_store.addDenyList(s);
    if (cfg.ask_tools_csv) |s| try permission_store.addAskList(s);
    try permissions_mod.maybeAttachPersistence(
        &permission_store,
        cfg.remember_permissions,
        cfg.arena.allocator(),
        io,
        environ_map,
    );

    session.* = .{
        .allocator = allocator,
        .io = io,
        .registry = ai.registry.Registry.init(allocator),
        .faux = ai.providers.faux.FauxProvider.init(allocator),
        .provider = undefined,
        .tools = filtered,
        .role_arena = role_arena,
        .role_gate = role_gate,
        .permission_store = permission_store,
        .system_prompt = undefined,
        .transcript = agent.loop.Transcript.init(allocator),
        .cfg = cfg,
        .environ_map = environ_map,
        .prompts_enabled = prompts_enabled,
        .bash_state = tools_mod.bash.SessionBashState.init(allocator),
        .ccr_store = compression_mod.CcrSessionStore.init(allocator),
    };
    session.ccr_ctx = .{ .store = &session.ccr_store, .stats = &session.compression_stats };
    session.web_search_ctx = .{ .environ_map = session.environ_map };
    session.session_gates = .{
        .role = &session.role_gate,
        .permissions = if (session.prompts_enabled) &session.permission_store else null,
    };
    errdefer session.registry.deinit();
    errdefer session.faux.deinit();
    errdefer session.bash_state.deinit();

    // v1.27.3 — synthesize a process-scoped session dir for bash
    // spills. RPC has no on-disk transcript persistence (matching
    // the v1 spec note about virtual-session multiplexing), but
    // bash captures still want a discoverable home that isn't /tmp.
    // Layout: `<FRANKY_HOME or $HOME/.franky>/sessions/rpc-<pid>-<unix_ms>/bash/<call_id>.log`.
    // Best-effort — if neither env var is set, the spill writer
    // falls back to /tmp via its own gate, matching v1.27.0
    // behavior. The dir lives until manually cleaned (or until a
    // future `--gc-sessions` reaps it); RPC processes are
    // long-lived so leaving the dir around per-run is fine.
    {
        const home_root = if (environ.getPosix("FRANKY_HOME")) |h|
            try std.fs.path.join(allocator, &.{ h, "sessions" })
        else if (environ.getPosix("HOME")) |h|
            try std.fs.path.join(allocator, &.{ h, ".franky", "sessions" })
        else
            null;
        if (home_root) |hr| {
            defer allocator.free(hr);
            // Process-scoped id from the startup timestamp. Two rpc
            // processes started in the same millisecond would collide,
            // but that's vanishingly rare and the worst-case symptom is
            // a shared spill dir — not corruption.
            const startup_ms: i64 = ai.stream.nowMillis();
            const rpc_id = try std.fmt.allocPrint(allocator, "rpc-{d}", .{startup_ms});
            defer allocator.free(rpc_id);
            const sd = try std.fs.path.join(allocator, &.{ hr, rpc_id });
            defer allocator.free(sd);
            session.bash_state.setSessionDir(sd) catch {};
            // v0.30.0 — keep the rpc id for env injection once the provider
            // is resolved below.
            session.session_id = try session.role_arena.allocator().dupe(u8, rpc_id);
        }
    }

    // v1.27.3 — rebuild the filtered tool list with `bash.toolWithState`
    // now that `&session.bash_state` is at a stable address. Same
    // pattern as proxy.zig.
    {
        const all_tools_with_state = [_]at.AgentTool{
            tools_mod.read.tool(),
            tools_mod.write.tool(),
            tools_mod.edit.tool(),
            tools_mod.bash.toolWithState(&session.bash_state),
            tools_mod.ls.tool(),
            tools_mod.find.tool(),
            tools_mod.grep.tool(),
            tools_mod.web_search.toolWithCtx(&session.web_search_ctx),
            tools_mod.web_fetch.toolWithCtx(&session.web_search_ctx),
        };
        session.tools = try role_mod.filterTools(session.role_arena.allocator(), &all_tools_with_state, session.role_gate.set);
    }

    // §6.10 — harness-enforced guardrails (stuck detection, compilation guard, finish_task).
    session.guardrail_state = try agent.guardrails.GuardrailState.init(
        allocator,
        .{ .workspace_dir = environ.getPosix("PWD") orelse "." },
        io,
    );
    errdefer session.guardrail_state.deinit();
    session.guardrail_state.setupAutoCommitBranch(allocator, io);

    session.provider = try print_mode.resolveProviderIo(allocator, io, environ, cfg);

    // v0.30.0 — expose session metadata to the bash tool's child env.
    // Provider/model are only known after `resolveProviderIo`; the session
    // id was minted above. Rpc sessions have no transcript file.
    session.bash_state.parent_env = session.environ_map;
    session.bash_state.setSessionMetadata(
        session.session_id,
        null,
        session.provider.provider_name,
        session.provider.model_id,
        session.cfg.thinking,
    ) catch {};

    try session.registry.register(.{
        .api = "faux",
        .provider = "faux",
        .stream_fn = fauxShim,
        .userdata = @ptrCast(&session.faux),
    });
    try session.registry.register(.{
        .api = "anthropic-messages",
        .provider = "anthropic",
        .stream_fn = ai.providers.anthropic.streamFn,
    });
    try session.registry.register(.{
        .api = "openai-chat-completions",
        .provider = "openai",
        .stream_fn = ai.providers.openai_chat.streamFn,
    });
    try session.registry.register(.{
        .api = "openai-compatible-gateway",
        .provider = "gateway",
        .stream_fn = ai.providers.openai_gateway.streamFn,
    });
    try session.registry.register(.{
        .api = "google-gemini",
        .provider = "google-gemini",
        .stream_fn = ai.providers.google_gemini.streamFn,
    });

    // v1.24.0 — append subagent + list_subagent_presets tools.
    // §5 — preset registry lives in role_arena alongside ctx.
    //
    // v1.28.0 — RPC reuses the same synthesized rpc-<startup_ms>
    // dir that bash_state already points at (set via
    // `setSessionDir` above). Sub-agent transcripts land at
    // `<rpc-dir>/subagents/<call_id>/transcript.json` and the
    // path is surfaced in the result so the parent can `read`
    // it on demand. When neither `FRANKY_HOME` nor `HOME` is
    // set the bash_state has no session dir — sub-agent
    // persistence is then skipped and the result omits
    // `transcript_path`.
    const ra = session.role_arena.allocator();

    const preset_reg = try ra.create(tools_mod.subagent.PresetRegistry);
    preset_reg.* = tools_mod.subagent.PresetRegistry.init(ra);
    try tools_mod.subagent.registerBuiltinPresets(preset_reg);

    const params_json = try tools_mod.subagent.buildParametersJson(ra, preset_reg);

    const subagent_ctx = try ra.create(tools_mod.subagent.Ctx);
    const parent_session_dir: ?[]const u8 = if (session.bash_state.getSessionDir()) |sd|
        try ra.dupe(u8, sd)
    else
        null;
    subagent_ctx.* = .{
        .registry = &session.registry,
        .environ = environ,
        .environ_map = environ_map,
        .parent_tools = session.tools,
        .parent_role = session.role_gate.role,
        .parent_profile = cfg.profile orelse "",
        .presets = preset_reg,
        .parameters_json_owned = params_json,
        .permission_store = if (session.prompts_enabled) &session.permission_store else null,
        // v1.24.3 — pointer-to-slot reads `session.current_prompter`
        // at sub-agent spawn time (parent is mid-prompt then,
        // so the slot holds the live prompter).
        .permission_prompter_slot = &session.current_prompter,
        .parent_session_dir = parent_session_dir,
        // §6.6 — forward sub-agent events as JSON-RPC `event` notifications.
        .progress_fn = subagentProgressForward,
        .progress_userdata = session,
    };
    const final_tools = try ra.alloc(at.AgentTool, session.tools.len + 3);
    @memcpy(final_tools[0..session.tools.len], session.tools);
    final_tools[session.tools.len] = tools_mod.subagent.toolWithCtx(subagent_ctx);
    final_tools[session.tools.len + 1] = tools_mod.subagent.listPresetsToolWithCtx(preset_reg);
    // v3.0 — ccr_retrieve tool for reversible compression
    final_tools[session.tools.len + 2] = tools_mod.ccr_retrieve.toolWithCtxAndStats(&session.ccr_ctx);
    session.tools = final_tools;

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
        .config = blk: {
            var lc: agent.loop.Config = .{
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
                .registry = &session.registry,
                .cancel = &session.cancel,
                .hook_userdata = @ptrCast(&session.session_gates),
                .guardrails = &session.guardrail_state,
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
            };
            // v3.0 — wire compression into the agent loop
            if (session.cfg.compress) {
                lc.compression = compression_mod.CompressionConfig{
                    .enabled = true,
                    .min_bytes_to_compress = session.cfg.compress_min_bytes,
                    .smart_crusher_enabled = session.cfg.compress_json,
                    .log_compressor_enabled = session.cfg.compress_logs,
                    .search_compressor_enabled = session.cfg.compress_search,
                    .diff_compressor_enabled = session.cfg.compress_diff,
                    .code_compressor_enabled = session.cfg.compress_code,
                    .plain_text_compressor_enabled = session.cfg.compress_plain_text,
                    .ccr_enabled = session.cfg.compress_ccr,
                };
                lc.ccr_store = &session.ccr_store;
                lc.compression_stats = &session.compression_stats;
            }
            break :blk lc;
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
