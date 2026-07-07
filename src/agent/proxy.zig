//! streamProxy — §4.7 event-framing primitives.
//!
//! Transport-agnostic serialization for exposing the agent loop
//! to a remote front-end over SSE:
//!
//!   - `writeEvent(writer, ev)` — render one `AgentEvent` as an SSE
//!     frame (`event: <kind>\ndata: <json>\n\n`).
//!   - `encodeEventJson(allocator, ev)` — pure function that
//!     produces the JSON payload for an event (no SSE framing).
//!
//! The HTTP/SSE listener that calls these primitives lives at
//! `coding/modes/proxy.zig` (`franky --mode proxy`, shipped
//! v1.4.0). The split keeps this module pure (no `std.Io.net`
//! dependency) so it stays testable in isolation and re-usable
//! by alternative transports (Slack-bot bridges, custom RPC
//! frames).
//!
//! Events are the same `at.AgentEvent` shapes the in-process loop
//! emits, so a remote client can drive the agent with zero
//! semantic translation — matching §4.7's "uses the same event
//! shape" invariant.

const std = @import("std");
const at = @import("types.zig");
const ai_types = @import("../ai/types.zig");
const ai_errors = @import("../ai/errors.zig");

pub const ProxyError = error{
    WriteFailed,
} || std.mem.Allocator.Error;

/// Render `ev` as an SSE frame onto `writer`. The writer signature
/// matches `std.Io.Writer` — a `writeAll([]const u8) !void` method.
pub fn writeEvent(
    allocator: std.mem.Allocator,
    writer: anytype,
    ev: at.AgentEvent,
) !void {
    const kind = @tagName(ev);
    try writer.writeAll("event: ");
    try writer.writeAll(kind);
    try writer.writeAll("\ndata: ");
    const json = try encodeEventJson(allocator, ev);
    defer allocator.free(json);
    try writer.writeAll(json);
    try writer.writeAll("\n\n");
}

/// Encode `ev` as a JSON payload — no SSE framing. Caller-owned.
pub fn encodeEventJson(allocator: std.mem.Allocator, ev: at.AgentEvent) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.append(allocator, '{');
    switch (ev) {
        .turn_start => try buf.appendSlice(allocator, "\"kind\":\"turn_start\""),
        .turn_end => try buf.appendSlice(allocator, "\"kind\":\"turn_end\""),
        .message_start => |s| {
            try buf.appendSlice(allocator, "\"kind\":\"message_start\",\"role\":");
            try appendJsonStr(&buf, allocator, roleName(s.role));
            if (s.custom_role) |cr| {
                try buf.appendSlice(allocator, ",\"customRole\":");
                try appendJsonStr(&buf, allocator, cr);
            }
        },
        .message_update => |m| switch (m) {
            .text => |t| {
                try buf.appendSlice(allocator, "\"kind\":\"message_update\",\"deltaKind\":\"text\",\"blockIndex\":");
                try appendJsonInt(&buf, allocator, @intCast(t.block_index));
                try buf.appendSlice(allocator, ",\"delta\":");
                try appendJsonStr(&buf, allocator, t.delta);
            },
            .thinking => |t| {
                try buf.appendSlice(allocator, "\"kind\":\"message_update\",\"deltaKind\":\"thinking\",\"blockIndex\":");
                try appendJsonInt(&buf, allocator, @intCast(t.block_index));
                try buf.appendSlice(allocator, ",\"delta\":");
                try appendJsonStr(&buf, allocator, t.delta);
            },
            .toolcall_args => |t| {
                try buf.appendSlice(allocator, "\"kind\":\"message_update\",\"deltaKind\":\"toolcall_args\",\"blockIndex\":");
                try appendJsonInt(&buf, allocator, @intCast(t.block_index));
                try buf.appendSlice(allocator, ",\"delta\":");
                try appendJsonStr(&buf, allocator, t.delta);
            },
        },
        .message_end => |m| {
            try buf.appendSlice(allocator, "\"kind\":\"message_end\",\"role\":");
            try appendJsonStr(&buf, allocator, roleName(m.role));
            try buf.appendSlice(allocator, ",\"contentBlocks\":");
            try appendJsonInt(&buf, allocator, @intCast(m.content.len));
        },
        .tool_execution_start => |s| {
            try buf.appendSlice(allocator, "\"kind\":\"tool_execution_start\",\"callId\":");
            try appendJsonStr(&buf, allocator, s.call_id);
            try buf.appendSlice(allocator, ",\"name\":");
            try appendJsonStr(&buf, allocator, s.name);
            try buf.appendSlice(allocator, ",\"argsJson\":");
            try appendJsonStr(&buf, allocator, s.args_json);
        },
        .tool_execution_update => |u| {
            try buf.appendSlice(allocator, "\"kind\":\"tool_execution_update\",\"callId\":");
            try appendJsonStr(&buf, allocator, u.call_id);
            try buf.appendSlice(allocator, ",\"update\":");
            try buf.appendSlice(allocator, u.update_json);
        },
        .tool_execution_end => |e| {
            try buf.appendSlice(allocator, "\"kind\":\"tool_execution_end\",\"callId\":");
            try appendJsonStr(&buf, allocator, e.call_id);
            try buf.appendSlice(allocator, ",\"isError\":");
            try buf.appendSlice(allocator, if (e.result.is_error) "true" else "false");
            if (e.result.tool_code) |code| {
                try buf.appendSlice(allocator, ",\"toolCode\":");
                try appendJsonStr(&buf, allocator, code);
            }
            // Concatenate all text content blocks into resultText so the
            // web UI can display the tool output in a collapsible panel.
            try buf.appendSlice(allocator, ",\"resultText\":");
            var combined: std.ArrayListUnmanaged(u8) = .empty;
            defer combined.deinit(allocator);
            for (e.result.content) |cb| {
                if (cb == .text) try combined.appendSlice(allocator, cb.text.text);
            }
            try appendJsonStr(&buf, allocator, combined.items);
            // §6.8 — include details_json as opaque metadata for the front-end
            // (e.g. unified diff for the edit tool). The value is already valid
            // JSON, so we append it directly without re-encoding.
            if (e.result.details_json) |dj| {
                try buf.appendSlice(allocator, ",\"detailsJson\":");
                try buf.appendSlice(allocator, dj);
            }
        },
        .tool_permission_request => |r| {
            try buf.appendSlice(allocator, "\"kind\":\"tool_permission_request\",\"callId\":");
            try appendJsonStr(&buf, allocator, r.call_id);
            try buf.appendSlice(allocator, ",\"toolName\":");
            try appendJsonStr(&buf, allocator, r.tool_name);
            try buf.appendSlice(allocator, ",\"argsJson\":");
            try appendJsonStr(&buf, allocator, r.args_json);
            try buf.appendSlice(allocator, ",\"fingerprint\":");
            try appendJsonStr(&buf, allocator, r.fingerprint);
        },
        .agent_error => |d| {
            try buf.appendSlice(allocator, "\"kind\":\"agent_error\",\"code\":");
            try appendJsonStr(&buf, allocator, d.code.toString());
            try buf.appendSlice(allocator, ",\"message\":");
            try appendJsonStr(&buf, allocator, d.message);
            if (!d.is_fatal) {
                try buf.appendSlice(allocator, ",\"isFatal\":false");
            }
            if (d.http_status) |s| {
                try buf.appendSlice(allocator, ",\"httpStatus\":");
                try appendJsonInt(&buf, allocator, @intCast(s));
            }
        },
        .agent_interrupted => {
            try buf.appendSlice(allocator, "\"kind\":\"agent_interrupted\"");
        },
        .provider_retry => |r| {
            try buf.appendSlice(allocator, "\"kind\":\"provider_retry\",\"attempt\":");
            try appendJsonInt(&buf, allocator, @intCast(r.attempt));
            try buf.appendSlice(allocator, ",\"max_attempts\":");
            try appendJsonInt(&buf, allocator, @intCast(r.max_attempts));
            try buf.appendSlice(allocator, ",\"delay_ms\":");
            try appendJsonInt(&buf, allocator, @intCast(r.delay_ms));
            try buf.appendSlice(allocator, ",\"reason\":");
            try appendJsonStr(&buf, allocator, @tagName(r.reason));
            if (r.http_status) |s| {
                try buf.appendSlice(allocator, ",\"http_status\":");
                try appendJsonInt(&buf, allocator, @intCast(s));
            }
            if (r.provider_code) |pc| {
                try buf.appendSlice(allocator, ",\"provider_code\":");
                try appendJsonStr(&buf, allocator, pc);
            }
            if (r.provider_message) |pm| {
                try buf.appendSlice(allocator, ",\"provider_message\":");
                try appendJsonStr(&buf, allocator, pm);
            }
        },
    }
    try buf.append(allocator, '}');
    return try buf.toOwnedSlice(allocator);
}

fn roleName(r: ai_types.Role) []const u8 {
    return switch (r) {
        .user => "user",
        .assistant => "assistant",
        .tool_result => "tool_result",
        .custom => "custom",
    };
}

fn appendJsonStr(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try buf.append(allocator, '"');
    for (s) |c| switch (c) {
        '"' => try buf.appendSlice(allocator, "\\\""),
        '\\' => try buf.appendSlice(allocator, "\\\\"),
        '\n' => try buf.appendSlice(allocator, "\\n"),
        '\r' => try buf.appendSlice(allocator, "\\r"),
        '\t' => try buf.appendSlice(allocator, "\\t"),
        0...0x07, 0x08, 0x0b, 0x0c, 0x0e...0x1f => {
            var tmp: [8]u8 = undefined;
            const w = std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{c}) catch unreachable;
            try buf.appendSlice(allocator, w);
        },
        else => try buf.append(allocator, c),
    };
    try buf.append(allocator, '"');
}

fn appendJsonInt(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, n: i64) !void {
    var tmp: [20]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{n}) catch unreachable;
    try buf.appendSlice(allocator, s);
}

// ─── tests ────────────────────────────────────────────────────────

const testing = std.testing;

/// Simple `writeAll`-style writer backed by an ArrayList.
const ListWriter = struct {
    list: *std.ArrayList(u8),
    allocator: std.mem.Allocator,

    fn writeAll(self: *ListWriter, bytes: []const u8) !void {
        try self.list.appendSlice(self.allocator, bytes);
    }
};

test "encodeEventJson: turn_start" {
    const gpa = testing.allocator;
    const json = try encodeEventJson(gpa, .turn_start);
    defer gpa.free(json);
    try testing.expectEqualStrings("{\"kind\":\"turn_start\"}", json);
}

test "encodeEventJson: message_start carries role" {
    const gpa = testing.allocator;
    const json = try encodeEventJson(gpa, .{ .message_start = .{ .role = .assistant } });
    defer gpa.free(json);
    try testing.expectEqualStrings("{\"kind\":\"message_start\",\"role\":\"assistant\"}", json);
}

test "encodeEventJson: text delta preserves block_index + delta text" {
    const gpa = testing.allocator;
    const json = try encodeEventJson(gpa, .{ .message_update = .{ .text = .{
        .block_index = 3,
        .delta = "hello world",
    } } });
    defer gpa.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"deltaKind\":\"text\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"blockIndex\":3") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"delta\":\"hello world\"") != null);
}

test "encodeEventJson: tool_execution_start + end" {
    const gpa = testing.allocator;
    const start_json = try encodeEventJson(gpa, .{ .tool_execution_start = .{
        .call_id = "c-7",
        .name = "read",
        .args_json = "{\"path\":\"src/foo.zig\"}",
    } });
    defer gpa.free(start_json);
    try testing.expect(std.mem.indexOf(u8, start_json, "\"callId\":\"c-7\"") != null);
    try testing.expect(std.mem.indexOf(u8, start_json, "\"name\":\"read\"") != null);
}

test "encodeEventJson: agent_error carries code + message + status" {
    const gpa = testing.allocator;
    const json = try encodeEventJson(gpa, .{ .agent_error = .{
        .code = .rate_limited_hard,
        .message = "quota exceeded",
        .http_status = 429,
    } });
    defer gpa.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"code\":\"rate_limited_hard\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"httpStatus\":429") != null);
    // Fatal errors (default) must NOT emit isFatal — omission means true.
    try testing.expect(std.mem.indexOf(u8, json, "isFatal") == null);
}

test "encodeEventJson: agent_error omits isFatal when true, includes false when non-fatal" {
    const gpa = testing.allocator;
    const json = try encodeEventJson(gpa, .{ .agent_error = .{
        .code = .compilation_failed,
        .message = "build error",
        .is_fatal = false,
    } });
    defer gpa.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"isFatal\":false") != null);
}

test "writeEvent: full SSE framing lands on the writer" {
    const gpa = testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    var w = ListWriter{ .list = &list, .allocator = gpa };

    try writeEvent(gpa, &w, .turn_start);
    try testing.expectEqualStrings("event: turn_start\ndata: {\"kind\":\"turn_start\"}\n\n", list.items);
}

test "encodeEventJson: json escaping handles quotes and newlines" {
    const gpa = testing.allocator;
    const json = try encodeEventJson(gpa, .{ .message_update = .{ .text = .{
        .block_index = 0,
        .delta = "he said \"hi\"\nlater",
    } } });
    defer gpa.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\\\"hi\\\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\\n") != null);
}
