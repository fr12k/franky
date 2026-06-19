//! Anthropic Messages provider — §A.2 of the spec.
//!
//! Implements request serialization and SSE event translation. Works
//! against both the real API and synthetic SSE byte streams via
//! `runFromSse` (used by tests).
//!
//! Register with the registry:
//!
//!     try registry.register(.{
//!         .api = "anthropic-messages",
//!         .provider = "anthropic",
//!         .stream_fn = anthropic.streamFn,
//!     });
//!
//! The registry-dispatched `streamFn` performs a real HTTPS POST.

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

const Channel = channel_mod
    .Channel(stream_mod.StreamEvent);

pub const default_endpoint: []const u8 = "https://api.anthropic.com/v1/messages";
// pub const default_endpoint: []const u8 = "http://localhost:11434/v1/messages";
pub const default_version_header: []const u8 = "2023-06-01";
/// Beta header stack required when authenticating with an OAuth/JWT
/// bearer token (the Claude Pro/Max path). The combination of
/// `claude-code-20250219` and `oauth-2025-04-20` is what Claude Code
/// itself sends; without it the server either 400s or hits you with
/// aggressive 429 rate limits. See AUTH.md in this directory.
pub const oauth_beta_header: []const u8 = "claude-code-20250219,oauth-2025-04-20";
/// When OAuth bearer auth is used, Anthropic's Messages API silently
/// validates that the `system` field begins with this exact byte string
/// (as the whole plain string, or as the first element of a `system`
/// array). All non-Haiku models enforce this. Documented in
/// https://github.com/anthropics/claude-code/issues/40515.
pub const oauth_system_prefix: []const u8 = "You are Claude Code, Anthropic's official CLI for Claude.";
/// User-agent string the server fingerprints on for the OAuth path.
/// Non-matching agents get heavy rate-limiting even on a healthy token.
pub const oauth_user_agent: []const u8 = "claude-cli/2.1.85 (external, cli)";

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

    // max_tokens is required by the API. When extended thinking is on,
    // Anthropic requires `budget_tokens < max_tokens`; auto-bump
    // max_tokens so the request is accepted. 512 tokens of headroom is
    // arbitrary but enough for a short post-thinking answer.
    const base_max_tokens: u32 = options.max_tokens orelse model.max_output;
    const thinking_budget: u32 = options.thinking.anthropicBudget() orelse 0;
    const max_tokens: u32 = if (thinking_budget > 0 and base_max_tokens <= thinking_budget)
        thinking_budget + 512
    else
        base_max_tokens;
    try buf.appendSlice(allocator, ",\"max_tokens\":");
    try utils.appendJsonInt(&buf, allocator, @intCast(max_tokens));

    try buf.appendSlice(allocator, ",\"stream\":true");

    if (options.temperature) |t| {
        try buf.appendSlice(allocator, ",\"temperature\":");
        try utils.appendJsonFloat(&buf, allocator, t);
    }

    // OAuth path: emit `system` as a 1- or 2-element array whose first
    // entry is the fixed Claude Code prefix. The server silently rejects
    // anything else on non-Haiku models.
    if (options.auth_token != null) {
        try buf.appendSlice(allocator, ",\"system\":[{\"type\":\"text\",\"text\":");
        try utils.appendJsonStr(&buf, allocator, oauth_system_prefix);
        try buf.append(allocator, '}');
        if (context.system_prompt.len > 0 and
            !std.mem.eql(u8, context.system_prompt, oauth_system_prefix))
        {
            try buf.appendSlice(allocator, ",{\"type\":\"text\",\"text\":");
            try utils.appendJsonStr(&buf, allocator, context.system_prompt);
            try buf.append(allocator, '}');
        }
        try buf.append(allocator, ']');
    } else if (context.system_prompt.len > 0) {
        try buf.appendSlice(allocator, ",\"system\":");
        try utils.appendJsonStr(&buf, allocator, context.system_prompt);
    }

    if (options.thinking.anthropicBudget()) |budget| {
        try buf.appendSlice(allocator, ",\"thinking\":{\"type\":\"enabled\",\"budget_tokens\":");
        try utils.appendJsonInt(&buf, allocator, @intCast(budget));
        try buf.appendSlice(allocator, "}");
    }

    if (context.tools.len > 0) {
        try buf.appendSlice(allocator, ",\"tools\":[");
        for (context.tools, 0..) |t, i| {
            if (i > 0) try buf.append(allocator, ',');
            try buf.appendSlice(allocator, "{\"name\":");
            try utils.appendJsonStr(&buf, allocator, t.name);
            try buf.appendSlice(allocator, ",\"description\":");
            try utils.appendJsonStr(&buf, allocator, t.description);
            try buf.appendSlice(allocator, ",\"input_schema\":");
            try buf.appendSlice(allocator, t.parameters_json);
            try buf.append(allocator, '}');
        }
        try buf.append(allocator, ']');
    }

    try buf.appendSlice(allocator, ",\"messages\":[");
    var first = true;
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
        .custom => return false, // custom roles are filtered before send
        .user, .tool_result, .assistant => {},
    }
    if (!first) try buf.append(allocator, ',');

    try buf.appendSlice(allocator, "{\"role\":");
    const role_str: []const u8 = switch (m.role) {
        .user, .tool_result => "user",
        .assistant => "assistant",
        .custom => unreachable,
    };
    try utils.appendJsonStr(buf, allocator, role_str);
    try buf.appendSlice(allocator, ",\"content\":[");

    if (m.role == .tool_result) {
        try buf.appendSlice(allocator, "{\"type\":\"tool_result\",\"tool_use_id\":");
        try utils.appendJsonStr(buf, allocator, m.tool_call_id orelse "");
        try buf.appendSlice(allocator, ",\"is_error\":");
        try buf.appendSlice(allocator, if (m.is_error) "true" else "false");
        try buf.appendSlice(allocator, ",\"content\":[");
        for (m.content, 0..) |cb, i| {
            if (i > 0) try buf.append(allocator, ',');
            try appendToolResultBlock(buf, allocator, cb);
        }
        try buf.appendSlice(allocator, "]}");
    } else {
        for (m.content, 0..) |cb, i| {
            if (i > 0) try buf.append(allocator, ',');
            try appendContentBlock(buf, allocator, cb);
        }
    }
    try buf.appendSlice(allocator, "]}");
    return true;
}

fn appendContentBlock(
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
        .thinking => |t| {
            if (t.redacted) {
                try buf.appendSlice(allocator, "{\"type\":\"redacted_thinking\",\"data\":");
                try utils.appendJsonStr(buf, allocator, t.thinking_signature orelse "");
                try buf.append(allocator, '}');
            } else {
                try buf.appendSlice(allocator, "{\"type\":\"thinking\",\"thinking\":");
                try utils.appendJsonStr(buf, allocator, t.thinking);
                if (t.thinking_signature) |sig| {
                    try buf.appendSlice(allocator, ",\"signature\":");
                    try utils.appendJsonStr(buf, allocator, sig);
                }
                try buf.append(allocator, '}');
            }
        },
        .image => |img| {
            try buf.appendSlice(allocator, "{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":");
            try utils.appendJsonStr(buf, allocator, img.mime_type);
            try buf.appendSlice(allocator, ",\"data\":");
            try utils.appendJsonStr(buf, allocator, img.data);
            try buf.appendSlice(allocator, "}}");
        },
        .tool_call => |tc| {
            try buf.appendSlice(allocator, "{\"type\":\"tool_use\",\"id\":");
            try utils.appendJsonStr(buf, allocator, tc.id);
            try buf.appendSlice(allocator, ",\"name\":");
            try utils.appendJsonStr(buf, allocator, tc.name);
            try buf.appendSlice(allocator, ",\"input\":");
            if (tc.arguments_json.len == 0) {
                try buf.appendSlice(allocator, "{}");
            } else {
                try buf.appendSlice(allocator, tc.arguments_json);
            }
            try buf.append(allocator, '}');
        },
    }
}

fn appendToolResultBlock(
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
            try buf.appendSlice(allocator, "{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":");
            try utils.appendJsonStr(buf, allocator, img.mime_type);
            try buf.appendSlice(allocator, ",\"data\":");
            try utils.appendJsonStr(buf, allocator, img.data);
            try buf.appendSlice(allocator, "}}");
        },
        else => {
            // tool results only carry text/image content
            try buf.appendSlice(allocator, "{\"type\":\"text\",\"text\":\"[unsupported block]\"}");
        },
    }
}

// ─── SSE → StreamEvent ────────────────────────────────────────────

/// Run the Anthropic SSE event stream: parse each SSE event, translate
/// it into `StreamEvent`s, and push them into `out`. Closes `out` on
/// terminal (`message_stop` or `error`).
pub fn runFromSse(
    allocator: std.mem.Allocator,
    io: std.Io,
    sse_body: []const u8,
    out: *Channel,
    cancel: *stream_mod.Cancel,
) !void {
    return runFromSseWithTrace(allocator, io, sse_body, out, cancel, null);
}

/// v1.29.0 — runFromSse + trace_id. Channel takes ownership of
/// `trace_id`; pass `null` to skip.
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
                .provider = "anthropic",
                .stop_reason = driver.stop_reason orelse .stop,
                .text_seen = driver.text_seen,
                .thinking_seen = driver.thinking_seen,
                .tool_count = driver.tool_count,
                .parts_seen = driver.parts_seen,
                .finish_reason_raw = driver.finish_reason_owned,
                .candidates_tokens = driver.candidates_tokens,
            });
        }
    } else |e| {
        stream_mod.closeOnSseError(out, io, allocator, e);
    }
}

/// Per-stream state machine that translates Anthropic events into franky
/// events. Anthropic's content-block model maps to our per-kind indexing
/// via a tiny bookkeeping layer: anthropic's global `index` becomes our
/// kind-local `block_index`.
const Driver = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    out: *Channel,

    /// The kind of the content block at each anthropic index (once
    /// `content_block_start` arrives).
    slot_kind: std.AutoHashMap(u32, SlotKind) = undefined,
    slot_kind_init: bool = false,
    /// Per-kind counters: how many text/thinking/tool_call blocks have
    /// been opened so far.
    text_count: u32 = 0,
    thinking_count: u32 = 0,
    tool_count: u32 = 0,
    /// Anthropic index → per-kind index assigned at content_block_start.
    slot_kind_idx: std.AutoHashMap(u32, u32) = undefined,

    stop_reason: ?types.StopReason = null,
    closed: bool = false,
    /// v1.29.0 — diagnostic counters (see `stream.TerminalInfo`).
    /// `parts_seen` increments on `content_block_start` (each opens
    /// a "part" in Anthropic's model); the seen-flags track whether
    /// any non-empty delta of that kind was actually pushed.
    parts_seen: u32 = 0,
    text_seen: bool = false,
    thinking_seen: bool = false,
    finish_reason_owned: ?[]u8 = null,
    candidates_tokens: ?u64 = null,

    const SlotKind = enum { text, thinking, tool_call };

    fn lazyInit(self: *Driver) !void {
        if (self.slot_kind_init) return;
        self.slot_kind = std.AutoHashMap(u32, SlotKind).init(self.allocator);
        self.slot_kind_idx = std.AutoHashMap(u32, u32).init(self.allocator);
        self.slot_kind_init = true;
    }

    fn deinit(self: *Driver) void {
        if (self.slot_kind_init) {
            self.slot_kind.deinit();
            self.slot_kind_idx.deinit();
        }
        if (self.finish_reason_owned) |s| self.allocator.free(s);
    }

    fn onEvent(ud: ?*anyopaque, ev: sse_mod.Event) http_mod.EventHandlerError!void {
        const self: *Driver = @ptrCast(@alignCast(ud.?));
        self.lazyInit() catch return http_mod.EventHandlerError.OutOfMemory;

        const ev_name = ev.event orelse return;
        self.handle(ev_name, ev.data) catch |e| switch (e) {
            error.OutOfMemory => return http_mod.EventHandlerError.OutOfMemory,
            error.Closed => return http_mod.EventHandlerError.Handler,
        };
    }

    fn handle(self: *Driver, name: []const u8, data: []const u8) !void {
        if (std.mem.eql(u8, name, "ping")) return;

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), data, .{}) catch return;
        const root = parsed.value;

        if (std.mem.eql(u8, name, "message_start")) return;

        if (std.mem.eql(u8, name, "content_block_start")) {
            self.parts_seen +%= 1;
            const idx: u32 = @intCast(root.object.get("index").?.integer);
            const cb = root.object.get("content_block") orelse return;
            const ty = cb.object.get("type") orelse return;
            if (ty != .string) return;
            if (std.mem.eql(u8, ty.string, "text")) {
                try self.slot_kind.put(idx, .text);
                try self.slot_kind_idx.put(idx, self.text_count);
                self.text_count += 1;
            } else if (std.mem.eql(u8, ty.string, "thinking") or std.mem.eql(u8, ty.string, "redacted_thinking")) {
                try self.slot_kind.put(idx, .thinking);
                try self.slot_kind_idx.put(idx, self.thinking_count);
                self.thinking_count += 1;
            } else if (std.mem.eql(u8, ty.string, "tool_use")) {
                try self.slot_kind.put(idx, .tool_call);
                const kidx = self.tool_count;
                try self.slot_kind_idx.put(idx, kidx);
                self.tool_count += 1;
                const id = cb.object.get("id").?.string;
                const tname = cb.object.get("name").?.string;
                try self.out.push(self.io, .{ .toolcall_start = .{
                    .block_index = kidx,
                    .id = try self.allocator.dupe(u8, id),
                    .name = try self.allocator.dupe(u8, tname),
                } });
            }
            return;
        }

        if (std.mem.eql(u8, name, "content_block_delta")) {
            const idx: u32 = @intCast(root.object.get("index").?.integer);
            const delta = root.object.get("delta") orelse return;
            const ty = delta.object.get("type") orelse return;
            if (ty != .string) return;
            const kidx = self.slot_kind_idx.get(idx) orelse return;
            if (std.mem.eql(u8, ty.string, "text_delta")) {
                const text = delta.object.get("text") orelse return;
                if (text != .string) return;
                if (text.string.len > 0) self.text_seen = true;
                try self.out.push(self.io, .{ .text_delta = .{
                    .block_index = kidx,
                    .delta = try self.allocator.dupe(u8, text.string),
                } });
            } else if (std.mem.eql(u8, ty.string, "thinking_delta")) {
                const text = delta.object.get("thinking") orelse return;
                if (text != .string) return;
                if (text.string.len > 0) self.thinking_seen = true;
                try self.out.push(self.io, .{ .thinking_delta = .{
                    .block_index = kidx,
                    .delta = try self.allocator.dupe(u8, text.string),
                } });
            } else if (std.mem.eql(u8, ty.string, "signature_delta")) {
                const sig = delta.object.get("signature") orelse return;
                if (sig != .string) return;
                try self.out.push(self.io, .{ .thinking_delta = .{
                    .block_index = kidx,
                    .delta = try self.allocator.dupe(u8, sig.string),
                    .is_signature = true,
                } });
            } else if (std.mem.eql(u8, ty.string, "input_json_delta")) {
                const partial = delta.object.get("partial_json") orelse return;
                if (partial != .string) return;
                try self.out.push(self.io, .{ .toolcall_delta = .{
                    .block_index = kidx,
                    .args_delta = try self.allocator.dupe(u8, partial.string),
                } });
            }
            return;
        }

        if (std.mem.eql(u8, name, "content_block_stop")) {
            const idx: u32 = @intCast(root.object.get("index").?.integer);
            const kind = self.slot_kind.get(idx) orelse return;
            if (kind == .tool_call) {
                const kidx = self.slot_kind_idx.get(idx).?;
                // Anthropic emits input as incremental JSON; the final
                // concatenated string has been built by the reducer. We
                // emit an empty toolcall_end because we don't have the
                // authoritative string here — the Reducer already has
                // concatenated args. This matches invariant 6.
                try self.out.push(self.io, .{ .toolcall_end = .{
                    .block_index = kidx,
                    .args_json = try self.allocator.dupe(u8, ""),
                } });
            }
            return;
        }

        if (std.mem.eql(u8, name, "message_delta")) {
            if (root.object.get("delta")) |d| if (d == .object) {
                if (d.object.get("stop_reason")) |sr| if (sr == .string) {
                    self.stop_reason = types.StopReason.fromString(sr.string) orelse .stop;
                    if (self.finish_reason_owned) |old| self.allocator.free(old);
                    self.finish_reason_owned = self.allocator.dupe(u8, sr.string) catch null;
                };
            };
            if (root.object.get("usage")) |uv| if (uv == .object) {
                const inp: u64 = if (uv.object.get("input_tokens")) |v| @intCast(v.integer) else 0;
                const out: u64 = if (uv.object.get("output_tokens")) |v| @intCast(v.integer) else 0;
                self.candidates_tokens = out;
                try self.out.push(self.io, .{ .usage = .{ .input = inp, .output = out } });
            };
            return;
        }

        if (std.mem.eql(u8, name, "message_stop")) {
            stream_mod.closeWithDiagnostics(self.out, self.io, self.allocator, .{
                .provider = "anthropic",
                .stop_reason = self.stop_reason orelse .stop,
                .text_seen = self.text_seen,
                .thinking_seen = self.thinking_seen,
                .tool_count = self.tool_count,
                .parts_seen = self.parts_seen,
                .finish_reason_raw = self.finish_reason_owned,
                .candidates_tokens = self.candidates_tokens,
            });
            self.closed = true;
            return;
        }

        if (std.mem.eql(u8, name, "error")) {
            const err_obj = root.object.get("error") orelse return;
            const msg = if (err_obj.object.get("message")) |m| m.string else "anthropic error";
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

/// Stream function for registry.register.
///
/// Authentication: prefers `options.auth_token` (OAuth / JWT bearer) over
/// `options.api_key`. See `AUTH.md` in this directory for the full
/// precedence and header shape.
pub fn streamFn(ctx: registry_mod.StreamCtx) anyerror!void {
    const use_bearer = ctx.options.auth_token != null;
    const credential: []const u8 = ctx.options.auth_token orelse ctx.options.api_key orelse {
        try ctx.out.push(ctx.io, .start);
        ctx.out.closeWithFinal(ctx.io, .{ .error_ev = .{
            .code = errors.Code.auth,
            .message = try ctx.allocator.dupe(
                u8,
                "anthropic provider: no credential (set --api-key, --auth-token, ANTHROPIC_API_KEY, ANTHROPIC_AUTH_TOKEN, or CLAUDE_CODE_OAUTH_TOKEN)",
            ),
        } });
        return;
    };

    const body = try buildRequestJson(ctx.allocator, ctx.model, ctx.context, ctx.options);
    defer ctx.allocator.free(body);

    log.log(.debug, "http", "request", "provider=anthropic model={s} scheme={s} body_bytes={d}", .{
        ctx.model.id,
        if (use_bearer) "bearer" else "x-api-key",
        body.len,
    });
    log.body(.trace, "http", "request_body", body, 64 * 1024);

    // Bearer path needs "Bearer <token>"; API-key path sends the key verbatim.
    const auth_header = if (use_bearer)
        try std.fmt.allocPrint(ctx.allocator, "Bearer {s}", .{credential})
    else
        try ctx.allocator.dupe(u8, credential);
    defer ctx.allocator.free(auth_header);

    // `http_headers` ownership: the name/value slices below are all either
    // static strings or `auth_header` (freed by this function). http_mod.Client
    // only borrows them for the duration of fetch().
    var http_headers_buf: [7]std.http.Header = undefined;
    var http_headers_len: usize = 0;
    if (use_bearer) {
        http_headers_buf[http_headers_len] = .{ .name = "authorization", .value = auth_header };
        http_headers_len += 1;
        http_headers_buf[http_headers_len] = .{ .name = "anthropic-beta", .value = oauth_beta_header };
        http_headers_len += 1;
        // The OAuth path is fingerprinted on these two. Omit either and
        // Anthropic rate-limits hard (even on a healthy subscription).
        http_headers_buf[http_headers_len] = .{ .name = "user-agent", .value = oauth_user_agent };
        http_headers_len += 1;
        http_headers_buf[http_headers_len] = .{ .name = "x-app", .value = "cli" };
        http_headers_len += 1;
    } else {
        http_headers_buf[http_headers_len] = .{ .name = "x-api-key", .value = auth_header };
        http_headers_len += 1;
    }
    http_headers_buf[http_headers_len] = .{ .name = "anthropic-version", .value = default_version_header };
    http_headers_len += 1;
    http_headers_buf[http_headers_len] = .{ .name = "content-type", .value = "application/json" };
    http_headers_len += 1;
    http_headers_buf[http_headers_len] = .{ .name = "accept", .value = "text/event-stream" };
    http_headers_len += 1;
    const http_headers = http_headers_buf[0..http_headers_len];

    // Capture body via http_mod.streamSse. Since streamSse buffers the
    // body in our first pass, this still works for short test conversations.
    // For production a streaming adapter would plug in here.
    const cancel = ctx.options.cancel orelse unreachable;

    // Response body accumulator. `Allocating.fromArrayList` silently
    // takes ownership of the ArrayList's buffer and leaves it empty, so
    // a `body.deinit()` on the original list would be a no-op and leak
    // whatever the writer grew. Keep the Allocating as the sole owner
    // and free it via its own deinit.
    var bw = std.Io.Writer.Allocating.init(ctx.allocator);
    defer bw.deinit();

    // Reuse streamSse by capturing bytes into the Allocating writer, then
    // hand the bytes to runFromSse.
    var sc = http_mod.acquireStreamClient(ctx) orelse return;
    defer sc.deinit();
    const client = sc.client;

    var phase_info: http_mod.PhaseInfo = .{};
    const result = http_mod.fetchWithRetryAndTimeoutsAndHooksAndPhases(client, .{
        .location = .{ .url = default_endpoint },
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
    log.body(.trace, "http", "response_body", response_body, 64 * 1024);
    const trace_id_owned = http_mod.writeTraceFile(
        ctx.allocator,
        ctx.io,
        ctx.options.http_trace_dir,
        "anthropic",
        default_endpoint,
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
            .anthropic,
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

fn newFauxChannel(gpa: std.mem.Allocator) !Channel {
    return try Channel.initWithDrop(gpa, 64, stream_mod.StreamEvent.deinit, gpa);
}

test "buildRequestJson serializes context fields" {
    const gpa = testing.allocator;
    var msgs: [1]types.Message = .{.{
        .role = .user,
        .content = blk: {
            const c = try gpa.alloc(types.ContentBlock, 1);
            c[0] = .{ .text = .{ .text = try gpa.dupe(u8, "hi") } };
            break :blk c;
        },
        .timestamp = 0,
    }};
    defer msgs[0].deinit(gpa);

    const context = types.Context{
        .system_prompt = "you are franky",
        .messages = &msgs,
        .tools = &.{},
    };
    const body = try buildRequestJson(
        gpa,
        .{ .id = "claude-sonnet-4", .provider = "anthropic", .api = "anthropic-messages", .max_output = 1024 },
        context,
        .{},
    );
    defer gpa.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"model\":\"claude-sonnet-4\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"stream\":true") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"system\":\"you are franky\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"max_tokens\":1024") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"role\":\"user\"") != null);
}

test "buildRequestJson auto-bumps max_tokens above thinking budget" {
    const gpa = testing.allocator;
    const context = types.Context{
        .system_prompt = "",
        .messages = &.{},
        .tools = &.{},
    };
    // max_output=4096, but thinking=high → budget 16384. Must exceed.
    const body = try buildRequestJson(
        gpa,
        .{ .id = "claude-opus-4-6", .provider = "anthropic", .api = "anthropic-messages", .max_output = 4096 },
        context,
        .{ .thinking = .high },
    );
    defer gpa.free(body);
    // 16384 + 512 = 16896.
    try testing.expect(std.mem.indexOf(u8, body, "\"max_tokens\":16896") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"budget_tokens\":16384") != null);
}

test "buildRequestJson leaves max_tokens alone when thinking fits" {
    const gpa = testing.allocator;
    const context = types.Context{
        .system_prompt = "",
        .messages = &.{},
        .tools = &.{},
    };
    const body = try buildRequestJson(
        gpa,
        .{ .id = "claude-opus-4-6", .provider = "anthropic", .api = "anthropic-messages", .max_output = 32768 },
        context,
        .{ .thinking = .low },
    );
    defer gpa.free(body);
    // thinking=low → budget 4096; max_output 32768 already exceeds it.
    try testing.expect(std.mem.indexOf(u8, body, "\"max_tokens\":32768") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"budget_tokens\":4096") != null);
}

test "buildRequestJson emits Claude Code system prefix when auth_token is set" {
    const gpa = testing.allocator;
    var msgs: [1]types.Message = .{.{
        .role = .user,
        .content = blk: {
            const c = try gpa.alloc(types.ContentBlock, 1);
            c[0] = .{ .text = .{ .text = try gpa.dupe(u8, "hi") } };
            break :blk c;
        },
        .timestamp = 0,
    }};
    defer msgs[0].deinit(gpa);

    const context = types.Context{
        .system_prompt = "you are franky",
        .messages = &msgs,
        .tools = &.{},
    };
    const body = try buildRequestJson(
        gpa,
        .{ .id = "claude-sonnet-4", .provider = "anthropic", .api = "anthropic-messages", .max_output = 1024 },
        context,
        .{ .auth_token = "sk-ant-oat01-fake" },
    );
    defer gpa.free(body);

    // Required Claude Code prefix must be the first `system` array entry.
    const expected_prefix =
        "\"system\":[{\"type\":\"text\",\"text\":\"You are Claude Code, Anthropic's official CLI for Claude.\"},";
    try testing.expect(std.mem.indexOf(u8, body, expected_prefix) != null);
    // User's own prompt follows as a separate entry.
    try testing.expect(std.mem.indexOf(u8, body, "\"text\":\"you are franky\"") != null);
    // Not the plain-string form.
    try testing.expect(std.mem.indexOf(u8, body, "\"system\":\"you are franky\"") == null);
}

test "buildRequestJson avoids duplicating the Claude Code prefix on bearer auth" {
    const gpa = testing.allocator;
    const context = types.Context{
        .system_prompt = "You are Claude Code, Anthropic's official CLI for Claude.",
        .messages = &.{},
        .tools = &.{},
    };
    const body = try buildRequestJson(
        gpa,
        .{ .id = "claude-sonnet-4", .provider = "anthropic", .api = "anthropic-messages", .max_output = 1024 },
        context,
        .{ .auth_token = "sk-ant-oat01-fake" },
    );
    defer gpa.free(body);

    // Prefix appears exactly once.
    var count: usize = 0;
    var it = std.mem.splitSequence(u8, body, "You are Claude Code, Anthropic's official CLI for Claude.");
    while (it.next()) |_| count += 1;
    try testing.expectEqual(@as(usize, 2), count); // 2 halves ⇒ 1 occurrence
}

test "runFromSse parses a synthetic text-only Anthropic stream" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const body =
        "event: message_start\ndata: {\"type\":\"message_start\"}\n\n" ++
        "event: content_block_start\ndata: {\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
        "event: content_block_delta\ndata: {\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello, \"}}\n\n" ++
        "event: content_block_delta\ndata: {\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"world!\"}}\n\n" ++
        "event: content_block_stop\ndata: {\"index\":0}\n\n" ++
        "event: message_delta\ndata: {\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"input_tokens\":5,\"output_tokens\":3}}\n\n" ++
        "event: message_stop\ndata: {}\n\n";

    var cancel = stream_mod.Cancel{};
    var ch = try newFauxChannel(gpa);
    defer ch.deinit();

    try runFromSse(gpa, io, body, &ch, &cancel);

    var msg = try stream_mod.drainToMessage(&ch, io, gpa, "anthropic", "claude-sonnet-4", "anthropic-messages");
    defer msg.deinit(gpa);

    try testing.expectEqual(@as(usize, 1), msg.content.len);
    try testing.expectEqualStrings("Hello, world!", msg.content[0].text.text);
    try testing.expectEqual(@as(u64, 5), msg.usage.?.input);
    try testing.expectEqual(@as(u64, 3), msg.usage.?.output);
}

test "runFromSse handles a tool_use block" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const body =
        "event: message_start\ndata: {}\n\n" ++
        "event: content_block_start\ndata: {\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"read\",\"input\":{}}}\n\n" ++
        "event: content_block_delta\ndata: {\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"path\\\":\"}}\n\n" ++
        "event: content_block_delta\ndata: {\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"\\\"/etc/hosts\\\"}\"}}\n\n" ++
        "event: content_block_stop\ndata: {\"index\":0}\n\n" ++
        "event: message_delta\ndata: {\"delta\":{\"stop_reason\":\"tool_use\"}}\n\n" ++
        "event: message_stop\ndata: {}\n\n";

    var cancel = stream_mod.Cancel{};
    var ch = try newFauxChannel(gpa);
    defer ch.deinit();

    try runFromSse(gpa, io, body, &ch, &cancel);

    var msg = try stream_mod.drainToMessage(&ch, io, gpa, null, null, null);
    defer msg.deinit(gpa);

    try testing.expectEqual(@as(usize, 1), msg.content.len);
    const tc = msg.content[0].tool_call;
    try testing.expectEqualStrings("toolu_1", tc.id);
    try testing.expectEqualStrings("read", tc.name);
    try testing.expectEqualStrings("{\"path\":\"/etc/hosts\"}", tc.arguments_json);
    try testing.expectEqual(types.StopReason.tool_use, msg.stop_reason.?);
}
