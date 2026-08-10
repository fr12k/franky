//! `--mode worker` — franky-box task queue worker.
//!
//! Reuses the proxy listener and session — tasks from the queue are
//! just additional prompts fed into the same session that the web UI
//! uses. After each turn, inspects stop_reason and cancel state to
//! determine success/failure and posts the result to the outbox.

const std = @import("std");
const franky = @import("../../root.zig");
const ai = franky.ai;
const box_client = franky.franky_box.box_client;
const cli_mod = franky.coding.cli;
const proxy = @import("proxy.zig");
const at = franky.agent.types;

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

    // Two independent backoffs: one for claim *errors* (network/server
    // failures — counts toward max_consecutive_failures and exits the
    // loop), one for *idle* polls (empty inbox — normal, must not kill the
    // worker but should still ease off the server). The previous code
    // reset the idle backoff on every successful (non-erroring) claim,
    // so an empty inbox was polled at 1 Hz forever — the escalation was
    // dead code.
    var failures: u32 = 0;
    var fail_backoff_ms: u64 = 1000;
    var idle_backoff_ms: u64 = 1000;
    var completed: u64 = 0;

    while (failures < max_failures) {
        const result = client.claim() catch |err| {
            ai.log.log(.warn, "worker", "claim", "failed: {}", .{err});
            failures += 1;
            io.sleep(std.Io.Duration.fromMilliseconds(@intCast(fail_backoff_ms)), .real) catch {};
            fail_backoff_ms = @min(fail_backoff_ms * 2, 30_000);
            continue;
        };
        // A successful claim call (even returning null) clears the
        // *failure* counters — only claim errors are fatal.
        failures = 0;
        fail_backoff_ms = 1000;

        if (result) |claimed| {
            defer claimed.deinit(allocator);
            ai.log.log(.info, "worker", "claimed", "task={s} action={s} try={d}", .{ claimed.task_id, claimed.action, claimed.try_count });

            // Claimed work resets the idle backoff so the next empty
            // poll starts from the base interval again.
            idle_backoff_ms = 1000;

            // Run the agent — same mutex as POST /prompt
            session.run_mutex.lockUncancelable(io);
            proxy.runOneTurn(&session, allocator, io, claimed.payload);
            session.run_mutex.unlock(io);

            // Detect outcome
            const outcome = detectOutcome(&session);

            switch (outcome) {
                .success => {
                    const output = try std.fmt.allocPrint(allocator,
                        "{{\"status\":\"completed\",\"task_id\":\"{s}\"}}", .{claimed.task_id});
                    _ = try client.complete(claimed.task_id, output);
                    ai.log.log(.info, "worker", "completed", "task={s}", .{claimed.task_id});
                },
                .failed => |reason| {
                    const error_body = try std.fmt.allocPrint(allocator,
                        "{{\"error\":\"{s}\",\"task_id\":\"{s}\"}}", .{ reason, claimed.task_id });
                    defer allocator.free(error_body);
                    _ = try client.fail(claimed.task_id, error_body);
                    ai.log.log(.info, "worker", "failed", "task={s} reason={s}", .{ claimed.task_id, reason });
                },
            }

            // Reset cancel flag for next task
            session.cancel = .{};

            completed += 1;
        } else {
            // Empty inbox — normal idle. Back off up to 30 s so an idle
            // worker doesn't hammer the server at 1 Hz.
            io.sleep(std.Io.Duration.fromMilliseconds(@intCast(idle_backoff_ms)), .real) catch {};
            idle_backoff_ms = @min(idle_backoff_ms * 2, 30_000);
        }
    }

    ai.log.log(.err, "worker", "exit", "{d} consecutive claim failures exceeded; {d} tasks completed", .{ max_failures, completed });
}

const Outcome = union(enum) {
    success: void,
    failed: []const u8,
};

fn detectOutcome(session: *proxy.Session) Outcome {
    // Check if agent was aborted (cancel fired, max_turns exceeded)
    if (session.cancel.isFired()) {
        return .{ .failed = "aborted" };
    }

    // Check the last message's stop_reason
    const msgs = session.transcript.messages.items;
    if (msgs.len > 0) {
        const last = &msgs[msgs.len - 1];
        const reason = last.stop_reason orelse return .{ .failed = "no stop reason" };
        switch (reason) {
            .err => {
                const err_msg = last.error_message orelse "agent error";
                return .{ .failed = err_msg };
            },
            .aborted => return .{ .failed = "aborted" },
            .refusal => return .{ .failed = "refused" },
            .stop, .tool_use, .length => return .{ .success = {} },
        }
    }

    // No messages means something went wrong before we got a response
    return .{ .failed = "empty response" };
}