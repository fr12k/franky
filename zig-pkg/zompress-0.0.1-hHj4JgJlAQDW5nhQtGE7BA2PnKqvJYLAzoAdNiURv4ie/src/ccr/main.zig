const std = @import("std");
const hash_util = @import("../util/hash.zig");

pub const CcrStore = struct {
    map: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) CcrStore {
        return .{
            .map = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CcrStore) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.map.deinit();
    }

    pub fn store(self: *CcrStore, original: []const u8) ![]const u8 {
        const key = &hash_util.computeHash(original);
        const key_dup = try self.allocator.dupe(u8, key);
        const val_dup = try self.allocator.dupe(u8, original);
        try self.map.put(key_dup, val_dup);
        return key_dup;
    }

    pub fn retrieve(self: *CcrStore, key: []const u8) ?[]const u8 {
        return self.map.get(key);
    }

    pub fn formatMarker(hash: []const u8, count: usize, allocator: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(allocator, "<<ccr:{s} {d}_rows_offloaded>>", .{ hash, count });
    }

    pub fn parseMarker(text: []const u8) ?struct { hash: []const u8, count: usize } {
        const prefix = "<<ccr:";
        if (!std.mem.startsWith(u8, text, prefix)) return null;
        const rest = text[prefix.len..];
        const space = std.mem.indexOf(u8, rest, " ") orelse return null;
        const hash = rest[0..space];
        const suffix = rest[space + 1 ..];
        const underscore = std.mem.indexOf(u8, suffix, "_") orelse return null;
        const count_str = suffix[0..underscore];
        const count = std.fmt.parseInt(usize, count_str, 10) catch return null;
        return .{ .hash = hash, .count = count };
    }
};

test "CCR store and retrieve" {
    var store = CcrStore.init(std.testing.allocator);
    defer store.deinit();

    const original = "Large payload content here";
    const key = try store.store(original);
    const retrieved = store.retrieve(key) orelse return error.TestFailed;
    try std.testing.expectEqualStrings(original, retrieved);
}

test "CCR marker format and parse" {
    const marker = try CcrStore.formatMarker("abc123", 42, std.testing.allocator);
    defer std.testing.allocator.free(marker);

    const parsed = CcrStore.parseMarker(marker) orelse return error.TestFailed;
    try std.testing.expectEqualStrings("abc123", parsed.hash);
    try std.testing.expectEqual(@as(usize, 42), parsed.count);
}

test "CCR marker parse invalid" {
    try std.testing.expect(CcrStore.parseMarker("not a marker") == null);
}
