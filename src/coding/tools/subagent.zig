//! subagent tool — v1.24.0 (`v1.24-design.md`).
//!
//! Spawns an isolated sub-agent with its own model + provider,
//! runs it to completion, returns the final assistant text +
//! metadata as a `ToolResult`. The parent LLM drives delegation
//! via tool calls — no separate code-driven pipeline path.
//!
//! Wire shape:
//!   - `tool()` returns an unconfigured tool that errors at
//!     execute time. Use `toolWithCtx(*const Ctx)` from the mode
//!     drivers — they have the SessionGates / registry / parent
//!     tool list / environ_map needed to spawn a real sub-agent.
//!   - Sub-agents do NOT receive the `subagent` tool itself
//!     (depth-1 enforcement, §3.4). Implementation: filter the
//!     parent tool list by name when building the sub's tools.
//!   - Per-sub-agent timeout via a supervisor thread that fires
//!     the sub's `Cancel` when EITHER `timeout_ms` elapses OR
//!     the parent's cancel fires (cascade abort, §3.10).
//!   - Permission inheritance §3.5 (option C): fresh
//!     `SessionGates` per sub-agent, shared `Store` + `Prompter`
//!     pointers from the parent. Always-allow decisions persist
//!     across siblings; per-call `ask` resolutions stay local.
//!   - Role demotion only (§3.5): `parent.atLeast(sub)` must
//!     hold; promotion errors with `role_promotion_denied`.
//!
//! Result shape on success — JSON serialized into a single
//! `text` content block (Anthropic-friendly):
//!   { "ok": true, "final_text": "...", "turn_count": 4,
//!     "tool_call_count": 7, "duration_ms": 8231,
//!     "session_id": "..." }
//!
//! Result shape on failure:
//!   { "ok": false, "error_kind": "<kind>",
//!     "error_message": "...", "hint": "...",
//!     "partial_text": "...optional...",
//!     "turn_count": <int> }
//!
//! `error_kind` values per design §3.8:
//!   profile_not_found / role_promotion_denied / timeout /
//!   max_turns_exceeded / agent_error / aborted / config_error.

const std = @import("std");
const ct = @import("../types.zig");
const at = ct.agent.types;
const ai = ct.ai;
const agent_mod = @import("../../agent/agent.zig");
const loop_mod = @import("../../agent/loop.zig");
const cli_mod = @import("../config/cli.zig");
const profiles_mod = @import("../config/profiles.zig");
const print_mod = @import("../modes/print.zig");
const role_mod = @import("../security/role.zig");
const permissions_mod = @import("../security/permissions.zig");
const session_mod = @import("../session/mod.zig");
const truncate_mod = @import("truncate.zig");
const common = @import("common.zig");
const workspace_mod = @import("workspace.zig");

pub const tool_name: []const u8 = "subagent";

pub const default_timeout_ms: u64 = 1_800_000; // 30 min — design §3.6
pub const max_timeout_ms: u64 = 7_200_000; //     2 h
pub const min_timeout_ms: u64 = 1_000; //         1 s
pub const default_max_turns: u32 = 20; //         design §3.7

/// v1.24.4 — process-wide concurrency cap on in-flight sub-agent
/// runs. The parent's parallel-homogeneous tool executor fans
/// out every `subagent` call in a turn at once; without a cap a
/// 7+ way fan-out routinely 429s the upstream gateway. Set to
/// 10 to leave headroom while keeping each gateway's per-token
/// quota manageable. Configurable knob deferred to v2 — most
/// users either run 1-3 concurrent sub-agents (well under the
/// cap, no effect) or need a different default per-provider
/// (Cerebras: ~5) which a single global doesn't
/// capture cleanly.
pub const concurrency_cap: u32 = 10;
var concurrency_mutex: std.Io.Mutex = .init;
var concurrency_active: u32 = 0;
var concurrency_cond: std.Io.Condition = .init;

// ─── §6.6 — sub-agent progress forwarding ─────────────────────────

/// Per-call state for `subagentProgressHandler`. Lives on the
/// `runSubagent` stack frame — valid for the lifetime of the
/// sub-agent (stack-allocated + unsubscribed before frame exits).
const ForwardState = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    /// Borrowed from `runSubagent`'s stack frame.
    call_id: []const u8,
    ctx: *const Ctx,
    /// Tracks tool names by call_id so `tool_execution_end` can emit
    /// the name (not present in the end event payload). Guarded by
    /// the agent's `subs_mutex` (handler fires under it). The map
    /// owns both keys and values (duped on insert, freed on remove).
    tool_names: std.StringHashMapUnmanaged([]const u8),
    /// Mutex protecting `tool_names` from concurrent subagent tool
    /// executions (parallel tools call the handler concurrently).
    names_mutex: std.Io.Mutex,

    fn deinit(self: *ForwardState) void {
        var it = self.tool_names.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.tool_names.deinit(self.allocator);
    }
};

/// JSON-escape a string into a fixed-size stack buffer. Returns the
/// escaped slice, or null if the buffer was too small. Escapes `"`,
/// `\`, `\n`, `\r`, `\t`, and control chars as `\uXXXX`.
fn jsonEscapeInto(buf: []u8, s: []const u8) ?[]u8 {
    var out: usize = 0;
    for (s) |c| {
        const need: usize = switch (c) {
            '"', '\\' => 2,
            '\n', '\r', '\t' => 2,
            0...0x07, 0x0b, 0x0e...0x1f => 6,
            else => 1,
        };
        if (out + need > buf.len) return null;
        switch (c) {
            '"' => {
                buf[out] = '\\';
                buf[out + 1] = '"';
            },
            '\\' => {
                buf[out] = '\\';
                buf[out + 1] = '\\';
            },
            '\n' => {
                buf[out] = '\\';
                buf[out + 1] = 'n';
            },
            '\r' => {
                buf[out] = '\\';
                buf[out + 1] = 'r';
            },
            '\t' => {
                buf[out] = '\\';
                buf[out + 1] = 't';
            },
            0...0x07, 0x0b, 0x0e...0x1f => {
                _ = std.fmt.bufPrint(buf[out..][0..6], "\\u{x:0>4}", .{c}) catch unreachable;
            },
            else => {
                buf[out] = c;
            },
        }
        out += need;
    }
    return buf[0..out];
}

/// Allocate an escaped copy of `s` using `allocator`.
fn jsonEscapeAlloc(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    // Worst case: every byte expands to 6 chars (\uXXXX).
    const cap = s.len * 6;
    const buf = try allocator.alloc(u8, cap);
    const result = jsonEscapeInto(buf, s) orelse unreachable;
    return allocator.realloc(buf, result.len);
}

/// `SubscribeHandler` fired synchronously (under `subs_mutex`) from
/// the sub-agent's worker thread for every `AgentEvent`. Translates
/// structural events into compact `update_json` blobs and calls
/// `ctx.progress_fn`.
fn subagentProgressHandler(userdata: ?*anyopaque, ev: at.AgentEvent) void {
    const fwd: *ForwardState = @ptrCast(@alignCast(userdata.?));
    const ctx = fwd.ctx;
    const progress_fn = ctx.progress_fn orelse return;

    // Fixed-size stack buffer for events with bounded size.
    var stack_buf: [512]u8 = undefined;

    switch (ev) {
        .turn_start, .turn_end, .provider_retry => {},
        .tool_execution_start => |s| {
            // Store name by call_id so tool_execution_end can include it.
            fwd.names_mutex.lockUncancelable(fwd.io);
            const key = fwd.allocator.dupe(u8, s.call_id) catch null;
            const val = fwd.allocator.dupe(u8, s.name) catch null;
            if (key != null and val != null) {
                fwd.tool_names.put(fwd.allocator, key.?, val.?) catch {
                    fwd.allocator.free(key.?);
                    fwd.allocator.free(val.?);
                };
            } else {
                if (key) |k| fwd.allocator.free(k);
                if (val) |v| fwd.allocator.free(v);
            }
            fwd.names_mutex.unlock(fwd.io);
            // Truncate args to 80 chars for the progress preview, then
            // JSON-escape into a local buffer before embedding in JSON.
            const max_args: usize = 80;
            const args_src = if (s.args_json.len > max_args) s.args_json[0..max_args] else s.args_json;
            const truncated = s.args_json.len > max_args;
            var args_esc_buf: [512]u8 = undefined;
            const args_esc = jsonEscapeInto(&args_esc_buf, args_src) orelse "";
            var ts_buf: [1024]u8 = undefined;
            const json = std.fmt.bufPrint(
                &ts_buf,
                "{{\"kind\":\"tool_start\",\"name\":\"{s}\",\"cid\":\"{s}\",\"args\":\"{s}{s}\"}}",
                .{ s.name, s.call_id, args_esc, if (truncated) "..." else "" },
            ) catch return;
            progress_fn(ctx.progress_userdata, fwd.call_id, json);
        },
        .tool_execution_end => |e| {
            // Recover name from our tracking map (tool_execution_end
            // doesn't carry the tool name in its payload).
            fwd.names_mutex.lockUncancelable(fwd.io);
            const maybe_name = fwd.tool_names.get(e.call_id);
            // Copy the name before unlocking so we can use it after.
            const name_copy: []const u8 = if (maybe_name) |n|
                fwd.allocator.dupe(u8, n) catch ""
            else
                "";
            // Remove the entry — this call is done.
            if (fwd.tool_names.fetchRemove(e.call_id)) |kv| {
                fwd.allocator.free(kv.key);
                fwd.allocator.free(kv.value);
            }
            fwd.names_mutex.unlock(fwd.io);
            defer if (name_copy.len > 0) fwd.allocator.free(name_copy);

            const json = std.fmt.bufPrint(
                &stack_buf,
                "{{\"kind\":\"tool_end\",\"name\":\"{s}\",\"cid\":\"{s}\",\"ok\":{s}}}",
                .{ name_copy, e.call_id, if (!e.result.is_error) "true" else "false" },
            ) catch return;
            progress_fn(ctx.progress_userdata, fwd.call_id, json);
        },
        .agent_error => |d| {
            const escaped = jsonEscapeAlloc(fwd.allocator, d.message) catch return;
            defer fwd.allocator.free(escaped);
            const json = std.fmt.allocPrint(
                fwd.allocator,
                "{{\"kind\":\"error\",\"msg\":\"{s}\"}}",
                .{escaped},
            ) catch return;
            defer fwd.allocator.free(json);
            progress_fn(ctx.progress_userdata, fwd.call_id, json);
        },
        .message_update => |m| {
            if (!ctx.verbose_progress) return;
            switch (m) {
                .text => |t| {
                    const escaped = jsonEscapeAlloc(fwd.allocator, t.delta) catch return;
                    defer fwd.allocator.free(escaped);
                    const json = std.fmt.allocPrint(
                        fwd.allocator,
                        "{{\"kind\":\"text_delta\",\"block\":{d},\"delta\":\"{s}\"}}",
                        .{ t.block_index, escaped },
                    ) catch return;
                    defer fwd.allocator.free(json);
                    progress_fn(ctx.progress_userdata, fwd.call_id, json);
                },
                .thinking => |t| {
                    const escaped = jsonEscapeAlloc(fwd.allocator, t.delta) catch return;
                    defer fwd.allocator.free(escaped);
                    const json = std.fmt.allocPrint(
                        fwd.allocator,
                        "{{\"kind\":\"thinking_delta\",\"block\":{d},\"delta\":\"{s}\"}}",
                        .{ t.block_index, escaped },
                    ) catch return;
                    defer fwd.allocator.free(json);
                    progress_fn(ctx.progress_userdata, fwd.call_id, json);
                },
                .toolcall_args => {}, // not forwarded
            }
        },
        // Never forwarded.
        .message_start,
        .message_end,
        .tool_execution_update,
        .tool_permission_request,
        .agent_interrupted,
        => {},
    }
}

// ─── preset types ──────────────────────────────────────────────────

pub const SafetyClaims = struct {
    /// Truncate sub-agent final_text to this many bytes (applied on
    /// top of the global `final_text_max_bytes` cap — whichever is
    /// lower wins). Uses the existing truncate primitives.
    max_result_bytes: ?u32 = null,
    /// Advisory — declared for future discovery surface / audit.
    read_only: bool = false,
    requires_sandbox: bool = false,
    max_calls_per_minute: ?u32 = null,
};

pub const Preset = struct {
    name: []const u8,
    /// One-line purpose (≤100 chars). Returned by list_subagent_presets.
    description: []const u8,
    /// Default profile name. Empty string means "inherit parent profile".
    default_profile: []const u8,
    default_role: role_mod.Role,
    default_system_prompt: []const u8,
    /// Returns the sub-agent's tool list, selected from `parent_tools`
    /// (already wired by the mode driver — ReadCtx, BashCtx, etc.).
    /// Must NOT include the `subagent` tool (depth-1).
    build_tools: *const fn (
        allocator: std.mem.Allocator,
        parent_tools: []const at.AgentTool,
    ) anyerror![]at.AgentTool,
    safety: SafetyClaims = .{},
};

pub const PresetRegistry = struct {
    allocator: std.mem.Allocator,
    presets: std.StringArrayHashMapUnmanaged(Preset) = .empty,

    pub fn init(allocator: std.mem.Allocator) PresetRegistry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *PresetRegistry) void {
        self.presets.deinit(self.allocator);
    }

    pub fn register(self: *PresetRegistry, p: Preset) !void {
        const gop = try self.presets.getOrPut(self.allocator, p.name);
        if (gop.found_existing) {
            ai.log.log(.warn, "subagent", "preset-registry", "preset '{s}' overrides existing entry", .{p.name});
        }
        gop.value_ptr.* = p;
    }

    pub fn get(self: *const PresetRegistry, name: []const u8) ?Preset {
        return self.presets.get(name);
    }

    /// Returns a deep copy of the registry. Every parallel subagent
    /// call clones its own copy so concurrent hash-map reads don't
    /// race (v1.28.1 race fix — same pattern as cloneEnvironMap).
    /// The clone owns its allocated memory; caller must deinit.
    pub fn clone(self: *const PresetRegistry, allocator: std.mem.Allocator) !PresetRegistry {
        var out = PresetRegistry.init(allocator);
        errdefer out.deinit();
        var it = self.presets.iterator();
        while (it.next()) |entry| {
            try out.register(entry.value_ptr.*);
        }
        return out;
    }
};

// ─── preset builders ───────────────────────────────────────────────

fn selectTools(
    allocator: std.mem.Allocator,
    parent_tools: []const at.AgentTool,
    names: []const []const u8,
) ![]at.AgentTool {
    var out = try allocator.alloc(at.AgentTool, names.len);
    var n: usize = 0;
    for (names) |want| {
        for (parent_tools) |t| {
            if (std.mem.eql(u8, t.name, want)) {
                out[n] = t;
                n += 1;
                break;
            }
        }
    }
    return allocator.realloc(out, n);
}

const research_tool_names = [_][]const u8{ "read", "ls", "find", "grep", "web_search", "web_fetch" };
const diff_review_tool_names = [_][]const u8{};
const file_ops_tool_names = [_][]const u8{ "read", "write", "edit", "ls", "find", "grep" };
const bash_runner_tool_names = [_][]const u8{ "bash", "ls", "find", "grep" };

fn buildResearchTools(alloc: std.mem.Allocator, parent: []const at.AgentTool) ![]at.AgentTool {
    return selectTools(alloc, parent, &research_tool_names);
}

fn buildCodeAuditTools(alloc: std.mem.Allocator, parent: []const at.AgentTool) ![]at.AgentTool {
    return selectTools(alloc, parent, &research_tool_names);
}

fn buildDiffReviewTools(alloc: std.mem.Allocator, parent: []const at.AgentTool) ![]at.AgentTool {
    return selectTools(alloc, parent, &diff_review_tool_names);
}

fn buildFileOpsTools(alloc: std.mem.Allocator, parent: []const at.AgentTool) ![]at.AgentTool {
    return selectTools(alloc, parent, &file_ops_tool_names);
}

fn buildBashRunnerTools(alloc: std.mem.Allocator, parent: []const at.AgentTool) ![]at.AgentTool {
    return selectTools(alloc, parent, &bash_runner_tool_names);
}

pub fn registerBuiltinPresets(reg: *PresetRegistry) !void {
    try reg.register(.{
        .name = "research",
        .description = "Reads files, greps for patterns, summarises findings within the workspace.",
        .default_profile = "ollama-cloud/deepseek-v4-pro:cloud",
        .default_role = .read,
        .default_system_prompt =
        \\You are a research sub-agent. Your job is to read, search, and summarise.
        \\You have read, ls, find, and grep. Do NOT write or modify files.
        \\When finished, write your final answer as a clear, self-contained summary.
        ,
        .build_tools = buildResearchTools,
        .safety = .{ .read_only = true },
    });
    try reg.register(.{
        .name = "code-audit",
        .description = "Audits a stated quality or security concern read-only across the workspace.",
        .default_profile = "ollama-cloud/deepseek-v4-pro:cloud",
        .default_role = .read,
        .default_system_prompt =
        \\You are a code-audit sub-agent. Focus on the single concern stated in the prompt.
        \\You have read, ls, find, and grep. Do NOT write or modify files.
        \\Report findings as a structured list with file paths and line references.
        ,
        .build_tools = buildCodeAuditTools,
        .safety = .{ .read_only = true },
    });
    try reg.register(.{
        .name = "diff-review",
        .description = "Reviews a diff pasted in the prompt — has NO file tools (works from prompt text only).",
        .default_profile = "ollama-cloud/deepseek-v4-pro:cloud",
        .default_role = .read,
        .default_system_prompt =
        \\You are a diff-review sub-agent. You have NO file-read tools.
        \\Analyse the diff text in the prompt above. Identify correctness,
        \\security, and performance issues. Report each finding as:
        \\file:line — [severity] description
        \\Be concise. Omit style nits.
        ,
        .build_tools = buildDiffReviewTools,
        .safety = .{ .read_only = true },
    });
    try reg.register(.{
        .name = "file-ops",
        .description = "Performs targeted file edits given clear instructions.",
        .default_profile = "ollama-cloud/deepseek-v4-pro:cloud",
        .default_role = .plan,
        .default_system_prompt =
        \\You are a file-ops sub-agent. Apply the edits described in the prompt exactly.
        \\You have read, write, edit, and ls. Prefer edit over write for existing files.
        \\When finished, confirm what you changed.
        ,
        .build_tools = buildFileOpsTools,
    });
    try reg.register(.{
        .name = "bash-runner",
        .description = "Runs a bounded shell task and reports stdout, stderr, and exit code.",
        .default_profile = "ollama-cloud/deepseek-v4-pro:cloud",
        .default_role = .code,
        .default_system_prompt =
        \\You are a bash-runner sub-agent. Execute the shell task described in the prompt.
        \\You have bash and ls. Keep commands focused and report results clearly.
        ,
        .build_tools = buildBashRunnerTools,
    });
}

// ─── dynamic parameters_json ───────────────────────────────────────

/// Build the `parameters_json` string for the `subagent` tool from
/// the registered preset names. Called once at session-init; the
/// result is stored on `Ctx` and freed by the mode driver.
pub fn buildParametersJson(
    allocator: std.mem.Allocator,
    registry: *const PresetRegistry,
) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator,
        \\{"type":"object","required":["preset","prompt"],"properties":{
        \\"preset":{"type":"string","enum":[
    );
    var it = registry.presets.iterator();
    var first = true;
    while (it.next()) |entry| {
        if (!first) try buf.append(allocator, ',');
        first = false;
        try buf.append(allocator, '"');
        try buf.appendSlice(allocator, entry.key_ptr.*);
        try buf.append(allocator, '"');
    }
    try buf.appendSlice(allocator,
        \\],"description":"Sub-agent preset. Call list_subagent_presets to see descriptions."},
        \\"profile":{"type":"string","description":"Optional profile override (model + provider). Defaults to the preset's default_profile."},
        \\"prompt":{"type":"string","description":"The instruction the sub-agent will run. Self-contained — sub-agent has no access to parent's transcript."},
        \\"timeout_ms":{"type":"integer","minimum":1000,"maximum":7200000,"description":"Wall-clock timeout (default 1800000 = 30 min, max 7200000 = 2 h)."},
        \\"max_turns":{"type":"integer","minimum":1,"description":"Hard cap on agent-loop turns (default 20)."},
        \\"role":{"type":"string","enum":["read","plan","code","full"],"description":"Capability role override (defaults to preset's default_role; demotion only)."},
        \\"system_prompt":{"type":"string","description":"Optional override for the sub-agent's system prompt."},
        \\"context_file":{"type":"string","description":"Optional path to a file whose contents are appended to `prompt` server-side before spawning the sub-agent. Use this for large content (e.g. a diff > ~10 KB) instead of inlining it into `prompt` — the parent's JSON string emission is unreliable for long payloads. Path is resolved against the workspace root with the same path-safety as the `read` tool; max 256 KB."}
        \\}}
    );
    return buf.toOwnedSlice(allocator);
}

// ─── list_subagent_presets tool ────────────────────────────────────

pub const list_presets_tool_name: []const u8 = "list_subagent_presets";

const list_presets_params_json: []const u8 =
    \\{"type":"object","properties":{},"required":[]}
;

pub fn listPresetsToolWithCtx(registry: *const PresetRegistry) at.AgentTool {
    return .{
        .name = list_presets_tool_name,
        .description = "List available sub-agent presets (with their purpose, default profile, and default role) plus all available profile names you can use with the `profile` parameter.",
        .parameters_json = list_presets_params_json,
        .execution_mode = .sequential,
        .ctx = @ptrCast(@constCast(registry)),
        .execute = executeListPresets,
    };
}

fn executeListPresets(
    self: *const at.AgentTool,
    allocator: std.mem.Allocator,
    io: std.Io,
    call_id: []const u8,
    args_json: []const u8,
    cancel: *ai.stream.Cancel,
    on_update: at.OnUpdate,
) anyerror!at.ToolResult {
    _ = call_id;
    _ = args_json;
    _ = cancel;
    _ = on_update;

    const registry: *const PresetRegistry = @ptrCast(@alignCast(self.ctx.?));

    // Compute available profiles — same approach as buildSubagentHint.
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    const profiles_csv = profiles_mod.listProfileNamesCSV(allocator, io, &env_map) catch "";
    defer if (profiles_csv.len > 0) allocator.free(profiles_csv);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.append(allocator, '{');

    // ── presets array ──
    try buf.appendSlice(allocator, "\"presets\":[");
    var it = registry.presets.iterator();
    var first = true;
    while (it.next()) |entry| {
        if (!first) try buf.append(allocator, ',');
        first = false;
        const p = entry.value_ptr.*;
        try buf.appendSlice(allocator, "{\"name\":");
        try ai.utils.appendJsonStr(&buf, allocator, p.name);
        try buf.appendSlice(allocator, ",\"description\":");
        try ai.utils.appendJsonStr(&buf, allocator, p.description);
        try buf.appendSlice(allocator, ",\"default_profile\":");
        try ai.utils.appendJsonStr(&buf, allocator, p.default_profile);
        try buf.appendSlice(allocator, ",\"default_role\":");
        try ai.utils.appendJsonStr(&buf, allocator, p.default_role.toString());
        try buf.appendSlice(allocator, ",\"read_only\":");
        try buf.appendSlice(allocator, if (p.safety.read_only) "true" else "false");
        try buf.append(allocator, '}');
    }
    try buf.append(allocator, ']');

    // ── available_profiles (comma-separated) ──
    try buf.appendSlice(allocator, ",\"available_profiles\":");
    try ai.utils.appendJsonStr(&buf, allocator, profiles_csv);

    try buf.append(allocator, '}');

    const text = try buf.toOwnedSlice(allocator);
    var content = try allocator.alloc(ai.types.ContentBlock, 1);
    content[0] = .{ .text = .{ .text = text } };
    return .{ .content = content, .is_error = false };
}

// ─── static fallback parameters_json (unconfigured tool only) ──────

const parameters_json_unconfigured: []const u8 =
    \\{"type":"object","required":["preset","prompt"],"properties":{
    \\"preset":{"type":"string","description":"Sub-agent preset (not yet configured — call list_subagent_presets)."},
    \\"prompt":{"type":"string","description":"The instruction the sub-agent will run."}
    \\}}
;

/// Configuration handed to `toolWithCtx`. Mode drivers build this
/// at session-init time. Borrowed pointers — caller owns
/// lifetimes; ctx must outlive any in-flight subagent execute call.
pub const Ctx = struct {
    /// Provider registry the sub-agent will dispatch through. The
    /// SAME registry as the parent — sub-agents share the
    /// pre-registered streamFn entries.
    registry: *const ai.registry.Registry,
    /// Parent's environ — passed to `applyProfile` for `${VAR}`
    /// interpolation and to `resolveProviderIo` for credential
    /// lookup. Same `std.process.Environ` the parent runs against.
    environ: std.process.Environ,
    /// Mutable env map for `applyProfile` (it's an in-place
    /// overlay). Borrowed.
    environ_map: *std.process.Environ.Map,
    /// Parent's tools — passed to preset.build_tools so builders
    /// can filter already-wired tools (ReadCtx, BashCtx, etc.)
    /// by name. Also used as the fallback tool list when no
    /// preset registry is set (back-compat). Borrowed.
    parent_tools: []const at.AgentTool,
    /// Parent's role. Sub-agents demote only — promotion errors.
    parent_role: role_mod.Role,
    /// Profile name the parent session was started with (the
    /// --profile flag value). Empty string when the parent used
    /// no profile. Presets with `default_profile = ""` inherit
    /// this so they use the operator's chosen provider.
    parent_profile: []const u8 = "",
    /// Preset registry — frozen at session-init. Presets are
    /// looked up here on every `subagent` tool call.
    presets: *const PresetRegistry,
    /// Dynamic parameters_json built from the registry at session-
    /// init. Owned by the mode driver; freed after the session ends.
    parameters_json_owned: []const u8,
    /// Shared `Store` (always-allow / always-deny database) for
    /// permission inheritance per design §3.5. Optional — when
    /// null, sub-agents run without permission gating.
    /// v1.24.3 — automatically dropped at sub-agent spawn time
    /// when no live prompter is available (see
    /// `permission_prompter_slot`). Trust boundary: the parent
    /// already approved the `subagent` tool call.
    permission_store: ?*permissions_mod.Store,
    /// v1.24.3 — pointer-to-slot for the parent's *dynamic*
    /// prompter. The slot itself outlives ctx (it's a struct
    /// field on the mode-driver session); the `?*Prompter` value
    /// inside flips per-turn (proxy/rpc set it during runPrompt
    /// and clear it after). Reading at sub-agent spawn time gets
    /// whatever is current then.
    /// - Set in proxy/rpc to `&session.current_prompter`.
    /// - Null in print mode (no interactive prompter exists).
    /// When the slot derefs to null, the sub-agent's
    /// `permission_store` is dropped too (no path to resolve
    /// `ask` decisions → would deadlock; un-gate instead).
    permission_prompter_slot: ?*const ?*permissions_mod.PermissionPrompter = null,
    /// Parent's session directory. Sub-agents persist their
    /// transcripts under `<parent_session_dir>/subagents/<call_id>/`.
    /// When null, persistence is skipped (e.g. `--no-session`).
    parent_session_dir: ?[]const u8,
    /// v1.31.0 — workspace root for `context_file` path-safety.
    /// When set, `context_file` paths are canonicalized against this
    /// root (same `workspace.canonicalizeOrError` the `read` tool
    /// uses). When null, `context_file` paths are read directly
    /// against CWD (degraded safety — for back-compat with mode
    /// drivers not yet wired). Borrowed pointer; must outlive any
    /// in-flight subagent execute call.
    workspace: ?*const workspace_mod.Workspace = null,
    /// Faux provider for tests — the sub-agent's registry needs
    /// `userdata` matching what the parent's `faux` registration
    /// uses. v1.24.0 just passes the same registry through; this
    /// field is reserved for future per-sub-agent isolation.
    faux_userdata: ?*anyopaque = null,

    // ── §6.6 — sub-agent progress forwarding ──────────────────────
    //
    // When set, `subagentProgressHandler` subscribes to the sub-agent
    // and calls this function for every forwarded event. Must be
    // thread-safe — the callback fires from the sub-agent's worker
    // thread. Null → no forwarding (default, backward-compatible).
    /// Called from the sub-agent's worker thread for each forwarded
    /// event. Must be thread-safe. Null → no forwarding.
    progress_fn: ?*const fn (userdata: ?*anyopaque, call_id: []const u8, update_json: []const u8) void = null,
    progress_userdata: ?*anyopaque = null,
    /// When true, also forward message_update (text + thinking) deltas.
    /// Default false — structural events only.
    verbose_progress: bool = false,
};

/// Unconfigured factory. The execute path errors with
/// `config_error` when called without ctx. Useful for the rare
/// caller (some tests) that wants a plain tool stub.
pub fn tool() at.AgentTool {
    return .{
        .name = tool_name,
        .description = "Spawn an isolated sub-agent with its own model + provider, run it to completion, return the final assistant message. NOT configured — wire via toolWithCtx.",
        .parameters_json = parameters_json_unconfigured,
        .execution_mode = .parallel,
        .execute = executeUnconfigured,
    };
}

pub fn toolWithCtx(ctx: *const Ctx) at.AgentTool {
    return .{
        .name = tool_name,
        .description = "Spawn an isolated sub-agent with its own model + tool set, run it to completion, return the final assistant message. Pick a preset to choose the sub-agent's purpose and tools. Call list_subagent_presets to see what is available.",
        .parameters_json = ctx.parameters_json_owned,
        .execution_mode = .parallel,
        .ctx = @ptrCast(@constCast(ctx)),
        .execute = executeWithCtx,
    };
}

// ─── execute paths ─────────────────────────────────────────────────

fn executeUnconfigured(
    self: *const at.AgentTool,
    allocator: std.mem.Allocator,
    io: std.Io,
    call_id: []const u8,
    args_json: []const u8,
    cancel: *ai.stream.Cancel,
    on_update: at.OnUpdate,
) anyerror!at.ToolResult {
    _ = self;
    _ = io;
    _ = args_json;
    _ = cancel;
    _ = on_update;
    return errorResult(allocator, .config_error, "subagent tool is not configured: register via toolWithCtx in the mode driver", .{ .spawn_id = call_id });
}

fn executeWithCtx(
    self: *const at.AgentTool,
    allocator: std.mem.Allocator,
    io: std.Io,
    call_id: []const u8,
    args_json: []const u8,
    cancel: *ai.stream.Cancel,
    on_update: at.OnUpdate,
) anyerror!at.ToolResult {
    _ = on_update;
    const ctx_ptr = self.ctx orelse {
        return errorResult(allocator, .config_error, "subagent tool ctx pointer is null", .{ .spawn_id = call_id });
    };
    const ctx: *const Ctx = @ptrCast(@alignCast(ctx_ptr));

    // runSubagent's inferred error set is `error{OutOfMemory}` —
    // every other failure mode is captured as a structured
    // ToolResult inside. Propagate OOM (the loop will surface it
    // as an `agent_error`); everything else returns a result.
    return try runSubagent(allocator, io, call_id, args_json, cancel, ctx);
}

// ─── core run ──────────────────────────────────────────────────────

const ParsedArgs = struct {
    preset: []const u8,
    profile: ?[]const u8,
    prompt: []const u8,
    timeout_ms: u64,
    max_turns: u32,
    role: ?role_mod.Role,
    system_prompt: ?[]const u8,
    /// v1.31.0 — optional path to a file whose contents are appended
    /// to `prompt` server-side before spawning the sub-agent. Lets the
    /// parent pass a large diff/context by path instead of inlining
    /// tens of KB into the JSON `prompt` string (which LLMs emit
    /// unreliably — truncating, dropping, or leaving the placeholder).
    /// The file is read with the same workspace path-safety + 256 KB
    /// cap as the `read` tool. See `loadContextFile`.
    context_file: ?[]const u8,

    fn deinit(self: *ParsedArgs, alloc: std.mem.Allocator) void {
        alloc.free(self.preset);
        if (self.profile) |p| alloc.free(p);
        alloc.free(self.prompt);
        if (self.system_prompt) |s| alloc.free(s);
        if (self.context_file) |c| alloc.free(c);
    }
};

const ErrorKind = enum {
    profile_not_found,
    preset_not_found,
    role_promotion_denied,
    timeout,
    max_turns_exceeded,
    agent_error,
    aborted,
    config_error,
    invalid_args,
    /// Sub-agent terminated normally but produced no text content
    /// in any assistant message — e.g. the model emitted a
    /// malformed tool call inside thinking, or trailed off without
    /// summarizing. Surfaced as a failure so the parent doesn't
    /// silently absorb an empty answer.
    no_final_text,

    fn name(self: ErrorKind) []const u8 {
        return @tagName(self);
    }

    fn hint(self: ErrorKind) []const u8 {
        return switch (self) {
            .profile_not_found => "retry with one of the profile names listed in `available_profiles` (or run with --list-profiles to see the catalog)",
            .preset_not_found => "call list_subagent_presets to see available presets, then retry with a valid preset name",
            .role_promotion_denied => "the preset's default_role is higher than the parent's role; run franky with a higher --role or pick a preset with a lower default_role",
            .timeout => "summarize the task more or break into smaller steps; partial_text contains what was produced before the timer fired",
            .max_turns_exceeded => "task too complex for the configured max_turns; decompose further or raise max_turns",
            .agent_error => "retry; details in error_message",
            .aborted => "parent agent is being shut down — do not retry",
            .config_error => "the subagent tool wasn't wired in this mode driver; this is a franky bug, file an issue",
            .invalid_args => "fix the JSON arguments per the schema and retry",
            .no_final_text => "the model exited without writing a user-facing response (likely emitted a malformed tool call inside thinking, or trailed off without summarizing); re-prompt with an explicit \"summarize your findings as text\" instruction or pick a stronger model",
        };
    }
};

/// v1.24.4 — wait for an in-flight slot under the global
/// `concurrency_cap`. Called at the very top of `runSubagent`
/// so any work-spawning happens AFTER the slot is held. Cancel
/// is checked before each wait; on a parent-cancel while the
/// caller is queued we return `error.AbortedWhileQueued`. The
/// wait itself is uncancelable — it relies on `releaseSubagentSlot`'s
/// broadcast as the wakeup signal. In the (rare) pathological
/// case where every active slot is stuck and the parent cancels,
/// the cancel won't propagate until ONE slot frees and we
/// re-check the loop. For 10 slots × 30-min default timeout
/// that's an acceptable bound; if real users hit this we'd
/// switch to `Io.Event` per slot for fine-grained cancel.
fn acquireSubagentSlot(io: std.Io, parent_cancel: *ai.stream.Cancel) error{AbortedWhileQueued}!void {
    concurrency_mutex.lockUncancelable(io);
    defer concurrency_mutex.unlock(io);
    while (concurrency_active >= concurrency_cap) {
        if (parent_cancel.isFired()) return error.AbortedWhileQueued;
        concurrency_cond.waitUncancelable(io, &concurrency_mutex);
    }
    concurrency_active += 1;
}

fn releaseSubagentSlot(io: std.Io) void {
    concurrency_mutex.lockUncancelable(io);
    defer concurrency_mutex.unlock(io);
    if (concurrency_active > 0) concurrency_active -= 1;
    concurrency_cond.broadcast(io);
}

fn runSubagent(
    allocator: std.mem.Allocator,
    io: std.Io,
    call_id: []const u8,
    args_json: []const u8,
    parent_cancel: *ai.stream.Cancel,
    ctx: *const Ctx,
) !at.ToolResult {
    const start_ms = ai.stream.nowMillis();

    // v1.24.4 — block until the global concurrency cap has room.
    // Defers release so EVERY exit path (success / error /
    // structured-result) frees the slot.
    acquireSubagentSlot(io, parent_cancel) catch {
        return errorResult(allocator, .aborted, "parent agent aborted while sub-agent was queued behind concurrency cap", .{ .spawn_id = call_id });
    };
    defer releaseSubagentSlot(io);

    // Parse args.
    var parsed = parseArgs(allocator, args_json) catch |e| {
        const msg = switch (e) {
            error.MissingPreset => "missing required field `preset`; call list_subagent_presets to see available presets",
            error.MissingPrompt => "missing required field `prompt`",
            error.InvalidJson => "args are not valid JSON",
            error.InvalidRole => "role must be one of: read, plan, code, full",
            error.TimeoutOutOfRange => "timeout_ms out of range (1000..7200000)",
            error.MaxTurnsOutOfRange => "max_turns must be >= 1",
            else => "invalid arguments",
        };
        return errorResult(allocator, .invalid_args, msg, .{ .spawn_id = call_id });
    };
    defer parsed.deinit(allocator);

    // v1.28.1 — clone the preset registry per-call. The
    // PresetRegistry (a StringArrayHashMapUnmanaged) is NOT
    // thread-safe. With N parallel `subagent` tool calls all
    // reading the SAME map concurrently, the hash table
    // metadata corrupts → SIGABRT (same class of bug as
    // the environ_map clone in v1.24.2).
    // The clone gives each sub-agent isolated read state;
    // parent's registry stays untouched. Freed when this
    // stack frame exits.
    var local_presets = try ctx.presets.clone(allocator);
    defer local_presets.deinit();

    // Resolve preset.
    const preset = local_presets.get(parsed.preset) orelse {
        const msg = std.fmt.allocPrint(
            allocator,
            "preset '{s}' is not registered; call list_subagent_presets to see available presets",
            .{parsed.preset},
        ) catch unreachable;
        defer allocator.free(msg);
        return errorResult(allocator, .preset_not_found, msg, .{ .spawn_id = call_id });
    };

    // Resolve role (demotion only; preset default used when not overridden).
    const sub_role = parsed.role orelse preset.default_role;
    if (sub_role.atLeast(ctx.parent_role) and sub_role != ctx.parent_role) {
        // sub_role > parent → reject with actionable hint.
        const msg = std.fmt.allocPrint(
            allocator,
            "preset '{s}' requires role '{s}' or higher but parent role is '{s}'; run franky with --role {s} or choose a different preset",
            .{ preset.name, sub_role.toString(), ctx.parent_role.toString(), sub_role.toString() },
        ) catch unreachable;
        defer allocator.free(msg);
        return errorResult(allocator, .role_promotion_denied, msg, .{ .spawn_id = call_id });
    }

    // v1.24.2 — clone the parent's environ_map per-call. `applyProfile`
    // writes the profile's `env: {}` block into the map via
    // `environ_map.put(...)`, and `Environ.Map` (a StringHashMap) is
    // NOT thread-safe. With N parallel `subagent` tool calls all
    // mutating the SAME map, the hash table corrupts → SIGABRT.
    // The clone gives each sub-agent isolated env state; parent's
    // map stays untouched.
    var local_env_map = try cloneEnvironMap(allocator, ctx.environ_map);
    defer local_env_map.deinit();

    // Build a fresh cli.Config seeded with parent's environ. Apply
    // the effective profile if one is set (preset default or per-call
    // override). Presets with default_profile="" inherit the parent's
    // provider via settings/env (same as the parent's own startup).
    var sub_cfg: cli_mod.Config = .{ .arena = std.heap.ArenaAllocator.init(allocator) };
    defer sub_cfg.deinit();

    const effective_profile: []const u8 = blk: {
        if (parsed.profile) |p| break :blk p;
        if (preset.default_profile.len > 0) break :blk preset.default_profile;
        break :blk ctx.parent_profile;
    };

    if (effective_profile.len > 0) {
        profiles_mod.applyProfile(&sub_cfg, io, &local_env_map, effective_profile) catch |e| switch (e) {
            error.ProfileNotFound => {
                const list = profiles_mod.listProfiles(allocator, io, &local_env_map) catch null;
                defer if (list) |l| allocator.free(l);
                const msg = std.fmt.allocPrint(allocator, "profile '{s}' not found", .{effective_profile}) catch unreachable;
                defer allocator.free(msg);
                return errorResult(allocator, .profile_not_found, msg, .{ .profiles_listing = list, .spawn_id = call_id });
            },
            else => {
                const msg = std.fmt.allocPrint(allocator, "profile load failed: {s}", .{@errorName(e)}) catch unreachable;
                defer allocator.free(msg);
                return errorResult(allocator, .invalid_args, msg, .{ .spawn_id = call_id });
            },
        };
    }

    // Resolve the provider — same path print mode runs at startup.
    const provider_info = print_mod.resolveProviderIo(allocator, io, ctx.environ, &sub_cfg) catch |e| {
        // Detect missing API key — give a hint with available profiles
        // rather than a raw error name the parent model can't act on.
        if (e == error.MissingApiKey) {
            var env_map = std.process.Environ.Map.init(allocator);
            defer env_map.deinit();
            const list = profiles_mod.listProfileNamesCSV(allocator, io, &env_map) catch "";
            defer if (list.len > 0) allocator.free(list);
            const hint = if (list.len > 0)
                try std.fmt.allocPrint(allocator, "the requested profile needs an API key that is not configured; please retry with one of these: {s}", .{list})
            else
                try allocator.dupe(u8, "the requested profile needs an API key that is not configured; set the required environment variable or retry with a different profile");
            defer allocator.free(hint);
            return errorResult(allocator, .agent_error, hint, .{ .spawn_id = call_id });
        }
        const msg = try std.fmt.allocPrint(allocator, "provider resolve failed: {s}", .{@errorName(e)});
        defer allocator.free(msg);
        return errorResult(allocator, .agent_error, msg, .{ .spawn_id = call_id });
    };

    // Build the sub-agent's tool list via the preset's builder.
    // Builders filter from parent_tools (already wired by mode driver)
    // by tool name, so ReadCtx / BashCtx contexts are preserved.
    const sub_tools = try preset.build_tools(allocator, ctx.parent_tools);
    defer allocator.free(sub_tools);

    // Allocate a fresh RoleGate for the sub-agent (per design §3.5
    // option C). Resolve the parent's LIVE prompter via the
    // pointer-to-slot — proxy/rpc set their session's
    // `current_prompter` per-turn; we want whatever is current
    // RIGHT NOW (the parent is mid-prompt while we're spawning).
    // Print mode has no slot wired → live_prompter stays null.
    const live_prompter: ?*permissions_mod.PermissionPrompter = blk: {
        const slot = ctx.permission_prompter_slot orelse break :blk null;
        break :blk slot.*;
    };
    // v1.24.3 — when no live prompter is available, drop the Store
    // too. Otherwise an `ask` decision (e.g. profile sets
    // `ask-tools: "all"`) would refuse-and-deadlock the sub-agent
    // because there's no path to resolve. Trust boundary: the
    // parent already approved the `subagent` tool call; the
    // sub-agent operates inside that approval.
    const effective_store: ?*permissions_mod.Store = if (live_prompter != null)
        ctx.permission_store
    else
        null;
    var sub_role_gate = role_mod.RoleGate.init(sub_role);
    var sub_gates: permissions_mod.SessionGates = .{
        .role = &sub_role_gate,
        .permissions = effective_store,
        .prompter = live_prompter,
    };

    // System prompt: per-call override > preset default.
    const sys_prompt_base = parsed.system_prompt orelse preset.default_system_prompt;

    // Inject "Current folder: <pwd>" so the sub-agent has an authoritative
    // cwd reference independent of what the parent LLM writes in the prompt.
    const pwd = ctx.environ.getPosix("PWD");
    const sys_prompt: []const u8 = if (pwd) |p|
        try std.fmt.allocPrint(allocator, "Current folder: {s}\n\n{s}", .{ p, std.mem.trimEnd(u8, sys_prompt_base, &std.ascii.whitespace) })
    else
        sys_prompt_base;
    defer if (pwd != null) allocator.free(sys_prompt);

    // OpenRouter app-attribution for the sub-agent. Computed on the
    // sub-agent's config arena so the header slice + strings outlive the
    // sub-agent's requests. Null when the provider isn't OpenRouter.
    const sub_attribution_headers = ai.openrouter_attribution.attributionHeaders(
        sub_cfg.arena.allocator(),
        provider_info.base_url,
        .{
            .referer = sub_cfg.http_referer,
            .title = sub_cfg.openrouter_title,
            .categories = sub_cfg.openrouter_categories,
        },
    ) catch null;

    // Build the sub-agent.
    const sub_model: ai.types.Model = .{
        .id = provider_info.model_id,
        .provider = provider_info.provider_name,
        .api = provider_info.api_tag,
        .context_window = provider_info.context_window,
        .max_output = provider_info.max_output,
        .capabilities = provider_info.capabilities,
    };
    var sub_agent = try agent_mod.Agent.init(allocator, io, .{
        .model = sub_model,
        .system_prompt = sys_prompt,
        .tools = sub_tools,
        .registry = ctx.registry,
        .thinking_level = sub_cfg.thinking,
        .stream_options = .{
            .api_key = provider_info.api_key,
            .auth_token = provider_info.auth_token,
            .base_url = provider_info.base_url,
            .timeouts = print_mod.resolveTimeoutsFromMap(&sub_cfg, &local_env_map),
            .retry_policy = print_mod.resolveRetryPolicyFromMap(&sub_cfg, null),
            // Use the per-call cloned env so the sub-agent's HTTP
            // client sees the profile's `env: {}` block (e.g.
            // FRANKY_FIRST_BYTE_TIMEOUT_MS overrides) without
            // touching the parent's map.
            .environ_map = &local_env_map,
            .headers = sub_attribution_headers,
        },
        .tool_gate = .{
            .userdata = @ptrCast(&sub_gates),
            .before_tool_call = permissions_mod.SessionGates.beforeToolCall,
            .role_denied = permissions_mod.SessionGates.roleDenied,
        },
    });
    defer sub_agent.deinit();

    // §6.6 — subscribe to sub-agent events for progress forwarding.
    // `ForwardState` lives on the stack here and is valid until after
    // `waitForIdle` returns. The defer unsubscribes before the frame exits.
    var fwd: ForwardState = .{
        .io = io,
        .allocator = allocator,
        .call_id = call_id,
        .ctx = ctx,
        .tool_names = .{},
        .names_mutex = .init,
    };
    defer fwd.deinit();
    const sub_progress_id: ?u32 = if (ctx.progress_fn != null)
        (sub_agent.subscribe(subagentProgressHandler, &fwd) catch null)
    else
        null;
    defer if (sub_progress_id) |id| sub_agent.unsubscribe(id);

    // Spawn supervisor — fires sub_agent.cancel on parent cancel
    // OR timeout. The supervisor exits when `done.flag` is set
    // by the main thread after `waitForIdle` returns.
    var supervisor_done = std.atomic.Value(bool).init(false);
    const supervisor_args = SupervisorArgs{
        .io = io,
        .parent_cancel = parent_cancel,
        .sub_cancel = &sub_agent.cancel,
        .timeout_ms = parsed.timeout_ms,
        .start_ms = start_ms,
        .done = &supervisor_done,
    };
    const supervisor = std.Thread.spawn(.{}, supervisorMain, .{supervisor_args}) catch |e| {
        const msg = std.fmt.allocPrint(allocator, "failed to spawn supervisor thread: {s}", .{@errorName(e)}) catch unreachable;
        defer allocator.free(msg);
        return errorResult(allocator, .agent_error, msg, .{ .spawn_id = call_id });
    };

    // v1.31.0 — load `context_file` (if provided) server-side and append
    // its contents to the prompt before spawning. This is the fix for
    // the large-diff-to-subagent failure mode: the parent passes a
    // small instruction + a file path instead of inlining tens of KB
    // into the JSON `prompt` string (which LLMs emit unreliably —
    // truncating, dropping, or leaving the placeholder). The loaded
    // bytes are appended after a separator so the diff-review preset
    // (which has NO file tools) sees the full content in its prompt.
    // Ownership: `effective_prompt_owned` is the joined buffer we hand
    // to `sub_agent.prompt`; null means we borrow `parsed.prompt`
    // directly (no alloc, no free).
    var effective_prompt_owned: ?[]u8 = null;
    defer if (effective_prompt_owned) |b| allocator.free(b);
    const effective_prompt: []const u8 = blk: {
        const cf = parsed.context_file orelse break :blk parsed.prompt;
        const content = loadContextFile(allocator, io, ctx, cf) catch |e| {
            const msg = switch (e) {
                ContextFileError.NotFound => std.fmt.allocPrint(allocator, "context_file not found: {s}", .{cf}) catch unreachable,
                ContextFileError.TooLarge => std.fmt.allocPrint(allocator, "context_file too large (exceeds {d} bytes): {s}", .{ context_file_max_bytes, cf }) catch unreachable,
                ContextFileError.Binary => std.fmt.allocPrint(allocator, "context_file appears binary (contains NUL): {s}", .{cf}) catch unreachable,
                ContextFileError.ReadFailed => std.fmt.allocPrint(allocator, "context_file read failed: {s}", .{cf}) catch unreachable,
            };
            defer allocator.free(msg);
            return errorResult(allocator, .invalid_args, msg, .{ .spawn_id = call_id });
        };
        // content is caller-owned (loadContextFile allocates); join it
        // with the prompt and free the intermediate content buffer.
        defer allocator.free(content);
        const joined = try std.fmt.allocPrint(allocator, "{s}\n\n--- context_file: {s} ---\n\n{s}", .{ parsed.prompt, cf, content });
        effective_prompt_owned = joined;
        break :blk joined;
    };

    // Run the sub-agent. Buffered: we wait until idle and read
    // the final assistant text from its transcript.
    ai.log.log(.info, "subagent", "spawn", "preset={s} profile={s} call_id={s} model={s} role={s} timeout_ms={d} max_turns={d}", .{
        preset.name, effective_profile, call_id, provider_info.model_id, sub_role.toString(), parsed.timeout_ms, parsed.max_turns,
    });
    sub_agent.prompt(effective_prompt) catch |e| {
        supervisor_done.store(true, .release);
        supervisor.join();
        const msg = std.fmt.allocPrint(allocator, "agent.prompt failed: {s}", .{@errorName(e)}) catch unreachable;
        defer allocator.free(msg);
        return errorResult(allocator, .agent_error, msg, .{ .spawn_id = call_id });
    };
    sub_agent.waitForIdle();

    // Stop the supervisor.
    supervisor_done.store(true, .release);
    supervisor.join();

    const elapsed_ms: i64 = ai.stream.nowMillis() - start_ms;

    // Persist the sub-agent's session if the parent has one.
    if (ctx.parent_session_dir) |parent_dir| {
        const persist_args = PersistArgs{
            .parent_session_dir = parent_dir,
            .call_id = call_id,
            .profile = effective_profile,
            .prompt = parsed.prompt,
            .provider = provider_info.provider_name,
            .model = provider_info.model_id,
            .api = provider_info.api_tag,
            .thinking_level = @tagName(sub_cfg.thinking),
            .transcript = &sub_agent.transcript,
            .start_ms = start_ms,
            .duration_ms = elapsed_ms,
        };
        persistSubagentSession(allocator, io, persist_args) catch |e| {
            ai.log.log(.warn, "subagent", "persist", "subagent persistence failed call_id={s}: {s}", .{ call_id, @errorName(e) });
        };
    }

    // Decide outcome: aborted (parent or timeout) → timeout/aborted,
    // agent_error in transcript → agent_error, otherwise success.
    if (sub_agent.cancel.isFired()) {
        // Distinguish timeout from cascade abort.
        const kind: ErrorKind = if (parent_cancel.isFired()) .aborted else .timeout;
        const partial = lastAssistantText(allocator, &sub_agent.transcript) catch null;
        defer if (partial) |p| allocator.free(p);
        const turn_count = countAssistantTurns(&sub_agent.transcript);
        const msg = std.fmt.allocPrint(allocator, "sub-agent {s} after {d} ms ({d} turns)", .{ kind.name(), elapsed_ms, turn_count }) catch unreachable;
        defer allocator.free(msg);
        return errorResult(allocator, kind, msg, .{ .partial_text = partial, .turn_count = turn_count, .spawn_id = call_id });
    }
    if (sub_agent.last_error) |err_details| {
        const msg = std.fmt.allocPrint(allocator, "sub-agent failed: {s} — {s}", .{ @tagName(err_details.code), err_details.message }) catch unreachable;
        defer allocator.free(msg);
        const partial = lastAssistantText(allocator, &sub_agent.transcript) catch null;
        defer if (partial) |p| allocator.free(p);
        const turn_count = countAssistantTurns(&sub_agent.transcript);
        return errorResult(allocator, .agent_error, msg, .{ .partial_text = partial, .turn_count = turn_count, .spawn_id = call_id });
    }

    const final_text_raw = (lastAssistantText(allocator, &sub_agent.transcript) catch null) orelse try allocator.dupe(u8, "");
    defer allocator.free(final_text_raw);
    const turn_count = countAssistantTurns(&sub_agent.transcript);
    const tool_call_count = countToolCalls(&sub_agent.transcript);

    // Surface "ran to completion but never produced a text answer"
    // as a failure rather than `ok: true, final_text: ""`. The
    // parent agent otherwise can't tell a successful empty response
    // apart from a model that hallucinated a tool call inside its
    // thinking block (a known small-model failure mode). Pass the
    // tail of the last thinking block as `partial_text` so the
    // caller has enough signal to decide whether to retry, switch
    // models, or give up.
    if (final_text_raw.len == 0) {
        const thinking_tail = lastAssistantThinkingTail(allocator, &sub_agent.transcript, 200) catch null;
        defer if (thinking_tail) |t| allocator.free(t);
        const stop_name = if (lastAssistantStopReason(&sub_agent.transcript)) |sr| @tagName(sr) else "unknown";
        const msg = std.fmt.allocPrint(
            allocator,
            "sub-agent completed {d} turn(s) and {d} tool call(s) but produced no final answer text. Last assistant stop reason: {s}.",
            .{ turn_count, tool_call_count, stop_name },
        ) catch unreachable;
        defer allocator.free(msg);
        ai.log.log(.warn, "subagent", "no-final-text", "call_id={s} turns={d} tool_calls={d} stop={s}", .{ call_id, turn_count, tool_call_count, stop_name });
        return errorResult(allocator, .no_final_text, msg, .{ .partial_text = thinking_tail, .turn_count = turn_count, .spawn_id = call_id });
    }

    // Cap `final_text`. Two limits; whichever is lower wins:
    //   - global `final_text_max_bytes` (4 KB) — always applied.
    //   - preset's `safety.max_result_bytes` — opt-in per preset.
    const effective_cap: usize = if (preset.safety.max_result_bytes) |limit|
        @min(final_text_max_bytes, @as(usize, limit))
    else
        final_text_max_bytes;
    const trunc = truncate_mod.truncateHead(final_text_raw, .{
        .max_lines = std.math.maxInt(usize),
        .max_bytes = effective_cap,
    });
    var capped: std.ArrayList(u8) = .empty;
    defer capped.deinit(allocator);
    try capped.appendSlice(allocator, trunc.content);
    if (trunc.truncated) {
        const cap_size = try truncate_mod.formatSize(allocator, effective_cap);
        defer allocator.free(cap_size);
        const total_size = try truncate_mod.formatSize(allocator, trunc.total_bytes);
        defer allocator.free(total_size);
        const trailer = try std.fmt.allocPrint(
            allocator,
            "\n\n[final_text truncated: showing first {s} of {s}. Re-prompt the sub-agent with a more focused question if you need the full answer.]",
            .{ cap_size, total_size },
        );
        defer allocator.free(trailer);
        try capped.appendSlice(allocator, trailer);
    }

    // v1.28.0 — if persistence happened, expose the transcript
    // path so the parent agent can `read` it on demand for full
    // conversation details. Only emitted when persistence
    // actually wrote — null when `parent_session_dir` was unset
    // OR when `persistSubagentSession` failed (the failure was
    // already warn-logged).
    const transcript_path: ?[]u8 = if (ctx.parent_session_dir) |parent|
        std.fs.path.join(allocator, &.{ parent, "subagents", call_id, "transcript.json" }) catch null
    else
        null;
    defer if (transcript_path) |p| allocator.free(p);

    ai.log.log(.info, "subagent", "done", "call_id={s} turns={d} tool_calls={d} duration_ms={d}", .{ call_id, turn_count, tool_call_count, elapsed_ms });
    return successResult(allocator, capped.items, turn_count, tool_call_count, elapsed_ms, call_id, transcript_path, call_id);
}

/// v1.28.0 — cap on the `final_text` field returned by every
/// sub-agent run. Sub-agents already firewall their tool results
/// from the parent's context, but `final_text` rides back into the
/// parent's transcript verbatim — uncapped, that's a regression
/// vector ("ask sub-agent to summarize, get a 50 KB monologue
/// dumped into context"). 4 KB is generous for a focused-question
/// answer and tight enough to keep parent context clean.
pub const final_text_max_bytes: usize = 4 * 1024;

// ─── supervisor ────────────────────────────────────────────────────

const SupervisorArgs = struct {
    io: std.Io,
    parent_cancel: *ai.stream.Cancel,
    sub_cancel: *ai.stream.Cancel,
    timeout_ms: u64,
    start_ms: i64,
    done: *std.atomic.Value(bool),
};

fn supervisorMain(args: SupervisorArgs) void {
    const deadline_ms: i64 = args.start_ms + @as(i64, @intCast(args.timeout_ms));
    while (!args.done.load(.acquire)) {
        if (args.parent_cancel.isFired() or ai.stream.nowMillis() >= deadline_ms) {
            args.sub_cancel.fire();
            return;
        }
        // Poll at 1-second granularity — 50 ms was far too aggressive and
        // with a 6-8 way fan-out of concurrent sub-agents, each polling loop
        // (especially the non-libc fallback which busy-waits) consumed ~100%
        // of a CPU core per supervisor.  1-second wake-ups are adequate for
        // timeout detection on sub-agent runs that last minutes.
        args.io.sleep(.fromMilliseconds(1000), .awake) catch {};
    }
}

// ─── arg parsing ───────────────────────────────────────────────────

const ParseError = error{
    OutOfMemory,
    MissingPreset,
    MissingPrompt,
    InvalidJson,
    InvalidRole,
    TimeoutOutOfRange,
    MaxTurnsOutOfRange,
};

/// v1.31.0 — errors specific to `context_file` loading. Surfaced
/// via `errorResult(.invalid_args, ...)` so the parent agent gets
/// an actionable message instead of a raw tool failure.
const ContextFileError = error{
    NotFound,
    TooLarge,
    Binary,
    ReadFailed,
};

/// v1.31.0 — soft cap on `context_file` size. Matches the `read`
/// tool's `max_bytes_without_limit` (256 KB). Diffs and source
/// listings the parent passes in are well under this; going higher
/// risks blowing the sub-agent's context window for no benefit.
const context_file_max_bytes: usize = 256 * 1024;

/// v1.31.0 — read `path` from disk with the same workspace
/// path-safety + size cap as the `read` tool. Returns a
/// caller-owned byte slice. Errors are mapped to `ContextFileError`
/// so the caller can surface an actionable `invalid_args` result.
///
/// Why this exists: the `diff-review` preset has NO file-reading
/// tools, so the parent agent must pass the diff text inside the
/// `prompt` JSON string. For diffs > tens of KB, LLMs emit the
/// string unreliably (truncating, dropping, or leaving the
/// `[paste full diff]` placeholder). `context_file` lets the
/// parent pass a path instead; this loader reads it server-side
/// and the caller appends it to the prompt before spawning.
///
/// `ctx.workspace` is optional — when null (older mode drivers
/// not yet wired), the raw `path` is read directly against CWD
/// without path-safety. This keeps the field opt-in for mode
/// drivers while degrading safely.
fn loadContextFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    ctx: *const Ctx,
    path: []const u8,
) ContextFileError![]u8 {
    // Resolve the path to an absolute filesystem path, then open+read
    // once. When a workspace is configured we canonicalize through it
    // (same path-safety as the `read` tool); otherwise we fall back to
    // the raw path against CWD.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aalloc = arena.allocator();

    const abs_path: []const u8 = blk: {
        const ws = ctx.workspace orelse break :blk path;
        // canonicalizeOrError returns `!CanonResult` (error union).
        // On success `.ok` holds an owned CanonPath (caller must
        // deinit); on error `.err` holds a code+message. We map any
        // path-safety failure to NotFound so the parent gets an
        // actionable `context_file not found` message.
        const r = workspace_mod.canonicalizeOrError(aalloc, ws, path) catch return error.NotFound;
        switch (r) {
            .ok => |c| break :blk c.abs,
            .err => return error.NotFound,
        }
    };

    const file = std.Io.Dir.cwd().openFile(io, abs_path, .{}) catch return error.NotFound;
    defer file.close(io);
    return readCapped(allocator, io, file);
}

/// Read up to `context_file_max_bytes` from an open file. Refuses
/// binary content (NUL in the first 8 KB) and files exceeding the cap.
/// The caller owns the returned slice.
fn readCapped(
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
) ContextFileError![]u8 {
    const len = file.length(io) catch return error.ReadFailed;
    if (len > context_file_max_bytes) return error.TooLarge;
    const buf = allocator.alloc(u8, @intCast(len)) catch return error.ReadFailed;
    errdefer allocator.free(buf);
    const n = file.readPositionalAll(io, buf, 0) catch return error.ReadFailed;
    const bytes = buf[0..n];
    // Binary sniff — same heuristic as the `read` tool.
    const sniff_len = @min(bytes.len, 8192);
    if (std.mem.indexOfScalar(u8, bytes[0..sniff_len], 0) != null) {
        allocator.free(buf);
        return error.Binary;
    }
    return buf;
}

fn parseArgs(allocator: std.mem.Allocator, args_json: []const u8) ParseError!ParsedArgs {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aalloc = arena.allocator();

    const json_to_parse: []const u8 = blk: {
        if (common.repairConcatJson(aalloc, args_json)) |r| break :blk r;
        break :blk args_json;
    };
    const parsed = std.json.parseFromSlice(std.json.Value, aalloc, json_to_parse, .{}) catch return error.InvalidJson;
    if (parsed.value != .object) return error.InvalidJson;
    const obj = parsed.value.object;

    const preset_v = obj.get("preset") orelse return error.MissingPreset;
    if (preset_v != .string) return error.MissingPreset;
    const prompt_v = obj.get("prompt") orelse return error.MissingPrompt;
    if (prompt_v != .string) return error.MissingPrompt;

    var out: ParsedArgs = .{
        .preset = try allocator.dupe(u8, preset_v.string),
        .profile = null,
        .prompt = try allocator.dupe(u8, prompt_v.string),
        .timeout_ms = default_timeout_ms,
        .max_turns = default_max_turns,
        .role = null,
        .system_prompt = null,
        .context_file = null,
    };
    errdefer out.deinit(allocator);

    if (obj.get("profile")) |v| if (v == .string) {
        out.profile = try allocator.dupe(u8, v.string);
    };
    if (obj.get("timeout_ms")) |v| if (v == .integer) {
        const t = v.integer;
        if (t < @as(i64, @intCast(min_timeout_ms)) or t > @as(i64, @intCast(max_timeout_ms))) return error.TimeoutOutOfRange;
        out.timeout_ms = @intCast(t);
    };
    if (obj.get("max_turns")) |v| if (v == .integer) {
        if (v.integer < 1) return error.MaxTurnsOutOfRange;
        out.max_turns = @intCast(v.integer);
    };
    if (obj.get("role")) |v| if (v == .string) {
        out.role = role_mod.Role.fromString(v.string) catch return error.InvalidRole;
    };
    if (obj.get("system_prompt")) |v| if (v == .string) {
        out.system_prompt = try allocator.dupe(u8, v.string);
    };
    // v1.31.0 — optional context_file path. Read server-side so the
    // parent doesn't have to inline large content into the JSON prompt
    // string (the failure mode that prompted this field).
    if (obj.get("context_file")) |v| if (v == .string) {
        if (v.string.len > 0) {
            out.context_file = try allocator.dupe(u8, v.string);
        }
    };

    return out;
}

// ─── helpers ───────────────────────────────────────────────────────

/// v1.24.2 — shallow-clone an `Environ.Map` per concurrent
/// subagent call so `applyProfile`'s mutation of the env block
/// stays isolated. `Environ.Map.put` dupes both key and value
/// internally, so the clone is fully independent — `deinit` is
/// safe regardless of source-map lifetime.
fn cloneEnvironMap(allocator: std.mem.Allocator, src: *std.process.Environ.Map) !std.process.Environ.Map {
    var out = std.process.Environ.Map.init(allocator);
    errdefer out.deinit();
    var it = src.iterator();
    while (it.next()) |entry| {
        try out.put(entry.key_ptr.*, entry.value_ptr.*);
    }
    return out;
}

fn buildSubTools(allocator: std.mem.Allocator, parent_tools: []const at.AgentTool) ![]at.AgentTool {
    var out = try allocator.alloc(at.AgentTool, parent_tools.len);
    var n: usize = 0;
    for (parent_tools) |t| {
        if (std.mem.eql(u8, t.name, tool_name)) continue;
        out[n] = t;
        n += 1;
    }
    return allocator.realloc(out, n);
}

fn lastAssistantText(allocator: std.mem.Allocator, transcript: *const loop_mod.Transcript) !?[]u8 {
    const msgs = transcript.messages.items;
    var i: usize = msgs.len;
    while (i > 0) {
        i -= 1;
        if (msgs[i].role != .assistant) continue;
        for (msgs[i].content) |cb| switch (cb) {
            .text => |t| return try allocator.dupe(u8, t.text),
            else => {},
        };
    }
    return null;
}

fn lastAssistantThinkingTail(
    allocator: std.mem.Allocator,
    transcript: *const loop_mod.Transcript,
    max_bytes: usize,
) !?[]u8 {
    const msgs = transcript.messages.items;
    var i: usize = msgs.len;
    while (i > 0) {
        i -= 1;
        if (msgs[i].role != .assistant) continue;
        var j: usize = msgs[i].content.len;
        while (j > 0) {
            j -= 1;
            switch (msgs[i].content[j]) {
                .thinking => |th| {
                    const trunc = truncate_mod.truncateTail(th.thinking, .{
                        .max_lines = std.math.maxInt(usize),
                        .max_bytes = max_bytes,
                    });
                    if (!trunc.truncated) return try allocator.dupe(u8, trunc.content);
                    var out: std.ArrayList(u8) = .empty;
                    errdefer out.deinit(allocator);
                    try out.appendSlice(allocator, "[…]");
                    try out.appendSlice(allocator, trunc.content);
                    return try out.toOwnedSlice(allocator);
                },
                else => {},
            }
        }
    }
    return null;
}

fn lastAssistantStopReason(transcript: *const loop_mod.Transcript) ?ai.types.StopReason {
    const msgs = transcript.messages.items;
    var i: usize = msgs.len;
    while (i > 0) {
        i -= 1;
        if (msgs[i].role != .assistant) continue;
        return msgs[i].stop_reason;
    }
    return null;
}

fn countAssistantTurns(transcript: *const loop_mod.Transcript) u32 {
    var n: u32 = 0;
    for (transcript.messages.items) |m| if (m.role == .assistant) {
        n += 1;
    };
    return n;
}

fn countToolCalls(transcript: *const loop_mod.Transcript) u32 {
    var n: u32 = 0;
    for (transcript.messages.items) |m| {
        if (m.role != .assistant) continue;
        for (m.content) |cb| switch (cb) {
            .tool_call => n += 1,
            else => {},
        };
    }
    return n;
}

// ─── result builders ───────────────────────────────────────────────

fn successResult(
    allocator: std.mem.Allocator,
    final_text: []const u8,
    turn_count: u32,
    tool_call_count: u32,
    duration_ms: i64,
    session_id: []const u8,
    /// v1.28.0 — when the parent has an on-disk session, the
    /// sub-agent's full transcript is persisted to this path. The
    /// parent agent can `read` it for full conversation details
    /// without burning context on the round-trip back. Null in
    /// `--no-session` runs (in-memory transcripts only).
    transcript_path: ?[]const u8,
    /// v1.30.0 — stable spawn id echoed back in the result envelope
    /// so the UI panel can match a result row to its spawn by key
    /// (not by positional order, which races when one sub-agent
    /// fast-fails while siblings are still streaming). Always equal
    /// to the tool-call `id` issued by the parent model.
    spawn_id: []const u8,
) !at.ToolResult {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"ok\":true,\"final_text\":");
    try ai.utils.appendJsonStr(&buf, allocator, final_text);
    try buf.appendSlice(allocator, ",\"turn_count\":");
    try ai.utils.appendJsonInt(&buf, allocator, turn_count);
    try buf.appendSlice(allocator, ",\"tool_call_count\":");
    try ai.utils.appendJsonInt(&buf, allocator, tool_call_count);
    try buf.appendSlice(allocator, ",\"duration_ms\":");
    try ai.utils.appendJsonInt(&buf, allocator, duration_ms);
    try buf.appendSlice(allocator, ",\"session_id\":");
    try ai.utils.appendJsonStr(&buf, allocator, session_id);
    try buf.appendSlice(allocator, ",\"spawn_id\":");
    try ai.utils.appendJsonStr(&buf, allocator, spawn_id);
    if (transcript_path) |p| {
        try buf.appendSlice(allocator, ",\"transcript_path\":");
        try ai.utils.appendJsonStr(&buf, allocator, p);
    }
    try buf.append(allocator, '}');

    const text = try buf.toOwnedSlice(allocator);
    var content = try allocator.alloc(ai.types.ContentBlock, 1);
    content[0] = .{ .text = .{ .text = text } };
    return .{ .content = content, .is_error = false };
}

const ErrorOpts = struct {
    partial_text: ?[]const u8 = null,
    turn_count: u32 = 0,
    profiles_listing: ?[]const u8 = null,
    /// v1.30.0 — stable spawn id (the parent tool-call id). Null for
    /// error paths that fire before a call_id is known (none today,
    /// but kept optional so the fast-fail paths don't have to thread
    /// one synthetically).
    spawn_id: ?[]const u8 = null,
};

fn errorResult(
    allocator: std.mem.Allocator,
    kind: ErrorKind,
    msg: []const u8,
    opts: ErrorOpts,
) !at.ToolResult {
    const partial_text = opts.partial_text;
    const turn_count = opts.turn_count;
    const profiles_listing = opts.profiles_listing;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"ok\":false,\"error_kind\":");
    try ai.utils.appendJsonStr(&buf, allocator, kind.name());
    try buf.appendSlice(allocator, ",\"error_message\":");
    try ai.utils.appendJsonStr(&buf, allocator, msg);
    try buf.appendSlice(allocator, ",\"hint\":");
    try ai.utils.appendJsonStr(&buf, allocator, kind.hint());
    if (partial_text) |p| {
        try buf.appendSlice(allocator, ",\"partial_text\":");
        try ai.utils.appendJsonStr(&buf, allocator, p);
    }
    try buf.appendSlice(allocator, ",\"turn_count\":");
    try ai.utils.appendJsonInt(&buf, allocator, turn_count);
    if (profiles_listing) |pl| {
        try buf.appendSlice(allocator, ",\"available_profiles\":");
        try ai.utils.appendJsonStr(&buf, allocator, pl);
    }
    if (opts.spawn_id) |sid| {
        try buf.appendSlice(allocator, ",\"spawn_id\":");
        try ai.utils.appendJsonStr(&buf, allocator, sid);
    }
    try buf.append(allocator, '}');

    const text = try buf.toOwnedSlice(allocator);
    var content = try allocator.alloc(ai.types.ContentBlock, 1);
    content[0] = .{ .text = .{ .text = text } };
    const tool_code_owned = try allocator.dupe(u8, kind.name());
    return .{ .content = content, .is_error = true, .tool_code = tool_code_owned };
}

// ─── persistence ───────────────────────────────────────────────────

const PersistArgs = struct {
    parent_session_dir: []const u8,
    call_id: []const u8,
    profile: []const u8,
    prompt: []const u8,
    provider: []const u8,
    model: []const u8,
    api: []const u8,
    thinking_level: []const u8,
    transcript: *const loop_mod.Transcript,
    start_ms: i64,
    duration_ms: i64,
};

fn persistSubagentSession(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: PersistArgs,
) !void {
    const subagents_dir = try std.fs.path.join(allocator, &.{ args.parent_session_dir, "subagents" });
    defer allocator.free(subagents_dir);

    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, subagents_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };

    // Title = profile name + first 40 chars of the prompt (best-effort
    // human label for transcripts viewers; nothing relies on it).
    const title_max = 40;
    const trimmed_prompt = if (args.prompt.len > title_max) args.prompt[0..title_max] else args.prompt;
    const title = try std.fmt.allocPrint(allocator, "subagent[{s}]: {s}", .{ args.profile, trimmed_prompt });
    defer allocator.free(title);

    // session.save handles the <subagents>/<call_id>/transcript.json layout.
    try session_mod.save(allocator, io, subagents_dir, .{
        .id = args.call_id,
        .created_at_ms = args.start_ms,
        .updated_at_ms = args.start_ms + args.duration_ms,
        .title = title,
        .provider = args.provider,
        .model = args.model,
        .api = args.api,
        .thinking_level = args.thinking_level,
        .active_branch = "main",
    }, args.transcript);

    // meta.json sidecar — debugging context.
    const meta_path = try std.fs.path.join(allocator, &.{ subagents_dir, args.call_id, "meta.json" });
    defer allocator.free(meta_path);
    var meta_buf: std.ArrayList(u8) = .empty;
    defer meta_buf.deinit(allocator);
    try meta_buf.appendSlice(allocator, "{\"profile\":");
    try ai.utils.appendJsonStr(&meta_buf, allocator, args.profile);
    try meta_buf.appendSlice(allocator, ",\"prompt\":");
    try ai.utils.appendJsonStr(&meta_buf, allocator, args.prompt);
    try meta_buf.appendSlice(allocator, ",\"call_id\":");
    try ai.utils.appendJsonStr(&meta_buf, allocator, args.call_id);
    try meta_buf.appendSlice(allocator, ",\"provider\":");
    try ai.utils.appendJsonStr(&meta_buf, allocator, args.provider);
    try meta_buf.appendSlice(allocator, ",\"model\":");
    try ai.utils.appendJsonStr(&meta_buf, allocator, args.model);
    try meta_buf.appendSlice(allocator, ",\"started_at_ms\":");
    try ai.utils.appendJsonInt(&meta_buf, allocator, args.start_ms);
    try meta_buf.appendSlice(allocator, ",\"duration_ms\":");
    try ai.utils.appendJsonInt(&meta_buf, allocator, args.duration_ms);
    try meta_buf.append(allocator, '}');
    try cwd.writeFile(io, .{ .sub_path = meta_path, .data = meta_buf.items });
}

// ─── tests ─────────────────────────────────────────────────────────

const testing = std.testing;

test "parseArgs: required fields + defaults" {
    const gpa = testing.allocator;
    var p = try parseArgs(gpa, "{\"preset\":\"research\",\"prompt\":\"hi\"}");
    defer p.deinit(gpa);
    try testing.expectEqualStrings("research", p.preset);
    try testing.expect(p.profile == null);
    try testing.expectEqualStrings("hi", p.prompt);
    try testing.expectEqual(default_timeout_ms, p.timeout_ms);
    try testing.expectEqual(default_max_turns, p.max_turns);
    try testing.expect(p.role == null);
    try testing.expect(p.system_prompt == null);
    // v1.31.0 — context_file defaults to null when not provided.
    try testing.expect(p.context_file == null);
}

test "parseArgs: context_file parsed when provided" {
    const gpa = testing.allocator;
    var p = try parseArgs(gpa, "{\"preset\":\"diff-review\",\"prompt\":\"review this\",\"context_file\":\"/tmp/diff.patch\"}");
    defer p.deinit(gpa);
    try testing.expectEqualStrings("diff-review", p.preset);
    try testing.expectEqualStrings("review this", p.prompt);
    try testing.expectEqualStrings("/tmp/diff.patch", p.context_file.?);
}

test "parseArgs: empty context_file string treated as null" {
    // An empty `context_file` string is a no-op — the loader skips it.
    // Models sometimes emit `""` for optional string fields; treating
    // that as "no file" avoids a spurious not-found error.
    const gpa = testing.allocator;
    var p = try parseArgs(gpa, "{\"preset\":\"diff-review\",\"prompt\":\"y\",\"context_file\":\"\"}");
    defer p.deinit(gpa);
    try testing.expect(p.context_file == null);
}

test "loadContextFile: reads a workspace file and returns its bytes" {
    const gpa = testing.allocator;
    var threaded = @import("../../test_helpers.zig").threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    // Create a temp dir + file inside it.
    const tmp = "/tmp/franky_ctx_file_test_";
    _ = std.Io.Dir.cwd().deleteTree(io, tmp) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try std.Io.Dir.cwd().createDirPath(io, tmp);
    const file_path = tmp ++ "/diff.patch";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file_path, .data = "--- a\n+++ b\n@@ -1 +1 @@\n-old\n+new\n" });

    var ws: workspace_mod.Workspace = .{ .root = tmp };
    var ctx: Ctx = .{
        .registry = undefined,
        .environ = undefined,
        .environ_map = undefined,
        .parent_tools = &.{},
        .parent_role = .read,
        .presets = undefined,
        .parameters_json_owned = "",
        .permission_store = null,
        .parent_session_dir = null,
        .workspace = &ws,
    };
    const content = try loadContextFile(gpa, io, &ctx, "diff.patch");
    defer gpa.free(content);
    try testing.expect(std.mem.indexOf(u8, content, "-old") != null);
    try testing.expect(std.mem.indexOf(u8, content, "+new") != null);
}

test "loadContextFile: not-found maps to NotFound error" {
    const gpa = testing.allocator;
    var threaded = @import("../../test_helpers.zig").threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    var ws: workspace_mod.Workspace = .{ .root = "/tmp" };
    var ctx: Ctx = .{
        .registry = undefined,
        .environ = undefined,
        .environ_map = undefined,
        .parent_tools = &.{},
        .parent_role = .read,
        .presets = undefined,
        .parameters_json_owned = "",
        .permission_store = null,
        .parent_session_dir = null,
        .workspace = &ws,
    };
    try testing.expectError(error.NotFound, loadContextFile(gpa, io, &ctx, "franky_nonexistent_file_xyz.patch"));
}

test "loadContextFile: workspace escape maps to NotFound" {
    // Paths that escape the workspace root are rejected by
    // canonicalizeOrError; the loader maps that to NotFound so the
    // parent agent gets an actionable message.
    const gpa = testing.allocator;
    var threaded = @import("../../test_helpers.zig").threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    var ws: workspace_mod.Workspace = .{ .root = "/tmp" };
    var ctx: Ctx = .{
        .registry = undefined,
        .environ = undefined,
        .environ_map = undefined,
        .parent_tools = &.{},
        .parent_role = .read,
        .presets = undefined,
        .parameters_json_owned = "",
        .permission_store = null,
        .parent_session_dir = null,
        .workspace = &ws,
    };
    // /etc/passwd escapes /tmp.
    try testing.expectError(error.NotFound, loadContextFile(gpa, io, &ctx, "/etc/passwd"));
}

test "parseArgs: explicit timeout_ms + max_turns + role" {
    const gpa = testing.allocator;
    var p = try parseArgs(gpa, "{\"preset\":\"file-ops\",\"prompt\":\"y\",\"timeout_ms\":5000,\"max_turns\":3,\"role\":\"plan\"}");
    defer p.deinit(gpa);
    try testing.expectEqual(@as(u64, 5000), p.timeout_ms);
    try testing.expectEqual(@as(u32, 3), p.max_turns);
    try testing.expectEqual(role_mod.Role.plan, p.role.?);
}

test "parseArgs: missing preset errors" {
    const gpa = testing.allocator;
    try testing.expectError(error.MissingPreset, parseArgs(gpa, "{\"prompt\":\"x\"}"));
}

test "parseArgs: missing prompt errors" {
    const gpa = testing.allocator;
    try testing.expectError(error.MissingPrompt, parseArgs(gpa, "{\"preset\":\"research\"}"));
}

test "parseArgs: timeout out of range errors" {
    const gpa = testing.allocator;
    try testing.expectError(error.TimeoutOutOfRange, parseArgs(gpa, "{\"preset\":\"research\",\"prompt\":\"y\",\"timeout_ms\":100}"));
    try testing.expectError(error.TimeoutOutOfRange, parseArgs(gpa, "{\"preset\":\"research\",\"prompt\":\"y\",\"timeout_ms\":99999999}"));
}

test "parseArgs: invalid role errors" {
    const gpa = testing.allocator;
    try testing.expectError(error.InvalidRole, parseArgs(gpa, "{\"preset\":\"research\",\"prompt\":\"y\",\"role\":\"superuser\"}"));
}

test "PresetRegistry: register + get" {
    const gpa = testing.allocator;
    var reg = PresetRegistry.init(gpa);
    defer reg.deinit();

    try reg.register(.{
        .name = "my-preset",
        .description = "test preset",
        .default_profile = "gemini",
        .default_role = .read,
        .default_system_prompt = "test",
        .build_tools = buildResearchTools,
    });
    const p = reg.get("my-preset");
    try testing.expect(p != null);
    try testing.expectEqualStrings("my-preset", p.?.name);
    try testing.expect(reg.get("nonexistent") == null);
}

test "registerBuiltinPresets: populates all five built-ins" {
    const gpa = testing.allocator;
    var reg = PresetRegistry.init(gpa);
    defer reg.deinit();
    try registerBuiltinPresets(&reg);

    const names = [_][]const u8{ "research", "code-audit", "diff-review", "file-ops", "bash-runner" };
    for (names) |n| {
        const p = reg.get(n);
        try testing.expect(p != null);
        try testing.expect(p.?.description.len > 0);
        try testing.expect(p.?.default_system_prompt.len > 0);
    }
    try testing.expectEqual(role_mod.Role.read, reg.get("research").?.default_role);
    try testing.expectEqual(role_mod.Role.read, reg.get("code-audit").?.default_role);
    try testing.expectEqual(role_mod.Role.read, reg.get("diff-review").?.default_role);
    try testing.expectEqual(role_mod.Role.plan, reg.get("file-ops").?.default_role);
    try testing.expectEqual(role_mod.Role.code, reg.get("bash-runner").?.default_role);
    try testing.expect(reg.get("research").?.safety.read_only);
    try testing.expect(reg.get("code-audit").?.safety.read_only);
    try testing.expect(reg.get("diff-review").?.safety.read_only);
}

test "buildParametersJson: enum contains all registered preset names" {
    const gpa = testing.allocator;
    var reg = PresetRegistry.init(gpa);
    defer reg.deinit();
    try registerBuiltinPresets(&reg);

    const params = try buildParametersJson(gpa, &reg);
    defer gpa.free(params);

    try testing.expect(std.mem.indexOf(u8, params, "\"research\"") != null);
    try testing.expect(std.mem.indexOf(u8, params, "\"code-audit\"") != null);
    try testing.expect(std.mem.indexOf(u8, params, "\"diff-review\"") != null);
    try testing.expect(std.mem.indexOf(u8, params, "\"file-ops\"") != null);
    try testing.expect(std.mem.indexOf(u8, params, "\"bash-runner\"") != null);
    try testing.expect(std.mem.indexOf(u8, params, "\"preset\"") != null);
    try testing.expect(std.mem.indexOf(u8, params, "\"prompt\"") != null);
}

test "selectTools: filters by name from parent slice" {
    const gpa = testing.allocator;
    const read_t: at.AgentTool = .{ .name = "read", .description = "", .parameters_json = "{}", .execute = undefined };
    const ls_t: at.AgentTool = .{ .name = "ls", .description = "", .parameters_json = "{}", .execute = undefined };
    const bash_t: at.AgentTool = .{ .name = "bash", .description = "", .parameters_json = "{}", .execute = undefined };
    const parent = [_]at.AgentTool{ read_t, ls_t, bash_t };

    const sub = try selectTools(gpa, &parent, &[_][]const u8{ "read", "ls" });
    defer gpa.free(sub);

    try testing.expectEqual(@as(usize, 2), sub.len);
    try testing.expectEqualStrings("read", sub[0].name);
    try testing.expectEqualStrings("ls", sub[1].name);
}

test "research preset build_tools: returns read+ls+find+grep, no bash/write/edit" {
    const gpa = testing.allocator;
    const parent = [_]at.AgentTool{
        .{ .name = "read", .description = "", .parameters_json = "{}", .execute = undefined },
        .{ .name = "ls", .description = "", .parameters_json = "{}", .execute = undefined },
        .{ .name = "find", .description = "", .parameters_json = "{}", .execute = undefined },
        .{ .name = "grep", .description = "", .parameters_json = "{}", .execute = undefined },
        .{ .name = "bash", .description = "", .parameters_json = "{}", .execute = undefined },
        .{ .name = "write", .description = "", .parameters_json = "{}", .execute = undefined },
        .{ .name = "edit", .description = "", .parameters_json = "{}", .execute = undefined },
    };
    const tools = try buildResearchTools(gpa, &parent);
    defer gpa.free(tools);

    try testing.expectEqual(@as(usize, 4), tools.len);
    const has = struct {
        fn check(ts: []const at.AgentTool, n: []const u8) bool {
            for (ts) |t| if (std.mem.eql(u8, t.name, n)) return true;
            return false;
        }
    }.check;
    try testing.expect(has(tools, "read"));
    try testing.expect(has(tools, "ls"));
    try testing.expect(has(tools, "find"));
    try testing.expect(has(tools, "grep"));
    try testing.expect(!has(tools, "bash"));
    try testing.expect(!has(tools, "write"));
    try testing.expect(!has(tools, "edit"));
}

test "PresetRegistry: SDK preset overrides built-in with same name" {
    const gpa = testing.allocator;
    var reg = PresetRegistry.init(gpa);
    defer reg.deinit();
    try registerBuiltinPresets(&reg);

    // Override research with a custom one.
    try reg.register(.{
        .name = "research",
        .description = "custom research",
        .default_profile = "gemini",
        .default_role = .read,
        .default_system_prompt = "custom prompt",
        .build_tools = buildResearchTools,
    });

    const p = reg.get("research").?;
    try testing.expectEqualStrings("custom research", p.description);
    try testing.expectEqualStrings("gemini", p.default_profile);
}

test "ErrorKind hints are non-empty for all variants" {
    const enum_info = @typeInfo(ErrorKind).@"enum";
    inline for (enum_info.field_names, enum_info.field_values) |name, value| {
        _ = name;
        const k: ErrorKind = @enumFromInt(value);
        try testing.expect(k.hint().len > 0);
        try testing.expect(k.name().len > 0);
    }
}

test "successResult emits valid JSON with the expected fields" {
    const gpa = testing.allocator;
    var r = try successResult(gpa, "the answer", 4, 7, 1234, "01J0", null, "call_abc");
    defer r.deinit(gpa);
    try testing.expect(!r.is_error);
    try testing.expectEqual(@as(usize, 1), r.content.len);
    const text = r.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, text, "\"ok\":true") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"final_text\":\"the answer\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"turn_count\":4") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"tool_call_count\":7") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"duration_ms\":1234") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"session_id\":\"01J0\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"spawn_id\":\"call_abc\"") != null);
    // null transcript_path → field omitted entirely.
    try testing.expect(std.mem.indexOf(u8, text, "transcript_path") == null);
}

test "successResult emits transcript_path field when set (v1.28.0)" {
    const gpa = testing.allocator;
    var r = try successResult(
        gpa,
        "the answer",
        4,
        7,
        1234,
        "01J0",
        "/home/user/.franky/sessions/abc/subagents/01J0/transcript.json",
        "call_xyz",
    );
    defer r.deinit(gpa);
    try testing.expect(!r.is_error);
    const text = r.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, text, "\"transcript_path\":") != null);
    try testing.expect(std.mem.indexOf(u8, text, "/subagents/01J0/transcript.json") != null);
}

test "errorResult emits valid JSON with kind + hint + tool_code" {
    const gpa = testing.allocator;
    var r = try errorResult(gpa, .timeout, "took too long", .{ .partial_text = "partial answer", .turn_count = 3, .spawn_id = "call_t1" });
    defer r.deinit(gpa);
    try testing.expect(r.is_error);
    try testing.expectEqualStrings("timeout", r.tool_code.?);
    const text = r.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, text, "\"ok\":false") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"error_kind\":\"timeout\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"error_message\":\"took too long\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"partial_text\":\"partial answer\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"turn_count\":3") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"spawn_id\":\"call_t1\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"hint\":\"") != null);
}

test "lastAssistantThinkingTail: returns last block, capped with prefix" {
    const gpa = testing.allocator;
    var transcript = loop_mod.Transcript.init(gpa);
    defer transcript.deinit();

    // Two assistant messages, the latest with a long thinking block.
    const c1 = try gpa.alloc(ai.types.ContentBlock, 1);
    c1[0] = .{ .thinking = .{ .thinking = try gpa.dupe(u8, "early thinking") } };
    try transcript.append(.{ .role = .assistant, .content = c1, .timestamp = 0 });

    var tmp_500: [500]u8 = @splat('X');
    const long_thinking = tmp_500[0..];
    const c2 = try gpa.alloc(ai.types.ContentBlock, 1);
    c2[0] = .{ .thinking = .{ .thinking = try gpa.dupe(u8, long_thinking) } };
    try transcript.append(.{ .role = .assistant, .content = c2, .timestamp = 0 });

    const tail = (try lastAssistantThinkingTail(gpa, &transcript, 64)).?;
    defer gpa.free(tail);
    // 3 bytes prefix "[…]" (UTF-8: 0xE2 0x80 0xA6 → 3 bytes for the
    // ellipsis alone, plus the [ and ]) + last 64 bytes of "X"*500.
    try testing.expect(std.mem.startsWith(u8, tail, "[…]"));
    var tmp_64: [64]u8 = @splat('X');
    try testing.expect(std.mem.endsWith(u8, tail, tmp_64[0..]));
}

test "lastAssistantThinkingTail: short block returned unchanged" {
    const gpa = testing.allocator;
    var transcript = loop_mod.Transcript.init(gpa);
    defer transcript.deinit();

    const c = try gpa.alloc(ai.types.ContentBlock, 1);
    c[0] = .{ .thinking = .{ .thinking = try gpa.dupe(u8, "brief") } };
    try transcript.append(.{ .role = .assistant, .content = c, .timestamp = 0 });

    const tail = (try lastAssistantThinkingTail(gpa, &transcript, 200)).?;
    defer gpa.free(tail);
    try testing.expectEqualStrings("brief", tail);
}

test "lastAssistantThinkingTail: returns null when no thinking exists" {
    const gpa = testing.allocator;
    var transcript = loop_mod.Transcript.init(gpa);
    defer transcript.deinit();

    const c = try gpa.alloc(ai.types.ContentBlock, 1);
    c[0] = .{ .text = .{ .text = try gpa.dupe(u8, "hello") } };
    try transcript.append(.{ .role = .assistant, .content = c, .timestamp = 0 });

    const tail = try lastAssistantThinkingTail(gpa, &transcript, 200);
    try testing.expect(tail == null);
}

test "concurrency cap: 11 simultaneous acquires never exceed the cap (v1.24.4)" {
    const test_h = @import("../../test_helpers.zig");
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    // Simulate 11 concurrent acquires — only 10 may hold the slot
    // at any moment. We track the live max via an atomic.
    var live = std.atomic.Value(u32).init(0);
    var peak = std.atomic.Value(u32).init(0);
    var cancel = ai.stream.Cancel{};

    const Worker = struct {
        fn run(ioi: std.Io, c: *ai.stream.Cancel, l: *std.atomic.Value(u32), p: *std.atomic.Value(u32)) void {
            acquireSubagentSlot(ioi, c) catch return;
            defer releaseSubagentSlot(ioi);
            const cur = l.fetchAdd(1, .acq_rel) + 1;
            // Update peak if we set a new high water mark.
            var current_peak = p.load(.acquire);
            while (cur > current_peak) {
                current_peak = p.cmpxchgWeak(current_peak, cur, .acq_rel, .acquire) orelse break;
            }
            // Hold the slot briefly so the cap actually has a
            // chance to bind (without sleep all 11 might serialize
            // through the mutex faster than the next thread arrives).
            ioi.sleep(.fromMilliseconds(20), .awake) catch {};
            _ = l.fetchSub(1, .acq_rel);
        }
    };

    var threads: [11]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, Worker.run, .{ io, &cancel, &live, &peak });
    }
    for (threads) |t| t.join();

    try testing.expect(peak.load(.acquire) <= concurrency_cap);
    try testing.expectEqual(@as(u32, 0), live.load(.acquire));
    // After all workers finish, the global counter must be zero.
    concurrency_mutex.lockUncancelable(io);
    defer concurrency_mutex.unlock(io);
    try testing.expectEqual(@as(u32, 0), concurrency_active);
}

test "cloneEnvironMap: produces an independent copy (v1.24.2 race fix)" {
    const gpa = testing.allocator;
    var src = std.process.Environ.Map.init(gpa);
    defer src.deinit();
    try src.put("FOO", "1");
    try src.put("BAR", "x");

    var clone = try cloneEnvironMap(gpa, &src);
    defer clone.deinit();

    try testing.expectEqualStrings("1", clone.get("FOO").?);
    try testing.expectEqualStrings("x", clone.get("BAR").?);

    // Mutating the clone must not affect the source — this is what
    // protects parallel `subagent` calls from corrupting each
    // other's env via `applyProfile.put(...)`.
    try clone.put("FOO", "999");
    try clone.put("NEW", "from-clone");
    try testing.expectEqualStrings("1", src.get("FOO").?);
    try testing.expect(src.get("NEW") == null);
}

// ─── §6.6 progress handler tests ──────────────────────────────────

test "subagentProgressHandler: turn_start/turn_end are no-ops (turn removed)" {
    const gpa = testing.allocator;
    const test_h = @import("../../test_helpers.zig");
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const TestState = struct {
        calls: u32 = 0,

        fn callback(userdata: ?*anyopaque, call_id: []const u8, update_json: []const u8) void {
            _ = call_id;
            _ = update_json;
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            self.calls += 1;
        }
    };

    var ts: TestState = .{};
    const test_ctx: Ctx = .{
        .registry = undefined,
        .environ = .empty,
        .environ_map = undefined,
        .parent_tools = &.{},
        .parent_role = .read,
        .presets = undefined,
        .parameters_json_owned = "",
        .permission_store = null,
        .parent_session_dir = null,
        .progress_fn = TestState.callback,
        .progress_userdata = &ts,
        .verbose_progress = false,
    };

    var fwd: ForwardState = .{
        .io = io,
        .allocator = gpa,
        .call_id = "call-1",
        .ctx = &test_ctx,
        .tool_names = .{},
        .names_mutex = .init,
    };
    defer fwd.deinit();

    // turn_start and turn_end must NOT fire progress_fn — the turn
    // counter was removed (not needed for web-ui proxy mode).
    subagentProgressHandler(&fwd, .turn_start);
    try testing.expectEqual(@as(u32, 0), ts.calls);

    subagentProgressHandler(&fwd, .turn_end);
    try testing.expectEqual(@as(u32, 0), ts.calls);

    subagentProgressHandler(&fwd, .turn_start);
    try testing.expectEqual(@as(u32, 0), ts.calls);
}

test "subagentProgressHandler: verbose_progress=false suppresses text_delta" {
    const gpa = testing.allocator;
    const test_h = @import("../../test_helpers.zig");
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const TestCounter = struct {
        calls: u32 = 0,
        fn callback(userdata: ?*anyopaque, call_id: []const u8, update_json: []const u8) void {
            _ = call_id;
            _ = update_json;
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            self.calls += 1;
        }
    };

    var ctr: TestCounter = .{};
    const test_ctx: Ctx = .{
        .registry = undefined,
        .environ = .empty,
        .environ_map = undefined,
        .parent_tools = &.{},
        .parent_role = .read,
        .presets = undefined,
        .parameters_json_owned = "",
        .permission_store = null,
        .parent_session_dir = null,
        .progress_fn = TestCounter.callback,
        .progress_userdata = &ctr,
        .verbose_progress = false,
    };

    var fwd: ForwardState = .{
        .io = io,
        .allocator = gpa,
        .call_id = "call-2",
        .ctx = &test_ctx,
        .tool_names = .{},
        .names_mutex = .init,
    };
    defer fwd.deinit();

    // text delta must NOT be forwarded when verbose_progress=false.
    const delta_ev: at.AgentEvent = .{ .message_update = .{ .text = .{
        .block_index = 0,
        .delta = "hello world",
    } } };
    subagentProgressHandler(&fwd, delta_ev);
    try testing.expectEqual(@as(u32, 0), ctr.calls);

    // thinking delta must NOT be forwarded when verbose_progress=false.
    const think_ev: at.AgentEvent = .{ .message_update = .{ .thinking = .{
        .block_index = 0,
        .delta = "reasoning...",
    } } };
    subagentProgressHandler(&fwd, think_ev);
    try testing.expectEqual(@as(u32, 0), ctr.calls);

    // turn_start is also suppressed (turn removed — not needed for web-ui proxy mode).
    subagentProgressHandler(&fwd, .turn_start);
    try testing.expectEqual(@as(u32, 0), ctr.calls);
}

test "executeUnconfigured returns config_error" {
    const gpa = testing.allocator;
    var threaded = @import("../../test_helpers.zig").threadedIo();
    defer threaded.deinit();
    var cancel = ai.stream.Cancel{};

    const t = tool();
    var r = try t.execute(&t, gpa, threaded.io(), "call-1", "{\"profile\":\"x\",\"prompt\":\"y\"}", &cancel, .{});
    defer r.deinit(gpa);
    try testing.expect(r.is_error);
    try testing.expectEqualStrings("config_error", r.tool_code.?);
}
