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

/// v1.3.0 dedup — the standard tool-arg parse prologue. Every built-in
/// tool's `execute` opened with the same three lines: arena-init +
/// `repairConcatJson` + `parseFromSlice`. This folds them into one call
/// while leaving the arena in the caller (several tools re-use
/// `arena.allocator()` for downstream extraction like `resolvePaths`).
///
/// Usage:
///   var arena = std.heap.ArenaAllocator.init(allocator);
///   defer arena.deinit();
///   const parsed = try common.parseToolArgs(arena.allocator(), args_json);
///   const root = parsed.value;
pub fn parseToolArgs(
    arena_allocator: std.mem.Allocator,
    args_json: []const u8,
) !std.json.Parsed(std.json.Value) {
    const json_to_parse = repairConcatJson(arena_allocator, args_json) orelse args_json;
    return try std.json.parseFromSlice(std.json.Value, arena_allocator, json_to_parse, .{});
}

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

/// Repair concatenated JSON objects that some LLMs emit as tool-call
/// arguments (e.g. `{"path":"a"}{"path":"b"}{"path":"c"}`).
///
/// Strategy: scan the input at the byte level to find `}{` at
/// brace-depth 0 (outside strings), split at those boundaries,
/// parse each fragment with `std.json`, then merge into a single
/// object. Keys that have the same value in every fragment stay
/// scalar; keys that differ are collected into a JSON array.
///
/// Returns null when the input is already a single JSON object
/// (no concatenation detected) or when it doesn't start with `{`.
/// On repair failure (malformed fragments) also returns null — the
/// caller falls back to the original `std.json.parseFromSlice` path
/// which will produce the proper error.
pub fn repairConcatJson(arena: std.mem.Allocator, raw: []const u8) ?[]const u8 {
    const trimmed = mem.trim(u8, raw, " \t\n\r");
    if (trimmed.len == 0 or trimmed[0] != '{') return null;

    // Split at top-level `}{` boundaries (outside strings).
    var fragments: std.ArrayList(std.json.Value) = .empty;
    var pos: usize = 0;
    while (pos < trimmed.len) {
        while (pos < trimmed.len and trimmed[pos] != '{') : (pos += 1) {}
        if (pos >= trimmed.len) break;

        const start = pos;
        const end = nextTopLevelBraceClose(trimmed, start) orelse break;
        const slice = trimmed[start..end];
        const parsed = std.json.parseFromSlice(std.json.Value, arena, slice, .{}) catch return null;
        if (parsed.value != .object) return null;
        fragments.append(arena, parsed.value) catch return null;
        pos = end;

        while (pos < trimmed.len and (trimmed[pos] == ' ' or trimmed[pos] == '\t' or trimmed[pos] == '\n' or trimmed[pos] == '\r')) : (pos += 1) {}
    }
    if (fragments.items.len <= 1) return null;

    // Merge: collect the set of keys, then for each key decide scalar vs array.
    var key_set = std.StringHashMap(void).init(arena);
    for (fragments.items) |f| {
        var iter = f.object.iterator();
        while (iter.next()) |entry| {
            key_set.put(entry.key_ptr.*, {}) catch return null;
        }
    }

    // Collect per-key values.
    var per_key = std.StringHashMap(std.ArrayList(std.json.Value)).init(arena);
    var ki = key_set.iterator();
    while (ki.next()) |ke| {
        const k = ke.key_ptr.*;
        var vals: std.ArrayList(std.json.Value) = .empty;
        for (fragments.items) |f| {
            if (f.object.get(k)) |v| {
                vals.append(arena, v) catch return null;
            }
        }
        per_key.put(k, vals) catch return null;
    }

    // Build the merged JSON string manually to avoid type issues with valueAlloc
    // on a freshly-constructed ObjectMap.
    var out_buf: std.ArrayList(u8) = .empty;
    out_buf.append(arena, '{') catch return null;
    var first_key = true;
    var ki2 = per_key.iterator();
    while (ki2.next()) |ke2| {
        const k = ke2.key_ptr.*;
        const vals = ke2.value_ptr.*;
        if (!first_key) out_buf.append(arena, ',') catch return null;
        first_key = false;

        // Write key as JSON string. Must explicitly type as Value union
        // — anon-struct .{ .string = k } serializes as {"string":"path"}.
        const key_val: std.json.Value = .{ .string = k };
        const key_json = std.json.Stringify.valueAlloc(arena, key_val, .{}) catch return null;
        out_buf.appendSlice(arena, key_json) catch return null;
        out_buf.append(arena, ':') catch return null;

        if (vals.items.len == 0) {
            out_buf.appendSlice(arena, "null") catch return null;
        } else if (vals.items.len == 1) {
            appendJsonValueSlice(&out_buf, arena, vals.items[0]) catch return null;
        } else {
            if (allValuesEqual(vals.items)) {
                appendJsonValueSlice(&out_buf, arena, vals.items[0]) catch return null;
            } else {
                out_buf.append(arena, '[') catch return null;
                for (vals.items, 0..) |v, j| {
                    if (j > 0) out_buf.append(arena, ',') catch return null;
                    appendJsonValueSlice(&out_buf, arena, v) catch return null;
                }
                out_buf.append(arena, ']') catch return null;
            }
        }
    }
    out_buf.append(arena, '}') catch return null;
    return out_buf.toOwnedSlice(arena) catch return null;
}

/// Write a `std.json.Value` as JSON into an `ArrayList(u8)`.
/// Uses `valueAlloc` which works for scalar/array values but not
/// for newly-constructed `ObjectMap` with sentinel-less keys.
fn appendJsonValueSlice(buf: *std.ArrayList(u8), arena: std.mem.Allocator, v: std.json.Value) !void {
    const json_str = std.json.Stringify.valueAlloc(arena, v, .{}) catch return error.OutOfMemory;
    try buf.appendSlice(arena, json_str);
}

/// Find the position past the `}` that closes the top-level object
/// starting at `s[start]`. Returns null on unbalanced braces.
fn nextTopLevelBraceClose(s: []const u8, start: usize) ?usize {
    var depth: usize = 0;
    var in_string = false;
    var escape_next = false;
    for (s[start..], 0..) |ch, j| {
        if (escape_next) { escape_next = false; continue; }
        if (ch == '\\' and in_string) { escape_next = true; continue; }
        if (ch == '"') { in_string = !in_string; continue; }
        if (in_string) continue;
        if (ch == '{') { depth += 1; continue; }
        if (ch == '}') {
            if (depth == 0) return null;
            depth -= 1;
            if (depth == 0) return start + j + 1;
        }
    }
    return null;
}

fn allValuesEqual(values: []const std.json.Value) bool {
    if (values.len <= 1) return true;
    for (1..values.len) |i| {
        if (!jsonValueEqual(values[0], values[i])) return false;
    }
    return true;
}

/// Deep equality of two `std.json.Value` trees.
fn jsonValueEqual(a: std.json.Value, b: std.json.Value) bool {
    const ta = @intFromEnum(a);
    const tb = @intFromEnum(b);
    if (ta != tb) return false;
    return switch (a) {
        .null => true,
        .bool => a.bool == b.bool,
        .integer => a.integer == b.integer,
        .float => a.float == b.float,
        .number_string => mem.eql(u8, a.number_string, b.number_string),
        .string => mem.eql(u8, a.string, b.string),
        .array => |arr_a| {
            const arr_b = b.array;
            if (arr_a.items.len != arr_b.items.len) return false;
            for (arr_a.items, arr_b.items) |va, vb| {
                if (!jsonValueEqual(va, vb)) return false;
            }
            return true;
        },
        .object => |obj_a| {
            const obj_b = b.object;
            if (obj_a.count() != obj_b.count()) return false;
            var iter = obj_a.iterator();
            while (iter.next()) |entry| {
                const vb = obj_b.get(entry.key_ptr.*) orelse return false;
                if (!jsonValueEqual(entry.value_ptr.*, vb)) return false;
            }
            return true;
        },
    };
}

// ─── tests ────────────────────────────────────────────────────────

const testing = std.testing;

test "repairConcatJson: single object → null" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    try testing.expect(repairConcatJson(arena.allocator(), "{\"path\":\"x\"}") == null);
}

test "repairConcatJson: empty/whitespace → null" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    try testing.expect(repairConcatJson(arena.allocator(), "") == null);
    try testing.expect(repairConcatJson(arena.allocator(), "   ") == null);
}

test "repairConcatJson: two objects with same key, different values → array" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const raw = "{\"path\":\"a.zig\"}{\"path\":\"b.zig\"}";
    const repaired = repairConcatJson(arena.allocator(), raw) orelse return error.NoRepair;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, repaired, .{});
    defer parsed.deinit();
    const paths = parsed.value.object.get("path").?;
    try testing.expect(paths == .array);
    try testing.expectEqual(@as(usize, 2), paths.array.items.len);
    try testing.expectEqualStrings("a.zig", paths.array.items[0].string);
    try testing.expectEqualStrings("b.zig", paths.array.items[1].string);
}

test "repairConcatJson: three objects with mixed same/different keys" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const raw =
        "{\"path\":\"a\",\"limit\":10}" ++
        "{\"path\":\"b\",\"limit\":10}" ++
        "{\"path\":\"c\",\"limit\":10}";
    const repaired = repairConcatJson(arena.allocator(), raw) orelse return error.NoRepair;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, repaired, .{});
    defer parsed.deinit();

    // path differs → array
    const paths = parsed.value.object.get("path").?;
    try testing.expect(paths == .array);
    try testing.expectEqual(@as(usize, 3), paths.array.items.len);

    // limit is the same → scalar
    const limit = parsed.value.object.get("limit").?;
    try testing.expect(limit == .integer);
    try testing.expectEqual(@as(i64, 10), limit.integer);
}

test "repairConcatJson: four objects like the real-world read/ls call" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const raw =
        "{\"path\":\"build.zig\"}" ++
        "{\"path\":\"build.zig.zon\"}" ++
        "{\"path\":\".goreleaser.yaml\"}" ++
        "{\"path\":\".franky-workflow.yaml\"}";
    const repaired = repairConcatJson(arena.allocator(), raw) orelse return error.NoRepair;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, repaired, .{});
    defer parsed.deinit();
    const paths = parsed.value.object.get("path").?;
    try testing.expect(paths == .array);
    try testing.expectEqual(@as(usize, 4), paths.array.items.len);
    try testing.expectEqualStrings("build.zig", paths.array.items[0].string);
    try testing.expectEqualStrings("build.zig.zon", paths.array.items[1].string);
    try testing.expectEqualStrings(".goreleaser.yaml", paths.array.items[2].string);
    try testing.expectEqualStrings(".franky-workflow.yaml", paths.array.items[3].string);
}

test "repairConcatJson: not-json garbage → null" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    try testing.expect(repairConcatJson(arena.allocator(), "not json at all") == null);
}

test "jsonValueEqual: scalars" {
    try testing.expect(jsonValueEqual(.{ .string = "hi" }, .{ .string = "hi" }));
    try testing.expect(!jsonValueEqual(.{ .string = "hi" }, .{ .string = "ho" }));
    try testing.expect(jsonValueEqual(.{ .integer = 42 }, .{ .integer = 42 }));
    try testing.expect(!jsonValueEqual(.{ .integer = 42 }, .{ .integer = 99 }));
    try testing.expect(jsonValueEqual(.{ .bool = true }, .{ .bool = true }));
    try testing.expect(jsonValueEqual(.null, .null));
    try testing.expect(!jsonValueEqual(.null, .{ .bool = false }));
}

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

