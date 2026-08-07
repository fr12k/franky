//! streamProxy — §4.7 event-framing primitives.
//!
//! Transport-agnostic serialization for exposing the agent loop
//! to a remote front-end over SSE:
//!
//!   - `writeEvent(writer, ev)` — render one `AgentEvent` as an SSE
//!     frame (`event: <kind>\ndata: <json>\n\n`).
//!   - `encodeEventJson(allocator, ev)` — pure function that
//!     produces the JSON payload for an event (no SSE framing).
//!
//! The HTTP/SSE listener that calls these primitives lives at
//! `coding/modes/proxy.zig` (`franky --mode proxy`, shipped
//! v1.4.0). The split keeps this module pure (no `std.Io.net`
//! dependency) so it stays testable in isolation and re-usable
//! by alternative transports (Slack-bot bridges, custom RPC
//! frames).
//!
//! Events are the same `at.AgentEvent` shapes the in-process loop
//! emits, so a remote client can drive the agent with zero
//! semantic translation — matching §4.7's "uses the same event
//! shape" invariant.

const std = @import("std");
const at = @import("types.zig");
const wire = @import("wire.zig");

// `encodeEventJson` now lives in `agent/wire.zig` (a contract module)
// so `coding/sse.zig` and `coding/modes/rpc.zig` can import just the
// serializer without pulling this HTTP server module. Re-exported here
// for backward compatibility with callers that use `agent.proxy.encodeEventJson`.
pub const encodeEventJson = wire.encodeEventJson;

pub const ProxyError = error{
    WriteFailed,
} || std.mem.Allocator.Error;

/// Render `ev` as an SSE frame onto `writer`. The writer signature
/// matches `std.Io.Writer` — a `writeAll([]const u8) !void` method.
pub fn writeEvent(
    allocator: std.mem.Allocator,
    writer: anytype,
    ev: at.AgentEvent,
) !void {
    const kind = @tagName(ev);
    try writer.writeAll("event: ");
    try writer.writeAll(kind);
    try writer.writeAll("\ndata: ");
    const json = try encodeEventJson(allocator, ev);
    defer allocator.free(json);
    try writer.writeAll(json);
    try writer.writeAll("\n\n");
}

// ─── tests ────────────────────────────────────────────────────────

const testing = std.testing;

/// Simple `writeAll`-style writer backed by an ArrayList.
const ListWriter = struct {
    list: *std.ArrayList(u8),
    allocator: std.mem.Allocator,

    fn writeAll(self: *ListWriter, bytes: []const u8) !void {
        try self.list.appendSlice(self.allocator, bytes);
    }
};

test "writeEvent: full SSE framing lands on the writer" {
    const gpa = testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    var w = ListWriter{ .list = &list, .allocator = gpa };

    try writeEvent(gpa, &w, .turn_start);
    try testing.expectEqualStrings("event: turn_start\ndata: {\"kind\":\"turn_start\"}\n\n", list.items);
}
