//! ls tool — §C.5 of the spec.
//!
//! Schema: `{path?, recursive?, maxDepth?, respectGitignore?}`.
//! Output: one entry per line, indented by depth, with a `/` suffix on
//! directories. Symlinks get a `@` suffix.
//!
//! When `recursive=false` (default), lists one level. When `true`, uses
//! `Io.Dir.walk` with a depth cap.
//!
//! `respectGitignore` (default `true`): load every `.gitignore` in the
//! scanned subtree via `coding/gitignore.zig` and drop ignored entries.
//! Recursive walks also prune ignored directories so we don't descend
//! into them. Pass `respectGitignore=false` to force the full listing.

const std = @import("std");
const ct = @import("../types.zig");
const at = ct.agent.types;
const ai = ct.ai;
const workspace_mod = @import("workspace.zig");
const gitignore = @import("../gitignore.zig");
const common = @import("common.zig");

pub const parameters_json: []const u8 =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "path": {"type": "string", "description": "Directory to list. Defaults to the agent's cwd."},
    \\    "recursive": {"type": "boolean", "description": "Recurse into subdirectories. Default false."},
    \\    "maxDepth": {"type": "integer", "minimum": 1, "description": "Maximum depth when recursive is true. Default 8."},
    \\    "respectGitignore": {"type": "boolean", "description": "Respect .gitignore rules under the scanned path. Default true."}
    \\  },
    \\  "additionalProperties": false
    \\}
;

pub const default_max_depth: usize = 8;
pub const max_entries: usize = 5_000;

pub fn tool() at.AgentTool {
    return .{
        .name = "ls",
        .description = "List directory entries (tree-style when recursive). Recursive=true with no focused `path` walks the whole tree — pass a specific subdir first.",
        .parameters_json = parameters_json,
        .execution_mode = .parallel,
        .execute = execute,
    };
}

pub fn toolWithWorkspace(ws: *const workspace_mod.Workspace) at.AgentTool {
    return .{
        .name = "ls",
        .description = "List directory entries (path-safety enforced). Pass a focused `path` before using `recursive=true`.",
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

    const parsed = try common.parseToolArgs(arena.allocator(), args_json);
    const root = parsed.value;

    const user_path: []const u8 = if (root.object.get("path")) |v|
        (if (v == .string) v.string else ".")
    else
        ".";
    const recursive: bool = if (root.object.get("recursive")) |v|
        (v == .bool and v.bool)
    else
        false;
    const max_depth: usize = if (root.object.get("maxDepth")) |v| blk: {
        if (v == .integer and v.integer >= 1) break :blk @intCast(v.integer);
        break :blk default_max_depth;
    } else default_max_depth;
    const respect_gitignore: bool = if (root.object.get("respectGitignore")) |v|
        (v != .bool or v.bool)
    else
        true;

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

    return try listPath(allocator, io, path, recursive, max_depth, respect_gitignore, cancel);
}

pub fn listPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    recursive: bool,
    max_depth: usize,
    respect_gitignore: bool,
    cancel: *ai.stream.Cancel,
) !at.ToolResult {
    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return common.toolError(allocator, "file_not_found", path),
        error.NotDir => return common.toolError(allocator, "not_a_directory", path),
        error.AccessDenied, error.PermissionDenied => return common.toolError(allocator, "access_denied", path),
        else => return common.toolError(allocator, "open_failed", @errorName(err)),
    };
    defer dir.close(io);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try out.appendSlice(allocator, path);
    try out.append(allocator, '\n');

    // Load `.gitignore` (gated by `respect_gitignore`) and
    // `.contextignore` (§6.9 — always on) up front. See
    // `gitignore.loadIgnoreStacks` for the contract.
    var stacks = gitignore.loadIgnoreStacks(allocator, io, path, respect_gitignore);
    defer stacks.deinit();

    var count: usize = 0;

    if (!recursive) {
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (cancel.isFired()) return common.toolError(allocator, "aborted", "cancelled");
            if (count >= max_entries) {
                try out.appendSlice(allocator, "(truncated: too many entries)\n");
                break;
            }
            // Hard-skip the `.git` directory regardless of `.gitignore`
            // contents. Git's internal data store isn't tracked-or-ignored
            // (it's a special directory git manages), so even with
            // `respectGitignore=true` it would otherwise show up. No
            // legitimate ls result lives in there for an LLM agent.
            if (std.mem.eql(u8, entry.name, ".git")) continue;
            if (stacks.isIgnored(entry.name, entry.kind == .directory)) continue;
            try appendEntry(&out, allocator, 0, entry.name, entry.kind);
            count += 1;
        }
    } else {
        var walker = try dir.walk(allocator);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (cancel.isFired()) return common.toolError(allocator, "aborted", "cancelled");
            const depth = entry.depth();
            if (depth >= max_depth) continue;
            if (count >= max_entries) {
                try out.appendSlice(allocator, "(truncated: too many entries)\n");
                break;
            }
            // Hard-skip `.git` (and its subtree) regardless of
            // `.gitignore`. See note in the non-recursive branch.
            if (std.mem.eql(u8, entry.path, ".git") or std.mem.startsWith(u8, entry.path, ".git/")) continue;
            if (stacks.isIgnored(entry.path, entry.kind == .directory)) continue;
            try appendEntry(&out, allocator, depth, entry.path, entry.kind);
            count += 1;
        }
    }

    const text = try allocator.dupe(u8, out.items);
    const arr = try allocator.alloc(ai.types.ContentBlock, 1);
    arr[0] = .{ .text = .{ .text = text } };
    return .{ .content = arr };
}

fn appendEntry(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    depth: usize,
    name: []const u8,
    kind: std.Io.File.Kind,
) !void {
    var d: usize = 0;
    while (d < depth) : (d += 1) try out.appendSlice(allocator, "  ");
    try out.appendSlice(allocator, name);
    switch (kind) {
        .directory => try out.append(allocator, '/'),
        .sym_link => try out.append(allocator, '@'),
        else => {},
    }
    try out.append(allocator, '\n');
}


// ─── tests ────────────────────────────────────────────────────────────

const testing = std.testing;
const test_h = @import("../../test_helpers.zig");

test "ls tool: non-recursive lists entries" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_ls_test";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};

    try std.Io.Dir.cwd().createDirPath(io, base);
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/a.txt", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "hello");
    }
    try std.Io.Dir.cwd().createDirPath(io, base ++ "/sub");

    var cancel: ai.stream.Cancel = .{};
    var res = try listPath(gpa, io, base, false, 4, false, &cancel);
    defer res.deinit(gpa);
    try testing.expect(!res.is_error);
    const text = res.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, text, "a.txt") != null);
    try testing.expect(std.mem.indexOf(u8, text, "sub/") != null);
}

test "ls tool: recursive walks with depth cap" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_ls_rec_test";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};

    try std.Io.Dir.cwd().createDirPath(io, base ++ "/a/b/c");
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/a/b/c/deep.txt", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "x");
    }

    var cancel: ai.stream.Cancel = .{};
    var res = try listPath(gpa, io, base, true, 10, false, &cancel);
    defer res.deinit(gpa);
    try testing.expect(std.mem.indexOf(u8, res.content[0].text.text, "deep.txt") != null);
}

test "ls tool: reports file_not_found" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var cancel: ai.stream.Cancel = .{};
    var res = try listPath(gpa, io, "/tmp/does-not-exist-franky-xyz", false, 4, false, &cancel);
    defer res.deinit(gpa);
    try testing.expect(res.is_error);
    try testing.expect(std.mem.indexOf(u8, res.content[0].text.text, "file_not_found") != null);
    // v1.7.1 — §F.2: tool_code now also surfaces as a structured field.
    try testing.expect(res.tool_code != null);
    try testing.expectEqualStrings("file_not_found", res.tool_code.?);
}

test "ls tool: respectGitignore skips ignored entries" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_ls_gi_test";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};

    try std.Io.Dir.cwd().createDirPath(io, base ++ "/build");
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/.gitignore", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "*.log\nbuild/\n");
    }
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/foo.zig", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "x");
    }
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/debug.log", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "x");
    }
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/build/out.o", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "x");
    }

    var cancel: ai.stream.Cancel = .{};
    var res = try listPath(gpa, io, base, true, 10, true, &cancel);
    defer res.deinit(gpa);
    const text = res.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, text, "foo.zig") != null);
    try testing.expect(std.mem.indexOf(u8, text, "debug.log") == null);
    try testing.expect(std.mem.indexOf(u8, text, "build/") == null);
    try testing.expect(std.mem.indexOf(u8, text, "out.o") == null);
}

test "ls tool: hard-skips .git directory regardless of respectGitignore" {
    // `.git` is git's internal data store, not source — it's a
    // special directory git manages, never matched by `.gitignore`.
    // Without this hard-skip, a recursive ls from repo root pulls in
    // thousands of object hashes and derails the LLM's context.
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_ls_dot_git_test";
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
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/foo.zig", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "x");
    }

    // respect_gitignore=false intentionally — proves the .git skip is
    // independent of gitignore handling.
    var cancel: ai.stream.Cancel = .{};

    // Recursive: must skip the entire .git subtree.
    var res_rec = try listPath(gpa, io, base, true, 10, false, &cancel);
    defer res_rec.deinit(gpa);
    const text_rec = res_rec.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, text_rec, "foo.zig") != null);
    try testing.expect(std.mem.indexOf(u8, text_rec, ".git") == null);
    try testing.expect(std.mem.indexOf(u8, text_rec, "config") == null);
    try testing.expect(std.mem.indexOf(u8, text_rec, "objects") == null);
    try testing.expect(std.mem.indexOf(u8, text_rec, "abcdef") == null);

    // Non-recursive: must skip the top-level .git entry too.
    var res_flat = try listPath(gpa, io, base, false, 1, false, &cancel);
    defer res_flat.deinit(gpa);
    const text_flat = res_flat.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, text_flat, "foo.zig") != null);
    try testing.expect(std.mem.indexOf(u8, text_flat, ".git") == null);
}

test "ls tool: .contextignore is enforced unconditionally (§6.9)" {
    // Pin the §6.9 contract: `.contextignore` paths are hidden from `ls`
    // regardless of any argument the model passes. We run with
    // `respect_gitignore=false` so contextignore behavior is observably
    // independent of the gitignore stack.
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_ls_contextignore_test";
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

    // Recursive listing — gitignore disabled, contextignore still applies.
    var res_rec = try listPath(gpa, io, base, true, 10, false, &cancel);
    defer res_rec.deinit(gpa);
    const text_rec = res_rec.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, text_rec, "current.md") != null);
    try testing.expect(std.mem.indexOf(u8, text_rec, "frozen.md") == null);
    try testing.expect(std.mem.indexOf(u8, text_rec, "archive") == null);
    try testing.expect(std.mem.indexOf(u8, text_rec, "old.md") == null);

    // Non-recursive listing — same expectation at the top level.
    var res_flat = try listPath(gpa, io, base, false, 1, false, &cancel);
    defer res_flat.deinit(gpa);
    const text_flat = res_flat.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, text_flat, "current.md") != null);
    try testing.expect(std.mem.indexOf(u8, text_flat, "frozen.md") == null);
    try testing.expect(std.mem.indexOf(u8, text_flat, "archive") == null);
}

test "ls tool: respectGitignore=false preserves full listing" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_ls_gi_off_test";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};

    try std.Io.Dir.cwd().createDirPath(io, base);
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/.gitignore", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "*.log\n");
    }
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/debug.log", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "x");
    }

    var cancel: ai.stream.Cancel = .{};
    var res = try listPath(gpa, io, base, false, 4, false, &cancel);
    defer res.deinit(gpa);
    try testing.expect(std.mem.indexOf(u8, res.content[0].text.text, "debug.log") != null);
}
