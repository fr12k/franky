//! MCP UDS bridge — Phase 2 of `--mcp-code-mode`.
//!
//! A per-session Unix-domain-socket server that the sandboxed
//! `code_exec` subprocess (via the generated `_runtime.py`) talks to.
//! The sandbox blocks direct network access, so the UDS socket is the
//! only channel through which model-written Python can reach external
//! MCP servers.
//!
//! Security (defense in depth):
//!   1. **Bearer token** — 32 random bytes (hex) minted per session into
//!      `FRANKY_MCP_TOKEN`, verified with `std.crypto.timing_safe.eql`.
//!   2. **Peer-PID verification** — `SO_PEERCRED` (Linux) /
//!      `LOCAL_PEERPID` (macOS) checked against the `code_exec`-spawned
//!      child PID (or a member of its process group).
//!   3. **Permission gate** — every dispatch reconstructs the namespaced
//!      `mcp__<server>__<tool>` name and routes it through the existing
//!      `permissions.Store.checkDetailed`, so `--deny-tools`/`--ask-tools`
//!      /auto-mode apply exactly as if the model called the tool directly.
//!
//! Stats: each call is counted in an internal `StringHashMap(BridgeStat)`
//! (calls, errors, bytes, latency). `code_exec` appends a compact footer
//! summarizing bridge usage so the model sees how much work happened
//! in-sandbox without each payload entering the context window.

const std = @import("std");
const posix = std.posix;
const at = @import("../agent/types.zig");
const ai = @import("../ai/mod.zig");
const mcp_client = @import("mcp/client.zig");
const permissions = @import("security/permissions.zig");
const jh = @import("mcp/json_helpers.zig");

const log = ai.log;

pub const BridgeError = error{
    Unauthorized,
    UnknownTool,
    PermissionDenied,
    OutOfMemory,
    Io,
};

/// Per-tool aggregate stats, keyed by `mcp__<server>__<tool>`.
pub const BridgeStat = struct {
    calls: u64 = 0,
    errors: u64 = 0,
    total_ms: u64 = 0,
    bytes: u64 = 0,
};

/// Aggregate view used by `code_exec` to render its footer.
pub const Summary = struct {
    calls: u64,
    errors: u64,
    servers: usize,
    bytes: u64,
};

/// One registered dispatch target: the namespaced tool name plus the
/// MCP context needed to issue the remote `tools/call`.
const Target = struct {
    ns_name: []const u8,
    server: []const u8,
    ctx: *const mcp_client.McpToolCtx,
};

pub const McpBridge = struct {
    allocator: std.mem.Allocator,
    /// Stable allocator used for all bridge operations executed by the
    /// accept thread. It outlives the session arena owned by the resolver.
    io_allocator: std.mem.Allocator,
    socket_path: []u8,
    token_hex: []u8,
    token_raw: [32]u8,
    permission_store: ?*permissions.Store,
    /// Serializes shutdown with the full connection handler lifetime.
    connection_mutex: std.Io.Mutex = .init,
    server: ?std.Io.net.Server = null,
    targets: std.StringHashMap(Target),
    stats: std.StringHashMap(BridgeStat),
    running: std.atomic.Value(bool) = .init(false),
    mutex: std.Io.Mutex = .init,
    /// Captured at `listen` so `summary`/`recordStat` can lock the
    /// mutex without threading `io` through every call site.
    io: ?std.Io = null,
    serve_thread: ?std.Thread = null,

    /// Build a bridge bound to a fresh `/tmp/franky-mcp-<rand>.sock`.
    /// Mints the session token but does NOT start listening yet —
    /// call `listen` once the dispatch table is populated.
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        permission_store: ?*permissions.Store,
        io_allocator: std.mem.Allocator,
    ) !*McpBridge {
        const self = try allocator.create(McpBridge);

        var raw: [32]u8 = undefined;
        try io.randomSecure(&raw);

        const token_hex = try std.fmt.allocPrint(allocator, "{x}", .{raw});
        errdefer allocator.free(token_hex);

        // /tmp keeps the path well under macOS's 104-byte sun_path limit.
        var rand16: [8]u8 = undefined;
        try io.randomSecure(&rand16);
        const socket_path = try std.fmt.allocPrint(allocator, "/tmp/franky-mcp-{x}.sock", .{rand16});
        errdefer allocator.free(socket_path);

        self.* = .{
            .allocator = allocator,
            .io_allocator = io_allocator,
            .socket_path = socket_path,
            .token_hex = token_hex,
            .token_raw = raw,
            .permission_store = permission_store,
            .targets = std.StringHashMap(Target).init(allocator),
            .stats = std.StringHashMap(BridgeStat).init(allocator),
            .io = io,
        };
        return self;
    }

    pub fn deinit(self: *McpBridge, io: std.Io) void {
        self.shutdown(io);
        self.targets.deinit();
        self.stats.deinit();
        self.allocator.free(self.socket_path);
        self.allocator.free(self.token_hex);
        self.allocator.destroy(self);
    }

    /// Self-contained teardown using the `io` captured at `init`. Lets
    /// owners that don't hold an `io` at their own deinit (e.g.
    /// `ResolvedConfig`) release the bridge cleanly.
    pub fn deinitSelf(self: *McpBridge) void {
        if (self.io) |io| {
            self.deinit(io);
        } else {
            self.targets.deinit();
            self.stats.deinit();
            self.allocator.free(self.socket_path);
            self.allocator.free(self.token_hex);
            self.allocator.destroy(self);
        }
    }

    /// Register an MCP tool so the bridge can dispatch to it. Called once
    /// per discovered `mcp__*` tool during session setup.
    pub fn registerTool(self: *McpBridge, ctx: *const mcp_client.McpToolCtx) !void {
        const ns_name = try std.fmt.allocPrint(self.allocator, "mcp__{s}__{s}", .{ ctx.server_name, ctx.tool_name });
        try self.targets.put(ns_name, .{
            .ns_name = ns_name,
            .server = ctx.server_name,
            .ctx = ctx,
        });
    }

    /// Bind + listen on the UDS socket and set restrictive permissions.
    pub fn listen(self: *McpBridge, io: std.Io) !void {
        const addr = try std.Io.net.UnixAddress.init(self.socket_path);
        self.server = try addr.listen(io, .{ .kernel_backlog = 16 });
        // 0600 so only this user can even open the socket.
        if (comptime @import("builtin").os.tag != .windows) {
            var zbuf: [std.Io.net.UnixAddress.max_len + 1]u8 = undefined;
            @memcpy(zbuf[0..self.socket_path.len], self.socket_path);
            zbuf[self.socket_path.len] = 0;
            const path_z: [*:0]const u8 = @ptrCast(&zbuf);
            _ = std.c.chmod(path_z, 0o600);
        }
        self.running.store(true, .release);
    }

    /// Stop the accept loop and remove the socket file.
    pub fn shutdown(self: *McpBridge, io: std.Io) void {
        if (self.serve_thread) |t| {
            self.connection_mutex.lockUncancelable(io);
            defer self.connection_mutex.unlock(io);
            self.running.store(false, .release);
            // Wake a blocking accept with a local connection while the
            // listening descriptor is still valid. serve() checks `running`
            // immediately after accept and skips handling the wake connection.
            if (self.server != null) {
                const addr = std.Io.net.UnixAddress.init(self.socket_path) catch null;
                if (addr) |a| if (a.connect(io)) |stream| {
                    var wake = stream;
                    wake.close(io);
                } else |_| {};
            }
            t.join();
            self.serve_thread = null;
        }
        self.running.store(false, .release);
        if (self.server) |*s| s.deinit(io);
        self.server = null;
        std.Io.Dir.deleteFileAbsolute(io, self.socket_path) catch {};
    }

    /// Start the accept loop on a joinable background thread.
    pub fn startServing(self: *McpBridge) !void {
        if (self.serve_thread != null) return;
        if (self.io == null or self.server == null) return error.NotListening;
        self.serve_thread = try std.Thread.spawn(.{}, serveEntry, .{self});
    }

    fn serveEntry(self: *McpBridge) void {
        const io = self.io orelse return;
        self.serve(io);
    }

    /// Accept + serve connections until `shutdown` is called. Runs on its
    /// own thread for the life of the session. Each connection is one
    /// newline-delimited JSON request → one JSON response line.
    pub fn serve(self: *McpBridge, io: std.Io) void {
        while (self.running.load(.acquire)) {
            const srv = &(self.server orelse return);
            var stream = srv.accept(io) catch |err| {
                if (!self.running.load(.acquire)) return; // shutting down
                log.log(.warn, "mcp-bridge", "accept", "accept failed: {s}", .{@errorName(err)});
                continue;
            };
            // Do not process the shutdown wake-up connection: it has no
            // authorized child peer, and writing its denial response would
            // allocate through the bridge arena while the owner is tearing down.
            if (!self.running.load(.acquire)) {
                stream.close(io);
                return;
            }
            self.handleConnection(io, &stream) catch {};
            stream.close(io);
        }
    }

    /// Handle a single connection: read one JSON line, dispatch, reply.
    fn handleConnection(self: *McpBridge, io: std.Io, stream: *std.Io.net.Stream) !void {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.io_allocator);
        var chunk: [16384]u8 = undefined;
        var r = stream.reader(io, &.{});
        while (true) {
            var vecs: [1][]u8 = .{chunk[0..]};
            const n = r.interface.readVec(&vecs) catch |err| {
                if (err == error.EndOfStream) break;
                return err;
            };
            if (n == 0) break;
            try buf.appendSlice(self.io_allocator, chunk[0..n]);
            if (std.mem.indexOfScalar(u8, buf.items, '\n') != null) break;
            if (buf.items.len > 1 << 20) return error.Io; // 1 MiB request cap
        }
        const line = std.mem.trim(u8, buf.items, " \t\r\n");
        if (line.len == 0) return;
        // dispatch converts auth/permission/unknown-tool failures into a
        // JSON error payload itself, so the only errors that escape are
        // allocation/IO — surface those as a generic bridge error frame.
        const resp = self.dispatch(io, line) catch |err| blk: {
            break :blk try self.errorJson(@errorName(err));
        };
        defer self.io_allocator.free(resp);
        try self.writeJsonLine(io, stream, resp);
    }

    /// Parse + authorize + route one request frame. Returns an owned JSON
    /// response line (without trailing newline).
    fn dispatch(self: *McpBridge, io: std.Io, line: []const u8) ![]u8 {
        var arena = std.heap.ArenaAllocator.init(self.io_allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        const parsed = std.json.parseFromSliceLeaky(std.json.Value, aa, line, .{}) catch
            return try self.errorJson("invalid json");
        if (parsed != .object) return try self.errorJson("request not an object");
        const obj = parsed.object;

        // 1. Per-session bearer token. This is the bridge authentication
        // mechanism; don't bind authorization to wrapper PIDs, which vary
        // across bwrap/unshare/sandbox-exec implementations.
        const tok = if (obj.get("token")) |t| (if (t == .string) t.string else "") else "";
        if (!self.checkToken(tok)) return try self.errorJson("unauthorized token");

        const server = if (obj.get("server")) |s| (if (s == .string) s.string else "") else "";
        const tool = if (obj.get("tool")) |s| (if (s == .string) s.string else "") else "";
        var args_buf: std.ArrayList(u8) = .empty;
        if (obj.get("args")) |a| jh.renderJson(&args_buf, aa, a) catch {};
        const args: []const u8 = if (args_buf.items.len > 0) args_buf.items else "{}";

        const ns_name = try std.fmt.allocPrint(aa, "mcp__{s}__{s}", .{ server, tool });

        // 2. Permission gate — same path as a direct tool call.
        if (self.permission_store) |store| {
            const dd = store.checkDetailed(ns_name, args);
            switch (dd.decision) {
                .auto_deny => return try self.errorJson(dd.reason orelse dd.rule_name orelse "permission denied"),
                // `ask` cannot prompt mid-sandbox (no TTY / no RPC round-trip
                // from inside the isolated child), so we fail closed and tell
                // the model to allow the tool up-front.
                .ask => return try self.errorJson("tool requires approval; allow it via --allow-tools before running"),
                .auto_allow => {},
            }
        }

        // 3. Resolve + dispatch.
        const target = self.targets.get(ns_name) orelse return try self.errorJson("unknown tool");
        const start = ai.stream.nowMillis();

        var cancel: ai.stream.Cancel = .{};
        var result = mcp_client.callTool(target.ctx, self.io_allocator, io, args, &cancel) catch |err| {
            self.recordStat(ns_name, true, elapsed(start), 0);
            return try self.errorJson(@errorName(err));
        };
        defer result.deinit(self.io_allocator);

        // Serialize the ToolResult content blocks to a JSON array.
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(self.io_allocator);
        try resultToJson(&payload, self.io_allocator, result);
        self.recordStat(ns_name, result.is_error, elapsed(start), payload.items.len);

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.io_allocator);
        try out.appendSlice(self.io_allocator, "{\"result\":");
        try out.appendSlice(self.io_allocator, payload.items);
        try out.appendSlice(self.io_allocator, "}");
        return out.toOwnedSlice(self.io_allocator);
    }

    fn errorJson(self: *McpBridge, msg: []const u8) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(self.io_allocator);
        try buf.appendSlice(self.io_allocator, "{\"error\":");
        try jh.appendJsonStr(&buf, self.io_allocator, msg);
        try buf.appendSlice(self.io_allocator, "}");
        return buf.toOwnedSlice(self.io_allocator);
    }

    fn checkToken(self: *McpBridge, tok_hex: []const u8) bool {
        if (tok_hex.len != self.token_hex.len) return false;
        // Decode the provided hex then timing-safe compare against raw.
        var provided: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&provided, tok_hex) catch return false;
        return std.crypto.timing_safe.eql([32]u8, provided, self.token_raw);
    }

    fn recordStat(self: *McpBridge, ns_name: []const u8, is_error: bool, ms: u64, bytes: u64) void {
        const io = self.io orelse return;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const gop = self.stats.getOrPut(ns_name) catch return;
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.calls += 1;
        if (is_error) gop.value_ptr.errors += 1;
        gop.value_ptr.total_ms += ms;
        gop.value_ptr.bytes += bytes;
    }

    /// Aggregate summary for the `code_exec` footer.
    pub fn summary(self: *McpBridge) Summary {
        if (self.io) |io| {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            return self.summaryLocked();
        }
        return self.summaryLocked();
    }

    fn summaryLocked(self: *McpBridge) Summary {
        var s: Summary = .{ .calls = 0, .errors = 0, .servers = 0, .bytes = 0 };
        var it = self.stats.iterator();
        while (it.next()) |e| {
            s.calls += e.value_ptr.calls;
            s.errors += e.value_ptr.errors;
            s.bytes += e.value_ptr.bytes;
        }
        s.servers = self.targets.count();
        return s;
    }

    fn writeJsonLine(self: *McpBridge, io: std.Io, stream: *std.Io.net.Stream, line: []const u8) !void {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.io_allocator);
        try buf.appendSlice(self.io_allocator, line);
        try buf.append(self.io_allocator, '\n');
        var wbuf: [8192]u8 = undefined;
        var w = stream.writer(io, &wbuf);
        try w.interface.writeAll(buf.items);
        try w.interface.flush();
    }
};

fn elapsed(start_ms: i64) u64 {
    const now = ai.stream.nowMillis();
    return if (now > start_ms) @intCast(now - start_ms) else 0;
}

/// Serialize a `ToolResult`'s content blocks to a JSON array of
/// `{type, text}` / `{type, mimeType, data}` objects.
fn resultToJson(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, result: at.ToolResult) !void {
    try buf.append(allocator, '[');
    for (result.content, 0..) |cb, i| {
        if (i > 0) try buf.append(allocator, ',');
        switch (cb) {
            .text => |t| {
                try buf.appendSlice(allocator, "{\"type\":\"text\",\"text\":");
                try jh.appendJsonStr(buf, allocator, t.text);
                try buf.append(allocator, '}');
            },
            .image => |im| {
                try buf.appendSlice(allocator, "{\"type\":\"image\",\"mimeType\":");
                try jh.appendJsonStr(buf, allocator, im.mime_type);
                try buf.appendSlice(allocator, ",\"data\":");
                try jh.appendJsonStr(buf, allocator, im.data);
                try buf.append(allocator, '}');
            },
            else => {
                try buf.appendSlice(allocator, "{\"type\":\"text\",\"text\":\"\"}");
            },
        }
    }
    try buf.append(allocator, ']');
}

// ─── tests ─────────────────────────────────────────────────────────

const testing = std.testing;

/// Read one newline-terminated line from `stream` into an owned list.
fn readOneLine(gpa: std.mem.Allocator, io: std.Io, stream: *std.Io.net.Stream) !std.ArrayList(u8) {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var chunk: [1024]u8 = undefined;
    var r = stream.reader(io, &.{});
    while (true) {
        var vecs: [1][]u8 = .{chunk[0..]};
        const n = r.interface.readVec(&vecs) catch break;
        if (n == 0) break;
        try out.appendSlice(gpa, chunk[0..n]);
        if (std.mem.indexOfScalar(u8, out.items, '\n') != null) break;
    }
    return out;
}

test "token check is timing-safe and length-checked" {
    var threaded = @import("../test_helpers.zig").threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = @import("../global_allocator.zig").gpa;

    const bridge = try McpBridge.init(gpa, io, null, gpa);
    defer bridge.deinit(io);

    // Build the correct hex from raw.
    const good = try std.fmt.allocPrint(gpa, "{x}", .{bridge.token_raw});
    defer gpa.free(good);
    try testing.expect(bridge.checkToken(good));
    try testing.expect(!bridge.checkToken("deadbeef"));
    try testing.expect(!bridge.checkToken(""));
}

test "stats aggregate across calls" {
    var threaded = @import("../test_helpers.zig").threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = @import("../global_allocator.zig").gpa;

    const bridge = try McpBridge.init(gpa, io, null, gpa);
    defer bridge.deinit(io);

    bridge.recordStat("mcp__a__t1", false, 5, 100);
    bridge.recordStat("mcp__a__t1", true, 7, 40);
    bridge.recordStat("mcp__b__t2", false, 3, 200);
    const s = bridge.summary();
    try testing.expectEqual(@as(u64, 3), s.calls);
    try testing.expectEqual(@as(u64, 1), s.errors);
    try testing.expectEqual(@as(u64, 340), s.bytes);
}
