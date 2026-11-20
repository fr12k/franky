//! `--profile <name>` loader — v2 §5 (settings & profile system).
//!
//! Phase 1 (v1.17.0): read `profiles.<name>` from settings.json,
//! apply its fields onto `cli.Config` for any flag the user didn't
//! set on the command line, resolve `api_key_env`/`auth_token_env`
//! credential indirections, and set process env vars from the
//! `env: {}` block. `${VAR}` interpolation in string values is
//! supported.
//!
//! Profiles are read exclusively from `profiles.<name>` in
//! settings.json (project, FRANKY_HOME, $HOME/.franky) and the
//! settings.json embedded into the binary by build.zig. If no
//! settings.json has the named profile, applyProfile returns
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
    /// v3.x — vision capability override. When non-null, this value
    /// overrides the model-catalog `capabilities.vision` for every
    /// model in this profile. Used for gateway-served models that
    /// aren't in the built-in catalog. For profiles with mixed
    /// vision/non-vision models, use `model_vision` instead.
    vision: ?bool = null,
    /// v3.x — per-model vision overrides. Maps model id → bool. When
    /// the selected model has an entry here, it wins over both the
    /// catalog default and the profile-level `vision` field. Keys are
    /// model ids as they appear in the `models` array.
    model_vision: ?std.StringHashMap(bool) = null,
    /// OpenRouter app-attribution overrides (see `ai/openrouter_attribution.zig`).
    /// When the resolved `base_url` is an OpenRouter endpoint, these stamp
    /// `HTTP-Referer` / `X-OpenRouter-Title` / `X-OpenRouter-Categories`
    /// onto every request. Any left null falls back to the built-in franky
    /// identity. Forks/rehosters should set `http_referer` (and usually
    /// `openrouter_title`) to claim their own ranking identity.
    http_referer: ?[]const u8 = null,
    openrouter_title: ?[]const u8 = null,
    openrouter_categories: ?[]const u8 = null,
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

    /// `models` array. When present, the profile is a
    /// *provider template* that auto-expands into synthetic
    /// sub-profiles named `<parent-name>/<model>` for each entry.
    /// All other fields (provider, base_url, api_key, …) are
    /// inherited; only the model differs per entry.
    /// Example: `"ollama"` with `models: ["gemma4:31b", "qwen3.6:latest"]`
    /// creates synthetic profiles `ollama/gemma4:31b` and
    /// `ollama/qwen3.6:latest`.
    /// When a profile is referenced directly (without `/model` suffix),
    /// the first entry in `models` is used as the effective model.
    models: ?[][]const u8 = null,

    /// Index into `models` for the selected model. When `null`,
    /// defaults to 0 (first entry). Set during parent/model expansion
    /// to point at the matched model without mutating the array.
    selected_model_idx: ?usize = null,

    /// Return the effective model string: `models[selected_model_idx orelse 0]`.
    /// Returns `null` when `models` is null or empty.
    pub fn model(self: Profile) ?[]const u8 {
        const ms = self.models orelse return null;
        if (ms.len == 0) return null;
        const idx = self.selected_model_idx orelse 0;
        if (idx >= ms.len) return null;
        return ms[idx];
    }
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
/// `profiles.<name>`. Returns null if no layer has the name.
/// Profiles come exclusively from settings.json (project,
/// FRANKY_HOME, $HOME/.franky) and the settings.json embedded
/// into the binary by build.zig.
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

    return null;
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

    // 1. Try exact match first.
    if (profiles_val.object.get(name)) |profile_val| {
        if (profile_val != .object) return error.MalformedProfile;
        return try parseProfileObject(arena, environ_map, profile_val.object);
    }

    // 2. v3.1 — try parent/model expansion.
    //    If name is "parent/model", look up "parent", check its
    //    "models" array, and synthesize a profile with model set.
    if (std.mem.indexOfScalar(u8, name, '/')) |slash| {
        const parent_name = name[0..slash];
        const model_name = name[slash + 1 ..];
        if (model_name.len == 0) return null;
        if (profiles_val.object.get(parent_name)) |parent_val| {
            if (parent_val != .object) return null;
            const parent_obj = parent_val.object;
            const models_val = parent_obj.get("models") orelse return null;
            if (models_val != .array) return null;
            // Check that model_name is in the models array.
            const found = for (models_val.array.items) |item| {
                if (item == .string and std.mem.eql(u8, item.string, model_name)) break true;
            } else false;
            if (!found) return null;

            // Parse the parent profile, then set the selected model index
            // to point at the matched model without mutating the array.
            var profile = try parseProfileObject(arena, environ_map, parent_obj);
            for (profile.models.?, 0..) |m, i| {
                if (std.mem.eql(u8, m, model_name)) {
                    profile.selected_model_idx = i;
                    break;
                }
            }
            return profile;
        }
    }

    return null;
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
    // v3.x — vision capability overrides.
    if (optBool(obj, "vision")) |v| p.vision = v;
    if (obj.get("model_vision")) |mv| if (mv == .object) {
        var map = std.StringHashMap(bool).init(arena);
        var it = mv.object.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* != .bool) continue;
            const k = try arena.dupe(u8, entry.key_ptr.*);
            try map.put(k, entry.value_ptr.bool);
        }
        p.model_vision = map;
    };
    if (try optString(arena, environ_map, obj, "http_referer")) |v| p.http_referer = v;
    if (try optString(arena, environ_map, obj, "openrouter_title")) |v| p.openrouter_title = v;
    if (try optString(arena, environ_map, obj, "openrouter_categories")) |v| p.openrouter_categories = v;
    if (optInt(u32, obj, "max_turns")) |v| p.max_turns = v;
    if (optInt(u32, obj, "retry_max_attempts")) |v| p.retry_max_attempts = v;
    if (optInt(u64, obj, "retry_max_total_ms")) |v| p.retry_max_total_ms = v;
    if (optInt(u32, obj, "base_delay_ms")) |v| p.base_delay_ms = v;

    if (obj.get("models")) |models_v| if (models_v == .array) {
        const arr = models_v.array;
        var models = try arena.alloc([]const u8, arr.items.len);
        for (arr.items, 0..) |item, i| {
            if (item == .string) {
                models[i] = try interpolate(arena, environ_map, item.string);
            } else {
                models[i] = "";
            }
        }
        p.models = models;
    };

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
    // v3.x — vision capability override. Precedence: per-model map
    // (for the selected model) > profile-level `vision` field.
    if (profile.model_vision) |mv| {
        if (profile.model()) |model_id| {
            if (mv.get(model_id)) |v| cfg.vision_override = v;
        }
    }
    if (cfg.vision_override == null) if (profile.vision) |v| {
        cfg.vision_override = v;
    };
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
    if (cfg.model == null) if (profile.model()) |v| {
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
    if (cfg.http_referer == null) if (profile.http_referer) |v| {
        cfg.http_referer = try arena.dupe(u8, v);
    };
    if (cfg.openrouter_title == null) if (profile.openrouter_title) |v| {
        cfg.openrouter_title = try arena.dupe(u8, v);
    };
    if (cfg.openrouter_categories == null) if (profile.openrouter_categories) |v| {
        cfg.openrouter_categories = try arena.dupe(u8, v);
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
    if (std.mem.eql(u8, s, "rpc")) return .rpc;
    if (std.mem.eql(u8, s, "proxy")) return .proxy;
    return error.UnknownMode;
}

/// Comma-separated list of available profile names (user from
/// settings.json layers), for embedding in the system prompt's
/// subagent guidance. Names only — no descriptions. Sorted
/// alphabetically for determinism (the prompt cache benefits from
/// a stable order).
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
    environ_map: *const std.process.Environ.Map,
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

        // v3.1 — if the profile has a "models" array, also register
        // each expanded name (parent/model) so they appear in listings.
        if (entry.value_ptr.* == .object) {
            if (entry.value_ptr.object.get("models")) |models_v| if (models_v == .array) {
                for (models_v.array.items) |item| {
                    if (item == .string and item.string.len > 0) {
                        const expanded = try std.fmt.allocPrint(arena, "{s}/{s}", .{ entry.key_ptr.*, item.string });
                        try out.put(expanded, {});
                    }
                }
            };
        }
    }
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
        \\      "models": ["@cf/google/gemma-4-26b-a4b-it"],
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

test "applyToCfg: profile vision override sets cfg.vision_override" {
    const gpa = testing.allocator;
    var cfg = try cli.parse(gpa, &.{"franky"});
    defer cfg.deinit();

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();

    const profile = Profile{ .vision = true };
    try applyToCfg(&cfg, profile, &env);
    try testing.expectEqual(@as(?bool, true), cfg.vision_override);
}

test "applyToCfg: model_vision map wins over profile vision" {
    const gpa = testing.allocator;
    var cfg = try cli.parse(gpa, &.{"franky"});
    defer cfg.deinit();

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();

    var mv = std.StringHashMap(bool).init(cfg.arena.allocator());
    try mv.put("gemma4:latest", true);
    try mv.put("granite4.1:30b", false);
    const models = [_][]const u8{ "gemma4:latest", "granite4.1:30b" };
    const profile = Profile{
        .models = @constCast(&models),
        .selected_model_idx = 1, // granite → false
        .vision = true, // profile says true, but model_vision wins
        .model_vision = mv,
    };
    try applyToCfg(&cfg, profile, &env);
    try testing.expectEqual(@as(?bool, false), cfg.vision_override);
}

test "applyToCfg: model_vision falls back to profile vision when model not in map" {
    const gpa = testing.allocator;
    var cfg = try cli.parse(gpa, &.{"franky"});
    defer cfg.deinit();

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();

    var mv = std.StringHashMap(bool).init(cfg.arena.allocator());
    try mv.put("other-model", false);
    const models = [_][]const u8{"gemma4:latest"};
    const profile = Profile{
        .models = @constCast(&models),
        .selected_model_idx = 0,
        .vision = true,
        .model_vision = mv,
    };
    try applyToCfg(&cfg, profile, &env);
    try testing.expectEqual(@as(?bool, true), cfg.vision_override);
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
        \\{"profiles": {"p": {"provider": "gateway", "models": ["from-profile"]}}}
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
        \\      "models": ["@cf/google/gemma-4-26b-a4b-it"],
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
    try testing.expectEqual(cli.Mode.rpc, try parseMode("rpc"));
    try testing.expectEqual(cli.Mode.proxy, try parseMode("proxy"));
    try testing.expectError(error.UnknownMode, parseMode("bogus"));
}

test "applyProfile: explicit attribution overrides round-trip" {
    // A profile that explicitly sets all three attribution fields must
    // overlay them onto `cfg` verbatim.
    const gpa = testing.allocator;

    const ts = stream.nowMillis();
    const dir_path = try std.fmt.allocPrint(gpa, "/tmp/franky-attribution-{d}", .{ts});
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
        \\    "orfork": {
        \\      "provider": "gateway",
        \\      "base_url": "https://openrouter.ai/api/v1/chat/completions",
        \\      "api_key_env": "OPENROUTER_API_KEY",
        \\      "http_referer": "https://myfork.example",
        \\      "openrouter_title": "myfork",
        \\      "openrouter_categories": "cli-agent,cloud-agent"
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
    try env.put("OPENROUTER_API_KEY", "or-key");

    var cfg = try cli.parse(gpa, &.{"franky"});
    defer cfg.deinit();

    try applyProfile(&cfg, io, &env, "orfork");

    try testing.expectEqualStrings("https://myfork.example", cfg.http_referer.?);
    try testing.expectEqualStrings("myfork", cfg.openrouter_title.?);
    try testing.expectEqualStrings("cli-agent,cloud-agent", cfg.openrouter_categories.?);
}

