//! v2.31 — conversation compaction.
//!
//! When the agent-loop transcript grows past `Config.compact_after_messages`,
//! the older prefix is collapsed into a single `compaction_summary`
//! custom-role message. The last `Config.compact_protect_recent` messages
//! are preserved verbatim so the model keeps its immediate context. The
//! `defaultConvertToLlm` function in `loop.zig` already rewrites the
//! custom role into an ordinary `user` message with the prefix
//! "Earlier in this conversation:\n\n", so we just need to emit it.
//!
//! This file deliberately takes a dependency on `zompress` for the
//! compression of the historical blob. The `compress()` function
//! auto-detects content type and routes to the right compressor; the
//! output is then wrapped in a `compaction_summary` envelope with
//! header / footer that names the summary for the model.
//!
//! CCR (Compress-Cache-Retrieve) hooks land in Phase 3; for now the
//! `ccr_store` parameter is accepted but ignored — every code path
//! in this file leaves the store slot null.

const std = @import("std");
const ai = struct {
    pub const types = @import("../ai/types.zig");
    pub const stream = @import("../ai/stream.zig");
    pub const log = @import("../ai/log.zig");
};
const at = @import("types.zig");
const zompress = @import("zompress");

/// Compact the conversation history. Replaces `messages[0..compact_end]`
/// with a single `compaction_summary` custom-role message and returns
/// the new (shorter) slice. The last `protect_recent` messages are
/// preserved verbatim.
///
/// `ccr_store` is the Phase 3 hook point — for now it's accepted but
/// unused, so the function compiles without CCR wiring. When Phase 3
/// lands, the call site will pass a non-null `*CcrStore` and this
/// function will store the original blob there and append the CCR key
/// to the summary envelope.
///
/// Returns a fresh `[]AgentMessage` slice that the caller owns; the
/// caller is responsible for `deinit`-ing the messages when done
/// (matching `Transcript.replaceMessages`'s contract).
///
/// On error, returns the error. On "too small to compact" (the prefix
/// is < 3 messages), returns a fresh `dupe` of the input so the caller
/// can treat success / "no-op" uniformly.
pub fn compactConversation(
    allocator: std.mem.Allocator,
    messages: []const at.AgentMessage,
    protect_recent: u32,
    ccr_store: ?*zompress.ccr.CcrStore,
) ![]at.AgentMessage {
    const n = messages.len;
    const protect = @min(@as(usize, protect_recent), n);
    const compact_end = n - protect;

    // Spec §4.2: "Too small" — return a dupe of the input so the
    // caller can keep its existing flow uniform. The 3-message floor
    // is empirical: anything less and the "earlier conversation"
    // framing in the model-side prefix is misleading.
    //
    // Ownership: a shallow `dupe` of the input is NOT safe — both
    // the input and the returned slice would then own the same
    // `content` blocks, and the caller's `defer m.deinit(allocator)`
    // would double-free. We deep-dupe each message so the returned
    // slice is independent of the input.
    if (compact_end < 3) {
        var out_dup: std.ArrayList(at.AgentMessage) = .empty;
        errdefer {
            for (out_dup.items) |*m| m.deinit(allocator);
            out_dup.deinit(allocator);
        }
        try out_dup.appendSlice(allocator, messages[0..0]); // no-op; kept for clarity
        for (messages) |msg| {
            try out_dup.append(allocator, try dupeMessage(allocator, msg));
        }
        return out_dup.toOwnedSlice(allocator);
    }

    // 1. Concatenate the compactable prefix into a single blob, with
    // role tags so the compressed output keeps structural cues.
    var blob: std.ArrayList(u8) = .empty;
    defer blob.deinit(allocator);
    for (messages[0..compact_end]) |msg| {
        try blob.appendSlice(allocator, "=== ");
        try blob.appendSlice(allocator, @tagName(msg.role));
        try blob.appendSlice(allocator, " ===\n");
        for (msg.content) |cb| {
            switch (cb) {
                .text => |t| try blob.appendSlice(allocator, t.text),
                else => {},
            }
        }
        try blob.appendSlice(allocator, "\n\n");
    }

    // 2. Compress the blob. zompress's compress() auto-detects
    // content type — for a multi-message transcript it'll typically
    // land on plain_text (mixed roles, no clear single structure).
    // That's fine: the `min_tokens_to_compress = 100` gate is the
    // same one used for tool results, and the byte-length guardrail
    // in the loop ensures we never replace with bigger output.
    const zompress_cfg: zompress.CompressConfig = .{
        .min_tokens_to_compress = 100,
    };
    const result = zompress.compress(allocator, blob.items, zompress_cfg) catch |err| {
        ai.log.log(.warn, "compaction", "compress_failed", "err={s}", .{@errorName(err)});
        return err;
    };
    defer {
        allocator.free(result.compressed);
        allocator.free(result.transforms_applied);
        allocator.free(result.ccr_keys);
    }

    // 3. Optional CCR store. Phase 3 will populate this; for now
    // we keep the hook so the call site doesn't need to change when
    // CCR lands.
    var ccr_key: ?[]const u8 = null;
    if (ccr_store) |store| {
        ccr_key = store.store(blob.items) catch |err| blk: {
            ai.log.log(.warn, "compaction", "ccr_store_failed", "err={s}", .{@errorName(err)});
            break :blk null;
        };
    }

    // 4. Build the summary text. The spec format is:
    //   <header>
    //   <compressed body>
    //   <footer with stats>
    //   <optional CCR key>
    // The header sets the model-side context; the footer is
    // bookkeeping the model can ignore. We use the unmanaged
    // ArrayList API (allocator passed explicitly) and call `print`
    // directly rather than going through a `writer` interface —
    // matches the convention in `loop.zig` for the same reason.
    var summary_buf: std.ArrayList(u8) = .empty;
    defer summary_buf.deinit(allocator);
    try summary_buf.appendSlice(allocator, "The earlier part of this conversation has been compacted.\n\n");
    try summary_buf.appendSlice(allocator, result.compressed);
    try summary_buf.print(
        allocator,
        "\n\n({d} original messages compacted into this summary. {d} token reduction.)",
        .{ compact_end, result.tokens_saved },
    );
    if (ccr_key) |key| {
        try summary_buf.print(
            allocator,
            "\n[CCR key: {s} — use ccr_retrieve to get the full content]",
            .{key},
        );
    }
    const summary_text = try summary_buf.toOwnedSlice(allocator);
    errdefer allocator.free(summary_text);

    // 5. Build the result: [compaction_summary, ...protected_messages].
    // The protected messages are deep-copied so the caller owns the
    // entire returned slice independently of the input.
    var out: std.ArrayList(at.AgentMessage) = .empty;
    errdefer {
        for (out.items) |*m| m.deinit(allocator);
        out.deinit(allocator);
    }
    const summary_content = try allocator.alloc(ai.types.ContentBlock, 1);
    summary_content[0] = .{ .text = .{ .text = summary_text } };
    try out.append(allocator, .{
        .role = .custom,
        .custom_role = try allocator.dupe(u8, "compaction_summary"),
        .content = summary_content,
        .timestamp = ai.stream.nowMillis(),
    });
    for (messages[compact_end..]) |msg| {
        try out.append(allocator, try dupeMessage(allocator, msg));
    }
    return out.toOwnedSlice(allocator);
}

/// Deep-copy an `AgentMessage` onto `allocator`. Used by
/// `compactConversation` to duplicate the protected tail of the
/// transcript so the returned slice is independent of the input.
fn dupeMessage(allocator: std.mem.Allocator, msg: at.AgentMessage) !at.AgentMessage {
    const content = try allocator.alloc(ai.types.ContentBlock, msg.content.len);
    for (msg.content, 0..) |cb, i| {
        content[i] = try cb.dupe(allocator);
    }
    var out: at.AgentMessage = .{
        .role = msg.role,
        .content = content,
        .timestamp = msg.timestamp,
    };
    // Copy the optional string fields. Each `dupe` failure must
    // free the partial copy before propagating.
    errdefer out.deinit(allocator);
    if (msg.error_message) |s| out.error_message = try allocator.dupe(u8, s);
    if (msg.provider) |s| out.provider = try allocator.dupe(u8, s);
    if (msg.model) |s| out.model = try allocator.dupe(u8, s);
    if (msg.api) |s| out.api = try allocator.dupe(u8, s);
    if (msg.tool_call_id) |s| out.tool_call_id = try allocator.dupe(u8, s);
    if (msg.custom_role) |s| out.custom_role = try allocator.dupe(u8, s);
    if (msg.meta_json) |s| out.meta_json = try allocator.dupe(u8, s);
    return out;
}

test "compactConversation: too-small input returns a dupe" {
    const gpa = std.testing.allocator;
    var c0 = [_]ai.types.ContentBlock{.{ .text = .{ .text = "msg 0" } }};
    var c1 = [_]ai.types.ContentBlock{.{ .text = .{ .text = "msg 1" } }};
    const messages = [_]at.AgentMessage{
        .{ .role = .user, .content = &c0, .timestamp = 0 },
        .{ .role = .assistant, .content = &c1, .timestamp = 0 },
    };
    const out = try compactConversation(gpa, &messages, 8, null);
    defer {
        for (out) |*m| m.deinit(gpa);
        gpa.free(out);
    }
    try std.testing.expectEqual(@as(usize, 2), out.len);
}

test "compactConversation: 100 messages, protect_recent=8 → 1 summary + 8 messages" {
    // Spec §4.4 acceptance check: 100 messages, compact_after=50 →
    // messages[0..92] → 1 summary + messages[92..100].
    // We don't set compact_after here (that's the loop's job); we
    // call compactConversation directly with the same input shape.
    const gpa = std.testing.allocator;

    // Build 100 messages with stack-owned string literals (the test
    // doesn't own the content text — `compactConversation` deep-copies
    // its input into the output, so the input is read-only here).
    var blocks: [100]ai.types.ContentBlock = undefined;
    var messages: [100]at.AgentMessage = undefined;
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        // Stack-allocated 64-byte buffer holding "message NN with some text content".
        var txt_buf: [64]u8 = undefined;
        const txt = std.fmt.bufPrint(
            txt_buf[0..],
            "message {d} with some text content",
            .{i},
        ) catch unreachable;
        blocks[i] = .{ .text = .{ .text = txt } };
        messages[i] = .{
            .role = if (i % 2 == 0) .user else .assistant,
            .content = (&blocks[i])[0..1],
            .timestamp = @intCast(i),
        };
    }

    const out = try compactConversation(gpa, &messages, 8, null);
    defer {
        for (out) |*m| m.deinit(gpa);
        gpa.free(out);
    }

    // 1 summary + 8 protected = 9 messages.
    try std.testing.expectEqual(@as(usize, 9), out.len);
    // First message is the summary with the right custom role.
    try std.testing.expectEqual(ai.types.Role.custom, out[0].role);
    try std.testing.expect(out[0].custom_role != null);
    try std.testing.expectEqualStrings("compaction_summary", out[0].custom_role.?);
    // Last protected message is the last input message.
    try std.testing.expectEqual(messages[99].timestamp, out[8].timestamp);
}

test "compactConversation: protect_recent bounds to message count" {
    // protect_recent=20 but only 5 messages → protect clamps to 5 →
    // compact_end = 0 → "too small" path.
    const gpa = std.testing.allocator;
    var blocks: [5]ai.types.ContentBlock = undefined;
    var messages: [5]at.AgentMessage = undefined;
    for (blocks[0..5], 0..) |*cb, i| {
        cb.* = .{ .text = .{ .text = "x" } };
        messages[i] = .{ .role = .user, .content = (&cb.*)[0..1], .timestamp = @intCast(i) };
    }
    const out = try compactConversation(gpa, &messages, 20, null);
    defer {
        for (out) |*m| m.deinit(gpa);
        gpa.free(out);
    }
    // No compaction because compact_end == 0.
    try std.testing.expectEqual(@as(usize, 5), out.len);
}
