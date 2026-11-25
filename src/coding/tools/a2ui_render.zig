//! a2ui_render tool — the model's entry point for emitting A2UI
//! (Agent-to-User Interface) messages in proxy mode.
//!
//! The tool accepts an array of A2UI v1.0 envelopes
//! (`createSurface` / `updateComponents` / `updateDataModel` /
//! `deleteSurface`), validates each against the PoC catalog, applies
//! it to the session's A2UI state, and fans it out to `/a2ui/events`
//! SSE subscribers. Validation failures are returned as tool errors in
//! the spec's standard error format so the model can self-correct
//! (prompt–generate–validate loop, spec §usage pattern).
//!
//! Only registered when `--a2ui` / `tools.a2ui.enabled` is on.

const std = @import("std");
const ct = @import("../types.zig");
const at = ct.agent.types;
const ai = ct.ai;
const common = @import("common.zig");
const a2ui_mod = @import("../a2ui.zig");

/// Write `s` to `writer` as a JSON string literal (quoted + escaped).
/// Used by the proxy's host-side A2UI projections to build component
/// batches safely (plan §4.4 — tool names / args may contain quotes).
pub fn jsonStringifyStr(writer: *std.Io.Writer, s: []const u8) !void {
    try std.json.Stringify.value(s, .{}, writer);
}

pub const parameters_json: []const u8 =
    \\{
    \\  "type": "object",
    \\  "required": ["messages"],
    \\  "properties": {
    \\    "messages": {
    \\      "type": "array",
    \\      "description": "A2UI v1.0 envelopes, applied in order. Each item is an object with exactly one key: createSurface, updateComponents, updateDataModel, or deleteSurface.",
    \\      "items": { "type": "object" }
    \\    }
    \\  }
    \\}
;

/// Create the a2ui_render tool bound to the session's A2UI state.
pub fn tool(session: *a2ui_mod.Session) at.AgentTool {
    return .{
        .name = "a2ui_render",
        .description = "Render or update rich interactive UI in the user's browser using A2UI v1.0 " ++
            "messages (createSurface / updateComponents / updateDataModel / deleteSurface). " ++
            "Use for forms, cards, dashboards — anything a visual layout communicates better " ++
            "than prose. Always send the complete component list for the part of the UI " ++
            "you manage in updateComponents. Catalog: Column, Row, Text, Button, TextField, " ++
            "CheckBox, Card.",
        .parameters_json = parameters_json,
        .execution_mode = .sequential,
        .ctx = @ptrCast(session),
        .execute = execute,
        .skip_compression = true, // validation errors must reach the LLM verbatim
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
    const session: *a2ui_mod.Session = @ptrCast(@alignCast(self.ctx.?));

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const json_to_parse = common.repairConcatJson(a, args_json) orelse args_json;
    const parsed = std.json.parseFromSlice(std.json.Value, a, json_to_parse, .{}) catch {
        return common.toolError(allocator, "invalid_args", "failed to parse arguments JSON");
    };
    const root = parsed.value;
    if (root != .object)
        return common.toolError(allocator, "invalid_args", "arguments must be an object with a \"messages\" array");
    const msgs = root.object.get("messages") orelse
        return common.toolError(allocator, "invalid_args", "missing \"messages\" array");
    if (msgs != .array)
        return common.toolError(allocator, "invalid_args", "\"messages\" must be an array");
    if (msgs.array.items.len == 0)
        return common.toolError(allocator, "invalid_args", "\"messages\" must contain at least one envelope");

    // Apply envelopes in order, stop at first validation failure so
    // the model can fix + retry (spec §prompt-generate-validate loop).
    for (msgs.array.items, 0..) |env, i| {
        if (try session.applyEnvelope(allocator, env)) |err_json| {
            // applyEnvelope's error strings are caller-owned (see
            // a2ui.zig applyEnvelope doc) — free after formatting.
            defer allocator.free(err_json);
            const msg = try std.fmt.allocPrint(allocator, "message {d} failed validation: {s}", .{ i, err_json });
            defer allocator.free(msg); // toolError formats its own copy
            return common.toolError(allocator, "a2ui_validation", msg);
        }
    }

    const text = try std.fmt.allocPrint(allocator, "Rendered {d} A2UI message(s) to surface \"{s}\" (version {d}). The UI is now visible in the user's browser.", .{ msgs.array.items.len, a2ui_mod.surface_id, session.currentVersion() });
    const content_arr = try allocator.alloc(ai.types.ContentBlock, 1);
    content_arr[0] = .{ .text = .{ .text = text } };
    return .{ .content = content_arr };
}

// ─── tests ──────────────────────────────────────────────────────

const testing = std.testing;

test "a2ui_render: valid envelopes reach the session state" {
    var session = a2ui_mod.Session.init(testing.allocator, undefined);
    defer session.deinit();
    const t = tool(&session);

    var threaded = std.Io.Threaded.init(testing.allocator, .{ .argv0 = .empty, .environ = .empty });
    defer threaded.deinit();
    const io = threaded.io();
    var cancel: ai.stream.Cancel = .{};

    const args =
        \\{"messages":[
        \\  {"updateComponents":{"surfaceId":"main","components":[
        \\    {"id":"root","component":"Column","children":["title"]},
        \\    {"id":"title","component":"Text","text":"What should I call you?"}
        \\  ]}},
        \\  {"updateDataModel":{"surfaceId":"main","data":{"form":{"name":"Frank"}}}}
        \\]}
    ;
    var result = try t.execute(&t, testing.allocator, io, "call1", args, &cancel, .{});
    defer result.deinit(testing.allocator);
    try testing.expect(!result.is_error);
    try testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "2 A2UI message(s)") != null);

    const snap = try session.renderSnapshotJson(testing.allocator);
    defer testing.allocator.free(snap);
    try testing.expect(std.mem.indexOf(u8, snap, "What should I call you?") != null);
    try testing.expect(std.mem.indexOf(u8, snap, "\"name\":\"Frank\"") != null);
}

test "a2ui_render: validation failure returns spec-format tool error" {
    var session = a2ui_mod.Session.init(testing.allocator, undefined);
    defer session.deinit();
    const t = tool(&session);

    var threaded = std.Io.Threaded.init(testing.allocator, .{ .argv0 = .empty, .environ = .empty });
    defer threaded.deinit();
    const io = threaded.io();
    var cancel: ai.stream.Cancel = .{};

    const args =
        \\{"messages":[{"updateComponents":{"components":[{"id":"x","component":"Iframe"}]}}]}
    ;
    var result = try t.execute(&t, testing.allocator, io, "call2", args, &cancel, .{});
    defer result.deinit(testing.allocator);
    try testing.expect(result.is_error);
    try testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "VALIDATION_FAILED") != null);
    try testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "message 0 failed validation") != null);
}

test "a2ui_render: missing messages array is invalid_args" {
    var session = a2ui_mod.Session.init(testing.allocator, undefined);
    defer session.deinit();
    const t = tool(&session);

    var threaded = std.Io.Threaded.init(testing.allocator, .{ .argv0 = .empty, .environ = .empty });
    defer threaded.deinit();
    const io = threaded.io();
    var cancel: ai.stream.Cancel = .{};

    var result = try t.execute(&t, testing.allocator, io, "call3", "{}", &cancel, .{});
    defer result.deinit(testing.allocator);
    try testing.expect(result.is_error);
    try testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "missing \"messages\" array") != null);
}
