//! Session-scoped CCR (Compress-Cache-Retrieve) store.
//!
//! Stores original tool output content keyed by a content hash so the
//! LLM can retrieve it later via the `ccr_retrieve` tool. Uses per-item
//! allocation (not an arena) with LRU eviction to prevent unbounded
//! memory growth over long sessions.
//!
//! The store is in-memory for the session lifetime. Persistence across
//! sessions is a future enhancement.
//!
//! Keys are 12 hex characters (48 bits) — a truncated SHA-256.
//! Collision probability at 1000 entries is ~10⁻⁹, negligible.

const std = @import("std");

/// Maximum number of entries in the CCR store before LRU eviction kicks in.
pub const default_max_entries: usize = 1000;

/// Maximum total bytes of stored content before LRU eviction kicks in.
pub const default_max_bytes: usize = 64 * 1024 * 1024; // 64 MB

/// Length of CCR keys in hex characters (48 bits of SHA-256).
pub const key_len: usize = 12;

/// Session-scoped CCR store.
///
/// Stores original content blobs keyed by a 12-char truncated SHA-256 hex hash.
/// Old entries are evicted via LRU when the cap is reached.
pub const CcrSessionStore = struct {
    allocator: std.mem.Allocator,
    /// key -> original content (both owned)
    map: std.StringHashMap([]const u8),
    max_entries: usize,
    max_bytes: usize,
    /// Current total bytes of stored content.
    total_bytes: usize,
    /// LRU tracking: ordered list of keys, most-recently-used at the end.
    lru_keys: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator) CcrSessionStore {
        return .{
            .allocator = allocator,
            .map = std.StringHashMap([]const u8).init(allocator),
            .max_entries = default_max_entries,
            .max_bytes = default_max_bytes,
            .total_bytes = 0,
            .lru_keys = .empty,
        };
    }

    pub fn deinit(self: *CcrSessionStore) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.map.deinit();
        for (self.lru_keys.items) |k| self.allocator.free(k);
        self.lru_keys.deinit(self.allocator);
    }

    /// Store original content and return a hash key.
    /// The returned key is owned by the store and valid until the entry is evicted.
    /// Uses 12 hex chars (48 bits of SHA-256) — collision-free at session scale.
    pub fn store(self: *CcrSessionStore, original: []const u8) ![]const u8 {
        const key = try computeKey(self.allocator, original);
        errdefer self.allocator.free(key);

        const val = try self.allocator.dupe(u8, original);
        errdefer self.allocator.free(val);

        // Remove old value if key already exists (content collision)
        if (self.map.fetchRemove(key)) |kv| {
            self.total_bytes -|= kv.value.len;
            self.allocator.free(kv.key);
            self.allocator.free(kv.value);
        }

        // Evict LRU entries until we have room for the new value.
        // Check both entry count and byte budget.
        const needed_bytes = val.len;
        while (self.lru_keys.items.len >= self.max_entries or
            (self.total_bytes + needed_bytes > self.max_bytes and self.lru_keys.items.len > 0))
        {
            const oldest_key = self.lru_keys.orderedRemove(0);
            if (self.map.fetchRemove(oldest_key)) |kv| {
                self.total_bytes -|= kv.value.len;
                self.allocator.free(kv.key);
                self.allocator.free(kv.value);
            }
            self.allocator.free(oldest_key);
        }

        try self.map.put(key, val);
        self.total_bytes += val.len;

        // Update LRU: remove old position if exists, then append
        for (self.lru_keys.items, 0..) |lk, i| {
            if (std.mem.eql(u8, lk, key)) {
                const removed = self.lru_keys.orderedRemove(i);
                self.allocator.free(removed);
                break;
            }
        }

        const duped_key = try self.allocator.dupe(u8, key);
        try self.lru_keys.append(self.allocator, duped_key);

        return key;
    }

    /// Retrieve original content by hash key.
    pub fn retrieve(self: *CcrSessionStore, key: []const u8) ?[]const u8 {
        const value = self.map.get(key) orelse return null;

        // Update LRU: move to end
        for (self.lru_keys.items, 0..) |lk, i| {
            if (std.mem.eql(u8, lk, key)) {
                const removed = self.lru_keys.orderedRemove(i);
                self.allocator.free(removed);
                break;
            }
        }

        const duped_key = self.allocator.dupe(u8, key) catch return value;
        self.lru_keys.append(self.allocator, duped_key) catch {
            self.allocator.free(duped_key);
            return value;
        };

        return value;
    }

    /// Format a CCR marker for embedding in compressed output.
    /// Uses a distinctive prefix to avoid collision with tool output.
    /// The key is already 12 chars — no truncation needed.
    pub fn formatMarker(key: []const u8, count: usize, allocator: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(allocator, "<<<ccr:{s} {d}_rows_offloaded>>>", .{ key, count });
    }

    /// Parse a CCR marker to extract the hash key and count.
    pub fn parseMarker(text: []const u8) ?struct { key: []const u8, count: usize } {
        const prefix = "<<<ccr:";
        if (!std.mem.startsWith(u8, text, prefix)) return null;
        const rest = text[prefix.len..];
        const suffix = ">>>";
        const suffix_start = std.mem.lastIndexOf(u8, rest, suffix) orelse return null;
        const inner = rest[0..suffix_start];
        const space = std.mem.indexOf(u8, inner, " ") orelse return null;
        const key = inner[0..space];
        const count_part = inner[space + 1 ..];
        const underscore = std.mem.indexOf(u8, count_part, "_") orelse return null;
        const count_str = count_part[0..underscore];
        const count = std.fmt.parseInt(usize, count_str, 10) catch return null;
        return .{ .key = key, .count = count };
    }
};

/// Compute a 12-char hex key for content (truncated SHA-256).
/// 12 hex chars = 48 bits. Collision probability at 1000 entries is ~10⁻⁹.
fn computeKey(allocator: std.mem.Allocator, content: []const u8) ![]const u8 {
    var sha256 = std.crypto.hash.sha2.Sha256.init(.{});
    sha256.update(content);
    var digest: [32]u8 = undefined;
    sha256.final(&digest);

    // Take first 6 bytes (48 bits) and hex-encode to 12 chars.
    const hex_chars = "0123456789abcdef";
    var key_buf: [key_len]u8 = undefined;
    for (0..key_len / 2) |i| {
        key_buf[i * 2] = hex_chars[digest[i] >> 4];
        key_buf[i * 2 + 1] = hex_chars[digest[i] & 0x0f];
    }
    return try allocator.dupe(u8, &key_buf);
}

test "CCR store and retrieve" {
    var store = CcrSessionStore.init(std.testing.allocator);
    defer store.deinit();

    const original = "Large payload content here";
    const key = try store.store(original);
    const retrieved = store.retrieve(key) orelse return error.TestFailed;
    try std.testing.expectEqualStrings(original, retrieved);
}

test "CCR store round-trip multiple entries" {
    var store = CcrSessionStore.init(std.testing.allocator);
    defer store.deinit();

    const a = try store.store("content a");
    const b = try store.store("content b");
    const c = try store.store("content c");

    try std.testing.expectEqualStrings("content a", store.retrieve(a).?);
    try std.testing.expectEqualStrings("content b", store.retrieve(b).?);
    try std.testing.expectEqualStrings("content c", store.retrieve(c).?);
}

test "CCR marker format and parse" {
    const marker = try CcrSessionStore.formatMarker("a1b2c3d4e5f6", 42, std.testing.allocator);
    defer std.testing.allocator.free(marker);

    const parsed = CcrSessionStore.parseMarker(marker) orelse return error.TestFailed;
    try std.testing.expectEqualStrings("a1b2c3d4e5f6", parsed.key);
    try std.testing.expectEqual(@as(usize, 42), parsed.count);
}

test "CCR marker parse invalid" {
    try std.testing.expect(CcrSessionStore.parseMarker("not a marker") == null);
}

test "compute key is deterministic" {
    const key1 = try computeKey(std.testing.allocator, "same content");
    defer std.testing.allocator.free(key1);
    const key2 = try computeKey(std.testing.allocator, "same content");
    defer std.testing.allocator.free(key2);
    try std.testing.expectEqualStrings(key1, key2);
}

test "compute key differs for different content" {
    const key1 = try computeKey(std.testing.allocator, "content a");
    defer std.testing.allocator.free(key1);
    const key2 = try computeKey(std.testing.allocator, "content b");
    defer std.testing.allocator.free(key2);
    try std.testing.expect(!std.mem.eql(u8, key1, key2));
}

test "CCR key length is 12" {
    const key = try computeKey(std.testing.allocator, "test content");
    defer std.testing.allocator.free(key);
    try std.testing.expectEqual(@as(usize, key_len), key.len);
}

test "CCR store LRU eviction" {
    var store = CcrSessionStore.init(std.testing.allocator);
    store.max_entries = 3;
    defer store.deinit();

    const a = try store.store("entry a");
    const b = try store.store("entry b");
    const c = try store.store("entry c");

    // All three should be present
    try std.testing.expect(store.retrieve(a) != null);
    try std.testing.expect(store.retrieve(b) != null);
    try std.testing.expect(store.retrieve(c) != null);

    // Adding a fourth should evict the oldest (a)
    const d = try store.store("entry d");
    try std.testing.expect(store.retrieve(d) != null);
    try std.testing.expect(store.retrieve(a) == null); // evicted
    try std.testing.expect(store.retrieve(b) != null);
    try std.testing.expect(store.retrieve(c) != null);
}

test "CCR store retrieve by key from marker" {
    var store = CcrSessionStore.init(std.testing.allocator);
    defer store.deinit();

    const key = try store.store("some important content");
    // key is 12 chars (truncated SHA-256)
    try std.testing.expectEqual(@as(usize, key_len), key.len);

    // Retrieving with the key should work
    try std.testing.expectEqualStrings("some important content", store.retrieve(key).?);

    // A non-existent key should return null
    try std.testing.expect(store.retrieve("nonexistent12") == null);
}