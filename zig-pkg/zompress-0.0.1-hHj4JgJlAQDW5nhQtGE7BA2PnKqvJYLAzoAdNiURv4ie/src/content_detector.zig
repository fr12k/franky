const std = @import("std");

/// Content types that the compressor can handle.
pub const ContentType = enum {
    json_array,
    json_object,
    source_code,
    search_results,
    build_output,
    git_diff,
    html,
    xml,
    csv,
    plain_text,
};

/// The result of content type detection.
pub const DetectionResult = struct {
    content_type: ContentType,
    confidence: f64,

    pub fn init(ct: ContentType, conf: f64) DetectionResult {
        return .{
            .content_type = ct,
            .confidence = conf,
        };
    }

    pub fn certain(ct: ContentType) DetectionResult {
        return .init(ct, 1.0);
    }

    pub fn guess(ct: ContentType) DetectionResult {
        return .init(ct, 0.6);
    }
};

/// Detect content type by scanning the first bytes and lines of content.
/// No regex dependency — uses hand-rolled scanners.
pub fn detect(content: []const u8) DetectionResult {
    if (content.len == 0) return DetectionResult.certain(.plain_text);

    // 1. Check first non-whitespace byte
    const first_nonws = firstNonWhitespaceByte(content);

    if (first_nonws) |b| {
        if (b == '[') {
            // Could be a JSON array — try to parse
            if (looksLikeJsonArray(content)) {
                return DetectionResult.certain(.json_array);
            }
        }
        if (b == '{') {
            // Could be a JSON object
            if (looksLikeJsonObject(content)) {
                return DetectionResult.guess(.json_object);
            }
        }
        if (b == '<') {
            if (looksLikeHtml(content)) {
                return DetectionResult.certain(.html);
            }
            if (looksLikeXml(content)) {
                return DetectionResult.certain(.xml);
            }
        }
    }

    // 2. Check line-by-line patterns (first 50 lines)
    const lines = firstNLines(content, 50);

    // Check for git diff first (most distinctive signature)
    if (startsWithLinePattern(lines, "diff --git")) {
        return DetectionResult.certain(.git_diff);
    }

    // Check for search results (grep/ripgrep format: file:line:content)
    if (looksLikeSearchResults(lines)) {
        return DetectionResult.certain(.search_results);
    }

    // Check for build/test output
    if (looksLikeBuildOutput(lines)) {
        return DetectionResult.certain(.build_output);
    }

    // Check for source code
    if (looksLikeSourceCode(lines)) {
        return DetectionResult.certain(.source_code);
    }

    // Check for CSV
    if (looksLikeCsv(lines)) {
        return DetectionResult.guess(.csv);
    }

    // 3. Fallback: plain text
    return DetectionResult.certain(.plain_text);
}

fn firstNonWhitespaceByte(content: []const u8) ?u8 {
    for (content) |b| {
        if (b != ' ' and b != '\t' and b != '\n' and b != '\r') return b;
    }
    return null;
}

fn looksLikeJsonArray(content: []const u8) bool {
    // Quick check: starts with [ and ends with ] after trimming
    var start: usize = 0;
    while (start < content.len and (content[start] == ' ' or content[start] == '\t' or content[start] == '\n' or content[start] == '\r')) {
        start += 1;
    }
    if (start >= content.len or content[start] != '[') return false;

    var end = content.len;
    while (end > start) {
        end -= 1;
        const b = content[end];
        if (b != ' ' and b != '\t' and b != '\n' and b != '\r') break;
    }
    if (content[end] != ']') return false;

    // Try to parse with std.json
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, content, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value == .array) {
        return true;
    }
    return false;
}

fn looksLikeJsonObject(content: []const u8) bool {
    var start: usize = 0;
    while (start < content.len and (content[start] == ' ' or content[start] == '\t' or content[start] == '\n' or content[start] == '\r')) {
        start += 1;
    }
    if (start >= content.len or content[start] != '{') return false;

    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, content, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value == .object) return true;
    return false;
}

fn looksLikeHtml(content: []const u8) bool {
    const trimmed = std.mem.trim(u8, content, " \t\n\r");
    // Check for <html>, <!DOCTYPE html>, or common HTML tags
    if (std.ascii.findIgnoreCase(trimmed, "<html") != null) return true;
    if (std.ascii.findIgnoreCase(trimmed, "<!doctype html") != null) return true;
    if (std.ascii.findIgnoreCase(trimmed, "<div") != null) return true;
    if (std.ascii.findIgnoreCase(trimmed, "<body") != null) return true;
    if (std.ascii.findIgnoreCase(trimmed, "<head") != null) return true;
    return false;
}

fn looksLikeXml(content: []const u8) bool {
    const trimmed = std.mem.trim(u8, content, " \t\n\r");
    if (!std.mem.startsWith(u8, trimmed, "<")) return false;
    // XML declaration or tag, but not HTML
    if (std.mem.startsWith(u8, content, "<?xml")) return true;
    // Has closing tag that isn't HTML standard
    // Simple: if it has <*/> or </*> pattern and isn't HTML
    return false;
}

fn firstNLines(content: []const u8, n: usize) []const []const u8 {
    // Stack-allocated lines — caller must not hold references across alloc/free
    var lines: std.ArrayList([]const u8) = .empty;
    var iter = std.mem.splitScalar(u8, content, '\n');
    var count: usize = 0;
    while (iter.next()) |line| {
        lines.append(std.heap.page_allocator, line) catch break;
        count += 1;
        if (count >= n) break;
    }
    return lines.toOwnedSlice(std.heap.page_allocator) catch &[_][]const u8{};
}

fn startsWithLinePattern(lines: []const []const u8, pattern: []const u8) bool {
    for (lines) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, pattern)) return true;
    }
    return false;
}

fn looksLikeSearchResults(lines: []const []const u8) bool {
    var match_count: usize = 0;
    for (lines) |line| {
        if (line.len == 0) continue;
        // Pattern: <path>:<line_number>:<content>
        // or <path>-<line_number>-<content> (rg context)
        if (parseGrepLine(line) != null) {
            match_count += 1;
            if (match_count >= 2) return true;
        }
    }
    return false;
}

fn parseGrepLine(line: []const u8) ?struct { path: []const u8, line_num: usize } {
    // Handle Windows paths: C:\Users\... 
    var start: usize = 0;
    if (line.len >= 2 and std.ascii.isAlphabetic(line[0]) and line[1] == ':') {
        // Could be Windows drive — scan past the colon
        start = 2;
    }

    // Find the first :<digits>: or -<digits>- pattern after start
    var i = start;
    while (i < line.len) : (i += 1) {
        const sep = line[i];
        if (sep == ':' or sep == '-') {
            if (i + 1 < line.len and std.ascii.isDigit(line[i + 1])) {
                // Found potential line-number marker
                var j = i + 1;
                while (j < line.len and std.ascii.isDigit(line[j])) {
                    j += 1;
                }
                if (j < line.len and (line[j] == ':' or line[j] == '-')) {
                    // It's a grep/ripgrep line
                    const num = std.fmt.parseInt(usize, line[i + 1 .. j], 10) catch continue;
                    return .{ .path = line[0..i], .line_num = num };
                }
            }
        }
    }
    return null;
}

fn looksLikeBuildOutput(lines: []const []const u8) bool {
    var error_count: usize = 0;
    for (lines) |line| {
        if (std.ascii.findIgnoreCase(line, "error") != null) error_count += 1;
        if (std.ascii.findIgnoreCase(line, "traceback") != null) error_count += 3;
        if (std.ascii.findIgnoreCase(line, "failed") != null) error_count += 1;
        if (std.ascii.findIgnoreCase(line, "warning:") != null) error_count += 1;
        if (std.mem.indexOf(u8, line, "======") != null) error_count += 1; // pytest separators
    }
    return error_count >= 3;
}

fn looksLikeSourceCode(lines: []const []const u8) bool {
    var code_count: usize = 0;
    for (lines) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        // Common language keywords
        if (std.mem.startsWith(u8, trimmed, "import ")) code_count += 1;
        if (std.mem.startsWith(u8, trimmed, "fn ")) code_count += 1;
        if (std.mem.startsWith(u8, trimmed, "pub fn ")) code_count += 2;
        if (std.mem.startsWith(u8, trimmed, "def ")) code_count += 1;
        if (std.mem.startsWith(u8, trimmed, "class ")) code_count += 1;
        if (std.mem.startsWith(u8, trimmed, "const ") and std.mem.indexOf(u8, trimmed, "=") != null) code_count += 1;
        if (std.mem.startsWith(u8, trimmed, "let ")) code_count += 1;
        if (std.mem.startsWith(u8, trimmed, "var ")) code_count += 1;
        if (std.mem.startsWith(u8, trimmed, "package ")) code_count += 1;
        if (std.mem.startsWith(u8, trimmed, "#include")) code_count += 1;
        if (std.mem.startsWith(u8, trimmed, "using namespace")) code_count += 1;
        // Common patterns: function calls, if/else/for/while
        if (std.mem.startsWith(u8, trimmed, "if ")) code_count += 1;
        if (std.mem.startsWith(u8, trimmed, "for ")) code_count += 1;
        if (std.mem.startsWith(u8, trimmed, "while ")) code_count += 1;
        if (std.mem.startsWith(u8, trimmed, "switch ")) code_count += 1;
        if (std.mem.startsWith(u8, trimmed, "return ")) code_count += 1;
        // Comments
        if (std.mem.startsWith(u8, trimmed, "//")) code_count += 1;
        if (std.mem.startsWith(u8, trimmed, "# ")) code_count += 1;
        // Indentation patterns (code typically has indented lines)
        if (trimmed.len > 0 and (trimmed[0] == ' ' or trimmed[0] == '\t')) code_count += 0;
    }
    return code_count >= 5;
}

fn looksLikeCsv(lines: []const []const u8) bool {
    if (lines.len < 2) return false;

    // Check if first line has commas
    const first = std.mem.trim(u8, lines[0], " \t\r\n");
    const comma_count = countChar(first, ',');
    if (comma_count < 2) return false;

    // Check if at least half the rows have the same number of commas
    const target = comma_count;
    var consistent: usize = 0;
    for (lines[1..]) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;
        if (countChar(trimmed, ',') == target) consistent += 1;
    }
    return consistent >= lines.len / 3;
}

fn countChar(s: []const u8, c: u8) usize {
    var count: usize = 0;
    for (s) |ch| {
        if (ch == c) count += 1;
    }
    return count;
}

test "detect empty content returns plain_text" {
    const result = detect("");
    try std.testing.expectEqual(ContentType.plain_text, result.content_type);
}

test "detect JSON array" {
    const result = detect("[{\"a\": 1}, {\"a\": 2}]");
    try std.testing.expectEqual(ContentType.json_array, result.content_type);
}

test "detect git diff" {
    const input = 
    \\diff --git a/src/main.zig b/src/main.zig
    \\index abc..def 100644
    \\--- a/src/main.zig
    \\+++ b/src/main.zig
    \\@@ -1,3 +1,4 @@
    \\ test
    \\
    ;
    const result = detect(input);
    try std.testing.expectEqual(ContentType.git_diff, result.content_type);
}

test "detect search results" {
    const input = "src/main.zig:42:fn process():\nfoo/bar.rs:10:fn test():\nbaz.py:5:def run():";
    const result = detect(input);
    try std.testing.expectEqual(ContentType.search_results, result.content_type);
}

test "detect Windows search paths" {
    const input = "C:\\Users\\foo\\bar.py:42:def process():\nD:\\data\\test.py:10:def run():";
    const result = detect(input);
    try std.testing.expectEqual(ContentType.search_results, result.content_type);
}

test "detect build output" {
    const input =
    \\==================== FAILURES ======================
    \\ERROR: something failed
    \\Traceback (most recent call last):
    \\  File "test.py", line 42, in test
    \\    assert False
    \\AssertionError
    ;
    const result = detect(input);
    try std.testing.expectEqual(ContentType.build_output, result.content_type);
}

test "detect source code" {
    const input =
    \\import std
    \\pub fn main() !void {
    \\    const x: i32 = 42;
    \\    return x;
    \\}
    ;
    const result = detect(input);
    try std.testing.expectEqual(ContentType.source_code, result.content_type);
}

test "detect HTML" {
    const input = "<html><body><div>Hello</div></body></html>";
    const result = detect(input);
    try std.testing.expectEqual(ContentType.html, result.content_type);
}

test "detect plain text fallback" {
    const result = detect("Hello, this is just some random text content.");
    try std.testing.expectEqual(ContentType.plain_text, result.content_type);
}

test "parse grep line with colon" {
    const parsed = parseGrepLine("src/main.zig:42:fn process():") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("src/main.zig", parsed.path);
    try std.testing.expectEqual(@as(usize, 42), parsed.line_num);
}

test "parse grep line with dash" {
    const parsed = parseGrepLine("src/main.zig-42-fn process():") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("src/main.zig", parsed.path);
    try std.testing.expectEqual(@as(usize, 42), parsed.line_num);
}

test "parse Windows path grep line" {
    const parsed = parseGrepLine("C:\\Users\\foo\\bar.py:42:def process():") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("C:\\Users\\foo\\bar.py", parsed.path);
    try std.testing.expectEqual(@as(usize, 42), parsed.line_num);
}