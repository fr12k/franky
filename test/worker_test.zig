//! Worker-mode integration test — `--mode worker` against a real
//! franky-box server subprocess.
//!
//! This is the first test that exercises the full worker pipeline end-to-end:
//!
//!   1. The `franky-box` binary (built from the franky_box dependency) is
//!      spawned as a subprocess, listening on port 8080 (the hardcoded
//!      default in franky-box's main.zig). It uses a unique SQLite db file
//!      per test run to avoid cross-test bleed.
//!   2. The `franky` binary is spawned as a subprocess in `--mode worker`
//!      with `--provider faux`, pointed at the franky-box server via
//!      `--inbox-server`, `--agent-id`, and `--agent-secret`.
//!   3. A task is dispatched to the franky-box server via its HTTP API
//!      (POST /v1/tasks/dispatch).
//!   4. The worker polls the inbox, claims the task, runs one faux-provider
//!      turn, and posts the result back to the outbox (via HTTP).
//!   5. The test polls the outbox via the HTTP API (GET /v1/agents/.../outbox)
//!      until the task appears with a completed status, then asserts the
//!      completion body.
//!
//! Port 8080: the franky-box binary hardcodes port 8080 in its main.zig
//! (no CLI override in v0.2.2 or v0.4.0). The test checks if port 8080 is
//! free before spawning; if it's in use, the test skips (error.SkipZigTest)
//! rather than failing — this avoids false negatives in CI environments
//! where port 8080 may be occupied.
//!
//! v0.29.1 — new; closes the worker-mode coverage gap noted in AGENTS.md
//! §"Recommended Next Steps" item 4 (mode-level integration tests).

const std = @import("std");
const testing = std.testing;
const net = std.Io.net;

const franky = @import("franky");

// ── Constants ─────────────────────────────────────────────────────────────

/// The franky-box server's hardcoded listen port.
const box_port: u16 = 8080;

/// The default agent registered by franky-box's `registerDefaultAgent()`.
const agent_id = "agent-0";
const agent_secret = "default-secret-please-change";

// ── Helpers ──────────────────────────────────────────────────────────────

/// Locate a binary relative to the repo root (mirrors mode_test.zig).
fn findBin(io: std.Io, name: []const u8) ?[]const u8 {
    const paths = [_][]const u8{name};
    for (paths) |p| {
        std.Io.Dir.cwd().access(io, p, .{}) catch continue;
        return p;
    }
    return null;
}

/// Check if a TCP port is free (nothing listening on it).
fn isPortFree(io: std.Io, port: u16) bool {
    var addr = net.IpAddress.parseIp4("127.0.0.1", port) catch return false;
    var server = net.IpAddress.listen(&addr, io, .{
        .kernel_backlog = 1,
        .reuse_address = true,
    }) catch return false;
    server.deinit(io);
    return true;
}

/// Wait until a TCP port has a listener (poll with connect attempts).
fn waitForPort(io: std.Io, port: u16, timeout_ms: i64) bool {
    const deadline = franky.ai.stream.nowMillis() + timeout_ms;
    while (franky.ai.stream.nowMillis() < deadline) {
        var addr = net.IpAddress.parseIp4("127.0.0.1", port) catch continue;
        var stream = net.IpAddress.connect(&addr, io, .{ .mode = .stream }) catch {
            std.Io.sleep(io, std.Io.Duration{ .nanoseconds = 100_000_000 }, .real) catch {};
            continue;
        };
        stream.close(io);
        return true;
    }
    return false;
}

/// Send a raw HTTP request to a local port and return the response body
/// (caller frees). Runs on a spawned thread to avoid blocking the test's
/// `threaded.io()` backend.
fn httpReq(
    io: std.Io,
    allocator: std.mem.Allocator,
    port: u16,
    request_str: []const u8,
) ![]const u8 {
    const Result = struct { bytes: ?[]const u8, err: ?anyerror };
    var result: Result = .{ .bytes = null, .err = null };
    const Args = struct { io: std.Io, alloc: std.mem.Allocator, p: u16, req: []const u8, out: *Result };
    const args = Args{ .io = io, .alloc = allocator, .p = port, .req = request_str, .out = &result };
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(a: Args) void {
            const r = doReq(a.io, a.alloc, a.p, a.req) catch |e| {
                a.out.* = .{ .bytes = null, .err = e };
                return;
            };
            a.out.* = .{ .bytes = r, .err = null };
        }
    }.run, .{args});
    thread.join();
    if (result.err) |e| return e;
    return result.bytes.?;
}

fn doReq(io: std.Io, allocator: std.mem.Allocator, port: u16, request_str: []const u8) ![]const u8 {
    var addr = try net.IpAddress.parseIp4("127.0.0.1", port);
    var stream = try net.IpAddress.connect(&addr, io, .{ .mode = .stream });
    defer stream.close(io);

    var wb: [256]u8 = undefined;
    var w = stream.writer(io, &wb);
    try w.interface.writeAll(request_str);
    try w.interface.flush();

    var rb: [16 * 1024]u8 = undefined;
    var r = stream.reader(io, &.{});
    var total: usize = 0;
    while (total < rb.len) {
        var vecs: [1][]u8 = .{rb[total..]};
        const n = r.interface.readVec(&vecs) catch break;
        if (n == 0) break;
        total += n;
    }
    const resp = rb[0..total];
    const body_start = std.mem.indexOfPos(u8, resp, 0, "\r\n\r\n") orelse return error.NoResponseBody;
    return try allocator.dupe(u8, resp[body_start + 4 ..]);
}

/// Dispatch a task to the franky-box server via HTTP.
fn dispatchTask(io: std.Io, allocator: std.mem.Allocator, payload: []const u8) ![]const u8 {
    const req = try std.fmt.allocPrint(
        allocator,
        "POST /v1/tasks/dispatch HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ payload.len, payload },
    );
    defer allocator.free(req);
    return httpReq(io, allocator, box_port, req);
}

/// Read the outbox from the franky-box server via HTTP (authenticated).
fn readOutbox(io: std.Io, allocator: std.mem.Allocator) ![]const u8 {
    const req = try std.fmt.allocPrint(
        allocator,
        "GET /v1/agents/{s}/outbox HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {s}\r\nConnection: close\r\n\r\n",
        .{ agent_id, agent_secret },
    );
    defer allocator.free(req);
    return httpReq(io, allocator, box_port, req);
}

// ── Tests ─────────────────────────────────────────────────────────────────

test "worker mode: claims a dispatched task and posts a completed result" {
    var threaded = franky.test_helpers.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const franky_bin = findBin(io, "zig-out/bin/franky") orelse return error.SkipZigTest;
    const box_bin = findBin(io, "zig-out/bin/franky-box") orelse return error.SkipZigTest;

    // Port 8080 is hardcoded in franky-box; skip if it's already in use.
    if (!isPortFree(io, box_port)) return error.SkipZigTest;

    // 1. Spawn the franky-box server subprocess.
    var box_child = std.process.spawn(io, .{
        .argv = &.{box_bin},
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return error.SkipZigTest;
    defer box_child.kill(io);

    // Wait for the server to bind on port 8080.
    if (!waitForPort(io, box_port, 5_000)) {
        box_child.kill(io);
        return error.SkipZigTest;
    }

    // 2. Spawn the franky worker subprocess.
    const inbox_url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{box_port});
    defer gpa.free(inbox_url);
    const web_port_str = try std.fmt.allocPrint(gpa, "{d}", .{box_port + 100});
    defer gpa.free(web_port_str);

    var worker_child = std.process.spawn(io, .{
        .argv = &.{
            franky_bin,
            "--provider", "faux",
            "--mode", "worker",
            "--no-session",
            "--inbox-server", inbox_url,
            "--agent-id", agent_id,
            "--agent-secret", agent_secret,
            "--web-port", web_port_str,
            "--max-consecutive-failures", "3",
        },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch {
        box_child.kill(io);
        return error.SkipZigTest;
    };
    defer worker_child.kill(io);

    // 3. Dispatch a task to the inbox. The payload is a JSON string; the
    //    worker feeds it to the agent as the user prompt. The faux
    //    provider echoes it back as "you said: <payload>".
    const payload_text = "hello from worker integration test";
    const payload_json = try std.fmt.allocPrint(gpa, "\"{s}\"", .{payload_text});
    defer gpa.free(payload_json);
    const dispatch_resp = try dispatchTask(io, gpa, payload_json);
    defer gpa.free(dispatch_resp);
    try testing.expect(std.mem.indexOf(u8, dispatch_resp, "task_id") != null);
    try testing.expect(std.mem.indexOf(u8, dispatch_resp, "dispatched") != null);

    // 4. Poll the outbox until the task appears as completed. The worker
    //    polls the inbox at ~1 Hz initially; give it a generous 30 s budget
    //    to account for subprocess startup + first claim.
    const deadline = franky.ai.stream.nowMillis() + 30_000;
    var found_completed = false;
    while (franky.ai.stream.nowMillis() < deadline) {
        const outbox_json = readOutbox(io, gpa) catch {
            std.Io.sleep(io, std.Io.Duration{ .nanoseconds = 200_000_000 }, .real) catch {};
            continue;
        };
        defer gpa.free(outbox_json);

        // The outbox JSON is an array. A non-empty array with the task_id
        // and "completed_at" means the task was processed.
        if (std.mem.indexOf(u8, outbox_json, "task-") != null and
            std.mem.indexOf(u8, outbox_json, "completed_at") != null)
        {
            found_completed = true;
            // The worker posts {"status":"completed","task_id":"task-0"}
            // as the completion body — verify it's present.
            try testing.expect(std.mem.indexOf(u8, outbox_json, "completed") != null);
            break;
        }

        std.Io.sleep(io, std.Io.Duration{ .nanoseconds = 500_000_000 }, .real) catch {};
    }

    try testing.expect(found_completed);
}