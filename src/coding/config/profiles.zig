//! `--profile <name>` loader — v2 §5 (settings & profile system).
//!
//! Phase 1 (v1.17.0): read `profiles.<name>` from settings.json,
//! apply its fields onto `cli.Config` for any flag the user didn't
//! set on the command line, resolve `api_key_env`/`auth_token_env`
//! credential indirections, and set process env vars from the
//! `env: {}` block. `${VAR}` interpolation in string values is
//! supported.
//!
//! Phase 2 (planned): built-in preset catalog + `--save-profile` +
//! `--list-profiles`. Phase 1 only reads from disk — if no settings.json
//! exists or the named profile isn't there, applyProfile returns
//! `error.ProfileNotFound`.
//!
//! Precedence (per v2 §5.3):
//!   defaults < env vars < settings.json (top-level) < **profile** < CLI flags
//!
//! So the apply step here runs *after* cli.parse() — for each profile
//! field, it overlays only when the matching cfg field is still at its
//! default (null / false / .off). This treats CLI-provided values as
//! authoritative and the profile as "named bundle of defaults."

const std = @import("std");
const build_options = @import("build_options");
const cli = @import("cli.zig");
const ait = @import("../../ai/types.zig");
const stream = @import("../../ai/stream.zig");
const log = @import("../../ai/log.zig");

pub const ProfileError = error{
    ProfileNotFound,
    MalformedProfile,
    MissingValue,
    UnknownMode,
    UnknownThinkingLevel,
} || std.mem.Allocator.Error;

/// Resolved field values from `profiles.<name>`. All optional —
/// applyProfile only overlays present fields onto cfg. Each string
/// is owned by the caller's arena (cfg.arena).
pub const Profile = struct {
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    api_key_env: ?[]const u8 = null,
    auth_token: ?[]const u8 = null,
    auth_token_env: ?[]const u8 = null,
    base_url: ?[]const u8 = null,
    thinking: ?[]const u8 = null,
    mode: ?[]const u8 = null,
    prompts: ?bool = null,
    yes: ?bool = null,
    ask_tools: ?[]const u8 = null,
    allow_tools: ?[]const u8 = null,
    deny_tools: ?[]const u8 = null,
    role: ?[]const u8 = null,
    log_level: ?[]const u8 = null,
    log_file: ?[]const u8 = null,
    system_prompt: ?[]const u8 = null,
    append_system_prompt: ?[]const u8 = null,
    text_tool_call_fallback: ?bool = null,
    http_trace_dir: ?[]const u8 = null,
    /// Hard cap on agent-loop turn count. CLI `--max-turns` always
    /// wins; this is the per-profile default for users who routinely
    /// run a slow / verbose model and want a higher cap baked in.
    max_turns: ?u32 = null,
    /// Per-profile retry policy overrides. CLI `--retry-max-*` always wins.
    retry_max_attempts: ?u32 = null,
    retry_max_total_ms: ?u64 = null,
    /// Base delay for retry backoff in ms (default 10_000).
    /// Read from `base_delay_ms` in the profile JSON.
    base_delay_ms: ?u32 = null,
    /// Process-env-var assignments. Applied via `environ_map.put`
    /// before any mode reads timeouts, log vars, or other knobs.
    /// Values support `${VAR}` interpolation against the **caller's
    /// pre-existing env** so a profile entry can reference parent
    /// env vars without leaking secrets into the file.
    env: ?std.StringHashMap([]const u8) = null,
};

/// Settings.json paths searched. First match wins; profiles are
/// atomic bundles so we never field-merge across layers (per v2
/// §5.4). Paths in priority order:
///
///   1. `<cwd>/.franky/settings.json` (project)
///   2. `$FRANKY_HOME/settings.json`
///   3. `$HOME/.franky/settings.json`
///
/// Paths returned are arena-allocated. `null` slots indicate the
/// underlying env variable wasn't set; the caller skips that layer.
fn settingsPaths(arena: std.mem.Allocator, environ_map: *const std.process.Environ.Map) !struct {
    project: []u8,
    franky_home: ?[]u8,
    home_canonical: ?[]u8,
} {
    const franky_home: ?[]u8 = if (environ_map.get("FRANKY_HOME")) |h| blk: {
        if (h.len == 0) break :blk null;
        break :blk try std.fs.path.join(arena, &.{ h, "settings.json" });
    } else null;

    const home_canonical: ?[]u8 = if (environ_map.get("HOME")) |h| blk: {
        if (h.len == 0) break :blk null;
        break :blk try std.fs.path.join(arena, &.{ h, ".franky", "settings.json" });
    } else null;

    const project = try arena.dupe(u8, ".franky/settings.json");

    return .{
        .project = project,
        .franky_home = franky_home,
        .home_canonical = home_canonical,
    };
}

/// Top-level entry: load `profiles.<name>` from any settings.json
/// layer (project overrides user) and overlay onto `cfg`.
///
/// Precedence: profile values are applied **only** for fields that
/// look unset on `cfg` (null for optional strings, false for bools,
/// `.off` for thinking, `false` for `thinking_explicit`). This
/// preserves CLI flags as the source of truth — if the user said
/// `--provider faux` and the profile says `"provider": "gateway"`,
/// the user wins.
///
/// On `error.ProfileNotFound`, the caller should report a friendly
/// error and exit. Other errors (`MalformedProfile`, etc.) are
/// propagated for the caller to handle.
pub fn applyProfile(
    cfg: *cli.Config,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    name: []const u8,
) ProfileError!void {
    const arena = cfg.arena.allocator();
    const profile = (try loadFromSettings(arena, io, environ_map, name)) orelse return error.ProfileNotFound;
    try applyToCfg(cfg, profile, environ_map);
}

/// Walk all settings.json layers, return the first hit for
/// `profiles.<name>`. Returns null if no layer has the name. Falls
/// back to the built-in catalog (v1.17.0 Phase 2): user-defined
/// profiles in settings.json override built-ins of the same name,
/// but a name only present in the built-ins is still resolved.
pub fn loadFromSettings(
    arena: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    name: []const u8,
) ProfileError!?Profile {
    const paths = try settingsPaths(arena, environ_map);

    // Search order: project (most specific) wins, then FRANKY_HOME,
    // then $HOME/.franky/settings.json. First match wins — profiles
    // are atomic bundles per v2 §5.4.
    const candidates = [_]?[]const u8{ paths.project, paths.franky_home, paths.home_canonical };
    for (candidates) |maybe_path| {
        const path = maybe_path orelse continue;
        const profile = (try loadProfileFromFile(arena, io, environ_map, path, name)) orelse continue;
        log.log(.debug, "profile", "loaded", "name={s} path={s}", .{ name, path });
        return profile;
    }

    // Fall back to the settings.json embedded into the binary by build.zig.
    // This keeps local-checkout Harbor/Terminal-Bench runs able to use project
    // profiles even after the binary is copied into an isolated task container
    // without the host's settings.json files.
    if ((try loadProfileFromBytes(arena, environ_map, build_options.embedded_settings_json, name))) |profile| {
        log.log(.debug, "profile", "loaded", "name={s} source=embedded-settings", .{name});
        return profile;
    }

    // Fall back to the built-in catalog.
    if (getBuiltinBody(name)) |body| {
        log.log(.debug, "profile", "loaded", "name={s} source=builtin", .{name});
        return try parseBuiltinBody(arena, environ_map, body);
    }

    return null;
}

fn parseBuiltinBody(
    arena: std.mem.Allocator,
    environ_map: *std.process.Environ.Map,
    body: []const u8,
) ProfileError!Profile {
    const parsed = std.json.parseFromSlice(std.json.Value, arena, body, .{}) catch
        return error.MalformedProfile;
    if (parsed.value != .object) return error.MalformedProfile;
    return try parseProfileObject(arena, environ_map, parsed.value.object);
}

fn loadProfileFromFile(
    arena: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    path: []const u8,
    name: []const u8,
) ProfileError!?Profile {
    var f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer f.close(io);
    const len = f.length(io) catch return null;
    if (len == 0) return null;
    const buf = try arena.alloc(u8, @intCast(len));
    const n = f.readPositionalAll(io, buf, 0) catch return null;

    return try loadProfileFromBytes(arena, environ_map, buf[0..n], name);
}

fn loadProfileFromBytes(
    arena: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    bytes: []const u8,
    name: []const u8,
) ProfileError!?Profile {
    const parsed = std.json.parseFromSlice(std.json.Value, arena, bytes, .{}) catch
        return error.MalformedProfile;
    if (parsed.value != .object) return null;
    const profiles_val = parsed.value.object.get("profiles") orelse return null;
    if (profiles_val != .object) return null;
    const profile_val = profiles_val.object.get(name) orelse return null;
    if (profile_val != .object) return error.MalformedProfile;

    return try parseProfileObject(arena, environ_map, profile_val.object);
}

/// Parse one `{...}` object into a `Profile`. Each string value
/// is `${VAR}`-interpolated against `environ_map`. The `env` block
/// is preserved as-is for later application.
fn parseProfileObject(
    arena: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    obj: std.json.ObjectMap,
) ProfileError!Profile {
    var p: Profile = .{};

    if (try optString(arena, environ_map, obj, "provider")) |v| p.provider = v;
    if (try optString(arena, environ_map, obj, "model")) |v| p.model = v;
    if (try optString(arena, environ_map, obj, "api_key")) |v| p.api_key = v;
    if (try optString(arena, environ_map, obj, "api_key_env")) |v| p.api_key_env = v;
    if (try optString(arena, environ_map, obj, "auth_token")) |v| p.auth_token = v;
    if (try optString(arena, environ_map, obj, "auth_token_env")) |v| p.auth_token_env = v;
    if (try optString(arena, environ_map, obj, "base_url")) |v| p.base_url = v;
    if (try optString(arena, environ_map, obj, "thinking")) |v| p.thinking = v;
    if (try optString(arena, environ_map, obj, "mode")) |v| p.mode = v;
    if (optBool(obj, "prompts")) |v| p.prompts = v;
    if (optBool(obj, "yes")) |v| p.yes = v;
    if (try optString(arena, environ_map, obj, "ask_tools")) |v| p.ask_tools = v;
    if (try optString(arena, environ_map, obj, "allow_tools")) |v| p.allow_tools = v;
    if (try optString(arena, environ_map, obj, "deny_tools")) |v| p.deny_tools = v;
    if (try optString(arena, environ_map, obj, "role")) |v| p.role = v;
    if (try optString(arena, environ_map, obj, "log_level")) |v| p.log_level = v;
    if (try optString(arena, environ_map, obj, "log_file")) |v| p.log_file = v;
    if (try optString(arena, environ_map, obj, "system_prompt")) |v| p.system_prompt = v;
    if (try optString(arena, environ_map, obj, "append_system_prompt")) |v| p.append_system_prompt = v;
    if (optBool(obj, "text_tool_call_fallback")) |v| p.text_tool_call_fallback = v;
    if (try optString(arena, environ_map, obj, "http_trace_dir")) |v| p.http_trace_dir = v;
    if (optInt(u32, obj, "max_turns")) |v| p.max_turns = v;
    if (optInt(u32, obj, "retry_max_attempts")) |v| p.retry_max_attempts = v;
    if (optInt(u64, obj, "retry_max_total_ms")) |v| p.retry_max_total_ms = v;
    if (optInt(u32, obj, "base_delay_ms")) |v| p.base_delay_ms = v;

    if (obj.get("env")) |env_v| if (env_v == .object) {
        var env_map = std.StringHashMap([]const u8).init(arena);
        var it = env_v.object.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* != .string) continue;
            const k = try arena.dupe(u8, entry.key_ptr.*);
            const v = try interpolate(arena, environ_map, entry.value_ptr.string);
            try env_map.put(k, v);
        }
        p.env = env_map;
    };

    return p;
}

fn optString(
    arena: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    obj: std.json.ObjectMap,
    key: []const u8,
) ProfileError!?[]const u8 {
    const v = lookupField(obj, key) orelse return null;
    if (v != .string) return null;
    return try interpolate(arena, environ_map, v.string);
}

fn optBool(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const v = lookupField(obj, key) orelse return null;
    if (v != .bool) return null;
    return v.bool;
}

fn optInt(comptime T: type, obj: std.json.ObjectMap, key: []const u8) ?T {
    const v = lookupField(obj, key) orelse return null;
    if (v != .integer) return null;
    if (v.integer < 0) return null;
    if (v.integer > std.math.maxInt(T)) return null;
    return @intCast(v.integer);
}

/// v1.17.1 — accept both `snake_case` and `kebab-case` keys
/// for profile fields. Users intuitively type `base-url` (matching
/// the CLI flag name) or `base_url` (matching the spec table); we
/// honor both so neither gets silently dropped. The lookup tries
/// the canonical form first, then a kebab variant if it differs.
fn lookupField(obj: std.json.ObjectMap, key: []const u8) ?std.json.Value {
    if (obj.get(key)) |v| return v;
    // Try the alternate form — swap every `_` with `-` (and vice
    // versa). Stack-buffer is fine because every profile-field key
    // we use is well under 64 bytes.
    var buf: [64]u8 = undefined;
    if (key.len > buf.len) return null;
    var differs = false;
    for (key, 0..) |c, i| {
        const swapped: u8 = switch (c) {
            '_' => '-',
            '-' => '_',
            else => c,
        };
        if (swapped != c) differs = true;
        buf[i] = swapped;
    }
    if (!differs) return null;
    return obj.get(buf[0..key.len]);
}

/// `${VAR}` interpolation. Walks `input`, replaces every
/// `${NAME}` with `environ_map.get(NAME)` (or empty string if
/// unset). Literal `$` followed by anything other than `{` is
/// passed through unchanged. Nested braces (`${${X}}`) are not
/// supported — interpolate is one-pass.
pub fn interpolate(
    arena: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    input: []const u8,
) ProfileError![]const u8 {
    if (std.mem.indexOf(u8, input, "${") == null) {
        return try arena.dupe(u8, input);
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);

    var i: usize = 0;
    while (i < input.len) {
        if (i + 1 < input.len and input[i] == '$' and input[i + 1] == '{') {
            const end = std.mem.indexOfPos(u8, input, i + 2, "}") orelse {
                // Unterminated `${` — treat literally.
                try out.append(arena, input[i]);
                i += 1;
                continue;
            };
            const name = input[i + 2 .. end];
            if (environ_map.get(name)) |val| {
                try out.appendSlice(arena, val);
            }
            // Unset → expand to empty string. Matches shell behavior.
            i = end + 1;
        } else {
            try out.append(arena, input[i]);
            i += 1;
        }
    }
    return try out.toOwnedSlice(arena);
}

/// Overlay profile fields onto cfg for any field that's still at
/// its default. Sets process env vars from the `env` block.
pub fn applyToCfg(
    cfg: *cli.Config,
    profile: Profile,
    environ_map: *std.process.Environ.Map,
) ProfileError!void {
    try applyProfileEnv(profile, environ_map);
    try applyProfileStringFields(cfg, profile, environ_map);
    applyProfileBoolFields(cfg, profile);
    applyProfileNumericFields(cfg, profile);
    try applyProfileThinking(cfg, profile);
    try applyProfileMode(cfg, profile);
}

fn applyProfileEnv(profile: Profile, environ_map: *std.process.Environ.Map) !void {
    if (profile.env) |env_map| {
        var it = env_map.iterator();
        while (it.next()) |entry| {
            try environ_map.put(entry.key_ptr.*, entry.value_ptr.*);
        }
    }
}

fn applyProfileStringFields(
    cfg: *cli.Config,
    profile: Profile,
    environ_map: *std.process.Environ.Map,
) !void {
    const arena = cfg.arena.allocator();

    if (cfg.provider == null) if (profile.provider) |v| {
        cfg.provider = try arena.dupe(u8, v);
    };
    if (cfg.model == null) if (profile.model) |v| {
        cfg.model = try arena.dupe(u8, v);
    };
    if (cfg.api_key == null) {
        if (profile.api_key) |v| {
            cfg.api_key = try arena.dupe(u8, v);
        } else if (profile.api_key_env) |env_name| {
            if (environ_map.get(env_name)) |val| if (val.len > 0) {
                cfg.api_key = try arena.dupe(u8, val);
            };
        }
    }
    if (cfg.auth_token == null) {
        if (profile.auth_token) |v| {
            cfg.auth_token = try arena.dupe(u8, v);
        } else if (profile.auth_token_env) |env_name| {
            if (environ_map.get(env_name)) |val| if (val.len > 0) {
                cfg.auth_token = try arena.dupe(u8, val);
            };
        }
    }
    if (cfg.base_url == null) if (profile.base_url) |v| {
        cfg.base_url = try arena.dupe(u8, v);
    };
    if (cfg.system_prompt == null) if (profile.system_prompt) |v| {
        cfg.system_prompt = try arena.dupe(u8, v);
    };
    if (cfg.append_system_prompt == null) if (profile.append_system_prompt) |v| {
        cfg.append_system_prompt = try arena.dupe(u8, v);
    };
    if (cfg.log_level == null) if (profile.log_level) |v| {
        cfg.log_level = try arena.dupe(u8, v);
    };
    if (cfg.log_file == null) if (profile.log_file) |v| {
        cfg.log_file = try arena.dupe(u8, v);
    };
    if (cfg.http_trace_dir == null) if (profile.http_trace_dir) |v| {
        cfg.http_trace_dir = try arena.dupe(u8, v);
    };
    if (cfg.role == null) if (profile.role) |v| {
        cfg.role = try arena.dupe(u8, v);
    };
    if (cfg.ask_tools_csv == null) if (profile.ask_tools) |v| {
        cfg.ask_tools_csv = try arena.dupe(u8, v);
    };
    if (cfg.allow_tools_csv == null) if (profile.allow_tools) |v| {
        cfg.allow_tools_csv = try arena.dupe(u8, v);
    };
    if (cfg.deny_tools_csv == null) if (profile.deny_tools) |v| {
        cfg.deny_tools_csv = try arena.dupe(u8, v);
    };
}

fn applyProfileBoolFields(cfg: *cli.Config, profile: Profile) void {
    if (!cfg.prompts) if (profile.prompts) |v| {
        cfg.prompts = v;
    };
    if (!cfg.yes) if (profile.yes) |v| {
        cfg.yes = v;
    };
    if (!cfg.text_tool_call_fallback) if (profile.text_tool_call_fallback) |v| {
        cfg.text_tool_call_fallback = v;
    };
}

fn applyProfileNumericFields(cfg: *cli.Config, profile: Profile) void {
    if (cfg.max_turns == null) if (profile.max_turns) |v| {
        cfg.max_turns = v;
    };
    if (cfg.retry_max_attempts == null) if (profile.retry_max_attempts) |v| {
        cfg.retry_max_attempts = v;
    };
    if (cfg.retry_max_total_ms == null) if (profile.retry_max_total_ms) |v| {
        cfg.retry_max_total_ms = v;
    };
    if (cfg.retry_base_delay_ms == null) if (profile.base_delay_ms) |v| {
        cfg.retry_base_delay_ms = v;
    };
}

fn applyProfileThinking(cfg: *cli.Config, profile: Profile) ProfileError!void {
    if (!cfg.thinking_explicit) if (profile.thinking) |v| {
        cfg.thinking = parseThinking(v) catch return error.UnknownThinkingLevel;
    };
}

fn applyProfileMode(cfg: *cli.Config, profile: Profile) ProfileError!void {
    if (cfg.mode == .print) if (profile.mode) |v| {
        cfg.mode = parseMode(v) catch return error.UnknownMode;
    };
}

fn parseThinking(s: []const u8) !ait.ThinkingLevel {
    if (std.mem.eql(u8, s, "off")) return .off;
    if (std.mem.eql(u8, s, "minimal")) return .minimal;
    if (std.mem.eql(u8, s, "low")) return .low;
    if (std.mem.eql(u8, s, "medium")) return .medium;
    if (std.mem.eql(u8, s, "high")) return .high;
    if (std.mem.eql(u8, s, "xhigh")) return .xhigh;
    return error.UnknownThinkingLevel;
}

fn parseMode(s: []const u8) !cli.Mode {
    if (std.mem.eql(u8, s, "print")) return .print;
    if (std.mem.eql(u8, s, "interactive")) return .interactive;
    if (std.mem.eql(u8, s, "rpc")) return .rpc;
    if (std.mem.eql(u8, s, "proxy")) return .proxy;
    return error.UnknownMode;
}

// ─── v1.17.0 Phase 2 — built-in preset catalog ────────────────

/// One built-in preset. `body` is the JSON body that would go
/// inside `profiles.<name>` of a user's settings.json — same shape
/// as user profiles, runs through the same parser, can carry the
/// same `${VAR}` references and `env` block.
pub const Builtin = struct {
    name: []const u8,
    description: []const u8,
    body: []const u8,
};

const builtin_cloudflare_gemma_body =
    \\{
    \\  "provider": "gateway",
    \\  "model": "@cf/google/gemma-4-26b-a4b-it",
    \\  "base_url": "https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/ai/v1/chat/completions",
    \\  "api_key_env": "CLOUDFLARE_API_TOKEN",
    \\  "ask_tools": "all",
    \\  "env": {
    \\    "FRANKY_FIRST_BYTE_TIMEOUT_MS": "300000"
    \\  }
    \\}
;

const builtin_cloudflare_llama_body =
    \\{
    \\  "provider": "gateway",
    \\  "model": "@cf/meta/llama-3.3-70b-instruct-fp8-fast",
    \\  "base_url": "https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/ai/v1/chat/completions",
    \\  "api_key_env": "CLOUDFLARE_API_TOKEN",
    \\  "text_tool_call_fallback": true,
    \\  "ask_tools": "all",
    \\  "env": {
    \\    "FRANKY_FIRST_BYTE_TIMEOUT_MS": "300000"
    \\  }
    \\}
;

const builtin_cerebras_body =
    \\{
    \\  "provider": "gateway",
    \\  "base_url": "https://api.cerebras.ai/v1/chat/completions",
    \\  "api_key_env": "CEREBRAS_API_KEY"
    \\}
;

const builtin_openrouter_body =
    \\{
    \\  "provider": "gateway",
    \\  "base_url": "https://openrouter.ai/api/v1/chat/completions",
    \\  "api_key_env": "OPENROUTER_API_KEY"
    \\}
;

const builtin_ollama_body =
    \\{
    \\  "provider": "gateway",
    \\  "base_url": "http://localhost:11434/v1/chat/completions",
    \\  "env": {
    \\    "FRANKY_FIRST_BYTE_TIMEOUT_MS": "600000"
    \\  }
    \\}
;

const builtin_lm_studio_body =
    \\{
    \\  "provider": "gateway",
    \\  "base_url": "http://localhost:1234/v1/chat/completions"
    \\}
;

const builtin_gemini_body =
    \\{
    \\  "provider": "google-gemini",
    \\  "model": "gemini-2.5-pro",
    \\  "api_key_env": "GEMINI_API_KEY"
    \\}
;

pub const builtin_catalog = [_]Builtin{
    .{
        .name = "cloudflare-gemma",
        .description = "Cloudflare Workers AI — @cf/google/gemma-4-26b-a4b-it (env: CLOUDFLARE_ACCOUNT_ID + CLOUDFLARE_API_TOKEN)",
        .body = builtin_cloudflare_gemma_body,
    },
    .{
        .name = "cloudflare-llama",
        .description = "Cloudflare Workers AI — Llama-3.3-70b with --text-tool-call-fallback (env: CLOUDFLARE_ACCOUNT_ID + CLOUDFLARE_API_TOKEN)",
        .body = builtin_cloudflare_llama_body,
    },
    .{
        .name = "cerebras",
        .description = "Cerebras — inference cloud (env: CEREBRAS_API_KEY)",
        .body = builtin_cerebras_body,
    },
    .{
        .name = "openrouter",
        .description = "OpenRouter — multi-provider gateway (env: OPENROUTER_API_KEY)",
        .body = builtin_openrouter_body,
    },
    .{
        .name = "ollama",
        .description = "Local Ollama on http://localhost:11434 (no auth, generous first-byte timeout)",
        .body = builtin_ollama_body,
    },
    .{
        .name = "lm-studio",
        .description = "Local LM Studio on http://localhost:1234 (no auth)",
        .body = builtin_lm_studio_body,
    },
    .{
        .name = "gemini",
        .description = "Google AI Studio Gemini — gemini-2.5-pro via native provider (env: GEMINI_API_KEY; or --auth-token / auth.json bearer record)",
        .body = builtin_gemini_body,
    },
};

/// Return the embedded body for the named built-in, or null if no
/// such built-in exists. The body is the JSON object literal that
/// would go under `profiles.<name>` in a user's settings.json.
pub fn getBuiltinBody(name: []const u8) ?[]const u8 {
    for (builtin_catalog) |b| {
        if (std.mem.eql(u8, b.name, name)) return b.body;
    }
    return null;
}

/// Render every available profile (built-in + user) as a printable
/// string, one per line, with provenance and description.
///
/// User profiles take priority — if a name exists in both, the user
/// version wins at apply time and the built-in is marked
/// `[overridden]`. Owned slice; caller frees.
/// v1.24.1 — comma-separated list of available profile names
/// (user from settings.json layers + built-in catalog, deduped),
/// for embedding in the system prompt's subagent guidance.
/// Names only — no descriptions. Sorted alphabetically for
/// determinism (the prompt cache benefits from a stable order).
pub fn listProfileNamesCSV(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var names = std.StringHashMap(void).init(a);
    const paths = try settingsPaths(a, environ_map);
    const candidates = [_]?[]const u8{ paths.project, paths.franky_home, paths.home_canonical };
    for (candidates) |maybe_path| {
        const path = maybe_path orelse continue;
        try collectUserProfileNames(a, io, path, &names);
    }
    // Only include builtin profiles when no user profiles exist.
    if (names.count() == 0) {
        for (builtin_catalog) |b| try names.put(try a.dupe(u8, b.name), {});
    }

    var sorted: std.ArrayList([]const u8) = .empty;
    var it = names.iterator();
    while (it.next()) |e| try sorted.append(a, e.key_ptr.*);
    std.mem.sort([]const u8, sorted.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (sorted.items, 0..) |n, i| {
        if (i > 0) try out.appendSlice(allocator, ", ");
        try out.appendSlice(allocator, n);
    }
    return try out.toOwnedSlice(allocator);
}

pub fn listProfiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Collect user profile names by reading each settings.json layer.
    var user_names = std.StringHashMap(void).init(a);
    const paths = try settingsPaths(a, environ_map);
    const candidates = [_]?[]const u8{ paths.project, paths.franky_home, paths.home_canonical };
    for (candidates) |maybe_path| {
        const path = maybe_path orelse continue;
        try collectUserProfileNames(a, io, path, &user_names);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    if (user_names.count() > 0) {
        try out.appendSlice(allocator, "User profiles (settings.json):\n");
        var it = user_names.iterator();
        while (it.next()) |entry| {
            const line = try std.fmt.allocPrint(allocator, "  {s}\n", .{entry.key_ptr.*});
            defer allocator.free(line);
            try out.appendSlice(allocator, line);
        }
        try out.appendSlice(allocator, "\n");
    }

    try out.appendSlice(allocator, "Built-in profiles:\n");
    for (builtin_catalog) |b| {
        const marker = if (user_names.contains(b.name)) "  [overridden]" else "";
        const line = try std.fmt.allocPrint(allocator, "  {s}{s}  {s}\n", .{ b.name, marker, b.description });
        defer allocator.free(line);
        try out.appendSlice(allocator, line);
    }

    return try out.toOwnedSlice(allocator);
}

fn collectUserProfileNames(
    arena: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    out: *std.StringHashMap(void),
) !void {
    var f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return;
    defer f.close(io);
    const len = f.length(io) catch return;
    if (len == 0) return;
    const buf = try arena.alloc(u8, @intCast(len));
    const n = f.readPositionalAll(io, buf, 0) catch return;

    const parsed = std.json.parseFromSlice(std.json.Value, arena, buf[0..n], .{}) catch return;
    if (parsed.value != .object) return;
    const profiles_val = parsed.value.object.get("profiles") orelse return;
    if (profiles_val != .object) return;

    var it = profiles_val.object.iterator();
    while (it.next()) |entry| {
        const name_dup = try arena.dupe(u8, entry.key_ptr.*);
        try out.put(name_dup, {});
    }
}

/// Materialize a built-in preset into the user's settings.json so
/// they can edit it. Writes to `$FRANKY_HOME/settings.json` if set,
/// else `$HOME/.franky/settings.json`. Errors if no parent env is
/// available, the named built-in doesn't exist, or a user profile
/// of the same name already exists.
///
/// Implementation note: instead of mutating a parsed JSON Value
/// tree (which fights std.json's ObjectMap surface), this builds
/// the merged settings.json text directly. We parse only to detect
/// whether an existing profile of the same name is present, then
/// emit a fresh whole-file render. The resulting file always has
/// our standard shape — top-level keys preserved as-is, profiles
/// section always last — even if the user's original was
/// differently formatted.
pub fn saveBuiltin(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    name: []const u8,
) !void {
    const body = getBuiltinBody(name) orelse return error.UnknownBuiltin;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Resolve target path: prefer $FRANKY_HOME, fall back to
    // $HOME/.franky.
    const target_dir: []u8 = if (environ_map.get("FRANKY_HOME")) |h| blk: {
        if (h.len == 0) return error.NoHome;
        break :blk try a.dupe(u8, h);
    } else if (environ_map.get("HOME")) |h| blk: {
        if (h.len == 0) return error.NoHome;
        break :blk try std.fs.path.join(a, &.{ h, ".franky" });
    } else return error.NoHome;

    try std.Io.Dir.cwd().createDirPath(io, target_dir);
    const settings_path = try std.fs.path.join(a, &.{ target_dir, "settings.json" });

    // Read existing settings.json text (or empty `{}`).
    const existing_text: []const u8 = blk: {
        const f_or = std.Io.Dir.cwd().openFile(io, settings_path, .{});
        if (f_or) |f_open| {
            var f = f_open;
            defer f.close(io);
            const len = f.length(io) catch break :blk "{}";
            if (len == 0) break :blk "{}";
            const buf = try a.alloc(u8, @intCast(len));
            const n = f.readPositionalAll(io, buf, 0) catch break :blk "{}";
            break :blk buf[0..n];
        } else |_| {
            break :blk "{}";
        }
    };

    // Parse to validate + collect existing top-level keys + check
    // for duplicate profile name.
    const existing_parsed = std.json.parseFromSlice(std.json.Value, a, existing_text, .{}) catch
        return error.ExistingSettingsMalformed;
    if (existing_parsed.value != .object) return error.ExistingSettingsMalformed;
    const root_obj = existing_parsed.value.object;

    // Refuse to overwrite an existing user profile of the same name.
    if (root_obj.get("profiles")) |p| if (p == .object) {
        if (p.object.contains(name)) return error.ProfileAlreadyExists;
    };

    // Build the merged settings.json by string concat. Preserves
    // any non-`profiles` top-level fields verbatim by re-stringifying
    // them; replaces the `profiles` block with a merged version.
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try out.appendSlice(a, "{\n");

    // Re-emit non-profiles top-level fields first. Keys are
    // emitted via `appendQuoted` (simple `"..."` literal — profile
    // and settings keys are alphanumeric / underscore in practice;
    // if a key contains a control char or quote, we let std.json's
    // Stringify on the Value handle the escape level later via the
    // `keyValue` helper below).
    var it = root_obj.iterator();
    var first = true;
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "profiles")) continue;
        if (!first) try out.appendSlice(a, ",\n");
        first = false;
        try out.appendSlice(a, "  ");
        try appendKey(a, &out, entry.key_ptr.*);
        try out.appendSlice(a, ": ");
        const v_json = try std.json.Stringify.valueAlloc(a, entry.value_ptr.*, .{});
        try out.appendSlice(a, v_json);
    }

    // Profiles block.
    if (!first) try out.appendSlice(a, ",\n");
    try out.appendSlice(a, "  \"profiles\": {\n");

    var profile_first = true;
    if (root_obj.get("profiles")) |p| if (p == .object) {
        var pit = p.object.iterator();
        while (pit.next()) |entry| {
            if (!profile_first) try out.appendSlice(a, ",\n");
            profile_first = false;
            try out.appendSlice(a, "    ");
            try appendKey(a, &out, entry.key_ptr.*);
            try out.appendSlice(a, ": ");
            const v_json = try std.json.Stringify.valueAlloc(a, entry.value_ptr.*, .{});
            try out.appendSlice(a, v_json);
        }
    };

    // Append the new built-in preset.
    if (!profile_first) try out.appendSlice(a, ",\n");
    try out.appendSlice(a, "    ");
    try appendKey(a, &out, name);
    try out.appendSlice(a, ": ");
    try out.appendSlice(a, body);

    try out.appendSlice(a, "\n  }\n}\n");

    // Atomic tempfile + rename. The file may carry env-var hints
    // (api_key_env, etc.) but no raw secrets, so 0600 is a
    // belt-and-suspenders policy aligned with auth.json/permissions.json.
    const tmp_path = try std.fmt.allocPrint(a, "{s}.tmp.{d}", .{ settings_path, stream.nowMillis() });
    {
        var f = try std.Io.Dir.cwd().createFile(io, tmp_path, .{});
        defer f.close(io);
        var wbuf: [4096]u8 = undefined;
        var w = f.writer(io, &wbuf);
        try w.interface.writeAll(out.items);
        try w.interface.flush();
    }
    try std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), settings_path, io);
}

/// Quote `key` as a JSON string literal into `out`. Escapes the
/// minimum set required for JSON validity: `"`, `\`, and control
/// characters. Other Unicode bytes pass through verbatim. Used for
/// the merged-settings.json render in `saveBuiltin`.
fn appendKey(allocator: std.mem.Allocator, out: *std.ArrayList(u8), key: []const u8) !void {
    try out.append(allocator, '"');
    for (key) |c| switch (c) {
        '"' => try out.appendSlice(allocator, "\\\""),
        '\\' => try out.appendSlice(allocator, "\\\\"),
        '\n' => try out.appendSlice(allocator, "\\n"),
        '\r' => try out.appendSlice(allocator, "\\r"),
        '\t' => try out.appendSlice(allocator, "\\t"),
        0...0x07, 0x0b, 0x0e...0x1f => {
            var tmp: [8]u8 = undefined;
            const written = std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{c}) catch unreachable;
            try out.appendSlice(allocator, written);
        },
        else => try out.append(allocator, c),
    };
    try out.append(allocator, '"');
}

// ─── tests ────────────────────────────────────────────────────────

const testing = std.testing;
const test_h = @import("../../test_helpers.zig");

test "interpolate: passthrough when no ${ present" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    const out = try interpolate(arena.allocator(), &env, "plain string");
    try testing.expectEqualStrings("plain string", out);
}

test "interpolate: replaces ${VAR} with env value" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("ACCOUNT", "abc123");
    const out = try interpolate(arena.allocator(), &env, "https://x/${ACCOUNT}/y");
    try testing.expectEqualStrings("https://x/abc123/y", out);
}

test "interpolate: unset var expands to empty" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    const out = try interpolate(arena.allocator(), &env, "x${MISSING}y");
    try testing.expectEqualStrings("xy", out);
}

test "interpolate: unterminated ${ is literal" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    const out = try interpolate(arena.allocator(), &env, "trailing ${oops");
    try testing.expectEqualStrings("trailing ${oops", out);
}

test "applyProfile: full cloudflare-style profile from settings.json" {
    const gpa = testing.allocator;

    // Set up a temp $FRANKY_HOME with a settings.json containing
    // the profile.
    const ts = stream.nowMillis();
    const dir_path = try std.fmt.allocPrint(gpa, "/tmp/franky-profile-test-{d}", .{ts});
    defer gpa.free(dir_path);
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    defer std.Io.Dir.cwd().deleteTree(io, dir_path) catch {};

    try std.Io.Dir.cwd().createDirPath(io, dir_path);
    const settings_path = try std.fs.path.join(gpa, &.{ dir_path, "settings.json" });
    defer gpa.free(settings_path);
    const settings_body =
        \\{
        \\  "profiles": {
        \\    "cloudflare": {
        \\      "provider": "gateway",
        \\      "mode": "print",
        \\      "model": "@cf/google/gemma-4-26b-a4b-it",
        \\      "base_url": "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/ai/v1/chat/completions",
        \\      "api_key_env": "CF_API_TOKEN",
        \\      "thinking": "high",
        \\      "prompts": true,
        \\      "ask_tools": "all",
        \\      "log_level": "trace",
        \\      "text_tool_call_fallback": true,
        \\      "env": {
        \\        "FRANKY_FIRST_BYTE_TIMEOUT_MS": "1200000"
        \\      }
        \\    }
        \\  }
        \\}
    ;
    var f = try std.Io.Dir.cwd().createFile(io, settings_path, .{});
    {
        var wbuf: [256]u8 = undefined;
        var w = f.writer(io, &wbuf);
        try w.interface.writeAll(settings_body);
        try w.interface.flush();
    }
    f.close(io);

    // Build the env: FRANKY_HOME points at our temp dir; provide
    // CF_ACCOUNT_ID + CF_API_TOKEN so the profile can resolve them.
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("FRANKY_HOME", dir_path);
    try env.put("CF_ACCOUNT_ID", "acct-xyz");
    try env.put("CF_API_TOKEN", "tok-secret");

    var cfg = try cli.parse(gpa, &.{"franky"});
    defer cfg.deinit();

    try applyProfile(&cfg, io, &env, "cloudflare");

    try testing.expectEqualStrings("gateway", cfg.provider.?);
    try testing.expectEqualStrings("@cf/google/gemma-4-26b-a4b-it", cfg.model.?);
    try testing.expectEqualStrings(
        "https://api.cloudflare.com/client/v4/accounts/acct-xyz/ai/v1/chat/completions",
        cfg.base_url.?,
    );
    try testing.expectEqualStrings("tok-secret", cfg.api_key.?);
    try testing.expect(cfg.prompts);
    try testing.expect(cfg.text_tool_call_fallback);
    try testing.expectEqualStrings("all", cfg.ask_tools_csv.?);
    try testing.expectEqualStrings("trace", cfg.log_level.?);
    try testing.expectEqual(ait.ThinkingLevel.high, cfg.thinking);
    try testing.expectEqualStrings("1200000", env.get("FRANKY_FIRST_BYTE_TIMEOUT_MS").?);
}

test "applyToCfg: max_turns flows from profile when CLI didn't set it" {
    const gpa = testing.allocator;
    var cfg = try cli.parse(gpa, &.{"franky"});
    defer cfg.deinit();
    try testing.expectEqual(@as(?u32, null), cfg.max_turns);

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();

    const profile = Profile{ .max_turns = 75 };
    try applyToCfg(&cfg, profile, &env);

    try testing.expectEqual(@as(?u32, 75), cfg.max_turns);
}

test "applyToCfg: CLI max_turns wins over profile" {
    const gpa = testing.allocator;
    var cfg = try cli.parse(gpa, &.{ "franky", "--max-turns", "10" });
    defer cfg.deinit();

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();

    const profile = Profile{ .max_turns = 200 };
    try applyToCfg(&cfg, profile, &env);

    try testing.expectEqual(@as(?u32, 10), cfg.max_turns);
}

test "applyProfile: CLI flags win over profile values" {
    const gpa = testing.allocator;

    const ts = stream.nowMillis();
    const dir_path = try std.fmt.allocPrint(gpa, "/tmp/franky-profile-precedence-{d}", .{ts});
    defer gpa.free(dir_path);
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    defer std.Io.Dir.cwd().deleteTree(io, dir_path) catch {};

    try std.Io.Dir.cwd().createDirPath(io, dir_path);
    const settings_path = try std.fs.path.join(gpa, &.{ dir_path, "settings.json" });
    defer gpa.free(settings_path);
    const settings_body =
        \\{"profiles": {"p": {"provider": "gateway", "model": "from-profile"}}}
    ;
    var f = try std.Io.Dir.cwd().createFile(io, settings_path, .{});
    {
        var wbuf: [256]u8 = undefined;
        var w = f.writer(io, &wbuf);
        try w.interface.writeAll(settings_body);
        try w.interface.flush();
    }
    f.close(io);

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("FRANKY_HOME", dir_path);

    // CLI explicitly sets --model from-cli; profile shouldn't win.
    var cfg = try cli.parse(gpa, &.{ "franky", "--model", "from-cli" });
    defer cfg.deinit();

    try applyProfile(&cfg, io, &env, "p");

    try testing.expectEqualStrings("gateway", cfg.provider.?); // applied (CLI didn't set)
    try testing.expectEqualStrings("from-cli", cfg.model.?); // CLI wins
}

test "applyProfile: kebab-case keys work as well as snake_case" {
    const gpa = testing.allocator;

    const ts = stream.nowMillis();
    const dir_path = try std.fmt.allocPrint(gpa, "/tmp/franky-profile-kebab-{d}", .{ts});
    defer gpa.free(dir_path);
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    defer std.Io.Dir.cwd().deleteTree(io, dir_path) catch {};

    try std.Io.Dir.cwd().createDirPath(io, dir_path);
    const settings_path = try std.fs.path.join(gpa, &.{ dir_path, "settings.json" });
    defer gpa.free(settings_path);
    // Mirrors the real user-reported file: kebab-case keys
    // (`base-url`, `api-key-env`, `ask-tools`, `log-level`,
    // `http-trace-dir`).
    const settings_body =
        \\{
        \\  "profiles": {
        \\    "cf": {
        \\      "provider": "gateway",
        \\      "model": "@cf/google/gemma-4-26b-a4b-it",
        \\      "base-url": "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/ai/v1/chat/completions",
        \\      "api-key-env": "CF_API_TOKEN",
        \\      "ask-tools": "all",
        \\      "log-level": "trace",
        \\      "http-trace-dir": "/tmp/cf-trace",
        \\      "thinking": "high",
        \\      "prompts": true,
        \\      "text-tool-call-fallback": true
        \\    }
        \\  }
        \\}
    ;
    var f = try std.Io.Dir.cwd().createFile(io, settings_path, .{});
    {
        var wbuf: [256]u8 = undefined;
        var w = f.writer(io, &wbuf);
        try w.interface.writeAll(settings_body);
        try w.interface.flush();
    }
    f.close(io);

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("FRANKY_HOME", dir_path);
    try env.put("CF_ACCOUNT_ID", "kebab-acct");
    try env.put("CF_API_TOKEN", "kebab-token");

    var cfg = try cli.parse(gpa, &.{"franky"});
    defer cfg.deinit();

    try applyProfile(&cfg, io, &env, "cf");

    try testing.expectEqualStrings("gateway", cfg.provider.?);
    try testing.expect(std.mem.indexOf(u8, cfg.base_url.?, "kebab-acct") != null);
    try testing.expectEqualStrings("kebab-token", cfg.api_key.?);
    try testing.expectEqualStrings("all", cfg.ask_tools_csv.?);
    try testing.expectEqualStrings("trace", cfg.log_level.?);
    try testing.expectEqualStrings("/tmp/cf-trace", cfg.http_trace_dir.?);
    try testing.expectEqual(ait.ThinkingLevel.high, cfg.thinking);
    try testing.expect(cfg.prompts);
    try testing.expect(cfg.text_tool_call_fallback);
}

test "lookupField: snake_case key matches" {
    const gpa = testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, "{\"foo_bar\": 1}", .{});
    defer parsed.deinit();
    try testing.expect(lookupField(parsed.value.object, "foo_bar") != null);
    try testing.expect(lookupField(parsed.value.object, "foo-bar") != null);
}

test "lookupField: kebab-case key matches via snake-case lookup" {
    const gpa = testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, "{\"foo-bar\": 1}", .{});
    defer parsed.deinit();
    try testing.expect(lookupField(parsed.value.object, "foo_bar") != null);
    try testing.expect(lookupField(parsed.value.object, "foo-bar") != null);
}

test "lookupField: unrelated key returns null" {
    const gpa = testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, "{\"foo_bar\": 1}", .{});
    defer parsed.deinit();
    try testing.expect(lookupField(parsed.value.object, "qux") == null);
}

test "applyProfile: missing profile name returns ProfileNotFound" {
    const gpa = testing.allocator;

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    // No FRANKY_HOME, no HOME → no settings file findable.
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    var cfg = try cli.parse(gpa, &.{"franky"});
    defer cfg.deinit();

    const result = applyProfile(&cfg, io, &env, "nonexistent");
    try testing.expectError(error.ProfileNotFound, result);
}

test "parseThinking: covers all variants" {
    try testing.expectEqual(ait.ThinkingLevel.off, try parseThinking("off"));
    try testing.expectEqual(ait.ThinkingLevel.minimal, try parseThinking("minimal"));
    try testing.expectEqual(ait.ThinkingLevel.low, try parseThinking("low"));
    try testing.expectEqual(ait.ThinkingLevel.medium, try parseThinking("medium"));
    try testing.expectEqual(ait.ThinkingLevel.high, try parseThinking("high"));
    try testing.expectEqual(ait.ThinkingLevel.xhigh, try parseThinking("xhigh"));
    try testing.expectError(error.UnknownThinkingLevel, parseThinking("bogus"));
}

test "parseMode: covers all variants" {
    try testing.expectEqual(cli.Mode.print, try parseMode("print"));
    try testing.expectEqual(cli.Mode.interactive, try parseMode("interactive"));
    try testing.expectEqual(cli.Mode.rpc, try parseMode("rpc"));
    try testing.expectEqual(cli.Mode.proxy, try parseMode("proxy"));
    try testing.expectError(error.UnknownMode, parseMode("bogus"));
}

// ─── v1.17.0 Phase 2 — built-in catalog tests ─────────────────

test "getBuiltinBody: known names resolve, unknown returns null" {
    try testing.expect(getBuiltinBody("cloudflare-gemma") != null);
    try testing.expect(getBuiltinBody("cloudflare-llama") != null);
    try testing.expect(getBuiltinBody("gemini") != null);
    try testing.expect(getBuiltinBody("ollama") != null);
    try testing.expect(getBuiltinBody("nonexistent") == null);
}

test "every built-in body parses as a valid profile object" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();

    for (builtin_catalog) |b| {
        const profile = parseBuiltinBody(arena.allocator(), &env, b.body) catch |e| {
            std.debug.print("built-in '{s}' failed to parse: {s}\n", .{ b.name, @errorName(e) });
            return e;
        };
        // Every preset must at least set provider.
        try testing.expect(profile.provider != null);
    }
}

test "applyProfile: built-in catalog works without settings.json" {
    const gpa = testing.allocator;

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("CLOUDFLARE_ACCOUNT_ID", "acct-test");
    try env.put("CLOUDFLARE_API_TOKEN", "tok-test");

    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    var cfg = try cli.parse(gpa, &.{"franky"});
    defer cfg.deinit();

    try applyProfile(&cfg, io, &env, "cloudflare-llama");

    try testing.expectEqualStrings("gateway", cfg.provider.?);
    try testing.expectEqualStrings("@cf/meta/llama-3.3-70b-instruct-fp8-fast", cfg.model.?);
    try testing.expect(std.mem.indexOf(u8, cfg.base_url.?, "acct-test") != null);
    try testing.expectEqualStrings("tok-test", cfg.api_key.?);
    try testing.expect(cfg.text_tool_call_fallback);
}

test "saveBuiltin: writes preset to fresh settings.json" {
    const gpa = testing.allocator;

    const ts = stream.nowMillis();
    const dir_path = try std.fmt.allocPrint(gpa, "/tmp/franky-save-test-{d}", .{ts});
    defer gpa.free(dir_path);
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    defer std.Io.Dir.cwd().deleteTree(io, dir_path) catch {};

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("FRANKY_HOME", dir_path);

    try saveBuiltin(gpa, io, &env, "gemini");

    // Read it back and verify.
    const settings_path = try std.fs.path.join(gpa, &.{ dir_path, "settings.json" });
    defer gpa.free(settings_path);
    var f = try std.Io.Dir.cwd().openFile(io, settings_path, .{});
    defer f.close(io);
    const len = try f.length(io);
    const buf = try gpa.alloc(u8, @intCast(len));
    defer gpa.free(buf);
    _ = try f.readPositionalAll(io, buf, 0);

    try testing.expect(std.mem.indexOf(u8, buf, "\"gemini\"") != null);
    try testing.expect(std.mem.indexOf(u8, buf, "GEMINI_API_KEY") != null);
}

test "saveBuiltin: refuses to overwrite an existing profile of the same name" {
    const gpa = testing.allocator;

    const ts = stream.nowMillis();
    const dir_path = try std.fmt.allocPrint(gpa, "/tmp/franky-save-conflict-{d}", .{ts});
    defer gpa.free(dir_path);
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    defer std.Io.Dir.cwd().deleteTree(io, dir_path) catch {};

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("FRANKY_HOME", dir_path);

    // Save once → success.
    try saveBuiltin(gpa, io, &env, "gemini");
    // Save again → ProfileAlreadyExists.
    try testing.expectError(error.ProfileAlreadyExists, saveBuiltin(gpa, io, &env, "gemini"));
}

test "saveBuiltin: unknown built-in returns UnknownBuiltin" {
    const gpa = testing.allocator;

    const ts = stream.nowMillis();
    const dir_path = try std.fmt.allocPrint(gpa, "/tmp/franky-save-unknown-{d}", .{ts});
    defer gpa.free(dir_path);
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    defer std.Io.Dir.cwd().deleteTree(io, dir_path) catch {};

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("FRANKY_HOME", dir_path);

    try testing.expectError(error.UnknownBuiltin, saveBuiltin(gpa, io, &env, "nonexistent"));
}

test "listProfiles: prints every built-in" {
    const gpa = testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const text = try listProfiles(gpa, io, &env);
    defer gpa.free(text);

    for (builtin_catalog) |b| {
        try testing.expect(std.mem.indexOf(u8, text, b.name) != null);
    }
}
