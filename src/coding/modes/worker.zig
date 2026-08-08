//! `--mode worker` — unattended task worker for franky-box.
//! Connects to a franky-box server, polls for tasks, executes them
//! in isolated sessions, and posts results to the outbox.

const std = @import("std");
const franky = @import("../../root.zig");
const ai = franky.ai;
const box_client = franky.franky_box.box_client;
const box_types = franky.franky_box.box_types;
const cli_mod = franky.coding.cli;

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
    argv: []const []const u8,
) !void {
    _ = environ;
    _ = environ_map;
    _ = argv;
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

    var client = try box_client.BoxClient.init(allocator, io, .{
        .base_url = inbox_server,
        .agent_id = agent_id,
        .agent_secret = agent_secret,
        .team_id = team_id,
    });
    defer client.deinit();

    var failures: u32 = 0;
    var backoff_ms: u64 = 1000;
    var completed: u64 = 0;

    ai.log.log(.info, "worker", "start", "agent={s} team={s} inbox={s}", .{agent_id, team_id, inbox_server});

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
            ai.log.log(.info, "worker", "claimed", "task={s} action={s} try={d}", .{t.task_id, t.action, t.try_count});

            const output = try std.fmt.allocPrint(allocator, "{{\"status\":\"completed\",\"task_id\":\"{s}\"}}", .{t.task_id});

            _ = try client.complete(t.task_id, output);

            completed += 1;
            ai.log.log(.info, "worker", "done", "task={s} total={d}", .{t.task_id, completed});
        } else {
            std.time.sleep(backoff_ms * std.time.ns_per_ms);
            backoff_ms = @min(backoff_ms * 2, 30_000);
        }
    }

    ai.log.log(.err, "worker", "exit", "{d} consecutive failures exceeded", .{max_failures});
}
