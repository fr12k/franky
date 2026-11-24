//! Models catalog — §3.7 + §H.3.
//!
//! A port-time generated catalog of well-known models with their
//! provider, API tag, context window, max output, and capability
//! flags. Ships with a tiny **built-in** set covering the providers
//! already wired in v0.3.*. Users can augment via a disk file
//! (`<cwd>/models.json` or `$FRANKY_HOME/models.json`) whose entries
//! override or extend the built-ins by `id`.
//!
//! Scope note (v0.7.2): this module ships the catalog + lookup +
//! loader + merge semantics. A real `zig build gen-models` step that
//! regenerates the catalog from an authoritative external source
//! is the roadmap's follow-up — today the built-ins are hand-edited,
//! and the disk-JSON path exists so downstream users can add their
//! own models without a franky rebuild.

const std = @import("std");

pub const Capabilities = struct {
    vision: bool = false,
    tool_use: bool = true,
    reasoning: bool = false,
    cache: bool = false,
    streaming: bool = true,

    pub const json_meta = .{
        .tool_use = .{ .rename = "toolUse" },
    };

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try @import("../../ai/json_meta.zig").stringifyWithMeta(self, jw);
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        options: std.json.ParseOptions,
    ) !Capabilities {
        _ = options;
        return @import("../../ai/json_meta.zig").parseWithMeta(Capabilities, allocator, source);
    }
};

pub const Cost = struct {
    input_per_1m: f32 = 0,
    output_per_1m: f32 = 0,
    cache_read_per_1m: f32 = 0,
    cache_write_per_1m: f32 = 0,

    /// `.format = .shortest_float` renders each f32 with `{d}` (shortest
    /// round-trip, e.g. `0.3`), matching the prior manual renderer. Without
    /// it, `jw.write(f32)` would emit full precision (`0.30000001192092896`),
    /// changing models.json bytes.
    pub const json_meta = .{
        .input_per_1m = .{ .rename = "inputPer1M", .format = .shortest_float },
        .output_per_1m = .{ .rename = "outputPer1M", .format = .shortest_float },
        .cache_read_per_1m = .{ .rename = "cacheReadPer1M", .format = .shortest_float },
        .cache_write_per_1m = .{ .rename = "cacheWritePer1M", .format = .shortest_float },
    };

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try @import("../../ai/json_meta.zig").stringifyWithMeta(self, jw);
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        options: std.json.ParseOptions,
    ) !Cost {
        _ = options;
        return @import("../../ai/json_meta.zig").parseWithMeta(Cost, allocator, source);
    }
};

pub const Entry = struct {
    id: []const u8,
    provider: []const u8,
    api: []const u8,
    display_name: []const u8,
    context_window: u32,
    max_output: u32,
    capabilities: Capabilities,
    cost: Cost,
    knowledge_cutoff: []const u8,

    pub const json_meta = .{
        .display_name = .{ .rename = "displayName" },
        .context_window = .{ .rename = "contextWindow" },
        .max_output = .{ .rename = "maxOutput" },
        .knowledge_cutoff = .{ .rename = "knowledgeCutoff" },
    };

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try @import("../../ai/json_meta.zig").stringifyWithMeta(self, jw);
    }

    /// Parse a `std.json.Value` (object) into an `Entry` via the generic
    /// `json_meta.parseWithMeta` helper (which recurses into `capabilities`
    /// / `cost` via their own hooks and dups the string fields). Requires
    /// `id`; `display_name` falls back to `id` when absent (matching the
    /// prior manual parser).
    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        options: std.json.ParseOptions,
    ) !Entry {
        _ = options;
        if (source != .object) return error.UnexpectedToken;
        const id_v = source.object.get("id") orelse return error.MissingField;
        if (id_v != .string) return error.UnexpectedToken;
        var e = try @import("../../ai/json_meta.zig").parseWithMeta(Entry, allocator, source);
        // `display_name` falls back to `id` when the `displayName` key is
        // absent OR present-but-not-a-string — matching the prior manual
        // parser's `strOr(o, "displayName", id)`, which used the default in
        // both cases. An explicitly-empty `displayName` string is kept.
        if (source.object.get("displayName")) |dn| {
            if (dn != .string) e.display_name = try allocator.dupe(u8, id_v.string);
        } else {
            e.display_name = try allocator.dupe(u8, id_v.string);
        }
        return e;
    }
};

/// Built-in catalog. Order matters for `lookup`: the first match
/// wins. Disk layers add/override entries by `id`.
pub const builtin: []const Entry = &.{
    .{
        .id = "claude-opus-4-7",
        .provider = "anthropic",
        .api = "anthropic-messages",
        .display_name = "Claude Opus 4.7",
        .context_window = 1_000_000,
        .max_output = 8192,
        .capabilities = .{ .vision = true, .tool_use = true, .reasoning = true, .cache = true, .streaming = true },
        .cost = .{ .input_per_1m = 15.0, .output_per_1m = 75.0, .cache_read_per_1m = 1.5, .cache_write_per_1m = 18.75 },
        .knowledge_cutoff = "2026-01",
    },
    .{
        .id = "claude-sonnet-4-6",
        .provider = "anthropic",
        .api = "anthropic-messages",
        .display_name = "Claude Sonnet 4.6",
        .context_window = 1_000_000,
        .max_output = 8192,
        .capabilities = .{ .vision = true, .tool_use = true, .reasoning = true, .cache = true, .streaming = true },
        .cost = .{ .input_per_1m = 3.0, .output_per_1m = 15.0, .cache_read_per_1m = 0.30, .cache_write_per_1m = 3.75 },
        .knowledge_cutoff = "2025-12",
    },
    .{
        .id = "claude-haiku-4-5",
        .provider = "anthropic",
        .api = "anthropic-messages",
        .display_name = "Claude Haiku 4.5",
        .context_window = 200_000,
        .max_output = 4096,
        .capabilities = .{ .vision = true, .tool_use = true, .reasoning = false, .cache = true, .streaming = true },
        .cost = .{ .input_per_1m = 0.80, .output_per_1m = 4.0, .cache_read_per_1m = 0.08, .cache_write_per_1m = 1.0 },
        .knowledge_cutoff = "2025-06",
    },
    .{
        .id = "gpt-5",
        .provider = "openai",
        .api = "openai-chat-completions",
        .display_name = "GPT-5",
        .context_window = 400_000,
        .max_output = 16384,
        .capabilities = .{ .vision = true, .tool_use = true, .reasoning = true, .cache = false, .streaming = true },
        .cost = .{ .input_per_1m = 5.0, .output_per_1m = 20.0 },
        .knowledge_cutoff = "2025-09",
    },
};

pub const ModelsError = error{
    MalformedJson,
} || std.mem.Allocator.Error;

/// Lookup by `id` (first match wins). Scans the combined catalog:
/// disk entries (from `extras`) first, then built-ins. Returns a
/// borrowed `Entry` — no ownership transfer.
pub fn lookup(extras: []const Entry, id: []const u8) ?Entry {
    for (extras) |e| if (std.mem.eql(u8, e.id, id)) return e;
    for (builtin) |e| if (std.mem.eql(u8, e.id, id)) return e;
    return null;
}

/// Parse `models.json` bytes into a heap-allocated slice of
/// `Entry`s. Each string field is owned by `allocator`; free via
/// `freeEntries`.
pub fn parseFromSlice(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) ModelsError![]Entry {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const parsed = std.json.parseFromSlice(std.json.Value, scratch.allocator(), bytes, .{}) catch return ModelsError.MalformedJson;
    if (parsed.value != .object) return ModelsError.MalformedJson;

    const models_v = parsed.value.object.get("models") orelse return try allocator.alloc(Entry, 0);
    if (models_v != .array) return ModelsError.MalformedJson;

    var out: std.ArrayList(Entry) = .empty;
    errdefer {
        for (out.items) |*e| freeEntry(allocator, e);
        out.deinit(allocator);
    }

    for (models_v.array.items) |item| {
        if (item != .object) continue;
        // Parse via the Entry.jsonParseFromValue hook (requires id, dups the
        // string fields, recurses into capabilities/cost, camelCase renames,
        // display_name falls back to id). Entries with a missing/malformed id
        // are skipped, matching the prior manual loop.
        const entry = std.json.parseFromValueLeaky(Entry, allocator, item, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory, // hard failure — don't skip entries silently
            else => continue, // shape error → skip entry (matching prior loop)
        };
        try out.append(allocator, entry);
    }
    return try out.toOwnedSlice(allocator);
}

pub fn freeEntries(allocator: std.mem.Allocator, entries: []Entry) void {
    for (entries) |*e| freeEntry(allocator, e);
    allocator.free(entries);
}

fn freeEntry(allocator: std.mem.Allocator, e: *Entry) void {
    allocator.free(e.id);
    allocator.free(e.provider);
    allocator.free(e.api);
    allocator.free(e.display_name);
    allocator.free(e.knowledge_cutoff);
}

// ─── tests ────────────────────────────────────────────────────────

const testing = std.testing;

test "lookup: hits the built-in catalog for every registered id" {
    for (builtin) |e| {
        const found = lookup(&.{}, e.id);
        try testing.expect(found != null);
        try testing.expectEqualStrings(e.id, found.?.id);
    }
}

test "lookup: unknown id returns null" {
    try testing.expect(lookup(&.{}, "gpt-99-imaginary") == null);
}

test "lookup: extras shadow built-ins by id" {
    const overrides = [_]Entry{.{
        .id = "gpt-5",
        .provider = "custom",
        .api = "openai-chat-completions",
        .display_name = "Our Private GPT-5",
        .context_window = 128_000,
        .max_output = 4096,
        .capabilities = .{},
        .cost = .{},
        .knowledge_cutoff = "2025-01",
    }};
    const found = lookup(&overrides, "gpt-5").?;
    try testing.expectEqualStrings("custom", found.provider);
    try testing.expectEqualStrings("Our Private GPT-5", found.display_name);
}

test "parseFromSlice: round-trips id/provider/api/contextWindow/maxOutput" {
    const gpa = testing.allocator;
    const bytes =
        \\{"version":1,"models":[
        \\  {"id":"m-a","provider":"p","api":"openai-chat-completions",
        \\   "displayName":"M A","contextWindow":32000,"maxOutput":4096,
        \\   "capabilities":{"vision":true,"toolUse":true,"reasoning":false},
        \\   "cost":{"inputPer1M":1.5,"outputPer1M":3.0},
        \\   "knowledgeCutoff":"2025-06"}
        \\]}
    ;
    const entries = try parseFromSlice(gpa, bytes);
    defer freeEntries(gpa, entries);

    try testing.expectEqual(@as(usize, 1), entries.len);
    const e = entries[0];
    try testing.expectEqualStrings("m-a", e.id);
    try testing.expectEqualStrings("p", e.provider);
    try testing.expectEqualStrings("openai-chat-completions", e.api);
    try testing.expectEqualStrings("M A", e.display_name);
    try testing.expectEqual(@as(u32, 32000), e.context_window);
    try testing.expectEqual(@as(u32, 4096), e.max_output);
    try testing.expect(e.capabilities.vision);
    try testing.expect(e.capabilities.tool_use);
    try testing.expect(!e.capabilities.reasoning);
    try testing.expectApproxEqAbs(@as(f32, 1.5), e.cost.input_per_1m, 0.001);
    try testing.expectEqualStrings("2025-06", e.knowledge_cutoff);
}

test "parseFromSlice: empty models array yields empty slice" {
    const gpa = testing.allocator;
    const entries = try parseFromSlice(gpa, "{\"models\":[]}");
    defer freeEntries(gpa, entries);
    try testing.expectEqual(@as(usize, 0), entries.len);
}

test "parseFromSlice: malformed JSON surfaces MalformedJson" {
    const err = parseFromSlice(testing.allocator, "{ not json ");
    try testing.expectError(ModelsError.MalformedJson, err);
}

test "parseFromSlice: entries without id are skipped" {
    const gpa = testing.allocator;
    const bytes =
        \\{"models":[{"provider":"x"},{"id":"ok","provider":"p","api":"a"}]}
    ;
    const entries = try parseFromSlice(gpa, bytes);
    defer freeEntries(gpa, entries);
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("ok", entries[0].id);
}

test "parseFromSlice: absent capability keys keep their non-zero defaults" {
    // Regression guard for the json_meta parse migration: parseWithMeta must
    // default-initialise from the struct's declared defaults, NOT
    // std.mem.zeroes — otherwise `tool_use = true` and `streaming = true`
    // would silently parse as false when the keys (or the whole
    // `capabilities` object) are absent.
    const gpa = testing.allocator;
    const bytes =
        \\{"models":[{"id":"ok","provider":"p","api":"a"}]}
    ;
    const entries = try parseFromSlice(gpa, bytes);
    defer freeEntries(gpa, entries);
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqual(true, entries[0].capabilities.tool_use);
    try testing.expectEqual(true, entries[0].capabilities.streaming);
}
