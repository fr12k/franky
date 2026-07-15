const std = @import("std");
const CompressConfig = @import("main.zig").CompressConfig;
const CompressResult = @import("main.zig").CompressResult;

pub const SearchMatch = struct {
    file: []const u8,
    line_number: usize,
    content: []const u8,
    score: f64,
};

pub const FileMatches = struct {
    file: []const u8,
    matches: []SearchMatch,

    pub fn first(self: *const FileMatches) ?*const SearchMatch {
        if (self.matches.len > 0) return &self.matches[0];
        return null;
    }

    pub fn last(self: *const FileMatches) ?*const SearchMatch {
        if (self.matches.len > 0) return &self.matches[self.matches.len - 1];
        return null;
    }
};

pub fn compress(allocator: std.mem.Allocator, search_text: []const u8, _: CompressConfig) !CompressResult {
    var matches: std.ArrayList(SearchMatch) = .empty;
    defer matches.deinit(allocator);

    var line_iter = std.mem.splitScalar(u8, search_text, '\n');
    while (line_iter.next()) |line| {
        if (parseSearchLine(line)) |m| {
            try matches.append(allocator, m);
        }
    }

    if (matches.items.len == 0) return CompressResult.passthrough(allocator, search_text);

    var file_map = std.StringHashMap(std.ArrayList(SearchMatch)).init(allocator);
    defer {
        var iter = file_map.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        file_map.deinit();
    }

    for (matches.items) |m| {
        const result = try file_map.getOrPut(m.file);
        if (!result.found_existing) {
            result.value_ptr.* = .empty;
        }
        try result.value_ptr.*.append(allocator, m);
    }

    const FileScore = struct {
        file: []const u8,
        score: f64,
    };
    var file_scores: std.ArrayList(FileScore) = .empty;
    defer file_scores.deinit(allocator);

    var iter = file_map.iterator();
    while (iter.next()) |entry| {
        var total_score: f64 = 0;
        const arr = entry.value_ptr.*;
        for (arr.items) |m| {
            total_score += m.score;
        }
        try file_scores.append(allocator, .{ .file = entry.key_ptr.*, .score = total_score });
    }

    std.mem.sort(FileScore, file_scores.items, {}, struct {
        fn lessThan(_: void, a: FileScore, b: FileScore) bool {
            return a.score > b.score;
        }
    }.lessThan);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var files_kept: usize = 0;
    const max_files = @min(@as(usize, 15), file_scores.items.len);

    for (file_scores.items[0..max_files]) |fs| {
        if (files_kept > 0) try out.appendSlice(allocator, "\n");
        const arr = file_map.get(fs.file) orelse continue;
        const max_per_file = @min(@as(usize, 5), arr.items.len);

        try out.appendSlice(allocator, arr.items[0].file);
        try out.append(allocator, ':');
        const line_str = try std.fmt.allocPrint(allocator, "{d}", .{arr.items[0].line_number});
        defer allocator.free(line_str);
        try out.appendSlice(allocator, line_str);
        try out.append(allocator, ':');
        try out.appendSlice(allocator, arr.items[0].content);

        if (max_per_file > 1 and arr.items.len > 1) {
            const last_idx = arr.items.len - 1;
            if (last_idx != 0) {
                try out.append(allocator, '\n');
                try out.appendSlice(allocator, arr.items[last_idx].file);
                try out.append(allocator, ':');
                try out.appendSlice(allocator, try std.fmt.allocPrint(allocator, "{d}", .{arr.items[last_idx].line_number}));
                try out.append(allocator, ':');
                try out.appendSlice(allocator, arr.items[last_idx].content);
            }
        }
        if (arr.items.len > max_per_file) {
            try out.appendSlice(allocator, try std.fmt.allocPrint(allocator, "\n[... and {d} more matches in file]", .{arr.items.len - max_per_file}));
        }
        files_kept += 1;
    }

    const compressed = try allocator.dupe(u8, out.items);
    return CompressResult{
        .compressed = compressed,
        .tokens_before = search_text.len / 4,
        .tokens_after = compressed.len / 4,
        .tokens_saved = (search_text.len - compressed.len) / 4,
        .compression_ratio = @as(f64, @floatFromInt(compressed.len)) / @as(f64, @floatFromInt(search_text.len)),
        .transforms_applied = try allocator.dupe([]const u8, &[_][]const u8{"search_compressor"}),
        .ccr_keys = try allocator.dupe([]const u8, &[_][]const u8{}),
    };
}

pub fn parseSearchLine(line: []const u8) ?SearchMatch {
    if (line.len == 0) return null;
    var start: usize = 0;
    if (line.len >= 2 and std.ascii.isAlphabetic(line[0]) and line[1] == ':') {
        start = 2;
    }
    var i = start;
    while (i < line.len) : (i += 1) {
        const sep = line[i];
        if (sep == ':' or sep == '-') {
            if (i + 1 < line.len and std.ascii.isDigit(line[i + 1])) {
                var j = i + 1;
                while (j < line.len and std.ascii.isDigit(line[j])) {
                    j += 1;
                }
                if (j < line.len and (line[j] == ':' or line[j] == '-')) {
                    const num = std.fmt.parseInt(usize, line[i + 1 .. j], 10) catch continue;
                    const path = line[0..i];
                    const content = line[j + 1 ..];
                    return .{
                        .file = path,
                        .line_number = num,
                        .content = content,
                        .score = 0.5,
                    };
                }
            }
        }
    }
    return null;
}

test "parse grep line" {
    const m = parseSearchLine("src/main.zig:42:fn process():") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("src/main.zig", m.file);
    try std.testing.expectEqual(@as(usize, 42), m.line_number);
}

test "parse Windows path" {
    const m = parseSearchLine("C:\\Users\\foo\\bar.py:42:def process():") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("C:\\Users\\foo\\bar.py", m.file);
    try std.testing.expectEqual(@as(usize, 42), m.line_number);
}

test "compress search results preserves file structure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = CompressConfig{};
    const input =
        \\src/main.zig:42:fn process():
        \\src/main.zig:43:    var x: i32 = 0;
        \\src/main.zig:44:    return x;
        \\src/lib.zig:10:pub fn helper():
        \\src/lib.zig:11:    return 42;
    ;
    const result = try compress(a, input, config);
    try std.testing.expect(std.mem.indexOf(u8, result.compressed, "main.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.compressed, "lib.zig") != null);
    try std.testing.expect(result.compressed.len <= input.len);
}

test "compress empty search passthrough" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = CompressConfig{};
    const result = try compress(a, "", config);
    try std.testing.expectEqualStrings("", result.compressed);
}

test "parseSearchLine dash format" {
    const m = parseSearchLine("src/main.zig-42-fn process():") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("src/main.zig", m.file);
    try std.testing.expectEqual(@as(usize, 42), m.line_number);
    try std.testing.expectEqualStrings("fn process():", m.content);
}

test "parseSearchLine no false positive on regular text" {
    const result = parseSearchLine("The ratio is 42:1");
    try std.testing.expect(result == null);
}
