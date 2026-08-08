//! `--mode worker` — unattended task worker for franky-box.
//!
//! Reuses the proxy mode's initSession + runOneTurn so there is
//! minimal code duplication. The worker:
//!   1. Inits a proxy session (agent state, tools, transcript)
//!   2. Polls franky-box for tasks via BoxClient
//!   3. Injects each claimed task as a prompt via runOneTurn
//!   4. Posts result to outbox, repeats

const std = @import("std");
const franky = @import("../../root.zig");
const ai = franky.ai;
const box_client = franky.franky_box.box_client;
const cli_mod = franky.coding.cli;
const proxy = @import("proxy.zig");

pub const RunError = error{
    MissingInboxServer,
    MissingAgentId,
    MissingAgentSecret,
} || std.mem.Allocator.Error;

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    environ_map: *std.process.Environ.Map,
    cfg: *cli_mod.Config,
    _: []const []const u8,
) !void {
    const inbox_server = cfg.inbox_server_url orelse {
        ai.log.log(.err, "worker", "config", "missing --inbox-server", .{});
        return RunError.MissingInboxServer;
    };
    const agent_id = cfg.inbox_agent_id orelse {
        ai.log.log(.err, "worker", "config", "missing --agent-id", .{});
        return RunError.MissingAgentId;
    };
    const agent_secret = cfg.inbox_agent_secret orelse {
        ai.log.log(.err, "worker", "config", "missing --agent-secret", .{});
        return RunError.MissingAgentSecret;
    };
    const team_id = cfg.inbox_team_id orelse "default";
    const max_failures = cfg.max_consecutive_failures orelse 5;

    // Map --web-port to --proxy-port for the proxy listener
    if (cfg.web_port) |wp| cfg.proxy_port = wp;
    cfg.mode = .proxy;

    // Create box client
    var client = try box_client.BoxClient.init(allocator, io, .{
        .base_url = inbox_server,
        .agent_id = agent_id,
        .agent_secret = agent_secret,
        .team_id = team_id,
    });
    defer client.deinit();

    // Init proxy session — gives us a full agent state, tools,
    // transcript, memory, etc. without any code duplication.
    var session: proxy.Session = undefined;
    try proxy.initSession(&session, allocator, io, environ, environ_map, cfg, &.{});
    defer session.deinit();

    // Worker loop
    var failures: u32 = 0;
    var backoff_ms: u64 = 1000;
    var completed: u64 = 0;

    ai.log.log(.info, "worker", "start", "agent={s} team={s} inbox={s}", .{ agent_id, team_id, inbox_server });

    while (failures < max_failures) {
        const task = client.claim() catch |err| {
            ai.log.log(.warn, "worker", "claim", "failed: {}", .{err});
            failures += 1;
            std.time.sleep(backoff_ms * std.time.ns_per_ms);
            backoff_ms = @min(backoff_ms * 2, 30_000);
            continue;
        };
        failures = 0;
        backoff_ms = 1000;

        if (task) |t| {
            defer t.deinit(allocator);
            ai.log.log(.info, "worker", "claimed", "task={s} action={s} try={d}", .{ t.task_id, t.action, t.try_count });

            // Use proxy's runOneTurn — drives the full agent loop
            // (LLM calls, tool execution, SSE events, subscribers).
            // The task payload becomes the user prompt.
            proxy.runOneTurn(&session, allocator, io, t.payload);

            // Post result to outbox (placeholder — real impl captures
            // the final transcript state)
            const output = try std.fmt.allocPrint(allocator,
                "{{\"status\":\"completed\",\"task_id\":\"{s}\"}}", .{t.task_id});
            _ = try client.complete(t.task_id, output);

            completed += 1;
            ai.log.log(.info, "worker", "done", "task={s} total={d}", .{ t.task_id, completed });
        } else {
            // No tasks — exponential backoff
            std.time.sleep(backoff_ms * std.time.ns_per_ms);
            backoff_ms = @min(backoff_ms * 2, 30_000);
        }
    }

    ai.log.log(.err, "worker", "exit", "{d} consecutive failures exceeded", .{max_failures});
}
