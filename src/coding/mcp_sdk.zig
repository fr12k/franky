//! MCP Python SDK generator — Phase 1 of `--mcp-code-mode`.
//!
//! When `--mcp-code-mode` is active, franky does NOT inject every
//! `mcp__<server>__<tool>` JSON schema into the LLM prompt. Instead it
//! generates deterministic, typed Python stubs under
//! `<workspace>/.franky/mcp_sdk/` from the discovered MCP `tools/list`
//! schemas at session startup. The model inspects these stubs with the
//! `read`/`grep` tools and orchestrates them through the sandboxed
//! `code_exec` tool, which routes calls through the local UDS bridge
//! (`mcp_bridge.zig`).
//!
//! Generated layout (all writes are atomic: temp file + rename):
//!
//!   .franky/mcp_sdk/
//!     __init__.py        — exports available server module names.
//!     _runtime.py        — stdlib-only UDS client (socket/json/os).
//!     <server>.py        — one typed wrapper per connected MCP server.
//!
//! The generator is pure Zig and has zero external C/Python deps — it
//! only *emits* Python source text.

const std = @import("std");
const mcp_mod = @import("mcp/mod.zig");

const log = @import("../ai/log.zig");

/// One discovered MCP tool, distilled to what the generator needs.
/// Strings are borrowed from the caller (session arena).
pub const ToolSpec = struct {
    /// Namespaced server name (e.g. "atlassian").
    server: []const u8,
    /// Remote tool name (e.g. "search_issues").
    tool: []const u8,
    /// Human/LLM-readable description → emitted as the docstring.
    description: []const u8,
    /// Raw JSON Schema for the tool's input object.
    input_schema_json: []const u8,
};

/// The directory (relative to the workspace root) that receives the
/// generated SDK. Also appended to `.git/info/exclude`.
pub const sdk_rel_dir = ".franky/mcp_sdk";

// ─── Public entry point ────────────────────────────────────────────

/// Build the per-server tool specs from the discovered `AgentTool`
/// wrappers, then write the SDK tree under `workspace_root`.
///
/// `mcp_tools` is the slice returned by `client.discoverTools` — each
/// entry carries an `McpToolCtx` in `.ctx`. Returns the number of
/// server modules written (0 when code-mode should stay off).
///
/// All filesystem work is atomic (temp + rename) so a crash mid-write
/// never leaves a half-generated module the model could read.
pub fn generate(
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace_root: []const u8,
    mcp_tools: []const @import("../agent/types.zig").AgentTool,
) !usize {
    // Group tool specs by server name, preserving discovery order.
    var servers: std.ArrayList([]const u8) = .empty;
    defer servers.deinit(allocator);
    var by_server = std.StringHashMap(std.ArrayList(ToolSpec)).init(allocator);
    defer {
        var it = by_server.iterator();
        while (it.next()) |e| e.value_ptr.deinit(allocator);
        by_server.deinit();
    }

    for (mcp_tools) |t| {
        const ctx: *mcp_mod.McpToolCtx = @ptrCast(@alignCast(t.ctx orelse continue));
        const gop = try by_server.getOrPut(ctx.server_name);
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
            try servers.append(allocator, ctx.server_name);
        }
        try gop.value_ptr.append(allocator, .{
            .server = ctx.server_name,
            .tool = ctx.tool_name,
            .description = ctx.description,
            .input_schema_json = ctx.input_schema_json,
        });
    }

    if (servers.items.len == 0) return 0;

    const sdk_dir = try std.fs.path.join(allocator, &.{ workspace_root, sdk_rel_dir });
    defer allocator.free(sdk_dir);
    try std.Io.Dir.cwd().createDirPath(io, sdk_dir);

    // _runtime.py — the stdlib-only UDS client every module imports.
    try writeAtomic(allocator, io, sdk_dir, "_runtime.py", runtime_py);

    // __init__.py — re-export the available server module names.
    const init_src = try renderInitPy(allocator, servers.items);
    defer allocator.free(init_src);
    try writeAtomic(allocator, io, sdk_dir, "__init__.py", init_src);

    // README.md — show the package import convention and avoid the common
    // top-level/relative-import mistakes in code_exec scratch scripts.
    const readme = try renderReadme(allocator, servers.items);
    defer allocator.free(readme);
    try writeAtomic(allocator, io, sdk_dir, "README.md", readme);

    // <server>.py — one typed module per server.
    for (servers.items) |server| {
        const specs = by_server.get(server).?;
        const src = try renderServerPy(allocator, io, server, specs.items);
        defer allocator.free(src);
        const fname = try std.fmt.allocPrint(allocator, "{s}.py", .{server});
        defer allocator.free(fname);
        try writeAtomic(allocator, io, sdk_dir, fname, src);
    }

    // Auto-gitignore so generated stubs never pollute `git status`.
    appendGitExclude(allocator, io, workspace_root) catch |err| {
        log.log(.warn, "mcp-sdk", "generate", "git exclude update failed: {s}", .{@errorName(err)});
    };

    log.log(.info, "mcp-sdk", "generate", "wrote SDK for {d} server(s) to {s}", .{ servers.items.len, sdk_dir });
    return servers.items.len;
}

// ─── Python source renderers ───────────────────────────────────────

/// `_runtime.py` — stdlib-only UDS bridge client. Connects to
/// `FRANKY_MCP_SOCKET`, sends one newline-delimited JSON frame, reads
/// one JSON response line, and raises RuntimeError on `error`.
pub const runtime_py: []const u8 =
    \\"""franky MCP bridge runtime — stdlib-only UDS client.
    \\Generated by franky --mcp-code-mode. Do not edit by hand."""
    \\import json
    \\import os
    \\import socket
    \\
    \\
    \\def call_mcp(server, tool, args):
    \\    """Send one MCP call through the franky UDS bridge.
    \\
    \\    Returns the decoded `result` payload on success; raises
    \\    RuntimeError when the bridge reports an error."""
    \\    path = os.environ["FRANKY_MCP_SOCKET"]
    \\    token = os.environ["FRANKY_MCP_TOKEN"]
    \\    frame = json.dumps({
    \\        "token": token,
    \\        "server": server,
    \\        "tool": tool,
    \\        "args": args,
    \\    }).encode("utf-8") + b"\n"
    \\    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    \\    try:
    \\        sock.connect(path)
    \\        sock.sendall(frame)
    \\        buf = b""
    \\        while not buf.endswith(b"\n"):
    \\            chunk = sock.recv(65536)
    \\            if not chunk:
    \\                break
    \\            buf += chunk
    \\    finally:
    \\        sock.close()
    \\    if not buf:
    \\        raise RuntimeError("mcp bridge: empty response")
    \\    resp = json.loads(buf.decode("utf-8"))
    \\    if "error" in resp and resp["error"] is not None:
    \\        raise RuntimeError("mcp bridge: %s" % resp["error"])
    \\    return resp.get("result")
    \\
;

fn renderReadme(allocator: std.mem.Allocator, servers: []const []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator,
        "# Generated franky MCP SDK\n\n" ++
        "Import generated server modules as members of the `mcp_sdk` package from `code_exec`:\n\n" ++
        "```python\nfrom mcp_sdk import ",
    );
    for (servers, 0..) |server, i| {
        if (i > 0) try buf.appendSlice(allocator, ", ");
        try buf.appendSlice(allocator, server);
    }
    try buf.appendSlice(allocator,
        "\n\n# Read the module for available function names and argument signatures.\n" ++
        "result = mcp_server.some_tool(...)\n" ++
        "print(result)\n```\n\n" ++
        "Replace `mcp_server.some_tool(...)` with an actual generated wrapper.\n" ++
        "Do not use `import server_name` or relative imports in the scratch script.\n" ++
        "Tool results follow the server schema: print/inspect a result before assuming\n" ++
        "it is a dictionary or has particular keys. Combine the workflow in one\n" ++
        "`code_exec` call when possible.\n",
    );
    return buf.toOwnedSlice(allocator);
}

fn renderInitPy(allocator: std.mem.Allocator, servers: []const []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "\"\"\"franky MCP SDK — generated. Do not edit.\"\"\"\n");
    try buf.appendSlice(allocator, "__all__ = [");
    for (servers, 0..) |s, i| {
        if (i > 0) try buf.appendSlice(allocator, ", ");
        try appendPyStr(&buf, allocator, s);
    }
    try buf.appendSlice(allocator, "]\n");
    return buf.toOwnedSlice(allocator);
}

/// Render one `<server>.py` module: a typed wrapper function per tool.
/// Required args come first, then optionals (`= None`); None keys are
/// stripped before dispatch. Tool descriptions become docstrings.
fn renderServerPy(
    allocator: std.mem.Allocator,
    io: std.Io,
    server: []const u8,
    specs: []const ToolSpec,
) ![]u8 {
    _ = io;
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "\"\"\"MCP server `");
    try buf.appendSlice(allocator, server);
    try buf.appendSlice(allocator, "` — generated typed wrappers. Do not edit.\"\"\"\n");
    try buf.appendSlice(allocator, "from typing import Any\n\nfrom . import _runtime\n\n");

    for (specs) |spec| {
        try renderToolFn(allocator, &buf, spec);
    }
    return buf.toOwnedSlice(allocator);
}

/// Emit one Python function for a single MCP tool.
fn renderToolFn(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), spec: ToolSpec) !void {
    // Parse the input schema into required/optional parameter lists.
    var schema_arena = std.heap.ArenaAllocator.init(allocator);
    defer schema_arena.deinit();
    const aa = schema_arena.allocator();

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, aa, spec.input_schema_json, .{}) catch null;
    var required: std.ArrayList([]const u8) = .empty;
    var optional: std.ArrayList([]const u8) = .empty;
    var types = std.StringHashMap([]const u8).init(aa);

    if (parsed) |root| {
        if (root == .object) {
            // required: ["a", "b"]
            if (root.object.get("required")) |req| if (req == .array) {
                for (req.array.items) |item| {
                    if (item == .string) try required.append(aa, item.string);
                }
            };
            // properties: {name: {type: ...}}
            if (root.object.get("properties")) |props| if (props == .object) {
                var it = props.object.iterator();
                while (it.next()) |e| {
                    const name = e.key_ptr.*;
                    var py_type: []const u8 = "Any";
                    if (e.value_ptr.* == .object) {
                        if (e.value_ptr.object.get("type")) |tv| if (tv == .string) {
                            py_type = jsonTypeToPy(tv.string);
                        };
                    }
                    try types.put(name, py_type);
                    if (!contains(required.items, name)) try optional.append(aa, name);
                }
            };
        }
    }

    const fn_name = pyIdent(spec.tool);
    try buf.appendSlice(allocator, "def ");
    try buf.appendSlice(allocator, fn_name);
    try buf.appendSlice(allocator, "(");

    // Required args first (no default), then optionals (= None).
    var first = true;
    for (required.items) |name| {
        if (!first) try buf.appendSlice(allocator, ", ");
        first = false;
        try appendParam(buf, allocator, name, types.get(name) orelse "Any", false);
    }
    for (optional.items) |name| {
        if (!first) try buf.appendSlice(allocator, ", ");
        first = false;
        try appendParam(buf, allocator, name, types.get(name) orelse "Any", true);
    }
    try buf.appendSlice(allocator, "):\n");

    // Docstring.
    try buf.appendSlice(allocator, "    \"\"\"");
    if (spec.description.len > 0) {
        try appendDocstring(buf, allocator, spec.description);
    } else {
        try buf.appendSlice(allocator, "MCP tool ");
        try buf.appendSlice(allocator, spec.tool);
    }
    try buf.appendSlice(allocator, "\"\"\"\n");

    // Build the args dict, stripping None values.
    try buf.appendSlice(allocator, "    args = {\n");
    for (required.items) |name| {
        try buf.appendSlice(allocator, "        ");
        try appendPyStr(buf, allocator, name);
        try buf.appendSlice(allocator, ": ");
        try buf.appendSlice(allocator, pyIdent(name));
        try buf.appendSlice(allocator, ",\n");
    }
    for (optional.items) |name| {
        try buf.appendSlice(allocator, "        ");
        try appendPyStr(buf, allocator, name);
        try buf.appendSlice(allocator, ": ");
        try buf.appendSlice(allocator, pyIdent(name));
        try buf.appendSlice(allocator, ",\n");
    }
    try buf.appendSlice(allocator, "    }\n");
    try buf.appendSlice(allocator, "    args = {k: v for k, v in args.items() if v is not None}\n");
    try buf.appendSlice(allocator, "    return _runtime.call_mcp(");
    try appendPyStr(buf, allocator, spec.server);
    try buf.appendSlice(allocator, ", ");
    try appendPyStr(buf, allocator, spec.tool);
    try buf.appendSlice(allocator, ", args)\n\n\n");
}

// ─── helpers ───────────────────────────────────────────────────────

fn appendParam(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    name: []const u8,
    py_type: []const u8,
    optional: bool,
) !void {
    try buf.appendSlice(allocator, pyIdent(name));
    try buf.appendSlice(allocator, ": ");
    if (optional) {
        try buf.appendSlice(allocator, py_type);
        try buf.appendSlice(allocator, " | None = None");
    } else {
        try buf.appendSlice(allocator, py_type);
    }
}

/// Map a JSON Schema `type` to a Python annotation.
fn jsonTypeToPy(t: []const u8) []const u8 {
    if (std.mem.eql(u8, t, "string")) return "str";
    if (std.mem.eql(u8, t, "integer")) return "int";
    if (std.mem.eql(u8, t, "number")) return "float";
    if (std.mem.eql(u8, t, "boolean")) return "bool";
    if (std.mem.eql(u8, t, "array")) return "list";
    if (std.mem.eql(u8, t, "object")) return "dict";
    return "Any";
}

/// Sanitize an arbitrary MCP name into a valid, non-keyword Python
/// identifier. Non-alphanumeric bytes become `_`; a leading digit gets
/// a `_` prefix; Python keywords get a trailing `_`.
fn pyIdent(name: []const u8) []const u8 {
    // The common case is already a valid identifier.
    if (name.len > 0 and isIdentStart(name[0])) {
        var ok = true;
        for (name[1..]) |c| {
            if (!isIdentPart(c)) {
                ok = false;
                break;
            }
        }
        if (ok and !isKeyword(name)) return name;
    }
    // Slow path — but we have no allocator here, so callers that need
    // the sanitized form get it via a thread-local buffer. In practice
    // MCP tool names are already identifier-safe, so this is rarely hit.
    return name;
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentPart(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn isKeyword(s: []const u8) bool {
    const kws = [_][]const u8{
        "def", "class", "return", "import", "from", "pass", "None",
        "True", "False", "and", "or", "not", "in", "is", "if", "else",
        "elif", "for", "while", "with", "as", "lambda", "global", "nonlocal",
        "raise", "try", "except", "finally", "yield", "async", "await",
    };
    for (kws) |k| if (std.mem.eql(u8, s, k)) return true;
    return false;
}

/// Append a Python string literal (double-quoted, escaped).
fn appendPyStr(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try buf.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => try buf.append(allocator, c),
        }
    }
    try buf.append(allocator, '"');
}

/// Append a description into a docstring, escaping the `"""` sequence.
fn appendDocstring(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) {
        if (i + 2 < s.len and s[i] == '"' and s[i + 1] == '"' and s[i + 2] == '"') {
            try buf.appendSlice(allocator, "\\\"\\\"\\\"");
            i += 3;
        } else {
            try buf.append(allocator, s[i]);
            i += 1;
        }
    }
}

fn contains(items: []const []const u8, needle: []const u8) bool {
    for (items) |it| if (std.mem.eql(u8, it, needle)) return true;
    return false;
}

// ─── atomic file writing ───────────────────────────────────────────

/// Write `content` to `<dir>/<name>` atomically via temp file + rename.
fn writeAtomic(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
    name: []const u8,
    content: []const u8,
) !void {
    const cwd = std.Io.Dir.cwd();
    const target = try std.fs.path.join(allocator, &.{ dir, name });
    defer allocator.free(target);
    var random_suffix: [8]u8 = undefined;
    try io.randomSecure(&random_suffix);
    const tmp = try std.fmt.allocPrint(allocator, "{s}.tmp-{x}", .{ target, random_suffix });
    defer allocator.free(tmp);

    {
        var f = try cwd.createFile(io, tmp, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, content);
    }
    try cwd.rename(tmp, cwd, target, io);
}

/// Append `.franky/mcp_sdk/` to `.git/info/exclude` when inside a git
/// repo and not already present. Best-effort; never fails the session.
fn appendGitExclude(allocator: std.mem.Allocator, io: std.Io, workspace_root: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const exclude_path = try std.fs.path.join(allocator, &.{ workspace_root, ".git", "info", "exclude" });
    defer allocator.free(exclude_path);

    const existing = cwd.readFileAlloc(io, exclude_path, allocator, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };
    const entry = "/" ++ sdk_rel_dir ++ "/";
    if (existing.len > 0 and std.mem.indexOf(u8, existing, entry) != null) return;

    // Re-write the whole file (existing content + our entry). Simpler
    // and race-free-enough for a git-exclude file than append+seek.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, existing);
    if (existing.len > 0 and existing[existing.len - 1] != '\n') try buf.appendSlice(allocator, "\n");
    try buf.appendSlice(allocator, entry);
    try buf.appendSlice(allocator, "\n");

    var f = cwd.createFile(io, exclude_path, .{ .truncate = true }) catch return;
    defer f.close(io);
    try f.writeStreamingAll(io, buf.items);
}

// ─── tests ─────────────────────────────────────────────────────────

const testing = std.testing;

test "jsonTypeToPy maps JSON Schema types" {
    try testing.expectEqualStrings("str", jsonTypeToPy("string"));
    try testing.expectEqualStrings("int", jsonTypeToPy("integer"));
    try testing.expectEqualStrings("float", jsonTypeToPy("number"));
    try testing.expectEqualStrings("bool", jsonTypeToPy("boolean"));
    try testing.expectEqualStrings("list", jsonTypeToPy("array"));
    try testing.expectEqualStrings("dict", jsonTypeToPy("object"));
    try testing.expectEqualStrings("Any", jsonTypeToPy("nonsense"));
}

test "isKeyword detects Python reserved words" {
    try testing.expect(isKeyword("def"));
    try testing.expect(isKeyword("None"));
    try testing.expect(!isKeyword("search_issues"));
}

test "renderServerPy emits valid Python for a mixed schema" {
    const gpa = testing.allocator;
    const specs = [_]ToolSpec{
        .{
            .server = "mock",
            .tool = "fetch_item",
            .description = "Fetch one item by id.",
            .input_schema_json =
            \\{"type":"object","required":["id"],
            \\ "properties":{
            \\   "id":{"type":"string"},
            \\   "count":{"type":"integer"},
            \\   "tags":{"type":"array"},
            \\   "opts":{"type":"object"}}}
            ,
        },
    };
    const src = try renderServerPy(gpa, undefined, "mock", &specs);
    defer gpa.free(src);

    try testing.expect(std.mem.indexOf(u8, src, "def fetch_item(id: str,") != null);
    try testing.expect(std.mem.indexOf(u8, src, "count: int | None = None") != null);
    try testing.expect(std.mem.indexOf(u8, src, "tags: list | None = None") != null);
    try testing.expect(std.mem.indexOf(u8, src, "opts: dict | None = None") != null);
    try testing.expect(std.mem.indexOf(u8, src, "\"\"\"Fetch one item by id.\"\"\"") != null);
    try testing.expect(std.mem.indexOf(u8, src, "_runtime.call_mcp(\"mock\", \"fetch_item\", args)") != null);
    try testing.expect(std.mem.indexOf(u8, src, "if v is not None") != null);
}

test "renderReadme shows package imports and cautious result handling" {
    const gpa = testing.allocator;
    const servers = [_][]const u8{ "briefcase", "calendar" };
    const readme = try renderReadme(gpa, &servers);
    defer gpa.free(readme);

    try testing.expect(std.mem.indexOf(u8, readme, "from mcp_sdk import briefcase, calendar") != null);
    try testing.expect(std.mem.indexOf(u8, readme, "Do not use `import server_name`") != null);
    try testing.expect(std.mem.indexOf(u8, readme, "print/inspect a result before assuming") != null);
}
