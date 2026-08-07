//! Skills — domain-knowledge bundles auto-injected into the system
//! prompt.
//!
//! A skill is a Markdown file with YAML-subset frontmatter:
//!
//! ```markdown
//! ---
//! name: zig
//! description: |
//!   Idioms for Zig 0.17-dev. TRIGGER when: editing .zig files…
//! auto_apply: ["**/*.zig", "build.zig", "build.zig.zon"]
//! ---
//!
//! # Body content the model reads as context…
//! ```
//!
//! Activation paths (deterministic — model never decides):
//!   1. `--skill NAME` repeatable CLI flag → forced active.
//!   2. `auto_apply` glob matches any file in the workspace tree
//!      (respecting `.gitignore` + the `.git/` hard-skip from `find`).
//!
//! When active, the skill's body is appended verbatim to the system
//! prompt under an `## Active skills` header. Inactive skills cost
//! zero tokens.
//!
//! Roots are scanned in precedence order (high → low):
//!   1. `cfg.skills_path` (`--skills <dir>`) — explicit override.
//!   2. `<workspace>/skills/`
//!   3. `$FRANKY_HOME/skills/`
//!
//! Same `name` in multiple roots → high-precedence wins. `index.md`
//! is reserved for human browsing and skipped by the loader.

const std = @import("std");
const find_mod = @import("tools/find.zig");
const gitignore = @import("gitignore.zig");
const ai_log = @import("../ai/log.zig");

pub const reserved_index_filename = "index.md";

/// Soft cap on bodies appended to the system prompt. When the
/// concatenated active-skill body exceeds this many bytes, the
/// renderer logs a warning and falls back to descriptions only.
pub const max_body_bytes: usize = 200_000;

pub const Frontmatter = struct {
    /// Required.
    name: []const u8,
    /// Optional. `.agents/skills/*/skill.md` uses `id:` when `name:` is absent.
    /// When both are present, `name` wins and `id` is stored as an alias.
    id: ?[]const u8 = null,
    /// Required. May be multi-line via YAML `description: |`.
    description: []const u8,
    /// Optional. Empty slice when absent. Glob syntax matches
    /// `find.globMatch` (`*`, `**`, `?`, `[abc]`).
    auto_apply: []const []const u8,
    /// Optional. When false, the skill is excluded from the active set
    /// regardless of auto_apply or explicit selection. Default true.
    enabled: bool = true,
};

pub const Skill = struct {
    meta: Frontmatter,
    body: []const u8,
    /// Absolute path the skill was loaded from. Borrowed slice into
    /// the arena that owns this Skill.
    source_path: []const u8,

    pub fn deinit(self: *Skill, allocator: std.mem.Allocator) void {
        allocator.free(self.meta.name);
        if (self.meta.id) |id| allocator.free(id);
        allocator.free(self.meta.description);
        for (self.meta.auto_apply) |g| allocator.free(g);
        allocator.free(self.meta.auto_apply);
        allocator.free(self.body);
        allocator.free(self.source_path);
    }
};

pub const ParseError = error{
    MissingFrontmatter,
    UnclosedFrontmatter,
    MissingName,
    MissingDescription,
} || std.mem.Allocator.Error;

/// Parse a single skill file. Returns the parsed skill or
/// `ParseError` on malformed input. `source_path` is duped into
/// `allocator` so the caller may free `text` immediately.
pub fn parseSkill(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    text: []const u8,
) ParseError!Skill {
    if (!std.mem.startsWith(u8, text, "---\n") and !std.mem.startsWith(u8, text, "---\r\n"))
        return ParseError.MissingFrontmatter;

    const after_open = if (std.mem.startsWith(u8, text, "---\r\n")) text[5..] else text[4..];

    // Find the closing `---` line. Tolerated terminators: `\n---\n`,
    // `\n---\r\n`, or `\n---` at end-of-string (no trailing newline —
    // common in Zig multi-line string literals used by tests).
    var close_at: ?usize = null;
    var close_after: usize = 0;
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, after_open, search_from, "\n---")) |pos| {
        const tail_start = pos + 4; // past `\n---`
        if (tail_start == after_open.len) {
            close_at = pos;
            close_after = tail_start;
            break;
        }
        if (after_open[tail_start] == '\n') {
            close_at = pos;
            close_after = tail_start + 1;
            break;
        }
        if (after_open[tail_start] == '\r' and tail_start + 1 < after_open.len and after_open[tail_start + 1] == '\n') {
            close_at = pos;
            close_after = tail_start + 2;
            break;
        }
        search_from = pos + 1;
    }
    const close_idx = close_at orelse return ParseError.UnclosedFrontmatter;
    const fm_text = after_open[0..close_idx];
    const raw_body = if (close_after < after_open.len) after_open[close_after..] else "";

    var name_owned: ?[]u8 = null;
    var id_owned: ?[]u8 = null;
    var description_owned: ?[]u8 = null;
    var auto_apply_list: std.ArrayList([]const u8) = .empty;
    var enabled: bool = true;
    errdefer {
        if (name_owned) |n| allocator.free(n);
        if (id_owned) |id| allocator.free(id);
        if (description_owned) |d| allocator.free(d);
        for (auto_apply_list.items) |g| allocator.free(g);
        auto_apply_list.deinit(allocator);
    }

    var i: usize = 0;
    while (i < fm_text.len) {
        const eol = std.mem.indexOfScalarPos(u8, fm_text, i, '\n') orelse fm_text.len;
        const raw_line = fm_text[i..eol];
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        i = eol + 1;
        if (line.len == 0) continue;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        const rest = std.mem.trim(u8, line[colon + 1 ..], " \t");

        if (std.mem.eql(u8, key, "name")) {
            if (name_owned) |old| allocator.free(old);
            name_owned = try allocator.dupe(u8, rest);
        } else if (std.mem.eql(u8, key, "id")) {
            if (id_owned) |old| allocator.free(old);
            id_owned = try allocator.dupe(u8, rest);
        } else if (std.mem.eql(u8, key, "description")) {
            if (description_owned) |old| allocator.free(old);
            if (std.mem.eql(u8, rest, "|") or std.mem.eql(u8, rest, "|-")) {
                description_owned = try readBlockScalar(allocator, fm_text, &i);
            } else {
                description_owned = try allocator.dupe(u8, rest);
            }
        } else if (std.mem.eql(u8, key, "auto_apply")) {
            try parseStringArray(allocator, rest, &auto_apply_list);
        } else if (std.mem.eql(u8, key, "enabled")) {
            enabled = std.mem.eql(u8, rest, "true");
        }
        // Unknown keys silently ignored (forward-compat).
    }

    const name = name_owned orelse id_owned orelse return ParseError.MissingName;
    const description = description_owned orelse return ParseError.MissingDescription;

    // Take ownership of the glob list. After this point, errdefer
    // for `auto_apply_list` is dead (list is empty) — register a new
    // errdefer for the owned slice so subsequent `try`s clean up.
    const auto_apply_owned = try auto_apply_list.toOwnedSlice(allocator);
    errdefer {
        for (auto_apply_owned) |g| allocator.free(g);
        allocator.free(auto_apply_owned);
    }

    const body_owned = try allocator.dupe(u8, raw_body);
    errdefer allocator.free(body_owned);
    const path_owned = try allocator.dupe(u8, source_path);

    // If `name` was taken from `id` (no `name:` key), the id field
    // becomes null (already consumed). Otherwise keep it as alias.
    const id_final: ?[]u8 = if (name_owned != null) id_owned else null;

    return .{
        .meta = .{
            .name = name,
            .id = id_final,
            .description = description,
            .auto_apply = auto_apply_owned,
            .enabled = enabled,
        },
        .body = body_owned,
        .source_path = path_owned,
    };
}

/// Parse a YAML literal block scalar (`|` indicator). Reads
/// indented lines until an outdent or blank-then-outdent.
/// Advances `*cursor` past the consumed lines.
fn readBlockScalar(
    allocator: std.mem.Allocator,
    text: []const u8,
    cursor: *usize,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var first = true;
    var indent: usize = 0;

    while (cursor.* < text.len) {
        const eol = std.mem.indexOfScalarPos(u8, text, cursor.*, '\n') orelse text.len;
        const raw_line = text[cursor.*..eol];
        const line = std.mem.trimEnd(u8, raw_line, "\r");

        var leading: usize = 0;
        while (leading < line.len and (line[leading] == ' ' or line[leading] == '\t')) : (leading += 1) {}

        const is_blank = leading == line.len;

        if (first and !is_blank) {
            if (leading == 0) break; // not indented — block ends before first line
            indent = leading;
            first = false;
        } else if (!first and !is_blank and leading < indent) {
            break; // outdent terminates the block
        }

        if (!first or !is_blank) {
            if (out.items.len > 0) try out.append(allocator, '\n');
            const start = if (is_blank) line.len else @min(indent, line.len);
            try out.appendSlice(allocator, line[start..]);
        }

        cursor.* = eol + 1;
    }

    return try out.toOwnedSlice(allocator);
}

/// Parse a JSON-style array of strings: `["a", "b"]`. Whitespace
/// tolerant. Append each into `list` (allocated copies).
fn parseStringArray(
    allocator: std.mem.Allocator,
    text: []const u8,
    list: *std.ArrayList([]const u8),
) !void {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len < 2 or trimmed[0] != '[' or trimmed[trimmed.len - 1] != ']') return;
    const inner = trimmed[1 .. trimmed.len - 1];

    var i: usize = 0;
    while (i < inner.len) {
        while (i < inner.len and (inner[i] == ' ' or inner[i] == '\t' or inner[i] == ',')) : (i += 1) {}
        if (i >= inner.len) break;
        if (inner[i] != '"') break; // malformed — bail
        i += 1;
        const start = i;
        while (i < inner.len and inner[i] != '"') : (i += 1) {}
        if (i >= inner.len) break;
        try list.append(allocator, try allocator.dupe(u8, inner[start..i]));
        i += 1;
    }
}

pub const Roots = struct {
    /// `--skills <dir>` — borrowed, not owned.
    explicit_root: ?[]const u8 = null,
    /// `<workspace>/skills/` — owned (joined PWD + "skills").
    workspace_root: ?[]u8 = null,
    /// `$FRANKY_HOME/skills/` or `$HOME/.franky/skills/` — owned.
    user_root: ?[]u8 = null,
    /// NEW — directories from standard locations (read-only).
    standard_roots: []const []const u8 = &.{},
    /// Bare PWD, used for `auto_apply` glob walks (separate from
    /// `workspace_root` because the glob is scanned over the
    /// project root, not the skills dir). Borrowed.
    workspace_for_glob: ?[]const u8 = null,

    pub fn deinit(self: *Roots, allocator: std.mem.Allocator) void {
        if (self.workspace_root) |b| allocator.free(b);
        if (self.user_root) |b| allocator.free(b);
        for (self.standard_roots) |r| allocator.free(r);
        allocator.free(self.standard_roots);
        self.workspace_root = null;
        self.user_root = null;
        self.standard_roots = &.{};
    }

    /// Resolve paths for standard skill roots (.agents/skills/,
    /// .claude/skills/, .cursor/rules/) at workspace and home levels.
    pub fn resolveStandard(allocator: std.mem.Allocator, workspace: ?[]const u8, home: ?[]const u8) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (out.items) |p| allocator.free(p);
            out.deinit(allocator);
        }
        if (workspace) |p| {
            try out.append(allocator, try std.fs.path.join(allocator, &.{ p, ".agents", "skills" }));
            try out.append(allocator, try std.fs.path.join(allocator, &.{ p, ".claude", "skills" }));
            try out.append(allocator, try std.fs.path.join(allocator, &.{ p, ".cursor", "rules" }));
        }
        if (home) |h| {
            try out.append(allocator, try std.fs.path.join(allocator, &.{ h, ".agents", "skills" }));
            try out.append(allocator, try std.fs.path.join(allocator, &.{ h, ".claude", "skills" }));
        }
        return try out.toOwnedSlice(allocator);
    }
};

/// Resolve the three skill roots from an `Environ.Map` (proxy).
pub fn resolveRootsFromMap(
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    explicit: ?[]const u8,
) !Roots {
    var r: Roots = .{};
    r.explicit_root = explicit;
    if (environ_map.get("PWD")) |p| if (p.len > 0) {
        r.workspace_for_glob = p;
        r.workspace_root = try std.fs.path.join(allocator, &.{ p, "skills" });
    };
    if (environ_map.get("FRANKY_HOME")) |h| {
        if (h.len > 0) r.user_root = try std.fs.path.join(allocator, &.{ h, "skills" });
    } else if (environ_map.get("HOME")) |h| {
        if (h.len > 0) r.user_root = try std.fs.path.join(allocator, &.{ h, ".franky", "skills" });
    }
    // Resolve standard roots.
    const pwd = if (environ_map.get("PWD")) |p| if (p.len > 0) p else null else null;
    const home = if (environ_map.get("FRANKY_HOME")) |h| if (h.len > 0) h else null else if (environ_map.get("HOME")) |h| if (h.len > 0) h else null else null;
    r.standard_roots = try Roots.resolveStandard(allocator, pwd, home);
    return r;
}


/// Render a human-readable listing of every loaded skill, marking
/// each one ACTIVE / idle along with the reason. Used by the
/// `/skills` slash command in proxy.
pub fn buildListingFromMap(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    explicit_skills_path: ?[]const u8,
    explicit_csv: ?[]const u8,
) ![]u8 {
    var roots = try resolveRootsFromMap(allocator, environ_map, explicit_skills_path);
    defer roots.deinit(allocator);

    var loaded = try loadAll(allocator, io, .{
        .explicit_root = roots.explicit_root,
        .workspace_root = roots.workspace_root,
        .user_root = roots.user_root,
    });
    defer {
        for (loaded.items) |*s| s.deinit(allocator);
        loaded.deinit(allocator);
    }

    var explicit_list: std.ArrayList([]const u8) = .empty;
    defer explicit_list.deinit(allocator);
    if (explicit_csv) |csv| {
        var it = std.mem.tokenizeScalar(u8, csv, ',');
        while (it.next()) |tok| {
            const trimmed = std.mem.trim(u8, tok, " \t");
            if (trimmed.len > 0) try explicit_list.append(allocator, trimmed);
        }
    }

    var active = try selectActive(allocator, io, loaded.items, roots.workspace_for_glob, explicit_list.items);
    defer active.deinit(allocator);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    if (loaded.items.len == 0) {
        try out.appendSlice(allocator, "No skills loaded.\n\nSearched roots:\n");
        try appendRootLine(&out, allocator, "  --skills   ", roots.explicit_root);
        try appendRootLine(&out, allocator, "  workspace  ", roots.workspace_root);
        try appendRootLine(&out, allocator, "  user       ", roots.user_root);
        try out.appendSlice(allocator, "\nDrop a `*.md` file with YAML frontmatter into one of these roots to add a skill.\n");
        return try out.toOwnedSlice(allocator);
    }

    {
        const hdr = try std.fmt.allocPrint(allocator, "Loaded skills ({d}):\n\n", .{loaded.items.len});
        defer allocator.free(hdr);
        try out.appendSlice(allocator, hdr);
    }

    var active_set = std.AutoHashMap(usize, void).init(allocator);
    defer active_set.deinit();
    for (active.items) |i| try active_set.put(i, {});

    for (loaded.items, 0..) |s, idx| {
        const is_active = active_set.contains(idx);
        try out.appendSlice(allocator, if (is_active) "  [ACTIVE] " else "  [idle]   ");
        try out.appendSlice(allocator, s.meta.name);
        try out.appendSlice(allocator, " — ");
        if (is_active) {
            var by_explicit = false;
            for (explicit_list.items) |e| if (std.mem.eql(u8, e, s.meta.name)) {
                by_explicit = true;
                break;
            };
            if (by_explicit) {
                try out.appendSlice(allocator, "forced via --skill");
            } else {
                try out.appendSlice(allocator, "auto_apply matched workspace");
            }
        } else if (s.meta.auto_apply.len == 0) {
            try out.appendSlice(allocator, "no auto_apply (use --skill NAME)");
        } else {
            try out.appendSlice(allocator, "auto_apply globs didn't match workspace");
        }
        try out.append(allocator, '\n');

        const desc = s.meta.description;
        const eol = std.mem.indexOfScalar(u8, desc, '\n') orelse desc.len;
        try out.appendSlice(allocator, "             ");
        try out.appendSlice(allocator, std.mem.trim(u8, desc[0..eol], " \t"));
        try out.append(allocator, '\n');
    }

    try out.appendSlice(allocator, "\nRoots scanned:\n");
    try appendRootLine(&out, allocator, "  --skills   ", roots.explicit_root);
    try appendRootLine(&out, allocator, "  workspace  ", roots.workspace_root);
    try appendRootLine(&out, allocator, "  user       ", roots.user_root);

    return try out.toOwnedSlice(allocator);
}

fn appendRootLine(out: *std.ArrayList(u8), allocator: std.mem.Allocator, prefix: []const u8, path: ?[]const u8) !void {
    try out.appendSlice(allocator, prefix);
    if (path) |p| {
        try out.appendSlice(allocator, p);
    } else {
        try out.appendSlice(allocator, "(unset)");
    }
    try out.append(allocator, '\n');
}

pub const LoadOptions = struct {
    /// Highest-precedence root. Typically `cfg.skills_path`. May be null.
    explicit_root: ?[]const u8 = null,
    /// `<workspace>/skills/`. May be null when no workspace.
    workspace_root: ?[]const u8 = null,
    /// `$FRANKY_HOME/skills/` or `$HOME/.franky/skills/`. May be null.
    user_root: ?[]const u8 = null,
    /// NEW — standard roots from `.agents/skills/`, `.claude/skills/`, `.cursor/rules/`.
    /// Lower precedence than user_root, higher than builtins.
    standard_roots: []const []const u8 = &.{},
};

/// Walk every configured root, parse each `*.md` (skipping
/// `index.md`), and return a deduplicated list keyed on `name`.
/// Higher-precedence roots shadow lower ones. Malformed files are
/// logged to stderr and skipped — one bad skill shouldn't block the
/// rest. Caller owns the returned slice and must free each Skill.
pub fn loadAll(
    allocator: std.mem.Allocator,
    io: std.Io,
    opts: LoadOptions,
) !std.ArrayList(Skill) {
    var out: std.ArrayList(Skill) = .empty;
    errdefer {
        for (out.items) |*s| s.deinit(allocator);
        out.deinit(allocator);
    }

    // Tracks which `name`s already won — later roots are skipped.
    var seen: std.StringHashMap(void) = .init(allocator);
    defer seen.deinit();

    const roots = [_]?[]const u8{ opts.explicit_root, opts.workspace_root, opts.user_root };
    for (roots) |maybe_root| {
        const root = maybe_root orelse continue;
        loadFromRoot(allocator, io, root, &out, &seen) catch |e| switch (e) {
            error.FileNotFound, error.NotDir => continue,
            else => return e,
        };
    }

    // NEW — iterate standard roots after user root, before builtins.
    for (opts.standard_roots) |root| {
        loadFromRoot(allocator, io, root, &out, &seen) catch |e| switch (e) {
            error.FileNotFound, error.NotDir => continue,
            else => return e,
        };
    }

    // v2.16 — append builtin skills that were not shadowed by a
    // higher-precedence root. The `seen` map already tracks every
    // name that won via the roots loop.
    for (builtins) |b| {
        if (seen.contains(b.name)) continue;
        const skill = parseSkill(allocator, "(builtin)", b.content) catch |err| {
            ai_log.log(.warn, "skills", "builtin.skip", "name={s} err={s}", .{ b.name, @errorName(err) });
            continue;
        };
        try out.append(allocator, skill);
        try seen.put(skill.meta.name, {});
    }

    return out;
}

fn loadFromRoot(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    out: *std.ArrayList(Skill),
    seen: *std.StringHashMap(void),
) !void {
    const cwd = std.Io.Dir.cwd();
    var dir = try cwd.openDir(io, root, .{ .iterate = true });
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
        if (std.mem.eql(u8, entry.name, reserved_index_filename)) continue;

        const path = try std.fs.path.join(allocator, &.{ root, entry.name });
        defer allocator.free(path);

        var f = dir.openFile(io, entry.name, .{}) catch continue;
        defer f.close(io);
        const len = f.length(io) catch continue;
        if (len == 0) continue;
        const buf = try allocator.alloc(u8, @intCast(len));
        defer allocator.free(buf);
        _ = f.readPositionalAll(io, buf, 0) catch continue;

        var skill = parseSkill(allocator, path, buf) catch |err| {
            ai_log.log(.warn, "skills", "load.skip", "path={s} err={s}", .{ path, @errorName(err) });
            continue;
        };

        if (seen.contains(skill.meta.name)) {
            skill.deinit(allocator);
            continue;
        }
        try seen.put(skill.meta.name, {});
        try out.append(allocator, skill);
    }
}

/// Decide which skills to inject into the system prompt. A skill is
/// active iff its `name` ∈ `explicit_names` OR any `auto_apply` glob
/// matches a file in `workspace_root` (subject to `.gitignore` +
/// `.git/` hard-skip). Returns indices into `skills`.
pub fn selectActive(
    allocator: std.mem.Allocator,
    io: ?std.Io,
    skills: []const Skill,
    workspace_root: ?[]const u8,
    explicit_names: []const []const u8,
) !std.ArrayList(usize) {
    var active: std.ArrayList(usize) = .empty;
    errdefer active.deinit(allocator);

    for (skills, 0..) |s, idx| {
        if (containsName(explicit_names, s.meta.name)) {
            try active.append(allocator, idx);
            continue;
        }
        if (s.meta.auto_apply.len == 0) continue;
        if (workspace_root == null or io == null) continue;
        const matched = workspaceHasMatch(io.?, workspace_root.?, s.meta.auto_apply) catch false;
        if (matched) try active.append(allocator, idx);
    }

    return active;
}

pub const BuiltinSkill = struct {
    name: []const u8,
    content: []const u8,
};

/// Built-in skills shipped with the franky binary. These are embedded
/// via `@embedFile` and loaded as fallbacks when no file with the same
/// name exists in any skill root (explicit → workspace → user).
/// A user placing their own `<root>/multimodel-review.md` overrides
/// the builtin — dedup by name already works in `loadAll`.
///
/// Extend this list when adding new built-in skills.
pub const builtins: []const BuiltinSkill = &.{
    .{
        .name = "multimodel-review",
        .content = @embedFile("skills/multimodel-review.md"),
    },
};

fn containsName(names: []const []const u8, want: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, want)) return true;
    return false;
}

const max_workspace_walk: usize = 5_000;

fn workspaceHasMatch(
    io: std.Io,
    workspace_root: []const u8,
    globs: []const []const u8,
) !bool {
    const cwd = std.Io.Dir.cwd();
    var dir = try cwd.openDir(io, workspace_root, .{ .iterate = true });
    defer dir.close(io);

    // Use a fresh allocator for the walk; the caller's allocator
    // doesn't need to outlive the scan.
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var walker = try dir.walk(arena);
    defer walker.deinit();

    var ignore_stack: ?gitignore.Stack = null;
    defer if (ignore_stack) |*s| s.deinit();
    ignore_stack = gitignore.loadFromTree(arena, io, workspace_root) catch null;

    var visited: usize = 0;
    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        visited += 1;
        if (visited > max_workspace_walk) return false;

        if (std.mem.eql(u8, entry.path, ".git") or std.mem.startsWith(u8, entry.path, ".git/")) continue;
        if (ignore_stack) |*s| if (s.isIgnored(entry.path, false)) continue;

        for (globs) |g| {
            if (find_mod.globMatch(g, entry.path)) return true;
        }
    }
    return false;
}

/// Render the active skills into a system-prompt section. Empty
/// active set returns an empty slice (caller appends nothing).
/// When the concatenated body exceeds `max_body_bytes`, falls back
/// to descriptions only and logs a warning.
pub fn renderSection(
    allocator: std.mem.Allocator,
    skills: []const Skill,
    active: []const usize,
) ![]u8 {
    if (active.len == 0) return try allocator.alloc(u8, 0);

    var total_body: usize = 0;
    for (active) |i| total_body += skills[i].body.len;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "## Active skills\n\nThe following domain references apply to this workspace.\n");

    if (total_body > max_body_bytes) {
        ai_log.log(.warn, "skills", "render.cap", "total_body={d} max={d} fallback=descriptions_only", .{ total_body, max_body_bytes });
        for (active) |i| {
            const s = skills[i];
            try out.appendSlice(allocator, "\n### ");
            try out.appendSlice(allocator, s.meta.name);
            try out.append(allocator, '\n');
            try out.appendSlice(allocator, s.meta.description);
            try out.append(allocator, '\n');
        }
        return try out.toOwnedSlice(allocator);
    }

    for (active) |i| {
        const s = skills[i];
        try out.appendSlice(allocator, "\n---\n\n### ");
        try out.appendSlice(allocator, s.meta.name);
        try out.append(allocator, '\n');
        const trimmed = std.mem.trimEnd(u8, s.body, &std.ascii.whitespace);
        try out.appendSlice(allocator, trimmed);
        try out.append(allocator, '\n');
    }
    return try out.toOwnedSlice(allocator);
}

// ─── tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "parseSkill: minimal frontmatter + body" {
    const t = testing;
    const src =
        \\---
        \\name: tiny
        \\description: a one-line skill
        \\---
        \\body content here
        \\
    ;
    var skill = try parseSkill(t.allocator, "/tmp/tiny.md", src);
    defer skill.deinit(t.allocator);
    try t.expectEqualStrings("tiny", skill.meta.name);
    try t.expectEqualStrings("a one-line skill", skill.meta.description);
    try t.expectEqual(@as(usize, 0), skill.meta.auto_apply.len);
    try t.expect(std.mem.indexOf(u8, skill.body, "body content here") != null);
}

test "parseSkill: multi-line description (| literal block) + auto_apply array" {
    const t = testing;
    const src =
        \\---
        \\name: zig
        \\description: |
        \\  Idioms for Zig 0.17-dev.
        \\  TRIGGER when: editing .zig files.
        \\auto_apply: ["**/*.zig", "build.zig"]
        \\---
        \\body
    ;
    var skill = try parseSkill(t.allocator, "/tmp/zig.md", src);
    defer skill.deinit(t.allocator);
    try t.expectEqualStrings("zig", skill.meta.name);
    try t.expect(std.mem.indexOf(u8, skill.meta.description, "Idioms for Zig") != null);
    try t.expect(std.mem.indexOf(u8, skill.meta.description, "TRIGGER when") != null);
    try t.expectEqual(@as(usize, 2), skill.meta.auto_apply.len);
    try t.expectEqualStrings("**/*.zig", skill.meta.auto_apply[0]);
    try t.expectEqualStrings("build.zig", skill.meta.auto_apply[1]);
}

test "parseSkill: missing frontmatter → MissingFrontmatter" {
    const t = testing;
    try t.expectError(ParseError.MissingFrontmatter, parseSkill(t.allocator, "/x", "no frontmatter\n"));
}

test "parseSkill: unclosed frontmatter → UnclosedFrontmatter" {
    const t = testing;
    try t.expectError(ParseError.UnclosedFrontmatter, parseSkill(t.allocator, "/x", "---\nname: foo\ndescription: bar\n"));
}

test "parseSkill: missing required key → MissingDescription" {
    const t = testing;
    const src =
        \\---
        \\name: lonely
        \\---
        \\body
    ;
    try t.expectError(ParseError.MissingDescription, parseSkill(t.allocator, "/x", src));
}

test "selectActive: explicit name forces inclusion" {
    const t = testing;
    var s1 = try parseSkill(t.allocator, "/a.md",
        \\---
        \\name: a
        \\description: skill a
        \\---
    );
    defer s1.deinit(t.allocator);
    var s2 = try parseSkill(t.allocator, "/b.md",
        \\---
        \\name: b
        \\description: skill b
        \\---
    );
    defer s2.deinit(t.allocator);

    const skills = [_]Skill{ s1, s2 };
    const explicit = [_][]const u8{"b"};
    var active = try selectActive(t.allocator, null, &skills, null, &explicit);
    defer active.deinit(t.allocator);
    try t.expectEqual(@as(usize, 1), active.items.len);
    try t.expectEqual(@as(usize, 1), active.items[0]);
}

test "selectActive: skill without auto_apply and without explicit pick stays inactive" {
    const t = testing;
    var s = try parseSkill(t.allocator, "/a.md",
        \\---
        \\name: a
        \\description: skill a
        \\---
    );
    defer s.deinit(t.allocator);
    const skills = [_]Skill{s};
    const explicit: []const []const u8 = &.{};
    var active = try selectActive(t.allocator, null, &skills, "/tmp", explicit);
    defer active.deinit(t.allocator);
    try t.expectEqual(@as(usize, 0), active.items.len);
}

test "renderSection: empty active set returns empty slice" {
    const t = testing;
    const skills: []const Skill = &.{};
    const active: []const usize = &.{};
    const out = try renderSection(t.allocator, skills, active);
    defer t.allocator.free(out);
    try t.expectEqual(@as(usize, 0), out.len);
}

test "renderSection: appends body verbatim under named header" {
    const t = testing;
    var s = try parseSkill(t.allocator, "/a.md",
        \\---
        \\name: alpha
        \\description: d
        \\---
        \\HELLO BODY
        \\
    );
    defer s.deinit(t.allocator);
    const skills = [_]Skill{s};
    const active = [_]usize{0};
    const out = try renderSection(t.allocator, &skills, &active);
    defer t.allocator.free(out);
    try t.expect(std.mem.indexOf(u8, out, "## Active skills") != null);
    try t.expect(std.mem.indexOf(u8, out, "### alpha") != null);
    try t.expect(std.mem.indexOf(u8, out, "HELLO BODY") != null);
}

test "loadAll: scans roots, skips index.md, dedup by name across roots" {
    const t = testing;
    var threaded = std.Io.Threaded.init(t.allocator, .{ .argv0 = .empty, .environ = .empty });
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root_path = try std.fmt.allocPrint(t.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer t.allocator.free(root_path);

    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, root_path) catch {};

    // Write a real skill, an index.md (must be skipped), and a malformed file.
    {
        var path_buf: [256]u8 = undefined;
        const real_path = try std.fmt.bufPrint(&path_buf, "{s}/zig.md", .{root_path});
        var f = try cwd.createFile(io, real_path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io,
            \\---
            \\name: zig
            \\description: zig idioms
            \\---
            \\BODY
        );
    }
    {
        var path_buf: [256]u8 = undefined;
        const idx_path = try std.fmt.bufPrint(&path_buf, "{s}/index.md", .{root_path});
        var f = try cwd.createFile(io, idx_path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "should be ignored");
    }
    {
        var path_buf: [256]u8 = undefined;
        const bad_path = try std.fmt.bufPrint(&path_buf, "{s}/broken.md", .{root_path});
        var f = try cwd.createFile(io, bad_path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "not even a frontmatter\n");
    }

    var loaded = try loadAll(t.allocator, io, .{ .explicit_root = root_path });
    defer {
        for (loaded.items) |*s| s.deinit(t.allocator);
        loaded.deinit(t.allocator);
    }
    try t.expectEqual(@as(usize, 2), loaded.items.len);
    try t.expectEqualStrings("zig", loaded.items[0].meta.name);
    // v2.16 — the builtin multimodel-review skill is appended when no
    // user-supplied skill shadows it.
    try t.expectEqualStrings("multimodel-review", loaded.items[1].meta.name);
}
