//! OpenAI Responses API provider — §A.4.
//!
//! Endpoint: `POST /v1/responses`. Unified reasoning + multimodal
//! shape. Request uses `input` (array of items) instead of `messages`;
//! items have types `message`, `function_call`, `function_call_output`,
//! `reasoning`. Tool definitions nest under `tools: [{type: "function",
//! name, description, parameters}]` (no `function` wrapper — the
//! function fields are on the tool itself). `reasoning: {effort: …}`
//! controls thinking.
//!
//! SSE event types we translate:
//!
//!   response.output_text.delta         → text_delta
//!   response.function_call_arguments.delta → toolcall_delta
//!   response.reasoning_summary_text.delta  → thinking_delta
//!   response.output_item.done          → per-slot end (synthesized)
//!   response.completed                 → done
//!   response.failed / response.incomplete → error_ev
//!
//! Registers under api tag `openai-responses`.

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

pub const default_endpoint: []const u8 = "https://api.openai.com/v1/responses";

/// JSON Schema keywords that OpenAI Responses API (and most
/// OpenAI-compatible providers) do NOT support. These are stripped
/// from tool parameter schemas before serialization.
const unsupported_schema_keys = [_][]const u8{
    "oneOf",
    "anyOf",
    "allOf",
    "$ref",
    "$defs",
    "definitions",
    "if",
    "then",
    "else",
    "not",
    "const",
    "contains",
};

/// Parse `schema_json`, walk it recursively, drop keys that
/// OpenAI-compatible providers reject (oneOf, anyOf, allOf, $ref,
/// etc.), then serialize the result back into `buf`. Falls back
/// to inlining the original (unsanitized) schema if parsing fails.
///
/// Fast path: substring scan — if none of the unsupported keywords
/// appear, inline verbatim. Machinery lives in `ai.utils`
/// (v1.3.0 dedup); this file owns only the key list.
fn appendSanitizedSchema(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    schema_json: []const u8,
) !void {
    return utils.appendSanitizedSchema(buf, allocator, schema_json, &unsupported_schema_keys);
}

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

    if (options.max_tokens) |mt| {
        try buf.appendSlice(allocator, ",\"max_output_tokens\":");
        try utils.appendJsonInt(&buf, allocator, @intCast(mt));
    }
    if (options.temperature) |t| {
        try buf.appendSlice(allocator, ",\"temperature\":");
        try utils.appendJsonFloat(&buf, allocator, t);
    }

    if (options.thinking.openaiResponsesEffort()) |effort| {
        try buf.appendSlice(allocator, ",\"reasoning\":{\"effort\":");
        try utils.appendJsonStr(&buf, allocator, effort);
        try buf.append(allocator, '}');
    }

    if (context.tools.len > 0) {
        try buf.appendSlice(allocator, ",\"tools\":[");
        for (context.tools, 0..) |t, i| {
            if (i > 0) try buf.append(allocator, ',');
            try buf.appendSlice(allocator, "{\"type\":\"function\",\"name\":");
            try utils.appendJsonStr(&buf, allocator, t.name);
            try buf.appendSlice(allocator, ",\"description\":");
            try utils.appendJsonStr(&buf, allocator, t.description);
            try buf.appendSlice(allocator, ",\"parameters\":");
            try appendSanitizedSchema(&buf, allocator, t.parameters_json);
            try buf.append(allocator, '}');
        }
        try buf.append(allocator, ']');
    }

    // System message is supported via `instructions`.
    if (context.system_prompt.len > 0) {
        try buf.appendSlice(allocator, ",\"instructions\":");
        try utils.appendJsonStr(&buf, allocator, context.system_prompt);
    }

    try buf.appendSlice(allocator, ",\"input\":[");
    var first = true;
    for (context.messages) |m| {
        if (!try appendInputItem(&buf, allocator, m, first)) continue;
        first = false;
    }
    try buf.append(allocator, ']');

    try buf.append(allocator, '}');
    return buf.toOwnedSlice(allocator);
}

fn appendInputItem(
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
        .user => {
            try buf.appendSlice(allocator, "{\"type\":\"message\",\"role\":\"user\",\"content\":[");
            for (m.content, 0..) |cb, i| {
                if (i > 0) try buf.append(allocator, ',');
                switch (cb) {
                    .text => |t| {
                        try buf.appendSlice(allocator, "{\"type\":\"input_text\",\"text\":");
                        try utils.appendJsonStr(buf, allocator, t.text);
                        try buf.append(allocator, '}');
                    },
                    else => try buf.appendSlice(allocator, "{\"type\":\"input_text\",\"text\":\"[unsupported]\"}"),
                }
            }
            try buf.appendSlice(allocator, "]}");
        },
        .assistant => {
            // Emit each tool_call as a top-level `function_call`
            // item. Emit each text block as a message-role item.
            var emitted = false;
            for (m.content) |cb| switch (cb) {
                .tool_call => |tc| {
                    if (emitted) try buf.append(allocator, ',');
                    try buf.appendSlice(allocator, "{\"type\":\"function_call\",\"call_id\":");
                    try utils.appendJsonStr(buf, allocator, tc.id);
                    try buf.appendSlice(allocator, ",\"name\":");
                    try utils.appendJsonStr(buf, allocator, tc.name);
                    try buf.appendSlice(allocator, ",\"arguments\":");
                    // v1.16.2 — sanitize first: strict openai-compat gateways
                    // reparse `arguments` as JSON and reject malformed escapes
                    // (e.g. `\c`) that some open-source models emit. See
                    // `utils.sanitizeJsonString`.
                    const raw_args = if (tc.arguments_json.len == 0) "{}" else tc.arguments_json;
                    const safe_args = try utils.sanitizeJsonString(allocator, raw_args);
                    defer allocator.free(safe_args);
                    try utils.appendJsonStr(buf, allocator, safe_args);
                    try buf.append(allocator, '}');
                    emitted = true;
                },
                .text => |t| {
                    if (emitted) try buf.append(allocator, ',');
                    try buf.appendSlice(allocator, "{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":");
                    try utils.appendJsonStr(buf, allocator, t.text);
                    try buf.appendSlice(allocator, "}]}");
                    emitted = true;
                },
                else => {},
            };
            if (!emitted) try buf.appendSlice(allocator, "{\"type\":\"message\",\"role\":\"assistant\",\"content\":[]}");
        },
        .tool_result => {
            try buf.appendSlice(allocator, "{\"type\":\"function_call_output\",\"call_id\":");
            try utils.appendJsonStr(buf, allocator, m.tool_call_id orelse "");
            try buf.appendSlice(allocator, ",\"output\":");
            var text_buf: std.ArrayList(u8) = .empty;
            defer text_buf.deinit(allocator);
            for (m.content) |cb| switch (cb) {
                .text => |t| try text_buf.appendSlice(allocator, t.text),
                else => {},
            };
            try utils.appendJsonStr(buf, allocator, text_buf.items);
            try buf.append(allocator, '}');
        },
        .custom => unreachable,
    }
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
    var driver = Driver{ .allocator = allocator, .io = io, .out = out };
    defer driver.deinit();

    const result = http_mod.driveSseFromBytes(allocator, sse_body, cancel, Driver.onEvent, @ptrCast(&driver));
    if (result) |_| {
        if (!driver.closed) {
            stream_mod.closeWithDiagnostics(out, io, allocator, .{
                .provider = "openai-responses",
                .stop_reason = driver.stop_reason orelse .stop,
                .text_seen = driver.text_seen,
                .thinking_seen = driver.thinking_seen,
                .tool_count = driver.seen_tool_slots,
                .parts_seen = driver.parts_seen,
                .candidates_tokens = driver.candidates_tokens,
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
    started_tool_slots: std.AutoHashMap(u32, void) = undefined,
    started_init: bool = false,
    seen_tool_slots: u32 = 0,
    stop_reason: ?types.StopReason = null,
    closed: bool = false,
    /// v1.29.0 — diagnostics (see `stream.TerminalInfo`).
    parts_seen: u32 = 0,
    text_seen: bool = false,
    thinking_seen: bool = false,
    candidates_tokens: ?u64 = null,

    fn lazyInit(self: *Driver) !void {
        if (self.started_init) return;
        self.started_tool_slots = std.AutoHashMap(u32, void).init(self.allocator);
        self.started_init = true;
    }

    fn deinit(self: *Driver) void {
        if (self.started_init) self.started_tool_slots.deinit();
    }

    fn onEvent(ud: ?*anyopaque, ev: sse_mod.Event) http_mod.EventHandlerError!void {
        const self: *Driver = @ptrCast(@alignCast(ud.?));
        self.lazyInit() catch return http_mod.EventHandlerError.OutOfMemory;
        self.handle(ev) catch |e| switch (e) {
            error.OutOfMemory => return http_mod.EventHandlerError.OutOfMemory,
            error.Closed => return http_mod.EventHandlerError.Handler,
        };
    }

    fn handle(self: *Driver, ev: sse_mod.Event) !void {
        const name = ev.event orelse return;

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), ev.data, .{}) catch return;
        if (parsed.value != .object) return;
        const obj = parsed.value.object;

        if (std.mem.eql(u8, name, "response.output_text.delta")) {
            if (obj.get("delta")) |d| if (d == .string) {
                self.parts_seen +%= 1;
                if (d.string.len > 0) self.text_seen = true;
                try self.out.push(self.io, .{ .text_delta = .{
                    .block_index = 0,
                    .delta = try self.allocator.dupe(u8, d.string),
                } });
            };
            return;
        }
        if (std.mem.eql(u8, name, "response.reasoning_summary_text.delta")) {
            if (obj.get("delta")) |d| if (d == .string) {
                self.parts_seen +%= 1;
                if (d.string.len > 0) self.thinking_seen = true;
                try self.out.push(self.io, .{ .thinking_delta = .{
                    .block_index = 0,
                    .delta = try self.allocator.dupe(u8, d.string),
                } });
            };
            return;
        }
        if (std.mem.eql(u8, name, "response.function_call_arguments.delta")) {
            const idx: u32 = if (obj.get("output_index")) |v|
                (if (v == .integer) @intCast(v.integer) else 0)
            else
                0;
            if (!self.started_tool_slots.contains(idx)) {
                const id = if (obj.get("item_id")) |v| (if (v == .string) v.string else "") else "";
                const tname = if (obj.get("name")) |v| (if (v == .string) v.string else "") else "";
                try self.out.push(self.io, .{ .toolcall_start = .{
                    .block_index = idx,
                    .id = try self.allocator.dupe(u8, id),
                    .name = try self.allocator.dupe(u8, tname),
                } });
                try self.started_tool_slots.put(idx, {});
                if (idx + 1 > self.seen_tool_slots) self.seen_tool_slots = idx + 1;
            }
            if (obj.get("delta")) |d| if (d == .string and d.string.len > 0) {
                try self.out.push(self.io, .{ .toolcall_delta = .{
                    .block_index = idx,
                    .args_delta = try self.allocator.dupe(u8, d.string),
                } });
            };
            return;
        }
        if (std.mem.eql(u8, name, "response.completed")) {
            // Flush tool_end stubs.
            var i: u32 = 0;
            while (i < self.seen_tool_slots) : (i += 1) {
                try self.out.push(self.io, .{ .toolcall_end = .{
                    .block_index = i,
                    .args_json = try self.allocator.dupe(u8, ""),
                } });
            }
            // Usage if present.
            if (obj.get("response")) |r| if (r == .object) {
                if (r.object.get("usage")) |uv| if (uv == .object) {
                    const inp: u64 = if (uv.object.get("input_tokens")) |v| (if (v == .integer) @intCast(v.integer) else 0) else 0;
                    const out: u64 = if (uv.object.get("output_tokens")) |v| (if (v == .integer) @intCast(v.integer) else 0) else 0;
                    self.candidates_tokens = out;
                    try self.out.push(self.io, .{ .usage = .{ .input = inp, .output = out } });
                };
            };
            self.stop_reason = .stop;
            stream_mod.closeWithDiagnostics(self.out, self.io, self.allocator, .{
                .provider = "openai-responses",
                .stop_reason = self.stop_reason.?,
                .text_seen = self.text_seen,
                .thinking_seen = self.thinking_seen,
                .tool_count = self.seen_tool_slots,
                .parts_seen = self.parts_seen,
                .candidates_tokens = self.candidates_tokens,
            });
            self.closed = true;
            return;
        }
        if (std.mem.eql(u8, name, "response.failed") or std.mem.eql(u8, name, "response.incomplete")) {
            const msg = if (obj.get("response")) |r|
                (if (r == .object) (if (r.object.get("error")) |er| (if (er == .object) (if (er.object.get("message")) |m| (if (m == .string) m.string else "") else "") else "") else "") else "")
            else
                "openai responses error";
            self.out.closeWithFinal(self.io, .{ .error_ev = .{
                .code = .internal,
                .message = try self.allocator.dupe(u8, msg),
            } });
            self.closed = true;
            return;
        }
    }
};

// ─── registry entry ──────────────────────────────────────────────

pub fn streamFn(ctx: registry_mod.StreamCtx) anyerror!void {
    const credential: []const u8 = ctx.options.api_key orelse ctx.options.auth_token orelse {
        try ctx.out.push(ctx.io, .start);
        ctx.out.closeWithFinal(ctx.io, .{ .error_ev = .{
            .code = errors.Code.auth,
            .message = try ctx.allocator.dupe(u8, "openai-responses: no credential (set --api-key or OPENAI_API_KEY)"),
        } });
        return;
    };

    const body = try buildRequestJson(ctx.allocator, ctx.model, ctx.context, ctx.options);
    defer ctx.allocator.free(body);

    log.log(.debug, "http", "request", "provider=openai-responses model={s} body_bytes={d}", .{ ctx.model.id, body.len });
    log.body(.trace, "http", "request_body", body, 64 * 1024);

    const auth_header = try std.fmt.allocPrint(ctx.allocator, "Bearer {s}", .{credential});
    defer ctx.allocator.free(auth_header);

    var http_headers_buf: [3]std.http.Header = undefined;
    http_headers_buf[0] = .{ .name = "authorization", .value = auth_header };
    http_headers_buf[1] = .{ .name = "content-type", .value = "application/json" };
    http_headers_buf[2] = .{ .name = "accept", .value = "text/event-stream" };
    const http_headers = http_headers_buf[0..3];

    const cancel = ctx.options.cancel orelse unreachable;

    var sc = http_mod.acquireStreamClient(ctx) orelse return;
    defer sc.deinit();
    const client = sc.client;

    var bw = std.Io.Writer.Allocating.init(ctx.allocator);
    defer bw.deinit();

    const endpoint: []const u8 = ctx.options.base_url orelse default_endpoint;
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
        "openai-responses",
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

test "buildRequestJson: stream=true + instructions + input/message shape" {
    const gpa = testing.allocator;
    var uc = [_]types.ContentBlock{.{ .text = .{ .text = "hi" } }};
    var msgs = [_]types.Message{.{ .role = .user, .content = &uc, .timestamp = 0 }};
    const ctx: types.Context = .{ .system_prompt = "you are helpful", .messages = &msgs, .tools = &.{} };
    const model: types.Model = .{ .id = "o1", .provider = "openai", .api = "openai-responses" };
    const body = try buildRequestJson(gpa, model, ctx, .{});
    defer gpa.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"model\":\"o1\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"stream\":true") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"instructions\":\"you are helpful\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"type\":\"message\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"type\":\"input_text\"") != null);
}

test "buildRequestJson: reasoning.effort mapped from thinking level" {
    const gpa = testing.allocator;
    var uc = [_]types.ContentBlock{.{ .text = .{ .text = "?" } }};
    var msgs = [_]types.Message{.{ .role = .user, .content = &uc, .timestamp = 0 }};
    const ctx: types.Context = .{ .system_prompt = "", .messages = &msgs, .tools = &.{} };
    const model: types.Model = .{ .id = "o3", .provider = "openai", .api = "openai-responses" };

    const body = try buildRequestJson(gpa, model, ctx, .{ .thinking = .high });
    defer gpa.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"reasoning\":{\"effort\":\"high\"}") != null);
}

test "buildRequestJson: tools serialize without the nested function wrapper" {
    const gpa = testing.allocator;
    const tool: types.Tool = .{
        .name = "get_time",
        .description = "returns now",
        .parameters_json = "{\"type\":\"object\"}",
    };
    var uc = [_]types.ContentBlock{.{ .text = .{ .text = "q" } }};
    var msgs = [_]types.Message{.{ .role = .user, .content = &uc, .timestamp = 0 }};
    var tools = [_]types.Tool{tool};
    const ctx: types.Context = .{ .system_prompt = "", .messages = &msgs, .tools = &tools };
    const model: types.Model = .{ .id = "o1", .provider = "openai", .api = "openai-responses" };
    const body = try buildRequestJson(gpa, model, ctx, .{});
    defer gpa.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"tools\":[{\"type\":\"function\",\"name\":\"get_time\"") != null);
    // No nested function wrapper — the function fields are directly on the tool entry.
    try testing.expect(std.mem.indexOf(u8, body, "\"function\":{") == null);
}

test "buildRequestJson: assistant tool-call emits function_call item" {
    const gpa = testing.allocator;
    var uc = [_]types.ContentBlock{.{ .text = .{ .text = "q" } }};
    var asst_c = [_]types.ContentBlock{.{ .tool_call = .{
        .id = "call_1",
        .name = "do_thing",
        .arguments_json = "{\"a\":1}",
    } }};
    var tr_c = [_]types.ContentBlock{.{ .text = .{ .text = "ok" } }};
    var msgs = [_]types.Message{
        .{ .role = .user, .content = &uc, .timestamp = 0 },
        .{ .role = .assistant, .content = &asst_c, .timestamp = 0 },
        .{ .role = .tool_result, .tool_call_id = "call_1", .content = &tr_c, .timestamp = 0 },
    };
    const ctx: types.Context = .{ .system_prompt = "", .messages = &msgs, .tools = &.{} };
    const model: types.Model = .{ .id = "o1", .provider = "openai", .api = "openai-responses" };
    const body = try buildRequestJson(gpa, model, ctx, .{});
    defer gpa.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"type\":\"function_call\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"call_id\":\"call_1\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"type\":\"function_call_output\"") != null);
}

test "runFromSse: text delta + completed → done" {
    const gpa = testing.allocator;
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    var ch = try Channel.init(gpa, 16);
    defer ch.deinit();
    var cancel: stream_mod.Cancel = .{};

    const sse =
        "event: response.output_text.delta\ndata: {\"delta\":\"Hel\"}\n\n" ++
        "event: response.output_text.delta\ndata: {\"delta\":\"lo\"}\n\n" ++
        "event: response.completed\ndata: {\"response\":{\"usage\":{\"input_tokens\":3,\"output_tokens\":2}}}\n\n";

    try runFromSse(gpa, io, sse, &ch, &cancel);

    var seen_bytes: usize = 0;
    var seen_done = false;
    var seen_usage = false;
    while (ch.next(io)) |ev| switch (ev) {
        .text_delta => |d| {
            seen_bytes += d.delta.len;
            gpa.free(d.delta);
        },
        .usage => |u| {
            seen_usage = true;
            try testing.expectEqual(@as(u64, 3), u.input);
            try testing.expectEqual(@as(u64, 2), u.output);
        },
        .done => seen_done = true,
        else => ev.deinit(gpa),
    };
    try testing.expectEqual(@as(usize, 5), seen_bytes);
    try testing.expect(seen_usage);
    try testing.expect(seen_done);
}

test "runFromSse: function_call_arguments.delta emits toolcall events" {
    const gpa = testing.allocator;
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    var ch = try Channel.init(gpa, 32);
    defer ch.deinit();
    var cancel: stream_mod.Cancel = .{};

    const sse =
        "event: response.function_call_arguments.delta\ndata: {\"output_index\":0,\"item_id\":\"c1\",\"name\":\"f\",\"delta\":\"{\\\"x\\\":\"}\n\n" ++
        "event: response.function_call_arguments.delta\ndata: {\"output_index\":0,\"delta\":\"1}\"}\n\n" ++
        "event: response.completed\ndata: {\"response\":{}}\n\n";

    try runFromSse(gpa, io, sse, &ch, &cancel);

    var saw_start = false;
    var saw_end = false;
    var start_name: []const u8 = "";
    var start_id: []const u8 = "";
    var args: std.ArrayList(u8) = .empty;
    defer args.deinit(gpa);
    while (ch.next(io)) |ev| switch (ev) {
        .toolcall_start => |s| {
            saw_start = true;
            start_name = s.name;
            start_id = s.id;
        },
        .toolcall_delta => |d| {
            try args.appendSlice(gpa, d.args_delta);
            gpa.free(d.args_delta);
        },
        .toolcall_end => |e| {
            saw_end = true;
            gpa.free(e.args_json);
        },
        .done => {},
        else => ev.deinit(gpa),
    };
    try testing.expect(saw_start);
    try testing.expect(saw_end);
    try testing.expectEqualStrings("f", start_name);
    try testing.expectEqualStrings("c1", start_id);
    try testing.expectEqualStrings("{\"x\":1}", args.items);
    gpa.free(start_name);
    gpa.free(start_id);
}
