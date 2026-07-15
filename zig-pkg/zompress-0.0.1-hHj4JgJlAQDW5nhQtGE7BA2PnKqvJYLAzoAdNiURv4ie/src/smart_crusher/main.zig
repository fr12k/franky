const std = @import("std");
const CompressConfig = @import("../main.zig").CompressConfig;
const CompressResult = @import("../main.zig").CompressResult;

pub const SmartCrusherConfig = struct {
    enabled: bool = true,
    min_items_to_analyze: usize = 5,
    min_tokens_to_crush: usize = 200,
    variance_threshold: f64 = 2.0,
    uniqueness_threshold: f64 = 0.1,
    similarity_threshold: f64 = 0.8,
    max_items_after_crush: usize = 15,
    preserve_change_points: bool = true,
    dedup_identical_items: bool = true,
    first_fraction: f64 = 0.3,
    last_fraction: f64 = 0.15,
    enable_lossless_compaction: bool = true,
};

pub const SmartCrusher = struct {
    config: SmartCrusherConfig,

    pub fn init(config: SmartCrusherConfig) SmartCrusher {
        return .{ .config = config };
    }

    pub fn crushArray(self: *SmartCrusher, allocator: std.mem.Allocator, json_text: []const u8, _: CompressConfig) !CompressResult {
        // 1. Parse JSON
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{});
        defer parsed.deinit();

        const items = switch (parsed.value) {
            .array => |arr| arr,
            else => return CompressResult.passthrough(allocator, json_text),
        };

        if (items.items.len < self.config.min_items_to_analyze) {
            return CompressResult.passthrough(allocator, json_text);
        }

        // 2. Classify array type
        const array_type = classifyArray(items.items);

        // 3. Compress based on type
        switch (array_type) {
            .dict_array => {
                return self.crushDictArray(allocator, items.items, json_text);
            },
            .string_array => {
                return self.crushStringArray(allocator, items.items, json_text);
            },
            .number_array => {
                return self.crushNumberArray(allocator, items.items, json_text);
            },
            else => {
                return CompressResult.passthrough(allocator, json_text);
            },
        }
    }

    fn crushDictArray(self: *SmartCrusher, allocator: std.mem.Allocator, items: []const std.json.Value, original: []const u8) !CompressResult {
        // Simple strategy: keep first, some with error keywords, and sample from middle
        const len = items.len;
        var kept: std.ArrayList(usize) = .empty;
        defer kept.deinit(allocator);

        // Always keep first item
        try kept.append(allocator, 0);

        // Keep last item
        if (len > 1) try kept.append(allocator, len - 1);

        // Keep error-containing items
        for (items, 0..) |item, i| {
            if (i == 0 or i == len - 1) continue;
            if (item == .object) {
                if (containsErrorInObject(item.object)) {
                    try kept.append(allocator, i);
                }
            }
        }

        // Fill remaining budget with evenly-spaced items
        const budget = self.config.max_items_after_crush;
        while (kept.items.len < budget and kept.items.len < len) {
            // Find the largest gap between kept indices and insert the midpoint
            var max_gap: usize = 0;
            var insert_at_idx: usize = 0;
            std.mem.sort(usize, kept.items, {}, comptime std.sort.asc(usize));
            for (kept.items, 0..) |_, idx| {
                if (idx + 1 >= kept.items.len) break;
                const gap = kept.items[idx + 1] - kept.items[idx];
                if (gap > max_gap) {
                    max_gap = gap;
                    insert_at_idx = idx;
                }
            }
            if (max_gap <= 1) break;
            try kept.append(allocator, kept.items[insert_at_idx] + max_gap / 2);
        }

        // Sort kept indices
        std.mem.sort(usize, kept.items, {}, comptime std.sort.asc(usize));

        // Deduplicate
        var deduped: std.ArrayList(usize) = .empty;
        defer deduped.deinit(allocator);
        for (kept.items, 0..) |idx, i| {
            if (i > 0 and kept.items[i - 1] == idx) continue;
            try deduped.append(allocator, idx);
        }

        // Build output
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);
        try out.append(allocator, '[');
        for (deduped.items, 0..) |idx, i| {
            if (i > 0) try out.append(allocator, ',');
            const item_str = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(items[idx], .{})});
            defer allocator.free(item_str);
            try out.appendSlice(allocator, item_str);
        }
        try out.append(allocator, ']');

        const compressed = try allocator.dupe(u8, out.items);

        return CompressResult{
            .compressed = compressed,
            .tokens_before = original.len / 4,
            .tokens_after = compressed.len / 4,
            .tokens_saved = (original.len - compressed.len) / 4,
            .compression_ratio = @as(f64, @floatFromInt(compressed.len)) / @as(f64, @floatFromInt(original.len)),
            .transforms_applied = try allocator.dupe([]const u8, &[_][]const u8{"smart_crusher"}),
            .ccr_keys = try allocator.dupe([]const u8, &[_][]const u8{}),
        };
    }

    fn crushStringArray(_: *SmartCrusher, allocator: std.mem.Allocator, items: []const std.json.Value, original: []const u8) !CompressResult {
        var kept: std.ArrayList(usize) = .empty;
        defer kept.deinit(allocator);

        // Keep first
        try kept.append(allocator, 0);
        // Keep last
        if (items.len > 1) try kept.append(allocator, items.len - 1);

        // Keep strings with error keywords or unusual length
        var avg_len: f64 = 0;
        var count: usize = 0;
        for (items) |item| {
            if (item == .string) {
                avg_len += @as(f64, @floatFromInt(item.string.len));
                count += 1;
            }
        }
        if (count > 0) avg_len /= @as(f64, @floatFromInt(count));

        for (items, 0..) |item, i| {
            if (i == 0 or i == items.len - 1) continue;
            if (item == .string) {
                const s = item.string;
                if (containsErrorKeyword(s)) {
                    try kept.append(allocator, i);
                } else if (avg_len > 0 and @as(f64, @floatFromInt(s.len)) > avg_len * 2) {
                    try kept.append(allocator, i);
                }
            }
        }

        std.mem.sort(usize, kept.items, {}, comptime std.sort.asc(usize));

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);
        try out.append(allocator, '[');
        var prev: ?usize = null;
        for (kept.items) |idx| {
            if (prev) |p| if (p == idx) continue;
            prev = idx;
            if (out.items.len > 1) try out.append(allocator, ',');
            const item_str = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(items[idx], .{})});
            defer allocator.free(item_str);
            try out.appendSlice(allocator, item_str);
        }
        try out.append(allocator, ']');

        const compressed = try allocator.dupe(u8, out.items);
        return CompressResult{
            .compressed = compressed,
            .tokens_before = original.len / 4,
            .tokens_after = compressed.len / 4,
            .tokens_saved = (original.len - compressed.len) / 4,
            .compression_ratio = @as(f64, @floatFromInt(compressed.len)) / @as(f64, @floatFromInt(original.len)),
            .transforms_applied = try allocator.dupe([]const u8, &[_][]const u8{"smart_crusher"}),
            .ccr_keys = try allocator.dupe([]const u8, &[_][]const u8{}),
        };
    }

    fn crushNumberArray(_: *SmartCrusher, allocator: std.mem.Allocator, items: []const std.json.Value, original: []const u8) !CompressResult {
        _ = items;
        // For number arrays, just passthrough for MVP
        return CompressResult.passthrough(allocator, original);
    }
};

pub const ArrayType = enum {
    dict_array,
    string_array,
    number_array,
    bool_array,
    nested_array,
    mixed_array,
    empty,
};

pub fn classifyArray(items: []const std.json.Value) ArrayType {
    if (items.len == 0) return .empty;

    var has_bool = false;
    var has_number = false;
    var has_string = false;
    var has_object = false;
    var has_array = false;
    var has_null = false;

    for (items) |item| {
        switch (item) {
            .bool => has_bool = true,
            .integer, .float => has_number = true,
            .string => has_string = true,
            .object => has_object = true,
            .array => has_array = true,
            .null => has_null = true,
            .number_string => has_string = true, // treat as string
        }
    }

    if (has_object and !has_bool and !has_number and !has_string and !has_array and !has_null)
        return .dict_array;
    if (has_string and !has_bool and !has_number and !has_object and !has_array and !has_null)
        return .string_array;
    if (has_number and !has_bool and !has_string and !has_object and !has_array and !has_null)
        return .number_array;
    if (has_bool and !has_number and !has_string and !has_object and !has_array and !has_null)
        return .bool_array;
    if (has_array and !has_bool and !has_number and !has_string and !has_object and !has_null)
        return .nested_array;

    return .mixed_array;
}

fn containsErrorKeyword(text: []const u8) bool {
    const keywords = &[_][]const u8{
        "error", "exception", "failed", "failure", "fatal",
        "traceback", "panic", "segmentation fault", "abort",
        "crash", "timeout", "unreachable", "assert",
        "cannot", "unable to", "permission denied",
        "not found", "invalid", "syntax error", "type mismatch",
    };
    var lower_buf: [4096]u8 = undefined;
    if (text.len > lower_buf.len) return false;
    const lower = std.ascii.lowerString(&lower_buf, text);
    for (keywords) |kw| {
        if (std.mem.indexOf(u8, lower, kw) != null) return true;
    }
    return false;
}

fn containsErrorInObject(obj: std.json.ObjectMap) bool {
    var iter = obj.iterator();
    while (iter.next()) |entry| {
        if (entry.value_ptr.* == .string) {
            if (containsErrorKeyword(entry.value_ptr.*.string)) return true;
        }
    }
    return false;
}

test "classify empty array" {
    try std.testing.expectEqual(ArrayType.empty, classifyArray(&[_]std.json.Value{}));
}

test "classify dict array" {
    var items: [1]std.json.Value = undefined;
    var obj = try std.json.ObjectMap.init(std.testing.allocator, &[_][]const u8{}, &[_]std.json.Value{});
    defer obj.deinit(std.testing.allocator);
    try obj.put(std.testing.allocator, "a", std.json.Value{ .float = 1.0 });
    items[0] = std.json.Value{ .object = obj };
    try std.testing.expectEqual(ArrayType.dict_array, classifyArray(&items));
}

test "containsErrorKeyword matches error text" {
    try std.testing.expect(containsErrorKeyword("this is an error message"));
    try std.testing.expect(containsErrorKeyword("Assertion failed"));
    try std.testing.expect(!containsErrorKeyword("normal informational text"));
    try std.testing.expect(!containsErrorKeyword(""));
}

test "containsErrorInObject detects error fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    
    var obj = try std.json.ObjectMap.init(a, &[_][]const u8{}, &[_]std.json.Value{});
    defer obj.deinit(a);
    try obj.put(a, "status", std.json.Value{ .string = "error occurred" });
    try std.testing.expect(containsErrorInObject(obj));
}

test "crushArray passes through small arrays" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var crusher = SmartCrusher.init(.{});
    const config = CompressConfig{};

    // Single item array should passthrough
    const single = try crusher.crushArray(a, "[42]", config);
    try std.testing.expect(std.mem.indexOf(u8, single.compressed, "42") != null);

    // Dict array with errors should compress
    const with_errors = 
        \\[{"msg": "ok"}, {"msg": "error: timeout"}, {"msg": "ok2"}, {"msg": "ok3"}, {"msg": "ok4"}, {"msg": "ok5"}]
    ;
    const result = try crusher.crushArray(a, with_errors, config);
    try std.testing.expect(std.mem.indexOf(u8, result.compressed, "error: timeout") != null);
    try std.testing.expect(result.compressed.len <= with_errors.len);
}

test "classify string array" {
    var items: [3]std.json.Value = undefined;
    items[0] = std.json.Value{ .string = "hello" };
    items[1] = std.json.Value{ .string = "world" };
    items[2] = std.json.Value{ .string = "test" };
    try std.testing.expectEqual(ArrayType.string_array, classifyArray(&items));
}

test "crushStringArray keeps errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var crusher = SmartCrusher.init(.{});
    const config = CompressConfig{};

    const input =
        \\["normal", "fine", "error: crash", "normal2", "normal3", "normal4", "normal5"]
    ;
    const result = try crusher.crushArray(a, input, config);
    try std.testing.expect(std.mem.indexOf(u8, result.compressed, "error: crash") != null);
    try std.testing.expect(result.compressed.len <= input.len);
}
