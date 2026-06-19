//! Google Generative AI provider — §A.5 (public Gemini API).
//!
//! Endpoint: `POST /v1beta/models/{model}:streamGenerateContent?alt=sse&key=<key>`.
//! Request uses `contents` (array of `{role, parts}`) and
//! `systemInstruction: {parts:[{text}]}`.
//! Parts: `{text}`, `{inlineData:{mimeType,data}}`,
//! `{functionCall:{name,args}}`, `{functionResponse:{name,response}}`,
//! `{thought: true, text}`.
//! `generationConfig.thinkingConfig: {thinkingBudget: <int>}` (§B).
//! Tool calls may carry `thoughtSignature`; we preserve it opaquely.
//! SSE payloads are JSON objects; each line is a full candidate delta
//! with `candidates[0].content.parts[]` + `usageMetadata`.
//!
//! Registers under api tag `google-gemini`.
//!
//! Vertex variant (§Q.4 service-account JWT) shares this wire format
//! and is delivered as `google_vertex.zig` in v0.8.2.

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

const Channel = channel_mod.Channel(stream_mod.StreamEvent);

pub const default_host: []const u8 = "generativelanguage.googleapis.com";

// ─── request serialization ────────────────────────────────────────

pub fn buildRequestJson(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: registry_mod.StreamOptions,
) ![]u8 {
    _ = model;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.append(allocator, '{');

    if (context.system_prompt.len > 0) {
        try buf.appendSlice(allocator, "\"systemInstruction\":{\"parts\":[{\"text\":");
        try utils.appendJsonStr(&buf, allocator, context.system_prompt);
        try buf.appendSlice(allocator, "}]}");
    }

    // generationConfig (thinking + max + temperature).
    if (options.thinking.googleBudget() != null or options.max_tokens != null or options.temperature != null) {
        if (buf.items.len > 1) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, "\"generationConfig\":{");
        var first = true;
        if (options.max_tokens) |mt| {
            try buf.appendSlice(allocator, "\"maxOutputTokens\":");
            try utils.appendJsonInt(&buf, allocator, @intCast(mt));
            first = false;
        }
        if (options.temperature) |t| {
            if (!first) try buf.append(allocator, ',');
            try buf.appendSlice(allocator, "\"temperature\":");
            try utils.appendJsonFloat(&buf, allocator, t);
            first = false;
        }
        if (options.thinking.googleBudget()) |tb| {
            if (!first) try buf.append(allocator, ',');
            try buf.appendSlice(allocator, "\"thinkingConfig\":{\"thinkingBudget\":");
            try utils.appendJsonInt(&buf, allocator, @intCast(tb));
            try buf.append(allocator, '}');
        }
        try buf.append(allocator, '}');
    }

    if (context.tools.len > 0) {
        if (buf.items.len > 1) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, "\"tools\":[{\"functionDeclarations\":[");
        for (context.tools, 0..) |t, i| {
            if (i > 0) try buf.append(allocator, ',');
            try buf.appendSlice(allocator, "{\"name\":");
            try utils.appendJsonStr(&buf, allocator, t.name);
            try buf.appendSlice(allocator, ",\"description\":");
            try utils.appendJsonStr(&buf, allocator, t.description);
            try buf.appendSlice(allocator, ",\"parameters\":");
            // v1.23.1 — Gemini's tool-parameter schema is a strict
            // subset of OpenAPI/JSON-Schema and rejects keywords
            // like `additionalProperties` / `$schema` that
            // OpenAI + Anthropic accept. franky's built-in tools
            // emit `additionalProperties: false` for strict
            // validation, so we have to scrub the schema before
            // inlining. Recursive — `additionalProperties` can
            // appear inside nested arrays' `items` and per-property
            // sub-schemas.
            try appendSanitizedSchema(&buf, allocator, t.parameters_json);
            try buf.append(allocator, '}');
        }
        try buf.appendSlice(allocator, "]}]");
    }

    if (buf.items.len > 1) try buf.append(allocator, ',');
    try buf.appendSlice(allocator, "\"contents\":[");
    var first = true;
    for (context.messages) |m| {
        if (!try appendContent(&buf, allocator, m, first)) continue;
        first = false;
    }
    try buf.append(allocator, ']');

    try buf.append(allocator, '}');
    return buf.toOwnedSlice(allocator);
}

/// v1.23.1 — JSON Schema keywords Gemini rejects with
/// `request_invalid: Unknown name "<key>"`. Stripped recursively
/// from every nested object before sending. Add to this list as
/// new incompatibilities surface from real prompts.
const gemini_unsupported_schema_keys = [_][]const u8{
    "additionalProperties",
    "$schema",
    "$defs",
    "definitions",
};

/// Parse `schema_json`, walk it recursively, drop keys Gemini
/// rejects, then serialize the result back into `buf`. Falls back
/// to inlining the original (unsanitized) schema if parsing
/// fails — better to attempt a request with the original than to
/// fail closed; Gemini will return its own error which the user
/// can act on.
///
/// Fast path (most schemas): a substring scan. If none of the
/// unsupported keywords appear, the schema is already valid for
/// Gemini and we inline it verbatim — skipping the parse / walk /
/// re-stringify entirely. This is the common case (only franky's
/// own tools currently emit `additionalProperties` for strict
/// mode); avoids ~1KB of allocations × N tools per HTTP request.
///
/// Machinery lives in `ai.utils` (v1.3.0 dedup); this file owns
/// only the `gemini_unsupported_schema_keys` list.
fn appendSanitizedSchema(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    schema_json: []const u8,
) !void {
    return utils.appendSanitizedSchema(buf, allocator, schema_json, &gemini_unsupported_schema_keys);
}

fn appendContent(
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
    const role_str = switch (m.role) {
        .user => "user",
        .assistant => "model",
        .tool_result => "user", // Gemini returns function_response via user role
        .custom => unreachable,
    };
    try buf.appendSlice(allocator, "{\"role\":");
    try utils.appendJsonStr(buf, allocator, role_str);
    try buf.appendSlice(allocator, ",\"parts\":[");

    var emitted: usize = 0;
    if (m.role == .tool_result) {
        // v1.23.3 — for tool_result messages, emit ONLY the
        // `functionResponse` wrapper. Pre-fix, the loop below
        // *also* emitted `{"text":...}` for each text content
        // block, producing a malformed `[{"text":...}{"functionResponse":...}]`
        // (missing comma between the two parts) that Gemini
        // rejected with `request_invalid: Expected , or ] after
        // array value`. The functionResponse wrapper already
        // concatenates the text payload into its `response.content`
        // field, so the separate text emission was both wrong AND
        // duplicate.
        var text_buf: std.ArrayList(u8) = .empty;
        defer text_buf.deinit(allocator);
        for (m.content) |cb| switch (cb) {
            .text => |t| try text_buf.appendSlice(allocator, t.text),
            else => {},
        };
        try buf.appendSlice(allocator, "{\"functionResponse\":{\"name\":");
        try utils.appendJsonStr(buf, allocator, m.tool_call_id orelse "");
        try buf.appendSlice(allocator, ",\"response\":{\"content\":");
        try utils.appendJsonStr(buf, allocator, text_buf.items);
        try buf.appendSlice(allocator, "}}}");
        emitted += 1;
    } else {
        for (m.content) |cb| {
            switch (cb) {
                .text => |t| {
                    if (emitted > 0) try buf.append(allocator, ',');
                    try buf.appendSlice(allocator, "{\"text\":");
                    try utils.appendJsonStr(buf, allocator, t.text);
                    try buf.append(allocator, '}');
                    emitted += 1;
                },
                .tool_call => |tc| {
                    if (emitted > 0) try buf.append(allocator, ',');
                    try buf.appendSlice(allocator, "{\"functionCall\":{\"name\":");
                    try utils.appendJsonStr(buf, allocator, tc.name);
                    try buf.appendSlice(allocator, ",\"args\":");
                    try buf.appendSlice(allocator, if (tc.arguments_json.len == 0) "{}" else tc.arguments_json);
                    try buf.appendSlice(allocator, "}}");
                    emitted += 1;
                },
                .image => |img| {
                    if (emitted > 0) try buf.append(allocator, ',');
                    try buf.appendSlice(allocator, "{\"inlineData\":{\"mimeType\":");
                    try utils.appendJsonStr(buf, allocator, img.mime_type);
                    try buf.appendSlice(allocator, ",\"data\":");
                    try utils.appendJsonStr(buf, allocator, img.data);
                    try buf.appendSlice(allocator, "}}");
                    emitted += 1;
                },
                .thinking => {},
            }
        }
    }

    if (emitted == 0) try buf.appendSlice(allocator, "{\"text\":\"\"}");
    try buf.appendSlice(allocator, "]}");
    return true;
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

/// v1.29.0 — runFromSse + trace_id. The legacy 5-arg shape is
/// retained so existing tests keep compiling without churn.
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
    var driver = Driver{ .allocator = allocator, .io = io, .out = out };
    defer driver.deinit();
    const result = http_mod.driveSseFromBytes(allocator, sse_body, cancel, Driver.onEvent, @ptrCast(&driver));
    if (result) |_| {
        if (!driver.closed) {
            stream_mod.closeWithDiagnostics(out, io, allocator, .{
                .provider = "google-gemini",
                .stop_reason = driver.stop_reason orelse .stop,
                .text_seen = driver.text_seen,
                .thinking_seen = driver.thinking_seen,
                .tool_count = driver.tool_count,
                .parts_seen = driver.parts_seen,
                .finish_reason_raw = driver.finish_reason_raw,
                .candidates_tokens = driver.candidates_tokens,
                .thoughts_tokens = driver.thoughts_tokens,
            });
        }
    } else |e| {
        stream_mod.closeOnSseError(out, io, allocator, e);
    }
}

const Driver = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    out: *Channel,
    tool_count: u32 = 0,
    stop_reason: ?types.StopReason = null,
    closed: bool = false,
    /// v1.29.0 — diagnostic counters. `parts_seen` increments on
    /// every SSE event whose `candidates[0].content.parts` array
    /// has at least one part. `text_seen`/`thinking_seen` flip on
    /// the first non-empty text/thinking part. `finish_reason_raw`
    /// captures the raw provider string verbatim. The `_tokens`
    /// fields mirror what we already pull out of `usageMetadata`.
    parts_seen: u32 = 0,
    text_seen: bool = false,
    thinking_seen: bool = false,
    finish_reason_raw: ?[]const u8 = null, // arena-owned; valid while handle() runs
    candidates_tokens: ?u64 = null,
    thoughts_tokens: ?u64 = null,
    /// Persisted copy of `finish_reason_raw` so it survives the
    /// arena-lifetime of `handle`. Allocated on the Driver's
    /// allocator; freed in `deinit`.
    finish_reason_owned: ?[]u8 = null,

    fn deinit(self: *Driver) void {
        if (self.finish_reason_owned) |s| self.allocator.free(s);
    }

    fn onEvent(ud: ?*anyopaque, ev: sse_mod.Event) http_mod.EventHandlerError!void {
        const self: *Driver = @ptrCast(@alignCast(ud.?));
        self.handle(ev) catch |e| switch (e) {
            error.OutOfMemory => return http_mod.EventHandlerError.OutOfMemory,
            error.Closed => return http_mod.EventHandlerError.Handler,
        };
    }

    fn handle(self: *Driver, ev: sse_mod.Event) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), ev.data, .{}) catch return;
        if (parsed.value != .object) return;
        const obj = parsed.value.object;

        // Drain `candidates[0].content.parts[]`.
        if (obj.get("candidates")) |cs| if (cs == .array and cs.array.items.len > 0) {
            const cand = cs.array.items[0];
            if (cand != .object) return;
            if (cand.object.get("content")) |ct| if (ct == .object) {
                if (ct.object.get("parts")) |ps| if (ps == .array and ps.array.items.len > 0) {
                    self.parts_seen +%= 1;
                    for (ps.array.items) |p| {
                        if (p != .object) continue;
                        // Gemini's `Part` proto carries two thinking-related
                        // fields and may co-locate them with a `functionCall`:
                        //   `thought: bool`              — explicit "this is a
                        //                                  thought summary"
                        //   `thoughtSignature: string`   — opaque continuation
                        //                                  token; can attach
                        //                                  to text, to a
                        //                                  functionCall, or
                        //                                  to a part that
                        //                                  carries both.
                        //
                        // v1.26.4 routed text-with-thoughtSignature → thinking_delta
                        // (gemini-2.5-pro reasoning monologues were rendering
                        // as the user-facing answer). v2.0.2 follow-up:
                        // gemini-3.1-pro emits the FIRST part as
                        // `{functionCall, thoughtSignature}` (no text) and the
                        // SECOND as `{text:""}` + `finishReason:STOP`. The
                        // pre-v2.0.2 path saw `is_thought = true` on the
                        // first part, ran the text branch (which no-op'd
                        // because there was no `text` key), then `continue`d
                        // — silently dropping the `functionCall`. The agent
                        // loop got an empty turn with `STOP` and the user
                        // saw nothing.
                        //
                        // Treat thinking-flag as scoping ONLY the text
                        // routing. `functionCall` always emits, regardless.
                        const is_thought_text = blk: {
                            if (p.object.get("thought")) |th| if (th == .bool and th.bool) break :blk true;
                            if (p.object.get("thoughtSignature")) |sig| if (sig == .string and sig.string.len > 0) break :blk true;
                            break :blk false;
                        };
                        if (p.object.get("text")) |t| if (t == .string) {
                            if (is_thought_text) {
                                if (t.string.len > 0) self.thinking_seen = true;
                                try self.out.push(self.io, .{ .thinking_delta = .{
                                    .block_index = 0,
                                    .delta = try self.allocator.dupe(u8, t.string),
                                } });
                            } else {
                                if (t.string.len > 0) self.text_seen = true;
                                try self.out.push(self.io, .{ .text_delta = .{
                                    .block_index = 0,
                                    .delta = try self.allocator.dupe(u8, t.string),
                                } });
                            }
                        };
                        if (p.object.get("functionCall")) |fc| if (fc == .object) {
                            const name = if (fc.object.get("name")) |n| (if (n == .string) n.string else "") else "";
                            const args_val = fc.object.get("args");
                            const args_buf = try renderArgs(self.allocator, args_val);
                            defer self.allocator.free(args_buf);

                            const idx = self.tool_count;
                            try self.out.push(self.io, .{ .toolcall_start = .{
                                .block_index = idx,
                                .id = try std.fmt.allocPrint(self.allocator, "gcall-{d}", .{idx}),
                                .name = try self.allocator.dupe(u8, name),
                            } });
                            if (args_buf.len > 0) {
                                try self.out.push(self.io, .{ .toolcall_delta = .{
                                    .block_index = idx,
                                    .args_delta = try self.allocator.dupe(u8, args_buf),
                                } });
                            }
                            try self.out.push(self.io, .{ .toolcall_end = .{
                                .block_index = idx,
                                .args_json = try self.allocator.dupe(u8, args_buf),
                            } });
                            self.tool_count += 1;
                        };
                    }
                };
            };
            if (cand.object.get("finishReason")) |fr| if (fr == .string) {
                self.stop_reason = mapFinishReason(fr.string);
                // v1.29.0 — preserve raw provider string for diagnostics.
                // Last-write-wins; Gemini emits the final reason once.
                if (self.finish_reason_owned) |old| self.allocator.free(old);
                self.finish_reason_owned = self.allocator.dupe(u8, fr.string) catch null;
                self.finish_reason_raw = self.finish_reason_owned;
            };
        };

        if (obj.get("usageMetadata")) |um| if (um == .object) {
            const inp: u64 = if (um.object.get("promptTokenCount")) |v| (if (v == .integer) @intCast(v.integer) else 0) else 0;
            const out: u64 = if (um.object.get("candidatesTokenCount")) |v| (if (v == .integer) @intCast(v.integer) else 0) else 0;
            // v1.29.0 — also pull thoughtsTokenCount; both end up in
            // the diagnostic struct so an after-the-fact reader can
            // tell the empty-response signature ("thoughts > 0,
            // candidates == 0") from a normal turn.
            self.candidates_tokens = out;
            if (um.object.get("thoughtsTokenCount")) |v| if (v == .integer) {
                self.thoughts_tokens = @intCast(v.integer);
            };
            try self.out.push(self.io, .{ .usage = .{ .input = inp, .output = out } });
        };
    }
};

/// Re-encode Gemini's `functionCall.args` (an already-parsed
/// `std.json.Value`) back to a JSON string for the agent loop.
///
/// The handwritten walker this replaced (v1.23–v1.26.0) wrote
/// raw bytes from each string value verbatim — no JSON-escape
/// pass — and dropped nested objects/arrays to `null`. Both
/// were bugs surfaced by real subagent calls: a multi-line
/// `prompt` arg arrived through the wire with embedded `\n`
/// chars, and the unescaped re-emit produced "JSON" with
/// literal control characters that strict parsers (the
/// subagent tool's `parseArgs`) reject as `invalid_args`.
///
/// `std.json.Stringify.valueAlloc` handles control-char
/// escaping, nested objects/arrays, and number/bool formatting
/// in one shot.
fn renderArgs(allocator: std.mem.Allocator, v: ?std.json.Value) ![]u8 {
    const value = v orelse return try allocator.dupe(u8, "{}");
    if (value != .object) return try allocator.dupe(u8, "{}");
    return try std.json.Stringify.valueAlloc(allocator, value, .{});
}

fn mapFinishReason(s: []const u8) ?types.StopReason {
    if (std.mem.eql(u8, s, "STOP")) return .stop;
    if (std.mem.eql(u8, s, "MAX_TOKENS")) return .length;
    if (std.mem.eql(u8, s, "SAFETY")) return .refusal;
    if (std.mem.eql(u8, s, "TOOL_USE") or std.mem.eql(u8, s, "TOOL_CODE")) return .tool_use;
    return null;
}

// ─── registry entry ──────────────────────────────────────────────

pub fn streamFn(ctx: registry_mod.StreamCtx) anyerror!void {
    // Two auth shapes for the Google Generative Language API:
    //  - API key as `?key=...` query param (the AI Studio key path).
    //  - Bearer token in the `Authorization` header (an externally
    //    minted Google access token, supplied via `auth_token`).
    // If both happen to be set, prefer the bearer — it carries a
    // real Google identity, whereas API keys are cheap to mint.
    const has_api_key = ctx.options.api_key != null and ctx.options.api_key.?.len > 0;
    const has_auth_token = ctx.options.auth_token != null and ctx.options.auth_token.?.len > 0;
    if (!has_api_key and !has_auth_token) {
        try ctx.out.push(ctx.io, .start);
        ctx.out.closeWithFinal(ctx.io, .{ .error_ev = .{
            .code = errors.Code.auth,
            .message = try ctx.allocator.dupe(u8, "google-gemini: no credential (set --api-key, GOOGLE_API_KEY / GEMINI_API_KEY, or pass --auth-token / a bearer-token record in $FRANKY_HOME/auth.json)"),
        } });
        return;
    }

    const body = try buildRequestJson(ctx.allocator, ctx.model, ctx.context, ctx.options);
    defer ctx.allocator.free(body);

    log.log(.debug, "http", "request", "provider=google-gemini model={s} body_bytes={d}", .{ ctx.model.id, body.len });
    log.body(.trace, "http", "request_body", body, 64 * 1024);

    // URL: bearer-token path drops the `key=` param (Google's API
    // rejects the dual-auth combination); API-key path appends
    // `&key=...`.
    const url = if (has_auth_token)
        try std.fmt.allocPrint(
            ctx.allocator,
            "https://{s}/v1beta/models/{s}:streamGenerateContent?alt=sse",
            .{ default_host, ctx.model.id },
        )
    else
        try std.fmt.allocPrint(
            ctx.allocator,
            "https://{s}/v1beta/models/{s}:streamGenerateContent?alt=sse&key={s}",
            .{ default_host, ctx.model.id, ctx.options.api_key.? },
        );
    defer ctx.allocator.free(url);

    const auth_header: ?[]u8 = if (has_auth_token)
        try std.fmt.allocPrint(ctx.allocator, "Bearer {s}", .{ctx.options.auth_token.?})
    else
        null;
    defer if (auth_header) |h| ctx.allocator.free(h);

    var http_headers_buf: [3]std.http.Header = undefined;
    var http_headers_len: usize = 0;
    if (auth_header) |h| {
        http_headers_buf[http_headers_len] = .{ .name = "authorization", .value = h };
        http_headers_len += 1;
    }
    http_headers_buf[http_headers_len] = .{ .name = "content-type", .value = "application/json" };
    http_headers_len += 1;
    http_headers_buf[http_headers_len] = .{ .name = "accept", .value = "text/event-stream" };
    http_headers_len += 1;
    const http_headers = http_headers_buf[0..http_headers_len];

    const cancel = ctx.options.cancel orelse unreachable;

    var sc = http_mod.acquireStreamClient(ctx) orelse return;
    defer sc.deinit();
    const client = sc.client;

    var bw = std.Io.Writer.Allocating.init(ctx.allocator);
    defer bw.deinit();

    const endpoint: []const u8 = ctx.options.base_url orelse url;
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
    const trace_id_owned = http_mod.writeTraceFile(
        ctx.allocator,
        ctx.io,
        ctx.options.http_trace_dir,
        "google-gemini",
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
            .openai, // Google returns an `{"error":{...}}` shape close enough to share the mapper
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

test "buildRequestJson: contents + systemInstruction shape" {
    const gpa = testing.allocator;
    var uc = [_]types.ContentBlock{.{ .text = .{ .text = "hello" } }};
    var msgs = [_]types.Message{.{ .role = .user, .content = &uc, .timestamp = 0 }};
    const ctx: types.Context = .{ .system_prompt = "sys", .messages = &msgs, .tools = &.{} };
    const model: types.Model = .{ .id = "gemini-2.5-pro", .provider = "google", .api = "google-gemini" };
    const body = try buildRequestJson(gpa, model, ctx, .{});
    defer gpa.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"systemInstruction\":{\"parts\":[{\"text\":\"sys\"}]}") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"contents\":[{\"role\":\"user\",\"parts\":[{\"text\":\"hello\"}]}]") != null);
}

test "buildRequestJson: thinking=off omits thinkingBudget entirely (v1.23.2)" {
    // gemini-2.5-pro rejects `Budget 0 is invalid`; the safer
    // behavior is to send NO thinkingBudget so Google's per-model
    // default kicks in. Pin that contract: with thinking=off, the
    // request body must not contain "thinkingBudget".
    const gpa = testing.allocator;
    var uc = [_]types.ContentBlock{.{ .text = .{ .text = "?" } }};
    var msgs = [_]types.Message{.{ .role = .user, .content = &uc, .timestamp = 0 }};
    const ctx: types.Context = .{ .system_prompt = "", .messages = &msgs, .tools = &.{} };
    const model: types.Model = .{ .id = "gemini-2.5-pro", .provider = "google", .api = "google-gemini" };

    const body = try buildRequestJson(gpa, model, ctx, .{ .thinking = .off });
    defer gpa.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "thinkingBudget") == null);
    try testing.expect(std.mem.indexOf(u8, body, "thinkingConfig") == null);
}

test "buildRequestJson: thinkingConfig from §B mapping" {
    const gpa = testing.allocator;
    var uc = [_]types.ContentBlock{.{ .text = .{ .text = "?" } }};
    var msgs = [_]types.Message{.{ .role = .user, .content = &uc, .timestamp = 0 }};
    const ctx: types.Context = .{ .system_prompt = "", .messages = &msgs, .tools = &.{} };
    const model: types.Model = .{ .id = "gemini-2.5-pro", .provider = "google", .api = "google-gemini" };

    const body = try buildRequestJson(gpa, model, ctx, .{ .thinking = .high });
    defer gpa.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"thinkingConfig\":{\"thinkingBudget\":16384}") != null);
}

test "appendSanitizedSchema: fast-path inlines verbatim when no keyword present" {
    // A clean schema (no additionalProperties / $schema / etc.)
    // should round-trip exactly — sanitizer's fast-path skips
    // parse/walk/stringify and saves ~1KB of allocations per
    // tool per HTTP request.
    const gpa = testing.allocator;
    const clean =
        \\{"type":"object","properties":{"q":{"type":"string"}}}
    ;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try appendSanitizedSchema(&buf, gpa, clean);
    try testing.expectEqualStrings(clean, buf.items);
}

test "buildRequestJson: strips additionalProperties from tool parameters" {
    const gpa = testing.allocator;
    // Mimics the franky `edit` tool's nested schema — array of
    // objects, each with `additionalProperties: false`. Gemini
    // rejected all three depths in real usage; the sanitizer must
    // strip them all.
    const params =
        \\{"type":"object","required":["path","edits"],"properties":{"path":{"type":"string"},"edits":{"type":"array","items":{"type":"object","required":["old","new"],"properties":{"old":{"type":"string"},"new":{"type":"string"}},"additionalProperties":false}}},"additionalProperties":false}
    ;
    const tool: types.Tool = .{
        .name = "edit",
        .description = "edit",
        .parameters_json = params,
    };
    var uc = [_]types.ContentBlock{.{ .text = .{ .text = "q" } }};
    var msgs = [_]types.Message{.{ .role = .user, .content = &uc, .timestamp = 0 }};
    var tools = [_]types.Tool{tool};
    const ctx: types.Context = .{ .system_prompt = "", .messages = &msgs, .tools = &tools };
    const model: types.Model = .{ .id = "gemini-2.5-pro", .provider = "google", .api = "google-gemini" };
    const body = try buildRequestJson(gpa, model, ctx, .{});
    defer gpa.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "additionalProperties") == null);
    // Sanity: the rest of the schema survived.
    try testing.expect(std.mem.indexOf(u8, body, "\"items\":") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"old\":") != null);
}

test "buildRequestJson: tools nested under functionDeclarations" {
    const gpa = testing.allocator;
    const tool: types.Tool = .{
        .name = "search",
        .description = "web search",
        .parameters_json = "{\"type\":\"object\"}",
    };
    var uc = [_]types.ContentBlock{.{ .text = .{ .text = "q" } }};
    var msgs = [_]types.Message{.{ .role = .user, .content = &uc, .timestamp = 0 }};
    var tools = [_]types.Tool{tool};
    const ctx: types.Context = .{ .system_prompt = "", .messages = &msgs, .tools = &tools };
    const model: types.Model = .{ .id = "gemini-2.5-pro", .provider = "google", .api = "google-gemini" };
    const body = try buildRequestJson(gpa, model, ctx, .{});
    defer gpa.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"tools\":[{\"functionDeclarations\":[{\"name\":\"search\"") != null);
}

test "buildRequestJson: tool_result emits ONE functionResponse, not text+functionResponse (v1.23.3)" {
    // Regression: pre-v1.23.3 a tool_result message emitted both
    // `{"text":...}` (from the per-content-block loop) AND a
    // `{"functionResponse":...}` after it — without a comma —
    // yielding `[{"text":"…"}{"functionResponse":…}]` which
    // Gemini rejected with `request_invalid: Expected , or ] …`.
    // Pin the new shape: a single functionResponse part.
    const gpa = testing.allocator;
    var tool_result_content = [_]types.ContentBlock{.{ .text = .{ .text = "refactoring.md\n" } }};
    var msgs = [_]types.Message{.{
        .role = .tool_result,
        .content = &tool_result_content,
        .timestamp = 0,
        .tool_call_id = "call-abc",
    }};
    const ctx: types.Context = .{ .system_prompt = "", .messages = &msgs, .tools = &.{} };
    const model: types.Model = .{ .id = "gemini-2.5-pro", .provider = "google", .api = "google-gemini" };
    const body = try buildRequestJson(gpa, model, ctx, .{});
    defer gpa.free(body);

    // Exactly one functionResponse, no separate {"text":...} part.
    try testing.expect(std.mem.indexOf(u8, body, "\"parts\":[{\"functionResponse\":") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"name\":\"call-abc\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"content\":\"refactoring.md\\n\"") != null);
    // No malformed `}{` adjacency anywhere in the parts array.
    try testing.expect(std.mem.indexOf(u8, body, "}{\"functionResponse\":") == null);
}

test "buildRequestJson: assistant role renders as 'model'" {
    const gpa = testing.allocator;
    var uc = [_]types.ContentBlock{.{ .text = .{ .text = "q" } }};
    var ac = [_]types.ContentBlock{.{ .text = .{ .text = "a" } }};
    var msgs = [_]types.Message{
        .{ .role = .user, .content = &uc, .timestamp = 0 },
        .{ .role = .assistant, .content = &ac, .timestamp = 0 },
    };
    const ctx: types.Context = .{ .system_prompt = "", .messages = &msgs, .tools = &.{} };
    const model: types.Model = .{ .id = "gemini-2.5-pro", .provider = "google", .api = "google-gemini" };
    const body = try buildRequestJson(gpa, model, ctx, .{});
    defer gpa.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"role\":\"model\"") != null);
}

test "runFromSse: text + finishReason STOP → done" {
    const gpa = testing.allocator;
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    var ch = try Channel.init(gpa, 16);
    defer ch.deinit();
    var cancel: stream_mod.Cancel = .{};

    const sse =
        "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"Hel\"}]}}]}\n\n" ++
        "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"lo\"}]},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":3,\"candidatesTokenCount\":2}}\n\n";

    try runFromSse(gpa, io, sse, &ch, &cancel);

    var bytes: usize = 0;
    var saw_usage = false;
    var done_reason: ?types.StopReason = null;
    while (ch.next(io)) |ev| switch (ev) {
        .text_delta => |d| {
            bytes += d.delta.len;
            gpa.free(d.delta);
        },
        .usage => |u| {
            saw_usage = true;
            try testing.expectEqual(@as(u64, 3), u.input);
            try testing.expectEqual(@as(u64, 2), u.output);
        },
        .done => |d| done_reason = d.stop_reason,
        else => ev.deinit(gpa),
    };
    try testing.expectEqual(@as(usize, 5), bytes);
    try testing.expect(saw_usage);
    try testing.expectEqual(@as(?types.StopReason, .stop), done_reason);
}

test "runFromSse: thoughtSignature parts route to thinking_delta (v1.26.4)" {
    // Regression for the http-trace where gemini-2.5-pro emitted a long
    // self-correcting reasoning monologue as `text` parts each carrying
    // `thoughtSignature` (without `thought: true`). Pre-v1.26.4 these
    // routed to `text_delta` and surfaced in the assistant's answer
    // bubble; the user perceived "no answer was rendered" because the
    // actual answer was empty (the turn ended with a `functionCall`,
    // and only thinking text preceded it). Post-fix the same parts
    // route to `thinking_delta` and end up in the thinking pane.
    const gpa = testing.allocator;
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    var ch = try Channel.init(gpa, 16);
    defer ch.deinit();
    var cancel: stream_mod.Cancel = .{};

    const sse =
        "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"thinking aloud\",\"thoughtSignature\":\"sigA\"}]}}]}\n\n" ++
        "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\" more thinking\",\"thoughtSignature\":\"sigB\"}]},\"finishReason\":\"STOP\"}]}\n\n";

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
    try testing.expect(thinking_bytes > 0);
    try testing.expectEqual(@as(usize, 0), text_bytes);
}

test "runFromSse: functionCall co-located with thoughtSignature still emits the call (v2.0.2)" {
    // Regression for the http-trace where gemini-3.1-pro emitted the FIRST
    // SSE event as a single part containing BOTH `functionCall` and
    // `thoughtSignature` (no `text` field), then a SECOND event as
    // `{text:""}` + `finishReason:STOP`. Pre-v2.0.2 the parser short-
    // circuited on `is_thought` and `continue`d past the functionCall
    // branch — the agent loop saw no tool calls, no text, and a STOP
    // finish reason. The proxy/web UI showed nothing at all to the user.
    const gpa = testing.allocator;
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    var ch = try Channel.init(gpa, 16);
    defer ch.deinit();
    var cancel: stream_mod.Cancel = .{};

    const sse =
        "data: {\"candidates\":[{\"content\":{\"parts\":[{\"functionCall\":{\"name\":\"ls\",\"args\":{}},\"thoughtSignature\":\"opaqueA\"}],\"role\":\"model\"}}]}\n\n" ++
        "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"\"}],\"role\":\"model\"},\"finishReason\":\"STOP\"}]}\n\n";

    try runFromSse(gpa, io, sse, &ch, &cancel);

    var saw_tool_start = false;
    var saw_tool_end = false;
    var tool_name_buf: [32]u8 = undefined;
    var tool_name_len: usize = 0;
    while (ch.next(io)) |ev| switch (ev) {
        .toolcall_start => |t| {
            saw_tool_start = true;
            const n = @min(t.name.len, tool_name_buf.len);
            @memcpy(tool_name_buf[0..n], t.name[0..n]);
            tool_name_len = n;
            gpa.free(t.id);
            gpa.free(t.name);
        },
        .toolcall_end => |t| {
            saw_tool_end = true;
            gpa.free(t.args_json);
        },
        else => ev.deinit(gpa),
    };
    try testing.expect(saw_tool_start);
    try testing.expect(saw_tool_end);
    try testing.expectEqualStrings("ls", tool_name_buf[0..tool_name_len]);
}

test "runFromSse: thought=true alone still routes to thinking (v1.26.4)" {
    // Backward-compat: explicit `thought: true` parts (the API-doc-spec
    // shape, set when `thinkingConfig.includeThoughts: true` is
    // requested) still route to thinking_delta even if no signature
    // is present.
    const gpa = testing.allocator;
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    var ch = try Channel.init(gpa, 8);
    defer ch.deinit();
    var cancel: stream_mod.Cancel = .{};

    const sse =
        "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"reasoning\",\"thought\":true}]},\"finishReason\":\"STOP\"}]}\n\n";
    try runFromSse(gpa, io, sse, &ch, &cancel);

    var thinking_bytes: usize = 0;
    while (ch.next(io)) |ev| switch (ev) {
        .thinking_delta => |d| {
            thinking_bytes += d.delta.len;
            gpa.free(d.delta);
        },
        else => ev.deinit(gpa),
    };
    try testing.expectEqual(@as(usize, "reasoning".len), thinking_bytes);
}

test "runFromSse: bare text (no thought, no signature) still routes to text" {
    // Pin the negative case: a regular response part without any
    // thinking markers must remain a `text_delta`. This is the
    // common path under default thinking config (no `includeThoughts`).
    const gpa = testing.allocator;
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    var ch = try Channel.init(gpa, 8);
    defer ch.deinit();
    var cancel: stream_mod.Cancel = .{};

    const sse =
        "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"hello\"}]},\"finishReason\":\"STOP\"}]}\n\n";
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
    try testing.expectEqual(@as(usize, 0), thinking_bytes);
    try testing.expectEqual(@as(usize, "hello".len), text_bytes);
}

test "runFromSse: SAFETY → refusal" {
    const gpa = testing.allocator;
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    var ch = try Channel.init(gpa, 8);
    defer ch.deinit();
    var cancel: stream_mod.Cancel = .{};

    const sse =
        "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"x\"}]},\"finishReason\":\"SAFETY\"}]}\n\n";

    try runFromSse(gpa, io, sse, &ch, &cancel);

    var reason: ?types.StopReason = null;
    while (ch.next(io)) |ev| switch (ev) {
        .text_delta => |d| gpa.free(d.delta),
        .done => |d| reason = d.stop_reason,
        else => ev.deinit(gpa),
    };
    try testing.expectEqual(@as(?types.StopReason, .refusal), reason);
}

test "mapFinishReason covers documented Google values" {
    try testing.expectEqual(@as(?types.StopReason, .stop), mapFinishReason("STOP"));
    try testing.expectEqual(@as(?types.StopReason, .length), mapFinishReason("MAX_TOKENS"));
    try testing.expectEqual(@as(?types.StopReason, .refusal), mapFinishReason("SAFETY"));
    try testing.expectEqual(@as(?types.StopReason, .tool_use), mapFinishReason("TOOL_USE"));
    try testing.expectEqual(@as(?types.StopReason, null), mapFinishReason("OTHER"));
}

test "renderArgs: JSON-escapes control chars in string values (v1.26.1)" {
    // Regression for the subagent-with-multiline-prompt failure: when
    // the model emits `args.prompt` as a string with embedded `\n`,
    // the re-stringified args_json must contain `\n` ESCAPED so
    // strict downstream parsers (subagent.parseArgs) accept it.
    const gpa = testing.allocator;
    const src =
        \\{"profile":"google","prompt":"line1\nline2\twith \"quotes\""}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, src, .{});
    defer parsed.deinit();

    const out = try renderArgs(gpa, parsed.value);
    defer gpa.free(out);

    // Round-trip must succeed under strict JSON.
    var roundtrip = try std.json.parseFromSlice(std.json.Value, gpa, out, .{});
    defer roundtrip.deinit();
    try testing.expect(roundtrip.value == .object);
    const prompt = roundtrip.value.object.get("prompt").?;
    try testing.expect(prompt == .string);
    try testing.expectEqualStrings("line1\nline2\twith \"quotes\"", prompt.string);

    // The serialized form must NOT contain a raw newline byte.
    try testing.expect(std.mem.indexOfScalar(u8, out, '\n') == null);
}

test "renderArgs: preserves nested objects + arrays" {
    // Pre-v1.26.1 the handwritten walker dropped non-scalar values
    // to `null`, so a nested `edits` array would arrive as a bogus
    // null and the tool would reject. Now that we hand off to
    // std.json.Stringify the nesting survives.
    const gpa = testing.allocator;
    const src =
        \\{"path":"foo.txt","edits":[{"old":"a","new":"b"}],"meta":{"k":1}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, src, .{});
    defer parsed.deinit();

    const out = try renderArgs(gpa, parsed.value);
    defer gpa.free(out);

    var roundtrip = try std.json.parseFromSlice(std.json.Value, gpa, out, .{});
    defer roundtrip.deinit();
    try testing.expect(roundtrip.value.object.get("edits").? == .array);
    try testing.expect(roundtrip.value.object.get("meta").? == .object);
}

test "renderArgs: null / non-object → \"{}\"" {
    const gpa = testing.allocator;
    const a = try renderArgs(gpa, null);
    defer gpa.free(a);
    try testing.expectEqualStrings("{}", a);

    const b = try renderArgs(gpa, .{ .string = "not-an-object" });
    defer gpa.free(b);
    try testing.expectEqualStrings("{}", b);
}

test "runFromSse: empty-response (STOP, no parts) closes with error_ev{empty_response} (v1.29.0)" {
    // Pin the demonstrated Gemini-2.5-pro failure mode: the model
    // returns a clean STOP terminal but emits zero content parts.
    // Pre-v1.29.0 we'd silently close with `.done{.stop}` and the
    // saved transcript would have an empty assistant message. With
    // the v1.29.0 detection this must surface as a loud
    // `error_ev{ code = .empty_response }` so the agent-loop UI
    // can act on it.
    const gpa = testing.allocator;
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    var ch = try Channel.init(gpa, 16);
    defer ch.deinit();
    var cancel: stream_mod.Cancel = .{};

    // Single SSE event matching the user-supplied trace: candidate
    // content has no `parts` array, finishReason STOP, usageMetadata
    // says 0 candidate tokens (only thoughts).
    const sse =
        "data: {\"candidates\":[{\"content\":{\"role\":\"model\"},\"finishReason\":\"STOP\",\"index\":0}]," ++
        "\"usageMetadata\":{\"promptTokenCount\":3619,\"totalTokenCount\":4180,\"thoughtsTokenCount\":561}}\n\n";

    try runFromSse(gpa, io, sse, &ch, &cancel);

    var saw_error_empty = false;
    var saw_done = false;
    while (ch.next(io)) |ev| switch (ev) {
        .error_ev => |e| {
            if (e.code == .empty_response) saw_error_empty = true;
            gpa.free(e.message);
            if (e.tool_code) |v| gpa.free(v);
            if (e.provider_code) |v| gpa.free(v);
            if (e.provider_message) |v| gpa.free(v);
        },
        .done => saw_done = true,
        else => ev.deinit(gpa),
    };
    try testing.expect(saw_error_empty);
    try testing.expect(!saw_done);
}

test "runFromSseWithTrace: trace_id surfaces as a .diagnostic event (v1.29.0)" {
    // The provider hands trace_id_owned (allocated by writeTraceFile)
    // to runFromSseWithTrace, which pushes it as the first
    // diagnostic event. Channel takes ownership; we free it here
    // after popping.
    const gpa = testing.allocator;
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    var ch = try Channel.init(gpa, 16);
    defer ch.deinit();
    var cancel: stream_mod.Cancel = .{};

    const tid = try gpa.dupe(u8, "1777498943846-0001");
    const sse =
        "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"hi\"}]}}]}\n\n" ++
        "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"\"}]},\"finishReason\":\"STOP\"}]}\n\n";

    try runFromSseWithTrace(gpa, io, sse, &ch, &cancel, tid);

    var saw_trace_id = false;
    while (ch.next(io)) |ev| switch (ev) {
        .diagnostic => |d| {
            if (d.trace_id) |s| {
                if (std.mem.eql(u8, s, "1777498943846-0001")) saw_trace_id = true;
                gpa.free(s);
            }
            if (d.finish_reason_raw) |s| gpa.free(s);
        },
        .text_delta => |d| gpa.free(d.delta),
        else => ev.deinit(gpa),
    };
    try testing.expect(saw_trace_id);
}
