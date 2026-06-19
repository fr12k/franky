//! read tool — §C.1 of the spec.
//!
//! Schema: `{path, offset?, limit?}` where `path` is a string or an array of up to 10 strings (batch read).
//! Output: text prefixed with line numbers in the format `{N:>6}\t{line}`.
//! Files > 256 KB without explicit `limit` return a truncation error.
//! Binary files (NUL byte in first 8 KB) return `read_binary`.

const std = @import("std");
const ct = @import("../types.zig");
const at = ct.agent.types;
const ai = ct.ai;
const workspace_mod = @import("workspace.zig");
const common = @import("common.zig");
const truncate_mod = @import("truncate.zig");
const ls_mod = @import("ls.zig");

pub const max_paths: usize = 10;
pub const parameters_json: []const u8 =
    \\{
    \\  "type": "object",
    \\  "required": ["path"],
    \\  "properties": {
    \\    "path": {
    \\      "oneOf": [
    \\        {"type": "string"},
    \\        {"type": "array", "items": {"type": "string"}, "minItems": 1, "maxItems": 10}
    \\      ]
    \\    },
    \\    "offset": {"type": "integer", "minimum": 1},
    \\    "limit": {"type": "integer", "minimum": 1}
    \\  },
    \\  "additionalProperties": false
    \\}
;

pub const max_bytes_without_limit: usize = 256 * 1024;
pub const default_limit: usize = 2000;
pub const binary_sniff_bytes: usize = 8 * 1024;

/// v1.19.0 — opt-in ctx for the read tool, used by callers that
/// want to feed in the settings-layer overlay alongside workspace
/// scope. The legacy `tool()` and `toolWithWorkspace(ws)` factories
/// remain — they don't carry the overlay (use module-level default).
pub const ReadCtx = struct {
    workspace: ?*const workspace_mod.Workspace = null,
    /// `tools.read.maxBytes` from settings.json. null = no override.
    max_bytes_without_limit_override: ?usize = null,

    pub fn effectiveMaxBytes(self: *const ReadCtx) usize {
        return self.max_bytes_without_limit_override orelse max_bytes_without_limit;
    }
};

pub fn tool() at.AgentTool {
    return .{
        .name = "read",
        .description = "Read file(s) from the workspace. `path` can be a string or an array of up to 10 strings. Files >256 KB without `limit` are refused — paginate with `offset`+`limit` (default limit emits up to 2000 lines and a continuation hint).",
        .parameters_json = parameters_json,
        .execution_mode = .parallel,
        .execute = execute,
    };
}

/// Variant that enforces §R.1-§R.4 workspace-scope checks: every
/// path is canonicalized via `path_safety` before the file is
/// opened.
pub fn toolWithWorkspace(ws: *const workspace_mod.Workspace) at.AgentTool {
    return .{
        .name = "read",
        .description = "Read file(s) from the workspace (path-safety enforced). `path` can be a string or an array of up to 10 strings. Files >256 KB without `limit` are refused — paginate with `offset`+`limit` (default limit emits up to 2000 lines and a continuation hint).",
        .parameters_json = parameters_json,
        .execution_mode = .parallel,
        .ctx = @constCast(@ptrCast(ws)),
        .execute = execute,
    };
}

/// v1.19.0 — workspace + settings-layer overlay variant. When a
/// settings.json defines `tools.read.maxBytes`, callers wire it
/// through `ReadCtx`; per-call `limit` arg always wins.
pub fn toolWithCtx(ctx: *const ReadCtx) at.AgentTool {
    return .{
        .name = "read",
        .description = "Read file(s) from the workspace (path-safety + max-bytes overlay). `path` can be a string or an array of up to 10 strings. Files over the cap without `limit` are refused — paginate with `offset`+`limit`.",
        .parameters_json = parameters_json,
        .execution_mode = .parallel,
        .ctx = @constCast(@ptrCast(ctx)),
        .execute = executeWithCtx,
    };
}

/// Resolve `path` from JSON: either a single string or an array
/// of up to `max_paths` strings. Returns owned slice (arena).
fn resolvePaths(allocator: std.mem.Allocator, val: std.json.Value) ![]const []const u8 {
    switch (val) {
        .string => |s| {
            const arr = try allocator.alloc([]const u8, 1);
            arr[0] = s;
            return arr;
        },
        .array => |arr| {
            if (arr.items.len > max_paths)
                return error.ToolError;
            const result = try allocator.alloc([]const u8, arr.items.len);
            for (arr.items, 0..) |item, i| {
                if (item != .string) return error.ToolError;
                result[i] = item.string;
            }
            return result;
        },
        else => {},
    }
    return allocator.alloc([]const u8, 0);
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
    _ = cancel;
    _ = on_update;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed = try common.parseToolArgs(arena.allocator(), args_json);
    const root = parsed.value;
    const path_val = root.object.get("path") orelse
        return common.toolError(allocator, "invalid_args", "missing path");
    const paths = try resolvePaths(arena.allocator(), path_val);
    if (paths.len == 0) return common.toolError(allocator, "invalid_args", "path must be a string or non-empty array");

    const offset: usize = if (root.object.get("offset")) |v| blk: {
        if (v == .integer and v.integer >= 1) break :blk @intCast(v.integer);
        break :blk 1;
    } else 1;
    const limit: ?usize = if (root.object.get("limit")) |v| blk: {
        if (v == .integer and v.integer >= 1) break :blk @as(?usize, @intCast(v.integer));
        break :blk null;
    } else null;

    return try readFiles(allocator, io, self.ctx, null, paths, offset, limit, max_bytes_without_limit);
}

/// Batch-read multiple paths. Single-path returns raw output; multi-path
/// prepends a `==== path ====` banner before each file.
fn readFiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    ctx: ?*anyopaque,
    read_ctx: ?*const ReadCtx,
    paths: []const []const u8,
    offset: usize,
    limit: ?usize,
    default_max_bytes: usize,
) !at.ToolResult {
    const max_bytes: usize = if (read_ctx) |r| r.effectiveMaxBytes() else default_max_bytes;

    if (paths.len == 1) {
        const user_path = paths[0];
        var canon_path: ?[]u8 = null;
        defer if (canon_path) |p| allocator.free(p);
        const effective_path: []const u8 = if (ctx) |raw| blk: {
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
        return try readFileWithCap(allocator, io, effective_path, offset, limit, max_bytes);
    }

    // Multi-path: try each file, collecting results with headers.
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    for (paths) |user_path| {
        const header = try std.fmt.allocPrint(allocator, "==== {s} ====\n", .{user_path});
        defer allocator.free(header);
        try out.appendSlice(allocator, header);

        var canon_path: ?[]u8 = null;
        defer if (canon_path) |p| allocator.free(p);

        const effective_path: []const u8 = if (ctx) |raw| blk: {
            const ws: *const workspace_mod.Workspace = @ptrCast(@alignCast(raw));
            const r = try workspace_mod.canonicalizeOrError(allocator, ws, user_path);
            switch (r) {
                .ok => |c| {
                    canon_path = c.abs;
                    if (try common.contextIgnoreError(allocator, io, ws, c.abs)) |_| {
                        const err_line = try std.fmt.allocPrint(allocator, "\n", .{});
                        defer allocator.free(err_line);
                        try out.appendSlice(allocator, err_line);
                        continue;
                    }
                    break :blk c.abs;
                },
                .err => |e| {
                    const err_line = try std.fmt.allocPrint(allocator, "error: {s}\n\n", .{e.message});
                    defer allocator.free(err_line);
                    try out.appendSlice(allocator, err_line);
                    continue;
                },
            }
        } else user_path;

        var result = readFileWithCap(allocator, io, effective_path, offset, limit, max_bytes) catch |err| {
            const err_line = try std.fmt.allocPrint(allocator, "error: {s}\n\n", .{@errorName(err)});
            defer allocator.free(err_line);
            try out.appendSlice(allocator, err_line);
            continue;
        };
        defer result.deinit(allocator);
        for (result.content) |cb| {
            if (cb == .text) {
                try out.appendSlice(allocator, cb.text.text);
            }
        }
        try out.appendSlice(allocator, "\n");
    }

    const owned_text = try allocator.dupe(u8, out.items);
    const arr = try allocator.alloc(ai.types.ContentBlock, 1);
    arr[0] = .{ .text = .{ .text = owned_text } };
    return .{ .content = arr };
}

fn executeWithCtx(
    self: *const at.AgentTool,
    allocator: std.mem.Allocator,
    io: std.Io,
    call_id: []const u8,
    args_json: []const u8,
    cancel: *ai.stream.Cancel,
    on_update: at.OnUpdate,
) anyerror!at.ToolResult {
    _ = call_id;
    _ = cancel;
    _ = on_update;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed = try common.parseToolArgs(arena.allocator(), args_json);
    const root = parsed.value;
    const path_val = root.object.get("path") orelse
        return common.toolError(allocator, "invalid_args", "missing path");
    const paths = try resolvePaths(arena.allocator(), path_val);
    if (paths.len == 0) return common.toolError(allocator, "invalid_args", "path must be a string or non-empty array");

    const offset: usize = if (root.object.get("offset")) |v| blk: {
        if (v == .integer and v.integer >= 1) break :blk @intCast(v.integer);
        break :blk 1;
    } else 1;
    const limit: ?usize = if (root.object.get("limit")) |v| blk: {
        if (v == .integer and v.integer >= 1) break :blk @as(?usize, @intCast(v.integer));
        break :blk null;
    } else null;

    const ctx: *const ReadCtx = @ptrCast(@alignCast(self.ctx.?));
    return try readFiles(allocator, io, @constCast(@ptrCast(ctx.workspace)), ctx, paths, offset, limit, max_bytes_without_limit);
}

pub fn readFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    offset: usize,
    limit: ?usize,
) !at.ToolResult {
    return try readFileWithCap(allocator, io, path, offset, limit, max_bytes_without_limit);
}

pub fn readFileWithCap(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    offset: usize,
    limit: ?usize,
    max_bytes_cap: usize,
) !at.ToolResult {
    const cwd = std.Io.Dir.cwd();

    // If the path is a directory, fall back to a flat ls rather than
    // returning an error. Some models (e.g. DeepSeek, Gemma) call read
    // on directory paths and expect a listing. Probing with openDir is
    // platform-safe: openFile on a directory succeeds on Linux but
    // fails at read time (pread returns EISDIR), so we check eagerly.
    if (cwd.openDir(io, path, .{})) |d| {
        var dir = d;
        dir.close(io);
        var cancel = ai.stream.Cancel{};
        return ls_mod.listPath(allocator, io, path, false, ls_mod.default_max_depth, false, &cancel);
    } else |_| {}

    var file = cwd.openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return common.toolError(allocator, "file_not_found", "file does not exist"),
        error.AccessDenied, error.PermissionDenied => return common.toolError(allocator, "access_denied", "cannot read file"),
        else => return common.toolError(allocator, "open_failed", @errorName(err)),
    };
    defer file.close(io);

    const len = file.length(io) catch |err|
        return common.toolError(allocator, "stat_failed", @errorName(err));
    if (limit == null and len > max_bytes_cap) {
        // v1.27.1 — actionable hint per pi-mono. Tells the model
        // exactly how to paginate AND a `bash sed | head -c` fallback
        // for the rare single-giant-line case (minified JSON, etc).
        const cap_size = try truncate_mod.formatSize(allocator, max_bytes_cap);
        defer allocator.free(cap_size);
        const file_size = try truncate_mod.formatSize(allocator, @intCast(len));
        defer allocator.free(file_size);
        const msg = try std.fmt.allocPrint(
            allocator,
            "file is {s} (exceeds {s} without-limit cap). Use `offset`+`limit` to paginate, " ++
                "or `bash sed -n '1,Np' {s} | head -c {d}` to inspect a chunk.",
            .{ file_size, cap_size, path, max_bytes_cap },
        );
        defer allocator.free(msg);
        return common.toolError(allocator, "read_too_large", msg);
    }

    const buf = try allocator.alloc(u8, @intCast(len));
    defer allocator.free(buf);
    const n = file.readPositionalAll(io, buf, 0) catch |err|
        return common.toolError(allocator, "read_failed", @errorName(err));
    const bytes = buf[0..n];

    const sniff_len = @min(bytes.len, binary_sniff_bytes);
    if (std.mem.indexOfScalar(u8, bytes[0..sniff_len], 0) != null) {
        return common.toolError(allocator, "read_binary", "file appears to be binary");
    }

    // v1.27.1 — pi-mono first-line-too-big fallback. After loading
    // the file, check whether any of the first few requested lines
    // alone exceed `truncate.default_max_bytes` (50 KB). If so,
    // refuse with an actionable bash hint — the model needs a tool
    // that can chunk-read a single line, which is `bash sed`. Common
    // case: minified JSON dumps, single-line CSVs, generated lookup
    // tables. This check fires AFTER the file-size check so a
    // multi-line file under the file cap with one giant line at e.g.
    // line 42 is the only path that hits it.
    const effective_offset: usize = if (offset == 0) 1 else offset;
    if (firstLongLineWithin(bytes, effective_offset, limit orelse default_limit, truncate_mod.default_max_bytes)) |hit| {
        const cap_size = try truncate_mod.formatSize(allocator, truncate_mod.default_max_bytes);
        defer allocator.free(cap_size);
        const line_size = try truncate_mod.formatSize(allocator, hit.bytes);
        defer allocator.free(line_size);
        const msg = try std.fmt.allocPrint(
            allocator,
            "line {d} is {s} (exceeds {s} per-line cap). Use `bash sed -n '{d}p' {s} | head -c {d}` to inspect a chunk of it.",
            .{ hit.line_no, line_size, cap_size, hit.line_no, path, truncate_mod.default_max_bytes },
        );
        defer allocator.free(msg);
        return common.toolError(allocator, "read_line_too_large", msg);
    }

    return try formatLineNumbered(allocator, bytes, offset, limit orelse default_limit);
}

/// Returns the first line within `[offset, offset+limit)` whose byte
/// length exceeds `cap`. Lines are 1-indexed externally; offset=0
/// is treated as 1 (the read tool's own normalization).
const LongLineHit = struct { line_no: usize, bytes: usize };

fn firstLongLineWithin(bytes: []const u8, offset: usize, limit: usize, cap: usize) ?LongLineHit {
    var line_no: usize = 1;
    var checked: usize = 0;
    var i: usize = 0;
    while (i < bytes.len and checked < limit) {
        const nl = std.mem.indexOfScalarPos(u8, bytes, i, '\n') orelse bytes.len;
        if (line_no >= offset) {
            const line_len = nl - i;
            if (line_len > cap) return .{ .line_no = line_no, .bytes = line_len };
            checked += 1;
        }
        if (nl == bytes.len) break;
        i = nl + 1;
        line_no += 1;
    }
    return null;
}

fn formatLineNumbered(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    offset: usize,
    limit: usize,
) !at.ToolResult {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    // First pass: count total lines so we can render an actionable
    // continuation hint when the limit truncates output. Cheap byte
    // scan — we already loaded the whole file into `bytes`.
    var total_lines: usize = 0;
    if (bytes.len > 0) {
        total_lines = 1;
        for (bytes) |c| if (c == '\n') {
            total_lines += 1;
        };
        // Trailing-newline files count as N lines, not N+1 (final
        // empty after the last `\n` is elided to match the
        // splitScalar(...).len convention pi-mono uses).
        if (bytes[bytes.len - 1] == '\n') total_lines -= 1;
    }

    var line_no: usize = 1;
    var emitted: usize = 0;
    var first_emitted_line: ?usize = null;
    var last_emitted_line: usize = 0;
    var i: usize = 0;
    while (i < bytes.len and emitted < limit) {
        const nl = std.mem.indexOfScalarPos(u8, bytes, i, '\n') orelse bytes.len;
        if (line_no >= offset) {
            const line = bytes[i..nl];
            const chunk = try std.fmt.allocPrint(allocator, "{d:>6}\t{s}\n", .{ line_no, line });
            defer allocator.free(chunk);
            try out.appendSlice(allocator, chunk);
            if (first_emitted_line == null) first_emitted_line = line_no;
            last_emitted_line = line_no;
            emitted += 1;
        }
        if (nl == bytes.len) break;
        i = nl + 1;
        line_no += 1;
    }

    // v1.28.0 — append a continuation hint when the limit truncated
    // output and there are still lines past `last_emitted_line`.
    // Pi-mono pattern: the model needs to know both that more
    // exists AND the exact `offset` value to read next so it can
    // paginate without guessing. The hint never fires when the
    // file ended naturally within the limit.
    if (emitted == limit and last_emitted_line < total_lines) {
        const start = first_emitted_line orelse offset;
        const next_offset = last_emitted_line + 1;
        const hint = try std.fmt.allocPrint(
            allocator,
            "\n[Showing lines {d}-{d} of {d}. Use offset={d} to continue.]\n",
            .{ start, last_emitted_line, total_lines, next_offset },
        );
        defer allocator.free(hint);
        try out.appendSlice(allocator, hint);
    }

    const owned_text = try allocator.dupe(u8, out.items);
    const arr = try allocator.alloc(ai.types.ContentBlock, 1);
    arr[0] = .{ .text = .{ .text = owned_text } };
    return .{ .content = arr };
}


// ─── tests ────────────────────────────────────────────────────────────

const testing = std.testing;
const test_h = @import("../../test_helpers.zig");

fn writeTempFile(io: std.Io, path: []const u8, bytes: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    var f = try cwd.createFile(io, path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, bytes);
}

fn deleteTempFile(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

test "read tool returns line-numbered output" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const gpa = testing.allocator;
    const tmp_path = "/tmp/franky_read_test.txt";
    try writeTempFile(io, tmp_path, "alpha\nbeta\ngamma\n");
    defer deleteTempFile(io, tmp_path);

    var res = try readFile(gpa, io, tmp_path, 1, null);
    defer res.deinit(gpa);
    try testing.expect(!res.is_error);
    const got = res.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, got, "     1\talpha") != null);
    try testing.expect(std.mem.indexOf(u8, got, "     2\tbeta") != null);
    try testing.expect(std.mem.indexOf(u8, got, "     3\tgamma") != null);
}

test "read tool refuses binary files" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const gpa = testing.allocator;
    const tmp_path = "/tmp/franky_read_binary.bin";
    try writeTempFile(io, tmp_path, "\x00\x01\x02abc");
    defer deleteTempFile(io, tmp_path);

    var res = try readFile(gpa, io, tmp_path, 1, null);
    defer res.deinit(gpa);
    try testing.expect(res.is_error);
    try testing.expect(std.mem.indexOf(u8, res.content[0].text.text, "read_binary") != null);
}

test "read tool honors offset and limit" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const gpa = testing.allocator;
    const tmp_path = "/tmp/franky_read_range.txt";

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var line: u32 = 1;
    var lb: [32]u8 = undefined;
    while (line <= 10) : (line += 1) {
        const s = try std.fmt.bufPrint(&lb, "line{d}\n", .{line});
        try buf.appendSlice(gpa, s);
    }
    try writeTempFile(io, tmp_path, buf.items);
    defer deleteTempFile(io, tmp_path);

    var res = try readFile(gpa, io, tmp_path, 3, 2);
    defer res.deinit(gpa);
    const text = res.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, text, "     3\tline3") != null);
    try testing.expect(std.mem.indexOf(u8, text, "     4\tline4") != null);
    try testing.expect(std.mem.indexOf(u8, text, "line5") == null);
}

test "read tool with workspace: rejects workspace escape" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    // Stage a file inside /tmp so we have something legal to read.
    const legal_path = "/tmp/franky_ws_legal.txt";
    std.Io.Dir.cwd().deleteFile(io, legal_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, legal_path) catch {};
    {
        var f = try std.Io.Dir.cwd().createFile(io, legal_path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "inside workspace\n");
    }

    var ws: workspace_mod.Workspace = .{ .root = "/tmp" };
    const t = toolWithWorkspace(&ws);
    var cancel = ai.stream.Cancel{};

    // Legal path → succeeds.
    {
        const args = try std.fmt.allocPrint(gpa, "{{\"path\":\"franky_ws_legal.txt\"}}", .{});
        defer gpa.free(args);
        var res = try t.execute(&t, gpa, io, "id1", args, &cancel, .{});
        defer res.deinit(gpa);
        try testing.expect(!res.is_error);
        try testing.expect(std.mem.indexOf(u8, res.content[0].text.text, "inside workspace") != null);
    }

    // Escape attempt → path_escape_workspace error.
    {
        var res = try t.execute(&t, gpa, io, "id2", "{\"path\":\"/etc/passwd\"}", &cancel, .{});
        defer res.deinit(gpa);
        try testing.expect(res.is_error);
        try testing.expect(std.mem.indexOf(u8, res.content[0].text.text, "path_escape_workspace") != null);
    }
}

test "read tool: refuses contextignored path with structured error (§6.9)" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const ws_root = "/tmp/franky_read_contextignore";
    _ = std.Io.Dir.cwd().deleteTree(io, ws_root) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, ws_root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, ws_root);

    // `.contextignore` blocks `archived.md`; `current.md` stays readable.
    {
        var f = try std.Io.Dir.cwd().createFile(io, ws_root ++ "/.contextignore", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "archived.md\n");
    }
    {
        var f = try std.Io.Dir.cwd().createFile(io, ws_root ++ "/archived.md", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "secret history\n");
    }
    {
        var f = try std.Io.Dir.cwd().createFile(io, ws_root ++ "/current.md", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "live notes\n");
    }

    var ws: workspace_mod.Workspace = .{ .root = ws_root };
    const t = toolWithWorkspace(&ws);
    var cancel = ai.stream.Cancel{};

    // Contextignored path → structured `contextignored` error.
    {
        var res = try t.execute(&t, gpa, io, "id1", "{\"path\":\"archived.md\"}", &cancel, .{});
        defer res.deinit(gpa);
        try testing.expect(res.is_error);
        try testing.expect(res.tool_code != null);
        try testing.expectEqualStrings(common.tool_code_contextignored, res.tool_code.?);
        // The model should never see the file's contents in the error.
        try testing.expect(std.mem.indexOf(u8, res.content[0].text.text, "secret history") == null);
    }

    // Allowed sibling still works.
    {
        var res = try t.execute(&t, gpa, io, "id2", "{\"path\":\"current.md\"}", &cancel, .{});
        defer res.deinit(gpa);
        try testing.expect(!res.is_error);
        try testing.expect(std.mem.indexOf(u8, res.content[0].text.text, "live notes") != null);
    }
}

// ─── v1.19.0 — ReadCtx + max_bytes overlay tests ────────────────────

test "ReadCtx.effectiveMaxBytes honors override" {
    var ctx: ReadCtx = .{};
    try testing.expectEqual(max_bytes_without_limit, ctx.effectiveMaxBytes());
    ctx.max_bytes_without_limit_override = 1024;
    try testing.expectEqual(@as(usize, 1024), ctx.effectiveMaxBytes());
}

test "toolWithCtx: max_bytes override caps without-limit reads tighter than module default" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    // 2048-byte file: above a 1024-byte cap, below the 256 KiB module default.
    const tmp_path = "/tmp/franky_read_overlay_cap.txt";
    var contents: [2048]u8 = undefined;
    @memset(&contents, 'x');
    try writeTempFile(io, tmp_path, &contents);
    defer deleteTempFile(io, tmp_path);

    var ctx: ReadCtx = .{ .max_bytes_without_limit_override = 1024 };
    const t = toolWithCtx(&ctx);
    var cancel = ai.stream.Cancel{};

    // No `limit` arg → tighter override hits → read_too_large.
    {
        var res = try t.execute(&t, gpa, io, "id1", "{\"path\":\"/tmp/franky_read_overlay_cap.txt\"}", &cancel, .{});
        defer res.deinit(gpa);
        try testing.expect(res.is_error);
        try testing.expect(std.mem.indexOf(u8, res.content[0].text.text, "read_too_large") != null);
    }
    // Explicit `limit` arg → cap is bypassed (per-call still wins).
    {
        var res = try t.execute(&t, gpa, io, "id2", "{\"path\":\"/tmp/franky_read_overlay_cap.txt\",\"limit\":10}", &cancel, .{});
        defer res.deinit(gpa);
        try testing.expect(!res.is_error);
    }
}

test "toolWithCtx: null override falls back to module default" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const tmp_path = "/tmp/franky_read_overlay_null.txt";
    try writeTempFile(io, tmp_path, "small\n");
    defer deleteTempFile(io, tmp_path);

    var ctx: ReadCtx = .{}; // no override; effective = 256 KiB
    const t = toolWithCtx(&ctx);
    var cancel = ai.stream.Cancel{};

    var res = try t.execute(&t, gpa, io, "id", "{\"path\":\"/tmp/franky_read_overlay_null.txt\"}", &cancel, .{});
    defer res.deinit(gpa);
    try testing.expect(!res.is_error);
}

test "read tool: read_too_large now embeds offset+limit + bash sed hint (v1.27.1)" {
    // Prior to v1.27.1 the message was just "file exceeds without-limit
    // cap" — non-actionable. The new message names the cap, the file
    // size, and tells the model how to paginate or shell out.
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;
    const tmp_path = "/tmp/franky_read_too_large.txt";
    defer deleteTempFile(io, tmp_path);

    // 300 KB file — over the 256 KB without-limit cap.
    const big = try gpa.alloc(u8, 300 * 1024);
    defer gpa.free(big);
    @memset(big, 'a');
    try writeTempFile(io, tmp_path, big);

    var res = try readFile(gpa, io, tmp_path, 1, null);
    defer res.deinit(gpa);
    try testing.expect(res.is_error);
    const txt = res.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, txt, "read_too_large") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "offset") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "bash sed -n") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "head -c") != null);
}

test "read tool: rejects single line larger than per-line cap with bash hint (v1.27.1)" {
    // Multi-line file under the file cap, but one line at line 3 is
    // 60 KB — over the 50 KB per-line cap. With limit=10 we'd
    // otherwise emit that whole line into context. v1.27.1 refuses
    // with `read_line_too_large` and a `sed -n 'Np' file | head -c …`
    // hint.
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;
    const tmp_path = "/tmp/franky_read_long_line.txt";
    defer deleteTempFile(io, tmp_path);

    var contents: std.ArrayList(u8) = .empty;
    defer contents.deinit(gpa);
    try contents.appendSlice(gpa, "first\nsecond\n");
    // 60 KB single line as line 3.
    const long = try gpa.alloc(u8, 60 * 1024);
    defer gpa.free(long);
    @memset(long, 'x');
    try contents.appendSlice(gpa, long);
    try contents.append(gpa, '\n');
    try contents.appendSlice(gpa, "fourth\n");
    try writeTempFile(io, tmp_path, contents.items);

    // Use limit=10 so we'd otherwise pull line 3 into context.
    var res = try readFile(gpa, io, tmp_path, 1, 10);
    defer res.deinit(gpa);
    try testing.expect(res.is_error);
    const txt = res.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, txt, "read_line_too_large") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "line 3") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "bash sed -n '3p'") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "head -c") != null);
}

test "read tool: per-line cap doesn't fire when offset skips the long line (v1.27.1)" {
    // Same fixture, but offset=4 so we skip the giant line entirely.
    // Read should succeed and return only line 4 ("fourth").
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;
    const tmp_path = "/tmp/franky_read_long_line_skip.txt";
    defer deleteTempFile(io, tmp_path);

    var contents: std.ArrayList(u8) = .empty;
    defer contents.deinit(gpa);
    try contents.appendSlice(gpa, "first\nsecond\n");
    const long = try gpa.alloc(u8, 60 * 1024);
    defer gpa.free(long);
    @memset(long, 'x');
    try contents.appendSlice(gpa, long);
    try contents.append(gpa, '\n');
    try contents.appendSlice(gpa, "fourth\n");
    try writeTempFile(io, tmp_path, contents.items);

    var res = try readFile(gpa, io, tmp_path, 4, 10);
    defer res.deinit(gpa);
    try testing.expect(!res.is_error);
    const txt = res.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, txt, "fourth") != null);
}

test "read tool: line-cap truncation appends [Showing lines X-Y of Z. Use offset=N+1] hint (v1.28.0)" {
    // 50-line file, read with limit=10 → emits lines 1-10, then a
    // continuation hint pointing at offset=11 (so the model can
    // paginate without guessing).
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;
    const tmp_path = "/tmp/franky_read_continuation_hint.txt";
    defer deleteTempFile(io, tmp_path);

    var contents: std.ArrayList(u8) = .empty;
    defer contents.deinit(gpa);
    var i: usize = 1;
    while (i <= 50) : (i += 1) {
        const ln = try std.fmt.allocPrint(gpa, "line-{d:0>2}\n", .{i});
        defer gpa.free(ln);
        try contents.appendSlice(gpa, ln);
    }
    try writeTempFile(io, tmp_path, contents.items);

    var res = try readFile(gpa, io, tmp_path, 1, 10);
    defer res.deinit(gpa);
    try testing.expect(!res.is_error);
    const txt = res.content[0].text.text;
    // First and last visible lines are present.
    try testing.expect(std.mem.indexOf(u8, txt, "line-01") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "line-10") != null);
    // Past-the-cap line is NOT in the visible body.
    try testing.expect(std.mem.indexOf(u8, txt, "line-11") == null);
    // Continuation hint with the right offset.
    try testing.expect(std.mem.indexOf(u8, txt, "[Showing lines 1-10 of 50") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "Use offset=11 to continue") != null);
}

test "read tool: directory path falls back to ls output" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const tmp_dir = "/tmp/franky_read_dir_test";
    _ = std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, tmp_dir);
    {
        var f = try std.Io.Dir.cwd().createFile(io, tmp_dir ++ "/hello.txt", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "hi\n");
    }

    var res = try readFile(gpa, io, tmp_dir, 1, null);
    defer res.deinit(gpa);
    try testing.expect(!res.is_error);
    try testing.expect(std.mem.indexOf(u8, res.content[0].text.text, "hello.txt") != null);
}

test "read tool: continuation hint does NOT fire when file ends within the limit (v1.28.0)" {
    // 5-line file, limit=10 → no hint; we got everything.
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;
    const tmp_path = "/tmp/franky_read_continuation_no_hint.txt";
    defer deleteTempFile(io, tmp_path);

    try writeTempFile(io, tmp_path, "a\nb\nc\nd\ne\n");

    var res = try readFile(gpa, io, tmp_path, 1, 10);
    defer res.deinit(gpa);
    try testing.expect(!res.is_error);
    const txt = res.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, txt, "Use offset=") == null);
    try testing.expect(std.mem.indexOf(u8, txt, "[Showing lines") == null);
}

test "read tool: continuation hint with offset > 1 reports correct visible range (v1.28.0)" {
    // 30-line file, read with offset=11, limit=10 → emits 11-20,
    // hint points at offset=21.
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;
    const tmp_path = "/tmp/franky_read_continuation_mid.txt";
    defer deleteTempFile(io, tmp_path);

    var contents: std.ArrayList(u8) = .empty;
    defer contents.deinit(gpa);
    var i: usize = 1;
    while (i <= 30) : (i += 1) {
        const ln = try std.fmt.allocPrint(gpa, "L{d}\n", .{i});
        defer gpa.free(ln);
        try contents.appendSlice(gpa, ln);
    }
    try writeTempFile(io, tmp_path, contents.items);

    var res = try readFile(gpa, io, tmp_path, 11, 10);
    defer res.deinit(gpa);
    try testing.expect(!res.is_error);
    const txt = res.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, txt, "[Showing lines 11-20 of 30") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "Use offset=21 to continue") != null);
}
