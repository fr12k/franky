const std = @import("std");
const content_detector = @import("content_detector.zig");
const ContentType = content_detector.ContentType;
const DetectionResult = content_detector.DetectionResult;
const smart_crusher = @import("smart_crusher/main.zig");
const code_compressor = @import("code_compressor.zig");
const plain_text_compressor = @import("plain_text_compressor.zig");
const log_compressor = @import("log_compressor.zig");
const search_compressor = @import("search_compressor.zig");
const diff_compressor = @import("diff_compressor.zig");
const CompressConfig = @import("main.zig").CompressConfig;
const CompressResult = @import("main.zig").CompressResult;

pub const ContentRouter = struct {
    config: CompressConfig,

    pub fn init(config: CompressConfig) ContentRouter {
        return .{ .config = config };
    }

    pub fn compress(_: *ContentRouter, allocator: std.mem.Allocator, input: []const u8, config: CompressConfig) !CompressResult {
        const detection = content_detector.detect(input);

        switch (detection.content_type) {
            .json_array => {
                if (!config.smart_crusher_enabled) return CompressResult.passthrough(allocator, input);
                var crusher = smart_crusher.SmartCrusher.init(.{});
                return crusher.crushArray(allocator, input, config);
            },
            .json_object => {
                return CompressResult.passthrough(allocator, input);
            },
            .source_code => {
                if (config.smart_crusher_enabled) {
                    return code_compressor.compress(allocator, @ptrCast(input), config);
                }
                return CompressResult.passthrough(allocator, input);
            },
            .search_results => {
                if (!config.search_compressor_enabled) return CompressResult.passthrough(allocator, input);
                return search_compressor.compress(allocator, input, config);
            },
            .build_output => {
                if (!config.log_compressor_enabled) return CompressResult.passthrough(allocator, input);
                return log_compressor.compress(allocator, input, config);
            },
            .git_diff => {
                if (!config.diff_compressor_enabled) return CompressResult.passthrough(allocator, input);
                return diff_compressor.compress(allocator, input, config);
            },
            .html, .xml, .csv => {
                return CompressResult.passthrough(allocator, input);
            },
            .plain_text => {
                if (!config.plain_text_compressor_enabled) return CompressResult.passthrough(allocator, input);
                return plain_text_compressor.compress(allocator, input, config);
            },
        }
    }
};

test "ContentRouter routes JSON arrays to SmartCrusher" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var router = ContentRouter.init(.{});
    const config = @import("main.zig").CompressConfig{};

    const json_input = 
        \\[{"msg": "ok"}, {"msg": "error: timeout"}, {"msg": "ok2"}, {"msg": "ok3"}, {"msg": "ok4"}, {"msg": "ok5"}]
    ;
    const result = try router.compress(a, json_input, config);
    try std.testing.expect(std.mem.indexOf(u8, result.compressed, "error: timeout") != null);
    try std.testing.expect(result.transforms_applied.len > 0);
}

test "ContentRouter passes through short plain text" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var router = ContentRouter.init(.{});
    const config = @import("main.zig").CompressConfig{};

    const text = "This is just some plain text content.";
    const result = try router.compress(a, text, config);
    // Short text (< 10 lines) passes through unchanged
    try std.testing.expectEqualStrings(text, result.compressed);
    try std.testing.expectEqual(@as(usize, 0), result.transforms_applied.len);
}

test "ContentRouter compresses long plain text" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var router = ContentRouter.init(.{});
    const config = @import("main.zig").CompressConfig{};

    // 50 lines of plain text — should trigger plain_text_compressor
    var input = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        if (i > 0) try input.append(a, '\n');
        const line = try std.fmt.allocPrint(a, "this is plain text line {d}", .{i});
        try input.appendSlice(a, line);
    }

    const result = try router.compress(a, input.items, config);
    // Should have been compressed (smaller than original)
    try std.testing.expect(result.compressed.len < input.items.len);
    try std.testing.expect(result.transforms_applied.len > 0);
}
