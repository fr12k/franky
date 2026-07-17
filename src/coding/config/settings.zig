//! settings.json loader — §5.7 + §H.2.
//!
//! Layered config merged top-down:
//!
//!   1. CLI flags (applied by the caller after `loadLayered` returns)
//!   2. Project: `<project_dir>/.franky/settings.json`
//!   3. User:    `<home_dir>/.franky/settings.json`
//!   4. Built-in defaults (`default_settings` below)
//!
//! Missing files at any layer are silent — the layer contributes
//! nothing and lower layers shine through. Malformed JSON at a layer
//! surfaces as an explicit `SettingsError.MalformedJson` so the
//! caller can warn and fall back to defaults.
//!
//! Scope note (v0.7.0): this module ships the struct + loader +
//! tests. Wiring into `print.run`'s `Config` resolution is a small
//! follow-up that replaces today's hardcoded defaults
//! (`default_anthropic_model`, etc.) with `settings.defaultModels`
//! lookups.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

/// Local-checkout fallback settings embedded into the binary by build.zig. This
/// is primarily useful when Franky is copied into an isolated benchmark/container
/// runtime where `$FRANKY_HOME/settings.json` and `$HOME/.franky/settings.json`
/// are not present. Real on-disk project/user settings still take precedence.
const embedded_settings_json = build_options.embedded_settings_json;

pub const SettingsError = error{
    MalformedJson,
} || std.mem.Allocator.Error;

pub const KeybindingPreset = enum { vi, emacs };

pub const Settings = struct {
    /// Every string field is allocated on this allocator. Free them
    /// all via `deinit`.
    allocator: std.mem.Allocator,

    default_provider: []const u8,
    default_model_anthropic: []const u8,
    default_model_openai: []const u8,
    thinking: []const u8,
    auto_compact: bool,
    keybindings: KeybindingPreset,
    theme: []const u8,

    // v1.19.0 — settings-layer overlay (§4.5 + §4.10 + §4.12).
    //
    // All `?T` fields use `null` to mean "no setting present at any
    // layer; built-in default applies." A non-null value carries the
    // last-write-wins resolution across user → project layers.
    //
    // Arrays are owned ([]const u8 slices duped onto `allocator`) and
    // concatenate across layers (project items appended after user
    // items; consumers treat them as set-semantic so order is moot).

    /// `tools.bash.timeoutMs` — settings-layer default for bash
    /// per-call timeout. Per-call `timeoutMs` arg still wins.
    bash_timeout_ms: ?u64 = null,
    /// `tools.read.maxBytes` — settings-layer default for read
    /// without-explicit-limit cap. Per-call `limit` arg still wins.
    read_max_bytes: ?usize = null,

    /// v3.0 — `tools.maxFullToolResults` — settings-layer default for
    /// the number of most-recent tool results to keep with full content.
    /// Older tool results are replaced with a compact placeholder
    /// ("[tool result: <id> — <size> (offloaded)]") before sending to
    /// the LLM. 0 (default) disables offloading — send everything.
    max_full_tool_results: ?u32 = null,

    /// v3.0 — `tools.compress.enabled` — settings-layer default for
    /// content-aware tool output compression.
    compress_enabled: ?bool = null,
    /// `tools.compress.minBytes` — minimum output size to trigger compression.
    compress_min_bytes: ?usize = null,
    /// `tools.compress.ccr` — enable Compress-Cache-Retrieve.
    compress_ccr: ?bool = null,
    /// `tools.compress.json` — enable JSON array compression.
    compress_json: ?bool = null,
    /// `tools.compress.logs` — enable log output compression.
    compress_logs: ?bool = null,
    /// `tools.compress.search` — enable search result compression.
    compress_search: ?bool = null,
    /// `tools.compress.diff` — enable diff compression.
    compress_diff: ?bool = null,
    /// `tools.compress.code` — enable source code compression.
    compress_code: ?bool = null,
    /// `tools.compress.plainText` — enable plain text compression for bash output, file contents, etc.
    compress_plain_text: ?bool = null,

    /// `permissions.ask_all` — settings-layer default for the
    /// "ask before every tool call" toggle. CLI `--ask-tools all`
    /// still wins.
    permissions_ask_all: ?bool = null,
    /// `permissions.yes_to_all` — settings-layer default for the
    /// "auto-allow every prompt" CI toggle. CLI `--yes` / `-y`
    /// still wins.
    permissions_yes_to_all: ?bool = null,
    /// `permissions.always_allow.tools` — pre-seeded into the
    /// permission `Store` at session init.
    permissions_always_allow_tools: [][]const u8 = &.{},
    /// `permissions.always_allow.bash` — bash fingerprints (verb
    /// level, e.g. `git`, `ls`) pre-seeded into the `Store`.
    permissions_always_allow_bash: [][]const u8 = &.{},
    /// `permissions.always_deny.tools` — pre-seeded into the
    /// `Store`. Deny beats allow per the v1.11.0 precedence.
    permissions_always_deny_tools: [][]const u8 = &.{},
    /// `permissions.always_deny.bash` — pre-seeded into the
    /// `Store`. Deny beats allow.
    permissions_always_deny_bash: [][]const u8 = &.{},

    /// `prompts: bool` — settings-layer toggle for the per-tool
    /// permission overlay (§5.11). CLI `--prompts` still wins.
    prompts_default: ?bool = null,

    /// `max_turns: int` — settings-layer cap on agent-loop turn count
    /// per prompt. Precedence: CLI `--max-turns` > env `FRANKY_MAX_TURNS`
    /// > profile `max_turns` > settings `max_turns` > built-in default 100.
    max_turns: ?u32 = null,

    /// v2.13 — retry policy overrides. Parsed from `tools.retry.*`.
    /// CLI flags `--retry-max-attempts` / `--retry-max-total-ms` still win.
    retry_max_attempts: ?u32 = null,
    retry_max_total_ms: ?u64 = null,

    /// v2.16 — multi-model code review settings.
    /// `review.profiles` — ordered list of profile names for multi-model review.
    /// Concatenated across user → project layers. Empty = auto-discovery at runtime.
    review_profiles: [][]const u8 = &.{},
    /// `review.minModels` — abort if fewer than this many models respond. Default 2.
    review_min_models: u32 = 2,
    /// `review.maxModels` — cap on concurrent subagents even if more profiles are listed. Default 4.
    review_max_models: u32 = 4,
    /// `review.timeoutMs` — per-subagent wall-clock timeout in ms. Default 180 000 (3 min).
    review_timeout_ms: u64 = 180_000,

    pub fn deinit(self: *Settings) void {
        self.allocator.free(self.default_provider);
        self.allocator.free(self.default_model_anthropic);
        self.allocator.free(self.default_model_openai);
        self.allocator.free(self.thinking);
        self.allocator.free(self.theme);
        deinitStringArray(self.allocator, self.permissions_always_allow_tools);
        deinitStringArray(self.allocator, self.permissions_always_allow_bash);
        deinitStringArray(self.allocator, self.permissions_always_deny_tools);
        deinitStringArray(self.allocator, self.permissions_always_deny_bash);
        deinitStringArray(self.allocator, self.review_profiles);
        self.* = undefined;
    }
};

fn deinitStringArray(alloc: std.mem.Allocator, arr: [][]const u8) void {
    for (arr) |s| alloc.free(s);
    if (arr.len > 0) alloc.free(arr);
}

/// Append all string entries from `src` (duped onto `alloc`) to the
/// slice pointed at by `target`. Reallocates the slice. Non-string
/// entries are silently skipped — settings.json is permissive at the
/// edges (matches every other field's parsing here).
fn appendStringArray(
    alloc: std.mem.Allocator,
    target: *[][]const u8,
    src: std.json.Array,
) !void {
    var n_strings: usize = 0;
    for (src.items) |item| if (item == .string) {
        n_strings += 1;
    };
    if (n_strings == 0) return;
    const old = target.*;
    const combined = try alloc.alloc([]const u8, old.len + n_strings);
    @memcpy(combined[0..old.len], old);
    var i: usize = old.len;
    for (src.items) |item| if (item == .string) {
        combined[i] = try alloc.dupe(u8, item.string);
        i += 1;
    };
    if (old.len > 0) alloc.free(old);
    target.* = combined;
}

pub const default_provider: []const u8 = "anthropic";
pub const default_model_anthropic: []const u8 = "claude-sonnet-4-6";
pub const default_model_openai: []const u8 = "gpt-5";
pub const default_thinking: []const u8 = "off";
pub const default_auto_compact: bool = true;
pub const default_keybindings: KeybindingPreset = .emacs;
pub const default_theme: []const u8 = "default";

/// Built-in defaults. Every layer can override any subset; missing
/// fields fall through.
pub fn defaults(allocator: std.mem.Allocator) !Settings {
    return .{
        .allocator = allocator,
        .default_provider = try allocator.dupe(u8, default_provider),
        .default_model_anthropic = try allocator.dupe(u8, default_model_anthropic),
        .default_model_openai = try allocator.dupe(u8, default_model_openai),
        .thinking = try allocator.dupe(u8, default_thinking),
        .auto_compact = default_auto_compact,
        .keybindings = default_keybindings,
        .theme = try allocator.dupe(u8, default_theme),
    };
}

/// Read + merge: user → project layered on top of defaults. Each
/// layer is optional; a missing file is not an error.
pub fn loadLayered(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_dir: ?[]const u8,
    home_dir: ?[]const u8,
) !Settings {
    var settings = try defaults(allocator);
    errdefer settings.deinit();

    var loaded_any_layer = false;

    if (home_dir) |hd| {
        const path = try std.fs.path.join(allocator, &.{ hd, ".franky", "settings.json" });
        defer allocator.free(path);
        loaded_any_layer = (try applyLayer(&settings, io, path)) or loaded_any_layer;
    }
    if (project_dir) |pd| {
        const path = try std.fs.path.join(allocator, &.{ pd, ".franky", "settings.json" });
        defer allocator.free(path);
        loaded_any_layer = (try applyLayer(&settings, io, path)) or loaded_any_layer;
    }

    // If no settings layer is readable, fall back to the settings.json that was
    // present in the checkout at compile time. Tests keep the old pure-defaults
    // behavior so existing fixture expectations remain local and deterministic.
    if (!loaded_any_layer and !builtin.is_test) {
        try applyLayerBytes(&settings, embedded_settings_json);
    }
    return settings;
}

fn applyTopLevelFields(settings: *Settings, obj: std.json.ObjectMap) !void {
    const alloc = settings.allocator;
    if (obj.get("defaultProvider")) |v| if (v == .string) {
        alloc.free(settings.default_provider);
        settings.default_provider = try alloc.dupe(u8, v.string);
    };
    if (obj.get("defaultModels")) |v| if (v == .object) {
        if (v.object.get("anthropic")) |a| if (a == .string) {
            alloc.free(settings.default_model_anthropic);
            settings.default_model_anthropic = try alloc.dupe(u8, a.string);
        };
        if (v.object.get("openai")) |o| if (o == .string) {
            alloc.free(settings.default_model_openai);
            settings.default_model_openai = try alloc.dupe(u8, o.string);
        };
    };
    if (obj.get("thinking")) |v| if (v == .string) {
        alloc.free(settings.thinking);
        settings.thinking = try alloc.dupe(u8, v.string);
    };
    if (obj.get("autoCompact")) |v| if (v == .bool) {
        settings.auto_compact = v.bool;
    };
    if (obj.get("keybindings")) |v| if (v == .string) {
        if (std.mem.eql(u8, v.string, "vi")) settings.keybindings = .vi;
        if (std.mem.eql(u8, v.string, "emacs")) settings.keybindings = .emacs;
    };
    if (obj.get("theme")) |v| if (v == .string) {
        alloc.free(settings.theme);
        settings.theme = try alloc.dupe(u8, v.string);
    };
}

fn applyToolsSection(settings: *Settings, obj: std.json.ObjectMap) !void {
    if (obj.get("tools")) |tools_v| if (tools_v == .object) {
        if (tools_v.object.get("bash")) |bash_v| if (bash_v == .object) {
            if (bash_v.object.get("timeoutMs")) |t| if (t == .integer and t.integer >= 1) {
                settings.bash_timeout_ms = @intCast(t.integer);
            };
        };
        if (tools_v.object.get("read")) |read_v| if (read_v == .object) {
            if (read_v.object.get("maxBytes")) |m| if (m == .integer and m.integer >= 1) {
                settings.read_max_bytes = @intCast(m.integer);
            };
        };
        if (tools_v.object.get("maxFullToolResults")) |v| if (v == .integer and v.integer >= 0 and v.integer <= std.math.maxInt(u32)) {
            settings.max_full_tool_results = @intCast(v.integer);
        };
        if (tools_v.object.get("retry")) |retry_v| if (retry_v == .object) {
            if (retry_v.object.get("maxAttempts")) |rv| if (rv == .integer and rv.integer >= 0 and rv.integer <= std.math.maxInt(u32)) {
                settings.retry_max_attempts = @intCast(rv.integer);
            };
            if (retry_v.object.get("maxTotalMs")) |t| if (t == .integer and t.integer >= 0) {
                settings.retry_max_total_ms = @intCast(t.integer);
            };
        };
        if (tools_v.object.get("compress")) |compress_v| if (compress_v == .object) {
            if (compress_v.object.get("enabled")) |v| if (v == .bool) {
                settings.compress_enabled = v.bool;
            };
            if (compress_v.object.get("minBytes")) |v| if (v == .integer and v.integer >= 1) {
                settings.compress_min_bytes = @intCast(v.integer);
            };
            if (compress_v.object.get("ccr")) |v| if (v == .bool) {
                settings.compress_ccr = v.bool;
            };
            if (compress_v.object.get("json")) |v| if (v == .bool) {
                settings.compress_json = v.bool;
            };
            if (compress_v.object.get("logs")) |v| if (v == .bool) {
                settings.compress_logs = v.bool;
            };
            if (compress_v.object.get("search")) |v| if (v == .bool) {
                settings.compress_search = v.bool;
            };
            if (compress_v.object.get("diff")) |v| if (v == .bool) {
                settings.compress_diff = v.bool;
            };
            if (compress_v.object.get("code")) |v| if (v == .bool) {
                settings.compress_code = v.bool;
            };
            if (compress_v.object.get("plainText")) |v| if (v == .bool) {
                settings.compress_plain_text = v.bool;
            };
        };
    };
}

fn applyPermissionsSection(settings: *Settings, obj: std.json.ObjectMap) !void {
    const alloc = settings.allocator;
    if (obj.get("permissions")) |perms_v| if (perms_v == .object) {
        if (perms_v.object.get("ask_all")) |b| if (b == .bool) {
            settings.permissions_ask_all = b.bool;
        };
        if (perms_v.object.get("yes_to_all")) |b| if (b == .bool) {
            settings.permissions_yes_to_all = b.bool;
        };
        if (perms_v.object.get("always_allow")) |aa| if (aa == .object) {
            if (aa.object.get("tools")) |arr| if (arr == .array) {
                try appendStringArray(alloc, &settings.permissions_always_allow_tools, arr.array);
            };
            if (aa.object.get("bash")) |arr| if (arr == .array) {
                try appendStringArray(alloc, &settings.permissions_always_allow_bash, arr.array);
            };
        };
        if (perms_v.object.get("always_deny")) |ad| if (ad == .object) {
            if (ad.object.get("tools")) |arr| if (arr == .array) {
                try appendStringArray(alloc, &settings.permissions_always_deny_tools, arr.array);
            };
            if (ad.object.get("bash")) |arr| if (arr == .array) {
                try appendStringArray(alloc, &settings.permissions_always_deny_bash, arr.array);
            };
        };
    };
}

fn applyReviewSection(settings: *Settings, obj: std.json.ObjectMap) !void {
    const alloc = settings.allocator;
    if (obj.get("review")) |rev_v| if (rev_v == .object) {
        if (rev_v.object.get("profiles")) |p| if (p == .array) {
            try appendStringArray(alloc, &settings.review_profiles, p.array);
        };
        if (rev_v.object.get("minModels")) |m| if (m == .integer and m.integer >= 1) {
            settings.review_min_models = @intCast(m.integer);
        };
        if (rev_v.object.get("maxModels")) |m| if (m == .integer and m.integer >= 1) {
            settings.review_max_models = @intCast(m.integer);
        };
        if (rev_v.object.get("timeoutMs")) |t| if (t == .integer and t.integer >= 1) {
            settings.review_timeout_ms = @intCast(t.integer);
        };
        // v2.16 — validate that minModels <= maxModels; clamp if not.
        if (settings.review_min_models > settings.review_max_models) {
            settings.review_min_models = settings.review_max_models;
        }
    };
}

fn applyLayer(settings: *Settings, io: std.Io, path: []const u8) !bool {
    const alloc = settings.allocator;
    // Scratch arena for the file read only; JSON parsing has its own scratch in
    // applyLayerBytes.
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const sa = scratch.allocator();

    var f = std.Io.Dir.cwd().openFile(io, path, .{}) catch |e| switch (e) {
        error.FileNotFound => return false,
        else => return false,
    };
    defer f.close(io);
    const len = f.length(io) catch return false;
    const buf = sa.alloc(u8, @intCast(len)) catch return false;
    const n = f.readPositionalAll(io, buf, 0) catch return false;

    try applyLayerBytes(settings, buf[0..n]);
    return true;
}

fn applyLayerBytes(settings: *Settings, bytes: []const u8) !void {
    const alloc = settings.allocator;
    // Scratch arena for the JSON parse only; applied values are duped onto the
    // Settings allocator before this function returns.
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const sa = scratch.allocator();

    const parsed = std.json.parseFromSlice(std.json.Value, sa, bytes, .{}) catch return SettingsError.MalformedJson;
    if (parsed.value != .object) return SettingsError.MalformedJson;
    const obj = parsed.value.object;

    try applyTopLevelFields(settings, obj);
    try applyToolsSection(settings, obj);
    try applyPermissionsSection(settings, obj);

    if (obj.get("prompts")) |v| if (v == .bool) {
        settings.prompts_default = v.bool;
    };

    if (obj.get("max_turns")) |v| if (v == .integer and v.integer >= 1 and v.integer <= std.math.maxInt(u32)) {
        settings.max_turns = @intCast(v.integer);
    };

    try applyReviewSection(settings, obj);
}

// ─── tests ────────────────────────────────────────────────────────

const testing = std.testing;
const test_h = @import("../../test_helpers.zig");

test "defaults: sensible baselines per §H.2" {
    var s = try defaults(testing.allocator);
    defer s.deinit();
    try testing.expectEqualStrings("anthropic", s.default_provider);
    try testing.expectEqualStrings("claude-sonnet-4-6", s.default_model_anthropic);
    try testing.expect(s.auto_compact);
    try testing.expectEqual(KeybindingPreset.emacs, s.keybindings);
}

test "loadLayered: both dirs missing → defaults" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    var s = try loadLayered(testing.allocator, io, "/tmp/franky_nosuch_proj", "/tmp/franky_nosuch_home");
    defer s.deinit();
    try testing.expectEqualStrings("anthropic", s.default_provider);
}

test "loadLayered: project layer overrides defaults" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_settings_proj";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, base ++ "/.franky");
    const path = base ++ "/.franky/settings.json";
    {
        var f = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io,
            \\{"defaultProvider":"openai","thinking":"high","autoCompact":false,"keybindings":"vi"}
        );
    }

    var s = try loadLayered(gpa, io, base, "/tmp/franky_nosuch_home");
    defer s.deinit();
    try testing.expectEqualStrings("openai", s.default_provider);
    try testing.expectEqualStrings("high", s.thinking);
    try testing.expect(!s.auto_compact);
    try testing.expectEqual(KeybindingPreset.vi, s.keybindings);
}

test "loadLayered: project beats user (CLI sits on top in caller)" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const user_base = "/tmp/franky_settings_user";
    _ = std.Io.Dir.cwd().deleteTree(io, user_base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, user_base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, user_base ++ "/.franky");
    {
        var f = try std.Io.Dir.cwd().createFile(io, user_base ++ "/.franky/settings.json", .{});
        defer f.close(io);
        try f.writeStreamingAll(io,
            \\{"defaultProvider":"openai","theme":"dark"}
        );
    }
    const proj_base = "/tmp/franky_settings_proj2";
    _ = std.Io.Dir.cwd().deleteTree(io, proj_base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, proj_base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, proj_base ++ "/.franky");
    {
        var f = try std.Io.Dir.cwd().createFile(io, proj_base ++ "/.franky/settings.json", .{});
        defer f.close(io);
        try f.writeStreamingAll(io,
            \\{"defaultProvider":"anthropic"}
        );
    }

    var s = try loadLayered(gpa, io, proj_base, user_base);
    defer s.deinit();
    // Project's `defaultProvider` wins; user's `theme` shines through.
    try testing.expectEqualStrings("anthropic", s.default_provider);
    try testing.expectEqualStrings("dark", s.theme);
}

test "loadLayered: malformed JSON surfaces MalformedJson" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const base = "/tmp/franky_settings_malformed";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, base ++ "/.franky");
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/.franky/settings.json", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "{ not json ");
    }
    const err = loadLayered(testing.allocator, io, base, null);
    try testing.expectError(SettingsError.MalformedJson, err);
}

test "loadLayered: partial file preserves unspecified defaults" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const base = "/tmp/franky_settings_partial";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, base ++ "/.franky");
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/.franky/settings.json", .{});
        defer f.close(io);
        try f.writeStreamingAll(io,
            \\{"thinking":"medium"}
        );
    }

    var s = try loadLayered(testing.allocator, io, base, null);
    defer s.deinit();
    try testing.expectEqualStrings("medium", s.thinking);
    // Every other field keeps its default.
    try testing.expectEqualStrings("anthropic", s.default_provider);
    try testing.expect(s.auto_compact);
}

// ─── v1.19.0 — settings-layer overlay tests ───────────────────────

test "loadLayered: tools.bash.timeoutMs + tools.read.maxBytes" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const base = "/tmp/franky_settings_tools_overlay";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, base ++ "/.franky");
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/.franky/settings.json", .{});
        defer f.close(io);
        try f.writeStreamingAll(io,
            \\{"tools":{"bash":{"timeoutMs":30000},"read":{"maxBytes":524288}}}
        );
    }

    var s = try loadLayered(testing.allocator, io, base, null);
    defer s.deinit();
    try testing.expectEqual(@as(?u64, 30_000), s.bash_timeout_ms);
    try testing.expectEqual(@as(?usize, 524_288), s.read_max_bytes);
}

test "loadLayered: tools overlay defaults remain null when absent" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    var s = try loadLayered(testing.allocator, io, null, null);
    defer s.deinit();
    try testing.expectEqual(@as(?u64, null), s.bash_timeout_ms);
    try testing.expectEqual(@as(?usize, null), s.read_max_bytes);
    try testing.expectEqual(@as(?bool, null), s.permissions_ask_all);
    try testing.expectEqual(@as(?bool, null), s.permissions_yes_to_all);
    try testing.expectEqual(@as(?bool, null), s.prompts_default);
    try testing.expectEqual(@as(usize, 0), s.permissions_always_allow_tools.len);
    try testing.expectEqual(@as(usize, 0), s.permissions_always_allow_bash.len);
}

test "loadLayered: permissions overlay — scalars + arrays" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const base = "/tmp/franky_settings_perms_overlay";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, base ++ "/.franky");
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/.franky/settings.json", .{});
        defer f.close(io);
        try f.writeStreamingAll(io,
            \\{"permissions":{"ask_all":true,"yes_to_all":false,"always_allow":{"tools":["read","ls"],"bash":["git","ls"]},"always_deny":{"tools":["write"],"bash":["rm"]}}}
        );
    }

    var s = try loadLayered(testing.allocator, io, base, null);
    defer s.deinit();
    try testing.expectEqual(@as(?bool, true), s.permissions_ask_all);
    try testing.expectEqual(@as(?bool, false), s.permissions_yes_to_all);
    try testing.expectEqual(@as(usize, 2), s.permissions_always_allow_tools.len);
    try testing.expectEqualStrings("read", s.permissions_always_allow_tools[0]);
    try testing.expectEqualStrings("ls", s.permissions_always_allow_tools[1]);
    try testing.expectEqual(@as(usize, 2), s.permissions_always_allow_bash.len);
    try testing.expectEqualStrings("git", s.permissions_always_allow_bash[0]);
    try testing.expectEqual(@as(usize, 1), s.permissions_always_deny_tools.len);
    try testing.expectEqualStrings("write", s.permissions_always_deny_tools[0]);
    try testing.expectEqual(@as(usize, 1), s.permissions_always_deny_bash.len);
    try testing.expectEqualStrings("rm", s.permissions_always_deny_bash[0]);
}

test "loadLayered: permissions arrays concatenate user + project" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const user_base = "/tmp/franky_settings_perms_user";
    _ = std.Io.Dir.cwd().deleteTree(io, user_base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, user_base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, user_base ++ "/.franky");
    {
        var f = try std.Io.Dir.cwd().createFile(io, user_base ++ "/.franky/settings.json", .{});
        defer f.close(io);
        try f.writeStreamingAll(io,
            \\{"permissions":{"always_allow":{"tools":["read"]}}}
        );
    }
    const proj_base = "/tmp/franky_settings_perms_proj";
    _ = std.Io.Dir.cwd().deleteTree(io, proj_base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, proj_base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, proj_base ++ "/.franky");
    {
        var f = try std.Io.Dir.cwd().createFile(io, proj_base ++ "/.franky/settings.json", .{});
        defer f.close(io);
        try f.writeStreamingAll(io,
            \\{"permissions":{"always_allow":{"tools":["ls","grep"]}}}
        );
    }

    var s = try loadLayered(gpa, io, proj_base, user_base);
    defer s.deinit();
    // user applied first, project appended after.
    try testing.expectEqual(@as(usize, 3), s.permissions_always_allow_tools.len);
    try testing.expectEqualStrings("read", s.permissions_always_allow_tools[0]);
    try testing.expectEqualStrings("ls", s.permissions_always_allow_tools[1]);
    try testing.expectEqualStrings("grep", s.permissions_always_allow_tools[2]);
}

test "loadLayered: prompts: bool overlay" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const base = "/tmp/franky_settings_prompts_overlay";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, base ++ "/.franky");
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/.franky/settings.json", .{});
        defer f.close(io);
        try f.writeStreamingAll(io,
            \\{"prompts":true}
        );
    }
    var s = try loadLayered(testing.allocator, io, base, null);
    defer s.deinit();
    try testing.expectEqual(@as(?bool, true), s.prompts_default);
}

test "loadLayered: rejects ill-typed overlay fields silently" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const base = "/tmp/franky_settings_overlay_illtype";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, base ++ "/.franky");
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/.franky/settings.json", .{});
        defer f.close(io);
        // timeoutMs as string, maxBytes negative, ask_all as int,
        // always_allow.tools mixed-type — every bad value should be
        // silently dropped, leaving the field at default null/empty.
        try f.writeStreamingAll(io,
            \\{"tools":{"bash":{"timeoutMs":"30s"},"read":{"maxBytes":-1}},"permissions":{"ask_all":1,"always_allow":{"tools":["read",42]}},"prompts":"yes"}
        );
    }
    var s = try loadLayered(testing.allocator, io, base, null);
    defer s.deinit();
    try testing.expectEqual(@as(?u64, null), s.bash_timeout_ms);
    try testing.expectEqual(@as(?usize, null), s.read_max_bytes);
    try testing.expectEqual(@as(?bool, null), s.permissions_ask_all);
    try testing.expectEqual(@as(?bool, null), s.prompts_default);
    // Mixed-type array drops the non-string entry but keeps the
    // valid one; settings.json is permissive at the edges.
    try testing.expectEqual(@as(usize, 1), s.permissions_always_allow_tools.len);
    try testing.expectEqualStrings("read", s.permissions_always_allow_tools[0]);
}

test "loadLayered: review.profiles + scalars parse correctly (A1)" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const base = "/tmp/franky_settings_review_a1";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, base ++ "/.franky");
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/.franky/settings.json", .{});
        defer f.close(io);
        try f.writeStreamingAll(io,
            \\{"review":{"profiles":["mistral-medium-3-5","ollama-deepseek-flash"],"minModels":3,"maxModels":5,"timeoutMs":120000}}
        );
    }
    var s = try loadLayered(testing.allocator, io, base, null);
    defer s.deinit();
    try testing.expectEqual(@as(usize, 2), s.review_profiles.len);
    try testing.expectEqualStrings("mistral-medium-3-5", s.review_profiles[0]);
    try testing.expectEqualStrings("ollama-deepseek-flash", s.review_profiles[1]);
    try testing.expectEqual(@as(u32, 3), s.review_min_models);
    try testing.expectEqual(@as(u32, 5), s.review_max_models);
    try testing.expectEqual(@as(u64, 120_000), s.review_timeout_ms);
}

test "loadLayered: review.profiles concatenate across layers (A2)" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const proj = "/tmp/franky_settings_review_a2_proj";
    const home = "/tmp/franky_settings_review_a2_home";
    _ = std.Io.Dir.cwd().deleteTree(io, proj) catch {};
    _ = std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, proj) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, home) catch {};
    try std.Io.Dir.cwd().createDirPath(io, proj ++ "/.franky");
    try std.Io.Dir.cwd().createDirPath(io, home ++ "/.franky");
    {
        var f = try std.Io.Dir.cwd().createFile(io, proj ++ "/.franky/settings.json", .{});
        defer f.close(io);
        try f.writeStreamingAll(io,
            \\{"review":{"profiles":["mistral-medium-3-5"]}}
        );
    }
    {
        var f = try std.Io.Dir.cwd().createFile(io, home ++ "/.franky/settings.json", .{});
        defer f.close(io);
        try f.writeStreamingAll(io,
            \\{"review":{"profiles":["mistral-medium-3-5","claude-sonnet"]}}
        );
    }
    var s = try loadLayered(testing.allocator, io, proj, home);
    defer s.deinit();
    // Both layers contribute; order is user-layer first, project-layer second.
    try testing.expectEqual(@as(usize, 3), s.review_profiles.len);
}
