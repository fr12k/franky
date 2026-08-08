//! `--mode worker` — franky-box task queue worker.
//!
//! Reuses the proxy listener unchanged — tasks from the queue are
//! just additional prompts fed into the same session that the web UI
//! (POST /prompt) uses. Everything serializes on the session mutex.

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

    cfg.mode = .proxy;
    if (cfg.web_port) |wp| cfg.proxy_port = wp;

    var client = try box_client.BoxClient.init(allocator, io, .{
        .base_url = inbox_server,
        .agent_id = agent_id,
        .agent_secret = agent_secret,
        .team_id = team_id,
    });
    defer client.deinit();

    var session: proxy.Session = undefined;
    try proxy.initSession(&session, allocator, io, environ, environ_map, cfg, &.{});
    defer session.deinit();

    const port = cfg.proxy_port orelse proxy.default_port;
    var addr = try std.Io.net.IpAddress.parseIp4("0.0.0.0", port);
    var server = try std.Io.net.IpAddress.listen(&addr, io, .{
        .kernel_backlog = 32,
        .reuse_address = true,
    });
    var server_closed: bool = false;
    defer if (!server_closed) server.deinit(io);

    _ = try std.Thread.spawn(.{}, proxy.runAcceptLoop, .{
        &session, &server, &server_closed, allocator, io,
    });

    ai.log.log(.info, "worker", "start", "agent={s} team={s} inbox={s} web=:{d}", .{ agent_id, team_id, inbox_server, port });

    var failures: u32 = 0;
    var backoff_ms: u64 = 1000;
    var completed: u64 = 0;

    while (failures < max_failures) {
        const result = client.claim() catch |err| {
            ai.log.log(.warn, "worker", "claim", "failed: {}", .{err});
            failures += 1;
            std.time.sleep(backoff_ms * std.time.ns_per_ms);
            backoff_ms = @min(backoff_ms * 2, 30_000);
            continue;
        };
        failures = 0;
        backoff_ms = 1000;

        if (result) |claimed| {
            defer claimed.deinit(allocator);
            ai.log.log(.info, "worker", "claimed", "task={s} action={s} try={d}", .{ claimed.task_id, claimed.action, claimed.try_count });

            // Same mutex as POST /prompt — user prompts and task
            // prompts serialize perfectly.
            session.run_mutex.lockUncancelable(io);
            proxy.runOneTurn(&session, allocator, io, claimed.payload);
            session.run_mutex.unlock(io);

            const output = try std.fmt.allocPrint(allocator, "{{\"status\":\"completed\",\"task_id\":\"{s}\"}}", .{claimed.task_id});
            _ = try client.complete(claimed.task_id, output);
            completed += 1;
            ai.log.log(.info, "worker", "done", "task={s} total={d}", .{ claimed.task_id, completed });
        } else {
            std.time.sleep(backoff_ms * std.time.ns_per_ms);
            backoff_ms = @min(backoff_ms * 2, 30_000);
        }
    }

    ai.log.log(.err, "worker", "exit", "{d} consecutive failures exceeded", .{max_failures});
}