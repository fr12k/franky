//! Per-tool permission gate — Approach A from `permission.md`.
//!
//! Layered on top of the v1.9.x role system: roles control which
//! tools the model *sees*; this gate controls which tool *calls*
//! actually run, with a per-call decision (`auto_allow` /
//! `auto_deny` / `ask`). Disabled by default; enable per run via
//! `--prompts`. Intended for users who picked role `code` but
//! still want belt-and-braces confirmation on individual `bash`
//! commands.
//!
//! For v1.11.0 the gate decides without pausing — the "ask"
//! branch falls through to deny with a helpful message in
//! non-interactive contexts (print/RPC/proxy in this
//! pass). The pause+prompt protocol (`tool_permission_request`
//! event, `Agent.resolvePermission`) is v1.11.1+.

const std = @import("std");
const ai = struct {
    pub const stream = @import("../../ai/stream.zig");
};
const at = @import("../../agent/types.zig");
const agent_loop = @import("../../agent/loop.zig");
const role_mod = @import("role.zig");

/// Per-call decision returned by `Store.check`.
pub const Decision = enum {
    /// Run the tool without asking.
    auto_allow,
    /// Refuse the tool — synthesize a tool error.
    auto_deny,
    /// Default policy says "prompt the user". When a
    /// `PermissionPrompter` is wired the worker thread suspends
    /// on a Condition until the mode driver calls `resolve`;
    /// otherwise the gate falls through to `auto_deny` plus a
    /// helpful error message.
    ask,
};

/// User-supplied resolution after a `tool_permission_request`
/// prompt. `*_once` decides only the in-flight call; `always_*`
/// also writes the matching tool/fingerprint into the Store so
/// future calls don't re-ask.
pub const Resolution = enum {
    allow_once,
    deny_once,
    always_allow,
    always_deny,

    pub fn isAllow(self: Resolution) bool {
        return self == .allow_once or self == .always_allow;
    }

    pub fn fromString(s: []const u8) ?Resolution {
        if (std.mem.eql(u8, s, "allow_once")) return .allow_once;
        if (std.mem.eql(u8, s, "deny_once")) return .deny_once;
        if (std.mem.eql(u8, s, "always_allow")) return .always_allow;
        if (std.mem.eql(u8, s, "always_deny")) return .always_deny;
        return null;
    }
};

/// Default per-tool policy. read-family tools auto-allow because
/// §R already canonicalizes paths inside the workspace; write,
/// edit, and bash gate-ask.
pub fn defaultPolicy(tool_name: []const u8) Decision {
    if (std.mem.eql(u8, tool_name, "read")) return .auto_allow;
    if (std.mem.eql(u8, tool_name, "ls")) return .auto_allow;
    if (std.mem.eql(u8, tool_name, "find")) return .auto_allow;
    if (std.mem.eql(u8, tool_name, "grep")) return .auto_allow;
    if (std.mem.eql(u8, tool_name, "write")) return .ask;
    if (std.mem.eql(u8, tool_name, "edit")) return .ask;
    if (std.mem.eql(u8, tool_name, "bash")) return .ask;
    return .ask;
}

/// In-memory store of per-session allow/deny decisions, plus the
/// allowlist/denylist seeded from CLI flags. Keys for `bash` are
/// the verb fingerprint (see `fingerprintBash`); other tools use
/// the tool name directly.
pub const Store = struct {
    allocator: std.mem.Allocator,
    /// `--yes` — every `ask` becomes auto-allow.
    yes_to_all: bool = false,
    /// `--ask-tools all` — flip every default-auto_allow tool to
    /// `ask`. Subject to explicit allow/deny lists, which still
    /// take precedence (so `--ask-tools all --allow-tools bash:git`
    /// asks for everything except `git`).
    ask_all: bool = false,
    /// v1.12.0 — when non-null, every `*_always` promotion auto-
    /// persists the store to this absolute path (see
    /// `saveToDisk`). Set by mode drivers when
    /// `--remember-permissions` is on. The path is borrowed —
    /// callers (cfg arena) own the bytes.
    persist_path: ?[]const u8 = null,
    /// v1.12.0 — `io` for the auto-persist save path. Mode
    /// drivers set this together with `persist_path`.
    persist_io: ?std.Io = null,
    /// Tool names that auto-allow (whole tool, all calls).
    allow_tools: std.StringHashMapUnmanaged(void) = .empty,
    /// Tool names that auto-deny. Takes precedence over allow.
    deny_tools: std.StringHashMapUnmanaged(void) = .empty,
    /// Tool names whose default decision is forced to `ask`. Used
    /// when the user wants `read`/`ls`/`find`/`grep` to prompt
    /// even though the default policy auto-allows them.
    ask_tools: std.StringHashMapUnmanaged(void) = .empty,
    /// Bash fingerprints that auto-allow.
    allow_bash: std.StringHashMapUnmanaged(void) = .empty,
    /// Bash fingerprints that auto-deny. Takes precedence over allow.
    deny_bash: std.StringHashMapUnmanaged(void) = .empty,
    /// Bash fingerprints whose default decision is forced to `ask`.
    ask_bash: std.StringHashMapUnmanaged(void) = .empty,

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Store) void {
        freeStringSet(self.allocator, &self.allow_tools);
        freeStringSet(self.allocator, &self.deny_tools);
        freeStringSet(self.allocator, &self.ask_tools);
        freeStringSet(self.allocator, &self.allow_bash);
        freeStringSet(self.allocator, &self.deny_bash);
        freeStringSet(self.allocator, &self.ask_bash);
        self.* = undefined;
    }

    pub const Kind = enum { allow, deny, ask };

    /// Parse one entry like `"read"` or `"bash:git"` into the
    /// matching set. Tool-scoped entries (`bash:<fingerprint>`)
    /// land in the `*_bash` set; bare names land in the `*_tools`
    /// set. The reserved sentinel `"all"` is only meaningful for
    /// `kind == .ask` — it sets `ask_all = true` so every
    /// default-auto_allow tool flips to `ask`.
    fn addOne(self: *Store, entry: []const u8, kind: Kind) !void {
        if (entry.len == 0) return;
        if (kind == .ask and std.mem.eql(u8, entry, "all")) {
            self.ask_all = true;
            return;
        }
        if (std.mem.indexOfScalar(u8, entry, ':')) |colon| {
            const tool = entry[0..colon];
            const fingerprint = entry[colon + 1 ..];
            if (!std.mem.eql(u8, tool, "bash")) {
                // Only `bash` supports fingerprint scoping today;
                // ignore other prefixes silently rather than
                // erroring on unknown tools.
                return;
            }
            if (fingerprint.len == 0) return;
            const set = switch (kind) {
                .allow => &self.allow_bash,
                .deny => &self.deny_bash,
                .ask => &self.ask_bash,
            };
            try addToSet(self.allocator, set, fingerprint);
            return;
        }
        const set = switch (kind) {
            .allow => &self.allow_tools,
            .deny => &self.deny_tools,
            .ask => &self.ask_tools,
        };
        try addToSet(self.allocator, set, entry);
    }

    /// Parse a comma-separated list and add every entry.
    pub fn addAllowList(self: *Store, csv: []const u8) !void {
        try addCsv(self, csv, .allow);
    }

    pub fn addDenyList(self: *Store, csv: []const u8) !void {
        try addCsv(self, csv, .deny);
    }

    /// `--ask-tools <csv>` — demote each entry from the default
    /// (likely `auto_allow`) to `ask`. Reserved sentinel `all`
    /// flips every default-auto_allow tool to `ask`.
    pub fn addAskList(self: *Store, csv: []const u8) !void {
        try addCsv(self, csv, .ask);
    }

    /// v1.19.0 — pre-seed the Store from already-parsed string
    /// arrays (e.g. settings.json `permissions.always_allow.tools`).
    /// `name` is a bare tool name (`read`) or a bare bash
    /// fingerprint (`git`); the caller decides which set via the
    /// `is_bash_fingerprint` flag. Empty names are silently skipped.
    pub fn addBareEntry(
        self: *Store,
        name: []const u8,
        kind: Kind,
        is_bash_fingerprint: bool,
    ) !void {
        if (name.len == 0) return;
        const set: *std.StringHashMapUnmanaged(void) = if (is_bash_fingerprint) switch (kind) {
            .allow => &self.allow_bash,
            .deny => &self.deny_bash,
            .ask => &self.ask_bash,
        } else switch (kind) {
            .allow => &self.allow_tools,
            .deny => &self.deny_tools,
            .ask => &self.ask_tools,
        };
        try addToSet(self.allocator, set, name);
    }

    fn addCsv(self: *Store, csv: []const u8, kind: Kind) !void {
        var it = std.mem.tokenizeScalar(u8, csv, ',');
        while (it.next()) |raw| {
            const trimmed = std.mem.trim(u8, raw, " \t");
            try self.addOne(trimmed, kind);
        }
    }

    /// Drop a single entry from any of the six allow/deny/ask
    /// sets. Accepts the same shapes as `--allow-tools` etc.:
    /// bare tool name (`write`) or scoped bash fingerprint
    /// (`bash:git`). Returns whether anything was removed; `false`
    /// surfaces "no such entry" to the caller without erroring.
    /// Auto-persists on success when `persist_path` is set.
    pub fn revoke(self: *Store, entry: []const u8) bool {
        if (entry.len == 0) return false;
        var removed: bool = false;
        if (std.mem.indexOfScalar(u8, entry, ':')) |colon| {
            const tool = entry[0..colon];
            const fp = entry[colon + 1 ..];
            if (!std.mem.eql(u8, tool, "bash") or fp.len == 0) return false;
            const sets = [_]*std.StringHashMapUnmanaged(void){
                &self.allow_bash, &self.deny_bash, &self.ask_bash,
            };
            for (sets) |set| {
                if (set.fetchRemove(fp)) |old| {
                    self.allocator.free(old.key);
                    removed = true;
                }
            }
        } else {
            const sets = [_]*std.StringHashMapUnmanaged(void){
                &self.allow_tools, &self.deny_tools, &self.ask_tools,
            };
            for (sets) |set| {
                if (set.fetchRemove(entry)) |old| {
                    self.allocator.free(old.key);
                    removed = true;
                }
            }
        }
        if (removed) self.persistIfConfigured();
        return removed;
    }

    /// Wipe every allow/deny/ask entry plus the `yes_to_all` /
    /// `ask_all` flags. The store remains usable; the persisted
    /// path (if any) is rewritten with empty arrays so the next
    /// session loads the cleared state.
    pub fn clearAll(self: *Store) void {
        freeStringSet(self.allocator, &self.allow_tools);
        freeStringSet(self.allocator, &self.deny_tools);
        freeStringSet(self.allocator, &self.ask_tools);
        freeStringSet(self.allocator, &self.allow_bash);
        freeStringSet(self.allocator, &self.deny_bash);
        freeStringSet(self.allocator, &self.ask_bash);
        self.allow_tools = .empty;
        self.deny_tools = .empty;
        self.ask_tools = .empty;
        self.allow_bash = .empty;
        self.deny_bash = .empty;
        self.ask_bash = .empty;
        self.yes_to_all = false;
        self.ask_all = false;
        self.persistIfConfigured();
    }

    /// v1.12.0 helper exposed publicly for the `/permissions`
    /// slash command's revoke/clear paths. No-op when no
    /// persistence is configured.
    pub fn persistIfConfigured(self: *const Store) void {
        const path = self.persist_path orelse return;
        const io = self.persist_io orelse return;
        saveToDisk(self, self.allocator, io, path) catch {};
    }

    /// Total number of allow/deny/ask entries across all six sets.
    /// Used by the `/permissions` status renderer to summarize
    /// without having to itemize when there's nothing interesting.
    pub fn entryCount(self: *const Store) usize {
        return self.allow_tools.count() + self.deny_tools.count() +
            self.ask_tools.count() + self.allow_bash.count() +
            self.deny_bash.count() + self.ask_bash.count();
    }

    /// Decide whether to permit a single tool call. `args_json` is
    /// the raw JSON the model sent; for bash we fingerprint the
    /// command, for other tools we ignore it.
    ///
    /// Precedence (most → least specific):
    ///   1. `deny_tools` / `deny_bash` (hard refusal)
    ///   2. `allow_tools` / `allow_bash` (auto-allow)
    ///   3. `ask_tools` / `ask_bash` / `ask_all` (force-ask, even
    ///      when the default policy auto-allows)
    ///   4. default policy (`defaultPolicy`)
    ///
    /// `yes_to_all` flips a final `ask` decision into `auto_allow`,
    /// so it composes with `ask_all` to give a "gate active but
    /// auto-confirm everything" CI shape.
    pub fn check(
        self: *const Store,
        tool_name: []const u8,
        args_json: []const u8,
    ) Decision {
        // Step 1: deny lists (hard refusal).
        if (self.deny_tools.contains(tool_name)) return .auto_deny;
        const is_bash = std.mem.eql(u8, tool_name, "bash");
        const bash_fp: ?[]const u8 = if (is_bash)
            (if (extractBashCommand(args_json)) |cmd| fingerprintBash(cmd) else null)
        else
            null;
        if (bash_fp) |fp| {
            if (self.deny_bash.contains(fp)) return .auto_deny;
        }

        // Step 2: allow lists.
        if (bash_fp) |fp| {
            if (self.allow_bash.contains(fp)) return .auto_allow;
        }
        if (self.allow_tools.contains(tool_name)) return .auto_allow;

        // Step 3: explicit force-ask (overrides default auto_allow).
        const force_ask = self.ask_all
            or self.ask_tools.contains(tool_name)
            or (bash_fp != null and self.ask_bash.contains(bash_fp.?));
        if (force_ask) {
            if (self.yes_to_all) return .auto_allow;
            return .ask;
        }

        // Step 4: default policy.
        const default = defaultPolicy(tool_name);
        if (default == .ask and self.yes_to_all) return .auto_allow;
        return default;
    }
};

fn addToSet(
    allocator: std.mem.Allocator,
    set: *std.StringHashMapUnmanaged(void),
    key: []const u8,
) !void {
    if (set.contains(key)) return;
    const owned = try allocator.dupe(u8, key);
    errdefer allocator.free(owned);
    try set.put(allocator, owned, {});
}

fn freeStringSet(
    allocator: std.mem.Allocator,
    set: *std.StringHashMapUnmanaged(void),
) void {
    var it = set.keyIterator();
    while (it.next()) |k| allocator.free(k.*);
    set.deinit(allocator);
}

/// Verb-level fingerprint of a bash command — the first non-path
/// component of the leading argv token. Coarse enough that
/// users make ~5–10 decisions per session, fine enough that
/// `git` and `rm` are distinct entries.
///
/// `"git status"` → `"git"`, `"/usr/local/bin/zig build"` → `"zig"`,
/// `"npm install foo"` → `"npm"`.
pub fn fingerprintBash(command: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, command, " \t\r\n");
    if (trimmed.len == 0) return "";
    const space = std.mem.indexOfAny(u8, trimmed, " \t") orelse trimmed.len;
    const first = trimmed[0..space];
    if (std.mem.lastIndexOfScalar(u8, first, '/')) |slash| {
        return first[slash + 1 ..];
    }
    return first;
}

/// Pull the `command` field out of a bash tool call's JSON
/// arguments. Returns null on parse failure or missing field —
/// the gate then falls through to the tool-name policy.
fn extractBashCommand(args_json: []const u8) ?[]const u8 {
    // Tiny scan — we don't need a full JSON parser. Look for
    // `"command":` then read the following string literal.
    const key = "\"command\"";
    const k = std.mem.indexOf(u8, args_json, key) orelse return null;
    var i = k + key.len;
    while (i < args_json.len and (args_json[i] == ' ' or args_json[i] == ':' or args_json[i] == '\t')) : (i += 1) {}
    if (i >= args_json.len or args_json[i] != '"') return null;
    i += 1;
    const start = i;
    while (i < args_json.len) : (i += 1) {
        if (args_json[i] == '\\') {
            i += 1;
            continue;
        }
        if (args_json[i] == '"') return args_json[start..i];
    }
    return null;
}

/// Best-effort fingerprint a call uses for `always_*` decisions.
/// Bash uses `fingerprintBash` against the parsed `command` arg;
/// every other tool keys on the tool name.
pub fn fingerprintFor(tool_name: []const u8, args_json: []const u8) []const u8 {
    if (std.mem.eql(u8, tool_name, "bash")) {
        if (extractBashCommand(args_json)) |cmd| {
            return fingerprintBash(cmd);
        }
        return "bash";
    }
    return tool_name;
}

// ─── Pause-and-prompt protocol (v1.11.1) ─────────────────────────

/// One pending permission request. Lives in the prompter's
/// `pending` map keyed by `call_id`. Owned strings (call_id,
/// fingerprint) live in the prompter's allocator until the
/// resolver frees them via `resolve`.
const PendingPrompt = struct {
    /// Tool name + fingerprint copied at request time so the
    /// resolver can promote `always_*` decisions without a
    /// callback-side allocation.
    tool_name: []u8,
    fingerprint: []u8,
    /// Set to non-null by `resolve`. The waiter reads it under
    /// the prompter mutex after `cond` fires.
    resolution: ?Resolution = null,
    cond: std.Io.Condition = .init,
};

/// Mode-driver-supplied bridge between the worker thread (which
/// suspends inside `before_tool_call`) and the UI / RPC client
/// (which reads `tool_permission_request` events and replies via
/// `resolve`).
///
/// Lifecycle: created by the mode driver alongside the channel,
/// installed into `SessionGates.prompter`, deinit'ed when the
/// session tears down. Address must be stable for the session.
pub const PermissionPrompter = struct {
    allocator: std.mem.Allocator,
    /// Channel the agent loop pushes events to — also where the
    /// `tool_permission_request` event lands. The mode driver
    /// already owns this; the prompter borrows it.
    channel: *agent_loop.AgentChannel,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    pending: std.StringHashMapUnmanaged(*PendingPrompt) = .empty,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        channel: *agent_loop.AgentChannel,
    ) PermissionPrompter {
        return .{ .allocator = allocator, .io = io, .channel = channel };
    }

    pub fn deinit(self: *PermissionPrompter) void {
        // Wake any stragglers so the worker thread doesn't block
        // forever on shutdown — a deny resolution is the safe
        // default.
        var it = self.pending.iterator();
        while (it.next()) |entry| {
            const slot = entry.value_ptr.*;
            slot.resolution = .deny_once;
            slot.cond.broadcast(self.io);
            self.allocator.free(slot.tool_name);
            self.allocator.free(slot.fingerprint);
            self.allocator.destroy(slot);
            self.allocator.free(entry.key_ptr.*);
        }
        self.pending.deinit(self.allocator);
        self.* = undefined;
    }

    /// Called from inside the worker thread's `before_tool_call`
    /// hook when the policy returns `ask`. Pushes the
    /// `tool_permission_request` event, suspends on a per-call
    /// Condition, and returns the user's resolution. `args_json`
    /// is borrowed only for the duration of the call — the
    /// prompter copies what it needs before pushing the event.
    pub fn requestAndWait(
        self: *PermissionPrompter,
        tool_name: []const u8,
        call_id: []const u8,
        args_json: []const u8,
    ) !Resolution {
        const fingerprint = fingerprintFor(tool_name, args_json);
        const owned_call_id = try self.allocator.dupe(u8, call_id);
        errdefer self.allocator.free(owned_call_id);
        const slot = try self.allocator.create(PendingPrompt);
        errdefer self.allocator.destroy(slot);
        slot.* = .{
            .tool_name = try self.allocator.dupe(u8, tool_name),
            .fingerprint = try self.allocator.dupe(u8, fingerprint),
        };
        errdefer self.allocator.free(slot.tool_name);
        errdefer self.allocator.free(slot.fingerprint);

        // Map ownership: we free key + slot in resolve / deinit.
        try self.pending.put(self.allocator, owned_call_id, slot);

        // Push the event AFTER the slot is in the map so a fast
        // resolver can't race ahead. The event payload uses
        // freshly-duped strings (channel takes ownership).
        const ev = at.AgentEvent{ .tool_permission_request = .{
            .call_id = try self.allocator.dupe(u8, call_id),
            .tool_name = try self.allocator.dupe(u8, tool_name),
            .args_json = try self.allocator.dupe(u8, args_json),
            .fingerprint = try self.allocator.dupe(u8, fingerprint),
        } };
        try self.channel.push(self.io, ev);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (slot.resolution == null) {
            slot.cond.waitUncancelable(self.io, &self.mutex);
        }
        const final = slot.resolution.?;
        // Pull the slot out of the map and free under the same
        // lock so a late `resolve` can't see it.
        if (self.pending.fetchRemove(owned_call_id)) |kv| {
            self.allocator.free(kv.key);
        }
        self.allocator.free(slot.tool_name);
        self.allocator.free(slot.fingerprint);
        self.allocator.destroy(slot);
        return final;
    }

    /// Mode-driver entry point. Writes the user's decision into
    /// the matching pending slot and wakes the worker. Returns
    /// `error.NotPending` if `call_id` doesn't match an
    /// outstanding request — the resolver should report that as
    /// "stale resolution" instead of crashing.
    pub fn resolve(self: *PermissionPrompter, call_id: []const u8, decision: Resolution) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const slot = self.pending.get(call_id) orelse return error.NotPending;
        slot.resolution = decision;
        slot.cond.broadcast(self.io);
    }
};

/// Combined hook-userdata struct. The agent loop passes a single
/// `hook_userdata` pointer to `before_tool_call` AND
/// `role_denied`; both callbacks downcast to this struct so the
/// gates can coexist. Stable address required (worker thread
/// dereferences it).
pub const SessionGates = struct {
    role: ?*role_mod.RoleGate = null,
    permissions: ?*Store = null,
    /// v1.11.1 — when set, the gate pauses the worker on `ask`
    /// and the mode driver answers via `prompter.resolve`. When
    /// null, the gate falls through to `auto_deny` plus a
    /// CI-friendly hint.
    prompter: ?*PermissionPrompter = null,

    /// Adapter for `agent_loop.Config.role_denied`. Forwards to
    /// the role gate; when no role gate is configured the loop's
    /// existing "unknown tool" path handles it.
    pub fn roleDenied(userdata: ?*anyopaque, tool_name: []const u8) ?agent_loop.RoleDenial {
        const self: *SessionGates = @ptrCast(@alignCast(userdata.?));
        const gate = self.role orelse return null;
        return role_mod.RoleGate.check(@ptrCast(gate), tool_name);
    }

    /// Adapter for `agent_loop.Config.before_tool_call`.
    pub fn beforeToolCall(
        userdata: ?*anyopaque,
        tool: *const at.AgentTool,
        call_id: []const u8,
        args_json: []const u8,
    ) agent_loop.HookDecision {
        const self: *SessionGates = @ptrCast(@alignCast(userdata.?));
        const store = self.permissions orelse return .{ .block = false };
        const decision = store.check(tool.name, args_json);
        switch (decision) {
            .auto_allow => return .{ .block = false },
            .auto_deny => return .{
                .block = true,
                .reason_text = "permission gate: tool denied by --deny-tools or default policy",
            },
            .ask => {
                if (self.prompter) |p| return waitForPrompt(p, store, tool.name, call_id, args_json);
                return .{
                    .block = true,
                    .reason_text = "permission gate: tool requires explicit approval (use --yes, --allow-tools, or run --mode proxy for interactive prompts)",
                };
            },
        }
    }
};

fn waitForPrompt(
    prompter: *PermissionPrompter,
    store: *Store,
    tool_name: []const u8,
    call_id: []const u8,
    args_json: []const u8,
) agent_loop.HookDecision {
    const resolution = prompter.requestAndWait(tool_name, call_id, args_json) catch {
        // Allocation / push failure is rare; fail closed.
        return .{
            .block = true,
            .reason_text = "permission gate: prompt dispatch failed",
        };
    };
    // Promote `always_*` decisions into the store so future
    // calls of the same shape don't re-ask. Ignore allocation
    // failures here — the in-flight call still resolves
    // correctly; the worst case is the user gets re-prompted on
    // a future call.
    var promoted = false;
    switch (resolution) {
        .always_allow => {
            const fp = fingerprintFor(tool_name, args_json);
            if (std.mem.eql(u8, tool_name, "bash")) {
                addToSet(store.allocator, &store.allow_bash, fp) catch {};
            } else {
                addToSet(store.allocator, &store.allow_tools, tool_name) catch {};
            }
            promoted = true;
        },
        .always_deny => {
            const fp = fingerprintFor(tool_name, args_json);
            if (std.mem.eql(u8, tool_name, "bash")) {
                addToSet(store.allocator, &store.deny_bash, fp) catch {};
            } else {
                addToSet(store.allocator, &store.deny_tools, tool_name) catch {};
            }
            promoted = true;
        },
        .allow_once, .deny_once => {},
    }

    // v1.12.0 — auto-persist when the user opted in via
    // `--remember-permissions`. Failures are silently swallowed:
    // the in-flight call still resolves correctly; the worst case
    // is the next session re-prompts for the same tool.
    if (promoted) {
        if (store.persist_path) |path| {
            if (store.persist_io) |io| {
                saveToDisk(store, store.allocator, io, path) catch {};
            }
        }
    }
    if (resolution.isAllow()) return .{ .block = false };
    return .{
        .block = true,
        .reason_text = "permission gate: denied by user",
    };
}

/// v1.12.0 — convenience for mode drivers. When
/// `cfg.remember_permissions` is true:
///   1. Resolves `permissions.json` path via `defaultPath`.
///   2. Loads existing entries into `store` (no-op if missing).
///   3. Sets `store.persist_path` + `store.persist_io` so future
///      `*_always` resolutions auto-persist.
///
/// Path bytes are allocated by `path_arena` (caller manages
/// lifetime — typically the cfg arena, which outlives the
/// session). Failures (malformed file, no HOME) are swallowed
/// silently — the gate continues with in-memory state.
pub fn maybeAttachPersistence(
    store: *Store,
    cfg_remember: bool,
    path_arena: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
) !void {
    if (!cfg_remember) return;
    const path = (try defaultPath(path_arena, environ_map)) orelse return;
    _ = loadFromDisk(store, store.allocator, io, path) catch {};
    store.persist_path = path;
    store.persist_io = io;
}

// ─── persistent permissions.json (v1.12.0) ────────────────────────
//
// `--remember-permissions` opts in. Path resolves to
// `$FRANKY_HOME/permissions.json`, falling back to
// `$HOME/.franky/permissions.json`. Schema (matches `permission.md`
// §A.6 — only the always_allow / always_deny halves; default policy
// stays in code):
//
//     {
//       "version": 1,
//       "always_allow": { "tools": ["write"], "bash": ["git", "ls"] },
//       "always_deny":  { "tools": [],         "bash": ["rm", "curl"] }
//     }
//
// Round-trip is order-stable across the keys franky cares about.

pub const persistence_version: i64 = 1;

/// Resolve the canonical permissions.json path.
/// Returns null when neither `FRANKY_HOME` nor `HOME` is set
/// (typical only in tests / sandboxed CI). Caller frees.
pub fn defaultPath(
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
) !?[]u8 {
    if (environ_map.get("FRANKY_HOME")) |home| {
        if (home.len == 0) return null;
        return try std.fmt.allocPrint(allocator, "{s}/permissions.json", .{home});
    }
    if (environ_map.get("HOME")) |home| {
        if (home.len == 0) return null;
        return try std.fmt.allocPrint(allocator, "{s}/.franky/permissions.json", .{home});
    }
    return null;
}

/// Load `permissions.json` and seed `store` with the always-allow /
/// always-deny entries. Missing file is *not* an error — returns
/// false so callers can decide whether to log. Malformed JSON
/// returns `error.MalformedJson`; the gate continues with
/// in-memory state only.
pub fn loadFromDisk(
    store: *Store,
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) !bool {
    var f = std.Io.Dir.cwd().openFile(io, path, .{}) catch |e| switch (e) {
        error.FileNotFound => return false,
        else => return false,
    };
    defer f.close(io);

    const len = f.length(io) catch return false;
    if (len == 0) return false;
    const buf = allocator.alloc(u8, @intCast(len)) catch return error.OutOfMemory;
    defer allocator.free(buf);
    const n = f.readPositionalAll(io, buf, 0) catch return false;

    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const parsed = std.json.parseFromSlice(std.json.Value, scratch.allocator(), buf[0..n], .{}) catch return error.MalformedJson;
    if (parsed.value != .object) return error.MalformedJson;
    const root = parsed.value.object;

    if (root.get("always_allow")) |v| try seedFromObject(store, v, .allow);
    if (root.get("always_deny")) |v| try seedFromObject(store, v, .deny);
    return true;
}

/// Atomic write — tempfile + rename. Returns silently on failure
/// (called from inside the agent loop's hook; we don't want disk
/// hiccups to abort a turn).
pub fn saveToDisk(
    store: *const Store,
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) !void {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    try renderPermissionsJson(&body, allocator, store);

    var tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len + 5 > tmp_path_buf.len) return error.PathTooLong;
    @memcpy(tmp_path_buf[0..path.len], path);
    @memcpy(tmp_path_buf[path.len .. path.len + 5], ".part");
    const tmp_path = tmp_path_buf[0 .. path.len + 5];

    if (std.fs.path.dirname(path)) |dir_path| {
        std.Io.Dir.cwd().createDirPath(io, dir_path) catch {};
    }

    const perms: std.Io.Dir.Permissions = switch (@import("builtin").os.tag) {
        .windows, .wasi => .default_file,
        else => std.Io.File.Permissions.fromMode(0o600),
    };
    var f = std.Io.Dir.cwd().createFile(io, tmp_path, .{ .permissions = perms }) catch return error.WriteFailed;
    {
        defer f.close(io);
        f.writeStreamingAll(io, body.items) catch return error.WriteFailed;
        f.sync(io) catch {};
    }
    std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), path, io) catch return error.WriteFailed;
}

fn seedFromObject(store: *Store, value: std.json.Value, kind: Store.Kind) !void {
    if (value != .object) return;
    const obj = value.object;
    if (obj.get("tools")) |tools_v| if (tools_v == .array) {
        for (tools_v.array.items) |entry| {
            if (entry != .string) continue;
            const set = switch (kind) {
                .allow => &store.allow_tools,
                .deny => &store.deny_tools,
                .ask => &store.ask_tools,
            };
            try addToSet(store.allocator, set, entry.string);
        }
    };
    if (obj.get("bash")) |bash_v| if (bash_v == .array) {
        for (bash_v.array.items) |entry| {
            if (entry != .string) continue;
            const set = switch (kind) {
                .allow => &store.allow_bash,
                .deny => &store.deny_bash,
                .ask => &store.ask_bash,
            };
            try addToSet(store.allocator, set, entry.string);
        }
    };
}

fn renderPermissionsJson(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    store: *const Store,
) !void {
    try buf.appendSlice(allocator, "{\n  \"version\": ");
    const version_buf = try std.fmt.allocPrint(allocator, "{d}", .{persistence_version});
    defer allocator.free(version_buf);
    try buf.appendSlice(allocator, version_buf);
    try buf.appendSlice(allocator, ",\n  \"always_allow\": ");
    try renderAllowDenyObject(buf, allocator, &store.allow_tools, &store.allow_bash);
    try buf.appendSlice(allocator, ",\n  \"always_deny\": ");
    try renderAllowDenyObject(buf, allocator, &store.deny_tools, &store.deny_bash);
    try buf.appendSlice(allocator, "\n}\n");
}

fn renderAllowDenyObject(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    tools_set: *const std.StringHashMapUnmanaged(void),
    bash_set: *const std.StringHashMapUnmanaged(void),
) !void {
    try buf.appendSlice(allocator, "{ \"tools\": ");
    try renderStringSet(buf, allocator, tools_set);
    try buf.appendSlice(allocator, ", \"bash\": ");
    try renderStringSet(buf, allocator, bash_set);
    try buf.appendSlice(allocator, " }");
}

fn renderStringSet(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    set: *const std.StringHashMapUnmanaged(void),
) !void {
    // Sort for deterministic output — round-trip stability matters
    // for diff-friendly storage in dotfile repos.
    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(allocator);
    var it = set.keyIterator();
    while (it.next()) |k| try keys.append(allocator, k.*);
    std.mem.sort([]const u8, keys.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    try buf.append(allocator, '[');
    for (keys.items, 0..) |k, i| {
        if (i > 0) try buf.appendSlice(allocator, ", ");
        try buf.append(allocator, '"');
        try buf.appendSlice(allocator, k);
        try buf.append(allocator, '"');
    }
    try buf.append(allocator, ']');
}

// ─── tests ────────────────────────────────────────────────────────

const testing = std.testing;

test "fingerprintBash: extracts verb from common shapes" {
    try testing.expectEqualStrings("git", fingerprintBash("git status"));
    try testing.expectEqualStrings("git", fingerprintBash("git push origin main"));
    try testing.expectEqualStrings("rm", fingerprintBash("rm -rf /tmp/foo"));
    try testing.expectEqualStrings("zig", fingerprintBash("/usr/local/bin/zig build"));
    try testing.expectEqualStrings("npm", fingerprintBash("  npm install foo"));
    try testing.expectEqualStrings("ls", fingerprintBash("ls"));
    try testing.expectEqualStrings("", fingerprintBash(""));
    try testing.expectEqualStrings("", fingerprintBash("   "));
}

test "defaultPolicy: read-family auto, write/edit/bash ask" {
    try testing.expectEqual(Decision.auto_allow, defaultPolicy("read"));
    try testing.expectEqual(Decision.auto_allow, defaultPolicy("ls"));
    try testing.expectEqual(Decision.auto_allow, defaultPolicy("find"));
    try testing.expectEqual(Decision.auto_allow, defaultPolicy("grep"));
    try testing.expectEqual(Decision.ask, defaultPolicy("write"));
    try testing.expectEqual(Decision.ask, defaultPolicy("edit"));
    try testing.expectEqual(Decision.ask, defaultPolicy("bash"));
    // Unknown tool defaults to ask (fail-closed).
    try testing.expectEqual(Decision.ask, defaultPolicy("not_a_real_tool"));
}

test "Store.check: read auto-allows under defaults" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    try testing.expectEqual(Decision.auto_allow, s.check("read", "{}"));
}

test "Store.check: yes_to_all turns ask into auto_allow" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    s.yes_to_all = true;
    try testing.expectEqual(Decision.auto_allow, s.check("write", "{}"));
    try testing.expectEqual(Decision.auto_allow, s.check("bash", "{\"command\":\"git status\"}"));
}

test "Store.addAllowList: tool-name allow keeps ask others" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    try s.addAllowList("write");
    try testing.expectEqual(Decision.auto_allow, s.check("write", "{}"));
    try testing.expectEqual(Decision.ask, s.check("edit", "{}"));
}

test "Store.addAllowList: bash fingerprint scope" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    try s.addAllowList("bash:git, bash:ls");
    try testing.expectEqual(Decision.auto_allow, s.check("bash", "{\"command\":\"git status\"}"));
    try testing.expectEqual(Decision.auto_allow, s.check("bash", "{\"command\":\"ls -la\"}"));
    // rm not in allowlist → falls back to default (ask).
    try testing.expectEqual(Decision.ask, s.check("bash", "{\"command\":\"rm /tmp/x\"}"));
}

test "Store.addDenyList: bash fingerprint deny overrides allow" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    try s.addAllowList("bash:rm");
    try s.addDenyList("bash:rm");
    try testing.expectEqual(Decision.auto_deny, s.check("bash", "{\"command\":\"rm -rf /tmp\"}"));
}

test "Store.addDenyList: tool-name deny overrides yes_to_all" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    s.yes_to_all = true;
    try s.addDenyList("write");
    try testing.expectEqual(Decision.auto_deny, s.check("write", "{}"));
}

test "Store.addAllowList: ignores empty + unknown-tool prefixes" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    try s.addAllowList(",,read,, edit ,foo:bar");
    try testing.expectEqual(Decision.auto_allow, s.check("read", "{}"));
    try testing.expectEqual(Decision.auto_allow, s.check("edit", "{}"));
    try testing.expectEqual(Decision.ask, s.check("write", "{}"));
}

// ─── v1.11.5 — --ask-tools demote-to-ask overlay ──────────────────

test "Store.addAskList: demotes a default-auto_allow tool to ask" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    // Baseline: read auto-allows.
    try testing.expectEqual(Decision.auto_allow, s.check("read", "{}"));
    try s.addAskList("read,find");
    try testing.expectEqual(Decision.ask, s.check("read", "{}"));
    try testing.expectEqual(Decision.ask, s.check("find", "{}"));
    // ls/grep untouched — still auto-allow.
    try testing.expectEqual(Decision.auto_allow, s.check("ls", "{}"));
}

test "Store.addAskList: 'all' sentinel flips every default-auto_allow to ask" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    try s.addAskList("all");
    try testing.expect(s.ask_all);
    try testing.expectEqual(Decision.ask, s.check("read", "{}"));
    try testing.expectEqual(Decision.ask, s.check("ls", "{}"));
    try testing.expectEqual(Decision.ask, s.check("find", "{}"));
    try testing.expectEqual(Decision.ask, s.check("grep", "{}"));
    // write/edit/bash already default to ask — unchanged.
    try testing.expectEqual(Decision.ask, s.check("write", "{}"));
}

test "Store.check: deny still wins over force-ask" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    try s.addAskList("all");
    try s.addDenyList("write");
    try testing.expectEqual(Decision.auto_deny, s.check("write", "{}"));
    try testing.expectEqual(Decision.ask, s.check("read", "{}"));
}

test "Store.check: allow still wins over force-ask" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    try s.addAskList("all");
    try s.addAllowList("bash:git");
    // ask_all set, but bash:git is in the explicit allowlist → auto_allow.
    try testing.expectEqual(Decision.auto_allow, s.check("bash", "{\"command\":\"git status\"}"));
    // bash with another fingerprint: ask_all hits, no allow match.
    try testing.expectEqual(Decision.ask, s.check("bash", "{\"command\":\"rm -rf /\"}"));
}

test "Store.addAskList: bash:fingerprint scopes to one verb" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    try s.addAskList("bash:cat");
    // bash:cat → forced ask (would normally be ask anyway from default,
    // but this verifies the fingerprint scoping path).
    try testing.expectEqual(Decision.ask, s.check("bash", "{\"command\":\"cat /etc/passwd\"}"));
    // Other bash verbs follow the default policy (still ask).
    try testing.expectEqual(Decision.ask, s.check("bash", "{\"command\":\"git status\"}"));
    // read still auto-allows — bash-scoped ask doesn't leak.
    try testing.expectEqual(Decision.auto_allow, s.check("read", "{}"));
}

// ─── v1.12.0 — persistent permissions.json ────────────────────────

test "renderPermissionsJson: empty store emits the schema skeleton" {
    const gpa = testing.allocator;
    var s = Store.init(gpa);
    defer s.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try renderPermissionsJson(&buf, gpa, &s);
    try testing.expect(std.mem.indexOf(u8, buf.items, "\"version\": 1") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "\"always_allow\": { \"tools\": [], \"bash\": [] }") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "\"always_deny\": { \"tools\": [], \"bash\": [] }") != null);
}

test "renderPermissionsJson: keys are sorted (round-trip-stable)" {
    const gpa = testing.allocator;
    var s = Store.init(gpa);
    defer s.deinit();
    try s.addAllowList("write,read,bash:zig,bash:git,bash:ls");
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try renderPermissionsJson(&buf, gpa, &s);
    // Tools sorted: read, write
    const tools_idx = std.mem.indexOf(u8, buf.items, "\"tools\": [\"read\", \"write\"]").?;
    // Bash sorted: git, ls, zig
    const bash_idx = std.mem.indexOf(u8, buf.items, "\"bash\": [\"git\", \"ls\", \"zig\"]").?;
    try testing.expect(tools_idx > 0);
    try testing.expect(bash_idx > tools_idx);
}

test "loadFromDisk → saveToDisk round-trip preserves entries" {
    const gpa = testing.allocator;
    var threaded = @import("../../test_helpers.zig").threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const base = "/tmp/franky_perm_roundtrip";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, base);
    const path = base ++ "/permissions.json";

    var src = Store.init(gpa);
    defer src.deinit();
    try src.addAllowList("write,bash:git");
    try src.addDenyList("bash:rm");
    try saveToDisk(&src, gpa, io, path);

    var dst = Store.init(gpa);
    defer dst.deinit();
    try testing.expect(try loadFromDisk(&dst, gpa, io, path));
    try testing.expectEqual(Decision.auto_allow, dst.check("write", "{}"));
    try testing.expectEqual(Decision.auto_allow, dst.check("bash", "{\"command\":\"git status\"}"));
    try testing.expectEqual(Decision.auto_deny, dst.check("bash", "{\"command\":\"rm -rf /tmp\"}"));
}

test "loadFromDisk: missing file returns false (no error)" {
    const gpa = testing.allocator;
    var threaded = @import("../../test_helpers.zig").threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    var s = Store.init(gpa);
    defer s.deinit();
    const ok = try loadFromDisk(&s, gpa, io, "/nonexistent/path/permissions.json");
    try testing.expect(!ok);
}

test "loadFromDisk: malformed JSON returns error.MalformedJson" {
    const gpa = testing.allocator;
    var threaded = @import("../../test_helpers.zig").threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const base = "/tmp/franky_perm_malformed";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, base);
    const path = base ++ "/bad.json";

    // Drop a malformed JSON file via the same atomic-write helper
    // (saving a hand-rolled string would duplicate file IO logic).
    var f = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, "{ this isn't json");

    var s = Store.init(gpa);
    defer s.deinit();
    try testing.expectError(error.MalformedJson, loadFromDisk(&s, gpa, io, path));
}

test "defaultPath: prefers FRANKY_HOME, falls back to HOME/.franky" {
    const gpa = testing.allocator;
    var m = std.process.Environ.Map.init(gpa);
    defer m.deinit();

    // No env vars → null.
    try testing.expect((try defaultPath(gpa, &m)) == null);

    try m.put("HOME", "/tmp/u");
    const home_path = (try defaultPath(gpa, &m)).?;
    defer gpa.free(home_path);
    try testing.expectEqualStrings("/tmp/u/.franky/permissions.json", home_path);

    try m.put("FRANKY_HOME", "/srv/franky");
    const fh_path = (try defaultPath(gpa, &m)).?;
    defer gpa.free(fh_path);
    try testing.expectEqualStrings("/srv/franky/permissions.json", fh_path);
}

test "Store auto-persists on always_allow when persist_path is set" {
    // Walks the same code path waitForPrompt uses on `*_always`:
    // addToSet + saveToDisk. Then reloads into a fresh store to
    // confirm the entry survived the round-trip.
    const gpa = testing.allocator;
    var threaded = @import("../../test_helpers.zig").threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const base = "/tmp/franky_perm_autopersist";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, base);
    const path = base ++ "/permissions.json";

    var s = Store.init(gpa);
    defer s.deinit();
    s.persist_path = path;
    s.persist_io = io;

    try addToSet(s.allocator, &s.allow_bash, "git");
    try saveToDisk(&s, gpa, io, path);

    var s2 = Store.init(gpa);
    defer s2.deinit();
    try testing.expect(try loadFromDisk(&s2, gpa, io, path));
    try testing.expectEqual(Decision.auto_allow, s2.check("bash", "{\"command\":\"git status\"}"));
}

// ─── /permissions slash-command surface ───────────────────────────

test "Store.revoke: drops bash-fingerprint entry from allow set" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    try s.addAllowList("bash:git,bash:ls,write");

    try testing.expect(s.revoke("bash:git"));
    try testing.expectEqual(Decision.ask, s.check("bash", "{\"command\":\"git status\"}"));
    // ls fingerprint untouched.
    try testing.expectEqual(Decision.auto_allow, s.check("bash", "{\"command\":\"ls -la\"}"));
    // write tool untouched.
    try testing.expectEqual(Decision.auto_allow, s.check("write", "{}"));
}

test "Store.revoke: drops bare tool name from any set it appears in" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    try s.addAllowList("write");
    try s.addDenyList("edit");
    try s.addAskList("read");

    try testing.expect(s.revoke("write"));
    try testing.expect(s.revoke("edit"));
    try testing.expect(s.revoke("read"));
    try testing.expectEqual(@as(usize, 0), s.entryCount());
}

test "Store.revoke: returns false for unknown entries" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    try testing.expect(!s.revoke("nope"));
    try testing.expect(!s.revoke("bash:nope"));
    try testing.expect(!s.revoke(""));
    // Wrong prefix → not bash-scoped → never matches anywhere.
    try testing.expect(!s.revoke("foo:bar"));
}

test "Store.clearAll: wipes every set + flag" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    try s.addAllowList("write,bash:git");
    try s.addDenyList("bash:rm");
    try s.addAskList("all");
    s.yes_to_all = true;
    try testing.expect(s.entryCount() > 0);
    try testing.expect(s.ask_all);
    try testing.expect(s.yes_to_all);

    s.clearAll();
    try testing.expectEqual(@as(usize, 0), s.entryCount());
    try testing.expect(!s.ask_all);
    try testing.expect(!s.yes_to_all);
    // Defaults restored.
    try testing.expectEqual(Decision.ask, s.check("bash", "{\"command\":\"git status\"}"));
}

test "Store.entryCount: sums across all six sets" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    try testing.expectEqual(@as(usize, 0), s.entryCount());
    try s.addAllowList("write,bash:git,bash:ls");
    try s.addDenyList("bash:rm");
    try s.addAskList("read");
    try testing.expectEqual(@as(usize, 5), s.entryCount());
}

test "Store.revoke + persist_path: rewrite is observable from a fresh store" {
    const gpa = testing.allocator;
    var threaded = @import("../../test_helpers.zig").threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const base = "/tmp/franky_perm_revoke";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, base);
    const path = base ++ "/permissions.json";

    var s = Store.init(gpa);
    defer s.deinit();
    s.persist_path = path;
    s.persist_io = io;
    try s.addAllowList("bash:git,bash:ls");
    try saveToDisk(&s, gpa, io, path);

    // Confirm both fingerprints land on disk first.
    var loaded = Store.init(gpa);
    defer loaded.deinit();
    try testing.expect(try loadFromDisk(&loaded, gpa, io, path));
    try testing.expectEqual(@as(usize, 2), loaded.entryCount());

    // Revoke one — should auto-persist.
    try testing.expect(s.revoke("bash:git"));

    // Reload again; only `ls` should remain.
    var after = Store.init(gpa);
    defer after.deinit();
    try testing.expect(try loadFromDisk(&after, gpa, io, path));
    try testing.expectEqual(@as(usize, 1), after.entryCount());
    try testing.expectEqual(Decision.auto_allow, after.check("bash", "{\"command\":\"ls -la\"}"));
    try testing.expectEqual(Decision.ask, after.check("bash", "{\"command\":\"git status\"}"));
}

test "Store.addBareEntry: tool-name allow + bash fingerprint deny" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    try s.addBareEntry("read", .allow, false);
    try s.addBareEntry("write", .deny, false);
    try s.addBareEntry("git", .allow, true);
    try s.addBareEntry("rm", .deny, true);
    // Tool-level allow → auto_allow; tool-level deny → auto_deny.
    try testing.expectEqual(Decision.auto_allow, s.check("read", "{}"));
    try testing.expectEqual(Decision.auto_deny, s.check("write", "{}"));
    // Bash fingerprint allow/deny.
    try testing.expectEqual(Decision.auto_allow, s.check("bash", "{\"command\":\"git status\"}"));
    try testing.expectEqual(Decision.auto_deny, s.check("bash", "{\"command\":\"rm -rf /\"}"));
}

test "Store.addBareEntry: empty name silently skipped" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    try s.addBareEntry("", .allow, false);
    try s.addBareEntry("", .deny, true);
    try testing.expectEqual(@as(usize, 0), s.entryCount());
}

test "Store.check: yes_to_all + ask_all → auto_allow (CI gate-active mode)" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    try s.addAskList("all");
    s.yes_to_all = true;
    // Gate runs through every call (ask_all) but auto-confirms each
    // because yes_to_all is set. Useful in CI where you want the audit
    // trail of "gate fired" without manual confirmations.
    try testing.expectEqual(Decision.auto_allow, s.check("read", "{}"));
    try testing.expectEqual(Decision.auto_allow, s.check("write", "{}"));
    try testing.expectEqual(Decision.auto_allow, s.check("bash", "{\"command\":\"git status\"}"));
}

test "extractBashCommand: handles common shapes" {
    try testing.expect(extractBashCommand("{}") == null);
    try testing.expect(extractBashCommand("{\"x\":1}") == null);
    try testing.expectEqualStrings("git status", extractBashCommand("{\"command\":\"git status\"}").?);
    try testing.expectEqualStrings(
        "rm -rf /tmp",
        extractBashCommand("{\"command\":\"rm -rf /tmp\",\"timeout\":5}").?,
    );
}

test "SessionGates.beforeToolCall: no store → never blocks" {
    var gates = SessionGates{};
    var tool: at.AgentTool = .{ .name = "bash", .description = "", .parameters_json = "{}", .execute = undefined };
    const dec = SessionGates.beforeToolCall(@ptrCast(&gates), &tool, "c1", "{}");
    try testing.expect(!dec.block);
}

test "SessionGates.beforeToolCall: store + ask → blocks with hint" {
    var store = Store.init(testing.allocator);
    defer store.deinit();
    var gates = SessionGates{ .permissions = &store };
    var tool: at.AgentTool = .{ .name = "bash", .description = "", .parameters_json = "{}", .execute = undefined };
    const dec = SessionGates.beforeToolCall(@ptrCast(&gates), &tool, "c1", "{\"command\":\"rm -rf /\"}");
    try testing.expect(dec.block);
    try testing.expect(dec.reason_text != null);
    try testing.expect(std.mem.indexOf(u8, dec.reason_text.?, "--allow-tools") != null);
}

test "SessionGates.beforeToolCall: store + auto_allow → passes through" {
    var store = Store.init(testing.allocator);
    defer store.deinit();
    try store.addAllowList("bash:git");
    var gates = SessionGates{ .permissions = &store };
    var tool: at.AgentTool = .{ .name = "bash", .description = "", .parameters_json = "{}", .execute = undefined };
    const dec = SessionGates.beforeToolCall(@ptrCast(&gates), &tool, "c1", "{\"command\":\"git status\"}");
    try testing.expect(!dec.block);
}

test "Resolution.fromString" {
    try testing.expectEqual(Resolution.allow_once, Resolution.fromString("allow_once").?);
    try testing.expectEqual(Resolution.always_deny, Resolution.fromString("always_deny").?);
    try testing.expect(Resolution.fromString("garbage") == null);
}

test "fingerprintFor: bash uses command verb, others use tool name" {
    try testing.expectEqualStrings("git", fingerprintFor("bash", "{\"command\":\"git status\"}"));
    try testing.expectEqualStrings("write", fingerprintFor("write", "{\"path\":\"x.zig\"}"));
}

/// Test fixture: the worker thread plays the role of the agent
/// loop calling `before_tool_call`. The main test thread plays
/// the role of a mode driver — it consumes the channel until it
/// sees the `tool_permission_request` event, then calls
/// `resolve`. Reading the event before resolving is what avoids
/// the race (the slot is in the pending map by the time the
/// event lands on the channel).
const PromptTestWorker = struct {
    gates: *SessionGates,
    tool_name: []const u8,
    args_json: []const u8,
    call_id: []const u8,
    result: agent_loop.HookDecision = .{ .block = false },
    done: std.Io.Mutex = .init,

    fn run(self: *PromptTestWorker) void {
        var tool: at.AgentTool = .{
            .name = self.tool_name,
            .description = "",
            .parameters_json = "{}",
            .execute = undefined,
        };
        self.result = SessionGates.beforeToolCall(
            @ptrCast(self.gates),
            &tool,
            self.call_id,
            self.args_json,
        );
    }
};

/// Drain the channel until `tool_permission_request` arrives,
/// then call resolve with `decision`. Returns the call_id seen
/// in the event (caller compares).
fn drainAndResolve(
    ch: *agent_loop.AgentChannel,
    io: std.Io,
    gpa: std.mem.Allocator,
    prompter: *PermissionPrompter,
    decision: Resolution,
    expected_fingerprint: []const u8,
) !void {
    while (ch.next(io)) |ev| {
        switch (ev) {
            .tool_permission_request => |r| {
                try testing.expectEqualStrings(expected_fingerprint, r.fingerprint);
                try prompter.resolve(r.call_id, decision);
                ev.deinit(gpa);
                return;
            },
            else => {},
        }
        ev.deinit(gpa);
    }
    return error.NoRequestEvent;
}

test "PermissionPrompter: allow_once round-trip pushes event and lets call through" {
    var threaded = @import("../../test_helpers.zig").threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var ch = try agent_loop.AgentChannel.initWithDrop(gpa, 8, at.AgentEvent.deinit, gpa);
    defer ch.deinit();
    var store = Store.init(gpa);
    defer store.deinit();
    var prompter = PermissionPrompter.init(gpa, io, &ch);
    defer prompter.deinit();
    var gates = SessionGates{ .permissions = &store, .prompter = &prompter };

    var worker = PromptTestWorker{
        .gates = &gates,
        .tool_name = "bash",
        .args_json = "{\"command\":\"git status\"}",
        .call_id = "c1",
    };
    const t = try std.Thread.spawn(.{}, PromptTestWorker.run, .{&worker});

    try drainAndResolve(&ch, io, gpa, &prompter, .allow_once, "git");
    t.join();
    try testing.expect(!worker.result.block);
}

test "PermissionPrompter: always_allow promotes to store" {
    var threaded = @import("../../test_helpers.zig").threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var ch = try agent_loop.AgentChannel.initWithDrop(gpa, 8, at.AgentEvent.deinit, gpa);
    defer ch.deinit();
    var store = Store.init(gpa);
    defer store.deinit();
    var prompter = PermissionPrompter.init(gpa, io, &ch);
    defer prompter.deinit();
    var gates = SessionGates{ .permissions = &store, .prompter = &prompter };

    var worker = PromptTestWorker{
        .gates = &gates,
        .tool_name = "bash",
        .args_json = "{\"command\":\"git status\"}",
        .call_id = "c1",
    };
    const t = try std.Thread.spawn(.{}, PromptTestWorker.run, .{&worker});

    try drainAndResolve(&ch, io, gpa, &prompter, .always_allow, "git");
    t.join();
    try testing.expect(!worker.result.block);

    // A second call with a different `git` invocation should
    // auto-allow now (no resolver running) — the always-decision
    // got promoted into the store under fingerprint "git".
    try testing.expectEqual(Decision.auto_allow, store.check("bash", "{\"command\":\"git push\"}"));
}

test "PermissionPrompter: deny_once blocks with user-denied reason" {
    var threaded = @import("../../test_helpers.zig").threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var ch = try agent_loop.AgentChannel.initWithDrop(gpa, 8, at.AgentEvent.deinit, gpa);
    defer ch.deinit();
    var store = Store.init(gpa);
    defer store.deinit();
    var prompter = PermissionPrompter.init(gpa, io, &ch);
    defer prompter.deinit();
    var gates = SessionGates{ .permissions = &store, .prompter = &prompter };

    var worker = PromptTestWorker{
        .gates = &gates,
        .tool_name = "bash",
        .args_json = "{\"command\":\"rm -rf /\"}",
        .call_id = "c1",
    };
    const t = try std.Thread.spawn(.{}, PromptTestWorker.run, .{&worker});

    try drainAndResolve(&ch, io, gpa, &prompter, .deny_once, "rm");
    t.join();
    try testing.expect(worker.result.block);
    try testing.expect(worker.result.reason_text != null);
    try testing.expect(std.mem.indexOf(u8, worker.result.reason_text.?, "denied by user") != null);
}

test "PermissionPrompter.resolve on stale call_id returns NotPending" {
    var threaded = @import("../../test_helpers.zig").threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;
    var ch = try agent_loop.AgentChannel.initWithDrop(gpa, 8, at.AgentEvent.deinit, gpa);
    defer ch.deinit();
    var prompter = PermissionPrompter.init(gpa, io, &ch);
    defer prompter.deinit();
    try testing.expectError(error.NotPending, prompter.resolve("never-issued", .allow_once));
}
