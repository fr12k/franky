//! find tool — §C.6 of the spec.
//!
//! Schema: `{pattern, cwd?, limit?, respectGitignore?}`.
//!
//! `pattern` is a shell-style glob matched against each file's path
//! relative to `cwd` (default `.`). Supported glob syntax:
//!   - `*` matches any sequence of non-`/` characters
//!   - `**` matches any sequence including `/`
//!   - `?` matches a single non-`/` character
//!   - `[abc]` character class
//! Results are file paths, one per line.
//!
//! `pattern` may also be an array of strings — a file matches if it
//! matches ANY of the patterns (OR semantics).
//!
//! `respectGitignore` (default `true`): uses `coding/gitignore.zig` to
//! drop any result whose path is ignored by a `.gitignore` inside
//! `cwd`. Pass `false` to search the full tree.

const std = @import("std");
const ct = @import("../types.zig");
const at = ct.agent.types;
const ai = ct.ai;
const gitignore = @import("../gitignore.zig");
const workspace_mod = @import("workspace.zig");
const common = @import("common.zig");

pub const parameters_json: []const u8 =
    \\{
    \\  "type": "object",
    \\  "required": ["pattern"],
    \\  "properties": {
    \\    "pattern": {
    \\      "oneOf": [
    \\        {"type": "string", "description": "Glob pattern. Supports *, **, ?, [abc]."},
    \\        {"type": "array", "items": {"type": "string"}, "minItems": 1, "description": "Multiple glob patterns — match ANY (OR)."}
    \\      ]
    \\    },
    \\    "cwd": {"type": "string", "description": "Root to search (default '.')."},
    \\    "limit": {"type": "integer", "minimum": 1, "description": "Maximum number of results (default 1000)."},
    \\    "respectGitignore": {"type": "boolean", "description": "Respect .gitignore rules under cwd. Default true."}
    \\  },
    \\  "additionalProperties": false
    \\}
;

pub const default_limit: usize = 1000;
pub const max_walk_entries: usize = 500_000;

pub fn tool() at.AgentTool {
    return .{
        .name = "find",
        .description = "Find files by glob pattern (*, **, ?, [abc]). Default limit is 1000 results. Pass a focused `cwd` first when searching a large tree — broad globs from repo root truncate.",
        .parameters_json = parameters_json,
        .execution_mode = .parallel,
        .execute = execute,
    };
}

pub fn toolWithWorkspace(ws: *const workspace_mod.Workspace) at.AgentTool {
    return .{
        .name = "find",
        .description = "Find files by glob pattern (path-safety enforced). Default limit is 1000. Narrow with `cwd` before scanning from repo root.",
        .parameters_json = parameters_json,
        .execution_mode = .parallel,
        .ctx = @constCast(@ptrCast(ws)),
        .execute = execute,
    };
}

/// Extract the pattern(s) from `root.object`.
///
/// Accepts either:
///   `"pattern": "foo/*.zig"`         → single-element slice
///   `"pattern": ["a.zig", "b.zig"]`  → all elements (minimum 1)
///
/// Returns an empty slice when the field is absent or has the wrong type.
fn extractPatterns(arena_alloc: std.mem.Allocator, root: std.json.ObjectMap) ![]const []const u8 {
    const pattern_val = root.get("pattern") orelse return &.{};
    switch (pattern_val) {
        .string => {
            const arr = try arena_alloc.alloc([]const u8, 1);
            arr[0] = pattern_val.string;
            return arr;
        },
        .array => {
            const items = pattern_val.array.items;
            // Count strings, skip non-strings silently.
            var n: usize = 0;
            for (items) |item| {
                if (item == .string) n += 1;
            }
            if (n == 0) return &.{};
            const arr = try arena_alloc.alloc([]const u8, n);
            var i: usize = 0;
            for (items) |item| {
                if (item == .string) {
                    arr[i] = item.string;
                    i += 1;
                }
            }
            return arr;
        },
        else => return &.{},
    }
}

/// Returns true if `name` matches any of the `patterns`.
fn anyMatch(patterns: []const []const u8, name: []const u8) bool {
    for (patterns) |p| {
        if (globMatch(p, name)) return true;
    }
    return false;
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

    const user_cwd: []const u8 = if (root.object.get("cwd")) |v|
        (if (v == .string) v.string else ".")
    else
        ".";
    const limit: usize = if (root.object.get("limit")) |v| blk: {
        if (v == .integer and v.integer >= 1) break :blk @intCast(v.integer);
        break :blk default_limit;
    } else default_limit;
    const respect_gitignore: bool = if (root.object.get("respectGitignore")) |v|
        (v != .bool or v.bool)
    else
        true;

    var canon_path: ?[]u8 = null;
    defer if (canon_path) |p| allocator.free(p);
    const cwd: []const u8 = if (self.ctx) |raw| blk: {
        const ws: *const workspace_mod.Workspace = @ptrCast(@alignCast(raw));
        const r = try workspace_mod.canonicalizeOrError(allocator, ws, user_cwd);
        switch (r) {
            .ok => |c| {
                canon_path = c.abs;
                break :blk c.abs;
            },
            .err => |e| return common.toolError(allocator, e.code, e.message),
        }
    } else user_cwd;

    return try findMatches(allocator, io, cwd, patterns, limit, respect_gitignore, cancel);
}

pub fn findMatches(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    patterns: []const []const u8,
    limit: usize,
    respect_gitignore: bool,
    cancel: *ai.stream.Cancel,
) !at.ToolResult {
    const root_dir = std.Io.Dir.cwd().openDir(io, cwd, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return common.toolError(allocator, "file_not_found", cwd),
        error.NotDir => return common.toolError(allocator, "not_a_directory", cwd),
        error.AccessDenied, error.PermissionDenied => return common.toolError(allocator, "access_denied", cwd),
        else => return common.toolError(allocator, "open_failed", @errorName(err)),
    };
    var dir = root_dir;
    defer dir.close(io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var stacks = gitignore.loadIgnoreStacks(allocator, io, cwd, respect_gitignore);
    defer stacks.deinit();

    var found: usize = 0;
    var visited: usize = 0;
    while (walker.next(io) catch |e| return common.toolError(allocator, "walk_failed", @errorName(e))) |entry| {
        if (cancel.isFired()) return common.toolError(allocator, "aborted", "cancelled");
        visited += 1;
        if (visited > max_walk_entries) {
            try out.appendSlice(allocator, "(walk aborted: too many entries)\n");
            break;
        }
        // find matches only files (spec §C.6 default behavior; dirs are not "finds").
        if (entry.kind != .file) continue;
        // Hard-skip the `.git` directory regardless of `.gitignore`
        // contents. Git's internal data store isn't tracked-or-ignored
        // (it's a special directory git manages); without this skip a
        // recursive find from repo root pulls in thousands of object
        // hashes and derails the LLM's context.
        if (std.mem.eql(u8, entry.path, ".git") or std.mem.startsWith(u8, entry.path, ".git/")) continue;
        if (stacks.isIgnored(entry.path, false)) continue;
        if (anyMatch(patterns, entry.path)) {
            try out.appendSlice(allocator, entry.path);
            try out.append(allocator, '\n');
            found += 1;
            if (found >= limit) {
                try out.appendSlice(allocator, "(truncated: limit reached)\n");
                break;
            }
        }
    }

    const text = try allocator.dupe(u8, out.items);
    const arr = try allocator.alloc(ai.types.ContentBlock, 1);
    arr[0] = .{ .text = .{ .text = text } };
    return .{ .content = arr };
}

/// Minimal glob matcher: supports `*`, `**`, `?`, `[abc]`, `\` escape.
pub fn globMatch(pattern: []const u8, name: []const u8) bool {
    return matchInner(pattern, 0, name, 0);
}

fn matchInner(pat: []const u8, pi0: usize, s: []const u8, si0: usize) bool {
    var pi = pi0;
    var si = si0;
    while (pi < pat.len) {
        const c = pat[pi];
        switch (c) {
            '*' => {
                // '**' matches arbitrary path components (possibly zero);
                // '*' matches any non-'/' run.
                const is_double = pi + 1 < pat.len and pat[pi + 1] == '*';
                if (is_double) {
                    // Special case: '**/' — consume optional directory prefix.
                    // Try matching the remainder against s[si..] directly
                    // (zero-component case) before chewing through slashes.
                    var rest_start = pi + 2;
                    if (rest_start < pat.len and pat[rest_start] == '/') rest_start += 1;
                    if (matchInner(pat, rest_start, s, si)) return true;
                    // Otherwise advance si past one path component at a time.
                    while (si < s.len) {
                        if (s[si] == '/') {
                            si += 1;
                            if (matchInner(pat, rest_start, s, si)) return true;
                        } else {
                            si += 1;
                        }
                    }
                    return false;
                }
                pi += 1;
                // '*' at end matches anything remaining without a slash.
                if (pi >= pat.len) {
                    return std.mem.indexOfScalar(u8, s[si..], '/') == null;
                }
                while (si <= s.len) : (si += 1) {
                    if (matchInner(pat, pi, s, si)) return true;
                    if (si == s.len) break;
                    if (s[si] == '/') return false;
                }
                return false;
            },
            '?' => {
                if (si >= s.len) return false;
                if (s[si] == '/') return false;
                pi += 1;
                si += 1;
            },
            '[' => {
                // Character class: [abc] or [a-z], optional leading '!' or '^' to negate.
                if (si >= s.len) return false;
                pi += 1;
                var negate = false;
                if (pi < pat.len and (pat[pi] == '!' or pat[pi] == '^')) {
                    negate = true;
                    pi += 1;
                }
                var matched = false;
                while (pi < pat.len and pat[pi] != ']') {
                    var start_c = pat[pi];
                    if (start_c == '\\' and pi + 1 < pat.len) {
                        pi += 1;
                        start_c = pat[pi];
                    }
                    var end_c = start_c;
                    if (pi + 2 < pat.len and pat[pi + 1] == '-' and pat[pi + 2] != ']') {
                        end_c = pat[pi + 2];
                        pi += 3;
                    } else {
                        pi += 1;
                    }
                    if (s[si] >= start_c and s[si] <= end_c) matched = true;
                }
                if (pi < pat.len and pat[pi] == ']') pi += 1;
                if (matched == negate) return false;
                si += 1;
            },
            '\\' => {
                if (pi + 1 >= pat.len) return false;
                pi += 1;
                if (si >= s.len or s[si] != pat[pi]) return false;
                pi += 1;
                si += 1;
            },
            else => {
                if (si >= s.len or s[si] != c) return false;
                pi += 1;
                si += 1;
            },
        }
    }
    return si == s.len;
}


// ─── tests ────────────────────────────────────────────────────────────

const testing = std.testing;
const test_h = @import("../../test_helpers.zig");

test "find globMatch: literal + wildcard" {
    try testing.expect(globMatch("foo", "foo"));
    try testing.expect(!globMatch("foo", "bar"));
    try testing.expect(globMatch("*.zig", "x.zig"));
    try testing.expect(!globMatch("*.zig", "x.c"));
    try testing.expect(globMatch("src/*.zig", "src/a.zig"));
    try testing.expect(!globMatch("src/*.zig", "src/sub/a.zig"));
    try testing.expect(globMatch("src/**/*.zig", "src/sub/a.zig"));
    try testing.expect(globMatch("**/*.zig", "a/b/c.zig"));
    try testing.expect(globMatch("f?o", "foo"));
    try testing.expect(!globMatch("f?o", "foxo"));
    try testing.expect(globMatch("[abc].txt", "a.txt"));
    try testing.expect(globMatch("[abc].txt", "c.txt"));
    try testing.expect(!globMatch("[abc].txt", "d.txt"));
    try testing.expect(globMatch("[a-z].txt", "m.txt"));
    try testing.expect(!globMatch("[!a-z].txt", "m.txt"));
}

test "find anyMatch: multiple patterns" {
    try testing.expect(anyMatch(&.{ "*.zig", "*.md" }, "foo.zig"));
    try testing.expect(anyMatch(&.{ "*.zig", "*.md" }, "foo.md"));
    try testing.expect(!anyMatch(&.{ "*.zig", "*.md" }, "foo.c"));
    try testing.expect(anyMatch(&.{ "**/*.zig", "**/*.md" }, "src/foo.zig"));
    try testing.expect(anyMatch(&.{ "**/*.zig", "**/*.md" }, "readme.md"));
    try testing.expect(!anyMatch(&.{ "**/*.zig", "**/*.md" }, "src/foo.c"));
}

test "find extractPatterns: string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const json = try std.json.parseFromSlice(std.json.Value, arena.allocator(),
        \\{"pattern": "*.zig"}
    , .{});
    const pats = try extractPatterns(arena.allocator(), json.value.object);
    try testing.expectEqual(@as(usize, 1), pats.len);
    try testing.expectEqualStrings("*.zig", pats[0]);
}

test "find extractPatterns: array" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const json = try std.json.parseFromSlice(std.json.Value, arena.allocator(),
        \\{"pattern": ["*.zig", "*.md"]}
    , .{});
    const pats = try extractPatterns(arena.allocator(), json.value.object);
    try testing.expectEqual(@as(usize, 2), pats.len);
    try testing.expectEqualStrings("*.zig", pats[0]);
    try testing.expectEqualStrings("*.md", pats[1]);
}

test "find extractPatterns: empty string returns empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const json = try std.json.parseFromSlice(std.json.Value, arena.allocator(),
        \\{"pattern": ""}
    , .{});
    const pats = try extractPatterns(arena.allocator(), json.value.object);
    try testing.expectEqual(@as(usize, 1), pats.len);
    try testing.expectEqualStrings("", pats[0]);
}

test "find extractPatterns: missing key returns empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const json = try std.json.parseFromSlice(std.json.Value, arena.allocator(),
        \\{}
    , .{});
    const pats = try extractPatterns(arena.allocator(), json.value.object);
    try testing.expectEqual(@as(usize, 0), pats.len);
}

test "find tool: returns matching files" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_find_test";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};

    try std.Io.Dir.cwd().createDirPath(io, base ++ "/sub");
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/alpha.zig", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "x");
    }
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/sub/beta.zig", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "y");
    }
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/sub/beta.c", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "z");
    }

    var cancel: ai.stream.Cancel = .{};
    var res = try findMatches(gpa, io, base, &.{"**/*.zig"}, 100, false, &cancel);
    defer res.deinit(gpa);
    const text = res.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, text, "alpha.zig") != null);
    try testing.expect(std.mem.indexOf(u8, text, "beta.zig") != null);
    try testing.expect(std.mem.indexOf(u8, text, "beta.c") == null);
}

test "find tool: hard-skips .git directory regardless of respectGitignore" {
    // `.git` is git's internal data store, not source — it's a
    // special directory git manages, never matched by `.gitignore`.
    // Without this hard-skip, a broad glob from repo root pulls in
    // thousands of object hashes and derails the LLM's context.
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_find_dot_git_test";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};

    try std.Io.Dir.cwd().createDirPath(io, base ++ "/.git/objects/ab");
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/.git/config", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "");
    }
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/.git/objects/ab/cdef", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "");
    }
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/src.zig", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "x");
    }

    // respect_gitignore=false intentionally — proves the .git skip is
    // independent of gitignore handling.
    var cancel: ai.stream.Cancel = .{};
    var res = try findMatches(gpa, io, base, &.{"**/*"}, 100, false, &cancel);
    defer res.deinit(gpa);
    const text = res.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, text, "src.zig") != null);
    try testing.expect(std.mem.indexOf(u8, text, ".git/config") == null);
    try testing.expect(std.mem.indexOf(u8, text, ".git/objects/ab/cdef") == null);
}

test "find tool: respectGitignore drops ignored matches" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_find_gi_test";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};

    try std.Io.Dir.cwd().createDirPath(io, base ++ "/build");
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/.gitignore", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "build/\n*.tmp\n");
    }
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/src.zig", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "x");
    }
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/scratch.tmp", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "x");
    }
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/build/cache.zig", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "x");
    }

    var cancel: ai.stream.Cancel = .{};
    var res = try findMatches(gpa, io, base, &.{"**/*"}, 100, true, &cancel);
    defer res.deinit(gpa);
    const text = res.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, text, "src.zig") != null);
    try testing.expect(std.mem.indexOf(u8, text, "scratch.tmp") == null);
    try testing.expect(std.mem.indexOf(u8, text, "cache.zig") == null);
    try testing.expect(std.mem.indexOf(u8, text, ".gitignore") != null);
}

test "find tool: .contextignore is enforced unconditionally (§6.9)" {
    // Pin the §6.9 contract: contextignored paths never appear in
    // `find` output. We pass `respect_gitignore=false` here so the
    // behaviour is observably independent of the gitignore stack.
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_find_contextignore_test";
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
        try f.writeStreamingAll(io, "x");
    }
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/frozen.md", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "x");
    }
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/archive/old.md", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "x");
    }

    var cancel: ai.stream.Cancel = .{};
    var res = try findMatches(gpa, io, base, &.{"**/*"}, 100, false, &cancel);
    defer res.deinit(gpa);
    const text = res.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, text, "current.md") != null);
    try testing.expect(std.mem.indexOf(u8, text, "frozen.md") == null);
    try testing.expect(std.mem.indexOf(u8, text, "archive/old.md") == null);
}

test "find tool: multi-pattern with array" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_find_multi_test";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};

    try std.Io.Dir.cwd().createDirPath(io, base ++ "/sub");
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/alpha.zig", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "x");
    }
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/readme.md", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "x");
    }
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/sub/beta.zig", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "x");
    }
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/sub/beta.c", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "z");
    }

    var cancel: ai.stream.Cancel = .{};
    // Match both .zig and .md files
    var res = try findMatches(gpa, io, base, &.{ "**/*.zig", "**/*.md" }, 100, false, &cancel);
    defer res.deinit(gpa);
    const text = res.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, text, "alpha.zig") != null);
    try testing.expect(std.mem.indexOf(u8, text, "readme.md") != null);
    try testing.expect(std.mem.indexOf(u8, text, "beta.zig") != null);
    try testing.expect(std.mem.indexOf(u8, text, "beta.c") == null);
}