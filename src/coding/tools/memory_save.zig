//! memory_save tool — lets the agent persist a memory to L1.
//!
//! The agent calls this when it decides something is worth remembering.
//! It writes directly to L1 via MemoryContext.save(). No extraction LLM —
//! the agent IS the extractor.
//!
//! Schema: `{content, type, priority?, scene_name?}`.

const std = @import("std");
const ct = @import("../types.zig");
const at = ct.agent.types;
const ai = ct.ai;
const common = @import("common.zig");
const memory_mod = @import("../memory.zig");
const agent_memory = @import("agent_memory");

pub const parameters_json: []const u8 =
    \\{
    \\  "type": "object",
    \\  "required": ["content", "type"],
    \\  "properties": {
    \\    "content": {
    \\      "type": "string",
    \\      "description": "The memory text. Must be self-contained — readable without conversation context. The subject must be 'User' or 'AI'."
    \\    },
    \\    "type": {
    \\      "type": "string",
    \\      "enum": ["persona", "episodic", "instruction"],
    \\      "description": "persona=user preferences/traits, episodic=events/decisions, instruction=rules/constraints"
    \\    },
    \\    "priority": {
    \\      "type": "integer",
    \\      "description": "0-100, higher=more important. Default 50.",
    \\      "default": 50
    \\    },
    \\    "scene_name": {
    \\      "type": "string",
    \\      "description": "Scenario label (e.g. 'debugging auth module'). Default empty.",
    \\      "default": ""
    \\    }
    \\  }
    \\}
;

/// Create the memory_save tool. `ctx` must point to a `MemoryState`.
pub fn tool(ctx: *memory_mod.MemoryState) at.AgentTool {
    return .{
        .name = "memory_save",
        .description = "Save a fact, decision, preference, or instruction to persistent memory. " ++
            "This memory will be available in future sessions via memory_search. " ++
            "Only save information that is durable (not one-time), self-contained " ++
            "(makes sense without conversation context), and user or AI centric. " ++
            "Do NOT save transient state, temporary values, or chitchat.",
        .parameters_json = parameters_json,
        .execution_mode = .parallel,
        .ctx = @ptrCast(ctx),
        .execute = execute,
        .skip_compression = true, // memory save confirmations should stay intact
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
    const ctx: *memory_mod.MemoryState = @ptrCast(@alignCast(self.ctx.?));

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const json_to_parse = common.repairConcatJson(a, args_json) orelse args_json;
    const parsed = std.json.parseFromSlice(std.json.Value, a, json_to_parse, .{}) catch {
        return common.toolError(allocator, "invalid_args", "failed to parse arguments JSON");
    };
    const root = parsed.value;

    const content_val = root.object.get("content") orelse
        return common.toolError(allocator, "invalid_args", "missing 'content' parameter");
    if (content_val != .string) return common.toolError(allocator, "invalid_args", "'content' must be a string");
    const content = content_val.string;

    const type_val = root.object.get("type") orelse
        return common.toolError(allocator, "invalid_args", "missing 'type' parameter");
    if (type_val != .string) return common.toolError(allocator, "invalid_args", "'type' must be a string");
    const mem_type = agent_memory.MemoryType.fromString(type_val.string) orelse
        return common.toolError(allocator, "invalid_args", "'type' must be 'persona', 'episodic', or 'instruction'");

    const priority: f32 = if (root.object.get("priority")) |v| blk: {
        if (v == .integer) break :blk @as(f32, @floatFromInt(v.integer));
        if (v == .float) break :blk @as(f32, @floatCast(v.float));
        break :blk 50.0;
    } else 50.0;

    const scene_name: []const u8 = if (root.object.get("scene_name")) |v|
        (if (v == .string) v.string else "")
    else
        "";

    // Save to L1 via MemoryContext.
    _ = ctx.ctx.save(allocator, content, mem_type, priority, scene_name) catch |e| {
        return common.toolError(allocator, "save_failed", @errorName(e));
    };

    // Confirm to the agent.
    const text = try std.fmt.allocPrint(allocator, "Saved memory ({s}): {s}", .{
        mem_type.toString(),
        content,
    });
    const content_arr = try allocator.alloc(ai.types.ContentBlock, 1);
    content_arr[0] = .{ .text = .{ .text = text } };
    return .{ .content = content_arr };
}