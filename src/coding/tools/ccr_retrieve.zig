//! ccr_retrieve tool.
//!
//! Retrieves original content from the CCR store by hash key.
//! This makes compression reversible — the LLM can drill down into
//! compressed content when it needs details.
//!
//! The tool is registered alongside the compression config and injected
//! with a reference to the session's CCR store via the `ctx` field.

const std = @import("std");
const ct = @import("../types.zig");
const at = ct.agent.types;
const ai = ct.ai;
const common = @import("common.zig");
const ccr_store = @import("../session/ccr_store.zig");

pub const parameters_json: []const u8 =
    \\{
    \\  "type": "object",
    \\  "required": ["key"],
    \\  "properties": {
    \\    "key": {
    \\      "type": "string",
    \\      "description": "The CCR hash key from a <<<ccr:<hash> N_rows_offloaded>>> marker"
    \\    }
    \\  },
    \\  "additionalProperties": false
    \\}
;

/// Create a ccr_retrieve tool with a reference to the session's CCR store.
pub fn tool(store: *ccr_store.CcrSessionStore) at.AgentTool {
    return .{
        .name = "ccr_retrieve",
        .description = "Retrieve original content that was compressed during tool execution. " ++
            "Pass the hash key from a `<<<ccr:<hash> N_rows_offloaded>>>` marker.",
        .parameters_json = parameters_json,
        .execution_mode = .parallel,
        .ctx = @ptrCast(store),
        .execute = execute,
    };
}

/// Create a ccr_retrieve tool with a nullable context (set later by mode driver).
pub fn toolWithCtx(ctx: ?*anyopaque) at.AgentTool {
    return .{
        .name = "ccr_retrieve",
        .description = "Retrieve original content that was compressed during tool execution. " ++
            "Pass the hash key from a `<<<ccr:<hash> N_rows_offloaded>>>` marker.",
        .parameters_json = parameters_json,
        .execution_mode = .parallel,
        .skip_compression = true,
        .ctx = ctx,
        .execute = execute,
    };
}

fn execute(
    self: *const at.AgentTool,
    allocator: std.mem.Allocator,
    _: std.Io,
    _: []const u8,
    args_json: []const u8,
    _: *ai.stream.Cancel,
    _: at.OnUpdate,
) anyerror!at.ToolResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const json_to_parse = common.repairConcatJson(a, args_json) orelse args_json;
    const parsed = std.json.parseFromSlice(std.json.Value, a, json_to_parse, .{}) catch {
        return common.toolError(allocator, "invalid_args", "failed to parse arguments JSON");
    };
    const root = parsed.value;

    const key_v = root.object.get("key") orelse
        return common.toolError(allocator, "invalid_args", "missing key");
    if (key_v != .string) return common.toolError(allocator, "invalid_args", "key must be a string");
    const key = key_v.string;

    const store: *ccr_store.CcrSessionStore = @ptrCast(@alignCast(self.ctx orelse
        return common.toolError(allocator, "no_store", "CCR store not available")));

    const original = store.retrieve(key) orelse
        return common.toolError(allocator, "not_found", "no content found for this CCR key (may have been evicted)");

    const content = try allocator.alloc(ai.types.ContentBlock, 1);
    content[0] = .{ .text = .{ .text = try allocator.dupe(u8, original) } };

    return .{ .content = content };
}
