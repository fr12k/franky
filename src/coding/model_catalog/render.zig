//! Models catalog renderer — §H.3 shape.
//!
//! Produces the canonical `models.json` JSON payload from a slice of
//! `models.Entry`. Used by `bin/gen_models.zig` (the `zig build
//! gen-models` target) to write a regenerated catalog. Pure logic;
//! no IO.
//!
//! Output is sorted by `id` for diff-friendly regeneration.

const std = @import("std");
const models = @import("models.zig");
const ai_utils = @import("../../ai/utils.zig");

pub const RenderOptions = struct {
    /// ISO-8601 timestamp written into `generatedAt`. Caller-supplied
    /// so the renderer stays pure (no clock dependency).
    generated_at: []const u8,
    /// Pretty-printed (2-space indent) when true; compact when false.
    /// Defaults to pretty so a freshly-generated file diffs cleanly.
    pretty: bool = true,
};

/// Render `entries` as `models.json` per §H.3. Caller owns the
/// returned slice. Entries are sorted by `id` (case-sensitive,
/// byte-wise) before emit so two runs over the same set produce the
/// same bytes regardless of input order.
pub fn render(
    allocator: std.mem.Allocator,
    entries: []const models.Entry,
    opts: RenderOptions,
) ![]u8 {
    const sorted = try allocator.dupe(models.Entry, entries);
    defer allocator.free(sorted);
    std.mem.sort(models.Entry, sorted, {}, lessThanById);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try writePreamble(&buf, allocator, &opts);
    for (sorted, 0..) |e, i| {
        try writeModelEntry(&buf, allocator, e, &opts);
        if (i + 1 < sorted.len) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, if (opts.pretty) "\n" else "");
    }
    try writeEpilogue(&buf, allocator, sorted.len, &opts);

    return buf.toOwnedSlice(allocator);
}

fn writePreamble(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, opts: *const RenderOptions) !void {
    const nl: []const u8 = if (opts.pretty) "\n" else "";
    const ind1: []const u8 = if (opts.pretty) "  " else "";
    const sp: []const u8 = if (opts.pretty) " " else "";

    try buf.appendSlice(allocator, "{");
    try buf.appendSlice(allocator, nl);

    try writeKv(buf, allocator, ind1, "version", .{ .integer = 1 }, opts.pretty);
    try buf.appendSlice(allocator, ",");
    try buf.appendSlice(allocator, nl);

    try buf.appendSlice(allocator, ind1);
    try buf.appendSlice(allocator, "\"generatedAt\":");
    try buf.appendSlice(allocator, sp);
    try ai_utils.appendJsonStr(buf, allocator, opts.generated_at);
    try buf.appendSlice(allocator, ",");
    try buf.appendSlice(allocator, nl);

    try buf.appendSlice(allocator, ind1);
    try buf.appendSlice(allocator, "\"models\":");
    try buf.appendSlice(allocator, sp);
    try buf.appendSlice(allocator, "[");
}

fn writeModelEntry(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, e: models.Entry, opts: *const RenderOptions) !void {
    const nl: []const u8 = if (opts.pretty) "\n" else "";
    const ind2: []const u8 = if (opts.pretty) "    " else "";
    const ind3: []const u8 = if (opts.pretty) "      " else "";

    try buf.appendSlice(allocator, nl);
    try buf.appendSlice(allocator, ind2);
    try buf.appendSlice(allocator, "{");
    try buf.appendSlice(allocator, nl);

    try writeStringField(buf, allocator, ind3, "id", e.id, opts.pretty);
    try buf.appendSlice(allocator, ",");
    try buf.appendSlice(allocator, nl);
    try writeStringField(buf, allocator, ind3, "provider", e.provider, opts.pretty);
    try buf.appendSlice(allocator, ",");
    try buf.appendSlice(allocator, nl);
    try writeStringField(buf, allocator, ind3, "api", e.api, opts.pretty);
    try buf.appendSlice(allocator, ",");
    try buf.appendSlice(allocator, nl);
    try writeStringField(buf, allocator, ind3, "displayName", e.display_name, opts.pretty);
    try buf.appendSlice(allocator, ",");
    try buf.appendSlice(allocator, nl);

    try writeKv(buf, allocator, ind3, "contextWindow", .{ .integer = e.context_window }, opts.pretty);
    try buf.appendSlice(allocator, ",");
    try buf.appendSlice(allocator, nl);
    try writeKv(buf, allocator, ind3, "maxOutput", .{ .integer = e.max_output }, opts.pretty);
    try buf.appendSlice(allocator, ",");
    try buf.appendSlice(allocator, nl);

    try writeCapabilities(buf, allocator, ind3, e.capabilities, opts.pretty);
    try buf.appendSlice(allocator, ",");
    try buf.appendSlice(allocator, nl);
    try writeCost(buf, allocator, ind3, e.cost, opts.pretty);
    try buf.appendSlice(allocator, ",");
    try buf.appendSlice(allocator, nl);

    try writeStringField(buf, allocator, ind3, "knowledgeCutoff", e.knowledge_cutoff, opts.pretty);
    try buf.appendSlice(allocator, nl);

    try buf.appendSlice(allocator, ind2);
    try buf.append(allocator, '}');
}

fn writeEpilogue(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, entry_count: usize, opts: *const RenderOptions) !void {
    const nl: []const u8 = if (opts.pretty) "\n" else "";
    const ind1: []const u8 = if (opts.pretty) "  " else "";

    if (entry_count > 0) try buf.appendSlice(allocator, ind1);
    try buf.appendSlice(allocator, "]");
    try buf.appendSlice(allocator, nl);
    try buf.appendSlice(allocator, "}");
    if (opts.pretty) try buf.append(allocator, '\n');
}

fn lessThanById(_: void, a: models.Entry, b: models.Entry) bool {
    return std.mem.lessThan(u8, a.id, b.id);
}

const Scalar = union(enum) {
    integer: u32,
    float: f32,
    boolean: bool,
};

fn writeKv(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    indent: []const u8,
    key: []const u8,
    value: Scalar,
    pretty: bool,
) !void {
    try buf.appendSlice(allocator, indent);
    try buf.append(allocator, '"');
    try buf.appendSlice(allocator, key);
    try buf.append(allocator, '"');
    try buf.append(allocator, ':');
    if (pretty) try buf.append(allocator, ' ');
    switch (value) {
        .integer => |n| {
            const s = try std.fmt.allocPrint(allocator, "{d}", .{n});
            defer allocator.free(s);
            try buf.appendSlice(allocator, s);
        },
        .float => |f| {
            const s = try std.fmt.allocPrint(allocator, "{d}", .{f});
            defer allocator.free(s);
            try buf.appendSlice(allocator, s);
        },
        .boolean => |b| try buf.appendSlice(allocator, if (b) "true" else "false"),
    }
}

fn writeStringField(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    indent: []const u8,
    key: []const u8,
    val: []const u8,
    pretty: bool,
) !void {
    try buf.appendSlice(allocator, indent);
    try buf.append(allocator, '"');
    try buf.appendSlice(allocator, key);
    try buf.append(allocator, '"');
    try buf.append(allocator, ':');
    if (pretty) try buf.append(allocator, ' ');
    try ai_utils.appendJsonStr(buf, allocator, val);
}

fn writeCapabilities(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    indent: []const u8,
    c: models.Capabilities,
    pretty: bool,
) !void {
    const inner_indent = if (pretty) try std.fmt.allocPrint(allocator, "{s}  ", .{indent}) else try allocator.dupe(u8, "");
    defer allocator.free(inner_indent);

    try buf.appendSlice(allocator, indent);
    try buf.appendSlice(allocator, "\"capabilities\":");
    if (pretty) try buf.append(allocator, ' ');
    try buf.append(allocator, '{');
    if (pretty) try buf.append(allocator, '\n');
    try writeKv(buf, allocator, inner_indent, "vision", .{ .boolean = c.vision }, pretty);
    try buf.append(allocator, ',');
    if (pretty) try buf.append(allocator, '\n');
    try writeKv(buf, allocator, inner_indent, "toolUse", .{ .boolean = c.tool_use }, pretty);
    try buf.append(allocator, ',');
    if (pretty) try buf.append(allocator, '\n');
    try writeKv(buf, allocator, inner_indent, "reasoning", .{ .boolean = c.reasoning }, pretty);
    try buf.append(allocator, ',');
    if (pretty) try buf.append(allocator, '\n');
    try writeKv(buf, allocator, inner_indent, "cache", .{ .boolean = c.cache }, pretty);
    try buf.append(allocator, ',');
    if (pretty) try buf.append(allocator, '\n');
    try writeKv(buf, allocator, inner_indent, "streaming", .{ .boolean = c.streaming }, pretty);
    if (pretty) try buf.append(allocator, '\n');
    try buf.appendSlice(allocator, indent);
    try buf.append(allocator, '}');
}

fn writeCost(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    indent: []const u8,
    c: models.Cost,
    pretty: bool,
) !void {
    const inner_indent = if (pretty) try std.fmt.allocPrint(allocator, "{s}  ", .{indent}) else try allocator.dupe(u8, "");
    defer allocator.free(inner_indent);

    try buf.appendSlice(allocator, indent);
    try buf.appendSlice(allocator, "\"cost\":");
    if (pretty) try buf.append(allocator, ' ');
    try buf.append(allocator, '{');
    if (pretty) try buf.append(allocator, '\n');
    try writeKv(buf, allocator, inner_indent, "inputPer1M", .{ .float = c.input_per_1m }, pretty);
    try buf.append(allocator, ',');
    if (pretty) try buf.append(allocator, '\n');
    try writeKv(buf, allocator, inner_indent, "outputPer1M", .{ .float = c.output_per_1m }, pretty);
    try buf.append(allocator, ',');
    if (pretty) try buf.append(allocator, '\n');
    try writeKv(buf, allocator, inner_indent, "cacheReadPer1M", .{ .float = c.cache_read_per_1m }, pretty);
    try buf.append(allocator, ',');
    if (pretty) try buf.append(allocator, '\n');
    try writeKv(buf, allocator, inner_indent, "cacheWritePer1M", .{ .float = c.cache_write_per_1m }, pretty);
    if (pretty) try buf.append(allocator, '\n');
    try buf.appendSlice(allocator, indent);
    try buf.append(allocator, '}');
}

/// Append `s` with JSON-string escaping. Handles `"`, `\`, control
/// chars; assumes valid UTF-8.
// ─── tests ────────────────────────────────────────────────────────

const testing = std.testing;

test "render: empty entries yields skeleton with empty models array" {
    const out = try render(testing.allocator, &.{}, .{ .generated_at = "2026-04-25T00:00:00Z" });
    defer testing.allocator.free(out);
    const expected =
        "{\n" ++
        "  \"version\": 1,\n" ++
        "  \"generatedAt\": \"2026-04-25T00:00:00Z\",\n" ++
        "  \"models\": []\n" ++
        "}\n";
    try testing.expectEqualStrings(expected, out);
}

test "render: single entry covers all §H.3 fields and pretty layout" {
    const e = models.Entry{
        .id = "test-model",
        .provider = "test",
        .api = "openai-chat-completions",
        .display_name = "Test Model",
        .context_window = 32_000,
        .max_output = 4_096,
        .capabilities = .{ .vision = true, .tool_use = true, .reasoning = false, .cache = false, .streaming = true },
        .cost = .{ .input_per_1m = 1.5, .output_per_1m = 3.0 },
        .knowledge_cutoff = "2025-06",
    };
    const out = try render(testing.allocator, &.{e}, .{ .generated_at = "2026-04-25T00:00:00Z" });
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"id\": \"test-model\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"provider\": \"test\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"contextWindow\": 32000") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"maxOutput\": 4096") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"vision\": true") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"reasoning\": false") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"inputPer1M\": 1.5") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"knowledgeCutoff\": \"2025-06\"") != null);
}

test "render: entries are sorted by id regardless of input order" {
    const a = models.Entry{
        .id = "zzz",
        .provider = "p",
        .api = "a",
        .display_name = "Z",
        .context_window = 0,
        .max_output = 0,
        .capabilities = .{},
        .cost = .{},
        .knowledge_cutoff = "",
    };
    const b = models.Entry{ .id = "aaa", .provider = "p", .api = "a", .display_name = "A", .context_window = 0, .max_output = 0, .capabilities = .{}, .cost = .{}, .knowledge_cutoff = "" };
    const out = try render(testing.allocator, &.{ a, b }, .{ .generated_at = "t" });
    defer testing.allocator.free(out);
    const idx_a = std.mem.indexOf(u8, out, "\"id\": \"aaa\"") orelse return error.TestUnexpectedResult;
    const idx_z = std.mem.indexOf(u8, out, "\"id\": \"zzz\"") orelse return error.TestUnexpectedResult;
    try testing.expect(idx_a < idx_z);
}

test "render: round-trips through models.parseFromSlice" {
    const e = models.Entry{
        .id = "m-rt",
        .provider = "rt-prov",
        .api = "anthropic-messages",
        .display_name = "RT Model",
        .context_window = 200_000,
        .max_output = 8192,
        .capabilities = .{ .vision = false, .tool_use = true, .reasoning = true, .cache = true, .streaming = true },
        .cost = .{ .input_per_1m = 3.0, .output_per_1m = 15.0, .cache_read_per_1m = 0.30, .cache_write_per_1m = 3.75 },
        .knowledge_cutoff = "2025-12",
    };
    const json = try render(testing.allocator, &.{e}, .{ .generated_at = "2026-04-25T00:00:00Z" });
    defer testing.allocator.free(json);

    const parsed = try models.parseFromSlice(testing.allocator, json);
    defer models.freeEntries(testing.allocator, parsed);

    try testing.expectEqual(@as(usize, 1), parsed.len);
    const got = parsed[0];
    try testing.expectEqualStrings(e.id, got.id);
    try testing.expectEqualStrings(e.provider, got.provider);
    try testing.expectEqualStrings(e.api, got.api);
    try testing.expectEqualStrings(e.display_name, got.display_name);
    try testing.expectEqual(e.context_window, got.context_window);
    try testing.expectEqual(e.max_output, got.max_output);
    try testing.expectEqual(e.capabilities.vision, got.capabilities.vision);
    try testing.expectEqual(e.capabilities.reasoning, got.capabilities.reasoning);
    try testing.expectApproxEqAbs(e.cost.input_per_1m, got.cost.input_per_1m, 0.001);
    try testing.expectApproxEqAbs(e.cost.cache_write_per_1m, got.cost.cache_write_per_1m, 0.001);
    try testing.expectEqualStrings(e.knowledge_cutoff, got.knowledge_cutoff);
}

test "render: special characters in strings are JSON-escaped" {
    const e = models.Entry{
        .id = "with-quote-\"-inside",
        .provider = "p",
        .api = "a",
        .display_name = "back\\slash",
        .context_window = 0,
        .max_output = 0,
        .capabilities = .{},
        .cost = .{},
        .knowledge_cutoff = "",
    };
    const out = try render(testing.allocator, &.{e}, .{ .generated_at = "t" });
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "with-quote-\\\"-inside") != null);
    try testing.expect(std.mem.indexOf(u8, out, "back\\\\slash") != null);
}

test "render: compact mode produces single-line output" {
    const e = models.Entry{
        .id = "c",
        .provider = "p",
        .api = "a",
        .display_name = "C",
        .context_window = 1,
        .max_output = 1,
        .capabilities = .{},
        .cost = .{},
        .knowledge_cutoff = "",
    };
    const out = try render(testing.allocator, &.{e}, .{ .generated_at = "t", .pretty = false });
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\n") == null);
}
