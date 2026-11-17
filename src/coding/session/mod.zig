//! Session persistence — §H of the spec.
//!
//! Types + convenience save/load on top of the I/O layer
//! (`persistence.zig`). Re-exports every public symbol from
//! persistence so external consumers don't need to know about
//! the file split.

const std = @import("std");
const builtin = @import("builtin");
const ai = struct {
    pub const types = @import("../../ai/types.zig");
};
const agent_mod = @import("../../agent/mod.zig");
const object_store = @import("object_store.zig");

const p = @import("persistence.zig");

pub const current_session_version = p.current_session_version;
pub const current_transcript_version = p.current_transcript_version;
pub const Ulid = p.Ulid;
pub const SessionHeader = p.SessionHeader;
pub const newUlid = p.newUlid;
pub const writeSessionHeader = p.writeSessionHeader;
pub const readSessionHeader = p.readSessionHeader;
pub const freeSessionHeader = p.freeSessionHeader;
pub const writeTranscript = p.writeTranscript;
pub const readTranscript = p.readTranscript;
pub const writeBranchTranscript = p.writeBranchTranscript;
pub const readBranchTranscript = p.readBranchTranscript;
pub const sha256Hex = p.sha256Hex;
pub const appendContentBlockJson = p.appendContentBlockJson;
pub const atomicWrite = p.atomicWrite;
pub const readWholeFile = p.readWholeFile;
pub const crockford = p.crockford;
pub const SessionMigrationError = p.SessionMigrationError;
pub const MigratedSession = p.MigratedSession;
pub const migrateSessionIfNeeded = p.migrateSessionIfNeeded;
pub const assertRefsInKeep = p.assertRefsInKeep;

// ─── Session factory (§3.2) ────────────────────────────────────────
pub const create = @import("create.zig");
pub const SessionState = create.SessionState;
pub const ProviderInfo = create.ProviderInfo;

/// Convenience: top-level save/load.

pub const Session = struct {
    header: SessionHeader,
    transcript: agent_mod.loop.Transcript,

    pub fn deinit(self: *Session, allocator: std.mem.Allocator) void {
        freeSessionHeader(allocator, self.header);
        self.transcript.deinit();
    }
};

/// Write both `session.json` and `transcript.jsonl` atomically under
/// `<parent_dir>/<session_id>/`. The directory is created if missing.
pub fn save(
    allocator: std.mem.Allocator,
    io: std.Io,
    parent_dir: []const u8,
    header: SessionHeader,
    transcript: *const agent_mod.loop.Transcript,
) !void {
    const session_dir = try std.fs.path.join(allocator, &.{ parent_dir, header.id });
    defer allocator.free(session_dir);

    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, session_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };

    try writeSessionHeader(allocator, io, session_dir, header);
    try writeTranscript(allocator, io, session_dir, transcript, header.active_branch);
}

/// Load a session from `<parent_dir>/<session_id>/`. Caller owns the
/// returned `Session`.
pub fn load(
    allocator: std.mem.Allocator,
    io: std.Io,
    parent_dir: []const u8,
    session_id: []const u8,
) !Session {
    const session_dir = try std.fs.path.join(allocator, &.{ parent_dir, session_id });
    defer allocator.free(session_dir);

    const header = try readSessionHeader(allocator, io, session_dir);
    errdefer freeSessionHeader(allocator, header);
    const transcript = try readTranscript(allocator, io, session_dir);
    return .{ .header = header, .transcript = transcript };
}

// ─── tests ────────────────────────────────────────────────────────

const testing = std.testing;
const test_h = @import("../../test_helpers.zig");


test "ULID renders 26 Crockford-base32 chars" {
    var prng = std.Random.DefaultPrng.init(0);
    const u = newUlid(0x0192345678, prng.random());
    try testing.expectEqual(@as(usize, 26), u.asSlice().len);
    for (u.asSlice()) |c| {
        const in_set = std.mem.indexOfScalar(u8, crockford, c) != null;
        try testing.expect(in_set);
    }
}

test "session round-trips through disk" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_session_test";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};

    try std.Io.Dir.cwd().createDirPath(io, base);

    var transcript = agent_mod.loop.Transcript.init(gpa);
    defer transcript.deinit();

    {
        const content = try gpa.alloc(ai.types.ContentBlock, 1);
        content[0] = .{ .text = .{ .text = try gpa.dupe(u8, "hi") } };
        try transcript.append(.{ .role = .user, .content = content, .timestamp = 1000 });
    }
    {
        const content = try gpa.alloc(ai.types.ContentBlock, 2);
        content[0] = .{ .text = .{ .text = try gpa.dupe(u8, "let me help") } };
        content[1] = .{ .tool_call = .{
            .id = try gpa.dupe(u8, "tc1"),
            .name = try gpa.dupe(u8, "echo"),
            .arguments_json = try gpa.dupe(u8, "{\"msg\":\"hi\"}"),
        } };
        try transcript.append(.{
            .role = .assistant,
            .content = content,
            .timestamp = 1500,
            .stop_reason = .tool_use,
            .provider = try gpa.dupe(u8, "faux"),
            .model = try gpa.dupe(u8, "faux-1"),
            .api = try gpa.dupe(u8, "faux"),
        });
    }

    const header = SessionHeader{
        .id = "01JXTEST",
        .created_at_ms = 1000,
        .updated_at_ms = 2000,
        .title = "test session",
        .provider = "faux",
        .model = "faux-1",
        .api = "faux",
        .thinking_level = "off",
    };

    try save(gpa, io, base, header, &transcript);

    var loaded = try load(gpa, io, base, "01JXTEST");
    defer loaded.deinit(gpa);

    try testing.expectEqualStrings("test session", loaded.header.title);
    try testing.expectEqualStrings("faux", loaded.header.provider);
    try testing.expectEqual(@as(usize, 2), loaded.transcript.messages.items.len);

    const m0 = loaded.transcript.messages.items[0];
    try testing.expectEqual(ai.types.Role.user, m0.role);
    try testing.expectEqualStrings("hi", m0.content[0].text.text);

    const m1 = loaded.transcript.messages.items[1];
    try testing.expectEqual(ai.types.Role.assistant, m1.role);
    try testing.expectEqual(@as(usize, 2), m1.content.len);
    try testing.expectEqualStrings("let me help", m1.content[0].text.text);
    try testing.expectEqualStrings("echo", m1.content[1].tool_call.name);
    try testing.expectEqual(ai.types.StopReason.tool_use, m1.stop_reason.?);
}

test "migrateSessionIfNeeded: v1 → current backs up + rewrites" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_mig_v1";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, base);

    const v1_json =
        \\{"version":1,"id":"01J000","createdAtMs":100,"updatedAtMs":100,"title":"t","provider":"faux","model":"faux-1","api":"faux","thinkingLevel":"off"}
    ;
    const path = try std.fs.path.join(gpa, &.{ base, "session.json" });
    defer gpa.free(path);
    {
        var f = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, v1_json);
    }

    const r = try migrateSessionIfNeeded(gpa, io, base);
    try testing.expectEqual(@as(u32, 1), r.original_version);
    try testing.expectEqual(current_session_version, r.current_version);
    try testing.expect(r.migrated);

    const bak_path = try std.fmt.allocPrint(gpa, "{s}.bak", .{path});
    defer gpa.free(bak_path);
    const bak_bytes = try readWholeFile(gpa, io, bak_path);
    defer gpa.free(bak_bytes);
    try testing.expectEqualStrings(v1_json, bak_bytes);

    const new_bytes = try readWholeFile(gpa, io, path);
    defer gpa.free(new_bytes);
    const expected_version = try std.fmt.allocPrint(gpa, "\"version\": {d}", .{current_session_version});
    defer gpa.free(expected_version);
    try testing.expect(std.mem.indexOf(u8, new_bytes, expected_version) != null);
}

test "migrateSessionIfNeeded: same-version session is a no-op" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_mig_current";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, base);

    const header: SessionHeader = .{
        .id = "01J001",
        .created_at_ms = 1,
        .updated_at_ms = 1,
        .title = "t",
        .provider = "faux",
        .model = "faux-1",
        .api = "faux",
        .thinking_level = "off",
    };
    try writeSessionHeader(gpa, io, base, header);

    const r = try migrateSessionIfNeeded(gpa, io, base);
    try testing.expectEqual(current_session_version, r.original_version);
    try testing.expect(!r.migrated);

    const bak_path = try std.fs.path.join(gpa, &.{ base, "session.json.bak" });
    defer gpa.free(bak_path);
    const err = std.Io.Dir.cwd().openFile(io, bak_path, .{});
    try testing.expectError(error.FileNotFound, err);
}

test "migrateSessionIfNeeded: future version rejected" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_mig_future";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, base);

    const future_json =
        \\{"version":999,"id":"01J999","createdAtMs":0,"updatedAtMs":0,"title":"t","provider":"faux","model":"faux-1","api":"faux","thinkingLevel":"off"}
    ;
    const path = try std.fs.path.join(gpa, &.{ base, "session.json" });
    defer gpa.free(path);
    {
        var f = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, future_json);
    }

    const err = migrateSessionIfNeeded(gpa, io, base);
    try testing.expectError(SessionMigrationError.UnsupportedSessionVersion, err);
}

test "sha256Hex produces 64-char lowercase hex" {
    const gpa = testing.allocator;
    const hex = try sha256Hex(gpa, "hello");
    defer gpa.free(hex);
    try testing.expectEqual(@as(usize, 64), hex.len);
    try testing.expectEqualStrings("2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824", hex);
}

// ─── v1.5.0 — $ref round-trip via object_store ────────────────────

test "transcript: small block stays inline; objects/ dir stays empty" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_refsmall";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, base);

    var transcript = agent_mod.loop.Transcript.init(gpa);
    defer transcript.deinit();
    const content = try gpa.alloc(ai.types.ContentBlock, 1);
    content[0] = .{ .text = .{ .text = try gpa.dupe(u8, "hi") } };
    try transcript.append(.{ .role = .user, .content = content, .timestamp = 1 });

    const header = SessionHeader{
        .id = "01JXSMALL",
        .created_at_ms = 1,
        .updated_at_ms = 1,
        .title = "s",
        .provider = "faux",
        .model = "faux-1",
        .api = "faux",
        .thinking_level = "off",
    };
    try save(gpa, io, base, header, &transcript);

    const t_path = try std.fmt.allocPrint(gpa, "{s}/01JXSMALL/transcript.jsonl", .{base});
    defer gpa.free(t_path);
    const t_bytes = try readWholeFile(gpa, io, t_path);
    defer gpa.free(t_bytes);
    try testing.expect(std.mem.indexOf(u8, t_bytes, "\"text\":\"hi\"") != null);
    try testing.expect(std.mem.indexOf(u8, t_bytes, "\"type\":\"ref\"") == null);

    const obj_path = try std.fmt.allocPrint(gpa, "{s}/01JXSMALL/objects", .{base});
    defer gpa.free(obj_path);
    if (std.Io.Dir.cwd().openDir(io, obj_path, .{ .iterate = true })) |*d_const| {
        var d = d_const.*;
        defer d.close(io);
        var it = d.iterate();
        const entry = try it.next(io);
        try testing.expect(entry == null);
    } else |_| {}
}

test "transcript: 32 KiB block externalized and round-trips through $ref" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_reflarge";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, base);

    const big = try gpa.alloc(u8, object_store.inline_threshold_bytes + 100);
    defer gpa.free(big);
    @memset(big, 'z');

    var transcript = agent_mod.loop.Transcript.init(gpa);
    defer transcript.deinit();
    const content = try gpa.alloc(ai.types.ContentBlock, 1);
    content[0] = .{ .text = .{ .text = try gpa.dupe(u8, big) } };
    try transcript.append(.{ .role = .assistant, .content = content, .timestamp = 1 });

    const header = SessionHeader{
        .id = "01JXLARGE",
        .created_at_ms = 1,
        .updated_at_ms = 1,
        .title = "s",
        .provider = "faux",
        .model = "faux-1",
        .api = "faux",
        .thinking_level = "off",
    };
    try save(gpa, io, base, header, &transcript);

    const t_path = try std.fmt.allocPrint(gpa, "{s}/01JXLARGE/transcript.jsonl", .{base});
    defer gpa.free(t_path);
    const t_bytes = try readWholeFile(gpa, io, t_path);
    defer gpa.free(t_bytes);
    try testing.expect(std.mem.indexOf(u8, t_bytes, "\"type\":\"ref\"") != null);
    try testing.expect(std.mem.indexOf(u8, t_bytes, "\"hash\":\"sha256:") != null);
    try testing.expect(t_bytes.len < big.len);

    var loaded = try load(gpa, io, base, "01JXLARGE");
    defer loaded.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), loaded.transcript.messages.items.len);
    const m = loaded.transcript.messages.items[0];
    try testing.expectEqual(@as(usize, 1), m.content.len);
    try testing.expectEqualSlices(u8, big, m.content[0].text.text);
}

test "transcript: missing blob during load surfaces a structured error" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_refmissing";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, base);

    // Write a session first so the header is valid.
    var transcript = agent_mod.loop.Transcript.init(gpa);
    defer transcript.deinit();
    const big = try gpa.alloc(u8, object_store.inline_threshold_bytes + 100);
    defer gpa.free(big);
    @memset(big, 'x');
    {
        const content = try gpa.alloc(ai.types.ContentBlock, 1);
        content[0] = .{ .text = .{ .text = try gpa.dupe(u8, big) } };
        try transcript.append(.{ .role = .user, .content = content, .timestamp = 1 });
    }

    const header = SessionHeader{
        .id = "01JXMISS",
        .created_at_ms = 1,
        .updated_at_ms = 1,
        .title = "s",
        .provider = "faux",
        .model = "faux-1",
        .api = "faux",
        .thinking_level = "off",
    };
    try save(gpa, io, base, header, &transcript);

    // Delete the objects dir so the ref cannot be resolved.
    const obj_path = try std.fmt.allocPrint(gpa, "{s}/01JXMISS/objects", .{base});
    defer gpa.free(obj_path);
    _ = std.Io.Dir.cwd().deleteTree(io, obj_path) catch {};

    const err = load(gpa, io, base, "01JXMISS");
    try testing.expectError(error.FileNotFound, err);
}

test "writeBranchTranscript + readBranchTranscript: round-trip preserves messages" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_br_rt";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, base);

    var transcript = agent_mod.loop.Transcript.init(gpa);
    defer transcript.deinit();
    const c = try gpa.alloc(ai.types.ContentBlock, 1);
    c[0] = .{ .text = .{ .text = try gpa.dupe(u8, "branch test") } };
    try transcript.append(.{ .role = .user, .content = c, .timestamp = 1 });

    try writeBranchTranscript(gpa, io, base, &transcript, "experiment");

    // v1.30 — verify the snapshot is written as .jsonl with a meta header.
    const snap_path = try std.fmt.allocPrint(gpa, "{s}/transcripts/experiment.jsonl", .{base});
    defer gpa.free(snap_path);
    const snap_bytes = try readWholeFile(gpa, io, snap_path);
    defer gpa.free(snap_bytes);
    try testing.expect(std.mem.indexOf(u8, snap_bytes, "\"type\":\"meta\"") != null);

    var loaded = try readBranchTranscript(gpa, io, base, "experiment");
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 1), loaded.messages.items.len);
    try testing.expectEqualStrings("branch test", loaded.messages.items[0].content[0].text.text);
}

test "readBranchTranscript: missing snapshot yields FileNotFound" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_br_missing";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, base);

    const err = readBranchTranscript(gpa, io, base, "nonexistent");
    try testing.expectError(error.FileNotFound, err);
}

test "writeBranchTranscript: large blocks still spill to shared objects/" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_br_spill";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, base);

    var transcript = agent_mod.loop.Transcript.init(gpa);
    defer transcript.deinit();
    const big = try gpa.alloc(u8, object_store.inline_threshold_bytes + 200);
    defer gpa.free(big);
    @memset(big, 'z');
    {
        const content = try gpa.alloc(ai.types.ContentBlock, 1);
        content[0] = .{ .text = .{ .text = try gpa.dupe(u8, big) } };
        try transcript.append(.{ .role = .user, .content = content, .timestamp = 1 });
    }

    try writeBranchTranscript(gpa, io, base, &transcript, "big-branch");

    var loaded = try readBranchTranscript(gpa, io, base, "big-branch");
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 1), loaded.messages.items.len);
    try testing.expectEqualSlices(u8, big, loaded.messages.items[0].content[0].text.text);
}

test "transcript: threshold edge — just below stays inline, at threshold spills" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_tr_edge";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, base);

    // --- Just below threshold (32 KiB - 100 bytes) stays inline ---
    {
        var transcript = agent_mod.loop.Transcript.init(gpa);
        defer transcript.deinit();
        const below_payload_len = object_store.inline_threshold_bytes - 100;
        const small = try gpa.alloc(u8, below_payload_len);
        defer gpa.free(small);
        @memset(small, 'a');
        {
            const content = try gpa.alloc(ai.types.ContentBlock, 1);
            content[0] = .{ .text = .{ .text = try gpa.dupe(u8, small) } };
            try transcript.append(.{ .role = .user, .content = content, .timestamp = 1 });
        }

        const header = SessionHeader{
            .id = "01JXEDGE1",
            .created_at_ms = 1,
            .updated_at_ms = 1,
            .title = "s",
            .provider = "faux",
            .model = "faux-1",
            .api = "faux",
            .thinking_level = "off",
        };
        try save(gpa, io, base, header, &transcript);

        var loaded = try load(gpa, io, base, "01JXEDGE1");
        defer loaded.deinit(gpa);
        try testing.expectEqual(@as(usize, 1), loaded.transcript.messages.items.len);
        try testing.expectEqualSlices(u8, small, loaded.transcript.messages.items[0].content[0].text.text);

        const obj_path = try std.fmt.allocPrint(gpa, "{s}/01JXEDGE1/objects", .{base});
        defer gpa.free(obj_path);
        if (std.Io.Dir.cwd().openDir(io, obj_path, .{ .iterate = true })) |*d_const| {
            var d = d_const.*;
            defer d.close(io);
            var it = d.iterate();
            const entry = try it.next(io);
            try testing.expect(entry == null);
        } else |_| {}
    }

    // --- At threshold (32 KiB exactly) spills ---
    {
        var transcript = agent_mod.loop.Transcript.init(gpa);
        defer transcript.deinit();
        const at_payload_len = object_store.inline_threshold_bytes;
        const big = try gpa.alloc(u8, at_payload_len);
        defer gpa.free(big);
        @memset(big, 'b');
        {
            const content = try gpa.alloc(ai.types.ContentBlock, 1);
            content[0] = .{ .text = .{ .text = try gpa.dupe(u8, big) } };
            try transcript.append(.{ .role = .user, .content = content, .timestamp = 1 });
        }

        const header = SessionHeader{
            .id = "01JXEDGE2",
            .created_at_ms = 1,
            .updated_at_ms = 1,
            .title = "s",
            .provider = "faux",
            .model = "faux-1",
            .api = "faux",
            .thinking_level = "off",
        };
        try save(gpa, io, base, header, &transcript);

        var loaded = try load(gpa, io, base, "01JXEDGE2");
        defer loaded.deinit(gpa);
        try testing.expectEqual(@as(usize, 1), loaded.transcript.messages.items.len);
        try testing.expectEqualSlices(u8, big, loaded.transcript.messages.items[0].content[0].text.text);
    }
}

test "Diagnostics round-trips through writeTranscript / readTranscript (v1.29.0)" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky-session-diag";
    std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, base) catch {};

    var transcript = agent_mod.loop.Transcript.init(gpa);
    defer transcript.deinit();

    const c = try gpa.alloc(ai.types.ContentBlock, 1);
    c[0] = .{ .text = .{ .text = try gpa.dupe(u8, "ok") } };
    try transcript.append(.{
        .role = .assistant,
        .content = c,
        .timestamp = 100,
        .stop_reason = .stop,
        .diagnostics = .{
            .trace_id = try gpa.dupe(u8, "1777498943846-0007"),
            .finish_reason_raw = try gpa.dupe(u8, "STOP"),
            .parts_seen = 4,
            .candidates_tokens = 12,
            .thoughts_tokens = 561,
            .text_event_count = 3,
            .was_degenerate = false,
        },
    });

    const header: SessionHeader = .{
        .id = "01JDIAG",
        .created_at_ms = 0,
        .updated_at_ms = 0,
        .title = "diag",
        .provider = "google-gemini",
        .model = "gemini-2.5-pro",
        .api = "google-gemini",
        .thinking_level = "high",
    };
    try save(gpa, io, base, header, &transcript);

    var loaded = try load(gpa, io, base, "01JDIAG");
    defer loaded.deinit(gpa);

    try testing.expectEqual(@as(usize, 1), loaded.transcript.messages.items.len);
    const m = loaded.transcript.messages.items[0];
    try testing.expect(m.diagnostics != null);
    const d = m.diagnostics.?;
    try testing.expectEqualStrings("1777498943846-0007", d.trace_id.?);
    try testing.expectEqualStrings("STOP", d.finish_reason_raw.?);
    try testing.expectEqual(@as(u32, 4), d.parts_seen);
    try testing.expectEqual(@as(?u64, 12), d.candidates_tokens);
    try testing.expectEqual(@as(?u64, 561), d.thoughts_tokens);
    try testing.expectEqual(@as(u32, 3), d.text_event_count);
}

test "assertRefsInKeep: large content block hash is verified in keep list" {
    const gpa = testing.allocator;

    const payload_len = object_store.inline_threshold_bytes + 100;
    const big = try gpa.alloc(u8, payload_len);
    defer gpa.free(big);
    @memset(big, 'x');

    var transcript = agent_mod.loop.Transcript.init(gpa);
    defer transcript.deinit();
    const content = try gpa.alloc(ai.types.ContentBlock, 1);
    content[0] = .{ .text = .{ .text = try gpa.dupe(u8, big) } };
    try transcript.append(.{ .role = .user, .content = content, .timestamp = 1 });

    var tmp: std.ArrayList(u8) = .empty;
    defer tmp.deinit(gpa);
    appendContentBlockJson(&tmp, gpa, transcript.messages.items[0].content[0]) catch @panic("test: appendContentBlockJson failed");

    try testing.expect(tmp.items.len >= object_store.inline_threshold_bytes);

    const hex = try sha256Hex(gpa, tmp.items);
    defer gpa.free(hex);

    assertRefsInKeep(gpa, &transcript, &.{hex});
}


// ─── v1.30.0 JSONL format tests ───────────────────────────────────

/// Write a minimal `session.json` under `<base>/<id>/` so `load()`
/// can read the header. Returns the session_dir path (caller frees).
fn writeMinimalSessionHeader(allocator: std.mem.Allocator, io: std.Io, base: []const u8, id: []const u8) ![]u8 {
    const session_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, id });
    try std.Io.Dir.cwd().createDirPath(io, session_dir);

    const session_json = try std.fmt.allocPrint(allocator,
        "{{\"version\":3,\"id\":\"{s}\",\"createdAtMs\":1,\"updatedAtMs\":1," ++
            "\"title\":\"t\",\"provider\":\"faux\",\"model\":\"faux-1\",\"api\":\"faux\"," ++
            "\"thinkingLevel\":\"off\",\"activeBranch\":\"main\",\"systemPromptHash\":\"\"}}", .{id});
    defer allocator.free(session_json);

    const session_path = try std.fmt.allocPrint(allocator, "{s}/session.json", .{session_dir});
    defer allocator.free(session_path);
    try atomicWrite(io, session_path, session_json);
    return session_dir;
}

test "v1.30: legacy .json transcript is read when .jsonl is absent" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_legacy_read";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, base);

    const session_dir = try writeMinimalSessionHeader(gpa, io, base, "01JXLEG");
    defer gpa.free(session_dir);

    // Write a legacy single-JSON transcript.json (version 3 shape).
    const legacy_json =
        "{\"version\":3,\"branch\":\"main\",\"messages\":[" ++
        "{\"role\":\"user\",\"timestamp\":1000,\"content\":[{\"type\":\"text\",\"text\":\"legacy hello\"}]}" ++
        "]}";
    const legacy_path = try std.fmt.allocPrint(gpa, "{s}/transcript.json", .{session_dir});
    defer gpa.free(legacy_path);
    try atomicWrite(io, legacy_path, legacy_json);

    // readTranscript should find the .jsonl absent and fall back to .json.
    var loaded = try load(gpa, io, base, "01JXLEG");
    defer loaded.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), loaded.transcript.messages.items.len);
    try testing.expectEqualStrings("legacy hello", loaded.transcript.messages.items[0].content[0].text.text);
}

test "v1.30: empty JSONL (meta-only) yields zero messages" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_empty_jsonl";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, base);

    const session_dir = try writeMinimalSessionHeader(gpa, io, base, "01JXEMPTY");
    defer gpa.free(session_dir);

    const jsonl_path = try std.fmt.allocPrint(gpa, "{s}/transcript.jsonl", .{session_dir});
    defer gpa.free(jsonl_path);
    try atomicWrite(io, jsonl_path, "{\"type\":\"meta\",\"version\":4,\"branch\":\"main\"}\n");

    var loaded = try load(gpa, io, base, "01JXEMPTY");
    defer loaded.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), loaded.transcript.messages.items.len);
}

test "v1.30: truncated final line is skipped, prior messages load" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_truncated";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, base);

    const session_dir = try writeMinimalSessionHeader(gpa, io, base, "01JXTRUNC");
    defer gpa.free(session_dir);

    // Meta header + one valid message + one truncated line.
    const jsonl_content =
        "{\"type\":\"meta\",\"version\":4,\"branch\":\"main\"}\n" ++
        "{\"role\":\"user\",\"timestamp\":1000,\"content\":[{\"type\":\"text\",\"text\":\"ok\"}]}\n" ++
        "{\"role\":\"assistant\",\"timestamp\":2000,\"content\":[{\"type\":\"text\",\"text\":\"trun";
    const jsonl_path = try std.fmt.allocPrint(gpa, "{s}/transcript.jsonl", .{session_dir});
    defer gpa.free(jsonl_path);
    try atomicWrite(io, jsonl_path, jsonl_content);

    var loaded = try load(gpa, io, base, "01JXTRUNC");
    defer loaded.deinit(gpa);
    // The valid user message loads; the truncated assistant line is skipped.
    try testing.expectEqual(@as(usize, 1), loaded.transcript.messages.items.len);
    try testing.expectEqualStrings("ok", loaded.transcript.messages.items[0].content[0].text.text);
}

test "v1.30: legacy .json branch snapshot is read when .jsonl is absent" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_br_legacy";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, base);

    const snap_dir = try std.fmt.allocPrint(gpa, "{s}/transcripts", .{base});
    defer gpa.free(snap_dir);
    try std.Io.Dir.cwd().createDirPath(io, snap_dir);

    // Write a legacy single-JSON branch snapshot.
    const legacy_json =
        "{\"version\":3,\"branch\":\"old\",\"messages\":[" ++
        "{\"role\":\"user\",\"timestamp\":500,\"content\":[{\"type\":\"text\",\"text\":\"old branch\"}]}" ++
        "]}";
    const legacy_path = try std.fmt.allocPrint(gpa, "{s}/transcripts/old.json", .{base});
    defer gpa.free(legacy_path);
    try atomicWrite(io, legacy_path, legacy_json);

    var loaded = try readBranchTranscript(gpa, io, base, "old");
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 1), loaded.messages.items.len);
    try testing.expectEqualStrings("old branch", loaded.messages.items[0].content[0].text.text);
}
