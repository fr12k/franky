const std = @import("std");
const CompressConfig = @import("main.zig").CompressConfig;
const CompressResult = @import("main.zig").CompressResult;

pub fn compress(allocator: std.mem.Allocator, diff_text: []const u8, _: CompressConfig) !CompressResult {
    // 1. Parse unified diff format into files + hunks
    // Check if it looks like a diff
    if (!isDiff(diff_text)) return CompressResult.passthrough(allocator, diff_text);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var line_iter = std.mem.splitScalar(u8, diff_text, '\n');
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(allocator);

    while (line_iter.next()) |line| {
        try lines.append(allocator, line);
    }

    if (lines.items.len == 0) return CompressResult.passthrough(allocator, diff_text);

    // Simple state machine: keep all metadata, but trim context lines
    var in_hunk = false;
    var context_count: usize = 0;
    var kept_lines: usize = 0;
    const max_lines = @min(lines.items.len, @as(usize, 200));

    for (lines.items) |line| {
        if (kept_lines >= max_lines) break;

        // Always keep diff metadata
        if (std.mem.startsWith(u8, line, "diff --git") or
            std.mem.startsWith(u8, line, "index ") or
            std.mem.startsWith(u8, line, "--- ") or
            std.mem.startsWith(u8, line, "+++ "))
        {
            try out.appendSlice(allocator, line);
            try out.append(allocator, '\n');
            kept_lines += 1;
            in_hunk = false;
            context_count = 0;
            continue;
        }

        // Hunk header
        if (std.mem.startsWith(u8, line, "@@")) {
            try out.appendSlice(allocator, line);
            try out.append(allocator, '\n');
            kept_lines += 1;
            in_hunk = true;
            context_count = 0;
            continue;
        }

        if (!in_hunk) {
            try out.appendSlice(allocator, line);
            try out.append(allocator, '\n');
            kept_lines += 1;
            continue;
        }

        // Inside hunk: additions, deletions, context
        if (line.len > 0) {
            const first = line[0];
            if (first == '+') {
                // Always keep additions
                try out.appendSlice(allocator, line);
                try out.append(allocator, '\n');
                kept_lines += 1;
                context_count = 0;
            } else if (first == '-') {
                // Always keep deletions
                try out.appendSlice(allocator, line);
                try out.append(allocator, '\n');
                kept_lines += 1;
                context_count = 0;
            } else if (first == ' ') {
                // Context: keep limited lines around changes
                if (context_count < 2) {
                    try out.appendSlice(allocator, line);
                    try out.append(allocator, '\n');
                    kept_lines += 1;
                }
                context_count += 1;
            } else {
                // Other (empty line in hunk, etc.)
                try out.appendSlice(allocator, line);
                try out.append(allocator, '\n');
                kept_lines += 1;
                context_count = 0;
            }
        } else {
            try out.append(allocator, '\n');
            kept_lines += 1;
        }
    }

    const compressed = try allocator.dupe(u8, out.items);
    return CompressResult{
        .compressed = compressed,
        .tokens_before = diff_text.len / 4,
        .tokens_after = compressed.len / 4,
        .tokens_saved = (diff_text.len -| compressed.len) / 4,
        .compression_ratio = @as(f64, @floatFromInt(compressed.len)) / @as(f64, @floatFromInt(diff_text.len)),
        .transforms_applied = try allocator.dupe([]const u8, &[_][]const u8{"diff_compressor"}),
        .ccr_keys = try allocator.dupe([]const u8, &[_][]const u8{}),
    };
}

fn isDiff(text: []const u8) bool {
    return std.mem.indexOf(u8, text, "diff --git") != null;
}

test "detect diff" {
    try std.testing.expect(isDiff("diff --git a/src/main.zig b/src/main.zig"));
    try std.testing.expect(!isDiff("just some text"));
}

test "diff compression preserves structure" {
    const input =
        \\diff --git a/src/main.zig b/src/main.zig
        \\index abc..def 100644
        \\--- a/src/main.zig
        \\+++ b/src/main.zig
        \\@@ -1,5 +1,6 @@
        \\ line1
        \\ line2
        \\+added line
        \\ line3
        \\ line4
        \\ line5
        \\+another addition
        ;
    const config = CompressConfig{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try compress(arena.allocator(), input, config);
    try std.testing.expect(std.mem.indexOf(u8, result.compressed, "added line") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.compressed, "another addition") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.compressed, "diff --git") != null);
}

test "diff compression preserves additions and deletions" {
    const input =
        \\diff --git a/src/main.zig b/src/main.zig
        \\index abc..def 100644
        \\--- a/src/main.zig
        \\+++ b/src/main.zig
        \\@@ -1,7 +1,8 @@
        \\ line1
        \\ line2
        \\ line3
        \\+added line
        \\ line4
        \\ line5
        \\-removed line
        \\ line6
        \\ line7
        ;
    const config = @import("main.zig").CompressConfig{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try compress(arena.allocator(), input, config);
    try std.testing.expect(std.mem.indexOf(u8, result.compressed, "added line") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.compressed, "removed line") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.compressed, "diff --git") != null);
    try std.testing.expect(result.compressed.len <= input.len);
}

test "compress passthrough for non-diff" {
    const input = "just some regular text without any diff markers";
    const config = @import("main.zig").CompressConfig{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try compress(arena.allocator(), input, config);
    try std.testing.expectEqualStrings(input, result.compressed);
}
