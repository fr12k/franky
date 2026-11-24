//! Wire-format serialization for `AgentEvent` — §4.7.
//!
//! Pure function that encodes an `AgentEvent` as a JSON payload.
//! Transport-agnostic: no SSE framing, no HTTP, no `std.Io.net`.
//! Callers add framing (SSE, LSP Content-Length, etc.) in their
//! own modules.
//!
//! Previously this lived in `agent/proxy.zig` alongside the HTTP
//! server code. `coding/sse.zig` and `coding/modes/rpc.zig` needed
//! the serializer but not the server, so they pulled the entire
//! proxy module into their dependency graph. Moving the pure
//! serialization to `agent/wire.zig` (a contract module) lets
//! consumers import just the encoding without the HTTP runtime.

const std = @import("std");
const at = @import("types.zig");
const ai_types = @import("../ai/types.zig");
const ai_errors = @import("../ai/errors.zig");
const ai_utils = @import("../ai/utils.zig");

/// Encode `ev` as a JSON payload — no SSE framing. Caller-owned.
///
/// Every variant's payload is a clean struct, so it serialises via
/// `std.json.Stringify.valueAlloc` over a per-variant payload struct; the
/// emitted object's braces are stripped and spliced into the `"kind"`
/// wrapper (`appendPayloadFields`). Two variants splice **raw JSON** that
/// `std.json` would re-encode as an escaped string — the sub-agent
/// `update` payload and the front-end `detailsJson` metadata — so their
/// raw fragment is appended verbatim after the struct fields.
pub fn encodeEventJson(allocator: std.mem.Allocator, ev: at.AgentEvent) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.append(allocator, '{');
    switch (ev) {
        .turn_start => try buf.appendSlice(allocator, "\"kind\":\"turn_start\""),
        .turn_end => try buf.appendSlice(allocator, "\"kind\":\"turn_end\""),
        .agent_interrupted => try buf.appendSlice(allocator, "\"kind\":\"agent_interrupted\""),
        .message_start => |s| {
            try buf.appendSlice(allocator, "\"kind\":\"message_start\"");
            try appendPayloadFields(allocator, &buf, .{
                .role = roleName(s.role),
                .customRole = s.custom_role,
            });
        },
        .message_update => |m| switch (m) {
            inline .text, .thinking, .toolcall_args => |t, k| {
                try buf.appendSlice(allocator, "\"kind\":\"message_update\"");
                try appendPayloadFields(allocator, &buf, .{
                    .deltaKind = @tagName(k),
                    .blockIndex = t.block_index,
                    .delta = t.delta,
                });
            },
        },
        .message_end => |m| {
            try buf.appendSlice(allocator, "\"kind\":\"message_end\"");
            try appendPayloadFields(allocator, &buf, .{
                .role = roleName(m.role),
                .contentBlocks = m.content.len,
            });
        },
        .tool_execution_start => |s| {
            try buf.appendSlice(allocator, "\"kind\":\"tool_execution_start\"");
            try appendPayloadFields(allocator, &buf, .{
                .callId = s.call_id,
                .name = s.name,
                .argsJson = s.args_json,
            });
        },
        .tool_execution_update => |u| {
            try buf.appendSlice(allocator, "\"kind\":\"tool_execution_update\"");
            try appendPayloadFields(allocator, &buf, .{ .callId = u.call_id });
            // `update` is already-serialised JSON (the sub-agent's progress
            // payload); append verbatim so it isn't re-escaped as a string.
            try buf.appendSlice(allocator, ",\"update\":");
            try buf.appendSlice(allocator, u.update_json);
        },
        .tool_execution_end => |e| {
            try buf.appendSlice(allocator, "\"kind\":\"tool_execution_end\"");
            // Concatenate all text content blocks into resultText so the
            // web UI can display the tool output in a collapsible panel.
            var combined: std.ArrayListUnmanaged(u8) = .empty;
            defer combined.deinit(allocator);
            for (e.result.content) |cb| {
                if (cb == .text) try combined.appendSlice(allocator, cb.text.text);
            }
            try appendPayloadFields(allocator, &buf, .{
                .callId = e.call_id,
                .isError = e.result.is_error,
                .toolCode = e.result.tool_code,
                .resultText = combined.items,
            });
            // §6.8 — `details_json` is already-serialised JSON (e.g. the
            // unified diff for the edit tool); append verbatim.
            if (e.result.details_json) |dj| {
                try buf.appendSlice(allocator, ",\"detailsJson\":");
                try buf.appendSlice(allocator, dj);
            }
        },
        .tool_permission_request => |r| {
            try buf.appendSlice(allocator, "\"kind\":\"tool_permission_request\"");
            try appendPayloadFields(allocator, &buf, .{
                .callId = r.call_id,
                .toolName = r.tool_name,
                .argsJson = r.args_json,
                .fingerprint = r.fingerprint,
            });
        },
        .agent_error => |d| {
            try buf.appendSlice(allocator, "\"kind\":\"agent_error\"");
            try appendPayloadFields(allocator, &buf, .{
                .code = d.code.toString(),
                .message = d.message,
                // Emitted only when false, to match the prior wire shape.
                .isFatal = if (d.is_fatal) null else false,
                .httpStatus = d.http_status,
            });
        },
        .provider_retry => |r| {
            try buf.appendSlice(allocator, "\"kind\":\"provider_retry\"");
            try appendPayloadFields(allocator, &buf, .{
                .attempt = r.attempt,
                .max_attempts = r.max_attempts,
                .delay_ms = r.delay_ms,
                .reason = @tagName(r.reason),
                .http_status = r.http_status,
                .provider_code = r.provider_code,
                .provider_message = r.provider_message,
            });
        },
    }
    try buf.append(allocator, '}');
    return try buf.toOwnedSlice(allocator);
}

/// Serialise `payload` (a struct of wire fields) via
/// `std.json.Stringify.valueAlloc`, strip the outer braces, and append the
/// fields into `buf` (with a leading comma). With
/// `.emit_null_optional_fields = false`, null optional fields are omitted.
/// An empty payload struct appends nothing.
fn appendPayloadFields(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), payload: anytype) !void {
    const pj = try std.json.Stringify.valueAlloc(allocator, payload, .{
        .emit_null_optional_fields = false,
    });
    defer allocator.free(pj);
    if (pj.len > 2) {
        try buf.append(allocator, ',');
        try buf.appendSlice(allocator, pj[1 .. pj.len - 1]);
    }
}

/// HTML-escape `s` into `buf`. Replaces the browser-side `escapeHtml`
/// for all server-rendered fragments. Escapes &, <, >, ", '.
fn appendHtmlEsc(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| switch (c) {
        '&' => try buf.appendSlice(allocator, "&amp;"),
        '<' => try buf.appendSlice(allocator, "&lt;"),
        '>' => try buf.appendSlice(allocator, "&gt;"),
        '"' => try buf.appendSlice(allocator, "&quot;"),
        '\'' => try buf.appendSlice(allocator, "&#39;"),
        else => try buf.append(allocator, c),
    };
}

/// Encode `ev` for the htmx SSE path. Named events delegate to
/// `encodeEventJson` so JS handlers receive the same payload they
/// expect. Unnamed events produce OOB HTML fragments that htmx
/// swaps automatically. See `sse.renderFrameHtml` for SSE framing.
pub fn encodeEventHtml(allocator: std.mem.Allocator, ev: at.AgentEvent) ![]u8 {
    // Named events produce the same JSON payload as encodeEventJson.
    // JS handlers parse `event.detail.data` for the same fields.
    if (isNamedHtmlEvent(ev)) {
        return encodeEventJson(allocator, ev);
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    switch (ev) {
        // ── OOB HTML: thinking/toolcall_args deltas ────────────────
        .message_update => |m| switch (m) {
            .text => unreachable, // named, handled by guard above
            .thinking => |t| {
                try buf.appendSlice(allocator, "<div id=\"thinking-");
                try ai_utils.appendJsonInt(&buf, allocator, @intCast(t.block_index));
                try buf.appendSlice(allocator, "\" hx-swap-oob=\"beforeend\" class=\"thinking-delta\">");
                try appendHtmlEsc(&buf, allocator, t.delta);
                try buf.appendSlice(allocator, "</div>");
            },
            .toolcall_args => |t| {
                try buf.appendSlice(allocator, "<span id=\"toolcall-args-");
                try ai_utils.appendJsonInt(&buf, allocator, @intCast(t.block_index));
                try buf.appendSlice(allocator, "\" hx-swap-oob=\"beforeend\" class=\"toolcall-args-delta\">");
                try appendHtmlEsc(&buf, allocator, t.delta);
                try buf.appendSlice(allocator, "</span>");
            },
        },

        // ── OOB HTML: permission modal ────────────────────────────
        .tool_permission_request => |r| {
            try buf.appendSlice(allocator, "<div id=\"permission-modal\" hx-swap-oob=\"true\" class=\"permission-modal\">");
            try buf.appendSlice(allocator, "<div class=\"permission-card\"><h3>Permission required</h3>");
            try buf.appendSlice(allocator, "<p>Tool: <code>");
            try appendHtmlEsc(&buf, allocator, r.tool_name);
            try buf.appendSlice(allocator, "</code></p><p>Args: <code>");
            try appendHtmlEsc(&buf, allocator, r.args_json);
            try buf.appendSlice(allocator, "</code></p>");
            try buf.appendSlice(allocator, "<form hx-post=\"/permission/resolve\" hx-target=\"#permission-modal\" hx-swap=\"outerHTML\">");
            try buf.appendSlice(allocator, "<input type=\"hidden\" name=\"callId\" value=\"");
            try appendHtmlEsc(&buf, allocator, r.call_id);
            try buf.appendSlice(allocator, "\" />");
            try buf.appendSlice(allocator, "<button type=\"submit\" name=\"decision\" value=\"allow\">Allow</button>");
            try buf.appendSlice(allocator, "<button type=\"submit\" name=\"decision\" value=\"deny\">Deny</button>");
            try buf.appendSlice(allocator, "</form></div></div>");
        },

        // All named events are handled by isNamedHtmlEvent guard above.
        .turn_start, .turn_end, .agent_interrupted, .agent_error,
        .provider_retry, .message_start, .message_end,
        .tool_execution_start, .tool_execution_end, .tool_execution_update => unreachable,
    }
    return try buf.toOwnedSlice(allocator);
}

/// Whether `ev` should be sent as a named SSE event (JSON payload,
/// client handles via `hx-on`) vs an unnamed event (HTML fragment,
/// htmx processes OOB swaps). Named events are those that need JS
/// state management (tool cards, subagent panel, active message);
/// unnamed events are server-rendered HTML swapped by htmx.
pub fn isNamedHtmlEvent(ev: at.AgentEvent) bool {
    // ── Named: lifecycle + text deltas (JS-driven) ────────────────
    return switch (ev) {
        .turn_start,
        .turn_end,
        .agent_interrupted,
        .agent_error,
        .provider_retry,
        .message_start,
        .message_end,
        .tool_execution_start,
        .tool_execution_end,
        .tool_execution_update,
        => true,
        // Text deltas stay JSON (Option B — client-side markdown render).
        .message_update => |m| switch (m) {
            .text => true,
            .thinking => false,
            .toolcall_args => false,
        },
        // ── Unnamed: OOB HTML (htmx auto-swap) ────────────────────
        .tool_permission_request => false,
    };
}

fn roleName(r: ai_types.Role) []const u8 {
    return switch (r) {
        .user => "user",
        .assistant => "assistant",
        .tool_result => "tool_result",
        .custom => "custom",
    };
}

// ─── tests ────────────────────────────────────────────────────────

const testing = std.testing;

test "encodeEventJson: turn_start" {
    const gpa = testing.allocator;
    const json = try encodeEventJson(gpa, .turn_start);
    defer gpa.free(json);
    try testing.expectEqualStrings("{\"kind\":\"turn_start\"}", json);
}

test "encodeEventJson: message_start carries role" {
    const gpa = testing.allocator;
    const json = try encodeEventJson(gpa, .{ .message_start = .{ .role = .assistant } });
    defer gpa.free(json);
    try testing.expectEqualStrings("{\"kind\":\"message_start\",\"role\":\"assistant\"}", json);
}

test "encodeEventJson: text delta preserves block_index + delta text" {
    const gpa = testing.allocator;
    const json = try encodeEventJson(gpa, .{ .message_update = .{ .text = .{
        .block_index = 3,
        .delta = "hello world",
    } } });
    defer gpa.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"deltaKind\":\"text\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"blockIndex\":3") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"delta\":\"hello world\"") != null);
}

test "encodeEventJson: tool_execution_start + end" {
    const gpa = testing.allocator;
    const start_json = try encodeEventJson(gpa, .{ .tool_execution_start = .{
        .call_id = "c-7",
        .name = "read",
        .args_json = "{\"path\":\"src/foo.zig\"}",
    } });
    defer gpa.free(start_json);
    try testing.expect(std.mem.indexOf(u8, start_json, "\"callId\":\"c-7\"") != null);
    try testing.expect(std.mem.indexOf(u8, start_json, "\"name\":\"read\"") != null);
}

test "encodeEventJson: agent_error carries code + message + status" {
    const gpa = testing.allocator;
    const json = try encodeEventJson(gpa, .{ .agent_error = .{
        .code = .rate_limited_hard,
        .message = "quota exceeded",
        .http_status = 429,
    } });
    defer gpa.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"code\":\"rate_limited_hard\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"httpStatus\":429") != null);
    // Fatal errors (default) must NOT emit isFatal — omission means true.
    try testing.expect(std.mem.indexOf(u8, json, "isFatal") == null);
}

test "encodeEventJson: agent_error omits isFatal when true, includes false when non-fatal" {
    const gpa = testing.allocator;
    const json = try encodeEventJson(gpa, .{ .agent_error = .{
        .code = .compilation_failed,
        .message = "build error",
        .is_fatal = false,
    } });
    defer gpa.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"isFatal\":false") != null);
}

test "encodeEventJson: json escaping handles quotes and newlines" {
    const gpa = testing.allocator;
    const json = try encodeEventJson(gpa, .{ .message_update = .{ .text = .{
        .block_index = 0,
        .delta = "he said \"hi\"\nlater",
    } } });
    defer gpa.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\\\"hi\\\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\\n") != null);
}
// ─── encodeEventHtml + isNamedHtmlEvent tests ─────────────────────

test "encodeEventHtml: turn_start delegates to encodeEventJson" {
    const gpa = testing.allocator;
    const html = try encodeEventHtml(gpa, .turn_start);
    defer gpa.free(html);
    try testing.expect(std.mem.indexOf(u8, html, "\"kind\":\"turn_start\"") != null);
}

test "encodeEventHtml: message_update text stays JSON (Option B)" {
    const gpa = testing.allocator;
    const html = try encodeEventHtml(gpa, .{ .message_update = .{ .text = .{
        .block_index = 2,
        .delta = "hello",
    } } });
    defer gpa.free(html);
    try testing.expect(std.mem.indexOf(u8, html, "\"deltaKind\":\"text\"") != null);
    try testing.expect(std.mem.indexOf(u8, html, "\"delta\":\"hello\"") != null);
    try testing.expect(std.mem.indexOf(u8, html, "<") == null); // no HTML
}

test "encodeEventHtml: thinking delta is OOB HTML fragment" {
    const gpa = testing.allocator;
    const html = try encodeEventHtml(gpa, .{ .message_update = .{ .thinking = .{
        .block_index = 1,
        .delta = "reasoning here",
    } } });
    defer gpa.free(html);
    try testing.expect(std.mem.indexOf(u8, html, "id=\"thinking-1\"") != null);
    try testing.expect(std.mem.indexOf(u8, html, "hx-swap-oob=\"beforeend\"") != null);
    try testing.expect(std.mem.indexOf(u8, html, "reasoning here") != null);
}

test "encodeEventHtml: tool_execution_start delegates to encodeEventJson" {
    const gpa = testing.allocator;
    const html = try encodeEventHtml(gpa, .{ .tool_execution_start = .{
        .call_id = "c-1",
        .name = "read",
        .args_json = "{\"path\":\"foo.zig\"}",
    } });
    defer gpa.free(html);
    try testing.expect(std.mem.indexOf(u8, html, "\"callId\":\"c-1\"") != null);
    try testing.expect(std.mem.indexOf(u8, html, "\"name\":\"read\"") != null);
}

test "encodeEventHtml: tool_execution_end delegates to encodeEventJson" {
    const gpa = testing.allocator;
    const html = try encodeEventHtml(gpa, .{ .tool_execution_end = .{
        .call_id = "c-1",
        .result = .{
            .is_error = false,
            .content = &.{},
            .tool_code = null,
            .details_json = null,
        },
    } });
    defer gpa.free(html);
    try testing.expect(std.mem.indexOf(u8, html, "\"callId\":\"c-1\"") != null);
    try testing.expect(std.mem.indexOf(u8, html, "\"isError\":false") != null);
}

test "encodeEventHtml: html escaping handles <, >, & in OOB permission modal" {
    const gpa = testing.allocator;
    const html = try encodeEventHtml(gpa, .{ .tool_permission_request = .{
        .call_id = "c-2",
        .tool_name = "edit",
        .args_json = "<script>alert(1)</script>",
        .fingerprint = "fp",
    } });
    defer gpa.free(html);
    try testing.expect(std.mem.indexOf(u8, html, "&lt;script&gt;") != null);
    try testing.expect(std.mem.indexOf(u8, html, "<script>") == null);
}

test "isNamedHtmlEvent: text is named, thinking/toolcall are unnamed" {
    try testing.expect(isNamedHtmlEvent(.turn_start));
    try testing.expect(isNamedHtmlEvent(.turn_end));
    try testing.expect(isNamedHtmlEvent(.agent_interrupted));
    try testing.expect(isNamedHtmlEvent(.{ .agent_error = .{
        .code = .compilation_failed,
        .message = "err",
    } }));
    try testing.expect(isNamedHtmlEvent(.{ .message_update = .{ .text = .{
        .block_index = 0,
        .delta = "x",
    } } }));
    // thinking + toolcall_args are OOB HTML (unnamed).
    try testing.expect(!isNamedHtmlEvent(.{ .message_update = .{ .thinking = .{
        .block_index = 0,
        .delta = "x",
    } } }));
    try testing.expect(!isNamedHtmlEvent(.{ .message_update = .{ .toolcall_args = .{
        .block_index = 0,
        .delta = "x",
    } } }));
    // tool_execution_start/end and tool_execution_update are named.
    try testing.expect(isNamedHtmlEvent(.{ .tool_execution_start = .{
        .call_id = "c",
        .name = "read",
        .args_json = "{}",
    } }));
    try testing.expect(isNamedHtmlEvent(.{ .tool_execution_end = .{
        .call_id = "c",
        .result = .{ .is_error = false, .content = &.{}, .tool_code = null, .details_json = null },
    } }));
    // tool_execution_update is named JSON (subagent panel state).
    try testing.expect(isNamedHtmlEvent(.{ .tool_execution_update = .{
        .call_id = "c",
        .update_json = "{}",
    } }));
}
