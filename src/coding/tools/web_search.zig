//! web_search tool.
//!
//! POST query → ranked results (title, url, snippet). The companion
//! `web_fetch` tool lives in `web_fetch.zig` and reuses this module's
//! `Provider`, `WebSearchCtx`, and HTTP helpers.
//!
//! Provider abstraction — add a new one by:
//!   1. Extending the `Provider` enum.
//!   2. Adding a branch to `searchEndpoint` (here) and
//!      `fetchEndpoint` (in `web_fetch.zig`), plus `envKeyName`.
//!   All providers share the same HTTP transport (`doPost`).
//!
//! Currently implemented:
//!   `ollama`  — https://ollama.com/api/{web_search,web_fetch}
//!               Bearer token from `ctx.api_key` or `OLLAMA_API_KEY`.

const std = @import("std");
const ct = @import("../types.zig");
const at = ct.agent.types;
const ai = ct.ai;
const http_mod = @import("../../ai/http.zig");
const utils = @import("../../ai/utils.zig");
const common = @import("common.zig");

// ─── provider abstraction ─────────────────────────────────────────

pub const Provider = enum {
    ollama,
    // future: brave, tavily, serper, …
};

fn searchEndpoint(p: Provider) []const u8 {
    return switch (p) {
        .ollama => "https://ollama.com/api/web_search",
    };
}

pub fn envKeyName(p: Provider) []const u8 {
    return switch (p) {
        .ollama => "OLLAMA_API_KEY",
    };
}

// ─── ctx ─────────────────────────────────────────────────────────

pub const WebSearchCtx = struct {
    provider: Provider = .ollama,
    /// Pre-resolved key. When null, `execute` looks up `envKeyName(provider)`
    /// in `environ_map`. Both may be null for anonymous access (provider may
    /// still accept the request).
    api_key: ?[]const u8 = null,
    /// Passed to `http.setupClientFromEnv` for proxy support.
    environ_map: ?*const std.process.Environ.Map = null,
};

// ─── parameters schema ───────────────────────────────────────────

pub const parameters_json: []const u8 =
    \\{
    \\  "type": "object",
    \\  "required": ["query"],
    \\  "properties": {
    \\    "query": {
    \\      "oneOf": [
    \\        {"type": "string"},
    \\        {"type": "array", "items": {"type": "string"}, "minItems": 1}
    \\      ]
    \\    },
    \\    "max_results": {"type": "integer", "minimum": 1, "maximum": 10, "default": 5}
    \\  },
    \\  "additionalProperties": false
    \\}
;

// ─── tool factories ──────────────────────────────────────────────

pub fn tool() at.AgentTool {
    return .{
        .name = "web_search",
        .description = "Search the web for current information. Returns ranked results with titles, URLs and content snippets.",
        .parameters_json = parameters_json,
        .execution_mode = .parallel,
        .execute = executeSearch,
    };
}

pub fn toolWithCtx(ctx: *const WebSearchCtx) at.AgentTool {
    return .{
        .name = "web_search",
        .description = "Search the web for current information. Returns ranked results with titles, URLs and content snippets.",
        .parameters_json = parameters_json,
        .execution_mode = .parallel,
        .ctx = @ptrCast(@constCast(ctx)),
        .execute = executeSearch,
    };
}

// ─── execute ─────────────────────────────────────────────────────

fn executeSearch(
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

    const query_v = root.object.get("query") orelse
        return common.toolError(allocator, "invalid_args", "missing query");

    const max_results: u32 = if (root.object.get("max_results")) |v|
        if (v == .integer and v.integer >= 1 and v.integer <= 10) @intCast(v.integer) else 5
    else
        5;

    const ctx = ctxFromSelf(self);
    const provider: Provider = if (ctx) |c| c.provider else .ollama;
    const api_key = resolveApiKey(ctx, provider);
    const environ_map: ?*const std.process.Environ.Map = if (ctx) |c| c.environ_map else null;

    // Collect all query strings (single string or array of strings).
    var queries: std.ArrayList([]const u8) = .empty;
    defer queries.deinit(allocator);

    if (query_v == .string) {
        try queries.append(allocator, query_v.string);
    } else if (query_v == .array) {
        if (query_v.array.items.len == 0)
            return common.toolError(allocator, "invalid_args", "query array must not be empty");
        for (query_v.array.items) |item| {
            if (item != .string)
                return common.toolError(allocator, "invalid_args", "each query in array must be a string");
            try queries.append(allocator, item.string);
        }
    } else {
        return common.toolError(allocator, "invalid_args", "query must be a string or array of strings");
    }

    // Run one search per query and combine results.
    var combined: std.ArrayList(u8) = .empty;
    defer combined.deinit(allocator);

    for (queries.items, 0..) |q, i| {
        if (i > 0) try combined.appendSlice(allocator, "\n---\n\n");

        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(allocator);
        try body.appendSlice(allocator, "{\"query\":");
        try utils.appendJsonStr(&body, allocator, q);
        {
            var num: [16]u8 = undefined;
            try body.appendSlice(allocator, ",\"max_results\":");
            try body.appendSlice(allocator, std.fmt.bufPrint(&num, "{d}", .{max_results}) catch unreachable);
        }
        try body.append(allocator, '}');

        const resp = doPost(allocator, io, cancel, searchEndpoint(provider), api_key, body.items, environ_map) catch |e|
            return httpError(allocator, "web_search", e);
        defer allocator.free(resp);

        var parsed_res = try parseSearchResponse(allocator, resp, q);
        defer parsed_res.deinit(allocator);
        try combined.appendSlice(allocator, parsed_res.content[0].text.text);
    }

    return makeTextResult(allocator, combined.items);
}

// ─── HTTP transport (shared with web_fetch) ──────────────────────

/// POST `body` to `url` with optional Bearer auth. Returns the owned
/// response body on success; propagates transport errors to caller.
/// Caller frees the returned slice.
pub fn doPost(
    allocator: std.mem.Allocator,
    io: std.Io,
    cancel: *ai.stream.Cancel,
    url: []const u8,
    api_key: ?[]const u8,
    body: []const u8,
    environ_map: ?*const std.process.Environ.Map,
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

    var bw = std.Io.Writer.Allocating.init(allocator);
    defer bw.deinit();

    // Build auth header value into a stack buffer (key ≤ 256 bytes is safe).
    var auth_buf: [280]u8 = undefined;
    var headers_buf: [3]std.http.Header = undefined;
    var n_headers: usize = 0;
    if (api_key) |k| {
        const auth_val = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{k}) catch
            return error.ApiKeyTooLong;
        headers_buf[n_headers] = .{ .name = "authorization", .value = auth_val };
        n_headers += 1;
    }
    headers_buf[n_headers] = .{ .name = "content-type", .value = "application/json" };
    n_headers += 1;
    headers_buf[n_headers] = .{ .name = "accept", .value = "application/json" };
    n_headers += 1;

    var phase_info: http_mod.PhaseInfo = .{};
    const result = http_mod.fetchWithRetryAndTimeoutsAndHooksAndPhases(
        &client,
        .{
            .location = .{ .url = url },
            .method = .POST,
            .payload = body,
            .extra_headers = headers_buf[0..n_headers],
        },
        &bw,
        cancel,
        .{ .max_retries = 1 },
        .{ .connect_ms = 5_000, .upload_ms = 10_000, .first_byte_ms = 15_000, .event_gap_ms = 0 },
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

// ─── response parsing ─────────────────────────────────────────────

fn parseSearchResponse(
    allocator: std.mem.Allocator,
    body: []const u8,
    query: []const u8,
) !at.ToolResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), body, .{}) catch
        return common.toolError(allocator, "web_search_parse", "invalid JSON response from provider");

    const root = parsed.value;
    if (root != .object)
        return common.toolError(allocator, "web_search_parse", "unexpected response shape");

    const results_v = root.object.get("results") orelse
        return common.toolError(allocator, "web_search_parse", "missing `results` in response");
    if (results_v != .array)
        return common.toolError(allocator, "web_search_parse", "`results` is not an array");

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    {
        const hdr = try std.fmt.allocPrint(allocator, "Search results for: {s}\n\n", .{query});
        defer allocator.free(hdr);
        try out.appendSlice(allocator, hdr);
    }

    for (results_v.array.items, 0..) |r, i| {
        if (r != .object) continue;
        const title = strField(r, "title");
        const url = strField(r, "url");
        const content = strField(r, "content");
        const entry = try std.fmt.allocPrint(allocator, "[{d}] {s}\nURL: {s}\n{s}\n\n", .{ i + 1, title, url, content });
        defer allocator.free(entry);
        try out.appendSlice(allocator, entry);
    }
    if (results_v.array.items.len == 0) {
        try out.appendSlice(allocator, "(no results)\n");
    }

    return makeTextResult(allocator, out.items);
}

// ─── helpers (shared with web_fetch) ─────────────────────────────

pub fn ctxFromSelf(self: *const at.AgentTool) ?*const WebSearchCtx {
    const raw = self.ctx orelse return null;
    return @ptrCast(@alignCast(raw));
}

pub fn resolveApiKey(ctx: ?*const WebSearchCtx, provider: Provider) ?[]const u8 {
    const c = ctx orelse return null;
    if (c.api_key) |k| return k;
    if (c.environ_map) |em| if (em.get(envKeyName(provider))) |k| return k;
    return null;
}

pub fn strField(v: std.json.Value, key: []const u8) []const u8 {
    const f = v.object.get(key) orelse return "";
    return if (f == .string) f.string else "";
}

pub fn makeTextResult(allocator: std.mem.Allocator, text: []const u8) !at.ToolResult {
    const owned = try allocator.dupe(u8, text);
    const arr = try allocator.alloc(ai.types.ContentBlock, 1);
    arr[0] = .{ .text = .{ .text = owned } };
    return .{ .content = arr };
}

pub fn httpError(allocator: std.mem.Allocator, code: []const u8, e: anyerror) !at.ToolResult {
    const msg: []const u8 = switch (e) {
        error.Unauthorized => "unauthorized — set OLLAMA_API_KEY or pass --web-search-api-key",
        error.RateLimited => "rate limited — back off and retry",
        error.Timeout => "request timed out",
        error.ApiKeyTooLong => "API key exceeds 256 bytes",
        else => return common.toolError(allocator, code, @errorName(e)),
    };
    return common.toolError(allocator, code, msg);
}

// ─── tests ───────────────────────────────────────────────────────

const testing = std.testing;

test "parseSearchResponse: formats results correctly" {
    const gpa = testing.allocator;
    const body =
        \\{"results":[
        \\  {"title":"Ollama","url":"https://ollama.com","content":"Run models locally."},
        \\  {"title":"Blog","url":"https://ollama.com/blog","content":"Latest news."}
        \\]}
    ;
    var res = try parseSearchResponse(gpa, body, "ollama");
    defer res.deinit(gpa);
    try testing.expect(!res.is_error);
    const text = res.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, text, "Search results for: ollama") != null);
    try testing.expect(std.mem.indexOf(u8, text, "[1] Ollama") != null);
    try testing.expect(std.mem.indexOf(u8, text, "https://ollama.com") != null);
    try testing.expect(std.mem.indexOf(u8, text, "[2] Blog") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Run models locally.") != null);
}

test "parseSearchResponse: empty results array" {
    const gpa = testing.allocator;
    var res = try parseSearchResponse(gpa, "{\"results\":[]}", "nothing");
    defer res.deinit(gpa);
    try testing.expect(!res.is_error);
    try testing.expect(std.mem.indexOf(u8, res.content[0].text.text, "(no results)") != null);
}

test "parseSearchResponse: invalid JSON returns error result" {
    const gpa = testing.allocator;
    var res = try parseSearchResponse(gpa, "not json", "q");
    defer res.deinit(gpa);
    try testing.expect(res.is_error);
    try testing.expect(std.mem.indexOf(u8, res.content[0].text.text, "web_search_parse") != null);
}

test "resolveApiKey: prefers ctx.api_key over env" {
    var env_map = std.process.Environ.Map.init(testing.allocator);
    defer env_map.deinit();
    try env_map.put("OLLAMA_API_KEY", "env-key");

    const ctx = WebSearchCtx{ .api_key = "direct-key", .environ_map = &env_map };
    try testing.expectEqualStrings("direct-key", resolveApiKey(&ctx, .ollama).?);
}

test "resolveApiKey: falls back to env when api_key is null" {
    var env_map = std.process.Environ.Map.init(testing.allocator);
    defer env_map.deinit();
    try env_map.put("OLLAMA_API_KEY", "env-key");

    const ctx = WebSearchCtx{ .environ_map = &env_map };
    try testing.expectEqualStrings("env-key", resolveApiKey(&ctx, .ollama).?);
}

test "resolveApiKey: returns null when neither is set" {
    const ctx = WebSearchCtx{};
    try testing.expect(resolveApiKey(&ctx, .ollama) == null);
}

test "tool: name and schema are correct" {
    const t = tool();
    try testing.expectEqualStrings("web_search", t.name);
    try testing.expect(std.mem.indexOf(u8, t.parameters_json, "\"query\"") != null);
    try testing.expect(std.mem.indexOf(u8, t.parameters_json, "max_results") != null);
}
