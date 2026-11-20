//! Per-provider models-endpoint response parsers.
//!
//! Pure logic: each function takes raw response bytes from a provider's
//! `GET /models`-equivalent endpoint and produces a `[]models.Entry`
//! slice in our canonical shape. The HTTP fetch itself lives in
//! `bin/gen_models.zig` (the `zig build gen-models` driver) so this
//! module stays unit-testable with fixture bytes.
//!
//! What each provider's endpoint exposes (and what we therefore can
//! populate without a hand-curated overlay):
//!
//! - **Anthropic** `GET /v1/models` → `id` + `display_name`. No
//!   context window, no pricing, no capabilities. Defaults the rest.
//! - **OpenAI** `GET /v1/models` → `id` only (plus `owned_by` /
//!   `created`, neither of which we propagate). Defaults the rest.
//! - **Google Gemini** `GET /v1beta/models` → `name` + `displayName`
//!   + `inputTokenLimit` + `outputTokenLimit` +
//!   `supportedGenerationMethods`. Richest info; we set
//!   `context_window`, `max_output`, and infer `streaming = true` and
//!   `tool_use = true` from the supported-methods list.
//!
//! Pricing and the rest of the §H.3 metadata come from the merge step
//! in `bin/gen_models.zig` — built-in entries supply pricing/cutoff
//! when an id matches.

const std = @import("std");
const models = @import("models.zig");
const utils = @import("../../ai/utils.zig");

pub const FetchError = error{
    MalformedJson,
} || std.mem.Allocator.Error;

/// Parse Anthropic's `GET /v1/models` response. Shape:
/// ```json
/// {"data":[{"id":"...", "display_name":"...", "type":"model", "created_at":"..."}], "first_id":..., "last_id":..., "has_more":false}
/// ```
pub fn parseAnthropic(allocator: std.mem.Allocator, bytes: []const u8) FetchError![]models.Entry {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const parsed = std.json.parseFromSlice(std.json.Value, scratch.allocator(), bytes, .{}) catch return FetchError.MalformedJson;
    if (parsed.value != .object) return FetchError.MalformedJson;

    const data = parsed.value.object.get("data") orelse return try allocator.alloc(models.Entry, 0);
    if (data != .array) return FetchError.MalformedJson;

    var out: std.ArrayList(models.Entry) = .empty;
    errdefer freeAndDeinit(allocator, &out);

    for (data.array.items) |item| {
        if (item != .object) continue;
        const o = item.object;
        const id = utils.jsonStr(o, "id") orelse continue;
        const display_name = utils.jsonStr(o, "display_name") orelse id;
        try out.append(allocator, .{
            .id = try allocator.dupe(u8, id),
            .provider = try allocator.dupe(u8, "anthropic"),
            .api = try allocator.dupe(u8, "anthropic-messages"),
            .display_name = try allocator.dupe(u8, display_name),
            .context_window = 0,
            .max_output = 0,
            .capabilities = .{},
            .cost = .{},
            .knowledge_cutoff = try allocator.dupe(u8, ""),
        });
    }
    return out.toOwnedSlice(allocator);
}

/// Parse OpenAI's `GET /v1/models` response. Shape:
/// ```json
/// {"object":"list","data":[{"id":"gpt-4","object":"model","created":...,"owned_by":"openai"}]}
/// ```
pub fn parseOpenAI(allocator: std.mem.Allocator, bytes: []const u8) FetchError![]models.Entry {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const parsed = std.json.parseFromSlice(std.json.Value, scratch.allocator(), bytes, .{}) catch return FetchError.MalformedJson;
    if (parsed.value != .object) return FetchError.MalformedJson;

    const data = parsed.value.object.get("data") orelse return try allocator.alloc(models.Entry, 0);
    if (data != .array) return FetchError.MalformedJson;

    var out: std.ArrayList(models.Entry) = .empty;
    errdefer freeAndDeinit(allocator, &out);

    for (data.array.items) |item| {
        if (item != .object) continue;
        const id = utils.jsonStr(item.object, "id") orelse continue;
        try out.append(allocator, .{
            .id = try allocator.dupe(u8, id),
            .provider = try allocator.dupe(u8, "openai"),
            .api = try allocator.dupe(u8, "openai-chat-completions"),
            .display_name = try allocator.dupe(u8, id),
            .context_window = 0,
            .max_output = 0,
            .capabilities = .{},
            .cost = .{},
            .knowledge_cutoff = try allocator.dupe(u8, ""),
        });
    }
    return out.toOwnedSlice(allocator);
}

/// Predicate: does this id name a chat-completion-compatible model?
///
/// OpenAI's `/v1/models` returns every model the key has access to —
/// chat, image, audio, embedding, moderation, legacy completion, and
/// specialty endpoints. Only the chat-completion-compatible subset
/// makes sense for franky's runtime, since the catalog hard-codes
/// `api: "openai-chat-completions"` for OpenAI entries.
///
/// The predicate is a denylist on id patterns; OpenAI doesn't expose
/// a model-type field on the response so id matching is the only
/// signal. Conservative bias — anything that looks ambiguous is kept.
pub fn isChatCompletionId(id: []const u8) bool {
    // Drop legacy completion-only models.
    if (std.mem.startsWith(u8, id, "babbage-")) return false;
    if (std.mem.startsWith(u8, id, "davinci-")) return false;

    // Drop image / video models.
    if (std.mem.startsWith(u8, id, "dall-e")) return false;
    if (std.mem.startsWith(u8, id, "gpt-image")) return false;
    if (std.mem.startsWith(u8, id, "chatgpt-image")) return false;
    if (std.mem.startsWith(u8, id, "sora-")) return false;

    // Drop audio / TTS / realtime models.
    if (std.mem.startsWith(u8, id, "tts-")) return false;
    if (std.mem.startsWith(u8, id, "whisper-")) return false;
    if (std.mem.startsWith(u8, id, "gpt-audio")) return false;
    if (std.mem.startsWith(u8, id, "gpt-realtime")) return false;
    if (std.mem.indexOf(u8, id, "-audio") != null) return false;
    if (std.mem.indexOf(u8, id, "-realtime") != null) return false;
    if (std.mem.indexOf(u8, id, "-tts") != null) return false;
    if (std.mem.indexOf(u8, id, "-transcribe") != null) return false;

    // Drop embeddings.
    if (std.mem.startsWith(u8, id, "text-embedding-")) return false;

    // Drop moderation.
    if (std.mem.indexOf(u8, id, "moderation") != null) return false;

    // Drop specialty endpoints (search APIs, deep research) — these
    // accept different request shapes than `/v1/chat/completions`.
    if (std.mem.indexOf(u8, id, "-search-") != null) return false;
    if (std.mem.indexOf(u8, id, "-deep-research") != null) return false;

    // Drop legacy completion-style instruct variants.
    if (std.mem.indexOf(u8, id, "-instruct") != null) return false;

    return true;
}

/// Parse Ollama's `GET /api/tags` response (its native "list installed
/// models" endpoint). Shape:
///
/// ```json
/// {"models":[{"name":"llama3.2:latest","model":"llama3.2:latest",
///              "modified_at":"...","size":2019393189,"digest":"sha256:...",
///              "details":{"parameter_size":"3.2B","family":"llama",
///                         "quantization_level":"Q4_K_M",...}}]}
/// ```
///
/// No context window or capabilities flags are exposed by `/api/tags` —
/// for that we need a follow-up `POST /api/show` per entry (see
/// `parseOllamaShow`). The `gen-models` driver does that loop and
/// merges the result via `enrichWithShow`.
///
/// The full `name:tag` (e.g. `llama3.2:1b`) is kept as the id so
/// variants stay distinct — `llama3.2:1b` and `llama3.2:3b` are
/// different models and need different catalog entries. This also
/// matches the runtime call shape — Ollama's `/v1/chat/completions`
/// expects the full `name:tag` as `model`.
///
/// Mapped to `provider: "ollama", api: "openai-compatible-gateway"`
/// since Ollama serves its OpenAI-compat surface at
/// `/v1/chat/completions`.
pub fn parseOllama(allocator: std.mem.Allocator, bytes: []const u8) FetchError![]models.Entry {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const parsed = std.json.parseFromSlice(std.json.Value, scratch.allocator(), bytes, .{}) catch return FetchError.MalformedJson;
    if (parsed.value != .object) return FetchError.MalformedJson;

    const data = parsed.value.object.get("models") orelse return try allocator.alloc(models.Entry, 0);
    if (data != .array) return FetchError.MalformedJson;

    var out: std.ArrayList(models.Entry) = .empty;
    errdefer freeAndDeinit(allocator, &out);

    for (data.array.items) |item| {
        if (item != .object) continue;
        const o = item.object;
        const name = utils.jsonStr(o, "name") orelse continue;

        // Display name: include the parameter size when reported,
        // e.g. "llama3.2:1b (1.2B)".
        const param_size: ?[]const u8 = blk: {
            const details = o.get("details") orelse break :blk null;
            if (details != .object) break :blk null;
            break :blk utils.jsonStr(details.object, "parameter_size");
        };
        const display_name = if (param_size) |p|
            try std.fmt.allocPrint(allocator, "{s} ({s})", .{ name, p })
        else
            try allocator.dupe(u8, name);
        errdefer allocator.free(display_name);

        try out.append(allocator, .{
            .id = try allocator.dupe(u8, name),
            .provider = try allocator.dupe(u8, "ollama"),
            .api = try allocator.dupe(u8, "openai-compatible-gateway"),
            .display_name = display_name,
            .context_window = 0,
            .max_output = 0,
            .capabilities = .{
                .vision = false,
                .tool_use = true,
                .reasoning = false,
                .cache = false,
                .streaming = true,
            },
            .cost = .{},
            .knowledge_cutoff = try allocator.dupe(u8, ""),
        });
    }
    return out.toOwnedSlice(allocator);
}

/// Per-model details extracted from `POST /api/show`. Used by
/// `gen_models.zig` to enrich the entries returned by `parseOllama`
/// (which only has access to `/api/tags`).
pub const OllamaShowDetails = struct {
    context_window: u32 = 0,
    parameter_count: u64 = 0,
    capabilities: models.Capabilities = .{},
};

/// Parse Ollama's `POST /api/show` response. Body sent: `{"model":"<id>"}`.
/// Response shape (only the fields we care about):
///
/// ```json
/// {
///   "model_info": {
///     "general.architecture": "llama",
///     "general.parameter_count": 3212749824,
///     "llama.context_length": 131072,
///     ...
///   },
///   "capabilities": ["completion", "tools"]
/// }
/// ```
///
/// Lookup rules:
/// - **Architecture key** is `model_info["general.architecture"]`. The
///   context window lives at `<arch>.context_length` — e.g.
///   `llama.context_length`, `qwen2.context_length`, `gemma.context_length`,
///   `phi3.context_length`, `deepseek2.context_length`.
/// - **Parameter count** is `model_info["general.parameter_count"]`.
/// - **Capabilities** array maps:
///   - `"tools"` → `tool_use = true`
///   - `"vision"` → `vision = true`
///   - `"completion"` (or any non-embedding presence) → `streaming = true`
///   - `"embedding"`-only → `streaming = false`, `tool_use = false`
///
/// Missing fields default to zero / false. A response that doesn't
/// even have `model_info` returns `OllamaShowDetails{}` (all zero).
pub fn parseOllamaShow(allocator: std.mem.Allocator, bytes: []const u8) FetchError!OllamaShowDetails {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const parsed = std.json.parseFromSlice(std.json.Value, scratch.allocator(), bytes, .{}) catch return FetchError.MalformedJson;
    if (parsed.value != .object) return FetchError.MalformedJson;
    const root = parsed.value.object;

    var out = OllamaShowDetails{};

    // model_info.<arch>.context_length + general.parameter_count
    if (root.get("model_info")) |mi| if (mi == .object) {
        const info = mi.object;
        if (utils.jsonStr(info, "general.architecture")) |arch| {
            const ctx_key = try std.fmt.allocPrint(scratch.allocator(), "{s}.context_length", .{arch});
            if (info.get(ctx_key)) |v| switch (v) {
                .integer => |i| {
                    // Clamp to u32 range to match our Entry.context_window
                    // type. Anything beyond that is degenerate input.
                    if (i > 0 and i <= std.math.maxInt(u32)) out.context_window = @intCast(i);
                },
                else => {},
            };
        }
        // Parameter count is its own integer (sometimes returned as a
        // float by older Ollama builds — handle both).
        if (info.get("general.parameter_count")) |v| switch (v) {
            .integer => |i| if (i >= 0) {
                out.parameter_count = @intCast(i);
            },
            .float => |f| if (f >= 0) {
                out.parameter_count = @intFromFloat(f);
            },
            else => {},
        };
    };

    // capabilities array → Capabilities struct.
    var has_completion = false;
    var has_embedding = false;
    var has_tools = false;
    var has_vision = false;
    if (root.get("capabilities")) |c| if (c == .array) {
        for (c.array.items) |item| if (item == .string) {
            const s = item.string;
            if (std.mem.eql(u8, s, "completion")) has_completion = true;
            if (std.mem.eql(u8, s, "embedding")) has_embedding = true;
            if (std.mem.eql(u8, s, "tools")) has_tools = true;
            if (std.mem.eql(u8, s, "vision")) has_vision = true;
        };
    };
    out.capabilities = .{
        .vision = has_vision,
        .tool_use = has_tools,
        .reasoning = false, // Ollama doesn't expose a reasoning flag
        .cache = false,
        .streaming = has_completion or !has_embedding,
    };
    return out;
}

/// Apply enrichment from `parseOllamaShow` to an entry returned by
/// `parseOllama`. The entry's owned strings are kept; only the
/// numeric / capability fields are updated.
pub fn enrichWithShow(entry: *models.Entry, show: OllamaShowDetails) void {
    if (show.context_window > 0) entry.context_window = show.context_window;
    // Capabilities are authoritative when /api/show responded — the
    // /api/tags defaults (`tool_use = true`, `streaming = true`) are
    // optimistic guesses since /api/tags has no info.
    entry.capabilities = show.capabilities;
}

/// Parse Google Gemini's `GET /v1beta/models` response. Shape:
/// ```json
/// {"models":[{"name":"models/gemini-1.5-pro","displayName":"Gemini 1.5 Pro",
///             "inputTokenLimit":2097152,"outputTokenLimit":8192,
///             "supportedGenerationMethods":["generateContent","countTokens"]}]}
/// ```
///
/// `name` comes back prefixed with `models/`; we strip it for the
/// `id` field. `tool_use` is inferred from the presence of
/// `generateContent` in `supportedGenerationMethods` (the only
/// method that supports function calls).
pub fn parseGoogleGemini(allocator: std.mem.Allocator, bytes: []const u8) FetchError![]models.Entry {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const parsed = std.json.parseFromSlice(std.json.Value, scratch.allocator(), bytes, .{}) catch return FetchError.MalformedJson;
    if (parsed.value != .object) return FetchError.MalformedJson;

    const data = parsed.value.object.get("models") orelse return try allocator.alloc(models.Entry, 0);
    if (data != .array) return FetchError.MalformedJson;

    var out: std.ArrayList(models.Entry) = .empty;
    errdefer freeAndDeinit(allocator, &out);

    for (data.array.items) |item| {
        if (item != .object) continue;
        const o = item.object;
        const raw_name = utils.jsonStr(o, "name") orelse continue;
        const id = stripPrefix(raw_name, "models/");
        if (id.len == 0) continue;
        const display_name = utils.jsonStr(o, "displayName") orelse id;
        const ctx_window = u32Field(o, "inputTokenLimit");
        const max_out = u32Field(o, "outputTokenLimit");
        const supports_generate = arrayContainsString(o, "supportedGenerationMethods", "generateContent");

        try out.append(allocator, .{
            .id = try allocator.dupe(u8, id),
            .provider = try allocator.dupe(u8, "google"),
            .api = try allocator.dupe(u8, "google-gemini"),
            .display_name = try allocator.dupe(u8, display_name),
            .context_window = ctx_window,
            .max_output = max_out,
            .capabilities = .{
                .vision = false,
                .tool_use = supports_generate,
                .reasoning = false,
                .cache = false,
                .streaming = supports_generate,
            },
            .cost = .{},
            .knowledge_cutoff = try allocator.dupe(u8, ""),
        });
    }
    return out.toOwnedSlice(allocator);
}

/// Merge `live` over `base` by `id`. For each `live` entry, if a
/// matching id exists in `base`, the merged entry takes:
///   - `id`/`provider`/`api`/`display_name` from `live` (so endpoint
///     renames flow through)
///   - `context_window`/`max_output` from `live` if non-zero, else
///     from `base` (so when the endpoint omits limits we keep our
///     hand-curated values)
///   - `capabilities`/`cost`/`knowledge_cutoff` from `base` (the
///     endpoint exposes none of these reliably)
/// Entries in `base` not present in `live` are preserved as-is.
/// Entries in `live` with no matching id are kept verbatim.
///
/// Returned slice owns all string fields via `allocator`. Caller
/// frees with `models.freeEntries`. `base` and `live` are unaffected.
pub fn merge(
    allocator: std.mem.Allocator,
    base: []const models.Entry,
    live: []const models.Entry,
) ![]models.Entry {
    var out: std.ArrayList(models.Entry) = .empty;
    errdefer freeAndDeinit(allocator, &out);

    // First pass: for each live entry, look up a base match and merge.
    for (live) |l| {
        const base_match: ?models.Entry = blk: {
            for (base) |b| if (std.mem.eql(u8, b.id, l.id)) break :blk b;
            break :blk null;
        };
        try out.append(allocator, try cloneMerged(allocator, l, base_match));
    }

    // Second pass: keep base entries with no live match.
    for (base) |b| {
        const has_live = blk: {
            for (live) |l| if (std.mem.eql(u8, b.id, l.id)) break :blk true;
            break :blk false;
        };
        if (!has_live) try out.append(allocator, try cloneEntry(allocator, b));
    }
    return out.toOwnedSlice(allocator);
}

fn cloneMerged(
    allocator: std.mem.Allocator,
    live: models.Entry,
    base: ?models.Entry,
) !models.Entry {
    if (base) |b| {
        const ctx = if (live.context_window != 0) live.context_window else b.context_window;
        const mx = if (live.max_output != 0) live.max_output else b.max_output;
        return .{
            .id = try allocator.dupe(u8, live.id),
            .provider = try allocator.dupe(u8, live.provider),
            .api = try allocator.dupe(u8, live.api),
            .display_name = try allocator.dupe(u8, live.display_name),
            .context_window = ctx,
            .max_output = mx,
            .capabilities = b.capabilities,
            .cost = b.cost,
            .knowledge_cutoff = try allocator.dupe(u8, b.knowledge_cutoff),
        };
    }
    return cloneEntry(allocator, live);
}

fn cloneEntry(allocator: std.mem.Allocator, e: models.Entry) !models.Entry {
    return .{
        .id = try allocator.dupe(u8, e.id),
        .provider = try allocator.dupe(u8, e.provider),
        .api = try allocator.dupe(u8, e.api),
        .display_name = try allocator.dupe(u8, e.display_name),
        .context_window = e.context_window,
        .max_output = e.max_output,
        .capabilities = e.capabilities,
        .cost = e.cost,
        .knowledge_cutoff = try allocator.dupe(u8, e.knowledge_cutoff),
    };
}

fn freeAndDeinit(allocator: std.mem.Allocator, list: *std.ArrayList(models.Entry)) void {
    for (list.items) |*e| {
        allocator.free(e.id);
        allocator.free(e.provider);
        allocator.free(e.api);
        allocator.free(e.display_name);
        allocator.free(e.knowledge_cutoff);
    }
    list.deinit(allocator);
}

// v1.33.0 — `stringField` moved to `ai/utils.zig` as `jsonStr`.
fn u32Field(o: std.json.ObjectMap, key: []const u8) u32 {
    if (o.get(key)) |v| switch (v) {
        .integer => |i| if (i >= 0) return @intCast(i),
        else => {},
    };
    return 0;
}

fn arrayContainsString(o: std.json.ObjectMap, key: []const u8, needle: []const u8) bool {
    if (o.get(key)) |v| if (v == .array) {
        for (v.array.items) |item| if (item == .string and std.mem.eql(u8, item.string, needle)) return true;
    };
    return false;
}

fn stripPrefix(s: []const u8, prefix: []const u8) []const u8 {
    if (std.mem.startsWith(u8, s, prefix)) return s[prefix.len..];
    return s;
}

// ─── tests ────────────────────────────────────────────────────────

const testing = std.testing;

test "parseAnthropic: extracts id + display_name, defaults the rest" {
    const bytes =
        \\{"data":[
        \\  {"id":"claude-opus-4-7","display_name":"Claude Opus 4.7","type":"model","created_at":"2026-01-01T00:00:00Z"},
        \\  {"id":"claude-sonnet-4-6","display_name":"Claude Sonnet 4.6","type":"model","created_at":"2025-12-01T00:00:00Z"}
        \\],"has_more":false}
    ;
    const entries = try parseAnthropic(testing.allocator, bytes);
    defer models.freeEntries(testing.allocator, entries);
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqualStrings("claude-opus-4-7", entries[0].id);
    try testing.expectEqualStrings("Claude Opus 4.7", entries[0].display_name);
    try testing.expectEqualStrings("anthropic", entries[0].provider);
    try testing.expectEqualStrings("anthropic-messages", entries[0].api);
    try testing.expectEqual(@as(u32, 0), entries[0].context_window);
}

test "parseAnthropic: missing data key is treated as empty" {
    const entries = try parseAnthropic(testing.allocator, "{\"has_more\":false}");
    defer models.freeEntries(testing.allocator, entries);
    try testing.expectEqual(@as(usize, 0), entries.len);
}

test "parseAnthropic: malformed JSON surfaces MalformedJson" {
    try testing.expectError(FetchError.MalformedJson, parseAnthropic(testing.allocator, "{ broken"));
}

test "parseOpenAI: extracts id only" {
    const bytes =
        \\{"object":"list","data":[
        \\  {"id":"gpt-5","object":"model","created":1700000000,"owned_by":"openai"},
        \\  {"id":"gpt-4o","object":"model","created":1690000000,"owned_by":"openai"}
        \\]}
    ;
    const entries = try parseOpenAI(testing.allocator, bytes);
    defer models.freeEntries(testing.allocator, entries);
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqualStrings("gpt-5", entries[0].id);
    try testing.expectEqualStrings("gpt-5", entries[0].display_name);
    try testing.expectEqualStrings("openai-chat-completions", entries[0].api);
}

test "parseGoogleGemini: extracts id, display, token limits, infers tool_use" {
    const bytes =
        \\{"models":[
        \\  {"name":"models/gemini-2.0-pro","displayName":"Gemini 2.0 Pro",
        \\   "inputTokenLimit":2097152,"outputTokenLimit":8192,
        \\   "supportedGenerationMethods":["generateContent","countTokens"]},
        \\  {"name":"models/embedding-001","displayName":"Embedding 001",
        \\   "inputTokenLimit":2048,"outputTokenLimit":1,
        \\   "supportedGenerationMethods":["embedContent"]}
        \\]}
    ;
    const entries = try parseGoogleGemini(testing.allocator, bytes);
    defer models.freeEntries(testing.allocator, entries);
    try testing.expectEqual(@as(usize, 2), entries.len);

    try testing.expectEqualStrings("gemini-2.0-pro", entries[0].id);
    try testing.expectEqualStrings("Gemini 2.0 Pro", entries[0].display_name);
    try testing.expectEqual(@as(u32, 2_097_152), entries[0].context_window);
    try testing.expectEqual(@as(u32, 8192), entries[0].max_output);
    try testing.expect(entries[0].capabilities.tool_use);
    try testing.expect(entries[0].capabilities.streaming);

    try testing.expectEqualStrings("embedding-001", entries[1].id);
    try testing.expect(!entries[1].capabilities.tool_use);
    try testing.expect(!entries[1].capabilities.streaming);
}

test "parseGoogleGemini: name without `models/` prefix passes through" {
    const bytes =
        \\{"models":[{"name":"plain-id","displayName":"Plain","inputTokenLimit":1024,"outputTokenLimit":256,"supportedGenerationMethods":["generateContent"]}]}
    ;
    const entries = try parseGoogleGemini(testing.allocator, bytes);
    defer models.freeEntries(testing.allocator, entries);
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("plain-id", entries[0].id);
}

test "merge: live takes pricing + cutoff from base on id match" {
    const base = [_]models.Entry{.{
        .id = "claude-sonnet-4-6",
        .provider = "anthropic",
        .api = "anthropic-messages",
        .display_name = "Old Display",
        .context_window = 200_000,
        .max_output = 8192,
        .capabilities = .{ .vision = true, .tool_use = true, .reasoning = true, .cache = true, .streaming = true },
        .cost = .{ .input_per_1m = 3.0, .output_per_1m = 15.0, .cache_read_per_1m = 0.30, .cache_write_per_1m = 3.75 },
        .knowledge_cutoff = "2025-12",
    }};
    const live = [_]models.Entry{.{
        .id = "claude-sonnet-4-6",
        .provider = "anthropic",
        .api = "anthropic-messages",
        .display_name = "New Display From API",
        .context_window = 0, // missing; falls back to base
        .max_output = 0,
        .capabilities = .{},
        .cost = .{},
        .knowledge_cutoff = "",
    }};
    const merged = try merge(testing.allocator, &base, &live);
    defer models.freeEntries(testing.allocator, merged);

    try testing.expectEqual(@as(usize, 1), merged.len);
    const m = merged[0];
    try testing.expectEqualStrings("New Display From API", m.display_name);
    try testing.expectEqual(@as(u32, 200_000), m.context_window);
    try testing.expectEqual(@as(u32, 8192), m.max_output);
    try testing.expectApproxEqAbs(@as(f32, 3.0), m.cost.input_per_1m, 0.001);
    try testing.expectEqualStrings("2025-12", m.knowledge_cutoff);
    try testing.expect(m.capabilities.cache);
}

test "merge: live limits override base when non-zero" {
    const base = [_]models.Entry{.{
        .id = "x",
        .provider = "p",
        .api = "a",
        .display_name = "x",
        .context_window = 100_000,
        .max_output = 4096,
        .capabilities = .{},
        .cost = .{},
        .knowledge_cutoff = "",
    }};
    const live = [_]models.Entry{.{
        .id = "x",
        .provider = "p",
        .api = "a",
        .display_name = "x",
        .context_window = 200_000,
        .max_output = 8192,
        .capabilities = .{},
        .cost = .{},
        .knowledge_cutoff = "",
    }};
    const merged = try merge(testing.allocator, &base, &live);
    defer models.freeEntries(testing.allocator, merged);
    try testing.expectEqual(@as(u32, 200_000), merged[0].context_window);
    try testing.expectEqual(@as(u32, 8192), merged[0].max_output);
}

test "merge: base entries with no live match are preserved" {
    const base = [_]models.Entry{
        .{ .id = "alpha", .provider = "p", .api = "a", .display_name = "A", .context_window = 1, .max_output = 1, .capabilities = .{}, .cost = .{}, .knowledge_cutoff = "" },
        .{ .id = "beta", .provider = "p", .api = "a", .display_name = "B", .context_window = 2, .max_output = 2, .capabilities = .{}, .cost = .{}, .knowledge_cutoff = "" },
    };
    const live: []const models.Entry = &.{};
    const merged = try merge(testing.allocator, &base, live);
    defer models.freeEntries(testing.allocator, merged);
    try testing.expectEqual(@as(usize, 2), merged.len);
}

test "isChatCompletionId: keeps gpt/o-series chat models" {
    const keep = [_][]const u8{
        "gpt-3.5-turbo",
        "gpt-3.5-turbo-0125",
        "gpt-3.5-turbo-16k",
        "gpt-4",
        "gpt-4-0613",
        "gpt-4-turbo",
        "gpt-4-turbo-2024-04-09",
        "gpt-4.1",
        "gpt-4.1-mini",
        "gpt-4.1-nano",
        "gpt-4o",
        "gpt-4o-mini",
        "gpt-4o-2024-08-06",
        "gpt-5",
        "gpt-5-chat-latest",
        "gpt-5-codex",
        "gpt-5-mini",
        "gpt-5-nano",
        "gpt-5-pro",
        "gpt-5.1",
        "gpt-5.1-codex",
        "gpt-5.4-pro-2026-03-05",
        "gpt-5.5",
        "o1",
        "o1-pro",
        "o3",
        "o3-mini",
        "o4-mini",
        "chatgpt-4o-latest",
    };
    for (keep) |id| try testing.expect(isChatCompletionId(id));
}

test "isChatCompletionId: drops non-chat models" {
    const drop = [_][]const u8{
        // Legacy completion-only
        "babbage-002",
        "davinci-002",
        "gpt-3.5-turbo-instruct",
        "gpt-3.5-turbo-instruct-0914",
        // Image / video
        "dall-e-2",
        "dall-e-3",
        "gpt-image-1",
        "gpt-image-2-2026-04-21",
        "chatgpt-image-latest",
        "sora-2",
        "sora-2-pro",
        // Audio / TTS / realtime
        "tts-1",
        "tts-1-hd",
        "whisper-1",
        "gpt-audio",
        "gpt-audio-mini-2025-12-15",
        "gpt-realtime",
        "gpt-realtime-mini-2025-12-15",
        "gpt-4o-audio-preview",
        "gpt-4o-mini-audio-preview-2024-12-17",
        "gpt-4o-realtime-preview",
        "gpt-4o-mini-tts-2025-03-20",
        "gpt-4o-mini-transcribe",
        "gpt-4o-transcribe-diarize",
        // Embeddings / moderation
        "text-embedding-3-large",
        "text-embedding-ada-002",
        "omni-moderation-latest",
        // Specialty endpoints
        "gpt-4o-search-preview",
        "gpt-5-search-api-2025-10-14",
        "o4-mini-deep-research-2025-06-26",
    };
    for (drop) |id| try testing.expect(!isChatCompletionId(id));
}

test "parseOllama: keeps full name:tag as id so variants stay distinct" {
    const bytes =
        \\{"models":[
        \\  {"name":"llama3.2:1b","model":"llama3.2:1b","modified_at":"2026-04-25T00:00:00Z",
        \\   "size":1300000000,"digest":"sha256:aaa",
        \\   "details":{"family":"llama","parameter_size":"1.2B","quantization_level":"Q4_K_M"}},
        \\  {"name":"llama3.2:3b","model":"llama3.2:3b","modified_at":"2026-04-25T00:00:00Z",
        \\   "size":2019393189,"digest":"sha256:bbb",
        \\   "details":{"family":"llama","parameter_size":"3.2B","quantization_level":"Q4_K_M"}},
        \\  {"name":"qwen2.5-coder:7b","model":"qwen2.5-coder:7b","modified_at":"2026-04-20T00:00:00Z",
        \\   "size":4683073184,"digest":"sha256:def",
        \\   "details":{"family":"qwen2","parameter_size":"7B","quantization_level":"Q4_K_M"}},
        \\  {"name":"mistral:latest","model":"mistral:latest","modified_at":"2026-04-15T00:00:00Z",
        \\   "size":4109868544,"digest":"sha256:ghi",
        \\   "details":{}}
        \\]}
    ;
    const entries = try parseOllama(testing.allocator, bytes);
    defer models.freeEntries(testing.allocator, entries);

    try testing.expectEqual(@as(usize, 4), entries.len);

    try testing.expectEqualStrings("llama3.2:1b", entries[0].id);
    try testing.expectEqualStrings("llama3.2:1b (1.2B)", entries[0].display_name);
    try testing.expectEqualStrings("ollama", entries[0].provider);
    try testing.expectEqualStrings("openai-compatible-gateway", entries[0].api);

    try testing.expectEqualStrings("llama3.2:3b", entries[1].id);
    try testing.expectEqualStrings("llama3.2:3b (3.2B)", entries[1].display_name);

    try testing.expectEqualStrings("qwen2.5-coder:7b", entries[2].id);

    // No `parameter_size` → display falls back to bare name.
    try testing.expectEqualStrings("mistral:latest", entries[3].id);
    try testing.expectEqualStrings("mistral:latest", entries[3].display_name);
}

test "parseOllamaShow: extracts <arch>.context_length + parameter_count + capabilities" {
    const bytes =
        \\{
        \\  "modelfile": "...",
        \\  "details":{"parameter_size":"3.2B","family":"llama"},
        \\  "model_info":{
        \\    "general.architecture":"llama",
        \\    "general.file_type":15,
        \\    "general.parameter_count":3212749824,
        \\    "general.quantization_version":2,
        \\    "llama.attention.head_count":24,
        \\    "llama.block_count":28,
        \\    "llama.context_length":131072,
        \\    "llama.embedding_length":3072
        \\  },
        \\  "capabilities":["completion","tools"]
        \\}
    ;
    const show = try parseOllamaShow(testing.allocator, bytes);
    try testing.expectEqual(@as(u32, 131_072), show.context_window);
    try testing.expectEqual(@as(u64, 3_212_749_824), show.parameter_count);
    try testing.expect(show.capabilities.tool_use);
    try testing.expect(show.capabilities.streaming);
    try testing.expect(!show.capabilities.vision);
}

test "parseOllamaShow: vision + tools combo flags both" {
    const bytes =
        \\{"model_info":{"general.architecture":"qwen2","qwen2.context_length":32768,"general.parameter_count":7000000000},
        \\ "capabilities":["completion","tools","vision"]}
    ;
    const show = try parseOllamaShow(testing.allocator, bytes);
    try testing.expectEqual(@as(u32, 32_768), show.context_window);
    try testing.expect(show.capabilities.tool_use);
    try testing.expect(show.capabilities.vision);
    try testing.expect(show.capabilities.streaming);
}

test "parseOllamaShow: embedding-only model marks streaming=false, tool_use=false" {
    const bytes =
        \\{"model_info":{"general.architecture":"bert","bert.context_length":512},
        \\ "capabilities":["embedding"]}
    ;
    const show = try parseOllamaShow(testing.allocator, bytes);
    try testing.expectEqual(@as(u32, 512), show.context_window);
    try testing.expect(!show.capabilities.streaming);
    try testing.expect(!show.capabilities.tool_use);
    try testing.expect(!show.capabilities.vision);
}

test "parseOllamaShow: missing model_info returns zero defaults" {
    const show = try parseOllamaShow(testing.allocator, "{}");
    try testing.expectEqual(@as(u32, 0), show.context_window);
    try testing.expectEqual(@as(u64, 0), show.parameter_count);
    // With no capabilities array, has_completion=false, has_embedding=false →
    // streaming = (false or !false) = true. That matches the optimistic
    // tags-only default; a /api/show response with no capabilities is
    // anomalous anyway.
    try testing.expect(show.capabilities.streaming);
}

test "parseOllamaShow: arch mismatch → context_window stays 0" {
    // model_info claims llama but only has gemma.context_length —
    // lookup fails, no context window is recorded.
    const bytes =
        \\{"model_info":{"general.architecture":"llama","gemma.context_length":8192}}
    ;
    const show = try parseOllamaShow(testing.allocator, bytes);
    try testing.expectEqual(@as(u32, 0), show.context_window);
}

test "parseOllamaShow: malformed JSON surfaces MalformedJson" {
    try testing.expectError(FetchError.MalformedJson, parseOllamaShow(testing.allocator, "{ broken"));
}

test "enrichWithShow: applies context_window + capabilities, preserves owned strings" {
    const gpa = testing.allocator;
    const e_init = models.Entry{
        .id = try gpa.dupe(u8, "llama3.2:3b"),
        .provider = try gpa.dupe(u8, "ollama"),
        .api = try gpa.dupe(u8, "openai-compatible-gateway"),
        .display_name = try gpa.dupe(u8, "llama3.2:3b (3.2B)"),
        .context_window = 0,
        .max_output = 0,
        .capabilities = .{ .vision = false, .tool_use = true, .reasoning = false, .cache = false, .streaming = true },
        .cost = .{},
        .knowledge_cutoff = try gpa.dupe(u8, ""),
    };
    var entry = e_init;
    defer {
        gpa.free(entry.id);
        gpa.free(entry.provider);
        gpa.free(entry.api);
        gpa.free(entry.display_name);
        gpa.free(entry.knowledge_cutoff);
    }

    enrichWithShow(&entry, .{
        .context_window = 131_072,
        .parameter_count = 3_212_749_824,
        .capabilities = .{ .vision = false, .tool_use = true, .reasoning = false, .cache = false, .streaming = true },
    });

    try testing.expectEqual(@as(u32, 131_072), entry.context_window);
    // Strings unchanged.
    try testing.expectEqualStrings("llama3.2:3b", entry.id);
    try testing.expectEqualStrings("llama3.2:3b (3.2B)", entry.display_name);
}

test "enrichWithShow: zero context_window from /api/show preserves entry's prior value" {
    const gpa = testing.allocator;
    var entry = models.Entry{
        .id = try gpa.dupe(u8, "x"),
        .provider = try gpa.dupe(u8, "ollama"),
        .api = try gpa.dupe(u8, "openai-compatible-gateway"),
        .display_name = try gpa.dupe(u8, "x"),
        .context_window = 8192, // something the entry already had (e.g. from --base)
        .max_output = 0,
        .capabilities = .{},
        .cost = .{},
        .knowledge_cutoff = try gpa.dupe(u8, ""),
    };
    defer {
        gpa.free(entry.id);
        gpa.free(entry.provider);
        gpa.free(entry.api);
        gpa.free(entry.display_name);
        gpa.free(entry.knowledge_cutoff);
    }

    enrichWithShow(&entry, .{}); // all zero
    // /api/show returned no context_length info → keep the prior 8192.
    try testing.expectEqual(@as(u32, 8192), entry.context_window);
}

test "parseOllama: empty / missing models field yields empty slice" {
    const e1 = try parseOllama(testing.allocator, "{\"models\":[]}");
    defer models.freeEntries(testing.allocator, e1);
    try testing.expectEqual(@as(usize, 0), e1.len);

    const e2 = try parseOllama(testing.allocator, "{}");
    defer models.freeEntries(testing.allocator, e2);
    try testing.expectEqual(@as(usize, 0), e2.len);
}

test "merge: live entries with no base match are kept verbatim" {
    const base: []const models.Entry = &.{};
    const live = [_]models.Entry{.{ .id = "new", .provider = "p", .api = "a", .display_name = "N", .context_window = 5, .max_output = 5, .capabilities = .{}, .cost = .{}, .knowledge_cutoff = "" }};
    const merged = try merge(testing.allocator, base, &live);
    defer models.freeEntries(testing.allocator, merged);
    try testing.expectEqual(@as(usize, 1), merged.len);
    try testing.expectEqualStrings("new", merged[0].id);
}
