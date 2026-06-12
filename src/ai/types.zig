//! Core data types — §3.2 of the spec.
//!
//! All plain structs/unions; every value is serializable to JSON. Messages
//! and content blocks own the memory behind their string slices; callers
//! call `deinit(allocator)` to release.

const std = @import("std");

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
    /// USD, per category. Optional; providers without pricing data omit.
    cost_input: ?f64 = null,
    cost_output: ?f64 = null,
    cost_cache_read: ?f64 = null,
    cost_cache_write: ?f64 = null,

    pub fn total(self: Usage) u64 {
        return self.input + self.output + self.cache_read + self.cache_write;
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

    /// v2.31 — deep-copy this message onto `allocator`. The
    /// returned copy owns all its slices independently of the original.
    pub fn dupe(self: Message, allocator: std.mem.Allocator) !Message {
        const content = try allocator.alloc(ContentBlock, self.content.len);
        errdefer allocator.free(content);
        for (self.content, 0..) |cb, i| {
            content[i] = try cb.dupe(allocator);
        }
        var out: Message = .{
            .role = self.role,
            .content = content,
            .timestamp = self.timestamp,
            .is_error = self.is_error,
        };
        errdefer out.deinit(allocator);
        if (self.stop_reason) |v| out.stop_reason = v;
        if (self.usage) |v| out.usage = v;
        if (self.error_message) |s| out.error_message = try allocator.dupe(u8, s);
        if (self.provider) |s| out.provider = try allocator.dupe(u8, s);
        if (self.model) |s| out.model = try allocator.dupe(u8, s);
        if (self.api) |s| out.api = try allocator.dupe(u8, s);
        if (self.diagnostics) |d| out.diagnostics = try d.dupe(allocator);
        if (self.tool_call_id) |s| out.tool_call_id = try allocator.dupe(u8, s);
        if (self.custom_role) |s| out.custom_role = try allocator.dupe(u8, s);
        if (self.meta_json) |s| out.meta_json = try allocator.dupe(u8, s);
        return out;
    }

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
    off,
    minimal,
    low,
    medium,
    high,
    xhigh,

    pub fn fromString(s: []const u8) ?ThinkingLevel {
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
