//! memory_list tool — lets the agent enumerate existing memories.
//!
//! The agent calls this to browse what's already stored, without ranking by
//! relevance. Unlike memory_search (BM25-ranked, returns content + record_id),
//! memory_list returns only a metadata projection per memory:
//!   * scene_name
//!   * created_time
//!   * updated_time
//!   * metadata_json
//!
//! This is the "what do I already know?" counterpart to memory_search's
//! "what's relevant to this query?". It's useful when the agent wants to
//! audit, deduplicate, or sanity-check the memory store before saving or
//! deleting — e.g. "list memories, then delete the stale ones".
//!
//! Soft-deleted records are excluded automatically (the store filters
//! `deleted = 0`). The result is ordered newest-first by created_time.
//!
//! Schema: `{limit?, type?, scene_name?}` (all optional).

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
    \\  "properties": {
    \\    "limit": {
    \\      "type": "integer",
    \\      "description": "Maximum number of memories to return (default 20, max 100). Newest first.",
    \\      "default": 20
    \\    },
    \\    "type": {
    \\      "type": "string",
    \\      "enum": ["persona", "episodic", "instruction"],
    \\      "description": "Filter by memory type. Omit to list all types."
    \\    }
    \\  }
    \\}
;

/// Create the memory_list tool. `ctx` must point to a `MemoryState`.
pub fn tool(ctx: *memory_mod.MemoryState) at.AgentTool {
    return .{
        .name = "memory_list",
        .description = "List existing memories (metadata only: scene_name, created_time, " ++
            "updated_time, metadata_json). Use this to browse what's already stored " ++
            "before saving duplicates or to audit which memories exist. " ++
            "Results are newest-first and exclude soft-deleted memories. " ++
            "Unlike memory_search, this does not rank by relevance — it enumerates. " ++
            "Optional: filter by type, cap with limit (default 20).",
        .parameters_json = parameters_json,
        .execution_mode = .parallel,
        .ctx = @ptrCast(ctx),
        .execute = execute,
        .skip_compression = true, // listing output should stay intact
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

    // limit (optional, default 20, clamp 1..100).
    const limit: u32 = if (root.object.get("limit")) |v| blk: {
        if (v == .integer and v.integer >= 1) {
            const clamped: u32 = @min(@as(u32, @intCast(v.integer)), 100);
            break :blk clamped;
        }
        break :blk 20;
    } else 20;

    // type filter (optional).
    var filter = agent_memory.L1QueryFilter{ .limit = limit };
    if (root.object.get("type")) |v| {
        if (v == .string) {
            if (agent_memory.MemoryType.fromString(v.string)) |mt| {
                filter.type = mt;
            }
        }
    }

    // List live memories via MemoryContext.list (metadata projection only).
    const items = ctx.ctx.list(allocator, filter) catch |e| {
        return common.toolError(allocator, "list_failed", @errorName(e));
    };
    defer {
        for (items) |it| it.deinit(allocator);
        allocator.free(items);
    }

    // Format results as text.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    if (items.len == 0) {
        try buf.appendSlice(allocator, "No memories found.");
        if (filter.type) |t| {
            const line = try std.fmt.allocPrint(allocator, " (type={s})", .{t.toString()});
            defer allocator.free(line);
            try buf.appendSlice(allocator, line);
        }
        try buf.appendSlice(allocator, " The memory store may be empty or all matching memories may have been deleted.");
    } else {
        const header = try std.fmt.allocPrint(allocator, "{d} memory(s) (newest first):\n", .{items.len});
        defer allocator.free(header);
        try buf.appendSlice(allocator, header);

        for (items, 0..) |it, i| {
            // Truncate metadata_json if very long, to keep the listing readable.
            const meta_preview = if (it.metadata_json.len > 80)
                it.metadata_json[0..80]
            else
                it.metadata_json;
            const meta_suffix: []const u8 = if (it.metadata_json.len > 80) "…" else "";

            const line = try std.fmt.allocPrint(
                allocator,
                "[{d}] scene=\"{s}\" created={s} updated={s} metadata={s}{s}\n",
                .{
                    i + 1,
                    it.scene_name,
                    it.created_time,
                    it.updated_time,
                    meta_preview,
                    meta_suffix,
                },
            );
            defer allocator.free(line);
            try buf.appendSlice(allocator, line);
        }
    }

    const text = try buf.toOwnedSlice(allocator);
    const content_arr = try allocator.alloc(ai.types.ContentBlock, 1);
    content_arr[0] = .{ .text = .{ .text = text } };
    return .{ .content = content_arr };
}