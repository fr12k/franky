//! `--mode mcp` — Model Context Protocol server over stdio.
//!
//! Speaks MCP (Model Context Protocol) revisions 2024-11-05 (v1)
//! and 2026-07-28 (v2) over JSON-RPC 2.0 with LSP Content-Length
//! framing — the exact wire format `--mode rpc` already uses.
//!
//! This is a thin method-vocabulary layer on top of the RPC mode's
//! session/framing infrastructure. It reuses `rpc.initSession`,
//! `rpc.Session`, `rpc.writeResultFrame`, `rpc.writeErrorFrame`,
//! and `rpc.writeFrameToStdout` so there is zero duplicated
//! plumbing. The only thing this file adds is the MCP method set:
//!
//!   - `initialize`           → capability negotiation + serverInfo
//!   - `notifications/initialized` → no-op ack (notification, no reply)
//!   - `ping`                 → `{}`
//!   - `tools/list`           → enumerate the franky tool catalog
//!   - `tools/call`           → invoke a franky tool by name
//!   - `resources/list`       → empty (franky exposes no MCP resources)
//!   - `prompts/list`         → empty (franky exposes no MCP prompts)
//!   - `shutdown`             → graceful exit
//!   - `server/discover`      → v2 discovery endpoint
//!
//! All 16+ franky built-in tools (read/write/edit/bash/ls/find/grep/
//! subagent/web_search/web_fetch/workspace/memory_*/ccr_retrieve)
//! are automatically exposed because `initSession` builds the same
//! tool set as `--mode rpc`. MCP's `inputSchema` maps 1:1 from
//! `AgentTool.parameters_json`.

const std = @import("std");
const franky = @import("../../root.zig");
const ai = franky.ai;
const agent = franky.agent;
const at = agent.types;
const rpc = franky.coding.rpc;
const cli_mod = franky.coding.cli;
const rpc_mode = @import("rpc.zig");

/// MCP protocol versions we can negotiate.
pub const protocol_v1: []const u8 = "2024-11-05";
pub const protocol_v2: []const u8 = "2026-07-28";

/// Known protocol versions a client may request in `initialize`.
/// We echo the client's requested version if we know it, otherwise
/// fall back to v1 (the most broadly compatible).
const known_versions = [_][]const u8{
    protocol_v2,
    "2025-11-25",
    "2025-06-18",
    "2025-03-26",
    protocol_v1,
};

/// Entry point — same signature as `rpc_mode.run`.
pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    environ_map: *std.process.Environ.Map,
    cfg: *cli_mod.Config,
) !void {
    const stdin = std.Io.File.stdin();
    const stdout = std.Io.File.stdout();

    // Reuse the exact same session assembly as --mode rpc.
    var session: rpc_mode.Session = undefined;
    try rpc_mode.initSession(&session, allocator, io, environ, environ_map, cfg);
    defer session.deinit();

    var initialized = false;
    var negotiated_version: []const u8 = protocol_v1;

    // Read frames in a loop — identical to rpc.zig's main loop.
    var read_buf: std.ArrayList(u8) = .empty;
    defer read_buf.deinit(allocator);
    var cursor: usize = 0;
    var scratch: [4096]u8 = undefined;

    while (true) {
        const span = rpc.readFrame(read_buf.items, cursor) catch |err| {
            try rpc_mode.writeErrorFrame(allocator, io, stdout, null, err);
            continue;
        };
        if (span) |s| {
            const body = read_buf.items[s.body_start..s.body_end];
            try dispatchOne(
                allocator,
                io,
                stdout,
                &session,
                body,
                &initialized,
                &negotiated_version,
            );
            cursor = s.body_end;
            if (cursor > 16 * 1024) {
                const remaining = read_buf.items[cursor..];
                std.mem.copyForwards(u8, read_buf.items[0..remaining.len], remaining);
                read_buf.items.len = remaining.len;
                cursor = 0;
            }
            continue;
        }
        const n = std.posix.read(stdin.handle, &scratch) catch |err| switch (err) {
            error.WouldBlock => 0,
            else => break,
        };
        if (n == 0) break; // EOF
        try read_buf.appendSlice(allocator, scratch[0..n]);
    }
}

// ─── dispatch ───────────────────────────────────────────────────

fn dispatchOne(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: std.Io.File,
    session: *rpc_mode.Session,
    body: []const u8,
    initialized: *bool,
    negotiated_version: *[]const u8,
) !void {
    var req = rpc.parseRequest(allocator, body) catch |err| {
        try rpc_mode.writeErrorFrame(allocator, io, stdout, null, err);
        return;
    };
    defer rpc.freeRequest(allocator, &req);

    // MCP notifications (no `id`) get no response.
    const is_notification = req.id == null;

    if (std.mem.eql(u8, req.method, "initialize")) {
        try handleInitialize(allocator, io, stdout, req, negotiated_version);
        return;
    }
    if (std.mem.eql(u8, req.method, "notifications/initialized")) {
        initialized.* = true;
        return;
    }
    if (std.mem.eql(u8, req.method, "ping")) {
        try rpc_mode.writeResultFrame(allocator, io, stdout, req.id, "{}");
        return;
    }
    if (std.mem.eql(u8, req.method, "tools/list")) {
        try handleToolsList(allocator, io, stdout, session, req);
        return;
    }
    if (std.mem.eql(u8, req.method, "tools/call")) {
        try handleToolsCall(allocator, io, stdout, session, req);
        return;
    }
    if (std.mem.eql(u8, req.method, "resources/list")) {
        try rpc_mode.writeResultFrame(allocator, io, stdout, req.id, "{\"resources\":[]}");
        return;
    }
    if (std.mem.eql(u8, req.method, "prompts/list")) {
        try rpc_mode.writeResultFrame(allocator, io, stdout, req.id, "{\"prompts\":[]}");
        return;
    }
    if (std.mem.eql(u8, req.method, "server/discover")) {
        // v2 discovery — return the same mode matrix as initialize.
        try handleDiscover(allocator, io, stdout, req);
        return;
    }
    if (std.mem.eql(u8, req.method, "shutdown")) {
        if (!is_notification) {
            try rpc_mode.writeResultFrame(allocator, io, stdout, req.id, "{}");
        }
        return;
    }
    if (is_notification) return; // unknown notification → silent

    // JSON-RPC method-not-found (-32601).
    try writeMcpError(allocator, io, stdout, req.id, -32601, "Method not found");
}

// ─── initialize ─────────────────────────────────────────────────

fn handleInitialize(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: std.Io.File,
    req: rpc.Request,
    negotiated_version: *[]const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // Parse client-requested protocolVersion if present.
    var client_version: ?[]const u8 = null;
    if (req.params_raw) |params| {
        const parsed = std.json.parseFromSlice(std.json.Value, aa, params, .{}) catch null;
        if (parsed) |p| if (p.value == .object) {
            if (p.value.object.get("protocolVersion")) |pv| if (pv == .string) {
                client_version = pv.string;
            };
        };
    }

    // Negotiate: echo the client's version if known, else fall back to v1.
    const chosen = blk: {
        if (client_version) |cv| {
            for (known_versions) |kv| {
                if (std.mem.eql(u8, cv, kv)) break :blk cv;
            }
        }
        break :blk protocol_v1;
    };
    negotiated_version.* = chosen;

    // Build the initialize result.
    //   serverInfo.name, serverInfo.version
    //   protocolVersion (negotiated)
    //   capabilities.tools = {}
    const payload = try std.fmt.allocPrint(aa,
        \\{{"protocolVersion":"{s}","capabilities":{{"tools":{{}},"resources":{{}},"prompts":{{}}}},"serverInfo":{{"name":"franky","version":"{s}"}}}}
    , .{ chosen, franky.version });
    try rpc_mode.writeResultFrame(allocator, io, stdout, req.id, payload);
}

// ─── server/discover (v2) ───────────────────────────────────────

fn handleDiscover(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: std.Io.File,
    req: rpc.Request,
) !void {
    // v2 `server/discover` returns the same shape as `initialize`
    // but without the protocolVersion negotiation — we just report
    // our top-level capabilities.
    const payload = try std.fmt.allocPrint(allocator,
        \\{{"serverInfo":{{"name":"franky","version":"{s}"}},"capabilities":{{"tools":{{}},"resources":{{}},"prompts":{{}}}}}}
    , .{franky.version});
    defer allocator.free(payload);
    try rpc_mode.writeResultFrame(allocator, io, stdout, req.id, payload);
}

// ─── tools/list ─────────────────────────────────────────────────

fn handleToolsList(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: std.Io.File,
    session: *rpc_mode.Session,
    req: rpc.Request,
) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"tools\":[");

    const tools = session.tools;
    var first = true;
    for (tools) |t| {
        // Skip internal harness tools that don't make sense over MCP.
        // `finish_task` is a franky-internal guardrail trigger.
        if (std.mem.eql(u8, t.name, "finish_task")) continue;

        if (!first) try buf.append(allocator, ',');
        first = false;
        try buf.append(allocator, '{');
        try buf.appendSlice(allocator, "\"name\":");
        try appendJsonStr(&buf, allocator, t.name);
        try buf.appendSlice(allocator, ",\"description\":");
        try appendJsonStr(&buf, allocator, t.description);
        // `parameters_json` is already a JSON Schema string; embed it raw.
        try buf.appendSlice(allocator, ",\"inputSchema\":");
        try buf.appendSlice(allocator, t.parameters_json);
        try buf.append(allocator, '}');
    }
    try buf.appendSlice(allocator, "]}");

    try rpc_mode.writeResultFrame(allocator, io, stdout, req.id, buf.items);
}

// ─── tools/call ─────────────────────────────────────────────────

fn handleToolsCall(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: std.Io.File,
    session: *rpc_mode.Session,
    req: rpc.Request,
) !void {
    const params = req.params_raw orelse {
        try writeMcpError(allocator, io, stdout, req.id, -32602, "Invalid params");
        return;
    };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const parsed = std.json.parseFromSlice(std.json.Value, aa, params, .{}) catch {
        try writeMcpError(allocator, io, stdout, req.id, -32602, "Invalid params");
        return;
    };
    if (parsed.value != .object) {
        try writeMcpError(allocator, io, stdout, req.id, -32602, "Invalid params");
        return;
    }
    const o = parsed.value.object;

    const name_val = o.get("name") orelse {
        try writeMcpError(allocator, io, stdout, req.id, -32602, "Missing tool name");
        return;
    };
    if (name_val != .string) {
        try writeMcpError(allocator, io, stdout, req.id, -32602, "Tool name must be a string");
        return;
    }
    const tool_name = name_val.string;

    // Find the tool in the session's tool set.
    const tools = session.tools;
    var tool_def: ?at.AgentTool = null;
    for (tools) |t| {
        if (std.mem.eql(u8, t.name, tool_name)) {
            tool_def = t;
            break;
        }
    }
    if (tool_def == null) {
        const msg = try std.fmt.allocPrint(allocator, "Unknown tool: {s}", .{tool_name});
        defer allocator.free(msg);
        try writeMcpError(allocator, io, stdout, req.id, -32602, msg);
        return;
    }
    const tool = tool_def.?;

    // Serialize `arguments` back to a JSON string for the franky tool's
    // `execute` (which expects args_json). MCP sends arguments as a JSON
    // object; we re-serialize it.
    var args_json: []const u8 = "{}";
    if (o.get("arguments")) |args_val| {
        if (args_val == .object or args_val == .array) {
            var tmp: std.ArrayList(u8) = .empty;
            defer tmp.deinit(allocator);
            try renderJson(&tmp, allocator, args_val);
            args_json = try allocator.dupe(u8, tmp.items);
        } else if (args_val == .string) {
            // Some clients send a pre-serialized string.
            args_json = try allocator.dupe(u8, args_val.string);
        }
    }

    // Invoke the tool. We use a no-op cancel and on_update — MCP
    // tool calls are synchronous from the protocol's perspective.
    var cancel: ai.stream.Cancel = .{};
    const on_update: at.OnUpdate = .{};
    // Generate a call_id from the request id.
    var call_id_buf: [32]u8 = undefined;
    const call_id = switch (req.id orelse rpc.Id{ .number = 0 }) {
        .number => |n| blk: {
            const s = std.fmt.bufPrint(&call_id_buf, "mcp-{d}", .{n}) catch "mcp";
            break :blk s;
        },
        .string => |s| s,
    };

    var result = tool.execute(&tool, allocator, io, call_id, args_json, &cancel, on_update) catch |err| {
        // Tool threw — wrap as an MCP error result (isError: true).
        const err_msg = try std.fmt.allocPrint(allocator, "Tool '{s}' failed: {s}", .{ tool_name, @errorName(err) });
        defer allocator.free(err_msg);
        const err_payload = try std.fmt.allocPrint(allocator,
            "{{\"content\":[{{\"type\":\"text\",\"text\":{s}}}],\"isError\":true}}",
            .{try jsonStr(aa, err_msg)});
        try rpc_mode.writeResultFrame(allocator, io, stdout, req.id, err_payload);
        return;
    };
    defer result.deinit(allocator);

    // Translate ToolResult → MCP CallToolResult.
    // MCP wants: {"content":[{"type":"text","text":"..."}], "isError": bool}
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"content\":[");
    var first = true;
    for (result.content) |cb| switch (cb) {
        .text => |tc| {
            if (!first) try buf.append(allocator, ',');
            first = false;
            try buf.appendSlice(allocator, "{\"type\":\"text\",\"text\":");
            try appendJsonStr(&buf, allocator, tc.text);
            try buf.append(allocator, '}');
        },
        .image => |ic| {
            if (!first) try buf.append(allocator, ',');
            first = false;
            try buf.appendSlice(allocator, "{\"type\":\"image\",\"data\":");
            try appendJsonStr(&buf, allocator, ic.data);
            try buf.appendSlice(allocator, ",\"mimeType\":");
            try appendJsonStr(&buf, allocator, ic.mime_type);
            try buf.append(allocator, '}');
        },
        // thinking and tool_call blocks are not translatable to MCP
        // content — skip them.
        else => {},
    };
    try buf.appendSlice(allocator, "],\"isError\":");
    try buf.appendSlice(allocator, if (result.is_error) "true" else "false");
    try buf.append(allocator, '}');

    try rpc_mode.writeResultFrame(allocator, io, stdout, req.id, buf.items);
}

// ─── helpers ────────────────────────────────────────────────────

/// Write a JSON-RPC error with a specific MCP code + message.
fn writeMcpError(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: std.Io.File,
    id: ?rpc.Id,
    code: i64,
    message: []const u8,
) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"jsonrpc\":\"2.0\"");
    if (id) |idv| {
        try buf.appendSlice(allocator, ",\"id\":");
        switch (idv) {
            .number => |n| {
                var tmp: [20]u8 = undefined;
                const s = std.fmt.bufPrint(&tmp, "{d}", .{n}) catch unreachable;
                try buf.appendSlice(allocator, s);
            },
            .string => |s| {
                try buf.append(allocator, '"');
                try buf.appendSlice(allocator, s);
                try buf.append(allocator, '"');
            },
        }
    } else {
        try buf.appendSlice(allocator, ",\"id\":null");
    }
    try buf.appendSlice(allocator, ",\"error\":{\"code\":");
    {
        var tmp: [20]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "{d}", .{code}) catch unreachable;
        try buf.appendSlice(allocator, s);
    }
    try buf.appendSlice(allocator, ",\"message\":");
    try appendJsonStr(&buf, allocator, message);
    try buf.appendSlice(allocator, "}}");
    try rpc_mode.writeFrameToStdout(io, stdout, buf.items);
}

/// JSON-encode a string (allocates on `allocator`).
fn jsonStr(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try appendJsonStr(&buf, allocator, s);
    return try buf.toOwnedSlice(allocator);
}

fn appendJsonStr(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try buf.append(allocator, '"');
    for (s) |c| switch (c) {
        '"' => try buf.appendSlice(allocator, "\\\""),
        '\\' => try buf.appendSlice(allocator, "\\\\"),
        '\n' => try buf.appendSlice(allocator, "\\n"),
        '\r' => try buf.appendSlice(allocator, "\\r"),
        '\t' => try buf.appendSlice(allocator, "\\t"),
        0...0x07, 0x0b, 0x0e...0x1f => {
            var tmp: [8]u8 = undefined;
            const w = std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{c}) catch unreachable;
            try buf.appendSlice(allocator, w);
        },
        else => try buf.append(allocator, c),
    };
    try buf.append(allocator, '"');
}

/// Re-serialize a `std.json.Value` to a string (mirrors rpc.zig's
/// private `renderJson`).
fn renderJson(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, v: std.json.Value) !void {
    switch (v) {
        .null => try buf.appendSlice(allocator, "null"),
        .bool => |b| try buf.appendSlice(allocator, if (b) "true" else "false"),
        .integer => |i| {
            var tmp: [20]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{d}", .{i}) catch unreachable;
            try buf.appendSlice(allocator, s);
        },
        .float => |f| {
            var tmp: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{d}", .{f}) catch unreachable;
            try buf.appendSlice(allocator, s);
        },
        .string => |s| try appendJsonStr(buf, allocator, s),
        .number_string => |s| {
            try buf.append(allocator, '"');
            try buf.appendSlice(allocator, s);
            try buf.append(allocator, '"');
        },
        .array => |arr| {
            try buf.append(allocator, '[');
            for (arr.items, 0..) |item, i| {
                if (i > 0) try buf.append(allocator, ',');
                try renderJson(buf, allocator, item);
            }
            try buf.append(allocator, ']');
        },
        .object => |obj| {
            try buf.append(allocator, '{');
            var it = obj.iterator();
            var first = true;
            while (it.next()) |entry| {
                if (!first) try buf.append(allocator, ',');
                first = false;
                try appendJsonStr(buf, allocator, entry.key_ptr.*);
                try buf.append(allocator, ':');
                try renderJson(buf, allocator, entry.value_ptr.*);
            }
            try buf.append(allocator, '}');
        },
    }
}

// ─── tests ──────────────────────────────────────────────────────

const testing = std.testing;

test "appendJsonStr: escapes control chars" {
    const gpa = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try appendJsonStr(&buf, gpa, "a\nb\"c");
    try testing.expectEqualStrings("\"a\\nb\\\"c\"", buf.items);
}

test "renderJson: object round-trip" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), "{\"x\":1,\"y\":\"z\"}", .{});
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try renderJson(&buf, gpa, parsed.value);
    // Order may differ; just check key presence.
    try testing.expect(std.mem.indexOf(u8, buf.items, "\"x\":1") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "\"y\":\"z\"") != null);
}
