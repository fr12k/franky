//! OpenAI Chat Completions provider — §A.3 of the spec.
//!
//! Registers under api tag `openai-chat-completions`. The §A.6
//! gateway provider (`v0.3.4`) re-registers the same tag under
//! `openai-compatible-gateway` with a configurable base URL + auth
//! header; this file owns the wire format.
//!
//! Endpoint: `POST /v1/chat/completions` with `Authorization: Bearer
//! <key>` and `stream: true`.
//!
//! SSE is simpler than Anthropic's: every event is an unnamed
//! `data: {…chunk…}\n\n` frame; a final `data: [DONE]\n\n` sentinel
//! marks end-of-stream. Each chunk's `choices[0].delta` carries
//! optional `role`, `content`, `tool_calls[i].{index,id,function.{name,
//! arguments}}`, and a `finish_reason` on the last non-usage chunk.
//! When `stream_options.include_usage` is set, a final chunk with
//! empty `choices` and a top-level `usage` object precedes `[DONE]`.
//!
//! Tool-call `arguments` stream as **string fragments** — they are
//! concatenated by the reducer, not parsed per-chunk. This matches
//! Anthropic's `input_json_delta` invariant and is what the stream
//! reducer already expects.

const std = @import("std");
const types = @import("../types.zig");
const errors = @import("../errors.zig");
const stream_mod = @import("../stream.zig");
const channel_mod = @import("../channel.zig");
const registry_mod = @import("../registry.zig");
const sse_mod = @import("../sse.zig");
const http_mod = @import("../http.zig");
const log = @import("../log.zig");
const utils = @import("../utils.zig");
const schema_sanitize = @import("../schema_sanitize.zig");

const Channel = channel_mod.Channel(stream_mod.StreamEvent);

pub const default_endpoint: []const u8 = "https://api.openai.com/v1/chat/completions";

// ─── request serialization ────────────────────────────────────────

pub fn buildRequestJson(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: registry_mod.StreamOptions,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"model\":");
    try utils.appendJsonStr(&buf, allocator, model.id);

    try buf.appendSlice(allocator, ",\"stream\":true");
    try buf.appendSlice(allocator, ",\"stream_options\":{\"include_usage\":true}");

    if (options.max_tokens) |mt| {
        try buf.appendSlice(allocator, ",\"max_completion_tokens\":");
        try utils.appendJsonInt(&buf, allocator, @intCast(mt));
    }
    if (options.temperature) |t| {
        try buf.appendSlice(allocator, ",\"temperature\":");
        try utils.appendJsonFloat(&buf, allocator, t);
    }

    // §B reasoning effort — Chat Completions uses the same string values
    // as the Responses API. Models without reasoning support ignore it.
    if (options.thinking.openaiResponsesEffort()) |effort| {
        try buf.appendSlice(allocator, ",\"reasoning_effort\":");
        try utils.appendJsonStr(&buf, allocator, effort);
    }

    if (context.tools.len > 0) {
        try buf.appendSlice(allocator, ",\"tools\":[");
        for (context.tools, 0..) |t, i| {
            if (i > 0) try buf.append(allocator, ',');
            try buf.appendSlice(allocator, "{\"type\":\"function\",\"function\":{\"name\":");
            try utils.appendJsonStr(&buf, allocator, t.name);
            try buf.appendSlice(allocator, ",\"description\":");
            try utils.appendJsonStr(&buf, allocator, t.description);
            try buf.appendSlice(allocator, ",\"parameters\":");
            // v1.30.0 — sanitize tool schemas before sending. Some
            // OpenAI-compatible gateways (GLM, Cloudflare Workers AI)
            // reject JSON Schema keywords like `additionalProperties`,
            // `$schema`, `$defs`, and `definitions` with a 400
            // (`request_invalid http_status=400`). Strip them the same
            // way the Gemini provider does.
            try schema_sanitize.appendSanitizedSchema(&buf, allocator, t.parameters_json);
            try buf.appendSlice(allocator, "}}");
        }
        try buf.append(allocator, ']');
    }

    try buf.appendSlice(allocator, ",\"messages\":[");
    var first = true;
    if (context.system_prompt.len > 0) {
        try buf.appendSlice(allocator, "{\"role\":\"system\",\"content\":");
        try utils.appendJsonStr(&buf, allocator, context.system_prompt);
        try buf.append(allocator, '}');
        first = false;
    }
    for (context.messages) |m| {
        if (!try appendMessage(&buf, allocator, m, first)) continue;
        first = false;
    }
    try buf.append(allocator, ']');

    try buf.append(allocator, '}');
    return buf.toOwnedSlice(allocator);
}

fn appendMessage(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    m: types.Message,
    first: bool,
) !bool {
    switch (m.role) {
        .custom => return false,
        .user, .tool_result, .assistant => {},
    }
    if (!first) try buf.append(allocator, ',');

    switch (m.role) {
        .user => try appendUserMessage(buf, allocator, m),
        .assistant => try appendAssistantMessage(buf, allocator, m),
        .tool_result => try appendToolResultMessage(buf, allocator, m),
        .custom => unreachable,
    }
    return true;
}

fn appendUserMessage(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    m: types.Message,
) !void {
    try buf.appendSlice(allocator, "{\"role\":\"user\",\"content\":");
    // Simple shape: single text block → plain string.
    // Multi/image → array of content parts.
    if (m.content.len == 1 and m.content[0] == .text) {
        try utils.appendJsonStr(buf, allocator, m.content[0].text.text);
    } else {
        try buf.append(allocator, '[');
        for (m.content, 0..) |cb, i| {
            if (i > 0) try buf.append(allocator, ',');
            try appendUserContentPart(buf, allocator, cb);
        }
        try buf.append(allocator, ']');
    }
    try buf.append(allocator, '}');
}

fn appendUserContentPart(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    cb: types.ContentBlock,
) !void {
    switch (cb) {
        .text => |t| {
            try buf.appendSlice(allocator, "{\"type\":\"text\",\"text\":");
            try utils.appendJsonStr(buf, allocator, t.text);
            try buf.append(allocator, '}');
        },
        .image => |img| {
            // OpenAI accepts data: URIs for inline images.
            try buf.appendSlice(allocator, "{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:");
            try utils.appendJsonRaw(buf, allocator, img.mime_type);
            try buf.appendSlice(allocator, ";base64,");
            try utils.appendJsonRaw(buf, allocator, img.data);
            try buf.appendSlice(allocator, "\"}}");
        },
        // Thinking / tool_call blocks are never inside a user message
        // in a valid transcript; fall back to a safe placeholder.
        else => try buf.appendSlice(allocator, "{\"type\":\"text\",\"text\":\"[unsupported block]\"}"),
    }
}

fn appendAssistantMessage(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    m: types.Message,
) !void {
    try buf.appendSlice(allocator, "{\"role\":\"assistant\"");

    // Split content into text vs tool_call blocks.
    var text_buf: std.ArrayList(u8) = .empty;
    defer text_buf.deinit(allocator);
    var tool_calls: std.ArrayList(types.ToolCall) = .empty;
    defer tool_calls.deinit(allocator);

    for (m.content) |cb| switch (cb) {
        .text => |t| try text_buf.appendSlice(allocator, t.text),
        .tool_call => |tc| try tool_calls.append(allocator, tc),
        // thinking blocks are not re-sent in Chat Completions.
        .thinking, .image => {},
    };

    if (text_buf.items.len > 0) {
        try buf.appendSlice(allocator, ",\"content\":");
        try utils.appendJsonStr(buf, allocator, text_buf.items);
    } else if (tool_calls.items.len > 0) {
        try buf.appendSlice(allocator, ",\"content\":null");
    } else {
        try buf.appendSlice(allocator, ",\"content\":\"\"");
    }

    if (tool_calls.items.len > 0) {
        try buf.appendSlice(allocator, ",\"tool_calls\":[");
        for (tool_calls.items, 0..) |tc, i| {
            if (i > 0) try buf.append(allocator, ',');
            try buf.appendSlice(allocator, "{\"id\":");
            try utils.appendJsonStr(buf, allocator, tc.id);
            try buf.appendSlice(allocator, ",\"type\":\"function\",\"function\":{\"name\":");
            try utils.appendJsonStr(buf, allocator, tc.name);
            try buf.appendSlice(allocator, ",\"arguments\":");
            // `arguments` must be a string in Chat Completions even
            // though it's JSON underneath. Escape as a string.
            //
            // v1.16.2 — sanitize first: strict openai-compat gateways
            // (Cloudflare Workers AI) reparse the inner string as
            // JSON, so a model that emitted an invalid escape (e.g.
            // `\c`) would 400 the next request. `sanitizeJsonString`
            // doubles malformed backslashes so the inner JSON parses.
            const raw_args = if (tc.arguments_json.len == 0) "{}" else tc.arguments_json;
            const safe_args = try utils.sanitizeJsonString(allocator, raw_args);
            defer allocator.free(safe_args);
            try utils.appendJsonStr(buf, allocator, safe_args);
            try buf.appendSlice(allocator, "}}");
        }
        try buf.append(allocator, ']');
    }
    try buf.append(allocator, '}');
}

fn appendToolResultMessage(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    m: types.Message,
) !void {
    try buf.appendSlice(allocator, "{\"role\":\"tool\",\"tool_call_id\":");
    try utils.appendJsonStr(buf, allocator, m.tool_call_id orelse "");
    try buf.appendSlice(allocator, ",\"content\":");
    var text_buf: std.ArrayList(u8) = .empty;
    defer text_buf.deinit(allocator);
    for (m.content) |cb| switch (cb) {
        .text => |t| try text_buf.appendSlice(allocator, t.text),
        else => {},
    };
    try utils.appendJsonStr(buf, allocator, text_buf.items);
    try buf.append(allocator, '}');
}

// ─── SSE → StreamEvent ────────────────────────────────────────────

pub fn runFromSse(
    allocator: std.mem.Allocator,
    io: std.Io,
    sse_body: []const u8,
    out: *Channel,
    cancel: *stream_mod.Cancel,
) !void {
    return runFromSseWithTrace(allocator, io, sse_body, out, cancel, null);
}

/// v1.29.0 — runFromSse + trace_id. Channel takes ownership.
pub fn runFromSseWithTrace(
    allocator: std.mem.Allocator,
    io: std.Io,
    sse_body: []const u8,
    out: *Channel,
    cancel: *stream_mod.Cancel,
    trace_id: ?[]u8,
) !void {
    try out.push(io, .start);
    stream_mod.pushTraceId(out, io, allocator, trace_id);

    var driver = Driver{
        .allocator = allocator,
        .io = io,
        .out = out,
    };
    defer driver.deinit();

    const result = http_mod.driveSseFromBytes(
        allocator,
        sse_body,
        cancel,
        Driver.onEvent,
        @ptrCast(&driver),
    );

    if (result) |_| {
        if (!driver.closed) {
            stream_mod.closeWithDiagnostics(out, io, allocator, .{
                .provider = "openai-chat",
                .stop_reason = driver.stop_reason orelse .stop,
                .text_seen = driver.text_seen,
                .thinking_seen = driver.thinking_seen,
                .tool_count = driver.seen_tool_slots,
                .parts_seen = driver.parts_seen,
                .finish_reason_raw = driver.finish_reason_owned,
                .candidates_tokens = driver.candidates_tokens,
            });
        }
    } else |e| switch (e) {
        error.Aborted => out.closeWithFinal(io, .{ .error_ev = .{
            .code = .aborted,
            .message = try allocator.dupe(u8, "cancelled"),
        } }),
        error.ProtocolViolation => out.closeWithFinal(io, .{ .error_ev = .{
            .code = .protocol_violation,
            .message = try allocator.dupe(u8, "malformed SSE stream"),
        } }),
        error.OutOfMemory => out.closeWithFinal(io, .{ .error_ev = .{
            .code = .internal,
            .message = try allocator.dupe(u8, "out of memory"),
        } }),
        error.Timeout => out.closeWithFinal(io, .{ .error_ev = .{
            .code = .timeout,
            .message = try allocator.dupe(u8, "event gap exceeded timeouts.event_gap_ms"),
        } }),
        error.Handler => out.closeWithFinal(io, .{ .error_ev = .{
            .code = .internal,
            .message = try allocator.dupe(u8, "handler failure"),
        } }),
    }
}

/// Per-stream state. OpenAI's tool_calls carry their own per-call
/// `index` field in the delta shape, so we use that as the local
/// toolcall index. We only need to track which indexes have been
/// `toolcall_start`ed so we don't re-emit the event for subsequent
/// argument-fragment deltas.
const Driver = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    out: *Channel,
    /// Tracks which tool-call slots have been announced with
    /// `toolcall_start`. OpenAI repeats the index on each delta.
    started_tool_slots: std.AutoHashMap(u32, void) = undefined,
    started_init: bool = false,
    /// Have we seen any assistant text yet? Used to emit `toolcall_end`
    /// events at stream close.
    seen_tool_slots: u32 = 0,
    stop_reason: ?types.StopReason = null,
    closed: bool = false,
    /// v1.29.0 — diagnostics. `parts_seen` increments on each
    /// `choices[0].delta` chunk that carried any field; `text_seen`
    /// flips on the first non-empty content delta.
    parts_seen: u32 = 0,
    text_seen: bool = false,
    thinking_seen: bool = false,
    finish_reason_owned: ?[]u8 = null,
    candidates_tokens: ?u64 = null,

    fn lazyInit(self: *Driver) !void {
        if (self.started_init) return;
        self.started_tool_slots = std.AutoHashMap(u32, void).init(self.allocator);
        self.started_init = true;
    }

    fn deinit(self: *Driver) void {
        if (self.started_init) self.started_tool_slots.deinit();
        if (self.finish_reason_owned) |s| self.allocator.free(s);
    }

    fn onEvent(ud: ?*anyopaque, ev: sse_mod.Event) http_mod.EventHandlerError!void {
        const self: *Driver = @ptrCast(@alignCast(ud.?));
        self.lazyInit() catch return http_mod.EventHandlerError.OutOfMemory;
        self.handle(ev.data) catch |e| switch (e) {
            error.OutOfMemory => return http_mod.EventHandlerError.OutOfMemory,
            error.Closed => return http_mod.EventHandlerError.Handler,
        };
    }

    fn handle(self: *Driver, data: []const u8) !void {
        // `[DONE]` sentinel — graceful stream close.
        if (std.mem.eql(u8, std.mem.trim(u8, data, " \t\r\n"), "[DONE]")) {
            var i: u32 = 0;
            while (i < self.seen_tool_slots) : (i += 1) {
                try self.out.push(self.io, .{ .toolcall_end = .{
                    .block_index = i,
                    .args_json = try self.allocator.dupe(u8, ""),
                } });
            }
            stream_mod.closeWithDiagnostics(self.out, self.io, self.allocator, .{
                .provider = "openai-chat",
                .stop_reason = self.stop_reason orelse .stop,
                .text_seen = self.text_seen,
                .thinking_seen = self.thinking_seen,
                .tool_count = self.seen_tool_slots,
                .parts_seen = self.parts_seen,
                .finish_reason_raw = self.finish_reason_owned,
                .candidates_tokens = self.candidates_tokens,
            });
            self.closed = true;
            return;
        }

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), data, .{}) catch return;
        if (parsed.value != .object) return;
        const root = parsed.value.object;

        // Usage-only chunk (final chunk with empty `choices`).
        if (root.get("usage")) |uv| if (uv == .object) {
            const inp: u64 = if (uv.object.get("prompt_tokens")) |v|
                (if (v == .integer) @intCast(v.integer) else 0)
            else
                0;
            const out: u64 = if (uv.object.get("completion_tokens")) |v|
                (if (v == .integer) @intCast(v.integer) else 0)
            else
                0;
            self.candidates_tokens = out;
            try self.out.push(self.io, .{ .usage = .{ .input = inp, .output = out } });
        };

        const choices_val = root.get("choices") orelse return;
        if (choices_val != .array or choices_val.array.items.len == 0) return;
        const choice = choices_val.array.items[0];
        if (choice != .object) return;

        if (choice.object.get("delta")) |dv| if (dv == .object) {
            self.parts_seen +%= 1;
            try self.handleDelta(dv.object);
        };

        if (choice.object.get("finish_reason")) |fr| if (fr == .string) {
            self.stop_reason = mapFinishReason(fr.string);
            if (self.finish_reason_owned) |old| self.allocator.free(old);
            self.finish_reason_owned = self.allocator.dupe(u8, fr.string) catch null;
        };
    }

    fn handleDelta(self: *Driver, delta: std.json.ObjectMap) !void {
        // Content fragment — skip empty strings. DeepSeek (and some other
        // reasoning models) emit `"content":""` on every thinking chunk
        // alongside the `reasoning` field. Forwarding those as empty
        // text_delta events produces spurious `message_update` SSE frames
        // that flip the UI activity indicator to "responding…" during the
        // thinking phase and waste bandwidth on multi-MB reasoning responses.
        if (delta.get("content")) |cv| if (cv == .string and cv.string.len > 0) {
            self.text_seen = true;
            try self.out.push(self.io, .{ .text_delta = .{
                .block_index = 0,
                .delta = try self.allocator.dupe(u8, cv.string),
            } });
        };

        // v1.17.5 — `reasoning_content` (Kimi, DeepSeek, some
        // OpenAI-compat shims) and `reasoning` (others) carry the
        // model's thinking output as a separate field. Without this
        // arm the entire reasoning stream gets silently dropped:
        // a thinking-heavy model can emit megabytes of `reasoning_content`
        // chunks, and franky's UI shows nothing because no `content`
        // arrives. We translate to the existing `thinking_delta`
        // event, the same channel Anthropic's reasoning takes.
        if (delta.get("reasoning_content")) |rv| if (rv == .string) {
            if (rv.string.len > 0) self.thinking_seen = true;
            try self.out.push(self.io, .{ .thinking_delta = .{
                .block_index = 0,
                .delta = try self.allocator.dupe(u8, rv.string),
            } });
        };
        if (delta.get("reasoning")) |rv| if (rv == .string) {
            if (rv.string.len > 0) self.thinking_seen = true;
            try self.out.push(self.io, .{ .thinking_delta = .{
                .block_index = 0,
                .delta = try self.allocator.dupe(u8, rv.string),
            } });
        };

        // Tool-call fragments.
        if (delta.get("tool_calls")) |tv| if (tv == .array) {
            for (tv.array.items) |entry| {
                if (entry != .object) continue;
                const idx_val = entry.object.get("index") orelse continue;
                if (idx_val != .integer) continue;
                const idx: u32 = @intCast(idx_val.integer);

                // Emit toolcall_start once per slot.
                if (!self.started_tool_slots.contains(idx)) {
                    const id = if (entry.object.get("id")) |v|
                        (if (v == .string) v.string else "")
                    else
                        "";
                    const fn_obj = entry.object.get("function");
                    const name = if (fn_obj) |f|
                        (if (f == .object)
                            (if (f.object.get("name")) |n| (if (n == .string) n.string else "") else "")
                        else
                            "")
                    else
                        "";
                    try self.out.push(self.io, .{ .toolcall_start = .{
                        .block_index = idx,
                        .id = try self.allocator.dupe(u8, id),
                        .name = try self.allocator.dupe(u8, name),
                    } });
                    try self.started_tool_slots.put(idx, {});
                    if (idx + 1 > self.seen_tool_slots) self.seen_tool_slots = idx + 1;
                }

                // Emit toolcall_delta for the argument fragment (if any).
                if (entry.object.get("function")) |fnv| if (fnv == .object) {
                    if (fnv.object.get("arguments")) |av| if (av == .string and av.string.len > 0) {
                        try self.out.push(self.io, .{ .toolcall_delta = .{
                            .block_index = idx,
                            .args_delta = try self.allocator.dupe(u8, av.string),
                        } });
                    };
                };
            }
        };
    }
};

fn mapFinishReason(s: []const u8) ?types.StopReason {
    if (std.mem.eql(u8, s, "stop")) return .stop;
    if (std.mem.eql(u8, s, "length")) return .length;
    if (std.mem.eql(u8, s, "tool_calls")) return .tool_use;
    if (std.mem.eql(u8, s, "function_call")) return .tool_use;
    if (std.mem.eql(u8, s, "content_filter")) return .refusal;
    return null;
}

// ─── registry entry ──────────────────────────────────────────────

pub fn streamFn(ctx: registry_mod.StreamCtx) anyerror!void {
    const endpoint: []const u8 = ctx.options.base_url orelse default_endpoint;
    const is_gateway = ctx.options.base_url != null;
    const credential: ?[]const u8 = ctx.options.api_key orelse ctx.options.auth_token;

    // OpenAI proper requires a bearer. Gateways may be local (Ollama,
    // LM Studio, vLLM) and accept anonymous traffic; only error on
    // missing credentials for the canonical openai.com endpoint.
    if (credential == null and !is_gateway) {
        try ctx.out.push(ctx.io, .start);
        ctx.out.closeWithFinal(ctx.io, .{ .error_ev = .{
            .code = errors.Code.auth,
            .message = try ctx.allocator.dupe(
                u8,
                "openai provider: no credential (set --api-key or OPENAI_API_KEY)",
            ),
        } });
        return;
    }

    const body = try buildRequestJson(ctx.allocator, ctx.model, ctx.context, ctx.options);
    defer ctx.allocator.free(body);

    log.log(.debug, "http", "request", "provider=openai model={s} endpoint={s} body_bytes={d}", .{ ctx.model.id, endpoint, body.len });
    log.body(.trace, "http", "request_body", body, 64 * 1024);

    const auth_header: ?[]u8 = if (credential) |c|
        try std.fmt.allocPrint(ctx.allocator, "Bearer {s}", .{c})
    else
        null;
    defer if (auth_header) |h| ctx.allocator.free(h);

    // Build the outgoing header slice. The fixed three (authorization,
    // content-type, accept) are always present; `ctx.options.headers` is
    // merged in afterwards so callers (notably the OpenRouter app-
    // attribution path — see `ai/openrouter_attribution.zig`) can stamp
    // HTTP-Referer / X-OpenRouter-Title / X-OpenRouter-Categories onto
    // every gateway request. Heap-allocated because the count is caller-
    // driven; the slice is tiny and freed before the fn returns.
    const extra = ctx.options.headers orelse &.{ };
    const base_count: usize = (if (auth_header != null) @as(usize, 1) else 0) + 2;
    const http_headers = try ctx.allocator.alloc(std.http.Header, base_count + extra.len);
    defer ctx.allocator.free(http_headers);
    var hi: usize = 0;
    if (auth_header) |h| {
        http_headers[hi] = .{ .name = "authorization", .value = h };
        hi += 1;
    }
    http_headers[hi] = .{ .name = "content-type", .value = "application/json" };
    hi += 1;
    http_headers[hi] = .{ .name = "accept", .value = "text/event-stream" };
    hi += 1;
    for (extra) |h| {
        http_headers[hi] = .{ .name = h.name, .value = h.value };
        hi += 1;
    }

    const cancel = ctx.options.cancel orelse unreachable;

    var local_client: http_mod.Client = undefined;
    var proxy_arena: ?std.heap.ArenaAllocator = null;
    const client: *http_mod.Client = if (ctx.http_client) |h|
        @ptrCast(@alignCast(h))
    else blk: {
        local_client = .{ .allocator = ctx.allocator, .io = ctx.io };
        if (ctx.options.environ_map) |env_map| {
            proxy_arena = http_mod.setupClientFromEnv(&local_client, ctx.allocator, env_map) catch |e| {
                try ctx.out.push(ctx.io, .start);
                ctx.out.closeWithFinal(ctx.io, .{ .error_ev = .{
                    .code = errors.Code.transport,
                    .message = try std.fmt.allocPrint(ctx.allocator, "client setup failed: {s}", .{@errorName(e)}),
                } });
                return;
            };
        }
        break :blk &local_client;
    };
    defer if (ctx.http_client == null) {
        local_client.deinit();
        if (proxy_arena) |*a| a.deinit();
    };

    var bw = std.Io.Writer.Allocating.init(ctx.allocator);
    defer bw.deinit();

    var phase_info: http_mod.PhaseInfo = .{};
    const result = http_mod.fetchWithRetryAndTimeoutsAndHooksAndPhases(client, .{
        .location = .{ .url = endpoint },
        .method = .POST,
        .payload = body,
        .extra_headers = http_headers,
    }, &bw, cancel, ctx.options.retry_policy orelse .{}, ctx.options.timeouts, http_mod.hooksFromOptionsWithRetry(ctx), &phase_info) catch |e| {
        try http_mod.reportTransportErrorWithPhase(ctx.out, ctx.io, ctx.allocator, e, phase_info.timed_out_phase, ctx.options.timeouts, phase_info.last_error_message);
        if (phase_info.last_error_message) |m| ctx.allocator.free(m);
        return;
    };

    const response_body = bw.written();
    log.log(.debug, "http", "response", "status={d} body_bytes={d}", .{ @intFromEnum(result.status), response_body.len });
    const trace_id_owned = http_mod.writeTraceFile(
        ctx.allocator,
        ctx.io,
        ctx.options.http_trace_dir,
        if (is_gateway) "openai-gateway" else "openai-chat",
        endpoint,
        "POST",
        @intFromEnum(result.status),
        body,
        response_body,
    );

    if (@intFromEnum(result.status) >= 400) {
        if (trace_id_owned) |tid| ctx.allocator.free(tid);
        try ctx.out.push(ctx.io, .start);
        const details = try @import("../error_map.zig").mapError(
            ctx.allocator,
            .openai,
            @intFromEnum(result.status),
            response_body,
        );
        ctx.out.closeWithFinal(ctx.io, .{ .error_ev = details });
        return;
    }

    try runFromSseWithTrace(ctx.allocator, ctx.io, response_body, ctx.out, cancel, trace_id_owned);
}

// ─── tests ────────────────────────────────────────────────────────

const testing = std.testing;
const test_h = @import("../../test_helpers.zig");

test "buildRequestJson: system prompt + user text + model + stream flag" {
    const gpa = testing.allocator;
    var user_content = [_]types.ContentBlock{.{ .text = .{ .text = "Hello" } }};
    var msgs = [_]types.Message{.{ .role = .user, .content = &user_content, .timestamp = 0 }};
    const ctx: types.Context = .{
        .system_prompt = "You are a helpful assistant.",
        .messages = &msgs,
        .tools = &.{},
    };
    const model: types.Model = .{ .id = "gpt-5", .provider = "openai", .api = "openai-chat-completions" };
    const body = try buildRequestJson(gpa, model, ctx, .{});
    defer gpa.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"model\":\"gpt-5\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"stream\":true") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"stream_options\":{\"include_usage\":true}") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"role\":\"system\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"content\":\"You are a helpful assistant.\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"role\":\"user\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"content\":\"Hello\"") != null);
}

test "buildRequestJson: reasoning_effort mapped via §B" {
    const gpa = testing.allocator;
    var uc = [_]types.ContentBlock{.{ .text = .{ .text = "hi" } }};
    var msgs = [_]types.Message{.{ .role = .user, .content = &uc, .timestamp = 0 }};
    const ctx: types.Context = .{
        .system_prompt = "",
        .messages = &msgs,
        .tools = &.{},
    };
    const model: types.Model = .{ .id = "gpt-5-thinking", .provider = "openai", .api = "openai-chat-completions" };

    const body_off = try buildRequestJson(gpa, model, ctx, .{ .thinking = .off });
    defer gpa.free(body_off);
    try testing.expect(std.mem.indexOf(u8, body_off, "reasoning_effort") == null);

    const body_hi = try buildRequestJson(gpa, model, ctx, .{ .thinking = .high });
    defer gpa.free(body_hi);
    try testing.expect(std.mem.indexOf(u8, body_hi, "\"reasoning_effort\":\"high\"") != null);

    const body_xhi = try buildRequestJson(gpa, model, ctx, .{ .thinking = .xhigh });
    defer gpa.free(body_xhi);
    // xhigh collapses to "high" per §B.
    try testing.expect(std.mem.indexOf(u8, body_xhi, "\"reasoning_effort\":\"high\"") != null);
}

test "buildRequestJson: tool schema under function wrapper" {
    const gpa = testing.allocator;
    const tool: types.Tool = .{
        .name = "get_weather",
        .description = "look up the weather",
        .parameters_json = "{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\"}}}",
    };
    var uc2 = [_]types.ContentBlock{.{ .text = .{ .text = "?" } }};
    var msgs2 = [_]types.Message{.{ .role = .user, .content = &uc2, .timestamp = 0 }};
    var tools_arr = [_]types.Tool{tool};
    const ctx: types.Context = .{
        .system_prompt = "",
        .messages = &msgs2,
        .tools = &tools_arr,
    };
    const model: types.Model = .{ .id = "gpt-5", .provider = "openai", .api = "openai-chat-completions" };
    const body = try buildRequestJson(gpa, model, ctx, .{});
    defer gpa.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"get_weather\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"description\":\"look up the weather\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"parameters\":{\"type\":\"object\"") != null);
}

// v1.30.0 — tool schemas with `additionalProperties` must be stripped
// for OpenAI-compatible gateways that reject them with a 400.
test "buildRequestJson: tool schema additionalProperties is stripped" {
    const gpa = testing.allocator;
    const tool: types.Tool = .{
        .name = "read",
        .description = "read a file",
        .parameters_json = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"additionalProperties\":false}",
    };
    var uc = [_]types.ContentBlock{.{ .text = .{ .text = "read foo.zig" } }};
    var msgs = [_]types.Message{.{ .role = .user, .content = &uc, .timestamp = 0 }};
    var tools_arr = [_]types.Tool{tool};
    const ctx: types.Context = .{
        .system_prompt = "",
        .messages = &msgs,
        .tools = &tools_arr,
    };
    const model: types.Model = .{ .id = "glm-4", .provider = "gateway", .api = "openai-compatible-gateway" };
    const body = try buildRequestJson(gpa, model, ctx, .{});
    defer gpa.free(body);

    // `additionalProperties` must be removed
    try testing.expect(std.mem.indexOf(u8, body, "additionalProperties") == null);
    // The other properties should still be present
    try testing.expect(std.mem.indexOf(u8, body, "\"path\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"type\":\"object\"") != null);
}

test "buildRequestJson: assistant-with-tool_calls serializes tool_calls array" {
    const gpa = testing.allocator;
    var user_c = [_]types.ContentBlock{.{ .text = .{ .text = "weather in SF?" } }};
    var asst_c = [_]types.ContentBlock{.{ .tool_call = .{
        .id = "call_1",
        .name = "get_weather",
        .arguments_json = "{\"city\":\"SF\"}",
    } }};
    var tr_c = [_]types.ContentBlock{.{ .text = .{ .text = "72F and sunny" } }};
    var msgs = [_]types.Message{
        .{ .role = .user, .content = &user_c, .timestamp = 0 },
        .{ .role = .assistant, .content = &asst_c, .timestamp = 0 },
        .{ .role = .tool_result, .tool_call_id = "call_1", .content = &tr_c, .timestamp = 0 },
    };
    const ctx: types.Context = .{ .system_prompt = "", .messages = &msgs, .tools = &.{} };
    const model: types.Model = .{ .id = "gpt-5", .provider = "openai", .api = "openai-chat-completions" };
    const body = try buildRequestJson(gpa, model, ctx, .{});
    defer gpa.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"tool_calls\":[") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"id\":\"call_1\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"type\":\"function\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"arguments\":\"{\\\"city\\\":\\\"SF\\\"}\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"role\":\"tool\",\"tool_call_id\":\"call_1\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"content\":\"72F and sunny\"") != null);
}

test "runFromSse: text delta + finish_reason → done" {
    const gpa = testing.allocator;
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    var ch = try Channel.init(gpa, 16);
    defer ch.deinit();
    var cancel: stream_mod.Cancel = .{};

    const sse =
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\"}}]}\n\n" ++
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hel\"}}]}\n\n" ++
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"lo\"},\"finish_reason\":\"stop\"}]}\n\n" ++
        "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":2}}\n\n" ++
        "data: [DONE]\n\n";

    try runFromSse(gpa, io, sse, &ch, &cancel);

    // Drain: expect start, text_delta, text_delta, usage, done.
    var seen_text: usize = 0;
    var seen_usage: bool = false;
    var done_reason: ?types.StopReason = null;
    while (ch.next(io)) |ev| switch (ev) {
        .start => {},
        .text_delta => |d| {
            seen_text += d.delta.len;
            gpa.free(d.delta);
        },
        .usage => |u| {
            seen_usage = true;
            try testing.expectEqual(@as(u64, 3), u.input);
            try testing.expectEqual(@as(u64, 2), u.output);
        },
        .done => |d| done_reason = d.stop_reason,
        else => ev.deinit(gpa),
    };
    try testing.expectEqual(@as(usize, 5), seen_text); // "Hel" + "lo"
    try testing.expect(seen_usage);
    try testing.expectEqual(@as(?types.StopReason, .stop), done_reason);
}

test "runFromSse: reasoning_content delta becomes thinking_delta" {
    const gpa = testing.allocator;
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    var ch = try Channel.init(gpa, 16);
    defer ch.deinit();
    var cancel: stream_mod.Cancel = .{};

    // Mirrors what Cloudflare's openai-compat shim emits for Kimi-K2.6
    // and DeepSeek-style reasoning models: thinking content arrives in
    // `delta.reasoning_content` rather than `delta.content`.
    const sse =
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\"}}]}\n\n" ++
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"reasoning_content\":\"let me\"}}]}\n\n" ++
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"reasoning_content\":\" think\"}}]}\n\n" ++
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"OK\"},\"finish_reason\":\"stop\"}]}\n\n" ++
        "data: [DONE]\n\n";

    try runFromSse(gpa, io, sse, &ch, &cancel);

    var thinking_bytes: usize = 0;
    var text_bytes: usize = 0;
    while (ch.next(io)) |ev| switch (ev) {
        .thinking_delta => |d| {
            thinking_bytes += d.delta.len;
            gpa.free(d.delta);
        },
        .text_delta => |d| {
            text_bytes += d.delta.len;
            gpa.free(d.delta);
        },
        else => ev.deinit(gpa),
    };
    try testing.expectEqual(@as(usize, "let me".len + " think".len), thinking_bytes);
    try testing.expectEqual(@as(usize, 2), text_bytes); // "OK"
}

test "runFromSse: bare `reasoning` field is also accepted" {
    const gpa = testing.allocator;
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    var ch = try Channel.init(gpa, 16);
    defer ch.deinit();
    var cancel: stream_mod.Cancel = .{};

    const sse =
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"reasoning\":\"hmm\"},\"finish_reason\":null}]}\n\n" ++
        "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
        "data: [DONE]\n\n";

    try runFromSse(gpa, io, sse, &ch, &cancel);

    var thinking_bytes: usize = 0;
    while (ch.next(io)) |ev| switch (ev) {
        .thinking_delta => |d| {
            thinking_bytes += d.delta.len;
            gpa.free(d.delta);
        },
        else => ev.deinit(gpa),
    };
    try testing.expectEqual(@as(usize, 3), thinking_bytes); // "hmm"
}

test "runFromSse: DeepSeek reasoning chunks with empty content do not emit text_delta" {
    // DeepSeek (and some other reasoning models) send `"content":""` on every
    // thinking chunk alongside `"reasoning":"..."`. Only the final non-empty
    // content chunk should produce a text_delta; the empty-content chunks must
    // not.
    const gpa = testing.allocator;
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    var ch = try Channel.init(gpa, 32);
    defer ch.deinit();
    var cancel: stream_mod.Cancel = .{};

    const sse =
        // Thinking chunk 1 — content is empty, reasoning has text.
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"\",\"reasoning\":\"step one\"},\"finish_reason\":null}]}\n\n" ++
        // Thinking chunk 2 — same pattern.
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"\",\"reasoning\":\" step two\"},\"finish_reason\":null}]}\n\n" ++
        // Content chunk — now content is non-empty, reasoning absent.
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"answer\"},\"finish_reason\":null}]}\n\n" ++
        "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
        "data: [DONE]\n\n";

    try runFromSse(gpa, io, sse, &ch, &cancel);

    var text_count: usize = 0;
    var text_bytes: usize = 0;
    var thinking_bytes: usize = 0;
    var done_reason: ?types.StopReason = null;
    while (ch.next(io)) |ev| switch (ev) {
        .text_delta => |d| {
            text_count += 1;
            text_bytes += d.delta.len;
            gpa.free(d.delta);
        },
        .thinking_delta => |d| {
            thinking_bytes += d.delta.len;
            gpa.free(d.delta);
        },
        .done => |d| done_reason = d.stop_reason,
        else => ev.deinit(gpa),
    };
    // Only the single non-empty content chunk should produce a text_delta.
    try testing.expectEqual(@as(usize, 1), text_count);
    try testing.expectEqual(@as(usize, 6), text_bytes); // "answer"
    // Both reasoning chunks combined: "step one" + " step two" = 17 bytes.
    try testing.expectEqual(@as(usize, 17), thinking_bytes);
    try testing.expectEqual(@as(?types.StopReason, .stop), done_reason);
}

test "runFromSse: tool-call argument streaming" {
    const gpa = testing.allocator;
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    var ch = try Channel.init(gpa, 32);
    defer ch.deinit();
    var cancel: stream_mod.Cancel = .{};

    const sse =
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"get_weather\",\"arguments\":\"\"}}]}}]}\n\n" ++
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{\\\"city\\\":\"}}]}}]}\n\n" ++
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"\\\"SF\\\"}\"}}]}}]}\n\n" ++
        "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n" ++
        "data: [DONE]\n\n";

    try runFromSse(gpa, io, sse, &ch, &cancel);

    var saw_start = false;
    var start_id: []const u8 = "";
    var start_name: []const u8 = "";
    var accumulated: std.ArrayList(u8) = .empty;
    defer accumulated.deinit(gpa);
    var saw_end = false;
    var done_reason: ?types.StopReason = null;
    while (ch.next(io)) |ev| switch (ev) {
        .start => {},
        .toolcall_start => |s| {
            saw_start = true;
            start_id = s.id;
            start_name = s.name;
        },
        .toolcall_delta => |d| {
            try accumulated.appendSlice(gpa, d.args_delta);
            gpa.free(d.args_delta);
        },
        .toolcall_end => |e| {
            saw_end = true;
            gpa.free(e.args_json);
        },
        .done => |d| done_reason = d.stop_reason,
        else => ev.deinit(gpa),
    };
    try testing.expect(saw_start);
    try testing.expectEqualStrings("call_1", start_id);
    try testing.expectEqualStrings("get_weather", start_name);
    try testing.expectEqualStrings("{\"city\":\"SF\"}", accumulated.items);
    try testing.expect(saw_end);
    try testing.expectEqual(@as(?types.StopReason, .tool_use), done_reason);

    gpa.free(start_id);
    gpa.free(start_name);
}

test "runFromSse: content_filter → refusal stop_reason" {
    const gpa = testing.allocator;
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    var ch = try Channel.init(gpa, 8);
    defer ch.deinit();
    var cancel: stream_mod.Cancel = .{};

    const sse =
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"x\"},\"finish_reason\":\"content_filter\"}]}\n\n" ++
        "data: [DONE]\n\n";

    try runFromSse(gpa, io, sse, &ch, &cancel);

    var reason: ?types.StopReason = null;
    while (ch.next(io)) |ev| switch (ev) {
        .text_delta => |d| gpa.free(d.delta),
        .done => |d| reason = d.stop_reason,
        else => ev.deinit(gpa),
    };
    try testing.expectEqual(@as(?types.StopReason, .refusal), reason);
}

test "mapFinishReason covers all documented variants" {
    try testing.expectEqual(@as(?types.StopReason, .stop), mapFinishReason("stop"));
    try testing.expectEqual(@as(?types.StopReason, .length), mapFinishReason("length"));
    try testing.expectEqual(@as(?types.StopReason, .tool_use), mapFinishReason("tool_calls"));
    try testing.expectEqual(@as(?types.StopReason, .tool_use), mapFinishReason("function_call"));
    try testing.expectEqual(@as(?types.StopReason, .refusal), mapFinishReason("content_filter"));
    try testing.expectEqual(@as(?types.StopReason, null), mapFinishReason("bogus"));
}

test "runFromSse: ignores malformed chunks, preserves earlier deltas" {
    const gpa = testing.allocator;
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    var ch = try Channel.init(gpa, 16);
    defer ch.deinit();
    var cancel: stream_mod.Cancel = .{};

    const sse =
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hi\"}}]}\n\n" ++
        "data: not-json\n\n" ++
        "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
        "data: [DONE]\n\n";

    try runFromSse(gpa, io, sse, &ch, &cancel);

    var seen: usize = 0;
    var reason: ?types.StopReason = null;
    while (ch.next(io)) |ev| switch (ev) {
        .text_delta => |d| {
            seen += d.delta.len;
            gpa.free(d.delta);
        },
        .done => |d| reason = d.stop_reason,
        else => ev.deinit(gpa),
    };
    try testing.expectEqual(@as(usize, 2), seen);
    try testing.expectEqual(@as(?types.StopReason, .stop), reason);
}
