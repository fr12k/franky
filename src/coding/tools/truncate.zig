//! Shared truncation primitives for tool outputs (v1.27.0).
//!
//! Ported from `badlogic/pi-mono`'s `coding-agent/src/core/tools/truncate.ts`
//! with adaptation for Zig's allocation discipline: where the TS version
//! returns a freshly built string, the Zig version returns a slice into the
//! caller-owned input — no allocation, no ownership transfer. The caller
//! `dupe`s if it needs to outlive the input.
//!
//! Two independent limits, whichever hits first wins:
//!   - **Line limit** (default 2000)
//!   - **Byte limit** (default 50 KiB)
//!
//! Two head/tail variants:
//!   - `truncateHead` — keep the **first** N lines/bytes (file reads).
//!     Never returns a partial line; if the very first line exceeds the
//!     byte limit, returns empty + `first_line_exceeds_limit = true` and
//!     the caller should suggest a chunked alternative (e.g. `bash sed`).
//!   - `truncateTail` — keep the **last** N lines/bytes (bash output —
//!     errors live at the end). May return a partial first line in the
//!     edge case where the final line alone exceeds the byte limit.
//!
//! Plus:
//!   - `truncateLine` — single-line cap (used by `grep` to keep
//!     individual match lines compact).
//!   - `formatSize` — human-friendly `512B` / `1.5KB` / `3.2MB`.
//!
//! All slices in `Result.content` borrow from the input — caller owns
//! the lifetime. `formatSize` is the only allocating function.

const std = @import("std");

// Agent-layer truncation primitives (tool_result_max_bytes, formatSize)
// now live in `agent/truncate.zig` so the agent loop doesn't have to
// import this coding-layer module. Re-exported here for backward
// compatibility with tools that still reference `truncate.formatSize`.
const agent_truncate = @import("../../agent/truncate.zig");
pub const tool_result_max_bytes = agent_truncate.tool_result_max_bytes;
pub const formatSize = agent_truncate.formatSize;

pub const default_max_lines: usize = 2000;
pub const default_max_bytes: usize = 50 * 1024;
pub const grep_max_line_length: usize = 500;

pub const TruncatedBy = enum { lines, bytes };

pub const Options = struct {
    max_lines: usize = default_max_lines,
    max_bytes: usize = default_max_bytes,
};

pub const Result = struct {
    /// Slice into the caller-supplied `content`. Borrowed; caller `dupe`s
    /// to outlive the input.
    content: []const u8,
    truncated: bool,
    truncated_by: ?TruncatedBy,
    total_lines: usize,
    total_bytes: usize,
    output_lines: usize,
    output_bytes: usize,
    /// True only in the `truncateTail` edge case where the final line
    /// alone is larger than `max_bytes` — the slice is then the LAST
    /// `max_bytes` bytes of that line (UTF-8 boundary aware) rather
    /// than a full line. Surface in the result message so the caller
    /// can render `[Showing last 50KB of line 9000 (line is 1.2MB)]`.
    last_line_partial: bool,
    /// True only in the `truncateHead` edge case where the very first
    /// line exceeds the byte limit — content is empty. Caller should
    /// suggest a chunked alternative.
    first_line_exceeds_limit: bool,
    max_lines: usize,
    max_bytes: usize,
};

/// Truncate `content` from the head (keep the first N lines/bytes).
///
/// Walks forward counting newlines until either the line cap is reached
/// or appending the next line would exceed the byte cap, whichever
/// comes first. Always returns whole lines (never a partial line) —
/// see `truncateTail` for the partial-line edge case.
pub fn truncateHead(content: []const u8, options: Options) Result {
    const total_bytes = content.len;
    const total_lines = countLines(content);

    if (total_lines <= options.max_lines and total_bytes <= options.max_bytes) {
        return .{
            .content = content,
            .truncated = false,
            .truncated_by = null,
            .total_lines = total_lines,
            .total_bytes = total_bytes,
            .output_lines = total_lines,
            .output_bytes = total_bytes,
            .last_line_partial = false,
            .first_line_exceeds_limit = false,
            .max_lines = options.max_lines,
            .max_bytes = options.max_bytes,
        };
    }

    // First line too big? Bail with empty + the flag.
    const first_line_end = std.mem.indexOfScalar(u8, content, '\n') orelse content.len;
    if (first_line_end > options.max_bytes) {
        return .{
            .content = "",
            .truncated = true,
            .truncated_by = .bytes,
            .total_lines = total_lines,
            .total_bytes = total_bytes,
            .output_lines = 0,
            .output_bytes = 0,
            .last_line_partial = false,
            .first_line_exceeds_limit = true,
            .max_lines = options.max_lines,
            .max_bytes = options.max_bytes,
        };
    }

    // Walk forward, accumulating whole lines until a cap trips.
    var cursor: usize = 0;
    var lines_kept: usize = 0;
    var truncated_by: TruncatedBy = .lines;
    while (cursor < content.len and lines_kept < options.max_lines) {
        const next_nl = std.mem.indexOfScalarPos(u8, content, cursor, '\n');
        // `next_nl` points at the `\n` (exclusive of `\n`); the span
        // [cursor, next_nl+1) including the `\n` is what we'd keep. For
        // a trailing line with no `\n`, span_end == content.len.
        const span_end_inclusive = if (next_nl) |i| i + 1 else content.len;
        if (span_end_inclusive > options.max_bytes) {
            truncated_by = .bytes;
            break;
        }
        cursor = span_end_inclusive;
        lines_kept += 1;
    }
    if (lines_kept >= options.max_lines and cursor <= options.max_bytes) {
        truncated_by = .lines;
    }

    const out = content[0..cursor];
    return .{
        .content = out,
        .truncated = true,
        .truncated_by = truncated_by,
        .total_lines = total_lines,
        .total_bytes = total_bytes,
        .output_lines = lines_kept,
        .output_bytes = out.len,
        .last_line_partial = false,
        .first_line_exceeds_limit = false,
        .max_lines = options.max_lines,
        .max_bytes = options.max_bytes,
    };
}

/// Truncate `content` from the tail (keep the last N lines/bytes).
///
/// Walks backward counting newlines until a cap trips. May return a
/// partial first line in the edge case where the final line alone
/// exceeds `max_bytes` — that slice is taken from the END of the line
/// at a valid UTF-8 boundary, with `last_line_partial = true`.
pub fn truncateTail(content: []const u8, options: Options) Result {
    const total_bytes = content.len;
    const total_lines = countLines(content);

    if (total_lines <= options.max_lines and total_bytes <= options.max_bytes) {
        return .{
            .content = content,
            .truncated = false,
            .truncated_by = null,
            .total_lines = total_lines,
            .total_bytes = total_bytes,
            .output_lines = total_lines,
            .output_bytes = total_bytes,
            .last_line_partial = false,
            .first_line_exceeds_limit = false,
            .max_lines = options.max_lines,
            .max_bytes = options.max_bytes,
        };
    }

    // Walk backward by newlines.
    var lines_kept: usize = 0;
    var cut: usize = content.len;
    var truncated_by: TruncatedBy = .lines;
    while (cut > 0 and lines_kept < options.max_lines) {
        // Find the LEFT boundary of the next line we'd add (going
        // backward). The newline that bounds it on the left is the
        // last `\n` STRICTLY BEFORE the line — so we exclude
        // content[cut-1] from the search whenever it's a `\n`,
        // because that `\n` either terminates the line we just kept
        // (then it's already accounted for) or terminates the line
        // we're about to add (its left boundary is the `\n` BEFORE
        // it, not itself).
        const slice_start: usize = blk: {
            const search_end = if (cut > 0 and content[cut - 1] == '\n')
                cut - 1
            else
                cut;
            if (search_end == 0) break :blk 0;
            const last_nl = std.mem.lastIndexOfScalar(u8, content[0..search_end], '\n');
            break :blk if (last_nl) |i| i + 1 else 0;
        };
        const candidate_bytes = content.len - slice_start;
        if (candidate_bytes > options.max_bytes) {
            truncated_by = .bytes;
            // If this is the FIRST line we'd add and it alone exceeds
            // the byte cap, take a partial tail from this line at a
            // UTF-8 boundary.
            if (lines_kept == 0) {
                const partial_start = utf8BoundaryFromEnd(content, options.max_bytes);
                const out = content[partial_start..];
                return .{
                    .content = out,
                    .truncated = true,
                    .truncated_by = .bytes,
                    .total_lines = total_lines,
                    .total_bytes = total_bytes,
                    .output_lines = 1,
                    .output_bytes = out.len,
                    .last_line_partial = true,
                    .first_line_exceeds_limit = false,
                    .max_lines = options.max_lines,
                    .max_bytes = options.max_bytes,
                };
            }
            break;
        }
        cut = slice_start;
        lines_kept += 1;
        if (slice_start == 0) break;
    }
    if (lines_kept >= options.max_lines and (content.len - cut) <= options.max_bytes) {
        truncated_by = .lines;
    }

    const out = content[cut..];
    return .{
        .content = out,
        .truncated = true,
        .truncated_by = truncated_by,
        .total_lines = total_lines,
        .total_bytes = total_bytes,
        .output_lines = lines_kept,
        .output_bytes = out.len,
        .last_line_partial = false,
        .first_line_exceeds_limit = false,
        .max_lines = options.max_lines,
        .max_bytes = options.max_bytes,
    };
}

pub const LineResult = struct {
    /// Slice into the caller-supplied `line`, or — when `was_truncated`
    /// is true — the original is too long to fit; caller renders this
    /// as `<text>... [truncated]` or similar. We don't allocate the
    /// suffix here so the caller can pick the trailer wording.
    text: []const u8,
    was_truncated: bool,
};

/// Single-line cap — used by `grep` to keep match lines compact even
/// when the matched line is huge. Returns a sub-slice (no allocation).
pub fn truncateLine(line: []const u8, max_chars: usize) LineResult {
    if (line.len <= max_chars) return .{ .text = line, .was_truncated = false };
    return .{ .text = line[0..max_chars], .was_truncated = true };
}

// ─── helpers ─────────────────────────────────────────────────────

/// Count lines: number of `\n` characters + 1 if the content has any
/// bytes. A single `\n` is two lines (the empty content before and the
/// empty content after) — matches splitScalar(u8, content, '\n').len.
fn countLines(content: []const u8) usize {
    if (content.len == 0) return 1;
    var n: usize = 1;
    for (content) |c| if (c == '\n') {
        n += 1;
    };
    return n;
}

/// Walk back from the END of `content` to land on a valid UTF-8 start
/// byte such that the resulting tail is at most `max_bytes` long.
/// Continuation bytes have the bit pattern 10xxxxxx.
fn utf8BoundaryFromEnd(content: []const u8, max_bytes: usize) usize {
    if (content.len <= max_bytes) return 0;
    var start = content.len - max_bytes;
    while (start < content.len and (content[start] & 0xc0) == 0x80) start += 1;
    return start;
}

// ─── tests ───────────────────────────────────────────────────────

const testing = std.testing;

test "truncateHead: short content is not truncated" {
    const r = truncateHead("hello\nworld", .{});
    try testing.expect(!r.truncated);
    try testing.expect(r.truncated_by == null);
    try testing.expectEqualStrings("hello\nworld", r.content);
    try testing.expectEqual(@as(usize, 2), r.total_lines);
    try testing.expectEqual(@as(usize, 11), r.total_bytes);
}

test "truncateHead: line cap" {
    const r = truncateHead("a\nb\nc\nd\ne\n", .{ .max_lines = 3, .max_bytes = 1024 });
    try testing.expect(r.truncated);
    try testing.expectEqual(TruncatedBy.lines, r.truncated_by.?);
    try testing.expectEqual(@as(usize, 3), r.output_lines);
    try testing.expectEqualStrings("a\nb\nc\n", r.content);
}

test "truncateHead: byte cap stops short of line cap" {
    const r = truncateHead("aaaa\nbbbb\ncccc\n", .{ .max_lines = 100, .max_bytes = 6 });
    try testing.expect(r.truncated);
    try testing.expectEqual(TruncatedBy.bytes, r.truncated_by.?);
    try testing.expectEqualStrings("aaaa\n", r.content);
    try testing.expectEqual(@as(usize, 1), r.output_lines);
}

test "truncateHead: first line exceeds byte limit" {
    const r = truncateHead("aaaaaaaaaaaaaaaa\nshort\n", .{ .max_lines = 100, .max_bytes = 4 });
    try testing.expect(r.truncated);
    try testing.expect(r.first_line_exceeds_limit);
    try testing.expectEqual(@as(usize, 0), r.output_lines);
    try testing.expectEqualStrings("", r.content);
}

test "truncateHead: empty input" {
    const r = truncateHead("", .{});
    try testing.expect(!r.truncated);
    try testing.expectEqualStrings("", r.content);
}

test "truncateTail: short content is not truncated" {
    const r = truncateTail("hello\nworld", .{});
    try testing.expect(!r.truncated);
    try testing.expectEqualStrings("hello\nworld", r.content);
}

test "truncateTail: line cap keeps the last N lines" {
    const r = truncateTail("a\nb\nc\nd\ne\n", .{ .max_lines = 2, .max_bytes = 1024 });
    try testing.expect(r.truncated);
    try testing.expectEqual(TruncatedBy.lines, r.truncated_by.?);
    try testing.expectEqualStrings("d\ne\n", r.content);
}

test "truncateTail: byte cap" {
    const r = truncateTail("aaaa\nbbbb\ncccc\n", .{ .max_lines = 100, .max_bytes = 6 });
    try testing.expect(r.truncated);
    try testing.expectEqual(TruncatedBy.bytes, r.truncated_by.?);
    // Tail cap of 6 keeps "cccc\n" (5 bytes); "bbbb\ncccc\n" would be 10.
    try testing.expectEqualStrings("cccc\n", r.content);
}

test "truncateTail: last line alone exceeds byte limit (partial)" {
    const r = truncateTail("first\nsecond\naaaaaaaaaaaaaaaa", .{ .max_lines = 100, .max_bytes = 8 });
    try testing.expect(r.truncated);
    try testing.expect(r.last_line_partial);
    try testing.expectEqualStrings("aaaaaaaa", r.content);
}

test "truncateTail: UTF-8 multi-byte boundary handling" {
    // Each `é` is 2 bytes (0xC3 0xA9). With max_bytes=5 we can fit
    // 2 chars (4 bytes) and not a half-char.
    const r = truncateTail("éééééé", .{ .max_lines = 100, .max_bytes = 5 });
    try testing.expect(r.truncated);
    try testing.expect(r.last_line_partial);
    // The cut should land on a char boundary (no orphaned 0x80 byte).
    try testing.expect(r.content.len <= 5);
    try testing.expect((r.content[0] & 0xc0) != 0x80);
}

test "truncateLine: short stays unchanged" {
    const r = truncateLine("short", 100);
    try testing.expect(!r.was_truncated);
    try testing.expectEqualStrings("short", r.text);
}

test "truncateLine: oversized clipped to max_chars" {
    const r = truncateLine("aaaaaaaaaaaaaaaa", 4);
    try testing.expect(r.was_truncated);
    try testing.expectEqualStrings("aaaa", r.text);
}


