//! Memory guardrail — nudges the agent to save memory on finish_task.
//!
//! This is a soft nudge, not forced extraction. The agent already has the
//! memory_save tool and can call it whenever. But sometimes the agent
//! forgets. This guardrail reminds it.
//!
//! Wired into the loop's betweenTurns hook alongside the existing
//! guardrails. When finish_task is triggered and no memory was saved
//! this session, it injects a synthetic user message asking the agent
//! to consider saving important facts before finishing.

const std = @import("std");
const ai = struct {
    pub const types = @import("../../ai/types.zig");
    pub const stream = @import("../../ai/stream.zig");
    pub const log = @import("../../ai/log.zig");
};
const at = @import("../types.zig");

/// Configuration for the memory guardrail.
pub const Config = struct {
    /// Whether the nudge is enabled (default: false — opt-in).
    enabled: bool = false,
    /// Max nudges per session (default: 1 — one reminder is enough).
    max_nudges: u32 = 1,
};

/// State for the memory guardrail.
pub const MemoryGuardrail = struct {
    config: Config,
    /// Whether the agent has saved any memory this session.
    session_has_saved: bool = false,
    /// How many times we've nudged this session.
    nudge_count: u32 = 0,

    pub fn init(config: Config) MemoryGuardrail {
        return .{
            .config = config,
            .session_has_saved = false,
            .nudge_count = 0,
        };
    }

    /// Called after every tool execution. Tracks whether memory_save
    /// was called.
    pub fn afterToolCall(self: *MemoryGuardrail, tool_name: []const u8) void {
        if (std.mem.eql(u8, tool_name, "memory_save")) {
            self.session_has_saved = true;
        }
    }

    /// Called between turns. If finish_task was triggered and no memory
    /// was saved, injects a nudge and returns true (wants another turn).
    /// Returns false otherwise (no nudge needed).
    pub fn betweenTurns(
        self: *MemoryGuardrail,
        allocator: std.mem.Allocator,
        transcript: *at.Transcript,
        finish_task_triggered: bool,
    ) !bool {
        if (!self.config.enabled) return false;
        if (!finish_task_triggered) return false;
        if (self.session_has_saved) return false;
        if (self.nudge_count >= self.config.max_nudges) return false;

        self.nudge_count += 1;

        const nudge = "Before finishing, if there are any important facts, decisions, " ++
            "or user preferences from this session that would be useful in future sessions, " ++
            "please use the memory_save tool to persist them. " ++
            "If nothing worth remembering happened, you can skip this and call finish_task again.";

        const content = try allocator.alloc(ai.types.ContentBlock, 1);
        content[0] = .{ .text = .{ .text = try allocator.dupe(u8, nudge) } };
        try transcript.append(.{
            .role = .user,
            .content = content,
            .timestamp = ai.stream.nowMillis(),
        });

        ai.log.log(.info, "memory_guardrail", "nudge_injected", "nudge_count={d}", .{self.nudge_count});
        return true; // give the agent another turn to see the nudge
    }

    /// Reset for a new session (called when a new prompt starts).
    pub fn reset(self: *MemoryGuardrail) void {
        self.session_has_saved = false;
        self.nudge_count = 0;
    }
};

// ============================
// Tests
// ============================

const testing = std.testing;

test "MemoryGuardrail: disabled by default" {
    var mg = MemoryGuardrail.init(.{});
    var transcript = at.Transcript.init(testing.allocator);
    defer transcript.deinit();

    const wants_turn = try mg.betweenTurns(testing.allocator, &transcript, true);
    try testing.expect(!wants_turn);
}

test "MemoryGuardrail: enabled but no finish_task → no nudge" {
    var mg = MemoryGuardrail.init(.{ .enabled = true });
    var transcript = at.Transcript.init(testing.allocator);
    defer transcript.deinit();

    const wants_turn = try mg.betweenTurns(testing.allocator, &transcript, false);
    try testing.expect(!wants_turn);
}

test "MemoryGuardrail: finish_task without save → nudge" {
    var mg = MemoryGuardrail.init(.{ .enabled = true });
    var transcript = at.Transcript.init(testing.allocator);
    defer transcript.deinit();

    const wants_turn = try mg.betweenTurns(testing.allocator, &transcript, true);
    try testing.expect(wants_turn);
    try testing.expectEqual(@as(u32, 1), mg.nudge_count);
    try testing.expectEqual(@as(usize, 1), transcript.messages.items.len);
}

test "MemoryGuardrail: finish_task with save → no nudge" {
    var mg = MemoryGuardrail.init(.{ .enabled = true });
    mg.afterToolCall("memory_save");
    var transcript = at.Transcript.init(testing.allocator);
    defer transcript.deinit();

    const wants_turn = try mg.betweenTurns(testing.allocator, &transcript, true);
    try testing.expect(!wants_turn);
}

test "MemoryGuardrail: max_nudges caps repeats" {
    var mg = MemoryGuardrail.init(.{ .enabled = true, .max_nudges = 1 });
    var transcript = at.Transcript.init(testing.allocator);
    defer transcript.deinit();

    // First nudge fires.
    const first = try mg.betweenTurns(testing.allocator, &transcript, true);
    try testing.expect(first);

    // Second call is capped — no nudge.
    const second = try mg.betweenTurns(testing.allocator, &transcript, true);
    try testing.expect(!second);
}

test "MemoryGuardrail: afterToolCall tracks memory_save" {
    var mg = MemoryGuardrail.init(.{ .enabled = true });
    try testing.expect(!mg.session_has_saved);

    mg.afterToolCall("read");
    try testing.expect(!mg.session_has_saved);

    mg.afterToolCall("memory_save");
    try testing.expect(mg.session_has_saved);
}

test "MemoryGuardrail: reset clears state" {
    var mg = MemoryGuardrail.init(.{ .enabled = true });
    mg.afterToolCall("memory_save");
    mg.nudge_count = 1;

    mg.reset();
    try testing.expect(!mg.session_has_saved);
    try testing.expectEqual(@as(u32, 0), mg.nudge_count);
}