//! Shared helpers for built-in tools.
//!
//! Every built-in tool (`read`/`write`/`edit`/`ls`/`find`/`grep`/
//! `bash`) needs the same error-result shape: a single text block
//! of the form `"[{code}] {msg}"` plus `is_error = true` plus a
//! duped `tool_code` subcode per §F.2 (v1.7.1). This module ships
//! the one canonical implementation; tools call into it instead
//! of each maintaining a private copy (v1.3.0 R1 refactor — ~49
//! lines deleted).

const std = @import("std");
const mem = std.mem;
const ai = struct {
    pub const types = @import("../../ai/types.zig");
};
const at = @import("../../agent/types.zig");
const gitignore = @import("../gitignore.zig");
const workspace_mod = @import("workspace.zig");

// `repairConcatJson` now lives in `agent/json_repair.zig` (the agent
// layer) so `agent/loop.zig` doesn't have to import this coding-layer
// module — that was a cycle (`agent → coding → agent`). Re-exported
// here for backward compatibility with the many tools that call
// `common.repairConcatJson`.
pub const repairConcatJson = @import("../../agent/json_repair.zig").repairConcatJson;

/// §6.9 — tool_code emitted when a single-path tool refuses a path
/// covered by `.contextignore`. Single literal so call sites and
/// test assertions stay in sync.
pub const tool_code_contextignored: []const u8 = "contextignored";

/// Build a structured failure `ToolResult`. The rendered text
/// carries `"[{code}] {msg}"` so models (and developers reading
/// scrollback) see the subcode; the `tool_code` field duplicates
/// the code so callers that escalate to an `agent_error` can
/// carry the §F.2 subcode through `ErrorDetails.tool_code`.
pub fn toolError(
    allocator: std.mem.Allocator,
    code: []const u8,
    msg: []const u8,
) !at.ToolResult {
    const text = try std.fmt.allocPrint(allocator, "[{s}] {s}", .{ code, msg });
    const arr = try allocator.alloc(ai.types.ContentBlock, 1);
    arr[0] = .{ .text = .{ .text = text } };
    const code_dup = try allocator.dupe(u8, code);
    return .{ .content = arr, .is_error = true, .tool_code = code_dup };
}

/// §6.9 — return a `contextignored` `ToolResult` if `abs_path` is
/// suppressed by any `.contextignore` under `workspace.root`, else
/// null. Used by single-path tools (`read`/`write`/`edit`) to
/// enforce the unconditional §6.9 gate.
///
/// Idiom at the call site:
/// ```zig
/// if (try common.contextIgnoreError(allocator, io, ws, abs)) |err| return err;
/// ```
pub fn contextIgnoreError(
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace: *const workspace_mod.Workspace,
    abs_path: []const u8,
) !?at.ToolResult {
    if (!gitignore.isContextIgnored(allocator, io, workspace.root, abs_path)) return null;
    return try toolError(
        allocator,
        tool_code_contextignored,
        "path is in .contextignore — archived/historical content not available to the model",
    );
}

// ─── tests ────────────────────────────────────────────────────────

const testing = std.testing;

test "toolError: renders [code] msg + sets tool_code + is_error=true" {
    const gpa = testing.allocator;
    var res = try toolError(gpa, "edit_no_match", "needle missing in foo.zig");
    defer res.deinit(gpa);
    try testing.expect(res.is_error);
    try testing.expect(res.tool_code != null);
    try testing.expectEqualStrings("edit_no_match", res.tool_code.?);
    try testing.expectEqual(@as(usize, 1), res.content.len);
    try testing.expectEqualStrings(
        "[edit_no_match] needle missing in foo.zig",
        res.content[0].text.text,
    );
}

