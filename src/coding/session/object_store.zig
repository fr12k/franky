//! Content-addressed object store — §H.4.
//!
//! Blobs ≥ `inline_threshold_bytes` (default 32 KiB) are hashed with
//! SHA-256 and written to `<store_dir>/<first-2-hex>/<remaining-62-hex>`
//! atomically. Blobs under the threshold stay inline in the transcript
//! JSON. `resolve` turns a persisted `Ref` back into bytes; `sweep`
//! walks the store dir and deletes every object not in a referenced-
//! set (basic GC).
//!
//! Scope note (v0.6.1): this module ships the primitives. Wiring them
//! into `transcript.jsonl` serialization — emitting
//! `{"$ref":"sha256:<hex>"}` when a content block is external — is a
//! follow-up sub-pass that reshapes the transcript JSON shape. The
//! primitives below are tested end-to-end on tmpdirs.

const std = @import("std");
const session_mod = @import("persistence.zig");

/// Blobs smaller than this stay inline in `transcript.jsonl`.
/// Blobs at or above this size are stored in `objects/`.
pub const inline_threshold_bytes: usize = 32 * 1024;

pub const Ref = union(enum) {
    /// Inline — bytes live in the calling slice; the store does not
    /// own them.
    inline_bytes: []const u8,
    /// External — bytes persisted to `store_dir/<shard>/<tail>` with
    /// the given lowercase-hex SHA-256.
    external: struct { hex: []const u8 },
};

/// Classify a blob and — if external — ensure it's persisted under
/// `store_dir`. Returns a `Ref` that:
///   - for inline: borrows `bytes` (caller keeps ownership)
///   - for external: owns a fresh 64-char hex string allocated on
///     `allocator`
pub fn store(
    allocator: std.mem.Allocator,
    io: std.Io,
    store_dir: []const u8,
    bytes: []const u8,
) !Ref {
    if (bytes.len < inline_threshold_bytes) {
        return .{ .inline_bytes = bytes };
    }
    const hex = try session_mod.sha256Hex(allocator, bytes);
    errdefer allocator.free(hex);
    try writeObject(allocator, io, store_dir, hex, bytes);
    return .{ .external = .{ .hex = hex } };
}

/// Resolve a Ref back to bytes. For `.inline_bytes` we return the
/// slice as-is. For `.external` we read the file under
/// `store_dir/<shard>/<tail>`; caller owns the returned allocation.
pub fn resolve(
    allocator: std.mem.Allocator,
    io: std.Io,
    store_dir: []const u8,
    ref: Ref,
) ![]u8 {
    switch (ref) {
        .inline_bytes => |b| return try allocator.dupe(u8, b),
        .external => |e| return try readObject(allocator, io, store_dir, e.hex),
    }
}

/// Sweep every object under `store_dir` whose hex is not present in
/// `keep` (a slice of 64-char hex strings). Returns the number of
/// deleted files.
pub fn sweep(
    allocator: std.mem.Allocator,
    io: std.Io,
    store_dir: []const u8,
    keep: []const []const u8,
) !usize {
    const root_path = try std.fs.path.join(allocator, &.{store_dir});
    defer allocator.free(root_path);

    var root = std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return 0,
        else => return e,
    };
    defer root.close(io);

    var deleted: usize = 0;
    var walker = try root.walk(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        // Reconstruct full hex from the entry path: two-hex/tail.
        const sep = std.mem.indexOfScalar(u8, entry.path, '/') orelse continue;
        if (sep != 2) continue;
        const prefix = entry.path[0..2];
        const tail = entry.path[sep + 1 ..];
        if (tail.len != 62) continue;
        // Concatenate into a stack buffer to dedupe against `keep`.
        var full: [64]u8 = undefined;
        @memcpy(full[0..2], prefix);
        @memcpy(full[2..], tail);

        var referenced = false;
        for (keep) |h| {
            if (h.len == 64 and std.mem.eql(u8, &full, h)) {
                referenced = true;
                break;
            }
        }
        if (!referenced) {
            const full_path = try std.fs.path.join(allocator, &.{ root_path, entry.path });
            defer allocator.free(full_path);
            std.Io.Dir.cwd().deleteFile(io, full_path) catch continue;
            deleted += 1;
        }
    }
    return deleted;
}

/// Write `bytes` to `store_dir/<hex[0..2]>/<hex[2..]>` atomically.
/// Concurrent writers of the same hash produce byte-identical files;
/// the rename is idempotent.
pub fn writeObject(
    allocator: std.mem.Allocator,
    io: std.Io,
    store_dir: []const u8,
    hex: []const u8,
    bytes: []const u8,
) !void {
    if (hex.len != 64) return error.InvalidHash;
    const shard_dir = try std.fs.path.join(allocator, &.{ store_dir, hex[0..2] });
    defer allocator.free(shard_dir);
    try std.Io.Dir.cwd().createDirPath(io, shard_dir);

    const object_path = try std.fs.path.join(allocator, &.{ shard_dir, hex[2..] });
    defer allocator.free(object_path);

    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{object_path});
    defer allocator.free(tmp_path);

    {
        var f = try std.Io.Dir.cwd().createFile(io, tmp_path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, bytes);
    }

    // Rename is atomic on POSIX; if the destination already exists
    // with byte-identical content (same hash ⇒ same bytes by the
    // content-addressed invariant), the overwrite is a no-op from
    // the reader's perspective.
    const cwd = std.Io.Dir.cwd();
    try cwd.rename(tmp_path, cwd, object_path, io);
}

pub fn readObject(
    allocator: std.mem.Allocator,
    io: std.Io,
    store_dir: []const u8,
    hex: []const u8,
) ![]u8 {
    if (hex.len != 64) return error.InvalidHash;
    const object_path = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ store_dir, hex[0..2], hex[2..] });
    defer allocator.free(object_path);

    var f = try std.Io.Dir.cwd().openFile(io, object_path, .{});
    defer f.close(io);
    const len = try f.length(io);
    const buf = try allocator.alloc(u8, @intCast(len));
    const n = try f.readPositionalAll(io, buf, 0);
    return buf[0..n];
}

// ─── tests ────────────────────────────────────────────────────────

const testing = std.testing;
const test_h = @import("../../test_helpers.zig");

test "store: small blob returned inline" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const base = "/tmp/franky_objstore_small";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, base);

    const small = "tiny blob";
    const ref = try store(testing.allocator, io, base, small);
    switch (ref) {
        .inline_bytes => |b| try testing.expectEqualStrings(small, b),
        .external => try testing.expect(false),
    }
}

test "store: boundary 32767 bytes stays inline" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const base = "/tmp/franky_objstore_bound_lo";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, base);

    const gpa = testing.allocator;
    const buf = try gpa.alloc(u8, inline_threshold_bytes - 1);
    defer gpa.free(buf);
    @memset(buf, 'a');

    const ref = try store(gpa, io, base, buf);
    switch (ref) {
        .inline_bytes => {},
        .external => try testing.expect(false),
    }
}

test "store: boundary 32768 bytes is external" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const base = "/tmp/franky_objstore_bound_hi";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, base);

    const gpa = testing.allocator;
    const buf = try gpa.alloc(u8, inline_threshold_bytes);
    defer gpa.free(buf);
    @memset(buf, 'b');

    const ref = try store(gpa, io, base, buf);
    switch (ref) {
        .inline_bytes => try testing.expect(false),
        .external => |e| {
            defer gpa.free(e.hex);
            try testing.expectEqual(@as(usize, 64), e.hex.len);
            // Resolve round-trip.
            const round = try resolve(gpa, io, base, ref);
            defer gpa.free(round);
            try testing.expectEqualSlices(u8, buf, round);
        },
    }
}

test "shard: first-2-hex / remaining-62-hex file layout on disk" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const base = "/tmp/franky_objstore_shard";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, base);

    const gpa = testing.allocator;
    const buf = try gpa.alloc(u8, inline_threshold_bytes + 4);
    defer gpa.free(buf);
    @memset(buf, 'c');

    const ref = try store(gpa, io, base, buf);
    defer switch (ref) {
        .external => |e| gpa.free(e.hex),
        else => {},
    };
    const hex = switch (ref) {
        .external => |e| e.hex,
        else => unreachable,
    };

    // File exists at the exact spec path.
    const expected_path = try std.fmt.allocPrint(gpa, "{s}/{s}/{s}", .{ base, hex[0..2], hex[2..] });
    defer gpa.free(expected_path);
    var f = try std.Io.Dir.cwd().openFile(io, expected_path, .{});
    f.close(io);
}

test "store: dedupes byte-identical writers (idempotent rename)" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const base = "/tmp/franky_objstore_dedupe";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, base);

    const gpa = testing.allocator;
    const buf = try gpa.alloc(u8, inline_threshold_bytes);
    defer gpa.free(buf);
    @memset(buf, 'd');

    const ref1 = try store(gpa, io, base, buf);
    defer switch (ref1) {
        .external => |e| gpa.free(e.hex),
        else => {},
    };
    const ref2 = try store(gpa, io, base, buf);
    defer switch (ref2) {
        .external => |e| gpa.free(e.hex),
        else => {},
    };

    // Same hash, same file on disk, no error from the second write.
    const hex1 = switch (ref1) {
        .external => |e| e.hex,
        else => unreachable,
    };
    const hex2 = switch (ref2) {
        .external => |e| e.hex,
        else => unreachable,
    };
    try testing.expectEqualStrings(hex1, hex2);
}

test "sweep: GC removes unreferenced objects" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const base = "/tmp/franky_objstore_sweep";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, base);

    const gpa = testing.allocator;

    // Two distinct blobs, both external.
    const a = try gpa.alloc(u8, inline_threshold_bytes);
    defer gpa.free(a);
    @memset(a, 'A');
    const b = try gpa.alloc(u8, inline_threshold_bytes);
    defer gpa.free(b);
    @memset(b, 'B');

    const ref_a = try store(gpa, io, base, a);
    defer switch (ref_a) {
        .external => |e| gpa.free(e.hex),
        else => {},
    };
    const ref_b = try store(gpa, io, base, b);
    defer switch (ref_b) {
        .external => |e| gpa.free(e.hex),
        else => {},
    };

    const hex_a = switch (ref_a) {
        .external => |e| e.hex,
        else => unreachable,
    };

    // Sweep keeping only `a`. Expect 1 deletion (b).
    const keep = [_][]const u8{hex_a};
    const deleted = try sweep(gpa, io, base, &keep);
    try testing.expectEqual(@as(usize, 1), deleted);

    // `a` still resolves; `b`'s file is gone.
    const round_a = try readObject(gpa, io, base, hex_a);
    defer gpa.free(round_a);
    try testing.expectEqualSlices(u8, a, round_a);

    const hex_b = switch (ref_b) {
        .external => |e| e.hex,
        else => unreachable,
    };
    const err = readObject(gpa, io, base, hex_b);
    try testing.expectError(error.FileNotFound, err);
}

// ─── v1.6.1 — coverage gap fills ─────────────────────────────────

test "readObject: non-64 hex → InvalidHash" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const err = readObject(testing.allocator, io, "/tmp/franky_objstore_ignored", "abc");
    try testing.expectError(error.InvalidHash, err);
}

test "writeObject: non-64 hex → InvalidHash" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const err = writeObject(testing.allocator, io, "/tmp/franky_objstore_ignored", "abc", "x");
    try testing.expectError(error.InvalidHash, err);
}

test "sweep: missing store dir is a no-op (0 deletions)" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const base = "/tmp/franky_objstore_missing";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};

    const deleted = try sweep(testing.allocator, io, base, &.{});
    try testing.expectEqual(@as(usize, 0), deleted);
}

test "store: zero-length input stays inline" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const base = "/tmp/franky_objstore_zero";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, base);

    const ref = try store(testing.allocator, io, base, "");
    switch (ref) {
        .inline_bytes => |b| try testing.expectEqual(@as(usize, 0), b.len),
        .external => try testing.expect(false),
    }
}
