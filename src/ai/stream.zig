//! AssistantMessageEventStream — §3.4 of the spec.
//!
//! The stream contract:
//!   - Exactly one `start` event, first.
//!   - Any number of text/thinking/toolcall deltas and usage events.
//!   - Exactly one terminal event (`done` or `error_ev`), last.
//!   - The stream function never throws or rejects after returning;
//!     failures become stream events.
//!
//! A stream is a `Channel(StreamEvent)` with a reducer that converts the
//! event log into the final `AssistantMessage`.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const errors = @import("errors.zig");
const channel_mod = @import("channel.zig");

/// Wall-clock milliseconds since epoch. Plain helper, no `std.Io`
/// threading.
///
/// Linux uses the direct syscall (`std.os.linux.clock_gettime`).
/// Darwin / BSD / other POSIX targets call libc's `clock_gettime`
/// via `std.c`. Any failure path returns 0 — callers treat 0 as
/// "clock unavailable" rather than "epoch zero" since no modern
/// system reports 1970-01-01 for its wall clock.
///
/// **Bug fix (v1.3.1):** the pre-v1.3.1 implementation was
/// hardcoded to the Linux path and returned 0 everywhere else,
/// which silently broke every timing-dependent code path on
/// macOS — most visibly two test hangs (`parallel tools:
/// three calls complete in ~max(individual)` busy-waits against
/// `nowMillis`, and the SSE handler-stall timeout compares
/// `now - last_event_ms` which stayed 0). The TUI's `(Ns ·
/// usage)` status line also read `0s` on macOS.
pub fn nowMillis() i64 {
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var ts: linux.timespec = undefined;
        if (linux.clock_gettime(.REALTIME, &ts) == 0) {
            return @as(i64, ts.sec) * 1000 + @divFloor(@as(i64, ts.nsec), std.time.ns_per_ms);
        }
        return 0;
    }
    // POSIX (Darwin / BSD / other) via libc.
    if (builtin.link_libc) {
        var ts: std.c.timespec = undefined;
        if (std.c.clock_gettime(.REALTIME, &ts) == 0) {
            return @as(i64, ts.sec) * 1000 + @divFloor(@as(i64, ts.nsec), std.time.ns_per_ms);
        }
    }
    return 0;
}

pub const Channel = channel_mod.Channel(StreamEvent);

/// Application cancellation flag (§N.2). Shared with tools and transport.
pub const Cancel = struct {
    flag: std.atomic.Value(bool) = .init(false),

    pub fn fire(self: *Cancel) void {
        self.flag.store(true, .release);
    }

    pub fn isFired(self: *const Cancel) bool {
        return self.flag.load(.acquire);
    }
};

pub const EventKind = enum {
    start,
    text_delta,
    thinking_delta,
    toolcall_start,
    toolcall_delta,
    toolcall_end,
    usage,
    /// v1.29.0 — non-terminal "side-channel" event. Providers push
    /// these to populate `Message.Diagnostics` on the final message
    /// without conflating them with the content-stream proper.
    diagnostic,
    /// §6.13 — emitted between retry attempts so the harness, sibling
    /// apps, and UI can display "retrying in Ns" while the retry
    /// backoff sleep runs. Fires BEFORE each sleep (per Q2 decision).
    /// Non-terminal — the stream is still alive.
    provider_retry,
    done,
    error_ev,
};

/// Content-block index, disambiguated by kind (§3.4 invariant 4).
pub const BlockIndex = u32;

/// Every string-payload variant owns the backing memory; the receiver
/// (consumer or the channel on `deinit`) must call `deinit(allocator)`
/// exactly once per event. Providers allocate with the same allocator
/// the channel was created with.
pub const StreamEvent = union(EventKind) {
    start: void,
    text_delta: struct {
        block_index: BlockIndex,
        delta: []const u8,
    },
    thinking_delta: struct {
        block_index: BlockIndex,
        delta: []const u8,
        is_signature: bool = false,
        redacted: bool = false,
    },
    toolcall_start: struct {
        block_index: BlockIndex,
        id: []const u8,
        name: []const u8,
    },
    toolcall_delta: struct {
        block_index: BlockIndex,
        args_delta: []const u8,
    },
    toolcall_end: struct {
        block_index: BlockIndex,
        args_json: []const u8,
    },
    usage: types.Usage,
    /// v1.29.0 — diagnostic side-channel; non-terminal. Strings
    /// are owned by the producer's allocator and freed via the
    /// channel's drop-hook on `deinit` like every other event.
    diagnostic: struct {
        trace_id: ?[]const u8 = null,
        finish_reason_raw: ?[]const u8 = null,
        parts_seen: ?u32 = null,
        candidates_tokens: ?u64 = null,
        thoughts_tokens: ?u64 = null,
    },
    /// §6.13 — retry attempt info. Fires before each backoff sleep.
    /// Strings (provider_code, provider_message) are owned by the
    /// producer's allocator and freed via `deinit`.
    provider_retry: struct {
        /// 1-indexed; attempt 1 = first retry (second call overall).
        attempt: u32,
        max_attempts: u32,
        delay_ms: u32,
        reason: errors.Code,
        provider_code: ?[]const u8 = null,
        provider_message: ?[]const u8 = null,
        http_status: ?u16 = null,
    },
    /// Terminal: stream ended successfully. The final Message is produced
    /// by calling `drainToMessage` or `Reducer.finalize()` after the
    /// terminal — the `done` event intentionally carries no payload so the
    /// build-the-message responsibility is not duplicated across providers.
    done: struct {
        stop_reason: types.StopReason = .stop,
    },
    /// Terminal: stream ended with an error.
    error_ev: errors.ErrorDetails,

    pub fn isTerminal(self: StreamEvent) bool {
        return switch (self) {
            .done, .error_ev => true,
            else => false,
        };
    }

    /// Free the owned string allocations carried by this event.
    /// `allocator` must be the one the producer used to allocate the
    /// event's payload.
    pub fn deinit(self: StreamEvent, allocator: std.mem.Allocator) void {
        switch (self) {
            .start, .usage, .done => {},
            .text_delta => |d| allocator.free(d.delta),
            .provider_retry => |r| {
                if (r.provider_code) |v| allocator.free(v);
                if (r.provider_message) |v| allocator.free(v);
            },
            .thinking_delta => |d| allocator.free(d.delta),
            .toolcall_start => |s| {
                allocator.free(s.id);
                allocator.free(s.name);
            },
            .toolcall_delta => |d| allocator.free(d.args_delta),
            .toolcall_end => |e| allocator.free(e.args_json),
            .diagnostic => |d| {
                if (d.trace_id) |s| allocator.free(s);
                if (d.finish_reason_raw) |s| allocator.free(s);
            },
            .error_ev => |e| {
                allocator.free(e.message);
                if (e.tool_code) |v| allocator.free(v);
                if (e.provider_code) |v| allocator.free(v);
                if (e.provider_message) |v| allocator.free(v);
            },
        }
    }
};

/// Drain a stream channel into a Reducer, freeing each event as it is
/// consumed. Returns the final `types.Message` (role = assistant). Caller
/// owns the returned Message.
pub fn drainToMessage(
    ch: *Channel,
    io: std.Io,
    allocator: std.mem.Allocator,
    provider: ?[]const u8,
    model: ?[]const u8,
    api: ?[]const u8,
) !types.Message {
    var reducer = Reducer.init(allocator);
    defer reducer.deinit();

    while (ch.next(io)) |ev| {
        reducer.apply(ev) catch |e| {
            ev.deinit(allocator);
            return e;
        };
        ev.deinit(allocator);
    }
    return try reducer.finalize(provider, model, api);
}

/// Reducer state: accumulates deltas into content blocks so the producer
/// can emit a final `types.Message` at terminal time. Each reducer instance
/// is owned by one producer fiber.
pub const Reducer = struct {
    allocator: std.mem.Allocator,
    text_blocks: std.ArrayList(std.ArrayList(u8)),
    thinking_blocks: std.ArrayList(std.ArrayList(u8)),
    thinking_signatures: std.ArrayList(?[]u8),
    thinking_redacted: std.ArrayList(bool),
    tool_calls: std.ArrayList(ToolCallState),
    usage: types.Usage = .{},
    stop_reason: ?types.StopReason = null,
    error_message: ?[]u8 = null,
    /// Order in which blocks are opened, for later ordered emission.
    /// Each entry is {kind, logical_index_within_kind}.
    block_order: std.ArrayList(BlockRef),
    /// v1.29.0 — diagnostic state accumulated from `.diagnostic`
    /// side-channel events plus per-event counters. Surfaced on the
    /// final Message via `finalize`.
    diag: types.Diagnostics = .{},

    const ToolCallState = struct {
        id: []u8,
        name: []u8,
        args: std.ArrayList(u8),
    };

    pub const BlockKind = enum { text, thinking, tool_call };
    pub const BlockRef = struct { kind: BlockKind, index: u32 };

    pub fn init(allocator: std.mem.Allocator) Reducer {
        return .{
            .allocator = allocator,
            .text_blocks = .empty,
            .thinking_blocks = .empty,
            .thinking_signatures = .empty,
            .thinking_redacted = .empty,
            .tool_calls = .empty,
            .block_order = .empty,
        };
    }

    /// Free internal buffers. Must NOT be called after `finalize` has
    /// transferred ownership of the content slices to a `types.Message`.
    pub fn deinit(self: *Reducer) void {
        for (self.text_blocks.items) |*b| b.deinit(self.allocator);
        self.text_blocks.deinit(self.allocator);
        for (self.thinking_blocks.items) |*b| b.deinit(self.allocator);
        self.thinking_blocks.deinit(self.allocator);
        for (self.thinking_signatures.items) |s| if (s) |v| self.allocator.free(v);
        self.thinking_signatures.deinit(self.allocator);
        self.thinking_redacted.deinit(self.allocator);
        for (self.tool_calls.items) |*tc| {
            self.allocator.free(tc.id);
            self.allocator.free(tc.name);
            tc.args.deinit(self.allocator);
        }
        self.tool_calls.deinit(self.allocator);
        self.block_order.deinit(self.allocator);
        if (self.error_message) |m| self.allocator.free(m);
        self.diag.deinit(self.allocator);
    }

    fn ensureTextBlock(self: *Reducer, idx: u32) !void {
        while (self.text_blocks.items.len <= idx) {
            try self.text_blocks.append(self.allocator, .empty);
            try self.block_order.append(self.allocator, .{ .kind = .text, .index = @intCast(self.text_blocks.items.len - 1) });
        }
    }

    fn ensureThinkingBlock(self: *Reducer, idx: u32) !void {
        while (self.thinking_blocks.items.len <= idx) {
            try self.thinking_blocks.append(self.allocator, .empty);
            try self.thinking_signatures.append(self.allocator, null);
            try self.thinking_redacted.append(self.allocator, false);
            try self.block_order.append(self.allocator, .{ .kind = .thinking, .index = @intCast(self.thinking_blocks.items.len - 1) });
        }
    }

    /// Called by the producer for each event it emits (before or after
    /// pushing — doesn't matter, order-wise, because the reducer doesn't
    /// observe other consumers).
    pub fn apply(self: *Reducer, ev: StreamEvent) !void {
        switch (ev) {
            .start, .provider_retry => {},
            .text_delta => |d| {
                try self.ensureTextBlock(d.block_index);
                try self.text_blocks.items[d.block_index].appendSlice(self.allocator, d.delta);
                self.diag.text_event_count +%= 1;
            },
            .thinking_delta => |d| {
                try self.ensureThinkingBlock(d.block_index);
                if (d.is_signature) {
                    const dst = &self.thinking_signatures.items[d.block_index];
                    if (dst.*) |old| self.allocator.free(old);
                    dst.* = try self.allocator.dupe(u8, d.delta);
                } else {
                    try self.thinking_blocks.items[d.block_index].appendSlice(self.allocator, d.delta);
                }
                if (d.redacted) self.thinking_redacted.items[d.block_index] = true;
                self.diag.thinking_event_count +%= 1;
            },
            .toolcall_start => |s| {
                while (self.tool_calls.items.len <= s.block_index) {
                    try self.tool_calls.append(self.allocator, .{
                        .id = try self.allocator.dupe(u8, ""),
                        .name = try self.allocator.dupe(u8, ""),
                        .args = .empty,
                    });
                    try self.block_order.append(self.allocator, .{ .kind = .tool_call, .index = @intCast(self.tool_calls.items.len - 1) });
                }
                // Replace id/name with the authoritative ones.
                const tc = &self.tool_calls.items[s.block_index];
                self.allocator.free(tc.id);
                self.allocator.free(tc.name);
                tc.id = try self.allocator.dupe(u8, s.id);
                tc.name = try self.allocator.dupe(u8, s.name);
                self.diag.tool_call_event_count +%= 1;
            },
            .toolcall_delta => |d| {
                if (d.block_index >= self.tool_calls.items.len) return; // protocol violation — ignored here, caller should have emitted error_ev
                try self.tool_calls.items[d.block_index].args.appendSlice(self.allocator, d.args_delta);
            },
            .toolcall_end => |e| {
                if (e.block_index >= self.tool_calls.items.len) return;
                const tc = &self.tool_calls.items[e.block_index];
                // Replace with authoritative args_json only if the event
                // supplied one. Empty args_json means "providers that don't
                // emit a full authoritative string at end-of-call (e.g.,
                // Anthropic) — trust the concatenated deltas instead".
                if (e.args_json.len > 0 and !std.mem.eql(u8, tc.args.items, e.args_json)) {
                    tc.args.clearRetainingCapacity();
                    try tc.args.appendSlice(self.allocator, e.args_json);
                }
            },
            .usage => |u| self.usage = u,
            .diagnostic => |d| {
                if (d.trace_id) |s| {
                    if (self.diag.trace_id) |old| self.allocator.free(old);
                    self.diag.trace_id = try self.allocator.dupe(u8, s);
                }
                if (d.finish_reason_raw) |s| {
                    if (self.diag.finish_reason_raw) |old| self.allocator.free(old);
                    self.diag.finish_reason_raw = try self.allocator.dupe(u8, s);
                }
                if (d.parts_seen) |n| self.diag.parts_seen = n;
                if (d.candidates_tokens) |n| self.diag.candidates_tokens = n;
                if (d.thoughts_tokens) |n| self.diag.thoughts_tokens = n;
            },
            .done => |d| {
                self.stop_reason = d.stop_reason;
            },
            .error_ev => |e| {
                self.stop_reason = .err;
                if (self.error_message) |m| self.allocator.free(m);
                self.error_message = try self.allocator.dupe(u8, e.message);
            },
        }
    }

    /// v1.29.0 — would `finalize` produce a degenerate (zero
    /// content blocks) message right now? Used by the agent loop
    /// to decide whether to dump reducer state to disk before
    /// finalize transfers ownership of the buffers.
    pub fn isLikelyDegenerate(self: *const Reducer) bool {
        if (self.error_message != null) return false;
        if (self.stop_reason) |sr| if (sr == .err) return false;
        for (self.block_order.items) |ref| switch (ref.kind) {
            .text => {
                if (self.text_blocks.items[ref.index].items.len > 0) return false;
            },
            .thinking => {
                const idx = ref.index;
                if (self.thinking_blocks.items[idx].items.len > 0) return false;
                if (self.thinking_signatures.items[idx] != null) return false;
                if (self.thinking_redacted.items[idx]) return false;
            },
            .tool_call => return false, // tool_calls always emit content blocks
        };
        return true;
    }

    /// v1.29.0 — render a JSON snapshot of the current state for
    /// diagnostic dumps. Pure (no IO); caller writes the result to
    /// disk if desired. Safe to call at any point in the reducer's
    /// lifetime (including before `finalize`); does not transfer
    /// ownership.
    pub fn snapshotJson(self: *const Reducer, allocator: std.mem.Allocator) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        try buf.appendSlice(allocator, "{\"version\":1");

        try appendStopReason(allocator, &buf, self);
        try appendErrorMessage(allocator, &buf, self);
        try appendDiagnosticsSnapshot(allocator, &buf, self);
        try appendBlockOrderSnapshot(allocator, &buf, self);
        try appendTextBlocksSnapshot(allocator, &buf, self);
        try appendThinkingBlocksSnapshot(allocator, &buf, self);
        try appendToolCallsSnapshot(allocator, &buf, self);

        try buf.append(allocator, '}');
        return try buf.toOwnedSlice(allocator);
    }

    fn appendStopReason(_allocator: std.mem.Allocator, buf: *std.ArrayList(u8), self: *const Reducer) !void {
        if (self.stop_reason) |sr| {
            try buf.appendSlice(_allocator, ",\"stopReason\":\"");
            try buf.appendSlice(_allocator, sr.toString());
            try buf.append(_allocator, '"');
        }
    }

    fn appendErrorMessage(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), self: *const Reducer) !void {
        if (self.error_message) |m| {
            try buf.appendSlice(allocator, ",\"errorMessage\":");
            try appendJsonStrLocal(allocator, buf, m);
        }
    }

    fn appendDiagnosticsSnapshot(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), self: *const Reducer) !void {
        try buf.appendSlice(allocator, ",\"diagnostics\":{");
        var first_d = true;
        if (self.diag.trace_id) |s| {
            try writeFieldStr(allocator, buf, &first_d, "traceId", s);
        }
        if (self.diag.finish_reason_raw) |s| {
            try writeFieldStr(allocator, buf, &first_d, "finishReasonRaw", s);
        }
        try writeFieldUint(allocator, buf, &first_d, "partsSeen", self.diag.parts_seen);
        if (self.diag.candidates_tokens) |n| try writeFieldUint(allocator, buf, &first_d, "candidatesTokens", n);
        if (self.diag.thoughts_tokens) |n| try writeFieldUint(allocator, buf, &first_d, "thoughtsTokens", n);
        try writeFieldUint(allocator, buf, &first_d, "textEvents", self.diag.text_event_count);
        try writeFieldUint(allocator, buf, &first_d, "thinkingEvents", self.diag.thinking_event_count);
        try writeFieldUint(allocator, buf, &first_d, "toolCallEvents", self.diag.tool_call_event_count);
        try buf.append(allocator, '}');
    }

    fn appendBlockOrderSnapshot(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), self: *const Reducer) !void {
        try buf.appendSlice(allocator, ",\"blockOrder\":[");
        for (self.block_order.items, 0..) |ref, i| {
            if (i > 0) try buf.append(allocator, ',');
            try buf.appendSlice(allocator, "{\"kind\":\"");
            try buf.appendSlice(allocator, switch (ref.kind) {
                .text => "text",
                .thinking => "thinking",
                .tool_call => "toolCall",
            });
            const ix_str = try std.fmt.allocPrint(allocator, "\",\"index\":{d}}}", .{ref.index});
            defer allocator.free(ix_str);
            try buf.appendSlice(allocator, ix_str);
        }
        try buf.append(allocator, ']');
    }

    fn appendTextBlocksSnapshot(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), self: *const Reducer) !void {
        try buf.appendSlice(allocator, ",\"textBlocks\":[");
        for (self.text_blocks.items, 0..) |b, i| {
            if (i > 0) try buf.append(allocator, ',');
            try buf.appendSlice(allocator, "{\"len\":");
            const ln = try std.fmt.allocPrint(allocator, "{d}", .{b.items.len});
            defer allocator.free(ln);
            try buf.appendSlice(allocator, ln);
            try buf.appendSlice(allocator, ",\"text\":");
            try appendJsonStrLocal(allocator, buf, b.items);
            try buf.append(allocator, '}');
        }
        try buf.append(allocator, ']');
    }

    fn appendThinkingBlocksSnapshot(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), self: *const Reducer) !void {
        try buf.appendSlice(allocator, ",\"thinkingBlocks\":[");
        for (self.thinking_blocks.items, 0..) |b, i| {
            if (i > 0) try buf.append(allocator, ',');
            try buf.appendSlice(allocator, "{\"len\":");
            const ln = try std.fmt.allocPrint(allocator, "{d}", .{b.items.len});
            defer allocator.free(ln);
            try buf.appendSlice(allocator, ln);
            try buf.appendSlice(allocator, ",\"text\":");
            try appendJsonStrLocal(allocator, buf, b.items);
            const sig = self.thinking_signatures.items[i];
            if (sig) |sv| {
                try buf.appendSlice(allocator, ",\"signature\":");
                try appendJsonStrLocal(allocator, buf, sv);
            }
            if (self.thinking_redacted.items[i]) try buf.appendSlice(allocator, ",\"redacted\":true");
            try buf.append(allocator, '}');
        }
        try buf.append(allocator, ']');
    }

    fn appendToolCallsSnapshot(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), self: *const Reducer) !void {
        try buf.appendSlice(allocator, ",\"toolCalls\":[");
        for (self.tool_calls.items, 0..) |tc, i| {
            if (i > 0) try buf.append(allocator, ',');
            try buf.appendSlice(allocator, "{\"id\":");
            try appendJsonStrLocal(allocator, buf, tc.id);
            try buf.appendSlice(allocator, ",\"name\":");
            try appendJsonStrLocal(allocator, buf, tc.name);
            try buf.appendSlice(allocator, ",\"args\":");
            try appendJsonStrLocal(allocator, buf, tc.args.items);
            try buf.append(allocator, '}');
        }
        try buf.append(allocator, ']');
    }

    /// Transfer accumulated state into a `types.Message` (role = assistant).
    /// After calling this, the Reducer MUST NOT be deinit'd — ownership of
    /// the content slices moved to the returned message. Call this exactly
    /// once, and then call `abandonBuffers` to zero out the reducer.
    pub fn finalize(self: *Reducer, provider: ?[]const u8, model: ?[]const u8, api: ?[]const u8) !types.Message {
        const allocator = self.allocator;

        var content: std.ArrayList(types.ContentBlock) = .empty;
        errdefer {
            for (content.items) |cb| cb.deinit(allocator);
            content.deinit(allocator);
        }

        for (self.block_order.items) |ref| switch (ref.kind) {
            .text => {
                const raw = self.text_blocks.items[ref.index];
                if (raw.items.len == 0) continue;
                const owned = try allocator.dupe(u8, raw.items);
                try content.append(allocator, .{ .text = .{ .text = owned } });
            },
            .thinking => {
                const raw = self.thinking_blocks.items[ref.index];
                const sig = self.thinking_signatures.items[ref.index];
                const red = self.thinking_redacted.items[ref.index];
                if (raw.items.len == 0 and sig == null and !red) continue;
                const owned_text = try allocator.dupe(u8, raw.items);
                errdefer allocator.free(owned_text);
                const owned_sig = if (sig) |v| try allocator.dupe(u8, v) else null;
                try content.append(allocator, .{ .thinking = .{
                    .thinking = owned_text,
                    .thinking_signature = owned_sig,
                    .redacted = red,
                } });
            },
            .tool_call => {
                const tc = self.tool_calls.items[ref.index];
                const owned_id = try allocator.dupe(u8, tc.id);
                errdefer allocator.free(owned_id);
                const owned_name = try allocator.dupe(u8, tc.name);
                errdefer allocator.free(owned_name);
                const owned_args = try allocator.dupe(u8, tc.args.items);
                try content.append(allocator, .{ .tool_call = .{
                    .id = owned_id,
                    .name = owned_name,
                    .arguments_json = owned_args,
                } });
            },
        };

        const owned_err = if (self.error_message) |m| try allocator.dupe(u8, m) else null;
        errdefer if (owned_err) |s| allocator.free(s);
        const owned_provider = if (provider) |v| try allocator.dupe(u8, v) else null;
        errdefer if (owned_provider) |s| allocator.free(s);
        const owned_model = if (model) |v| try allocator.dupe(u8, v) else null;
        errdefer if (owned_model) |s| allocator.free(s);
        const owned_api = if (api) |v| try allocator.dupe(u8, v) else null;
        errdefer if (owned_api) |s| allocator.free(s);

        // v1.29.0 — attach diagnostics. `was_degenerate` fires when
        // finalize is about to ship an assistant message with zero
        // content blocks AND no error path was taken (clean STOP →
        // nothing). Other fields are absorbed verbatim from
        // `.diagnostic` events the provider pushed during streaming.
        var diag = self.diag;
        diag.was_degenerate = (content.items.len == 0) and
            (self.error_message == null) and
            ((self.stop_reason orelse .stop) != .err);
        // Move ownership of diag's owned strings to the message
        // allocator (currently they're already on `self.allocator`,
        // which IS the message's allocator). Zero out the reducer's
        // copy so its `deinit` can no longer free them.
        self.diag = .{};
        const diag_attached: ?types.Diagnostics = if (diag.isEmpty()) blk: {
            // Free the owned strings since we're throwing the struct away.
            diag.deinit(allocator);
            break :blk null;
        } else diag;

        const content_slice = try content.toOwnedSlice(allocator);
        errdefer {
            for (content_slice) |cb| cb.deinit(allocator);
            allocator.free(content_slice);
        }

        // Build message as local so errdefer can clean up
        // if any of the later fields fail.
        //
        // v1.29.10 — only stamp usage when a real `.usage` event was
        // received. A zero-valued Usage struct coerces to non-null `?Usage` and
        // makes downstream display code show "in 0 + out 0 tokens".
        const usage_stamp: ?types.Usage = if (self.usage.total() > 0) self.usage else null;
        var msg: types.Message = .{
            .role = .assistant,
            .content = content_slice,
            .timestamp = nowMillis(),
            .stop_reason = self.stop_reason orelse .stop,
            .usage = usage_stamp,
            .error_message = owned_err,
            .provider = owned_provider,
            .model = owned_model,
            .api = owned_api,
            .diagnostics = diag_attached,
        };
        errdefer msg.deinit(allocator);
        return msg;
    }
};

// ─── v1.29.0 — provider-side helpers ───────────────────────────────

/// Aggregates the metrics every provider Driver collects so the
/// degenerate-response check + final `.diagnostic` push can be
/// shared across providers without each one re-implementing it.
pub const TerminalInfo = struct {
    provider: []const u8,
    stop_reason: types.StopReason = .stop,
    /// At least one `.text_delta` of non-zero length was pushed.
    text_seen: bool = false,
    /// At least one non-signature `.thinking_delta` of non-zero
    /// length was pushed.
    thinking_seen: bool = false,
    tool_count: u32 = 0,
    /// Number of provider events that carried at least one
    /// `content.parts` entry (Gemini-shaped) or equivalent. `0`
    /// plus a clean stop_reason is the empty-response signature.
    parts_seen: u32 = 0,
    /// Raw provider stop string (`STOP`, `tool_calls`, `end_turn`),
    /// duped before we put it on the channel. Caller-owned slice;
    /// safe to be from an arena that's about to drop.
    finish_reason_raw: ?[]const u8 = null,
    candidates_tokens: ?u64 = null,
    thoughts_tokens: ?u64 = null,
};

/// v1.29.0 — provider-side terminal close. Pushes a final
/// `.diagnostic` event with the captured metrics, then closes the
/// channel with either `.done` or `.error_ev{empty_response}`
/// depending on whether any content was emitted.
///
/// Best-effort: if `push` fails because the channel was already
/// closed we still close gracefully. Any allocations made for the
/// diagnostic payload are freed on that path.
pub fn closeWithDiagnostics(
    out: *Channel,
    io: std.Io,
    allocator: std.mem.Allocator,
    info: TerminalInfo,
) void {
    const fr_dup_opt: ?[]u8 = if (info.finish_reason_raw) |s|
        allocator.dupe(u8, s) catch null
    else
        null;
    out.push(io, .{ .diagnostic = .{
        .finish_reason_raw = fr_dup_opt,
        .parts_seen = info.parts_seen,
        .candidates_tokens = info.candidates_tokens,
        .thoughts_tokens = info.thoughts_tokens,
    } }) catch {
        if (fr_dup_opt) |s| allocator.free(s);
    };

    const has_content = info.text_seen or info.thinking_seen or info.tool_count > 0;
    if (!has_content and info.stop_reason == .stop) {
        const msg = std.fmt.allocPrint(
            allocator,
            "{s} returned stop_reason={s} but emitted no content (parts_seen={d}, candidates_tokens={?d}, thoughts_tokens={?d}). Likely model regression — re-run with adjusted thinking budget or a format-reminder nudge.",
            .{ info.provider, info.finish_reason_raw orelse "stop", info.parts_seen, info.candidates_tokens, info.thoughts_tokens },
        ) catch return;
        out.closeWithFinal(io, .{ .error_ev = .{
            .code = errors.Code.empty_response,
            .message = msg,
        } });
    } else {
        out.closeWithFinal(io, .{ .done = .{ .stop_reason = info.stop_reason } });
    }
}

/// v1.29.0 — push a trace_id diagnostic right after the `start`
/// event. Channel takes ownership of `trace_id` on success; on
/// channel-closed failure the slice is freed locally so callers
/// don't have to manage cleanup. Pass `null` to skip.
pub fn pushTraceId(
    out: *Channel,
    io: std.Io,
    allocator: std.mem.Allocator,
    trace_id: ?[]u8,
) void {
    const tid = trace_id orelse return;
    out.push(io, .{ .diagnostic = .{ .trace_id = tid } }) catch {
        allocator.free(tid);
    };
}

/// v1.3.0 dedup — close the channel with a canonical error event for
/// the `EventHandlerError` set returned by `http.driveSseFromBytes`.
/// Every provider's `runFromSseWithTrace` carried the same
/// `switch (e) { .Aborted, .ProtocolViolation, .OutOfMemory,
/// .Timeout, .Handler => … }` block (only the message text differed
/// cosmetically); this is the single canonical version. See
/// `DEDUP_PLAN.md` Finding 3.
///
/// Messages use the most-descriptive variant (openai-chat's).
/// `error.Timeout`'s message mentions `timeouts.event_gap_ms` to
/// match the v1.10 diagnostic.
///
/// **Review fix (multi-model v1.3.1):** the original per-provider
/// `try allocator.dupe(...)` propagated OOM to the caller; the dedup'd
/// `catch return` variant silently left the channel **open**, which
/// blocks consumers indefinitely (`Channel.next` waits on
/// `not_empty` forever). We must *always* close. The `ErrorDetails.message`
/// field is a borrowed slice the channel drop-hook frees, so it must
/// be allocator-owned (a string literal would crash on free). On
/// `dupe` failure we fall back to a zero-length owned allocation
/// (`alloc(u8, 0)`) so the channel still closes with a valid, freeable
/// (empty) message rather than hanging the consumer.
pub fn closeOnSseError(
    out: *Channel,
    io: std.Io,
    allocator: std.mem.Allocator,
    e: anyerror,
) void {
    // Resolve the canonical (code, text) for the error, then build an
    // owned message — falling back to an empty owned slice on OOM so
    // the channel is *always* closed.
    const code: errors.Code = switch (e) {
        error.Aborted => .aborted,
        error.ProtocolViolation => .protocol_violation,
        error.OutOfMemory => .internal,
        error.Timeout => .timeout,
        error.Handler => .internal,
        else => .internal,
    };
    const text: []const u8 = switch (e) {
        error.Aborted => "cancelled",
        error.ProtocolViolation => "malformed SSE stream",
        error.OutOfMemory => "out of memory",
        error.Timeout => "event gap exceeded timeouts.event_gap_ms",
        error.Handler => "handler failure",
        else => "unexpected stream error",
    };
    const msg = allocator.dupe(u8, text) catch
        (allocator.alloc(u8, 0) catch return);
    out.closeWithFinal(io, .{ .error_ev = .{
        .code = code,
        .message = msg,
    } });
}

// ─── v1.29.0 helpers shared by Reducer.snapshotJson ────────────────

fn appendJsonStrLocal(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    s: []const u8,
) !void {
    try buf.append(allocator, '"');
    for (s) |c| switch (c) {
        '"' => try buf.appendSlice(allocator, "\\\""),
        '\\' => try buf.appendSlice(allocator, "\\\\"),
        '\n' => try buf.appendSlice(allocator, "\\n"),
        '\r' => try buf.appendSlice(allocator, "\\r"),
        '\t' => try buf.appendSlice(allocator, "\\t"),
        0x08 => try buf.appendSlice(allocator, "\\b"),
        0x0c => try buf.appendSlice(allocator, "\\f"),
        else => {
            if (c < 0x20) {
                const esc = try std.fmt.allocPrint(allocator, "\\u{x:0>4}", .{c});
                defer allocator.free(esc);
                try buf.appendSlice(allocator, esc);
            } else try buf.append(allocator, c);
        },
    };
    try buf.append(allocator, '"');
}

fn writeFieldStr(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    first: *bool,
    name: []const u8,
    value: []const u8,
) !void {
    if (!first.*) try buf.append(allocator, ',');
    first.* = false;
    try buf.append(allocator, '"');
    try buf.appendSlice(allocator, name);
    try buf.appendSlice(allocator, "\":");
    try appendJsonStrLocal(allocator, buf, value);
}

fn writeFieldUint(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    first: *bool,
    name: []const u8,
    value: u64,
) !void {
    if (!first.*) try buf.append(allocator, ',');
    first.* = false;
    const piece = try std.fmt.allocPrint(allocator, "\"{s}\":{d}", .{ name, value });
    defer allocator.free(piece);
    try buf.appendSlice(allocator, piece);
}

// ─── tests ────────────────────────────────────────────────────────────

test "Reducer accumulates text deltas into final message" {
    const gpa = @import("../global_allocator.zig").gpa;
    var r = Reducer.init(gpa);
    defer r.deinit();

    try r.apply(.start);
    try r.apply(.{ .text_delta = .{ .block_index = 0, .delta = "Hel" } });
    try r.apply(.{ .text_delta = .{ .block_index = 0, .delta = "lo " } });
    try r.apply(.{ .text_delta = .{ .block_index = 0, .delta = "world" } });
    try r.apply(.{ .usage = .{ .input = 5, .output = 3 } });

    var msg = try r.finalize(null, null, null);
    defer msg.deinit(gpa);

    try std.testing.expectEqual(types.Role.assistant, msg.role);
    try std.testing.expectEqual(@as(usize, 1), msg.content.len);
    try std.testing.expectEqualStrings("Hello world", msg.content[0].text.text);
    try std.testing.expectEqual(@as(u64, 5), msg.usage.?.input);
}

test "Reducer handles tool call sequence" {
    const gpa = @import("../global_allocator.zig").gpa;
    var r = Reducer.init(gpa);
    defer r.deinit();

    try r.apply(.start);
    try r.apply(.{ .toolcall_start = .{ .block_index = 0, .id = "toolu_1", .name = "read" } });
    try r.apply(.{ .toolcall_delta = .{ .block_index = 0, .args_delta = "{\"path\":" } });
    try r.apply(.{ .toolcall_delta = .{ .block_index = 0, .args_delta = "\"/tmp\"}" } });
    try r.apply(.{ .toolcall_end = .{ .block_index = 0, .args_json = "{\"path\":\"/tmp\"}" } });

    var msg = try r.finalize("anthropic", "claude-sonnet", "anthropic-messages");
    defer msg.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), msg.content.len);
    const tc = msg.content[0].tool_call;
    try std.testing.expectEqualStrings("toolu_1", tc.id);
    try std.testing.expectEqualStrings("read", tc.name);
    try std.testing.expectEqualStrings("{\"path\":\"/tmp\"}", tc.arguments_json);
    try std.testing.expectEqualStrings("anthropic", msg.provider.?);
}

test "Reducer interleaves thinking, text, tool-call by open order" {
    const gpa = @import("../global_allocator.zig").gpa;
    var r = Reducer.init(gpa);
    defer r.deinit();

    try r.apply(.{ .thinking_delta = .{ .block_index = 0, .delta = "let me think" } });
    try r.apply(.{ .text_delta = .{ .block_index = 0, .delta = "ok" } });
    try r.apply(.{ .toolcall_start = .{ .block_index = 0, .id = "t1", .name = "x" } });
    try r.apply(.{ .toolcall_end = .{ .block_index = 0, .args_json = "{}" } });

    var msg = try r.finalize(null, null, null);
    defer msg.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 3), msg.content.len);
    try std.testing.expect(msg.content[0] == .thinking);
    try std.testing.expect(msg.content[1] == .text);
    try std.testing.expect(msg.content[2] == .tool_call);
}

test "Cancel is observable across threads" {
    var c = Cancel{};
    try std.testing.expect(!c.isFired());
    c.fire();
    try std.testing.expect(c.isFired());
}

test "Reducer.apply absorbs .diagnostic events, finalize attaches non-empty (v1.29.0)" {
    const gpa = @import("../global_allocator.zig").gpa;
    var r = Reducer.init(gpa);
    defer r.deinit();

    // `apply` borrows: it dupes the strings into reducer state.
    // Use literals so we don't have to free anything afterwards.
    try r.apply(.{ .diagnostic = .{
        .trace_id = "trace-7",
        .parts_seen = 4,
        .candidates_tokens = 0,
        .thoughts_tokens = 561,
    } });
    try r.apply(.{ .text_delta = .{ .block_index = 0, .delta = "hello" } });

    var msg = try r.finalize("anthropic", "claude-sonnet-4", "anthropic-messages");
    defer msg.deinit(gpa);

    try std.testing.expect(msg.diagnostics != null);
    const d = msg.diagnostics.?;
    try std.testing.expectEqualStrings("trace-7", d.trace_id.?);
    try std.testing.expectEqual(@as(u32, 4), d.parts_seen);
    try std.testing.expectEqual(@as(?u64, 0), d.candidates_tokens);
    try std.testing.expectEqual(@as(?u64, 561), d.thoughts_tokens);
    try std.testing.expectEqual(@as(u32, 1), d.text_event_count);
    try std.testing.expect(!d.was_degenerate);
}

test "Reducer.finalize sets was_degenerate when message has zero content (v1.29.0)" {
    const gpa = @import("../global_allocator.zig").gpa;
    var r = Reducer.init(gpa);
    defer r.deinit();
    try r.apply(.{ .done = .{ .stop_reason = .stop } });

    var msg = try r.finalize(null, null, null);
    defer msg.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), msg.content.len);
    try std.testing.expect(msg.diagnostics != null);
    try std.testing.expect(msg.diagnostics.?.was_degenerate);
}

test "Reducer.isLikelyDegenerate flips false on tool_call (v1.29.0)" {
    const gpa = @import("../global_allocator.zig").gpa;
    var r = Reducer.init(gpa);
    defer r.deinit();
    try std.testing.expect(r.isLikelyDegenerate());
    try r.apply(.{ .toolcall_start = .{ .block_index = 0, .id = "id", .name = "read" } });
    try std.testing.expect(!r.isLikelyDegenerate());
}

test "Reducer.snapshotJson contains structural keys + diagnostics (v1.29.0)" {
    const gpa = @import("../global_allocator.zig").gpa;
    var r = Reducer.init(gpa);
    defer r.deinit();
    try r.apply(.{ .text_delta = .{ .block_index = 0, .delta = "abc" } });
    try r.apply(.{ .diagnostic = .{ .finish_reason_raw = "STOP", .parts_seen = 2 } });

    const snap = try r.snapshotJson(gpa);
    defer gpa.free(snap);
    try std.testing.expect(std.mem.indexOf(u8, snap, "\"version\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, snap, "\"diagnostics\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snap, "\"finishReasonRaw\":\"STOP\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snap, "\"partsSeen\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, snap, "\"blockOrder\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snap, "\"textBlocks\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snap, "abc") != null);
}

test "nowMillis: returns a non-zero monotonically-advancing timestamp" {
    // Regression gate for the macOS hang: pre-v1.3.1 this returned
    // 0 on every non-Linux target, which looped forever in any
    // test that busy-waited against it. A modern wall-clock is
    // well past ~1.7e12 ms (2024+). Two consecutive reads a short
    // busy-loop apart must advance (or at minimum not go backward).
    const t1 = nowMillis();
    try std.testing.expect(t1 > 1_700_000_000_000);
    // Consume a handful of clock ticks so t2 ≥ t1 reliably even
    // when the wall clock has 1 ms resolution on the host.
    var acc: u64 = 0;
    var i: usize = 0;
    while (i < 100_000) : (i += 1) acc +%= i;
    std.mem.doNotOptimizeAway(acc);
    const t2 = nowMillis();
    try std.testing.expect(t2 >= t1);
}
