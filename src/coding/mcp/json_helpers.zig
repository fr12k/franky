//! Shared JSON helpers for the MCP modules.
//!
//! `appendJsonStr` and `renderJson` are needed by both the MCP
//! server mode (`modes/mcp.zig`) and the MCP client
//! (`mcp/client.zig`). They mirror the private copies in
//! `rpc.zig` but are `pub` so both MCP files can import them
//! without duplicating ~70 lines of code.

const std = @import("std");

/// JSON-encode a string into `buf`, escaping control chars.
pub fn appendJsonStr(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try buf.append(allocator, '"');
    for (s) |c| switch (c) {
        '"' => try buf.appendSlice(allocator, "\\\""),
        '\\' => try buf.appendSlice(allocator, "\\\\"),
        '\n' => try buf.appendSlice(allocator, "\\n"),
        '\r' => try buf.appendSlice(allocator, "\\r"),
        '\t' => try buf.appendSlice(allocator, "\\t"),
        // 0x00-0x08 (incl backspace), 0x0b, 0x0c (form feed),
        // 0x0e-0x1f: control chars not already handled above.
        0...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
            var tmp: [8]u8 = undefined;
            const w = std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{c}) catch unreachable;
            try buf.appendSlice(allocator, w);
        },
        else => try buf.append(allocator, c),
    };
    try buf.append(allocator, '"');
}

/// Re-serialize a `std.json.Value` to a string. Mirrors rpc.zig's
/// private `renderJson` but `pub` and with `number_string` emitted
/// raw (unquoted) — it is already a numeric literal.
pub fn renderJson(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, v: std.json.Value) !void {
    switch (v) {
        .null => try buf.appendSlice(allocator, "null"),
        .bool => |b| try buf.appendSlice(allocator, if (b) "true" else "false"),
        .integer => |i| {
            var tmp: [20]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{d}", .{i}) catch unreachable;
            try buf.appendSlice(allocator, s);
        },
        .float => |f| {
            var tmp: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{d}", .{f}) catch unreachable;
            try buf.appendSlice(allocator, s);
        },
        .string => |s| try appendJsonStr(buf, allocator, s),
        .number_string => |s| try buf.appendSlice(allocator, s),
        .array => |arr| {
            try buf.append(allocator, '[');
            for (arr.items, 0..) |item, i| {
                if (i > 0) try buf.append(allocator, ',');
                try renderJson(buf, allocator, item);
            }
            try buf.append(allocator, ']');
        },
        .object => |obj| {
            try buf.append(allocator, '{');
            var it = obj.iterator();
            var first = true;
            while (it.next()) |entry| {
                if (!first) try buf.append(allocator, ',');
                first = false;
                try appendJsonStr(buf, allocator, entry.key_ptr.*);
                try buf.append(allocator, ':');
                try renderJson(buf, allocator, entry.value_ptr.*);
            }
            try buf.append(allocator, '}');
        },
    }
}

/// JSON-encode a string and return an owned slice.
pub fn jsonStr(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try appendJsonStr(&buf, allocator, s);
    return try buf.toOwnedSlice(allocator);
}

/// Split a comma-separated string into a slice of trimmed strings.
/// Empty entries are skipped. Allocates on `allocator`.
pub fn splitCsv(allocator: std.mem.Allocator, csv: []const u8) ![][]const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    errdefer result.deinit(allocator);
    var it = std.mem.splitScalar(u8, csv, ',');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (trimmed.len > 0) {
            try result.append(allocator, try allocator.dupe(u8, trimmed));
        }
    }
    return result.toOwnedSlice(allocator);
}

// ─── tests ──────────────────────────────────────────────────────

const testing = std.testing;

test "appendJsonStr: escapes control chars" {
    const gpa = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try appendJsonStr(&buf, gpa, "a\nb\"c");
    try testing.expectEqualStrings("\"a\\nb\\\"c\"", buf.items);
}

test "renderJson: number_string unquoted" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), "12345", .{});
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try renderJson(&buf, gpa, parsed.value);
    try testing.expectEqualStrings("12345", buf.items);
}

test "splitCsv: trims and skips empty" {
    const gpa = testing.allocator;
    const parts = try splitCsv(gpa, " a , ,b, ");
    defer {
        for (parts) |p| gpa.free(p);
        gpa.free(parts);
    }
    try testing.expectEqual(@as(usize, 2), parts.len);
    try testing.expectEqualStrings("a", parts[0]);
    try testing.expectEqualStrings("b", parts[1]);
}
