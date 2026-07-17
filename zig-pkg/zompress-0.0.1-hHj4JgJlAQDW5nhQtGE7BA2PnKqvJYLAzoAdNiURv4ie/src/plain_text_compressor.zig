const std = @import("std");
const CompressConfig = @import("main.zig").CompressConfig;
const CompressResult = @import("main.zig").CompressResult;

/// Safe lossy compression for generic plain text (bash output, file contents, etc.).
///
/// Transformations (all safe because originals are stored in CCR):
///   - Collapse 3+ consecutive blank lines into 2
///   - Truncate lines longer than `max_line_len` chars
///   - Remove trailing whitespace
///   - Deduplicate consecutive identical lines
///   - Keep first N and last N lines, summarising the middle
///
/// The compressor is conservative — it only kicks in for text ≥ 10 lines and
/// targets a minimum compression ratio of 0.5 (50% reduction).
pub fn compress(allocator: std.mem.Allocator, text: []const u8, config: CompressConfig) !CompressResult {
    _ = config;

    // Use an arena for all intermediate allocations — simplifies ownership
    // and avoids double-free / leak issues with shared content pointers.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 1. Parse into lines
    var lines = std.ArrayList(Line).empty;
    var iter = std.mem.splitScalar(u8, text, '\n');
    while (iter.next()) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t\r");
        const duped = try a.dupe(u8, trimmed);
        try lines.append(a, .{ .content = duped, .is_blank = trimmed.len == 0 });
    }

    if (lines.items.len < 10) return CompressResult.passthrough(allocator, text);

    // 2. Collapse repeated blank lines (3+ → 2)
    var collapsed = std.ArrayList(Line).empty;
    var blank_run: usize = 0;
    for (lines.items) |line| {
        if (line.is_blank) {
            blank_run += 1;
            if (blank_run > 2) continue; // skip excess blanks
            try collapsed.append(a, line);
        } else {
            blank_run = 0;
            try collapsed.append(a, line);
        }
    }

    // 3. Deduplicate consecutive identical lines
    var deduped = std.ArrayList(Line).empty;
    for (collapsed.items, 0..) |line, i| {
        if (i > 0 and !line.is_blank and std.mem.eql(u8, line.content, collapsed.items[i - 1].content)) {
            continue; // skip duplicate
        }
        try deduped.append(a, line);
    }

    // 4. Truncate very long lines (allocates new strings in the arena)
    const max_line_len: usize = 500;
    for (deduped.items) |*line| {
        if (line.content.len > max_line_len) {
            const truncated = try std.fmt.allocPrint(a, "{s}... [{d} more chars]", .{
                line.content[0..max_line_len],
                line.content.len - max_line_len,
            });
            line.content = truncated;
        }
    }

    // 5. Keep first N, last N, summarise middle
    const keep_first: usize = 20;
    const keep_last: usize = 20;
    var out = std.ArrayList(u8).empty;

    if (deduped.items.len <= keep_first + keep_last + 5) {
        // Small enough — emit all
        for (deduped.items, 0..) |line, i| {
            if (i > 0) try out.append(a, '\n');
            try out.appendSlice(a, line.content);
        }
    } else {
        // Emit first N
        for (deduped.items[0..keep_first], 0..) |line, i| {
            if (i > 0) try out.append(a, '\n');
            try out.appendSlice(a, line.content);
        }

        // Summarise middle
        const omitted = deduped.items.len - keep_first - keep_last;
        try out.appendSlice(a, try std.fmt.allocPrint(a, "\n[... {d} lines omitted ...]\n", .{omitted}));

        // Emit last N
        for (deduped.items[deduped.items.len - keep_last ..], 0..) |line, i| {
            if (i > 0) try out.append(a, '\n');
            try out.appendSlice(a, line.content);
        }
    }

    // Copy the final result into the caller's allocator (arena will be freed)
    const compressed = try allocator.dupe(u8, out.items);
    const tokens_before = text.len / 4;
    const tokens_after = compressed.len / 4;

    return CompressResult{
        .compressed = compressed,
        .tokens_before = tokens_before,
        .tokens_after = tokens_after,
        .tokens_saved = tokens_before -| tokens_after,
        .compression_ratio = @as(f64, @floatFromInt(compressed.len)) / @as(f64, @floatFromInt(text.len)),
        .transforms_applied = try allocator.dupe([]const u8, &[_][]const u8{"plain_text_compressor"}),
        .ccr_keys = try allocator.dupe([]const u8, &[_][]const u8{}),
    };
}

const Line = struct {
    content: []const u8,
    is_blank: bool,
};

test "compress short text passes through" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = CompressConfig{};

    const input = "hello\nworld";
    const result = try compress(a, input, config);
    try std.testing.expectEqualStrings(input, result.compressed);
}

test "compress collapses repeated blank lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = CompressConfig{};

    // Build input with 10+ lines to trigger compression:
    // line1, then 10 blank lines, then line2 = 12 lines total
    var input = std.ArrayList(u8).empty;
    try input.appendSlice(a, "line1");
    var i: usize = 0;
    while (i < 10) : (i += 1) try input.appendSlice(a, "\n");
    try input.appendSlice(a, "line2");

    const result = try compress(a, input.items, config);
    try std.testing.expect(std.mem.indexOf(u8, result.compressed, "line1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.compressed, "line2") != null);
    // Should have at most 2 consecutive blank lines (4+ newlines = 3+ blank lines)
    try std.testing.expect(std.mem.count(u8, result.compressed, "\n\n\n\n") == 0);
}

test "compress truncates long lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = CompressConfig{};

    // 600-char line + 9 short lines = 10 lines total (triggers compression)
    var buf = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < 600) : (i += 1) try buf.append(a, 'x');
    try buf.append(a, '\n');
    i = 0;
    while (i < 9) : (i += 1) {
        const line = try std.fmt.allocPrint(a, "short line {d}", .{i});
        try buf.appendSlice(a, line);
        if (i < 8) try buf.append(a, '\n');
    }

    const result = try compress(a, buf.items, config);
    try std.testing.expect(std.mem.indexOf(u8, result.compressed, "...") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.compressed, "short") != null);
}

test "compress deduplicates consecutive identical lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = CompressConfig{};

    // 12 lines: a, b, b, b, c, then 7 more unique lines to reach 10+ lines
    var input = std.ArrayList(u8).empty;
    try input.appendSlice(a, "a\nb\nb\nb\nc\nd\ne\nf\ng\nh\ni\nj");

    const result = try compress(a, input.items, config);
    // "b" should appear only once in the output (deduped)
    try std.testing.expect(std.mem.count(u8, result.compressed, "\nb\n") <= 1);
}

test "compress keeps first and last N lines for large input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = CompressConfig{};

    var input = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        if (i > 0) try input.append(a, '\n');
        const line = try std.fmt.allocPrint(a, "line {d}", .{i});
        try input.appendSlice(a, line);
    }

    const result = try compress(a, input.items, config);
    try std.testing.expect(std.mem.indexOf(u8, result.compressed, "line 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.compressed, "line 99") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.compressed, "lines omitted") != null);
}