//! RPC protocol — §I.
//!
//! JSON-RPC 2.0 over stdio with LSP-style framing:
//!
//!   Content-Length: <N>\r\n
//!   \r\n
//!   { "jsonrpc": "2.0", "method": "...", "id": ..., "params": { ... } }
//!
//! This module ships the pure-logic pieces:
//!
//!   - `Framer` — read frames off a byte slice (the
//!     `readFrame(bytes, cursor) ?{header_end, body_start, body_end}`
//!     step) and `writeFrame(writer, json_payload)` for responses.
//!   - `Request` / `Response` / `Notification` structs + `parseRequest`
//!     / `encodeResponse` / `encodeNotification`.
//!
//! The `--mode rpc` dispatcher that actually reads stdin, pumps a
//! session, and writes stdout is a thin wrapper around these
//! primitives. It ships in a follow-up once the session/print-mode
//! glue settles.

const std = @import("std");
const ai_utils = @import("../ai/utils.zig");

pub const RpcError = error{
    MalformedFrame,
    MalformedJson,
    MissingJsonRpcField,
} || std.mem.Allocator.Error;

pub const Request = struct {
    jsonrpc: []const u8, // expected "2.0"
    id: ?Id = null,
    method: []const u8,
    /// Raw params JSON slice (caller owns the source buffer).
    params_raw: ?[]const u8 = null,
};

pub const Id = union(enum) {
    number: i64,
    string: []const u8,
};

/// Parse a single JSON-RPC 2.0 request. Strings reference the
/// input buffer (no allocation). Returns `MissingJsonRpcField` when
/// required fields (`jsonrpc`, `method`) are absent.
pub fn parseRequest(allocator: std.mem.Allocator, body: []const u8) !Request {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), body, .{}) catch return RpcError.MalformedJson;
    if (parsed.value != .object) return RpcError.MalformedJson;
    const o = parsed.value.object;

    const jr = o.get("jsonrpc") orelse return RpcError.MissingJsonRpcField;
    if (jr != .string) return RpcError.MalformedJson;

    const method = o.get("method") orelse return RpcError.MissingJsonRpcField;
    if (method != .string) return RpcError.MalformedJson;

    var req = Request{
        .jsonrpc = try allocator.dupe(u8, jr.string),
        .method = try allocator.dupe(u8, method.string),
    };
    errdefer freeRequest(allocator, &req);

    if (o.get("id")) |idv| switch (idv) {
        .integer => |i| req.id = .{ .number = i },
        .string => |s| req.id = .{ .string = try allocator.dupe(u8, s) },
        else => {},
    };

    if (o.get("params")) |pv| {
        // Re-serialize the params sub-object as a raw slice so the
        // caller can re-parse without a second json.Value pass.
        req.params_raw = try std.json.Stringify.valueAlloc(allocator, pv, .{});
    }

    return req;
}

pub fn freeRequest(allocator: std.mem.Allocator, r: *Request) void {
    allocator.free(r.jsonrpc);
    allocator.free(r.method);
    if (r.id) |i| switch (i) {
        .string => |s| allocator.free(s),
        else => {},
    };
    if (r.params_raw) |p| allocator.free(p);
}

/// Write LSP-framed JSON to `writer` (anything with a `writeAll`
/// method).
pub fn writeFrame(writer: anytype, payload_json: []const u8) !void {
    var hdr_buf: [64]u8 = undefined;
    const hdr = std.fmt.bufPrint(&hdr_buf, "Content-Length: {d}\r\n\r\n", .{payload_json.len}) catch unreachable;
    try writer.writeAll(hdr);
    try writer.writeAll(payload_json);
}

pub const FrameSpan = struct {
    body_start: usize,
    body_end: usize,
};

/// Parse one LSP frame starting at `cursor`. Returns `null` when
/// the buffer doesn't yet contain a full header+body. Returns
/// `MalformedFrame` when the header shape is invalid.
pub fn readFrame(bytes: []const u8, cursor: usize) !?FrameSpan {
    if (cursor >= bytes.len) return null;
    // Find the `\r\n\r\n` header terminator.
    const rest = bytes[cursor..];
    const term = std.mem.indexOf(u8, rest, "\r\n\r\n") orelse return null;
    const header = rest[0..term];

    // Look for `Content-Length: <N>` case-insensitively.
    var lines = std.mem.splitSequence(u8, header, "\r\n");
    var content_length: ?usize = null;
    while (lines.next()) |line| {
        if (startsWithCI(line, "content-length:")) {
            const trimmed = std.mem.trim(u8, line["content-length:".len..], " \t");
            content_length = std.fmt.parseInt(usize, trimmed, 10) catch return RpcError.MalformedFrame;
        }
    }
    if (content_length == null) return RpcError.MalformedFrame;
    const body_start = cursor + term + 4; // past "\r\n\r\n"
    const body_end = body_start + content_length.?;
    if (body_end > bytes.len) return null; // body incomplete
    return .{ .body_start = body_start, .body_end = body_end };
}

fn startsWithCI(hay: []const u8, needle: []const u8) bool {
    if (hay.len < needle.len) return false;
    for (needle, 0..) |c, i| {
        if (std.ascii.toLower(hay[i]) != std.ascii.toLower(c)) return false;
    }
    return true;
}

pub const Response = struct {
    id: ?Id = null,
    result_raw: ?[]const u8 = null,
    err: ?struct {
        code: i64,
        message: []const u8,
    } = null,
};

pub fn encodeResponse(allocator: std.mem.Allocator, resp: Response) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"jsonrpc\":\"2.0\"");
    if (resp.id) |idv| {
        try buf.appendSlice(allocator, ",\"id\":");
        switch (idv) {
            .number => |n| try ai_utils.appendJsonInt(&buf, allocator, n),
            .string => |s| try ai_utils.appendJsonStr(&buf, allocator, s),
        }
    } else {
        try buf.appendSlice(allocator, ",\"id\":null");
    }
    if (resp.err) |e| {
        try buf.appendSlice(allocator, ",\"error\":{\"code\":");
        try ai_utils.appendJsonInt(&buf, allocator, e.code);
        try buf.appendSlice(allocator, ",\"message\":");
        try ai_utils.appendJsonStr(&buf, allocator, e.message);
        try buf.append(allocator, '}');
    } else if (resp.result_raw) |r| {
        try buf.appendSlice(allocator, ",\"result\":");
        try buf.appendSlice(allocator, r);
    } else {
        try buf.appendSlice(allocator, ",\"result\":null");
    }
    try buf.append(allocator, '}');
    return try buf.toOwnedSlice(allocator);
}

pub fn encodeNotification(
    allocator: std.mem.Allocator,
    method: []const u8,
    params_raw: ?[]const u8,
) ![]u8 {
    // `params_raw` is a pre-serialized JSON blob embedded verbatim via
    // `.format = .raw_json`; `method` is escaped by std.json. The constant
    // `jsonrpc` field comes from `json_prefix`.
    const Notification = struct {
        method: []const u8,
        params_raw: ?[]const u8 = null,

        pub const json_prefix = .{
            .jsonrpc = @as([]const u8, "2.0"),
        };

        pub const json_meta = .{
            .params_raw = .{ .rename = "params", .format = .raw_json },
        };

        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try @import("../ai/json_meta.zig").stringifyWithMeta(self, jw);
        }
    };
    return std.json.Stringify.valueAlloc(allocator, Notification{
        .method = method,
        .params_raw = params_raw,
    }, .{ .emit_null_optional_fields = false });
}

// ─── tests ────────────────────────────────────────────────────────

const testing = std.testing;

const ListWriter = struct {
    list: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    fn writeAll(self: *ListWriter, bytes: []const u8) !void {
        try self.list.appendSlice(self.allocator, bytes);
    }
};

test "readFrame: single complete frame" {
    const raw = "Content-Length: 17\r\n\r\n{\"jsonrpc\":\"2.0\"}";
    const span = (try readFrame(raw, 0)).?;
    try testing.expectEqual(@as(usize, raw.len - 17), span.body_start);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\"}", raw[span.body_start..span.body_end]);
}

test "readFrame: body not yet fully received → null" {
    const partial = "Content-Length: 100\r\n\r\n{\"jsonrpc\":\"2.0\"}";
    const span = try readFrame(partial, 0);
    try testing.expect(span == null);
}

test "readFrame: missing Content-Length → MalformedFrame" {
    const raw = "Host: localhost\r\n\r\n{\"jsonrpc\":\"2.0\"}";
    const err = readFrame(raw, 0);
    try testing.expectError(RpcError.MalformedFrame, err);
}

test "readFrame: Content-Length is case-insensitive" {
    const raw = "CONTENT-LENGTH: 2\r\n\r\n{}";
    const span = (try readFrame(raw, 0)).?;
    try testing.expectEqualStrings("{}", raw[span.body_start..span.body_end]);
}

test "writeFrame: wraps payload with Content-Length header" {
    const gpa = testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    var w = ListWriter{ .list = &list, .allocator = gpa };
    try writeFrame(&w, "{\"x\":1}");
    try testing.expectEqualStrings("Content-Length: 7\r\n\r\n{\"x\":1}", list.items);
}

test "parseRequest: method + id + numeric id" {
    const gpa = testing.allocator;
    const body =
        \\{"jsonrpc":"2.0","id":42,"method":"prompt","params":{"text":"hi"}}
    ;
    var req = try parseRequest(gpa, body);
    defer freeRequest(gpa, &req);
    try testing.expectEqualStrings("2.0", req.jsonrpc);
    try testing.expectEqualStrings("prompt", req.method);
    try testing.expect(req.id != null);
    switch (req.id.?) {
        .number => |n| try testing.expectEqual(@as(i64, 42), n),
        .string => try testing.expect(false),
    }
    try testing.expect(req.params_raw != null);
    // Re-rendered params object still contains the `text` key.
    try testing.expect(std.mem.indexOf(u8, req.params_raw.?, "\"text\"") != null);
}

test "parseRequest: string id round-trip" {
    const gpa = testing.allocator;
    var req = try parseRequest(gpa, "{\"jsonrpc\":\"2.0\",\"id\":\"c-7\",\"method\":\"ping\"}");
    defer freeRequest(gpa, &req);
    switch (req.id.?) {
        .string => |s| try testing.expectEqualStrings("c-7", s),
        .number => try testing.expect(false),
    }
}

test "parseRequest: missing method → MissingJsonRpcField" {
    const err = parseRequest(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1}");
    try testing.expectError(RpcError.MissingJsonRpcField, err);
}

test "parseRequest: malformed JSON → MalformedJson" {
    const err = parseRequest(testing.allocator, "{ not json");
    try testing.expectError(RpcError.MalformedJson, err);
}

test "encodeResponse: result path" {
    const gpa = testing.allocator;
    const json = try encodeResponse(gpa, .{
        .id = .{ .number = 3 },
        .result_raw = "{\"ok\":true}",
    });
    defer gpa.free(json);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"ok\":true}}", json);
}

test "encodeResponse: error path wins over result" {
    const gpa = testing.allocator;
    const json = try encodeResponse(gpa, .{
        .id = .{ .string = "x" },
        .err = .{ .code = -32600, .message = "bad request" },
    });
    defer gpa.free(json);
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":\"x\",\"error\":{\"code\":-32600,\"message\":\"bad request\"}}",
        json,
    );
}

test "encodeNotification: method + params" {
    const gpa = testing.allocator;
    const json = try encodeNotification(gpa, "event", "{\"kind\":\"turn_start\"}");
    defer gpa.free(json);
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"method\":\"event\",\"params\":{\"kind\":\"turn_start\"}}",
        json,
    );
}

test "frame round-trip: request → response via writer" {
    const gpa = testing.allocator;
    const req_body =
        \\{"jsonrpc":"2.0","id":1,"method":"ping"}
    ;
    var framed: std.ArrayList(u8) = .empty;
    defer framed.deinit(gpa);
    var w = ListWriter{ .list = &framed, .allocator = gpa };
    try writeFrame(&w, req_body);

    const span = (try readFrame(framed.items, 0)).?;
    var req = try parseRequest(gpa, framed.items[span.body_start..span.body_end]);
    defer freeRequest(gpa, &req);
    try testing.expectEqualStrings("ping", req.method);
}
