//! Unified config resolver — v2.22 design.
//!
//! Single entry point `resolve()` that the four mode entry points
//! (print, interactive, rpc, proxy) call with their CLI config and
//! get back a fully-resolved, ready-to-use `ResolvedConfig` bundle.
//!
//! The resolver is the **only** place where layering precedence is
//! implemented. Changing precedence, adding a source, or adding a
//! field touches exactly one file.
//!
//! ## Lifecycle
//!
//! 1. Caller parses CLI args into `cli.Config`.
//! 2. Caller applies `--profile` (profiles_mod.applyProfile).
//! 3. Caller resolves log level + inits logger.
//! 4. Caller calls `config.resolve()` to get `ResolvedConfig`.
//! 5. Caller uses the resolved config directly — no per-mode merge.
//! 6. Caller calls `ResolvedConfig.deinit()` when done.

const std = @import("std");
const franky = @import("../root.zig");
const ai = franky.ai;
const agent = franky.agent;
const at = agent.types;
const tools_mod = franky.coding.tools;
const cli_mod = franky.coding.cli;
const settings_mod = franky.coding.settings;
const profiles_mod = franky.coding.profiles;
const auth_mod = franky.coding.auth;
const models_mod = franky.coding.models;
const role_mod = franky.coding.role;
const permissions_mod = franky.coding.permissions;
const skills_mod = franky.coding.skills;
const extensions_mod = franky.coding.extensions;
const ext_catalog = franky.coding.extensions_builtin.catalog;
const compression_mod = franky.coding.compression;

/// Error set for config resolution.
pub const ResolveError = error{
    MissingApiKey,
    UnknownProvider,
    ProfileNotFound,
    MalformedProfile,
    MalformedSettings,
    UnknownRole,
    UnknownThinkingLevel,
    UnknownMode,
} || std.mem.Allocator.Error || std.Io.File.WriteError;

// ─── ResolvedConfig ──────────────────────────────────────────────

pub const ResolvedConfig = struct {
    // ── Provider (resolved) ───────────────────────────────────────
    provider_name: []const u8,
    model_id: []const u8,
    api_key: ?[]const u8,
    auth_token: ?[]const u8,
    api_tag: []const u8,
    base_url: ?[]const u8,
    thinking_level: ai.types.ThinkingLevel,
    context_window: u32,
    max_output: u32,
    capabilities: ai.types.Capabilities,
    /// Per-provider timeout overrides (from profile or env)
    connect_timeout_ms: u64,
    upload_timeout_ms: u64,
    first_byte_timeout_ms: u64,
    event_gap_timeout_ms: u64,
    /// Text-tool-call-fallback flag (default false)
    text_tool_call_fallback: bool,
    /// v3.0 — when > 0, only the N most recent tool results carry full
    /// content to the LLM; older ones are replaced with a compact
    /// placeholder.
    max_full_tool_results: u32 = 0,
    registry: ai.registry.Registry,
    faux_provider: *ai.providers.faux.FauxProvider,

    // ── Tool set (filtered by role + tools_filter, merged with extensions) ─
    tools: []const at.AgentTool,

    // ── Permission store ──────────────────────────────────────────
    permission_store: *permissions_mod.Store,
    session_gates: *permissions_mod.SessionGates,

    // ── Preset registry ──────────────────────────────────────────
    preset_registry: tools_mod.subagent.PresetRegistry,

    // ── Extension manager ────────────────────────────────────────
    ext_manager: extensions_mod.Manager,

    // ── Skills ───────────────────────────────────────────────────
    skills: SkillsState,

    // ── Guardrails (per-mode wiring differs slightly) ────────────
    guardrail_state: *agent.guardrails.GuardrailState,

    // ── Settings overlay values ──────────────────────────────────
    bash_default_timeout_ms: ?u64,
    read_max_bytes_without_limit: ?usize,
    retry_policy: ai.retry.Policy,
    max_turns: u32,
    prompts_enabled: bool,

    // ── Workspace ────────────────────────────────────────────────
    workspace: ?*tools_mod.workspace.Workspace,

    // ── Bash state (arena-allocated, address stable) ─────────────
    bash_state: *tools_mod.bash.SessionBashState,

    // ── Read ctx (arena-allocated, address stable) ───────────────
    read_ctx: *tools_mod.read.ReadCtx,

    // ── Subagent context ─────────────────────────────────────────
    subagent_ctx: *tools_mod.subagent.Ctx,

    // ── Logging ─────────────────────────────────────────────────
    log_level: ai.log.Level,
    log_file: ?[]const u8,
    http_trace_dir: ?[]const u8,
    log_per_session: bool,

    // ── Startup warnings ─────────────────────────────────────────
    /// Messages printed to stderr once at startup (tool install hints, etc).
    startup_warnings: []const []const u8 = &.{},

    // ── Role gate ────────────────────────────────────────────────
    role_gate: *role_mod.RoleGate,
    active_role: role_mod.Role,

    // ── Pre-rendered review config block ─────────────────────────
    review_config_block: ?[]const u8,

    // ── Compression config ────────────────────────────────────────
    compression: compression_mod.CompressionConfig,

    // ── Arena ────────────────────────────────────────────────────
    /// Everything that outlives `resolve()` is allocated on this arena.
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *ResolvedConfig) void {
        // Free arena-owned slices before deiniting arena.
        const a = self.arena.allocator();
        // Tools slice is arena-allocated.
        // Bash state owns its cwd tracking etc.
        self.bash_state.deinit();
        a.destroy(self.bash_state);
        if (self.workspace) |ws| a.destroy(ws);
        a.destroy(self.read_ctx);
        a.destroy(self.subagent_ctx);
        // Guardrail state owns its sub-structures.
        self.guardrail_state.deinit();
        a.destroy(self.guardrail_state);
        // Extension manager deinits its extensions.
        self.ext_manager.deinit();
        // Preset registry deinits its presets.
        self.preset_registry.deinit();
        // Permission store deinits its internal maps.
        self.permission_store.deinit();
        a.destroy(self.permission_store);
        a.destroy(self.session_gates);
        a.destroy(self.role_gate);
        // Registry deinits its entries; faux provider owns any seeded scripts.
        self.faux_provider.deinit();
        a.destroy(self.faux_provider);
        self.registry.deinit();
        // Skills state.
        if (self.skills.owned) {
            for (self.skills.skills.items) |*s| s.deinit(a);
            self.skills.skills.deinit(a);
        }
        // Free everything on the resolver arena.
        self.arena.deinit();
    }
};

/// Skills loading state, owned by the resolver arena.
pub const SkillsState = struct {
    /// If true, `skills` and `active` need deinit.
    owned: bool,
    skills: std.ArrayList(skills_mod.Skill),
    active: std.ArrayList(usize),
};

// ─── Env-var resolution table ───────────────────────────────────

/// Describes one env var that maps to a `cli.Config` field.
/// The comptime loop in `resolve` iterates this table and sets
/// the field when it is still at its default value.
const EnvOverride = struct {
    env_name: []const u8,
    /// Field name within cli.Config — used for comptime reflection.
    /// Set to "" for env vars that are handled specially (not a field).
    field_name: []const u8,
};

/// Env vars that overlay onto cli.Config fields.
/// Adding a new env var is a one-line addition here.
const env_overrides = [_]EnvOverride{
    .{ .env_name = "FRANKY_LOG", .field_name = "log_level" },
    .{ .env_name = "FRANKY_LOG_FILE", .field_name = "log_file" },
    .{ .env_name = "FRANKY_LOG_PER_SESSION", .field_name = "log_per_session" },
    .{ .env_name = "FRANKY_MAX_TURNS", .field_name = "max_turns" },
    .{ .env_name = "FRANKY_HTTP_TRACE_DIR", .field_name = "http_trace_dir" },
    .{ .env_name = "FRANKY_CONNECT_TIMEOUT_MS", .field_name = "connect_timeout_ms" },
    .{ .env_name = "FRANKY_UPLOAD_TIMEOUT_MS", .field_name = "upload_timeout_ms" },
    .{ .env_name = "FRANKY_FIRST_BYTE_TIMEOUT_MS", .field_name = "first_byte_timeout_ms" },
    .{ .env_name = "FRANKY_EVENT_GAP_TIMEOUT_MS", .field_name = "event_gap_timeout_ms" },
    .{ .env_name = "FRANKY_DEBUG", .field_name = "" }, // handled specially
    .{ .env_name = "FRANKY_BASH_SPILL_DIR", .field_name = "" }, // handled in bash init
};

/// Apply env-var overrides onto `cfg` for fields still at default.
/// Uses the comptime table above.
fn applyEnvOverrides(cfg: *cli_mod.Config, map: *const std.process.Environ.Map) void {
    // Process each env var entry individually (no inline for with runtime control flow).
    {
        if (map.get("FRANKY_LOG")) |val| {
            if (cfg.log_level == null) cfg.log_level = cfg.arena.allocator().dupe(u8, val) catch null;
        }
    }
    {
        if (map.get("FRANKY_LOG_FILE")) |val| {
            if (cfg.log_file == null) cfg.log_file = cfg.arena.allocator().dupe(u8, val) catch null;
        }
    }
    {
        if (map.get("FRANKY_LOG_PER_SESSION")) |val| {
            if (!cfg.log_per_session) cfg.log_per_session = val.len > 0;
        }
    }
    {
        if (map.get("FRANKY_MAX_TURNS")) |val| {
            if (cfg.max_turns == null) cfg.max_turns = std.fmt.parseInt(u32, val, 10) catch null;
        }
    }
    {
        if (map.get("FRANKY_HTTP_TRACE_DIR")) |val| {
            if (cfg.http_trace_dir == null) cfg.http_trace_dir = cfg.arena.allocator().dupe(u8, val) catch null;
        }
    }
    {
        if (map.get("FRANKY_CONNECT_TIMEOUT_MS")) |val| {
            if (cfg.connect_timeout_ms == null) cfg.connect_timeout_ms = std.fmt.parseInt(u32, val, 10) catch null;
        }
    }
    {
        if (map.get("FRANKY_UPLOAD_TIMEOUT_MS")) |val| {
            if (cfg.upload_timeout_ms == null) cfg.upload_timeout_ms = std.fmt.parseInt(u32, val, 10) catch null;
        }
    }
    {
        if (map.get("FRANKY_FIRST_BYTE_TIMEOUT_MS")) |val| {
            if (cfg.first_byte_timeout_ms == null) cfg.first_byte_timeout_ms = std.fmt.parseInt(u32, val, 10) catch null;
        }
    }
    {
        if (map.get("FRANKY_EVENT_GAP_TIMEOUT_MS")) |val| {
            if (cfg.event_gap_timeout_ms == null) cfg.event_gap_timeout_ms = std.fmt.parseInt(u32, val, 10) catch null;
        }
    }
}

// ─── Log level resolution ───────────────────────────────────────

/// Extract the bare global level from a spec that may contain
/// comma-separated `scope:level` entries. Returns null when the
/// input is only scope overrides with no global level.
fn extractGlobalLevel(s: []const u8) ?ai.log.Level {
    var it = std.mem.splitScalar(u8, s, ',');
    var result: ?ai.log.Level = null;
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        // Skip scope:level entries — they don't set the global level.
        if (std.mem.indexOfScalar(u8, trimmed, ':')) |_| continue;
        if (ai.log.Level.fromString(trimmed)) |l| result = l;
    }
    return result;
}

/// Resolve log level from CLI config and environ.
/// Precedence: CLI --log-level > FRANKY_LOG > FRANKY_DEBUG > --verbose > .warn
pub fn resolveLogLevel(cfg: *const cli_mod.Config, map: *const std.process.Environ.Map) ai.log.Level {
    // 1. Explicit CLI flag wins (extract global level from compound spec).
    if (cfg.log_level) |s| {
        if (extractGlobalLevel(s)) |l| return l;
        if (ai.log.Level.fromString(s)) |l| return l; // backward compat
    }
    // 2. FRANKY_LOG env var.
    if (map.get("FRANKY_LOG")) |s| {
        if (extractGlobalLevel(s)) |l| return l;
        if (ai.log.Level.fromString(s)) |l| return l;
    }
    // 3. FRANKY_DEBUG=1 → debug.
    if (map.get("FRANKY_DEBUG")) |v| {
        if (v.len > 0 and v[0] != '0') return .debug;
    }
    // 4. --verbose → info.
    if (cfg.verbose) return .info;
    // 5. Default: warnings and errors only.
    return .warn;
}

/// Resolve log file destination.
/// Precedence: --log-file > FRANKY_LOG_FILE > null.
pub fn resolveLogFile(cfg: *const cli_mod.Config, map: *const std.process.Environ.Map) ?[]const u8 {
    if (cfg.log_file) |p| if (p.len > 0) return p;
    if (map.get("FRANKY_LOG_FILE")) |p| if (p.len > 0) return p;
    return null;
}

/// Resolve --log-per-session flag.
pub fn resolveLogPerSession(cfg: *const cli_mod.Config, map: *const std.process.Environ.Map) bool {
    if (cfg.log_per_session) return true;
    if (map.get("FRANKY_LOG_PER_SESSION")) |v| if (v.len > 0) return true;
    return false;
}

/// Resolve --http-trace-dir.
pub fn resolveHttpTraceDir(cfg: *const cli_mod.Config, map: *const std.process.Environ.Map) ?[]const u8 {
    if (cfg.http_trace_dir) |p| if (p.len > 0) return p;
    if (map.get("FRANKY_HTTP_TRACE_DIR")) |p| if (p.len > 0) return p;
    return null;
}

// ─── Timeouts resolution ────────────────────────────────────────

/// Resolve provider timeouts from CLI config and env map.
/// Precedence per field: CLI flag → env var → autodetected default.
pub fn resolveTimeouts(
    cfg: *const cli_mod.Config,
    map: *const std.process.Environ.Map,
) ai.registry.Timeouts {
    var t: ai.registry.Timeouts = .{};
    if (isLoopbackBaseUrl(cfg.base_url)) t.first_byte_ms = 600_000;

    if (cfg.connect_timeout_ms) |v| t.connect_ms = v else if (parseEnvMapU32(map, "FRANKY_CONNECT_TIMEOUT_MS")) |v| t.connect_ms = v;
    if (cfg.upload_timeout_ms) |v| t.upload_ms = v else if (parseEnvMapU32(map, "FRANKY_UPLOAD_TIMEOUT_MS")) |v| t.upload_ms = v;
    if (cfg.first_byte_timeout_ms) |v| t.first_byte_ms = v else if (parseEnvMapU32(map, "FRANKY_FIRST_BYTE_TIMEOUT_MS")) |v| t.first_byte_ms = v;
    if (cfg.event_gap_timeout_ms) |v| t.event_gap_ms = v else if (parseEnvMapU32(map, "FRANKY_EVENT_GAP_TIMEOUT_MS")) |v| t.event_gap_ms = v;
    return t;
}

fn parseEnvMapU32(map: *const std.process.Environ.Map, key: []const u8) ?u32 {
    const v = map.get(key) orelse return null;
    return std.fmt.parseInt(u32, v, 10) catch null;
}

/// True when `base_url` parses to a loopback host.
pub fn isLoopbackBaseUrl(maybe_url: ?[]const u8) bool {
    const url = maybe_url orelse return false;
    const after_scheme = blk: {
        if (std.mem.indexOf(u8, url, "://")) |i| break :blk url[i + 3 ..];
        break :blk url;
    };
    if (after_scheme.len > 0 and after_scheme[0] == '[') {
        const close = std.mem.indexOfScalar(u8, after_scheme, ']') orelse return false;
        const inner = after_scheme[1..close];
        return std.mem.eql(u8, inner, "::1");
    }
    const host_end = std.mem.indexOfAny(u8, after_scheme, ":/?#") orelse after_scheme.len;
    const host = after_scheme[0..host_end];
    return std.mem.eql(u8, host, "localhost") or
        std.mem.eql(u8, host, "127.0.0.1") or
        std.mem.eql(u8, host, "::1");
}

// ─── Settings overlay helpers ───────────────────────────────────

/// Load layered settings.json (project → user) using the same
/// path resolution as provider resolution. Returns the fresh
/// `Settings` so callers can apply overlays.
/// Failure modes: a malformed JSON layer surfaces as
/// `SettingsError.MalformedJson`; returns built-in defaults so a
/// bad file can't abort startup.
pub fn loadSettings(
    allocator: std.mem.Allocator,
    io: std.Io,
    map: *const std.process.Environ.Map,
) !settings_mod.Settings {
    const home = map.get("FRANKY_HOME") orelse map.get("HOME");
    const pwd = map.get("PWD");
    return settings_mod.loadLayered(allocator, io, pwd, home) catch
        try settings_mod.defaults(allocator);
}

/// Apply settings.json overlay fields onto bash_state.
pub fn applyBashSettingsOverlay(
    bash_state: *tools_mod.bash.SessionBashState,
    settings: *const settings_mod.Settings,
) void {
    if (settings.bash_timeout_ms) |ms| {
        bash_state.default_timeout_ms_override = ms;
    }
}

/// Apply settings.json overlay fields onto read_ctx.
pub fn applyReadSettingsOverlay(
    read_ctx: *tools_mod.read.ReadCtx,
    settings: *const settings_mod.Settings,
) void {
    if (settings.read_max_bytes) |b| {
        read_ctx.max_bytes_without_limit_override = b;
    }
}

/// Apply settings.json max_turns overlay onto cfg.
pub fn applyMaxTurnsSettingsOverlay(
    cfg: *cli_mod.Config,
    settings: *const settings_mod.Settings,
) void {
    if (cfg.max_turns != null) return; // CLI / profile already set it.
    if (settings.max_turns) |v| cfg.max_turns = v;
}

/// Apply settings.json retry policy overlay onto cfg.
pub fn applyRetrySettingsOverlay(
    cfg: *cli_mod.Config,
    settings: *const settings_mod.Settings,
) void {
    if (cfg.retry_max_attempts == null) {
        cfg.retry_max_attempts = settings.retry_max_attempts;
    }
    if (cfg.retry_max_total_ms == null) {
        cfg.retry_max_total_ms = settings.retry_max_total_ms;
    }
}

/// v3.0 — apply `tools.compress.*` settings.json overlay onto `cfg`.
/// Settings fill in when CLI didn't set them (CLI always wins).
pub fn applyCompressionSettingsOverlay(
    cfg: *cli_mod.Config,
    settings: *const settings_mod.Settings,
) void {
    if (settings.compress_enabled) |v| cfg.compress = v;
    if (settings.compress_min_bytes) |v| cfg.compress_min_bytes = v;
    if (settings.compress_ccr) |v| cfg.compress_ccr = v;
    if (settings.compress_json) |v| cfg.compress_json = v;
    if (settings.compress_logs) |v| cfg.compress_logs = v;
    if (settings.compress_search) |v| cfg.compress_search = v;
    if (settings.compress_diff) |v| cfg.compress_diff = v;
    if (settings.compress_code) |v| cfg.compress_code = v;
}

/// Apply permissions settings overlay onto permission store.
pub fn applyPermissionsSettingsOverlay(
    store: *permissions_mod.Store,
    settings: *const settings_mod.Settings,
) !void {
    if (settings.permissions_ask_all) |b| store.ask_all = b;
    if (settings.permissions_yes_to_all) |b| store.yes_to_all = b;
    for (settings.permissions_always_allow_tools) |t| {
        try store.addBareEntry(t, .allow, false);
    }
    for (settings.permissions_always_deny_tools) |t| {
        try store.addBareEntry(t, .deny, false);
    }
    for (settings.permissions_always_allow_bash) |fp| {
        try store.addBareEntry(fp, .allow, true);
    }
    for (settings.permissions_always_deny_bash) |fp| {
        try store.addBareEntry(fp, .deny, true);
    }
}

/// Resolve prompts default from settings when CLI didn't set it.
pub fn resolvePromptsDefault(
    cfg: *const cli_mod.Config,
    settings: *const settings_mod.Settings,
) bool {
    if (cfg.prompts) return true; // CLI wins.
    return settings.prompts_default orelse false;
}

/// Resolve max_turns from CLI flag, env var, or null.
pub fn resolveMaxTurns(
    cfg: *const cli_mod.Config,
    map: *const std.process.Environ.Map,
) ?u32 {
    if (cfg.max_turns) |v| return v;
    if (parseEnvMapU32(map, "FRANKY_MAX_TURNS")) |v| return v;
    return null;
}

/// Resolve retry policy from CLI flags, settings, or defaults.
pub fn resolveRetryPolicy(
    cfg: *const cli_mod.Config,
    settings: ?*const settings_mod.Settings,
) ai.retry.Policy {
    var p: ai.retry.Policy = .{};
    if (cfg.retry_max_attempts) |v| {
        p.max_retries = v;
    } else if (settings) |s| {
        if (s.retry_max_attempts) |v| p.max_retries = v;
    }
    if (cfg.retry_max_total_ms) |v| {
        p.max_total_delay_ms = v;
    } else if (settings) |s| {
        if (s.retry_max_total_ms) |v| p.max_total_delay_ms = v;
    }
    if (cfg.retry_base_delay_ms) |v| {
        p.base_delay_ms = v;
    }
    return p;
}

// ─── Provider resolution ────────────────────────────────────────

/// Resolved provider info (mirrors print.zig's ProviderInfo).
pub const ProviderInfo = struct {
    provider_name: []const u8,
    api_tag: []const u8,
    model_id: []const u8,
    api_key: ?[]const u8,
    auth_token: ?[]const u8,
    base_url: ?[]const u8,
    context_window: u32,
    max_output: u32,
    capabilities: ai.types.Capabilities,
};

/// Resolve provider from CLI config, env, auth.json, and settings.
/// This is the unified provider resolution used by all modes.
pub fn resolveProvider(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: *cli_mod.Config,
    map: *const std.process.Environ.Map,
) !ProviderInfo {
    const a = cfg.arena.allocator();

    var settings = try loadSettings(allocator, io, map);
    defer settings.deinit();
    applyThinkingOverride(cfg, &settings);

    var auth_state = try loadAuthState(a, allocator, io, map);
    defer if (auth_state) |*as| as.deinit();

    const models_extras = try loadModelsExtras(a, allocator, io, map);

    const creds = try resolveAllCredentials(a, cfg, map, auth_state);
    const chosen = chooseProvider(cfg, &creds, &settings);

    if (std.mem.eql(u8, chosen, "faux")) return buildFauxConfig(a, cfg, models_extras);
    if (std.mem.eql(u8, chosen, "anthropic")) return buildAnthropicConfig(a, cfg, &creds, &settings, models_extras);
    if (std.mem.eql(u8, chosen, "openai")) return buildOpenaiConfig(a, cfg, &creds, &settings, models_extras);
    if (std.mem.eql(u8, chosen, "gateway")) return buildGatewayConfig(a, cfg, map, &creds, auth_state, models_extras);
    if (std.mem.eql(u8, chosen, "google-gemini")) return buildGeminiConfig(a, cfg, &creds, models_extras);

    return error.UnknownProvider;
}

const ResolvedCredentials = struct {
    api_key: ?[]const u8 = null,
    auth_token: ?[]const u8 = null,
    openai_api_key: ?[]const u8 = null,
    gemini_api_key: ?[]const u8 = null,
    gemini_auth_token: ?[]const u8 = null,
    has_anthropic: bool = false,
    has_openai: bool = false,
    has_gemini: bool = false,
};

fn applyThinkingOverride(cfg: *cli_mod.Config, settings: *const settings_mod.Settings) void {
    if (!cfg.thinking_explicit) {
        if (ai.types.ThinkingLevel.fromString(settings.thinking)) |lvl| {
            cfg.thinking = lvl;
        }
    }
}

fn loadAuthState(a: std.mem.Allocator, allocator: std.mem.Allocator, io: std.Io, map: *const std.process.Environ.Map) !?auth_mod.Auth {
    const franky_home = map.get("FRANKY_HOME");
    const home = map.get("HOME");
    const auth_path = try authJsonPathFrom(a, franky_home, home);
    if (auth_path) |p| {
        return auth_mod.load(allocator, io, p) catch null;
    }
    return null;
}

fn loadModelsExtras(a: std.mem.Allocator, allocator: std.mem.Allocator, io: std.Io, map: *const std.process.Environ.Map) ![]const models_mod.Entry {
    const franky_home = map.get("FRANKY_HOME");
    const home = map.get("HOME");
    const models_path = try modelsJsonPathFrom(a, franky_home, home);
    if (models_path) |p| {
        const bytes = readWholeFileOpt(allocator, io, p) orelse return &.{};
        defer allocator.free(bytes);
        return models_mod.parseFromSlice(a, bytes) catch &.{};
    }
    return &.{};
}

fn resolveAllCredentials(a: std.mem.Allocator, cfg: *const cli_mod.Config, map: *const std.process.Environ.Map, auth_state: ?auth_mod.Auth) !ResolvedCredentials {
    const anthropic_file = if (auth_state) |as| as.get("anthropic") else null;
    const openai_file = if (auth_state) |as| as.get("openai") else null;
    const gemini_file = if (auth_state) |as| as.get("google-gemini") else null;

    const api_key: ?[]const u8 = blk: {
        if (cfg.api_key) |k| break :blk k;
        if (map.get("ANTHROPIC_API_KEY")) |k| break :blk try a.dupe(u8, k);
        if (anthropic_file) |rec| if (rec.api_key) |k| break :blk try a.dupe(u8, k);
        break :blk null;
    };
    const auth_token: ?[]const u8 = blk: {
        if (cfg.auth_token) |t| break :blk t;
        if (map.get("ANTHROPIC_AUTH_TOKEN")) |t| break :blk try a.dupe(u8, t);
        if (map.get("CLAUDE_CODE_OAUTH_TOKEN")) |t| break :blk try a.dupe(u8, t);
        if (anthropic_file) |rec| if (rec.access_token) |t| break :blk try a.dupe(u8, t);
        break :blk null;
    };
    const openai_api_key: ?[]const u8 = blk: {
        if (map.get("OPENAI_API_KEY")) |k| break :blk try a.dupe(u8, k);
        if (openai_file) |rec| if (rec.api_key) |k| break :blk try a.dupe(u8, k);
        break :blk null;
    };
    const gemini_api_key: ?[]const u8 = blk: {
        if (map.get("GEMINI_API_KEY")) |k| break :blk try a.dupe(u8, k);
        if (map.get("GOOGLE_API_KEY")) |k| break :blk try a.dupe(u8, k);
        if (gemini_file) |rec| if (rec.api_key) |k| break :blk try a.dupe(u8, k);
        break :blk null;
    };
    const gemini_auth_token: ?[]const u8 = blk: {
        if (gemini_file) |rec| if (rec.access_token) |t| break :blk try a.dupe(u8, t);
        break :blk null;
    };

    const has_anthropic = api_key != null or auth_token != null;
    const has_openai = openai_api_key != null or (cfg.api_key != null and !has_anthropic);
    const has_gemini = gemini_api_key != null or gemini_auth_token != null;

    return .{
        .api_key = api_key,
        .auth_token = auth_token,
        .openai_api_key = openai_api_key,
        .gemini_api_key = gemini_api_key,
        .gemini_auth_token = gemini_auth_token,
        .has_anthropic = has_anthropic,
        .has_openai = has_openai,
        .has_gemini = has_gemini,
    };
}

fn chooseProvider(cfg: *const cli_mod.Config, creds: *const ResolvedCredentials, settings: *const settings_mod.Settings) []const u8 {
    if (cfg.offline) return "faux";
    if (cfg.provider) |p| return p;
    if (creds.has_anthropic) return "anthropic";
    if (creds.has_openai) return "openai";
    if (creds.has_gemini) return "google-gemini";
    if (std.mem.eql(u8, settings.default_provider, "faux")) return "faux";
    return "faux";
}

fn buildFauxConfig(a: std.mem.Allocator, cfg: *const cli_mod.Config, models_extras: []const models_mod.Entry) ProviderInfo {
    const model = cfg.model orelse "faux-1";
    return finalize(a, .{
        .provider_name = "faux",
        .api_tag = "faux",
        .model_id = model,
        .api_key = null,
        .auth_token = null,
        .base_url = null,
        .context_window = 1_000_000,
        .max_output = 8192,
        .capabilities = undefined,
    }, cfg, models_extras);
}

fn buildAnthropicConfig(a: std.mem.Allocator, cfg: *const cli_mod.Config, creds: *const ResolvedCredentials, settings: *const settings_mod.Settings, models_extras: []const models_mod.Entry) !ProviderInfo {
    if (creds.api_key == null and creds.auth_token == null) return error.MissingApiKey;
    const model = cfg.model orelse try a.dupe(u8, resolveAnthropicAlias(settings.default_model_anthropic));
    const resolved_model = resolveAnthropicAlias(model);
    return finalize(a, .{
        .provider_name = "anthropic",
        .api_tag = "anthropic-messages",
        .model_id = resolved_model,
        .api_key = creds.api_key,
        .auth_token = creds.auth_token,
        .base_url = null,
        .context_window = 1_000_000,
        .max_output = 8192,
        .capabilities = undefined,
    }, cfg, models_extras);
}

fn buildOpenaiConfig(a: std.mem.Allocator, cfg: *const cli_mod.Config, creds: *const ResolvedCredentials, settings: *const settings_mod.Settings, models_extras: []const models_mod.Entry) !ProviderInfo {
    if (creds.openai_api_key == null and creds.api_key == null) return error.MissingApiKey;
    const actual_key = creds.openai_api_key orelse creds.api_key;
    const model = cfg.model orelse try a.dupe(u8, settings.default_model_openai);
    return finalize(a, .{
        .provider_name = "openai",
        .api_tag = "openai-chat-completions",
        .model_id = model,
        .api_key = actual_key,
        .auth_token = null,
        .base_url = null,
        .context_window = 1_000_000,
        .max_output = 8192,
        .capabilities = undefined,
    }, cfg, models_extras);
}

fn buildGatewayConfig(a: std.mem.Allocator, cfg: *const cli_mod.Config, map: *const std.process.Environ.Map, creds: *const ResolvedCredentials, auth_state: ?auth_mod.Auth, models_extras: []const models_mod.Entry) !ProviderInfo {
    const gateway_file = if (auth_state) |as| as.get("gateway") else null;
    const base_url_str: ?[]const u8 = cfg.base_url orelse blk: {
        if (map.get("FRANKY_GATEWAY_URL")) |u| break :blk try a.dupe(u8, u);
        if (map.get("OPENAI_BASE_URL")) |u| break :blk try a.dupe(u8, u);
        break :blk null;
    };
    const effective_key: ?[]const u8 = cfg.api_key orelse creds.openai_api_key orelse blk: {
        if (map.get("FRANKY_GATEWAY_TOKEN")) |t| break :blk try a.dupe(u8, t);
        if (gateway_file) |rec| if (rec.api_key) |k| break :blk try a.dupe(u8, k);
        break :blk null;
    };
    const model = cfg.model orelse try a.dupe(u8, "gpt-4o");
    return finalize(a, .{
        .provider_name = "gateway",
        .api_tag = "openai-compatible-gateway",
        .model_id = model,
        .api_key = effective_key,
        .auth_token = cfg.auth_token,
        .base_url = base_url_str,
        .context_window = 1_000_000,
        .max_output = 8192,
        .capabilities = undefined,
    }, cfg, models_extras);
}

fn buildGeminiConfig(a: std.mem.Allocator, cfg: *const cli_mod.Config, creds: *const ResolvedCredentials, models_extras: []const models_mod.Entry) !ProviderInfo {
    const model = cfg.model orelse try a.dupe(u8, "gemini-2.0-flash");
    const actual_key = creds.gemini_api_key orelse
        if (cfg.api_key) |k| k else null;
    return finalize(a, .{
        .provider_name = "google-gemini",
        .api_tag = "google-gemini",
        .model_id = model,
        .api_key = actual_key,
        .auth_token = creds.gemini_auth_token,
        .base_url = null,
        .context_window = 1_000_000,
        .max_output = 8192,
        .capabilities = undefined,
    }, cfg, models_extras);
}

fn finalize(
    arena_alloc: std.mem.Allocator,
    info_in: ProviderInfo,
    cfg: *const cli_mod.Config,
    extras: []const models_mod.Entry,
) ProviderInfo {
    _ = arena_alloc;
    var info = info_in;
    if (models_mod.lookup(extras, info.model_id)) |entry| {
        info.context_window = entry.context_window;
        info.max_output = entry.max_output;
        info.capabilities = .{
            .vision = entry.capabilities.vision,
            .tool_use = entry.capabilities.tool_use,
            .reasoning = if (cfg.thinking != .off) true else entry.capabilities.reasoning,
            .cache = entry.capabilities.cache,
            .streaming = entry.capabilities.streaming,
        };
    } else {
        info.capabilities = .{
            .tool_use = true,
            .reasoning = cfg.thinking != .off,
        };
    }
    return info;
}

/// Resolve Anthropic model aliases (e.g. "sonnet" → "claude-sonnet-4-6").
pub fn resolveAnthropicAlias(input: []const u8) []const u8 {
    const aliases = [_]struct { []const u8, []const u8 }{
        .{ "opus", "claude-opus-4-6" },
        .{ "opus-4-6", "claude-opus-4-6" },
        .{ "opus-4.6", "claude-opus-4-6" },
        .{ "opus-4-7", "claude-opus-4-7" },
        .{ "opus-4.7", "claude-opus-4-7" },
        .{ "sonnet", "claude-sonnet-4-6" },
        .{ "sonnet-4-6", "claude-sonnet-4-6" },
        .{ "sonnet-4.6", "claude-sonnet-4-6" },
        .{ "haiku", "claude-haiku-4-5" },
        .{ "haiku-4-5", "claude-haiku-4-5" },
        .{ "haiku-4.5", "claude-haiku-4-5" },
    };
    for (aliases) |kv| {
        if (std.mem.eql(u8, input, kv[0])) return kv[1];
    }
    return input;
}

// ─── Path helpers ───────────────────────────────────────────────

fn authJsonPathFrom(
    arena_alloc: std.mem.Allocator,
    franky_home: ?[]const u8,
    home: ?[]const u8,
) !?[]const u8 {
    if (franky_home) |h| {
        return try std.fs.path.join(arena_alloc, &.{ h, "auth.json" });
    }
    if (home) |h| {
        return try std.fs.path.join(arena_alloc, &.{ h, ".franky", "auth.json" });
    }
    return null;
}

fn modelsJsonPathFrom(
    arena_alloc: std.mem.Allocator,
    franky_home: ?[]const u8,
    home: ?[]const u8,
) !?[]const u8 {
    if (franky_home) |h| {
        return try std.fs.path.join(arena_alloc, &.{ h, "models.json" });
    }
    if (home) |h| {
        return try std.fs.path.join(arena_alloc, &.{ h, ".franky", "models.json" });
    }
    return null;
}

fn readWholeFileOpt(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ?[]u8 {
    const cwd = std.Io.Dir.cwd();
    var f = cwd.openFile(io, path, .{}) catch return null;
    defer f.close(io);
    const len = f.length(io) catch return null;
    const buf = allocator.alloc(u8, @intCast(len)) catch return null;
    const n = f.readPositionalAll(io, buf, 0) catch {
        allocator.free(buf);
        return null;
    };
    return buf[0..n];
}

// ─── Pre-rendered review config block ─────────────────────────────
fn buildReviewConfigBlock(
    allocator: std.mem.Allocator,
    settings: *const settings_mod.Settings,
) !?[]u8 {
    if (settings.review_profiles.len == 0) return null;
    const ca = allocator;
    var pb: std.ArrayList(u8) = .empty;
    defer pb.deinit(ca);
    for (settings.review_profiles, 0..) |p, i| {
        if (i > 0) try pb.appendSlice(ca, ", ");
        try pb.appendSlice(ca, p);
    }
    const profiles_csv = try pb.toOwnedSlice(ca);
    defer ca.free(profiles_csv);
    return try std.fmt.allocPrint(
        ca,
        "## Review configuration\n" ++
            "profiles: {s}\n" ++
            "min_models: {d}\n" ++
            "max_models: {d}\n" ++
            "timeout_ms: {d}",
        .{
            profiles_csv,
            settings.review_min_models,
            settings.review_max_models,
            settings.review_timeout_ms,
        },
    );
}

// ─── Main resolve entry point ───────────────────────────────────

/// Resolve a complete configuration from CLI args, env, and settings.
///
/// This is the single entry point all four modes call. It:
/// 1. Applies env-var overrides to cfg fields still at default.
/// 2. Loads and applies settings.json layers.
/// 3. Resolves the provider (credentials, model, auth).
/// 4. Sets up the provider registry.
/// 5. Builds workspace, bash state, read ctx.
/// 6. Filters tools by role + tools_filter.
/// 7. Sets up permission store.
/// 8. Builds preset registry and loads extensions.
/// 9. Loads skills.
/// 10. Initializes guardrail state.
/// 11. Builds subagent context.
/// 12. Renders review config block.
///
/// Everything allocated is owned by the returned `ResolvedConfig.arena`
/// (or by the cfg arena, which outlives the config).
pub fn resolve(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: *cli_mod.Config,
    environ: std.process.Environ,
    environ_map: *std.process.Environ.Map,
    argv: []const []const u8,
) !ResolvedConfig {
    _ = argv; // needed only for proxy mode restart
    var arena = std.heap.ArenaAllocator.init(allocator);
    const a = arena.allocator();
    errdefer arena.deinit();

    // ── Step 1: Apply env-var overrides ──────────────────────────
    applyEnvOverrides(cfg, environ_map);

    // ── Step 2: Load settings + apply profile overlays ───────────
    var settings = try loadSettings(allocator, io, environ_map);
    defer settings.deinit();

    // ── Step 3: Resolve log level (caller uses this to init logger) ─
    const log_level = resolveLogLevel(cfg, environ_map);
    const log_file = resolveLogFile(cfg, environ_map);
    const http_trace_dir = resolveHttpTraceDir(cfg, environ_map);
    const log_per_session = resolveLogPerSession(cfg, environ_map);

    // ── Step 4: Apply settings overlays to cfg ──────────────────
    applyMaxTurnsSettingsOverlay(cfg, &settings);
    applyRetrySettingsOverlay(cfg, &settings);
    applyCompressionSettingsOverlay(cfg, &settings);

    // ── Step 5: Resolve provider ──────────────────────────────────
    const provider = try resolveProvider(allocator, io, cfg, environ_map);

    // ── Step 6: Register providers ────────────────────────────────
    var reg = ai.registry.Registry.init(allocator);
    errdefer reg.deinit();

    // Faux provider — arena-allocated so the registry's userdata pointer
    // remains valid after resolve() returns.
    const faux_ptr = try a.create(ai.providers.faux.FauxProvider);
    errdefer a.destroy(faux_ptr);
    faux_ptr.* = ai.providers.faux.FauxProvider.init(allocator);
    errdefer faux_ptr.deinit();
    try reg.register(.{
        .api = "faux",
        .provider = "faux",
        .stream_fn = fauxShim,
        .userdata = @ptrCast(faux_ptr),
    });
    try reg.register(.{
        .api = "anthropic-messages",
        .provider = "anthropic",
        .stream_fn = ai.providers.anthropic.streamFn,
    });
    try reg.register(.{
        .api = "openai-chat-completions",
        .provider = "openai",
        .stream_fn = ai.providers.openai_chat.streamFn,
    });
    try reg.register(.{
        .api = "openai-compatible-gateway",
        .provider = "gateway",
        .stream_fn = ai.providers.openai_gateway.streamFn,
    });
    try reg.register(.{
        .api = "google-gemini",
        .provider = "google-gemini",
        .stream_fn = ai.providers.google_gemini.streamFn,
    });

    // Faux provider seeding — use arena allocation so data survives resolve() return.
    if (std.mem.eql(u8, provider.provider_name, "faux")) {
        const faux_reply = try std.fmt.allocPrint(a, "you said: {s}", .{cfg.prompt});
        const faux_events = try a.alloc(ai.providers.faux.Event, 1);
        faux_events[0] = .{ .text = .{ .text = faux_reply, .chunk_size = 8 } };
        try faux_ptr.push(.{ .events = faux_events[0..] });
    }

    // ── Step 7: Workspace + env policy ───────────────────────────
    const workspace_root: ?[]const u8 = environ.getPosix("PWD");
    const workspace_state: ?*tools_mod.workspace.Workspace = if (workspace_root) |root| blk: {
        const ws = try a.create(tools_mod.workspace.Workspace);
        errdefer a.destroy(ws);
        ws.* = .{ .root = root, .host_env = environ_map };
        break :blk ws;
    } else null;

    const bash_state = try a.create(tools_mod.bash.SessionBashState);
    errdefer a.destroy(bash_state);
    bash_state.* = tools_mod.bash.SessionBashState.init(allocator);
    errdefer bash_state.deinit();
    const read_ctx = try a.create(tools_mod.read.ReadCtx);
    errdefer a.destroy(read_ctx);
    read_ctx.* = .{
        .workspace = workspace_state,
    };

    // Apply settings overlays to bash/read state
    applyBashSettingsOverlay(bash_state, &settings);
    applyReadSettingsOverlay(read_ctx, &settings);

    // ── Step 8: Build tool set ───────────────────────────────────
    const bash_ctx = try a.create(tools_mod.bash.BashCtx);
    errdefer a.destroy(bash_ctx);
    bash_ctx.* = .{
        .state = bash_state,
        .workspace = workspace_state,
    };
    const web_search_ctx = try a.create(tools_mod.web_search.WebSearchCtx);
    errdefer a.destroy(web_search_ctx);
    web_search_ctx.* = .{
        .environ_map = environ_map,
    };

    var startup_warnings: std.ArrayList([]const u8) = .empty;
    const base_tool_count: usize = 9;
    var all_tools: [11]at.AgentTool = undefined;
    {
        var i: usize = 0;
        // Common tools (always present)
        if (workspace_state) |ws| {
            all_tools[i] = tools_mod.read.toolWithCtx(read_ctx);
            i += 1;
            all_tools[i] = tools_mod.write.toolWithWorkspace(ws);
            i += 1;
            all_tools[i] = tools_mod.edit.toolWithWorkspace(ws);
            i += 1;
            all_tools[i] = tools_mod.bash.toolWithStateAndWorkspace(bash_ctx);
            i += 1;
            all_tools[i] = tools_mod.ls.toolWithWorkspace(ws);
            i += 1;
            all_tools[i] = tools_mod.find.toolWithWorkspace(ws);
            i += 1;
            all_tools[i] = tools_mod.grep.toolWithWorkspace(ws);
            i += 1;
            all_tools[i] = tools_mod.web_search.toolWithCtx(web_search_ctx);
            i += 1;
            all_tools[i] = tools_mod.web_fetch.toolWithCtx(web_search_ctx);
            i += 1;
        } else {
            all_tools[i] = tools_mod.read.tool();
            i += 1;
            all_tools[i] = tools_mod.write.tool();
            i += 1;
            all_tools[i] = tools_mod.edit.tool();
            i += 1;
            all_tools[i] = tools_mod.bash.toolWithState(bash_state);
            i += 1;
            all_tools[i] = tools_mod.ls.tool();
            i += 1;
            all_tools[i] = tools_mod.find.tool();
            i += 1;
            all_tools[i] = tools_mod.grep.tool();
            i += 1;
            all_tools[i] = tools_mod.web_search.toolWithCtx(web_search_ctx);
            i += 1;
            all_tools[i] = tools_mod.web_fetch.toolWithCtx(web_search_ctx);
            i += 1;
        }
    }
    const all_tools_slice = all_tools[0..base_tool_count];

    const active_role = if (cfg.role) |s|
        try role_mod.Role.fromString(s)
    else
        role_mod.Role.plan;
    const role_gate = try a.create(role_mod.RoleGate);
    errdefer a.destroy(role_gate);
    role_gate.* = role_mod.RoleGate.init(active_role);
    const role_filtered_tools = try role_mod.filterTools(allocator, all_tools_slice, role_gate.set);
    defer allocator.free(role_filtered_tools);

    // ── Step 9: Permission store ─────────────────────────────────
    const permission_store = try a.create(permissions_mod.Store);
    errdefer a.destroy(permission_store);
    permission_store.* = permissions_mod.Store.init(allocator);
    errdefer permission_store.deinit();
    try applyPermissionsSettingsOverlay(permission_store, &settings);
    const prompts_enabled = resolvePromptsDefault(cfg, &settings);
    if (cfg.yes) permission_store.yes_to_all = true;
    if (cfg.allow_tools_csv) |s| try permission_store.addAllowList(s);
    if (cfg.deny_tools_csv) |s| try permission_store.addDenyList(s);
    if (cfg.ask_tools_csv) |s| try permission_store.addAskList(s);
    try permissions_mod.maybeAttachPersistence(
        permission_store,
        cfg.remember_permissions,
        cfg.arena.allocator(),
        io,
        environ_map,
    );
    const session_gates = try a.create(permissions_mod.SessionGates);
    errdefer a.destroy(session_gates);
    session_gates.* = .{
        .role = role_gate,
        .permissions = if (prompts_enabled) permission_store else null,
    };

    // ── Step 10: Preset registry + extensions ────────────────────
    var preset_registry = tools_mod.subagent.PresetRegistry.init(allocator);
    errdefer preset_registry.deinit();
    try tools_mod.subagent.registerBuiltinPresets(&preset_registry);

    var ext_manager = extensions_mod.Manager.init(allocator);
    ext_manager.presets = &preset_registry;
    errdefer ext_manager.deinit();
    try ext_manager.loadFromConfig(io, cfg.extensions, ext_catalog.lookup);

    // ── Step 11: Build final tool list (role-filtered + extensions + built-in tools) ─
    const ext_tools = ext_manager.tools();
    const final_tools = blk: {
        const slice = try a.alloc(at.AgentTool, role_filtered_tools.len + ext_tools.len + 3);
        @memcpy(slice[0..role_filtered_tools.len], role_filtered_tools);
        if (ext_tools.len > 0) {
            @memcpy(slice[role_filtered_tools.len..][0..ext_tools.len], ext_tools);
        }
        // Add subagent, listPresets, and finishTask tools later
        // (they need subagent_ctx and guardrail_state which are built below).
        break :blk slice;
    };

    // ── Step 12: Guardrail state ─────────────────────────────────
    const guardrail_state = try a.create(agent.guardrails.GuardrailState);
    errdefer a.destroy(guardrail_state);
    guardrail_state.* = try agent.guardrails.GuardrailState.init(
        allocator,
        .{ .workspace_dir = workspace_root orelse "." },
        io,
    );
    errdefer guardrail_state.deinit();

    // ── Step 13: Subagent context ────────────────────────────────
    // Build the Ctx first, then wire in the tools that reference it.
    // `parent_session_dir` is late-bound by the mode after session init.
    const subagent_params_json = try tools_mod.subagent.buildParametersJson(a, &preset_registry);

    const subagent_ctx = try a.create(tools_mod.subagent.Ctx);
    errdefer a.destroy(subagent_ctx);
    subagent_ctx.* = .{
        .registry = &reg,
        .environ = environ,
        .environ_map = environ_map,
        .parent_tools = final_tools,
        .parent_role = active_role,
        .parent_profile = cfg.profile orelse "",
        .presets = &preset_registry,
        .parameters_json_owned = subagent_params_json,
        .permission_store = if (prompts_enabled) permission_store else null,
        .permission_prompter_slot = null,
        .parent_session_dir = null,
    };
    const all_final_tools = blk: {
        const base_len = role_filtered_tools.len + ext_tools.len;
        const slice = try a.alloc(at.AgentTool, base_len + 4);
        @memcpy(slice[0..role_filtered_tools.len], role_filtered_tools);
        if (ext_tools.len > 0) {
            @memcpy(slice[role_filtered_tools.len..][0..ext_tools.len], ext_tools);
        }
        slice[base_len] = tools_mod.subagent.toolWithCtx(subagent_ctx);
        slice[base_len + 1] = tools_mod.subagent.listPresetsToolWithCtx(&preset_registry);
        slice[base_len + 2] = guardrail_state.finishTaskTool();
        // ccr_retrieve tool — ctx is set by the mode driver after session creation
        slice[base_len + 3] = tools_mod.ccr_retrieve.toolWithCtx(null);
        break :blk slice;
    };

    // ── Step 14: Build review config block ───────────────────────
    const review_block = try buildReviewConfigBlock(a, &settings);

    // ── Step 15: Resolve retry policy ─────────────────────────────
    const retry_policy = resolveRetryPolicy(cfg, &settings);

    // ── Step 16: Resolve max_turns ────────────────────────────────
    const max_turns_val = resolveMaxTurns(cfg, environ_map) orelse @as(u32, 100);

    // ── Step 17: Build skills state (lightweight — no rendering) ─
    // Skills rendering happens in buildSystemPrompt which is called
    // separately by the mode. Here we just note that skills are loaded.
    const skills_state = SkillsState{
        .owned = false,
        .skills = .empty,
        .active = .empty,
    };

    return ResolvedConfig{
        .provider_name = provider.provider_name,
        .model_id = provider.model_id,
        .api_key = provider.api_key,
        .auth_token = provider.auth_token,
        .api_tag = provider.api_tag,
        .base_url = provider.base_url,
        .thinking_level = cfg.thinking,
        .context_window = provider.context_window,
        .max_output = provider.max_output,
        .capabilities = provider.capabilities,
        .connect_timeout_ms = resolveTimeouts(cfg, environ_map).connect_ms,
        .upload_timeout_ms = resolveTimeouts(cfg, environ_map).upload_ms,
        .first_byte_timeout_ms = resolveTimeouts(cfg, environ_map).first_byte_ms,
        .event_gap_timeout_ms = resolveTimeouts(cfg, environ_map).event_gap_ms,
        .text_tool_call_fallback = cfg.text_tool_call_fallback,
        .max_full_tool_results = settings.max_full_tool_results orelse 0,
        .registry = reg,
        .faux_provider = faux_ptr,
        .tools = all_final_tools,
        .permission_store = permission_store,
        .session_gates = session_gates,
        .preset_registry = preset_registry,
        .ext_manager = ext_manager,
        .skills = skills_state,
        .guardrail_state = guardrail_state,
        .bash_default_timeout_ms = settings.bash_timeout_ms,
        .read_max_bytes_without_limit = settings.read_max_bytes,
        .retry_policy = retry_policy,
        .max_turns = max_turns_val,
        .prompts_enabled = prompts_enabled,
        .workspace = workspace_state,
        .bash_state = bash_state,
        .read_ctx = read_ctx,
        .subagent_ctx = subagent_ctx,
        .log_level = log_level,
        .log_file = log_file,
        .http_trace_dir = http_trace_dir,
        .log_per_session = log_per_session,
        .startup_warnings = try startup_warnings.toOwnedSlice(a),
        .role_gate = role_gate,
        .active_role = active_role,
        .review_config_block = review_block,
        .compression = .{
            .enabled = cfg.compress,
            .min_bytes_to_compress = cfg.compress_min_bytes,
            .smart_crusher_enabled = cfg.compress_json,
            .log_compressor_enabled = cfg.compress_logs,
            .search_compressor_enabled = cfg.compress_search,
            .diff_compressor_enabled = cfg.compress_diff,
            .code_compressor_enabled = cfg.compress_code,
            .ccr_enabled = cfg.compress_ccr,
        },
        .arena = arena,
    };
}

// ─── Shim for faux provider ─────────────────────────────────────

fn fauxShim(ctx: ai.registry.StreamCtx) anyerror!void {
    const faux_ptr: *ai.providers.faux.FauxProvider = @ptrCast(@alignCast(ctx.userdata.?));
    try faux_ptr.runSync(ctx.io, ctx.context, ctx.out);
}

// ─── Tests ─────────────────────────────────────────────────────

const testing = std.testing;
const test_h = @import("../test_helpers.zig");

test "resolveLogLevel: CLI flag wins over env" {
    var map = std.process.Environ.Map.init(testing.allocator);
    defer map.deinit();
    try map.put("FRANKY_LOG", "warn");

    const cfg = cli_mod.Config{
        .log_level = "debug",
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
    };
    defer cfg.arena.deinit();

    try testing.expectEqual(ai.log.Level.debug, resolveLogLevel(&cfg, &map));
}

test "resolveLogLevel: env var fallback" {
    var map = std.process.Environ.Map.init(testing.allocator);
    defer map.deinit();
    try map.put("FRANKY_LOG", "info");

    const cfg = cli_mod.Config{
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
    };
    defer cfg.arena.deinit();

    try testing.expectEqual(ai.log.Level.info, resolveLogLevel(&cfg, &map));
}

test "resolveLogLevel: default is warn" {
    var map = std.process.Environ.Map.init(testing.allocator);
    defer map.deinit();

    const cfg = cli_mod.Config{
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
    };
    defer cfg.arena.deinit();

    try testing.expectEqual(ai.log.Level.warn, resolveLogLevel(&cfg, &map));
}

test "isLoopbackBaseUrl detects localhost" {
    try testing.expect(isLoopbackBaseUrl("http://localhost:11434/v1"));
    try testing.expect(isLoopbackBaseUrl("http://127.0.0.1:8000"));
    try testing.expect(isLoopbackBaseUrl("http://[::1]:8080"));
    try testing.expect(!isLoopbackBaseUrl("https://api.example.com"));
    try testing.expect(!isLoopbackBaseUrl(null));
}

test "resolveAnthropicAlias" {
    try testing.expectEqualStrings("claude-sonnet-4-6", resolveAnthropicAlias("sonnet"));
    try testing.expectEqualStrings("claude-opus-4-6", resolveAnthropicAlias("opus"));
    try testing.expectEqualStrings("claude-haiku-4-5", resolveAnthropicAlias("haiku"));
    try testing.expectEqualStrings("custom-model", resolveAnthropicAlias("custom-model"));
}
