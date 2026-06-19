//! Faux provider — §M of the spec.
//!
//! Scripted test double. Each call to `stream` takes the next step whose
//! `match` predicate (if any) passes and emits its events into an
//! `AssistantMessageEventStream`.
//!
//! Construction pattern:
//!
//!     var faux = FauxProvider.init(gpa);
//!     defer faux.deinit();
//!     try faux.push(.{ .events = &.{ .{ .text = .{ .text = "hi" } } } });
//!     var stream = try faux.run(io, context);
//!     while (stream.next(io)) |ev| { ... }

const std = @import("std");
const types = @import("../types.zig");
const errors = @import("../errors.zig");
const stream_mod = @import("../stream.zig");
const channel_mod = @import("../channel.zig");
const registry_mod = @import("../registry.zig");

pub const Channel = channel_mod.Channel(stream_mod.StreamEvent);

pub const Match = struct {
    system_prompt_contains: ?[]const u8 = null,
    last_user_text_equals: ?[]const u8 = null,
    messages_count: ?usize = null,
};

pub const Event = union(enum) {
    text: struct {
        text: []const u8,
        chunk_size: usize = 8,
    },
    thinking: struct {
        text: []const u8,
        chunk_size: usize = 8,
        redacted: bool = false,
    },
    tool_call: struct {
        id: []const u8,
        name: []const u8,
        /// Raw JSON args. Will be split into `args_chunk_size` fragments.
        args_json: []const u8,
        args_chunk_size: usize = 16,
    },
    usage: types.Usage,
    done: struct {
        stop_reason: types.StopReason = .stop,
    },
    err: struct {
        code: errors.Code,
        message: []const u8,
        http_status: ?u16 = null,
        retry_after_ms: ?u64 = null,
    },
};

pub const Step = struct {
    match: ?Match = null,
    events: []const Event,
};

pub const CallLog = struct {
    matched_step: usize,
    emitted_event_count: usize,
};

pub const FauxProvider = struct {
    allocator: std.mem.Allocator,
    /// Owned; initial scripts supplied by the test.
    scripts: std.ArrayList(Step) = .empty,
    call_log: std.ArrayList(CallLog) = .empty,
    /// Mutex so push/run can be interleaved safely.
    mutex: std.Io.Mutex = .init,

    pub fn init(allocator: std.mem.Allocator) FauxProvider {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *FauxProvider) void {
        self.scripts.deinit(self.allocator);
        self.call_log.deinit(self.allocator);
    }

    /// Enqueue a script step.
    pub fn push(self: *FauxProvider, step: Step) !void {
        try self.scripts.append(self.allocator, step);
    }

    /// Drive one stream. Consumes the first matching script step and emits
    /// its events into `out`. The caller owns `out` and must drain it.
    ///
    /// `out` must be pre-initialized by the caller (capacity is the
    /// caller's choice; 64 is the spec default).
    ///
    /// This function is synchronous from the caller's perspective but the
    /// channel is written as if by a real streaming producer: the
    /// caller can drive it from a separate fiber/thread via `io.async`.
    pub fn runSync(
        self: *FauxProvider,
        io: std.Io,
        context: types.Context,
        out: *Channel,
    ) !void {
        const step_idx = self.selectStep(context) orelse {
            try out.push(io, .start);
            const details: errors.ErrorDetails = .{
                .code = .internal,
                .message = try self.allocator.dupe(u8, "no faux step matched"),
            };
            out.closeWithFinal(io, .{ .error_ev = details });
            return;
        };
        // Take the step (don't drop — call_log preserves it; we consume
        // from the front so multi-call tests get sequential plays).
        const step = self.scripts.orderedRemove(step_idx);

        try out.push(io, .start);
        var emitted: usize = 1;
        var auto_done = true;

        var text_idx: u32 = 0;
        var think_idx: u32 = 0;
        var tc_idx: u32 = 0;

        for (step.events) |ev| {
            switch (ev) {
                .text => |t| {
                    const cs = @max(1, t.chunk_size);
                    var i: usize = 0;
                    while (i < t.text.len) {
                        const end = @min(i + cs, t.text.len);
                        const delta = try self.allocator.dupe(u8, t.text[i..end]);
                        try out.push(io, .{ .text_delta = .{
                            .block_index = text_idx,
                            .delta = delta,
                        } });
                        emitted += 1;
                        i = end;
                    }
                    text_idx += 1;
                },
                .thinking => |t| {
                    const cs = @max(1, t.chunk_size);
                    var i: usize = 0;
                    while (i < t.text.len) {
                        const end = @min(i + cs, t.text.len);
                        const delta = try self.allocator.dupe(u8, t.text[i..end]);
                        try out.push(io, .{ .thinking_delta = .{
                            .block_index = think_idx,
                            .delta = delta,
                            .redacted = t.redacted,
                        } });
                        emitted += 1;
                        i = end;
                    }
                    think_idx += 1;
                },
                .tool_call => |t| {
                    try out.push(io, .{ .toolcall_start = .{
                        .block_index = tc_idx,
                        .id = try self.allocator.dupe(u8, t.id),
                        .name = try self.allocator.dupe(u8, t.name),
                    } });
                    emitted += 1;
                    const cs = @max(1, t.args_chunk_size);
                    var i: usize = 0;
                    while (i < t.args_json.len) {
                        const end = @min(i + cs, t.args_json.len);
                        const delta = try self.allocator.dupe(u8, t.args_json[i..end]);
                        try out.push(io, .{ .toolcall_delta = .{
                            .block_index = tc_idx,
                            .args_delta = delta,
                        } });
                        emitted += 1;
                        i = end;
                    }
                    try out.push(io, .{ .toolcall_end = .{
                        .block_index = tc_idx,
                        .args_json = try self.allocator.dupe(u8, t.args_json),
                    } });
                    emitted += 1;
                    tc_idx += 1;
                },
                .usage => |u| {
                    try out.push(io, .{ .usage = u });
                    emitted += 1;
                },
                .done => |d| {
                    auto_done = false;
                    out.closeWithFinal(io, .{ .done = .{ .stop_reason = d.stop_reason } });
                    emitted += 1;
                    try self.call_log.append(self.allocator, .{
                        .matched_step = step_idx,
                        .emitted_event_count = emitted,
                    });
                    return;
                },
                .err => |e| {
                    auto_done = false;
                    const details: errors.ErrorDetails = .{
                        .code = e.code,
                        .message = try self.allocator.dupe(u8, e.message),
                        .http_status = e.http_status,
                        .retry_after_ms = e.retry_after_ms,
                    };
                    out.closeWithFinal(io, .{ .error_ev = details });
                    emitted += 1;
                    try self.call_log.append(self.allocator, .{
                        .matched_step = step_idx,
                        .emitted_event_count = emitted,
                    });
                    return;
                },
            }
        }

        if (auto_done) {
            out.closeWithFinal(io, .{ .done = .{ .stop_reason = .stop } });
            emitted += 1;
        }

        try self.call_log.append(self.allocator, .{
            .matched_step = step_idx,
            .emitted_event_count = emitted,
        });
    }

    fn selectStep(self: *FauxProvider, context: types.Context) ?usize {
        for (self.scripts.items, 0..) |step, i| {
            if (step.match == null) return i;
            const m = step.match.?;
            if (m.messages_count) |mc| {
                if (context.messages.len != mc) continue;
            }
            if (m.system_prompt_contains) |s| {
                if (std.mem.indexOf(u8, context.system_prompt, s) == null) continue;
            }
            if (m.last_user_text_equals) |want| {
                var found = false;
                var j: usize = context.messages.len;
                while (j > 0) {
                    j -= 1;
                    const msg = context.messages[j];
                    if (msg.role == .user) {
                        for (msg.content) |cb| switch (cb) {
                            .text => |t| if (std.mem.eql(u8, t.text, want)) {
                                found = true;
                                break;
                            },
                            else => {},
                        };
                        break;
                    }
                }
                if (!found) continue;
            }
            return i;
        }
        return null;
    }

    /// `registry.StreamFn` trampoline that forwards to `runSync`.
    /// `ctx.userdata` must be a `*FauxProvider`. This is the canonical
    /// shim; the per-mode `fauxShim` copies and `compaction.zig`'s
    /// `fauxStreamShim` were replaced by this in the v1.3.0 dedup
    /// (see `DEDUP_PLAN.md` Finding 6).
    pub fn shim(ctx: registry_mod.StreamCtx) anyerror!void {
        const self: *FauxProvider = @ptrCast(@alignCast(ctx.userdata.?));
        try self.runSync(ctx.io, ctx.context, ctx.out);
    }
};

// ─── tests ────────────────────────────────────────────────────────────

fn emptyContext() types.Context {
    return .{
        .system_prompt = "",
        .messages = &.{},
        .tools = &.{},
    };
}

fn newFauxChannel(gpa: std.mem.Allocator) !Channel {
    return try Channel.initWithDrop(gpa, 64, stream_mod.StreamEvent.deinit, gpa);
}

const test_h = @import("../../test_helpers.zig");

test "faux emits streamed text and auto-done" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const gpa = @import("../../global_allocator.zig").gpa;
    var faux = FauxProvider.init(gpa);
    defer faux.deinit();

    try faux.push(.{ .events = &.{
        .{ .text = .{ .text = "hello world", .chunk_size = 4 } },
    } });

    var ch = try newFauxChannel(gpa);
    defer ch.deinit();

    try faux.runSync(io, emptyContext(), &ch);

    var msg = try stream_mod.drainToMessage(&ch, io, gpa, "faux", "faux-1", "faux");
    defer msg.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), msg.content.len);
    try std.testing.expectEqualStrings("hello world", msg.content[0].text.text);
    try std.testing.expectEqual(types.StopReason.stop, msg.stop_reason.?);
}

test "faux emits tool call with streamed args" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const gpa = @import("../../global_allocator.zig").gpa;
    var faux = FauxProvider.init(gpa);
    defer faux.deinit();

    try faux.push(.{ .events = &.{
        .{ .tool_call = .{
            .id = "call_1",
            .name = "read",
            .args_json = "{\"path\":\"/etc/hosts\"}",
            .args_chunk_size = 5,
        } },
        .{ .done = .{ .stop_reason = .tool_use } },
    } });

    var ch = try newFauxChannel(gpa);
    defer ch.deinit();
    try faux.runSync(io, emptyContext(), &ch);

    var msg = try stream_mod.drainToMessage(&ch, io, gpa, null, null, null);
    defer msg.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), msg.content.len);
    try std.testing.expectEqualStrings("call_1", msg.content[0].tool_call.id);
    try std.testing.expectEqualStrings("{\"path\":\"/etc/hosts\"}", msg.content[0].tool_call.arguments_json);
    try std.testing.expectEqual(types.StopReason.tool_use, msg.stop_reason.?);
}

test "faux emits error event instead of done" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const gpa = @import("../../global_allocator.zig").gpa;
    var faux = FauxProvider.init(gpa);
    defer faux.deinit();

    try faux.push(.{ .events = &.{
        .{ .text = .{ .text = "starting...", .chunk_size = 4 } },
        .{ .err = .{ .code = .rate_limited, .message = "slow down", .http_status = 429 } },
    } });

    var ch = try newFauxChannel(gpa);
    defer ch.deinit();
    try faux.runSync(io, emptyContext(), &ch);

    var msg = try stream_mod.drainToMessage(&ch, io, gpa, null, null, null);
    defer msg.deinit(gpa);
    try std.testing.expectEqual(types.StopReason.err, msg.stop_reason.?);
}

test "faux matcher selects by last_user_text_equals" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const gpa = @import("../../global_allocator.zig").gpa;
    var faux = FauxProvider.init(gpa);
    defer faux.deinit();

    try faux.push(.{
        .match = .{ .last_user_text_equals = "hi" },
        .events = &.{.{ .text = .{ .text = "hi back" } }},
    });
    try faux.push(.{
        .match = .{ .last_user_text_equals = "bye" },
        .events = &.{.{ .text = .{ .text = "see ya" } }},
    });

    const user_msg = types.Message{
        .role = .user,
        .content = blk: {
            const c = try gpa.alloc(types.ContentBlock, 1);
            c[0] = .{ .text = .{ .text = try gpa.dupe(u8, "bye") } };
            break :blk c;
        },
        .timestamp = 0,
    };
    defer {
        var m = user_msg;
        m.deinit(gpa);
    }
    const msgs = try gpa.alloc(types.Message, 1);
    defer gpa.free(msgs);
    msgs[0] = user_msg;

    var ch = try newFauxChannel(gpa);
    defer ch.deinit();
    try faux.runSync(io, .{
        .system_prompt = "",
        .messages = msgs,
        .tools = &.{},
    }, &ch);

    var msg = try stream_mod.drainToMessage(&ch, io, gpa, null, null, null);
    defer msg.deinit(gpa);
    try std.testing.expectEqualStrings("see ya", msg.content[0].text.text);
}

test "channel deinit with undrained faux events does not leak" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const gpa = @import("../../global_allocator.zig").gpa;
    var faux = FauxProvider.init(gpa);
    defer faux.deinit();

    try faux.push(.{ .events = &.{
        .{ .text = .{ .text = "abcdefghijklmnop", .chunk_size = 2 } },
        .{ .tool_call = .{ .id = "t1", .name = "x", .args_json = "{\"a\":1}", .args_chunk_size = 2 } },
        .{ .err = .{ .code = .internal, .message = "boom" } },
    } });

    var ch = try newFauxChannel(gpa);
    // fire and forget — drop without draining
    try faux.runSync(io, emptyContext(), &ch);
    ch.deinit();
    // testing.allocator will panic on leak
}
