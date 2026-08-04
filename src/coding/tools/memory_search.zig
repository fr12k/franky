//! memory_search tool — lets the agent query persistent memory.
//!
//! The agent calls this to find relevant memories from previous sessions.
//! It hits the SQLite FTS5 index via MemoryContext.search().
//!
//! Schema: `{query, limit?}`.

const std = @import("std");
const ct = @import("../types.zig");
const at = ct.agent.types;
const ai = ct.ai;
const common = @import("common.zig");
const memory_mod = @import("../memory.zig");

pub const parameters_json: []const u8 =
    \\{
    \\  "type": "object",
    \\  "required": ["query"],
    \\  "properties": {
    \\    "query": {
    \\      "type": "string",
    \\      "description": "Natural language search query for memories from previous sessions"
    \\    },
    \\    "limit": {
    \\      "type": "integer",
    \\      "description": "Maximum number of results to return (default 5)",
    \\      "default": 5
    \\    }
    \\  }
    \\}
;

/// Create the memory_search tool. `ctx` must point to a `MemoryState`.
pub fn tool(ctx: *memory_mod.MemoryState) at.AgentTool {
    return .{
        .name = "memory_search",
        .description = "Search persistent memory for relevant context from previous sessions. " ++
            "Use this when you need to recall user preferences, past decisions, " ++
            "or facts established in earlier conversations. " ++
            "Pass a natural language query; results are ranked by relevance.",
        .parameters_json = parameters_json,
        .execution_mode = .parallel,
        .ctx = @ptrCast(ctx),
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
    const ctx: *memory_mod.MemoryState = @ptrCast(@alignCast(self.ctx.?));

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const json_to_parse = common.repairConcatJson(a, args_json) orelse args_json;
    const parsed = std.json.parseFromSlice(std.json.Value, a, json_to_parse, .{}) catch {
        return common.toolError(allocator, "invalid_args", "failed to parse arguments JSON");
    };
    const root = parsed.value;

    const query_val = root.object.get("query") orelse
        return common.toolError(allocator, "invalid_args", "missing 'query' parameter");
    if (query_val != .string) return common.toolError(allocator, "invalid_args", "'query' must be a string");
    const query = query_val.string;

    const limit: u32 = if (root.object.get("limit")) |v| blk: {
        if (v == .integer and v.integer >= 1) break :blk @intCast(v.integer);
        break :blk 5;
    } else 5;

    // Search L1 via FTS5 BM25.
    const results = ctx.ctx.search(allocator, query, limit) catch |e| {
        return common.toolError(allocator, "search_failed", @errorName(e));
    };
    defer {
        for (results) |r| r.deinit(allocator);
        allocator.free(results);
    }

    // Format results as text.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    if (results.len == 0) {
        try buf.appendSlice(allocator, "No memories found for query: ");
        try buf.appendSlice(allocator, query);
    } else {
        for (results, 0..) |r, i| {
            const line = try std.fmt.allocPrint(allocator, "[{d}] ({s}, priority={d}) {s}\n", .{
                i + 1,
                r.type.toString(),
                @as(i32, @intFromFloat(r.priority)),
                r.content,
            });
            defer allocator.free(line);
            try buf.appendSlice(allocator, line);
        }
    }

    const text = try buf.toOwnedSlice(allocator);
    const content_arr = try allocator.alloc(ai.types.ContentBlock, 1);
    content_arr[0] = .{ .text = .{ .text = text } };
    return .{ .content = content_arr };
}