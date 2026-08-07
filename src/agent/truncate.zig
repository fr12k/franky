//! Truncation primitives shared between the agent loop and coding tools.
//!
//! This module owns the **agent-layer** truncation policy: the cap applied
//! to each tool-result text block before it enters the conversation history,
//! plus the human-readable size formatter used in truncation markers.
//!
//! Previously these lived in `coding/tools/truncate.zig`, which forced
//! `agent/loop.zig` to import a coding-layer module — a cycle
//! (`agent → coding → agent`). Moving the agent-layer primitives here keeps
//! the `ai → agent → coding` layering one-way. `coding/tools/truncate.zig`
//! re-exports the items it still needs for backward compatibility.
//!
//! The richer head/tail truncation API (`truncateHead`, `truncateTail`,
//! `truncateLine`) stays in `coding/tools/truncate.zig` — those are
//! tool-output shaping concerns, not agent-loop concerns.

const std = @import("std");

/// Cap applied to each tool result text block before it enters the
/// conversation history. Keeps large file reads from inflating every
/// subsequent turn's input token count.
pub const tool_result_max_bytes: usize = 8 * 1024;

/// Human-readable size: `512B` / `1.5KB` / `3.2MB`. Caller frees.
pub fn formatSize(allocator: std.mem.Allocator, bytes: usize) ![]u8 {
    if (bytes < 1024) return std.fmt.allocPrint(allocator, "{d}B", .{bytes});
    if (bytes < 1024 * 1024) return std.fmt.allocPrint(
        allocator,
        "{d:.1}KB",
        .{@as(f64, @floatFromInt(bytes)) / 1024.0},
    );
    return std.fmt.allocPrint(
        allocator,
        "{d:.1}MB",
        .{@as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0)},
    );
}

test "formatSize: bytes" {
    const gpa = std.testing.allocator;
    const s = try formatSize(gpa, 512);
    defer gpa.free(s);
    try std.testing.expectEqualStrings("512B", s);
}

test "formatSize: kilobytes" {
    const gpa = std.testing.allocator;
    const s = try formatSize(gpa, 1536);
    defer gpa.free(s);
    try std.testing.expectEqualStrings("1.5KB", s);
}

test "formatSize: megabytes" {
    const gpa = std.testing.allocator;
    const s = try formatSize(gpa, 3_355_443);
    defer gpa.free(s);
    try std.testing.expectEqualStrings("3.2MB", s);
}