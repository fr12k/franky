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

/// Encode `ev` as a JSON payload — no SSE framing. Caller-owned.
pub fn encodeEventJson(allocator: std.mem.Allocator, ev: at.AgentEvent) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.append(allocator, '{');
    switch (ev) {
        .turn_start => try buf.appendSlice(allocator, "\"kind\":\"turn_start\""),
        .turn_end => try buf.appendSlice(allocator, "\"kind\":\"turn_end\""),
        .message_start => |s| {
            try buf.appendSlice(allocator, "\"kind\":\"message_start\",\"role\":");
            try appendJsonStr(&buf, allocator, roleName(s.role));
            if (s.custom_role) |cr| {
                try buf.appendSlice(allocator, ",\"customRole\":");
                try appendJsonStr(&buf, allocator, cr);
            }
        },
        .message_update => |m| switch (m) {
            .text => |t| {
                try buf.appendSlice(allocator, "\"kind\":\"message_update\",\"deltaKind\":\"text\",\"blockIndex\":");
                try appendJsonInt(&buf, allocator, @intCast(t.block_index));
                try buf.appendSlice(allocator, ",\"delta\":");
                try appendJsonStr(&buf, allocator, t.delta);
            },
            .thinking => |t| {
                try buf.appendSlice(allocator, "\"kind\":\"message_update\",\"deltaKind\":\"thinking\",\"blockIndex\":");
                try appendJsonInt(&buf, allocator, @intCast(t.block_index));
                try buf.appendSlice(allocator, ",\"delta\":");
                try appendJsonStr(&buf, allocator, t.delta);
            },
            .toolcall_args => |t| {
                try buf.appendSlice(allocator, "\"kind\":\"message_update\",\"deltaKind\":\"toolcall_args\",\"blockIndex\":");
                try appendJsonInt(&buf, allocator, @intCast(t.block_index));
                try buf.appendSlice(allocator, ",\"delta\":");
                try appendJsonStr(&buf, allocator, t.delta);
            },
        },
        .message_end => |m| {
            try buf.appendSlice(allocator, "\"kind\":\"message_end\",\"role\":");
            try appendJsonStr(&buf, allocator, roleName(m.role));
            try buf.appendSlice(allocator, ",\"contentBlocks\":");
            try appendJsonInt(&buf, allocator, @intCast(m.content.len));
        },
        .tool_execution_start => |s| {
            try buf.appendSlice(allocator, "\"kind\":\"tool_execution_start\",\"callId\":");
            try appendJsonStr(&buf, allocator, s.call_id);
            try buf.appendSlice(allocator, ",\"name\":");
            try appendJsonStr(&buf, allocator, s.name);
            try buf.appendSlice(allocator, ",\"argsJson\":");
            try appendJsonStr(&buf, allocator, s.args_json);
        },
        .tool_execution_update => |u| {
            try buf.appendSlice(allocator, "\"kind\":\"tool_execution_update\",\"callId\":");
            try appendJsonStr(&buf, allocator, u.call_id);
            try buf.appendSlice(allocator, ",\"update\":");
            try buf.appendSlice(allocator, u.update_json);
        },
        .tool_execution_end => |e| {
            try buf.appendSlice(allocator, "\"kind\":\"tool_execution_end\",\"callId\":");
            try appendJsonStr(&buf, allocator, e.call_id);
            try buf.appendSlice(allocator, ",\"isError\":");
            try buf.appendSlice(allocator, if (e.result.is_error) "true" else "false");
            if (e.result.tool_code) |code| {
                try buf.appendSlice(allocator, ",\"toolCode\":");
                try appendJsonStr(&buf, allocator, code);
            }
            // Concatenate all text content blocks into resultText so the
            // web UI can display the tool output in a collapsible panel.
            try buf.appendSlice(allocator, ",\"resultText\":");
            var combined: std.ArrayListUnmanaged(u8) = .empty;
            defer combined.deinit(allocator);
            for (e.result.content) |cb| {
                if (cb == .text) try combined.appendSlice(allocator, cb.text.text);
            }
            try appendJsonStr(&buf, allocator, combined.items);
            // §6.8 — include details_json as opaque metadata for the front-end
            // (e.g. unified diff for the edit tool). The value is already valid
            // JSON, so we append it directly without re-encoding.
            if (e.result.details_json) |dj| {
                try buf.appendSlice(allocator, ",\"detailsJson\":");
                try buf.appendSlice(allocator, dj);
            }
        },
        .tool_permission_request => |r| {
            try buf.appendSlice(allocator, "\"kind\":\"tool_permission_request\",\"callId\":");
            try appendJsonStr(&buf, allocator, r.call_id);
            try buf.appendSlice(allocator, ",\"toolName\":");
            try appendJsonStr(&buf, allocator, r.tool_name);
            try buf.appendSlice(allocator, ",\"argsJson\":");
            try appendJsonStr(&buf, allocator, r.args_json);
            try buf.appendSlice(allocator, ",\"fingerprint\":");
            try appendJsonStr(&buf, allocator, r.fingerprint);
        },
        .agent_error => |d| {
            try buf.appendSlice(allocator, "\"kind\":\"agent_error\",\"code\":");
            try appendJsonStr(&buf, allocator, d.code.toString());
            try buf.appendSlice(allocator, ",\"message\":");
            try appendJsonStr(&buf, allocator, d.message);
            if (!d.is_fatal) {
                try buf.appendSlice(allocator, ",\"isFatal\":false");
            }
            if (d.http_status) |s| {
                try buf.appendSlice(allocator, ",\"httpStatus\":");
                try appendJsonInt(&buf, allocator, @intCast(s));
            }
        },
        .agent_interrupted => {
            try buf.appendSlice(allocator, "\"kind\":\"agent_interrupted\"");
        },
        .provider_retry => |r| {
            try buf.appendSlice(allocator, "\"kind\":\"provider_retry\",\"attempt\":");
            try appendJsonInt(&buf, allocator, @intCast(r.attempt));
            try buf.appendSlice(allocator, ",\"max_attempts\":");
            try appendJsonInt(&buf, allocator, @intCast(r.max_attempts));
            try buf.appendSlice(allocator, ",\"delay_ms\":");
            try appendJsonInt(&buf, allocator, @intCast(r.delay_ms));
            try buf.appendSlice(allocator, ",\"reason\":");
            try appendJsonStr(&buf, allocator, @tagName(r.reason));
            if (r.http_status) |s| {
                try buf.appendSlice(allocator, ",\"http_status\":");
                try appendJsonInt(&buf, allocator, @intCast(s));
            }
            if (r.provider_code) |pc| {
                try buf.appendSlice(allocator, ",\"provider_code\":");
                try appendJsonStr(&buf, allocator, pc);
            }
            if (r.provider_message) |pm| {
                try buf.appendSlice(allocator, ",\"provider_message\":");
                try appendJsonStr(&buf, allocator, pm);
            }
        },
    }
    try buf.append(allocator, '}');
    return try buf.toOwnedSlice(allocator);
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

/// Encode `ev` as an HTML fragment (for hx-sse OOB swaps) or a JSON
/// payload (for named lifecycle events handled via `hx-on`). Returns
/// the fragment body (without SSE framing); the caller wraps it in
/// `data: ...\n\n` (unnamed, OOB) or `event: kind\ndata: ...\n\n`
/// (named, lifecycle). See `sse.renderFrameHtml`.
///
/// Strategy (Phase 1, Option B):
///   - Lifecycle events (turn_start/end, agent_error/interrupted,
///     provider_retry, ping) stay JSON named events (small payloads,
///     handled by `hx-on` on the client).
///   - Content events (message_start/end, tool_execution_*,
///     tool_permission_request, thinking/toolcall deltas) become
///     HTML fragments with `hx-swap-oob` targeting stable element IDs.
///   - Text deltas (`message_update` .text) stay JSON named events —
///     the client-side markdown renderer accumulates and re-renders
///     (Option B; Phase 2 may move this server-side).
pub fn encodeEventHtml(allocator: std.mem.Allocator, ev: at.AgentEvent) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    switch (ev) {
        // ── Lifecycle: named JSON events (client handles via hx-on) ──
        .turn_start, .turn_end, .agent_interrupted => {
            // These carry no payload; the event name is enough.
            try buf.appendSlice(allocator, "{}");
        },
        .agent_error => |d| {
            // Keep JSON so the client can read code/message/isFatal.
            try buf.appendSlice(allocator, "{\"code\":");
            try appendJsonStr(&buf, allocator, d.code.toString());
            try buf.appendSlice(allocator, ",\"message\":");
            try appendJsonStr(&buf, allocator, d.message);
            if (!d.is_fatal) try buf.appendSlice(allocator, ",\"isFatal\":false");
            try buf.appendSlice(allocator, "}");
        },
        .provider_retry => |r| {
            try buf.appendSlice(allocator, "{\"attempt\":");
            try appendJsonInt(&buf, allocator, @intCast(r.attempt));
            try buf.appendSlice(allocator, ",\"reason\":");
            try appendJsonStr(&buf, allocator, @tagName(r.reason));
            try buf.appendSlice(allocator, "}");
        },

        // ── Text deltas: named JSON (client-side markdown render, Option B) ──
        .message_update => |m| switch (m) {
            .text => |t| {
                try buf.appendSlice(allocator, "{\"deltaKind\":\"text\",\"blockIndex\":");
                try appendJsonInt(&buf, allocator, @intCast(t.block_index));
                try buf.appendSlice(allocator, ",\"delta\":");
                try appendJsonStr(&buf, allocator, t.delta);
                try buf.appendSlice(allocator, "}");
            },
            // thinking + toolcall_args: OOB HTML append into the block.
            .thinking => |t| {
                try buf.appendSlice(allocator, "<div id=\"thinking-");
                try appendJsonInt(&buf, allocator, @intCast(t.block_index));
                try buf.appendSlice(allocator, "\" hx-swap-oob=\"beforeend\" class=\"thinking-delta\">");
                try appendHtmlEsc(&buf, allocator, t.delta);
                try buf.appendSlice(allocator, "</div>");
            },
            .toolcall_args => |t| {
                try buf.appendSlice(allocator, "<span id=\"toolcall-args-");
                try appendJsonInt(&buf, allocator, @intCast(t.block_index));
                try buf.appendSlice(allocator, "\" hx-swap-oob=\"beforeend\" class=\"toolcall-args-delta\">");
                try appendHtmlEsc(&buf, allocator, t.delta);
                try buf.appendSlice(allocator, "</span>");
            },
        },

        // ── Content: OOB HTML fragments ──
        .message_start => |s| {
            // Open the assistant message container.
            try buf.appendSlice(allocator, "<div class=\"msg msg-");
            try appendHtmlEsc(&buf, allocator, roleName(s.role));
            try buf.appendSlice(allocator, "\"></div>");
        },
        .message_end => {
            // Finalize the message container.
            try buf.appendSlice(allocator, "</div><!-- msg-end -->");
        },
        .tool_execution_start => |s| {
            try buf.appendSlice(allocator, "<div class=\"tool-card\" id=\"tool-");
            try appendHtmlEsc(&buf, allocator, s.call_id);
            try buf.appendSlice(allocator, "\"><div class=\"tool-head\"><span class=\"tool-name\">");
            try appendHtmlEsc(&buf, allocator, s.name);
            try buf.appendSlice(allocator, "</span></div><div class=\"tool-args\"><code>");
            try appendHtmlEsc(&buf, allocator, s.args_json);
            try buf.appendSlice(allocator, "</code></div></div>");
        },
        .tool_execution_update => |u| {
            // Append to the sub-agent log inside the tool card.
            try buf.appendSlice(allocator, "<div id=\"subagent-log-");
            try appendHtmlEsc(&buf, allocator, u.call_id);
            try buf.appendSlice(allocator, "\" hx-swap-oob=\"beforeend\" class=\"subagent-entry\">");
            try appendHtmlEsc(&buf, allocator, u.update_json);
            try buf.appendSlice(allocator, "</div>");
        },
        .tool_execution_end => |e| {
            // Re-render the full tool card with the result.
            try buf.appendSlice(allocator, "<div class=\"tool-card");
            if (e.result.is_error) try buf.appendSlice(allocator, " tool-card-error");
            try buf.appendSlice(allocator, "\" id=\"tool-");
            try appendHtmlEsc(&buf, allocator, e.call_id);
            try buf.appendSlice(allocator, "\"><div class=\"tool-head\"><span class=\"tool-name\">");
            // Tool name not carried in tool_execution_end; omit.
            try buf.appendSlice(allocator, "</span></div><div class=\"tool-result\"><pre>");
            var combined: std.ArrayListUnmanaged(u8) = .empty;
            defer combined.deinit(allocator);
            for (e.result.content) |cb| {
                if (cb == .text) try combined.appendSlice(allocator, cb.text.text);
            }
            try appendHtmlEsc(&buf, allocator, combined.items);
            try buf.appendSlice(allocator, "</pre></div></div>");
        },
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
    }
    return try buf.toOwnedSlice(allocator);
}

/// Whether `ev` should be sent as a named SSE event (JSON payload,
/// client handles via `hx-on`) vs an unnamed event (HTML fragment,
/// htmx processes OOB swaps). Lifecycle + text-delta events are
/// named; content events are unnamed.
pub fn isNamedHtmlEvent(ev: at.AgentEvent) bool {
    return switch (ev) {
        .turn_start,
        .turn_end,
        .agent_interrupted,
        .agent_error,
        .provider_retry,
        .message_update, // text deltas stay JSON (Option B)
        => true,
        .message_start,
        .message_end,
        .tool_execution_start,
        .tool_execution_end,
        .tool_execution_update,
        .tool_permission_request,
        => false,
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

fn appendJsonStr(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try buf.append(allocator, '"');
    for (s) |c| switch (c) {
        '"' => try buf.appendSlice(allocator, "\\\""),
        '\\' => try buf.appendSlice(allocator, "\\\\"),
        '\n' => try buf.appendSlice(allocator, "\\n"),
        '\r' => try buf.appendSlice(allocator, "\\r"),
        '\t' => try buf.appendSlice(allocator, "\\t"),
        0...0x07, 0x08, 0x0b, 0x0c, 0x0e...0x1f => {
            var tmp: [8]u8 = undefined;
            const w = std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{c}) catch unreachable;
            try buf.appendSlice(allocator, w);
        },
        else => try buf.append(allocator, c),
    };
    try buf.append(allocator, '"');
}

fn appendJsonInt(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, n: i64) !void {
    var tmp: [20]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{n}) catch unreachable;
    try buf.appendSlice(allocator, s);
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