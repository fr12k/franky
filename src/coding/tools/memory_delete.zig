//! memory_delete tool — lets the agent remove a memory from L1.
//!
//! The agent calls this when it decides a memory is wrong, outdated, or
//! superseded. This is the deletion counterpart to memory_save: without a
//! delete path, stale memories keep getting recalled forever.
//!
//! Deletion is SOFT by default (agent_memory v0.5.0): the record stops
//! appearing in search/recall but the row is kept and can be restored.
//! Pass hard=true for a permanent, irreversible removal.
//!
//! The agent deletes by record_id — the id memory_search returns — so
//! deletion is by reference, never by fuzzy content matching.
//!
//! Schema: `{record_id, hard?}`.

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
    \\  "required": ["record_id"],
    \\  "properties": {
    \\    "record_id": {
    \\      "type": "string",
    \\      "description": "ID of the memory to delete, exactly as returned by memory_search (the [id: ...] field)"
    \\    },
    \\    "hard": {
    \\      "type": "boolean",
    \\      "description": "Permanently remove the memory (irreversible). Default false = soft delete: hidden from search/recall but recoverable.",
    \\      "default": false
    \\    }
    \\  }
    \\}
;

/// Create the memory_delete tool. `ctx` must point to a `MemoryState`.
pub fn tool(ctx: *memory_mod.MemoryState) at.AgentTool {
    return .{
        .name = "memory_delete",
        .description = "Delete a memory from persistent memory. Use this when a memory " ++
            "is outdated, incorrect, or superseded — a stale memory that keeps " ++
            "getting recalled is worse than no memory. Pass the record_id exactly " ++
            "as returned by memory_search. Deletion is soft by default (the memory " ++
            "stops appearing in search and recall but can be restored); set " ++
            "hard=true to permanently remove it. Do NOT delete a memory just " ++
            "because it is currently not relevant — only delete memories that are " ++
            "wrong, superseded, or explicitly unwanted.",
        .parameters_json = parameters_json,
        .execution_mode = .parallel,
        .ctx = @ptrCast(ctx),
        .execute = execute,
        .skip_compression = true, // delete confirmations should stay intact
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

    const id_val = root.object.get("record_id") orelse
        return common.toolError(allocator, "invalid_args", "missing 'record_id' parameter");
    if (id_val != .string) return common.toolError(allocator, "invalid_args", "'record_id' must be a string");
    const record_id = id_val.string;
    if (record_id.len == 0) return common.toolError(allocator, "invalid_args", "'record_id' must not be empty");

    const hard: bool = if (root.object.get("hard")) |v| blk: {
        // Be strict for booleans: anything that is not JSON true/false is
        // treated as the default (soft) rather than guessed.
        if (v == .bool) break :blk v.bool;
        break :blk false;
    } else false;

    // Delete via MemoryContext (delegates through the store vtable).
    // Soft by default; hard only when explicitly requested.
    const options = agent_memory.DeleteOptions{ .soft = !hard };
    const deleted = ctx.ctx.store.deleteL1(record_id, options, ctx.ctx.iso) catch |e| {
        return common.toolError(allocator, "delete_failed", @errorName(e));
    };

    if (!deleted) {
        // Not an error — tell the agent clearly so it can recover
        // (e.g. re-run memory_search to get the current id).
        const text = try std.fmt.allocPrint(
            allocator,
            "No live memory found with id '{s}'. It may have been deleted already, " ++
                "or the id may be wrong/stale. Run memory_search and pass the exact " ++
                "[id: ...] value.",
            .{record_id},
        );
        const content_arr = try allocator.alloc(ai.types.ContentBlock, 1);
        content_arr[0] = .{ .text = .{ .text = text } };
        return .{ .content = content_arr };
    }

    // Confirm to the agent.
    const text = if (hard)
        try std.fmt.allocPrint(allocator, "Permanently deleted memory {s} (irreversible).", .{record_id})
    else
        try std.fmt.allocPrint(
            allocator,
            "Soft-deleted memory {s} (hidden from search/recall; recoverable by saving the same fact again).",
            .{record_id},
        );
    const content_arr = try allocator.alloc(ai.types.ContentBlock, 1);
    content_arr[0] = .{ .text = .{ .text = text } };
    return .{ .content = content_arr };
}
