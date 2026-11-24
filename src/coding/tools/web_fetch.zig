//! web_fetch tool.
//!
//! POST url → page title + content. Backed by the same pluggable
//! provider model as `web_search`; shared transport, ctx, and
//! helpers live in `web_search.zig`.

const std = @import("std");
const ct = @import("../types.zig");
const at = ct.agent.types;
const ai = ct.ai;
const utils = @import("../../ai/utils.zig");
const common = @import("common.zig");
const web_search = @import("web_search.zig");

pub const Provider = web_search.Provider;
pub const WebSearchCtx = web_search.WebSearchCtx;

fn fetchEndpoint(p: Provider) []const u8 {
    return switch (p) {
        .ollama => "https://ollama.com/api/web_fetch",
    };
}

pub const parameters_json: []const u8 =
    \\{
    \\  "type": "object",
    \\  "required": ["url"],
    \\  "properties": {
    \\    "url": {"type": "string"}
    \\  },
    \\  "additionalProperties": false
    \\}
;

pub fn tool() at.AgentTool {
    return .{
        .name = "web_fetch",
        .description = "Fetch the full content of a web page by URL. Returns the page title and main text.",
        .parameters_json = parameters_json,
        .execution_mode = .parallel,
        .execute = executeFetch,
    };
}

pub fn toolWithCtx(ctx: *const WebSearchCtx) at.AgentTool {
    return .{
        .name = "web_fetch",
        .description = "Fetch the full content of a web page by URL. Returns the page title and main text.",
        .parameters_json = parameters_json,
        .execution_mode = .parallel,
        .ctx = @ptrCast(@constCast(ctx)),
        .execute = executeFetch,
    };
}

fn executeFetch(
    self: *const at.AgentTool,
    allocator: std.mem.Allocator,
    io: std.Io,
    _: []const u8,
    args_json: []const u8,
    cancel: *ai.stream.Cancel,
    _: at.OnUpdate,
) anyerror!at.ToolResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const json_to_parse = common.repairConcatJson(arena.allocator(), args_json) orelse args_json;
    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), json_to_parse, .{});
    const root = parsed.value;

    const url_v = root.object.get("url") orelse
        return common.toolError(allocator, "invalid_args", "missing url");
    if (url_v != .string) return common.toolError(allocator, "invalid_args", "url must be a string");
    const url = url_v.string;

    const ctx = web_search.ctxFromSelf(self);
    const provider: Provider = if (ctx) |c| c.provider else .ollama;
    const api_key = web_search.resolveApiKey(ctx, provider);
    const environ_map: ?*const std.process.Environ.Map = if (ctx) |c| c.environ_map else null;

    const body = try std.json.Stringify.valueAlloc(allocator, .{ .url = url }, .{});
    defer allocator.free(body);

    const resp = web_search.doPost(allocator, io, cancel, fetchEndpoint(provider), api_key, body, environ_map) catch |e|
        return web_search.httpError(allocator, "web_fetch", e);
    defer allocator.free(resp);

    return parseFetchResponse(allocator, resp, url);
}

fn parseFetchResponse(
    allocator: std.mem.Allocator,
    body: []const u8,
    url: []const u8,
) !at.ToolResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), body, .{}) catch
        return common.toolError(allocator, "web_fetch_parse", "invalid JSON response from provider");

    const root = parsed.value;
    if (root != .object)
        return common.toolError(allocator, "web_fetch_parse", "unexpected response shape");

    const title = web_search.strField(root, "title");
    const content = web_search.strField(root, "content");

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    {
        const hdr = try std.fmt.allocPrint(allocator, "Page: {s}\nTitle: {s}\n\n", .{ url, title });
        defer allocator.free(hdr);
        try out.appendSlice(allocator, hdr);
    }
    try out.appendSlice(allocator, content);
    if (content.len > 0 and content[content.len - 1] != '\n') try out.append(allocator, '\n');

    return web_search.makeTextResult(allocator, out.items);
}

// ─── tests ───────────────────────────────────────────────────────

const testing = std.testing;

test "parseFetchResponse: formats title and content" {
    const gpa = testing.allocator;
    const body =
        \\{"title":"Ollama","content":"Ollama is an open-source tool.","links":["https://ollama.com"]}
    ;
    var res = try parseFetchResponse(gpa, body, "https://ollama.com");
    defer res.deinit(gpa);
    try testing.expect(!res.is_error);
    const text = res.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, text, "Title: Ollama") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Ollama is an open-source tool.") != null);
}

test "tool: name and schema are correct" {
    const t = tool();
    try testing.expectEqualStrings("web_fetch", t.name);
    try testing.expect(std.mem.indexOf(u8, t.parameters_json, "\"url\"") != null);
}
