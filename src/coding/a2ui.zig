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

/// Callback the session uses to fan a fully-rendered SSE frame out to
/// `/a2ui/events` subscribers. `userdata` is the proxy `Session`.
pub const BroadcastFn = *const fn (userdata: *anyopaque, frame: []const u8) void;

pub const Session = struct {
    allocator: std.mem.Allocator,
    /// Component adjacency list for the surface — the raw `components`
    /// array from the most recent accepted `updateComponents` batch.
    /// `null` until the first batch arrives. Owned (deep-copied).
    state: ?std.json.Value = null,
    /// Surface data model — deep-merged `updateDataModel` payloads.
    /// Owned (deep-copied).
    data_model: std.json.Value = .null,
    /// Monotonic version, bumped on every accepted mutation. Used as
    /// the SSE event id for `Last-Event-ID` reconnects.
    version: u64 = 0,
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
        if (self.state) |*s| freeCopy(self.allocator, s.*);
        freeCopy(self.allocator, self.data_model);
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
            // Idempotent in the PoC — the surface is implicit. Validate
            // the shape so the model gets feedback on malformed input.
            if (cs != .object) return try validationError(allocator, "VALIDATION_FAILED", "/createSurface", "createSurface must be an object");
            if (cs.object.get("surfaceId")) |sid| {
                if (sid != .string or !std.mem.eql(u8, sid.string, surface_id))
                    return try validationError(allocator, "VALIDATION_FAILED", "/createSurface/surfaceId", "PoC supports exactly one surface with surfaceId \"main\"");
            }
            return null; // nothing to mutate; no broadcast needed
        }

        if (obj.get("updateComponents")) |uc| {
            if (uc != .object) return try validationError(allocator, "VALIDATION_FAILED", "/updateComponents", "updateComponents must be an object");
            if (uc.object.get("surfaceId")) |sid| {
                if (sid != .string or !std.mem.eql(u8, sid.string, surface_id))
                    return try validationError(allocator, "VALIDATION_FAILED", "/updateComponents/surfaceId", "unknown surfaceId (PoC supports \"main\" only)");
            }
            const comps = uc.object.get("components") orelse
                return try validationError(allocator, "VALIDATION_FAILED", "/updateComponents/components", "missing components array");
            if (comps != .array) return try validationError(allocator, "VALIDATION_FAILED", "/updateComponents/components", "components must be an array");
            if (try validateComponents(a, comps.array.items)) |err_msg| return try allocator.dupe(u8, err_msg);

            // Full-replace mutation under lock. Rebind so the copy
            // (and later freeCopy) sees a plainly-mutable Value.
            const comps_mut: std.json.Value = comps;
            const copy = try deepCopy(self.allocator, comps_mut);
            self.mutex.lockUncancelable(self.io);
            if (self.state) |*s| freeCopy(self.allocator, s.*);
            self.state = copy;
            self.version += 1;
            const ver = self.version;
            self.mutex.unlock(self.io);
            try self.broadcast(allocator, "updateComponents", env, ver);
            return null;
        }

        if (obj.get("updateDataModel")) |udm| {
            if (udm != .object) return try validationError(allocator, "VALIDATION_FAILED", "/updateDataModel", "updateDataModel must be an object");
            if (udm.object.get("surfaceId")) |sid| {
                if (sid != .string or !std.mem.eql(u8, sid.string, surface_id))
                    return try validationError(allocator, "VALIDATION_FAILED", "/updateDataModel/surfaceId", "unknown surfaceId (PoC supports \"main\" only)");
            }
            const data = udm.object.get("data") orelse
                return try validationError(allocator, "VALIDATION_FAILED", "/updateDataModel/data", "missing data object");
            if (data != .object) return try validationError(allocator, "VALIDATION_FAILED", "/updateDataModel/data", "data must be an object");

            self.mutex.lockUncancelable(self.io);
            try mergeJson(self.allocator, &self.data_model, data);
            self.version += 1;
            const ver = self.version;
            self.mutex.unlock(self.io);
            try self.broadcast(allocator, "updateDataModel", env, ver);
            return null;
        }

        if (obj.get("deleteSurface")) |_| {
            self.mutex.lockUncancelable(self.io);
            if (self.state) |*s| {
                freeCopy(self.allocator, s.*);
                self.state = null;
            }
            freeCopy(self.allocator, self.data_model);
            self.data_model = .null;
            self.version += 1;
            const ver = self.version;
            self.mutex.unlock(self.io);
            try self.broadcast(allocator, "deleteSurface", env, ver);
            return null;
        }

        return try validationError(allocator, "VALIDATION_FAILED", "/", "envelope must contain exactly one of createSurface, updateComponents, updateDataModel, deleteSurface");
    }

    // ── renderer-side snapshots ───────────────────────────────────

    /// Serialize the current surface state + data model for a
    /// reconnecting renderer: `{"components": [...], "dataModel": {...},
    /// "version": N}`. Caller owns the returned slice.
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
        try jw.objectField("components");
        if (self.state) |s| {
            try jw.write(s);
        } else {
            try jw.beginArray();
            try jw.endArray();
        }
        try jw.objectField("dataModel");
        try jw.write(self.data_model);
        try jw.endObject();
        return try out.toOwnedSlice();
    }

    pub fn currentVersion(self: *Session) u64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.version;
    }

    /// Deep-copy of the current component adjacency list (or null
    /// when no `updateComponents` has landed yet). Caller frees with
    /// `freeCopy`. Used by the proxy's host-side projections to
    /// inspect the surface (e.g. locate the "root" children list).
    pub fn snapshotComponents(self: *Session, allocator: std.mem.Allocator) !?std.json.Value {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const s = self.state orelse return null;
        return try deepCopy(allocator, s);
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
        try upsertListLocked(self, parsed.value.array.items);
        self.version += 1;
        const ver = self.version;
        const payload = try std.json.Stringify.valueAlloc(allocator, self.state.?, .{});
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
        if (self.state != null and ids.len > 0) {
            var list = self.state.?.array;
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
            self.state = .{ .array = list };
        }
        self.version += 1;
        const ver = self.version;
        var payload: ?[]u8 = null;
        if (self.state) |st|
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

    /// Merge `items` into the surface adjacency list (upsert by `id`,
    /// preserving existing order; new ids append at the end). Caller
    /// must hold the mutex. `items` values are deep-copied.
    fn upsertListLocked(self: *Session, items: []const std.json.Value) !void {
        if (self.state == null)
            self.state = .{ .array = std.json.Array.init(self.allocator) };
        const list = &self.state.?.array;
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

        self.mutex.lockUncancelable(self.io);
        const f = self.broadcast_fn;
        const ud = self.broadcast_userdata;
        self.mutex.unlock(self.io);
        if (f) |bf| bf(ud.?, full);
    }
};

// ─── validation ─────────────────────────────────────────────────

const known_components = [_][]const u8{ "Column", "Row", "Text", "Button", "TextField", "CheckBox", "Card", "ToolCall", "CodeBlock" };

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
            return try validationError(a, "VALIDATION_FAILED", try std.fmt.allocPrint(a, "{s}/component", .{path_prefix}), try std.fmt.allocPrint(a, "unknown component \"{s}\" — catalog: Column, Row, Text, Button, TextField, CheckBox, Card, ToolCall, CodeBlock", .{comp_v.string}));
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

test "applyEnvelope: wrong surfaceId is rejected" {
    var session = Session.init(testing.allocator, undefined);
    defer session.deinit();
    const t = try parse(testing.allocator,
        \\{"updateComponents":{"surfaceId":"other","components":[]}}
    );
    defer freeCopy(testing.allocator, t);
    const err = (try session.applyEnvelope(testing.allocator, t)).?;
    defer testing.allocator.free(err);
    try testing.expect(std.mem.indexOf(u8, err, "unknown surfaceId") != null);
}

test "deepCopy + freeCopy round-trip" {
    const t = try parse(testing.allocator,
        \\{"a":[1,"two",{"b":null}],"c":"three"}
    );
    defer freeCopy(testing.allocator, t);
    // leak detection via testing.allocator is the assertion
}
