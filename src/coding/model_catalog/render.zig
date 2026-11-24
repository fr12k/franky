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

    // Build the top-level object via std.json.Stringify, leveraging the
    // jsonStringify hooks on Entry/Cost/Capabilities (json_meta). The
    // anonymous wrapper carries the `version` + `generatedAt` envelope;
    // the `models` array serializes via the Entry hook.
    const wrapper = .{
        .version = @as(i64, 1),
        .generatedAt = opts.generated_at,
        .models = sorted,
    };
    const stringify_opts: std.json.Stringify.Options = if (opts.pretty)
        .{ .whitespace = .indent_2 }
    else
        .{ .whitespace = .minified };
    const json = try std.json.Stringify.valueAlloc(allocator, wrapper, stringify_opts);
    errdefer allocator.free(json);

    // The manual renderer appended a trailing newline after `}` in
    // pretty mode; replicate that so the output is byte-identical.
    if (opts.pretty) {
        const with_nl = try allocator.alloc(u8, json.len + 1);
        @memcpy(with_nl[0..json.len], json);
        with_nl[json.len] = '\n';
        allocator.free(json);
        return with_nl;
    }
    return json;
}

fn lessThanById(_: void, a: models.Entry, b: models.Entry) bool {
    return std.mem.lessThan(u8, a.id, b.id);
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
