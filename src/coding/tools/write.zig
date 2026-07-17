//! write tool — §C.2 of the spec.
//!
//! Schema: `{path, content, overwrite?}`. Creates parent directories as
//! needed. Refuses if the file exists and `overwrite` is false
//! (tool_code = `write_exists`). On success, `details` carries
//! `{bytesWritten, parentCreated}`.

const std = @import("std");
const ct = @import("../types.zig");
const at = ct.agent.types;
const ai = ct.ai;
const workspace_mod = @import("workspace.zig");
const common = @import("common.zig");

pub const parameters_json: []const u8 =
    \\{
    \\  "type": "object",
    \\  "required": ["path", "content"],
    \\  "properties": {
    \\    "path": {"type": "string"},
    \\    "content": {"type": "string"},
    \\    "overwrite": {"type": "boolean", "default": false}
    \\  },
    \\  "additionalProperties": false
    \\}
;

pub fn tool() at.AgentTool {
    return .{
        .name = "write",
        .description = "Create a new file with the given content.",
        .parameters_json = parameters_json,
        .execution_mode = .sequential,
        .skip_compression = true,
        .execute = execute,
    };
}

pub fn toolWithWorkspace(ws: *const workspace_mod.Workspace) at.AgentTool {
    return .{
        .name = "write",
        .description = "Create a new file with the given content (path-safety enforced).",
        .parameters_json = parameters_json,
        .execution_mode = .sequential,
        .skip_compression = true,
        .ctx = @constCast(@ptrCast(ws)),
        .execute = execute,
    };
}

fn execute(
    self: *const at.AgentTool,
    allocator: std.mem.Allocator,
    io: std.Io,
    _: []const u8,
    args_json: []const u8,
    _: *ai.stream.Cancel,
    _: at.OnUpdate,
) anyerror!at.ToolResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const json_to_parse = common.repairConcatJson(arena.allocator(), args_json) orelse args_json;
    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), json_to_parse, .{});
    const root = parsed.value;

    const user_path = (root.object.get("path") orelse return common.toolError(allocator, "invalid_args", "missing path")).string;
    const content = (root.object.get("content") orelse return common.toolError(allocator, "invalid_args", "missing content")).string;
    const overwrite: bool = if (root.object.get("overwrite")) |v| (v == .bool and v.bool) else false;

    var canon_path: ?[]u8 = null;
    defer if (canon_path) |p| allocator.free(p);
    const effective_path: []const u8 = if (self.ctx) |raw| blk: {
        const ws: *const workspace_mod.Workspace = @ptrCast(@alignCast(raw));
        const r = try workspace_mod.canonicalizeOrError(allocator, ws, user_path);
        switch (r) {
            .ok => |c| {
                canon_path = c.abs;
                if (try common.contextIgnoreError(allocator, io, ws, c.abs)) |err| return err;
                break :blk c.abs;
            },
            .err => |e| return common.toolError(allocator, e.code, e.message),
        }
    } else user_path;

    return try writeFile(allocator, io, effective_path, content, overwrite);
}

pub fn writeFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    content: []const u8,
    overwrite: bool,
) !at.ToolResult {
    const cwd = std.Io.Dir.cwd();

    // Check existence unless overwrite requested.
    if (!overwrite) {
        if (cwd.access(io, path, .{})) {
            return common.toolError(allocator, "write_exists", "file already exists; set overwrite=true to replace");
        } else |e| switch (e) {
            error.FileNotFound => {}, // expected
            else => return common.toolError(allocator, "access_failed", @errorName(e)),
        }
    }

    // Create parent dirs if missing.
    var parent_created = false;
    if (std.fs.path.dirname(path)) |parent| if (parent.len > 0) {
        if (cwd.access(io, parent, .{})) {
            // exists
        } else |e| switch (e) {
            error.FileNotFound => {
                cwd.createDirPath(io, parent) catch |err|
                    return common.toolError(allocator, "mkdir_failed", @errorName(err));
                parent_created = true;
            },
            else => return common.toolError(allocator, "access_failed", @errorName(e)),
        }
    };

    var file = cwd.createFile(io, path, .{}) catch |err|
        return common.toolError(allocator, "create_failed", @errorName(err));
    defer file.close(io);
    file.writeStreamingAll(io, content) catch |err|
        return common.toolError(allocator, "write_failed", @errorName(err));

    const details = try std.fmt.allocPrint(allocator, "{{\"bytesWritten\":{d},\"parentCreated\":{}}}", .{ content.len, parent_created });
    const text = try std.fmt.allocPrint(allocator, "wrote {d} bytes to {s}", .{ content.len, path });
    const arr = try allocator.alloc(ai.types.ContentBlock, 1);
    arr[0] = .{ .text = .{ .text = text } };
    return .{ .content = arr, .details_json = details };
}


// ─── tests ────────────────────────────────────────────────────────────

const testing = std.testing;
const test_h = @import("../../test_helpers.zig");

test "write creates a new file" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const gpa = testing.allocator;
    const tmp = "/tmp/franky_write_test.txt";
    std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, tmp) catch {};

    var res = try writeFile(gpa, io, tmp, "hello", false);
    defer res.deinit(gpa);
    try testing.expect(!res.is_error);
    try testing.expect(res.details_json != null);
}

test "write refuses to overwrite by default" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const gpa = testing.allocator;
    const tmp = "/tmp/franky_write_exists.txt";
    std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, tmp) catch {};

    var r1 = try writeFile(gpa, io, tmp, "first", false);
    r1.deinit(gpa);

    var r2 = try writeFile(gpa, io, tmp, "second", false);
    defer r2.deinit(gpa);
    try testing.expect(r2.is_error);
    try testing.expect(std.mem.indexOf(u8, r2.content[0].text.text, "write_exists") != null);
}

test "write overwrite=true replaces file" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const gpa = testing.allocator;
    const tmp = "/tmp/franky_write_over.txt";
    std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, tmp) catch {};

    var r1 = try writeFile(gpa, io, tmp, "first", false);
    r1.deinit(gpa);
    var r2 = try writeFile(gpa, io, tmp, "second", true);
    defer r2.deinit(gpa);
    try testing.expect(!r2.is_error);
}

test "write tool: refuses to create at contextignored path (§6.9)" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const ws_root = "/tmp/franky_write_contextignore";
    _ = std.Io.Dir.cwd().deleteTree(io, ws_root) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, ws_root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, ws_root);

    {
        var f = try std.Io.Dir.cwd().createFile(io, ws_root ++ "/.contextignore", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "archived/\n");
    }

    var ws: workspace_mod.Workspace = .{ .root = ws_root };
    const t = toolWithWorkspace(&ws);
    var cancel = ai.stream.Cancel{};

    // Writing under the ignored directory → structured refusal; nothing
    // hits disk.
    {
        var res = try t.execute(&t, gpa, io, "id1",
            "{\"path\":\"archived/note.md\",\"content\":\"x\"}", &cancel, .{});
        defer res.deinit(gpa);
        try testing.expect(res.is_error);
        try testing.expectEqualStrings(common.tool_code_contextignored, res.tool_code.?);
        // File must not have been created.
        const file_or_err = std.Io.Dir.cwd().openFile(io, ws_root ++ "/archived/note.md", .{});
        try testing.expectError(error.FileNotFound, file_or_err);
    }

    // Allowed sibling write still works.
    {
        var res = try t.execute(&t, gpa, io, "id2",
            "{\"path\":\"current.md\",\"content\":\"x\"}", &cancel, .{});
        defer res.deinit(gpa);
        try testing.expect(!res.is_error);
    }
}
