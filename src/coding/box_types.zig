//! Types for the franky-box remote task inbox/outbox.

const std = @import("std");

/// A task claimed from the inbox.
/// Fields are caller-owned slices (allocated via the provided allocator).
pub const ClaimedTask = struct {
    task_id: []const u8,
    action: []const u8,
    /// JSON payload — caller owns the memory.
    payload: []const u8,
    try_count: i64,

    pub fn deinit(self: ClaimedTask, allocator: std.mem.Allocator) void {
        allocator.free(self.task_id);
        allocator.free(self.action);
        allocator.free(self.payload);
    }
};

/// Parse a ClaimedTask from the JSON body of a claim response.
pub fn parseClaimedTask(allocator: std.mem.Allocator, json: []const u8) !?ClaimedTask {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), json, .{}) catch return null;
    if (parsed.value != .object) return null;
    const o = parsed.value.object;

    const task_id = (o.get("task_id") orelse return null).string orelse return null;
    const action = (o.get("action") orelse return null).string orelse return null;
    const payload_val = o.get("payload") orelse return null;
    const try_count = (o.get("try_count") orelse return null).integer orelse return null;

    // Serialise payload to a string.
    const payload = blk: {
        if (payload_val == .string) {
            break :blk try allocator.dupe(u8, payload_val.string);
        }
        break :blk try std.json.Stringify.valueAlloc(allocator, payload_val, .{});
    };

    return ClaimedTask{
        .task_id = try allocator.dupe(u8, task_id),
        .action = try allocator.dupe(u8, action),
        .payload = payload,
        .try_count = try_count,
    };
}

test "parse claimed task with object payload" {
    const allocator = std.testing.allocator;
    const json = "{\"task_id\":\"task-abc\",\"action\":\"process\",\"payload\":{\"file\":\"test.txt\"},\"try_count\":1}";
    const task = try parseClaimedTask(allocator, json);
    try std.testing.expect(task != null);
    if (task) |t| {
        defer t.deinit(allocator);
        try std.testing.expectEqualStrings("task-abc", t.task_id);
        try std.testing.expectEqualStrings("process", t.action);
        try std.testing.expectEqual(@as(i64, 1), t.try_count);
        try std.testing.expect(t.payload.len > 0);
    }
}

test "parse empty response returns null" {
    const allocator = std.testing.allocator;
    const task = try parseClaimedTask(allocator, "{}");
    try std.testing.expect(task == null);
}

test "parse no content response" {
    const allocator = std.testing.allocator;
    const task = try parseClaimedTask(allocator, "");
    try std.testing.expect(task == null);
}