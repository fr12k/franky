const std = @import("std");
const builtin = @import("builtin");

// Re-export all public types
pub const code_compressor = @import("code_compressor.zig");
pub const content_detector = @import("content_detector.zig");
pub const content_router = @import("content_router.zig");
pub const adaptive_sizer = @import("adaptive_sizer.zig");
pub const smart_crusher = @import("smart_crusher/main.zig");
pub const log_compressor = @import("log_compressor.zig");
pub const search_compressor = @import("search_compressor.zig");
pub const diff_compressor = @import("diff_compressor.zig");
pub const ccr = @import("ccr/main.zig");

pub const util = struct {
    pub const hash = @import("util/hash.zig");
    pub const math = @import("util/math.zig");
    pub const token_counter = @import("util/token_counter.zig");
};

pub const CompressConfig = @import("main.zig").CompressConfig;
pub const CompressResult = @import("main.zig").CompressResult;
pub const CompressionError = @import("main.zig").CompressionError;
pub const ContentType = @import("content_detector.zig").ContentType;
pub const DetectionResult = @import("content_detector.zig").DetectionResult;

pub const compress = @import("main.zig").compress;
pub const compressJson = @import("main.zig").compressJson;
pub const compressLogs = @import("main.zig").compressLogs;
pub const compressSearch = @import("main.zig").compressSearch;
pub const compressDiff = @import("main.zig").compressDiff;

test "all modules compile" {
    _ = @import("content_detector.zig");
    _ = @import("content_router.zig");
    _ = @import("adaptive_sizer.zig");
    _ = @import("smart_crusher/main.zig");
    _ = @import("log_compressor.zig");
    _ = @import("search_compressor.zig");
    _ = @import("diff_compressor.zig");
    _ = @import("ccr/main.zig");
    _ = @import("util/hash.zig");
    _ = @import("util/math.zig");
    _ = @import("util/token_counter.zig");
}

test "compress returns caller-owned memory (regression: arena use-after-free)" {
    // This test verifies that compress() returns memory allocated through
    // the caller's allocator, not through an internal arena that gets freed
    // before the caller can use it.
    const allocator = std.testing.allocator;

    const json_input =
        \\["a","b","c","d","e","f","g","h","i","j"]
    ;

    const result = try compress(allocator, json_input, .{});

    // Use the result to ensure the memory is actually accessible
    try std.testing.expect(result.compressed.len > 0);

    // Now free the result fields through the caller's allocator.
    // This would crash or panic if the memory was owned by an internal
    // arena that had already been deinited.
    allocator.free(result.compressed);
    allocator.free(result.transforms_applied);
    allocator.free(result.ccr_keys);
}

test "compress result survives allocator reuse (regression)" {
    // Call compress() repeatedly through the same allocator.
    // The old arena bug would double-free across calls.
    const allocator = std.testing.allocator;

    const text_input = "Just some plain text that should pass through unchanged.";

    for (0..5) |_| {
        const result = try compress(allocator, text_input, .{});
        allocator.free(result.compressed);
        allocator.free(result.transforms_applied);
        allocator.free(result.ccr_keys);
    }
}

test "compressJson returns caller-owned memory" {
    const allocator = std.testing.allocator;

    const json_input =
        \\["x","y","z","1","2","3","4","5"]
    ;

    const result = try compressJson(allocator, json_input, .{});
    defer {
        allocator.free(result.compressed);
        allocator.free(result.transforms_applied);
        allocator.free(result.ccr_keys);
    }

    try std.testing.expect(result.compressed.len > 0);
}

test "compressLogs returns caller-owned memory" {
    const allocator = std.testing.allocator;

    const log_input =
        \\ERROR: something failed
    ;

    const result = try compressLogs(allocator, log_input, .{});
    defer {
        allocator.free(result.compressed);
        allocator.free(result.transforms_applied);
        allocator.free(result.ccr_keys);
    }

    try std.testing.expect(result.compressed.len > 0);
}

test "compressSearch returns caller-owned memory" {
    const allocator = std.testing.allocator;

    const search_input = "src/main.zig:10:  pub fn main() !void {}";

    const result = try compressSearch(allocator, search_input, .{});
    defer {
        allocator.free(result.compressed);
        allocator.free(result.transforms_applied);
        allocator.free(result.ccr_keys);
    }

    try std.testing.expect(result.compressed.len > 0);
}

test "compressDiff returns caller-owned memory" {
    const allocator = std.testing.allocator;

    const diff_input =
        \\diff --git a/a.txt b/a.txt
        \\index abc..def 100644
        \\--- a/a.txt
        \\+++ b/a.txt
        \\@@ -1,3 +1,4 @@
        \\ one
        \\-two
        \\+two updated
        \\ three
    ;

    const result = try compressDiff(allocator, diff_input, .{});
    defer {
        allocator.free(result.compressed);
        allocator.free(result.transforms_applied);
        allocator.free(result.ccr_keys);
    }

    try std.testing.expect(result.compressed.len > 0);
}
