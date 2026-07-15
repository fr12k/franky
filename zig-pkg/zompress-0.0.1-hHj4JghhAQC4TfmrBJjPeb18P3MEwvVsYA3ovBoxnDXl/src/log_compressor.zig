const std = @import("std");
const CompressConfig = @import("main.zig").CompressConfig;
const CompressResult = @import("main.zig").CompressResult;

pub const LogFormat = enum {
    pytest, npm, cargo, jest, make, generic,
};

pub const LogLevel = enum {
    err, fail, warn, info, debug, trace, unknown,
};

pub const LogLine = struct {
    line_number: usize,
    content: []const u8,
    level: LogLevel,
    is_stack_trace: bool,
    is_summary: bool,
    score: f64,
};

pub const LogCompressorConfig = struct {
    max_errors: usize = 10,
    max_fails: usize = 5,
    max_warnings: usize = 5,
    max_lines: usize = 200,
    enable_ccr: bool = true,
    min_lines_for_ccr: usize = 500,
    stack_trace_context: usize = 3,
    dedup_similar_warnings: bool = true,
};

pub fn compress(allocator: std.mem.Allocator, log_text: []const u8, _: CompressConfig) !CompressResult {
    // 1. Parse lines with level detection
    const lines = try parseLogLines(allocator, log_text);
    defer {
        for (lines) |l| allocator.free(l.content);
        allocator.free(lines);
    }

    if (lines.len == 0) return CompressResult.passthrough(allocator, log_text);

    // 2. Score each line
    const scored = try scoreLines(allocator, lines);
    defer allocator.free(scored);

    // 3. Select lines to keep
    var kept: std.ArrayList(usize) = .empty;
    defer kept.deinit(allocator);

    // Always keep ERROR/FAIL lines
    for (scored, 0..) |score, i| {
        if (score >= 1.0) {
            try kept.append(allocator, i);
        }
    }

    // Keep context around errors
    var kept_set = std.AutoHashMap(usize, void).init(allocator);
    defer kept_set.deinit();
    for (kept.items) |idx| try kept_set.put(idx, {});
    for (scored, 0..) |_, i| {
        if (kept_set.contains(i)) continue;
        // Check if within context window of an error
        var in_context = false;
        for (kept.items) |err_idx| {
            const dist = if (err_idx > i) err_idx - i else i - err_idx;
            if (dist <= 3) {
                in_context = true;
                break;
            }
        }
        if (in_context) {
            try kept.append(allocator, i);
            try kept_set.put(i, {});
        }
    }

    // Keep summary lines
    for (scored, 0..) |score, i| {
        if (kept_set.contains(i)) continue;
        if (score >= 0.6 and lines[i].is_summary) {
            try kept.append(allocator, i);
            try kept_set.put(i, {});
        }
    }

    // Fill remaining budget with highest-scored lines
    const budget = @min(lines.len, @as(usize, 200));
    while (kept.items.len < budget) {
        var best_idx: ?usize = null;
        var best_score: f64 = -1;
        for (scored, 0..) |score, i| {
            if (kept_set.contains(i)) continue;
            if (score > best_score) {
                best_score = score;
                best_idx = i;
            }
        }
        if (best_idx) |idx| {
            try kept.append(allocator, idx);
            try kept_set.put(idx, {});
        } else break;
    }

    // Sort by line number
    std.mem.sort(usize, kept.items, {}, comptime std.sort.asc(usize));

    // Build output
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    for (kept.items) |idx| {
        if (out.items.len > 0) try out.append(allocator, '\n');
        try out.appendSlice(allocator, lines[idx].content);
    }

    const compressed = try allocator.dupe(u8, out.items);

    return CompressResult{
        .compressed = compressed,
        .tokens_before = log_text.len / 4,
        .tokens_after = compressed.len / 4,
        .tokens_saved = (log_text.len - compressed.len) / 4,
        .compression_ratio = @as(f64, @floatFromInt(compressed.len)) / @as(f64, @floatFromInt(log_text.len)),
        .transforms_applied = try allocator.dupe([]const u8, &[_][]const u8{"log_compressor"}),
        .ccr_keys = try allocator.dupe([]const u8, &[_][]const u8{}),
    };
}

fn parseLogLines(allocator: std.mem.Allocator, text: []const u8) ![]LogLine {
    var lines: std.ArrayList(LogLine) = .empty;
    errdefer lines.deinit(allocator);
    var iter = std.mem.splitScalar(u8, text, '\n');
    var line_num: usize = 0;
    while (iter.next()) |content| {
        const duped = try allocator.dupe(u8, content);
        const level = detectLogLevel(content);
        const is_stack = isStackTraceLine(content);
        const is_summary = isSummaryLine(content);
        const score: f64 = switch (level) {
            .err => @as(f64, 1.0),
            .fail => @as(f64, 1.0),
            .warn => @as(f64, 0.6),
            .info => @as(f64, 0.1),
            .debug => @as(f64, 0.1),
            .trace => @as(f64, 0.1),
            .unknown => @as(f64, 0.0),
        };
        try lines.append(allocator, .{
            .line_number = line_num,
            .content = duped,
            .level = level,
            .is_stack_trace = is_stack,
            .is_summary = is_summary,
            .score = if (is_stack) @max(score, 0.8) else score,
        });
        line_num += 1;
    }
    return lines.toOwnedSlice(allocator);
}

fn scoreLines(allocator: std.mem.Allocator, lines: []const LogLine) ![]f64 {
    var scores = try allocator.alloc(f64, lines.len);
    for (lines, 0..) |line, i| {
        scores[i] = line.score;
    }
    return scores;
}

fn detectLogLevel(line: []const u8) LogLevel {
    var lower_buf: [4096]u8 = undefined;
    if (line.len > lower_buf.len) return .unknown;
    const lower = std.ascii.lowerString(&lower_buf, line);
    if (std.mem.indexOf(u8, lower, "error") != null or 
        std.mem.indexOf(u8, lower, "exception") != null or
        std.mem.indexOf(u8, lower, "traceback") != null) return .err;
    if (std.mem.indexOf(u8, lower, "failed") != null or
        std.mem.indexOf(u8, lower, "fail ") != null) return .fail;
    if (std.mem.indexOf(u8, lower, "warning") != null or
        std.mem.indexOf(u8, lower, "warn ") != null) return .warn;
    if (std.mem.indexOf(u8, lower, "info") != null) return .info;
    if (std.mem.indexOf(u8, lower, "debug") != null) return .debug;
    if (std.mem.indexOf(u8, lower, "trace") != null) return .trace;
    return .unknown;
}

fn isStackTraceLine(line: []const u8) bool {
    // Don't trim — leading whitespace is part of the stack trace pattern
    // Python: "  File \"path\", line N, in func"
    if (std.mem.startsWith(u8, line, "  File \"")) return true;
    // JS: "    at ..."
    if (std.mem.startsWith(u8, line, "    at ")) return true;
    // Java: "    at com.example..."
    if (std.mem.startsWith(u8, line, "    at ")) return true;
    // Zig: "    at /path/file.zig:line:col"
    if (line.len > 4 and line[0] == ' ' and line[1] == ' ' and line[2] == ' ' and line[3] == ' ') {
        if (std.mem.indexOf(u8, line, " at ") != null) return true;
    }
    return false;
}

fn isSummaryLine(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (std.mem.indexOf(u8, trimmed, "failed") != null and std.mem.indexOf(u8, trimmed, "passed") != null) return true;
    if (std.mem.indexOf(u8, trimmed, "tests ") != null and std.mem.indexOf(u8, trimmed, "failed") != null) return true;
    if (std.mem.indexOf(u8, trimmed, "error:") != null and std.mem.indexOf(u8, trimmed, "aborting") != null) return true;
    return false;
}

test "detect log level" {
    try std.testing.expectEqual(LogLevel.err, detectLogLevel("ERROR: something failed"));
    try std.testing.expectEqual(LogLevel.warn, detectLogLevel("WARNING: deprecated"));
    try std.testing.expectEqual(LogLevel.info, detectLogLevel("INFO: starting process"));
}

test "detect stack trace" {
    try std.testing.expect(isStackTraceLine("  File \"path\", line 42, in func"));
    try std.testing.expect(isStackTraceLine("    at Object.<anonymous> (path:42:5)"));
}

test "compress pytest output preserves errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const input =
        \\============================= test session starts ==============================
        \\collecting ... collected 42 items
        \\
        \\test_foo.py::test_pass PASSED
        \\test_bar.py::test_fail FAILED
        \\
        \\============================= FAILURES ==============================
        \\ERROR: test_bar.py::test_fail - AssertionError: expected 42, got 0
        \\Traceback (most recent call last):
        \\  File "test_bar.py", line 42, in test_fail
        \\    assert result == 42
        \\AssertionError
        \\
        \\============================= short summary ==============================
        \\1 failed, 1 passed in 0.42s
    ;
    const config = @import("main.zig").CompressConfig{};
    const result = try compress(a, input, config);
    try std.testing.expect(std.mem.indexOf(u8, result.compressed, "FAILED") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.compressed, "AssertionError") != null);
    try std.testing.expect(result.transforms_applied.len > 0);
}

test "compress empty log passthrough" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = @import("main.zig").CompressConfig{};
    const result = try compress(a, "", config);
    try std.testing.expectEqualStrings("", result.compressed);
}

test "isSummaryLine detection" {
    try std.testing.expect(isSummaryLine("6 failed, 42 passed in 0.5s"));
    try std.testing.expect(isSummaryLine("5 tests failed, 10 passed"));
    try std.testing.expect(!isSummaryLine("just a regular line"));
}

test "detect cargo error level" {
    try std.testing.expectEqual(LogLevel.err, detectLogLevel("error[E0425]: cannot find value `foo`"));
    try std.testing.expectEqual(LogLevel.warn, detectLogLevel("warning: unused variable `x`"));
    try std.testing.expectEqual(LogLevel.info, detectLogLevel("info: this is informational"));
    try std.testing.expectEqual(LogLevel.unknown, detectLogLevel("just some output"));
}

test "stack trace detection for JS" {
    try std.testing.expect(isStackTraceLine("    at Object.<anonymous> (path:42:5)"));
    try std.testing.expect(!isStackTraceLine("just a normal line of text"));
}
