//! Compression integration module.
//!
//! Wraps the zompress compression library and integrates it with franky's
//! tool result pipeline. Provides:
//!
//! - `compressToolResult()` — compress a tool result's text content blocks
//! - `CompressionConfig` — configuration struct with sensible defaults
//! - `CcrSessionStore` — re-exported from session/ccr_store.zig
//!
//! The API is **infallible** — if zompress returns an error, the original
//! content is passed through unchanged and a warning is logged. This ensures
//! the agent loop never crashes due to compression failure.

const std = @import("std");
const zompress = @import("zompress");
const at = @import("../agent/types.zig");
const ai = @import("../ai/types.zig");
const ccr_store = @import("./session/ccr_store.zig");

pub const CcrSessionStore = ccr_store.CcrSessionStore;

/// Compression statistics tracked per-session for the status line.
/// Updated by `compressToolResult` when a non-null pointer is provided.
///
/// Thread safety: the agent loop writes from a single thread (parallel
/// tool paths join before stats access). The HTTP `/usage` handler reads
/// from a different thread — use the mutex for atomic snapshot access.
pub const CompressionStats = struct {
    /// Total bytes of tool output text before compression (all text blocks).
    bytes_before: u64 = 0,
    /// Total bytes of tool output text after compression (compressed blocks only).
    bytes_after: u64 = 0,
    /// Number of text blocks that were successfully compressed.
    items_compressed: u64 = 0,
    /// Number of text blocks that passed through (too small, incompressible, etc).
    /// Does NOT include failed blocks (those are in items_failed).
    items_passthrough: u64 = 0,
    /// Number of text blocks that failed compression (fell back to passthrough).
    items_failed: u64 = 0,

    /// Mutex for thread-safe reads from the HTTP handler.
    mutex: std.Io.Mutex = .init,

    /// Bytes saved (before - after). Saturating subtraction.
    pub fn bytesSaved(self: *const CompressionStats) u64 {
        return if (self.bytes_before > self.bytes_after)
            self.bytes_before - self.bytes_after
        else
            0;
    }

    /// Compression ratio as a float 0..1 (1 = 100% saved).
    /// Returns 0 when bytes_before is 0 (no data processed).
    pub fn ratio(self: *const CompressionStats) f64 {
        if (self.bytes_before == 0) return 0;
        return @as(f64, @floatFromInt(self.bytesSaved())) /
            @as(f64, @floatFromInt(self.bytes_before));
    }

    /// Take a snapshot of the stats under the mutex for safe cross-thread reads.
    pub fn snapshot(self: *CompressionStats, io: std.Io) CompressionStats {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return .{
            .bytes_before = self.bytes_before,
            .bytes_after = self.bytes_after,
            .items_compressed = self.items_compressed,
            .items_passthrough = self.items_passthrough,
            .items_failed = self.items_failed,
        };
    }

    /// Lock the mutex for a batch of writes.
    pub fn lock(self: *CompressionStats, io: std.Io) void {
        self.mutex.lockUncancelable(io);
    }

    /// Unlock the mutex after a batch of writes.
    pub fn unlock(self: *CompressionStats, io: std.Io) void {
        self.mutex.unlock(io);
    }
};

/// Compression configuration with sensible defaults.
/// All per-compressor toggles default to `true` so that enabling
/// compression activates all available compressors.
pub const CompressionConfig = struct {
    /// Master switch — compression is opt-in.
    enabled: bool = false,
    /// Skip outputs smaller than this (bytes). Avoids overhead on tiny results.
    min_bytes_to_compress: usize = 1024,
    /// Minimum compression ratio to accept (compressed/original).
    /// If compression doesn't reduce size by at least this factor,
    /// the original is passed through unchanged.
    min_compression_ratio: f64 = 0.9,
    /// Enable SmartCrusher for JSON arrays.
    smart_crusher_enabled: bool = true,
    /// Enable LogCompressor for build/test output.
    log_compressor_enabled: bool = true,
    /// Enable SearchCompressor for grep/ripgrep results.
    search_compressor_enabled: bool = true,
    /// Enable DiffCompressor for git diffs.
    diff_compressor_enabled: bool = true,
    /// Enable CodeCompressor for source code.
    code_compressor_enabled: bool = true,
    /// Enable PlainTextCompressor for generic text (bash output, file contents, etc.).
    plain_text_compressor_enabled: bool = true,
    /// Enable Compress-Cache-Retrieve (stores originals for retrieval).
    ccr_enabled: bool = true,
    // Per-compressor overrides
    max_items_after_crush: usize = 15,
    log_max_errors: usize = 10,
    search_max_matches_per_file: usize = 5,
    diff_max_context_lines: usize = 2,
};

/// Compress a tool result's text content blocks.
///
/// Returns a NEW ToolResult with compressed text + CCR markers.
/// The caller MUST free the original ToolResult after calling this.
///
/// Non-text content blocks (images, binary) are passed through unchanged.
/// On compression failure, returns a passthrough copy (never throws).
pub fn compressToolResult(
    allocator: std.mem.Allocator,
    result: *const at.ToolResult,
    config: CompressionConfig,
    maybe_ccr_store: ?*CcrSessionStore,
    maybe_stats: ?*CompressionStats,
) at.ToolResult {
    // Build the zompress config from our CompressionConfig
    const zompress_config = zompress.CompressConfig{
        .smart_crusher_enabled = config.smart_crusher_enabled,
        .log_compressor_enabled = config.log_compressor_enabled,
        .search_compressor_enabled = config.search_compressor_enabled,
        .diff_compressor_enabled = config.diff_compressor_enabled,
        .plain_text_compressor_enabled = config.plain_text_compressor_enabled,
        .ccr_enabled = config.ccr_enabled,
        .max_items_after_crush = config.max_items_after_crush,
        .log_max_errors = config.log_max_errors,
        .search_max_matches_per_file = config.search_max_matches_per_file,
        .diff_max_context_lines = config.diff_max_context_lines,
    };

    // Compress each text content block
    var new_content: std.ArrayList(ai.ContentBlock) = .empty;
    errdefer {
        for (new_content.items) |*cb| cb.deinit(allocator);
        new_content.deinit(allocator);
    }

    for (result.content) |block| {
        switch (block) {
            .text => |text_block| {
                const input = text_block.text;
                if (input.len < config.min_bytes_to_compress) {
                    // Too small to compress — pass through
                    if (maybe_stats) |s| {
                        s.bytes_before += input.len;
                        s.bytes_after += input.len;
                        s.items_passthrough += 1;
                    }
                    const duped = block.dupe(allocator) catch continue;
                    new_content.append(allocator, duped) catch continue;
                    continue;
                }

                // Try to compress with zompress
                const compress_result = zompress.compress(allocator, input, zompress_config) catch |err| {
                    // Compression failed — log warning.
                    // Still store original in CCR so the LLM can retrieve it.
                    if (maybe_stats) |s| {
                        s.bytes_before += input.len;
                        s.bytes_after += input.len;
                        s.items_failed += 1;
                    }
                    std.log.warn("zompress compression failed: {}", .{err});
                    var fallback_marker: ?[]const u8 = null;
                    if (config.ccr_enabled) {
                        if (maybe_ccr_store) |store| {
                            if (store.store(input)) |k| {
                                const original_lines = countLines(input);
                                fallback_marker = CcrSessionStore.formatMarker(k, original_lines, allocator) catch null;
                            } else |_| {}
                        }
                    }
                    if (fallback_marker) |marker| {
                        const combined = std.fmt.allocPrint(allocator, "{s}\n{s}", .{ input, marker }) catch {
                            const duped = block.dupe(allocator) catch continue;
                            new_content.append(allocator, duped) catch continue;
                            continue;
                        };
                        new_content.append(allocator, .{ .text = .{
                            .text = combined,
                            .text_signature = null,
                        } }) catch {
                            allocator.free(combined);
                            continue;
                        };
                    } else {
                        const duped = block.dupe(allocator) catch continue;
                        new_content.append(allocator, duped) catch continue;
                    }
                    continue;
                };

                // Minimum-ratio gate: if compression didn't reduce size
                // enough, pass through the original unchanged.
                if (@as(f64, @floatFromInt(compress_result.compressed.len)) >=
                    @as(f64, @floatFromInt(input.len)) * config.min_compression_ratio)
                {
                    if (maybe_stats) |s| {
                        s.bytes_before += input.len;
                        s.bytes_after += input.len;
                        s.items_passthrough += 1;
                    }
                    allocator.free(compress_result.compressed);
                    allocator.free(compress_result.transforms_applied);
                    allocator.free(compress_result.ccr_keys);
                    const duped = block.dupe(allocator) catch continue;
                    new_content.append(allocator, duped) catch continue;
                    continue;
                }

                // Store original in CCR if enabled
                var ccr_marker: ?[]const u8 = null;
                if (config.ccr_enabled) {
                    if (maybe_ccr_store) |store| {
                        if (store.store(input)) |k| {
                            const original_lines = countLines(input);
                            ccr_marker = CcrSessionStore.formatMarker(k, original_lines, allocator) catch null;
                        } else |_| {
                            ccr_marker = null;
                        }
                    }
                }

                // Build the compressed text with optional CCR marker
                var compressed_text = compress_result.compressed;
                if (maybe_stats) |s| {
                    s.bytes_before += input.len;
                    s.bytes_after += compressed_text.len;
                    s.items_compressed += 1;
                }
                if (ccr_marker) |marker| {
                    // Append marker to compressed output
                    const combined = std.fmt.allocPrint(allocator, "{s}\n{s}", .{ compressed_text, marker }) catch {
                        // If formatting fails, just use compressed text
                        new_content.append(allocator, .{ .text = .{
                            .text = compressed_text,
                            .text_signature = null,
                        } }) catch {
                            allocator.free(compressed_text);
                        };
                        continue;
                    };
                    allocator.free(compressed_text);
                    compressed_text = combined;
                }

                new_content.append(allocator, .{ .text = .{
                    .text = compressed_text,
                    .text_signature = null,
                } }) catch {
                    allocator.free(compressed_text);
                    continue;
                };

                // Free zompress result fields
                allocator.free(compress_result.transforms_applied);
                allocator.free(compress_result.ccr_keys);
            },
            else => {
                // Non-text blocks (images, etc.) — pass through unchanged
                const duped = block.dupe(allocator) catch continue;
                new_content.append(allocator, duped) catch continue;
            },
        }
    }

    const content_slice = new_content.toOwnedSlice(allocator) catch {
        // If we can't finalize, return a minimal passthrough
        return at.ToolResult{
            .content = allocator.dupe(ai.ContentBlock, result.content) catch
                @panic("OOM in compressToolResult fallback"),
            .is_error = result.is_error,
            .tool_code = if (result.tool_code) |tc| allocator.dupe(u8, tc) catch null else null,
            .terminate = result.terminate,
        };
    };

    return at.ToolResult{
        .content = content_slice,
        .is_error = result.is_error,
        .tool_code = if (result.tool_code) |tc| allocator.dupe(u8, tc) catch null else null,
        .terminate = result.terminate,
    };
}

/// Count newlines in a byte slice.
fn countLines(s: []const u8) usize {
    var count: usize = 0;
    for (s) |b| {
        if (b == '\n') count += 1;
    }
    return count;
}

test "compressToolResult passes through small content" {
    const allocator = std.testing.allocator;

    const content = try allocator.alloc(ai.ContentBlock, 1);
    content[0] = .{ .text = .{ .text = try allocator.dupe(u8, "small"), .text_signature = null } };
    var result = at.ToolResult{
        .content = content,
        .is_error = false,
        .tool_code = null,
        .terminate = false,
    };
    defer result.deinit(allocator);

    const config = CompressionConfig{
        .enabled = true,
        .min_bytes_to_compress = 100, // larger than "small"
    };

    var compressed = compressToolResult(allocator, &result, config, null, null);
    defer compressed.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), compressed.content.len);
    try std.testing.expectEqualStrings("small", compressed.content[0].text.text);
}

test "compressToolResult passes through non-text blocks" {
    const allocator = std.testing.allocator;

    const content = try allocator.alloc(ai.ContentBlock, 1);
    content[0] = .{ .image = .{ .data = try allocator.dupe(u8, ""), .mime_type = try allocator.dupe(u8, "image/png") } };
    var result = at.ToolResult{
        .content = content,
        .is_error = false,
        .tool_code = null,
        .terminate = false,
    };
    defer result.deinit(allocator);

    const config = CompressionConfig{
        .enabled = true,
        .min_bytes_to_compress = 1,
    };

    var compressed = compressToolResult(allocator, &result, config, null, null);
    defer compressed.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), compressed.content.len);
    try std.testing.expect(compressed.content[0] == .image);
}

test "compressToolResult is infallible on empty input" {
    const allocator = std.testing.allocator;

    const content = try allocator.alloc(ai.ContentBlock, 0);
    var result = at.ToolResult{
        .content = content,
        .is_error = false,
        .tool_code = null,
        .terminate = false,
    };
    defer result.deinit(allocator);

    const config = CompressionConfig{ .enabled = true };

    var compressed = compressToolResult(allocator, &result, config, null, null);
    defer compressed.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), compressed.content.len);
}

test "CompressionStats accumulates correctly" {
    var stats = CompressionStats{};

    // Simulate a compressed block
    stats.bytes_before += 1000;
    stats.bytes_after += 200;
    stats.items_compressed += 1;

    // Simulate a passthrough (content passes through unchanged)
    stats.bytes_before += 500;
    stats.bytes_after += 500; // passthrough: after == before
    stats.items_passthrough += 1;

    // Simulate a failure (mutually exclusive from passthrough)
    stats.bytes_before += 300;
    stats.bytes_after += 300; // failure: original passed through unchanged
    stats.items_failed += 1;

    try std.testing.expectEqual(@as(u64, 1800), stats.bytes_before);
    try std.testing.expectEqual(@as(u64, 1000), stats.bytes_after);
    try std.testing.expectEqual(@as(u64, 800), stats.bytesSaved()); // 1800 - 1000
    try std.testing.expect(stats.ratio() > 0.43 and stats.ratio() < 0.46);
    try std.testing.expectEqual(@as(u64, 1), stats.items_compressed);
    try std.testing.expectEqual(@as(u64, 1), stats.items_passthrough);
    try std.testing.expectEqual(@as(u64, 1), stats.items_failed);

    // Verify total = compressed + passthrough + failed
    try std.testing.expectEqual(@as(u64, 3), stats.items_compressed + stats.items_passthrough + stats.items_failed);
}
