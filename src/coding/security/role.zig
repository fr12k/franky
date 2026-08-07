//! Capability roles — `permission.md`.
//!
//! A `Role` is a coarse capability tier picked at session
//! init. It controls *which built-in tools* the agent
//! registry contains, plus the runtime gate that responds
//! to `tool_call` events for tool names that aren't in the
//! filtered registry.
//!
//! Four roles, ordered weakest → strongest:
//!
//!   - `read` — inspection only (`read`/`ls`/`find`/`grep`).
//!   - `plan` — read + workspace-scoped writes
//!     (`write`/`edit` added). No shell.
//!   - `code` — `plan` + `bash` (cwd-locked, env-denylisted,
//!     shell-trusted via §R).
//!   - `full` — every tool, no §R restrictions. Recommended
//!     only inside a sandbox.
//!
//! The role binds at session init. There is no mid-session
//! escalation — to change roles, restart franky. This is
//! intentional: escalation paths in security designs are
//! reliable bug surfaces.
//!
//! Default: `plan` (least-disruptive that's still useful;
//! "zero risk of arbitrary execution out of the box").

const std = @import("std");
const at = @import("../../agent/types.zig");
// RoleDenial / HookDecision contract types now live in
// agent/types.zig (the contract module). Previously this file
// imported agent/loop.zig (the 2800-line runtime) just to reach
// RoleDenial — a leaking abstraction that pulled the entire
// loop implementation into the security module's dependency graph.

pub const Role = enum {
    read,
    plan,
    code,
    full,

    /// Parse a `--role <name>` argument. Unknown values
    /// surface as `error.UnknownRole` so the CLI driver can
    /// fail-closed rather than silently fall back to `full`.
    pub fn fromString(s: []const u8) error{UnknownRole}!Role {
        if (std.mem.eql(u8, s, "read")) return .read;
        if (std.mem.eql(u8, s, "plan")) return .plan;
        if (std.mem.eql(u8, s, "code")) return .code;
        if (std.mem.eql(u8, s, "full")) return .full;
        return error.UnknownRole;
    }

    pub fn toString(self: Role) []const u8 {
        return @tagName(self);
    }

    /// Human-readable summary for status bars and `--help`
    /// output. Tight enough to fit in a single status row.
    pub fn shortDescription(self: Role) []const u8 {
        return switch (self) {
            .read => "read-only inspection",
            .plan => "read + workspace writes (no shell)",
            .code => "plan + shell (workspace-scoped)",
            .full => "all tools, no restrictions",
        };
    }

    /// Total ordering — `a.atLeast(b)` is true when `a` is
    /// `b` or stronger. Used to derive `ToolSet.forRole`.
    pub fn atLeast(self: Role, other: Role) bool {
        return @intFromEnum(self) >= @intFromEnum(other);
    }
};

/// Single source of truth for built-in tool names + the
/// minimum role each one requires. Adding a new built-in is
/// a one-line edit here; `ToolSet`, `allows`, `minRoleFor`,
/// `isKnownToolName`, `allowedNames`, and `forRole` all
/// derive from this table.
const ToolEntry = struct { name: []const u8, min_role: Role };
const tool_table = [_]ToolEntry{
    .{ .name = "read", .min_role = .read },
    .{ .name = "ls", .min_role = .read },
    .{ .name = "find", .min_role = .read },
    .{ .name = "grep", .min_role = .read },
    .{ .name = "web_search", .min_role = .read },
    .{ .name = "web_fetch", .min_role = .read },
    .{ .name = "write", .min_role = .plan },
    .{ .name = "edit", .min_role = .plan },
    .{ .name = "bash", .min_role = .code },
};

/// Per-tool allow flags. Tool names match the registry entries
/// in `src/coding/mod.zig::tools`. The set is computed from
/// `tool_table` — no per-tool field editing required when adding
/// a new built-in.
pub const ToolSet = struct {
    /// Bit `i` is set iff `tool_table[i].min_role <= role`.
    /// Sized for `tool_table.len` so the compiler will catch
    /// any drift if the table grows.
    /// Default-initialized to all zeros via `.{}`.
    bits: std.StaticBitSet(tool_table.len) = .empty,

    pub fn forRole(r: Role) ToolSet {
        var ts: ToolSet = .{};
        inline for (tool_table, 0..) |entry, i| {
            if (r.atLeast(entry.min_role)) ts.bits.set(i);
        }
        return ts;
    }

    /// Lookup by tool name. Returns `false` for unknown names —
    /// callers handle "unknown tool" separately via the
    /// existing not-found path.
    pub fn allows(self: ToolSet, tool_name: []const u8) bool {
        if (indexOf(tool_name)) |i| return self.bits.isSet(i);
        return false;
    }

    /// True when `name` is a recognized built-in but currently
    /// disabled — distinct from "unknown tool name". Used by
    /// the runtime gate to emit `role_denied` rather than the
    /// generic "unknown tool" path.
    pub fn isKnownButDisabled(self: ToolSet, tool_name: []const u8) bool {
        if (indexOf(tool_name)) |i| return !self.bits.isSet(i);
        return false;
    }
};

fn indexOf(tool_name: []const u8) ?usize {
    for (tool_table, 0..) |entry, i| {
        if (std.mem.eql(u8, tool_name, entry.name)) return i;
    }
    return null;
}

pub fn isKnownToolName(tool_name: []const u8) bool {
    return indexOf(tool_name) != null;
}

/// Minimum role that re-enables `tool_name`, or null for
/// unknown names. Used in `role_denied` error messages.
pub fn minRoleFor(tool_name: []const u8) ?Role {
    if (indexOf(tool_name)) |i| return tool_table[i].min_role;
    return null;
}

/// Heap-allocated slice of permitted tool names. Order matches
/// `tool_table` so status displays are stable. Caller frees.
pub fn allowedNames(allocator: std.mem.Allocator, set: ToolSet) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(allocator);
    for (tool_table, 0..) |entry, i| {
        if (set.bits.isSet(i)) try out.append(allocator, entry.name);
    }
    return out.toOwnedSlice(allocator);
}

/// Filter a tool array by ToolSet — returns a heap-allocated
/// slice owned by `allocator`. Tools not allowed by `set` are
/// elided; their names won't appear in the model's tool list.
/// The runtime gate handles `tool_call` events for tools that
/// *would* exist under a higher role.
pub fn filterTools(
    allocator: std.mem.Allocator,
    all: []const at.AgentTool,
    set: ToolSet,
) ![]at.AgentTool {
    var out: std.ArrayList(at.AgentTool) = .empty;
    errdefer out.deinit(allocator);
    for (all) |t| {
        if (set.allows(t.name)) try out.append(allocator, t);
    }
    return out.toOwnedSlice(allocator);
}

/// Runtime role gate. Bound to the active role + ToolSet at
/// session init; passed into the agent loop's `Config` as
/// `hook_userdata` + the `role_denied` callback below. Lives
/// at a stable address for the session's lifetime so the
/// agent-loop worker thread can dereference it safely.
pub const RoleGate = struct {
    role: Role,
    set: ToolSet,

    pub fn init(role: Role) RoleGate {
        return .{ .role = role, .set = ToolSet.forRole(role) };
    }

    /// Callback for the agent loop's `Config.role_denied`. Returns a
    /// non-null `RoleDenial` only when `tool_name` is a known
    /// franky built-in disabled by the active role; otherwise
    /// `null` so the loop falls through to its existing
    /// "unknown tool" path.
    pub fn check(userdata: ?*anyopaque, tool_name: []const u8) ?at.RoleDenial {
        const self: *RoleGate = @ptrCast(@alignCast(userdata.?));
        if (!self.set.isKnownButDisabled(tool_name)) return null;
        const min = if (minRoleFor(tool_name)) |r| r.toString() else null;
        return .{
            .current_role = self.role.toString(),
            .min_role = min,
        };
    }
};

// ─── sandbox detection ────────────────────────────────────────────

/// Env vars that signal "we're inside a sandbox". File-based
/// heuristics (e.g. `/.dockerenv`) are deliberately omitted so
/// detection runs without `std.Io` plumbing — CI scripts that
/// set `$ZEROBOX_ACTIVE` cover the common case, and a missed
/// sandbox just produces an extra warning line.
const sandbox_env_vars = [_][]const u8{
    "ZEROBOX_ACTIVE", // zerobox wrapper
    "container", // systemd-nspawn / podman
    "DOCKER_CONTAINER", // userland convention
};

/// Best-effort detection — see `sandbox_env_vars`.
pub fn detectSandbox(environ: std.process.Environ) bool {
    for (sandbox_env_vars) |key| {
        if (environ.getPosix(key)) |_| return true;
    }
    return false;
}

/// Map-based variant — used in code paths that hold a
/// `*std.process.Environ.Map` (slash handlers, RPC sessions)
/// rather than a live `std.process.Environ`.
pub fn detectSandboxFromMap(map: *const std.process.Environ.Map) bool {
    for (sandbox_env_vars) |key| {
        if (map.get(key)) |_| return true;
    }
    return false;
}

// ─── status JSON shared by proxy + rpc surfaces ───────────────────

/// Render the `{role, description, sandbox, allowed_tools}`
/// status payload that both `coding/modes/proxy.zig::respondRole`
/// (HTTP) and `coding/modes/rpc.zig::writeRoleResult`
/// (JSON-RPC) expose. Single source of truth for the wire
/// shape so the two surfaces can never drift.
///
/// All values are ASCII-safe constants today (`Role.toString`
/// produces enum tags; tool names are restricted to
/// `[a-z]+`); JSON escaping is unnecessary. Add an escaper
/// here before plumbing user-controlled strings through.
pub fn renderRoleStatusJson(
    allocator: std.mem.Allocator,
    role: Role,
    set: ToolSet,
    sandboxed: bool,
    provider_name: []const u8,
    model_id: []const u8,
    extra_tools: []const []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    const head = try std.fmt.allocPrint(
        allocator,
        "{{\"role\":\"{s}\",\"description\":\"{s}\",\"sandbox\":{s},\"provider\":\"{s}\",\"model\":\"{s}\",\"allowed_tools\":[",
        .{ role.toString(), role.shortDescription(), if (sandboxed) "true" else "false", provider_name, model_id },
    );
    defer allocator.free(head);
    try buf.appendSlice(allocator, head);

    var first = true;
    for (tool_table, 0..) |entry, i| {
        if (!set.bits.isSet(i)) continue;
        if (!first) try buf.append(allocator, ',');
        first = false;
        try buf.append(allocator, '"');
        try buf.appendSlice(allocator, entry.name);
        try buf.append(allocator, '"');
    }
    // Extension tools are not in tool_table (hardcoded built-ins);
    // they are unconditionally allowed since no role gate applies
    // to them (role filtering happens before extension loading).
    for (extra_tools) |name| {
        if (!first) try buf.append(allocator, ',');
        first = false;
        try buf.append(allocator, '"');
        try buf.appendSlice(allocator, name);
        try buf.append(allocator, '"');
    }
    try buf.appendSlice(allocator, "]}");
    return buf.toOwnedSlice(allocator);
}

// ─── tests ────────────────────────────────────────────────────────

const testing = std.testing;

test "Role.fromString: known + unknown" {
    try testing.expectEqual(Role.read, try Role.fromString("read"));
    try testing.expectEqual(Role.plan, try Role.fromString("plan"));
    try testing.expectEqual(Role.code, try Role.fromString("code"));
    try testing.expectEqual(Role.full, try Role.fromString("full"));
    try testing.expectError(error.UnknownRole, Role.fromString("admin"));
    try testing.expectError(error.UnknownRole, Role.fromString(""));
}

test "ToolSet.forRole: read enables only inspection tools" {
    const ts = ToolSet.forRole(.read);
    try testing.expect(ts.allows("read") and ts.allows("ls") and ts.allows("find") and ts.allows("grep"));
    try testing.expect(!ts.allows("write") and !ts.allows("edit") and !ts.allows("bash"));
}

test "ToolSet.forRole: plan enables read + write/edit, no bash" {
    const ts = ToolSet.forRole(.plan);
    try testing.expect(ts.allows("read") and ts.allows("write") and ts.allows("edit"));
    try testing.expect(!ts.allows("bash"));
}

test "ToolSet.forRole: code adds bash to plan" {
    const ts = ToolSet.forRole(.code);
    try testing.expect(ts.allows("read") and ts.allows("write") and ts.allows("edit") and ts.allows("bash"));
}

test "ToolSet.forRole: full enables every tool" {
    const ts = ToolSet.forRole(.full);
    try testing.expect(ts.allows("read") and ts.allows("ls") and ts.allows("find") and ts.allows("grep"));
    try testing.expect(ts.allows("write") and ts.allows("edit") and ts.allows("bash"));
}

test "ToolSet.allows: name lookup" {
    const ts = ToolSet.forRole(.plan);
    try testing.expect(ts.allows("read"));
    try testing.expect(ts.allows("write"));
    try testing.expect(!ts.allows("bash"));
    try testing.expect(!ts.allows("unknown"));
}

test "ToolSet.isKnownButDisabled: bash under plan, false under code" {
    const plan_ts = ToolSet.forRole(.plan);
    try testing.expect(plan_ts.isKnownButDisabled("bash"));
    try testing.expect(!plan_ts.isKnownButDisabled("read"));
    try testing.expect(!plan_ts.isKnownButDisabled("unknown_tool"));

    const code_ts = ToolSet.forRole(.code);
    try testing.expect(!code_ts.isKnownButDisabled("bash"));
}

test "minRoleFor: bash needs code; read needs read" {
    try testing.expectEqual(Role.code, minRoleFor("bash").?);
    try testing.expectEqual(Role.plan, minRoleFor("write").?);
    try testing.expectEqual(Role.plan, minRoleFor("edit").?);
    try testing.expectEqual(Role.read, minRoleFor("read").?);
    try testing.expect(minRoleFor("unknown") == null);
}

test "renderRoleStatusJson: plan emits the wire shape" {
    const json = try renderRoleStatusJson(testing.allocator, .plan, ToolSet.forRole(.plan), false, "anthropic", "claude-sonnet-4-6", &.{});
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"role\":\"plan\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"sandbox\":false") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"write\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"bash\"") == null);
}
