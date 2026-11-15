//! MCP client — connects to external MCP servers over HTTP and
//! exposes their tools as franky `AgentTool` wrappers.
//!
//! Lifecycle:
//!   1. `discoverTools(allocator, io, server_configs, environ_map)`
//!      → for each server: send `initialize` + `tools/list`, collect
//!        tool definitions, build `AgentTool` wrappers.
//!   2. The returned `AgentTool` slice is appended to the session's
//!      tool set. When the agent calls one, the wrapper sends a
//!      `tools/call` JSON-RPC request to the originating server.
//!
//! The `McpToolCtx` stored in each tool's `.ctx` pointer carries the
//! server URL, headers, and tool name so the execute function can
//! route the call correctly.

const std = @import("std");
const config_mod = @import("config.zig");
const at = @import("../../agent/types.zig");
const ai = @import("../../ai/mod.zig");
const http_mod = ai.http;
const stream_mod = ai.stream;
const common = @import("../tools/common.zig");

/// Context for a single MCP-proxied tool. Allocated on the session
/// arena; lives for the duration of the session.
pub const McpToolCtx = struct {
    /// Server URL (e.g. "https://mcp.atlassian.com/v2/mcp").
    url: []const u8,
    /// HTTP headers (owned by the session arena).
    headers: []const config_mod.ServerConfig.Header,
    /// The tool name as known by the remote MCP server.
    tool_name: []const u8,
    /// The tool description (for the AgentTool).
    description: []const u8,
    /// The JSON Schema for the tool's input (for AgentTool.parameters_json).
    input_schema_json: []const u8,
    /// The server name (for namespacing, e.g. "atlassian__search_issues").
    server_name: []const u8,
};

/// Per-session MCP client state. Holds the arena-allocated tool
/// contexts and the cached server configs. Allocated by the caller
/// on the session arena.
pub const McpClient = struct {
    /// All discovered tool contexts. Each one is pointed to by the
    /// corresponding `AgentTool.ctx`.
    tool_ctxs: []McpToolCtx,
    /// The arena that owns all MCP string data. Deinit is the
    /// caller's responsibility (usually the session arena).
    arena: std.mem.Allocator,

    pub fn deinit(self: *McpClient) void {
        // Nothing to do — the arena is owned by the session.
        _ = self;
    }
};

/// Discover tools from all configured MCP servers.
///
/// For each server:
///   1. Send `initialize` (JSON-RPC over HTTP POST).
///   2. Send `tools/list` to get the tool catalog.
///   3. For each remote tool, create an `McpToolCtx` + `AgentTool`
///      wrapper with a namespaced name: `<server>__<tool>`.
///
/// Returns the `AgentTool` slice (allocated on `arena`) and fills
/// `client_out` with the tool contexts. On per-server failure, logs
/// a warning and continues with the remaining servers.
pub fn discoverTools(
    arena: std.mem.Allocator,
    io: std.Io,
    server_configs: []const config_mod.ServerConfig,
    environ_map: ?*const std.process.Environ.Map,
    cancel: *stream_mod.Cancel,
    client_out: *McpClient,
) ![]at.AgentTool {
    var tools: std.ArrayList(at.AgentTool) = .empty;
    var ctxs: std.ArrayList(McpToolCtx) = .empty;
    errdefer {
        tools.deinit(arena);
        ctxs.deinit(arena);
    }

    for (server_configs) |srv| {
        if (srv.transport != .http) continue; // Only http for now.

        // Initialize the remote server.
        const init_result = callRemote(
            arena,
            io,
            srv,
            environ_map,
            cancel,
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"franky\",\"version\":\"0.29.0\"}}}",
        ) catch |err| {
            logWarn(io, "mcp-client", "initialize failed for {s}: {s}", .{ srv.name, @errorName(err) });
            continue;
        };
        defer arena.free(init_result);

        // List tools.
        const list_result = callRemote(
            arena,
            io,
            srv,
            environ_map,
            cancel,
            "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{}}",
        ) catch |err| {
            logWarn(io, "mcp-client", "tools/list failed for {s}: {s}", .{ srv.name, @errorName(err) });
            continue;
        };
        defer arena.free(list_result);

        // Parse the tools/list response.
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, list_result, .{}) catch {
            logWarn(io, "mcp-client", "invalid JSON from {s} tools/list", .{srv.name});
            continue;
        };
        if (parsed != .object) continue;
        const result_obj = parsed.object.get("result") orelse continue;
        if (result_obj != .object) continue;
        const tools_arr = result_obj.object.get("tools") orelse continue;
        if (tools_arr != .array) continue;

        for (tools_arr.array.items) |tool_val| {
            if (tool_val != .object) continue;
            const to = tool_val.object;

            const remote_name = if (to.get("name")) |n| (if (n == .string) n.string else "") else "";
            if (remote_name.len == 0) continue;

            const desc = if (to.get("description")) |d| (if (d == .string) d.string else "") else "";

            // Re-serialize inputSchema to a JSON string.
            var schema_buf: std.ArrayList(u8) = .empty;
            if (to.get("inputSchema")) |schema| {
                renderJson(&schema_buf, arena, schema) catch {};
            }
            if (schema_buf.items.len == 0) {
                schema_buf.appendSlice(arena, "{\"type\":\"object\",\"properties\":{}}") catch {};
            }
            const input_schema = schema_buf.toOwnedSlice(arena) catch continue;

            // Namespaced name: mcp__server__tool
            const ns_name = std.fmt.allocPrint(arena, "mcp__{s}__{s}", .{ srv.name, remote_name }) catch continue;

            const ctx = try arena.create(McpToolCtx);
            ctx.* = .{
                .url = srv.url,
                .headers = srv.headers,
                .tool_name = try arena.dupe(u8, remote_name),
                .description = try arena.dupe(u8, desc),
                .input_schema_json = input_schema,
                .server_name = srv.name,
            };

            try ctxs.append(arena, ctx.*);
            try tools.append(arena, at.AgentTool{
                .name = ns_name,
                .description = ctx.description,
                .parameters_json = ctx.input_schema_json,
                .ctx = @ptrCast(ctx),
                .execute = executeMcpTool,
            });
        }
    }

    client_out.* = .{
        .tool_ctxs = try ctxs.toOwnedSlice(arena),
        .arena = arena,
    };
    return tools.toOwnedSlice(arena);
}

/// Execute function for MCP-proxied tools. Sends a `tools/call`
/// JSON-RPC request to the remote server and translates the
/// response to a franky `ToolResult`.
fn executeMcpTool(
    tool: *const at.AgentTool,
    allocator: std.mem.Allocator,
    io: std.Io,
    call_id: []const u8,
    args_json: []const u8,
    cancel: *stream_mod.Cancel,
    on_update: at.OnUpdate,
) anyerror!at.ToolResult {
    _ = call_id;
    _ = on_update;
    const ctx: *McpToolCtx = @ptrCast(@alignCast(tool.ctx.?));

    // Build the tools/call request. `arguments` is the raw args_json
    // from the agent — we embed it directly as the JSON value.
    var req_buf: std.ArrayList(u8) = .empty;
    defer req_buf.deinit(allocator);
    try req_buf.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":");
    try appendJsonStr(&req_buf, allocator, ctx.tool_name);
    try req_buf.appendSlice(allocator, ",\"arguments\":");
    // args_json is already a JSON object string; embed raw.
    if (args_json.len > 0) {
        try req_buf.appendSlice(allocator, args_json);
    } else {
        try req_buf.appendSlice(allocator, "{}");
    }
    try req_buf.appendSlice(allocator, "}}");

    const env_map: ?*const std.process.Environ.Map = null; // Not needed for call — headers already resolved.
    const response = try callRemote(allocator, io, .{
        .name = ctx.server_name,
        .transport = .http,
        .url = ctx.url,
        .headers = ctx.headers,
    }, env_map, cancel, req_buf.items);
    defer allocator.free(response);

    // Parse the response.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, aa, response, .{}) catch
        return common.toolError(allocator, "mcp_parse", "invalid JSON response from MCP server");
    if (parsed != .object) return common.toolError(allocator, "mcp_parse", "invalid MCP response");

    // Check for JSON-RPC error.
    if (parsed.object.get("error")) |err_val| if (err_val == .object) {
        const msg = if (err_val.object.get("message")) |m| (if (m == .string) m.string else "MCP server error") else "MCP server error";
        return common.toolError(allocator, "mcp_remote", try allocator.dupe(u8, msg));
    };

    // Extract result.content → ToolResult.content.
    const result_obj = parsed.object.get("result") orelse
        return common.toolError(allocator, "mcp_parse", "MCP response missing result");
    if (result_obj != .object) return common.toolError(allocator, "mcp_parse", "MCP result not an object");

    const is_error = if (result_obj.object.get("isError")) |ie| (ie == .bool and ie.bool) else false;
    const content_arr = result_obj.object.get("content") orelse
        return common.toolError(allocator, "mcp_parse", "MCP result missing content");
    if (content_arr != .array) return common.toolError(allocator, "mcp_parse", "MCP content not an array");

    // Translate MCP content blocks → franky ContentBlocks.
    var blocks: std.ArrayList(ai.types.ContentBlock) = .empty;
    errdefer {
        for (blocks.items) |cb| cb.deinit(allocator);
        blocks.deinit(allocator);
    }
    for (content_arr.array.items) |item| {
        if (item != .object) continue;
        const io_obj = item.object;
        const block_type = if (io_obj.get("type")) |t| (if (t == .string) t.string else "") else "";
        if (std.mem.eql(u8, block_type, "text")) {
            const text = if (io_obj.get("text")) |t| (if (t == .string) t.string else "") else "";
            try blocks.append(allocator, .{ .text = .{ .text = try allocator.dupe(u8, text) } });
        } else if (std.mem.eql(u8, block_type, "image")) {
            const data = if (io_obj.get("data")) |d| (if (d == .string) d.string else "") else "";
            const mime = if (io_obj.get("mimeType")) |m| (if (m == .string) m.string else "image/png") else "image/png";
            try blocks.append(allocator, .{ .image = .{
                .data = try allocator.dupe(u8, data),
                .mime_type = try allocator.dupe(u8, mime),
            } });
        }
        // Other block types (resource, etc.) are skipped for now.
    }

    if (blocks.items.len == 0) {
        // No content blocks — return a placeholder.
        try blocks.append(allocator, .{ .text = .{ .text = try allocator.dupe(u8, "") } });
    }

    return .{
        .content = try blocks.toOwnedSlice(allocator),
        .is_error = is_error,
    };
}

/// Send a single JSON-RPC POST to an MCP server and return the
/// response body. Allocates the result on `allocator`.
fn callRemote(
    allocator: std.mem.Allocator,
    io: std.Io,
    srv: config_mod.ServerConfig,
    environ_map: ?*const std.process.Environ.Map,
    cancel: *stream_mod.Cancel,
    payload: []const u8,
) ![]u8 {
    var client = http_mod.Client{ .allocator = allocator, .io = io };
    var proxy_arena: ?std.heap.ArenaAllocator = null;
    defer {
        client.deinit();
        if (proxy_arena) |*a| a.deinit();
    }
    if (environ_map) |em| {
        proxy_arena = try http_mod.setupClientFromEnv(&client, allocator, em);
    }

    // Build headers: server-configured headers + content-type + accept.
    const cfg_headers = srv.headers;
    var headers_buf = try allocator.alloc(std.http.Header, cfg_headers.len + 2);
    defer allocator.free(headers_buf);
    var hi: usize = 0;
    for (cfg_headers) |h| {
        headers_buf[hi] = .{ .name = h.name, .value = h.value };
        hi += 1;
    }
    headers_buf[hi] = .{ .name = "content-type", .value = "application/json" };
    hi += 1;
    headers_buf[hi] = .{ .name = "accept", .value = "application/json, text/event-stream" };
    hi += 1;

    var bw = std.Io.Writer.Allocating.init(allocator);
    defer bw.deinit();

    var phase_info: http_mod.PhaseInfo = .{};
    const result = http_mod.fetchWithRetryAndTimeoutsAndHooksAndPhases(
        &client,
        .{
            .location = .{ .url = srv.url },
            .method = .POST,
            .payload = payload,
            .extra_headers = headers_buf[0..hi],
        },
        &bw,
        cancel,
        .{ .max_retries = 1 },
        .{ .connect_ms = 10_000, .upload_ms = 15_000, .first_byte_ms = 30_000, .event_gap_ms = 0 },
        .{},
        &phase_info,
    ) catch |e| {
        if (phase_info.timed_out_phase != .none) return error.Timeout;
        return e;
    };

    const status: u16 = @intFromEnum(result.status);
    if (status == 401 or status == 403) return error.Unauthorized;
    if (status == 429) return error.RateLimited;
    if (status >= 400) return error.HttpErrorStatus;

    return allocator.dupe(u8, bw.written());
}

// ─── helpers ────────────────────────────────────────────────────

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

fn logWarn(io: std.Io, scope: []const u8, comptime fmt: []const u8, args: anytype) void {
    _ = io;
    _ = scope;
    _ = fmt;
    _ = args;
}
