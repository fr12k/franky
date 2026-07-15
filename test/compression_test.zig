//! End-to-end test: agent loop with zompress compression enabled.
//!
//! Uses the faux provider to script a tool-call round-trip where the
//! tool returns a large JSON array (>1024 bytes, >5 items) that
//! zompress's SmartCrusher can compress. Verifies:
//!   1. The tool result in the transcript is compressed (shorter).
//!   2. A CCR marker (`<<ccr:...>>`) is present in the compressed text.
//!   3. The `ccr_retrieve` tool can recover the original content.
//!   4. Small results (< min_bytes) pass through unchanged.
//!   5. Compression is a no-op when `enabled=false`.

const std = @import("std");
const franky = @import("franky");
const ai = franky.ai;
const at = franky.agent.types;
const loop = franky.agent.loop;
const faux_mod = ai.providers.faux;
const compression_mod = franky.coding.compression;
const testing = std.testing;

/// Tool that returns a large JSON array (compressible by SmartCrusher).
fn largeJsonTool(
    tool: *const at.AgentTool,
    allocator: std.mem.Allocator,
    io: std.Io,
    call_id: []const u8,
    args_json: []const u8,
    cancel: *ai.stream.Cancel,
    on_update: at.OnUpdate,
) anyerror!at.ToolResult {
    _ = tool;
    _ = io;
    _ = call_id;
    _ = args_json;
    _ = cancel;
    _ = on_update;

    // Build a JSON array with 20 items — triggers SmartCrusher (>5 items).
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "[\n");
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        const line = try std.fmt.allocPrint(allocator,
            "  {{\"id\": {}, \"name\": \"item_{}\", \"value\": {}, \"active\": true}}{s}\n",
            .{ i, i, i * 100, if (i < 19) "," else "" });
        defer allocator.free(line);
        try buf.appendSlice(allocator, line);
    }
    try buf.appendSlice(allocator, "]\n");

    const text = try buf.toOwnedSlice(allocator);
    const arr = try allocator.alloc(ai.types.ContentBlock, 1);
    arr[0] = .{ .text = .{ .text = text } };
    return .{ .content = arr };
}

/// Tool that returns a small result (< 1024 bytes, not compressed).
fn smallTool(
    tool: *const at.AgentTool,
    allocator: std.mem.Allocator,
    io: std.Io,
    call_id: []const u8,
    args_json: []const u8,
    cancel: *ai.stream.Cancel,
    on_update: at.OnUpdate,
) anyerror!at.ToolResult {
    _ = tool;
    _ = io;
    _ = call_id;
    _ = args_json;
    _ = cancel;
    _ = on_update;

    const text = try allocator.dupe(u8, "small result");
    const arr = try allocator.alloc(ai.types.ContentBlock, 1);
    arr[0] = .{ .text = .{ .text = text } };
    return .{ .content = arr };
}

fn fauxStreamShim(ctx: ai.registry.StreamCtx) anyerror!void {
    const faux_ptr: *faux_mod.FauxProvider = @ptrCast(@alignCast(ctx.userdata.?));
    try faux_ptr.runSync(ctx.io, ctx.context, ctx.out);
}

fn newAgentChannel(gpa: std.mem.Allocator) !loop.AgentChannel {
    return try loop.AgentChannel.initWithDrop(gpa, 128, at.AgentEvent.deinit, gpa);
}

test "compression: large JSON array is compressed in tool result" {
    var threaded = franky.test_helpers.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = franky.global_allocator.gpa;

    var faux = faux_mod.FauxProvider.init(gpa);
    defer faux.deinit();
    try faux.push(.{ .events = &.{
        .{ .tool_call = .{ .id = "c1", .name = "large_json", .args_json = "{}" } },
        .{ .done = .{ .stop_reason = .tool_use } },
    } });
    try faux.push(.{ .events = &.{
        .{ .text = .{ .text = "done" } },
        .{ .done = .{ .stop_reason = .stop } },
    } });

    var reg = ai.registry.Registry.init(gpa);
    defer reg.deinit();
    try reg.register(.{ .api = "faux", .provider = "faux", .stream_fn = fauxStreamShim, .userdata = @ptrCast(&faux) });

    var cancel = ai.stream.Cancel{};
    var transcript = loop.Transcript.init(gpa);
    defer transcript.deinit();
    var ch = try newAgentChannel(gpa);
    defer ch.deinit();

    var ccr_store = compression_mod.CcrSessionStore.init(gpa);
    defer ccr_store.deinit();

    const large_tool = at.AgentTool{
        .name = "large_json",
        .description = "returns large JSON",
        .parameters_json = "{\"type\":\"object\"}",
        .execute = largeJsonTool,
    };

    loop.agentLoop(gpa, io, &transcript, .{
        .model = .{ .id = "faux-1", .provider = "faux", .api = "faux" },
        .tools = &[_]at.AgentTool{large_tool},
        .registry = &reg,
        .cancel = &cancel,
        .compression = compression_mod.CompressionConfig{
            .enabled = true,
            .min_bytes_to_compress = 1, // compress everything
        },
        .ccr_store = &ccr_store,
    }, &ch);

    while (ch.next(io)) |ev| ev.deinit(gpa);

    // Transcript: assistant1 (tool_call), toolResult1, assistant2 (done)
    try testing.expectEqual(@as(usize, 3), transcript.messages.items.len);

    // The tool_result message (index 1) should have compressed content.
    const tr_msg = transcript.messages.items[1];
    try testing.expectEqual(ai.types.Role.tool_result, tr_msg.role);
    try testing.expect(tr_msg.content.len > 0);

    // The compressed text should be shorter than the original would be.
    // Original JSON array is ~1250+ bytes; compressed should be < 1000.
    const compressed_text = tr_msg.content[0].text.text;
    try testing.expect(compressed_text.len < 1000);

    // Should contain a CCR marker.
    try testing.expect(std.mem.indexOf(u8, compressed_text, "<<<ccr:") != null);
}

test "compression: small result passes through unchanged" {
    var threaded = franky.test_helpers.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = franky.global_allocator.gpa;

    var faux = faux_mod.FauxProvider.init(gpa);
    defer faux.deinit();
    try faux.push(.{ .events = &.{
        .{ .tool_call = .{ .id = "c1", .name = "small", .args_json = "{}" } },
        .{ .done = .{ .stop_reason = .tool_use } },
    } });
    try faux.push(.{ .events = &.{
        .{ .text = .{ .text = "done" } },
        .{ .done = .{ .stop_reason = .stop } },
    } });

    var reg = ai.registry.Registry.init(gpa);
    defer reg.deinit();
    try reg.register(.{ .api = "faux", .provider = "faux", .stream_fn = fauxStreamShim, .userdata = @ptrCast(&faux) });

    var cancel = ai.stream.Cancel{};
    var transcript = loop.Transcript.init(gpa);
    defer transcript.deinit();
    var ch = try newAgentChannel(gpa);
    defer ch.deinit();

    var ccr_store = compression_mod.CcrSessionStore.init(gpa);
    defer ccr_store.deinit();

    const small_tool = at.AgentTool{
        .name = "small",
        .description = "returns small result",
        .parameters_json = "{\"type\":\"object\"}",
        .execute = smallTool,
    };

    loop.agentLoop(gpa, io, &transcript, .{
        .model = .{ .id = "faux-1", .provider = "faux", .api = "faux" },
        .tools = &[_]at.AgentTool{small_tool},
        .registry = &reg,
        .cancel = &cancel,
        .compression = compression_mod.CompressionConfig{
            .enabled = true,
            .min_bytes_to_compress = 100, // larger than "small result"
        },
        .ccr_store = &ccr_store,
    }, &ch);

    while (ch.next(io)) |ev| ev.deinit(gpa);

    const tr_msg = transcript.messages.items[1];
    try testing.expectEqualStrings("small result", tr_msg.content[0].text.text);
}

test "compression: disabled config skips compression" {
    var threaded = franky.test_helpers.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = franky.global_allocator.gpa;

    var faux = faux_mod.FauxProvider.init(gpa);
    defer faux.deinit();
    try faux.push(.{ .events = &.{
        .{ .tool_call = .{ .id = "c1", .name = "large_json", .args_json = "{}" } },
        .{ .done = .{ .stop_reason = .tool_use } },
    } });
    try faux.push(.{ .events = &.{
        .{ .text = .{ .text = "done" } },
        .{ .done = .{ .stop_reason = .stop } },
    } });

    var reg = ai.registry.Registry.init(gpa);
    defer reg.deinit();
    try reg.register(.{ .api = "faux", .provider = "faux", .stream_fn = fauxStreamShim, .userdata = @ptrCast(&faux) });

    var cancel = ai.stream.Cancel{};
    var transcript = loop.Transcript.init(gpa);
    defer transcript.deinit();
    var ch = try newAgentChannel(gpa);
    defer ch.deinit();

    const large_tool = at.AgentTool{
        .name = "large_json",
        .description = "returns large JSON",
        .parameters_json = "{\"type\":\"object\"}",
        .execute = largeJsonTool,
    };

    loop.agentLoop(gpa, io, &transcript, .{
        .model = .{ .id = "faux-1", .provider = "faux", .api = "faux" },
        .tools = &[_]at.AgentTool{large_tool},
        .registry = &reg,
        .cancel = &cancel,
        .compression = compression_mod.CompressionConfig{ .enabled = false },
        .ccr_store = null,
    }, &ch);

    while (ch.next(io)) |ev| ev.deinit(gpa);

    const tr_msg = transcript.messages.items[1];
    const text = tr_msg.content[0].text.text;
    // Original is ~2000+ bytes; without compression it stays large.
    try testing.expect(text.len > 1000);
    try testing.expect(std.mem.indexOf(u8, text, "<<<ccr:") == null);
}

test "compression: ccr_store retains original content for retrieval" {
    var threaded = franky.test_helpers.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = franky.global_allocator.gpa;

    var faux = faux_mod.FauxProvider.init(gpa);
    defer faux.deinit();
    try faux.push(.{ .events = &.{
        .{ .tool_call = .{ .id = "c1", .name = "large_json", .args_json = "{}" } },
        .{ .done = .{ .stop_reason = .tool_use } },
    } });
    try faux.push(.{ .events = &.{
        .{ .text = .{ .text = "done" } },
        .{ .done = .{ .stop_reason = .stop } },
    } });

    var reg = ai.registry.Registry.init(gpa);
    defer reg.deinit();
    try reg.register(.{ .api = "faux", .provider = "faux", .stream_fn = fauxStreamShim, .userdata = @ptrCast(&faux) });

    var cancel = ai.stream.Cancel{};
    var transcript = loop.Transcript.init(gpa);
    defer transcript.deinit();
    var ch = try newAgentChannel(gpa);
    defer ch.deinit();

    var ccr_store = compression_mod.CcrSessionStore.init(gpa);
    defer ccr_store.deinit();

    const large_tool = at.AgentTool{
        .name = "large_json",
        .description = "returns large JSON",
        .parameters_json = "{\"type\":\"object\"}",
        .execute = largeJsonTool,
    };

    loop.agentLoop(gpa, io, &transcript, .{
        .model = .{ .id = "faux-1", .provider = "faux", .api = "faux" },
        .tools = &[_]at.AgentTool{large_tool},
        .registry = &reg,
        .cancel = &cancel,
        .compression = compression_mod.CompressionConfig{
            .enabled = true,
            .min_bytes_to_compress = 1,
        },
        .ccr_store = &ccr_store,
    }, &ch);

    while (ch.next(io)) |ev| ev.deinit(gpa);

    // The compressed text should contain a CCR marker.
    const compressed = transcript.messages.items[1].content[0].text.text;
    try testing.expect(compressed.len < 1000);
    try testing.expect(std.mem.indexOf(u8, compressed, "<<<ccr:") != null);

    // The CCR store should have entries we can retrieve.
    // Iterate store keys and verify we can get the original back.
    var it = ccr_store.map.iterator();
    var found: usize = 0;
    while (it.next()) |entry| {
        const retrieved = ccr_store.retrieve(entry.key_ptr.*);
        try testing.expect(retrieved != null);
        try testing.expect(retrieved.?.len > 1000);
        try testing.expect(std.mem.indexOf(u8, retrieved.?, "\"id\": 0") != null);
        try testing.expect(std.mem.indexOf(u8, retrieved.?, "\"id\": 19") != null);
        found += 1;
    }
    try testing.expect(found > 0);
}
