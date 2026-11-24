//! Shared JSON helpers for the MCP modules.
//!
//! `appendJsonStr` and `renderJson` are needed by both the MCP
//! server mode (`modes/mcp.zig`) and the MCP client
//! (`mcp/client.zig`). They mirror the private copies in
//! `rpc.zig` but are `pub` so both MCP files can import them
//! without duplicating ~70 lines of code.

const std = @import("std");
const ai_utils = @import("../../ai/utils.zig");

/// JSON-encode a string into `buf`, escaping control chars.
pub const appendJsonStr = ai_utils.appendJsonStr;

/// Re-serialize a `std.json.Value` to a string, appending into `buf`.
/// Thin wrapper around `std.json.Stringify.valueAlloc` — the stdlib
/// handles all value types (null/bool/int/float/string/array/object/
/// number_string) with correct escaping.
pub fn renderJson(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, v: std.json.Value) !void {
    const s = try std.json.Stringify.valueAlloc(allocator, v, .{});
    defer allocator.free(s);
    try buf.appendSlice(allocator, s);
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
