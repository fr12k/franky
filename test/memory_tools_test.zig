//! End-to-end test for the memory tools: memory_search, memory_save, and
//! memory_delete (agent_memory v0.5.0) against a real SQLite database.
//!
//! Exercises the full franky integration path:
//!   MemoryState (store + MemoryContext) → AgentTool.execute → store
//!
//! Covers:
//! - save → search (results include the [id: ...] field)
//! - delete (soft) → hidden from search, "no live memory" on second delete
//! - delete is always soft — an explicit `hard: true` arg is ignored,
//!   the row stays restorable via the operator-level store API
//! - unknown id → clear non-error message
//! - finalizeToolSet registers all three memory tools when memory is on

const std = @import("std");
const franky = @import("franky");
const ai = franky.ai;
const at = franky.agent.types;
const memory_mod = franky.coding.memory;
const tools_mod = franky.coding.tools;
const config_mod = franky.coding.config.resolver;
const testing = std.testing;

var test_counter: std.atomic.Value(u64) = .init(0);

/// Run a tool's execute with the given args JSON and return the text of
/// the first content block (caller frees).
fn runTool(
    tool: *const at.AgentTool,
    allocator: std.mem.Allocator,
    io: std.Io,
    args_json: []const u8,
) ![]u8 {
    var cancel = ai.stream.Cancel{};
    var result = try tool.execute(
        tool,
        allocator,
        io,
        "call-1",
        args_json,
        &cancel,
        .{},
    );
    defer result.deinit(allocator);
    var text: []u8 = &.{};
    for (result.content) |block| {
        if (block == .text) {
            text = try allocator.dupe(u8, block.text.text);
        }
    }
    return text;
}

test "memory tools: save → search shows id → soft delete → gone" {
    const allocator = testing.allocator;
    var threaded = franky.test_helpers.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    // Fresh temp DB per test run.
    const epoch = test_counter.fetchAdd(1, .monotonic);
    const dir = try std.fmt.allocPrint(allocator, "/tmp/franky-memtool-test-{d}", .{epoch});
    defer allocator.free(dir);
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const db_path = try std.fmt.allocPrint(allocator, "{s}/memory.db", .{dir});
    defer allocator.free(db_path);

    var state = try memory_mod.MemoryState.init(allocator, io, .{ .db_path = db_path });
    defer state.deinit();
    // `init()` returns by value — re-point ctx.store at the struct's final
    // address before any tool uses it.
    state.repointCtx();

    const search_tool = tools_mod.memory_search.tool(&state);
    const save_tool = tools_mod.memory_save.tool(&state);
    const delete_tool = tools_mod.memory_delete.tool(&state);

    // 1. Save a memory.
    const saved_text = try runTool(&save_tool, allocator, io,
        \\{"content": "User prefers PostgreSQL over MySQL", "type": "persona", "priority": 80}
    );
    defer allocator.free(saved_text);
    try testing.expect(std.mem.indexOf(u8, saved_text, "Saved memory") != null);

    // 2. Search — results must include the [id: ...] field.
    const search_text = try runTool(&search_tool, allocator, io,
        \\{"query": "PostgreSQL"}
    );
    defer allocator.free(search_text);
    try testing.expect(std.mem.indexOf(u8, search_text, "User prefers PostgreSQL over MySQL") != null);
    try testing.expect(std.mem.indexOf(u8, search_text, "[id: ") != null);

    // Extract the record id from "[id: mem-...] (".
    const id_start = std.mem.indexOf(u8, search_text, "[id: ").? + "[id: ".len;
    const id_end = std.mem.indexOfPos(u8, search_text, id_start, "] ").?;
    const record_id = search_text[id_start..id_end];

    // 3. Soft delete (default) by the extracted id.
    var buf: [256]u8 = undefined;
    const del_args = try std.fmt.bufPrint(&buf, "{{\"record_id\": \"{s}\"}}", .{record_id});
    const del_text = try runTool(&delete_tool, allocator, io, del_args);
    defer allocator.free(del_text);
    try testing.expect(std.mem.indexOf(u8, del_text, "Deleted memory") != null);

    // 4. Search — no longer visible.
    const search2_text = try runTool(&search_tool, allocator, io,
        \\{"query": "PostgreSQL"}
    );
    defer allocator.free(search2_text);
    try testing.expect(std.mem.indexOf(u8, search2_text, "No memories found") != null);

    // 5. Deleting again → clear non-error message.
    const del2_text = try runTool(&delete_tool, allocator, io, del_args);
    defer allocator.free(del2_text);
    try testing.expect(std.mem.indexOf(u8, del2_text, "No live memory found") != null);
}

test "memory tools: agent delete is always soft — hard arg is ignored" {
    const allocator = testing.allocator;
    var threaded = franky.test_helpers.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const epoch = test_counter.fetchAdd(1, .monotonic);
    const dir = try std.fmt.allocPrint(allocator, "/tmp/franky-memtool-test-{d}", .{epoch});
    defer allocator.free(dir);
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const db_path = try std.fmt.allocPrint(allocator, "{s}/memory.db", .{dir});
    defer allocator.free(db_path);

    var state = try memory_mod.MemoryState.init(allocator, io, .{ .db_path = db_path });
    defer state.deinit();
    // `init()` returns by value — re-point ctx.store at the struct's final
    // address before any tool uses it.
    state.repointCtx();

    const search_tool = tools_mod.memory_search.tool(&state);
    const save_tool = tools_mod.memory_save.tool(&state);
    const delete_tool = tools_mod.memory_delete.tool(&state);

    const saved_text = try runTool(&save_tool, allocator, io,
        \\{"content": "User uses SQLite for tests", "type": "episodic"}
    );
    allocator.free(saved_text);

    // Find the id.
    const search_text = try runTool(&search_tool, allocator, io,
        \\{"query": "SQLite"}
    );
    defer allocator.free(search_text);
    const id_start = std.mem.indexOf(u8, search_text, "[id: ").? + "[id: ".len;
    const id_end = std.mem.indexOfPos(u8, search_text, id_start, "] ").?;
    const record_id = search_text[id_start..id_end];

    // Delete with an explicit `hard: true` — the tool must IGNORE it and
    // only soft-delete. (Hard delete is not exposed to the agent.)
    var buf: [256]u8 = undefined;
    const del_args = try std.fmt.bufPrint(&buf, "{{\"record_id\": \"{s}\", \"hard\": true}}", .{record_id});
    const del_text = try runTool(&delete_tool, allocator, io, del_args);
    defer allocator.free(del_text);
    try testing.expect(std.mem.indexOf(u8, del_text, "Deleted memory") != null);
    try testing.expect(std.mem.indexOf(u8, del_text, "Permanently deleted") == null);

    // Hidden from search.
    const search2_text = try runTool(&search_tool, allocator, io,
        \\{"query": "SQLite"}
    );
    defer allocator.free(search2_text);
    try testing.expect(std.mem.indexOf(u8, search2_text, "No memories found") != null);

    // Second delete → not found (no live row).
    const del2_text = try runTool(&delete_tool, allocator, io, del_args);
    defer allocator.free(del2_text);
    try testing.expect(std.mem.indexOf(u8, del2_text, "No live memory found") != null);

    // The row is still SOFT-deleted at the store level — restorable by the
    // operator API (proof the agent cannot irreversibly destroy it).
    const restored = try state.ctx.restore(record_id);
    try testing.expect(restored);

    // …and back in search results.
    const search3_text = try runTool(&search_tool, allocator, io,
        \\{"query": "SQLite"}
    );
    defer allocator.free(search3_text);
    try testing.expect(std.mem.indexOf(u8, search3_text, "User uses SQLite for tests") != null);
}

test "memory tools: unknown id and invalid args return clear errors" {
    const allocator = testing.allocator;
    var threaded = franky.test_helpers.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const epoch = test_counter.fetchAdd(1, .monotonic);
    const dir = try std.fmt.allocPrint(allocator, "/tmp/franky-memtool-test-{d}", .{epoch});
    defer allocator.free(dir);
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const db_path = try std.fmt.allocPrint(allocator, "{s}/memory.db", .{dir});
    defer allocator.free(db_path);

    var state = try memory_mod.MemoryState.init(allocator, io, .{ .db_path = db_path });
    defer state.deinit();
    // `init()` returns by value — re-point ctx.store at the struct's final
    // address before any tool uses it.
    state.repointCtx();

    const delete_tool = tools_mod.memory_delete.tool(&state);

    // Unknown id → non-error guidance text.
    const del_text = try runTool(&delete_tool, allocator, io,
        \\{"record_id": "mem-does-not-exist"}
    );
    defer allocator.free(del_text);
    try testing.expect(std.mem.indexOf(u8, del_text, "No live memory found") != null);

    // Missing record_id → tool error.
    var cancel = ai.stream.Cancel{};
    var result = try delete_tool.execute(
        &delete_tool,
        allocator,
        io,
        "call-1",
        \\{}
    ,
        &cancel,
        .{},
    );
    defer result.deinit(allocator);
    try testing.expect(result.is_error == true);
}

test "finalizeToolSet registers memory_search, memory_save, memory_delete" {
    const allocator = testing.allocator;
    var threaded = franky.test_helpers.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const epoch = test_counter.fetchAdd(1, .monotonic);
    const dir = try std.fmt.allocPrint(allocator, "/tmp/franky-memtool-test-{d}", .{epoch});
    defer allocator.free(dir);
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const db_path = try std.fmt.allocPrint(allocator, "{s}/memory.db", .{dir});
    defer allocator.free(db_path);

    var state = try memory_mod.MemoryState.init(allocator, io, .{ .db_path = db_path });
    defer state.deinit();
    // `init()` returns by value — re-point ctx.store at the struct's final
    // address before any tool uses it.
    state.repointCtx();

    // Minimal real collaborators for the built-in extras — none are
    // dereferenced beyond field reads at construction time.
    var registry = ai.registry.Registry.init(allocator);
    defer registry.deinit();
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    const environ: std.process.Environ = .empty;
    var presets = tools_mod.subagent.PresetRegistry.init(allocator);
    defer presets.deinit();
    var guardrail_state = try franky.agent.guardrails.GuardrailState.init(
        allocator,
        .{ .workspace_dir = "/tmp" },
        io,
    );
    defer guardrail_state.deinit();

    const subagent_ctx = tools_mod.subagent.Ctx{
        .registry = &registry,
        .environ = environ,
        .environ_map = &env_map,
        .parent_tools = &.{},
        .parent_role = .full,
        .presets = &presets,
        .parameters_json_owned = "",
        .permission_store = null,
        .parent_session_dir = null,
    };

    const tools = try config_mod.finalizeToolSet(allocator, .{
        .base_tools = &.{},
        .ext_tools = &.{},
        .subagent_ctx = &subagent_ctx,
        .preset_registry = &presets,
        .guardrail_state = &guardrail_state,
        .ccr_ctx = null,
        .memory_state = &state,
    });
    defer allocator.free(tools);

    var saw_search = false;
    var saw_save = false;
    var saw_delete = false;
    for (tools) |t| {
        if (std.mem.eql(u8, t.name, "memory_search")) saw_search = true;
        if (std.mem.eql(u8, t.name, "memory_save")) saw_save = true;
        if (std.mem.eql(u8, t.name, "memory_delete")) saw_delete = true;
    }
    try testing.expect(saw_search);
    try testing.expect(saw_save);
    try testing.expect(saw_delete);
    // 3 memory tools + 4 built-in extras.
    try testing.expectEqual(@as(usize, 7), tools.len);
}
