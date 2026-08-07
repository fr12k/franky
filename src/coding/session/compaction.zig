//! Compaction algorithm — §E of the spec.
//!
//! Pure-logic primitives:
//!
//!   - `estimateTokens(bytes, kind)` — §E.1 token-count heuristic.
//!   - `shouldTrigger(estimate, model_window)` — returns `.none`,
//!     `.soft` (≥ 80 %), or `.hard` (≥ 92 %).
//!   - `selectSpan(messages, context_window)` — returns the span
//!     to compact per §E.2 (anchor, preserve first user, preserve
//!     tail-budget, preserve pinned, orphan-tool-pair avoidance).
//!
//! End-to-end dispatch (v1.5.1):
//!
//!   - `run(allocator, io, transcript, tree, config)` — the
//!     full §E.3 + §E.4 round-trip: forks a `pre-compact-<ts>`
//!     branch in `tree`, renders the span into a summarization
//!     prompt, calls the registered provider, and replaces the
//!     span in `transcript` with a synthetic `compaction_summary`
//!     custom-role message.
//!   - `renderSpanAsPrompt` — §E.3 user-message body builder.
//!   - `summarizer_system_prompt` — §E.3 system-prompt constant.
//!
//! §E.4 bullet 3 is honored by `agent.loop.defaultConvertToLlm`:
//! when it encounters a `custom_role = "compaction_summary"`
//! message, it emits a `user` message prefixed with
//! `"Earlier in this conversation:\n\n"`.

const std = @import("std");
const branching = @import("branching.zig");
const at = @import("../../agent/types.zig");
// Transcript / AgentMessage contract types now live in
// agent/types.zig (the contract module). Previously this file
// imported agent/loop.zig (the 2800-line runtime) just to reach
// these re-exported types — a leaking abstraction that pulled
// the entire loop implementation into the session module.
const types = @import("../../ai/types.zig");
const registry_mod = @import("../../ai/registry.zig");
const stream_mod = @import("../../ai/stream.zig");
const channel_mod = @import("../../ai/channel.zig");

pub const TokenKind = enum { english, code };

/// §E.1 heuristic: token ≈ ceil(utf8_bytes / 3.5) for text,
/// ceil(utf8_bytes / 2) for code-heavy content. Callers with a
/// real tokenizer should use it instead.
pub fn estimateTokens(bytes: []const u8, kind: TokenKind) u32 {
    return estimateFromLen(bytes.len, kind);
}

pub fn estimateFromLen(byte_len: usize, kind: TokenKind) u32 {
    const denom_num: u32 = switch (kind) {
        .english => 7, // 7/2 = 3.5
        .code => 2,
    };
    const denom_den: u32 = switch (kind) {
        .english => 2,
        .code => 1,
    };
    const total: u64 = @as(u64, byte_len) * denom_den;
    const denom_u64: u64 = denom_num;
    const quot = total / denom_u64;
    const rem = total % denom_u64;
    const result: u64 = if (rem == 0) quot else quot + 1;
    return @intCast(@min(result, @as(u64, std.math.maxInt(u32))));
}

pub const Trigger = enum { none, soft, hard };

pub fn shouldTrigger(estimated_tokens: u32, model_window: u32) Trigger {
    if (model_window == 0) return .none;
    // Compute percent * 100 without float math.
    const ratio_x100: u64 = (@as(u64, estimated_tokens) * 100) / @as(u64, model_window);
    if (ratio_x100 >= 92) return .hard;
    if (ratio_x100 >= 80) return .soft;
    return .none;
}

pub const SpanDecision = struct {
    /// Inclusive-exclusive range of messages that will be
    /// compacted. Empty when compaction is not worthwhile.
    compactable_start: u32,
    compactable_end: u32,
    /// When true, compaction should proceed; when false the caller
    /// aborts (fewer than 4 contiguous messages survived the
    /// preservation rules).
    proceed: bool,
    /// The anchor: index of the most-recent user-and-not-tool-result
    /// message. Everything ≥ this index stays untouched.
    anchor: u32,
};

/// Compute §E.2's compactable span for `messages`. The caller
/// provides the model context window (used for tail-budget) and a
/// parallel `pinned` bitmap (`true` for messages whose `meta` field
/// carries `preservePinned`). Allocates a scratch preserved-bitmap
/// on `allocator`; the returned struct owns no memory.
pub fn selectSpan(
    allocator: std.mem.Allocator,
    messages: []const types.Message,
    context_window: u32,
    pinned: []const bool,
) !SpanDecision {
    std.debug.assert(pinned.len == messages.len);

    // Step 1 — locate the anchor (last user, non-tool_result).
    var anchor: u32 = 0;
    var found_anchor = false;
    {
        var i = messages.len;
        while (i > 0) {
            i -= 1;
            const m = messages[i];
            if (m.role == .user and m.tool_call_id == null) {
                anchor = @intCast(i);
                found_anchor = true;
                break;
            }
        }
    }
    if (!found_anchor or anchor == 0) {
        return .{ .compactable_start = 0, .compactable_end = 0, .proceed = false, .anchor = 0 };
    }

    // Step 2 — candidate span `[0, anchor)`.
    const candidate_end = anchor;

    // Step 3 — preserve set: first user, tail-budget, pinned.
    const tail_budget: u64 = (@as(u64, context_window) * 15) / 100;
    const preserved = try allocator.alloc(bool, candidate_end);
    defer allocator.free(preserved);
    @memset(preserved, false);

    // First user — the request.
    {
        var i: u32 = 0;
        while (i < candidate_end) : (i += 1) {
            if (messages[i].role == .user and messages[i].tool_call_id == null) {
                preserved[i] = true;
                break;
            }
        }
    }

    // Tail budget (walking backward from anchor - 1).
    {
        var sum: u64 = 0;
        var i = candidate_end;
        while (i > 0) {
            i -= 1;
            if (sum >= tail_budget) break;
            const tokens = messageTokens(messages[i]);
            sum += tokens;
            preserved[i] = true;
        }
    }

    // Pinned set.
    {
        var i: u32 = 0;
        while (i < candidate_end) : (i += 1) {
            if (pinned[i]) preserved[i] = true;
        }
    }

    // Orphan-tool-pair fix-up.
    {
        var i: u32 = 0;
        while (i < candidate_end) : (i += 1) {
            const m = messages[i];
            if (m.role == .assistant) {
                for (m.content) |cb| switch (cb) {
                    .tool_call => |tc| {
                        const partner = findToolResult(messages[0..candidate_end], tc.id);
                        if (partner) |p| {
                            if (preserved[i] != preserved[p]) {
                                const keep = preserved[i] or preserved[p];
                                preserved[i] = keep;
                                preserved[p] = keep;
                            }
                        }
                    },
                    else => {},
                };
            }
        }
    }

    // Step 4 — longest contiguous `false` run in `preserved`.
    var best_start: u32 = 0;
    var best_end: u32 = 0;
    var run_start: u32 = 0;
    var in_run = false;
    var i: u32 = 0;
    while (i < candidate_end) : (i += 1) {
        if (!preserved[i]) {
            if (!in_run) {
                run_start = i;
                in_run = true;
            }
        } else if (in_run) {
            const run_len = i - run_start;
            if (run_len > best_end - best_start) {
                best_start = run_start;
                best_end = i;
            }
            in_run = false;
        }
    }
    if (in_run) {
        const run_len = candidate_end - run_start;
        if (run_len > best_end - best_start) {
            best_start = run_start;
            best_end = candidate_end;
        }
    }

    const span_len = best_end - best_start;
    return .{
        .compactable_start = best_start,
        .compactable_end = best_end,
        .proceed = span_len >= 4,
        .anchor = anchor,
    };
}

/// v1.24.5 — public sum of `messageTokens` over a transcript.
/// Used by the `/compact` slash handlers to render diagnostic
/// messages ("not yet compactable" stays informative — shows
/// actual transcript size + tail budget). Same accounting
/// compaction uses internally for the tail-budget heuristic.
pub fn estimateTranscriptTokens(messages: []const types.Message) u32 {
    var total: u64 = 0;
    for (messages) |m| total += messageTokens(m);
    return @intCast(@min(total, std.math.maxInt(u32)));
}

/// v1.24.5 — count user-and-not-tool-result messages. Mirrors
/// `selectSpan`'s anchor logic: a transcript with zero or one
/// such message can never be compacted (anchor at index 0 or
/// missing).
pub fn countUserTurns(messages: []const types.Message) u32 {
    var n: u32 = 0;
    for (messages) |m| if (m.role == .user and m.tool_call_id == null) {
        n += 1;
    };
    return n;
}

fn messageTokens(m: types.Message) u32 {
    var total_bytes: usize = 0;
    for (m.content) |cb| switch (cb) {
        .text => |t| total_bytes += t.text.len,
        .thinking => |t| total_bytes += t.thinking.len,
        .tool_call => |tc| total_bytes += tc.name.len + tc.arguments_json.len + tc.id.len,
        .image => |img| total_bytes += img.data.len / 8, // rough avg
    };
    return estimateFromLen(total_bytes, .english);
}

fn findToolResult(messages: []const types.Message, call_id: []const u8) ?u32 {
    var i: u32 = 0;
    while (i < messages.len) : (i += 1) {
        const m = messages[i];
        if (m.role == .tool_result) {
            if (m.tool_call_id) |cid| {
                if (std.mem.eql(u8, cid, call_id)) return i;
            }
        }
    }
    return null;
}

// ─── §E.3 + §E.4 summarization dispatch (v1.5.1) ──────────────────

pub const summarizer_system_prompt =
    \\You are summarizing a conversation between a user and an AI assistant.
    \\Produce a terse record of:
    \\
    \\1. The user's overall goal.
    \\2. Key decisions or corrections the user gave.
    \\3. Files touched and their current state (which were created, edited,
    \\   or read).
    \\4. Tool calls whose results matter for future turns (and why).
    \\5. Open questions or blockers.
    \\
    \\Write at most 250 words. Use present tense. Do not restate individual
    \\tool outputs; summarize their effect. Do not add commentary.
;

pub const CompactConfig = struct {
    model: types.Model,
    registry: *const registry_mod.Registry,
    stream_options: registry_mod.StreamOptions = .{},
    pinned: []const bool,
    /// Wall-clock millis — used to name the checkpoint branch
    /// (`pre-compact-<ts>`) and tagged onto the synthetic
    /// `compaction_summary` message.
    timestamp_ms: i64,
    /// When set, the summarization round-trip uses this model
    /// instead of the primary one.
    summarizer_model: ?types.Model = null,
    cancel: *stream_mod.Cancel,
};

pub const CompactResult = struct {
    /// False when the span was too small or there was no anchor —
    /// the trigger does not re-fire until another turn has elapsed.
    proceeded: bool,
    /// Number of messages removed and replaced by the summary.
    replaced_count: u32,
    /// Inclusive start / exclusive end of the removed span.
    span_start: u32,
    span_end: u32,
};

pub const CompactError = error{
    /// The provider returned a terminal `.error_ev`.
    SummarizerFailed,
    /// The provider finished but produced no usable text.
    EmptySummary,
    /// The branch checkpoint could not be created (e.g., name
    /// clash). Compaction aborts before any mutation.
    BranchCheckpointFailed,
};

/// §E.3 + §E.4: run one compaction round. On `proceeded=true`,
/// `transcript.messages[result.span_start]` is the new synthetic
/// `compaction_summary` message (custom role), and the tree has a
/// new `pre-compact-<timestamp_ms>` branch rooted at the original
/// span start. On `proceeded=false`, nothing is mutated.
pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    transcript: *at.Transcript,
    tree: *branching.Tree,
    config: CompactConfig,
) !CompactResult {
    std.debug.assert(config.pinned.len == transcript.messages.items.len);

    // 1. Select the span.
    const decision = try selectSpan(
        allocator,
        transcript.messages.items,
        config.model.context_window,
        config.pinned,
    );
    if (!decision.proceed) return .{
        .proceeded = false,
        .replaced_count = 0,
        .span_start = 0,
        .span_end = 0,
    };

    // 2. Checkpoint the current branch before we mutate.
    const branch_name = try std.fmt.allocPrint(
        allocator,
        "pre-compact-{d}",
        .{config.timestamp_ms},
    );
    defer allocator.free(branch_name);
    tree.fork(branch_name, tree.active, decision.compactable_start) catch {
        return error.BranchCheckpointFailed;
    };

    // 3. Render the §E.3 summarization prompt body.
    const span = transcript.messages.items[decision.compactable_start..decision.compactable_end];
    const prompt_body = try renderSpanAsPrompt(allocator, span);
    defer allocator.free(prompt_body);

    // 4. Dispatch a one-shot summarizer call.
    const model = config.summarizer_model orelse config.model;
    const summary = try runSummarizer(
        allocator,
        io,
        config.registry,
        model,
        prompt_body,
        config.stream_options,
        config.cancel,
    );
    errdefer allocator.free(summary);
    if (summary.len == 0) {
        allocator.free(summary);
        return error.EmptySummary;
    }

    // 5. Splice: remove [start, end), insert the synthetic message at `start`.
    const replaced_count = decision.compactable_end - decision.compactable_start;
    try replaceSpanWithSummary(
        allocator,
        transcript,
        decision.compactable_start,
        decision.compactable_end,
        summary,
        config.timestamp_ms,
        model,
        replaced_count,
    );

    return .{
        .proceeded = true,
        .replaced_count = replaced_count,
        .span_start = decision.compactable_start,
        .span_end = decision.compactable_end,
    };
}

/// §E.3 user-message body. Each message in `span` renders as:
///   --- message {i} ({role}) ---
///   <text blocks joined; tool calls shown as [tool: name(args-preview)];
///    tool results as [result: first-200-chars-or-error-flag]>
pub fn renderSpanAsPrompt(
    allocator: std.mem.Allocator,
    span: []const types.Message,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    for (span, 0..) |m, i| {
        if (i > 0) try buf.append(allocator, '\n');
        const role_name: []const u8 = switch (m.role) {
            .user => "user",
            .assistant => "assistant",
            .tool_result => "toolResult",
            .custom => m.custom_role orelse "custom",
        };
        var hdr_buf: [64]u8 = undefined;
        const hdr = try std.fmt.bufPrint(&hdr_buf, "--- message {d} ({s}) ---\n", .{ i, role_name });
        try buf.appendSlice(allocator, hdr);

        for (m.content) |cb| switch (cb) {
            .text => |t| {
                try buf.appendSlice(allocator, t.text);
                try buf.append(allocator, '\n');
            },
            .thinking => {},
            .image => |img| {
                try buf.appendSlice(allocator, "[image: ");
                try buf.appendSlice(allocator, img.mime_type);
                try buf.appendSlice(allocator, "]\n");
            },
            .tool_call => |tc| {
                try buf.appendSlice(allocator, "[tool: ");
                try buf.appendSlice(allocator, tc.name);
                try buf.append(allocator, '(');
                const args_preview = if (tc.arguments_json.len > 80) tc.arguments_json[0..80] else tc.arguments_json;
                try buf.appendSlice(allocator, args_preview);
                if (tc.arguments_json.len > 80) try buf.appendSlice(allocator, "…");
                try buf.appendSlice(allocator, ")]\n");
            },
        };
        if (m.role == .tool_result) {
            // Tool-result content already landed in the `.text` branch above;
            // prepend an error marker when relevant.
            if (m.is_error) try buf.appendSlice(allocator, "[result: error flag set]\n");
        }
    }

    return try buf.toOwnedSlice(allocator);
}

/// One-shot summarizer call via the registry. Uses the provided
/// `model.api` tag; drains the response stream into a single
/// assistant message and returns its joined text (caller owns).
pub fn runSummarizer(
    allocator: std.mem.Allocator,
    io: std.Io,
    registry: *const registry_mod.Registry,
    model: types.Model,
    user_text: []const u8,
    options: registry_mod.StreamOptions,
    cancel: *stream_mod.Cancel,
) ![]u8 {
    var ch = try stream_mod.Channel.init(allocator, 128);
    defer ch.deinit();

    var user_content = [_]types.ContentBlock{.{ .text = .{ .text = user_text } }};
    var messages = [_]types.Message{.{
        .role = .user,
        .content = &user_content,
        .timestamp = 0,
    }};

    var opts = options;
    opts.cancel = cancel;

    const ctx = registry_mod.StreamCtx{
        .allocator = allocator,
        .io = io,
        .model = model,
        .context = .{
            .system_prompt = summarizer_system_prompt,
            .messages = &messages,
            .tools = &.{},
        },
        .options = opts,
        .out = &ch,
    };
    // The provider drives the channel itself — most native providers
    // run synchronously through `fetch` + SSE translation. For the
    // faux provider this is also synchronous. If a future provider
    // needs async dispatch, callers must switch to a worker thread
    // (same pattern print/rpc mode use).
    registry.stream(ctx) catch {
        return error.SummarizerFailed;
    };

    var msg = stream_mod.drainToMessage(&ch, io, allocator, null, null, null) catch {
        return error.SummarizerFailed;
    };
    defer msg.deinit(allocator);
    if (msg.error_message != null) return error.SummarizerFailed;

    // Join every text block — the reducer guarantees insertion
    // order via its `block_order` table, so concatenation preserves
    // the model's intended text flow.
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    for (msg.content) |cb| switch (cb) {
        .text => |t| try out.appendSlice(allocator, t.text),
        else => {},
    };
    return try out.toOwnedSlice(allocator);
}

/// Splice: remove `transcript.messages[start..end)` and insert a
/// single `compaction_summary` custom-role message at `start`.
fn replaceSpanWithSummary(
    allocator: std.mem.Allocator,
    transcript: *at.Transcript,
    start: u32,
    end: u32,
    summary_text: []u8, // taken ownership of on success
    timestamp_ms: i64,
    summarizer_model: types.Model,
    replaced_count: u32,
) !void {
    _ = summarizer_model; // reserved for future `meta` emission once
    //   transcript messages carry a generic meta bag

    // Deinit the messages we're about to drop.
    for (transcript.messages.items[start..end]) |*m| m.deinit(allocator);

    // Build the synthetic message. Content owns `summary_text`.
    const content = try allocator.alloc(types.ContentBlock, 1);
    content[0] = .{ .text = .{ .text = summary_text } };

    const custom_role = try allocator.dupe(u8, "compaction_summary");

    const summary_msg = types.Message{
        .role = .custom,
        .custom_role = custom_role,
        .content = content,
        .timestamp = timestamp_ms,
    };

    // Splice in one go: remove `end-start` items, insert one.
    // ArrayList doesn't have a native splice, so replace [start] with
    // `summary_msg` and then remove the rest.
    if (end > start) {
        transcript.messages.items[start] = summary_msg;
        // Remove indices [start+1..end) — that's (end - start - 1) items.
        const drop_count = end - start - 1;
        if (drop_count > 0) {
            // Shift-left the tail [end..len) into [start+1..].
            const len = transcript.messages.items.len;
            // v2.18 — invariant check: the tail [end..len) must fit
            // exactly into the destination range [start+1..len-drop_count).
            const dst_start = start + 1;
            const dst_end = len - drop_count;
            const src_start = end;
            const src_end = len;
            std.debug.assert(src_start <= src_end);
            std.debug.assert(dst_start <= dst_end);
            std.debug.assert(dst_end - dst_start == src_end - src_start);
            std.mem.copyForwards(
                at.AgentMessage,
                transcript.messages.items[start + 1 .. len - drop_count],
                transcript.messages.items[end..len],
            );
            transcript.messages.items.len = len - drop_count;
        }
    } else {
        // Zero-length span is a protocol violation (proceed=true
        // implies ≥ 4 messages). Guard anyway.
        try transcript.messages.insert(allocator, start, summary_msg);
    }
    _ = replaced_count;
}

// ─── tests ────────────────────────────────────────────────────────

const testing = std.testing;
const test_h = @import("../../test_helpers.zig");

test "estimateTokens: english divides bytes by 3.5 (rounded up)" {
    // 2 / 3.5 = 0.57 → 1
    try testing.expectEqual(@as(u32, 1), estimateTokens("hi", .english));
    // 5 / 3.5 = 1.43 → 2
    try testing.expectEqual(@as(u32, 2), estimateTokens("hello", .english));
    // 10 / 3.5 = 2.86 → 3
    try testing.expectEqual(@as(u32, 3), estimateTokens("0123456789", .english));
}

test "estimateTokens: code divides bytes by 2 (rounded up)" {
    try testing.expectEqual(@as(u32, 1), estimateTokens("x", .code));
    try testing.expectEqual(@as(u32, 5), estimateTokens("abcdefghij", .code));
}

test "estimateTranscriptTokens + countUserTurns: diagnostic helpers (v1.24.5)" {
    var user_first = [_]types.ContentBlock{.{ .text = .{ .text = "hello" } }};
    var asst_first = [_]types.ContentBlock{.{ .text = .{ .text = "hi back, how can I help?" } }};
    var user_second = [_]types.ContentBlock{.{ .text = .{ .text = "tell me about cats" } }};
    const msgs = [_]types.Message{
        .{ .role = .user, .content = &user_first, .timestamp = 0 },
        .{ .role = .assistant, .content = &asst_first, .timestamp = 1 },
        .{ .role = .user, .content = &user_second, .timestamp = 2 },
    };

    // 2 user turns, neither is a tool_result.
    try testing.expectEqual(@as(u32, 2), countUserTurns(&msgs));

    // ~ "hello" (5) + "hi back, how can I help?" (24) + "tell me about cats" (18) = 47 bytes
    // / 3.5 ≈ 14 tokens. Just assert it's non-zero and ≥ each
    // individual message — the precise number is brittle to
    // estimateFromLen rounding.
    const total = estimateTranscriptTokens(&msgs);
    try testing.expect(total >= messageTokens(msgs[0]));
    try testing.expect(total > 0);
}

test "countUserTurns: tool_result messages don't count as user turns" {
    var user_only = [_]types.ContentBlock{.{ .text = .{ .text = "hi" } }};
    var tr = [_]types.ContentBlock{.{ .text = .{ .text = "tool output" } }};
    const msgs = [_]types.Message{
        .{ .role = .user, .content = &user_only, .timestamp = 0 },
        .{ .role = .tool_result, .content = &tr, .timestamp = 1, .tool_call_id = "call-1" },
    };
    // Only the first message counts — tool_result is excluded
    // (matches selectSpan's anchor logic that excludes tool_result
    // messages from being eligible anchors).
    try testing.expectEqual(@as(u32, 1), countUserTurns(&msgs));
}

test "shouldTrigger: below 80% returns .none" {
    try testing.expectEqual(Trigger.none, shouldTrigger(7999, 10_000));
    try testing.expectEqual(Trigger.none, shouldTrigger(0, 10_000));
}

test "shouldTrigger: 80%–91% returns .soft" {
    try testing.expectEqual(Trigger.soft, shouldTrigger(8000, 10_000));
    try testing.expectEqual(Trigger.soft, shouldTrigger(9100, 10_000));
}

test "shouldTrigger: 92%+ returns .hard" {
    try testing.expectEqual(Trigger.hard, shouldTrigger(9200, 10_000));
    try testing.expectEqual(Trigger.hard, shouldTrigger(10_000, 10_000));
}

test "shouldTrigger: zero window returns .none" {
    try testing.expectEqual(Trigger.none, shouldTrigger(9999, 0));
}

fn msgUser(text: []const u8) types.Message {
    var content = [_]types.ContentBlock{.{ .text = .{ .text = text } }};
    return .{
        .role = .user,
        .content = &content,
        .timestamp = 0,
    };
}

test "selectSpan: fewer than 4 compactable messages → proceed=false" {
    var c0 = [_]types.ContentBlock{.{ .text = .{ .text = "hi" } }};
    var c1 = [_]types.ContentBlock{.{ .text = .{ .text = "ok" } }};
    var c2 = [_]types.ContentBlock{.{ .text = .{ .text = "again" } }};

    var messages = [_]types.Message{
        .{ .role = .user, .content = &c0, .timestamp = 0 },
        .{ .role = .assistant, .content = &c1, .timestamp = 0 },
        .{ .role = .user, .content = &c2, .timestamp = 0 },
    };
    const pinned = [_]bool{ false, false, false };

    const d = try selectSpan(testing.allocator, &messages, 10_000, &pinned);
    try testing.expect(!d.proceed);
}

test "selectSpan: preserves first user + tail budget — compacts the middle" {
    // 12 messages — alternating user/assistant; last is the anchor.
    // Context window 1_000 → tail budget = 150 tokens (~0.15 * 1000).
    var buf: [12][1]types.ContentBlock = undefined;
    var msgs: [12]types.Message = undefined;
    var text_store: [12][64]u8 = undefined;
    for (&msgs, 0..) |*m, i| {
        // ~20 bytes each → ~6 tokens each → tail budget ≈ 25 messages worth.
        _ = try std.fmt.bufPrint(&text_store[i], "message number {d:>2} text here", .{i});
        buf[i][0] = .{ .text = .{ .text = text_store[i][0..30] } };
        m.* = .{
            .role = if (i % 2 == 0) .user else .assistant,
            .content = &buf[i],
            .timestamp = 0,
            .tool_call_id = null,
        };
    }
    const pinned: [12]bool = @splat(false);

    // Context window 100 → tail budget ≈ 15 tokens. With ~6 tokens
    // per message, only the last 2-3 messages before anchor survive
    // as "tail". The middle ~6 messages become the compactable span.
    const d = try selectSpan(testing.allocator, &msgs, 100, &pinned);
    try testing.expect(d.proceed);
    // First user (index 0) preserved → compactable starts at ≥ 1.
    try testing.expect(d.compactable_start >= 1);
    // Anchor is the most recent user; for 12 messages it's index 10.
    try testing.expectEqual(@as(u32, 10), d.anchor);
}

test "selectSpan: pinned messages are preserved" {
    var c: [6][1]types.ContentBlock = undefined;
    var msgs: [6]types.Message = undefined;
    const text = "fixed text content";
    for (&msgs, 0..) |*m, i| {
        c[i][0] = .{ .text = .{ .text = text } };
        m.* = .{
            .role = if (i % 2 == 0) .user else .assistant,
            .content = &c[i],
            .timestamp = 0,
        };
    }
    // Pin index 2; tail budget is tiny so everything else is
    // compactable candidate.
    var pinned: [6]bool = @splat(false);
    pinned[2] = true;

    const d = try selectSpan(testing.allocator, &msgs, 100, &pinned);
    // Span may or may not proceed depending on run length; the
    // invariant we assert is "index 2 is outside the compactable
    // span" — either before start or after end.
    try testing.expect(d.compactable_start > 2 or d.compactable_end <= 2);
}

// ─── v1.5.1 — summarization dispatch tests ────────────────────────

const faux = @import("../../ai/providers/faux.zig");

test "renderSpanAsPrompt: text, tool-call, tool-result formatted per §E.3" {
    const gpa = testing.allocator;
    var c_u: [1]types.ContentBlock = .{.{ .text = .{ .text = "please list the files" } }};
    var c_a: [1]types.ContentBlock = .{.{ .tool_call = .{
        .id = "c-1",
        .name = "ls",
        .arguments_json = "{\"path\":\".\"}",
    } }};
    var c_r: [1]types.ContentBlock = .{.{ .text = .{ .text = "one.txt\ntwo.txt" } }};
    const span = [_]types.Message{
        .{ .role = .user, .content = &c_u, .timestamp = 0 },
        .{ .role = .assistant, .content = &c_a, .timestamp = 0 },
        .{ .role = .tool_result, .content = &c_r, .timestamp = 0, .tool_call_id = "c-1" },
    };
    const body = try renderSpanAsPrompt(gpa, &span);
    defer gpa.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "--- message 0 (user) ---") != null);
    try testing.expect(std.mem.indexOf(u8, body, "please list the files") != null);
    try testing.expect(std.mem.indexOf(u8, body, "[tool: ls({\"path\":\".\"})]") != null);
    try testing.expect(std.mem.indexOf(u8, body, "one.txt") != null);
}

test "run: forks a pre-compact branch and splices compaction_summary in" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    // Build a 12-message transcript: enough to clear the 4-message
    // minimum compactable span once first-user + tail-budget are
    // preserved. Each message is ~30 bytes → ~9 tokens. Context
    // window 100 → tail budget ~15 tokens → roughly 1-2 messages
    // of tail preserved. Span should land in the middle.
    var transcript = at.Transcript.init(gpa);
    defer transcript.deinit();
    var i: u32 = 0;
    while (i < 12) : (i += 1) {
        const text = try std.fmt.allocPrint(gpa, "message number {d:>2} body text", .{i});
        const content = try gpa.alloc(types.ContentBlock, 1);
        content[0] = .{ .text = .{ .text = text } };
        try transcript.append(.{
            .role = if (i % 2 == 0) .user else .assistant,
            .content = content,
            .timestamp = 100 + @as(i64, i),
        });
    }

    // Wire a faux provider that returns a known summary blob.
    var fp = faux.FauxProvider.init(gpa);
    defer fp.deinit();
    try fp.push(.{ .events = &.{
        .{ .text = .{ .text = "SUMMARY: user wants files listed; tool ls returned two.", .chunk_size = 8 } },
    } });

    var reg = registry_mod.Registry.init(gpa);
    defer reg.deinit();
    try reg.register(.{
        .api = "faux",
        .provider = "faux",
        .stream_fn = fauxStreamShim,
        .userdata = @ptrCast(&fp),
    });

    var tree = try branching.Tree.init(gpa);
    defer tree.deinit();
    // The tree appends one Tree.appendOnActive per message in
    // production; we simulate that here so the fork point lines
    // up.
    var j: u32 = 0;
    while (j < 12) : (j += 1) try tree.appendOnActive(null);

    const pinned = try gpa.alloc(bool, 12);
    defer gpa.free(pinned);
    @memset(pinned, false);

    var cancel: stream_mod.Cancel = .{};
    const result = try run(gpa, io, &transcript, &tree, .{
        .model = .{ .id = "faux-1", .provider = "faux", .api = "faux", .context_window = 100 },
        .registry = &reg,
        .stream_options = .{ .cancel = &cancel },
        .pinned = pinned,
        .timestamp_ms = 1_714_000_000_000,
        .cancel = &cancel,
    });

    try testing.expect(result.proceeded);
    try testing.expect(result.replaced_count >= 4);

    // Transcript is shorter by (replaced_count - 1).
    try testing.expectEqual(
        @as(usize, 12 - result.replaced_count + 1),
        transcript.messages.items.len,
    );

    // Message at `span_start` is the compaction_summary custom-role.
    const summary_msg = transcript.messages.items[result.span_start];
    try testing.expectEqual(types.Role.custom, summary_msg.role);
    try testing.expect(summary_msg.custom_role != null);
    try testing.expectEqualStrings("compaction_summary", summary_msg.custom_role.?);
    try testing.expectEqual(@as(usize, 1), summary_msg.content.len);
    try testing.expect(std.mem.indexOf(u8, summary_msg.content[0].text.text, "SUMMARY") != null);

    // Tree gained a `pre-compact-<ts>` branch rooted at the span start.
    try testing.expect(tree.branches.get("pre-compact-1714000000000") != null);
}

test "run: proceed=false when the span is too short, no mutation" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    // Only 3 messages — §E.2 aborts when the compactable span is < 4.
    var transcript = at.Transcript.init(gpa);
    defer transcript.deinit();
    for (0..3) |i| {
        const content = try gpa.alloc(types.ContentBlock, 1);
        content[0] = .{ .text = .{ .text = try gpa.dupe(u8, "x") } };
        try transcript.append(.{
            .role = if (i % 2 == 0) .user else .assistant,
            .content = content,
            .timestamp = @as(i64, @intCast(i)),
        });
    }
    const orig_len = transcript.messages.items.len;

    var reg = registry_mod.Registry.init(gpa);
    defer reg.deinit();
    // No provider registered — proving `run` doesn't dispatch when
    // proceed=false.

    var tree = try branching.Tree.init(gpa);
    defer tree.deinit();
    const pinned = [_]bool{ false, false, false };
    var cancel: stream_mod.Cancel = .{};

    const result = try run(gpa, io, &transcript, &tree, .{
        .model = .{ .id = "faux-1", .provider = "faux", .api = "faux", .context_window = 100 },
        .registry = &reg,
        .stream_options = .{ .cancel = &cancel },
        .pinned = &pinned,
        .timestamp_ms = 1,
        .cancel = &cancel,
    });
    try testing.expect(!result.proceeded);
    try testing.expectEqual(orig_len, transcript.messages.items.len);
}

fn fauxStreamShim(ctx: registry_mod.StreamCtx) anyerror!void {
    const fp: *faux.FauxProvider = @ptrCast(@alignCast(ctx.userdata.?));
    try fp.runSync(ctx.io, ctx.context, ctx.out);
}

// ─── v1.6.1 — coverage gap fills ─────────────────────────────────

test "run: empty summarizer output → EmptySummary error" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var transcript = at.Transcript.init(gpa);
    defer transcript.deinit();
    var i: u32 = 0;
    while (i < 12) : (i += 1) {
        const text = try std.fmt.allocPrint(gpa, "message number {d:>2} body text", .{i});
        const content = try gpa.alloc(types.ContentBlock, 1);
        content[0] = .{ .text = .{ .text = text } };
        try transcript.append(.{
            .role = if (i % 2 == 0) .user else .assistant,
            .content = content,
            .timestamp = @as(i64, @intCast(i)),
        });
    }

    var fp = faux.FauxProvider.init(gpa);
    defer fp.deinit();
    // Empty text triggers EmptySummary because the reducer produces
    // an empty string.
    try fp.push(.{ .events = &.{.{ .text = .{ .text = "", .chunk_size = 8 } }} });

    var reg = registry_mod.Registry.init(gpa);
    defer reg.deinit();
    try reg.register(.{
        .api = "faux",
        .provider = "faux",
        .stream_fn = fauxStreamShim,
        .userdata = @ptrCast(&fp),
    });

    var tree = try branching.Tree.init(gpa);
    defer tree.deinit();
    var j: u32 = 0;
    while (j < 12) : (j += 1) try tree.appendOnActive(null);
    const pinned = try gpa.alloc(bool, 12);
    defer gpa.free(pinned);
    @memset(pinned, false);

    var cancel: stream_mod.Cancel = .{};
    const err = run(gpa, io, &transcript, &tree, .{
        .model = .{ .id = "faux-1", .provider = "faux", .api = "faux", .context_window = 100 },
        .registry = &reg,
        .stream_options = .{ .cancel = &cancel },
        .pinned = pinned,
        .timestamp_ms = 5,
        .cancel = &cancel,
    });
    try testing.expectError(error.EmptySummary, err);
}

test "messageTokens: english-rate heuristic on mixed content" {
    const gpa = testing.allocator;
    const c = try gpa.alloc(types.ContentBlock, 1);
    defer gpa.free(c);
    c[0] = .{ .text = .{ .text = "hello there" } }; // 11 bytes → ceil(11/3.5) = 4
    const m = types.Message{ .role = .user, .content = c, .timestamp = 0 };
    try testing.expectEqual(@as(u32, 4), messageTokens(m));
}

test "findToolResult: matches on id, ignores other roles" {
    var cu: [1]types.ContentBlock = .{.{ .text = .{ .text = "u" } }};
    var car: [1]types.ContentBlock = .{.{ .text = .{ .text = "r" } }};
    const messages = [_]types.Message{
        .{ .role = .user, .content = &cu, .timestamp = 0 },
        .{ .role = .tool_result, .content = &car, .timestamp = 0, .tool_call_id = "abc" },
        .{ .role = .tool_result, .content = &car, .timestamp = 0, .tool_call_id = "xyz" },
    };
    try testing.expectEqual(@as(u32, 1), findToolResult(&messages, "abc").?);
    try testing.expectEqual(@as(u32, 2), findToolResult(&messages, "xyz").?);
    try testing.expect(findToolResult(&messages, "nope") == null);
}

// ─── v2.18 — replaceSpanWithSummary unit tests ──────────────────

/// Helper: build a user/assistant message with heap-allocated content
/// so that `replaceSpanWithSummary` can safely deinit replaced slots.
fn buildMsg(gpa: std.mem.Allocator, text: []const u8, role: types.Role, ts: i64) !types.Message {
    const owned_text = try gpa.dupe(u8, text);
    const content = try gpa.alloc(types.ContentBlock, 1);
    content[0] = .{ .text = .{ .text = owned_text } };
    return .{
        .role = role,
        .content = content,
        .timestamp = ts,
    };
}

test "replaceSpanWithSummary: replaces first N messages (start=0)" {
    const gpa = testing.allocator;
    var transcript = at.Transcript.init(gpa);
    defer transcript.deinit();

    try transcript.append(try buildMsg(gpa, "user 0", .user, 100));
    try transcript.append(try buildMsg(gpa, "asst 0", .assistant, 101));
    try transcript.append(try buildMsg(gpa, "user 1", .user, 102));
    try transcript.append(try buildMsg(gpa, "asst 1", .assistant, 103));
    try transcript.append(try buildMsg(gpa, "user 2", .user, 104));
    try transcript.append(try buildMsg(gpa, "asst 2", .assistant, 105));

    const summary_text = try gpa.dupe(u8, "SUMMARY: first two messages compacted");
    try replaceSpanWithSummary(gpa, &transcript, 0, 2, summary_text, 200, types.Model{ .id = "test", .provider = "faux", .api = "faux" }, 2);

    // Length: 6 - (2 - 1) = 5
    try testing.expectEqual(@as(usize, 5), transcript.messages.items.len);

    // First message is the summary
    try testing.expectEqualStrings("SUMMARY: first two messages compacted", transcript.messages.items[0].content[0].text.text);
    try testing.expectEqual(types.Role.custom, transcript.messages.items[0].role);
    try testing.expectEqualStrings("compaction_summary", transcript.messages.items[0].custom_role.?);

    // Remaining messages shifted correctly
    try testing.expectEqualStrings("user 1", transcript.messages.items[1].content[0].text.text);
    try testing.expectEqualStrings("asst 1", transcript.messages.items[2].content[0].text.text);
    try testing.expectEqualStrings("user 2", transcript.messages.items[3].content[0].text.text);
    try testing.expectEqualStrings("asst 2", transcript.messages.items[4].content[0].text.text);
}

test "replaceSpanWithSummary: replaces last N messages (end=len)" {
    const gpa = testing.allocator;
    var transcript = at.Transcript.init(gpa);
    defer transcript.deinit();

    try transcript.append(try buildMsg(gpa, "user 0", .user, 100));
    try transcript.append(try buildMsg(gpa, "asst 0", .assistant, 101));
    try transcript.append(try buildMsg(gpa, "user 1", .user, 102));
    try transcript.append(try buildMsg(gpa, "asst 1", .assistant, 103));
    try transcript.append(try buildMsg(gpa, "user 2", .user, 104));
    try transcript.append(try buildMsg(gpa, "asst 2", .assistant, 105));

    const summary_text = try gpa.dupe(u8, "SUMMARY: last two messages compacted");
    try replaceSpanWithSummary(gpa, &transcript, 4, 6, summary_text, 200, types.Model{ .id = "test", .provider = "faux", .api = "faux" }, 2);

    // Length: 6 - (2 - 1) = 5
    try testing.expectEqual(@as(usize, 5), transcript.messages.items.len);

    // Last message is the summary
    try testing.expectEqualStrings("SUMMARY: last two messages compacted", transcript.messages.items[4].content[0].text.text);

    // Earlier messages unchanged
    try testing.expectEqualStrings("user 0", transcript.messages.items[0].content[0].text.text);
    try testing.expectEqualStrings("asst 0", transcript.messages.items[1].content[0].text.text);
}

test "replaceSpanWithSummary: replaces a middle span" {
    const gpa = testing.allocator;
    var transcript = at.Transcript.init(gpa);
    defer transcript.deinit();

    try transcript.append(try buildMsg(gpa, "user 0", .user, 100));
    try transcript.append(try buildMsg(gpa, "asst 0", .assistant, 101));
    try transcript.append(try buildMsg(gpa, "user 1", .user, 102));
    try transcript.append(try buildMsg(gpa, "asst 1", .assistant, 103));
    try transcript.append(try buildMsg(gpa, "user 2", .user, 104));
    try transcript.append(try buildMsg(gpa, "asst 2", .assistant, 105));
    try transcript.append(try buildMsg(gpa, "user 3", .user, 106));

    const summary_text = try gpa.dupe(u8, "SUMMARY: middle messages compacted");
    try replaceSpanWithSummary(gpa, &transcript, 2, 5, summary_text, 200, types.Model{ .id = "test", .provider = "faux", .api = "faux" }, 3);

    // Length: 7 - (3 - 1) = 5
    try testing.expectEqual(@as(usize, 5), transcript.messages.items.len);

    // Summary is at index 2 (start)
    try testing.expectEqualStrings("SUMMARY: middle messages compacted", transcript.messages.items[2].content[0].text.text);

    // First two messages unchanged
    try testing.expectEqualStrings("user 0", transcript.messages.items[0].content[0].text.text);
    try testing.expectEqualStrings("asst 0", transcript.messages.items[1].content[0].text.text);

    // Tail shifted correctly
    try testing.expectEqualStrings("asst 2", transcript.messages.items[3].content[0].text.text);
    try testing.expectEqualStrings("user 3", transcript.messages.items[4].content[0].text.text);
}

test "replaceSpanWithSummary: replaces a single message" {
    const gpa = testing.allocator;
    var transcript = at.Transcript.init(gpa);
    defer transcript.deinit();

    try transcript.append(try buildMsg(gpa, "user 0", .user, 100));
    try transcript.append(try buildMsg(gpa, "asst 0", .assistant, 101));
    try transcript.append(try buildMsg(gpa, "user 1", .user, 102));

    const summary_text = try gpa.dupe(u8, "SUMMARY: single message replaced");
    try replaceSpanWithSummary(gpa, &transcript, 1, 2, summary_text, 200, types.Model{ .id = "test", .provider = "faux", .api = "faux" }, 1);

    // Length: 3 - (1 - 1) = 3 — single message replaced in place
    try testing.expectEqual(@as(usize, 3), transcript.messages.items.len);

    try testing.expectEqualStrings("SUMMARY: single message replaced", transcript.messages.items[1].content[0].text.text);
    try testing.expectEqualStrings("user 0", transcript.messages.items[0].content[0].text.text);
    try testing.expectEqualStrings("user 1", transcript.messages.items[2].content[0].text.text);
}

test "replaceSpanWithSummary: zero-length span (start == end) inserts without removal" {
    const gpa = testing.allocator;
    var transcript = at.Transcript.init(gpa);
    defer transcript.deinit();

    try transcript.append(try buildMsg(gpa, "user 0", .user, 100));
    try transcript.append(try buildMsg(gpa, "asst 0", .assistant, 101));
    try transcript.append(try buildMsg(gpa, "user 1", .user, 102));

    const summary_text = try gpa.dupe(u8, "SUMMARY: inserted at position 1");
    try replaceSpanWithSummary(gpa, &transcript, 1, 1, summary_text, 200, types.Model{ .id = "test", .provider = "faux", .api = "faux" }, 0);

    // Length: 3 - (0 - 1) = 4 — summary inserted at index 1, others shifted right
    try testing.expectEqual(@as(usize, 4), transcript.messages.items.len);

    try testing.expectEqualStrings("user 0", transcript.messages.items[0].content[0].text.text);
    try testing.expectEqualStrings("SUMMARY: inserted at position 1", transcript.messages.items[1].content[0].text.text);
    try testing.expectEqualStrings("asst 0", transcript.messages.items[2].content[0].text.text);
    try testing.expectEqualStrings("user 1", transcript.messages.items[3].content[0].text.text);
}
