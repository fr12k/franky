//! Stateful Agent — §4.6 of the spec.
//!
//! Wraps the low-level `loop.agentLoop` with:
//!   - Reactive state (model, tools, transcript, streaming flag).
//!   - Observer pattern via `subscribe`.
//!   - Command methods: `prompt`, `continueRun`, `steer`, `followUp`,
//!     `abort`, `reset`, `waitForIdle`.
//!
//! The Agent owns a background fiber/thread that consumes events from
//! the loop's channel, updates state, and forwards events to subscribers.
//!
//! Concurrency model for the first port:
//!   - `prompt` spawns a worker thread via `std.Thread.spawn`.
//!   - The worker drives `agentLoop`; events are consumed by the worker
//!     and pushed to subscribers under a mutex.
//!   - `abort` fires the `Cancel` flag and joins the worker.

const std = @import("std");
const ai = struct {
    pub const types = @import("../ai/types.zig");
    pub const errors = @import("../ai/errors.zig");
    pub const stream = @import("../ai/stream.zig");
    pub const registry = @import("../ai/registry.zig");
    pub const http = @import("../ai/http.zig");
};
const at = @import("types.zig");
const loop_mod = @import("loop.zig");

pub const SubscribeHandler = *const fn (userdata: ?*anyopaque, ev: at.AgentEvent) void;

pub const Subscription = struct {
    id: u32,
    handler: SubscribeHandler,
    userdata: ?*anyopaque,
};

pub const Agent = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    // ── state (top-level replaceable fields; nested mutation forbidden) ──
    system_prompt: []u8,
    tools: []at.AgentTool,
    model: ai.types.Model,
    thinking_level: ai.types.ThinkingLevel = .off,
    transcript: loop_mod.Transcript,

    // ── runtime ───────────────────────────────────────────────────
    registry: *const ai.registry.Registry,
    cancel: ai.stream.Cancel = .{},
    is_streaming: std.atomic.Value(bool) = .init(false),
    /// Forwarded to every per-turn `agentLoop` call so providers
    /// see the auth + transport + timeout options the bot config
    /// supplied. Plain copy; deep ownership stays with the
    /// caller (`stream_options.environ_map`, `stream_options.cancel`,
    /// hooks).
    stream_options: ai.registry.StreamOptions = .{},

    /// v3.x — optional shared HTTP client. When null, the agent
    /// loop creates its own. When non-null, the loop borrows this
    /// client — used by subagents to reuse the parent's warm TLS
    /// connection pool. Caller-owned; must outlive the Agent.
    http_client: ?*ai.http.Client = null,

    /// v1.22.0 — see `Config.tool_gate`. Plain copy from Config
    /// at init time; the userdata pointer stays caller-owned.
    tool_gate: ?ToolGate = null,
    /// Hard cap on agent-loop turn count. Forwarded to `loop.Config`
    /// per-run. SDK consumers override the default by setting
    /// `Agent.Config.max_turns`; mode drivers override via
    /// `--max-turns` / settings / profile.
    max_turns: u32 = 100,
    /// Optional hook fired when the loop reaches `max_turns`. Returns
    /// `.extend(N)` to bump the cap additively or `.stop` to terminate.
    /// Without a hook the loop emits `max_turns_exceeded`. Wired the
    /// same way `tool_gate` is — caller-owned userdata + callback.
    max_turns_hook: ?MaxTurnsHook = null,
    /// v1.29.0 — directory the agent loop dumps reducer-state
    /// snapshots to when a turn ends with zero content blocks
    /// (see `loop.Config.reducer_dump_dir`). Caller-owned slice
    /// (typically a session-arena allocation); `null` disables.
    reducer_dump_dir: ?[]const u8 = null,

    // ── subscribers ───────────────────────────────────────────────
    subs: std.ArrayList(Subscription) = .empty,
    next_sub_id: u32 = 1,
    subs_mutex: std.Io.Mutex = .init,

    // ── worker thread ─────────────────────────────────────────────
    worker: ?std.Thread = null,

    // ── error channel ─────────────────────────────────────────────
    last_error: ?ai.errors.ErrorDetails = null,

    // ── steer / followUp queues (§4.3) ────────────────────────────
    // `pending_steer` holds user-role messages that should be
    // injected *before* the next LLM call inside the in-flight
    // turn. `pending_followup` holds user-role messages that run as
    // a *fresh* prompt once the current turn ends naturally — does
    // not abort. Both queues are drained by the loop at their
    // respective boundaries (wiring pending; §4.3 full integration
    // folds into the loop's next major pass).
    pending_steer: std.ArrayList([]u8) = .empty,
    pending_followup: std.ArrayList([]u8) = .empty,
    queue_mutex: std.Io.Mutex = .init,

    // ── vN: graceful stop signal ─────────────────────────────────
    /// When set by `interrupt()`, the loop checks this between
    /// turns and exits gracefully after the current turn finishes.
    /// Unlike `cancel`, this does NOT abort mid-turn — the
    /// assistant's current output and tool results are preserved
    /// in the transcript.
    stop_requested: std.atomic.Value(bool) = .init(false),

    pub const Config = struct {
        model: ai.types.Model,
        system_prompt: []const u8 = "",
        tools: []const at.AgentTool = &.{},
        registry: *const ai.registry.Registry,
        thinking_level: ai.types.ThinkingLevel = .off,
        /// Auth + transport options forwarded to every provider
        /// stream call. `api_key` / `auth_token` / `base_url` /
        /// `environ_map` / `timeouts` / `hooks` flow through here.
        /// Default `.{}` keeps tests on the faux provider working
        /// (no creds needed). Real providers (Anthropic, OpenAI,
        /// Gemini, Vertex) require at least one of `api_key` or
        /// `auth_token` to be set, or `environ_map` populated so
        /// the provider can pull them from env.
        stream_options: ai.registry.StreamOptions = .{},
        /// v3.x — optional shared HTTP client. When null (default),
        /// the agent loop creates its own client. When non-null,
        /// the loop borrows this client — used by subagents to
        /// reuse the parent's warm TLS connection pool, avoiding
        /// a new handshake from a deeply nested thread (which
        /// can stall under gvisor's userspace netstack).
        http_client: ?*ai.http.Client = null,
        /// v1.22.0 — per-Agent tool gate. Lets SDK consumers
        /// (franky-do, future siblings) plug their own
        /// `before_tool_call` / `role_denied` callbacks into the
        /// agent loop without forking the Agent class. Pass
        /// `coding/permissions.SessionGates`'s static methods
        /// here — the type is intentionally generic to preserve
        /// the `agent → coding` one-way layering. `null` keeps
        /// pre-v1.22 semantics (no per-tool gate).
        tool_gate: ?ToolGate = null,
        /// Hard cap on the agent loop's turn count for every prompt.
        /// SDK default matches `loop.Config.max_turns` (100). Mode
        /// drivers may override via CLI / settings / profile before
        /// constructing the Agent.
        max_turns: u32 = 100,
        /// Optional max-turns hook. When the loop hits the cap, this
        /// callback is invoked; returning `.extend(N)` adds N more
        /// turns to the cap (additive — credits accumulate). Returning
        /// `.stop` (or omitting the hook) emits `max_turns_exceeded`
        /// and closes the channel. Same shape as `tool_gate` — the
        /// type lives here to preserve the `agent → coding` layering.
        max_turns_hook: ?MaxTurnsHook = null,
        /// v1.29.0 — see `Agent.reducer_dump_dir`. When set, the
        /// agent loop snapshots reducer state to disk on
        /// degenerate (zero-content) turns. Mode drivers point
        /// this at `<session>/events`.
        reducer_dump_dir: ?[]const u8 = null,
    };

    /// v1.22.0 — generic per-tool-call gate. Each callback is
    /// independent of the others; a consumer can wire just one if
    /// the others aren't needed. Lives in `agent.zig` (not
    /// `coding/permissions.zig`) so the Agent class stays free of
    /// any `coding/` dependency, preserving the one-way layering.
    pub const ToolGate = struct {
        /// Caller-owned. Lives at the same address for the
        /// lifetime of the Agent. Passed to both callbacks.
        userdata: ?*anyopaque = null,
        /// Called before every tool execution attempt. Returns
        /// `{ block: true, reason_text }` to veto the call (a
        /// synthetic error tool result is sent back to the
        /// model). Returns `{ block: false }` to allow.
        before_tool_call: ?loop_mod.BeforeToolCallFn = null,
        /// Called when the model emits a tool name that's NOT
        /// in the registered tool set. A non-null return turns
        /// the synthetic error into a structured `role_denied`
        /// emission (more debuggable than "unknown tool").
        role_denied: ?loop_mod.RoleDeniedFn = null,
    };

    /// Optional max-turns extension callback bundle. Same lifetime
    /// rules as `ToolGate` — userdata is caller-owned and lives at
    /// the same address for the agent's lifetime.
    pub const MaxTurnsHook = struct {
        userdata: ?*anyopaque = null,
        on_max_turns: ?loop_mod.OnMaxTurnsFn = null,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: Config) !Agent {
        const owned_prompt = try allocator.dupe(u8, config.system_prompt);
        const owned_tools = try allocator.alloc(at.AgentTool, config.tools.len);
        for (config.tools, 0..) |t, i| owned_tools[i] = t;
        return .{
            .allocator = allocator,
            .io = io,
            .system_prompt = owned_prompt,
            .tools = owned_tools,
            .model = config.model,
            .thinking_level = config.thinking_level,
            .transcript = loop_mod.Transcript.init(allocator),
            .registry = config.registry,
            .stream_options = config.stream_options,
            .http_client = config.http_client,
            .tool_gate = config.tool_gate,
            .max_turns = config.max_turns,
            .max_turns_hook = config.max_turns_hook,
            .reducer_dump_dir = config.reducer_dump_dir,
        };
    }

    pub fn deinit(self: *Agent) void {
        self.abort();
        self.transcript.deinit();
        self.allocator.free(self.system_prompt);
        self.allocator.free(self.tools);
        self.subs.deinit(self.allocator);
        for (self.pending_steer.items) |m| self.allocator.free(m);
        self.pending_steer.deinit(self.allocator);
        for (self.pending_followup.items) |m| self.allocator.free(m);
        self.pending_followup.deinit(self.allocator);
        if (self.last_error) |d| {
            self.allocator.free(d.message);
            if (d.tool_code) |v| self.allocator.free(v);
            if (d.provider_code) |v| self.allocator.free(v);
            if (d.provider_message) |v| self.allocator.free(v);
        }
    }

    // ── observers ─────────────────────────────────────────────────

    pub fn subscribe(self: *Agent, handler: SubscribeHandler, userdata: ?*anyopaque) !u32 {
        self.subs_mutex.lockUncancelable(self.io);
        defer self.subs_mutex.unlock(self.io);
        const id = self.next_sub_id;
        self.next_sub_id += 1;
        try self.subs.append(self.allocator, .{ .id = id, .handler = handler, .userdata = userdata });
        return id;
    }

    pub fn unsubscribe(self: *Agent, id: u32) void {
        self.subs_mutex.lockUncancelable(self.io);
        defer self.subs_mutex.unlock(self.io);
        for (self.subs.items, 0..) |s, i| {
            if (s.id == id) {
                _ = self.subs.orderedRemove(i);
                return;
            }
        }
    }

    fn broadcast(self: *Agent, ev: at.AgentEvent) void {
        self.subs_mutex.lockUncancelable(self.io);
        defer self.subs_mutex.unlock(self.io);
        for (self.subs.items) |s| s.handler(s.userdata, ev);
    }

    // ── commands ──────────────────────────────────────────────────

    /// Append a user message and kick off a run. Illegal while streaming.
    pub fn prompt(self: *Agent, text: []const u8) !void {
        if (self.is_streaming.load(.acquire)) return error.AgentBusy;
        // append user message
        const content = try self.allocator.alloc(ai.types.ContentBlock, 1);
        content[0] = .{ .text = .{ .text = try self.allocator.dupe(u8, text) } };
        try self.transcript.append(.{
            .role = .user,
            .content = content,
            .timestamp = ai.stream.nowMillis(),
        });
        try self.startWorker();
    }

    /// Run another turn without appending a new message — useful when the
    /// caller has manually appended a message to `transcript`.
    pub fn continueRun(self: *Agent) !void {
        if (self.is_streaming.load(.acquire)) return error.AgentBusy;
        try self.startWorker();
    }

    /// Request cancellation and wait for the worker to exit.
    pub fn abort(self: *Agent) void {
        self.cancel.fire();
        if (self.worker) |t| {
            t.join();
            self.worker = null;
        }
        // Reset cancel flag for future runs.
        self.cancel.flag.store(false, .release);
        // Also reset stop-requested so a future run doesn't
        // immediately stop again.
        self.stop_requested.store(false, .release);
    }

    /// vN — request a graceful stop after the current turn finishes.
    /// Unlike `abort()`, this does NOT cancel mid-turn. The current
    /// assistant response completes (including tool executions) and
    /// then the loop exits with an `agent_interrupted` event.
    /// The transcript up to that point is preserved.
    pub fn interrupt(self: *Agent) void {
        ai.log.log(.info, "agent", "interrupt", "graceful stop requested, current turn will finish before stopping", .{});
        self.stop_requested.store(true, .release);
    }

    /// Block until the worker exits (run finished naturally or was aborted).
    pub fn waitForIdle(self: *Agent) void {
        if (self.worker) |t| {
            t.join();
            self.worker = null;
        }
    }

    /// Clear all messages and cancel any in-flight run.
    pub fn reset(self: *Agent) void {
        self.abort();
        for (self.transcript.messages.items) |*m| m.deinit(self.allocator);
        self.transcript.messages.clearRetainingCapacity();
    }

    pub fn setModel(self: *Agent, model: ai.types.Model) void {
        self.model = model;
        self.broadcast(.{ .turn_start = {} }); // placeholder state_changed
    }

    pub fn setTools(self: *Agent, tools: []const at.AgentTool) !void {
        const owned = try self.allocator.alloc(at.AgentTool, tools.len);
        for (tools, 0..) |t, i| owned[i] = t;
        self.allocator.free(self.tools);
        self.tools = owned;
    }

    pub fn setSystemPrompt(self: *Agent, prompt_text: []const u8) !void {
        const owned = try self.allocator.dupe(u8, prompt_text);
        self.allocator.free(self.system_prompt);
        self.system_prompt = owned;
    }

    pub fn setThinking(self: *Agent, level: ai.types.ThinkingLevel) void {
        self.thinking_level = level;
    }

    // ── v0.9.0 steer / v0.9.1 followUp ────────────────────────────

    /// Queue a steering message. §4.3 semantics: the loop drains the
    /// queue at the next tool-results boundary *inside the current
    /// turn*, prepending every queued entry as a user-role message
    /// before the next LLM call. Callable while streaming; returns
    /// immediately.
    pub fn steer(self: *Agent, text: []const u8) !void {
        self.queue_mutex.lockUncancelable(self.io);
        defer self.queue_mutex.unlock(self.io);
        const owned = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned);
        try self.pending_steer.append(self.allocator, owned);
    }

    /// Queue a follow-up message. §4.3 semantics: the loop drains
    /// the queue *after* the current turn ends naturally (not
    /// aborted) and fires each entry as a fresh `prompt`. Callable
    /// while streaming.
    pub fn followUp(self: *Agent, text: []const u8) !void {
        self.queue_mutex.lockUncancelable(self.io);
        defer self.queue_mutex.unlock(self.io);
        const owned = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned);
        try self.pending_followup.append(self.allocator, owned);
    }

    /// Drain the steer queue into an owned slice. Caller frees
    /// each entry + the slice. Used by the loop integration.
    pub fn drainSteerQueue(self: *Agent) ![][]u8 {
        self.queue_mutex.lockUncancelable(self.io);
        defer self.queue_mutex.unlock(self.io);
        const items = try self.allocator.alloc([]u8, self.pending_steer.items.len);
        for (self.pending_steer.items, 0..) |m, i| items[i] = m;
        self.pending_steer.clearRetainingCapacity();
        return items;
    }

    /// Drain the followUp queue into an owned slice. Same contract
    /// as `drainSteerQueue`.
    pub fn drainFollowUpQueue(self: *Agent) ![][]u8 {
        self.queue_mutex.lockUncancelable(self.io);
        defer self.queue_mutex.unlock(self.io);
        const items = try self.allocator.alloc([]u8, self.pending_followup.items.len);
        for (self.pending_followup.items, 0..) |m, i| items[i] = m;
        self.pending_followup.clearRetainingCapacity();
        return items;
    }

    /// Convenience accessors for tests + UIs that want to peek
    /// without draining.
    pub fn pendingSteerCount(self: *Agent) usize {
        self.queue_mutex.lockUncancelable(self.io);
        defer self.queue_mutex.unlock(self.io);
        return self.pending_steer.items.len;
    }

    pub fn pendingFollowUpCount(self: *Agent) usize {
        self.queue_mutex.lockUncancelable(self.io);
        defer self.queue_mutex.unlock(self.io);
        return self.pending_followup.items.len;
    }

    // ── worker ────────────────────────────────────────────────────

    fn startWorker(self: *Agent) !void {
        // Reset any prior transient error.
        if (self.last_error) |d| {
            self.allocator.free(d.message);
            if (d.tool_code) |v| self.allocator.free(v);
            if (d.provider_code) |v| self.allocator.free(v);
            if (d.provider_message) |v| self.allocator.free(v);
            self.last_error = null;
        }

        // vN — reset stop-requested flag for the new run.
        self.stop_requested.store(false, .release);

        self.is_streaming.store(true, .release);
        self.worker = try std.Thread.spawn(.{}, workerFn, .{self});
    }

    /// v1.21.0 — args struct for the agent-loop worker thread.
    /// The agentLoop runs on a separate thread so this Agent's
    /// drain loop can pull events concurrently. Single-thread
    /// agentLoop+drain previously deadlocked on the bounded
    /// channel (see `workerFn` for the full diagnosis).
    const LoopWorkerArgs = struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        transcript: *loop_mod.Transcript,
        config: loop_mod.Config,
        ch: *loop_mod.AgentChannel,
    };

    fn loopWorkerMain(args: LoopWorkerArgs) void {
        loop_mod.agentLoop(args.allocator, args.io, args.transcript, args.config, args.ch);
    }

    /// vN — callback for `loop.Config.stop_requested_fn`. Checks
    /// whether the user has requested a graceful stop via
    /// `Agent.interrupt()`. Returns true when the loop should exit
    /// after the current turn.
    fn stopRequestedFn(userdata: ?*anyopaque) bool {
        const self: *Agent = @ptrCast(@alignCast(userdata.?));
        return self.stop_requested.load(.acquire);
    }

    fn workerFn(self: *Agent) void {
        defer self.is_streaming.store(false, .release);

        // v1.21.0 — channel capacity bumped 128 → 4096 AND `agentLoop`
        // moved to a dedicated thread so this worker can drain
        // concurrently. The previous shape — `agentLoop` and the
        // drain loop running sequentially in this same thread — would
        // deadlock on tool-heavy turns: `agentLoop` calls
        // `out.push(...)` inline for every event (turn_start /
        // message_start / message_update × N / tool_execution_start /
        // tool_execution_end / message_end / turn_end), and once the
        // The provider pushes events synchronously (the whole response
        // is buffered first) and the drain loop runs on the same thread
        // — so this ring must fit the entire turn's event stream without
        // ever blocking on push, because blocking = deadlock.
        //
        // Event budget per turn (worst observed: DeepSeek-v4-flash:cloud):
        //   ~1 000 thinking_delta  (reasoning phase)
        //   ~4 000 text_delta      (content phase, ~4 K tokens)
        //   + start / done / diagnostic + misc overhead
        //   ≈ 5 300 events total
        //
        // 16 384 gives a 3× safety margin over that observed peak.
        // Interactive mode uses 4 096 without blocking, confirming
        // the consumer side is fast enough; 16 384 is conservative.
        // Memory cost is ~5.5 MB at 352 B/slot vs 22 MB at 65 536.
        var ch = loop_mod.AgentChannel.initWithDrop(
            self.allocator,
            16384,
            at.AgentEvent.deinit,
            self.allocator,
        ) catch return;
        defer ch.deinit();

        // Start from the caller-supplied stream_options (auth +
        // transport + timeouts) and overlay per-turn fields like
        // thinking level. The Agent's own `cancel` is what the
        // loop wires up; if the caller passed a cancel of their
        // own it would be ignored — the Agent owns cancellation.
        var stream_opts: ai.registry.StreamOptions = self.stream_options;
        stream_opts.thinking = self.thinking_level;

        // v1.22.0 — wire the tool_gate's hooks into the loop's
        // per-hook userdata fields. `hook_userdata` stays as
        // `self` so `betweenTurnsHook` can reach the Agent's
        // queue state. The tool_gate's hooks (typically
        // `permissions.SessionGates.beforeToolCall` and friends)
        // get their own userdata via the v1.22.0 fallback fields,
        // so a single hook_userdata pointer doesn't have to
        // service both.
        const gate = self.tool_gate orelse ToolGate{};
        const max_hook = self.max_turns_hook orelse MaxTurnsHook{};
        const cfg: loop_mod.Config = .{
            .model = self.model,
            .system_prompt = self.system_prompt,
            .tools = self.tools,
            .registry = self.registry,
            .cancel = &self.cancel,
            .stream_options = stream_opts,
            .http_client = self.http_client,
            .hook_userdata = @ptrCast(self),
            .between_turns = betweenTurnsHook,
            .before_tool_call = gate.before_tool_call,
            .before_tool_call_userdata = gate.userdata,
            .role_denied = gate.role_denied,
            .role_denied_userdata = gate.userdata,
            .max_turns = self.max_turns,
            .on_max_turns = max_hook.on_max_turns,
            .on_max_turns_userdata = max_hook.userdata,
            .reducer_dump_dir = self.reducer_dump_dir,
            .stop_requested_fn = stopRequestedFn,
        };

        const loop_args: LoopWorkerArgs = .{
            .allocator = self.allocator,
            .io = self.io,
            .transcript = &self.transcript,
            .config = cfg,
            .ch = &ch,
        };
        const loop_thread = std.Thread.spawn(.{}, loopWorkerMain, .{loop_args}) catch {
            // Spawn failure: synthesize an agent_error and broadcast
            // synchronously so subscribers see *something* before we
            // return. No drain to do — channel is empty.
            const err_msg = self.allocator.dupe(u8, "failed to spawn agent loop thread") catch return;
            const details: ai.errors.ErrorDetails = .{
                .code = .internal,
                .message = err_msg,
            };
            self.broadcast(.{ .agent_error = details });
            self.allocator.free(err_msg);
            return;
        };

        // Drain events concurrently with `agentLoop`. `ch.next`
        // blocks on `not_empty`; `agentLoop` closes the channel
        // when it returns, which unblocks the final `next` call
        // with `null`.
        while (ch.next(self.io)) |ev| {
            switch (ev) {
                .agent_error => |details| {
                    // Save a copy for inspection via last_error.
                    const copy = details.dupe(self.allocator) catch null;
                    if (copy) |c| self.last_error = c;
                },
                else => {},
            }
            self.broadcast(ev);
            ev.deinit(self.allocator);
        }

        // Join the agentLoop thread. By construction it has already
        // returned (its final action is `out.close(io)`), but join
        // is required to free the thread handle.
        loop_thread.join();
    }

    /// §4.3 between-turns hook: drain both queues into the
    /// transcript and request another turn whenever anything was
    /// appended. Invoked by `loop_mod.agentLoop` after a natural
    /// `keep_going=false` return and before closing.
    fn betweenTurnsHook(userdata: ?*anyopaque, transcript: *loop_mod.Transcript) bool {
        const self: *Agent = @ptrCast(@alignCast(userdata.?));
        var any_appended = false;

        // Drain the followUp queue — fresh user prompts.
        const follow_ups = self.drainFollowUpQueue() catch return false;
        defer self.allocator.free(follow_ups);
        for (follow_ups) |txt| {
            defer self.allocator.free(txt);
            if (appendUserText(self.allocator, transcript, txt)) any_appended = true;
        }

        // Drain the steer queue — mid-conversation steering
        // messages. Semantically same shape as followUp at this
        // boundary (§4.3 distinguishes them by WHEN they drain;
        // between-turns is the same code path for both).
        const steers = self.drainSteerQueue() catch return false;
        defer self.allocator.free(steers);
        for (steers) |txt| {
            defer self.allocator.free(txt);
            if (appendUserText(self.allocator, transcript, txt)) any_appended = true;
        }

        return any_appended;
    }

    fn appendUserText(
        allocator: std.mem.Allocator,
        transcript: *loop_mod.Transcript,
        text: []const u8,
    ) bool {
        const content = allocator.alloc(ai.types.ContentBlock, 1) catch return false;
        content[0] = .{ .text = .{ .text = allocator.dupe(u8, text) catch {
            allocator.free(content);
            return false;
        } } };
        transcript.append(.{
            .role = .user,
            .content = content,
            .timestamp = ai.stream.nowMillis(),
        }) catch {
            allocator.free(content[0].text.text);
            allocator.free(content);
            return false;
        };
        return true;
    }
};
