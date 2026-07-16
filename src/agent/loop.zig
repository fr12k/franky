//! Agent loop — §4.3-§4.5.
//!
//! `agentLoop` drives turns until: the assistant stops (no tool calls,
//! no steering/follow-up) OR a tool sets `terminate = true` OR cancel
//! fires. Each turn:
//!   1. Call LLM via the registry.
//!   2. Emit message_start/update/end for the assistant's streamed output.
//!   3. For each tool call: beforeToolCall hook → execute → afterToolCall.
//!   4. Emit toolResult messages in **source order**, append to history.
//!   5. Check steering / follow-up hooks → append → loop.
//!
//! Invariants:
//!   - All errors are stream events (`agent_error`), not raised.
//!   - Tool `execute` may throw; the loop catches and wraps as `tool_runtime`.
//!   - Callbacks must not throw; if they do, captured and emitted as
//!     `internal`.

const std = @import("std");
const ai = struct {
    pub const types = @import("../ai/types.zig");
    pub const errors = @import("../ai/errors.zig");
    pub const stream = @import("../ai/stream.zig");
    pub const channel = @import("../ai/channel.zig");
    pub const registry = @import("../ai/registry.zig");
    pub const log = @import("../ai/log.zig");
    pub const http = @import("../ai/http.zig");
};
const at = @import("types.zig");

pub const AgentChannel = at.AgentChannel;
pub const AgentMessage = at.AgentMessage;

const guardrails_mod = @import("guardrails/guardrails.zig");
const truncate = @import("../coding/tools/truncate.zig");
const tool_common = @import("../coding/tools/common.zig");
const compression_mod = @import("../coding/compression.zig");

pub const ConvertToLlmFn = *const fn (
    allocator: std.mem.Allocator,
    messages: []const AgentMessage,
) anyerror![]ai.types.Message;

/// Default convertToLlm: pass-through, with two custom-role rewrites:
///   - `custom_role == "compaction_summary"` is converted to a plain
///     `user` message whose first text block is prefixed with
///     `"Earlier in this conversation:\n\n"`. The model sees this as
///     ordinary context rather than a synthetic role it doesn't know.
///   - Any other `.custom` role is filtered out (unknown to the model).
pub fn defaultConvertToLlm(
    allocator: std.mem.Allocator,
    messages: []const AgentMessage,
) ![]ai.types.Message {
    const compaction_prefix = "Earlier in this conversation:\n\n";

    var out: std.ArrayList(ai.types.Message) = .empty;
    errdefer {
        for (out.items) |*m| m.deinit(allocator);
        out.deinit(allocator);
    }
    for (messages) |m| {
        const is_compaction = m.role == .custom and
            m.custom_role != null and
            std.mem.eql(u8, m.custom_role.?, "compaction_summary");
        if (m.role == .custom and !is_compaction) continue;

        // Deep-copy so the resulting slice can be owned independently.
        var content: std.ArrayList(ai.types.ContentBlock) = .empty;
        errdefer {
            for (content.items) |cb| cb.deinit(allocator);
            content.deinit(allocator);
        }
        if (is_compaction) {
            // Prefix the first text block; copy the rest verbatim.
            var first_text_done = false;
            for (m.content) |cb| switch (cb) {
                .text => |t| {
                    if (!first_text_done) {
                        const merged = try std.fmt.allocPrint(
                            allocator,
                            "{s}{s}",
                            .{ compaction_prefix, t.text },
                        );
                        errdefer allocator.free(merged);
                        const sig = if (t.text_signature) |s| try allocator.dupe(u8, s) else null;
                        try content.append(allocator, .{ .text = .{
                            .text = merged,
                            .text_signature = sig,
                        } });
                        first_text_done = true;
                    } else {
                        try content.append(allocator, try cb.dupe(allocator));
                    }
                },
                else => try content.append(allocator, try cb.dupe(allocator)),
            };
        } else {
            for (m.content) |cb| try content.append(allocator, try cb.dupe(allocator));
        }

        const content_slice = try content.toOwnedSlice(allocator);
        errdefer {
            for (content_slice) |cb| cb.deinit(allocator);
            allocator.free(content_slice);
        }

        // Build the message as a local so we can errdefer cleanup
        // if any of the optional-field dupes fails.
        var msg: ai.types.Message = .{
            .role = if (is_compaction) .user else m.role,
            .content = content_slice,
            .timestamp = m.timestamp,
            .stop_reason = m.stop_reason,
            .usage = m.usage,
            .error_message = if (m.error_message) |s| try allocator.dupe(u8, s) else null,
            .provider = if (m.provider) |s| try allocator.dupe(u8, s) else null,
            .model = if (m.model) |s| try allocator.dupe(u8, s) else null,
            .api = if (m.api) |s| try allocator.dupe(u8, s) else null,
            .tool_call_id = if (m.tool_call_id) |s| try allocator.dupe(u8, s) else null,
            .is_error = m.is_error,
        };
        errdefer msg.deinit(allocator);
        try out.append(allocator, msg);
    }
    return out.toOwnedSlice(allocator);
}

pub const HookDecision = struct {
    block: bool = false,
    reason_text: ?[]const u8 = null,
};

/// Decision from the runtime role gate. The mode-level driver
/// provides a callback that returns non-null when a tool name
/// (not present in this session's registered tools) is a known
/// built-in disabled by the active role. The loop then emits a
/// structured `role_denied` `tool_execution_end` instead of the
/// generic "unknown tool" path — catches the case where the
/// model emits a `tool_call` from prior-conversation memory or
/// training data for a tool that exists only in higher roles.
pub const RoleDenial = struct {
    current_role: []const u8,
    /// Lowest role that would re-enable this tool, when known.
    /// E.g. `bash` → `code`. Surfaces as a remedy hint.
    min_role: ?[]const u8 = null,
};

pub const RoleDeniedFn = *const fn (
    userdata: ?*anyopaque,
    tool_name: []const u8,
) ?RoleDenial;

pub const BeforeToolCallFn = *const fn (
    userdata: ?*anyopaque,
    tool: *const at.AgentTool,
    call_id: []const u8,
    args_json: []const u8,
) HookDecision;

pub const AfterToolCallFn = *const fn (
    userdata: ?*anyopaque,
    tool: *const at.AgentTool,
    call_id: []const u8,
    result: *at.ToolResult,
) void;

/// §4.3 between-turn hook. Called after `runTurn` returns
/// `keep_going=false` (the assistant stopped). Implementations
/// drain their steer/followUp queues, append new user-role
/// messages to `transcript`, and return `true` to request one
/// more turn. Returning `false` ends the loop immediately.
pub const BetweenTurnsFn = *const fn (
    userdata: ?*anyopaque,
    transcript: *Transcript,
) bool;

/// Decision returned by `OnMaxTurnsFn` when the loop has reached
/// its `max_turns` cap. `extend(N)` adds N more turns to the cap
/// (additive — each call accumulates). `stop` declines to extend;
/// the loop then emits `max_turns_exceeded` and closes.
pub const MaxTurnsDecision = union(enum) {
    stop,
    extend: u32,
};

/// Hook fired exactly when the loop's turn counter has caught up
/// to its current cap. Receives the number of turns consumed and
/// the cap that was just hit; returns `.extend(N)` to continue or
/// `.stop` to give up. Mode drivers wire this to whatever UX the
/// surface allows — interactive prompts the user, RPC/proxy can
/// surface a `tool_permission_request`-style event, print mode
/// typically passes null and lets the loop terminate.
pub const OnMaxTurnsFn = *const fn (
    userdata: ?*anyopaque,
    turns_used: u32,
    current_cap: u32,
) MaxTurnsDecision;

/// v1.22.0 — per-hook userdata resolver. Returns the hook's
/// override if set, otherwise the shared `hook_userdata`.
fn beforeToolCallUserdata(c: *const Config) ?*anyopaque {
    return c.before_tool_call_userdata orelse c.hook_userdata;
}

fn roleDeniedUserdata(c: *const Config) ?*anyopaque {
    return c.role_denied_userdata orelse c.hook_userdata;
}

fn onMaxTurnsUserdata(c: *const Config) ?*anyopaque {
    return c.on_max_turns_userdata orelse c.hook_userdata;
}

pub const Config = struct {
    model: ai.types.Model,
    system_prompt: []const u8 = "",
    tools: []const at.AgentTool,
    registry: *const ai.registry.Registry,
    convert_to_llm: ConvertToLlmFn = defaultConvertToLlm,
    execution_mode: at.ExecutionMode = .sequential,
    cancel: *ai.stream.Cancel,
    /// Default `userdata` for every hook below. Existing v1.x
    /// callers set this once and all hooks share it.
    hook_userdata: ?*anyopaque = null,
    before_tool_call: ?BeforeToolCallFn = null,
    /// v1.22.0 — optional per-hook userdata override. Falls back
    /// to `hook_userdata` when null. Lets a single Agent class
    /// wire its own `between_turns` userdata (the Agent itself,
    /// for queue-drain access) AND a separately-owned `before_tool_call`
    /// userdata (e.g. a `permissions.SessionGates`) without forcing
    /// every hook to share one downcast target. `null` keeps
    /// pre-v1.22 semantics.
    before_tool_call_userdata: ?*anyopaque = null,
    role_denied: ?RoleDeniedFn = null,
    /// v1.22.0 — same fallback shape as `before_tool_call_userdata`.
    role_denied_userdata: ?*anyopaque = null,
    after_tool_call: ?AfterToolCallFn = null,
    /// §4.3 steer/followUp drain hooks. Called between turns —
    /// after a turn naturally ends, before the next turn's LLM
    /// call. Implementations may append messages to `transcript`
    /// (typically one per queued steer/followUp entry) to inject
    /// user-role messages into the conversation. Each returns
    /// `true` to keep looping (another turn runs), `false` to
    /// stop early. When `null`, the loop uses its default
    /// "no tool calls → stop" rule.
    between_turns: ?BetweenTurnsFn = null,
    /// vN — optional check function. Called between turns just after
    /// the `between_turns` hook. Return true to exit the loop gracefully
    /// (the current turn's output is preserved in the transcript).
    /// Checks are also made before starting a new LLM call, so a stop
    /// requested during the between-turns hook is caught promptly.
    stop_requested_fn: ?*const fn (userdata: ?*anyopaque) bool = null,
    stream_options: ai.registry.StreamOptions = .{},
    /// Hard cap on turn count — guards against infinite loops.
    /// User-configurable via `--max-turns` (CLI), `Settings.max_turns`,
    /// the `max_turns` profile field, or the `Agent.Config.max_turns`
    /// SDK field. When the loop reaches this cap, `on_max_turns` is
    /// called (if set); without a hook, or when the hook returns
    /// `.stop`, the loop emits `max_turns_exceeded` and closes.
    max_turns: u32 = 100,
    /// Optional hook fired when `turn_count == max_turns`. Returns
    /// either `.extend(N)` (additive — `max_turns += N`, loop continues)
    /// or `.stop` (loop emits `max_turns_exceeded` and closes).
    on_max_turns: ?OnMaxTurnsFn = null,
    /// Optional per-hook userdata. Falls back to `hook_userdata` when
    /// null — same pattern as `before_tool_call_userdata` etc.
    on_max_turns_userdata: ?*anyopaque = null,
    /// When true, after the cap is exhausted and any `on_max_turns`
    /// extension credits are spent, run one final tool-disabled turn
    /// with a synthetic user message asking the model to produce a
    /// final report. Guarantees an `end_turn` and a useful artifact
    /// instead of just `agent_error`. The `max_turns_exceeded`
    /// agent_error still fires after the summary turn so callers
    /// that programmatically gate on it stay backwards-compatible.
    max_turns_summarize: bool = false,
    /// v1.16.3 — when true, if the assistant ends a turn with text
    /// content that parses as a recognized tool-call shape (e.g.
    /// `{"name": "X", "parameters": {...}}` or `{"type": "function",
    /// ...}`) and no structured `tool_calls[]` ever fired, synthesize
    /// a tool_call from the parsed object. Off by default — heuristic,
    /// risky for models that legitimately emit JSON as their text
    /// reply. Required for some gateway/model combos (Cloudflare's
    /// openai-compat shim with Llama, Cloudflare native endpoint with
    /// any model) where tool-call output isn't structurally translated.
    text_tool_call_fallback: bool = false,
    /// v1.29.0 — directory to dump a JSON snapshot of the reducer
    /// state when `finalize` is about to ship a degenerate (zero
    /// content blocks, clean stop) assistant message. `null`
    /// disables the dump. Mode drivers populate this with
    /// `<session_dir>/events`. Files are named
    /// `<turn-N>.reducer-dump.json`; turn index is 0-based and
    /// reset per agent-loop run.
    reducer_dump_dir: ?[]const u8 = null,
    guardrails: ?*guardrails_mod.GuardrailState = null,
    /// v2.27 — when true, the loop detects stalled models (stop_reason
    /// .length, near-empty .stop, degenerate) and injects a synthetic
    /// "please continue" user message into the transcript before calling
    /// the LLM again. Caps at 2 nudges per stall episode to prevent
    /// infinite loops. Default false — no behavioural change.
    nudge_on_stall: bool = false,
    /// v2.28 — when true, after a natural text-only stop (substantial
    /// content, stop_reason == .stop, no tool calls), the loop waits 1 s,
    /// then injects a synthetic user message asking the model to call
    /// finish_task if it is done. Caps at 2 nudges per session to prevent
    /// infinite loops. Designed for print mode where there is no user to
    /// say "done". Default false — no behavioural change.
    nudge_on_finish_task: bool = false,
    /// v2.29 — when true, after any stop where the model produced text or
    /// tool calls but did NOT call `finish_task`, inject a synthetic user
    /// message asking it to "Continue until you are done and then call
    /// finish task". Caps at 2 nudges per session. Broader than
    /// `nudge_on_finish_task` — fires even after tool-call turns.
    /// Set via CLI flag `--autocontinue`. Default false.
    nudge_on_autocontinue: bool = false,

    /// v3.0 — opt-in tool-result offloading. When > 0, only the `N` most
    /// recent tool-result messages are sent to the LLM with full content.
    /// Older tool results are replaced with a compact placeholder
    /// ("[tool result: <call_id> — <size> (offloaded) — see <path>]") so the
    /// model still sees the shape of the conversation without paying token
    /// cost for stale output, and the agent can `read` the file to recover
    /// the full content. 0 disables offloading (default — send everything).
    max_full_tool_results: u32 = 0,
    /// v3.0 — when `max_full_tool_results > 0`, the directory to write
    /// offloaded tool-result snapshots. Files are named
    /// `tool-<call_id>.json`. When null, offloaded content is discarded
    /// (old behaviour — the placeholder is still emitted but points to
    /// nowhere). Mode drivers populate this with
    /// `<session_dir>/offloaded-tool-results` or similar.
    offload_dir: ?[]const u8 = null,
    /// v3.0 — optional compression config. When non-null, tool results
    /// are compressed through zompress before entering the transcript.
    /// Embedded by value to avoid lifetime issues.
    compression: ?compression_mod.CompressionConfig = null,
    /// CCR store for reversible compression. Must outlive the loop.
    /// Passed in from the session — never created per turn.
    ccr_store: ?*compression_mod.CcrSessionStore = null,
    /// v3.0 — optional stats collector for compression metrics.
    /// Updated by `compressToolResult` when non-null.
    compression_stats: ?*compression_mod.CompressionStats = null,
};

pub const Transcript = at.Transcript;

/// Run one or more turns. Emits events into `out`; closes with
/// a terminal `turn_end` or `agent_error`.
pub fn agentLoop(
    allocator: std.mem.Allocator,
    io: std.Io,
    transcript: *Transcript,
    config: Config,
    out: *AgentChannel,
) void {
    // Create one HTTP client per loop run so the connection pool is
    // reused across turns (avoids a full TLS handshake on every LLM
    // call). Proxy settings are applied once here rather than per-turn.
    var loop_client = ai.http.Client{ .allocator = allocator, .io = io };
    var loop_proxy_arena: ?std.heap.ArenaAllocator = null;
    // Single defer block — client.deinit() must run before proxy_arena.deinit()
    // because the client holds pointers into the arena (proxy host/auth strings).
    defer {
        loop_client.deinit();
        if (loop_proxy_arena) |*a| a.deinit();
    }
    if (config.stream_options.environ_map) |env_map| {
        loop_proxy_arena = ai.http.setupClientFromEnv(&loop_client, allocator, env_map) catch |e| blk: {
            ai.log.log(.warn, "loop", "proxy_setup_failed", "err={s}", .{@errorName(e)});
            break :blk null;
        };
    }

    var turn_count: u32 = 0;
    var current_cap: u32 = config.max_turns;
    var nudge_count: u32 = 0; // v2.27 — nudges injected this episode
    var finish_nudge_count: u32 = 0; // v2.28 — finish-task nudges injected
    var autocontinue_nudge_count: u32 = 0; // v2.29 — autocontinue nudges injected
    cap_loop: while (true) {
        while (turn_count < current_cap) : (turn_count += 1) {
            if (config.cancel.isFired()) {
                pushAgentError(out, io, allocator, .aborted, "cancelled") catch {};
                return;
            }
            // vN — check stop-requested BEFORE starting a new LLM call.
            // This catches a stop that was requested during the
            // between-turns hook, preventing an unnecessary LLM call.
            if (config.stop_requested_fn) |check_stop| {
                if (check_stop(config.hook_userdata)) {
                    emitInterrupted(out, io, allocator) catch {};
                    return;
                }
            }
            const keep_going = runTurn(allocator, io, transcript, config, out, @ptrCast(&loop_client)) catch |err| {
                pushAgentError(out, io, allocator, agentErrorCode(err), @errorName(err)) catch {};
                return;
            };
            if (config.guardrails) |gr| {
                const gr_wants_turn = gr.betweenTurns(allocator, io, transcript, out) catch |err| blk: {
                    ai.log.log(.warn, "guardrails", "between_turns_error", "err={s}", .{@errorName(err)});
                    break :blk false;
                };
                if (gr_wants_turn) continue;
            }
            if (!keep_going) {
                // v2.27 — nudge-on-stall: detect models that stopped
                // prematurely (token limit, degenerate, near-empty) and
                // inject a "please continue" user message into the
                // transcript before calling the LLM again. Capped at 2
                // nudges per stall episode; reset when a turn ends
                // naturally (no nudge) so a later stall episode gets
                // fresh nudge credits.
                if (config.nudge_on_stall) {
                    if (nudge_count < 2) {
                        const nudged = maybeNudge(allocator, transcript) catch |e| blk: {
                            ai.log.log(.warn, "nudge", "inject_failed", "err={s}", .{@errorName(e)});
                            break :blk false;
                        };
                        if (nudged) {
                            nudge_count += 1;
                            ai.log.log(.info, "nudge", "injected", "count={d}", .{nudge_count});
                            continue;
                        }
                    }
                    // Turn ended naturally — reset the episode counter
                    // so future stall episodes get fresh nudge credits.
                    nudge_count = 0;
                }
                // v2.28 — nudge-on-finish-task: after a natural text-only stop
                // that produced substantive content (model looks done), wait 1 s
                // then inject a "Are you done? Please call finish_task" message.
                // Caps at 2 nudges per session. Designed for print mode where
                // there is no user to say "done".
                if (config.nudge_on_finish_task) {
                    if (finish_nudge_count < 2) {
                        const nudged = maybeNudgeToFinishTask(allocator, io, transcript) catch |e| blk: {
                            ai.log.log(.warn, "finish_nudge", "inject_failed", "err={s}", .{@errorName(e)});
                            break :blk false;
                        };
                        if (nudged) {
                            finish_nudge_count += 1;
                            ai.log.log(.info, "finish_nudge", "injected", "count={d}", .{finish_nudge_count});
                            continue;
                        }
                    }
                }
                // v2.29 — autocontinue: broader nudge that fires after
                // tool-call turns too (not only clean .stop). Injects
                // "Continue until you are done and then call finish task"
                // when the model stopped without calling finish_task.
                if (config.nudge_on_autocontinue) {
                    if (autocontinue_nudge_count < 2) {
                        const nudged = maybeNudgeAutoContinue(allocator, transcript) catch |e| blk: {
                            ai.log.log(.warn, "autocontinue", "inject_failed", "err={s}", .{@errorName(e)});
                            break :blk false;
                        };
                        if (nudged) {
                            autocontinue_nudge_count += 1;
                            ai.log.log(.info, "autocontinue", "injected", "count={d}", .{autocontinue_nudge_count});
                            continue;
                        }
                    }
                }
                // Natural turn_end — check the between-turns hook
                // (§4.3 followUp drain) before closing. When the
                // hook returns `true`, the transcript has new
                // user-role messages appended; run another turn.
                if (config.between_turns) |hook| {
                    if (hook(config.hook_userdata, transcript)) {
                        // vN — after the between-turns hook appended
                        // messages, check stop-requested BEFORE the
                        // next LLM call (the `while` condition jumps
                        // back to the top where the same check runs).
                        continue;
                    }
                }
                out.close(io);
                return;
            }
        }
        // Cap exhausted. Try the on_max_turns hook for an additive
        // extension. Without a hook, or when the hook returns
        // `.stop`, fall through to emit `max_turns_exceeded`.
        if (config.on_max_turns) |hook| {
            const decision = hook(onMaxTurnsUserdata(&config), turn_count, current_cap);
            switch (decision) {
                .extend => |delta| {
                    if (delta > 0) {
                        ai.log.log(.info, "loop", "max_turns_extended", "from={d} delta={d} new_cap={d}", .{ current_cap, delta, current_cap + delta });
                        current_cap += delta;
                        continue :cap_loop;
                    }
                    // delta == 0 is treated as stop — extending by zero
                    // would cause an infinite hook-call loop here.
                },
                .stop => {},
            }
        }
        break :cap_loop;
    }

    // Best-effort: provider/allocation failures here are warn-logged
    // and fall through to the `agent_error{max_turns_exceeded}` path
    // that callers already handle.
    if (config.max_turns_summarize and !config.cancel.isFired()) {
        runForcedSummary(allocator, io, transcript, config, out, current_cap, @ptrCast(&loop_client)) catch |err| {
            ai.log.log(.warn, "loop", "forced_summary_failed", "err={s}", .{@errorName(err)});
        };
    }

    const msg = std.fmt.allocPrint(
        allocator,
        "max turns ({d}) reached",
        .{current_cap},
    ) catch {
        // Out of memory: still emit the error event with a static fallback.
        pushAgentError(out, io, allocator, .max_turns_exceeded, "max turns reached") catch {};
        return;
    };
    defer allocator.free(msg);
    pushAgentError(out, io, allocator, .max_turns_exceeded, msg) catch {};
}

/// Append a synthetic user message asking for a final report, then
/// run one tool-disabled turn so the model has to emit text. The
/// synthetic user message is owned by the transcript on success; on
/// append failure we free locally before returning.
fn runForcedSummary(
    allocator: std.mem.Allocator,
    io: std.Io,
    transcript: *Transcript,
    config: Config,
    out: *AgentChannel,
    cap: u32,
    http_client: ?*anyopaque,
) !void {
    const prompt = try std.fmt.allocPrint(
        allocator,
        "Tool budget exhausted ({d} turns). No more tools — produce a final report in plain text: what you tried, what's still unknown, what you'd do next. Do not call any tools.",
        .{cap},
    );
    errdefer allocator.free(prompt);

    const content = try allocator.alloc(ai.types.ContentBlock, 1);
    errdefer allocator.free(content);
    content[0] = .{ .text = .{ .text = prompt } };

    try transcript.append(.{
        .role = .user,
        .content = content,
        .timestamp = ai.stream.nowMillis(),
    });
    // Ownership of `prompt` and `content` is now the transcript's.

    var no_tools_cfg = config;
    no_tools_cfg.tools = &.{};
    _ = runTurn(allocator, io, transcript, no_tools_cfg, out, http_client) catch |err| {
        ai.log.log(.warn, "loop", "forced_summary_turn_failed", "err={s}", .{@errorName(err)});
    };
}

/// v2.27 — inspect the last assistant message in the transcript and
/// inject a "please continue" user-role nudge if the model appears to
/// have stalled. Returns true when a nudge was appended, false otherwise.
fn maybeNudge(
    allocator: std.mem.Allocator,
    transcript: *Transcript,
) !bool {
    const msgs = transcript.messages.items;
    if (msgs.len == 0) return false;

    const last = msgs[msgs.len - 1];
    if (last.role != .assistant) return false;

    const stop = last.stop_reason orelse return false;

    // Skip: model is productively calling tools or explicitly stopped.
    if (stop == .tool_use or stop == .refusal or stop == .err or stop == .aborted) return false;

    // Count text content length and check for tool calls.
    var total_text_len: usize = 0;
    var has_tool_call = false;
    for (last.content) |cb| {
        switch (cb) {
            .text => |t| total_text_len += t.text.len,
            .tool_call => has_tool_call = true,
            else => {},
        }
    }

    // If the message has tool calls, the model was productive — no nudge.
    if (has_tool_call) return false;

    // Decide whether to nudge based on stop_reason and content.
    const should_nudge = switch (stop) {
        // Token-limit: strongest signal — the model was writing and got cut off.
        .length => true,
        // Clean stop with very little content: model "gave up".
        .stop => total_text_len < 50,
        else => false,
    };
    if (!should_nudge) return false;

    const nudge_text = if (stop == .length)
        "You were cut off mid-response (token limit reached). Continue from where you left off."
    else
        "Your response was very brief. Please continue or elaborate.";

    const text_dup = try allocator.dupe(u8, nudge_text);
    errdefer allocator.free(text_dup);

    const content = try allocator.alloc(ai.types.ContentBlock, 1);
    errdefer allocator.free(content);
    content[0] = .{ .text = .{ .text = text_dup } };

    try transcript.append(.{
        .role = .user,
        .content = content,
        .timestamp = ai.stream.nowMillis(),
    });
    // Ownership of text_dup and content is now the transcript's.
    return true;
}

/// v2.28 — inspect the last assistant message and inject a "please call
/// finish_task" user-role nudge if the model appears to be done with its
/// work (natural .stop, substantive content, no tool calls). Waits 1 s
/// before injecting to avoid racing past the model's own next turn.
/// Returns true when a nudge was appended, false otherwise.
fn maybeNudgeToFinishTask(
    allocator: std.mem.Allocator,
    io: std.Io,
    transcript: *Transcript,
) !bool {
    const msgs = transcript.messages.items;
    if (msgs.len == 0) return false;

    const last = msgs[msgs.len - 1];
    if (last.role != .assistant) return false;

    const stop = last.stop_reason orelse return false;

    // Only nudge on clean .stop (not length, tool_use, refusal, etc.).
    if (stop != .stop) return false;

    // Count text content and check for tool calls.
    var total_text_len: usize = 0;
    var has_tool_call = false;
    for (last.content) |cb| {
        switch (cb) {
            .text => |t| total_text_len += t.text.len,
            .tool_call => has_tool_call = true,
            else => {},
        }
    }

    // If the message already has tool calls, the model is productive — no nudge.
    if (has_tool_call) return false;

    // Only nudge when there is substantive content (model looks done).
    // Models that barely produce anything don't get the finish-task prompt.
    if (total_text_len < 50) return false;

    // Wait 1 s before injecting. This gives the model a moment in case
    // the loop is racing past a tool-call response the reducer didn't
    // parse. Best-effort: if the sleep fails we continue anyway.
    io.sleep(.fromMilliseconds(1000), .awake) catch {};

    const nudge_text = "Are you done? If so, please call finish_task to signal completion.";

    const text_dup = try allocator.dupe(u8, nudge_text);
    errdefer allocator.free(text_dup);

    const content = try allocator.alloc(ai.types.ContentBlock, 1);
    errdefer allocator.free(content);
    content[0] = .{ .text = .{ .text = text_dup } };

    try transcript.append(.{
        .role = .user,
        .content = content,
        .timestamp = ai.stream.nowMillis(),
    });
    return true;
}

/// v2.29 — inspect the last assistant message and inject a "Continue
/// until you are done and then call finish task" user-role nudge if the
/// model appears to be done (any stop_reason except err/aborted/refusal)
/// but did NOT call finish_task. Broader than `maybeNudgeToFinishTask` —
/// also fires after tool-call turns. Caps at 2 per session.
fn maybeNudgeAutoContinue(
    allocator: std.mem.Allocator,
    transcript: *Transcript,
) !bool {
    const msgs = transcript.messages.items;
    if (msgs.len == 0) return false;

    const last = msgs[msgs.len - 1];
    if (last.role != .assistant) return false;

    const stop = last.stop_reason orelse return false;

    // Don't nudge on explicit error / aborted / refusal.
    if (stop == .err or stop == .aborted or stop == .refusal) return false;

    // Check whether the last message has any text content.
    var total_text_len: usize = 0;
    var has_finish_task = false;
    for (last.content) |cb| {
        switch (cb) {
            .text => |t| total_text_len += t.text.len,
            .tool_call => |tc| {
                // If the model already called finish_task, skip.
                if (std.mem.eql(u8, tc.name, "finish_task")) has_finish_task = true;
            },
            else => {},
        }
    }

    if (has_finish_task) return false;

    // Only nudge when there is substantive content.
    if (total_text_len < 30) return false;

    const nudge_text = "Continue until you are done and then call finish task.";

    const text_dup = try allocator.dupe(u8, nudge_text);
    errdefer allocator.free(text_dup);

    const content = try allocator.alloc(ai.types.ContentBlock, 1);
    errdefer allocator.free(content);
    content[0] = .{ .text = .{ .text = text_dup } };

    try transcript.append(.{
        .role = .user,
        .content = content,
        .timestamp = ai.stream.nowMillis(),
    });
    // Ownership of text_dup and content is now the transcript's.
    return true;
}

/// Run one turn. Returns true if the caller should loop again, false to stop.
fn runTurn(
    allocator: std.mem.Allocator,
    io: std.Io,
    transcript: *Transcript,
    config: Config,
    out: *AgentChannel,
    http_client: ?*anyopaque,
) !bool {
    try out.push(io, .turn_start);
    ai.log.log(.debug, "turn", "start", "messages_in_transcript={d}", .{transcript.messages.items.len});

    // Build context from messages.
    var llm_messages = try config.convert_to_llm(allocator, transcript.messages.items);
    errdefer {
        for (llm_messages) |*m| m.deinit(allocator);
        allocator.free(llm_messages);
    }
    // v3.0 — optional tool-result offloading before sending to the LLM.
    if (config.max_full_tool_results > 0) {
        const offloaded = try offloadToolResults(allocator, io, llm_messages, config.max_full_tool_results, config.offload_dir);
        for (llm_messages) |*m| m.deinit(allocator);
        allocator.free(llm_messages);
        llm_messages = offloaded;
        // errdefer already captures the new slice.
    }
    if (ai.log.enabledForScope(.trace, "message")) {
        for (llm_messages, 0..) |m, i| {
            logMessageTrace("send", i, m);
        }
    }
    // Clone tools into the Context tools slice.
    const tools_ctx = try cloneTools(allocator, config.tools);
    errdefer {
        for (tools_ctx) |t| t.deinit(allocator);
        allocator.free(tools_ctx);
    }
    const context: ai.types.Context = .{
        .system_prompt = try allocator.dupe(u8, config.system_prompt),
        .messages = llm_messages,
        .tools = tools_ctx,
    };
    var ctx_mut = context;
    defer ctx_mut.deinit(allocator);

    // Call provider via registry, draining into a Reducer while forwarding
    // deltas as agent events.
    var stream_ch = try streamChannel(allocator);
    defer stream_ch.deinit();

    var opts = config.stream_options;
    opts.cancel = config.cancel;

    try config.registry.stream(.{
        .allocator = allocator,
        .io = io,
        .model = config.model,
        .context = context,
        .options = opts,
        .out = &stream_ch,
        .http_client = http_client,
    });

    // Diagnostic — channel usage during the synchronous stream that just
    // completed. Because the provider pushes all events before the drain
    // loop starts, the watermark at this point is the true peak. Log a
    // warning at ≥75 % so operators can increase capacity before a future
    // turn with more events hits 100 % and deadlocks.
    // See docs/limits/stream-channel-capacity.md for full analysis.
    {
        const sc_used = stream_ch.len;
        const sc_cap  = stream_ch.capacity;
        if (sc_used * 4 >= sc_cap * 3) {
            ai.log.log(
                .warn, "loop", "stream_channel_high_watermark",
                "events={d}/{d} ({d}%) — approaching deadlock threshold; see docs/limits/stream-channel-capacity.md",
                .{ sc_used, sc_cap, sc_used * 100 / sc_cap },
            );
        } else {
            ai.log.log(
                .debug, "loop", "stream_channel_usage",
                "events={d}/{d} ({d}%)",
                .{ sc_used, sc_cap, sc_used * 100 / sc_cap },
            );
        }
    }

    try out.push(io, .{ .message_start = .{ .role = .assistant } });

    var reducer = ai.stream.Reducer.init(allocator);
    defer reducer.deinit();

    var provider_error: ?ai.errors.ErrorDetails = null;
    while (stream_ch.next(io)) |ev| {
        reducer.apply(ev) catch |e| {
            ev.deinit(allocator);
            return e;
        };
        switch (ev) {
            .text_delta => |d| {
                // Re-dupe into agent event so stream deinit doesn't free
                // what the downstream consumer still needs.
                const copied = try allocator.dupe(u8, d.delta);
                try out.push(io, .{ .message_update = .{ .text = .{
                    .block_index = d.block_index,
                    .delta = copied,
                } } });
            },
            .thinking_delta => |d| {
                if (!d.is_signature) {
                    const copied = try allocator.dupe(u8, d.delta);
                    try out.push(io, .{ .message_update = .{ .thinking = .{
                        .block_index = d.block_index,
                        .delta = copied,
                    } } });
                }
            },
            .toolcall_delta => |d| {
                const copied = try allocator.dupe(u8, d.args_delta);
                try out.push(io, .{ .message_update = .{ .toolcall_args = .{
                    .block_index = d.block_index,
                    .delta = copied,
                } } });
            },
            .error_ev => |e| {
                // Snapshot the details here (before ev.deinit frees them)
                // so we can forward them as `agent_error` after the drain.
                provider_error = .{
                    .code = e.code,
                    .message = try allocator.dupe(u8, e.message),
                    .http_status = e.http_status,
                    .retry_after_ms = e.retry_after_ms,
                };
            },
            .provider_retry => |r| {
                try out.push(io, .{ .provider_retry = .{
                    .attempt = r.attempt,
                    .max_attempts = r.max_attempts,
                    .delay_ms = r.delay_ms,
                    .reason = r.reason,
                } });
            },
            else => {},
        }
        ev.deinit(allocator);
    }

    if (provider_error) |pe| {
        try pushAgentError(out, io, allocator, pe.code, pe.message);
        allocator.free(pe.message);
        return false;
    }

    // v1.29.0 — if `finalize` is about to emit a degenerate
    // assistant message AND a dump dir is configured, snapshot
    // the reducer's full internal state to
    // `<dump_dir>/<turn-N>.reducer-dump.json`. After-the-fact
    // readers can inspect block_order, every text/thinking/tool
    // buffer, and the diagnostic counters without needing a live
    // repro. Best-effort: any IO error is swallowed since the
    // primary path (saving the assistant message) must not be
    // blocked by a debug-aid failure.
    if (config.reducer_dump_dir) |dump_dir| {
        if (reducer.isLikelyDegenerate()) {
            dumpReducerSnapshot(allocator, io, dump_dir, transcript.messages.items.len, &reducer);
        }
    }

    var assistant_msg = try reducer.finalize(
        config.model.provider,
        config.model.id,
        config.model.api,
    );
    // v1.16.3 — text-tool-call fallback: some gateway/model combos
    // (Cloudflare's openai-compat shim with Llama, the native CF
    // endpoint with any model) deliver tool calls as text content
    // rather than structured `tool_calls[]`. When the user opts in,
    // we attempt to parse the text as a recognized tool-call shape
    // and rewrite the message in-place before broadcasting it, so
    // both the UI and the transcript see a normal tool_call event.
    if (config.text_tool_call_fallback) {
        maybeApplyTextToolCallFallback(allocator, &assistant_msg, config.tools) catch |e| {
            ai.log.log(.debug, "loop", "text_tool_fallback_failed", "err={s}", .{@errorName(e)});
        };
    }
    // Unconditional DSML-in-thinking scan: DeepSeek via Ollama embeds tool
    // calls inside reasoning_content (thinking blocks) using DSML markup
    // instead of the standard tool_calls[] array.  The DSML tag format is
    // specific enough (Unicode fullwidth vbars) that false positives are
    // impossible in practice so no opt-in flag is needed.
    maybeApplyDsmlThinkingFallback(allocator, &assistant_msg, config.tools) catch |e| {
        ai.log.log(.debug, "loop", "dsml_thinking_fallback_failed", "err={s}", .{@errorName(e)});
    };

    // vNEXT — v1.28.2 — repair concatenated-JSON tool-call args in
    // the assistant message before it enters the transcript. Some
    // models emit `{"path":"a"}{"path":"b"}` when calling read/ls;
    // the raw broken JSON is rejected by providers (request_invalid)
    // on the next turn. Repairing here ensures both the transcript
    // and the UI see a valid single-object arguments_json.
    repairToolCallArgsInMessage(allocator, &assistant_msg) catch |e| {
        ai.log.log(.debug, "loop", "repair_tool_args_failed", "err={s}", .{@errorName(e)});
    };

    // Push a duplicate into the event and keep the original for transcript.
    try out.push(io, .{ .message_end = try dupeMessage(allocator, assistant_msg) });
    if (ai.log.enabledForScope(.trace, "message")) logMessageTrace("recv", 0, assistant_msg);
    try transcript.append(assistant_msg);

    // Extract tool calls from the assistant message.
    var tool_calls: std.ArrayList(ai.types.ToolCall) = .empty;
    defer tool_calls.deinit(allocator);
    for (assistant_msg.content) |cb| switch (cb) {
        .tool_call => |tc| try tool_calls.append(allocator, tc),
        else => {},
    };

    if (tool_calls.items.len == 0) {
        try out.push(io, .turn_end);
        // No tools → we stop (no steering/follow-up machinery in MVP).
        return false;
    }

    // Execute tools. Collect results in source order.
    var results: std.ArrayList(ToolCallResult) = .empty;
    defer {
        for (results.items) |*r| r.result.deinit(allocator);
        results.deinit(allocator);
    }

    // §4.4 parallel dispatch (v0.5.0): when every tool in the batch
    // is parallel-safe, spawn a native thread per call and join them
    // in source order. Wall-time drops from Σ individual to
    // max(individual) for I/O-bound tools (read/grep/find/ls).
    // Any sequential tool in the batch forces the fallback path so
    // write/edit/bash serialization is preserved.
    const all_parallel = blk: {
        if (tool_calls.items.len <= 1) break :blk false;
        for (tool_calls.items) |tc| {
            const td = findTool(config.tools, tc.name) orelse break :blk false;
            if (td.execution_mode != .parallel) break :blk false;
        }
        break :blk true;
    };

    if (all_parallel) {
        try runToolsParallel(
            allocator,
            io,
            config,
            tool_calls.items,
            out,
            &results,
        );
    } else for (tool_calls.items) |tc| {
        const maybe_tool = findTool(config.tools, tc.name);
        if (maybe_tool == null) {
            const r = blk: {
                if (config.role_denied) |fn_| {
                    if (fn_(roleDeniedUserdata(&config), tc.name)) |denial| {
                        break :blk try makeRoleDeniedResult(allocator, tc.name, denial);
                    }
                }
                break :blk try makeErrorResult(allocator, "unknown tool");
            };
            try pushToolStart(out, io, allocator, tc.id, tc.name, tc.arguments_json);
            try pushToolEnd(out, io, allocator, tc.id, null, r);
            try results.append(allocator, .{ .call_id = tc.id, .result = r, .terminate = false });
            continue;
        }
        const tool_def = maybe_tool.?;

        // beforeToolCall
        if (config.before_tool_call) |hook| {
            const dec = hook(beforeToolCallUserdata(&config), &tool_def, tc.id, tc.arguments_json);
            if (dec.block) {
                const reason = dec.reason_text orelse "blocked by beforeToolCall";
                const r = try makeErrorResult(allocator, reason);
                try pushToolStart(out, io, allocator, tc.id, tool_def.name, tc.arguments_json);
                try pushToolEnd(out, io, allocator, tc.id, tool_def, r);
                try results.append(allocator, .{ .call_id = tc.id, .result = r, .terminate = false });
                continue;
            }
        }

        if (config.guardrails) |gr| gr.cacheArgs(tc.id, tc.arguments_json) catch {};

        try pushToolStart(out, io, allocator, tc.id, tool_def.name, tc.arguments_json);

        const on_update: at.OnUpdate = .{};
        var call_res = tool_def.execute(
            &tool_def,
            allocator,
            io,
            tc.id,
            tc.arguments_json,
            config.cancel,
            on_update,
        ) catch |e| blk: {
            // v1.16.3 — until v1.16.3 the model received bare error
            // tags like "SyntaxError" with no context. Now it gets
            // the tool name, the error tag, a hint about the most
            // common cause (JSON parse), and the first ~200 bytes of
            // the args it sent — enough signal to retry with a
            // corrected call.
            const detail = formatToolExecutionError(
                allocator,
                tool_def.name,
                e,
                tc.arguments_json,
            ) catch try allocator.dupe(u8, @errorName(e));
            defer allocator.free(detail);
            break :blk try makeErrorResult(allocator, detail);
        };

        if (config.after_tool_call) |hook| {
            hook(config.hook_userdata, &tool_def, tc.id, &call_res);
        }

        if (config.guardrails) |gr| gr.afterToolCall(&tool_def, tc.id, &call_res);

        // v3.0 — compress tool result before emitting to transcript
        if (config.compression) |cc| {
            if (cc.enabled and call_res.content.len > 0) {
                var old = call_res;
                call_res = compression_mod.compressToolResult(allocator, &old, cc, config.ccr_store, config.compression_stats);
                old.deinit(allocator);
            }
        }

        try pushToolEnd(out, io, allocator, tc.id, tool_def, call_res);
        try results.append(allocator, .{
            .call_id = tc.id,
            .result = call_res,
            .terminate = call_res.terminate,
        });
    }

    // Emit toolResult messages in source order; append to transcript.
    var all_terminate = true;
    for (results.items) |r| {
        if (!r.terminate) all_terminate = false;
        const tr_msg = try makeToolResultMessage(allocator, r);
        try out.push(io, .{ .message_start = .{ .role = .tool_result } });
        try out.push(io, .{ .message_end = try dupeMessage(allocator, tr_msg) });
        if (ai.log.enabledForScope(.trace, "message")) logMessageTrace("result", 0, tr_msg);
        try transcript.append(tr_msg);
    }

    ai.log.log(.debug, "turn", "end", "tools_executed={d} all_terminate={}", .{ results.items.len, all_terminate });
    try out.push(io, .turn_end);

    // Per §4.4 early-termination rule: stop if every finalized result had
    // terminate=true.
    if (all_terminate) return false;
    return true;
}

const ToolCallResult = struct {
    call_id: []const u8, // borrowed from assistant content
    result: at.ToolResult,
    terminate: bool,
};

/// Parallel-batch worker (v0.5.0). Every worker thread runs a single
/// `tool_def.execute`; the main thread drives `tool_execution_start`
/// events (emitted before spawn so consumers see them eagerly),
/// joins each worker in source order, and emits
/// `tool_execution_end` as each join completes.
const ParWork = struct {
    tc: ai.types.ToolCall,
    tool_def: at.AgentTool,
    allocator: std.mem.Allocator,
    io: std.Io,
    cancel: *ai.stream.Cancel,
    /// Populated by the worker thread; `err_name` wins if execute
    /// threw. Exactly one of the two fields is set on return.
    out_result: ?at.ToolResult = null,
    err_name: ?[]const u8 = null,
    /// v1.7.3 — flipped true by the worker right before return.
    /// Main thread polls this to emit `tool_execution_end` in
    /// completion order (§4.4).
    done_flag: std.atomic.Value(bool) = .init(false),
};

fn parallelWorker(w: *ParWork) void {
    defer w.done_flag.store(true, .release);
    const r = w.tool_def.execute(
        &w.tool_def,
        w.allocator,
        w.io,
        w.tc.id,
        w.tc.arguments_json,
        w.cancel,
        .{},
    ) catch |e| {
        w.err_name = @errorName(e);
        return;
    };
    w.out_result = r;
}

fn runToolsParallel(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: Config,
    tool_calls: []const ai.types.ToolCall,
    out: *AgentChannel,
    results: *std.ArrayList(ToolCallResult),
) !void {
    const n = tool_calls.len;

    // beforeToolCall hooks: run on the main thread so hook state is
    // single-threaded (hooks can veto a call; a vetoed call never
    // spawns a worker).
    var workers = try allocator.alloc(ParWork, n);
    defer allocator.free(workers);
    var vetoed = try allocator.alloc(?at.ToolResult, n);
    defer allocator.free(vetoed);
    for (vetoed) |*v| v.* = null;

    for (tool_calls, 0..) |tc, i| {
        const tool_def = findTool(config.tools, tc.name).?;
        if (config.before_tool_call) |hook| {
            const dec = hook(beforeToolCallUserdata(&config), &tool_def, tc.id, tc.arguments_json);
            if (dec.block) {
                const reason = dec.reason_text orelse "blocked by beforeToolCall";
                vetoed[i] = try makeErrorResult(allocator, reason);
            }
        }
        if (config.guardrails) |gr| gr.cacheArgs(tc.id, tc.arguments_json) catch {};
        workers[i] = .{
            .tc = tc,
            .tool_def = tool_def,
            .allocator = allocator,
            .io = io,
            .cancel = config.cancel,
        };
    }

    // Emit start events in source order — this is the consumer's first
    // signal that a given call_id is in flight.
    for (tool_calls) |tc| {
        const tool_def = findTool(config.tools, tc.name).?;
        try pushToolStart(out, io, allocator, tc.id, tool_def.name, tc.arguments_json);
    }

    // Spawn one thread per non-vetoed call.
    var threads = try allocator.alloc(?std.Thread, n);
    defer allocator.free(threads);
    for (threads) |*t| t.* = null;

    for (workers, 0..) |*w, i| {
        if (vetoed[i] != null) continue;
        threads[i] = try std.Thread.spawn(.{}, parallelWorker, .{w});
    }

    // v1.7.3 §4.4: poll `done_flag` atomics until every non-vetoed
    // worker has flipped. Emit `tool_execution_end` in completion
    // order (the order flags flip) so the UI sees real-time
    // progress. Results get collected into a source-indexed slot
    // array so the transcript assembly below stays deterministic
    // regardless of which tool finished first.
    var slot_results = try allocator.alloc(?at.ToolResult, n);
    defer allocator.free(slot_results);
    for (slot_results) |*s| s.* = null;
    var emitted = try allocator.alloc(bool, n);
    defer allocator.free(emitted);
    @memset(emitted, false);

    // Vetoed calls complete instantly — emit their end events first
    // so their "completion time" is t=0 (which matches the user's
    // intuition: a blocked call never actually ran).
    for (workers, 0..) |*w, i| {
        if (vetoed[i]) |veto_res| {
            try pushToolEnd(out, io, allocator, w.tc.id, w.tool_def, veto_res);
            slot_results[i] = veto_res;
            emitted[i] = true;
        }
    }

    var remaining: usize = 0;
    for (vetoed) |v| if (v == null) {
        remaining += 1;
    };

    while (remaining > 0) {
        var progress = false;
        for (workers, 0..) |*w, i| {
            if (emitted[i]) continue;
            if (!w.done_flag.load(.acquire)) continue;

            // This worker has completed. Join + process.
            threads[i].?.join();
            var call_res: at.ToolResult = if (w.out_result) |r|
                r
            else
                try makeErrorResult(allocator, w.err_name orelse "tool failed");
            if (config.after_tool_call) |hook| {
                hook(config.hook_userdata, &w.tool_def, w.tc.id, &call_res);
            }
            if (config.guardrails) |gr| gr.afterToolCall(&w.tool_def, w.tc.id, &call_res);

            // v3.0 — compress tool result before emitting to transcript
            if (config.compression) |cc| {
                if (cc.enabled and call_res.content.len > 0) {
                    var old = call_res;
                    call_res = compression_mod.compressToolResult(allocator, &old, cc, config.ccr_store, config.compression_stats);
                    old.deinit(allocator);
                }
            }

            try pushToolEnd(out, io, allocator, w.tc.id, w.tool_def, call_res);
            slot_results[i] = call_res;
            emitted[i] = true;
            remaining -= 1;
            progress = true;
        }
        if (!progress) io.sleep(.fromMilliseconds(1), .awake) catch {};
    }

    // Results appended in source order — preserves the
    // deterministic-transcript invariant under parallel execution
    // (see CLAUDE.md "Design invariants").
    for (workers, 0..) |*w, i| {
        const call_res = slot_results[i].?;
        try results.append(allocator, .{
            .call_id = w.tc.id,
            .result = call_res,
            .terminate = call_res.terminate,
        });
    }
}

fn streamChannel(allocator: std.mem.Allocator) !ai.channel.Channel(ai.stream.StreamEvent) {
    // Provider-to-reducer buffer. The provider's streamFn pushes every
    // SSE delta synchronously (whole response is buffered first) and the
    // drain loop runs on the same thread — so this ring must fit the
    // entire turn's event stream without ever blocking on push, because
    // blocking = deadlock.
    //
    // Event budget per turn (worst observed: DeepSeek-v4-flash:cloud):
    //   ~1 000 thinking_delta  (reasoning phase)
    //   ~4 000 text_delta      (content phase, ~4 K tokens)
    //   + start / done / diagnostic + misc overhead
    //   ≈ 5 300 events total
    //
    // 16 384 gives a 3× safety margin over the observed ~5 300 event
    // peak. Interactive mode uses 4 096 without blocking, confirming
    // the consumer side is fast enough; 16 384 is conservative.
    // Memory cost is ~5.5 MB at 352 B/slot vs 22 MB at 65 536.
    return try ai.channel.Channel(ai.stream.StreamEvent).initWithDrop(
        allocator,
        16384,
        ai.stream.StreamEvent.deinit,
        allocator,
    );
}

fn findTool(tools: []const at.AgentTool, name: []const u8) ?at.AgentTool {
    for (tools) |t| {
        if (std.mem.eql(u8, t.name, name)) return t;
    }
    return null;
}

fn pushToolStart(
    out: *AgentChannel,
    io: std.Io,
    allocator: std.mem.Allocator,
    call_id: []const u8,
    name: []const u8,
    args_json: []const u8,
) !void {
    try out.push(io, .{ .tool_execution_start = .{
        .call_id = try allocator.dupe(u8, call_id),
        .name = try allocator.dupe(u8, name),
        .args_json = try allocator.dupe(u8, args_json),
    } });
}

fn pushToolEnd(
    out: *AgentChannel,
    io: std.Io,
    allocator: std.mem.Allocator,
    call_id: []const u8,
    tool_def: ?at.AgentTool,
    result: at.ToolResult,
) !void {
    _ = tool_def;
    var copied_content: std.ArrayList(ai.types.ContentBlock) = .empty;
    errdefer {
        for (copied_content.items) |cb| cb.deinit(allocator);
        copied_content.deinit(allocator);
    }
    for (result.content) |cb| try copied_content.append(allocator, try cb.dupe(allocator));
    const owned_details = if (result.details_json) |d| try allocator.dupe(u8, d) else null;
    const owned_tool_code = if (result.tool_code) |t| try allocator.dupe(u8, t) else null;
    try out.push(io, .{ .tool_execution_end = .{
        .call_id = try allocator.dupe(u8, call_id),
        .result = .{
            .content = try copied_content.toOwnedSlice(allocator),
            .details_json = owned_details,
            .is_error = result.is_error,
            .terminate = result.terminate,
            .tool_code = owned_tool_code,
        },
    } });
}

fn makeToolResultMessage(
    allocator: std.mem.Allocator,
    r: ToolCallResult,
) !ai.types.Message {
    var copied: std.ArrayList(ai.types.ContentBlock) = .empty;
    errdefer {
        for (copied.items) |cb| cb.deinit(allocator);
        copied.deinit(allocator);
    }
    for (r.result.content) |cb| {
        const block: ai.types.ContentBlock = switch (cb) {
            .text => |t| blk: {
                if (t.text.len <= truncate.tool_result_max_bytes) break :blk try cb.dupe(allocator);
                // Slice at UTF-8 boundary, then append a size marker so the
                // model knows content was dropped.
                var end = truncate.tool_result_max_bytes;
                while (end > 0 and (t.text[end] & 0xc0) == 0x80) end -= 1;
                const size_str = try truncate.formatSize(allocator, t.text.len);
                defer allocator.free(size_str);
                const text = try std.fmt.allocPrint(
                    allocator,
                    "{s}\n[...{s} truncated]",
                    .{ t.text[0..end], size_str },
                );
                break :blk .{ .text = .{ .text = text } };
            },
            else => try cb.dupe(allocator),
        };
        try copied.append(allocator, block);
    }
    return .{
        .role = .tool_result,
        .content = try copied.toOwnedSlice(allocator),
        .timestamp = ai.stream.nowMillis(),
        .tool_call_id = try allocator.dupe(u8, r.call_id),
        .is_error = r.result.is_error,
    };
}

fn makeErrorResult(allocator: std.mem.Allocator, text: []const u8) !at.ToolResult {
    const cb = ai.types.ContentBlock{ .text = .{ .text = try allocator.dupe(u8, text) } };
    const arr = try allocator.alloc(ai.types.ContentBlock, 1);
    arr[0] = cb;
    return .{ .content = arr, .is_error = true };
}

/// v3.0 — offload early tool-result messages to compact placeholders.
/// Keeps only the `keep` most recent tool-result messages with full
/// content. Older ones are replaced with a single text block:
/// "[tool result: <tool-call-id> — <size> (offloaded)]".
/// Non-tool-result messages pass through unchanged.
fn offloadToolResults(
    allocator: std.mem.Allocator,
    io: std.Io,
    messages: []const ai.types.Message,
    keep: u32,
    offload_dir: ?[]const u8,
) ![]ai.types.Message {
    // First pass: count tool-result messages so we know which are old.
    var tr_count: u32 = 0;
    for (messages) |m| {
        if (m.role == .tool_result) tr_count += 1;
    }
    if (tr_count <= keep) {
        // Nothing to offload — dupe the whole slice.
        var out = try allocator.alloc(ai.types.Message, messages.len);
        errdefer {
            for (out[0..messages.len]) |*m| m.deinit(allocator);
            allocator.free(out);
        }
        for (messages, 0..) |m, i| out[i] = try dupeMessage(allocator, m);
        return out;
    }

    // Second pass: mark which tool results to offload.
    var to_offload = try allocator.alloc(bool, messages.len);
    defer allocator.free(to_offload);
    @memset(to_offload, false);
    {
        var seen: u32 = 0;
        var i = messages.len;
        while (i > 0) {
            i -= 1;
            if (messages[i].role == .tool_result) {
                if (seen >= keep) {
                    to_offload[i] = true;
                }
                seen += 1;
            }
        }
    }

    // Ensure the offload directory exists.
    if (offload_dir) |dir| {
        std.Io.Dir.cwd().createDirPath(io, dir) catch |err| {
            ai.log.log(.warn, "loop", "offload_mkdir",
                "failed to create offload dir '{s}': {s}",
                .{ dir, @errorName(err) },
            );
        };
    }

    // Third pass: allocate and fill.
    var out = try allocator.alloc(ai.types.Message, messages.len);
    errdefer {
        for (out[0..messages.len]) |*m| m.deinit(allocator);
        allocator.free(out);
    }
    for (messages, 0..) |m, i| {
        if (to_offload[i]) {
            // Compute original size across all text content blocks.
            var total_size: usize = 0;
            for (m.content) |cb| switch (cb) {
                .text => |t| total_size += t.text.len,
                else => {},
            };
            const call_id = m.tool_call_id orelse "?";
            const size_str = try truncate.formatSize(allocator, total_size);
            defer allocator.free(size_str);

            // Write full content to offload file if a directory is configured.
            var file_path: ?[]const u8 = null;
            if (offload_dir) |dir| {
                const seq = synth_tool_id_seq.fetchAdd(1, .monotonic);
                const filename = try std.fmt.allocPrint(allocator, "tool-{s}-s{x:0>8}.txt", .{ call_id, seq });
                defer allocator.free(filename);
                const full_path = try std.fs.path.join(allocator, &.{ dir, filename });
                defer allocator.free(full_path);
                // Concatenate all text content blocks into a single blob.
                var text_parts: std.ArrayList(u8) = .empty;
                defer text_parts.deinit(allocator);
                for (m.content) |cb| switch (cb) {
                    .text => |t| try text_parts.appendSlice(allocator, t.text),
                    else => {},
                };
                if (std.Io.Dir.cwd().writeFile(io, .{
                    .sub_path = full_path,
                    .data = text_parts.items,
                })) {
                    file_path = try allocator.dupe(u8, full_path);
                } else |err| {
                    ai.log.log(.warn, "loop", "offload_write",
                        "failed to write offload file '{s}': {s}",
                        .{ full_path, @errorName(err) },
                    );
                }
            }

            const placeholder = if (file_path) |fp|
                try std.fmt.allocPrint(
                    allocator,
                    "[tool result: {s} — {s} (offloaded) — see {s}]",
                    .{ call_id, size_str, fp },
                )
            else
                try std.fmt.allocPrint(
                    allocator,
                    "[tool result: {s} — {s} (offloaded)]",
                    .{ call_id, size_str },
                );
            errdefer allocator.free(placeholder);

            var content = try allocator.alloc(ai.types.ContentBlock, 1);
            errdefer allocator.free(content);
            content[0] = .{ .text = .{ .text = placeholder } };
            out[i] = .{
                .role = .tool_result,
                .content = content,
                .timestamp = m.timestamp,
                .tool_call_id = try allocator.dupe(u8, call_id),
                .is_error = false,
            };
        } else {
            out[i] = try dupeMessage(allocator, m);
        }
    }
    return out;
}

/// v1.16.3 — render a model-facing message for an exception that
/// escaped from a tool's `execute()`. Until v1.16.3 the agent loop
/// just sent the bare Zig error name (e.g. `"SyntaxError"`) as the
/// tool result content. The model couldn't tell *what* went wrong
/// or *why*, so it had no signal to retry with corrected args.
///
/// The new message includes:
/// - the tool name (so the model knows which call failed),
/// - the error tag (`@errorName`),
/// - a best-guess hint for the most common cause (JSON parse),
/// - the first ~200 bytes of the args the model sent, so it can
///   see what got rejected and self-correct.
///
/// Owned slice; caller frees.
fn formatToolExecutionError(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    err: anyerror,
    args_json: []const u8,
) ![]u8 {
    const err_name = @errorName(err);
    const hint = if (looksLikeJsonError(err_name))
        "Tool arguments must be a single valid JSON object matching the tool's parameters schema. Re-emit the call with valid JSON."
    else
        "The tool failed unexpectedly. Re-check the arguments and try again, or pick a different approach.";

    const max_preview: usize = 200;
    const preview = if (args_json.len <= max_preview) args_json else args_json[0..max_preview];
    const ellipsis = if (args_json.len > max_preview) "...(truncated)" else "";

    return std.fmt.allocPrint(
        allocator,
        "Tool '{s}' failed: {s}. {s} Args sent (first {d} bytes): {s}{s}",
        .{ tool_name, err_name, hint, preview.len, preview, ellipsis },
    );
}

/// Heuristic: is this error name from `std.json`'s parser?
/// Substring-free: an exact-match table because std.json's error
/// surface is small and the variants are known. Adding a future
/// `error.SomethingNew` to std.json doesn't break us — it just
/// gets the generic non-JSON hint, which is still a strict
/// improvement over the pre-v1.16.3 bare-error-name behavior.
fn looksLikeJsonError(name: []const u8) bool {
    const json_markers = [_][]const u8{
        "SyntaxError",          "UnexpectedToken",
        "UnexpectedEndOfInput", "InvalidNumber",
        "InvalidEscape",        "InvalidString",
        "InvalidCharacter",     "DuplicateField",
        "MissingField",
    };
    for (json_markers) |m| {
        if (std.mem.eql(u8, name, m)) return true;
    }
    return false;
}

//  ─── vNEXT — tool-arg repair ─────────────────────────────────────

/// Repair concatenated-JSON tool-call arguments in every tool_call
/// content block of `msg`. Called before the message enters the
/// transcript so the provider never sees `{"path":"a"}{"path":"b"}`.
fn repairToolCallArgsInMessage(
    allocator: std.mem.Allocator,
    msg: *AgentMessage,
) !void {
    for (msg.content) |*cb| {
        switch (cb.*) {
            .tool_call => |*tc| {
                var arena = std.heap.ArenaAllocator.init(allocator);
                defer arena.deinit();
                if (tool_common.repairConcatJson(arena.allocator(), tc.arguments_json)) |fixed| {
                    ai.log.log(.debug, "loop", "repair_tool_args", "name={s} orig_bytes={d} fixed_bytes={d}", .{
                        tc.name, tc.arguments_json.len, fixed.len,
                    });
                    allocator.free(tc.arguments_json);
                    tc.arguments_json = try allocator.dupe(u8, fixed);
                }
            },
            else => {},
        }
    }
}

// ─── v1.16.3 — text-tool-call fallback ────────────────────────

/// Process-global counter so synthesized tool-call ids are unique
/// across concurrent turns.
// 32-bit (not u64) so atomic ops work on i386 / 32-bit ARM targets
// where 64-bit atomic RMW isn't a single-instruction primitive.
// 4 billion synthetic ids per process is plenty.
var synth_tool_id_seq: std.atomic.Value(u32) = .init(0);

/// DeepSeek via Ollama embeds tool calls inside the `reasoning_content`
/// field, which arrives as a thinking block rather than a structured
/// `tool_calls[]` array. Scan every thinking block for DSML markup; if
/// found, append a new tool_call block to `msg`. Idempotent: skips when
/// the message already carries a tool_call block.
fn maybeApplyDsmlThinkingFallback(
    allocator: std.mem.Allocator,
    msg: *AgentMessage,
    tools: []const at.AgentTool,
) !void {
    for (msg.content) |cb| switch (cb) {
        .tool_call => return,
        else => {},
    };
    for (msg.content) |cb| switch (cb) {
        .thinking => |th| {
            const extracted = (try extractDsmlToolCall(allocator, th.thinking, tools)) orelse continue;
            msg.content = try allocator.realloc(msg.content, msg.content.len + 1);
            const seq = synth_tool_id_seq.fetchAdd(1, .monotonic);
            const id = try std.fmt.allocPrint(allocator, "txtcall_{x:0>8}", .{seq});
            msg.content[msg.content.len - 1] = .{ .tool_call = .{
                .id = id,
                .name = extracted.name,
                .arguments_json = extracted.args,
            } };
            ai.log.log(.debug, "loop", "dsml_thinking_fallback_hit", "name={s} args_bytes={d}", .{
                extracted.name, extracted.args.len,
            });
            return;
        },
        else => {},
    };
}

/// Inspect `msg`. If it carries text content that parses as a
/// recognized tool-call shape AND the named tool is in `tools`,
/// rewrite the matching text block into a `tool_call` block in
/// place. Idempotent on messages that already have a tool_call.
fn maybeApplyTextToolCallFallback(
    allocator: std.mem.Allocator,
    msg: *AgentMessage,
    tools: []const at.AgentTool,
) !void {
    // Skip if the message already has a tool_call.
    for (msg.content) |cb| switch (cb) {
        .tool_call => return,
        else => {},
    };

    // Find the first text block.
    var text_idx: ?usize = null;
    for (msg.content, 0..) |cb, i| switch (cb) {
        .text => {
            text_idx = i;
            break;
        },
        else => {},
    };
    if (text_idx == null) return;

    const text = msg.content[text_idx.?].text.text;

    // Try JSON-shaped tool call first, then DeepSeek DSML markup as fallback.
    const extracted =
        (try extractTextToolCall(allocator, text, tools)) orelse
        (try extractDsmlToolCall(allocator, text, tools)) orelse
        return;

    // Replace the text block with a tool_call block. Free the old
    // text bytes; ownership of `extracted.name` / `extracted.args`
    // transfers to the new ToolCall.
    allocator.free(text);

    const seq = synth_tool_id_seq.fetchAdd(1, .monotonic);
    const id = try std.fmt.allocPrint(allocator, "txtcall_{x:0>8}", .{seq});

    msg.content[text_idx.?] = .{ .tool_call = .{
        .id = id,
        .name = extracted.name,
        .arguments_json = extracted.args,
    } };

    ai.log.log(.debug, "loop", "text_tool_fallback_hit", "name={s} args_bytes={d}", .{
        extracted.name,
        extracted.args.len,
    });
}

const ExtractedToolCall = struct {
    name: []u8,
    args: []u8,
};

/// Recognized tool-call text shapes:
///   1. `{"type": "function", "name": "X", "parameters": {...}}`
///   2. `{"name": "X", "parameters": {...}}`
///   3. `{"name": "X", "arguments": {...}}` (object)
///   4. `{"name": "X", "arguments": "..."}` (string-encoded JSON, OpenAI)
///   5. Any of the above wrapped in `<tool_call>...</tool_call>` or
///      `<|python_tag|>...`.
///
/// Returns null when:
///   - the text doesn't contain a JSON object,
///   - the JSON parses but `name` is missing or not a string,
///   - the named tool isn't in `tools`,
///   - neither `parameters` nor `arguments` is present.
fn extractTextToolCall(
    allocator: std.mem.Allocator,
    text: []const u8,
    tools: []const at.AgentTool,
) !?ExtractedToolCall {
    const inner = stripToolCallWrappers(text);
    const trimmed = std.mem.trim(u8, inner, " \t\n\r");
    if (trimmed.len == 0 or trimmed[0] != '{') return null;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        arena.allocator(),
        trimmed,
        .{},
    ) catch return null;
    if (parsed.value != .object) return null;
    const root = parsed.value.object;

    const name_val = root.get("name") orelse return null;
    if (name_val != .string) return null;
    const name = name_val.string;

    // Validate name against tool registry.
    var matched = false;
    for (tools) |t| {
        if (std.mem.eql(u8, t.name, name)) {
            matched = true;
            break;
        }
    }
    if (!matched) return null;

    // Args: prefer `parameters` (CF/Llama style), fall back to
    // `arguments` (OpenAI-string-style or legacy object).
    const args: []u8 = if (root.get("parameters")) |p|
        try std.json.Stringify.valueAlloc(allocator, p, .{})
    else if (root.get("arguments")) |a|
        if (a == .string)
            try allocator.dupe(u8, a.string)
        else
            try std.json.Stringify.valueAlloc(allocator, a, .{})
    else
        return null;
    errdefer allocator.free(args);
    const owned_name = try allocator.dupe(u8, name);

    return .{ .name = owned_name, .args = args };
}

/// Strip leading `<tool_call>` / trailing `</tool_call>` and a
/// leading `<|python_tag|>` if present. Returns a sub-slice of
/// `text`; never allocates.
fn stripToolCallWrappers(text: []const u8) []const u8 {
    var s = text;
    s = std.mem.trim(u8, s, " \t\n\r");

    const py_tag = "<|python_tag|>";
    if (std.mem.startsWith(u8, s, py_tag)) {
        s = s[py_tag.len..];
        s = std.mem.trim(u8, s, " \t\n\r");
    }

    const open = "<tool_call>";
    const close = "</tool_call>";
    if (std.mem.startsWith(u8, s, open)) {
        s = s[open.len..];
        if (std.mem.endsWith(u8, s, close)) {
            s = s[0 .. s.len - close.len];
        }
        s = std.mem.trim(u8, s, " \t\n\r");
    }

    return s;
}

// ─── DSML tool-call parser ────────────────────────────────────────────────────
//
// DeepSeek V3.2 / V4 embed tool invocations as markup in the assistant's text
// output rather than as structured `tool_calls[]` JSON.  The delimiter is
// U+FF5C FULLWIDTH VERTICAL LINE, giving tags like:
//
//   <｜DSML｜tool_calls>
//   <｜DSML｜invoke name="read">
//   <｜DSML｜parameter name="path" string="true">/path/to/file
//
// `extractDsmlToolCall` detects this shape, converts the first <invoke> block
// into an ExtractedToolCall, and leaves the JSON/wrapper path as a fallback.

/// U+FF5C FULLWIDTH VERTICAL LINE (UTF-8: 0xEF 0xBD 0x9C).
const dsml_vbar = "\xef\xbd\x9c";
/// Common prefix for all DSML tags: "<｜DSML｜"
const dsml_open = "<" ++ dsml_vbar ++ "DSML" ++ dsml_vbar;
const dsml_invoke_tag = dsml_open ++ "invoke ";
const dsml_param_tag = dsml_open ++ "parameter ";
/// Closing tag prefix: "</|DSML|" — matches </|DSML|parameter>, </|DSML|invoke>, </|DSML|tool_calls>.
const dsml_close_tag = "<" ++ "/" ++ dsml_vbar ++ "DSML" ++ dsml_vbar;

/// Parses the first DSML `<invoke>` block found in `text`.
/// Returns null when no DSML markup is present or the tool name is not in `tools`.
fn extractDsmlToolCall(
    allocator: std.mem.Allocator,
    text: []const u8,
    tools: []const at.AgentTool,
) !?ExtractedToolCall {
    if (std.mem.indexOf(u8, text, dsml_open) == null) return null;

    const invoke_pos = std.mem.indexOf(u8, text, dsml_invoke_tag) orelse return null;
    const after_kw = text[invoke_pos + dsml_invoke_tag.len..];

    const name = dsmlAttr(after_kw, "name") orelse return null;

    var matched = false;
    for (tools) |t| {
        if (std.mem.eql(u8, t.name, name)) { matched = true; break; }
    }
    if (!matched) return null;

    const gt = std.mem.indexOf(u8, after_kw, ">") orelse return null;
    const param_region = after_kw[gt + 1..];

    // Build JSON args object from parameter tags.
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, '{');

    var pos: usize = 0;
    var first = true;
    while (std.mem.indexOfPos(u8, param_region, pos, dsml_param_tag)) |pstart| {
        const rest = param_region[pstart + dsml_param_tag.len..];
        const pname = dsmlAttr(rest, "name") orelse { pos = pstart + 1; continue; };
        const ptype = dsmlParamType(rest);
        const pgt = std.mem.indexOf(u8, rest, ">") orelse { pos = pstart + 1; continue; };
        const val_s = pgt + 1;
        const val_e = blk: {
            const n_open = std.mem.indexOf(u8, rest[val_s..], dsml_open);
            const n_close = std.mem.indexOf(u8, rest[val_s..], dsml_close_tag);
            const n = if (n_open) |a| if (n_close) |b| @min(a, b) else a else n_close;
            break :blk if (n) |nn| val_s + nn else rest.len;
        };
        const raw = std.mem.trim(u8, rest[val_s..val_e], " \t\n\r");

        if (!first) try buf.append(allocator, ',');
        first = false;
        try buf.append(allocator, '"');
        try dsmlJsonStr(&buf, allocator, pname);
        try buf.appendSlice(allocator, "\":");
        switch (ptype) {
            .string => {
                try buf.append(allocator, '"');
                try dsmlJsonStr(&buf, allocator, raw);
                try buf.append(allocator, '"');
            },
            else => try buf.appendSlice(allocator, raw),
        }
        pos = pstart + dsml_param_tag.len + val_e;
    }
    try buf.append(allocator, '}');

    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    return .{ .name = owned_name, .args = try buf.toOwnedSlice(allocator) };
}

/// Extract the value of `attr="..."` from an attribute string.
/// Requires `attr` to appear at position 0 or preceded by whitespace.
fn dsmlAttr(s: []const u8, attr: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, s, i, attr)) |p| {
        const ok = p == 0 or s[p - 1] == ' ' or s[p - 1] == '\t';
        if (ok) {
            const tail = s[p + attr.len..];
            if (tail.len >= 2 and tail[0] == '=' and tail[1] == '"') {
                const vs = p + attr.len + 2;
                const ve = std.mem.indexOfPos(u8, s, vs, "\"") orelse return null;
                return s[vs..ve];
            }
        }
        i = p + 1;
    }
    return null;
}

const DsmlParamType = enum { string, number, boolean, object, array };

fn dsmlParamType(rest: []const u8) DsmlParamType {
    const end = std.mem.indexOf(u8, rest, ">") orelse rest.len;
    const attrs = rest[0..end];
    if (std.mem.indexOf(u8, attrs, "number=\"true\"") != null) return .number;
    if (std.mem.indexOf(u8, attrs, "boolean=\"true\"") != null) return .boolean;
    if (std.mem.indexOf(u8, attrs, "object=\"true\"") != null) return .object;
    if (std.mem.indexOf(u8, attrs, "array=\"true\"") != null) return .array;
    return .string;
}

/// Append `s` as a JSON string body (no surrounding quotes) with proper escaping.
fn dsmlJsonStr(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| switch (c) {
        '"' => try buf.appendSlice(allocator, "\\\""),
        '\\' => try buf.appendSlice(allocator, "\\\\"),
        '\t' => try buf.appendSlice(allocator, "\\t"),
        '\n' => try buf.appendSlice(allocator, "\\n"),
        '\r' => try buf.appendSlice(allocator, "\\r"),
        0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
            var esc: [6]u8 = undefined;
            const n = std.fmt.bufPrint(&esc, "\\u{x:0>4}", .{c}) catch unreachable;
            try buf.appendSlice(allocator, n);
        },
        else => try buf.append(allocator, c),
    };
}

fn makeRoleDeniedResult(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    denial: RoleDenial,
) !at.ToolResult {
    const text = if (denial.min_role) |min|
        try std.fmt.allocPrint(
            allocator,
            "tool '{s}' is not available under role '{s}'. Restart with --role {s} (and ensure a sandbox is in place for risky roles) to enable it.",
            .{ tool_name, denial.current_role, min },
        )
    else
        try std.fmt.allocPrint(
            allocator,
            "tool '{s}' is not available under role '{s}'.",
            .{ tool_name, denial.current_role },
        );
    const arr = try allocator.alloc(ai.types.ContentBlock, 1);
    arr[0] = .{ .text = .{ .text = text } };
    return .{
        .content = arr,
        .is_error = true,
        .tool_code = try allocator.dupe(u8, at.role_denied_code),
    };
}

/// Dump one message to the trace log. Text and tool-call args are
/// written verbatim (truncated to 4 KiB per block); binary and image
/// blocks are summarised. Caller must have already checked
/// `log.enabled(.trace)`.
fn logMessageTrace(direction: []const u8, index: usize, msg: ai.types.Message) void {
    const role_str: []const u8 = switch (msg.role) {
        .user => "user",
        .assistant => "assistant",
        .tool_result => "tool_result",
        .custom => "custom",
    };
    ai.log.log(.trace, "message", direction, "idx={d} role={s} blocks={d}", .{ index, role_str, msg.content.len });
    // Tool-result messages carry the sub-id and is_error on the Message,
    // not per content block — surface those up front.
    if (msg.role == .tool_result) {
        ai.log.log(.trace, "message", "tool_result_meta", "tool_use_id={s} is_error={}", .{
            msg.tool_call_id orelse "",
            msg.is_error,
        });
    }
    for (msg.content, 0..) |cb, bi| switch (cb) {
        .text => |t| ai.log.body(.trace, "message", "text", t.text, 4096),
        .thinking => |th| ai.log.body(.trace, "message", "thinking", th.thinking, 4096),
        .image => ai.log.log(.trace, "message", "image", "block={d}", .{bi}),
        .tool_call => |tc| {
            ai.log.log(.trace, "message", "tool_call", "block={d} id={s} name={s}", .{ bi, tc.id, tc.name });
            ai.log.body(.trace, "message", "tool_args", tc.arguments_json, 4096);
        },
    };
}

fn pushAgentError(
    out: *AgentChannel,
    io: std.Io,
    allocator: std.mem.Allocator,
    code: ai.errors.Code,
    message: []const u8,
) !void {
    const owned = try allocator.dupe(u8, message);
    out.closeWithFinal(io, .{ .agent_error = .{ .code = code, .message = owned } });
}

/// vN — emit the graceful interrupt event and close the channel.
fn emitInterrupted(
    out: *AgentChannel,
    io: std.Io,
    allocator: std.mem.Allocator,
) !void {
    _ = allocator;
    ai.log.log(.info, "loop", "interrupted", "graceful stop after current turn", .{});
    out.closeWithFinal(io, .{ .agent_interrupted = {} });
}

/// v1.29.0 — write a JSON snapshot of the reducer's internal
/// state to `<dump_dir>/turn-<N>.reducer-dump.json`. Best-effort
/// — any IO failure (mkdir, allocation, snapshot generation,
/// write) is swallowed silently. Caller has already decided this
/// turn produced a degenerate message, so we're racing to capture
/// the state before `finalize` ships it.
fn dumpReducerSnapshot(
    allocator: std.mem.Allocator,
    io: std.Io,
    dump_dir: []const u8,
    turn_index: usize,
    reducer: *const ai.stream.Reducer,
) void {
    std.Io.Dir.cwd().createDirPath(io, dump_dir) catch return;
    const snap = reducer.snapshotJson(allocator) catch return;
    defer allocator.free(snap);
    const path = std.fmt.allocPrint(
        allocator,
        "{s}/turn-{d}.reducer-dump.json",
        .{ dump_dir, turn_index },
    ) catch return;
    defer allocator.free(path);
    var f = std.Io.Dir.cwd().createFile(io, path, .{}) catch return;
    defer f.close(io);
    f.writeStreamingAll(io, snap) catch return;
    ai.log.log(.warn, "loop", "reducer_dump_written", "path={s} bytes={d}", .{ path, snap.len });
}

fn agentErrorCode(e: anyerror) ai.errors.Code {
    return switch (e) {
        error.Auth => .auth,
        error.RequestInvalid => .request_invalid,
        error.ModelUnavailable => .model_unavailable,
        error.ContextOverflow => .context_overflow,
        error.PayloadTooLarge => .payload_too_large,
        error.RateLimited => .rate_limited,
        error.RateLimitedHard => .rate_limited_hard,
        error.Transient => .transient,
        error.Timeout => .timeout,
        error.Transport => .transport,
        error.SafetyRefusal => .safety_refusal,
        error.EmptyResponse => .empty_response,
        error.Aborted => .aborted,
        error.MaxTurnsExceeded => .max_turns_exceeded,
        error.ToolArgValidation => .tool_arg_validation,
        error.ToolRuntime => .tool_runtime,
        error.ToolBlocked => .tool_blocked,
        error.ProtocolViolation => .protocol_violation,
        error.OutOfMemory => .internal,
        else => .internal,
    };
}

fn cloneTools(
    allocator: std.mem.Allocator,
    tools: []const at.AgentTool,
) ![]ai.types.Tool {
    const out = try allocator.alloc(ai.types.Tool, tools.len);
    var cloned: usize = 0;
    errdefer {
        for (out[0..cloned]) |t| t.deinit(allocator);
        allocator.free(out);
    }
    for (tools, 0..) |t, i| {
        out[i] = .{
            .name = try allocator.dupe(u8, t.name),
            .description = try allocator.dupe(u8, t.description),
            .parameters_json = try allocator.dupe(u8, t.parameters_json),
        };
        cloned = i + 1;
    }
    return out;
}

fn dupeMessage(allocator: std.mem.Allocator, m: ai.types.Message) !ai.types.Message {
    var content: std.ArrayList(ai.types.ContentBlock) = .empty;
    errdefer {
        for (content.items) |cb| cb.deinit(allocator);
        content.deinit(allocator);
    }
    for (m.content) |cb| try content.append(allocator, try cb.dupe(allocator));
    const content_slice = try content.toOwnedSlice(allocator);
    errdefer {
        for (content_slice) |cb| cb.deinit(allocator);
        allocator.free(content_slice);
    }
    var msg: ai.types.Message = .{
        .role = m.role,
        .content = content_slice,
        .timestamp = m.timestamp,
        .stop_reason = m.stop_reason,
        .usage = m.usage,
        .error_message = if (m.error_message) |s| try allocator.dupe(u8, s) else null,
        .provider = if (m.provider) |s| try allocator.dupe(u8, s) else null,
        .model = if (m.model) |s| try allocator.dupe(u8, s) else null,
        .api = if (m.api) |s| try allocator.dupe(u8, s) else null,
        .tool_call_id = if (m.tool_call_id) |s| try allocator.dupe(u8, s) else null,
        .is_error = m.is_error,
        .custom_role = if (m.custom_role) |s| try allocator.dupe(u8, s) else null,
        .meta_json = if (m.meta_json) |s| try allocator.dupe(u8, s) else null,
    };
    errdefer msg.deinit(allocator);
    return msg;
}

// ─── tests ──────────────────────────────────────────────────────

const testing = std.testing;

test "defaultConvertToLlm: compaction_summary rewritten to user + prefix" {
    const gpa = testing.allocator;
    var c_sum = [_]ai.types.ContentBlock{.{ .text = .{ .text = "the user fixed a bug" } }};
    var c_user = [_]ai.types.ContentBlock{.{ .text = .{ .text = "next question" } }};
    const messages = [_]AgentMessage{
        .{
            .role = .custom,
            .custom_role = "compaction_summary",
            .content = &c_sum,
            .timestamp = 0,
        },
        .{ .role = .user, .content = &c_user, .timestamp = 0 },
    };

    const out = try defaultConvertToLlm(gpa, &messages);
    defer {
        for (out) |*m| m.deinit(gpa);
        gpa.free(out);
    }
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqual(ai.types.Role.user, out[0].role);
    try testing.expectEqualStrings(
        "Earlier in this conversation:\n\nthe user fixed a bug",
        out[0].content[0].text.text,
    );
    try testing.expectEqualStrings("next question", out[1].content[0].text.text);
}

test "defaultConvertToLlm: unknown .custom role is filtered out" {
    const gpa = testing.allocator;
    var c_x = [_]ai.types.ContentBlock{.{ .text = .{ .text = "ignored" } }};
    var c_u = [_]ai.types.ContentBlock{.{ .text = .{ .text = "kept" } }};
    const messages = [_]AgentMessage{
        .{
            .role = .custom,
            .custom_role = "something_else",
            .content = &c_x,
            .timestamp = 0,
        },
        .{ .role = .user, .content = &c_u, .timestamp = 0 },
    };
    const out = try defaultConvertToLlm(gpa, &messages);
    defer {
        for (out) |*m| m.deinit(gpa);
        gpa.free(out);
    }
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualStrings("kept", out[0].content[0].text.text);
}

// ─── v1.16.3 — formatToolExecutionError tests ─────────────────────

test "formatToolExecutionError: JSON-parse error includes hint + args preview" {
    const gpa = testing.allocator;
    const args = "{\"path\": \"foo.zig\", \"new\": <|broken|>}";
    const msg = try formatToolExecutionError(gpa, "edit", error.SyntaxError, args);
    defer gpa.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "Tool 'edit' failed") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "SyntaxError") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "JSON object") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "<|broken|>") != null);
}

test "formatToolExecutionError: non-JSON error gets generic hint" {
    const gpa = testing.allocator;
    const msg = try formatToolExecutionError(gpa, "bash", error.AccessDenied, "{\"command\":\"ls\"}");
    defer gpa.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "Tool 'bash' failed") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "AccessDenied") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "different approach") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "JSON object") == null);
}

test "formatToolExecutionError: long args get truncated with ellipsis" {
    const gpa = testing.allocator;
    var long_args: [400]u8 = undefined;
    @memset(&long_args, 'x');
    const msg = try formatToolExecutionError(gpa, "write", error.SyntaxError, &long_args);
    defer gpa.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "(truncated)") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "first 200 bytes") != null);
}

test "looksLikeJsonError: matches std.json error tags" {
    try testing.expect(looksLikeJsonError("SyntaxError"));
    try testing.expect(looksLikeJsonError("UnexpectedToken"));
    try testing.expect(looksLikeJsonError("InvalidEscape"));
    try testing.expect(looksLikeJsonError("MissingField"));
    try testing.expect(!looksLikeJsonError("AccessDenied"));
    try testing.expect(!looksLikeJsonError("OutOfMemory"));
    try testing.expect(!looksLikeJsonError("FileNotFound"));
}

// ─── v1.16.3 — text-tool-call fallback tests ──────────────────

fn fakeToolForTest(comptime name: []const u8) at.AgentTool {
    const Stub = struct {
        fn execute(
            _: *const at.AgentTool,
            _: std.mem.Allocator,
            _: std.Io,
            _: []const u8,
            _: []const u8,
            _: *ai.stream.Cancel,
            _: at.OnUpdate,
        ) anyerror!at.ToolResult {
            return error.Unsupported;
        }
    };
    return .{
        .name = name,
        .description = "test",
        .parameters_json = "{}",
        .execute = Stub.execute,
    };
}

test "extractTextToolCall: cloudflare-style {type, name, parameters}" {
    const gpa = testing.allocator;
    const tools = [_]at.AgentTool{fakeToolForTest("read")};
    const text =
        \\{"type": "function", "name": "read", "parameters": {"path": "code-analyse.md"}}
    ;
    const result = try extractTextToolCall(gpa, text, &tools);
    try testing.expect(result != null);
    defer gpa.free(result.?.name);
    defer gpa.free(result.?.args);
    try testing.expectEqualStrings("read", result.?.name);
    try testing.expect(std.mem.indexOf(u8, result.?.args, "code-analyse.md") != null);
}

test "extractTextToolCall: llama-style {name, parameters}" {
    const gpa = testing.allocator;
    const tools = [_]at.AgentTool{fakeToolForTest("read")};
    const text =
        \\{"name": "read", "parameters": {"path": "foo.zig"}}
    ;
    const result = try extractTextToolCall(gpa, text, &tools);
    try testing.expect(result != null);
    defer gpa.free(result.?.name);
    defer gpa.free(result.?.args);
    try testing.expectEqualStrings("read", result.?.name);
}

test "extractTextToolCall: openai-style {name, arguments-as-string}" {
    const gpa = testing.allocator;
    const tools = [_]at.AgentTool{fakeToolForTest("read")};
    const text =
        \\{"name": "read", "arguments": "{\"path\":\"x.zig\"}"}
    ;
    const result = try extractTextToolCall(gpa, text, &tools);
    try testing.expect(result != null);
    defer gpa.free(result.?.name);
    defer gpa.free(result.?.args);
    try testing.expectEqualStrings("{\"path\":\"x.zig\"}", result.?.args);
}

test "extractTextToolCall: <tool_call> wrapper is stripped" {
    const gpa = testing.allocator;
    const tools = [_]at.AgentTool{fakeToolForTest("read")};
    const text =
        \\<tool_call>{"name": "read", "parameters": {"path": "x"}}</tool_call>
    ;
    const result = try extractTextToolCall(gpa, text, &tools);
    try testing.expect(result != null);
    defer gpa.free(result.?.name);
    defer gpa.free(result.?.args);
    try testing.expectEqualStrings("read", result.?.name);
}

test "extractTextToolCall: <|python_tag|> wrapper is stripped" {
    const gpa = testing.allocator;
    const tools = [_]at.AgentTool{fakeToolForTest("read")};
    const text =
        \\<|python_tag|>{"name": "read", "parameters": {"path": "x"}}
    ;
    const result = try extractTextToolCall(gpa, text, &tools);
    try testing.expect(result != null);
    defer gpa.free(result.?.name);
    defer gpa.free(result.?.args);
    try testing.expectEqualStrings("read", result.?.name);
}

test "extractTextToolCall: name not in registry → null" {
    const gpa = testing.allocator;
    const tools = [_]at.AgentTool{fakeToolForTest("read")};
    const text =
        \\{"name": "delete_universe", "parameters": {"why_not": "yolo"}}
    ;
    const result = try extractTextToolCall(gpa, text, &tools);
    try testing.expect(result == null);
}

test "extractTextToolCall: plain text reply (not JSON) → null" {
    const gpa = testing.allocator;
    const tools = [_]at.AgentTool{fakeToolForTest("read")};
    const result = try extractTextToolCall(gpa, "Sure, I'll help with that.", &tools);
    try testing.expect(result == null);
}

test "extractTextToolCall: JSON without name → null" {
    const gpa = testing.allocator;
    const tools = [_]at.AgentTool{fakeToolForTest("read")};
    const text = "{\"hello\": \"world\"}";
    const result = try extractTextToolCall(gpa, text, &tools);
    try testing.expect(result == null);
}

test "extractTextToolCall: malformed JSON → null (doesn't throw)" {
    const gpa = testing.allocator;
    const tools = [_]at.AgentTool{fakeToolForTest("read")};
    const text = "{\"name\": \"read\", broken}";
    const result = try extractTextToolCall(gpa, text, &tools);
    try testing.expect(result == null);
}

test "stripToolCallWrappers: handles wrapper variants" {
    try testing.expectEqualStrings("{}", stripToolCallWrappers("{}"));
    try testing.expectEqualStrings("{}", stripToolCallWrappers("  {}  "));
    try testing.expectEqualStrings("{}", stripToolCallWrappers("<|python_tag|>{}"));
    try testing.expectEqualStrings("{}", stripToolCallWrappers("<tool_call>{}</tool_call>"));
    try testing.expectEqualStrings(
        "{}",
        stripToolCallWrappers("<|python_tag|><tool_call>{}</tool_call>"),
    );
}

test "maybeApplyTextToolCallFallback: rewrites text → tool_call" {
    const gpa = testing.allocator;
    const tools = [_]at.AgentTool{fakeToolForTest("read")};

    // Build a message with a single text block that holds a CF-style
    // text-shaped tool call.
    const text_payload = try gpa.dupe(
        u8,
        "{\"type\": \"function\", \"name\": \"read\", \"parameters\": {\"path\": \"x.zig\"}}",
    );
    var content_blocks = try gpa.alloc(ai.types.ContentBlock, 1);
    content_blocks[0] = .{ .text = .{ .text = text_payload } };

    var msg = AgentMessage{
        .role = .assistant,
        .content = content_blocks,
        .timestamp = 0,
    };
    defer msg.deinit(gpa);

    try maybeApplyTextToolCallFallback(gpa, &msg, &tools);

    // Now the block at index 0 should be a tool_call, not text.
    try testing.expect(msg.content[0] == .tool_call);
    try testing.expectEqualStrings("read", msg.content[0].tool_call.name);
    try testing.expect(std.mem.indexOf(u8, msg.content[0].tool_call.arguments_json, "x.zig") != null);
    try testing.expect(std.mem.startsWith(u8, msg.content[0].tool_call.id, "txtcall_"));
}

test "extractDsmlToolCall: single string parameter" {
    const gpa = testing.allocator;
    const tools = [_]at.AgentTool{fakeToolForTest("read")};
    const text =
        "<\xef\xbd\x9cDSML\xef\xbd\x9ctool_calls>\n" ++
        "<\xef\xbd\x9cDSML\xef\xbd\x9cinvoke name=\"read\">\n" ++
        "<\xef\xbd\x9cDSML\xef\xbd\x9cparameter name=\"path\" string=\"true\">/some/file.zig\n";
    const result = (try extractDsmlToolCall(gpa, text, &tools)).?;
    defer gpa.free(result.name);
    defer gpa.free(result.args);
    try testing.expectEqualStrings("read", result.name);
    try testing.expectEqualStrings("{\"path\":\"/some/file.zig\"}", result.args);
}

test "extractDsmlToolCall: multiple parameters mixed types" {
    const gpa = testing.allocator;
    const tools = [_]at.AgentTool{fakeToolForTest("write")};
    const text =
        "<\xef\xbd\x9cDSML\xef\xbd\x9ctool_calls>\n" ++
        "<\xef\xbd\x9cDSML\xef\xbd\x9cinvoke name=\"write\">\n" ++
        "<\xef\xbd\x9cDSML\xef\xbd\x9cparameter name=\"path\" string=\"true\">/out.txt\n" ++
        "<\xef\xbd\x9cDSML\xef\xbd\x9cparameter name=\"overwrite\" boolean=\"true\">true\n" ++
        "<\xef\xbd\x9cDSML\xef\xbd\x9cparameter name=\"count\" number=\"true\">42\n";
    const result = (try extractDsmlToolCall(gpa, text, &tools)).?;
    defer gpa.free(result.name);
    defer gpa.free(result.args);
    try testing.expectEqualStrings("write", result.name);
    try testing.expectEqualStrings(
        "{\"path\":\"/out.txt\",\"overwrite\":true,\"count\":42}",
        result.args,
    );
}

test "extractDsmlToolCall: string value with special chars is JSON-escaped" {
    const gpa = testing.allocator;
    const tools = [_]at.AgentTool{fakeToolForTest("echo")};
    const text =
        "<\xef\xbd\x9cDSML\xef\xbd\x9cinvoke name=\"echo\">\n" ++
        "<\xef\xbd\x9cDSML\xef\xbd\x9cparameter name=\"msg\" string=\"true\">say \"hi\"\n";
    const result = (try extractDsmlToolCall(gpa, text, &tools)).?;
    defer gpa.free(result.name);
    defer gpa.free(result.args);
    try testing.expectEqualStrings("{\"msg\":\"say \\\"hi\\\"\"}", result.args);
}

test "extractDsmlToolCall: no DSML markup → null" {
    const gpa = testing.allocator;
    const tools = [_]at.AgentTool{fakeToolForTest("read")};
    const result = try extractDsmlToolCall(gpa, "Sure, I'll help.", &tools);
    try testing.expect(result == null);
}

test "extractDsmlToolCall: tool name not in registry → null" {
    const gpa = testing.allocator;
    const tools = [_]at.AgentTool{fakeToolForTest("read")};
    const text =
        "<\xef\xbd\x9cDSML\xef\xbd\x9cinvoke name=\"unknown_tool\">\n" ++
        "<\xef\xbd\x9cDSML\xef\xbd\x9cparameter name=\"x\" string=\"true\">y\n";
    const result = try extractDsmlToolCall(gpa, text, &tools);
    try testing.expect(result == null);
}

test "extractDsmlToolCall: closing tag trims value without leaking" {
    const gpa = testing.allocator;
    const tools = [_]at.AgentTool{fakeToolForTest("read")};
    const text =
        "<\xef\xbd\x9cDSML\xef\xbd\x9ctool_calls>\n" ++
        "<\xef\xbd\x9cDSML\xef\xbd\x9cinvoke name=\"read\">\n" ++
        "<\xef\xbd\x9cDSML\xef\xbd\x9cparameter name=\"path\" string=\"true\">/path/to/file\n" ++
        "</\xef\xbd\x9cDSML\xef\xbd\x9cparameter>\n" ++
        "</\xef\xbd\x9cDSML\xef\xbd\x9cinvoke>\n" ++
        "</\xef\xbd\x9cDSML\xef\xbd\x9ctool_calls>\n";
    const result = (try extractDsmlToolCall(gpa, text, &tools)).?;
    defer gpa.free(result.name);
    defer gpa.free(result.args);
    try testing.expectEqualStrings("read", result.name);
    try testing.expectEqualStrings("{\"path\":\"/path/to/file\"}", result.args);
}

test "extractDsmlToolCall: multiple params with closing tags" {
    const gpa = testing.allocator;
    const tools = [_]at.AgentTool{fakeToolForTest("write")};
    const text =
        "<\xef\xbd\x9cDSML\xef\xbd\x9ctool_calls>\n" ++
        "<\xef\xbd\x9cDSML\xef\xbd\x9cinvoke name=\"write\">\n" ++
        "<\xef\xbd\x9cDSML\xef\xbd\x9cparameter name=\"path\" string=\"true\">/out.txt\n" ++
        "</\xef\xbd\x9cDSML\xef\xbd\x9cparameter>\n" ++
        "<\xef\xbd\x9cDSML\xef\xbd\x9cparameter name=\"overwrite\" boolean=\"true\">true\n" ++
        "</\xef\xbd\x9cDSML\xef\xbd\x9cparameter>\n" ++
        "</\xef\xbd\x9cDSML\xef\xbd\x9cinvoke>\n" ++
        "</\xef\xbd\x9cDSML\xef\xbd\x9ctool_calls>\n";
    const result = (try extractDsmlToolCall(gpa, text, &tools)).?;
    defer gpa.free(result.name);
    defer gpa.free(result.args);
    try testing.expectEqualStrings("write", result.name);
    try testing.expectEqualStrings(
        "{\"path\":\"/out.txt\",\"overwrite\":true}",
        result.args,
    );
}

test "extractDsmlToolCall: value after closing tag not consumed" {
    // Regression: ensure that when one param has a closing tag and the next
    // param follows, the second param is still parsed correctly.
    const gpa = testing.allocator;
    const tools = [_]at.AgentTool{fakeToolForTest("multi")};
    const text =
        "<\xef\xbd\x9cDSML\xef\xbd\x9cinvoke name=\"multi\">\n" ++
        "<\xef\xbd\x9cDSML\xef\xbd\x9cparameter name=\"a\" string=\"true\">val1\n" ++
        "</\xef\xbd\x9cDSML\xef\xbd\x9cparameter>\n" ++
        "<\xef\xbd\x9cDSML\xef\xbd\x9cparameter name=\"b\" string=\"true\">val2\n" ++
        "</\xef\xbd\x9cDSML\xef\xbd\x9cparameter>\n" ++
        "</\xef\xbd\x9cDSML\xef\xbd\x9cinvoke>\n";
    const result = (try extractDsmlToolCall(gpa, text, &tools)).?;
    defer gpa.free(result.name);
    defer gpa.free(result.args);
    try testing.expectEqualStrings("multi", result.name);
    try testing.expectEqualStrings(
        "{\"a\":\"val1\",\"b\":\"val2\"}",
        result.args,
    );
}

test "maybeApplyDsmlThinkingFallback: extracts tool call from thinking block" {
    // Simulates DeepSeek via Ollama: DSML tool call embedded in reasoning_content
    // which arrives as a thinking block with no separate tool_calls[] array.
    const gpa = testing.allocator;
    const tools = [_]at.AgentTool{fakeToolForTest("read")};

    const dsml =
        "Some reasoning about what to do next.\n" ++
        "<\xef\xbd\x9cDSML\xef\xbd\x9ctool_calls>\n" ++
        "<\xef\xbd\x9cDSML\xef\xbd\x9cinvoke name=\"read\">\n" ++
        "<\xef\xbd\x9cDSML\xef\xbd\x9cparameter name=\"path\" string=\"true\">src/foo.zig\n" ++
        "</\xef\xbd\x9cDSML\xef\xbd\x9cinvoke>\n" ++
        "</\xef\xbd\x9cDSML\xef\xbd\x9ctool_calls>\n";

    const thinking_text = try gpa.dupe(u8, dsml);
    var content_blocks = try gpa.alloc(ai.types.ContentBlock, 1);
    content_blocks[0] = .{ .thinking = .{ .thinking = thinking_text } };

    var msg = AgentMessage{
        .role = .assistant,
        .content = content_blocks,
        .timestamp = 0,
    };
    defer msg.deinit(gpa);

    try maybeApplyDsmlThinkingFallback(gpa, &msg, &tools);

    try testing.expectEqual(@as(usize, 2), msg.content.len);
    try testing.expect(msg.content[0] == .thinking);
    try testing.expect(msg.content[1] == .tool_call);
    try testing.expectEqualStrings("read", msg.content[1].tool_call.name);
    const args = msg.content[1].tool_call.arguments_json;
    try testing.expect(std.mem.indexOf(u8, args, "src/foo.zig") != null);
}

test "maybeApplyDsmlThinkingFallback: skips when tool_call already present" {
    const gpa = testing.allocator;
    const tools = [_]at.AgentTool{fakeToolForTest("read")};

    const existing_id = try gpa.dupe(u8, "existing");
    const existing_name = try gpa.dupe(u8, "read");
    const existing_args = try gpa.dupe(u8, "{}");
    var content_blocks = try gpa.alloc(ai.types.ContentBlock, 1);
    content_blocks[0] = .{ .tool_call = .{ .id = existing_id, .name = existing_name, .arguments_json = existing_args } };

    var msg = AgentMessage{ .role = .assistant, .content = content_blocks, .timestamp = 0 };
    defer msg.deinit(gpa);

    try maybeApplyDsmlThinkingFallback(gpa, &msg, &tools);

    // Still just the one existing tool_call — fallback is idempotent.
    try testing.expectEqual(@as(usize, 1), msg.content.len);
    try testing.expect(msg.content[0] == .tool_call);
}

test "maybeApplyTextToolCallFallback: leaves message untouched when no match" {
    const gpa = testing.allocator;
    const tools = [_]at.AgentTool{fakeToolForTest("read")};

    const text_payload = try gpa.dupe(u8, "Sure, I'll think about it.");
    var content_blocks = try gpa.alloc(ai.types.ContentBlock, 1);
    content_blocks[0] = .{ .text = .{ .text = text_payload } };

    var msg = AgentMessage{
        .role = .assistant,
        .content = content_blocks,
        .timestamp = 0,
    };
    defer msg.deinit(gpa);

    try maybeApplyTextToolCallFallback(gpa, &msg, &tools);

    // Still text — fallback didn't touch it.
    try testing.expect(msg.content[0] == .text);
    try testing.expectEqualStrings("Sure, I'll think about it.", msg.content[0].text.text);
}

test "makeToolResultMessage: text blocks over 8KB are truncated with size marker" {
    const gpa = testing.allocator;

    // Build a 16KB text block — double the cap. The source buffer is stack-
    // owned by the fake ToolResult; makeToolResultMessage allocates new memory
    // for the truncated copy, so we free the source ourselves.
    const big = try gpa.alloc(u8, 16 * 1024);
    defer gpa.free(big);
    @memset(big, 'a');

    var cb: ai.types.ContentBlock = .{ .text = .{ .text = big } };
    const result: at.ToolResult = .{ .content = (&cb)[0..1] };
    const call_result: ToolCallResult = .{ .call_id = "test_id", .result = result, .terminate = false };

    var msg = try makeToolResultMessage(gpa, call_result);
    defer msg.deinit(gpa);

    try testing.expect(msg.content.len == 1);
    const text = msg.content[0].text.text;
    try testing.expect(text.len <= truncate.tool_result_max_bytes + 32); // cap + marker overhead
    try testing.expect(std.mem.indexOf(u8, text, "[...") != null);
    try testing.expect(std.mem.indexOf(u8, text, "truncated]") != null);
}

test "makeToolResultMessage: text blocks under 8KB pass through unchanged" {
    const gpa = testing.allocator;

    // Source text is not owned by at.ToolResult — makeToolResultMessage dupes
    // it, so we free the original here.
    const small = try gpa.dupe(u8, "hello tool result");
    defer gpa.free(small);
    var cb: ai.types.ContentBlock = .{ .text = .{ .text = small } };
    const result: at.ToolResult = .{ .content = (&cb)[0..1] };
    const call_result: ToolCallResult = .{ .call_id = "id2", .result = result, .terminate = false };

    var msg = try makeToolResultMessage(gpa, call_result);
    defer msg.deinit(gpa);

    try testing.expectEqualStrings("hello tool result", msg.content[0].text.text);
}

test "offloadToolResults: nothing offloaded when under keep limit" {
    const gpa = testing.allocator;
    var tr_content = [_]ai.types.ContentBlock{.{ .text = .{ .text = "big output here" } }};
    var msgs = [_]ai.types.Message{
        .{ .role = .user, .content = &.{}, .timestamp = 0 },
        .{ .role = .assistant, .content = &.{}, .timestamp = 0 },
        .{ .role = .tool_result, .content = &tr_content, .timestamp = 0, .tool_call_id = "call_1" },
    };
    const result = try offloadToolResults(gpa, undefined, &msgs, 5, null);
    defer {
        for (result) |*m| m.deinit(gpa);
        gpa.free(result);
    }
    try testing.expect(result.len == 3);
    // tool_result still has full content
    try testing.expectEqualStrings("big output here", result[2].content[0].text.text);
}

test "offloadToolResults: old tool results replaced with placeholder" {
    const gpa = testing.allocator;
    var old_tr = [_]ai.types.ContentBlock{.{ .text = .{ .text = "old big output here" } }};
    var new_tr = [_]ai.types.ContentBlock{.{ .text = .{ .text = "fresh result" } }};
    var msgs = [_]ai.types.Message{
        .{ .role = .user, .content = &.{}, .timestamp = 0 },
        .{ .role = .tool_result, .content = &old_tr, .timestamp = 0, .tool_call_id = "call_1" },
        .{ .role = .assistant, .content = &.{}, .timestamp = 0 },
        .{ .role = .tool_result, .content = &new_tr, .timestamp = 0, .tool_call_id = "call_2" },
    };
    // keep=1 → only the last tool_result survives with full content
    const result = try offloadToolResults(gpa, undefined, &msgs, 1, null);
    defer {
        for (result) |*m| m.deinit(gpa);
        gpa.free(result);
    }
    try testing.expect(result.len == 4);
    // Index 1 (old tool result) is offloaded
    try testing.expect(std.mem.indexOf(u8, result[1].content[0].text.text, "(offloaded)") != null);
    // Index 3 (new tool result) still has full content
    try testing.expectEqualStrings("fresh result", result[3].content[0].text.text);
}

test "offloadToolResults: non-tool-result messages pass through unchanged" {
    const gpa = testing.allocator;
    var user_content = [_]ai.types.ContentBlock{.{ .text = .{ .text = "hello" } }};
    var tr_content = [_]ai.types.ContentBlock{.{ .text = .{ .text = "result" } }};
    var msgs = [_]ai.types.Message{
        .{ .role = .user, .content = &user_content, .timestamp = 0 },
        .{ .role = .tool_result, .content = &tr_content, .timestamp = 0, .tool_call_id = "c1" },
    };
    const result = try offloadToolResults(gpa, undefined, &msgs, 0, null);
    defer {
        for (result) |*m| m.deinit(gpa);
        gpa.free(result);
    }
    try testing.expect(result.len == 2);
    try testing.expectEqualStrings("hello", result[0].content[0].text.text);
    try testing.expect(std.mem.indexOf(u8, result[1].content[0].text.text, "(offloaded)") != null);
}
