//! finish_task tool — §6.10.
//!
//! The model calls `finish_task` to signal task completion. The tool:
//!   1. Validates and stores the commit_message and summary.
//!   2. Sets `terminate = true` so the loop naturally ends.
//!   3. Triggers the guardrails between-turns logic (final compilation check,
//!      optional auto-commit) before the loop closes.

const std = @import("std");
const ai = struct {
    pub const types = @import("../../ai/types.zig");
    pub const stream = @import("../../ai/stream.zig");
};
const at = @import("../types.zig");

pub const parameters_json: []const u8 =
    \\{
    \\  "type": "object",
    \\  "required": ["commit_message", "summary"],
    \\  "properties": {
    \\    "commit_message": {
    \\      "type": "string",
    \\      "description": "Follow the Conventional Commits format: <type>(<scope>): <subject> — e.g. \"fix(api): handle null pointer in user lookup\". Types: feat, fix, docs, style, refactor, perf, test, build, ci, chore, revert."
    \\    },
    \\    "summary": {
    \\      "type": "string",
    \\      "description": "What was done, what remains unknown, what to do next."
    \\    },
    \\    "restart": {
    \\      "type": "boolean",
    \\      "description": "When true, after committing, the process will restart itself (spawn a fresh binary and exit). Only works in proxy mode."
    \\    }
    \\  },
    \\  "additionalProperties": false
    \\}
;

/// Mutable state shared between the tool vtable and the GuardrailState.
pub const FinishTaskState = struct {
    allocator: std.mem.Allocator,
    /// Set when the model calls finish_task; null before that.
    commit_message: ?[]const u8 = null,
    /// Set when the model calls finish_task; null before that.
    summary: ?[]const u8 = null,
    /// True from the moment finish_task fires until betweenTurns consumes it.
    triggered: bool = false,
    /// When true, after successful compilation + commit the process restarts.
    restart: bool = false,

    pub fn init(allocator: std.mem.Allocator) FinishTaskState {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *FinishTaskState) void {
        if (self.commit_message) |s| self.allocator.free(s);
        if (self.summary) |s| self.allocator.free(s);
    }

    pub fn reset(self: *FinishTaskState) void {
        if (self.commit_message) |s| {
            self.allocator.free(s);
            self.commit_message = null;
        }
        if (self.summary) |s| {
            self.allocator.free(s);
            self.summary = null;
        }
        self.triggered = false;
        self.restart = false;
    }
};

/// Build the finish_task AgentTool backed by the given state.
pub fn tool(state: *FinishTaskState) at.AgentTool {
    return .{
        .name = "finish_task",
        .description =
        \\Signal that the current task is complete. Triggers a final compilation
        \\check before committing (when --auto-commit is active). The loop ends
        \\after this tool fires unless compilation fails (in which case the model
        \\must fix the error and call finish_task again).
        \\
        \\commit_message must follow the Conventional Commits format:
        \\<type>(<scope>): <subject>  — e.g. "fix(api): handle null pointer".
        \\Types: feat, fix, docs, style, refactor, perf, test, build, ci, chore, revert.
        ,
        .parameters_json = parameters_json,
        .execution_mode = .sequential,
        .ctx = @ptrCast(state),
        .execute = execute,
    };
}

fn execute(
    self: *const at.AgentTool,
    allocator: std.mem.Allocator,
    io: std.Io,
    _: []const u8,
    args_json: []const u8,
    _: *ai.stream.Cancel,
    _: at.OnUpdate,
) anyerror!at.ToolResult {
    _ = io;
    const state: *FinishTaskState = @ptrCast(@alignCast(self.ctx.?));

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), args_json, .{});
    const root = parsed.value;

    const cm_val = root.object.get("commit_message") orelse
        return toolError(allocator, "invalid_args", "missing commit_message");
    if (cm_val != .string)
        return toolError(allocator, "invalid_args", "commit_message must be a string");
    const commit_msg = cm_val.string;

    if (commit_msg.len == 0)
        return toolError(allocator, "invalid_args", "commit_message cannot be empty");

    // Validate printable ASCII only.
    for (commit_msg) |c| {
        if (c < 0x20 or c > 0x7e)
            return toolError(allocator, "invalid_args", "commit_message must contain only printable ASCII");
    }

    // Validate conventional commit format: "type(scope): subject" or "type: subject"
    {
        const colon_idx = std.mem.indexOfScalar(u8, commit_msg, ':')
            orelse return toolError(allocator, "invalid_args", "commit_message must be in conventional commit format: <type>(<scope>): <subject>");
        const type_part = commit_msg[0..colon_idx];
        if (type_part.len == 0) return toolError(allocator, "invalid_args", "commit_message type is empty");
        for (type_part) |c| {
            switch (c) {
                'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '(', ')', '!' => {},
                else => return toolError(allocator, "invalid_args", "commit_message type contains invalid characters"),
            }
        }
        if (commit_msg.len <= colon_idx + 2 or commit_msg[colon_idx + 1] != ' ')
            return toolError(allocator, "invalid_args", "commit_message must have a space after the colon: <type>: <subject>");
    }

    const sum_val = root.object.get("summary") orelse
        return toolError(allocator, "invalid_args", "missing summary");
    if (sum_val != .string)
        return toolError(allocator, "invalid_args", "summary must be a string");

    // Store in state (owned by the FinishTaskState's allocator).
    state.reset();
    state.commit_message = try state.allocator.dupe(u8, commit_msg);
    state.summary = try state.allocator.dupe(u8, sum_val.string);
    // v2.17 — parse optional restart flag from finish_task args.
    state.restart = if (root.object.get("restart")) |v| v == .bool and v.bool else false;
    state.triggered = true;

    const text = try std.fmt.allocPrint(
        allocator,
        "Task completion acknowledged. Running final checks...\n\nSummary: {s}",
        .{sum_val.string},
    );
    const arr = try allocator.alloc(ai.types.ContentBlock, 1);
    arr[0] = .{ .text = .{ .text = text } };
    return .{ .content = arr, .terminate = true };
}

fn toolError(allocator: std.mem.Allocator, code: []const u8, msg: []const u8) !at.ToolResult {
    const text = try std.fmt.allocPrint(allocator, "[{s}] {s}", .{ code, msg });
    const arr = try allocator.alloc(ai.types.ContentBlock, 1);
    arr[0] = .{ .text = .{ .text = text } };
    return .{ .content = arr, .is_error = true, .tool_code = try allocator.dupe(u8, code) };
}

// ─── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "FinishTaskState: reset clears commit_message and summary" {
    const gpa = testing.allocator;
    var s = FinishTaskState.init(gpa);
    defer s.deinit();

    s.commit_message = try gpa.dupe(u8, "fix: something");
    s.summary = try gpa.dupe(u8, "did stuff");
    s.triggered = true;

    s.reset();
    try testing.expect(s.commit_message == null);
    try testing.expect(s.summary == null);
    try testing.expect(!s.triggered);
}
