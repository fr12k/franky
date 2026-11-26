//! Core data types — §3.2 of the spec.
//!
//! All plain structs/unions; every value is serializable to JSON. Messages
//! and content blocks own the memory behind their string slices; callers
//! call `deinit(allocator)` to release.

const std = @import("std");
const json_meta = @import("json_meta.zig");
const json_meta_mod = json_meta; // unshadowed alias for use inside structs that declare their own `json_meta`

/// TextContent — `TextContent` in spec.
pub const TextContent = struct {
    text: []const u8,
    /// Provider-specific opaque metadata for multi-turn continuity.
    text_signature: ?[]const u8 = null,

    pub fn deinit(self: TextContent, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        if (self.text_signature) |s| allocator.free(s);
    }

    pub fn dupe(self: TextContent, allocator: std.mem.Allocator) !TextContent {
        const text = try allocator.dupe(u8, self.text);
        errdefer allocator.free(text);
        const sig = if (self.text_signature) |s| try allocator.dupe(u8, s) else null;
        return .{ .text = text, .text_signature = sig };
    }
};

/// ThinkingContent — the assistant's internal reasoning.
pub const ThinkingContent = struct {
    thinking: []const u8,
    thinking_signature: ?[]const u8 = null,
    /// True when the provider redacted the reasoning but still returned an
    /// opaque round-trippable signature.
    redacted: bool = false,

    pub fn deinit(self: ThinkingContent, allocator: std.mem.Allocator) void {
        allocator.free(self.thinking);
        if (self.thinking_signature) |s| allocator.free(s);
    }

    pub fn dupe(self: ThinkingContent, allocator: std.mem.Allocator) !ThinkingContent {
        const thinking = try allocator.dupe(u8, self.thinking);
        errdefer allocator.free(thinking);
        const sig = if (self.thinking_signature) |s| try allocator.dupe(u8, s) else null;
        return .{ .thinking = thinking, .thinking_signature = sig, .redacted = self.redacted };
    }
};

/// ImageContent — base64 inline image.
pub const ImageContent = struct {
    /// Base64 data (no `data:` prefix).
    data: []const u8,
    mime_type: []const u8,

    pub fn deinit(self: ImageContent, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
        allocator.free(self.mime_type);
    }

    pub fn dupe(self: ImageContent, allocator: std.mem.Allocator) !ImageContent {
        const data = try allocator.dupe(u8, self.data);
        errdefer allocator.free(data);
        const mime = try allocator.dupe(u8, self.mime_type);
        return .{ .data = data, .mime_type = mime };
    }
};

/// ToolCall — request for a tool to be executed.
pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    /// Raw JSON string (serialized arguments object). Kept as string so
    /// partial-json state during streaming maps cleanly; parsed strictly
    /// before handing to the tool.
    arguments_json: []const u8,
    /// Google only — round-trip opaque.
    thought_signature: ?[]const u8 = null,

    pub fn deinit(self: ToolCall, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.arguments_json);
        if (self.thought_signature) |s| allocator.free(s);
    }

    pub fn dupe(self: ToolCall, allocator: std.mem.Allocator) !ToolCall {
        const id = try allocator.dupe(u8, self.id);
        errdefer allocator.free(id);
        const name = try allocator.dupe(u8, self.name);
        errdefer allocator.free(name);
        const args = try allocator.dupe(u8, self.arguments_json);
        errdefer allocator.free(args);
        const sig = if (self.thought_signature) |s| try allocator.dupe(u8, s) else null;
        return .{ .id = id, .name = name, .arguments_json = args, .thought_signature = sig };
    }
};

/// Tagged union over the content-block variants a message can hold.
///
/// `UserMessage` accepts `.text` + `.image`, `AssistantMessage` accepts
/// `.text` + `.thinking` + `.tool_call`, `ToolResultMessage` accepts
/// `.text` + `.image`.
pub const ContentBlock = union(enum) {
    text: TextContent,
    thinking: ThinkingContent,
    image: ImageContent,
    tool_call: ToolCall,

    pub fn deinit(self: ContentBlock, allocator: std.mem.Allocator) void {
        switch (self) {
            .text => |v| v.deinit(allocator),
            .thinking => |v| v.deinit(allocator),
            .image => |v| v.deinit(allocator),
            .tool_call => |v| v.deinit(allocator),
        }
    }

    pub fn dupe(self: ContentBlock, allocator: std.mem.Allocator) !ContentBlock {
        return switch (self) {
            .text => |v| .{ .text = try v.dupe(allocator) },
            .thinking => |v| .{ .thinking = try v.dupe(allocator) },
            .image => |v| .{ .image = try v.dupe(allocator) },
            .tool_call => |v| .{ .tool_call = try v.dupe(allocator) },
        };
    }
};

/// Usage — per-turn token counts and costs.
pub const Usage = struct {
    input: u64 = 0,
    output: u64 = 0,
    cache_read: u64 = 0,
    cache_write: u64 = 0,
    /// v1.32.0 — thinking (reasoning) tokens for this turn.
    /// Anthropic reports this in `usage.output_tokens_details.thinking_tokens`;
    /// OpenRouter/gateways may surface it in `completion_tokens_details.reasoning_tokens`.
    thinking_tokens: u64 = 0,
    /// v1.32.0 — Anthropic splits `cache_creation_input_tokens` across
    /// ephemeral TTL windows. We keep the aggregate in `cache_write`
    /// (above) and the TTL breakdown here for the cost-state line.
    cache_creation_ephemeral_5m: u64 = 0,
    cache_creation_ephemeral_1h: u64 = 0,
    /// v1.32.0 — number of web-search server-tool requests billed for
    /// this turn (Anthropic web-search tool, OpenRouter, etc.). 0 when
    /// the provider did not report any.
    web_search_requests: u64 = 0,
    /// USD, per category. Optional; providers without pricing data omit.
    cost_input: ?f64 = null,
    cost_output: ?f64 = null,
    cost_cache_read: ?f64 = null,
    cost_cache_write: ?f64 = null,

    pub fn total(self: Usage) u64 {
        return self.input + self.output + self.cache_read + self.cache_write;
    }

    /// Sum of every USD cost field, or `null` when no cost data at all
    /// was reported for this turn. Used by the cost-state aggregator to
    /// detect `hasUnknownModelCost`.
    pub fn costTotal(self: Usage) ?f64 {
        var sum: f64 = 0;
        var any: bool = false;
        if (self.cost_input) |v| { sum += v; any = true; }
        if (self.cost_output) |v| { sum += v; any = true; }
        if (self.cost_cache_read) |v| { sum += v; any = true; }
        if (self.cost_cache_write) |v| { sum += v; any = true; }
        return if (any) sum else null;
    }

    /// True when every field is default — used by the transcript
    /// serializer to omit the `usage` object for messages that never
    /// touched a provider (user / tool_result rows, or assistant
    /// rows from a provider that reported no usage).
    pub fn isEmpty(self: Usage) bool {
        return self.input == 0 and self.output == 0 and
            self.cache_read == 0 and self.cache_write == 0 and
            self.thinking_tokens == 0 and
            self.cache_creation_ephemeral_5m == 0 and
            self.cache_creation_ephemeral_1h == 0 and
            self.web_search_requests == 0 and
            self.cost_input == null and self.cost_output == null and
            self.cost_cache_read == null and self.cost_cache_write == null;
    }

    // ─── JSON (de)serialization via std.json hooks ───────────────
    //
    // `Usage` opts into `std.json.Stringify` / `std.json.parseFromValue`
    // via the `jsonStringify` and `jsonParseFromValue` hooks. The wire
    // shape is the Claude-Code-compatible transcript.jsonl v5 format;
    // `json_meta` declares the rename / omit / compute / alias metadata
    // and the generic `json_meta` helpers do the (de)serialization.
    //
    // Provider-specific quirks, all expressed declaratively:
    //   1. `input` is emitted as `input_tokens` with the *uncached*
    //      portion (`input - cache_read - cache_write`) via `.compute`.
    //   2. Zero-valued integer fields are omitted via `.omit_default`.
    //   3. Cost fields serialize with a forced decimal point (`0.0` not
    //      `0`) via `.format = .float_force_decimal` so they round-trip
    //      as `.float`.
    //   4. Parse accepts both v5 (snake_case) and v4 (camelCase) key
    //      names via `.aliases`.
    // The only piece that stays manual is the parse-side cross-field
    // fix-up that restores the provider total into `input` from the
    // uncached `input_tokens` (it reads three fields at once).

    /// Uncached input tokens: the provider total minus cache hits,
    /// clamped >= 0. Claude Code reports only the uncached portion as
    /// `input_tokens`; franky's `Usage.input` includes cached tokens.
    /// Saturating add guards against u64 overflow. Referenced by the
    /// `.compute` hook in `json_meta`.
    pub fn uncachedInput(self: Usage) u64 {
        const cached = self.cache_read +| self.cache_write;
        return if (self.input > cached) self.input - cached else 0;
    }

    /// Wire metadata for `Usage`. Comptime-validated by the `json_meta`
    /// helpers: every renamed/aliased field exists, and the `.compute`
    /// method is present on the struct.
    pub const json_meta = .{
        .input = .{ .rename = "input_tokens", .compute = "uncachedInput", .omit_default = true, .aliases = &.{"input"}, .merge = .first },
        .output = .{ .rename = "output_tokens", .omit_default = true, .aliases = &.{"output"} },
        .cache_read = .{ .rename = "cache_read_input_tokens", .omit_default = true, .aliases = &.{"cacheRead"} },
        .cache_write = .{ .rename = "cache_creation_input_tokens", .omit_default = true, .aliases = &.{"cacheWrite"} },
        .thinking_tokens = .{ .omit_default = true, .aliases = &.{"thinkingTokens"} },
        .cache_creation_ephemeral_5m = .{ .rename = "cache_creation_5m_input_tokens", .omit_default = true, .aliases = &.{"cacheCreationEphemeral5m"} },
        .cache_creation_ephemeral_1h = .{ .rename = "cache_creation_1h_input_tokens", .omit_default = true, .aliases = &.{"cacheCreationEphemeral1h"} },
        .web_search_requests = .{ .omit_default = true, .aliases = &.{"webSearchRequests"} },
        .cost_input = .{ .format = .float_force_decimal, .aliases = &.{"costInput"} },
        .cost_output = .{ .format = .float_force_decimal, .aliases = &.{"costOutput"} },
        .cost_cache_read = .{ .format = .float_force_decimal, .aliases = &.{"costCacheRead"} },
        .cost_cache_write = .{ .format = .float_force_decimal, .aliases = &.{"costCacheWrite"} },
    };

    /// Serialize to a `std.json.Stringify` writer via the generic
    /// `json_meta.stringifyWithMeta` helper. The Claude-Code-compatible
    /// wire shape is fully declarative in `json_meta`: `input_tokens`
    /// carries the uncached portion (`.compute = "uncachedInput"`),
    /// zero-valued token fields are omitted (`.omit_default`), null cost
    /// fields are omitted, and present cost fields serialize with a forced
    /// decimal point (`.format = .float_force_decimal`).
    pub fn jsonStringify(self: Usage, jw: anytype) !void {
        try json_meta_mod.stringifyWithMeta(self, jw);
    }

    /// Deserialize from a `std.json.Value`. Accepts both v5
    /// (Claude-Code `snake_case`) and v4 (franky `camelCase`) key
    /// names — the dual names come from each field's `.aliases` in
    /// `json_meta`, parsed by the generic `json_meta.parseWithMeta`.
    /// Restores the provider-reported total into `input` from the
    /// uncached `input_tokens` by adding back cache hits.
    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        options: std.json.ParseOptions,
    ) !Usage {
        _ = options;
        if (source != .object) return error.UnexpectedToken;
        const o = source.object;

        // Parse every field via the generic helper (aliases handle the
        // v4/v5 dual names; `input` uses `.merge = .first` so a present
        // v4 `input` total outranks the v5 `input_tokens` alias).
        var u = try json_meta_mod.parseWithMeta(Usage, allocator, source);

        // Cross-field fix-up, kept manual: `input` is the one field whose
        // value depends on others. v4 `input` is already the total; v5
        // `input_tokens` is uncached, so add back the cache hits to
        // restore the provider-reported total.
        const input_from_v4 = if (o.get("input")) |v| jsonInt(v) else null;
        if (input_from_v4 == null) {
            u.input = u.input + u.cache_read + u.cache_write;
        }

        return u;
    }

    /// Extract a u64 from a `std.json.Value` (integer or float).
    fn jsonInt(v: std.json.Value) ?u64 {
        return switch (v) {
            .integer => |i| if (i >= 0) @intCast(i) else null,
            // Strict upper bound: `@floatFromInt(maxInt(u64))` rounds UP to
            // 2^64 (f64 can't represent 2^64-1 exactly), so `f <= that`
            // would admit f == 2^64 and `@intFromFloat` would panic. Use
            // strict `<` against the exact 2^64 boundary instead.
            .float => |f| if (f >= 0 and f < @as(f64, @floatFromInt(@as(u128, std.math.maxInt(u64)) + 1))) @intFromFloat(f) else null,
            .number_string => |s| std.fmt.parseInt(u64, s, 10) catch null,
            else => null,
        };
    }
};

/// v1.32.0 — Session-level cost-state accumulators for the
/// `cost-state` aggregate line in transcript.jsonl. These track the
/// values that CANNOT be derived from per-message `Usage` (durations
/// and edit line counts); the rest of the cost-state line
/// (`totalCostUSD`, `modelUsage`, `hasUnknownModelCost`) is computed
/// at write time from the transcript's assistant messages.
///
/// One instance per session. Updated by `agentLoop`/`runTurn`/
/// `runToolsParallel` via `Config.cost_state`. Thread-safe access is
/// NOT required — the agent loop runs single-threaded per prompt.
pub const CostState = struct {
    /// Wall-clock ms spent in provider API calls (all retries).
    total_api_duration_ms: u64 = 0,
    /// Wall-clock ms spent in provider API calls excluding retries.
    /// Without retry instrumentation this equals `total_api_duration_ms`;
    /// the loop updates it on the first attempt of each turn.
    total_api_duration_without_retries_ms: u64 = 0,
    /// Wall-clock ms spent executing tools (sum across all calls).
    total_tool_duration_ms: u64 = 0,
    /// Lines added by `write`/`edit` tools this session.
    total_lines_added: u64 = 0,
    /// Lines removed by `edit` tools this session.
    total_lines_removed: u64 = 0,
    /// Unix-ms timestamp of the session's first turn (set on first
    /// `runTurn`). Used for `totalDuration` = last_write - startTime.
    start_time_ms: i64 = 0,
    /// True once `start_time_ms` has been latched.
    started: bool = false,

    // ─── JSON (de)serialization via std.json hooks ───────────────
    //
    // `CostState` opts into `std.json.Stringify` / `std.json.parseFromValue`
    // via the `jsonStringify` and `jsonParseFromValue` hooks. The
    // `json_meta` map below renames Zig snake_case fields to the
    // Claude-Code-compatible camelCase wire keys used in the
    // transcript.jsonl `cost-state` aggregate line. `started` is an
    // internal latch — it is skipped on the wire (its truth is inferred
    // from the presence of `startTime` on parse).

    pub const json_meta = .{
        .total_api_duration_ms = .{ .rename = "totalAPIDuration" },
        .total_api_duration_without_retries_ms = .{ .rename = "totalAPIDurationWithoutRetries" },
        .total_tool_duration_ms = .{ .rename = "totalToolDuration" },
        .total_lines_added = .{ .rename = "totalLinesAdded" },
        .total_lines_removed = .{ .rename = "totalLinesRemoved" },
        .start_time_ms = .{ .rename = "startTime" },
        .started = .{ .skip = true },
    };

    /// Serialize the stored fields to a `std.json.Stringify` writer.
    /// Emits the six Claude-Code-compatible camelCase fields; `started`
    /// is skipped (internal latch). The caller (`renderCostStateLine`)
    /// emits the computed wrapper fields (`type`, `sessionId`,
    /// `totalCostUSD`, `totalDuration`, `modelUsage`,
    /// `hasUnknownModelCost`) around this object's fields — see
    /// `persistence.renderCostStateLine` for the full wire shape.
    pub fn jsonStringify(self: CostState, jw: anytype) !void {
        try json_meta_mod.stringifyWithMeta(self, jw);
    }

    /// Parse a `std.json.Value` (object) into a `CostState` via the
    /// generic `json_meta.parseWithMeta` helper. `started` is inferred
    /// from the presence of a `startTime` key in the source object
    /// (the field is skipped on the wire — see `json_meta`).
    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        options: std.json.ParseOptions,
    ) !CostState {
        _ = options;
        var cs = try json_meta_mod.parseWithMeta(CostState, allocator, source);
        // `started` is true when the `startTime` key was present AND held an
        // integer, matching the old manual parser's behavior
        // (`if (o.get("startTime")) |v| if (v == .integer) { started = true }`).
        if (source == .object) {
            if (source.object.get("startTime")) |v| {
                if (v == .integer) cs.started = true;
            }
        }
        return cs;
    }
};

pub const StopReason = enum {
    stop,
    length,
    tool_use,
    /// Content-policy refusal.
    refusal,
    err,
    aborted,

    pub fn fromString(s: []const u8) ?StopReason {
        if (std.mem.eql(u8, s, "stop")) return .stop;
        if (std.mem.eql(u8, s, "length")) return .length;
        if (std.mem.eql(u8, s, "tool_use")) return .tool_use;
        if (std.mem.eql(u8, s, "toolUse")) return .tool_use;
        if (std.mem.eql(u8, s, "refusal")) return .refusal;
        if (std.mem.eql(u8, s, "error")) return .err;
        if (std.mem.eql(u8, s, "aborted")) return .aborted;
        // Claude-Code-compatible aliases (transcript.jsonl v5).
        if (std.mem.eql(u8, s, "end_turn")) return .stop;
        if (std.mem.eql(u8, s, "max_tokens")) return .length;
        return null;
    }

    pub fn toString(self: StopReason) []const u8 {
        return switch (self) {
            .stop => "stop",
            .length => "length",
            .tool_use => "toolUse",
            .refusal => "refusal",
            .err => "error",
            .aborted => "aborted",
        };
    }

    /// Claude-Code-compatible `stop_reason` string for the transcript.jsonl
    /// v5 format. Claude Code uses `end_turn` / `tool_use` / `max_tokens`
    /// rather than franky's internal `stop` / `toolUse` / `length`.
    /// `toString()` is unchanged because stream.zig snapshots and the
    /// proxy UI use the internal names in their own (separate) formats.
    pub fn toClaudeCodeString(self: StopReason) []const u8 {
        return switch (self) {
            .stop => "end_turn",
            .length => "max_tokens",
            .tool_use => "tool_use",
            .refusal => "refusal",
            .err => "error",
            .aborted => "aborted",
        };
    }
};

pub const Role = enum {
    user,
    assistant,
    tool_result,
    /// Custom role (e.g., compaction summary). The string is held in
    /// `Message.custom_role`.
    custom,

    pub fn toString(self: Role) []const u8 {
        return switch (self) {
            .user => "user",
            .assistant => "assistant",
            .tool_result => "toolResult",
            .custom => "custom",
        };
    }
};

/// v1.29.0 — assistant-message diagnostics. Optional struct attached
/// to assistant messages so an after-the-fact reader can answer
/// "where did this content come from?" without re-running the
/// session. Only populated by the agent layer (the Reducer fills it
/// from stream events); only serialized when at least one field is
/// non-default (`isEmpty()` returns false). All string fields are
/// owned by the message's allocator.
pub const Diagnostics = struct {
    /// Filename stem of the matching `--http-trace-dir` file, e.g.
    /// `1777498943846-0001`. Pairs the saved Message with the raw
    /// HTTP request/response bytes. `null` when tracing was off.
    trace_id: ?[]const u8 = null,
    /// Raw provider-side `finishReason` / `stop_reason` string
    /// (Gemini's `STOP`, OpenAI's `tool_calls`, Anthropic's
    /// `end_turn`, etc.). Preserved verbatim because the
    /// canonicalized `Message.stop_reason` discards information
    /// useful when chasing provider-specific anomalies.
    finish_reason_raw: ?[]const u8 = null,
    /// Number of SSE events whose `candidates[…].content.parts`
    /// (Gemini-shaped) or equivalent contained at least one part.
    /// `0` plus a clean stop_reason is the empty-response shape.
    parts_seen: u32 = 0,
    candidates_tokens: ?u64 = null,
    thoughts_tokens: ?u64 = null,
    /// How many of each delta-class event the Reducer applied.
    /// Cheap counters that survive even when the buffers fail to
    /// produce content blocks (e.g. every text_delta was empty).
    text_event_count: u32 = 0,
    thinking_event_count: u32 = 0,
    tool_call_event_count: u32 = 0,
    /// Set by `Reducer.finalize` when the message ended cleanly
    /// (stop_reason ≠ err, no error_message) but produced ZERO
    /// content blocks. Cheap "this turn was anomalous" flag for
    /// downstream filters / UIs.
    was_degenerate: bool = false,

    pub fn isEmpty(self: Diagnostics) bool {
        return self.trace_id == null and self.finish_reason_raw == null and
            self.parts_seen == 0 and self.candidates_tokens == null and
            self.thoughts_tokens == null and self.text_event_count == 0 and
            self.thinking_event_count == 0 and self.tool_call_event_count == 0 and
            !self.was_degenerate;
    }

    pub fn deinit(self: Diagnostics, allocator: std.mem.Allocator) void {
        if (self.trace_id) |s| allocator.free(s);
        if (self.finish_reason_raw) |s| allocator.free(s);
    }

    pub fn dupe(self: Diagnostics, allocator: std.mem.Allocator) !Diagnostics {
        const trace_id = if (self.trace_id) |s| try allocator.dupe(u8, s) else null;
        errdefer if (trace_id) |s| allocator.free(s);
        const frr = if (self.finish_reason_raw) |s| try allocator.dupe(u8, s) else null;
        return .{
            .trace_id = trace_id,
            .finish_reason_raw = frr,
            .parts_seen = self.parts_seen,
            .candidates_tokens = self.candidates_tokens,
            .thoughts_tokens = self.thoughts_tokens,
            .text_event_count = self.text_event_count,
            .thinking_event_count = self.thinking_event_count,
            .tool_call_event_count = self.tool_call_event_count,
            .was_degenerate = self.was_degenerate,
        };
    }

    // ─── JSON (de)serialization via std.json hooks ───────────────
    //
    // Like `Usage`, `Diagnostics` opts into `std.json` via hooks.
    // The wire format uses camelCase keys and omits zero/null/false
    // fields (matching the transcript.jsonl v5 shape).

    pub const json_meta = .{
        .trace_id = .{ .rename = "traceId" },
        .finish_reason_raw = .{ .rename = "finishReasonRaw" },
        .parts_seen = .{ .rename = "partsSeen", .omit_default = true },
        .candidates_tokens = .{ .rename = "candidatesTokens" },
        .thoughts_tokens = .{ .rename = "thoughtsTokens" },
        .text_event_count = .{ .rename = "textEvents", .omit_default = true },
        .thinking_event_count = .{ .rename = "thinkingEvents", .omit_default = true },
        .tool_call_event_count = .{ .rename = "toolCallEvents", .omit_default = true },
        .was_degenerate = .{ .rename = "wasDegenerate", .omit_default = true },
    };

    /// Serialize to a `std.json.Stringify` writer via the generic
    /// `json_meta.stringifyWithMeta` helper. camelCase renames come from
    /// `json_meta`; zero-valued integers, `false` bools, and null optionals
    /// are omitted via `omit_default` + `emit_null_optional_fields`.
    pub fn jsonStringify(self: Diagnostics, jw: anytype) !void {
        try json_meta_mod.stringifyWithMeta(self, jw);
    }

    /// Parse a `std.json.Value` (object) into a `Diagnostics` via the
    /// generic `json_meta.parseWithMeta` helper. String fields are
    /// duped into `allocator` by `parseFromValueLeaky`.
    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        options: std.json.ParseOptions,
    ) !Diagnostics {
        _ = options;
        return json_meta_mod.parseWithMeta(Diagnostics, allocator, source);
    }
};

/// Message — tagged by role. Carries the content blocks plus role-specific
/// metadata. Callers use `deinit(allocator)` when done.
pub const Message = struct {
    role: Role,
    content: []ContentBlock,
    /// Unix millis.
    timestamp: i64,
    // assistant-only
    stop_reason: ?StopReason = null,
    usage: ?Usage = null,
    error_message: ?[]const u8 = null,
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    api: ?[]const u8 = null,
    /// v1.29.0 — optional, see `Diagnostics`. Always `null` for
    /// non-assistant roles.
    diagnostics: ?Diagnostics = null,
    // tool_result-only
    tool_call_id: ?[]const u8 = null,
    is_error: bool = false,
    // custom-role-only
    custom_role: ?[]const u8 = null,
    /// Free-form extension metadata stored as JSON string (for persistence).
    meta_json: ?[]const u8 = null,

    pub fn deinit(self: *Message, allocator: std.mem.Allocator) void {
        for (self.content) |block| block.deinit(allocator);
        allocator.free(self.content);
        if (self.error_message) |s| allocator.free(s);
        if (self.provider) |s| allocator.free(s);
        if (self.model) |s| allocator.free(s);
        if (self.api) |s| allocator.free(s);
        if (self.tool_call_id) |s| allocator.free(s);
        if (self.custom_role) |s| allocator.free(s);
        if (self.meta_json) |s| allocator.free(s);
        if (self.diagnostics) |d| d.deinit(allocator);
    }
};

/// Tool schema (JSON Schema, draft-07 subset) + optional strict flag.
pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    /// JSON Schema for the parameters object. Stored as a JSON string so it
    /// can be round-tripped through JSON without a schema AST.
    parameters_json: []const u8,
    strict: bool = false,

    pub fn deinit(self: Tool, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        allocator.free(self.parameters_json);
    }
};

/// Context — the canonical bundle sent to an LLM. Plain data.
pub const Context = struct {
    system_prompt: []const u8,
    messages: []Message,
    tools: []Tool,

    pub fn deinit(self: *Context, allocator: std.mem.Allocator) void {
        allocator.free(self.system_prompt);
        for (self.messages) |*m| m.deinit(allocator);
        allocator.free(self.messages);
        for (self.tools) |t| t.deinit(allocator);
        allocator.free(self.tools);
    }
};

pub const Capabilities = struct {
    vision: bool = false,
    tool_use: bool = true,
    reasoning: bool = false,
    cache: bool = false,
    streaming: bool = true,
};

pub const ModelCost = struct {
    input_per_1m: f64 = 0,
    output_per_1m: f64 = 0,
    cache_read_per_1m: f64 = 0,
    cache_write_per_1m: f64 = 0,
};

/// Model<Api> per §3.2 — generic-over-api-tag is collapsed into a plain
/// struct here; the API tag is a runtime string used for registry lookup.
pub const Model = struct {
    id: []const u8,
    provider: []const u8,
    /// API tag used for registry lookup — e.g., "anthropic-messages",
    /// "openai-responses", "faux".
    api: []const u8,
    display_name: []const u8 = "",
    context_window: u32 = 128_000,
    max_output: u32 = 4096,
    cost: ModelCost = .{},
    capabilities: Capabilities = .{},
    knowledge_cutoff: ?[]const u8 = null,
};

/// Reasoning/thinking intensity — unified across providers per §B.
pub const ThinkingLevel = enum {
    none,
    off,
    minimal,
    low,
    medium,
    high,
    xhigh,

    pub fn fromString(s: []const u8) ?ThinkingLevel {
        if (std.mem.eql(u8, s, "none")) return .none;
        if (std.mem.eql(u8, s, "off")) return .off;
        if (std.mem.eql(u8, s, "minimal")) return .minimal;
        if (std.mem.eql(u8, s, "low")) return .low;
        if (std.mem.eql(u8, s, "medium")) return .medium;
        if (std.mem.eql(u8, s, "high")) return .high;
        if (std.mem.eql(u8, s, "xhigh")) return .xhigh;
        return null;
    }

    pub fn toString(self: ThinkingLevel) []const u8 {
        return @tagName(self);
    }

    /// §B — Anthropic budget_tokens.
    pub fn anthropicBudget(self: ThinkingLevel) ?u32 {
        return switch (self) {
            .none => null,
            .off => null,
            .minimal => 1024,
            .low => 4096,
            .medium => 8192,
            .high => 16384,
            .xhigh => 32768,
        };
    }

    /// §B — OpenAI Responses `effort`.
    pub fn openaiResponsesEffort(self: ThinkingLevel) ?[]const u8 {
        return switch (self) {
            .off => null,
            .none => "none",
            .minimal => "minimal",
            .low => "low",
            .medium => "medium",
            .high, .xhigh => "high",
        };
    }

    /// §B — Google `thinkingBudget`. `off` returns `null` so the
    /// provider OMITS the field entirely (v1.23.2). Letting
    /// Google's default apply works for both: models that
    /// support disabling (Flash) ignore the missing field, and
    /// models that REQUIRE thinking (Pro) get their default
    /// budget instead of being told `0` and rejecting the
    /// request with `Budget 0 is invalid. This model only
    /// works in thinking mode.`
    pub fn googleBudget(self: ThinkingLevel) ?u32 {
        return switch (self) {
            .off => null,
            .none => null,
            .minimal => 512,
            .low => 2048,
            .medium => 8192,
            .high => 16384,
            .xhigh => 24576,
        };
    }
};

// ─── tests ────────────────────────────────────────────────────────────

test "TextContent.dupe owns memory" {
    const gpa = @import("../global_allocator.zig").gpa;
    const src: TextContent = .{ .text = "hello", .text_signature = "sig" };
    const dst = try src.dupe(gpa);
    defer dst.deinit(gpa);
    try std.testing.expectEqualStrings("hello", dst.text);
    try std.testing.expectEqualStrings("sig", dst.text_signature.?);
}

test "ContentBlock.dupe round-trips each variant" {
    const gpa = @import("../global_allocator.zig").gpa;
    {
        var cb: ContentBlock = .{ .text = .{ .text = try gpa.dupe(u8, "t") } };
        defer cb.deinit(gpa);
        const copy = try cb.dupe(gpa);
        defer copy.deinit(gpa);
        try std.testing.expectEqualStrings("t", copy.text.text);
    }
    {
        var cb: ContentBlock = .{ .tool_call = .{
            .id = try gpa.dupe(u8, "toolu_1"),
            .name = try gpa.dupe(u8, "read"),
            .arguments_json = try gpa.dupe(u8, "{\"path\":\"/tmp\"}"),
        } };
        defer cb.deinit(gpa);
        const copy = try cb.dupe(gpa);
        defer copy.deinit(gpa);
        try std.testing.expectEqualStrings("read", copy.tool_call.name);
    }
}

test "ThinkingLevel provider mappings" {
    try std.testing.expectEqual(@as(?u32, null), ThinkingLevel.off.anthropicBudget());
    try std.testing.expectEqual(@as(?u32, 8192), ThinkingLevel.medium.anthropicBudget());
    try std.testing.expectEqual(@as(?u32, 32768), ThinkingLevel.xhigh.anthropicBudget());
    try std.testing.expectEqualStrings("high", ThinkingLevel.xhigh.openaiResponsesEffort().?);
    // v1.23.2 — `off` now returns null so google_gemini omits
    // the `thinkingBudget` field entirely (gemini-2.5-pro
    // rejects `0` as invalid; letting Google's default apply
    // works for Pro + Flash both).
    try std.testing.expectEqual(@as(?u32, null), ThinkingLevel.off.googleBudget());
    try std.testing.expectEqual(@as(?u32, 24576), ThinkingLevel.xhigh.googleBudget());
}

test "StopReason round-trips" {
    try std.testing.expectEqual(StopReason.stop, StopReason.fromString("stop").?);
    try std.testing.expectEqual(StopReason.tool_use, StopReason.fromString("tool_use").?);
    try std.testing.expectEqual(StopReason.tool_use, StopReason.fromString("toolUse").?);
    try std.testing.expectEqualStrings("toolUse", StopReason.tool_use.toString());
}

// ─── Usage JSON (de)serialization tests ──────────────────────────────

test "Usage.jsonStringify emits Claude-Code-compatible keys with uncached input" {
    const u: Usage = .{
        .input = 1000, // total (incl. cached)
        .output = 500,
        .cache_read = 200,
        .cache_write = 100,
        .thinking_tokens = 50,
        .cost_input = 0.01,
        .cost_output = 0.02,
    };
    const json_str = try std.json.Stringify.valueAlloc(std.testing.allocator, u, .{
        .emit_null_optional_fields = false,
    });
    defer std.testing.allocator.free(json_str);

    // uncached_input = 1000 - 200 - 100 = 700
    // zero fields (web_search_requests, ephemeral) are omitted
    // null cost fields (cost_cache_read, cost_cache_write) are omitted
    try std.testing.expectEqualStrings(
        "{\"input_tokens\":700,\"output_tokens\":500," ++
            "\"cache_read_input_tokens\":200," ++
            "\"cache_creation_input_tokens\":100," ++
            "\"thinking_tokens\":50," ++
            "\"cost_input\":0.01,\"cost_output\":0.02}",
        json_str,
    );
}

test "Usage.jsonStringify omits all zero fields" {
    const u: Usage = .{
        .input = 100,
        .output = 0,
        .cache_read = 0,
        .cache_write = 0,
    };
    const json_str = try std.json.Stringify.valueAlloc(std.testing.allocator, u, .{
        .emit_null_optional_fields = false,
    });
    defer std.testing.allocator.free(json_str);

    // Only input_tokens (uncached = 100) is non-zero.
    try std.testing.expectEqualStrings("{\"input_tokens\":100}", json_str);
}

test "Usage round-trip: stringify then parseFromValue restores original" {
    const original: Usage = .{
        .input = 1000,
        .output = 500,
        .cache_read = 200,
        .cache_write = 100,
        .thinking_tokens = 50,
        .cache_creation_ephemeral_5m = 30,
        .cache_creation_ephemeral_1h = 20,
        .web_search_requests = 5,
        .cost_input = 0.01,
        .cost_output = 0.02,
        .cost_cache_read = 0.003,
        .cost_cache_write = 0.004,
    };

    // Serialize
    const json_str = try std.json.Stringify.valueAlloc(std.testing.allocator, original, .{
        .emit_null_optional_fields = false,
    });
    defer std.testing.allocator.free(json_str);

    // Parse back via the jsonParseFromValue hook.
    var value_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json_str, .{});
    defer value_parsed.deinit();

    var parsed = try std.json.parseFromValue(Usage, std.testing.allocator, value_parsed.value, .{});
    defer parsed.deinit();
    const u = parsed.value;

    // input is stored as total; serialization emits uncached (700),
    // parse restores total (700 + 200 + 100 = 1000).
    try std.testing.expectEqual(@as(u64, 1000), u.input);
    try std.testing.expectEqual(@as(u64, 500), u.output);
    try std.testing.expectEqual(@as(u64, 200), u.cache_read);
    try std.testing.expectEqual(@as(u64, 100), u.cache_write);
    try std.testing.expectEqual(@as(u64, 50), u.thinking_tokens);
    try std.testing.expectEqual(@as(u64, 30), u.cache_creation_ephemeral_5m);
    try std.testing.expectEqual(@as(u64, 20), u.cache_creation_ephemeral_1h);
    try std.testing.expectEqual(@as(u64, 5), u.web_search_requests);
    try std.testing.expectEqual(@as(?f64, 0.01), u.cost_input);
    try std.testing.expectEqual(@as(?f64, 0.02), u.cost_output);
    try std.testing.expectEqual(@as(?f64, 0.003), u.cost_cache_read);
    try std.testing.expectEqual(@as(?f64, 0.004), u.cost_cache_write);
}

test "Usage.jsonParseFromValue accepts v5 snake_case keys" {
    const json_str =
        "{\"input_tokens\":700,\"output_tokens\":500," ++
        "\"cache_read_input_tokens\":200," ++
        "\"cache_creation_input_tokens\":100," ++
        "\"thinking_tokens\":50," ++
        "\"web_search_requests\":5," ++
        "\"cost_input\":0.01,\"cost_output\":0.02}";

    var value_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json_str, .{});
    defer value_parsed.deinit();

    var parsed = try std.json.parseFromValue(Usage, std.testing.allocator, value_parsed.value, .{});
    defer parsed.deinit();
    const u = parsed.value;

    // input is restored as total: uncached(700) + cache_read(200) + cache_write(100) = 1000
    try std.testing.expectEqual(@as(u64, 1000), u.input);
    try std.testing.expectEqual(@as(u64, 500), u.output);
    try std.testing.expectEqual(@as(u64, 200), u.cache_read);
    try std.testing.expectEqual(@as(u64, 100), u.cache_write);
    try std.testing.expectEqual(@as(u64, 50), u.thinking_tokens);
    try std.testing.expectEqual(@as(u64, 5), u.web_search_requests);
    try std.testing.expectEqual(@as(?f64, 0.01), u.cost_input);
    try std.testing.expectEqual(@as(?f64, 0.02), u.cost_output);
}

test "Usage.jsonParseFromValue accepts v4 camelCase keys" {
    const json_str =
        "{\"input\":1000,\"output\":500," ++
        "\"cacheRead\":200,\"cacheWrite\":100," ++
        "\"thinkingTokens\":50," ++
        "\"webSearchRequests\":5," ++
        "\"costInput\":0.01,\"costOutput\":0.02}";

    var value_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json_str, .{});
    defer value_parsed.deinit();

    var parsed = try std.json.parseFromValue(Usage, std.testing.allocator, value_parsed.value, .{});
    defer parsed.deinit();
    const u = parsed.value;

    // v4 `input` is the total, so no fix-up needed.
    try std.testing.expectEqual(@as(u64, 1000), u.input);
    try std.testing.expectEqual(@as(u64, 500), u.output);
    try std.testing.expectEqual(@as(u64, 200), u.cache_read);
    try std.testing.expectEqual(@as(u64, 100), u.cache_write);
    try std.testing.expectEqual(@as(u64, 50), u.thinking_tokens);
    try std.testing.expectEqual(@as(u64, 5), u.web_search_requests);
    try std.testing.expectEqual(@as(?f64, 0.01), u.cost_input);
    try std.testing.expectEqual(@as(?f64, 0.02), u.cost_output);
}

test "Usage.jsonParseFromValue handles empty object" {
    var value_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{}", .{});
    defer value_parsed.deinit();

    var parsed = try std.json.parseFromValue(Usage, std.testing.allocator, value_parsed.value, .{});
    defer parsed.deinit();
    const u = parsed.value;

    try std.testing.expect(u.isEmpty());
}

// ─── Diagnostics JSON (de)serialization tests ─────────────────────────

test "Diagnostics.jsonStringify emits camelCase keys, omits defaults" {
    const d: Diagnostics = .{
        .trace_id = "trace_123",
        .finish_reason_raw = "end_turn",
        .parts_seen = 5,
        .candidates_tokens = 100,
        .was_degenerate = true,
    };
    const json_str = try std.json.Stringify.valueAlloc(std.testing.allocator, d, .{
        .emit_null_optional_fields = false,
    });
    defer std.testing.allocator.free(json_str);

    // Zero fields (text_event_count, etc.) and null optionals
    // (thoughts_tokens) are omitted.
    try std.testing.expectEqualStrings(
        "{\"traceId\":\"trace_123\",\"finishReasonRaw\":\"end_turn\"," ++
            "\"partsSeen\":5,\"candidatesTokens\":100,\"wasDegenerate\":true}",
        json_str,
    );
}

test "Diagnostics round-trip: stringify then parseFromValue restores original" {
    const original: Diagnostics = .{
        .trace_id = "trace_456",
        .finish_reason_raw = "tool_calls",
        .parts_seen = 3,
        .candidates_tokens = 200,
        .thoughts_tokens = 50,
        .text_event_count = 10,
        .thinking_event_count = 5,
        .tool_call_event_count = 2,
        .was_degenerate = false,
    };

    // Serialize
    const json_str = try std.json.Stringify.valueAlloc(std.testing.allocator, original, .{
        .emit_null_optional_fields = false,
    });
    defer std.testing.allocator.free(json_str);

    // Parse back via the jsonParseFromValue hook.
    var value_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json_str, .{});
    defer value_parsed.deinit();

    // Use parseFromValueLeaky with testing.allocator so we can free strings.
    const d = try std.json.parseFromValueLeaky(Diagnostics, std.testing.allocator, value_parsed.value, .{});
    defer {
        if (d.trace_id) |s| std.testing.allocator.free(s);
        if (d.finish_reason_raw) |s| std.testing.allocator.free(s);
    }

    try std.testing.expectEqualStrings("trace_456", d.trace_id.?);
    try std.testing.expectEqualStrings("tool_calls", d.finish_reason_raw.?);
    try std.testing.expectEqual(@as(u32, 3), d.parts_seen);
    try std.testing.expectEqual(@as(?u64, 200), d.candidates_tokens);
    try std.testing.expectEqual(@as(?u64, 50), d.thoughts_tokens);
    try std.testing.expectEqual(@as(u32, 10), d.text_event_count);
    try std.testing.expectEqual(@as(u32, 5), d.thinking_event_count);
    try std.testing.expectEqual(@as(u32, 2), d.tool_call_event_count);
    try std.testing.expectEqual(false, d.was_degenerate);
}

test "Diagnostics.jsonParseFromValue handles empty object" {
    var value_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{}", .{});
    defer value_parsed.deinit();

    const d = try std.json.parseFromValueLeaky(Diagnostics, std.testing.allocator, value_parsed.value, .{});
    try std.testing.expect(d.isEmpty());
}

// ─── CostState json_meta hook tests ──────────────────────────────────

test "CostState.jsonStringify emits camelCase wire keys" {
    const cs = CostState{
        .total_api_duration_ms = 1234,
        .total_api_duration_without_retries_ms = 1000,
        .total_tool_duration_ms = 5678,
        .total_lines_added = 42,
        .total_lines_removed = 10,
        .start_time_ms = 1700000000000,
        .started = true,
    };
    const json_str = try std.json.Stringify.valueAlloc(std.testing.allocator, cs, .{
        .emit_null_optional_fields = false,
    });
    defer std.testing.allocator.free(json_str);

    // `started` is skipped; the six stored fields use camelCase keys.
    try std.testing.expectEqualStrings(
        "{\"totalAPIDuration\":1234,\"totalAPIDurationWithoutRetries\":1000,\"totalToolDuration\":5678,\"totalLinesAdded\":42,\"totalLinesRemoved\":10,\"startTime\":1700000000000}",
        json_str,
    );
}

test "CostState round-trip: stringify then parseFromValue restores original" {
    const cs = CostState{
        .total_api_duration_ms = 9999,
        .total_api_duration_without_retries_ms = 8888,
        .total_tool_duration_ms = 7777,
        .total_lines_added = 100,
        .total_lines_removed = 50,
        .start_time_ms = -12345, // negative start time (pre-epoch edge)
        .started = true,
    };
    const json_str = try std.json.Stringify.valueAlloc(std.testing.allocator, cs, .{
        .emit_null_optional_fields = false,
    });
    defer std.testing.allocator.free(json_str);

    var value_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json_str, .{});
    defer value_parsed.deinit();

    const restored = try std.json.parseFromValueLeaky(CostState, std.testing.allocator, value_parsed.value, .{});
    try std.testing.expectEqual(cs.total_api_duration_ms, restored.total_api_duration_ms);
    try std.testing.expectEqual(cs.total_api_duration_without_retries_ms, restored.total_api_duration_without_retries_ms);
    try std.testing.expectEqual(cs.total_tool_duration_ms, restored.total_tool_duration_ms);
    try std.testing.expectEqual(cs.total_lines_added, restored.total_lines_added);
    try std.testing.expectEqual(cs.total_lines_removed, restored.total_lines_removed);
    try std.testing.expectEqual(cs.start_time_ms, restored.start_time_ms);
    try std.testing.expect(restored.started); // inferred from startTime presence
}

test "CostState.jsonParseFromValue handles empty object" {
    var value_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{}", .{});
    defer value_parsed.deinit();

    const cs = try std.json.parseFromValueLeaky(CostState, std.testing.allocator, value_parsed.value, .{});
    try std.testing.expectEqual(@as(u64, 0), cs.total_api_duration_ms);
    try std.testing.expectEqual(@as(u64, 0), cs.total_tool_duration_ms);
    try std.testing.expect(!cs.started);
}

test "CostState.jsonParseFromValue ignores unknown keys (cost-state wrapper fields)" {
    // The cost-state line wrapper carries computed fields the hook
    // must ignore: totalCostUSD, totalDuration, modelUsage,
    // hasUnknownModelCost, type, sessionId.
    const json_str =
        "{\"type\":\"cost-state\",\"sessionId\":\"abc\",\"totalCostUSD\":0.0,\"totalAPIDuration\":100,\"totalDuration\":200,\"modelUsage\":{},\"hasUnknownModelCost\":false,\"startTime\":1700000000000}";
    var value_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json_str, .{});
    defer value_parsed.deinit();

    const cs = try std.json.parseFromValueLeaky(CostState, std.testing.allocator, value_parsed.value, .{});
    try std.testing.expectEqual(@as(u64, 100), cs.total_api_duration_ms);
    try std.testing.expectEqual(@as(i64, 1700000000000), cs.start_time_ms);
    try std.testing.expect(cs.started);
}
