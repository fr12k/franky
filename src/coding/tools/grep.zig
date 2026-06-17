//! grep tool — §C.7 of the spec.
//!
//! Schema: `{pattern, path?, filesGlob?, regex?, caseSensitive?,
//!           contextBefore?, contextAfter?, maxMatches?, respectGitignore?}`.
//!
//! Two matching modes:
//!   - `regex=true` (default): `pattern` is compiled by `coding/regex.zig`
//!     (ECMAScript-subset: `. * + ? | [...] ^ $ \w \d \s` + negations +
//!     non-capturing groups). A bad pattern returns a structured
//!     `grep_bad_regex` error with the parser position so the model can
//!     fix it on the next turn.
//!   - `regex=false`: literal substring search (`grep -F` semantics).
//!     Useful for patterns full of metacharacters.
//!
//! Binary files are skipped (NUL byte in the first 8 KiB). Matches are
//! reported as `path:line:snippet`. Context lines (before/after) are
//! prefixed with `path-line-snippet`.
//!
//! `respectGitignore` (default `true`, matching `find` / `ls`): drops
//! files whose path is ignored by any `.gitignore` under `path`. Note
//! pre-v1.26.2 grep was missing this wiring entirely — a bare
//! `grep "<term>"` against a fresh build directory would scan every
//! `.zig-cache/.../*.yml` debug-info dump, easily emitting hundreds of
//! megabytes of cache-internal hits and exhausting context budgets.

const std = @import("std");
const ct = @import("../types.zig");
const at = ct.agent.types;
const ai = ct.ai;
const find_mod = @import("find.zig");
const regex_mod = @import("../regex.zig");
const workspace_mod = @import("workspace.zig");
const gitignore = @import("../gitignore.zig");
const truncate_mod = @import("truncate.zig");
const common = @import("common.zig");

pub const parameters_json: []const u8 =
    \\{
    \\  "type": "object",
    \\  "required": ["pattern"],
    \\  "properties": {
    \\    "pattern": {
    \\      "oneOf": [
    \\        {"type": "string", "description": "ECMAScript-subset regex by default: . * + ? | [abc] [^abc] [a-z] ^ $ \\w \\d \\s (and \\W \\D \\S). Non-capturing groups with (...). Set regex=false for literal substring match."},
    \\        {"type": "array", "items": {"type": "string"}, "minItems": 1, "description": "Multiple patterns — match ANY (OR). Each pattern is matched independently."}
    \\      ]
    \\    },
    \\    "path": {"type": "string", "description": "Root path to search. Default '.'."},
    \\    "filesGlob": {"type": "string", "description": "Only search files matching this glob (e.g. '**/*.zig')."},
    \\    "regex": {"type": "boolean", "description": "Treat pattern as regex. Default true. Set false for `grep -F` literal search."},
    \\    "caseSensitive": {"type": "boolean", "description": "Default true."},
    \\    "contextBefore": {"type": "integer", "minimum": 0},
    \\    "contextAfter": {"type": "integer", "minimum": 0},
    \\    "maxMatches": {"type": "integer", "minimum": 1, "description": "Max matches across all files. Default 500."},
    \\    "respectGitignore": {"type": "boolean", "description": "Respect .gitignore rules under path. Default true."}
    \\  },
    \\  "additionalProperties": false
    \\}
;

pub const default_max_matches: usize = 500;
pub const max_file_bytes: usize = 8 * 1024 * 1024; // skip huge files to keep grep fast
pub const binary_sniff_bytes: usize = 8 * 1024;

pub fn tool() at.AgentTool {
    return .{
        .name = "grep",
        .description = "Search files for a regex (default) or literal substring. Skips binaries. Output truncates at 500 matches OR 50 KB OR 500 chars per line — whichever first. Narrow with `path` and `filesGlob` (e.g. `**/*.zig`) before searching from repo root, otherwise broad searches truncate.",
        .parameters_json = parameters_json,
        .execution_mode = .parallel,
        .execute = execute,
    };
}

pub fn toolWithWorkspace(ws: *const workspace_mod.Workspace) at.AgentTool {
    return .{
        .name = "grep",
        .description = "Search files for a regex (path-safety enforced). Output truncates at 500 matches / 50 KB / 500 chars per line. Narrow with `path` and `filesGlob` before searching from repo root.",
        .parameters_json = parameters_json,
        .execution_mode = .parallel,
        .ctx = @constCast(@ptrCast(ws)),
        .execute = execute,
    };
}

fn execute(
    self: *const at.AgentTool,
    allocator: std.mem.Allocator,
    io: std.Io,
    call_id: []const u8,
    args_json: []const u8,
    cancel: *ai.stream.Cancel,
    on_update: at.OnUpdate,
) anyerror!at.ToolResult {
    _ = call_id;
    _ = on_update;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const json_to_parse = common.repairConcatJson(arena.allocator(), args_json) orelse args_json;
    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), json_to_parse, .{});
    const root = parsed.value;

    const patterns = try extractPatterns(arena.allocator(), root.object);
    if (patterns.len == 0) return common.toolError(allocator, "invalid_args", "pattern must be a non-empty string or array of strings");

    const user_path: []const u8 = if (root.object.get("path")) |v|
        (if (v == .string) v.string else ".")
    else
        ".";
    var canon_path: ?[]u8 = null;
    defer if (canon_path) |p| allocator.free(p);
    const path: []const u8 = if (self.ctx) |raw| blk: {
        const ws: *const workspace_mod.Workspace = @ptrCast(@alignCast(raw));
        const r = try workspace_mod.canonicalizeOrError(allocator, ws, user_path);
        switch (r) {
            .ok => |c| {
                canon_path = c.abs;
                break :blk c.abs;
            },
            .err => |e| return common.toolError(allocator, e.code, e.message),
        }
    } else user_path;
    const files_glob: ?[]const u8 = if (root.object.get("filesGlob")) |v|
        (if (v == .string) v.string else null)
    else
        null;
    const case_sensitive: bool = if (root.object.get("caseSensitive")) |v|
        (v != .bool or v.bool)
    else
        true;
    const context_before: usize = if (root.object.get("contextBefore")) |v|
        (if (v == .integer and v.integer >= 0) @intCast(v.integer) else 0)
    else
        0;
    const context_after: usize = if (root.object.get("contextAfter")) |v|
        (if (v == .integer and v.integer >= 0) @intCast(v.integer) else 0)
    else
        0;
    const max_matches: usize = if (root.object.get("maxMatches")) |v|
        (if (v == .integer and v.integer >= 1) @intCast(v.integer) else default_max_matches)
    else
        default_max_matches;
    const use_regex: bool = if (root.object.get("regex")) |v|
        (v != .bool or v.bool)
    else
        true;
    const respect_gitignore: bool = if (root.object.get("respectGitignore")) |v|
        (v != .bool or v.bool)
    else
        true;

    // Compile the regex(es) up front so a bad pattern surfaces as a clean
    // `grep_bad_regex` tool error before we touch the filesystem.
    var matcher: Matcher = undefined;
    if (use_regex) {
        matcher = compileMultiRegex(allocator, patterns, case_sensitive) catch |e| switch (e) {
            error.BadRegex => return common.toolError(allocator, "grep_bad_regex", "bad regex in one of the patterns (use regex=false for literal substring search)"),
            else => |err| return common.toolError(allocator, "compile_failed", @errorName(err)),
        };
    } else {
        matcher = try compileMultiLiteral(allocator, patterns, case_sensitive);
    }
    defer matcher.deinit();

    return try grepTree(allocator, io, path, &matcher, files_glob, context_before, context_after, max_matches, respect_gitignore, cancel);
}

/// Unified matcher abstraction so `grepFile` can stay pattern-agnostic.
/// Supports multiple patterns with OR semantics.
pub const Matcher = union(enum) {
    regex: struct { allocator: std.mem.Allocator, items: []regex_mod.Regex },
    literal: struct { allocator: std.mem.Allocator, items: []Literal },

    pub const Literal = struct {
        pattern: []const u8,
        case_sensitive: bool,
    };

    pub fn deinit(self: *Matcher) void {
        switch (self.*) {
            .regex => |r| {
                for (r.items) |*re| re.deinit();
                r.allocator.free(r.items);
            },
            .literal => |l| {
                l.allocator.free(l.items);
            },
        }
    }

    pub fn matches(self: *const Matcher, line: []const u8) bool {
        return switch (self.*) {
            .regex => |r| {
                for (r.items) |*re| {
                    if (re.matches(line)) return true;
                }
                return false;
            },
            .literal => |l| {
                for (l.items) |lit| {
                    const found = if (lit.case_sensitive)
                        std.mem.indexOf(u8, line, lit.pattern) != null
                    else
                        indexOfNoCase(line, lit.pattern) != null;
                    if (found) return true;
                }
                return false;
            },
        };
    }
};

/// Extract the pattern(s) from `root.object`.
///
/// Accepts either:
///   `"pattern": "foo.*bar"`         → single-element slice
///   `"pattern": ["foo", "bar"]`  → all elements (minimum 1)
///
/// Returns an empty slice when the field is absent or has the wrong type.
fn extractPatterns(arena_alloc: std.mem.Allocator, root: std.json.ObjectMap) ![]const []const u8 {
    const pattern_val = root.get("pattern") orelse return &.{};
    switch (pattern_val) {
        .string => {
            const p = pattern_val.string;
            if (p.len == 0) return &.{};
            const arr = try arena_alloc.alloc([]const u8, 1);
            arr[0] = p;
            return arr;
        },
        .array => {
            const items = pattern_val.array.items;
            // Count strings, skip non-strings silently.
            var n: usize = 0;
            for (items) |item| {
                if (item == .string and item.string.len > 0) n += 1;
            }
            if (n == 0) return &.{};
            const arr = try arena_alloc.alloc([]const u8, n);
            var i: usize = 0;
            for (items) |item| {
                if (item == .string and item.string.len > 0) {
                    arr[i] = item.string;
                    i += 1;
                }
            }
            return arr;
        },
        else => return &.{},
    }
}

/// Compile multiple regex patterns into a Matcher.
/// Falls back to literal mode for any pattern with unsupported assertions.
fn compileMultiRegex(allocator: std.mem.Allocator, patterns: []const []const u8, case_sensitive: bool) (error{BadRegex} || std.mem.Allocator.Error)!Matcher {
    // Try to compile all as regex first.
    var regexes: std.ArrayList(regex_mod.Regex) = .empty;
    errdefer {
        for (regexes.items) |*r| r.deinit();
        regexes.deinit(allocator);
    }

    for (patterns) |pattern| {
        const stripped = stripUnsupportedAssertions(pattern, allocator) catch {
            // Fall back to literal for this pattern.
            // Free any already-compiled regexes and build a mixed literal matcher.
            for (regexes.items) |*r| r.deinit();
            regexes.deinit(allocator);
            return compileMultiLiteral(allocator, patterns, case_sensitive);
        };
        defer allocator.free(stripped);

        var report: regex_mod.ErrorReport = .{};
        const re = regex_mod.compileOpts(
            allocator,
            stripped,
            .{ .case_insensitive = !case_sensitive },
            &report,
        ) catch return error.BadRegex;
        try regexes.append(allocator, re);
    }

    return .{ .regex = .{ .allocator = allocator, .items = try regexes.toOwnedSlice(allocator) } };
}

/// Compile multiple literal patterns into a Matcher.
fn compileMultiLiteral(allocator: std.mem.Allocator, patterns: []const []const u8, case_sensitive: bool) !Matcher {
    var lits: std.ArrayList(Matcher.Literal) = .empty;
    errdefer lits.deinit(allocator);

    for (patterns) |pattern| {
        try lits.append(allocator, .{ .pattern = pattern, .case_sensitive = case_sensitive });
    }

    return .{ .literal = .{ .allocator = allocator, .items = try lits.toOwnedSlice(allocator) } };
}

/// v2.18 — strip word-boundary assertions (`\b`, `\B`) unsupported
/// by Zig's ECMAScript-subset regex engine. These are the most common
/// patterns that models emit from PCRE/JavaScript/Go muscle memory.
///
/// Returns `error.UnsupportedRegexAssertion` for lookaround assertions
/// (`(?=`, `(?!`, `(?<=`, `(?<!`) which cannot be stripped without
/// changing semantics — callers should fall back to literal-substring mode.
fn stripUnsupportedAssertions(
    pattern: []const u8,
    allocator: std.mem.Allocator,
) (error{UnsupportedRegexAssertion} || std.mem.Allocator.Error)![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < pattern.len) {
        if (pattern[i] == '\\') {
            // Count consecutive backslashes.
            var bs_count: usize = 1;
            while (i + bs_count < pattern.len and pattern[i + bs_count] == '\\') : (bs_count += 1) {}

            if (i + bs_count < pattern.len and (pattern[i + bs_count] == 'b' or pattern[i + bs_count] == 'B')) {
                // `\b` / `\B` — word boundary assertion.
                // In ECMAScript regex, `\b` is a word boundary iff the
                // number of preceding backslashes is odd (meaning the `\`
                // sequence is the escape). If even, the last backslash
                // escapes the backslash before it, and `b` is literal.
                if (bs_count % 2 == 1) {
                    // Odd backslashes: the `\b` is a word boundary.
                    // Strip the entire sequence (backslashes + b/B).
                    i += bs_count + 1;
                    continue;
                } else {
                    // Even backslashes: `\\` escapes itself, so `b`/`B` is
                    // a literal char. Copy backslashes then the literal char.
                    for (0..bs_count) |_| {
                        try out.append(allocator, '\\');
                    }
                    try out.append(allocator, pattern[i + bs_count]);
                    i += bs_count + 1;
                    continue;
                }
            } else {
                // Not a `\b`/`\B` sequence — copy all backslashes.
                for (0..bs_count) |_| {
                    try out.append(allocator, '\\');
                }
                i += bs_count;
                continue;
            }
        }
        // Lookaround assertions — cannot strip without semantic change.
        if (i + 3 < pattern.len) {
            if (std.mem.eql(u8, pattern[i..i+3], "(?=") or
                std.mem.eql(u8, pattern[i..i+3], "(?!"))
            {
                return error.UnsupportedRegexAssertion;
            }
        }
        // Lookbehind assertions are 4 chars: (?<=, (?<!
        if (i + 4 < pattern.len) {
            if (std.mem.eql(u8, pattern[i..i+4], "(?<=") or
                std.mem.eql(u8, pattern[i..i+4], "(?<!"))
            {
                return error.UnsupportedRegexAssertion;
            }
        }
        try out.append(allocator, pattern[i]);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

pub fn grepTree(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    matcher: *const Matcher,
    files_glob: ?[]const u8,
    context_before: usize,
    context_after: usize,
    max_matches: usize,
    respect_gitignore: bool,
    cancel: *ai.stream.Cancel,
) !at.ToolResult {
    const root_dir = std.Io.Dir.cwd().openDir(io, cwd, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return common.toolError(allocator, "file_not_found", cwd),
        // path is a file, not a directory — grep it directly.
        error.NotDir => return grepSingleFile(allocator, io, cwd, matcher, context_before, context_after, max_matches, cancel),
        error.AccessDenied, error.PermissionDenied => return common.toolError(allocator, "access_denied", cwd),
        else => return common.toolError(allocator, "open_failed", @errorName(err)),
    };
    var dir = root_dir;
    defer dir.close(io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    // Mirror the find/ls pattern: load both ignore stacks once and
    // consult them per entry. See `gitignore.loadIgnoreStacks` for
    // the contract (gitignore is gated by `respect_gitignore`;
    // contextignore is §6.9-unconditional).
    var stacks = gitignore.loadIgnoreStacks(allocator, io, cwd, respect_gitignore);
    defer stacks.deinit();

    var total: usize = 0;
    var any_line_truncated: bool = false;
    var match_limit_reached: bool = false;
    while (walker.next(io) catch |e| return common.toolError(allocator, "walk_failed", @errorName(e))) |entry| {
        if (cancel.isFired()) return common.toolError(allocator, "aborted", "cancelled");
        if (entry.kind != .file) continue;
        // Hard-skip the `.git` directory regardless of `.gitignore`
        // contents. It's an internal data store, not source — no
        // legitimate grep result lives in there, and even one
        // packfile lookup is enough to derail a search.
        if (std.mem.startsWith(u8, entry.path, ".git/") or std.mem.eql(u8, entry.path, ".git")) continue;
        if (stacks.isIgnored(entry.path, false)) continue;
        if (files_glob) |g| if (!find_mod.globMatch(g, entry.path)) continue;
        if (total >= max_matches) {
            match_limit_reached = true;
            break;
        }
        const before = total;
        grepFile(
            allocator,
            io,
            &dir,
            entry.path,
            matcher,
            context_before,
            context_after,
            max_matches,
            &total,
            &out,
            &any_line_truncated,
        ) catch {
            // Skip unreadable files quietly.
            total = before;
        };
    }

    // v1.27.1 — apply the byte-cap from `truncate_mod`. Match limit
    // already governs row count, so we set `max_lines` to a no-op
    // ceiling (max usize) and let `default_max_bytes` (50 KB) be the
    // sole secondary bound. truncateHead returns a slice into
    // out.items so we don't need to dupe it twice.
    const trunc = truncate_mod.truncateHead(out.items, .{
        .max_lines = std.math.maxInt(usize),
        .max_bytes = truncate_mod.default_max_bytes,
    });

    var notices: std.ArrayList(u8) = .empty;
    defer notices.deinit(allocator);
    if (match_limit_reached) {
        const msg = try std.fmt.allocPrint(
            allocator,
            "{d} matches limit reached. Use limit={d} for more, or refine pattern",
            .{ max_matches, max_matches * 2 },
        );
        defer allocator.free(msg);
        if (notices.items.len > 0) try notices.appendSlice(allocator, ". ");
        try notices.appendSlice(allocator, msg);
    }
    if (trunc.truncated and trunc.truncated_by == .bytes) {
        const cap = try truncate_mod.formatSize(allocator, trunc.max_bytes);
        defer allocator.free(cap);
        const msg = try std.fmt.allocPrint(
            allocator,
            "{s} byte limit reached; refine pattern or use a narrower path/filesGlob",
            .{cap},
        );
        defer allocator.free(msg);
        if (notices.items.len > 0) try notices.appendSlice(allocator, ". ");
        try notices.appendSlice(allocator, msg);
    }
    if (any_line_truncated) {
        const msg = try std.fmt.allocPrint(
            allocator,
            "Some lines truncated to {d} chars. Use the read tool to see full lines",
            .{truncate_mod.grep_max_line_length},
        );
        defer allocator.free(msg);
        if (notices.items.len > 0) try notices.appendSlice(allocator, ". ");
        try notices.appendSlice(allocator, msg);
    }

    var final: std.ArrayList(u8) = .empty;
    defer final.deinit(allocator);
    try final.appendSlice(allocator, trunc.content);
    if (notices.items.len > 0) {
        if (final.items.len > 0 and final.items[final.items.len - 1] != '\n') try final.append(allocator, '\n');
        try final.append(allocator, '\n');
        try final.append(allocator, '[');
        try final.appendSlice(allocator, notices.items);
        try final.appendSlice(allocator, "]\n");
    }

    const text = try allocator.dupe(u8, final.items);
    const arr = try allocator.alloc(ai.types.ContentBlock, 1);
    arr[0] = .{ .text = .{ .text = text } };
    return .{ .content = arr };
}

/// Grep a single file path directly (used when `path` points to a file,
/// not a directory). Gitignore and filesGlob are not applied — the
/// caller already named the file explicitly.
fn grepSingleFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    file_path: []const u8,
    matcher: *const Matcher,
    context_before: usize,
    context_after: usize,
    max_matches: usize,
    cancel: *ai.stream.Cancel,
) !at.ToolResult {
    if (cancel.isFired()) return common.toolError(allocator, "aborted", "cancelled");

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var total: usize = 0;
    var any_line_truncated: bool = false;

    var cwd_dir = std.Io.Dir.cwd();
    grepFile(
        allocator,
        io,
        &cwd_dir,
        file_path,
        matcher,
        context_before,
        context_after,
        max_matches,
        &total,
        &out,
        &any_line_truncated,
    ) catch |e| switch (e) {
        error.FileNotFound => return common.toolError(allocator, "file_not_found", file_path),
        error.AccessDenied, error.PermissionDenied => return common.toolError(allocator, "access_denied", file_path),
        else => return common.toolError(allocator, "read_failed", @errorName(e)),
    };

    const trunc = truncate_mod.truncateHead(out.items, .{
        .max_lines = std.math.maxInt(usize),
        .max_bytes = truncate_mod.default_max_bytes,
    });

    var notices: std.ArrayList(u8) = .empty;
    defer notices.deinit(allocator);
    if (trunc.truncated and trunc.truncated_by == .bytes) {
        const cap = try truncate_mod.formatSize(allocator, trunc.max_bytes);
        defer allocator.free(cap);
        const msg = try std.fmt.allocPrint(allocator,
            "{s} byte limit reached; use a narrower pattern", .{cap});
        defer allocator.free(msg);
        try notices.appendSlice(allocator, msg);
    }
    if (any_line_truncated) {
        const msg = try std.fmt.allocPrint(allocator,
            "Some lines truncated to {d} chars. Use the read tool to see full lines",
            .{truncate_mod.grep_max_line_length});
        defer allocator.free(msg);
        if (notices.items.len > 0) try notices.appendSlice(allocator, ". ");
        try notices.appendSlice(allocator, msg);
    }

    var final: std.ArrayList(u8) = .empty;
    defer final.deinit(allocator);
    try final.appendSlice(allocator, trunc.content);
    if (notices.items.len > 0) {
        if (final.items.len > 0 and final.items[final.items.len - 1] != '\n') try final.append(allocator, '\n');
        try final.append(allocator, '\n');
        try final.append(allocator, '[');
        try final.appendSlice(allocator, notices.items);
        try final.appendSlice(allocator, "]\n");
    }

    const text = try allocator.dupe(u8, final.items);
    const arr = try allocator.alloc(ai.types.ContentBlock, 1);
    arr[0] = .{ .text = .{ .text = text } };
    return .{ .content = arr };
}

fn grepFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: *std.Io.Dir,
    rel_path: []const u8,
    matcher: *const Matcher,
    context_before: usize,
    context_after: usize,
    max_matches: usize,
    total: *usize,
    out: *std.ArrayList(u8),
    lines_truncated: *bool,
) !void {
    var file = try dir.openFile(io, rel_path, .{});
    defer file.close(io);

    const len = try file.length(io);
    if (len > max_file_bytes) return;

    const buf = try allocator.alloc(u8, @intCast(len));
    defer allocator.free(buf);
    const n = try file.readPositionalAll(io, buf, 0);
    const bytes = buf[0..n];

    // Binary skip.
    const sniff = @min(bytes.len, binary_sniff_bytes);
    if (std.mem.indexOfScalar(u8, bytes[0..sniff], 0) != null) return;

    // Split into lines (keep indices so we can do context cheaply).
    var line_starts: std.ArrayList(usize) = .empty;
    defer line_starts.deinit(allocator);
    try line_starts.append(allocator, 0);
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        if (bytes[i] == '\n') try line_starts.append(allocator, i + 1);
    }
    // Count of lines is line_starts.items.len - 1 if file ends with a newline,
    // otherwise line_starts.items.len.
    const line_count = if (bytes.len == 0) 0 else blk: {
        if (bytes.len > 0 and bytes[bytes.len - 1] == '\n') break :blk line_starts.items.len - 1;
        break :blk line_starts.items.len;
    };

    var last_printed: ?usize = null; // 0-based line index of the last line written
    var l: usize = 0;
    while (l < line_count) : (l += 1) {
        const start = line_starts.items[l];
        const end = if (l + 1 < line_starts.items.len) line_starts.items[l + 1] - 1 else bytes.len;
        const line = bytes[start..end];

        if (!matcher.matches(line)) continue;

        // Write "before" context.
        const ctx_start = if (l >= context_before) l - context_before else 0;
        const begin_print = if (last_printed) |lp| @max(ctx_start, lp + 1) else ctx_start;
        var bi = begin_print;
        while (bi < l) : (bi += 1) {
            try writeContextLine(out, allocator, rel_path, bi + 1, getLine(bytes, line_starts.items, bi), lines_truncated);
        }

        // The match line.
        try writeMatchLine(out, allocator, rel_path, l + 1, line, lines_truncated);
        total.* += 1;
        last_printed = l;

        // Write "after" context (but stop at end of file and at max_matches).
        var a_off: usize = 1;
        while (a_off <= context_after) : (a_off += 1) {
            const idx = l + a_off;
            if (idx >= line_count) break;
            try writeContextLine(out, allocator, rel_path, idx + 1, getLine(bytes, line_starts.items, idx), lines_truncated);
            last_printed = idx;
        }

        if (total.* >= max_matches) return;
    }
}

fn getLine(bytes: []const u8, line_starts: []const usize, idx: usize) []const u8 {
    const start = line_starts[idx];
    const end = if (idx + 1 < line_starts.len) line_starts[idx + 1] - 1 else bytes.len;
    return bytes[start..end];
}

fn writeMatchLine(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    path: []const u8,
    line_no: usize,
    line: []const u8,
    lines_truncated: *bool,
) !void {
    const t = truncate_mod.truncateLine(line, truncate_mod.grep_max_line_length);
    if (t.was_truncated) lines_truncated.* = true;
    const suffix: []const u8 = if (t.was_truncated) "... [truncated]" else "";
    try out.print(allocator, "{s}:{d}:{s}{s}\n", .{ path, line_no, t.text, suffix });
}

fn writeContextLine(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    path: []const u8,
    line_no: usize,
    line: []const u8,
    lines_truncated: *bool,
) !void {
    const t = truncate_mod.truncateLine(line, truncate_mod.grep_max_line_length);
    if (t.was_truncated) lines_truncated.* = true;
    const suffix: []const u8 = if (t.was_truncated) "... [truncated]" else "";
    try out.print(allocator, "{s}-{d}-{s}{s}\n", .{ path, line_no, t.text, suffix });
}

fn indexOfNoCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (haystack.len < needle.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var match = true;
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) {
                match = false;
                break;
            }
        }
        if (match) return i;
    }
    return null;
}


// ─── tests ────────────────────────────────────────────────────────────

const testing = std.testing;
const test_h = @import("../../test_helpers.zig");

fn literalMatcher(pattern: []const u8, case_sensitive: bool) Matcher {
    const lits = testing.allocator.alloc(Matcher.Literal, 1) catch @panic("OOM");
    lits[0] = .{ .pattern = pattern, .case_sensitive = case_sensitive };
    return .{ .literal = .{ .allocator = testing.allocator, .items = lits } };
}

fn regexMatcher(pattern: []const u8, case_insensitive: bool) !Matcher {
    var report: regex_mod.ErrorReport = .{};
    const re = try regex_mod.compileOpts(
        testing.allocator,
        pattern,
        .{ .case_insensitive = case_insensitive },
        &report,
    );
    const arr = try testing.allocator.alloc(regex_mod.Regex, 1);
    arr[0] = re;
    return .{ .regex = .{ .allocator = testing.allocator, .items = arr } };
}

test "grep tool: finds literal matches with line numbers" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_grep_test";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};

    try std.Io.Dir.cwd().createDirPath(io, base);
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/a.txt", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "line one\nNEEDLE here\nline three\n");
    }

    var cancel: ai.stream.Cancel = .{};
    var m = literalMatcher("NEEDLE", true);
    defer m.deinit();
    var res = try grepTree(gpa, io, base, &m, null, 0, 0, 100, false, &cancel);
    defer res.deinit(gpa);
    const text = res.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, text, ":2:NEEDLE here") != null);
    try testing.expect(std.mem.indexOf(u8, text, "line one") == null);
}

test "grep tool: case-insensitive literal match" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_grep_ci_test";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};

    try std.Io.Dir.cwd().createDirPath(io, base);
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/a.txt", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "Hello World\n");
    }

    var cancel: ai.stream.Cancel = .{};
    var m = literalMatcher("world", false);
    defer m.deinit();
    var res = try grepTree(gpa, io, base, &m, null, 0, 0, 100, false, &cancel);
    defer res.deinit(gpa);
    try testing.expect(std.mem.indexOf(u8, res.content[0].text.text, "Hello World") != null);
}

test "grep tool: context before/after" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_grep_ctx_test";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};

    try std.Io.Dir.cwd().createDirPath(io, base);
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/a.txt", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "l1\nl2\nMATCH\nl4\nl5\n");
    }

    var cancel: ai.stream.Cancel = .{};
    var m = literalMatcher("MATCH", true);
    defer m.deinit();
    var res = try grepTree(gpa, io, base, &m, null, 1, 1, 100, false, &cancel);
    defer res.deinit(gpa);
    const text = res.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, text, "-2-l2") != null);
    try testing.expect(std.mem.indexOf(u8, text, ":3:MATCH") != null);
    try testing.expect(std.mem.indexOf(u8, text, "-4-l4") != null);
}

test "grep tool: skips binary files" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_grep_bin_test";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};

    try std.Io.Dir.cwd().createDirPath(io, base);
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/bin.dat", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "\x00NEEDLE\x00\x00");
    }

    var cancel: ai.stream.Cancel = .{};
    var m = literalMatcher("NEEDLE", true);
    defer m.deinit();
    var res = try grepTree(gpa, io, base, &m, null, 0, 0, 100, false, &cancel);
    defer res.deinit(gpa);
    try testing.expect(std.mem.indexOf(u8, res.content[0].text.text, "NEEDLE") == null);
}

// ─── regex mode ───────────────────────────────────────────────────────

test "grep tool: regex metacharacters across files" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_grep_re_test";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};

    try std.Io.Dir.cwd().createDirPath(io, base);
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/a.zig", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "pub fn foo() void {}\nfn bar() !void {}\nconst x = 1;\n");
    }
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/b.zig", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "pub fn baz() u32 {\n    return 42;\n}\n");
    }

    var cancel: ai.stream.Cancel = .{};
    // Match function declarations: `fn <name>` (pub optional)
    var m = try regexMatcher("(pub )?fn \\w+", false);
    defer m.deinit();
    var res = try grepTree(gpa, io, base, &m, null, 0, 0, 100, false, &cancel);
    defer res.deinit(gpa);
    const text = res.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, text, "pub fn foo") != null);
    try testing.expect(std.mem.indexOf(u8, text, "fn bar") != null);
    try testing.expect(std.mem.indexOf(u8, text, "pub fn baz") != null);
    try testing.expect(std.mem.indexOf(u8, text, "const x") == null);
}

test "grep tool: regex + filesGlob combo" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_grep_glob_re";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};

    try std.Io.Dir.cwd().createDirPath(io, base);
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/a.zig", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "TODO: ship it\n");
    }
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/notes.txt", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "TODO: write more\n");
    }

    var cancel: ai.stream.Cancel = .{};
    var m = try regexMatcher("^TODO:", false);
    defer m.deinit();
    var res = try grepTree(gpa, io, base, &m, "*.zig", 0, 0, 100, false, &cancel);
    defer res.deinit(gpa);
    const text = res.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, text, "a.zig") != null);
    try testing.expect(std.mem.indexOf(u8, text, "notes.txt") == null);
}

test "grep tool: grep_bad_regex error path" {
    const gpa = testing.allocator;
    const bad =
        \\{"pattern":"foo(bar","path":"/tmp"}
    ;
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    var cancel: ai.stream.Cancel = .{};
    const t = tool();
    var res = try t.execute(&t, gpa, io, "call-1", bad, &cancel, .{});
    defer res.deinit(gpa);
    try testing.expect(res.is_error);
    try testing.expect(std.mem.indexOf(u8, res.content[0].text.text, "grep_bad_regex") != null);
    try testing.expect(std.mem.indexOf(u8, res.content[0].text.text, "bad regex") != null);
}

test "grep tool: regex=false preserves literal behavior" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_grep_literal_opt";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};

    try std.Io.Dir.cwd().createDirPath(io, base);
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/a.txt", .{});
        defer f.close(io);
        // `.*` as literal chars, not a regex
        try f.writeStreamingAll(io, "hello .* world\nnothing here\n");
    }

    var cancel: ai.stream.Cancel = .{};
    const args = try std.fmt.allocPrint(gpa,
        \\{{"pattern":".*","path":"{s}","regex":false}}
    , .{base});
    defer gpa.free(args);
    const t = tool();
    var res = try t.execute(&t, gpa, io, "call-2", args, &cancel, .{});
    defer res.deinit(gpa);
    try testing.expect(!res.is_error);
    try testing.expect(std.mem.indexOf(u8, res.content[0].text.text, ":1:hello .* world") != null);
    try testing.expect(std.mem.indexOf(u8, res.content[0].text.text, "nothing here") == null);
}

test "grep tool: cancellation fires cleanly with regex compiled" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_grep_cancel";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};

    try std.Io.Dir.cwd().createDirPath(io, base);
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/a.txt", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "match me\n");
    }

    var cancel: ai.stream.Cancel = .{};
    cancel.fire();
    var m = try regexMatcher("match", false);
    defer m.deinit();
    var res = try grepTree(gpa, io, base, &m, null, 0, 0, 100, false, &cancel);
    defer res.deinit(gpa);
    try testing.expect(res.is_error);
    try testing.expect(std.mem.indexOf(u8, res.content[0].text.text, "aborted") != null);
}

test "grep tool: respectGitignore drops ignored matches (v1.26.2 regression)" {
    // Pre-v1.26.2 grep had no gitignore wiring at all — this test
    // would return matches from `cache/leak.txt` even though the
    // sibling `.gitignore` says `cache/`. The literal repro is what
    // chewed through 1M context tokens in a sub-agent run: a bare
    // `grep "<term>"` in a fresh build directory walked every
    // `.zig-cache/.../*.yml` debug-info dump.
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_grep_gitignore";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};

    try std.Io.Dir.cwd().createDirPath(io, base);
    try std.Io.Dir.cwd().createDirPath(io, base ++ "/cache");
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/.gitignore", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "cache/\n");
    }
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/visible.txt", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "needle here\n");
    }
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/cache/leak.txt", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "needle inside cache\n");
    }

    var cancel: ai.stream.Cancel = .{};
    var m = try regexMatcher("needle", false);
    defer m.deinit();

    // respect_gitignore = true → cache/leak.txt is skipped.
    var res = try grepTree(gpa, io, base, &m, null, 0, 0, 100, true, &cancel);
    defer res.deinit(gpa);
    const text = res.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, text, "visible.txt") != null);
    try testing.expect(std.mem.indexOf(u8, text, "cache/leak.txt") == null);

    // respect_gitignore = false → both files surface.
    var res2 = try grepTree(gpa, io, base, &m, null, 0, 0, 100, false, &cancel);
    defer res2.deinit(gpa);
    const text2 = res2.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, text2, "visible.txt") != null);
    try testing.expect(std.mem.indexOf(u8, text2, "cache/leak.txt") != null);
}

test "grep tool: .contextignore is enforced unconditionally (§6.9)" {
    // Pin the §6.9 contract: contextignored paths never appear in
    // `grep` output, even with `respect_gitignore=false`. The needle
    // is the same in every file so we can prove suppression by
    // looking only at filenames in the result.
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_grep_contextignore";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};

    try std.Io.Dir.cwd().createDirPath(io, base ++ "/archive");
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/.contextignore", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "archive/\nfrozen.md\n");
    }
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/current.md", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "needle here\n");
    }
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/frozen.md", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "needle in frozen\n");
    }
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/archive/old.md", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "needle in archive\n");
    }

    var cancel: ai.stream.Cancel = .{};
    var m = try regexMatcher("needle", false);
    defer m.deinit();

    // respect_gitignore=false — contextignore still suppresses.
    var res = try grepTree(gpa, io, base, &m, null, 0, 0, 100, false, &cancel);
    defer res.deinit(gpa);
    const text = res.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, text, "current.md") != null);
    try testing.expect(std.mem.indexOf(u8, text, "frozen.md") == null);
    try testing.expect(std.mem.indexOf(u8, text, "archive/old.md") == null);
}

test "grep tool: path pointing to a single file works" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_grep_single_file";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};

    try std.Io.Dir.cwd().createDirPath(io, base);
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/src.zig", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "fn saveBuiltin() void {}\nfn other() void {}\n");
    }

    var cancel: ai.stream.Cancel = .{};
    const args = try std.fmt.allocPrint(gpa,
        \\{{"pattern":"fn saveBuiltin","path":"{s}/src.zig","regex":false}}
    , .{base});
    defer gpa.free(args);
    const t = tool();
    var res = try t.execute(&t, gpa, io, "call-sf", args, &cancel, .{});
    defer res.deinit(gpa);
    try testing.expect(!res.is_error);
    const text = res.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, text, "fn saveBuiltin") != null);
    try testing.expect(std.mem.indexOf(u8, text, "fn other") == null);
}

test "grep tool: hard-skips .git directory regardless of respectGitignore" {
    // `.git` is an internal data store, not source — never grep-able
    // even when no `.gitignore` mentions it. Verifies the explicit
    // skip in grepTree, not the gitignore stack.
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_grep_dotgit";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};

    try std.Io.Dir.cwd().createDirPath(io, base);
    try std.Io.Dir.cwd().createDirPath(io, base ++ "/.git");
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/.git/config", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "[core]\n\trepositoryformatversion = needle\n");
    }
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/README.md", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "needle in source\n");
    }

    var cancel: ai.stream.Cancel = .{};
    var m = try regexMatcher("needle", false);
    defer m.deinit();
    // respect_gitignore=false intentionally — proves the .git skip is
    // independent of the gitignore stack.
    var res = try grepTree(gpa, io, base, &m, null, 0, 0, 100, false, &cancel);
    defer res.deinit(gpa);
    const text = res.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, text, "README.md") != null);
    try testing.expect(std.mem.indexOf(u8, text, ".git/config") == null);
}

test "grep tool: long match line is truncated to grep_max_line_length (v1.27.1)" {
    // A single long match line should be capped at 500 chars and
    // suffixed with `... [truncated]`. The notice block at the end
    // should mention `Use the read tool to see full lines`.
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_grep_long_line";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};

    try std.Io.Dir.cwd().createDirPath(io, base);
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/big.txt", .{});
        defer f.close(io);
        // 800-char line containing "needle" at the start.
        var buf: [800]u8 = undefined;
        @memset(&buf, 'x');
        @memcpy(buf[0..6], "needle");
        try f.writeStreamingAll(io, &buf);
        try f.writeStreamingAll(io, "\n");
    }

    var cancel: ai.stream.Cancel = .{};
    var m = try regexMatcher("needle", false);
    defer m.deinit();
    var res = try grepTree(gpa, io, base, &m, null, 0, 0, 100, false, &cancel);
    defer res.deinit(gpa);
    const text = res.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, text, "needle") != null);
    try testing.expect(std.mem.indexOf(u8, text, "... [truncated]") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Use the read tool to see full lines") != null);
    // Sanity: the capped match line shouldn't contain all 800 'x's.
    try testing.expect(text.len < 1500);
}

test "grep tool: total output is byte-capped at default_max_bytes (v1.27.1)" {
    // 200 short matching files, each contributing ~30 bytes of output,
    // gives ~6 KB total. To exercise the byte cap we make 4000+ files
    // — each "needle: <id>" match emits ~15 bytes. Combined with a
    // generous match limit so the byte cap is the trigger, not the
    // match count.
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_grep_byte_cap";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};

    try std.Io.Dir.cwd().createDirPath(io, base);
    var i: usize = 0;
    while (i < 4000) : (i += 1) {
        const path = try std.fmt.allocPrint(gpa, "{s}/f{d:0>4}.txt", .{ base, i });
        defer gpa.free(path);
        var f = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "needle here\n");
    }

    var cancel: ai.stream.Cancel = .{};
    var m = try regexMatcher("needle", false);
    defer m.deinit();
    // max_matches = 10000 so the byte cap trips first.
    var res = try grepTree(gpa, io, base, &m, null, 0, 0, 10000, false, &cancel);
    defer res.deinit(gpa);
    const text = res.content[0].text.text;
    // Cap is 50 KB; allow some headroom for the notice trailer.
    try testing.expect(text.len <= 60 * 1024);
    try testing.expect(std.mem.indexOf(u8, text, "byte limit reached") != null);
}

test "stripUnsupportedAssertions: strips \\b and \\B" {
    const gpa = testing.allocator;

    const stripped = try stripUnsupportedAssertions("fn foo\\b", gpa);
    defer gpa.free(stripped);
    try testing.expectEqualStrings("fn foo", stripped);

    const stripped_b = try stripUnsupportedAssertions("foo\\Bbar", gpa);
    defer gpa.free(stripped_b);
    try testing.expectEqualStrings("foobar", stripped_b);

    const both = try stripUnsupportedAssertions("\\b\\B", gpa);
    defer gpa.free(both);
    try testing.expectEqualStrings("", both);
}

test "stripUnsupportedAssertions: plain pattern passes through unchanged" {
    const gpa = testing.allocator;
    const plain = try stripUnsupportedAssertions("fn grep", gpa);
    defer gpa.free(plain);
    try testing.expectEqualStrings("fn grep", plain);

    const with_meta = try stripUnsupportedAssertions("foo.*bar\\d+", gpa);
    defer gpa.free(with_meta);
    try testing.expectEqualStrings("foo.*bar\\d+", with_meta);
}

test "stripUnsupportedAssertions: literal backslash before b is preserved" {
    const gpa = testing.allocator;
    // Double-backslash = literal backslash followed by b — not \\b.
    const lit = try stripUnsupportedAssertions("\\\\b", gpa);
    defer gpa.free(lit);
    try testing.expectEqualStrings("\\\\b", lit);
}

test "stripUnsupportedAssertions: lookaround assertions trigger UnsupportedRegexAssertion" {
    const gpa = testing.allocator;
    try testing.expectError(error.UnsupportedRegexAssertion, stripUnsupportedAssertions("(?=foo)", gpa));
    try testing.expectError(error.UnsupportedRegexAssertion, stripUnsupportedAssertions("(?!foo)", gpa));
}

test "stripUnsupportedAssertions: lookbehind assertions trigger UnsupportedRegexAssertion" {
    const gpa = testing.allocator;
    try testing.expectError(error.UnsupportedRegexAssertion, stripUnsupportedAssertions("(?<=foo)", gpa));
    try testing.expectError(error.UnsupportedRegexAssertion, stripUnsupportedAssertions("(?<!foo)", gpa));
}

test "grep tool: multi-pattern with array (OR semantics)" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_grep_multi";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};

    try std.Io.Dir.cwd().createDirPath(io, base);
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/fruits.txt", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "apple pie\nbanana bread\ncherry tart\ndate smoothie\n");
    }

    // Helper to build JSON args without format-string conflicts.
    // Produces: {"pattern":[...],"path":"...","regex":false}
    const buildArgs = struct {
        fn make(a: std.mem.Allocator, patterns: []const []const u8, path: []const u8, is_regex: bool) ![]u8 {
            var buf: std.ArrayList(u8) = .empty;
            errdefer buf.deinit(a);
            try buf.appendSlice(a, "{\"pattern\":[");
            for (patterns, 0..) |p, i| {
                if (i > 0) try buf.appendSlice(a, ",");
                try buf.append(a, '\"');
                try buf.appendSlice(a, p);
                try buf.append(a, '\"');
            }
            try buf.appendSlice(a, "],\"path\":\"");
            try buf.appendSlice(a, path);
            try buf.appendSlice(a, "\",\"regex\":");
            try buf.appendSlice(a, if (is_regex) "true" else "false");
            try buf.append(a, '}');
            return buf.toOwnedSlice(a);
        }
    }.make;

    // Literal mode: match "apple" or "banana"
    {
        var cancel: ai.stream.Cancel = .{};
        const t = tool();
        const args = try buildArgs(gpa, &.{"apple", "banana"}, base, false);
        defer gpa.free(args);
        var res = try t.execute(&t, gpa, io, "call-1", args, &cancel, .{});
        defer res.deinit(gpa);
        try testing.expect(!res.is_error);
        const text = res.content[0].text.text;
        try testing.expect(std.mem.indexOf(u8, text, "apple pie") != null);
        try testing.expect(std.mem.indexOf(u8, text, "banana bread") != null);
        try testing.expect(std.mem.indexOf(u8, text, "cherry tart") == null);
        try testing.expect(std.mem.indexOf(u8, text, "date smoothie") == null);
    }

    // Regex mode: match "app.*" or "cher.*"
    {
        var cancel: ai.stream.Cancel = .{};
        const t = tool();
        const args = try buildArgs(gpa, &.{"app.*", "cher.*"}, base, true);
        defer gpa.free(args);
        var res = try t.execute(&t, gpa, io, "call-2", args, &cancel, .{});
        defer res.deinit(gpa);
        try testing.expect(!res.is_error);
        const text = res.content[0].text.text;
        try testing.expect(std.mem.indexOf(u8, text, "apple pie") != null);
        try testing.expect(std.mem.indexOf(u8, text, "cherry tart") != null);
        try testing.expect(std.mem.indexOf(u8, text, "banana bread") == null);
        try testing.expect(std.mem.indexOf(u8, text, "date smoothie") == null);
    }

    // Single string still works (regression check)
    {
        var cancel: ai.stream.Cancel = .{};
        const t = tool();
        const args = try buildArgs(gpa, &.{"banana"}, base, false);
        defer gpa.free(args);
        var res = try t.execute(&t, gpa, io, "call-3", args, &cancel, .{});
        defer res.deinit(gpa);
        try testing.expect(!res.is_error);
        const text = res.content[0].text.text;
        try testing.expect(std.mem.indexOf(u8, text, "banana bread") != null);
        try testing.expect(std.mem.indexOf(u8, text, "apple pie") == null);
        try testing.expect(std.mem.indexOf(u8, text, "cherry tart") == null);
    }
}
