//! Print mode — §5.5 of the spec.
//!
//! Non-interactive driver:
//!   - Assistant text streams to stdout.
//!   - Tool-call metadata, agent errors, and session info go to stderr.
//!   - Exit 0 on normal stop, 1 on agent error, 2 on CLI error.
//!
//! Provider selection: --provider explicitly, otherwise `anthropic` if an
//! API key is available (--api-key or ANTHROPIC_API_KEY), else `faux`.
//!
//! Tool set: read, write, edit, bash, ls, find, grep — all registered by
//! default (the coding-agent baseline per §5.2).
//!
//! Session persistence: on unless --no-session. Written under
//! $FRANKY_HOME/sessions (default ~/.franky/sessions). Resumable with
//! --resume <id>.

const std = @import("std");
const franky = @import("../../root.zig");
const ai = franky.ai;
const agent = franky.agent;
const at = agent.types;
const tools_mod = franky.coding.tools;
const role_mod = franky.coding.role;
const permissions_mod = franky.coding.permissions;
const session_mod = franky.coding.session;
const cli_mod = franky.coding.cli;
const profiles_mod = franky.coding.profiles;
const auth_mod = franky.coding.auth;
const settings_mod = franky.coding.settings;
const models_mod = franky.coding.models;
const branching_mod = franky.coding.branching;
const skills_mod = franky.coding.skills;
const instructions_mod = franky.coding.instructions;
const diagnostics_mod = franky.coding.diagnostics;
const slash_mod = franky.coding.slash;
const extensions_mod = franky.coding.extensions;
const ext_catalog = franky.coding.extensions_builtin.catalog;
const config_mod = franky.coding.config.resolver;
const session_create = franky.coding.session.create;
const sse_mod = @import("../sse.zig");
const orchestrator = franky.coding.orchestrator;

/// Default model when the user didn't pass `--model`. Sonnet 4.6 is
/// the current cost/latency sweet spot; Opus 4.6 is reachable via
/// `--model opus` for complex tasks that justify thinking. Aliases
/// are resolved in `resolveModelAlias` below.
pub const default_anthropic_model: []const u8 = "claude-sonnet-4-6";
/// Sonnet 4.6 / Opus 4.6 both ship 1M-token context windows. Haiku 4.5
/// is 200k but the value here is advisory (used for tokenizer sizing,
/// not request shape) so one default across the family is fine.
pub const default_context_window: u32 = 1_000_000;
/// Large enough to fit `--thinking high` (budget 16384) with headroom.
/// Opus 4.6 / Sonnet 4.6 cap at 64k–128k; users can override via
/// `--model` + a future `--max-output` flag when they need the full cap.
pub const default_max_output: u32 = 8192;
pub const default_sse_host: []const u8 = "0.0.0.0";

pub const RunError = error{
    MissingApiKey,
    UnknownProvider,
    ResumeFailed,
    PromptRequired,
} || std.mem.Allocator.Error || std.Io.File.WriteError;

/// Entry point from bin/main.zig. `argv` is the raw argv slice.
pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    environ_map: *std.process.Environ.Map,
    argv: []const []const u8,
) !void {
    // `franky update [--check] [--force] [--repo owner/name]` is a
    // standalone subcommand — it doesn't share the model/session
    // surface that `cli_mod.parse` is built around. Dispatch before
    // any parsing so an out-of-date binary on a sloppy CLI surface
    // can still upgrade itself.
    if (argv.len >= 2 and std.mem.eql(u8, argv[1], "update")) {
        return runUpdate(allocator, io, environ_map, argv[2..]);
    }
    if (argv.len >= 2 and std.mem.eql(u8, argv[1], "replay")) {
        return runReplaySubcommand(allocator, io, argv[2..]);
    }
    if (argv.len >= 2 and std.mem.eql(u8, argv[1], "fixture")) {
        return runFixtureSubcommand(allocator, io, argv[2..]);
    }
    if (argv.len >= 2 and std.mem.eql(u8, argv[1], "doctor")) {
        return runDoctorSubcommand(allocator, io, environ_map, argv[2..]);
    }

    var cfg = cli_mod.parse(allocator, argv) catch |e| switch (e) {
        error.MissingValue => return exitWithMessage(io, "missing value for flag; see --help\n", 2),
        error.UnknownMode => return exitWithMessage(io, "unknown --mode value; use print\n", 2),
        error.UnknownThinkingLevel => return exitWithMessage(io, "unknown --thinking value; use off|minimal|low|medium|high|xhigh\n", 2),
        else => |err| return err,
    };
    defer cfg.deinit();

    // v1.17.0 — apply --profile <name> right after CLI parse, before
    // help/version short-circuits. Profile values fill in for any
    // CLI flag the user didn't pass; the profile system spec is in
    // franky-spec-v2.md §5.
    if (cfg.profile) |profile_name| {
        profiles_mod.applyProfile(&cfg, io, environ_map, profile_name) catch |e| switch (e) {
            error.ProfileNotFound => {
                const msg = try std.fmt.allocPrint(
                    allocator,
                    "profile '{s}' not found in any settings.json layer\n",
                    .{profile_name},
                );
                defer allocator.free(msg);
                return exitWithMessage(io, msg, 2);
            },
            error.MalformedProfile => return exitWithMessage(io, "malformed profile in settings.json\n", 2),
            error.UnknownMode => return exitWithMessage(io, "profile contains unknown mode\n", 2),
            error.UnknownThinkingLevel => return exitWithMessage(io, "profile contains unknown thinking level\n", 2),
            else => |err| return err,
        };
    }

    if (cfg.show_help) {
        return writeOut(io, cli_mod.usage_text);
    }
    if (cfg.show_version) {
        const msg = try std.fmt.allocPrint(allocator, "franky {s}\n", .{franky.version});
        defer allocator.free(msg);
        return writeOut(io, msg);
    }

    // v1.17.0 Phase 2 — short-circuits for the profile catalog tools.
    if (cfg.list_profiles) {
        const text = try profiles_mod.listProfiles(allocator, io, environ_map);
        defer allocator.free(text);
        return writeOut(io, text);
    }
    if (cfg.save_profile) |save_name| {
        profiles_mod.saveBuiltin(allocator, io, environ_map, save_name) catch |e| switch (e) {
            error.UnknownBuiltin => {
                const msg = try std.fmt.allocPrint(
                    allocator,
                    "no built-in profile named '{s}' (try --list-profiles)\n",
                    .{save_name},
                );
                defer allocator.free(msg);
                return exitWithMessage(io, msg, 2);
            },
            error.ProfileAlreadyExists => return exitWithMessage(io, "user profile already exists; remove it from settings.json first\n", 2),
            error.NoHome => return exitWithMessage(io, "FRANKY_HOME or HOME must be set to save a profile\n", 2),
            error.ExistingSettingsMalformed => return exitWithMessage(io, "existing settings.json is malformed; cannot merge\n", 2),
            else => |err| return err,
        };
        const msg = try std.fmt.allocPrint(
            allocator,
            "✓ wrote built-in profile '{s}' to your settings.json — edit it freely.\n",
            .{save_name},
        );
        defer allocator.free(msg);
        return writeOut(io, msg);
    }

    // v1.7.5 — initialize the logger BEFORE mode dispatch so
    // every mode (rpc / proxy / interactive / print) honors
    // `--log-level` / `FRANKY_LOG`. Pre-1.7.5 the init lived
    // inside `runPrint`, which is unreachable for the other
    // modes — every `ai.log.log(...)` call in the proxy /
    // interactive / rpc paths was a silent no-op regardless of
    // the configured level.
    const log_level = resolveLogLevel(&cfg, environ);
    if (resolveLogFileFromMap(&cfg, environ_map)) |path| {
        ai.log.initWithFile(io, log_level, path) catch ai.log.init(io, log_level);
    } else {
        ai.log.init(io, log_level);
    }
    defer ai.log.deinit();

    // v1.19.0 — parse per-scope overrides from --log-level / FRANKY_LOG.
    {
        const spec = cfg.log_level orelse environ.getPosix("FRANKY_LOG");
        if (spec) |s| applyScopeOverrides(s);
    }

    if (cfg.mode == .rpc) {
        const rpc_mode = @import("rpc.zig");
        return rpc_mode.run(allocator, io, environ, environ_map, &cfg);
    }
    if (cfg.mode == .proxy) {
        const proxy_mode = @import("proxy.zig");
        return proxy_mode.run(allocator, io, environ, environ_map, &cfg, argv);
    }
    if (cfg.mode == .interactive) {
        // Interactive mode doesn't require a prompt — the REPL
        // collects input from the terminal.
        const interactive = @import("interactive.zig");
        return interactive.run(allocator, io, environ, environ_map, &cfg);
    }
    if (cfg.prompt.len == 0 and cfg.resume_id == null) {
        return exitWithMessage(io, "no prompt given; try: franky \"hello\"\n", 2);
    }

    try runPrint(allocator, io, environ, environ_map, &cfg);
}

fn runPrint(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    environ_map: *std.process.Environ.Map,
    cfg: *cli_mod.Config,
) !void {
    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);

    // v2.22 Phase 2 — use the unified config resolver instead of
    // duplicating the 200-line init inline. All provider resolution,
    // registry setup, workspace, bash/read state, tool filtering,
    // permission store, preset registry, extensions, guardrails,
    // subagent context, settings overlay, and review config block
    // come from the single `config.resolve()` call.
    var resolved = try config_mod.resolve(allocator, io, cfg, environ, environ_map, &.{});
    defer resolved.deinit();

    {
        const auth_scheme: []const u8 = if (resolved.auth_token != null)
            "bearer"
        else if (resolved.api_key != null)
            "x-api-key"
        else
            "none";
        ai.log.log(.info, "cfg", "resolved", "provider={s} model={s} auth={s} thinking={s}", .{
            resolved.provider_name,
            resolved.model_id,
            auth_scheme,
            resolved.thinking_level.toString(),
        });
    }

    // Sandbox warning (mode-specific — no reason to move into resolver).
    {
        const sandbox_active = role_mod.detectSandbox(environ);
        var stderr_buf: [512]u8 = undefined;
        var stderr = std.Io.File.stderr().writer(io, &stderr_buf);
        stderr.interface.print(
            "franky · role={s} · sandbox={s}\n",
            .{ resolved.active_role.toString(), if (sandbox_active) "yes" else "no" },
        ) catch {};
        if (!sandbox_active and (resolved.active_role == .code or resolved.active_role == .full)) {
            stderr.interface.print(
                "⚠ Running outside a sandbox with role={s}. Tool calls execute on the host filesystem.\n  Consider:  zerobox -- franky --role {s} ...   (or --role plan to disable bash)\n",
                .{ resolved.active_role.toString(), resolved.active_role.toString() },
            ) catch {};
        }
        stderr.interface.flush() catch {};
    }

    // Startup warnings (tool install hints, etc).
    {
        var sw_buf: [1024]u8 = undefined;
        var sw = std.Io.File.stderr().writer(io, &sw_buf);
        for (resolved.startup_warnings) |w| {
            sw.interface.print("⚠ {s}\n", .{w}) catch {};
        }
        sw.interface.flush() catch {};
    }

    // ── Session / transcript ───────────────────────────────────────
    var session_state = try SessionState.init(allocator, io, environ, cfg);
    defer session_state.deinit(allocator);

    // v3.0 — wire the session's CCR store into the ccr_retrieve tool
    for (resolved.tools, 0..) |t, i| {
        if (std.mem.eql(u8, t.name, "ccr_retrieve")) {
            const tools_slice: []at.AgentTool = @constCast(resolved.tools);
            tools_slice[i].ctx = @ptrCast(&session_state.ccr_store);
        }
    }

    if (!cfg.no_session) {
        ai.log.log(.info, "session", "init", "id={s} dir={s}", .{
            session_state.id(),
            session_state.parent_dir orelse "",
        });
    }

    // v1.27.2 + v1.28.0 — once `session_state.parent_dir +
    // session_id` is known, plumb the on-disk session directory
    // into `bash_state` and `subagent_ctx.parent_session_dir`.
    var session_dir_path: ?[]u8 = null;
    defer if (session_dir_path) |p| allocator.free(p);
    var events_dir_path: ?[]u8 = null;
    defer if (events_dir_path) |p| allocator.free(p);
    var offload_dir_path: ?[]u8 = null;
    defer if (offload_dir_path) |p| allocator.free(p);
    if (session_state.parent_dir) |parent| {
        session_dir_path = std.fs.path.join(allocator, &.{ parent, session_state.id() }) catch null;
        if (session_dir_path) |sd| {
            resolved.bash_state.setSessionDir(sd) catch {};
            resolved.subagent_ctx.parent_session_dir = sd;
            // v1.29.0 — `<session>/events` for reducer-state dumps
            // when a turn ends degenerate (clean STOP, zero content).
            events_dir_path = std.fs.path.join(allocator, &.{ sd, "events" }) catch null;
            // v3.0 — `<session>/offloaded-tool-results` for tool-result
            // offloading. The model can `read` these files to recover
            // full tool output after offloading replaced it with a placeholder.
            offload_dir_path = std.fs.path.join(allocator, &.{ sd, "offloaded-tool-results" }) catch null;
        }
    }

    // v1.18.0 — per-session log file (opt-in via --log-per-session).
    maybeReinitLoggerForSession(allocator, io, cfg, environ_map, session_state.id());

    // Append the new user prompt (if any — an empty prompt under --resume
    // means "continue with whatever is in the transcript").
    if (cfg.prompt.len > 0) {
        const content = try allocator.alloc(ai.types.ContentBlock, 1);
        content[0] = .{ .text = .{ .text = try allocator.dupe(u8, cfg.prompt) } };
        try session_state.transcript.append(.{
            .role = .user,
            .content = content,
            .timestamp = ai.stream.nowMillis(),
        });
    }

    // ── Agent loop ─────────────────────────────────────────────────
    const system_prompt = try buildSystemPromptIo(allocator, io, environ, cfg);
    defer allocator.free(system_prompt);

    const model: ai.types.Model = .{
        .id = resolved.model_id,
        .provider = resolved.provider_name,
        .api = resolved.api_tag,
        .context_window = resolved.context_window,
        .max_output = resolved.max_output,
        .capabilities = resolved.capabilities,
    };

    var cancel = ai.stream.Cancel{};
    var ch = try agent.loop.AgentChannel.initWithDrop(
        allocator,
        16384,
        at.AgentEvent.deinit,
        allocator,
    );
    defer ch.deinit();

    var loop_cfg: agent.loop.Config = .{
        .model = model,
        .system_prompt = system_prompt,
        .tools = resolved.tools,
        .registry = &resolved.registry,
        .cancel = &cancel,
        .guardrails = resolved.guardrail_state,
        .nudge_on_finish_task = true,
        .nudge_on_autocontinue = cfg.autocontinue,
        .max_full_tool_results = resolved.max_full_tool_results,
        .offload_dir = offload_dir_path,
        .hook_userdata = @ptrCast(resolved.session_gates),
        .role_denied = permissions_mod.SessionGates.roleDenied,
        .before_tool_call = permissions_mod.SessionGates.beforeToolCall,
        .text_tool_call_fallback = cfg.text_tool_call_fallback,
        .reducer_dump_dir = events_dir_path,
        .compression = if (resolved.compression.enabled) resolved.compression else null,
        .ccr_store = &session_state.ccr_store,
        .stream_options = .{
            .api_key = resolved.api_key,
            .auth_token = resolved.auth_token,
            .base_url = resolved.base_url,
            .environ_map = environ_map,
            .thinking = cfg.thinking,
            .timeouts = config_mod.resolveTimeouts(cfg, environ_map),
            .retry_policy = resolved.retry_policy,
            .http_trace_dir = config_mod.resolveHttpTraceDir(cfg, environ_map),
        },
    };
    if (config_mod.resolveMaxTurns(cfg, environ_map)) |v| loop_cfg.max_turns = v;
    const worker_args: WorkerArgs = .{
        .allocator = allocator,
        .io = io,
        .transcript = &session_state.transcript,
        .config = loop_cfg,
        .ch = &ch,
    };
    const worker = try std.Thread.spawn(.{}, workerMain, .{worker_args});
    defer worker.join();

    // ── Optional orchestrator registration ──────────────────────────
    //
    // When `--register <url>` (or FRANKY_ORCHESTRATOR_URL) is set,
    // we register the agent with a remote orchestrator after the SSE
    // listener is up.
    const orchestrator_url: ?[]const u8 = blk: {
        if (cfg.register_url) |u| if (u.len > 0) break :blk u;
        if (environ_map.get("FRANKY_ORCHESTRATOR_URL")) |v| if (v.len > 0) break :blk v;
        break :blk null;
    };

    // ── Optional SSE listener ────────────────────────────────────
    //
    // Only bind an SSE HTTP server when an orchestrator URL is
    // configured via `--register <url>` or FRANKY_ORCHESTRATOR_URL.
    // Print mode is purely a stdout pipeline — no server needed.
    var sse_server: ?*sse_mod.SseBroadcaster = null;
    var sse_server_storage: sse_mod.SseBroadcaster = undefined;
    var sse_accept_thread: ?std.Thread = null;
    const sse_port: u16 = cfg.proxy_port orelse @as(u16, 8787);
    var orchestrator_owned: ?[]u8 = null;

    if (orchestrator_url != null) {
        var addr = std.Io.net.IpAddress.parseIp4(default_sse_host, sse_port) catch {
            ai.log.log(.err, "sse", "listen", "failed to parse address", .{});
            return;
        };
        var listener = std.Io.net.IpAddress.listen(&addr, io, .{
            .kernel_backlog = 8,
            .reuse_address = true,
        }) catch {
            ai.log.log(.err, "sse", "listen", "failed to bind SSE listener on port {d}", .{sse_port});
            return;
        };
        defer {
            if (sse_accept_thread == null) listener.deinit(io);
        }
        sse_server_storage = sse_mod.SseBroadcaster.init(allocator, io);
        sse_server = &sse_server_storage;

        // Spawn the accept loop on a background thread.
        const ctx = allocator.create(SseAcceptCtx) catch {
            listener.deinit(io);
            return;
        };
        ctx.* = .{ .allocator = allocator, .listener = listener, .broadcaster = sse_server.?, .io = io };
        const accept_args = SseAcceptArgs{ .ctx = ctx };
        sse_accept_thread = std.Thread.spawn(.{}, sseAcceptLoop, .{accept_args}) catch blk: {
            allocator.destroy(ctx);
            listener.deinit(io);
            sse_server = null;
            break :blk null;
        };

        // Register with orchestrator (best-effort) when configured.
        if (orchestrator_url) |ourl| {
            orchestrator.register(
                allocator,
                io,
                ourl,
                session_state.id(),
                sse_port,
                resolved.model_id,
                resolved.active_role.toString(),
                environ_map,
            );
            orchestrator_owned = try allocator.dupe(u8, ourl);
        }
    }

    // Stderr notice.
    {
        var stderr_buf: [512]u8 = undefined;
        var stderr = std.Io.File.stderr().writer(io, &stderr_buf);
        if (sse_server != null) {
            if (orchestrator_url != null) {
                stderr.interface.print(
                    "franky · SSE listener on http://127.0.0.1:{d}/ · registered with orchestrator\n",
                    .{sse_port},
                ) catch {};
            } else {
                stderr.interface.print(
                    "franky · SSE listener on http://127.0.0.1:{d}/events\n",
                    .{sse_port},
                ) catch {};
            }
        }
        stderr.interface.flush() catch {};
    }

    defer {
        if (sse_accept_thread) |t| {
            // Signal the accept loop to stop by closing all subscribers.
            // The listener will cause accept() to error on next iteration.
            sse_server.?.events_mutex.lockUncancelable(io);
            for (sse_server.?.subs[0..]) |maybe| {
                if (maybe) |sub| sub.close();
            }
            sse_server.?.events_mutex.unlock(io);
            t.join();
        }
        if (sse_server) |srv| srv.deinit();
        if (orchestrator_owned) |ourl| {
            if (!cfg.no_session) {
                orchestrator.unregister(allocator, io, ourl, session_state.id(), environ_map);
            }
            allocator.free(ourl);
        }
    }

    var saw_error = false;
    while (ch.next(io)) |ev| {
        switch (ev) {
            .message_update => |u| switch (u) {
                .text => |t| stdout.interface.writeAll(t.delta) catch {},
                else => {},
            },
            .tool_execution_start => |s| {
                ai.log.log(.info, "tool", "start", "id={s} name={s}", .{ s.call_id, s.name });
            },
            .tool_execution_end => |e| {
                ai.log.log(.info, "tool", "end", "id={s} is_error={}", .{ e.call_id, e.result.is_error });
            },
            .agent_error => |details| {
                saw_error = true;
                ai.log.log(.err, "agent", "error", "code={s} message={s}", .{ details.code.toString(), details.message });
            },
            .turn_end => {
                stdout.interface.writeAll("\n") catch {};
                stdout.interface.flush() catch {};
            },
            else => {},
        }
        // Broadcast to SSE subscribers when active.
        if (sse_server) |srv| {
            if (sse_mod.renderFrame(allocator, ev)) |frame| {
                srv.broadcastEvent(frame);
                allocator.free(frame);
            } else |_| {}
        }
        ev.deinit(allocator);
    }

    stdout.interface.flush() catch {};

    // ── Persist session ───────────────────────────────────────────
    if (!cfg.no_session) {
        session_state.persist(allocator, io, .{
            .provider_name = resolved.provider_name,
            .api_tag = resolved.api_tag,
            .model_id = resolved.model_id,
            .api_key = resolved.api_key,
            .auth_token = resolved.auth_token,
            .base_url = resolved.base_url,
            .context_window = resolved.context_window,
            .max_output = resolved.max_output,
            .capabilities = resolved.capabilities,
        }, cfg) catch |err| {
            ai.log.log(.err, "session", "persist_failed", "error={s}", .{@errorName(err)});
        };
    }

    if (saw_error) std.process.exit(1);
}

// ─── agent-loop worker thread ─────────────────────────────────────

const WorkerArgs = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    transcript: *agent.loop.Transcript,
    config: agent.loop.Config,
    ch: *agent.loop.AgentChannel,
};

const SseAcceptArgs = struct {
    ctx: *SseAcceptCtx,
};

const SseAcceptCtx = struct {
    allocator: std.mem.Allocator,
    listener: std.Io.net.Server,
    broadcaster: *sse_mod.SseBroadcaster,
    io: std.Io,
};

fn sseAcceptLoop(args: SseAcceptArgs) void {
    const ctx = args.ctx;
    defer {
        ctx.listener.deinit(ctx.io);
        ctx.allocator.destroy(ctx);
    }
    while (true) {
        var stream = ctx.listener.accept(ctx.io) catch |err| switch (err) {
            error.Canceled => continue,
            else => return,
        };
        const hargs = HandleConnArgs{ .broadcaster = ctx.broadcaster, .stream = stream, .io = ctx.io };
        const t = std.Thread.spawn(.{}, handleSseConn, .{hargs}) catch {
            stream.close(ctx.io);
            continue;
        };
        t.detach();
    }
}

const HandleConnArgs = struct {
    broadcaster: *sse_mod.SseBroadcaster,
    stream: std.Io.net.Stream,
    io: std.Io,
};

fn handleSseConn(args: HandleConnArgs) void {
    var stream = args.stream;
    defer stream.close(args.io);

    var hdr_buf: [4096]u8 = undefined;
    const hdr_len = sse_mod.readHeaders(&stream, args.io, &hdr_buf) catch {
        sse_mod.respondStatus(&stream, args.io, 400, "Bad Request");
        return;
    };
    const headers = hdr_buf[0..hdr_len.consumed];
    const req = sse_mod.parseRequest(headers) orelse {
        sse_mod.respondStatus(&stream, args.io, 400, "Bad Request");
        return;
    };

    if (std.mem.eql(u8, req.method, "GET") and std.mem.eql(u8, req.path, "/health")) {
        sse_mod.respondJson(&stream, args.io, 200, "{\"ok\":true}");
        return;
    }
    if (std.mem.eql(u8, req.method, "GET") and std.mem.eql(u8, req.path, "/events")) {
        sse_mod.handleSseRequest(args.broadcaster, &stream, args.io, req.last_event_id orelse 0);
        return;
    }
    sse_mod.respondStatus(&stream, args.io, 404, "Not Found");
}

fn workerMain(args: WorkerArgs) void {
    agent.loop.agentLoop(args.allocator, args.io, args.transcript, args.config, args.ch);
}

// ─── model alias resolution ──────────────────────────────────────

/// Short aliases for the common Anthropic models. Anything that isn't
/// a known short alias is returned unchanged, so users can still pass
/// full API ids like `claude-opus-4-6` or dated snapshots like
/// `claude-haiku-4-5-20251001`.
///
/// Alias choices prioritize "what a user probably means" over strict
/// naming — `opus`/`sonnet`/`haiku` resolve to the current
/// extended-thinking-capable model in each tier (Opus 4.6, Sonnet 4.6,
/// Haiku 4.5). For the newer adaptive-only Opus 4.7, use the explicit
/// alias or id.
pub fn resolveAnthropicAlias(input: []const u8) []const u8 {
    const aliases = [_]struct { []const u8, []const u8 }{
        .{ "opus", "claude-opus-4-6" },
        .{ "opus-4-6", "claude-opus-4-6" },
        .{ "opus-4.6", "claude-opus-4-6" },
        .{ "opus-4-7", "claude-opus-4-7" },
        .{ "opus-4.7", "claude-opus-4-7" },
        .{ "sonnet", "claude-sonnet-4-6" },
        .{ "sonnet-4-6", "claude-sonnet-4-6" },
        .{ "sonnet-4.6", "claude-sonnet-4-6" },
        .{ "haiku", "claude-haiku-4-5" },
        .{ "haiku-4-5", "claude-haiku-4-5" },
        .{ "haiku-4.5", "claude-haiku-4-5" },
    };
    for (aliases) |kv| {
        if (std.mem.eql(u8, input, kv[0])) return kv[1];
    }
    return input;
}

// ─── log level resolution ────────────────────────────────────────

/// v1.19.0 — extract the bare global level from a spec that may
/// contain comma-separated `scope:level` entries. Returns null when
/// the input is only scope overrides with no global level.
fn extractGlobalLevel(s: []const u8) ?ai.log.Level {
    var it = std.mem.splitScalar(u8, s, ',');
    var result: ?ai.log.Level = null;
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        // Skip scope:level entries — they don't set the global level.
        if (std.mem.indexOfScalar(u8, trimmed, ':')) |_| continue;
        if (ai.log.Level.fromString(trimmed)) |l| result = l;
    }
    return result;
}

/// v1.19.0 — register per-scope level overrides from a spec string
/// in the form `scope:level,scope:level,...`. Non-override entries
/// (bare level names) are silently ignored.
pub fn applyScopeOverrides(s: []const u8) void {
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
        const scope = std.mem.trim(u8, trimmed[0..colon], " \t");
        const level_str = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
        if (scope.len > 0) {
            if (ai.log.Level.fromString(level_str)) |l| {
                ai.log.setScopeLevel(scope, l);
            }
        }
    }
}

pub fn resolveLogLevel(cfg: *const cli_mod.Config, environ: std.process.Environ) ai.log.Level {
    // 1. Explicit CLI flag wins (extract global level from compound spec).
    if (cfg.log_level) |s| {
        if (extractGlobalLevel(s)) |l| return l;
        if (ai.log.Level.fromString(s)) |l| return l; // backward compat
    }
    // 2. FRANKY_LOG env var.
    if (environ.getPosix("FRANKY_LOG")) |s| {
        if (extractGlobalLevel(s)) |l| return l;
        if (ai.log.Level.fromString(s)) |l| return l;
    }
    // 3. FRANKY_DEBUG=1 → debug.
    if (environ.getPosix("FRANKY_DEBUG")) |v| {
        if (v.len > 0 and v[0] != '0') return .debug;
    }
    // 4. --verbose → info.
    if (cfg.verbose) return .info;
    // 5. Default: warnings and errors only.
    return .warn;
}

/// Resolve log level from environ_map only (no cfg available).
/// Used by `runUpdate` which dispatches before CLI parse.
/// Precedence: FRANKY_LOG → FRANKY_DEBUG → warn (default).
pub fn resolveLogLevelMap(environ_map: *const std.process.Environ.Map) ai.log.Level {
    if (environ_map.get("FRANKY_LOG")) |s| {
        if (extractGlobalLevel(s)) |l| return l;
        if (ai.log.Level.fromString(s)) |l| return l;
    }
    if (environ_map.get("FRANKY_DEBUG")) |v| {
        if (v.len > 0 and v[0] != '0') return .debug;
    }
    return .warn;
}

/// Resolve `ai.registry.Timeouts` for this run.
///
/// Precedence per field: CLI flag → env var → autodetected default.
///
/// The autodetected default is normally `Timeouts{}` (the §G.4
/// standard), but bumps `first_byte_ms` to 10 minutes when
/// `cfg.base_url` points at a loopback host (Ollama on
/// `localhost:11434`, LM-Studio on `localhost:1234`, vLLM on
/// `localhost:8000`, …). Local LLMs commonly take longer than
/// 30 s to emit a first token under reasoning workloads, and the
/// hard cap surfaced as the misleading `transport: http error:
/// Timeout` the user reported pre-v1.10. An explicit
/// `--first-byte-timeout-ms` (or env var) still wins.
///
/// Map-based so every mode (print stays on the live `Environ`;
/// interactive/rpc/proxy hold a `Map`) can share the same resolver.
pub fn resolveTimeoutsFromMap(
    cfg: *const cli_mod.Config,
    environ_map: *const std.process.Environ.Map,
) ai.registry.Timeouts {
    var t: ai.registry.Timeouts = .{};
    if (isLoopbackBaseUrl(cfg.base_url)) t.first_byte_ms = 600_000;

    if (cfg.connect_timeout_ms) |v| t.connect_ms = v
    else if (parseEnvMapU32(environ_map, "FRANKY_CONNECT_TIMEOUT_MS")) |v| t.connect_ms = v;
    if (cfg.upload_timeout_ms) |v| t.upload_ms = v
    else if (parseEnvMapU32(environ_map, "FRANKY_UPLOAD_TIMEOUT_MS")) |v| t.upload_ms = v;
    if (cfg.first_byte_timeout_ms) |v| t.first_byte_ms = v
    else if (parseEnvMapU32(environ_map, "FRANKY_FIRST_BYTE_TIMEOUT_MS")) |v| t.first_byte_ms = v;
    if (cfg.event_gap_timeout_ms) |v| t.event_gap_ms = v
    else if (parseEnvMapU32(environ_map, "FRANKY_EVENT_GAP_TIMEOUT_MS")) |v| t.event_gap_ms = v;
    return t;
}

fn parseEnvMapU32(map: *const std.process.Environ.Map, key: []const u8) ?u32 {
    const v = map.get(key) orelse return null;
    return std.fmt.parseInt(u32, v, 10) catch null;
}

/// Resolve the agent loop's `max_turns` cap from the CLI flag, env
/// var, or null (caller falls back to `loop.Config.max_turns`'s
/// default). Precedence: `--max-turns` > `FRANKY_MAX_TURNS` > unset.
/// Settings/profile overlay layers in on top of this; see iter 4.
pub fn resolveMaxTurnsFromMap(
    cfg: *const cli_mod.Config,
    environ_map: *const std.process.Environ.Map,
) ?u32 {
    if (cfg.max_turns) |v| return v;
    if (parseEnvMapU32(environ_map, "FRANKY_MAX_TURNS")) |v| return v;
    return null;
}

/// v2.13 — resolve retry policy from CLI flags, settings, or defaults.
/// Callers pass their `cfg` and settings to build a `retry_mod.Policy`
/// that providers can use instead of the hard-coded defaults.
pub fn resolveRetryPolicyFromMap(
    cfg: *const cli_mod.Config,
    settings: ?*const settings_mod.Settings,
) ai.retry.Policy {
    var p: ai.retry.Policy = .{};
    if (cfg.retry_max_attempts) |v| {
        p.max_retries = v;
    } else if (settings) |s| {
        if (s.retry_max_attempts) |v| p.max_retries = v;
    }
    if (cfg.retry_max_total_ms) |v| {
        p.max_total_delay_ms = v;
    } else if (settings) |s| {
        if (s.retry_max_total_ms) |v| p.max_total_delay_ms = v;
    }
    if (cfg.retry_base_delay_ms) |v| {
        p.base_delay_ms = v;
    }
    return p;
}

/// v1.13.0 — resolve the log-file destination for this run.
/// Precedence: `--log-file` flag → `FRANKY_LOG_FILE` env var → null.
/// Returned slice is borrowed from `cfg` (CLI arena) or
/// `environ_map` (process env); both outlive the logger.
pub fn resolveLogFileFromMap(
    cfg: *const cli_mod.Config,
    environ_map: *const std.process.Environ.Map,
) ?[]const u8 {
    if (cfg.log_file) |p| if (p.len > 0) return p;
    if (environ_map.get("FRANKY_LOG_FILE")) |p| if (p.len > 0) return p;
    return null;
}

/// v1.16.1 — resolve `--http-trace-dir`.
/// Precedence: CLI flag → `FRANKY_HTTP_TRACE_DIR` env var → null.
pub fn resolveHttpTraceDirFromMap(
    cfg: *const cli_mod.Config,
    environ_map: *const std.process.Environ.Map,
) ?[]const u8 {
    if (cfg.http_trace_dir) |p| if (p.len > 0) return p;
    if (environ_map.get("FRANKY_HTTP_TRACE_DIR")) |p| if (p.len > 0) return p;
    return null;
}

/// v1.18.0 — true when the user wants per-session log files.
/// Precedence: `--log-per-session` CLI flag → non-empty
/// `FRANKY_LOG_PER_SESSION` env var → false.
pub fn resolveLogPerSessionFromMap(
    cfg: *const cli_mod.Config,
    environ_map: *const std.process.Environ.Map,
) bool {
    if (cfg.log_per_session) return true;
    if (environ_map.get("FRANKY_LOG_PER_SESSION")) |v| if (v.len > 0) return true;
    return false;
}

/// v1.18.0 — build the per-session log path from the active
/// session id. Prefers `$FRANKY_HOME/logs/<id>.log`; falls back
/// to `$HOME/.franky/logs/<id>.log`. Returns null when neither
/// env var is set. Caller owns the slice and frees it.
pub fn buildPerSessionLogPath(
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    session_id: []const u8,
) !?[]u8 {
    const filename = try std.fmt.allocPrint(allocator, "{s}.log", .{session_id});
    defer allocator.free(filename);
    if (environ_map.get("FRANKY_HOME")) |h| if (h.len > 0) {
        return try std.fs.path.join(allocator, &.{ h, "logs", filename });
    };
    if (environ_map.get("HOME")) |h| if (h.len > 0) {
        return try std.fs.path.join(allocator, &.{ h, ".franky", "logs", filename });
    };
    return null;
}

/// v1.18.0 — re-init the leveled logger to the per-session
/// path when `--log-per-session` is on AND the user didn't pass
/// an explicit `--log-file`. No-op otherwise. Best-effort: a
/// reopen failure leaves the previous sink active so logging
/// continues to wherever it was already going.
pub fn maybeReinitLoggerForSession(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: *const cli_mod.Config,
    environ_map: *const std.process.Environ.Map,
    session_id: []const u8,
) void {
    // Explicit `--log-file` always wins; never override it.
    if (resolveLogFileFromMap(cfg, environ_map)) |_| return;
    if (!resolveLogPerSessionFromMap(cfg, environ_map)) return;
    const path = (buildPerSessionLogPath(allocator, environ_map, session_id) catch return) orelse return;
    defer allocator.free(path);
    const level: ai.log.Level = ai.log.currentLevel();
    ai.log.initWithFile(io, level, path) catch {
        // Keep the previous sink (stderr or the auto-divert path).
    };
}

/// v1.19.0 — load layered settings.json (project → user) using
/// the same path resolution as `resolveProviderIo`. Returns the
/// fresh `Settings` so callers can apply overlays. Caller owns
/// the returned struct and must `deinit` it.
///
/// Failure modes: a malformed JSON layer surfaces as
/// `SettingsError.MalformedJson` from `loadLayered`; this helper
/// catches that and returns built-in defaults so a bad file
/// can't abort startup. (The malformed-file case is already
/// surfaced in logs by callers that want to know.)
pub fn loadSettingsForOverlay(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
) !settings_mod.Settings {
    const home = environ.getPosix("FRANKY_HOME") orelse environ.getPosix("HOME");
    const pwd = environ.getPosix("PWD");
    return settings_mod.loadLayered(allocator, io, pwd, home) catch
        try settings_mod.defaults(allocator);
}

/// v1.19.0 — copy the relevant settings.json overlay fields onto
/// `bash_state`. Today this is just `tools.bash.timeoutMs`; the
/// per-call `timeoutMs` arg always wins. Idempotent; safe to call
/// after `SessionBashState.init`.
pub fn applyBashSettingsOverlay(
    bash_state: *tools_mod.bash.SessionBashState,
    settings: *const settings_mod.Settings,
) void {
    if (settings.bash_timeout_ms) |ms| {
        bash_state.default_timeout_ms_override = ms;
    }
}

/// v1.19.0 — copy the relevant settings.json overlay fields onto
/// `read_ctx`. Today this is just `tools.read.maxBytes`; the
/// per-call `limit` arg always wins. Idempotent.
pub fn applyReadSettingsOverlay(
    read_ctx: *tools_mod.read.ReadCtx,
    settings: *const settings_mod.Settings,
) void {
    if (settings.read_max_bytes) |b| {
        read_ctx.max_bytes_without_limit_override = b;
    }
}

/// v1.19.0 — pre-seed a `permissions.Store` from settings.json's
/// `permissions.{always_allow,always_deny}.{tools,bash}` arrays
/// and the `permissions.{ask_all,yes_to_all}` scalars. Call after
/// `Store.init` and before applying CLI flags so CLI always wins
/// (CLI just adds entries; deny still beats allow in `Store.check`
/// regardless of which layer added them).
pub fn applyPermissionsSettingsOverlay(
    store: *permissions_mod.Store,
    settings: *const settings_mod.Settings,
) !void {
    if (settings.permissions_ask_all) |b| store.ask_all = b;
    if (settings.permissions_yes_to_all) |b| store.yes_to_all = b;
    for (settings.permissions_always_allow_tools) |t| {
        try store.addBareEntry(t, .allow, false);
    }
    for (settings.permissions_always_deny_tools) |t| {
        try store.addBareEntry(t, .deny, false);
    }
    for (settings.permissions_always_allow_bash) |fp| {
        try store.addBareEntry(fp, .allow, true);
    }
    for (settings.permissions_always_deny_bash) |fp| {
        try store.addBareEntry(fp, .deny, true);
    }
}

/// v1.19.0 — settings-layer default for `--prompts`. CLI flag
/// always wins. Returns `true` when prompts should be enabled
/// at this layer (settings says so AND CLI didn't set it).
pub fn resolvePromptsDefault(
    cfg: *const cli_mod.Config,
    settings: *const settings_mod.Settings,
) bool {
    if (cfg.prompts) return true; // CLI wins.
    return settings.prompts_default orelse false;
}

/// Backfill `cfg.max_turns` from `settings.max_turns` when the CLI
/// (or profile, via `applyToCfg` which already ran) didn't set it.
/// Preserves the precedence chain CLI > profile > settings > env >
/// default — `resolveMaxTurnsFromMap` then sees a populated `cfg`
/// before it falls through to the env-var lookup.
pub fn applyMaxTurnsSettingsOverlay(
    cfg: *cli_mod.Config,
    settings: *const settings_mod.Settings,
) void {
    if (cfg.max_turns != null) return; // CLI / profile already set it.
    if (settings.max_turns) |v| cfg.max_turns = v;
}

/// v2.13 — apply `settings.retry_max_attempts` and
/// `settings.retry_max_total_ms` to `cfg` when the CLI didn't
/// set them (or a profile didn't). Follows the same pattern as
/// `applyMaxTurnsSettingsOverlay`.
pub fn applyRetrySettingsOverlay(
    cfg: *cli_mod.Config,
    settings: *const settings_mod.Settings,
) void {
    if (cfg.retry_max_attempts == null) {
        cfg.retry_max_attempts = settings.retry_max_attempts;
    }
    if (cfg.retry_max_total_ms == null) {
        cfg.retry_max_total_ms = settings.retry_max_total_ms;
    }
}

/// True when `base_url` parses to a loopback host. Whole-host
/// match (not substring) so we don't false-positive on
/// `https://localhost-prod.example.com/`.
pub fn isLoopbackBaseUrl(maybe_url: ?[]const u8) bool {
    const url = maybe_url orelse return false;
    const after_scheme = blk: {
        if (std.mem.indexOf(u8, url, "://")) |i| break :blk url[i + 3 ..];
        break :blk url;
    };
    // Bracketed IPv6 host: `[::1]` (port follows after `]`).
    if (after_scheme.len > 0 and after_scheme[0] == '[') {
        const close = std.mem.indexOfScalar(u8, after_scheme, ']') orelse return false;
        const inner = after_scheme[1..close];
        return std.mem.eql(u8, inner, "::1");
    }
    const host_end = std.mem.indexOfAny(u8, after_scheme, ":/?#") orelse after_scheme.len;
    const host = after_scheme[0..host_end];
    return std.mem.eql(u8, host, "localhost") or
        std.mem.eql(u8, host, "127.0.0.1") or
        std.mem.eql(u8, host, "::1");
}

// ─── provider selection ──────────────────────────────────────────

/// Re-exported from session.create — canonical definition for
/// persistence-header metadata across all modes.
pub const ProviderInfo = session_create.ProviderInfo;

pub fn resolveProvider(
    allocator: std.mem.Allocator,
    environ: std.process.Environ,
    cfg: *cli_mod.Config,
) !ProviderInfo {
    return resolveProviderIo(allocator, null, environ, cfg);
}

/// Variant that consults `$FRANKY_HOME/auth.json` via `io`. The
/// `resolveProvider` wrapper above preserves the older call-free
/// signature that tests use; callers from the CLI dispatcher pass
/// their real `io` so the auth-file layer actually runs.
pub fn resolveProviderIo(
    allocator: std.mem.Allocator,
    io: ?std.Io,
    environ: std.process.Environ,
    cfg: *cli_mod.Config,
) !ProviderInfo {
    const a = cfg.arena.allocator();

    var settings = try resolvePrintSettings(allocator, io, environ);
    defer settings.deinit();
    applyPrintThinkingOverride(cfg, &settings);

    var auth_state = try loadPrintAuthState(a, allocator, io, environ);
    defer if (auth_state) |*as| as.deinit();

    const models_extras = try loadPrintModelsExtras(a, allocator, io, environ);

    const creds = try resolvePrintCredentials(a, cfg, environ, auth_state);
    const chosen = choosePrintProvider(cfg, &creds, &settings);

    if (std.mem.eql(u8, chosen, "faux")) return buildPrintFauxConfig(a, cfg, models_extras);
    if (std.mem.eql(u8, chosen, "anthropic")) return buildPrintAnthropicConfig(a, cfg, &creds, &settings, models_extras);
    if (std.mem.eql(u8, chosen, "openai")) return buildPrintOpenaiConfig(a, cfg, &creds, &settings, models_extras);
    if (std.mem.eql(u8, chosen, "gateway")) return buildPrintGatewayConfig(a, cfg, environ, &creds, auth_state, models_extras);
    if (std.mem.eql(u8, chosen, "google-gemini") or std.mem.eql(u8, chosen, "gemini") or std.mem.eql(u8, chosen, "google")) return buildPrintGeminiConfig(a, cfg, &creds, models_extras);

    return error.UnknownProvider;
}

const PrintCredentials = struct {
    api_key: ?[]const u8 = null,
    auth_token: ?[]const u8 = null,
    openai_api_key: ?[]const u8 = null,
    gemini_api_key: ?[]const u8 = null,
    gemini_auth_token: ?[]const u8 = null,
    has_anthropic: bool = false,
    has_openai: bool = false,
    has_gemini: bool = false,
};

fn resolvePrintSettings(allocator: std.mem.Allocator, io: ?std.Io, environ: std.process.Environ) !settings_mod.Settings {
    if (io) |ioref| {
        const home = environ.getPosix("FRANKY_HOME") orelse environ.getPosix("HOME");
        const pwd = environ.getPosix("PWD");
        return settings_mod.loadLayered(allocator, ioref, pwd, home) catch try settings_mod.defaults(allocator);
    }
    return try settings_mod.defaults(allocator);
}

fn applyPrintThinkingOverride(cfg: *cli_mod.Config, settings: *const settings_mod.Settings) void {
    if (!cfg.thinking_explicit) {
        if (ai.types.ThinkingLevel.fromString(settings.thinking)) |lvl| {
            cfg.thinking = lvl;
        }
    }
}

fn loadPrintAuthState(a: std.mem.Allocator, allocator: std.mem.Allocator, io: ?std.Io, environ: std.process.Environ) !?auth_mod.Auth {
    if (io) |ioref| {
        const auth_path = try authJsonPath(a, environ);
        if (auth_path) |p| {
            return auth_mod.load(allocator, ioref, p) catch null;
        }
    }
    return null;
}

fn loadPrintModelsExtras(a: std.mem.Allocator, allocator: std.mem.Allocator, io: ?std.Io, environ: std.process.Environ) ![]const models_mod.Entry {
    if (io) |ioref| {
        const franky_home: ?[]const u8 = environ.getPosix("FRANKY_HOME");
        const home: ?[]const u8 = environ.getPosix("HOME");
        const models_path = try modelsJsonPathFrom(a, franky_home, home);
        if (models_path) |p| {
            const bytes = readWholeFileOpt(allocator, ioref, p) orelse return &.{};
            defer allocator.free(bytes);
            return models_mod.parseFromSlice(a, bytes) catch &.{};
        }
    }
    return &.{};
}

fn resolvePrintCredentials(a: std.mem.Allocator, cfg: *const cli_mod.Config, environ: std.process.Environ, auth_state: ?auth_mod.Auth) !PrintCredentials {
    const anthropic_file = if (auth_state) |as| as.get("anthropic") else null;
    const openai_file = if (auth_state) |as| as.get("openai") else null;
    const gemini_file = if (auth_state) |as| as.get("google-gemini") else null;

    const api_key: ?[]const u8 = blk: {
        if (cfg.api_key) |k| break :blk k;
        if (environ.getPosix("ANTHROPIC_API_KEY")) |k| break :blk try a.dupe(u8, k);
        if (anthropic_file) |rec| if (rec.api_key) |k| break :blk try a.dupe(u8, k);
        break :blk null;
    };
    const auth_token: ?[]const u8 = blk: {
        if (cfg.auth_token) |t| break :blk t;
        if (environ.getPosix("ANTHROPIC_AUTH_TOKEN")) |t| break :blk try a.dupe(u8, t);
        if (environ.getPosix("CLAUDE_CODE_OAUTH_TOKEN")) |t| break :blk try a.dupe(u8, t);
        if (anthropic_file) |rec| if (rec.access_token) |t| break :blk try a.dupe(u8, t);
        break :blk null;
    };
    const openai_api_key: ?[]const u8 = blk: {
        if (environ.getPosix("OPENAI_API_KEY")) |k| break :blk try a.dupe(u8, k);
        if (openai_file) |rec| if (rec.api_key) |k| break :blk try a.dupe(u8, k);
        break :blk null;
    };
    const gemini_api_key: ?[]const u8 = blk: {
        if (environ.getPosix("GEMINI_API_KEY")) |k| break :blk try a.dupe(u8, k);
        if (environ.getPosix("GOOGLE_API_KEY")) |k| break :blk try a.dupe(u8, k);
        if (gemini_file) |rec| if (rec.api_key) |k| break :blk try a.dupe(u8, k);
        break :blk null;
    };
    const gemini_auth_token: ?[]const u8 = blk: {
        if (gemini_file) |rec| if (rec.access_token) |t| break :blk try a.dupe(u8, t);
        break :blk null;
    };

    const has_anthropic = api_key != null or auth_token != null;
    const has_openai = openai_api_key != null or (cfg.api_key != null and !has_anthropic);
    const has_gemini = gemini_api_key != null or gemini_auth_token != null;

    return .{
        .api_key = api_key,
        .auth_token = auth_token,
        .openai_api_key = openai_api_key,
        .gemini_api_key = gemini_api_key,
        .gemini_auth_token = gemini_auth_token,
        .has_anthropic = has_anthropic,
        .has_openai = has_openai,
        .has_gemini = has_gemini,
    };
}

fn choosePrintProvider(cfg: *const cli_mod.Config, creds: *const PrintCredentials, settings: *const settings_mod.Settings) []const u8 {
    if (cfg.offline) return "faux";
    if (cfg.provider) |p| return p;
    if (creds.has_anthropic) return "anthropic";
    if (creds.has_openai) return "openai";
    if (creds.has_gemini) return "google-gemini";
    if (std.mem.eql(u8, settings.default_provider, "faux")) return "faux";
    return "faux";
}

fn buildPrintFauxConfig(a: std.mem.Allocator, cfg: *const cli_mod.Config, models_extras: []const models_mod.Entry) !ProviderInfo {
    const model = cfg.model orelse try a.dupe(u8, "faux-1");
    return finalize(a, .{
        .provider_name = "faux",
        .api_tag = "faux",
        .model_id = model,
        .api_key = null,
        .auth_token = null,
        .base_url = null,
        .context_window = 1_000_000,
        .max_output = 8192,
        .capabilities = undefined,
    }, cfg, models_extras);
}

fn buildPrintAnthropicConfig(a: std.mem.Allocator, cfg: *const cli_mod.Config, creds: *const PrintCredentials, settings: *const settings_mod.Settings, models_extras: []const models_mod.Entry) !ProviderInfo {
    if (creds.api_key == null and creds.auth_token == null) return error.MissingApiKey;
    const model = cfg.model orelse try a.dupe(u8, resolveAnthropicAlias(settings.default_model_anthropic));
    const resolved_model = resolveAnthropicAlias(model);
    return finalize(a, .{
        .provider_name = "anthropic",
        .api_tag = "anthropic-messages",
        .model_id = resolved_model,
        .api_key = creds.api_key,
        .auth_token = creds.auth_token,
        .base_url = null,
        .context_window = 1_000_000,
        .max_output = 8192,
        .capabilities = undefined,
    }, cfg, models_extras);
}

fn buildPrintOpenaiConfig(a: std.mem.Allocator, cfg: *const cli_mod.Config, creds: *const PrintCredentials, settings: *const settings_mod.Settings, models_extras: []const models_mod.Entry) !ProviderInfo {
    if (creds.openai_api_key == null and creds.api_key == null) return error.MissingApiKey;
    const actual_key = creds.openai_api_key orelse creds.api_key;
    const model = cfg.model orelse try a.dupe(u8, settings.default_model_openai);
    return finalize(a, .{
        .provider_name = "openai",
        .api_tag = "openai-chat-completions",
        .model_id = model,
        .api_key = actual_key,
        .auth_token = null,
        .base_url = null,
        .context_window = 1_000_000,
        .max_output = 8192,
        .capabilities = undefined,
    }, cfg, models_extras);
}

fn buildPrintGatewayConfig(a: std.mem.Allocator, cfg: *const cli_mod.Config, environ: std.process.Environ, creds: *const PrintCredentials, auth_state: ?auth_mod.Auth, models_extras: []const models_mod.Entry) !ProviderInfo {
    const gateway_file = if (auth_state) |as| as.get("gateway") else null;
    const base_url_str: ?[]const u8 = cfg.base_url orelse blk: {
        if (environ.getPosix("FRANKY_GATEWAY_URL")) |u| break :blk try a.dupe(u8, u);
        if (environ.getPosix("OPENAI_BASE_URL")) |u| break :blk try a.dupe(u8, u);
        break :blk null;
    };
    const effective_key: ?[]const u8 = cfg.api_key orelse creds.openai_api_key orelse blk: {
        if (environ.getPosix("FRANKY_GATEWAY_TOKEN")) |t| break :blk try a.dupe(u8, t);
        if (gateway_file) |rec| if (rec.api_key) |k| break :blk try a.dupe(u8, k);
        break :blk null;
    };
    const model = cfg.model orelse try a.dupe(u8, "gpt-4o");
    return finalize(a, .{
        .provider_name = "gateway",
        .api_tag = "openai-compatible-gateway",
        .model_id = model,
        .api_key = effective_key,
        .auth_token = cfg.auth_token,
        .base_url = base_url_str,
        .context_window = 1_000_000,
        .max_output = 8192,
        .capabilities = undefined,
    }, cfg, models_extras);
}

fn buildPrintGeminiConfig(a: std.mem.Allocator, cfg: *const cli_mod.Config, creds: *const PrintCredentials, models_extras: []const models_mod.Entry) !ProviderInfo {
    const model = cfg.model orelse try a.dupe(u8, "gemini-2.5-pro");
    const actual_key = creds.gemini_api_key orelse
        if (cfg.api_key) |k| k else null;
    return finalize(a, .{
        .provider_name = "google-gemini",
        .api_tag = "google-gemini",
        .model_id = model,
        .api_key = actual_key,
        .auth_token = creds.gemini_auth_token,
        .base_url = null,
        .context_window = 1_000_000,
        .max_output = 8192,
        .capabilities = undefined,
    }, cfg, models_extras);
}

/// Post-process a `ProviderInfo`: consult the models catalog for
/// the chosen model id, and if a match exists, upgrade the
/// context_window/max_output/capabilities from the Entry. Callers
/// can still override by passing `--context-window` (TODO) etc.
fn finalize(
    arena_alloc: std.mem.Allocator,
    info_in: ProviderInfo,
    cfg: *const cli_mod.Config,
    extras: []const models_mod.Entry,
) !ProviderInfo {
    _ = arena_alloc;
    var info = info_in;
    if (models_mod.lookup(extras, info.model_id)) |entry| {
        info.context_window = entry.context_window;
        info.max_output = entry.max_output;
        info.capabilities = .{
            .vision = entry.capabilities.vision,
            .tool_use = entry.capabilities.tool_use,
            // Thinking stays user-controlled: if the user passed
            // `--thinking <level>` explicitly, light it up even if
            // the catalog says the model doesn't support reasoning
            // (the provider layer will reject gracefully).
            .reasoning = if (cfg.thinking != .off) true else entry.capabilities.reasoning,
            .cache = entry.capabilities.cache,
            .streaming = entry.capabilities.streaming,
        };
    } else {
        // Unknown model id — keep the hardcoded defaults but still
        // honor `--thinking`.
        info.capabilities = .{
            .tool_use = true,
            .reasoning = cfg.thinking != .off,
        };
    }
    return info;
}

/// Compute the path to `auth.json` from `FRANKY_HOME` or `HOME`.
/// Returns a slice allocated on `arena_alloc` or null if neither
/// env var is set.
fn authJsonPath(
    arena_alloc: std.mem.Allocator,
    environ: std.process.Environ,
) !?[]const u8 {
    const franky_home: ?[]const u8 = environ.getPosix("FRANKY_HOME");
    const home: ?[]const u8 = environ.getPosix("HOME");
    return authJsonPathFrom(arena_alloc, franky_home, home);
}

/// Pure-logic variant testable without a real `Environ`. Precedence:
/// `FRANKY_HOME/auth.json` > `HOME/.franky/auth.json` > null.
pub fn authJsonPathFrom(
    arena_alloc: std.mem.Allocator,
    franky_home: ?[]const u8,
    home: ?[]const u8,
) !?[]const u8 {
    if (franky_home) |h| {
        return try std.fs.path.join(arena_alloc, &.{ h, "auth.json" });
    }
    if (home) |h| {
        return try std.fs.path.join(arena_alloc, &.{ h, ".franky", "auth.json" });
    }
    return null;
}

/// Pure-logic variant for `models.json`. Same precedence as
/// `authJsonPathFrom`: `$FRANKY_HOME/models.json` >
/// `$HOME/.franky/models.json` > null (§H.3, v1.5.2).
pub fn modelsJsonPathFrom(
    arena_alloc: std.mem.Allocator,
    franky_home: ?[]const u8,
    home: ?[]const u8,
) !?[]const u8 {
    if (franky_home) |h| {
        return try std.fs.path.join(arena_alloc, &.{ h, "models.json" });
    }
    if (home) |h| {
        return try std.fs.path.join(arena_alloc, &.{ h, ".franky", "models.json" });
    }
    return null;
}

/// Pure-logic variant for `system.md`. Same precedence as
/// `authJsonPathFrom`: `$FRANKY_HOME/system.md` >
/// `$HOME/.franky/system.md` > null (§D, v1.5.2).
pub fn systemMdPathFrom(
    arena_alloc: std.mem.Allocator,
    franky_home: ?[]const u8,
    home: ?[]const u8,
) !?[]const u8 {
    if (franky_home) |h| {
        return try std.fs.path.join(arena_alloc, &.{ h, "system.md" });
    }
    if (home) |h| {
        return try std.fs.path.join(arena_alloc, &.{ h, ".franky", "system.md" });
    }
    return null;
}

// ─── Session state — shared with other modes via session.create ──
//
// The `SessionState` struct and its init/deinit/id/persist methods
// live in `coding/session/create.zig` to avoid duplication across
// mode drivers. Print mode re-exports `ProviderInfo` for the same
// reason.

const SessionState = session_create.SessionState;

// ─── system prompt ───────────────────────────────────────────────

pub const default_system_prompt: []const u8 =
    \\You are franky, an AI coding agent.
    \\
    \\You can read and edit files in the user's workspace, run shell
    \\commands, and search with ls/find/grep. Prefer focused edits over
    \\large rewrites. When asked to change code, first read the relevant
    \\files, then propose and apply minimal diffs.
    \\
    \\If a task needs information you don't have, use your tools to
    \\gather it. Do not guess file contents.
    \\
    \\When a sub-agent reports `ok: true`, trust its result and move on.
    \\Do not re-read files to verify the sub-agent's work — the work is
    \\done. Only re-investigate when the sub-agent reports `ok: false` or
    \\its `final_text` describes a problem. Re-verifying successful
    \\sub-agent runs wastes tokens and tends to revert correct edits.
;

pub fn buildSystemPrompt(allocator: std.mem.Allocator, cfg: *const cli_mod.Config) ![]u8 {
    if (cfg.system_prompt) |s| return try allocator.dupe(u8, s);
    if (cfg.append_system_prompt) |extra| {
        return try std.fmt.allocPrint(allocator, "{s}\n\n{s}", .{ default_system_prompt, extra });
    }
    return try allocator.dupe(u8, default_system_prompt);
}

/// v1.5.2 — io-aware system-prompt loader. Precedence (highest →
/// lowest): `--system-prompt` > `$FRANKY_HOME/system.md` or
/// `$HOME/.franky/system.md` > built-in `default_system_prompt`.
/// `--append-system-prompt` is appended to whichever base won.
/// Missing `system.md` is a silent fallback, not an error.
pub fn buildSystemPromptIo(
    allocator: std.mem.Allocator,
    io: ?std.Io,
    environ: std.process.Environ,
    cfg: *const cli_mod.Config,
) ![]u8 {
    if (cfg.system_prompt) |s| return try allocator.dupe(u8, s);

    // Try the disk template. On any read failure, fall back silently.
    var base: []u8 = undefined;
    var base_owned = true;
    var loaded_from_disk = false;
    if (io) |ioref| {
        const franky_home: ?[]const u8 = environ.getPosix("FRANKY_HOME");
        const home: ?[]const u8 = environ.getPosix("HOME");
        const path = systemMdPathFrom(allocator, franky_home, home) catch null;
        if (path) |p| {
            defer allocator.free(p);
            if (readWholeFileOpt(allocator, ioref, p)) |bytes| {
                base = bytes;
                loaded_from_disk = true;
            }
        }
    }
    if (!loaded_from_disk) {
        base = try allocator.dupe(u8, default_system_prompt);
    }
    defer if (base_owned) allocator.free(base);

    // v2.4.0 — inject the real working directory so the model
    // doesn't hallucinate its own cwd before checking with pwd.
    // Prepend "Current folder: <pwd>" as the very first line.
    if (environ.getPosix("PWD")) |pwd| {
        const trimmed = std.mem.trimEnd(u8, base, &std.ascii.whitespace);
        const inj = try std.fmt.allocPrint(allocator, "Current folder: {s}\n\n{s}", .{ pwd, trimmed });
        allocator.free(base);
        base = inj;
        // base_owned remains true (we just replaced the buffer)
    }

    // v1.24.1 — append a concise subagent hint when we're using
    // the built-in default prompt. Skipped for disk-loaded prompts
    // (operator chose their own wording — don't muck with it).
    // Profile list is interpolated at runtime; falls back to a
    // static placeholder if the lookup fails.
    var with_hint: []u8 = base;
    var hint_owned = false;
    if (!loaded_from_disk) {
        const hint = try buildSubagentHint(allocator, io, cfg);
        defer allocator.free(hint);
        if (hint.len > 0) {
            const trimmed = std.mem.trimEnd(u8, base, &std.ascii.whitespace);
            with_hint = try std.fmt.allocPrint(allocator, "{s}\n\n{s}", .{ trimmed, hint });
            hint_owned = true;
        }
    }
    defer if (hint_owned) allocator.free(with_hint);


    // AGENTS.md / CLAUDE.md instructions block (v2.30 design doc).
    // Scanned from workspace at startup; injected after subagent hint,
    // before skills. Skipped when --no-standards suppresses the scan.
    var with_instructions: []u8 = with_hint;
    var instructions_owned = false;
    if (io) |ioref| instructions_block: {
        const pwd = environ.getPosix("PWD");
        const pp = pwd orelse break :instructions_block;
        if (cfg.no_standards) break :instructions_block;
        var state = instructions_mod.InstructionsState.scan(allocator, ioref, pp) catch break :instructions_block;
        defer state.deinit(allocator);
        const block = state.rendered orelse break :instructions_block;
        const trimmed = std.mem.trimEnd(u8, with_hint, &std.ascii.whitespace);
        with_instructions = std.fmt.allocPrint(allocator, "{s}\n\n{s}", .{ trimmed, block }) catch break :instructions_block;
        instructions_owned = true;
    }
    defer if (instructions_owned) allocator.free(with_instructions);

    // Skills layer (§6.1). Each active skill's body is appended
    // verbatim under `## Active skills`. Activation is deterministic:
    // explicit `--skill NAME` and/or `auto_apply` glob match against
    // the workspace tree. Skipped silently when no `io` (pure-logic
    // path used by tests).
    var with_skills: []u8 = with_instructions;
    var skills_owned = false;
    if (io) |ioref| skills_block: {
        const pwd = environ.getPosix("PWD");

        var workspace_skills_root: ?[]u8 = null;
        defer if (workspace_skills_root) |b| allocator.free(b);
        if (pwd) |p| {
            workspace_skills_root = std.fs.path.join(allocator, &.{ p, "skills" }) catch null;
        }

        var user_skills_root: ?[]u8 = null;
        defer if (user_skills_root) |b| allocator.free(b);
        if (environ.getPosix("FRANKY_HOME")) |h| {
            user_skills_root = std.fs.path.join(allocator, &.{ h, "skills" }) catch null;
        } else if (environ.getPosix("HOME")) |h| {
            user_skills_root = std.fs.path.join(allocator, &.{ h, ".franky", "skills" }) catch null;
        }

        var loaded = skills_mod.loadAll(allocator, ioref, .{
            .explicit_root = cfg.skills_path,
            .workspace_root = workspace_skills_root,
            .user_root = user_skills_root,
        }) catch break :skills_block;
        defer {
            for (loaded.items) |*s| s.deinit(allocator);
            loaded.deinit(allocator);
        }
        if (loaded.items.len == 0) break :skills_block;

        var explicit_list: std.ArrayList([]const u8) = .empty;
        defer explicit_list.deinit(allocator);
        if (cfg.skills_select_csv) |csv| {
            var it = std.mem.tokenizeScalar(u8, csv, ',');
            while (it.next()) |tok| {
                const trimmed = std.mem.trim(u8, tok, " \t");
                if (trimmed.len > 0) explicit_list.append(allocator, trimmed) catch break :skills_block;
            }
        }

        var active = skills_mod.selectActive(
            allocator,
            ioref,
            loaded.items,
            pwd,
            explicit_list.items,
        ) catch break :skills_block;
        defer active.deinit(allocator);
        if (active.items.len == 0) break :skills_block;

        const section = skills_mod.renderSection(allocator, loaded.items, active.items) catch break :skills_block;
        defer allocator.free(section);

        const trimmed = std.mem.trimEnd(u8, with_hint, &std.ascii.whitespace);
        with_skills = std.fmt.allocPrint(allocator, "{s}\n\n{s}", .{ trimmed, section }) catch break :skills_block;
        skills_owned = true;
    }
    defer if (skills_owned) allocator.free(with_skills);

    // v2.16 — inject review configuration block when the multimodel-review
    // skill is active and profiles are configured. Append after skills so
    // the model sees both the skill instructions and the config in order.
    var with_review: []u8 = with_skills;
    var review_owned = false;
    if (cfg.review_config_block) |block| {
        if (io) |ioref| review_check: {
            // Check whether multimodel-review is among the loaded (and thus
            // active) skills by scanning the loaded list via a fresh load.
            const pwd = environ.getPosix("PWD");
            var workspace_skills_r: ?[]u8 = null;
            defer if (workspace_skills_r) |b| allocator.free(b);
            if (pwd) |p| {
                workspace_skills_r = std.fs.path.join(allocator, &.{ p, "skills" }) catch null;
            }
            var user_skills_r: ?[]u8 = null;
            defer if (user_skills_r) |b| allocator.free(b);
            if (environ.getPosix("FRANKY_HOME")) |h| {
                user_skills_r = std.fs.path.join(allocator, &.{ h, "skills" }) catch null;
            } else if (environ.getPosix("HOME")) |h| {
                user_skills_r = std.fs.path.join(allocator, &.{ h, ".franky", "skills" }) catch null;
            }
            var loaded = skills_mod.loadAll(allocator, ioref, .{
                .explicit_root = cfg.skills_path,
                .workspace_root = workspace_skills_r,
                .user_root = user_skills_r,
            }) catch break :review_check;
            defer {
                for (loaded.items) |*s| s.deinit(allocator);
                loaded.deinit(allocator);
            }
            const skill_active = for (loaded.items) |s| {
                if (std.mem.eql(u8, s.meta.name, "multimodel-review")) break true;
            } else false;

            if (skill_active) {
                const trimmed = std.mem.trimEnd(u8, with_skills, &std.ascii.whitespace);
                with_review = try std.fmt.allocPrint(
                    allocator,
                    "{s}\n\n{s}\n",
                    .{ trimmed, block },
                );
                review_owned = true;
            }
        }
    }
    defer if (review_owned) allocator.free(with_review);

    // v3.0 — compression hint: tell the LLM about CCR markers
    var with_compression: []u8 = with_review;
    var compression_owned = false;
    if (cfg.compress) {
        const trimmed = std.mem.trimEnd(u8, if (review_owned) with_review else with_skills, &std.ascii.whitespace);
        with_compression = try std.fmt.allocPrint(
            allocator,
            "{s}\n\n## Compression\n\n" ++
            "When tool output contains `<<<ccr:<hash> N_rows_offloaded>>>` markers, " ++
            "the original content was compressed to save context. You can retrieve " ++
            "the full original content by calling the `ccr_retrieve` tool with the " ++
            "hash key. Do NOT guess or hallucinate the content behind a marker — " ++
            "always use the retrieval tool if you need details.\n",
            .{trimmed},
        );
        compression_owned = true;
    }
    defer if (compression_owned) allocator.free(with_compression);

    if (cfg.append_system_prompt) |extra| {
        const trimmed = std.mem.trimEnd(u8, if (compression_owned) with_compression else if (review_owned) with_review else with_skills, &std.ascii.whitespace);
        const out = try std.fmt.allocPrint(allocator, "{s}\n\n{s}", .{ trimmed, extra });
        return out;
    }
    if (compression_owned) {
        compression_owned = false;
        return with_compression;
    }
    if (review_owned) {
        review_owned = false;
        return with_review;
    }
    if (skills_owned) {
        skills_owned = false;
        return with_skills;
    }
    if (hint_owned) {
        // Transfer ownership of with_hint to the caller.
        hint_owned = false;
        return with_hint;
    }
    base_owned = false;
    return base;
}

/// v1.24.1 — concise subagent guidance for the system prompt.
/// Empty string when there are no profiles to list (degenerate
/// case — pointless paragraph). Caller frees.
fn buildSubagentHint(
    allocator: std.mem.Allocator,
    io: ?std.Io,
    cfg: *const cli_mod.Config,
) ![]u8 {
    _ = cfg;
    const ioref = io orelse return try allocator.dupe(u8, "");
    // Build a borrowed environ_map view for the profiles helper.
    // The helper needs a *Map; we don't have a stable one here, so
    // synthesize a transient one from the standard env. Empty map
    // is fine — it just means no `${VAR}` interpolation in profile
    // bodies, which is irrelevant for name-listing.
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    const profile_list = profiles_mod.listProfileNamesCSV(allocator, ioref, &env_map) catch return try allocator.dupe(u8, "");
    defer allocator.free(profile_list);
    if (profile_list.len == 0) return try allocator.dupe(u8, "");
    return try std.fmt.allocPrint(allocator,
        "You also have a `subagent` tool that spawns an isolated agent with its own model. Use it for parallel sub-tasks or when a different profile fits the work better — skip it for single tool calls. Profiles: {s}.",
        .{profile_list},
    );
}

// ─── helpers ────────────────────────────────────────────────────

fn fauxShim(ctx: ai.registry.StreamCtx) anyerror!void {
    const faux_ptr: *ai.providers.faux.FauxProvider = @ptrCast(@alignCast(ctx.userdata.?));
    try faux_ptr.runSync(ctx.io, ctx.context, ctx.out);
}

fn writeOut(io: std.Io, s: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    w.interface.writeAll(s) catch {};
    w.interface.flush() catch {};
}

pub fn exitWithMessage(io: std.Io, msg: []const u8, code: u8) !void {
    var buf: [1024]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    w.interface.writeAll(msg) catch {};
    w.interface.flush() catch {};
    std.process.exit(code);
}

/// Format a stderr message with `args`, write it, and exit with `code`.
/// Collapses the common `allocPrint+defer free+exitWithMessage` triple.
fn exitFmtErr(
    allocator: std.mem.Allocator,
    io: std.Io,
    comptime fmt: []const u8,
    args: anytype,
    code: u8,
) !void {
    const msg = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(msg);
    return exitWithMessage(io, msg, code);
}

const update_usage =
    \\Usage: franky update [--check] [--force] [--repo owner/name]
    \\
    \\Replace the running franky binary with the latest GitHub release.
    \\
    \\  --check                Print the latest tag and exit (no replace).
    \\  --force                Replace even when versions match.
    \\  --repo owner/name      Override the GitHub repo. Defaults to
    \\                         $FRANKY_UPDATE_REPO or fr12k/franky.
    \\
    \\Env:
    \\  FRANKY_UPDATE_REPO     owner/name fallback for --repo.
    \\  FRANKY_UPDATE_BASE_URL Override https://api.github.com (tests).
    \\
;

/// Handle `franky update [...]`. Owns its own arena so it doesn't
/// share lifetime with the main `Config`.
fn runUpdate(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    args: []const []const u8,
) !void {
    // v1.19.0 — init logging early so the update subcommand's
    // log.log(...) calls reach the user (the main dispatch path
    // initialises logging after parsing, but the update subcommand
    // is dispatched before that).
    {
        const log_level = resolveLogLevelMap(environ_map);
        ai.log.init(io, log_level);
    }
    defer ai.log.deinit();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var opts = franky.coding.update.Options{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--check")) {
            opts.dry_run = true;
        } else if (std.mem.eql(u8, a, "--force")) {
            opts.force = true;
        } else if (std.mem.eql(u8, a, "--repo")) {
            i += 1;
            if (i >= args.len) return exitWithMessage(io, "--repo requires a value (owner/name)\n", 2);
            const ok = parseRepoSpec(args[i], &opts);
            if (!ok) return exitWithMessage(io, "--repo expects 'owner/name'\n", 2);
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            return writeOut(io, update_usage);
        } else {
            return exitFmtErr(allocator, io, "unknown flag: {s}\n", .{a}, 2);
        }
    }

    if (!opts.repo_explicit) {
        if (environ_map.get("FRANKY_UPDATE_REPO")) |env_repo| {
            if (!parseRepoSpec(env_repo, &opts)) {
                return exitWithMessage(io, "FRANKY_UPDATE_REPO must be 'owner/name'\n", 2);
            }
        }
    }
    if (environ_map.get("FRANKY_UPDATE_BASE_URL")) |env_base| {
        opts.base_url = env_base;
    }

    const outcome = franky.coding.update.run(arena, io, franky.version, .{
        .force = opts.force,
        .dry_run = opts.dry_run,
        .repo_owner = opts.repo_owner,
        .repo_name = opts.repo_name,
        .repo_explicit = opts.repo_explicit,
        .base_url = opts.base_url,
        .environ_map = environ_map,
    }) catch |err| {
        const reason: []const u8 = switch (err) {
            error.UnsupportedPlatform => "unsupported platform — releases ship only macOS/Linux on amd64/arm64 (+ linux/386)",
            error.HttpFailure => "failed to reach GitHub releases API",
            error.ReleaseApiFailed => "failed to reach GitHub releases API",
            error.ChecksumDownloadFailed => "failed to download checksums.txt from GitHub releases",
            error.BinaryDownloadFailed => "failed to download binary asset from GitHub releases",
            error.ReleaseParseFailed => "could not parse the GitHub releases response",
            error.AssetNotFound => "no matching binary asset in the latest release",
            error.ChecksumMissing => "no checksums.txt asset (or our entry was missing)",
            error.ChecksumMismatch => "checksum mismatch — refusing to replace binary",
            error.ReplaceFailed => "could not replace the running binary (permissions?)",
            error.OutOfMemory => "out of memory",
        };
        return exitFmtErr(allocator, io, "franky update: {s}\n", .{reason}, 1);
    };

    switch (outcome) {
        .up_to_date => |tag| {
            const msg = try std.fmt.allocPrint(allocator, "franky {s} is already up to date (latest: {s})\n", .{ franky.version, tag });
            defer allocator.free(msg);
            return writeOut(io, msg);
        },
        .updated => |u| {
            const verb: []const u8 = if (opts.dry_run) "would update" else "updated";
            const msg = try std.fmt.allocPrint(allocator, "{s} franky {s} -> {s}\n", .{ verb, u.from, u.to });
            defer allocator.free(msg);
            return writeOut(io, msg);
        },
    }
}

fn parseRepoSpec(spec: []const u8, opts: *franky.coding.update.Options) bool {
    const slash = std.mem.indexOfScalar(u8, spec, '/') orelse return false;
    if (slash == 0 or slash == spec.len - 1) return false;
    opts.repo_owner = spec[0..slash];
    opts.repo_name = spec[slash + 1 ..];
    opts.repo_explicit = true;
    return true;
}

const replay_usage =
    \\Usage: franky replay <trace_file> [--diff <expected.jsonl>]
    \\
    \\Read a captured `--http-trace-dir` file, feed the response body
    \\through the matching provider's SSE parser, and emit one canonical
    \\JSON object per StreamEvent to stdout.
    \\
    \\  --diff PATH    Compare the emitted JSONL against PATH; exit 1 on drift,
    \\                 with the first divergent line printed to stderr. Useful
    \\                 as a regression-test trip in CI.
    \\
;

fn runReplaySubcommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: []const []const u8,
) !void {
    var trace_path: ?[]const u8 = null;
    var diff_path: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            return writeOut(io, replay_usage);
        } else if (std.mem.eql(u8, a, "--diff")) {
            i += 1;
            if (i >= args.len) return exitWithMessage(io, "--diff requires a path\n", 2);
            diff_path = args[i];
        } else if (a.len > 0 and a[0] == '-') {
            return exitFmtErr(allocator, io, "unknown flag: {s}\n", .{a}, 2);
        } else if (trace_path == null) {
            trace_path = a;
        } else {
            return exitWithMessage(io, "replay accepts at most one trace file\n", 2);
        }
    }

    const path = trace_path orelse return exitWithMessage(io, "missing <trace_file>; see `franky replay --help`\n", 2);

    const trace_text = readWholeFileOpt(allocator, io, path) orelse
        return exitFmtErr(allocator, io, "replay: cannot read {s}\n", .{path}, 1);
    defer allocator.free(trace_text);

    const trace = franky.coding.replay.parseTraceFile(trace_text) catch |err|
        return exitFmtErr(allocator, io, "replay: {s}\n", .{@errorName(err)}, 1);

    var captured = std.Io.Writer.Allocating.init(allocator);
    defer captured.deinit();
    _ = franky.coding.replay.runReplay(allocator, io, trace, &captured.writer) catch |err|
        return exitFmtErr(allocator, io, "replay: parser failed: {s}\n", .{@errorName(err)}, 1);
    const actual = captured.written();

    if (diff_path) |dp| {
        const expected = readWholeFileOpt(allocator, io, dp) orelse
            return exitFmtErr(allocator, io, "replay: cannot read {s}\n", .{dp}, 1);
        defer allocator.free(expected);
        if (franky.coding.replay.compareJsonl(expected, actual)) |d| {
            return exitFmtErr(
                allocator,
                io,
                "replay: mismatch at line {d}\n  expected: {s}\n  actual:   {s}\n",
                .{ d.line, d.expected, d.actual },
                1,
            );
        }
        return; // match → stay silent, exit 0
    }

    return writeOut(io, actual);
}

const fixture_usage =
    \\Usage: franky fixture <trace_file> [--name SCENARIO] [--out DIR]
    \\
    \\Promote a captured `--http-trace-dir` file into a regression fixture.
    \\Reads the trace, redacts sensitive URL params (key=, access_token=, …),
    \\writes the scrubbed copy to <out>/<provider>/<scenario>/trace.txt, runs
    \\replay against it, and writes the canonical event sequence to
    \\<out>/<provider>/<scenario>/events.jsonl. The walker test picks up new
    \\fixtures automatically — no per-fixture wiring.
    \\
    \\  --name SCENARIO    Sub-directory name (default: filename stem with the
    \\                     trailing `-<provider>` stripped, e.g.
    \\                     `1777591322854-0000-google-gemini.txt` →
    \\                     `1777591322854-0000`). Rename the dir later for a
    \\                     descriptive label.
    \\  --out DIR          Fixture root (default: test/fixtures).
    \\  --force            Overwrite an existing fixture dir.
    \\
;

fn runFixtureSubcommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: []const []const u8,
) !void {
    var trace_path: ?[]const u8 = null;
    var name_override: ?[]const u8 = null;
    var out_root: []const u8 = "test/fixtures";
    var force = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            return writeOut(io, fixture_usage);
        } else if (std.mem.eql(u8, a, "--name")) {
            i += 1;
            if (i >= args.len) return exitWithMessage(io, "--name requires a value\n", 2);
            name_override = args[i];
        } else if (std.mem.eql(u8, a, "--out")) {
            i += 1;
            if (i >= args.len) return exitWithMessage(io, "--out requires a value\n", 2);
            out_root = args[i];
        } else if (std.mem.eql(u8, a, "--force")) {
            force = true;
        } else if (a.len > 0 and a[0] == '-') {
            return exitFmtErr(allocator, io, "unknown flag: {s}\n", .{a}, 2);
        } else if (trace_path == null) {
            trace_path = a;
        } else {
            return exitWithMessage(io, "fixture accepts at most one trace file\n", 2);
        }
    }

    const path = trace_path orelse return exitWithMessage(io, "missing <trace_file>; see `franky fixture --help`\n", 2);

    const redacted = blk: {
        const trace_text = readWholeFileOpt(allocator, io, path) orelse
            return exitFmtErr(allocator, io, "fixture: cannot read {s}\n", .{path}, 1);
        defer allocator.free(trace_text);
        break :blk franky.coding.replay.redactTraceText(allocator, trace_text) catch |e|
            return exitFmtErr(allocator, io, "fixture: redact failed: {s}\n", .{@errorName(e)}, 1);
    };
    defer allocator.free(redacted);

    const trace = franky.coding.replay.parseTraceFile(redacted) catch |e|
        return exitFmtErr(allocator, io, "fixture: parse failed: {s}\n", .{@errorName(e)}, 1);

    // Default scenario name strips the `-<provider>` suffix so the dir
    // path doesn't redundantly repeat the provider segment.
    const scenario = name_override orelse blk: {
        const base = std.fs.path.basename(path);
        const stem = std.fs.path.stem(base);
        const provider_suffix = std.fmt.allocPrint(allocator, "-{s}", .{trace.provider}) catch
            return exitWithMessage(io, "fixture: out of memory\n", 1);
        defer allocator.free(provider_suffix);
        if (std.mem.endsWith(u8, stem, provider_suffix)) {
            break :blk stem[0 .. stem.len - provider_suffix.len];
        }
        break :blk stem;
    };

    const fixture_dir = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ out_root, trace.provider, scenario });
    defer allocator.free(fixture_dir);
    const trace_out = try std.fmt.allocPrint(allocator, "{s}/trace.txt", .{fixture_dir});
    defer allocator.free(trace_out);
    const events_out = try std.fmt.allocPrint(allocator, "{s}/events.jsonl", .{fixture_dir});
    defer allocator.free(events_out);

    const cwd = std.Io.Dir.cwd();

    // Probe the actual fixture file (not the parent dir) so adjacent
    // scenarios sharing a `<provider>/` parent don't false-positive
    // each other, and so an earlier aborted run that left an empty
    // dir doesn't block a fresh fixture.
    if (!force) {
        if (cwd.openFile(io, trace_out, .{})) |existing| {
            var f = existing;
            f.close(io);
            return exitFmtErr(
                allocator,
                io,
                "fixture: {s} already exists; pass --force to overwrite\n",
                .{trace_out},
                1,
            );
        } else |_| {}
    }

    cwd.createDirPath(io, fixture_dir) catch |e|
        return exitFmtErr(allocator, io, "fixture: cannot create {s}: {s}\n", .{ fixture_dir, @errorName(e) }, 1);

    try writeFixtureFile(allocator, io, cwd, trace_out, redacted);

    var captured = std.Io.Writer.Allocating.init(allocator);
    defer captured.deinit();
    _ = franky.coding.replay.runReplay(allocator, io, trace, &captured.writer) catch |e|
        return exitFmtErr(allocator, io, "fixture: replay failed: {s}\n", .{@errorName(e)}, 1);

    try writeFixtureFile(allocator, io, cwd, events_out, captured.written());

    const summary = try std.fmt.allocPrint(
        allocator,
        "✓ fixture: {s}\n  provider={s} scenario={s}\n  trace.txt    ({d} bytes)\n  events.jsonl ({d} bytes)\n  → run `zig build test` to verify the walker picks it up\n",
        .{ fixture_dir, trace.provider, scenario, redacted.len, captured.written().len },
    );
    defer allocator.free(summary);
    return writeOut(io, summary);
}

fn writeFixtureFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    path: []const u8,
    content: []const u8,
) !void {
    var f = cwd.createFile(io, path, .{}) catch |e|
        return exitFmtErr(allocator, io, "fixture: cannot write {s}: {s}\n", .{ path, @errorName(e) }, 1);
    defer f.close(io);
    f.writeStreamingAll(io, content) catch |e|
        return exitFmtErr(allocator, io, "fixture: write failed for {s}: {s}\n", .{ path, @errorName(e) }, 1);
}

// ─── franky doctor ────────────────────────────────────────────────────────────

const doctor_usage =
    \\Usage: franky doctor <session_id> [options]
    \\       franky doctor --list
    \\
    \\Walk a saved session's transcript, detect per-turn anomalies (degenerate
    \\turns, prose tool calls, thinking-budget exhaustion, tool errors), and
    \\emit a human-readable report with suggested recovery actions and
    \\`franky fixture` promotion hints for any stored trace files.
    \\
    \\  <session_id>         ULID of the session to analyze (looks up
    \\                       <FRANKY_HOME>/sessions/<session_id>/).
    \\  --session-dir PATH   Explicit session directory (overrides session_id
    \\                       lookup; useful for sub-agent session dirs).
    \\  --trace-dir PATH     Directory containing `--http-trace-dir` captures.
    \\                       When set, per-turn anomalies link to their trace
    \\                       file and print a `franky fixture` promotion hint.
    \\  --no-persist         Print to stdout only; don't write the TXT report
    \\                       or summary.json under <FRANKY_HOME>/diagnostics/.
    \\  --list               List saved sessions with their anomaly summary
    \\                       (reads summary.json from each diagnostics dir).
    \\  -h, --help           Print this help and exit.
    \\
    \\environment:
    \\  FRANKY_HOME          Resolves sessions/ and diagnostics/ roots
    \\                       (default: $HOME/.franky).
    \\
    \\Note: `franky doctor` inspects a single session. For cross-session
    \\pattern analysis run `zig build doctor` (the improvement analyzer).
    \\
;

fn runDoctorSubcommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    args: []const []const u8,
) !void {
    var session_id: ?[]const u8 = null;
    var session_dir_arg: ?[]const u8 = null;
    var trace_dir_arg: ?[]const u8 = null;
    var no_persist = false;
    var list_mode = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            return writeOut(io, doctor_usage);
        } else if (std.mem.eql(u8, a, "--list")) {
            list_mode = true;
        } else if (std.mem.eql(u8, a, "--no-persist")) {
            no_persist = true;
        } else if (std.mem.eql(u8, a, "--session-dir")) {
            i += 1;
            if (i >= args.len) return exitWithMessage(io, "--session-dir requires a path\n", 2);
            session_dir_arg = args[i];
        } else if (std.mem.eql(u8, a, "--trace-dir")) {
            i += 1;
            if (i >= args.len) return exitWithMessage(io, "--trace-dir requires a path\n", 2);
            trace_dir_arg = args[i];
        } else if (a.len > 0 and a[0] == '-') {
            return exitFmtErr(allocator, io, "doctor: unknown flag: {s}\n", .{a}, 2);
        } else if (session_id == null) {
            session_id = a;
        } else {
            return exitWithMessage(io, "doctor: too many positional arguments\n", 2);
        }
    }

    const franky_home = diagnostics_mod.resolveFrankyHome(allocator, environ_map) catch null;
    defer if (franky_home) |fh| allocator.free(fh);

    if (list_mode) {
        return runDoctorList(allocator, io, franky_home);
    }

    // Resolve session directory.
    const session_dir: []const u8 = if (session_dir_arg) |sd|
        sd
    else if (session_id) |sid| blk: {
        const fh = franky_home orelse
            return exitWithMessage(io, "doctor: FRANKY_HOME or HOME must be set to look up a session\n", 2);
        break :blk try std.fs.path.join(allocator, &.{ fh, "sessions", sid });
    } else {
        return exitWithMessage(io, "doctor: provide a session_id or --session-dir, or use --list\n", 2);
    };
    defer if (session_dir_arg == null and session_id != null) allocator.free(session_dir);

    // Load session header (provider + model) and transcript.
    const header = session_mod.readSessionHeader(allocator, io, session_dir) catch |err|
        return exitFmtErr(allocator, io, "doctor: cannot load session header from {s}: {s}\n", .{ session_dir, @errorName(err) }, 1);
    defer session_mod.freeSessionHeader(allocator, header);

    var transcript = session_mod.readTranscript(allocator, io, session_dir) catch |err|
        return exitFmtErr(allocator, io, "doctor: cannot load transcript from {s}: {s}\n", .{ session_dir, @errorName(err) }, 1);
    defer transcript.deinit();

    const diag_opts: diagnostics_mod.Options = .{
        .transcript = transcript.messages.items,
        .http_trace_dir = trace_dir_arg,
        .session_dir = session_dir,
        .session_label = session_id,
        .mode_name = "print",
        .provider = if (header.provider.len > 0) header.provider else null,
        .model = if (header.model.len > 0) header.model else null,
    };

    const persist_opts: ?diagnostics_mod.PersistOptions = if (!no_persist) blk: {
        const fh = franky_home orelse {
            var ebuf: [512]u8 = undefined;
            var ew = std.Io.File.stderr().writer(io, &ebuf);
            ew.interface.writeAll("doctor: FRANKY_HOME unset — skipping persist (use --no-persist to suppress)\n") catch {};
            ew.interface.flush() catch {};
            break :blk null;
        };
        const sid = session_id orelse std.fs.path.basename(session_dir);
        break :blk .{
            .franky_home = fh,
            .session_id = sid,
            .timestamp_ms = ai.stream.nowMillis(),
        };
    } else null;

    const result = try diagnostics_mod.runAndPersist(allocator, io, diag_opts, persist_opts);
    defer result.deinit(allocator);

    try writeOut(io, result.rendered);
    if (result.persisted_path) |p| {
        const line = try std.fmt.allocPrint(allocator, "\nReport written to: {s}\n", .{p});
        defer allocator.free(line);
        var ebuf: [1024]u8 = undefined;
        var ew = std.Io.File.stderr().writer(io, &ebuf);
        ew.interface.writeAll(line) catch {};
        ew.interface.flush() catch {};
    }
}

/// `franky doctor --list`: walk FRANKY_HOME/diagnostics/ and print a
/// one-liner per session that has a summary.json.
fn runDoctorList(
    allocator: std.mem.Allocator,
    io: std.Io,
    franky_home: ?[]const u8,
) !void {
    const fh = franky_home orelse
        return exitWithMessage(io, "doctor --list: FRANKY_HOME or HOME must be set\n", 2);

    const diag_root = try std.fmt.allocPrint(allocator, "{s}/diagnostics", .{fh});
    defer allocator.free(diag_root);

    var dir = std.Io.Dir.cwd().openDir(io, diag_root, .{ .iterate = true }) catch {
        return writeOut(io, "(no diagnostics directory found — run a session with /diagnostics first)\n");
    };
    defer dir.close(io);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const summary_path = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}/summary.json",
            .{ diag_root, entry.name },
        );
        defer allocator.free(summary_path);

        const json = readWholeFileOpt(allocator, io, summary_path) orelse continue;
        defer allocator.free(json);

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch continue;
        defer parsed.deinit();
        const root = parsed.value.object;

        const model = if (root.get("model")) |v| if (v == .string) v.string else "?" else "?";
        const anomalies = if (root.get("anomaly_counts")) |ac| blk: {
            if (ac != .object) break :blk @as(u32, 0);
            var total: u32 = 0;
            var ac_it = ac.object.iterator();
            while (ac_it.next()) |kv| if (kv.value_ptr.* == .integer) {
                total += @intCast(kv.value_ptr.integer);
            };
            break :blk total;
        } else @as(u32, 0);

        const line = try std.fmt.allocPrint(
            allocator,
            "{s}  model={s}  anomalies={d}\n",
            .{ entry.name, model, anomalies },
        );
        defer allocator.free(line);
        try buf.appendSlice(allocator, line);
    }

    if (buf.items.len == 0) {
        return writeOut(io, "(no sessions with diagnostics found)\n");
    }
    return writeOut(io, buf.items);
}

fn exitWithMessageErr(allocator: std.mem.Allocator, msg: []const u8, code: u8) noreturn {
    _ = allocator;
    // Use direct posix write since we don't have an io handle here.
    std.debug.print("{s}", .{msg});
    std.process.exit(code);
}

/// Read `path` in full; returns null (not an error) if the file is
/// missing or unreadable. Used for optional disk overlays like
/// `models.json` and `system.md` where "file doesn't exist" is the
/// normal fallback — not an error.
fn readWholeFileOpt(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) ?[]u8 {
    const cwd = std.Io.Dir.cwd();
    var f = cwd.openFile(io, path, .{}) catch return null;
    defer f.close(io);
    const len = f.length(io) catch return null;
    const buf = allocator.alloc(u8, @intCast(len)) catch return null;
    const n = f.readPositionalAll(io, buf, 0) catch {
        allocator.free(buf);
        return null;
    };
    return buf[0..n];
}

// ─── tests ───────────────────────────────────────────────────────

const testing = std.testing;
const test_h = @import("../../test_helpers.zig");

test "resolveLogLevel: --log-level wins over env vars + verbose" {
    // Pin the precedence ladder for the now-`pub` resolver so a
    // refactor that re-orders the checks gets caught.
    var cfg = try cli_mod.parse(testing.allocator, &.{
        "franky", "--log-level", "trace",
    });
    defer cfg.deinit();
    const env: std.process.Environ = .empty;
    try testing.expectEqual(ai.log.Level.trace, resolveLogLevel(&cfg, env));
}

test "resolveLogLevel: default is warn" {
    var cfg = try cli_mod.parse(testing.allocator, &.{"franky"});
    defer cfg.deinit();
    const env: std.process.Environ = .empty;
    try testing.expectEqual(ai.log.Level.warn, resolveLogLevel(&cfg, env));
}

test "resolveTimeoutsFromMap: defaults match registry when unset" {
    var cfg = try cli_mod.parse(testing.allocator, &.{"franky"});
    defer cfg.deinit();
    var m = std.process.Environ.Map.init(testing.allocator);
    defer m.deinit();
    const t = resolveTimeoutsFromMap(&cfg, &m);
    try testing.expectEqual(@as(u32, 10_000), t.connect_ms);
    try testing.expectEqual(@as(u32, 30_000), t.first_byte_ms);
    try testing.expectEqual(@as(u32, 60_000), t.event_gap_ms);
}

test "resolveMaxTurnsFromMap: returns null when unset (caller uses default)" {
    var cfg = try cli_mod.parse(testing.allocator, &.{"franky"});
    defer cfg.deinit();
    var m = std.process.Environ.Map.init(testing.allocator);
    defer m.deinit();
    try testing.expectEqual(@as(?u32, null), resolveMaxTurnsFromMap(&cfg, &m));
}

test "resolveMaxTurnsFromMap: --max-turns wins over env" {
    var cfg = try cli_mod.parse(testing.allocator, &.{
        "franky", "--max-turns", "200",
    });
    defer cfg.deinit();
    var m = std.process.Environ.Map.init(testing.allocator);
    defer m.deinit();
    try m.put("FRANKY_MAX_TURNS", "5");
    try testing.expectEqual(@as(?u32, 200), resolveMaxTurnsFromMap(&cfg, &m));
}

test "resolveMaxTurnsFromMap: env var applies when CLI flag absent" {
    var cfg = try cli_mod.parse(testing.allocator, &.{"franky"});
    defer cfg.deinit();
    var m = std.process.Environ.Map.init(testing.allocator);
    defer m.deinit();
    try m.put("FRANKY_MAX_TURNS", "120");
    try testing.expectEqual(@as(?u32, 120), resolveMaxTurnsFromMap(&cfg, &m));
}

test "applyMaxTurnsSettingsOverlay: backfills cfg when CLI/profile didn't set it" {
    var cfg = try cli_mod.parse(testing.allocator, &.{"franky"});
    defer cfg.deinit();
    try testing.expectEqual(@as(?u32, null), cfg.max_turns);

    var settings = try settings_mod.defaults(testing.allocator);
    defer settings.deinit();
    settings.max_turns = 75;

    applyMaxTurnsSettingsOverlay(&cfg, &settings);
    try testing.expectEqual(@as(?u32, 75), cfg.max_turns);
}

test "applyMaxTurnsSettingsOverlay: CLI value wins over settings" {
    var cfg = try cli_mod.parse(testing.allocator, &.{ "franky", "--max-turns", "10" });
    defer cfg.deinit();
    try testing.expectEqual(@as(?u32, 10), cfg.max_turns);

    var settings = try settings_mod.defaults(testing.allocator);
    defer settings.deinit();
    settings.max_turns = 200;

    applyMaxTurnsSettingsOverlay(&cfg, &settings);
    try testing.expectEqual(@as(?u32, 10), cfg.max_turns);
}

test "applyMaxTurnsSettingsOverlay: both null leaves cfg null" {
    var cfg = try cli_mod.parse(testing.allocator, &.{"franky"});
    defer cfg.deinit();

    var settings = try settings_mod.defaults(testing.allocator);
    defer settings.deinit();

    applyMaxTurnsSettingsOverlay(&cfg, &settings);
    try testing.expectEqual(@as(?u32, null), cfg.max_turns);
}

test "resolveTimeoutsFromMap: --first-byte-timeout-ms wins over env" {
    var cfg = try cli_mod.parse(testing.allocator, &.{
        "franky", "--first-byte-timeout-ms", "300000",
    });
    defer cfg.deinit();
    var m = std.process.Environ.Map.init(testing.allocator);
    defer m.deinit();
    try m.put("FRANKY_FIRST_BYTE_TIMEOUT_MS", "999");
    const t = resolveTimeoutsFromMap(&cfg, &m);
    try testing.expectEqual(@as(u32, 300_000), t.first_byte_ms);
}

test "resolveTimeoutsFromMap: env var applies when CLI flag absent" {
    var cfg = try cli_mod.parse(testing.allocator, &.{"franky"});
    defer cfg.deinit();
    var m = std.process.Environ.Map.init(testing.allocator);
    defer m.deinit();
    try m.put("FRANKY_FIRST_BYTE_TIMEOUT_MS", "120000");
    const t = resolveTimeoutsFromMap(&cfg, &m);
    try testing.expectEqual(@as(u32, 120_000), t.first_byte_ms);
}

test "resolveTimeoutsFromMap: garbage env value falls back to default" {
    var cfg = try cli_mod.parse(testing.allocator, &.{"franky"});
    defer cfg.deinit();
    var m = std.process.Environ.Map.init(testing.allocator);
    defer m.deinit();
    try m.put("FRANKY_FIRST_BYTE_TIMEOUT_MS", "not-a-number");
    const t = resolveTimeoutsFromMap(&cfg, &m);
    try testing.expectEqual(@as(u32, 30_000), t.first_byte_ms);
}

test "resolveLogFileFromMap: --log-file wins over env" {
    var cfg = try cli_mod.parse(testing.allocator, &.{
        "franky", "--log-file", "/tmp/from-cli.log",
    });
    defer cfg.deinit();
    var m = std.process.Environ.Map.init(testing.allocator);
    defer m.deinit();
    try m.put("FRANKY_LOG_FILE", "/tmp/from-env.log");
    try testing.expectEqualStrings("/tmp/from-cli.log", resolveLogFileFromMap(&cfg, &m).?);
}

test "resolveLogFileFromMap: env applies when CLI flag absent" {
    var cfg = try cli_mod.parse(testing.allocator, &.{"franky"});
    defer cfg.deinit();
    var m = std.process.Environ.Map.init(testing.allocator);
    defer m.deinit();
    try m.put("FRANKY_LOG_FILE", "/tmp/from-env.log");
    try testing.expectEqualStrings("/tmp/from-env.log", resolveLogFileFromMap(&cfg, &m).?);
}

test "resolveLogFileFromMap: nothing set → null" {
    var cfg = try cli_mod.parse(testing.allocator, &.{"franky"});
    defer cfg.deinit();
    var m = std.process.Environ.Map.init(testing.allocator);
    defer m.deinit();
    try testing.expect(resolveLogFileFromMap(&cfg, &m) == null);
}

// v1.18.0 — per-session log path resolution

test "resolveLogPerSessionFromMap: CLI flag turns it on" {
    var cfg = try cli_mod.parse(testing.allocator, &.{ "franky", "--log-per-session" });
    defer cfg.deinit();
    var m = std.process.Environ.Map.init(testing.allocator);
    defer m.deinit();
    try testing.expect(resolveLogPerSessionFromMap(&cfg, &m));
}

test "resolveLogPerSessionFromMap: env var turns it on" {
    var cfg = try cli_mod.parse(testing.allocator, &.{"franky"});
    defer cfg.deinit();
    var m = std.process.Environ.Map.init(testing.allocator);
    defer m.deinit();
    try m.put("FRANKY_LOG_PER_SESSION", "1");
    try testing.expect(resolveLogPerSessionFromMap(&cfg, &m));
}

test "resolveLogPerSessionFromMap: empty env var stays off" {
    var cfg = try cli_mod.parse(testing.allocator, &.{"franky"});
    defer cfg.deinit();
    var m = std.process.Environ.Map.init(testing.allocator);
    defer m.deinit();
    try m.put("FRANKY_LOG_PER_SESSION", "");
    try testing.expect(!resolveLogPerSessionFromMap(&cfg, &m));
}

test "buildPerSessionLogPath: prefers FRANKY_HOME" {
    const gpa = testing.allocator;
    var m = std.process.Environ.Map.init(gpa);
    defer m.deinit();
    try m.put("FRANKY_HOME", "/etc/franky");
    try m.put("HOME", "/home/me");
    const p = (try buildPerSessionLogPath(gpa, &m, "01ABC")).?;
    defer gpa.free(p);
    try testing.expectEqualStrings("/etc/franky/logs/01ABC.log", p);
}

test "buildPerSessionLogPath: falls back to HOME/.franky/logs" {
    const gpa = testing.allocator;
    var m = std.process.Environ.Map.init(gpa);
    defer m.deinit();
    try m.put("HOME", "/home/me");
    const p = (try buildPerSessionLogPath(gpa, &m, "01ABC")).?;
    defer gpa.free(p);
    try testing.expectEqualStrings("/home/me/.franky/logs/01ABC.log", p);
}

test "buildPerSessionLogPath: no HOME → null" {
    const gpa = testing.allocator;
    var m = std.process.Environ.Map.init(gpa);
    defer m.deinit();
    const p = try buildPerSessionLogPath(gpa, &m, "01ABC");
    try testing.expect(p == null);
}

test "isLoopbackBaseUrl: matches loopback hosts" {
    try testing.expect(isLoopbackBaseUrl("http://localhost:11434/v1/messages"));
    try testing.expect(isLoopbackBaseUrl("http://127.0.0.1:11434"));
    try testing.expect(isLoopbackBaseUrl("https://localhost"));
    try testing.expect(isLoopbackBaseUrl("http://[::1]:8000/v1"));
    try testing.expect(isLoopbackBaseUrl("https://[::1]"));
    try testing.expect(isLoopbackBaseUrl("localhost:1234"));
}

test "isLoopbackBaseUrl: rejects non-loopback hosts and lookalikes" {
    try testing.expect(!isLoopbackBaseUrl(null));
    try testing.expect(!isLoopbackBaseUrl(""));
    try testing.expect(!isLoopbackBaseUrl("https://api.anthropic.com"));
    // Don't false-positive on hostnames that contain `localhost`.
    try testing.expect(!isLoopbackBaseUrl("https://localhost-prod.example.com"));
    try testing.expect(!isLoopbackBaseUrl("https://my.localhost.dev"));
}

test "resolveTimeoutsFromMap: loopback base_url bumps first_byte to 10 min" {
    var cfg = try cli_mod.parse(testing.allocator, &.{
        "franky", "--base-url", "http://localhost:11434/v1/messages",
    });
    defer cfg.deinit();
    var m = std.process.Environ.Map.init(testing.allocator);
    defer m.deinit();
    const t = resolveTimeoutsFromMap(&cfg, &m);
    try testing.expectEqual(@as(u32, 600_000), t.first_byte_ms);
}

test "resolveTimeoutsFromMap: explicit flag still wins over loopback bump" {
    var cfg = try cli_mod.parse(testing.allocator, &.{
        "franky",
        "--base-url",         "http://127.0.0.1:11434",
        "--first-byte-timeout-ms", "120000",
    });
    defer cfg.deinit();
    var m = std.process.Environ.Map.init(testing.allocator);
    defer m.deinit();
    const t = resolveTimeoutsFromMap(&cfg, &m);
    try testing.expectEqual(@as(u32, 120_000), t.first_byte_ms);
}

test "resolveTimeoutsFromMap: cloud base_url keeps the 30s default" {
    var cfg = try cli_mod.parse(testing.allocator, &.{
        "franky", "--base-url", "https://api.anthropic.com",
    });
    defer cfg.deinit();
    var m = std.process.Environ.Map.init(testing.allocator);
    defer m.deinit();
    const t = resolveTimeoutsFromMap(&cfg, &m);
    try testing.expectEqual(@as(u32, 30_000), t.first_byte_ms);
}

test "resolveAnthropicAlias maps short names to current ids" {
    try testing.expectEqualStrings("claude-opus-4-6", resolveAnthropicAlias("opus"));
    try testing.expectEqualStrings("claude-opus-4-6", resolveAnthropicAlias("opus-4-6"));
    try testing.expectEqualStrings("claude-opus-4-6", resolveAnthropicAlias("opus-4.6"));
    try testing.expectEqualStrings("claude-opus-4-7", resolveAnthropicAlias("opus-4-7"));
    try testing.expectEqualStrings("claude-sonnet-4-6", resolveAnthropicAlias("sonnet"));
    try testing.expectEqualStrings("claude-haiku-4-5", resolveAnthropicAlias("haiku"));
}

test "resolveAnthropicAlias passes full ids through untouched" {
    try testing.expectEqualStrings("claude-opus-4-6", resolveAnthropicAlias("claude-opus-4-6"));
    try testing.expectEqualStrings("claude-haiku-4-5-20251001", resolveAnthropicAlias("claude-haiku-4-5-20251001"));
    try testing.expectEqualStrings("whatever-custom-id", resolveAnthropicAlias("whatever-custom-id"));
}

// ─── v1.1.0 — provider resolution tests ──────────────────────────

fn makeCfg(
    model: ?[]const u8,
    thinking: ai.types.ThinkingLevel,
    offline: bool,
) !cli_mod.Config {
    var cfg: cli_mod.Config = .{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    cfg.model = model;
    cfg.thinking = thinking;
    cfg.offline = offline;
    return cfg;
}

test "finalize: known model pulls context_window + max_output from catalog" {
    var cfg = try makeCfg("claude-sonnet-4-6", .off, false);
    defer cfg.deinit();
    const info_in: ProviderInfo = .{
        .provider_name = "anthropic",
        .api_tag = "anthropic-messages",
        .model_id = "claude-sonnet-4-6",
        .api_key = null,
        .auth_token = null,
        .base_url = null,
        .context_window = 42,
        .max_output = 7,
    };
    const info = try finalize(cfg.arena.allocator(), info_in, &cfg, &.{});
    // Sonnet 4.6 has a 1M context window and 8192 max output.
    try testing.expectEqual(@as(u32, 1_000_000), info.context_window);
    try testing.expectEqual(@as(u32, 8192), info.max_output);
    try testing.expect(info.capabilities.vision);
    try testing.expect(info.capabilities.tool_use);
    try testing.expect(info.capabilities.cache);
}

test "finalize: unknown model keeps defaults, still honors --thinking" {
    var cfg = try makeCfg("no-such-model", .high, false);
    defer cfg.deinit();
    const info_in: ProviderInfo = .{
        .provider_name = "anthropic",
        .api_tag = "anthropic-messages",
        .model_id = "no-such-model",
        .api_key = null,
        .auth_token = null,
        .base_url = null,
        .context_window = default_context_window,
        .max_output = default_max_output,
    };
    const info = try finalize(cfg.arena.allocator(), info_in, &cfg, &.{});
    try testing.expectEqual(default_context_window, info.context_window);
    try testing.expectEqual(default_max_output, info.max_output);
    try testing.expect(info.capabilities.tool_use);
    try testing.expect(info.capabilities.reasoning); // --thinking high
}

test "finalize: --thinking forces reasoning on even for non-reasoning catalog entries" {
    var cfg = try makeCfg("claude-haiku-4-5", .medium, false);
    defer cfg.deinit();
    const info_in: ProviderInfo = .{
        .provider_name = "anthropic",
        .api_tag = "anthropic-messages",
        .model_id = "claude-haiku-4-5",
        .api_key = null,
        .auth_token = null,
        .base_url = null,
        .context_window = default_context_window,
        .max_output = default_max_output,
    };
    const info = try finalize(cfg.arena.allocator(), info_in, &cfg, &.{});
    // Haiku 4.5 has reasoning=false in the catalog; --thinking
    // overrides.
    try testing.expect(info.capabilities.reasoning);
}

test "finalize: --thinking off + catalog.reasoning=true keeps reasoning on" {
    var cfg = try makeCfg("claude-opus-4-7", .off, false);
    defer cfg.deinit();
    const info_in: ProviderInfo = .{
        .provider_name = "anthropic",
        .api_tag = "anthropic-messages",
        .model_id = "claude-opus-4-7",
        .api_key = null,
        .auth_token = null,
        .base_url = null,
        .context_window = default_context_window,
        .max_output = default_max_output,
    };
    const info = try finalize(cfg.arena.allocator(), info_in, &cfg, &.{});
    // Opus 4.7's catalog entry has reasoning=true; no --thinking
    // flag shouldn't clear it.
    try testing.expect(info.capabilities.reasoning);
}

test "resolveProvider (no io): with no creds and no --offline → faux with defaults" {
    var cfg = try makeCfg(null, .off, false);
    defer cfg.deinit();
    const env: std.process.Environ = .empty;
    const info = try resolveProvider(testing.allocator, env, &cfg);
    try testing.expectEqualStrings("faux", info.provider_name);
    try testing.expectEqualStrings("faux", info.api_tag);
    try testing.expectEqualStrings("faux-1", info.model_id);
}

test "resolveProvider (no io): --offline forces faux even with --api-key" {
    var cfg: cli_mod.Config = .{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    defer cfg.deinit();
    cfg.api_key = try cfg.arena.allocator().dupe(u8, "sk-test");
    cfg.offline = true;
    const env: std.process.Environ = .empty;
    const info = try resolveProvider(testing.allocator, env, &cfg);
    try testing.expectEqualStrings("faux", info.provider_name);
}

test "resolveProvider (no io): --provider google-gemini + --api-key wires native gemini" {
    var cfg: cli_mod.Config = .{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    defer cfg.deinit();
    cfg.provider = try cfg.arena.allocator().dupe(u8, "google-gemini");
    cfg.api_key = try cfg.arena.allocator().dupe(u8, "AIza-test");
    const env: std.process.Environ = .empty;
    const info = try resolveProvider(testing.allocator, env, &cfg);
    try testing.expectEqualStrings("google-gemini", info.provider_name);
    try testing.expectEqualStrings("google-gemini", info.api_tag);
    try testing.expectEqualStrings("gemini-2.5-pro", info.model_id);
    try testing.expectEqualStrings("AIza-test", info.api_key.?);
    try testing.expect(info.auth_token == null);
}

test "resolveProvider (no io): --provider gemini alias also routes to native" {
    var cfg: cli_mod.Config = .{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    defer cfg.deinit();
    cfg.provider = try cfg.arena.allocator().dupe(u8, "gemini");
    cfg.api_key = try cfg.arena.allocator().dupe(u8, "AIza-test");
    cfg.model = try cfg.arena.allocator().dupe(u8, "gemini-2.5-flash");
    const env: std.process.Environ = .empty;
    const info = try resolveProvider(testing.allocator, env, &cfg);
    try testing.expectEqualStrings("google-gemini", info.provider_name);
    try testing.expectEqualStrings("gemini-2.5-flash", info.model_id);
}

test "resolveProvider (no io): --provider google-gemini without any credential errors" {
    // resolveProvider calls exitWithMessageErr on missing creds via
    // std.process.exit, so we can't directly catch — instead pin
    // the auto-detection behavior: NO --provider, NO Gemini env →
    // chosen=faux (not google-gemini). Pairs with the full CLI
    // path that does exit on missing creds.
    var cfg = try makeCfg(null, .off, false);
    defer cfg.deinit();
    const env: std.process.Environ = .empty;
    const info = try resolveProvider(testing.allocator, env, &cfg);
    try testing.expectEqualStrings("faux", info.provider_name);
}

test "authJsonPathFrom: FRANKY_HOME takes precedence over HOME" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const path = (try authJsonPathFrom(arena.allocator(), "/fh", "/home/user")).?;
    try testing.expectEqualStrings("/fh/auth.json", path);
}

test "authJsonPathFrom: falls back to $HOME/.franky/auth.json" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const path = (try authJsonPathFrom(arena.allocator(), null, "/home/user")).?;
    try testing.expectEqualStrings("/home/user/.franky/auth.json", path);
}

test "authJsonPathFrom: neither env set → null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const path = try authJsonPathFrom(arena.allocator(), null, null);
    try testing.expect(path == null);
}

// ─── v1.5.2 — models.json + system.md disk-layer tests ─────────────

test "modelsJsonPathFrom: FRANKY_HOME wins, else HOME/.franky" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("/fh/models.json", (try modelsJsonPathFrom(a, "/fh", "/home/u")).?);
    try testing.expectEqualStrings("/home/u/.franky/models.json", (try modelsJsonPathFrom(a, null, "/home/u")).?);
    try testing.expect((try modelsJsonPathFrom(a, null, null)) == null);
}

test "systemMdPathFrom: FRANKY_HOME wins, else HOME/.franky" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("/fh/system.md", (try systemMdPathFrom(a, "/fh", "/home/u")).?);
    try testing.expectEqualStrings("/home/u/.franky/system.md", (try systemMdPathFrom(a, null, "/home/u")).?);
    try testing.expect((try systemMdPathFrom(a, null, null)) == null);
}

test "finalize: disk-extras shadow built-in catalog on id collision" {
    const gpa = testing.allocator;
    var cfg = try makeCfg("claude-sonnet-4-6", .off, false);
    defer cfg.deinit();

    // Override Sonnet 4.6's context_window to a small sentinel.
    const extras = [_]models_mod.Entry{.{
        .id = "claude-sonnet-4-6",
        .provider = "anthropic",
        .api = "anthropic-messages",
        .display_name = "custom-sonnet",
        .context_window = 42,
        .max_output = 7,
        .capabilities = .{
            .vision = false,
            .tool_use = true,
            .reasoning = false,
            .cache = false,
            .streaming = true,
        },
        .cost = .{},
        .knowledge_cutoff = "",
    }};

    const info_in: ProviderInfo = .{
        .provider_name = "anthropic",
        .api_tag = "anthropic-messages",
        .model_id = "claude-sonnet-4-6",
        .api_key = null,
        .auth_token = null,
        .base_url = null,
        .context_window = default_context_window,
        .max_output = default_max_output,
    };
    const info = try finalize(cfg.arena.allocator(), info_in, &cfg, &extras);
    try testing.expectEqual(@as(u32, 42), info.context_window);
    try testing.expectEqual(@as(u32, 7), info.max_output);
    _ = gpa;
}

test "buildSystemPromptIo: --system-prompt flag beats disk + default" {
    const gpa = testing.allocator;
    var cfg: cli_mod.Config = .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    defer cfg.deinit();
    const explicit = try cfg.arena.allocator().dupe(u8, "you are a test");
    cfg.system_prompt = explicit;

    const env: std.process.Environ = .empty;
    const out = try buildSystemPromptIo(gpa, null, env, &cfg);
    defer gpa.free(out);
    try testing.expectEqualStrings("you are a test", out);
}

test "buildSystemPromptIo: missing system.md falls back to default + appends subagent hint" {
    const gpa = testing.allocator;
    var cfg: cli_mod.Config = .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    defer cfg.deinit();

    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    // Env with no FRANKY_HOME/HOME → no disk lookup attempted.
    const env: std.process.Environ = .empty;
    const out = try buildSystemPromptIo(gpa, io, env, &cfg);
    defer gpa.free(out);
    // Default prompt body is preserved verbatim at the start.
    try testing.expect(std.mem.startsWith(u8, out, default_system_prompt));
    // v1.24.1 — subagent hint is appended with the profile catalog.
    try testing.expect(std.mem.indexOf(u8, out, "subagent") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Profiles:") != null);
    // At least one built-in profile name should appear.
    try testing.expect(std.mem.indexOf(u8, out, "gemini") != null);
    // v1.26.5 — trust-the-subagent nudge. The prompt instructs the
    // model not to re-verify successful sub-agent runs, since real
    // incidents have shown re-verification spirals where the parent
    // agent reverts a sub-agent's correct edits.
    try testing.expect(std.mem.indexOf(u8, out, "ok: true") != null);
    try testing.expect(std.mem.indexOf(u8, out, "trust") != null);
}

test "buildSystemPromptIo: --skill NAME injects body under Active skills (§6.1)" {
    const gpa = testing.allocator;
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    // Stage a tiny skill in a tmp dir.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(root);

    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, root) catch {};
    {
        const path = try std.fmt.allocPrint(gpa, "{s}/demo.md", .{root});
        defer gpa.free(path);
        var f = try cwd.createFile(io, path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io,
            \\---
            \\name: demo
            \\description: a demo skill
            \\---
            \\WORKSPACE-SPECIFIC GUIDANCE GOES HERE
            \\
        );
    }

    var cfg: cli_mod.Config = .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    defer cfg.deinit();
    cfg.skills_path = try cfg.arena.allocator().dupe(u8, root);
    cfg.skills_select_csv = try cfg.arena.allocator().dupe(u8, "demo");

    const env: std.process.Environ = .empty;
    const out = try buildSystemPromptIo(gpa, io, env, &cfg);
    defer gpa.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "## Active skills") != null);
    try testing.expect(std.mem.indexOf(u8, out, "### demo") != null);
    try testing.expect(std.mem.indexOf(u8, out, "WORKSPACE-SPECIFIC GUIDANCE") != null);
}

test "buildSystemPromptIo: skill stays out when not selected and no auto_apply (§6.1)" {
    const gpa = testing.allocator;
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(root);

    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, root) catch {};
    {
        const path = try std.fmt.allocPrint(gpa, "{s}/idle.md", .{root});
        defer gpa.free(path);
        var f = try cwd.createFile(io, path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io,
            \\---
            \\name: idle
            \\description: should never auto-apply
            \\---
            \\IDLE BODY MUST NOT APPEAR
            \\
        );
    }

    var cfg: cli_mod.Config = .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    defer cfg.deinit();
    cfg.skills_path = try cfg.arena.allocator().dupe(u8, root);
    // No skills_select_csv, no auto_apply on the skill → inactive.

    const env: std.process.Environ = .empty;
    const out = try buildSystemPromptIo(gpa, io, env, &cfg);
    defer gpa.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "Active skills") == null);
    try testing.expect(std.mem.indexOf(u8, out, "IDLE BODY") == null);
}

// ─── v1.19.0 — settings-layer overlay helper tests ──────────────────

test "applyBashSettingsOverlay: copies timeoutMs onto bash_state" {
    var state = tools_mod.bash.SessionBashState.init(testing.allocator);
    defer state.deinit();

    var settings = try settings_mod.defaults(testing.allocator);
    defer settings.deinit();
    settings.bash_timeout_ms = 30_000;

    applyBashSettingsOverlay(&state, &settings);
    try testing.expectEqual(@as(?u64, 30_000), state.default_timeout_ms_override);
    try testing.expectEqual(@as(u64, 30_000), state.defaultTimeoutMs());
}

test "applyBashSettingsOverlay: null setting leaves override unset" {
    var state = tools_mod.bash.SessionBashState.init(testing.allocator);
    defer state.deinit();

    var settings = try settings_mod.defaults(testing.allocator);
    defer settings.deinit();
    // settings.bash_timeout_ms stays null

    applyBashSettingsOverlay(&state, &settings);
    try testing.expectEqual(@as(?u64, null), state.default_timeout_ms_override);
}

test "applyReadSettingsOverlay: copies maxBytes onto read_ctx" {
    var ctx: tools_mod.read.ReadCtx = .{};
    var settings = try settings_mod.defaults(testing.allocator);
    defer settings.deinit();
    settings.read_max_bytes = 1024;
    applyReadSettingsOverlay(&ctx, &settings);
    try testing.expectEqual(@as(?usize, 1024), ctx.max_bytes_without_limit_override);
    try testing.expectEqual(@as(usize, 1024), ctx.effectiveMaxBytes());
}

test "applyPermissionsSettingsOverlay: pre-seeds Store from arrays + scalars" {
    var store = permissions_mod.Store.init(testing.allocator);
    defer store.deinit();

    var settings = try settings_mod.defaults(testing.allocator);
    defer settings.deinit();
    settings.permissions_ask_all = true;
    settings.permissions_yes_to_all = true;
    settings.permissions_always_allow_tools = try testing.allocator.alloc([]const u8, 1);
    settings.permissions_always_allow_tools[0] = try testing.allocator.dupe(u8, "read");
    settings.permissions_always_deny_bash = try testing.allocator.alloc([]const u8, 1);
    settings.permissions_always_deny_bash[0] = try testing.allocator.dupe(u8, "rm");

    try applyPermissionsSettingsOverlay(&store, &settings);
    try testing.expect(store.ask_all);
    try testing.expect(store.yes_to_all);
    try testing.expectEqual(permissions_mod.Decision.auto_allow, store.check("read", "{}"));
    try testing.expectEqual(permissions_mod.Decision.auto_deny, store.check("bash", "{\"command\":\"rm -rf /\"}"));
}

test "resolvePromptsDefault: CLI wins; settings only when CLI is off" {
    var cfg: cli_mod.Config = .{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    defer cfg.deinit();
    var settings = try settings_mod.defaults(testing.allocator);
    defer settings.deinit();

    // Both off → false.
    try testing.expect(!resolvePromptsDefault(&cfg, &settings));

    // Settings on, CLI off → true.
    settings.prompts_default = true;
    try testing.expect(resolvePromptsDefault(&cfg, &settings));

    // CLI on, settings off → true (CLI wins).
    settings.prompts_default = false;
    cfg.prompts = true;
    try testing.expect(resolvePromptsDefault(&cfg, &settings));

    // CLI on, settings on → true.
    settings.prompts_default = true;
    try testing.expect(resolvePromptsDefault(&cfg, &settings));
}
