//! ccr_retrieve tool — v2.31 Phase 3 §5.2.
//!
//! Schema: `{key: string}`. Returns the original content that was
//! compressed and stored in the CCR session. The CCR key is the hash
//! shown in the compaction-summary envelope (and in tool-result
//! compression markers when CCR is enabled).
//!
//! The tool wires the active `CcrSession` through the `ctx` field
//! of `at.AgentTool` (the same pattern `ls.zig` uses for the
//! `Workspace`). The session is owned by the agent loop, not by
//! the tool — see `src/coding/modes/print.zig` for ownership.

const std = @import("std");
const ct = @import("../types.zig");
const at = ct.agent.types;
const ai = ct.ai;
const ccr_integration_mod = @import("../../agent/ccr_integration.zig");

pub const parameters_json: []const u8 =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "key": {"type": "string", "description": "CCR key (hash) shown in the compaction marker."}
    \\  },
    \\  "required": ["key"],
    \\  "additionalProperties": false
    \\}
;

pub fn toolWithSession(session: *ccr_integration_mod.CcrSession) at.AgentTool {
    return .{
        .name = "ccr_retrieve",
        .description = "Retrieve the original (uncompressed) content for a CCR key. " ++
            "Keys are emitted by `compact_conversation` and by tool-result " ++
            "compression when CCR is enabled. Returns an error if the key " ++
            "was never stored or has been evicted by the FIFO cap.",
        .parameters_json = parameters_json,
        .execution_mode = .parallel,
        .ctx = @ptrCast(session),
        .execute = execute,
    };
}

fn execute(
    tool: *const at.AgentTool,
    allocator: std.mem.Allocator,
    io: std.Io,
    call_id: []const u8,
    args_json: []const u8,
    cancel: *ai.stream.Cancel,
    on_update: at.OnUpdate,
) anyerror!at.ToolResult {
    _ = call_id;
    _ = cancel;
    _ = on_update;
    // v2.31 Phase 3 — `io` is currently unused (the retrieval is a
    // pure map lookup) but it's part of the tool interface; keep the
    // param to match the vtable and silence the "unused parameter"
    // warning without `_ = io;` (which the spec-anchor checker
    // would still flag as a pointless discard). Future work that
    // adds a streaming-style or pre-fetch hook will use it.
    _ = io;

    // Pull the CcrSession out of the tool's ctx slot. The
    // `toolWithSession` constructor sets it; the type pun is
    // safe because both sides are `*CcrSession`.
    const session_ptr: *ccr_integration_mod.CcrSession = @ptrCast(@alignCast(tool.ctx.?));

    // Parse the `key` argument. We use the shared arena pattern
    // other tools use (see `tools/ls.zig`) so the parse scratch is
    // freed when the function returns.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        arena.allocator(),
        args_json,
        .{},
    );
    const root = parsed.value;
    if (root != .object) return error.MalformedArgs;

    const key_v = root.object.get("key") orelse return error.MissingKey;
    if (key_v != .string) return error.KeyMustBeString;
    const key: []const u8 = key_v.string;
    if (key.len == 0) return error.EmptyKey;

    const original = session_ptr.retrieve(key) orelse
        return error.CcrKeyNotFound;

    // Build a single text content block with the retrieved content.
    const arr = try allocator.alloc(ai.types.ContentBlock, 1);
    arr[0] = .{ .text = .{ .text = try allocator.dupe(u8, original) } };
    return .{ .content = arr };
}

// ─── Tests ──────────────────────────────────────────────────────

const testing = std.testing;
const test_h = @import("../../test_helpers.zig");

test "ccr_retrieve: missing key returns CcrKeyNotFound" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const gpa = testing.allocator;
    var session = ccr_integration_mod.CcrSession.init(gpa, null, ccr_integration_mod.default_max_entries);
    defer session.deinit();

    var tool = toolWithSession(&session);
    const err = tool.execute(
        &tool,
        gpa,
        io,
        "call_1",
        "{\"key\":\"nonexistent\"}",
        undefined,
        .{},
    );
    try testing.expectError(error.CcrKeyNotFound, err);
}

test "ccr_retrieve: missing key field returns MissingKey" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const gpa = testing.allocator;
    var session = ccr_integration_mod.CcrSession.init(gpa, null, ccr_integration_mod.default_max_entries);
    defer session.deinit();

    var tool = toolWithSession(&session);
    const err = tool.execute(
        &tool,
        gpa,
        io,
        "call_1",
        "{}",
        undefined,
        .{},
    );
    try testing.expectError(error.MissingKey, err);
}

test "ccr_retrieve: round trip returns original content" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const gpa = testing.allocator;
    var session = ccr_integration_mod.CcrSession.init(gpa, null, ccr_integration_mod.default_max_entries);
    defer session.deinit();

    const original = "the original uncompressed tool output";
    const key = try session.store(original);

    var tool = toolWithSession(&session);
    var result = try tool.execute(
        &tool,
        gpa,
        io,
        "call_1",
        try std.fmt.allocPrint(gpa, "{{\"key\":\"{s}\"}}", .{key}),
        undefined,
        .{},
    );
    defer result.deinit(gpa);

    try testing.expectEqual(@as(usize, 1), result.content.len);
    try testing.expectEqualStrings(original, result.content[0].text.text);
}
