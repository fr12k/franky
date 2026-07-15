//! Session factory — §3.2 of the A2A core-boundary design.
//!
//! Extracts the common session-identity setup that was previously
//! duplicated across mode drivers (print.zig, proxy.zig, rpc.zig,
//! interactive.zig). Every mode that needs a session calls
//! `session.SessionState.init()` instead of inlining the same
//! 200-line init sequence.
//!
//! The factory provides:
//!   1. `SessionState` — canonical session-identity struct (id,
//!      transcript, branch tree, parent dir).
//!   2. `init()` — creates session identity from CLI config.
//!   3. `persist()` — saves session + transcript + branch tree to
//!      disk.
//!
//! Design invariant: zero A2A-specific logic. This module is a
//! general-purpose SDK enrichment that benefits every extension
//! (orchestrator, test harness, A2A server, etc.).
//!
//! NOTE: To avoid circular imports, this module does NOT import
//! `franky.coding.modes.print`. If you need `buildSystemPromptIo`
//! alongside session creation, call it separately before/after
//! `SessionState.init()`.

const std = @import("std");
const franky = @import("../../root.zig");
const ai = franky.ai;
const agent = franky.agent;
const at = agent.types;
const cli_mod = franky.coding.cli;
const session_mod = @import("mod.zig");
const branching_mod = @import("branching.zig");
const ccr_store_mod = @import("ccr_store.zig");

// ─── SessionState ──────────────────────────────────────────────────

/// Canonical session-identity data. Owns the transcript, branch tree,
/// and arena for id/parent_dir strings.
pub const SessionState = struct {
    arena: std.heap.ArenaAllocator,
    session_id: []const u8,
    parent_dir: ?[]const u8,
    transcript: agent.loop.Transcript,
    created_at_ms: i64,
    /// v1.6.0 — branch tree for this session. Loaded from
    /// `<session_dir>/tree.json` on `--resume`, minted fresh
    /// otherwise. Saved alongside `session.json`/`transcript.json`
    /// in `persist`.
    tree: branching_mod.Tree,
    /// v3.0 — session-scoped CCR store for reversible compression.
    ccr_store: ccr_store_mod.CcrSessionStore,

    /// Initialise a `SessionState` from a parsed CLI config.
    ///
    /// Three cases:
    ///   - `--resume <sid>`  → load existing session from disk.
    ///   - `--session <sid>` → use the given id verbatim.
    ///   - neither           → mint a fresh ULID.
    ///
    /// When `--no-session` is set, `parent_dir` is null (no
    /// persistence), but we still mint an in-memory session id.
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        environ: std.process.Environ,
        cfg: *cli_mod.Config,
    ) !SessionState {
        var arena = std.heap.ArenaAllocator.init(allocator);
        const a = arena.allocator();

        const parent_dir: ?[]const u8 = if (cfg.no_session) null else blk: {
            if (cfg.session_dir) |d| break :blk try a.dupe(u8, d);
            const franky_home: ?[]const u8 = environ.getPosix("FRANKY_HOME");
            if (franky_home) |h| {
                break :blk try std.fs.path.join(a, &.{ h, "sessions" });
            }
            const home: ?[]const u8 = environ.getPosix("HOME");
            if (home) |h| {
                break :blk try std.fs.path.join(a, &.{ h, ".franky", "sessions" });
            }
            break :blk try a.dupe(u8, "./.franky-sessions");
        };

        // Case 1: --resume <sid> — load existing session.
        if (cfg.resume_id) |sid| {
            if (parent_dir == null) return error.ResumeFailed;
            const loaded = session_mod.load(allocator, io, parent_dir.?, sid) catch |err| {
                arena.deinit();
                return err;
            };
            var transcript = loaded.transcript;
            const created_ms = loaded.header.created_at_ms;
            const owned_id = try a.dupe(u8, sid);
            session_mod.freeSessionHeader(allocator, loaded.header);
            // Tree: `loadTree` tolerates missing file → fresh tree
            // with default `main` branch.
            const session_dir = try std.fs.path.join(a, &.{ parent_dir.?, owned_id });
            var tree = branching_mod.loadTree(allocator, io, session_dir) catch try branching_mod.Tree.init(allocator);

            // v1.7.0 — `--checkout <name>` swaps the transcript to
            // the branch snapshot at resume time. Falls back to the
            // already-loaded active transcript if the snapshot is
            // missing (e.g. pre-v1.7 sessions that never wrote one).
            if (cfg.checkout_branch) |name| {
                tree.switchTo(name) catch {};
                if (session_mod.readBranchTranscript(allocator, io, session_dir, name)) |snap| {
                    transcript.deinit();
                    transcript = snap;
                } else |_| {
                    ai.log.log(.warn, "session", "checkout_snapshot_missing", "branch={s}", .{name});
                }
            }

            if (cfg.fork_branch) |name| {
                const msg_count: u32 = @intCast(transcript.messages.items.len);
                tree.fork(name, tree.active, msg_count) catch {};
                tree.switchTo(name) catch {};
                session_mod.writeBranchTranscript(allocator, io, session_dir, &transcript, name) catch {};
            }
            return .{
                .arena = arena,
                .session_id = owned_id,
                .parent_dir = parent_dir,
                .transcript = transcript,
                .created_at_ms = created_ms,
                .tree = tree,
                .ccr_store = ccr_store_mod.CcrSessionStore.init(allocator),
            };
        }

        // Case 2: --session <sid> provided — use it as-is.
        // Case 3: no session flags — mint a new ULID.
        const owned_id = if (cfg.session_id) |sid|
            try a.dupe(u8, sid)
        else blk: {
            var prng = std.Random.DefaultPrng.init(@bitCast(ai.stream.nowMillis()));
            const now: u64 = @intCast(ai.stream.nowMillis());
            const u = session_mod.newUlid(now, prng.random());
            break :blk try a.dupe(u8, u.asSlice());
        };

        var tree = try branching_mod.Tree.init(allocator);
        if (cfg.fork_branch) |name| {
            tree.fork(name, tree.active, 0) catch {};
            tree.switchTo(name) catch {};
        }

        return .{
            .arena = arena,
            .session_id = owned_id,
            .parent_dir = parent_dir,
            .transcript = agent.loop.Transcript.init(allocator),
            .created_at_ms = ai.stream.nowMillis(),
            .tree = tree,
            .ccr_store = ccr_store_mod.CcrSessionStore.init(allocator),
        };
    }

    pub fn deinit(self: *SessionState, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.transcript.deinit();
        self.tree.deinit();
        self.ccr_store.deinit();
        self.arena.deinit();
    }

    pub fn id(self: *const SessionState) []const u8 {
        return self.session_id;
    }

    /// Persist session + transcript + branch tree to disk.
    /// No-op when `parent_dir` is null (--no-session).
    pub fn persist(
        self: *SessionState,
        allocator: std.mem.Allocator,
        io: std.Io,
        info: ProviderInfo,
        cfg: *cli_mod.Config,
    ) !void {
        const parent = self.parent_dir orelse return;

        const title = if (self.transcript.messages.items.len > 0 and
            self.transcript.messages.items[0].role == .user and
            self.transcript.messages.items[0].content.len > 0) blk: {
            const first = self.transcript.messages.items[0].content[0];
            switch (first) {
                .text => |t| {
                    const max_len = 64;
                    const take = @min(t.text.len, max_len);
                    break :blk t.text[0..take];
                },
                else => break :blk "franky session",
            }
        } else "franky session";

        const header = session_mod.SessionHeader{
            .id = self.session_id,
            .created_at_ms = self.created_at_ms,
            .updated_at_ms = ai.stream.nowMillis(),
            .title = title,
            .provider = info.provider_name,
            .model = info.model_id,
            .api = info.api_tag,
            .thinking_level = cfg.thinking.toString(),
        };

        try session_mod.save(allocator, io, parent, header, &self.transcript);

        // v1.6.0 — persist the branch tree alongside the header
        // and transcript.
        const session_dir = try std.fs.path.join(allocator, &.{ parent, self.session_id });
        defer allocator.free(session_dir);

        const entry_maybe = self.tree.branches.getPtr(self.tree.active);
        if (entry_maybe) |entry| {
            entry.message_count = @intCast(self.transcript.messages.items.len);
        }
        branching_mod.saveTree(allocator, io, session_dir, &self.tree) catch |err| {
            ai.log.log(.warn, "session", "tree_save_failed", "error={s}", .{@errorName(err)});
        };

        // v1.7.0 — also snapshot the active branch so
        // `--checkout <branch>` can rehydrate that exact state on resume.
        session_mod.writeBranchTranscript(allocator, io, session_dir, &self.transcript, self.tree.active) catch |err| {
            ai.log.log(.warn, "session", "branch_snapshot_failed", "error={s}", .{@errorName(err)});
        };
    }
};

// ─── ProviderInfo (provider-lite for persistence headers) ─────────

/// Minimal provider metadata for session persistence headers.
pub const ProviderInfo = struct {
    provider_name: []const u8,
    api_tag: []const u8,
    model_id: []const u8,
    api_key: ?[]const u8,
    auth_token: ?[]const u8,
    base_url: ?[]const u8,
    context_window: u32,
    max_output: u32,
    capabilities: ai.types.Capabilities = .{ .tool_use = true },
};
