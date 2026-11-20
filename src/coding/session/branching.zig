//! Session branching primitives — §5.1 + §H.4.
//!
//! A `Tree` is an in-memory name→`Branch` map. Each branch records
//! its `parent` (by name, `null` for root), the `fork_index` where
//! it diverged from the parent's message list, the `head_hash` (a
//! content address of the head message for future GC), and the
//! number of messages on the branch.
//!
//! Wire shape (§H.4): `tree.json` persists branches keyed by name;
//! `session.json.activeBranch` points at the currently-writable
//! branch. A compact or explicit fork copies the parent to a new
//! branch name before diverging, and updates `active_branch`.
//!
//! Scope note (v0.6.2): this module ships the primitives + JSON
//! round-trip. Wiring branching into the `agentLoop`'s transcript
//! append logic (so a fork actually creates a new writable line of
//! history) is a follow-up that interlocks with v0.6.3's
//! compaction pass; both share the "preserve first user + tail"
//! span rule.

const std = @import("std");
const utils = @import("../../ai/utils.zig");

pub const Branch = struct {
    /// Unique branch name — `"main"` for the initial line.
    name: []const u8,
    /// Parent branch name; `null` for the root.
    parent: ?[]const u8,
    /// Message index in the parent branch where this branch forked.
    /// For the root this is 0.
    fork_index: u32,
    /// Number of messages appended to this branch since the fork
    /// point (or from 0 for root).
    message_count: u32,
    /// Content-addressed hash of this branch's head message, used
    /// by the object-store GC to keep the right things alive. Empty
    /// for a freshly-forked branch with no appends.
    head_hash: []const u8 = "",
};

pub const Tree = struct {
    allocator: std.mem.Allocator,
    branches: std.StringHashMap(Branch),
    /// Name of the branch new appends go to.
    active: []const u8,

    pub fn init(allocator: std.mem.Allocator) !Tree {
        var t = Tree{
            .allocator = allocator,
            .branches = std.StringHashMap(Branch).init(allocator),
            .active = try allocator.dupe(u8, "main"),
        };
        const name = try allocator.dupe(u8, "main");
        try t.branches.put(name, .{
            .name = name,
            .parent = null,
            .fork_index = 0,
            .message_count = 0,
        });
        return t;
    }

    pub fn deinit(self: *Tree) void {
        var it = self.branches.iterator();
        while (it.next()) |entry| {
            const b = entry.value_ptr;
            self.allocator.free(b.name);
            if (b.parent) |p| self.allocator.free(p);
            if (b.head_hash.len > 0) self.allocator.free(b.head_hash);
        }
        self.branches.deinit();
        self.allocator.free(self.active);
        self.* = undefined;
    }

    /// Fork a new branch off `parent_name` at `fork_index`. The new
    /// branch is created if it doesn't exist; if it already exists,
    /// returns `error.BranchExists`.
    pub fn fork(
        self: *Tree,
        new_name: []const u8,
        parent_name: []const u8,
        fork_index: u32,
    ) !void {
        if (self.branches.get(new_name) != null) return error.BranchExists;
        const parent = self.branches.get(parent_name) orelse return error.ParentNotFound;
        if (fork_index > parent.message_count) return error.ForkIndexOutOfRange;

        const owned_name = try self.allocator.dupe(u8, new_name);
        const owned_parent = try self.allocator.dupe(u8, parent_name);
        try self.branches.put(owned_name, .{
            .name = owned_name,
            .parent = owned_parent,
            .fork_index = fork_index,
            .message_count = fork_index, // starts with the parent's prefix of length fork_index
        });
    }

    /// Switch the active branch. Returns error.BranchNotFound when
    /// the name isn't in the tree.
    pub fn switchTo(self: *Tree, name: []const u8) !void {
        if (self.branches.get(name) == null) return error.BranchNotFound;
        self.allocator.free(self.active);
        self.active = try self.allocator.dupe(u8, name);
    }

    /// Record that a new message landed on `active`, optionally
    /// updating the head hash for GC tracking.
    pub fn appendOnActive(self: *Tree, head_hash: ?[]const u8) !void {
        const entry = self.branches.getPtr(self.active) orelse return error.BranchNotFound;
        entry.message_count += 1;
        if (head_hash) |h| {
            if (entry.head_hash.len > 0) self.allocator.free(entry.head_hash);
            entry.head_hash = try self.allocator.dupe(u8, h);
        }
    }

    /// Orphan-tool-pair invariant (§E.2): a branch's `fork_index`
    /// must land on a turn boundary — it cannot split a tool call
    /// off from its tool result. Callers pass a boolean vector
    /// `at_turn_boundary[i]` indicating whether index `i` is legal
    /// as a fork point.
    pub fn isForkLegal(_: Tree, at_turn_boundary: []const bool, fork_index: u32) bool {
        if (fork_index >= at_turn_boundary.len) return fork_index == at_turn_boundary.len;
        return at_turn_boundary[fork_index];
    }
};

// ─── tree.json persistence — §H.4 ────────────────────────────────

pub const current_tree_version: u32 = 1;

pub const TreeIoError = error{
    MalformedJson,
    MissingField,
    WriteFailed,
} || std.mem.Allocator.Error;

/// Render `tree` to a JSON string (caller-owned).
///
/// Shape:
///   {
///     "version": 1,
///     "active": "main",
///     "branches": [
///       {"name":"main","parent":null,"forkIndex":0,"messageCount":3,"headHash":"…"},
///       ...
///     ]
///   }
pub fn renderTreeJson(allocator: std.mem.Allocator, tree: *const Tree) TreeIoError![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"version\":");
    try writeInt(&buf, allocator, @intCast(current_tree_version));
    try buf.appendSlice(allocator, ",\"active\":");
    try utils.appendJsonStr(&buf, allocator, tree.active);
    try buf.appendSlice(allocator, ",\"branches\":[");
    var first = true;
    var it = tree.branches.iterator();
    while (it.next()) |entry| {
        if (!first) try buf.append(allocator, ',');
        first = false;
        const b = entry.value_ptr.*;
        try buf.append(allocator, '{');
        try buf.appendSlice(allocator, "\"name\":");
        try utils.appendJsonStr(&buf, allocator, b.name);
        try buf.appendSlice(allocator, ",\"parent\":");
        if (b.parent) |p| {
            try utils.appendJsonStr(&buf, allocator, p);
        } else {
            try buf.appendSlice(allocator, "null");
        }
        try buf.appendSlice(allocator, ",\"forkIndex\":");
        try writeInt(&buf, allocator, b.fork_index);
        try buf.appendSlice(allocator, ",\"messageCount\":");
        try writeInt(&buf, allocator, b.message_count);
        if (b.head_hash.len > 0) {
            try buf.appendSlice(allocator, ",\"headHash\":");
            try utils.appendJsonStr(&buf, allocator, b.head_hash);
        }
        try buf.append(allocator, '}');
    }
    try buf.appendSlice(allocator, "]}");
    return buf.toOwnedSlice(allocator);
}

/// Parse a tree.json blob back into a `Tree`. Unknown fields
/// are ignored; missing required fields surface as
/// `TreeIoError.MissingField` (not MalformedJson — they're a
/// user mistake rather than a parser error).
pub fn parseTreeJson(allocator: std.mem.Allocator, body: []const u8) TreeIoError!Tree {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const parsed = std.json.parseFromSlice(std.json.Value, scratch.allocator(), body, .{}) catch return TreeIoError.MalformedJson;
    if (parsed.value != .object) return TreeIoError.MalformedJson;
    const obj = parsed.value.object;

    const branches_val = obj.get("branches") orelse return TreeIoError.MissingField;
    if (branches_val != .array) return TreeIoError.MalformedJson;

    // Start `active` as a freshly-allocated empty string so an
    // early-error path's `errdefer tree.deinit()` has something
    // valid to free.
    var tree: Tree = .{
        .allocator = allocator,
        .branches = std.StringHashMap(Branch).init(allocator),
        .active = try allocator.dupe(u8, ""),
    };
    errdefer tree.deinit();

    for (branches_val.array.items) |entry| {
        if (entry != .object) return TreeIoError.MalformedJson;
        const e = entry.object;
        const name_v = e.get("name") orelse return TreeIoError.MissingField;
        if (name_v != .string) return TreeIoError.MalformedJson;

        const owned_name = try allocator.dupe(u8, name_v.string);
        var b: Branch = .{
            .name = owned_name,
            .parent = null,
            .fork_index = 0,
            .message_count = 0,
        };
        if (e.get("parent")) |v| switch (v) {
            .string => |s| b.parent = try allocator.dupe(u8, s),
            .null => {},
            else => {},
        };
        if (utils.jsonInt(e, "forkIndex")) |v| {
            b.fork_index = @intCast(v);
        }
        if (utils.jsonInt(e, "messageCount")) |v| {
            b.message_count = @intCast(v);
        }
        if (utils.jsonStr(e, "headHash")) |s| {
            b.head_hash = try allocator.dupe(u8, s);
        }
        try tree.branches.put(owned_name, b);
    }

    const active_v = obj.get("active") orelse return TreeIoError.MissingField;
    if (active_v != .string) return TreeIoError.MalformedJson;
    allocator.free(tree.active); // drop the placeholder ""
    tree.active = try allocator.dupe(u8, active_v.string);
    return tree;
}


fn writeInt(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, n: u32) !void {
    const s = try std.fmt.allocPrint(allocator, "{d}", .{n});
    defer allocator.free(s);
    try buf.appendSlice(allocator, s);
}

/// Atomic write to `<session_dir>/tree.json` via tempfile + rename.
pub fn saveTree(
    allocator: std.mem.Allocator,
    io: std.Io,
    session_dir: []const u8,
    tree: *const Tree,
) TreeIoError!void {
    const body = try renderTreeJson(allocator, tree);
    defer allocator.free(body);

    const tmp_path = try std.fs.path.join(allocator, &.{ session_dir, "tree.json.part" });
    defer allocator.free(tmp_path);
    const final_path = try std.fs.path.join(allocator, &.{ session_dir, "tree.json" });
    defer allocator.free(final_path);

    std.Io.Dir.cwd().createDirPath(io, session_dir) catch {};
    var f = std.Io.Dir.cwd().createFile(io, tmp_path, .{}) catch return TreeIoError.WriteFailed;
    {
        defer f.close(io);
        f.writeStreamingAll(io, body) catch return TreeIoError.WriteFailed;
        f.sync(io) catch {};
    }
    std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), final_path, io) catch return TreeIoError.WriteFailed;
}

/// Load `<session_dir>/tree.json`. Missing → empty tree with
/// default `main` branch.
pub fn loadTree(
    allocator: std.mem.Allocator,
    io: std.Io,
    session_dir: []const u8,
) TreeIoError!Tree {
    const path = try std.fs.path.join(allocator, &.{ session_dir, "tree.json" });
    defer allocator.free(path);

    var f = std.Io.Dir.cwd().openFile(io, path, .{}) catch |e| switch (e) {
        error.FileNotFound => return try Tree.init(allocator),
        else => return TreeIoError.MalformedJson,
    };
    defer f.close(io);
    const len = f.length(io) catch return TreeIoError.MalformedJson;
    const buf = try allocator.alloc(u8, @intCast(len));
    defer allocator.free(buf);
    const n = f.readPositionalAll(io, buf, 0) catch return TreeIoError.MalformedJson;
    return try parseTreeJson(allocator, buf[0..n]);
}

// ─── tests ────────────────────────────────────────────────────────

const testing = std.testing;
const test_h = @import("../../test_helpers.zig");

test "Tree: init starts on main with 0 messages" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    try testing.expectEqualStrings("main", t.active);
    const main = t.branches.get("main").?;
    try testing.expectEqual(@as(u32, 0), main.message_count);
    try testing.expect(main.parent == null);
}

test "Tree: appendOnActive grows message_count on the current branch" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    try t.appendOnActive(null);
    try t.appendOnActive(null);
    try t.appendOnActive(null);
    try testing.expectEqual(@as(u32, 3), t.branches.get("main").?.message_count);
}

test "Tree: fork aliases parent's prefix, then diverges" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    // Populate main with 7 messages.
    var i: u32 = 0;
    while (i < 7) : (i += 1) try t.appendOnActive(null);

    try t.fork("alt", "main", 5);
    const alt = t.branches.get("alt").?;
    try testing.expectEqualStrings("alt", alt.name);
    try testing.expectEqualStrings("main", alt.parent.?);
    try testing.expectEqual(@as(u32, 5), alt.fork_index);
    try testing.expectEqual(@as(u32, 5), alt.message_count);

    // Switch to alt; further appends grow alt, not main.
    try t.switchTo("alt");
    try t.appendOnActive(null);
    try testing.expectEqual(@as(u32, 6), t.branches.get("alt").?.message_count);
    try testing.expectEqual(@as(u32, 7), t.branches.get("main").?.message_count);
}

test "Tree: fork at head (fork_index == message_count) is legal" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    try t.appendOnActive(null);
    try t.appendOnActive(null);

    try t.fork("alt", "main", 2); // at head
    const alt = t.branches.get("alt").?;
    try testing.expectEqual(@as(u32, 2), alt.message_count);
}

test "Tree: fork beyond parent's history rejected" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    try t.appendOnActive(null);

    const err = t.fork("alt", "main", 5);
    try testing.expectError(error.ForkIndexOutOfRange, err);
}

test "Tree: fork onto an existing name rejected" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    try t.appendOnActive(null);
    try t.fork("alt", "main", 1);

    const err = t.fork("alt", "main", 0);
    try testing.expectError(error.BranchExists, err);
}

test "Tree: fork with missing parent rejected" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    const err = t.fork("alt", "nope", 0);
    try testing.expectError(error.ParentNotFound, err);
}

test "Tree: switchTo requires an existing branch" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    try testing.expectError(error.BranchNotFound, t.switchTo("nope"));
}

test "Tree.isForkLegal: honors turn-boundary vector" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    const boundaries = [_]bool{ true, false, true, true, false };
    try testing.expect(t.isForkLegal(&boundaries, 0));
    try testing.expect(!t.isForkLegal(&boundaries, 1));
    try testing.expect(t.isForkLegal(&boundaries, 2));
    try testing.expect(!t.isForkLegal(&boundaries, 4));
    // fork at exact length (past end) also legal — fork-at-head.
    try testing.expect(t.isForkLegal(&boundaries, 5));
}

// ─── tree.json persistence (v1.4.0) ──────────────────────────────

test "renderTreeJson: root-only tree includes version + active + branches" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    const body = try renderTreeJson(testing.allocator, &t);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"version\":1") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"active\":\"main\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"name\":\"main\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"parent\":null") != null);
}

test "renderTreeJson + parseTreeJson: round-trip with fork + head_hash" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    try t.appendOnActive("abc123");
    try t.appendOnActive("def456");
    try t.fork("feature", "main", 1);
    try t.switchTo("feature");
    try t.appendOnActive("xyz789");

    const body = try renderTreeJson(testing.allocator, &t);
    defer testing.allocator.free(body);

    var t2 = try parseTreeJson(testing.allocator, body);
    defer t2.deinit();

    try testing.expectEqualStrings("feature", t2.active);
    try testing.expect(t2.branches.get("main") != null);
    try testing.expect(t2.branches.get("feature") != null);
    const feat = t2.branches.get("feature").?;
    try testing.expectEqual(@as(u32, 1), feat.fork_index);
    try testing.expectEqualStrings("main", feat.parent.?);
}

test "parseTreeJson: missing active → MissingField" {
    const body = "{\"version\":1,\"branches\":[{\"name\":\"main\"}]}";
    try testing.expectError(TreeIoError.MissingField, parseTreeJson(testing.allocator, body));
}

test "parseTreeJson: malformed JSON → MalformedJson" {
    try testing.expectError(TreeIoError.MalformedJson, parseTreeJson(testing.allocator, "not json"));
}

test "saveTree + loadTree: atomic round-trip under a temp dir" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const dir = "/tmp/franky_tree_rt";
    // Cleanup before + after so repeated test runs are idempotent.
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var t = try Tree.init(gpa);
    try t.appendOnActive("hash1");
    try t.fork("branch-a", "main", 1);
    try saveTree(gpa, io, dir, &t);
    t.deinit();

    var loaded = try loadTree(gpa, io, dir);
    defer loaded.deinit();
    try testing.expect(loaded.branches.get("branch-a") != null);
    try testing.expect(loaded.branches.get("main") != null);
}

test "loadTree: missing file yields fresh tree with default main branch" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const dir = "/tmp/franky_tree_missing_7";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    var t = try loadTree(testing.allocator, io, dir);
    defer t.deinit();
    try testing.expectEqualStrings("main", t.active);
    try testing.expect(t.branches.get("main") != null);
}

// ─── v1.6.1 — coverage gap fills ─────────────────────────────────

test "Tree: appendOnActive on unknown branch → BranchNotFound" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    // Manually corrupt `active` to a name that isn't in the map.
    testing.allocator.free(t.active);
    t.active = try testing.allocator.dupe(u8, "does-not-exist");
    try testing.expectError(error.BranchNotFound, t.appendOnActive(null));
}

test "Tree: appendOnActive records the head hash when supplied" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    try t.appendOnActive("sha256:deadbeef");
    const entry = t.branches.get("main").?;
    try testing.expectEqualStrings("sha256:deadbeef", entry.head_hash);
    // Subsequent call replaces (no leak because Tree.deinit frees it).
    try t.appendOnActive("sha256:cafef00d");
    const entry2 = t.branches.get("main").?;
    try testing.expectEqualStrings("sha256:cafef00d", entry2.head_hash);
}

test "renderTreeJson → parseTreeJson: round-trips head_hash" {
    const gpa = testing.allocator;
    var t = try Tree.init(gpa);
    defer t.deinit();
    try t.appendOnActive("sha256:abc");
    const json = try renderTreeJson(gpa, &t);
    defer gpa.free(json);

    var round = try parseTreeJson(gpa, json);
    defer round.deinit();
    const entry = round.branches.get("main").?;
    try testing.expectEqualStrings("sha256:abc", entry.head_hash);
}
