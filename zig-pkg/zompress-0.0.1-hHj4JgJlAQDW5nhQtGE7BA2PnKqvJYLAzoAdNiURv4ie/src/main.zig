const std = @import("std");

pub const CompressionError = error{
    EmptyInput,
    InvalidJson,
    ParseFailed,
    Uncompressible,
    CcrStoreFull,
};

pub const CompressConfig = struct {
    /// What to compress
    compress_user_messages: bool = false,
    compress_system_messages: bool = true,
    protect_recent: usize = 4,
    protect_analysis_context: bool = true,

    /// How aggressive
    target_ratio: ?f64 = null,
    min_tokens_to_compress: usize = 250,

    /// JSON compression
    smart_crusher_enabled: bool = true,
    max_items_after_crush: usize = 15,
    variance_threshold: f64 = 2.0,
    similarity_threshold: f64 = 0.8,

    /// Log compression
    log_compressor_enabled: bool = true,
    log_max_errors: usize = 10,
    log_max_lines: usize = 100,

    /// Search compression
    search_compressor_enabled: bool = true,
    search_max_matches_per_file: usize = 5,
    search_max_files: usize = 15,

    /// Diff compression
    diff_compressor_enabled: bool = true,
    diff_max_context_lines: usize = 2,
    diff_max_hunks_per_file: usize = 10,

    /// CCR
    ccr_enabled: bool = true,
};

pub const CompressResult = struct {
    compressed: []const u8,
    tokens_before: usize,
    tokens_after: usize,
    tokens_saved: usize,
    compression_ratio: f64,
    transforms_applied: []const []const u8,
    ccr_keys: []const []const u8,

    pub fn passthrough(allocator: std.mem.Allocator, input: []const u8) !CompressResult {
        return CompressResult{
            .compressed = try allocator.dupe(u8, input),
            .tokens_before = 0,
            .tokens_after = 0,
            .tokens_saved = 0,
            .compression_ratio = 1.0,
            .transforms_applied = try allocator.dupe([]const u8, &[_][]const u8{}),
            .ccr_keys = try allocator.dupe([]const u8, &[_][]const u8{}),
        };
    }
};

/// Top-level compress function. Detects content type and routes to the correct compressor.
pub fn compress(allocator: std.mem.Allocator, input: []const u8, config: CompressConfig) !CompressResult {
    if (input.len == 0) return CompressionError.EmptyInput;

    const content_router = @import("content_router.zig");
    var router = content_router.ContentRouter.init(config);
    return router.compress(allocator, input, config);
}

/// Convenience: compress JSON arrays specifically.
pub fn compressJson(allocator: std.mem.Allocator, json_text: []const u8, config: CompressConfig) !CompressResult {
    if (json_text.len == 0) return CompressionError.EmptyInput;

    const sc = @import("smart_crusher/main.zig");
    var crusher = sc.SmartCrusher.init(.{});
    return crusher.crushArray(allocator, json_text, config);
}

/// Convenience: compress log output specifically.
pub fn compressLogs(allocator: std.mem.Allocator, log_text: []const u8, config: CompressConfig) !CompressResult {
    if (log_text.len == 0) return CompressionError.EmptyInput;

    const lc = @import("log_compressor.zig");
    return lc.compress(allocator, log_text, config);
}

/// Convenience: compress search results specifically.
pub fn compressSearch(allocator: std.mem.Allocator, search_text: []const u8, config: CompressConfig) !CompressResult {
    if (search_text.len == 0) return CompressionError.EmptyInput;

    const sc = @import("search_compressor.zig");
    return sc.compress(allocator, search_text, config);
}

/// Convenience: compress diffs specifically.
pub fn compressDiff(allocator: std.mem.Allocator, diff_text: []const u8, config: CompressConfig) !CompressResult {
    if (diff_text.len == 0) return CompressionError.EmptyInput;

    const dc = @import("diff_compressor.zig");
    return dc.compress(allocator, diff_text, config);
}

/// Retrieve original content from the CCR store.
pub fn ccrRetrieve(allocator: std.mem.Allocator, key: []const u8) !?[]const u8 {
    const ccr_mod = @import("ccr/main.zig");
    var store = ccr_mod.CcrStore.init(allocator);
    defer store.deinit();
    return store.retrieve(key);
}

pub fn main() !void {
    // Read from stdin
    const stdin_fd = std.posix.STDIN_FILENO;
    var buf: [1024 * 1024]u8 = undefined;
    const n = std.posix.read(stdin_fd, &buf) catch 0;
    const content = buf[0..n];

    const config = CompressConfig{};
    const result = compress(std.heap.page_allocator, content, config) catch |err| {
        std.debug.print("Error: {}\n", .{err});
        std.process.exit(1);
    };

    std.debug.print("{s}\n\n--- Stats ---\nTokens before: {d}\nTokens after:  {d}\nTokens saved: {d}\nRatio: {d:.2}%\n", .{
        result.compressed,
        result.tokens_before,
        result.tokens_after,
        result.tokens_saved,
        result.compression_ratio * 100,
    });
}