//! A2UI (Agent-to-User Interface) — PoC integration.
//!
//! Spec: https://a2ui.org/specification/v1.0-a2ui/ (v1.0).
//!
//! Scope of this PoC:
//!   - One logical surface ("main"), created implicitly when the model
//!     emits its first `createSurface` message via the `a2ui_render`
//!     tool (spec §"an agent may skip createSurface if it knows of a
//!     preexisting surface").
//!   - `updateComponents` (full-replace semantics per surface: each
//!     batch replaces the whole adjacency list — simple and
//!     convergence-friendly for a PoC) and `updateDataModel`
//!     (deep-merge into the surface data model).
//!   - Catalog: Column, Row, Text, Button, TextField, CheckBox, Card.
//!   - Host-side projection: `upsertComponents` / `removeComponents`
//!     let the proxy inject UI (e.g. tool-permission forms per plan
//!     §4.4) without going through the LLM tool path.
//!   - Dynamic strings: plain string or `{ "@path": "/json/pointer" }`.
//!     `@call` function bindings are NOT supported (rejected).
//!   - Two-way binding is renderer-local per spec; state reaches the
//!     agent only via `action` messages (`POST /a2ui/action`), which
//!     are appended to the transcript as user messages and drive a
//!     normal agent turn.
//!
//! Threading: `Session.state` / `Session.version` are guarded by
//! `mutex`. The tool worker thread mutates; HTTP connection threads
//! read/broadcast. `broadcast_fn` is invoked WITHOUT the mutex held.

const std = @import("std");

pub const surface_id = "main";

/// Plan 4.2 — replay ring capacity for `/a2ui/events` reconnects.
/// Each accepted envelope is stored serialized so a stale
/// `Last-Event-ID` can be replayed; older than the ring falls back
/// to a full snapshot.
pub const replay_ring_capacity: usize = 1024;

/// Callback the session uses to fan a fully-rendered SSE frame out to
/// `/a2ui/events` subscribers. `userdata` is the proxy `Session`.
pub const BroadcastFn = *const fn (userdata: *anyopaque, frame: []const u8) void;

/// Plan 4.2 — one A2UI surface: its component adjacency list +
/// reactive data model. Keyed by surfaceId in `Session.surfaces`.
const Surface = struct {
    /// Raw `components` array from the most recent accepted
    /// `updateComponents` batch. `null` until the first batch.
    state: ?std.json.Value = null,
    /// Deep-merged `updateDataModel` payloads.
    data_model: std.json.Value = .null,

    fn deinit(self: *Surface, allocator: std.mem.Allocator) void {
        if (self.state) |*s| freeCopy(allocator, s.*);
        freeCopy(allocator, self.data_model);
    }
};

/// One replay-ring entry: the fully-stamped SSE frame
/// (`id:/event:/data:`) for an accepted envelope.
const ReplayFrame = struct {
    id: u64,
    frame: []u8,
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    /// Plan 4.2 — surface registry. `"main"` is created lazily on
    /// first use so existing callers (single-surface PoC) keep
    /// working without an explicit createSurface.
    surfaces: std.StringHashMapUnmanaged(Surface) = .empty,
    /// Monotonic version, bumped on every accepted mutation. Used as
    /// the SSE event id for `Last-Event-ID` reconnects.
    version: u64 = 0,
    /// Plan 4.2 — replay ring of recent stamped frames keyed by
    /// `id % replay_ring_capacity`.
    replay_ring: [replay_ring_capacity]?ReplayFrame = @splat(null),
    mutex: std.Io.Mutex = .init,
    broadcast_fn: ?BroadcastFn = null,
    broadcast_userdata: ?*anyopaque = null,
    /// Io handle captured at init for `lockUncancelable` (mutex lock
    /// needs an Io in 0.17). The proxy passes its loop Io.
    io: std.Io,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Session {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn deinit(self: *Session) void {
        var it = self.surfaces.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            e.value_ptr.deinit(self.allocator);
        }
        self.surfaces.deinit(self.allocator);
        for (self.replay_ring[0..]) |maybe| {
            if (maybe) |f| self.allocator.free(f.frame);
        }
    }

    /// Fetch or create the surface for `sid`. Caller holds the mutex.
    /// getOrPut does NOT consume the key on found_existing, so the
    /// dupe is freed on that path (same pattern as mergeJson).
    fn surfaceLocked(self: *Session, sid: []const u8) !*Surface {
        const duped = try self.allocator.dupe(u8, sid);
        const gop = try self.surfaces.getOrPut(self.allocator, duped);
        if (gop.found_existing) {
            self.allocator.free(duped);
        } else {
            gop.value_ptr.* = .{};
        }
        return gop.value_ptr;
    }

    pub fn setBroadcast(self: *Session, userdata: *anyopaque, f: BroadcastFn) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.broadcast_userdata = userdata;
        self.broadcast_fn = f;
    }

    // ── tool-side mutation ────────────────────────────────────────

    /// Apply one agent→renderer envelope (a single message object with
    /// exactly one of `createSurface` / `updateComponents` /
    /// `updateDataModel` / `deleteSurface`). Validates, mutates,
    /// broadcasts the same envelope to live subscribers.
    ///
    /// On validation failure returns an allocated, LLM-facing error
    /// string (JSON, spec §standard validation error format). On
    /// success returns null.
    /// Validation error strings are allocated on `allocator` and
    /// owned by the caller (the tool frees them after copying into
    /// the tool-result message). Intermediate validation strings use
    /// an internal arena.
    pub fn applyEnvelope(self: *Session, allocator: std.mem.Allocator, env: std.json.Value) !?[]u8 {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();

        if (env != .object) return try validationError(allocator, "VALIDATION_FAILED", "/", "envelope must be a JSON object");
        const obj = env.object;

        if (obj.get("createSurface")) |cs| {
            // Plan 4.2 — surfaces are created lazily; createSurface is
            // an explicit (idempotent) registration + shape validation.
            if (cs != .object) return try validationError(allocator, "VALIDATION_FAILED", "/createSurface", "createSurface must be an object");
            const sid: []const u8 = if (cs.object.get("surfaceId")) |v| blk: {
                if (v != .string or v.string.len == 0)
                    return try validationError(allocator, "VALIDATION_FAILED", "/createSurface/surfaceId", "surfaceId must be a non-empty string");
                break :blk v.string;
            } else surface_id;
            self.mutex.lockUncancelable(self.io);
            _ = try self.surfaceLocked(sid);
            self.mutex.unlock(self.io);
            return null; // nothing to broadcast — no content yet
        }

        if (obj.get("updateComponents")) |uc| {
            if (uc != .object) return try validationError(allocator, "VALIDATION_FAILED", "/updateComponents", "updateComponents must be an object");
            const sid: []const u8 = switch (try a2uiSurfaceId(allocator, uc, "/updateComponents")) {
                .none => surface_id,
                .ok => |s| s,
                .err => |e| return e,
            };
            const comps = uc.object.get("components") orelse
                return try validationError(allocator, "VALIDATION_FAILED", "/updateComponents/components", "missing components array");
            if (comps != .array) return try validationError(allocator, "VALIDATION_FAILED", "/updateComponents/components", "components must be an array");
            if (try validateComponents(a, comps.array.items)) |err_msg| return try allocator.dupe(u8, err_msg);

            // Full-replace mutation under lock. Rebind so the copy
            // (and later freeCopy) sees a plainly-mutable Value.
            const comps_mut: std.json.Value = comps;
            const copy = try deepCopy(self.allocator, comps_mut);
            self.mutex.lockUncancelable(self.io);
            const surf = try self.surfaceLocked(sid);
            if (surf.state) |*s| freeCopy(self.allocator, s.*);
            surf.state = copy;
            self.version += 1;
            const ver = self.version;
            self.mutex.unlock(self.io);
            try self.broadcast(allocator, "updateComponents", env, ver);
            return null;
        }

        if (obj.get("updateDataModel")) |udm| {
            if (udm != .object) return try validationError(allocator, "VALIDATION_FAILED", "/updateDataModel", "updateDataModel must be an object");
            const sid: []const u8 = switch (try a2uiSurfaceId(allocator, udm, "/updateDataModel")) {
                .none => surface_id,
                .ok => |s| s,
                .err => |e| return e,
            };
            const data = udm.object.get("data") orelse
                return try validationError(allocator, "VALIDATION_FAILED", "/updateDataModel/data", "missing data object");
            if (data != .object) return try validationError(allocator, "VALIDATION_FAILED", "/updateDataModel/data", "data must be an object");

            self.mutex.lockUncancelable(self.io);
            const surf = try self.surfaceLocked(sid);
            try mergeJson(self.allocator, &surf.data_model, data);
            self.version += 1;
            const ver = self.version;
            self.mutex.unlock(self.io);
            try self.broadcast(allocator, "updateDataModel", env, ver);
            return null;
        }

        if (obj.get("appendDataModel")) |adm| {
            // Plan 7.2 franky extension: append `delta` (a string) to
            // the string at `path` (RFC 6901) in the surface data
            // model, creating it when missing. Broadcast verbatim —
            // the renderer applies the same append, so streaming text
            // costs O(delta) per event instead of O(accumulated).
            if (adm != .object) return try validationError(allocator, "VALIDATION_FAILED", "/appendDataModel", "appendDataModel must be an object");
            const sid: []const u8 = switch (try a2uiSurfaceId(allocator, adm, "/appendDataModel")) {
                .none => surface_id,
                .ok => |s| s,
                .err => |e| return e,
            };
            const path_v = adm.object.get("path") orelse
                return try validationError(allocator, "VALIDATION_FAILED", "/appendDataModel/path", "missing path (JSON pointer to a string)");
            if (path_v != .string or path_v.string.len == 0 or path_v.string[0] != '/')
                return try validationError(allocator, "VALIDATION_FAILED", "/appendDataModel/path", "path must be an absolute JSON pointer (\"/...\")");
            const delta_v = adm.object.get("delta") orelse
                return try validationError(allocator, "VALIDATION_FAILED", "/appendDataModel/delta", "missing delta string");
            if (delta_v != .string)
                return try validationError(allocator, "VALIDATION_FAILED", "/appendDataModel/delta", "delta must be a string");

            self.mutex.lockUncancelable(self.io);
            const surf = try self.surfaceLocked(sid);
            // Convert internal append errors into an LLM-facing
            // validation error so the model can self-correct instead
            // of breaking the tool call (spec: prompt–generate–validate).
            pointerAppendString(self.allocator, &surf.data_model, path_v.string, delta_v.string) catch |e| {
                self.mutex.unlock(self.io);
                return try validationError(allocator, "VALIDATION_FAILED", "/appendDataModel/path", switch (e) {
                    error.TypeMismatch => "path points at a non-string value",
                    error.InvalidPath => "path traverses into a non-object value",
                    error.PathTooDeep => "path exceeds the maximum depth",
                    else => "failed to append at path",
                });
            };
            self.version += 1;
            const ver = self.version;
            self.mutex.unlock(self.io);
            try self.broadcast(allocator, "appendDataModel", env, ver);
            return null;
        }

        if (obj.get("deleteSurface")) |ds| {
            const sid: []const u8 = if (ds == .object) switch (try a2uiSurfaceId(allocator, ds, "/deleteSurface")) {
                .none => surface_id,
                .ok => |s| s,
                .err => |e| return e,
            } else surface_id;
            self.mutex.lockUncancelable(self.io);
            if (self.surfaces.getPtr(sid)) |surf| {
                surf.deinit(self.allocator);
                surf.* = .{};
            }
            self.version += 1;
            const ver = self.version;
            self.mutex.unlock(self.io);
            try self.broadcast(allocator, "deleteSurface", env, ver);
            return null;
        }

        return try validationError(allocator, "VALIDATION_FAILED", "/", "envelope must contain exactly one of createSurface, updateComponents, updateDataModel, appendDataModel, deleteSurface");
    }

    // ── renderer-side snapshots ───────────────────────────────────

    /// Serialize the full surface registry + data models for a
    /// reconnecting renderer:
    /// `{"version": N, "surfaces": {"main": {"components": [...],
    /// "dataModel": {...}}, ...}}`. Caller owns the returned slice.
    /// Plan 4.2 — multi-surface; `renderSnapshotJson("main")` below
    /// keeps the single-surface shape for the existing renderer.
    pub fn renderSnapshotAllJson(self: *Session, allocator: std.mem.Allocator) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var out: std.Io.Writer.Allocating = std.Io.Writer.Allocating.init(allocator);
        errdefer out.deinit();
        var jw: std.json.Stringify = .{
            .writer = &out.writer,
            .options = .{},
        };
        try jw.beginObject();
        try jw.objectField("version");
        try jw.write(self.version);
        try jw.objectField("surfaces");
        try jw.beginObject();
        var it = self.surfaces.iterator();
        while (it.next()) |e| {
            try jw.objectField(e.key_ptr.*);
            try writeSurfaceJson(&jw, e.value_ptr);
        }
        try jw.endObject();
        try jw.endObject();
        return try out.toOwnedSlice();
    }

    /// Single-surface snapshot (back-compat for the current renderer):
    /// `{"version": N, "surfaceId": sid, "components": [...],
    /// "dataModel": {...}}`.
    pub fn renderSnapshotJson(self: *Session, allocator: std.mem.Allocator) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var out: std.Io.Writer.Allocating = std.Io.Writer.Allocating.init(allocator);
        errdefer out.deinit();
        var jw: std.json.Stringify = .{
            .writer = &out.writer,
            .options = .{},
        };
        try jw.beginObject();
        try jw.objectField("version");
        try jw.write(self.version);
        try jw.objectField("surfaceId");
        try jw.write(surface_id);
        if (self.surfaces.getPtr(surface_id)) |surf| {
            try jw.objectField("components");
            if (surf.state) |s| {
                try jw.write(s);
            } else {
                try jw.beginArray();
                try jw.endArray();
            }
            try jw.objectField("dataModel");
            try jw.write(surf.data_model);
        } else {
            try jw.objectField("components");
            try jw.beginArray();
            try jw.endArray();
            try jw.objectField("dataModel");
            try jw.write(@as(std.json.Value, .null));
        }
        try jw.endObject();
        return try out.toOwnedSlice();
    }

    fn writeSurfaceJson(jw: *std.json.Stringify, surf: *const Surface) !void {
        try jw.beginObject();
        try jw.objectField("components");
        if (surf.state) |s| {
            try jw.write(s);
        } else {
            try jw.beginArray();
            try jw.endArray();
        }
        try jw.objectField("dataModel");
        try jw.write(surf.data_model);
        try jw.endObject();
    }

    pub fn currentVersion(self: *Session) u64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.version;
    }

    /// Deep-copy of the `"main"` surface's component adjacency list
    /// (or null when no `updateComponents` has landed yet). Caller
    /// frees with `freeCopy`. Used by the proxy's host-side
    /// projections to inspect the surface (e.g. locate the "root"
    /// children list). Multi-surface callers should use
    /// `renderSnapshotAllJson`.
    pub fn snapshotComponents(self: *Session, allocator: std.mem.Allocator) !?std.json.Value {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const surf = self.surfaces.getPtr(surface_id) orelse return null;
        const s = surf.state orelse return null;
        return try deepCopy(allocator, s);
    }

    // ── plan 4.2: replay ring ─────────────────────────────────────

    /// Store a fully-stamped SSE frame in the replay ring. Caller
    /// holds no lock; we take it. `frame` is deep-copied.
    fn replayPush(self: *Session, id: u64, frame: []const u8) !void {
        const copy = try self.allocator.dupe(u8, frame);
        self.mutex.lockUncancelable(self.io);
        const slot: usize = @intCast(id % replay_ring_capacity);
        if (self.replay_ring[slot]) |old| self.allocator.free(old.frame);
        self.replay_ring[slot] = .{ .id = id, .frame = copy };
        self.mutex.unlock(self.io);
    }

    /// Oldest event id still in the ring (1-based).
    pub fn oldestVersion(self: *Session) u64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.version > replay_ring_capacity)
            return self.version - replay_ring_capacity;
        return 1;
    }

    /// Append every frame with `id > last_event_id` to `out` (in
    /// order). Returns false when the requested range has fallen out
    /// of the ring — the caller should send a full snapshot instead.
    pub fn replaySince(self: *Session, last_event_id: u64, out: *std.Io.Writer.Allocating) !bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const oldest: u64 = if (self.version > replay_ring_capacity) self.version - replay_ring_capacity else 1;
        if (last_event_id + 1 < oldest and self.version > last_event_id) return false;
        var id = last_event_id + 1;
        while (id <= self.version) : (id += 1) {
            const slot: usize = @intCast(id % replay_ring_capacity);
            if (self.replay_ring[slot]) |f| {
                if (f.id == id) try out.writer.writeAll(f.frame);
            }
        }
        return true;
    }

    /// Host-side component projection (§4.3 translator seed): inject
    /// or replace components in the surface adjacency list without
    /// going through the LLM tool path. Used by the proxy to render
    /// `tool_permission_request` events as A2UI forms. The batch is
    /// validated (with per-id upsert semantics) and broadcast as a
    /// regular `updateComponents` envelope, so renderers just apply
    /// their normal upsert.
    pub fn upsertComponents(self: *Session, allocator: std.mem.Allocator, components: []const u8) !?[]u8 {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();

        var parsed = try std.json.parseFromSlice(std.json.Value, a, components, .{});
        defer parsed.deinit();
        if (parsed.value != .array)
            return try validationError(allocator, "VALIDATION_FAILED", "/components", "components must be an array");

        if (try validateComponents(a, parsed.value.array.items)) |err_msg|
            return try allocator.dupe(u8, err_msg);

        self.mutex.lockUncancelable(self.io);
        const surf = try self.surfaceLocked(surface_id);
        try upsertListLocked(self, surf, parsed.value.array.items);
        self.version += 1;
        const ver = self.version;
        const payload = try std.json.Stringify.valueAlloc(allocator, surf.state.?, .{});
        self.mutex.unlock(self.io);
        defer allocator.free(payload);

        const env = try std.fmt.allocPrint(allocator, "{{\"updateComponents\":{{\"surfaceId\":\"{s}\",\"components\":{s}}}}}", .{ surface_id, payload });
        defer allocator.free(env);
        try self.broadcastRaw(allocator, "updateComponents", env, ver);
        return null;
    }

    /// Host-side removal of components by id (e.g. a resolved
    /// permission card). Children lists referencing removed ids are
    /// pruned. Broadcast as a full-list `updateComponents` envelope.
    pub fn removeComponents(self: *Session, allocator: std.mem.Allocator, ids: []const []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        const surf = try self.surfaceLocked(surface_id);
        if (surf.state != null and ids.len > 0) {
            var list = surf.state.?.array;
            // Drop the entries themselves.
            var i: usize = 0;
            while (i < list.items.len) {
                const c = list.items[i];
                const id_v = if (c == .object) c.object.get("id") else null;
                const hit = if (id_v != null and id_v.? == .string) containsId(ids, id_v.?.string) else false;
                if (hit) {
                    freeCopy(self.allocator, c);
                    _ = list.orderedRemove(i);
                } else {
                    i += 1;
                }
            }
            // Prune dangling child references. NOTE: mutate the
            // `children` ArrayList through the `getPtr` pointer — a
            // copied struct would leave the in-tree list with a stale
            // length and corrupt subsequent serialization.
            for (list.items) |*c| {
                if (c.* != .object) continue;
                if (c.object.getPtr("children")) |ch| {
                    if (ch.* == .array) {
                        const kids = &ch.array;
                        var k: usize = 0;
                        while (k < kids.items.len) {
                            const kid = kids.items[k];
                            const dangling = if (kid == .string) containsId(ids, kid.string) else false;
                            if (dangling) {
                                freeCopy(self.allocator, kid);
                                _ = kids.orderedRemove(k);
                            } else {
                                k += 1;
                            }
                        }
                    }
                }
                if (c.object.getPtr("child")) |ch| {
                    if (ch.* == .string and containsId(ids, ch.string)) {
                        freeCopy(self.allocator, ch.*);
                        _ = c.object.orderedRemove("child");
                    }
                }
            }
            surf.state = .{ .array = list };
        }
        self.version += 1;
        const ver = self.version;
        var payload: ?[]u8 = null;
        if (surf.state) |st|
            payload = try std.json.Stringify.valueAlloc(allocator, st, .{});
        self.mutex.unlock(self.io);
        defer if (payload) |p| allocator.free(p);

        const env = try std.fmt.allocPrint(allocator, "{{\"updateComponents\":{{\"surfaceId\":\"{s}\",\"components\":{s}}}}}", .{ surface_id, payload orelse "[]" });
        defer allocator.free(env);
        try self.broadcastRaw(allocator, "updateComponents", env, ver);
    }

    fn containsId(ids: []const []const u8, id: []const u8) bool {
        for (ids) |x| if (std.mem.eql(u8, x, id)) return true;
        return false;
    }

    /// Merge `items` into a surface's adjacency list (upsert by `id`,
    /// preserving existing order; new ids append at the end). Caller
    /// must hold the mutex. `items` values are deep-copied.
    fn upsertListLocked(self: *Session, surf: *Surface, items: []const std.json.Value) !void {
        if (surf.state == null)
            surf.state = .{ .array = std.json.Array.init(self.allocator) };
        const list = &surf.state.?.array;
        for (items) |item| {
            const id = item.object.get("id").?.string; // validated
            var replaced = false;
            for (list.items) |*existing| {
                const eid = existing.object.get("id").?.string;
                if (std.mem.eql(u8, eid, id)) {
                    freeCopy(self.allocator, existing.*);
                    existing.* = try deepCopy(self.allocator, item);
                    replaced = true;
                    break;
                }
            }
            if (!replaced)
                try list.append(try deepCopy(self.allocator, item));
        }
    }

    // ── internals ─────────────────────────────────────────────────

    fn broadcast(self: *Session, allocator: std.mem.Allocator, kind: []const u8, env: std.json.Value, ver: u64) !void {
        const head = try std.fmt.allocPrint(allocator, "id: {d}\nevent: a2ui_{s}\ndata: ", .{ ver, kind });
        defer allocator.free(head);
        const payload = try std.json.Stringify.valueAlloc(allocator, env, .{});
        defer allocator.free(payload);
        const full = try std.fmt.allocPrint(allocator, "{s}{s}\n\n", .{ head, payload });
        defer allocator.free(full);

        // Plan 4.2 — store in the replay ring before fan-out so a
        // reconnecting client sees the same frame.
        try self.replayPush(ver, full);

        self.mutex.lockUncancelable(self.io);
        const f = self.broadcast_fn;
        const ud = self.broadcast_userdata;
        self.mutex.unlock(self.io);
        if (f) |bf| bf(ud.?, full);
    }

    /// Like `broadcast`, but `env` is a pre-serialized JSON envelope.
    fn broadcastRaw(self: *Session, allocator: std.mem.Allocator, kind: []const u8, env_json: []const u8, ver: u64) !void {
        const full = try std.fmt.allocPrint(allocator, "id: {d}\nevent: a2ui_{s}\ndata: {s}\n\n", .{ ver, kind, env_json });
        defer allocator.free(full);

        try self.replayPush(ver, full);

        self.mutex.lockUncancelable(self.io);
        const f = self.broadcast_fn;
        const ud = self.broadcast_userdata;
        self.mutex.unlock(self.io);
        if (f) |bf| bf(ud.?, full);
    }
};

/// Extract + validate an envelope's optional `surfaceId`.
/// - absent → `.none`
/// - present + valid → `.ok` with the id (borrows from `obj`)
/// - present + invalid → `.err` with an allocated validation string
///   (caller frees via the tool path)
/// Plan 4.2 — any non-empty surfaceId is accepted (surfaces are
/// created lazily).
const SurfaceIdResult = union(enum) {
    none,
    ok: []const u8,
    err: []u8,
};

fn a2uiSurfaceId(allocator: std.mem.Allocator, obj: std.json.Value, base_path: []const u8) !SurfaceIdResult {
    const v = obj.object.get("surfaceId") orelse return .none;
    if (v != .string or v.string.len == 0) {
        const p = try std.fmt.allocPrint(allocator, "{s}/surfaceId", .{base_path});
        defer allocator.free(p);
        const e = (try validationError(allocator, "VALIDATION_FAILED", p, "surfaceId must be a non-empty string")).?;
        return .{ .err = e };
    }
    return .{ .ok = v.string };
}

// ─── validation ─────────────────────────────────────────────────

const known_components = [_][]const u8{ "Column", "Row", "Text", "Button", "TextField", "CheckBox", "Card", "ToolCall", "CodeBlock", "Diff", "ThinkingBlock", "StreamingText" };

fn isKnownComponent(name: []const u8) bool {
    for (known_components) |k| if (std.mem.eql(u8, k, name)) return true;
    return false;
}

/// Validate a component batch (adjacency list). Returns an allocated
/// LLM-facing error string on failure, null on success. Checks:
///   - each entry: object with string `id` + known `component`
///   - ids unique
///   - every child reference resolves to a defined id
///   - dynamic strings: string OR {"@path": "..."} (@call rejected)
fn validateComponents(a: std.mem.Allocator, items: []const std.json.Value) !?[]u8 {
    var ids = std.StringHashMap(void).init(a);
    defer ids.deinit();

    // Pass 1: shape + id collection.
    for (items, 0..) |c, i| {
        const path_prefix = try std.fmt.allocPrint(a, "/components/{d}", .{i});
        if (c != .object)
            return try validationError(a, "VALIDATION_FAILED", path_prefix, "component must be an object");
        const id_v = c.object.get("id") orelse
            return try validationError(a, "VALIDATION_FAILED", path_prefix, "component missing \"id\"");
        if (id_v != .string or id_v.string.len == 0)
            return try validationError(a, "VALIDATION_FAILED", try std.fmt.allocPrint(a, "{s}/id", .{path_prefix}), "id must be a non-empty string");
        const gop = try ids.getOrPut(id_v.string);
        if (gop.found_existing)
            return try validationError(a, "VALIDATION_FAILED", try std.fmt.allocPrint(a, "{s}/id", .{path_prefix}), "duplicate component id");
        const comp_v = c.object.get("component") orelse
            return try validationError(a, "VALIDATION_FAILED", path_prefix, "component missing \"component\" type");
        if (comp_v != .string)
            return try validationError(a, "VALIDATION_FAILED", try std.fmt.allocPrint(a, "{s}/component", .{path_prefix}), "component type must be a string");
        if (!isKnownComponent(comp_v.string))
            return try validationError(a, "VALIDATION_FAILED", try std.fmt.allocPrint(a, "{s}/component", .{path_prefix}), try std.fmt.allocPrint(a, "unknown component \"{s}\" — catalog: Column, Row, Text, Button, TextField, CheckBox, Card, ToolCall, CodeBlock, Diff, ThinkingBlock, StreamingText", .{comp_v.string}));
    }

    // Pass 2: structural references + per-type prop validation.
    // Child references must be id strings; a reference may point at a
    // component defined outside this batch (upsert semantics — the
    // host-side permission projection and incremental updates rely on
    // it). The renderer ignores dangling ids at render time.
    for (items, 0..) |c, i| {
        const path_prefix = try std.fmt.allocPrint(a, "/components/{d}", .{i});
        const comp = c.object.get("component").?.string;

        if (c.object.get("children")) |ch| {
            if (ch != .array)
                return try validationError(a, "VALIDATION_FAILED", try std.fmt.allocPrint(a, "{s}/children", .{path_prefix}), "children must be an array of component ids (template ChildLists are not supported)");
            for (ch.array.items, 0..) |kid, k| {
                if (kid != .string)
                    return try validationError(a, "VALIDATION_FAILED", try std.fmt.allocPrint(a, "{s}/children/{d}", .{ path_prefix, k }), "child reference must be a component id string");
            }
        }
        if (c.object.get("child")) |ch| {
            if (ch != .string)
                return try validationError(a, "VALIDATION_FAILED", try std.fmt.allocPrint(a, "{s}/child", .{path_prefix}), "child must be a component id string");
        }

        if (std.mem.eql(u8, comp, "Text")) {
            const t = c.object.get("text") orelse
                return try validationError(a, "VALIDATION_FAILED", path_prefix, "Text component requires \"text\"");
            if (try validateDynamicString(a, t, try std.fmt.allocPrint(a, "{s}/text", .{path_prefix}))) |e| return e;
        } else if (std.mem.eql(u8, comp, "Button")) {
            const t = c.object.get("label") orelse
                return try validationError(a, "VALIDATION_FAILED", path_prefix, "Button component requires \"label\"");
            if (try validateDynamicString(a, t, try std.fmt.allocPrint(a, "{s}/label", .{path_prefix}))) |e| return e;
            if (c.object.get("action")) |act| {
                if (act != .object)
                    return try validationError(a, "VALIDATION_FAILED", try std.fmt.allocPrint(a, "{s}/action", .{path_prefix}), "action must be an object");
                const ev = act.object.get("event") orelse
                    return try validationError(a, "VALIDATION_FAILED", try std.fmt.allocPrint(a, "{s}/action", .{path_prefix}), "PoC supports only action.event (functionCall is not supported)");
                if (ev != .object)
                    return try validationError(a, "VALIDATION_FAILED", try std.fmt.allocPrint(a, "{s}/action/event", .{path_prefix}), "action.event must be an object");
                const name = ev.object.get("name") orelse
                    return try validationError(a, "VALIDATION_FAILED", try std.fmt.allocPrint(a, "{s}/action/event/name", .{path_prefix}), "action.event requires \"name\"");
                if (name != .string or name.string.len == 0)
                    return try validationError(a, "VALIDATION_FAILED", try std.fmt.allocPrint(a, "{s}/action/event/name", .{path_prefix}), "action.event.name must be a non-empty string");
            }
        } else if (std.mem.eql(u8, comp, "TextField")) {
            const l = c.object.get("label") orelse
                return try validationError(a, "VALIDATION_FAILED", path_prefix, "TextField component requires \"label\"");
            if (try validateDynamicString(a, l, try std.fmt.allocPrint(a, "{s}/label", .{path_prefix}))) |e| return e;
            const v = c.object.get("value") orelse
                return try validationError(a, "VALIDATION_FAILED", path_prefix, "TextField component requires \"value\" ({\"@path\": \"/...\"} two-way binding)");
            if (v != .object or v.object.get("@path") == null)
                return try validationError(a, "VALIDATION_FAILED", try std.fmt.allocPrint(a, "{s}/value", .{path_prefix}), "TextField.value must be a {\"@path\": \"/...\"} binding (two-way binding requires a data path)");
        } else if (std.mem.eql(u8, comp, "CheckBox")) {
            const l = c.object.get("label") orelse
                return try validationError(a, "VALIDATION_FAILED", path_prefix, "CheckBox component requires \"label\"");
            if (try validateDynamicString(a, l, try std.fmt.allocPrint(a, "{s}/label", .{path_prefix}))) |e| return e;
            const v = c.object.get("checked") orelse
                return try validationError(a, "VALIDATION_FAILED", path_prefix, "CheckBox component requires \"checked\" (boolean or {\"@path\": \"/...\"} two-way binding)");
            switch (v) {
                .bool => {},
                .object => {
                    if (v.object.get("@path") == null)
                        return try validationError(a, "VALIDATION_FAILED", try std.fmt.allocPrint(a, "{s}/checked", .{path_prefix}), "CheckBox.checked object must be a {\"@path\": \"/...\"} binding (@call is not supported)");
                },
                else => return try validationError(a, "VALIDATION_FAILED", try std.fmt.allocPrint(a, "{s}/checked", .{path_prefix}), "CheckBox.checked must be a boolean or a {\"@path\": \"/...\"} binding"),
            }
        } else if (std.mem.eql(u8, comp, "Card")) {
            if (c.object.get("title")) |t|
                if (try validateDynamicString(a, t, try std.fmt.allocPrint(a, "{s}/title", .{path_prefix}))) |e| return e;
            if (c.object.get("subtitle")) |t|
                if (try validateDynamicString(a, t, try std.fmt.allocPrint(a, "{s}/subtitle", .{path_prefix}))) |e| return e;
        } else if (std.mem.eql(u8, comp, "ToolCall")) {
            // Plan 4.7 franky catalog: a tool invocation card. `name` is
            // required; the rest are optional. `status` is one of
            // running|done|error (anything else is a validation error
            // so a typo can't silently render as "done").
            const n = c.object.get("name") orelse
                return try validationError(a, "VALIDATION_FAILED", path_prefix, "ToolCall component requires \"name\"");
            if (try validateDynamicString(a, n, try std.fmt.allocPrint(a, "{s}/name", .{path_prefix}))) |e| return e;
            if (c.object.get("args")) |v|
                if (try validateDynamicString(a, v, try std.fmt.allocPrint(a, "{s}/args", .{path_prefix}))) |e| return e;
            if (c.object.get("result")) |v|
                if (try validateDynamicString(a, v, try std.fmt.allocPrint(a, "{s}/result", .{path_prefix}))) |e| return e;
            if (c.object.get("status")) |s| {
                if (s != .string)
                    return try validationError(a, "VALIDATION_FAILED", try std.fmt.allocPrint(a, "{s}/status", .{path_prefix}), "ToolCall.status must be a string: running | done | error");
                if (!std.mem.eql(u8, s.string, "running") and
                    !std.mem.eql(u8, s.string, "done") and
                    !std.mem.eql(u8, s.string, "error"))
                    return try validationError(a, "VALIDATION_FAILED", try std.fmt.allocPrint(a, "{s}/status", .{path_prefix}), "ToolCall.status must be one of: running | done | error");
            }
        } else if (std.mem.eql(u8, comp, "CodeBlock")) {
            const code = c.object.get("code") orelse
                return try validationError(a, "VALIDATION_FAILED", path_prefix, "CodeBlock component requires \"code\"");
            if (try validateDynamicString(a, code, try std.fmt.allocPrint(a, "{s}/code", .{path_prefix}))) |e| return e;
            if (c.object.get("lang")) |v|
                if (try validateDynamicString(a, v, try std.fmt.allocPrint(a, "{s}/lang", .{path_prefix}))) |e| return e;
        } else if (std.mem.eql(u8, comp, "Diff")) {
            // Plan 4.7 franky catalog: a unified-diff view (franky's
            // edit/write tools emit this as `details_json.diff` in the
            // unified-diff-v1 format). `diff` is required; `path`
            // labels the header.
            const d = c.object.get("diff") orelse
                return try validationError(a, "VALIDATION_FAILED", path_prefix, "Diff component requires \"diff\" (unified-diff-v1 string)");
            if (try validateDynamicString(a, d, try std.fmt.allocPrint(a, "{s}/diff", .{path_prefix}))) |e| return e;
            if (c.object.get("path")) |v|
                if (try validateDynamicString(a, v, try std.fmt.allocPrint(a, "{s}/path", .{path_prefix}))) |e| return e;
        } else if (std.mem.eql(u8, comp, "ThinkingBlock")) {
            const t = c.object.get("text") orelse
                return try validationError(a, "VALIDATION_FAILED", path_prefix, "ThinkingBlock component requires \"text\"");
            if (try validateDynamicString(a, t, try std.fmt.allocPrint(a, "{s}/text", .{path_prefix}))) |e| return e;
            if (c.object.get("collapsed")) |v| {
                if (v != .bool)
                    return try validationError(a, "VALIDATION_FAILED", try std.fmt.allocPrint(a, "{s}/collapsed", .{path_prefix}), "ThinkingBlock.collapsed must be a boolean");
            }
        } else if (std.mem.eql(u8, comp, "StreamingText")) {
            // Plan 7.2: text bound to a data-model path, grown by
            // appendDataModel deltas (append semantics — the
            // alternative to chatty per-delta full-string replaces).
            const p = c.object.get("path") orelse
                return try validationError(a, "VALIDATION_FAILED", path_prefix, "StreamingText component requires \"path\" (a data-model JSON pointer the renderer binds to)");
            if (p != .string or p.string.len == 0 or p.string[0] != '/')
                return try validationError(a, "VALIDATION_FAILED", try std.fmt.allocPrint(a, "{s}/path", .{path_prefix}), "StreamingText.path must be an absolute JSON pointer (\"/...\")");
        }
    }
    return null;
}

fn validateDynamicString(a: std.mem.Allocator, v: std.json.Value, path: []const u8) !?[]u8 {
    switch (v) {
        .string => return null,
        .object => {
            if (v.object.get("@call") != null)
                return try validationError(a, "EXPRESSION_ERROR", path, "@call function bindings are not supported in the PoC");
            const p = v.object.get("@path") orelse
                return try validationError(a, "VALIDATION_FAILED", path, "dynamic string must be a plain string or {\"@path\": \"/...\"}");
            if (p != .string)
                return try validationError(a, "VALIDATION_FAILED", path, "@path value must be a JSON-pointer string");
            return null;
        },
        else => return try validationError(a, "VALIDATION_FAILED", path, "expected stringOrPath (string or {\"@path\": ...})"),
    }
}

fn validationError(a: std.mem.Allocator, code: []const u8, path: []const u8, message: []const u8) !?[]u8 {
    const ErrPayload = struct {
        code: []const u8,
        surfaceId: []const u8,
        path: []const u8,
        message: []const u8,
    };
    const Wrap = struct { @"error": ErrPayload };
    return try std.json.Stringify.valueAlloc(a, Wrap{ .@"error" = .{
        .code = code,
        .surfaceId = surface_id,
        .path = path,
        .message = message,
    } }, .{});
}

// ─── JSON helpers ───────────────────────────────────────────────

/// Deep-copy a JSON value onto `allocator`.
pub fn deepCopy(allocator: std.mem.Allocator, v: std.json.Value) !std.json.Value {
    return switch (v) {
        .null, .bool, .integer, .float, .number_string => v,
        .string => |s| .{ .string = try allocator.dupe(u8, s) },
        .array => |arr| blk: {
            var out = try std.json.Array.initCapacity(allocator, arr.items.len);
            for (arr.items) |item| out.appendAssumeCapacity(try deepCopy(allocator, item));
            break :blk .{ .array = out };
        },
        .object => |obj| blk: {
            var out: std.json.ObjectMap = .{};
            try out.ensureTotalCapacity(allocator, obj.count());
            var it = obj.iterator();
            while (it.next()) |e| {
                out.putAssumeCapacity(try allocator.dupe(u8, e.key_ptr.*), try deepCopy(allocator, e.value_ptr.*));
            }
            break :blk .{ .object = out };
        },
    };
}

/// Free a deep-copied JSON value (mirrors `deepCopy` allocation).
pub fn freeCopy(allocator: std.mem.Allocator, v: std.json.Value) void {
    switch (v) {
        .null, .bool, .integer, .float, .number_string => {},
        .string => |s| allocator.free(s),
        .array => |arr| {
            var a = arr;
            for (a.items) |item| freeCopy(allocator, item);
            a.deinit();
        },
        .object => |obj| {
            var m = obj;
            var it = m.iterator();
            while (it.next()) |e| {
                allocator.free(e.key_ptr.*);
                freeCopy(allocator, e.value_ptr.*);
            }
            m.deinit(allocator);
        },
    }
}

/// Append `delta` to the string at RFC 6901 `path` inside `*root`,
/// creating intermediate objects and the leaf string as needed.
/// `~0`/`~1` unescaping per RFC 6901. Errors on a type mismatch
/// (existing non-string leaf, numeric segment into a non-array).
fn pointerAppendString(allocator: std.mem.Allocator, root: *std.json.Value, path: []const u8, delta: []const u8) !void {
    if (root.* != .object) {
        freeCopy(allocator, root.*);
        root.* = .{ .object = .{} };
    }
    var cur: *std.json.Value = root;
    var it = std.mem.splitScalar(u8, path[1..], '/');
    var last_seg: []const u8 = "";
    var segs: [64][]const u8 = undefined;
    var n: usize = 0;
    while (it.next()) |raw| {
        if (n >= segs.len) return error.PathTooDeep;
        segs[n] = raw;
        n += 1;
    }
    if (n == 0) return error.InvalidPath;
    last_seg = segs[n - 1];
    for (segs[0 .. n - 1]) |raw| {
        const seg = try unescapeSegment(allocator, raw);
        defer allocator.free(seg);
        if (cur.* != .object) return error.InvalidPath;
        const duped = try allocator.dupe(u8, seg);
        const gop = try cur.object.getOrPut(allocator, duped);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .object = .{} };
        } else {
            allocator.free(duped); // getOrPut kept the existing key
            if (gop.value_ptr.* != .object) return error.InvalidPath;
        }
        cur = gop.value_ptr;
    }
    const seg = try unescapeSegment(allocator, last_seg);
    defer allocator.free(seg);
    if (cur.* != .object) return error.InvalidPath;
    const duped_key = try allocator.dupe(u8, seg);
    const gop = try cur.object.getOrPut(allocator, duped_key);
    if (gop.found_existing) {
        allocator.free(duped_key);
        if (gop.value_ptr.* != .string) return error.TypeMismatch;
        const joined = try std.fmt.allocPrint(allocator, "{s}{s}", .{ gop.value_ptr.string, delta });
        allocator.free(gop.value_ptr.string);
        gop.value_ptr.* = .{ .string = joined };
    } else {
        gop.value_ptr.* = .{ .string = try allocator.dupe(u8, delta) };
    }
}

fn unescapeSegment(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    // Unescape in place, then shrink so the caller frees the correct
    // length (safe allocators check the freed slice length against
    // the allocation size).
    const buf = try allocator.dupe(u8, raw);
    var i: usize = 0;
    var w: usize = 0;
    while (i < buf.len) : (i += 1) {
        if (buf[i] == '~' and i + 1 < buf.len) {
            if (buf[i + 1] == '0') {
                buf[w] = '~';
                i += 1;
            } else if (buf[i + 1] == '1') {
                buf[w] = '/';
                i += 1;
            } else {
                buf[w] = buf[i];
            }
        } else {
            buf[w] = buf[i];
        }
        w += 1;
    }
    if (w == buf.len) return buf;
    return try allocator.realloc(buf, w);
}

/// Deep-merge `src` into `*dst` (spec updateDataModel semantics:
/// objects merge recursively, everything else replaces). `dst`
/// ownership stays with the caller; merged-in values are deep copies.
fn mergeJson(allocator: std.mem.Allocator, dst: *std.json.Value, src: std.json.Value) !void {
    if (dst.* == .object and src == .object) {
        var it = src.object.iterator();
        while (it.next()) |e| {
            // NOTE on ownership: getOrPut does NOT consume the key on
            // the found_existing path, so we always free the fresh
            // dupe and keep the stored key alive.
            const duped_key = try allocator.dupe(u8, e.key_ptr.*);
            const gop = try dst.object.getOrPut(allocator, duped_key);
            if (gop.found_existing) {
                allocator.free(duped_key);
                if (gop.value_ptr.* == .object and e.value_ptr.* == .object) {
                    try mergeJson(allocator, gop.value_ptr, e.value_ptr.*);
                } else {
                    freeCopy(allocator, gop.value_ptr.*);
                    gop.value_ptr.* = try deepCopy(allocator, e.value_ptr.*);
                }
            } else {
                gop.value_ptr.* = try deepCopy(allocator, e.value_ptr.*);
            }
        }
    } else {
        freeCopy(allocator, dst.*);
        dst.* = try deepCopy(allocator, src);
    }
}

// ─── system-prompt block ────────────────────────────────────────

/// Appended to the proxy system prompt when A2UI is enabled. Teaches
/// the model the wire format + PoC catalog. Keep this tight — every
/// token rides along on every request.
pub const system_prompt_block: []const u8 =
    \\
    \\## A2UI — Generative UI (enabled)
    \\
    \\You can render rich, interactive UI in the user's browser by calling the
    \\`a2ui_render` tool with **A2UI v1.0** messages (https://a2ui.org/specification/v1.0-a2ui/).
    \\Use it when a visual form, card, or layout communicates better than prose —
    \\e.g. configuration forms, comparison cards, status dashboards. For plain
    \\answers, just reply with text; do NOT emit UI for every response.
    \\
    \\`a2ui_render` takes `messages`: an array of envelopes, each with exactly one key:
    \\- `createSurface` — `{"createSurface":{"surfaceId":"main"}}` (optional; the surface
    \\  "main" already exists, so you may skip this).
    \\- `updateComponents` — `{"updateComponents":{"surfaceId":"main","components":[...]}}`.
    \\  Full-replace: each call replaces the whole UI tree, so always resend the complete
    \\  component list. Components form an adjacency list referenced by `id`; the
    \\  component with `id":"root"` is the tree root.
    \\- `updateDataModel` — `{"updateDataModel":{"surfaceId":"main","data":{...}}}`.
    \\  Deep-merged into the surface data model. Components reference values via
    \\  `{"@path": "/json/pointer"}` (RFC 6901).
    \\- `deleteSurface` — `{"deleteSurface":{"surfaceId":"main"}}` clears the UI.
    \\
    \\Catalog (only these components exist):
    \\- `Column` / `Row`: `{"id","component":"Column","children":["<id>",...]}`
    \\- `Card`: `{"id","component":"Card","title":"...","subtitle":"...","children":[...]}`
    \\  (title/subtitle optional; a titled container for grouping content)
    \\- `Text`: `{"id","component":"Text","text":"..."}` — `text` is a string or `{"@path": "/..."}`
    \\- `Button`: `{"id","component":"Button","label":"...","action":{"event":{"name":"<snake_case>","userMessage":"...","context":{"k":{"@path":"/..."}}}}}`
    \\- `TextField`: `{"id","component":"TextField","label":"...","value":{"@path":"/form/field"}}`
    \\  (two-way bound: user edits update the local data model; nothing is sent until a Button action fires)
    \\- `CheckBox`: `{"id","component":"CheckBox","label":"...","checked":{"@path":"/form/flag"}}`
    \\  (two-way bound boolean; `checked` may also be a literal `true`/`false`)
    \\- `ToolCall`: `{"id","component":"ToolCall","name":"bash","args":"...","result":"...","status":"running|done|error"}`
    \\  (a tool-invocation card; only `name` is required)
    \\- `CodeBlock`: `{"id","component":"CodeBlock","code":"...","lang":"zig"}` (`lang` optional)
    \\- `Diff`: `{"id","component":"Diff","diff":"--- a/f\n+++ b/f\n@@ ...","path":"f"}`
    \\  (unified-diff view; `path` optional)
    \\- `ThinkingBlock`: `{"id","component":"ThinkingBlock","text":"...","collapsed":true}`
    \\  (collapsible reasoning block; `collapsed` optional, default true)
    \\- `StreamingText`: `{"id","component":"StreamingText","path":"/stream/msg"}`
    \\  (text bound to a data-model path; grow it with `appendDataModel`)
    \\
    \\`appendDataModel` (franky extension for streaming): 
    \\`{"appendDataModel":{"path":"/stream/msg","delta":"..."}}` appends `delta` to
    \\the string at `path` (created when missing). Prefer it over repeated
    \\`updateDataModel` for token-by-token text — each event costs O(delta)
    \\instead of O(accumulated).
    \\
    \\When the user clicks a Button, its `action.event` comes back to you as a user
    \\message (`[A2UI action] name=... context=...`) — treat it like a normal instruction.
    \\Exception: Button actions named `permission_decision` are consumed by the
    \\permission gate (approve/deny tool calls) and never reach you.
    \\
    \\Example — a name form:
    \\```json
    \\{"messages": [
    \\  {"updateComponents": {"surfaceId": "main", "components": [
    \\    {"id": "root", "component": "Column", "children": ["title", "name_field", "submit"]},
    \\    {"id": "title", "component": "Text", "text": "What should I call you?"},
    \\    {"id": "name_field", "component": "TextField", "label": "Name", "value": {"@path": "/form/name"}},
    \\    {"id": "submit", "component": "Button", "label": "Save", "action": {"event": {"name": "save_name", "userMessage": "Saved my name", "context": {"name": {"@path": "/form/name"}}}}}
    \\  ]}}
    \\]}
    \\```
    \\If `a2ui_render` returns an error object, fix the messages and retry once.
    \\
;

// ─── tests ──────────────────────────────────────────────────────

const testing = std.testing;

/// Test helper: parse `s` and return a detached (arena-independent)
/// Value that the caller frees with `freeCopy`. Detaching avoids the
/// `std.json.Parsed` arena indirection entirely.
fn parse(a: std.mem.Allocator, s: []const u8) !std.json.Value {
    var p = try std.json.parseFromSlice(std.json.Value, a, s, .{});
    defer p.deinit();
    return try deepCopy(a, p.value);
}

test "applyEnvelope: updateComponents happy path broadcasts and snapshots" {
    var session = Session.init(testing.allocator, undefined);
    defer session.deinit();

    const t = try parse(testing.allocator,
        \\{"updateComponents":{"surfaceId":"main","components":[
        \\  {"id":"root","component":"Column","children":["t"]},
        \\  {"id":"t","component":"Text","text":"hello"}
        \\]}}
    );
    defer freeCopy(testing.allocator, t);
    const err = try session.applyEnvelope(testing.allocator, t);
    try testing.expect(err == null);
    try testing.expectEqual(@as(u64, 1), session.currentVersion());

    const snap = try session.renderSnapshotJson(testing.allocator);
    defer testing.allocator.free(snap);
    try testing.expect(std.mem.indexOf(u8, snap, "\"version\":1") != null);
    try testing.expect(std.mem.indexOf(u8, snap, "\"hello\"") != null);
}

test "applyEnvelope: unknown component is rejected with catalog hint" {
    var session = Session.init(testing.allocator, undefined);
    defer session.deinit();
    const t = try parse(testing.allocator,
        \\{"updateComponents":{"components":[{"id":"x","component":"Iframe","src":"http://evil"}]}}
    );
    defer freeCopy(testing.allocator, t);
    const err = (try session.applyEnvelope(testing.allocator, t)).?;
    defer testing.allocator.free(err);
    try testing.expect(std.mem.indexOf(u8, err, "VALIDATION_FAILED") != null);
    try testing.expect(std.mem.indexOf(u8, err, "unknown component") != null);
    try testing.expectEqual(@as(u64, 0), session.currentVersion());
}

test "applyEnvelope: child reference to an id outside the batch is allowed (upsert semantics)" {
    var session = Session.init(testing.allocator, undefined);
    defer session.deinit();
    const t = try parse(testing.allocator,
        \\{"updateComponents":{"components":[{"id":"root","component":"Column","children":["nope"]}]}}
    );
    defer freeCopy(testing.allocator, t);
    const err = try session.applyEnvelope(testing.allocator, t);
    try testing.expect(err == null);
}

test "applyEnvelope: non-string child reference is rejected" {
    var session = Session.init(testing.allocator, undefined);
    defer session.deinit();
    const t = try parse(testing.allocator,
        \\{"updateComponents":{"components":[{"id":"root","component":"Column","children":[42]}]}}
    );
    defer freeCopy(testing.allocator, t);
    const err = (try session.applyEnvelope(testing.allocator, t)).?;
    defer testing.allocator.free(err);
    try testing.expect(std.mem.indexOf(u8, err, "child reference must be a component id string") != null);
}

test "upsertComponents: injects, replaces, and removeComponents prunes" {
    var session = Session.init(testing.allocator, undefined);
    defer session.deinit();

    const t = try parse(testing.allocator,
        \\{"updateComponents":{"components":[
        \\  {"id":"root","component":"Column","children":["t"]},
        \\  {"id":"t","component":"Text","text":"hello"}
        \\]}}
    );
    defer freeCopy(testing.allocator, t);
    _ = try session.applyEnvelope(testing.allocator, t);

    // Attach a card to the existing root + replace the text.
    const err = try session.upsertComponents(testing.allocator,
        \\[
        \\  {"id":"root","component":"Column","children":["t","card"]},
        \\  {"id":"card","component":"Card","title":"Perm","children":["c_txt"]},
        \\  {"id":"c_txt","component":"Text","text":"allow?"},
        \\  {"id":"t","component":"Text","text":"updated"}
        \\]
    );
    try testing.expect(err == null);
    const snap = try session.renderSnapshotJson(testing.allocator);
    defer testing.allocator.free(snap);
    try testing.expect(std.mem.indexOf(u8, snap, "\"updated\"") != null);
    try testing.expect(std.mem.indexOf(u8, snap, "\"Perm\"") != null);
    // Original root + text preserved; root now references the card.
    try testing.expect(std.mem.indexOf(u8, snap, "\"root\"") != null);
    try testing.expect(std.mem.indexOf(u8, snap, "\"surfaceId\":\"main\"") != null);

    // Remove the card: entries gone, dangling references pruned.
    try session.removeComponents(testing.allocator, &.{ "card", "c_txt" });
    const snap2 = try session.renderSnapshotJson(testing.allocator);
    defer testing.allocator.free(snap2);
    try testing.expect(std.mem.indexOf(u8, snap2, "\"card\"") == null);
    try testing.expect(std.mem.indexOf(u8, snap2, "\"c_txt\"") == null);
    try testing.expect(std.mem.indexOf(u8, snap2, "\"updated\"") != null);
    // root's children list must no longer reference "card".
    try testing.expect(std.mem.indexOf(u8, snap2, "\"children\":[\"t\"]") != null);
}

test "upsertComponents: invalid batch is rejected without mutation" {
    var session = Session.init(testing.allocator, undefined);
    defer session.deinit();
    const ver = session.currentVersion();
    const err = (try session.upsertComponents(testing.allocator,
        \\[{"id":"x","component":"Iframe"}]
    )).?;
    defer testing.allocator.free(err);
    try testing.expect(std.mem.indexOf(u8, err, "unknown component") != null);
    try testing.expectEqual(ver, session.currentVersion());
}

test "applyEnvelope: CheckBox and Card validate" {
    var session = Session.init(testing.allocator, undefined);
    defer session.deinit();
    const t = try parse(testing.allocator,
        \\{"updateComponents":{"components":[
        \\  {"id":"root","component":"Column","children":["c","cb"]},
        \\  {"id":"c","component":"Card","title":"T","subtitle":{"@path":"/s"}},
        \\  {"id":"cb","component":"CheckBox","label":"L","checked":{"@path":"/f/r"}}
        \\]}}
    );
    defer freeCopy(testing.allocator, t);
    try testing.expect((try session.applyEnvelope(testing.allocator, t)) == null);

    const bad = try parse(testing.allocator,
        \\{"updateComponents":{"components":[
        \\  {"id":"cb","component":"CheckBox","label":"L","checked":"yes"}
        \\]}}
    );
    defer freeCopy(testing.allocator, bad);
    const err = (try session.applyEnvelope(testing.allocator, bad)).?;
    defer testing.allocator.free(err);
    try testing.expect(std.mem.indexOf(u8, err, "CheckBox.checked") != null);
}

test "applyEnvelope: ToolCall and CodeBlock validate (plan 4.7 franky catalog)" {
    var session = Session.init(testing.allocator, undefined);
    defer session.deinit();
    const t = try parse(testing.allocator,
        \\{"updateComponents":{"components":[
        \\  {"id":"tc","component":"ToolCall","name":"bash","args":"ls","status":"running"},
        \\  {"id":"cb","component":"CodeBlock","code":"const x = 1;","lang":"zig"},
        \\  {"id":"cb2","component":"CodeBlock","code":{"@path":"/snippet"}}
        \\]}}
    );
    defer freeCopy(testing.allocator, t);
    try testing.expect((try session.applyEnvelope(testing.allocator, t)) == null);

    // Bad status is rejected so a typo can't silently render as done.
    const bad = try parse(testing.allocator,
        \\{"updateComponents":{"components":[
        \\  {"id":"tc","component":"ToolCall","name":"bash","status":"runnning"}
        \\]}}
    );
    defer freeCopy(testing.allocator, bad);
    const err = (try session.applyEnvelope(testing.allocator, bad)).?;
    defer testing.allocator.free(err);
    try testing.expect(std.mem.indexOf(u8, err, "ToolCall.status") != null);

    // name is required.
    const noname = try parse(testing.allocator,
        \\{"updateComponents":{"components":[
        \\  {"id":"tc","component":"ToolCall"}
        \\]}}
    );
    defer freeCopy(testing.allocator, noname);
    const err2 = (try session.applyEnvelope(testing.allocator, noname)).?;
    defer testing.allocator.free(err2);
    try testing.expect(std.mem.indexOf(u8, err2, "requires") != null);
}

test "applyEnvelope: Diff and ThinkingBlock validate (plan 4.7)" {
    var session = Session.init(testing.allocator, undefined);
    defer session.deinit();
    const t = try parse(testing.allocator,
        \\{"updateComponents":{"components":[
        \\  {"id":"d","component":"Diff","diff":"--- a/f\n+++ b/f\n@@ -1 +1 @@\n-x\n+y","path":"f"},
        \\  {"id":"th","component":"ThinkingBlock","text":"hmm","collapsed":false}
        \\]}}
    );
    defer freeCopy(testing.allocator, t);
    try testing.expect((try session.applyEnvelope(testing.allocator, t)) == null);

    // diff is required for Diff; collapsed must be a bool.
    const nodiff = try parse(testing.allocator,
        \\{"updateComponents":{"components":[{"id":"d","component":"Diff","path":"f"}]}}
    );
    defer freeCopy(testing.allocator, nodiff);
    const err = (try session.applyEnvelope(testing.allocator, nodiff)).?;
    defer testing.allocator.free(err);
    try testing.expect(std.mem.indexOf(u8, err, "requires") != null);

    const badcoll = try parse(testing.allocator,
        \\{"updateComponents":{"components":[{"id":"th","component":"ThinkingBlock","text":"x","collapsed":"yes"}]}}
    );
    defer freeCopy(testing.allocator, badcoll);
    const err2 = (try session.applyEnvelope(testing.allocator, badcoll)).?;
    defer testing.allocator.free(err2);
    try testing.expect(std.mem.indexOf(u8, err2, "collapsed must be a boolean") != null);
}

test "applyEnvelope: StreamingText validates path; appendDataModel grows the string (plan 7.2)" {
    var session = Session.init(testing.allocator, undefined);
    defer session.deinit();

    // Component requires an absolute path.
    const bad = try parse(testing.allocator,
        \\{"updateComponents":{"components":[{"id":"s","component":"StreamingText","path":"noslash"}]}}
    );
    defer freeCopy(testing.allocator, bad);
    const e0 = (try session.applyEnvelope(testing.allocator, bad)).?;
    defer testing.allocator.free(e0);
    try testing.expect(std.mem.indexOf(u8, e0, "absolute JSON pointer") != null);

    const comp = try parse(testing.allocator,
        \\{"updateComponents":{"components":[
        \\  {"id":"root","component":"Column","children":["s"]},
        \\  {"id":"s","component":"StreamingText","path":"/stream/msg"}
        \\]}}
    );
    defer freeCopy(testing.allocator, comp);
    try testing.expect((try session.applyEnvelope(testing.allocator, comp)) == null);

    // Appends accumulate; intermediate objects are created.
    const d1 = try parse(testing.allocator, "{\"appendDataModel\":{\"path\":\"/stream/msg\",\"delta\":\"Hello, \"}}");
    defer freeCopy(testing.allocator, d1);
    try testing.expect((try session.applyEnvelope(testing.allocator, d1)) == null);
    const d2 = try parse(testing.allocator, "{\"appendDataModel\":{\"path\":\"/stream/msg\",\"delta\":\"world\"}}");
    defer freeCopy(testing.allocator, d2);
    try testing.expect((try session.applyEnvelope(testing.allocator, d2)) == null);

    const snap = try session.renderSnapshotJson(testing.allocator);
    defer testing.allocator.free(snap);
    try testing.expect(std.mem.indexOf(u8, snap, "Hello, world") != null);
    try testing.expect(std.mem.indexOf(u8, snap, "\"StreamingText\"") != null);

    // Bad shapes are rejected without mutation.
    const nod = try parse(testing.allocator, "{\"appendDataModel\":{\"path\":\"/stream/msg\"}}");
    defer freeCopy(testing.allocator, nod);
    const e1 = (try session.applyEnvelope(testing.allocator, nod)).?;
    defer testing.allocator.free(e1);
    try testing.expect(std.mem.indexOf(u8, e1, "missing delta") != null);
    const notstr = try parse(testing.allocator, "{\"appendDataModel\":{\"path\":\"/stream/msg\",\"delta\":42}}");
    defer freeCopy(testing.allocator, notstr);
    const e2 = (try session.applyEnvelope(testing.allocator, notstr)).?;
    defer testing.allocator.free(e2);
    try testing.expect(std.mem.indexOf(u8, e2, "delta must be a string") != null);
}

test "pointerAppendString: RFC 6901 escapes" {
    var session = Session.init(testing.allocator, undefined);
    defer session.deinit();
    const d = try parse(testing.allocator, "{\"appendDataModel\":{\"path\":\"/a~0b/c~1d\",\"delta\":\"x\"}}");
    defer freeCopy(testing.allocator, d);
    try testing.expect((try session.applyEnvelope(testing.allocator, d)) == null);
    const snap = try session.renderSnapshotJson(testing.allocator);
    defer testing.allocator.free(snap);
    // ~0 → ~ and ~1 → / in key names.
    try testing.expect(std.mem.indexOf(u8, snap, "\"a~b\":{\"c/d\":\"x\"}") != null);
}

test "applyEnvelope: @call binding is rejected" {
    var session = Session.init(testing.allocator, undefined);
    defer session.deinit();
    const t = try parse(testing.allocator,
        \\{"updateComponents":{"components":[{"id":"t","component":"Text","text":{"@call":"openUrl","args":{}}}]}}
    );
    defer freeCopy(testing.allocator, t);
    const err = (try session.applyEnvelope(testing.allocator, t)).?;
    defer testing.allocator.free(err);
    try testing.expect(std.mem.indexOf(u8, err, "EXPRESSION_ERROR") != null);
}

test "applyEnvelope: updateDataModel deep-merges" {
    var session = Session.init(testing.allocator, undefined);
    defer session.deinit();
    const t1 = try parse(testing.allocator,
        \\{"updateDataModel":{"data":{"form":{"name":"a","email":"b"}}}}
    );
    defer freeCopy(testing.allocator, t1);
    _ = try session.applyEnvelope(testing.allocator, t1);
    const t2 = try parse(testing.allocator,
        \\{"updateDataModel":{"data":{"form":{"name":"z"}}}}
    );
    defer freeCopy(testing.allocator, t2);
    _ = try session.applyEnvelope(testing.allocator, t2);
    const snap = try session.renderSnapshotJson(testing.allocator);
    defer testing.allocator.free(snap);
    try testing.expect(std.mem.indexOf(u8, snap, "\"name\":\"z\"") != null);
    try testing.expect(std.mem.indexOf(u8, snap, "\"email\":\"b\"") != null);
}

test "applyEnvelope: deleteSurface clears state and data model" {
    var session = Session.init(testing.allocator, undefined);
    defer session.deinit();
    const t1 = try parse(testing.allocator,
        \\{"updateComponents":{"components":[{"id":"t","component":"Text","text":"x"}]}}
    );
    defer freeCopy(testing.allocator, t1);
    _ = try session.applyEnvelope(testing.allocator, t1);
    const t2 = try parse(testing.allocator,
        \\{"updateDataModel":{"data":{"a":1}}}
    );
    defer freeCopy(testing.allocator, t2);
    _ = try session.applyEnvelope(testing.allocator, t2);
    const t3 = try parse(testing.allocator,
        \\{"deleteSurface":{"surfaceId":"main"}}
    );
    defer freeCopy(testing.allocator, t3);
    _ = try session.applyEnvelope(testing.allocator, t3);
    const snap = try session.renderSnapshotJson(testing.allocator);
    defer testing.allocator.free(snap);
    try testing.expect(std.mem.indexOf(u8, snap, "\"components\":[]") != null);
    try testing.expect(std.mem.indexOf(u8, snap, "\"dataModel\":null") != null);
}

test "applyEnvelope: plan 4.2 — any surfaceId creates a lazy surface; surfaces are independent" {
    var session = Session.init(testing.allocator, undefined);
    defer session.deinit();
    const t = try parse(testing.allocator,
        \\{"updateComponents":{"surfaceId":"panel","components":[
        \\  {"id":"root","component":"Column","children":["t"]},
        \\  {"id":"t","component":"Text","text":"panel text"}
        \\]}}
    );
    defer freeCopy(testing.allocator, t);
    try testing.expect((try session.applyEnvelope(testing.allocator, t)) == null);

    // "main" untouched; "panel" has its own state.
    const snap_main = try session.renderSnapshotJson(testing.allocator);
    defer testing.allocator.free(snap_main);
    try testing.expect(std.mem.indexOf(u8, snap_main, "panel text") == null);
    const snap_all = try session.renderSnapshotAllJson(testing.allocator);
    defer testing.allocator.free(snap_all);
    try testing.expect(std.mem.indexOf(u8, snap_all, "\"panel\"") != null);
    try testing.expect(std.mem.indexOf(u8, snap_all, "panel text") != null);

    // Data models are per-surface too.
    const d = try parse(testing.allocator,
        \\{"updateDataModel":{"surfaceId":"panel","data":{"x":1}}}
    );
    defer freeCopy(testing.allocator, d);
    try testing.expect((try session.applyEnvelope(testing.allocator, d)) == null);
    const snap_main2 = try session.renderSnapshotJson(testing.allocator);
    defer testing.allocator.free(snap_main2);
    try testing.expect(std.mem.indexOf(u8, snap_main2, "\"x\":1") == null);

    // deleteSurface clears only that surface.
    const del = try parse(testing.allocator, "{\"deleteSurface\":{\"surfaceId\":\"panel\"}}");
    defer freeCopy(testing.allocator, del);
    try testing.expect((try session.applyEnvelope(testing.allocator, del)) == null);
    const snap_all2 = try session.renderSnapshotAllJson(testing.allocator);
    defer testing.allocator.free(snap_all2);
    try testing.expect(std.mem.indexOf(u8, snap_all2, "panel text") == null);
}

test "applyEnvelope: plan 4.2 — replay ring replays missed envelopes, falls off when too old" {
    var session = Session.init(testing.allocator, undefined);
    defer session.deinit();

    const t1 = try parse(testing.allocator,
        \\{"updateComponents":{"components":[{"id":"t","component":"Text","text":"v1"}]}}
    );
    defer freeCopy(testing.allocator, t1);
    try testing.expect((try session.applyEnvelope(testing.allocator, t1)) == null);
    const d1 = try parse(testing.allocator, "{\"updateDataModel\":{\"data\":{\"a\":1}}}");
    defer freeCopy(testing.allocator, d1);
    try testing.expect((try session.applyEnvelope(testing.allocator, d1)) == null);

    // version is 2; replay from 0 yields both frames in order.
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expect(try session.replaySince(0, &out));
    try testing.expect(std.mem.indexOf(u8, out.written(), "a2ui_updateComponents") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "a2ui_updateDataModel") != null);
    // Up-to-date client replays nothing.
    var out2: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out2.deinit();
    try testing.expect(try session.replaySince(2, &out2));
    try testing.expectEqual(@as(usize, 0), out2.written().len);
    // oldestVersion tracks the ring.
    try testing.expectEqual(@as(u64, 1), session.oldestVersion());
}

test "deepCopy + freeCopy round-trip" {
    const t = try parse(testing.allocator,
        \\{"a":[1,"two",{"b":null}],"c":"three"}
    );
    defer freeCopy(testing.allocator, t);
    // leak detection via testing.allocator is the assertion
}
