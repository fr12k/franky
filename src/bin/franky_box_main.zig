//! franky-box server binary entry point.
//!
//! This is a thin wrapper that re-exports franky-box's own `main.zig` via
//! the `franky_box` module. We build our own executable (instead of using
//! the dependency's artifact) because the dependency has both a lib and
//! an exe named "franky-box", making the artifact name ambiguous.
//!
//! The server listens on port 8080 (hardcoded in franky-box v0.2.2's
//! main.zig — no CLI override available). The worker-mode integration test
//! spawns this binary as a subprocess.

const std = @import("std");
const net = std.Io.net;
const http = std.http;
const franky = @import("franky_box");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const port: u16 = 8080;
    const db_path = "franky-box.db";

    var store_backend = try franky.SqliteStore.init(allocator, db_path);
    var ts = store_backend.storeInterface();
    defer store_backend.deinit();

    var api = franky.Server.init(allocator, io, &ts);
    defer api.deinit();
    try api.registerDefaultAgent();

    const address = try net.IpAddress.parseIp4("0.0.0.0", port);
    var tcp_server = try address.listen(io, .{ .reuse_address = true, .kernel_backlog = 128 });
    defer tcp_server.deinit(io);

    std.log.info("franky-box listening on 0.0.0.0:{d}", .{port});

    while (true) {
        const stream = tcp_server.accept(io) catch |err| {
            std.log.err("accept: {s}", .{@errorName(err)});
            continue;
        };
        defer stream.close(io);

        var read_buf: [8192]u8 = undefined;
        var write_buf: [4096]u8 = undefined;

        var reader = net.Stream.Reader.init(stream, io, &read_buf);
        var writer = net.Stream.Writer.init(stream, io, &write_buf);
        var http_server = http.Server.init(&reader.interface, &writer.interface);

        var request = http_server.receiveHead() catch |err| {
            if (err != error.EndOfStream) std.log.warn("receiveHead: {s}", .{@errorName(err)});
            continue;
        };

        // Save target before reading body (readerExpectNone invalidates
        // head strings). Use handleWithPath if available, else handle
        // with restored target.
        const saved_target = allocator.dupe(u8, request.head.target) catch continue;
        defer allocator.free(saved_target);

        const body = blk: {
            if (!request.head.method.requestHasBody()) break :blk "";

            var buf: [4096]u8 = undefined;
            var body_reader = request.readerExpectNone(&buf);
            request.head.target = saved_target; // restore after invalidation

            if (request.head.content_length) |cl| {
                if (cl == 0) break :blk "";
                const body_bytes = body_reader.allocRemaining(allocator, .unlimited) catch |err| {
                    std.log.warn("read body: {s}", .{@errorName(err)});
                    request.respond("", .{ .status = .bad_request }) catch {};
                    continue;
                };
                break :blk body_bytes;
            }
            break :blk "";
        };
        defer if (body.len > 0) allocator.free(body);

        request.head.target = saved_target;
        // v0.4.0 has handleWithPath which takes a saved path (safe after
        // readerExpectNone invalidates head strings).
        api.handleWithPath(&request, saved_target, body) catch |err| {
            std.log.err("handle: {s}", .{@errorName(err)});
            request.respond("", .{ .status = .internal_server_error }) catch {};
        };
    }
}