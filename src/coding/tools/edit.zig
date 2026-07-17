//! edit tool — §C.3 of the spec.
//!
//! Schema: `{path, edits: [{old, new, replaceAll?}]}`.
//! Edits are applied in order. For each: `old` must occur in the file;
//! with `replaceAll=false`, exactly once.
//!
//! All edits succeed atomically or none do — we build the final content
//! in memory and then write via tempfile+rename.
//!
//! Errors:
//!   `edit_no_match` — `old` string not found
//!   `edit_ambiguous` — non-unique `old` without `replaceAll`
//!   `edit_conflict` — a later edit's `old` was invalidated by earlier

const std = @import("std");
const ct = @import("../types.zig");
const at = ct.agent.types;
const ai = ct.ai;
const common = @import("common.zig");
const workspace_mod = @import("workspace.zig");

pub const parameters_json: []const u8 =
    \\{
    \\  "type": "object",
    \\  "required": ["path", "edits"],
    \\  "properties": {
    \\    "path": {"type": "string"},
    \\    "edits": {
    \\      "type": "array", "minItems": 1,
    \\      "items": {
    \\        "type": "object",
    \\        "required": ["old", "new"],
    \\        "properties": {
    \\          "old": {"type": "string"},
    \\          "new": {"type": "string"},
    \\          "replaceAll": {"type": "boolean", "default": false}
    \\        },
    \\        "additionalProperties": false
    \\      }
    \\    }
    \\  },
    \\  "additionalProperties": false
    \\}
;

// Anti-widening guidance is in the description (not just the
// post-hoc hint) so the model sees it before its first call —
// otherwise `edit_no_match` failures get retried with a wider
// `old`, which only helps for `edit_ambiguous`.
const edit_description =
    "Apply one or more find/replace edits to a file atomically. " ++
    "If `old` is not found, do NOT widen it with more surrounding " ++
    "context — re-read the file with the `read` tool and copy-paste " ++
    "the exact bytes into `old`. " ++
    "Pre-condition: you MUST have called `read` on the same path " ++
    "within the last 2 turns before calling edit.";

const edit_description_workspace = edit_description ++ " (path-safety enforced)";

pub fn tool() at.AgentTool {
    return .{
        .name = "edit",
        .description = edit_description,
        .parameters_json = parameters_json,
        .execution_mode = .sequential,
        .skip_compression = true,
        .execute = execute,
    };
}

pub fn toolWithWorkspace(ws: *const workspace_mod.Workspace) at.AgentTool {
    return .{
        .name = "edit",
        .description = edit_description_workspace,
        .parameters_json = parameters_json,
        .execution_mode = .sequential,
        .skip_compression = true,
        .ctx = @ptrCast(@constCast(ws)),
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
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const json_to_parse = common.repairConcatJson(arena.allocator(), args_json) orelse args_json;
    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), json_to_parse, .{});
    const root = parsed.value;

    const user_path = (root.object.get("path") orelse return common.toolError(allocator, "invalid_args", "missing path")).string;
    // Retrieve `edits`, tolerating two model quirks before failing:
    //   flattened schema: `edits` key absent, `old`/`new` at root level
    //   double-serialization: `edits` is a JSON string containing the array
    var edits_val: std.json.Value = blk: {
        if (root.object.get("edits")) |v| break :blk v;

        // Some models (e.g. certain DeepSeek configs) omit the `edits` key
        // entirely and put `old`/`new` directly alongside `path`.
        if (root.object.get("old")) |old_v| {
            if (root.object.get("new")) |new_v| {
                if (old_v == .string and new_v == .string) {
                    var obj: std.json.ObjectMap = .{};
                    try obj.put(arena.allocator(), "old", old_v);
                    try obj.put(arena.allocator(), "new", new_v);
                    var arr = std.json.Array.init(arena.allocator());
                    try arr.append(.{ .object = obj });
                    break :blk .{ .array = arr };
                }
            }
        }

        return common.toolError(allocator, "invalid_args", "missing edits");
    };

    // Some models double-serialize `edits` as a JSON string; some also append
    // trailing garbage — parsePartial handles both by returning the leading value.
    if (edits_val == .string) {
        if (ai.partial_json.parsePartial(arena.allocator(), edits_val.string)) |pr| {
            if (pr.value) |v| edits_val = v;
        } else |_| {}
    }

    // Some models emit `edits: {old, new}` instead of `[{old, new}]` — wrap.
    if (edits_val == .object) {
        var arr = std.json.Array.init(arena.allocator());
        try arr.append(edits_val);
        edits_val = .{ .array = arr };
    }

    if (edits_val != .array) {
        const type_str: []const u8 = switch (edits_val) {
            .null => "null",
            .bool => "boolean",
            .integer, .float, .number_string => "number",
            .string => "string",
            .object => "object",
            .array => "array",
        };
        const msg = try std.fmt.allocPrint(arena.allocator(), "edits must be an array (got {s})", .{type_str});
        return common.toolError(allocator, "invalid_args", msg);
    }

    var canon_path: ?[]u8 = null;
    defer if (canon_path) |p| allocator.free(p);
    const path: []const u8 = if (self.ctx) |raw| blk: {
        const ws: *const workspace_mod.Workspace = @ptrCast(@alignCast(raw));
        const r = try workspace_mod.canonicalizeOrError(allocator, ws, user_path);
        switch (r) {
            .ok => |c| {
                canon_path = c.abs;
                if (try common.contextIgnoreError(allocator, io, ws, c.abs)) |err| return err;
                break :blk c.abs;
            },
            .err => |e| return common.toolError(allocator, e.code, e.message),
        }
    } else user_path;

    var edits: std.ArrayList(EditOp) = .empty;
    defer edits.deinit(allocator);
    for (edits_val.array.items) |ev| {
        if (ev != .object) return common.toolError(allocator, "invalid_args", "edits[i] must be an object");
        const old_v = ev.object.get("old") orelse return common.toolError(allocator, "invalid_args", "edit missing old");
        const new_v = ev.object.get("new") orelse return common.toolError(allocator, "invalid_args", "edit missing new");
        if (old_v != .string or new_v != .string) return common.toolError(allocator, "invalid_args", "edit old/new must be strings");
        if (old_v.string.len == 0) return common.toolError(allocator, "invalid_args", "edit `old` must be non-empty");
        const replace_all = if (ev.object.get("replaceAll")) |x| (x == .bool and x.bool) else false;
        try edits.append(allocator, .{ .old = old_v.string, .new = new_v.string, .replace_all = replace_all });
    }

    return try applyEdits(allocator, io, path, edits.items);
}

const EditOp = struct {
    old: []const u8,
    new: []const u8,
    replace_all: bool,
};

pub fn applyEdits(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    edits: []const EditOp,
) !at.ToolResult {
    const cwd = std.Io.Dir.cwd();

    // Load the file.
    var file = cwd.openFile(io, path, .{}) catch |e| switch (e) {
        error.FileNotFound => return common.toolError(allocator, "file_not_found", "file does not exist"),
        else => return common.toolError(allocator, "open_failed", @errorName(e)),
    };
    const len = file.length(io) catch |e| {
        file.close(io);
        return common.toolError(allocator, "stat_failed", @errorName(e));
    };
    const original = try allocator.alloc(u8, @intCast(len));
    defer allocator.free(original);
    _ = file.readPositionalAll(io, original, 0) catch |e| {
        file.close(io);
        return common.toolError(allocator, "read_failed", @errorName(e));
    };
    file.close(io);

    // Empty-file short-circuit. Real-incident pattern (gemini-2.5-pro,
    // 100-turn proxy session): the model creates a placeholder file
    // via `write` with empty content, then immediately tries `edit` to
    // populate it. `indexOf(empty_buf, non_empty_old)` is always null,
    // and `indexOf(empty_buf, "")` matches at *every* position so the
    // existing edit_ambiguous check rejects empty `old` too. Either
    // way the model can't recover by retrying — there ARE no bytes to
    // match. Steer to `write` directly.
    if (original.len == 0) {
        return common.toolError(
            allocator,
            "edit_file_empty",
            "file is empty; use the `write` tool with `overwrite: true` to create initial content",
        );
    }

    // Apply edits into a growing buffer.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, original);

    var diff_rows: std.ArrayList(DiffRow) = .empty;
    defer diff_rows.deinit(allocator);

    for (edits, 0..) |ed, idx| {
        const found = std.mem.indexOf(u8, buf.items, ed.old);
        if (found == null) {
            const msg = try buildNoMatchMsg(allocator, idx, ed.old, buf.items);
            defer allocator.free(msg);
            return common.toolError(allocator, "edit_no_match", msg);
        }
        if (!ed.replace_all) {
            // Unique match required.
            const second = std.mem.indexOfPos(u8, buf.items, found.? + 1, ed.old);
            if (second != null) {
                const msg = try std.fmt.allocPrint(allocator, "edit {d}: `old` matches multiple times", .{idx});
                defer allocator.free(msg);
                return common.toolError(allocator, "edit_ambiguous", msg);
            }
            try replaceOnce(&buf, allocator, ed.old, ed.new);
        } else {
            try replaceAll(&buf, allocator, ed.old, ed.new);
        }
        try diff_rows.append(allocator, .{ .old = ed.old, .new = ed.new });
    }

    // Atomic write.
    try atomicWrite(io, path, buf.items);

    // Build a minimal unified-diff-ish summary.
    var summary: std.ArrayList(u8) = .empty;
    defer summary.deinit(allocator);
    {
        const s = try std.fmt.allocPrint(allocator, "applied {d} edit(s) to {s}\n", .{ edits.len, path });
        defer allocator.free(s);
        try summary.appendSlice(allocator, s);
    }
    for (diff_rows.items, 0..) |d, i| {
        try renderEditDiff(&summary, allocator, i, d.old, d.new);
    }

    // Build details_json with optional unified diff for the web UI diff view.
    // Failure to compute the diff is non-fatal — the plain text summary still works.
    // The `format` field is the contract version the client matches against
    // (see app.js:tryRenderDiffPanel). Bump the suffix when the diff string
    // shape changes and update the client allowlist in lockstep.
    const details = blk: {
        const diff_str = computeUnifiedDiff(allocator, original, buf.items, path) catch null;
        if (diff_str) |d| {
            defer allocator.free(d);
            // JSON-escape the diff string for embedding in details_json.
            const escaped = try escapeJsonString(allocator, d);
            defer allocator.free(escaped);
            break :blk try std.fmt.allocPrint(allocator, "{{\"edits\":{d},\"format\":\"unified-diff-v1\",\"diff\":\"{s}\",\"path\":\"{s}\"}}", .{ edits.len, escaped, path });
        } else {
            break :blk try std.fmt.allocPrint(allocator, "{{\"edits\":{d},\"diff\":null,\"path\":\"{s}\"}}", .{ edits.len, path });
        }
    };
    const text = try allocator.dupe(u8, summary.items);
    const arr = try allocator.alloc(ai.types.ContentBlock, 1);
    arr[0] = .{ .text = .{ .text = text } };
    return .{ .content = arr, .details_json = details };
}

const DiffRow = struct { old: []const u8, new: []const u8 };

/// Render one edit's diff as `[i] - <old line>` / `[i] + <new line>` rows,
/// one row per source line. Pre-v1.26.3 this only emitted the first line
/// of each side via `firstLine` — when `old` and `new` shared a first line
/// (e.g. a multi-line block where only later lines changed) the diff
/// looked like a no-op even though the whole tail had been replaced. Real
/// incident: a parent-agent revert silently undid a sub-agent's correct
/// edit because the apparent "no diff" output convinced the model the
/// edit hadn't taken; it then ping-ponged the file state across several
/// turns trying to reapply.
///
/// Each side is capped at `max_diff_lines_per_side` rows so a wholesale
/// rewrite doesn't dominate the tool result. When the cap is exceeded
/// we render the first ⌊cap/2⌋ lines, an `… (N more lines elided) …`
/// marker, then the last ⌈cap/2⌉ lines — matching the standard truncated-
/// diff format from `git`/`hg`.
fn renderEditDiff(
    summary: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    edit_index: usize,
    old_text: []const u8,
    new_text: []const u8,
) !void {
    try renderEditSide(summary, allocator, edit_index, '-', old_text);
    try renderEditSide(summary, allocator, edit_index, '+', new_text);
}

const max_diff_lines_per_side: usize = 12;

fn renderEditSide(
    summary: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    edit_index: usize,
    sign: u8,
    text: []const u8,
) !void {
    // Empty side renders as a single sentinel row so the reader sees
    // "block was deleted" / "block was inserted from nothing" instead
    // of just absent lines.
    if (text.len == 0) {
        const s = try std.fmt.allocPrint(allocator, "  [{d}] {c}(empty)\n", .{ edit_index, sign });
        defer allocator.free(s);
        try summary.appendSlice(allocator, s);
        return;
    }

    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(allocator);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |ln| try lines.append(allocator, ln);
    // splitScalar on a trailing-newline string emits a final empty slice
    // — drop it so a 3-line `old` doesn't render as 4 rows. Single
    // empty input was already handled above.
    if (lines.items.len > 1 and lines.items[lines.items.len - 1].len == 0) {
        lines.items.len -= 1;
    }

    const total = lines.items.len;
    if (total <= max_diff_lines_per_side) {
        for (lines.items) |ln| try emitLine(summary, allocator, edit_index, sign, ln);
        return;
    }
    const head = max_diff_lines_per_side / 2;
    const tail = max_diff_lines_per_side - head;
    for (lines.items[0..head]) |ln| try emitLine(summary, allocator, edit_index, sign, ln);
    {
        const elided = total - head - tail;
        const s = try std.fmt.allocPrint(allocator, "  [{d}] {c}… ({d} more lines elided) …\n", .{ edit_index, sign, elided });
        defer allocator.free(s);
        try summary.appendSlice(allocator, s);
    }
    for (lines.items[total - tail ..]) |ln| try emitLine(summary, allocator, edit_index, sign, ln);
}

fn emitLine(
    summary: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    edit_index: usize,
    sign: u8,
    line: []const u8,
) !void {
    const s = try std.fmt.allocPrint(allocator, "  [{d}] {c}{s}\n", .{ edit_index, sign, line });
    defer allocator.free(s);
    try summary.appendSlice(allocator, s);
}

fn buildNoMatchMsg(
    allocator: std.mem.Allocator,
    idx: usize,
    old: []const u8,
    file_content: []const u8,
) ![]u8 {
    // Detect over-escaped backslashes: a model reading a Zig file with
    // multiline-string lines (`\\foo`) sometimes emits them with doubled
    // backslashes in the edit `old`, causing a mismatch.  Try collapsing
    // every `\\` pair to `\` and see if that matches.
    const deescaped = try collapseBackslashPairs(allocator, old);
    if (deescaped.len < old.len and std.mem.indexOf(u8, file_content, deescaped) != null) {
        defer allocator.free(deescaped);
        return std.fmt.allocPrint(
            allocator,
            "edit {d}: `old` not found — backslash over-escaping detected. " ++
                "STOP. Do not retry with widened `old` — read the file with `read` and copy-paste exact bytes",
            .{idx},
        );
    }
    defer allocator.free(deescaped);

    // Check for a partial match — if most of `old` appears at one position,
    // show the model the actual bytes around the near-miss.
    var partial: ?PartialMatch = null;
    if (old.len > 4) {
        partial = findPartialMatch(old, file_content);
    }

    if (partial) |pm| {
        const ctx_start = if (pm.offset >= 15) pm.offset - 15 else 0;
        const ctx_end = @min(pm.offset + pm.match_len + 15, file_content.len);
        var context = file_content[ctx_start..ctx_end];
        // Cap the context display at 100 chars to avoid giant error messages.
        if (context.len > 100) context = context[0..100];
        return std.fmt.allocPrint(
            allocator,
            "edit {d}: `old` not found — closest match at byte offset {d} ({d} of {d} bytes matched). " ++
                "STOP. Do not retry with widened `old`. Read the file with `read` and copy-paste the exact bytes. " ++
                "Bytes around offset {d}: `{s}`",
            .{ idx, pm.offset, pm.match_len, old.len, pm.offset, context },
        );
    }

    return std.fmt.allocPrint(
        allocator,
        "edit {d}: `old` not found. " ++
            "STOP. Do not retry with widened `old` — read the file with `read` and copy-paste exact bytes",
        .{idx},
    );
}

const PartialMatch = struct {
    offset: usize,
    match_len: usize,
};

/// Find the longest contiguous prefix of `old` that appears in `content`.
/// Returns the offset and length of the best match (longest prefix).
/// Only checks the full old prefix — if the model appended/inserted
/// extra characters mid-way, this detects where the split happened.
fn findPartialMatch(old: []const u8, content: []const u8) ?PartialMatch {
    // Try the full prefix, then shrink by one byte at a time.
    var best: ?PartialMatch = null;
    var probe_len = old.len - 1;
    while (probe_len >= old.len / 2) : (probe_len -= 1) {
        const probe = old[0..probe_len];
        if (std.mem.indexOf(u8, content, probe)) |offset| {
            if (best == null or probe_len > best.?.match_len) {
                best = .{ .offset = offset, .match_len = probe_len };
            }
            // Longest possible for this probe_len — shrink further.
            // But a longer prefix is better, so continue.
        }
    }
    return best;
}

fn collapseBackslashPairs(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var i: usize = 0;
    while (i < s.len) {
        if (i + 1 < s.len and s[i] == '\\' and s[i + 1] == '\\') {
            try out.append(allocator, '\\');
            i += 2;
        } else {
            try out.append(allocator, s[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

fn replaceOnce(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    old: []const u8,
    new: []const u8,
) !void {
    if (old.len == 0) return; // guard against empty-old infinite loop
    const at_ = std.mem.indexOf(u8, buf.items, old) orelse return;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, buf.items[0..at_]);
    try out.appendSlice(allocator, new);
    try out.appendSlice(allocator, buf.items[at_ + old.len ..]);
    buf.clearRetainingCapacity();
    try buf.appendSlice(allocator, out.items);
}

fn replaceAll(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    old: []const u8,
    new: []const u8,
) !void {
    if (old.len == 0) return; // guard against empty-old infinite loop
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var i: usize = 0;
    while (i < buf.items.len) {
        const at_ = std.mem.indexOfPos(u8, buf.items, i, old) orelse {
            try out.appendSlice(allocator, buf.items[i..]);
            break;
        };
        try out.appendSlice(allocator, buf.items[i..at_]);
        try out.appendSlice(allocator, new);
        i = at_ + old.len;
    }
    buf.clearRetainingCapacity();
    try buf.appendSlice(allocator, out.items);
}

fn atomicWrite(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var tmp_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const counter = tmp_counter.fetchAdd(1, .monotonic);
    const tmp_path = try std.fmt.bufPrint(&tmp_path_buf, "{s}.edit.{d}", .{ path, counter });

    const cwd = std.Io.Dir.cwd();
    {
        var f = try cwd.createFile(io, tmp_path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, bytes);
    }
    cwd.rename(tmp_path, cwd, path, io) catch |e| {
        cwd.deleteFile(io, tmp_path) catch {};
        return e;
    };
}

var tmp_counter: std.atomic.Value(u32) = .init(0);

// ─── Unified diff generation (§6.8) ───────────────────────────────

/// Compute a standard unified diff between `original` and `modified`.
/// Returns the full diff including `--- a/<path>` / `+++ b/<path>` headers
/// and hunks with up to 3 context lines. Uses a simple LCS DP table
/// suitable for files up to ~2000 lines. Returns null on any error
/// (OOM, too large, etc.) — callers should fall back gracefully.
///
/// Format contract: paired with `parseUnifiedDiff` in
/// `src/coding/modes/web/app.js`. See the `wire-format contract tests`
/// block at the bottom of this file before changing the emit shape.
fn computeUnifiedDiff(
    allocator: std.mem.Allocator,
    original: []const u8,
    modified: []const u8,
    path: []const u8,
) ![]u8 {
    // Split into lines, preserving trailing-newline in each slice.
    const orig_lines = try splitLines(allocator, original);
    defer allocator.free(orig_lines);
    const mod_lines = try splitLines(allocator, modified);
    defer allocator.free(mod_lines);

    const n = orig_lines.len;
    const m = mod_lines.len;

    // Cap at 2000 lines to avoid O(n*m) blowup.
    if (n > 2000 or m > 2000) return error.TooLarge;

    // LCS DP table — flat [n+1][m+1] usize array.
    const cols = m + 1;
    const dp = try allocator.alloc(usize, (n + 1) * cols);
    defer allocator.free(dp);

    var i: usize = 0;
    while (i <= n) : (i += 1) {
        var j: usize = 0;
        while (j <= m) : (j += 1) {
            if (i == 0 or j == 0) {
                dp[i * cols + j] = 0;
            } else if (std.mem.eql(u8, orig_lines[i - 1], mod_lines[j - 1])) {
                dp[i * cols + j] = dp[(i - 1) * cols + (j - 1)] + 1;
            } else {
                dp[i * cols + j] = @max(dp[(i - 1) * cols + j], dp[i * cols + (j - 1)]);
            }
        }
    }

    // Trace back to produce a forward edit script.
    // We collect DiffOp values in forward order.
    var ops: std.ArrayList(DiffOp) = .empty;
    defer ops.deinit(allocator);

    {
        i = n;
        var j: usize = m;
        var rev: std.ArrayList(DiffOp) = .empty;
        defer rev.deinit(allocator);

        while (i > 0 or j > 0) {
            if (i > 0 and j > 0 and std.mem.eql(u8, orig_lines[i - 1], mod_lines[j - 1])) {
                try rev.append(allocator, .{ .kind = .keep, .orig_idx = i - 1, .mod_idx = j - 1 });
                i -= 1;
                j -= 1;
            } else if (j > 0 and (i == 0 or dp[i * cols + (j - 1)] >= dp[(i - 1) * cols + j])) {
                try rev.append(allocator, .{ .kind = .add, .orig_idx = null, .mod_idx = j - 1 });
                j -= 1;
            } else if (i > 0) {
                try rev.append(allocator, .{ .kind = .remove, .orig_idx = i - 1, .mod_idx = null });
                i -= 1;
            }
        }

        // Reverse into forward order.
        var ri: usize = rev.items.len;
        while (ri > 0) {
            ri -= 1;
            try ops.append(allocator, rev.items[ri]);
        }
    }

    // Group ops into hunks. For each change op (add/remove), expand
    // outward by `ctx` keeps on either side; merge ranges that touch
    // or overlap. Pure-keep regions never produce a hunk.
    const ctx: usize = 3;
    var hunks: std.ArrayList(Hunk) = .empty;
    defer hunks.deinit(allocator);

    const Range = struct { start: usize, end: usize };
    var ranges: std.ArrayList(Range) = .empty;
    defer ranges.deinit(allocator);

    for (ops.items, 0..) |op, idx| {
        if (op.kind == .keep) continue;
        const start = if (idx >= ctx) idx - ctx else 0;
        const end = @min(idx + ctx + 1, ops.items.len);
        if (ranges.items.len > 0 and ranges.items[ranges.items.len - 1].end >= start) {
            // Overlaps or touches the previous range — extend it.
            if (ranges.items[ranges.items.len - 1].end < end) {
                ranges.items[ranges.items.len - 1].end = end;
            }
        } else {
            try ranges.append(allocator, .{ .start = start, .end = end });
        }
    }

    for (ranges.items) |range| {
        const hunk_ops = ops.items[range.start..range.end];

        // Compute line numbers for hunk header.
        var orig_start: ?usize = null;
        var mod_start: ?usize = null;
        var orig_count: usize = 0;
        var mod_count: usize = 0;

        for (hunk_ops) |op| {
            switch (op.kind) {
                .keep => {
                    orig_count += 1;
                    mod_count += 1;
                    if (orig_start == null) {
                        orig_start = op.orig_idx.?;
                        mod_start = op.mod_idx.?;
                    }
                },
                .remove => {
                    orig_count += 1;
                    if (orig_start == null) {
                        orig_start = op.orig_idx.?;
                        mod_start = op.mod_idx orelse 0;
                    }
                },
                .add => {
                    mod_count += 1;
                    if (orig_start == null) {
                        orig_start = op.orig_idx orelse 0;
                        mod_start = op.mod_idx.?;
                    }
                },
            }
        }

        // Build the hunk body.
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(allocator);

        for (hunk_ops) |op| {
            switch (op.kind) {
                .keep => {
                    try body.appendSlice(allocator, " ");
                    try body.appendSlice(allocator, orig_lines[op.orig_idx.?]);
                },
                .remove => {
                    try body.appendSlice(allocator, "-");
                    try body.appendSlice(allocator, orig_lines[op.orig_idx.?]);
                },
                .add => {
                    try body.appendSlice(allocator, "+");
                    try body.appendSlice(allocator, mod_lines[op.mod_idx.?]);
                },
            }
        }

        if (body.items.len > 0) {
            try hunks.append(allocator, .{
                .orig_start = (orig_start orelse 0) + 1, // 1-indexed
                .orig_count = orig_count,
                .mod_start = (mod_start orelse 0) + 1,
                .mod_count = mod_count,
                .body = try body.toOwnedSlice(allocator),
            });
        }
    }

    // Build the full diff output.
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);

    try result.appendSlice(allocator, "--- a/");
    try result.appendSlice(allocator, path);
    try result.appendSlice(allocator, "\n+++ b/");
    try result.appendSlice(allocator, path);
    try result.appendSlice(allocator, "\n");

    for (hunks.items) |h| {
        try result.appendSlice(allocator, "@@ -");
        try appendUint(&result, allocator, h.orig_start);
        try result.appendSlice(allocator, ",");
        try appendUint(&result, allocator, h.orig_count);
        try result.appendSlice(allocator, " +");
        try appendUint(&result, allocator, h.mod_start);
        try result.appendSlice(allocator, ",");
        try appendUint(&result, allocator, h.mod_count);
        try result.appendSlice(allocator, " @@\n");
        try result.appendSlice(allocator, h.body);
        allocator.free(h.body);
    }

    return result.toOwnedSlice(allocator);
}

const DiffOpKind = enum { keep, remove, add };

const DiffOp = struct {
    kind: DiffOpKind,
    orig_idx: ?usize,
    mod_idx: ?usize,
};

const Hunk = struct {
    orig_start: usize,
    orig_count: usize,
    mod_start: usize,
    mod_count: usize,
    body: []const u8,
};

/// Split text into line slices, including the trailing newline (if any)
/// in each slice. Each line ends at either a '\n' or EOF.
fn splitLines(allocator: std.mem.Allocator, text: []const u8) ![][]const u8 {
    if (text.len == 0) return try allocator.alloc([]const u8, 0);

    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(allocator);

    var start: usize = 0;
    while (start < text.len) {
        const nl = std.mem.indexOfScalar(u8, text[start..], '\n');
        const end = if (nl) |pos| start + pos + 1 else text.len;
        try lines.append(allocator, text[start..end]);
        start = end;
    }

    return lines.toOwnedSlice(allocator);
}

/// Append a usize as decimal digits to an ArrayList.
fn appendUint(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, n: usize) !void {
    var tmp: [20]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{n}) catch unreachable;
    try buf.appendSlice(allocator, s);
}

/// JSON-escape a string for embedding in a JSON value.
fn escapeJsonString(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    for (s) |c| switch (c) {
        '"' => try buf.appendSlice(allocator, "\\\""),
        '\\' => try buf.appendSlice(allocator, "\\\\"),
        '\n' => try buf.appendSlice(allocator, "\\n"),
        '\r' => try buf.appendSlice(allocator, "\\r"),
        '\t' => try buf.appendSlice(allocator, "\\t"),
        0...0x07, 0x0b, 0x0e...0x1f => {
            var tmp: [8]u8 = undefined;
            const w = std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{c}) catch unreachable;
            try buf.appendSlice(allocator, w);
        },
        else => try buf.append(allocator, c),
    };

    return buf.toOwnedSlice(allocator);
}

// ─── tests ────────────────────────────────────────────────────────

const testing = std.testing;
const test_h = @import("../../test_helpers.zig");

fn writeTempFile(io: std.Io, path: []const u8, bytes: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    var f = try cwd.createFile(io, path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, bytes);
}

fn readAllAlloc(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const cwd = std.Io.Dir.cwd();
    var f = try cwd.openFile(io, path, .{});
    defer f.close(io);
    const len = try f.length(io);
    const buf = try allocator.alloc(u8, @intCast(len));
    _ = try f.readPositionalAll(io, buf, 0);
    return buf;
}

test "edit replaces a unique match" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const path = "/tmp/franky_edit_uniq.txt";
    defer _ = std.Io.Dir.cwd().deleteFile(io, path) catch {};

    try writeTempFile(io, path, "the quick brown fox\n");
    const edits = [_]EditOp{.{ .old = "brown", .new = "red", .replace_all = false }};
    var res = try applyEdits(gpa, io, path, &edits);
    defer res.deinit(gpa);
    try testing.expect(!res.is_error);
    const got = try readAllAlloc(gpa, io, path);
    defer gpa.free(got);
    try testing.expectEqualStrings("the quick red fox\n", got);
}

test "edit refuses ambiguous match without replaceAll" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const path = "/tmp/franky_edit_ambig.txt";
    defer _ = std.Io.Dir.cwd().deleteFile(io, path) catch {};

    try writeTempFile(io, path, "foo foo foo\n");
    const edits = [_]EditOp{.{ .old = "foo", .new = "bar", .replace_all = false }};
    var res = try applyEdits(gpa, io, path, &edits);
    defer res.deinit(gpa);
    try testing.expect(res.is_error);
    try testing.expect(std.mem.indexOf(u8, res.content[0].text.text, "edit_ambiguous") != null);
}

test "edit replaceAll replaces every occurrence" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const path = "/tmp/franky_edit_all.txt";
    defer _ = std.Io.Dir.cwd().deleteFile(io, path) catch {};

    try writeTempFile(io, path, "a b a b a\n");
    const edits = [_]EditOp{.{ .old = "a", .new = "X", .replace_all = true }};
    var res = try applyEdits(gpa, io, path, &edits);
    defer res.deinit(gpa);
    try testing.expect(!res.is_error);
    const got = try readAllAlloc(gpa, io, path);
    defer gpa.free(got);
    try testing.expectEqualStrings("X b X b X\n", got);
}

test "edit returns edit_file_empty when target file is 0 bytes" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const path = "/tmp/franky_edit_empty_file.txt";
    defer _ = std.Io.Dir.cwd().deleteFile(io, path) catch {};

    try writeTempFile(io, path, "");
    const edits = [_]EditOp{.{ .old = "anything", .new = "x", .replace_all = false }};
    var res = try applyEdits(gpa, io, path, &edits);
    defer res.deinit(gpa);
    try testing.expect(res.is_error);
    try testing.expect(std.mem.indexOf(u8, res.content[0].text.text, "edit_file_empty") != null);
    // The hint should NOT route through the edit_no_match retry-loop framing.
    try testing.expect(std.mem.indexOf(u8, res.content[0].text.text, "edit_no_match") == null);
}

test "edit errors when `old` not found" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const path = "/tmp/franky_edit_miss.txt";
    defer _ = std.Io.Dir.cwd().deleteFile(io, path) catch {};

    try writeTempFile(io, path, "hello world\n");
    const edits = [_]EditOp{.{ .old = "absent", .new = "x", .replace_all = false }};
    var res = try applyEdits(gpa, io, path, &edits);
    defer res.deinit(gpa);
    try testing.expect(res.is_error);
    try testing.expect(std.mem.indexOf(u8, res.content[0].text.text, "edit_no_match") != null);
}

test "edit applies multiple edits in order atomically" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const path = "/tmp/franky_edit_multi.txt";
    defer _ = std.Io.Dir.cwd().deleteFile(io, path) catch {};

    try writeTempFile(io, path, "alpha beta gamma\n");
    const edits = [_]EditOp{
        .{ .old = "alpha", .new = "A", .replace_all = false },
        .{ .old = "beta", .new = "B", .replace_all = false },
        .{ .old = "gamma", .new = "C", .replace_all = false },
    };
    var res = try applyEdits(gpa, io, path, &edits);
    defer res.deinit(gpa);
    try testing.expect(!res.is_error);
    const got = try readAllAlloc(gpa, io, path);
    defer gpa.free(got);
    try testing.expectEqualStrings("A B C\n", got);
}

test "edit diff renders every line of multi-line old/new (v1.26.3)" {
    // Regression for the http-trace failure where Gemini's parent
    // model reverted a sub-agent's correct multi-line edit because
    // the diff display only showed the first line of each side.
    // When `old` and `new` share a first line (common case: only
    // the *tail* of a block changed) the pre-v1.26.3 output looked
    // like `[0] - foo\n[0] + foo\n` — visually a no-op even though
    // four lines had been replaced.
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const path = "/tmp/franky_edit_multiline_diff.txt";
    defer _ = std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const before =
        "const role = data.role || 'plan';\n" ++
        "const provider = data.provider || '?';\n" ++
        "const model = data.model || '?';\n" ++
        "el.textContent = 'role: ' + role + ' · ' + provider + ':' + model;\n";
    try writeTempFile(io, path, before);

    const edits = [_]EditOp{.{
        .old = "const role = data.role || 'plan';\n" ++
            "const provider = data.provider || '?';\n" ++
            "const model = data.model || '?';\n" ++
            "el.textContent = 'role: ' + role + ' · ' + provider + ':' + model;",
        .new = "const role = data.role || 'plan';\n" ++
            "el.textContent = 'role: ' + role;",
        .replace_all = false,
    }};
    var res = try applyEdits(gpa, io, path, &edits);
    defer res.deinit(gpa);
    try testing.expect(!res.is_error);
    const summary = res.content[0].text.text;

    // Every line of `old` is rendered with `-`.
    try testing.expect(std.mem.indexOf(u8, summary, "-const provider") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "-const model") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "-el.textContent") != null);
    // Every line of `new` is rendered with `+`.
    try testing.expect(std.mem.indexOf(u8, summary, "+el.textContent = 'role: ' + role;") != null);
    // The shared first line shows on both sides — proves the diff
    // isn't suppressing identical-prefix lines (it's a literal
    // remove + add of the whole block, which is what actually
    // happened on disk).
    var minus_count: usize = 0;
    var plus_count: usize = 0;
    for (summary) |c| {
        if (c == '-') minus_count += 1;
        if (c == '+') plus_count += 1;
    }
    try testing.expect(minus_count >= 4);
    try testing.expect(plus_count >= 2);
}

test "edit diff elides huge replacements past the per-side cap" {
    // 30-line replacement should render head + elision + tail, not
    // 30 individual rows. Caps the worst-case tool result size on
    // wholesale rewrites.
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const path = "/tmp/franky_edit_diff_elision.txt";
    defer _ = std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(gpa);
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        const ln = try std.fmt.allocPrint(gpa, "line {d}\n", .{i});
        defer gpa.free(ln);
        try big.appendSlice(gpa, ln);
    }
    try writeTempFile(io, path, big.items);

    const edits = [_]EditOp{.{
        .old = big.items[0 .. big.items.len - 1], // drop trailing \n so the text matches as a literal
        .new = "shorter",
        .replace_all = false,
    }};
    var res = try applyEdits(gpa, io, path, &edits);
    defer res.deinit(gpa);
    try testing.expect(!res.is_error);
    const summary = res.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, summary, "more lines elided") != null);
}

test "edit diff renders empty new as `(empty)` sentinel" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const path = "/tmp/franky_edit_empty_side.txt";
    defer _ = std.Io.Dir.cwd().deleteFile(io, path) catch {};

    try writeTempFile(io, path, "remove me\n");
    const edits = [_]EditOp{.{
        .old = "remove me",
        .new = "",
        .replace_all = false,
    }};
    var res = try applyEdits(gpa, io, path, &edits);
    defer res.deinit(gpa);
    try testing.expect(!res.is_error);
    const summary = res.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, summary, "+(empty)") != null);
}

// ─── execute-level tests (args_json parsing recovery paths) ───────

fn callTool(gpa: std.mem.Allocator, io: std.Io, args_json: []const u8) !at.ToolResult {
    const t = tool();
    var cancel: ai.stream.Cancel = .{};
    return t.execute(&t, gpa, io, "", args_json, &cancel, .{});
}

test "execute: string-encoded edits (DeepSeek double-serialization)" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const path = "/tmp/franky_edit_str_edits.txt";
    defer _ = std.Io.Dir.cwd().deleteFile(io, path) catch {};

    try writeTempFile(io, path, "hello world\n");
    var res = try callTool(gpa, io,
        \\{"path":"/tmp/franky_edit_str_edits.txt","edits":"[{\"old\":\"hello\",\"new\":\"goodbye\"}]"}
    );
    defer res.deinit(gpa);
    try testing.expect(!res.is_error);
    const got = try readAllAlloc(gpa, io, path);
    defer gpa.free(got);
    try testing.expectEqualStrings("goodbye world\n", got);
}

test "execute: string-encoded edits with trailing garbage (DeepSeek batch)" {
    // Some DeepSeek configs append `, "path": "..."}]` after the array when
    // building multi-file edits, producing an invalid JSON string that still
    // has a valid array at the front.
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const path = "/tmp/franky_edit_str_trailing.txt";
    defer _ = std.Io.Dir.cwd().deleteFile(io, path) catch {};

    try writeTempFile(io, path, "hello world\n");
    var res = try callTool(gpa, io,
        \\{"path":"/tmp/franky_edit_str_trailing.txt","edits":"[{\"old\":\"hello\",\"new\":\"goodbye\"}], \"path\": \"src/coding/modes/proxy.zig\"}]"}
    );
    defer res.deinit(gpa);
    try testing.expect(!res.is_error);
    const got = try readAllAlloc(gpa, io, path);
    defer gpa.free(got);
    try testing.expectEqualStrings("goodbye world\n", got);
}

test "execute: flattened old/new at top level (missing edits key)" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const path = "/tmp/franky_edit_flat.txt";
    defer _ = std.Io.Dir.cwd().deleteFile(io, path) catch {};

    try writeTempFile(io, path, "the quick brown fox\n");
    var res = try callTool(gpa, io,
        \\{"path":"/tmp/franky_edit_flat.txt","old":"brown","new":"red"}
    );
    defer res.deinit(gpa);
    try testing.expect(!res.is_error);
    const got = try readAllAlloc(gpa, io, path);
    defer gpa.free(got);
    try testing.expectEqualStrings("the quick red fox\n", got);
}

test "edit_no_match hints at over-escaped backslashes when applicable" {
    // Zig multiline-string lines start with `\\` (two literal backslashes).
    // A model sometimes over-escapes these to `\\\\` (four backslashes) in
    // the `old` field. The resulting mismatch is confusing; detect it and
    // give a targeted hint.
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const path = "/tmp/franky_edit_backslash_hint.txt";
    defer _ = std.Io.Dir.cwd().deleteFile(io, path) catch {};

    // File has Zig multiline-string lines: each starts with two backslashes.
    try writeTempFile(io, path, "    \\\\foo bar\n    \\\\baz qux\n");

    // Model sends `old` with doubled backslashes (four backslashes per line).
    const edits = [_]EditOp{.{ .old = "    \\\\\\\\foo bar\n    \\\\\\\\baz qux", .new = "replaced", .replace_all = false }};
    var res = try applyEdits(gpa, io, path, &edits);
    defer res.deinit(gpa);
    try testing.expect(res.is_error);
    const msg = res.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, msg, "edit_no_match") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "over-escaping") != null);
}

test "edit_no_match generic message when no backslash hint applies" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const path = "/tmp/franky_edit_nohint.txt";
    defer _ = std.Io.Dir.cwd().deleteFile(io, path) catch {};

    try writeTempFile(io, path, "hello world\n");
    const edits = [_]EditOp{.{ .old = "completely absent", .new = "x", .replace_all = false }};
    var res = try applyEdits(gpa, io, path, &edits);
    defer res.deinit(gpa);
    try testing.expect(res.is_error);
    const msg = res.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, msg, "edit_no_match") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "over-escaping") == null);
}

test "execute: wrong edits type includes type name in error" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const path = "/tmp/franky_edit_bad_type.txt";
    defer _ = std.Io.Dir.cwd().deleteFile(io, path) catch {};

    try writeTempFile(io, path, "something\n");
    var res = try callTool(gpa, io,
        \\{"path":"/tmp/franky_edit_bad_type.txt","edits":42}
    );
    defer res.deinit(gpa);
    try testing.expect(res.is_error);
    try testing.expect(std.mem.indexOf(u8, res.content[0].text.text, "got number") != null);
}

// ─── §6.8 — wire-format contract tests for the web UI diff view ─────────
//
// These two tests pin the contract between `computeUnifiedDiff` (this
// file) and `parseUnifiedDiff` in `src/coding/modes/web/app.js`. A
// silent format drift between the two sides causes the browser to fall
// back to escaped raw text — these tests turn that silent drift into a
// loud test failure. If either fails after a deliberate format change,
// update BOTH the JS parser and the test fixture in lockstep.

test "computeUnifiedDiff: golden snapshot of the wire format" {
    const gpa = testing.allocator;

    const original = "alpha\nbeta\ngamma\ndelta\n";
    const modified = "alpha\nBETA\ngamma\ndelta\n";
    const got = try computeUnifiedDiff(gpa, original, modified, "f.txt");
    defer gpa.free(got);

    const want =
        "--- a/f.txt\n" ++
        "+++ b/f.txt\n" ++
        "@@ -1,4 +1,4 @@\n" ++
        " alpha\n" ++
        "-beta\n" ++
        "+BETA\n" ++
        " gamma\n" ++
        " delta\n";
    try testing.expectEqualStrings(want, got);
}

test "computeUnifiedDiff: every output line matches the JS parser's grammar" {
    const gpa = testing.allocator;

    // A multi-hunk fixture: two distant changes at the start and end of
    // the file so we exercise headers, multiple `@@` lines, and all
    // three body prefixes (` `, `-`, `+`).
    const original =
        "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n";
    const modified =
        "ONE\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nTEN\n";
    const got = try computeUnifiedDiff(gpa, original, modified, "f.txt");
    defer gpa.free(got);

    var lines = std.mem.splitScalar(u8, got, '\n');
    var line_idx: usize = 0;
    var hunk_count: usize = 0;
    while (lines.next()) |line| : (line_idx += 1) {
        if (line.len == 0) continue; // trailing empty after final \n
        // First two non-empty lines are the file headers.
        if (line_idx == 0) {
            try testing.expect(std.mem.startsWith(u8, line, "--- a/"));
            continue;
        }
        if (line_idx == 1) {
            try testing.expect(std.mem.startsWith(u8, line, "+++ b/"));
            continue;
        }
        // Subsequent lines are either hunk headers or body lines.
        if (std.mem.startsWith(u8, line, "@@")) {
            // Mirror the JS regex shape: `@@ -N(,M)? +N(,M)? @@`,
            // optionally followed by a trailing context label.
            try testing.expect(std.mem.endsWith(u8, line, " @@") or
                std.mem.indexOf(u8, line, " @@ ") != null);
            try testing.expect(std.mem.indexOf(u8, line, " -") != null);
            try testing.expect(std.mem.indexOf(u8, line, " +") != null);
            hunk_count += 1;
            continue;
        }
        // Body line — must start with ' ', '-', or '+'.
        const c = line[0];
        try testing.expect(c == ' ' or c == '-' or c == '+');
    }
    try testing.expect(hunk_count >= 1);
}

test "applyEdits: details_json carries the format version field" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const path = "/tmp/franky_edit_format_field.txt";
    defer _ = std.Io.Dir.cwd().deleteFile(io, path) catch {};

    try writeTempFile(io, path, "alpha\nbeta\ngamma\n");
    const edits = [_]EditOp{.{ .old = "beta", .new = "BETA", .replace_all = false }};
    var res = try applyEdits(gpa, io, path, &edits);
    defer res.deinit(gpa);
    try testing.expect(!res.is_error);
    try testing.expect(res.details_json != null);
    // The client allowlist matches this exact string — bump in lockstep.
    try testing.expect(std.mem.indexOf(u8, res.details_json.?, "\"format\":\"unified-diff-v1\"") != null);
}

test "edit tool: refuses to modify contextignored file (§6.9)" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const ws_root = "/tmp/franky_edit_contextignore";
    _ = std.Io.Dir.cwd().deleteTree(io, ws_root) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, ws_root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, ws_root);

    {
        var f = try std.Io.Dir.cwd().createFile(io, ws_root ++ "/.contextignore", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "archived.md\n");
    }
    {
        var f = try std.Io.Dir.cwd().createFile(io, ws_root ++ "/archived.md", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "frozen content\n");
    }
    {
        var f = try std.Io.Dir.cwd().createFile(io, ws_root ++ "/current.md", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "live content\n");
    }

    var ws: workspace_mod.Workspace = .{ .root = ws_root };
    const t = toolWithWorkspace(&ws);
    var cancel = ai.stream.Cancel{};

    // Editing the contextignored file is refused; the file on disk
    // must remain untouched.
    {
        var res = try t.execute(&t, gpa, io, "id1",
            "{\"path\":\"archived.md\",\"edits\":[{\"old\":\"frozen\",\"new\":\"changed\"}]}",
            &cancel, .{});
        defer res.deinit(gpa);
        try testing.expect(res.is_error);
        try testing.expectEqualStrings(common.tool_code_contextignored, res.tool_code.?);

        // Disk content unchanged.
        const got = try readAllAlloc(gpa, io, ws_root ++ "/archived.md");
        defer gpa.free(got);
        try testing.expectEqualStrings("frozen content\n", got);
    }

    // Editing a sibling that's not ignored still works.
    {
        var res = try t.execute(&t, gpa, io, "id2",
            "{\"path\":\"current.md\",\"edits\":[{\"old\":\"live\",\"new\":\"updated\"}]}",
            &cancel, .{});
        defer res.deinit(gpa);
        try testing.expect(!res.is_error);
        const got = try readAllAlloc(gpa, io, ws_root ++ "/current.md");
        defer gpa.free(got);
        try testing.expectEqualStrings("updated content\n", got);
    }
}
