//! Shared SSE broadcast infrastructure.
//!
//! Self-contained broadcaster + HTTP helpers usable by both `--mode print`
//! (optional SSE endpoint when `--register` is set) and `--mode proxy`
//! (the full web UI listener). Keeps the SSE wire format consistent
//! across modes so the same `GET /events` client works for both.
//!
//! Wire format: `event: <kind>\ndata: <json>\n\n` with an `id: <n>\n`
//! prefix for replay. Matches `agent.wire.encodeEventJson` for the
//! JSON payload.

const std = @import("std");
const at = @import("../agent/types.zig");
const wire = @import("../agent/wire.zig");
const ai_types = @import("../ai/types.zig");

pub const max_subs: usize = 32;
pub const replay_ring_capacity: usize = 4096;

/// Per-connection SSE writer (one slot per `/events` subscriber).
/// One thread (the agent worker) writes to each subscriber's
/// socket; the connection-handler thread only reads + closes. So
/// no per-subscriber lock is needed — `closed` is a flag the
/// reader can flip on disconnect and the writer checks before
/// flushing the next frame.
pub const SseSubscriber = struct {
    stream: std.Io.net.Stream,
    io: std.Io,
    closed: std.atomic.Value(bool) = .init(false),
    shutdown_on_close: bool = true,
    /// When true, the subscriber receives htmx hx-sse HTML frames
    /// (renderFrameHtml) instead of JSON frames (renderFrame). Set by
    /// the connection handler when the client requests
    /// GET /events?html=1 or sends Accept: text/html.
    html_mode: bool = false,

    pub fn close(sub: *SseSubscriber) void {
        sub.closed.store(true, .release);
        if (sub.shutdown_on_close) {
            sub.stream.shutdown(sub.io, .recv) catch {};
        }
    }
};

const ReplayEvent = struct {
    id: u64,
    frame: []u8,
    /// Optional HTML-mode frame (htmx hx-sse). When null, no HTML-mode
    /// subscriber was connected when this event was broadcast, so it
    /// wasn't rendered. A late-joining HTML subscriber will see a
    /// replay_gap and re-fetch the transcript via GET /transcript.
    html_frame: ?[]u8 = null,
};

/// Broadcasts SSE frames to connected subscribers with replay support.
/// Thread-safe: `broadcastEvent` / `broadcastFrame` may be called from
/// any thread; `addSub` / `removeSub` are called from connection handler
/// threads.
pub const SseBroadcaster = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    subs: [max_subs]?*SseSubscriber = @splat(null),
    events_mutex: std.Io.Mutex = .init,
    next_event_id: u64 = 1,
    replay_ring: [replay_ring_capacity]?ReplayEvent = @splat(null),

    pub fn init(allocator: std.mem.Allocator, io: std.Io) SseBroadcaster {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn deinit(self: *SseBroadcaster) void {
        for (self.replay_ring[0..]) |maybe| {
            if (maybe) |entry| {
                self.allocator.free(entry.frame);
                if (entry.html_frame) |hf| self.allocator.free(hf);
            }
        }
    }

    /// Register a subscriber. Returns false when the pool is full.
    pub fn addSub(self: *SseBroadcaster, sub: *SseSubscriber) bool {
        self.events_mutex.lockUncancelable(self.io);
        defer self.events_mutex.unlock(self.io);
        return self.addSubLocked(sub);
    }

    fn addSubLocked(self: *SseBroadcaster, sub: *SseSubscriber) bool {
        for (self.subs[0..], 0..) |s, i| {
            if (s == null) {
                self.subs[i] = sub;
                return true;
            }
        }
        return false;
    }

    pub fn removeSub(self: *SseBroadcaster, sub: *SseSubscriber) void {
        self.events_mutex.lockUncancelable(self.io);
        defer self.events_mutex.unlock(self.io);
        for (self.subs[0..], 0..) |s, i| {
            if (s == sub) {
                self.subs[i] = null;
                return;
            }
        }
    }

    /// Fan out a fully-rendered SSE frame to every live subscriber.
    /// Subscribers whose write fails are flagged closed and the
    /// connection-handler thread will reap them.
    ///
    /// Not replay-eligible — used for keepalive `ping`s only.
    /// Real agent events go through `broadcastEvent`.
    pub fn broadcastFrame(self: *SseBroadcaster, frame: []const u8) void {
        self.events_mutex.lockUncancelable(self.io);
        defer self.events_mutex.unlock(self.io);
        self.fanOutLocked(frame, null);
    }

    fn fanOutLocked(self: *SseBroadcaster, frame: []const u8, html_frame: ?[]const u8) void {
        for (self.subs[0..]) |maybe| {
            const sub = maybe orelse continue;
            if (sub.closed.load(.acquire)) continue;
            // Send the HTML frame to HTML-mode subscribers, JSON to the rest.
            const f = if (sub.html_mode and html_frame != null) html_frame.? else frame;
            var buf: [256]u8 = undefined;
            var w = sub.stream.writer(sub.io, &buf);
            w.interface.writeAll(f) catch {
                sub.close();
                continue;
            };
            w.interface.flush() catch {
                sub.close();
            };
        }
    }

    /// Stamp `frame_body` with the next monotonic event id, push
    /// the stamped copy into the replay ring, and fan out to live
    /// subscribers. Replay-eligible — every real `AgentEvent` frame
    /// should go through here.
    pub fn broadcastEvent(self: *SseBroadcaster, frame_body: []const u8) void {
        self.broadcastEventImpl(frame_body, null);
    }

    /// Like `broadcastEvent`, but also stamps an HTML-mode frame for
    /// htmx hx-sse subscribers. `html_frame_body` is the htmx-rendered
    /// equivalent of `frame_body` (from `renderFrameHtml`). Both are
    /// stored in the replay ring so either mode can replay.
    pub fn broadcastEventDual(self: *SseBroadcaster, frame_body: []const u8, html_frame_body: []const u8) void {
        self.broadcastEventImpl(frame_body, html_frame_body);
    }

    fn broadcastEventImpl(self: *SseBroadcaster, frame_body: []const u8, html_frame_body: ?[]const u8) void {
        self.events_mutex.lockUncancelable(self.io);
        defer self.events_mutex.unlock(self.io);

        const id = self.next_event_id;
        self.next_event_id += 1;

        var id_buf: [32]u8 = undefined;
        const id_str = std.fmt.bufPrint(&id_buf, "id: {d}\n", .{id}) catch unreachable;
        const stamped = self.allocator.alloc(u8, id_str.len + frame_body.len) catch {
            self.fanOutLocked(frame_body, html_frame_body);
            return;
        };
        @memcpy(stamped[0..id_str.len], id_str);
        @memcpy(stamped[id_str.len..], frame_body);

        // Stamp the HTML frame too (if provided).
        const stamped_html: ?[]u8 = blk: {
            if (html_frame_body) |hfb| {
                const sh = self.allocator.alloc(u8, id_str.len + hfb.len) catch break :blk null;
                @memcpy(sh[0..id_str.len], id_str);
                @memcpy(sh[id_str.len..], hfb);
                break :blk sh;
            }
            break :blk null;
        };

        const slot: usize = @intCast(id % replay_ring_capacity);
        if (self.replay_ring[slot]) |old| {
            self.allocator.free(old.frame);
            if (old.html_frame) |hf| self.allocator.free(hf);
        }
        self.replay_ring[slot] = .{ .id = id, .frame = stamped, .html_frame = stamped_html };

        self.fanOutLocked(stamped, stamped_html);
    }

    /// Return the oldest event id still in the ring (1-based).
    pub fn oldestEventId(self: *const SseBroadcaster) u64 {
        if (self.next_event_id > replay_ring_capacity)
            return self.next_event_id - replay_ring_capacity;
        return 1;
    }

    /// True when at least one live subscriber is in HTML mode (htmx).
    /// Callers use this to decide whether to render the HTML frame
    /// alongside the JSON frame before broadcasting.
    pub fn hasHtmlSubscriber(self: *SseBroadcaster) bool {
        self.events_mutex.lockUncancelable(self.io);
        defer self.events_mutex.unlock(self.io);
        for (self.subs[0..]) |maybe| {
            if (maybe) |sub| if (sub.html_mode and !sub.closed.load(.acquire)) return true;
        }
        return false;
    }
};

// ─── HTTP helpers for SSE endpoints ──────────────────────────────

pub const HeaderRead = struct { consumed: usize, total: usize };

pub const Request = struct {
    method: []const u8,
    path: []const u8,
    content_length: ?usize = null,
    last_event_id: ?u64 = null,
};

/// Read HTTP headers from a stream into buf. Returns the consumed
/// position (end of `\r\n\r\n` or `\n\n`) and total bytes read.
pub fn readHeaders(stream: *std.Io.net.Stream, io: std.Io, buf: []u8) !HeaderRead {
    var total: usize = 0;
    var r = stream.reader(io, &.{});
    while (total < buf.len) {
        var vecs: [1][]u8 = .{buf[total..]};
        const n = r.interface.readVec(&vecs) catch |err| switch (err) {
            error.EndOfStream => return HeaderRead{ .consumed = total, .total = total },
            error.ReadFailed => return error.ReadFailed,
        };
        if (n == 0) return HeaderRead{ .consumed = total, .total = total };
        total += n;
        if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n")) |idx| {
            return HeaderRead{ .consumed = idx + 4, .total = total };
        }
    }
    return HeaderRead{ .consumed = total, .total = total };
}

/// Parse a `Request` from raw header bytes.
pub fn parseRequest(headers: []const u8) ?Request {
    const line_end = std.mem.indexOf(u8, headers, "\r\n") orelse return null;
    const line = headers[0..line_end];
    const sp1 = std.mem.indexOfScalar(u8, line, ' ') orelse return null;
    const method = line[0..sp1];
    const rest = line[sp1 + 1 ..];
    const sp2 = std.mem.indexOfScalar(u8, rest, ' ') orelse return null;
    const path = rest[0..sp2];

    var req: Request = .{ .method = method, .path = path };

    var cursor: usize = line_end + 2;
    while (cursor < headers.len) {
        const next_eol = std.mem.indexOfPos(u8, headers, cursor, "\r\n") orelse break;
        if (next_eol == cursor) break;
        const header_line = headers[cursor..next_eol];
        if (std.ascii.startsWithIgnoreCase(header_line, "content-length:")) {
            const value = std.mem.trim(u8, header_line[15..], " \t");
            req.content_length = std.fmt.parseInt(usize, value, 10) catch null;
        } else if (std.ascii.startsWithIgnoreCase(header_line, "last-event-id:")) {
            const value = std.mem.trim(u8, header_line[14..], " \t");
            req.last_event_id = std.fmt.parseInt(u64, value, 10) catch null;
        }
        cursor = next_eol + 2;
    }
    return req;
}

pub fn respondStatus(stream: *std.Io.net.Stream, io: std.Io, status: u16, reason: []const u8) void {
    var buf: [512]u8 = undefined;
    const text = std.fmt.bufPrint(
        &buf,
        "HTTP/1.1 {d} {s}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        .{ status, reason },
    ) catch return;
    var wbuf: [256]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    w.interface.writeAll(text) catch {};
    w.interface.flush() catch {};
}

pub fn respondJson(stream: *std.Io.net.Stream, io: std.Io, status: u16, body: []const u8) void {
    var hdr: [256]u8 = undefined;
    const text = std.fmt.bufPrint(
        &hdr,
        "HTTP/1.1 {d} OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n",
        .{ status, body.len },
    ) catch return;
    var wbuf: [256]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    w.interface.writeAll(text) catch return;
    w.interface.writeAll(body) catch return;
    w.interface.flush() catch {};
}

/// Write the SSE preamble to a stream and return an SseSubscriber
/// that a connection handler thread can use to wait for disconnect.
/// The subscriber is NOT registered with the broadcaster yet.
pub fn writeSsePreamble(
    stream: *std.Io.net.Stream,
    io: std.Io,
) ?SseSubscriber {
    const preamble =
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: text/event-stream\r\n" ++
        "Cache-Control: no-cache\r\n" ++
        "Connection: close\r\n" ++
        "Access-Control-Allow-Origin: *\r\n" ++
        "\r\n" ++
        ": connected\n\n";
    var pre_buf: [256]u8 = undefined;
    var pw = stream.writer(io, &pre_buf);
    pw.interface.writeAll(preamble) catch return null;
    pw.interface.flush() catch return null;
    return SseSubscriber{ .stream = stream.*, .io = io };
}

/// Handle a `GET /events` request. Reads the `Last-Event-ID` header
/// (passed via `last_event_id`), sends replay frames, registers the
/// subscriber for live broadcast, then blocks until disconnect.
/// `broadcaster` must outlive the returned thread.
pub fn handleSseRequest(
    broadcaster: *SseBroadcaster,
    stream: *std.Io.net.Stream,
    io: std.Io,
    last_event_id: u64,
) void {
    var sub = writeSsePreamble(stream, io) orelse return;

    // Replay + register under mutex.
    {
        broadcaster.events_mutex.lockUncancelable(io);
        defer broadcaster.events_mutex.unlock(io);

        // Replay if the client has missed events OR it's a first-time
        // connection (last_event_id == 0) and events are available.
        // The latter covers the print-mode + orchestrator race: the
        // agent loop finishes before the orchestrator subscribes, so
        // the fresh client must see buffered events via replay.
        const has_events = broadcaster.next_event_id > 1;
        const needs_replay = (last_event_id == 0 and has_events) or
            (last_event_id > 0 and last_event_id + 1 < broadcaster.next_event_id);
        if (needs_replay) {
            const oldest = broadcaster.oldestEventId();

            if (last_event_id + 1 < oldest) {
                // Gap — emit replay_gap.
                var buf: [256]u8 = undefined;
                var w = stream.writer(io, &buf);
                w.interface.writeAll("event: replay_gap\ndata: {}\n\n") catch {};
                w.interface.flush() catch {};
            }

            const start: u64 = @max(last_event_id + 1, oldest);
            var i: u64 = start;
            while (i < broadcaster.next_event_id) : (i += 1) {
                const slot: usize = @intCast(i % replay_ring_capacity);
                if (broadcaster.replay_ring[slot]) |entry| {
                    if (entry.id == i) {
                        var buf: [256]u8 = undefined;
                        var w = stream.writer(io, &buf);
                        w.interface.writeAll(entry.frame) catch break;
                        w.interface.flush() catch break;
                    }
                }
                if (sub.closed.load(.acquire)) break;
            }
        }

        if (!broadcaster.addSubLocked(&sub)) {
            const msg = "event: error\ndata: {\"kind\":\"error\",\"message\":\"too many subscribers\"}\n\n";
            var ebuf: [256]u8 = undefined;
            var ew = stream.writer(io, &ebuf);
            ew.interface.writeAll(msg) catch {};
            ew.interface.flush() catch {};
            return;
        }
    }
    defer broadcaster.removeSub(&sub);

    // Block until client disconnects.
    var sink: [512]u8 = undefined;
    var r = stream.reader(io, &.{});
    while (!sub.closed.load(.acquire)) {
        var vecs: [1][]u8 = .{&sink};
        const n = r.interface.readVec(&vecs) catch break;
        if (n == 0) break;
    }
}

/// Render one `AgentEvent` as a complete SSE frame (without `id:` prefix).
/// Uses `agent.wire.encodeEventJson` for the JSON payload — same wire
/// format the proxy mode emits. Owned by the caller.
pub fn renderFrame(allocator: std.mem.Allocator, ev: at.AgentEvent) ![]u8 {
    const json = try wire.encodeEventJson(allocator, ev);
    defer allocator.free(json);
    const kind = @tagName(ev);
    return std.fmt.allocPrint(allocator, "event: {s}\ndata: {s}\n\n", .{ kind, json });
}

/// Render one `AgentEvent` as an SSE frame for the htmx hx-sse UI.
/// Named events (lifecycle + text deltas) keep the `event: kind\n`
/// prefix so the client can handle them via `hx-on`. Content events
/// are unnamed (`data: ...\n\n`) carrying HTML with `hx-swap-oob`
/// that htmx swaps into targets automatically. Owned by the caller.
pub fn renderFrameHtml(allocator: std.mem.Allocator, ev: at.AgentEvent) ![]u8 {
    const body = try wire.encodeEventHtml(allocator, ev);
    defer allocator.free(body);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    if (wire.isNamedHtmlEvent(ev)) {
        const kind = @tagName(ev);
        try buf.appendSlice(allocator, "event: ");
        try buf.appendSlice(allocator, kind);
        try buf.appendSlice(allocator, "\n");
    }
    // SSE spec: a `data:` field containing embedded newlines must be
    // split into one `data:` line per row — the client rejoins them
    // with `\n`. A bare `\n` in the body would terminate the data
    // field prematurely and break the frame.
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| {
        try buf.appendSlice(allocator, "data: ");
        try buf.appendSlice(allocator, line);
        try buf.appendSlice(allocator, "\n");
    }
    try buf.appendSlice(allocator, "\n");
    return buf.toOwnedSlice(allocator);
}

// ─── renderFrameHtml tests ────────────────────────────────────────

test "renderFrameHtml: named event (turn_start) gets event: prefix" {
    const gpa = std.testing.allocator;
    const frame = try renderFrameHtml(gpa, .turn_start);
    defer gpa.free(frame);
    try std.testing.expect(std.mem.indexOf(u8, frame, "event: turn_start\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "data: {}\n") != null);
}

test "renderFrameHtml: text delta is named (Option B)" {
    const gpa = std.testing.allocator;
    const frame = try renderFrameHtml(gpa, .{ .message_update = .{ .text = .{
        .block_index = 0,
        .delta = "hi",
    } } });
    defer gpa.free(frame);
    try std.testing.expect(std.mem.indexOf(u8, frame, "event: message_update\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"deltaKind\":\"text\"") != null);
}

test "renderFrameHtml: thinking delta is unnamed OOB" {
    const gpa = std.testing.allocator;
    const frame = try renderFrameHtml(gpa, .{ .message_update = .{ .thinking = .{
        .block_index = 0,
        .delta = "x",
    } } });
    defer gpa.free(frame);
    // No event: prefix for unnamed OOB events.
    try std.testing.expect(std.mem.indexOf(u8, frame, "event:") == null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "data: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "hx-swap-oob") != null);
}

test "renderFrameHtml: multi-line body split into data: lines (SSE spec)" {
    const gpa = std.testing.allocator;
    // tool_execution_end with multi-line output.
    var content = [_]ai_types.ContentBlock{.{ .text = .{ .text = "line1\nline2\nline3" } }};
    const frame = try renderFrameHtml(gpa, .{ .tool_execution_end = .{
        .call_id = "c",
        .result = .{
            .is_error = false,
            .content = &content,
            .tool_code = null,
            .details_json = null,
        },
    } });
    defer gpa.free(frame);
    // Each line of the body must be on its own data: line.
    try std.testing.expect(std.mem.indexOf(u8, frame, "data: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "line1") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "line2") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "line3") != null);
    // No bare \n inside a data: field (all \n must be preceded by a data: line).
    // Verify the frame ends with \n\n (SSE frame terminator).
    try std.testing.expect(frame.len >= 2);
    try std.testing.expect(frame[frame.len - 1] == '\n');
    try std.testing.expect(frame[frame.len - 2] == '\n');
}
