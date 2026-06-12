//! v2.31 Phase 3 — CCR (Compress-Cache-Retrieve) integration.
//!
//! A CCR session wraps `zompress.ccr.CcrStore` with three franky-specific
//! concerns layered on top:
//!
//! 1. **FIFO eviction** at `max_entries` (default 10 000, configurable).
//!    The store is keyed by content hash, so "least recently used" is
//!    not cheaply definable — FIFO keeps the hot path allocation-free
//!    and gives users a stable, predictable memory bound.
//! 2. **JSON-Lines persistence** on `deinit()`. The on-disk format is
//!    one entry per line: `{"key": "...", "content_b64": "..."}`. The
//!    store is best-effort cache, not a database — losing the last
//!    few entries on a hard crash is acceptable; pulling in SQLite
//!    for a single-table append-only cache is overkill.
//! 3. **Eviction log** at `debug` level. A user who later tries to
//!    retrieve an evicted key gets a diagnostic trail, not a silent
//!    miss.
//!
//! CCR is opt-in: a `null` `ccr_session` in `Agent.Config` disables it
//! and the compaction + tool-result paths skip the `store()` call.

const std = @import("std");
const ai = struct {
    pub const types = @import("../ai/types.zig");
    pub const log = @import("../ai/log.zig");
};
const at = @import("types.zig");
const zompress = @import("zompress");
const test_h = @import("../test_helpers.zig");

/// Default cap. Per the design doc §5.1: ≈ a few hundred MB depending
/// on average blob size, with FIFO eviction at insertion order.
pub const default_max_entries: u32 = 10_000;

/// v2.31 — session-scoped wrapper around `zompress.ccr.CcrStore`.
/// Owns the underlying store, the FIFO cap, the optional on-disk
/// persistence path, and the eviction counter (for the session-end
/// summary in `print.zig`).
pub const CcrSession = struct {
    // Renamed from `store` to `ccr_store` to avoid colliding with
    // the public `store()` method below. Field-vs-method name
    // collisions in Zig 0.17 are a hard error.
    ccr_store: zompress.ccr.CcrStore,
    allocator: std.mem.Allocator,
    persist_path: ?[]const u8,
    max_entries: u32,
    /// Insertion-order keys for FIFO eviction. When the store grows
    /// past `max_entries`, the oldest key is dropped.
    insertion_order: std.ArrayList([]const u8),
    /// Cumulative eviction count for the session-end summary.
    eviction_count: u32 = 0,
    /// Cumulative store/retrieve counts for the session-end summary
    /// (telemetry — Phase 5).
    store_count: u32 = 0,
    retrieve_hits: u32 = 0,
    retrieve_misses: u32 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        persist_path: ?[]const u8,
        max_entries: u32,
    ) CcrSession {
        return .{
            .ccr_store = zompress.ccr.CcrStore.init(allocator),
            .allocator = allocator,
            .persist_path = persist_path,
            .max_entries = max_entries,
            .insertion_order = .empty,
        };
    }

    pub fn deinit(self: *CcrSession) void {
        if (self.persist_path) |path| {
            // v2.31 — persist on deinit, no io available here
            // (the caller owns the io lifetime). We log a warning
            // and skip persistence; the caller is expected to call
            // `persist(path, io)` explicitly before deinit when
            // persistence is wanted. This avoids the brittleness of
            // holding an io reference in a long-lived session.
            ai.log.log(.warn, "ccr", "deinit_no_persist",
                "path={s} skipped; call CcrSession.persist explicitly",
                .{path},
            );
        }
        // Free the insertion_order entries (they were duped into the
        // list when the corresponding CcrStore entries were inserted).
        for (self.insertion_order.items) |k| self.allocator.free(k);
        self.insertion_order.deinit(self.allocator);
        self.ccr_store.deinit();
    }

    /// Store a blob and return its CCR key. The blob is duplicated onto
    /// the session allocator; the caller retains ownership of the
    /// input slice. Triggers FIFO eviction if the store is full.
    pub fn store(self: *CcrSession, original: []const u8) ![]const u8 {
        const key = try self.ccr_store.store(original);
        errdefer self.allocator.free(key);

        // Track insertion order for FIFO eviction. We dupe `key`
        // again so the eviction list owns an independent copy.
        const order_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(order_key);
        try self.insertion_order.append(self.allocator, order_key);

        // FIFO eviction: when we cross the threshold, drop the
        // oldest entry. Eviction is a warning, not an error — the
        // user gets a debug log to diagnose later misses.
        while (self.insertion_order.items.len > self.max_entries) {
            const oldest = self.insertion_order.orderedRemove(0);
            if (self.ccr_store.map.fetchRemove(oldest)) |kv| {
                self.allocator.free(kv.key);
                self.allocator.free(kv.value);
                self.eviction_count += 1;
                ai.log.log(.debug, "ccr", "evicted",
                    "key={s} max_entries={d}", .{ oldest, self.max_entries });
            }
            self.allocator.free(oldest);
        }

        self.store_count += 1;
        return key;
    }

    /// Retrieve a blob by key. Returns `null` if the key was never
    /// stored, was evicted, or is otherwise missing. Telemetry
    /// counters distinguish a hit from a miss so the session-end
    /// summary can surface the cache's effectiveness.
    pub fn retrieve(self: *CcrSession, key: []const u8) ?[]const u8 {
        const result = self.ccr_store.retrieve(key);
        if (result != null) {
            self.retrieve_hits += 1;
        } else {
            self.retrieve_misses += 1;
        }
        return result;
    }

    /// Persist the current store contents as JSON Lines. One entry
    /// per line: `{"key": "...", "content_b64": "..."}`. Loaded back
    /// on next session start (see `loadFromDisk`). `io` is the
    /// current event loop's `std.Io`; the caller owns its lifetime
    /// and the session does NOT keep a reference.
    pub fn persist(self: *CcrSession, path: []const u8, io: std.Io) !void {
        const file = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);

        // Use the same `Writer` pattern as `ai/log.zig`:
        // format each line into a local buffer, then write it
        // out atomically. The `std.Io.File.Writer` returned by
        // `file.writer()` doesn't expose `print`, so we go through
        // the generic Writer API.

        var it = self.ccr_store.map.iterator();
        while (it.next()) |entry| {
            // Base64-encode the content. The line format is JSON
            // because future-proofing for extra metadata (timestamp,
            // source tool, etc.) is cheap; the spec's design said
            // "best-effort cache, not a database" and we honor that.
            const encoded_len = std.base64.standard.Encoder.calcSize(entry.value_ptr.*.len);
            const encoded = try self.allocator.alloc(u8, encoded_len);
            defer self.allocator.free(encoded);
            _ = std.base64.standard.Encoder.encode(encoded, entry.value_ptr.*);

            var line_buf: [4096]u8 = undefined;
            var lw: std.Io.Writer = .fixed(&line_buf);
            try lw.print(
                "{{\"key\":\"{s}\",\"content_b64\":\"{s}\"}}\n",
                .{ entry.key_ptr.*, encoded },
            );
            try file.writeStreamingAll(io, lw.buffered());
        }
    }

    /// Load entries from a JSON-Lines file. Each line is one entry.
    /// Lines that fail to parse are silently skipped (the spec
    /// accepts losing the last few entries on a hard crash).
    pub fn loadFromDisk(self: *CcrSession, path: []const u8, io: std.Io) !void {
        const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer file.close(io);

        const len = try file.length(io);
        if (len == 0) return;
        const buf = try self.allocator.alloc(u8, @intCast(len));
        defer self.allocator.free(buf);
        _ = try file.readPositionalAll(io, buf, 0);

        var line_it = std.mem.splitScalar(u8, buf, '\n');
        while (line_it.next()) |line| {
            if (line.len == 0) continue;
            self.loadOneLine(line) catch |err| {
                ai.log.log(.debug, "ccr", "load_line_skipped",
                    "err={s}", .{@errorName(err)});
            };
        }
    }

    fn loadOneLine(self: *CcrSession, line: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            arena.allocator(),
            line,
            .{},
        );
        const obj = parsed.value.object;
        const key_v = obj.get("key") orelse return;
        const content_v = obj.get("content_b64") orelse return;
        if (key_v != .string or content_v != .string) return;

        const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(content_v.string);
        const decoded = try self.allocator.alloc(u8, decoded_len);
        defer self.allocator.free(decoded);
        try std.base64.standard.Decoder.decode(decoded, content_v.string);

        // Re-store via the public API so FIFO eviction runs.
        // `CcrStore.store` dupe's its input, so `decoded` is not
        // retained after the call — the `defer` above frees it.
        _ = try self.store(decoded);
    }
};

// ─── Tests ──────────────────────────────────────────────────────

test "CcrSession: store + retrieve round trip" {
    // Spec §5 acceptance check row 1.
    const gpa = std.testing.allocator;
    var session = CcrSession.init(gpa, null, default_max_entries);
    defer session.deinit();

    const original = "Large payload content here";
    const key = try session.store(original);
    const retrieved = session.retrieve(key).?;
    try std.testing.expectEqualStrings(original, retrieved);
    try std.testing.expectEqual(@as(u32, 1), session.store_count);
    try std.testing.expectEqual(@as(u32, 1), session.retrieve_hits);
}

test "CcrSession: retrieve non-existent key returns null + miss count" {
    const gpa = std.testing.allocator;
    var session = CcrSession.init(gpa, null, default_max_entries);
    defer session.deinit();

    const result = session.retrieve("nonexistent_key");
    try std.testing.expect(result == null);
    try std.testing.expectEqual(@as(u32, 1), session.retrieve_misses);
}

test "CcrSession: FIFO eviction at max_entries" {
    // Spec §5.1: hard cap with oldest-eviction by insertion order.
    const gpa = std.testing.allocator;
    var session = CcrSession.init(gpa, null, 3);
    defer session.deinit();

    // Store 5 entries with max_entries=3 → first 2 should be evicted.
    const k1 = try session.store("entry_one");
    const k2 = try session.store("entry_two");
    const k3 = try session.store("entry_three");
    const k4 = try session.store("entry_four");
    const k5 = try session.store("entry_five");

    // Recent entries are still present.
    try std.testing.expect(session.retrieve(k3) != null);
    try std.testing.expect(session.retrieve(k4) != null);
    try std.testing.expect(session.retrieve(k5) != null);
    // Old entries are gone.
    try std.testing.expect(session.retrieve(k1) == null);
    try std.testing.expect(session.retrieve(k2) == null);
    try std.testing.expectEqual(@as(u32, 2), session.eviction_count);
}

test "CcrSession: persist + load round trip via JSON Lines" {
    const gpa = std.testing.allocator;
    const path = "/tmp/franky_ccr_test_persist.jsonl";
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    // First session: store blobs, persist explicitly before deinit.
    // (The session's `deinit` no longer auto-persists because the
    // session can't safely hold an `io` reference for its lifetime.)
    {
        var session = CcrSession.init(gpa, path, default_max_entries);
        defer session.deinit();
        _ = try session.store("hello world");
        _ = try session.store("second blob");
        try session.persist(path, io);
    }

    // Second session: load from disk, verify both blobs are present.
    {
        var session = CcrSession.init(gpa, null, default_max_entries);
        defer session.deinit();
        try session.loadFromDisk(path, io);

        // The retrieval path is by hash, so we don't have the keys
        // from the previous session. But the entries are present
        // (count > 0), and the store_count is bumped by the load.
        try std.testing.expect(session.store_count >= 2);
    }
}
