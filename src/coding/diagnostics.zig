//! v1.29.1 — single-shot session diagnostics.
//!
//! Walks a transcript + optional `http_trace_dir` + optional
//! `session_dir` and renders a human-readable report mirroring the
//! process documented in `docs/reference/diagnostics.md`. Pure (no
//! IO except the optional trace-dir scan); easy to drive from a
//! slash command, an RPC handler, or a future `franky doctor`
//! subcommand.

const std = @import("std");
const ai = struct {
    pub const types = @import("../ai/types.zig");
};
const agent = @import("../agent/mod.zig");
const utils = @import("../ai/utils.zig");

/// Inputs the analyzer needs. All optional fields degrade gracefully
/// when missing — interactive mode passes only `transcript` and the
/// configured `http_trace_dir`; print mode would also pass
/// `session_dir` so reducer-dump pointers light up.
pub const Options = struct {
    /// Caller-owned. The analyzer only reads.
    transcript: []const ai.types.Message,
    /// `--http-trace-dir` value when set, else null. The analyzer
    /// uses this only to pretty-print the *expected* trace path; it
    /// does not stat the directory.
    http_trace_dir: ?[]const u8 = null,
    /// `<parent_dir>/<session_id>` when known (print/proxy/rpc),
    /// else null. When set, the analyzer renders the
    /// expected reducer-dump path for each degenerate turn so the
    /// user can `cat` it.
    session_dir: ?[]const u8 = null,
    /// Free-form display-only label (e.g. "interactive (in-memory)"
    /// or "session 01JD…"); rendered in the header.
    session_label: ?[]const u8 = null,
    /// "interactive", "print", "proxy", "rpc" — display only.
    mode_name: ?[]const u8 = null,
    /// v1.29.6 — display-only provider name (e.g. "google",
    /// "anthropic", "openai"). Rendered in the header so anyone
    /// reading the diagnostics knows which provider's quirks to
    /// suspect (Gemini's thinking-budget exhaustion vs OpenAI's
    /// tool-call shape, etc.).
    provider: ?[]const u8 = null,
    /// v1.29.6 — display-only model id (e.g. "gemini-2.5-pro",
    /// "claude-sonnet-4-5"). Rendered in the header alongside
    /// `provider` for the same reason.
    model: ?[]const u8 = null,
};

/// Anomaly classes flagged by the per-turn checks. The order
/// matches the diagnostics doc's worked examples.
pub const Anomaly = enum {
    /// `was_degenerate=true` on a clean stop_reason. Layer 2 of the
    /// diagnostics doc.
    degenerate,
    /// Assistant text content matches `^call:NAME{...}` or `"name":
    /// "X", "parameters": {...}` — model wrote a tool call as prose.
    prose_tool_call,
    /// `parts_seen==0 AND candidates_tokens==0 AND thoughts_tokens>0`
    /// — Gemini-shaped thinking-budget exhaustion. Often co-occurs
    /// with degenerate.
    thinking_budget_exhaustion,
    /// Saved error_message field is non-null. Pre-v1.29.0 transcripts
    /// only — current code surfaces these as agent_error events
    /// outside the saved transcript.
    saved_error,
    /// One or more tool calls on this assistant turn produced a
    /// `tool_result` with `is_error=true`. v1.29.3 — surfaces sub-
    /// agent timeouts, role denials, bash non-zero exits, edit
    /// `path_escape_workspace`, etc. The per-failure detail (tool
    /// name + code + message + hint) lives on `Turn.tool_failures`.
    tool_error,

    pub fn label(self: Anomaly) []const u8 {
        return switch (self) {
            .degenerate => "DEGENERATE",
            .prose_tool_call => "PROSE_TOOL_CALL",
            .thinking_budget_exhaustion => "THINKING_BUDGET_EXHAUSTION",
            .saved_error => "SAVED_ERROR",
            .tool_error => "TOOL_ERROR",
        };
    }

    pub fn hint(self: Anomaly) []const u8 {
        return switch (self) {
            .degenerate => "Provider closed cleanly with no content blocks. " ++
                "Try `--thinking off` or `--thinking low`, switch provider, " ++
                "or `--append-system-prompt` a tool-format reminder.",
            .prose_tool_call => "Model emitted prose-shaped tool-call syntax instead of " ++
                "a structured call. Inject a system-prompt nudge: " ++
                "\"Emit tool calls as structured functionCall parts, not text.\"",
            .thinking_budget_exhaustion => "Token math suggests the model burned reasoning " ++
                "budget without producing output. Lower `--thinking` or switch model.",
            .saved_error => "Pre-v1.29.0 transcript stored an error_message inline. " ++
                "v1.29.0+ surfaces these as agent_error events instead.",
            .tool_error => "One or more tool calls returned an error result. " ++
                "See per-failure detail below.",
        };
    }
};

/// One failed tool call discovered while walking the transcript.
/// Strings are owned by the report's allocator; `Turn.deinit`
/// frees them.
pub const ToolFailure = struct {
    call_id: []u8,
    tool_name: []u8,
    /// Sub-code for diagnosis: `tool_code` for builtins (e.g.
    /// `edit_no_match`, `bash_timeout`, `path_escape_workspace`,
    /// `role_denied`), or `error_kind` for sub-agent failures
    /// (e.g. `timeout`, `auth`, `transport`, `config_error`).
    code: ?[]u8 = null,
    message: ?[]u8 = null,
    /// Sub-agent failures emit a `hint` field; surfaced verbatim.
    hint: ?[]u8 = null,

    pub fn deinit(self: ToolFailure, allocator: std.mem.Allocator) void {
        allocator.free(self.call_id);
        allocator.free(self.tool_name);
        if (self.code) |s| allocator.free(s);
        if (self.message) |s| allocator.free(s);
        if (self.hint) |s| allocator.free(s);
    }
};

/// Suggested recovery action for a given tool failure code. Pure
/// — no IO, no allocation. Returned slice is a static literal.
pub fn hintForToolError(code: ?[]const u8, message: ?[]const u8) []const u8 {
    const c = code orelse "";
    const m = message orelse "";
    if (std.mem.eql(u8, c, "timeout") or std.mem.indexOf(u8, m, "timeout") != null) {
        return "Provider was slow. Raise --first-byte-timeout-ms / --event-gap-timeout-ms (or set FRANKY_FIRST_BYTE_TIMEOUT_MS / FRANKY_EVENT_GAP_TIMEOUT_MS).";
    }
    if (std.mem.eql(u8, c, "auth") or std.mem.indexOf(u8, m, "credential") != null) {
        return "Auth failure. Check $ANTHROPIC_API_KEY / $OPENAI_API_KEY / $GEMINI_API_KEY, or pass --auth-token / a bearer-token record in $FRANKY_HOME/auth.json.";
    }
    if (std.mem.eql(u8, c, "rate_limited") or std.mem.eql(u8, c, "rate_limited_hard")) {
        return "Provider rate-limited the request. Back off and retry; check the provider dashboard for quota.";
    }
    if (std.mem.eql(u8, c, "transport") or std.mem.indexOf(u8, m, "connection") != null) {
        return "Network/transport failure. Check $HTTPS_PROXY; try `--http-trace-dir` to capture the failed request.";
    }
    if (std.mem.eql(u8, c, "role_denied")) {
        return "Tool blocked by capability role. Restart with a higher --role (read < plan < code < full); /role is read-only.";
    }
    if (std.mem.eql(u8, c, "tool_blocked") or std.mem.indexOf(u8, m, "permission") != null) {
        return "Permission overlay vetoed the call. Adjust --allow-tools / --deny-tools / --ask-tools, or pass --yes for CI.";
    }
    if (std.mem.eql(u8, c, "path_escape_workspace") or std.mem.indexOf(u8, m, "workspace") != null) {
        return "Path escapes the workspace root. Use a path under the session cwd, or restart from a wider root.";
    }
    // v1.29.6 — split edit_no_match vs edit_ambiguous: the recovery
    // is the OPPOSITE for the two cases. no_match means the `old`
    // string isn't in the file at all (often because the model is
    // working from a stale mental model of the file); ambiguous
    // means it matches multiple times (and DOES need more context).
    // Pre-v1.29.6 the no_match hint said "read the file again to
    // get the current bytes" but Gemini-2.5-pro was interpreting
    // that as "widen the old string with more surrounding text" —
    // making it worse, since the bigger guess still doesn't match.
    if (std.mem.eql(u8, c, "edit_no_match")) {
        return "Edit `old` not found. DO NOT widen `old` with more context — that won't help if the original guess is wrong. Re-read the file with the `read` tool to get the actual bytes, then copy-paste the exact text into `old`.";
    }
    if (std.mem.eql(u8, c, "edit_file_empty")) {
        return "Target file is empty (0 bytes). The `edit` tool replaces existing content; for an empty file use the `write` tool with `overwrite: true` to create initial content in one call.";
    }
    if (std.mem.eql(u8, c, "edit_ambiguous")) {
        return "Edit `old` matched multiple times. Widen `old` with more surrounding context (e.g. include the line above and below) until it uniquely identifies the target. If a function-/declaration-level match is still ambiguous, split into two edits.";
    }
    // Fallback: legacy no-code-match heuristic. Older transcripts
    // and some sub-agent envelopes carry "no match" in the message
    // without a structured tool_code.
    if (std.mem.indexOf(u8, m, "no match") != null) {
        return "Edit `old` not found. Re-read the file with the `read` tool and copy-paste the exact bytes into `old`; do not widen the search string.";
    }
    if (std.mem.eql(u8, c, "write_exists") or std.mem.indexOf(u8, m, "already exists") != null) {
        return "File already exists. Pass `overwrite: true` to replace, OR use the `edit` tool to make a targeted change instead of rewriting the whole file.";
    }
    if (std.mem.eql(u8, c, "invalid_args")) {
        return "Tool was called with invalid arguments. The error message names the missing/bad field — re-call with the correct shape; check the tool's schema if unsure.";
    }
    if (std.mem.eql(u8, c, "bash_timeout")) {
        return "Bash command exceeded its hard timeout. Pass `timeoutMs` argument explicitly, or split the command.";
    }
    if (std.mem.eql(u8, c, "read_too_large") or std.mem.eql(u8, c, "read_line_too_large")) {
        return "File too large for an unbounded read. Paginate with `offset` + `limit`, or use the `bash sed` fallback in the error.";
    }
    if (std.mem.eql(u8, c, "agent_error") or std.mem.indexOf(u8, m, "sub-agent failed") != null) {
        // Generic sub-agent envelope — recurse on the inner error text.
        return "Sub-agent failed. Re-run with a narrower prompt, or invoke the failing tool directly to see the underlying error.";
    }
    return "Re-run the tool with adjusted arguments; check `tool_code` against `docs/spec/v1.md` §F.2 for the canonical sub-codes.";
}

/// Per-turn record, one per assistant message.
pub const Turn = struct {
    index: usize, // 0-based across all messages
    timestamp_ms: i64,
    stop_reason: ?ai.types.StopReason,
    diagnostics: ?ai.types.Diagnostics,
    /// Counts of each content-block kind on the saved message.
    text_blocks: u32 = 0,
    thinking_blocks: u32 = 0,
    tool_call_blocks: u32 = 0,
    /// First text block's content (referenced — caller's transcript
    /// owns it). Used for prose-tool-call detection display.
    first_text_excerpt: ?[]const u8 = null,
    /// Anomaly set, ordered as listed.
    anomalies: std.ArrayList(Anomaly) = .empty,
    /// v1.29.3 — failures bound to this turn via tool_call_id.
    /// Owned strings; freed in deinit.
    tool_failures: std.ArrayList(ToolFailure) = .empty,

    pub fn deinit(self: *Turn, allocator: std.mem.Allocator) void {
        self.anomalies.deinit(allocator);
        for (self.tool_failures.items) |f| f.deinit(allocator);
        self.tool_failures.deinit(allocator);
    }

    pub fn hasAny(self: *const Turn) bool {
        return self.anomalies.items.len > 0;
    }
};

pub const Report = struct {
    allocator: std.mem.Allocator,
    turns: std.ArrayList(Turn) = .empty,
    total_messages: usize = 0,
    total_assistant_turns: usize = 0,
    total_anomalies: usize = 0,

    pub fn deinit(self: *Report) void {
        for (self.turns.items) |*t| t.deinit(self.allocator);
        self.turns.deinit(self.allocator);
    }

    /// Sum of `tool_call_blocks` across all assistant turns.
    pub fn totalToolCalls(self: *const Report) u32 {
        var sum: u32 = 0;
        for (self.turns.items) |t| sum += t.tool_call_blocks;
        return sum;
    }

    /// Sum of failed tool calls (each turn's `tool_failures.items.len`).
    pub fn totalToolFailures(self: *const Report) u32 {
        var sum: u32 = 0;
        for (self.turns.items) |t| sum += @intCast(t.tool_failures.items.len);
        return sum;
    }

    /// Count occurrences per `Anomaly` variant. Returns a fixed-size
    /// slice indexed by the enum's tag integer value — callers can
    /// `[@intFromEnum(Anomaly.degenerate)]` etc.
    pub fn anomalyCounts(self: *const Report) [5]u32 {
        var counts: [5]u32 = .{ 0, 0, 0, 0, 0 };
        for (self.turns.items) |t| {
            for (t.anomalies.items) |a| counts[@intFromEnum(a)] += 1;
        }
        return counts;
    }

    /// Sum the per-turn `Diagnostics` token + parts counters across
    /// the report. Null Diagnostics or null token fields are treated
    /// as zero — pre-v1.29.0 transcripts have no diagnostics, so
    /// totals stay 0.
    pub fn tokenTotals(self: *const Report) TokenTotals {
        var t: TokenTotals = .{};
        for (self.turns.items) |turn| {
            const d = turn.diagnostics orelse continue;
            t.candidates += d.candidates_tokens orelse 0;
            t.thoughts += d.thoughts_tokens orelse 0;
            t.parts_seen += d.parts_seen;
        }
        return t;
    }
};

pub const TokenTotals = struct {
    candidates: u64 = 0,
    thoughts: u64 = 0,
    parts_seen: u64 = 0,
};

/// Analyze a transcript. The returned `Report` is owned by the
/// caller; call `Report.deinit` when done.
pub fn analyze(
    allocator: std.mem.Allocator,
    opts: Options,
) !Report {
    var report: Report = .{ .allocator = allocator };
    errdefer report.deinit();
    report.total_messages = opts.transcript.len;

    // Map call_id → (turn_ord_in_report, tool_name) so we can attach
    // tool_result failures to the assistant turn that issued them.
    // Uses borrowed slices into the caller's transcript; valid for
    // the duration of `analyze`.
    var call_index: std.StringHashMap(CallSlot) = .init(allocator);
    defer call_index.deinit();

    for (opts.transcript, 0..) |m, i| {
        switch (m.role) {
            .assistant => {
                const turn_ord = report.turns.items.len;
                report.total_assistant_turns += 1;

                var turn: Turn = .{
                    .index = i,
                    .timestamp_ms = m.timestamp,
                    .stop_reason = m.stop_reason,
                    .diagnostics = m.diagnostics,
                };

                // Per-block-kind counts + first text excerpt + record
                // call_ids for later tool_result lookup.
                for (m.content) |cb| switch (cb) {
                    .text => |t| {
                        turn.text_blocks += 1;
                        if (turn.first_text_excerpt == null) turn.first_text_excerpt = t.text;
                    },
                    .thinking => turn.thinking_blocks += 1,
                    .tool_call => |tc| {
                        turn.tool_call_blocks += 1;
                        try call_index.put(tc.id, .{ .turn_ord = turn_ord, .tool_name = tc.name });
                    },
                    .image => {},
                };

                // Anomaly checks (assistant-only).
                if (m.diagnostics) |d| if (d.was_degenerate) {
                    try turn.anomalies.append(allocator, .degenerate);
                };
                if (m.diagnostics) |d| {
                    const empty_candidates = (d.candidates_tokens orelse 0) == 0;
                    const has_thoughts = (d.thoughts_tokens orelse 0) > 0;
                    if (d.parts_seen == 0 and empty_candidates and has_thoughts) {
                        try turn.anomalies.append(allocator, .thinking_budget_exhaustion);
                    }
                }
                if (turn.first_text_excerpt) |txt| {
                    if (looksLikeProseToolCall(txt)) {
                        try turn.anomalies.append(allocator, .prose_tool_call);
                    }
                }
                if (m.error_message != null) {
                    try turn.anomalies.append(allocator, .saved_error);
                }

                try report.turns.append(allocator, turn);
            },
            .tool_result => {
                if (!m.is_error) continue;
                const cid = m.tool_call_id orelse continue;
                const slot = call_index.get(cid) orelse continue;
                if (slot.turn_ord >= report.turns.items.len) continue;

                const failure = try parseToolFailure(allocator, cid, slot.tool_name, m);
                var turn = &report.turns.items[slot.turn_ord];
                try turn.tool_failures.append(allocator, failure);
                // Add TOOL_ERROR anomaly at most once per turn (the
                // per-failure detail lives on `tool_failures`).
                var already = false;
                for (turn.anomalies.items) |a| if (a == .tool_error) {
                    already = true;
                };
                if (!already) try turn.anomalies.append(allocator, .tool_error);
            },
            else => {},
        }
    }

    // Tally anomalies after the second pass has had a chance to
    // append `tool_error`.
    for (report.turns.items) |t| report.total_anomalies += t.anomalies.items.len;

    return report;
}

const CallSlot = struct {
    turn_ord: usize,
    tool_name: []const u8,
};

/// Parse a saved tool_result message into a `ToolFailure`. Two
/// shapes coexist: built-in `[code] msg` text (`common.toolError`)
/// and sub-agent JSON (`{"ok":false,"error_kind":"...",...}`).
/// Falls back to the raw text as `message` when neither matches.
fn parseToolFailure(
    allocator: std.mem.Allocator,
    call_id: []const u8,
    tool_name: []const u8,
    m: ai.types.Message,
) !ToolFailure {
    const owned_id = try allocator.dupe(u8, call_id);
    errdefer allocator.free(owned_id);
    const owned_name = try allocator.dupe(u8, tool_name);
    errdefer allocator.free(owned_name);

    // First text block carries the error payload by convention.
    var raw_text: []const u8 = "";
    for (m.content) |cb| switch (cb) {
        .text => |t| {
            raw_text = t.text;
            break;
        },
        else => {},
    };

    var code_owned: ?[]u8 = null;
    var msg_owned: ?[]u8 = null;
    var hint_owned: ?[]u8 = null;
    errdefer if (code_owned) |s| allocator.free(s);
    errdefer if (msg_owned) |s| allocator.free(s);
    errdefer if (hint_owned) |s| allocator.free(s);

    const trimmed = std.mem.trim(u8, raw_text, " \t\r\n");
    if (trimmed.len > 0 and trimmed[0] == '{') {
        // Try sub-agent JSON shape.
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        if (std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), trimmed, .{})) |v| {
            if (v == .object) {
                if (v.object.get("error_kind")) |ek| if (ek == .string) {
                    code_owned = try allocator.dupe(u8, ek.string);
                };
                if (v.object.get("error_message")) |em| if (em == .string) {
                    msg_owned = try allocator.dupe(u8, em.string);
                };
                if (v.object.get("hint")) |h| if (h == .string) {
                    hint_owned = try allocator.dupe(u8, h.string);
                };
            }
        } else |_| {}
    } else if (trimmed.len > 2 and trimmed[0] == '[') {
        // Built-in "[code] msg" shape.
        if (std.mem.indexOfScalar(u8, trimmed, ']')) |close| {
            code_owned = try allocator.dupe(u8, trimmed[1..close]);
            const after = std.mem.trim(u8, trimmed[close + 1 ..], " \t");
            if (after.len > 0) msg_owned = try allocator.dupe(u8, after);
        }
    }

    // Fallback: at least preserve the raw text as the message so
    // the renderer has something to show.
    if (msg_owned == null and raw_text.len > 0) {
        const cap = @min(raw_text.len, 240);
        msg_owned = try allocator.dupe(u8, raw_text[0..cap]);
    }

    return .{
        .call_id = owned_id,
        .tool_name = owned_name,
        .code = code_owned,
        .message = msg_owned,
        .hint = hint_owned,
    };
}

/// Heuristic: does this text look like the model wrote a tool call
/// as prose instead of emitting a structured call? Catches the two
/// shapes seen in the wild:
///   - `call:NAME{...}` (Gemini-flavored)
///   - leading `{"name":"X","parameters":{...}}` JSON-shaped
/// Conservative — only fires when one of these patterns dominates
/// the start of the text. Mid-text occurrences inside legitimate
/// prose are intentionally not flagged.
pub fn looksLikeProseToolCall(text: []const u8) bool {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (t.len == 0) return false;
    // Pattern A: `call:` + identifier + `{`
    if (std.mem.startsWith(u8, t, "call:")) {
        const rest = t[5..];
        if (rest.len > 0 and (std.ascii.isAlphanumeric(rest[0]) or rest[0] == '_')) {
            // walk past the identifier
            var i: usize = 0;
            while (i < rest.len and (std.ascii.isAlphanumeric(rest[i]) or rest[i] == '_' or rest[i] == '-')) i += 1;
            if (i < rest.len and rest[i] == '{') return true;
        }
    }
    // Pattern B: `{"name":...,"parameters":...}` or
    // `{"type":"function","function":{...}}` — a JSON object whose
    // first or second key matches a known tool-call shape.
    if (t[0] == '{' and t.len > 16) {
        if (std.mem.indexOf(u8, t[0..@min(t.len, 256)], "\"name\":") != null and
            std.mem.indexOf(u8, t[0..@min(t.len, 256)], "\"parameters\":") != null) return true;
        if (std.mem.indexOf(u8, t[0..@min(t.len, 256)], "\"type\":\"function\"") != null and
            std.mem.indexOf(u8, t[0..@min(t.len, 256)], "\"function\":") != null) return true;
    }
    return false;
}

/// Render the report as text. Caller owns the result.
///
/// Rough output shape:
///   === franky diagnostics ===
///   mode:        interactive
///   session:     interactive (in-memory)
///   trace dir:   /tmp/franky-trace
///   reducer dir: <unset — interactive mode>
///   transcript:  5 assistant turns / 9 messages
///
///   Per-turn:
///     #1  ts=…  stop=stop  blocks=text:3  parts=3 cand=12 thoughts=0
///     #2  ts=…  stop=stop  blocks=text:1,toolCall:1
///     #5  ts=…  stop=stop  blocks=text:1
///        FLAGS: PROSE_TOOL_CALL, THINKING_BUDGET_EXHAUSTION, DEGENERATE
///        first text: "call:read{path:src/coding/tools/grep.zig}"
///        trace:      /tmp/franky-trace/<trace_id>-google-gemini.txt
///        reducer:    <session>/events/turn-N.reducer-dump.json
///        HINT (PROSE_TOOL_CALL): …
///        HINT (THINKING_BUDGET_EXHAUSTION): …
///        HINT (DEGENERATE): …
///
///   Summary: 1 anomaly across 5 turns
///   Reference: docs/reference/diagnostics.md
pub fn render(
    allocator: std.mem.Allocator,
    report: *const Report,
    opts: Options,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "=== franky diagnostics ===\n");
    {
        const line = try std.fmt.allocPrint(
            allocator,
            "mode:        {s}\nsession:     {s}\nprovider:    {s}\nmodel:       {s}\ntrace dir:   {s}\nreducer dir: {s}\ntranscript:  {d} assistant turns / {d} messages\n",
            .{
                opts.mode_name orelse "?",
                opts.session_label orelse "?",
                opts.provider orelse "?",
                opts.model orelse "?",
                opts.http_trace_dir orelse "<unset — pass --http-trace-dir to capture>",
                opts.session_dir orelse "<unset — interactive mode has no on-disk session>",
                report.total_assistant_turns,
                report.total_messages,
            },
        );
        defer allocator.free(line);
        try buf.appendSlice(allocator, line);
    }

    if (report.turns.items.len == 0) {
        try buf.appendSlice(allocator, "\n(no assistant turns yet — run a prompt first)\n");
        return try buf.toOwnedSlice(allocator);
    }

    try buf.appendSlice(allocator, "\nPer-turn:\n");
    for (report.turns.items, 0..) |t, ord| {
        try renderTurn(allocator, &buf, t, ord, opts);
    }

    try buf.appendSlice(allocator, "\nSummary: ");
    {
        const line = try std.fmt.allocPrint(
            allocator,
            "{d} anomaly across {d} turns\n",
            .{ report.total_anomalies, report.total_assistant_turns },
        );
        defer allocator.free(line);
        try buf.appendSlice(allocator, line);
    }
    if (report.total_anomalies == 0) {
        try buf.appendSlice(allocator, "(all turns clean)\n");
    }
    try buf.appendSlice(allocator, "Reference: docs/reference/diagnostics.md\n");
    return try buf.toOwnedSlice(allocator);
}

fn renderTurn(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    t: Turn,
    ord: usize,
    opts: Options,
) !void {
    // Header: turn number + timestamp + stop_reason + block kinds.
    var blocks_str: std.ArrayList(u8) = .empty;
    defer blocks_str.deinit(allocator);
    if (t.text_blocks > 0) {
        const s = try std.fmt.allocPrint(allocator, "text:{d}", .{t.text_blocks});
        defer allocator.free(s);
        try blocks_str.appendSlice(allocator, s);
    }
    if (t.thinking_blocks > 0) {
        if (blocks_str.items.len > 0) try blocks_str.append(allocator, ',');
        const s = try std.fmt.allocPrint(allocator, "thinking:{d}", .{t.thinking_blocks});
        defer allocator.free(s);
        try blocks_str.appendSlice(allocator, s);
    }
    if (t.tool_call_blocks > 0) {
        if (blocks_str.items.len > 0) try blocks_str.append(allocator, ',');
        const s = try std.fmt.allocPrint(allocator, "toolCall:{d}", .{t.tool_call_blocks});
        defer allocator.free(s);
        try blocks_str.appendSlice(allocator, s);
    }
    if (blocks_str.items.len == 0) try blocks_str.appendSlice(allocator, "(none)");

    const stop_str: []const u8 = if (t.stop_reason) |sr| sr.toString() else "?";
    const head = try std.fmt.allocPrint(
        allocator,
        "  #{d}  ts={d}  stop={s}  blocks={s}",
        .{ ord + 1, t.timestamp_ms, stop_str, blocks_str.items },
    );
    defer allocator.free(head);
    try buf.appendSlice(allocator, head);

    // Diagnostics counters one-liner.
    if (t.diagnostics) |d| {
        const parts = d.parts_seen;
        const cand = d.candidates_tokens orelse 0;
        const thoughts = d.thoughts_tokens orelse 0;
        const ev = d.text_event_count + d.thinking_event_count + d.tool_call_event_count;
        const dline = try std.fmt.allocPrint(
            allocator,
            "  parts={d} cand={d} thoughts={d} events={d}",
            .{ parts, cand, thoughts, ev },
        );
        defer allocator.free(dline);
        try buf.appendSlice(allocator, dline);
    }
    try buf.append(allocator, '\n');

    if (t.anomalies.items.len == 0) return;

    // FLAGS line.
    try buf.appendSlice(allocator, "      FLAGS: ");
    for (t.anomalies.items, 0..) |a, j| {
        if (j > 0) try buf.appendSlice(allocator, ", ");
        try buf.appendSlice(allocator, a.label());
    }
    try buf.append(allocator, '\n');

    // First-text excerpt (truncated to 80 chars).
    if (t.first_text_excerpt) |txt| {
        const max_excerpt: usize = 80;
        const trimmed = std.mem.trim(u8, txt, " \t\r\n");
        const cut = if (trimmed.len > max_excerpt) trimmed[0..max_excerpt] else trimmed;
        const ellipsis = if (trimmed.len > max_excerpt) "…" else "";
        const line = try std.fmt.allocPrint(allocator, "      first text: \"{s}{s}\"\n", .{ cut, ellipsis });
        defer allocator.free(line);
        try buf.appendSlice(allocator, line);
    }

    // trace_id → trace path hint, plus a fixture-promotion shortcut
    // when both http_trace_dir and the turn carry an anomaly worth
    // pinning. The promotion line shows up exactly when the bug
    // signal IS the trace — diagnostic flags without a stored trace
    // can't be replayed.
    if (t.diagnostics) |d| if (d.trace_id) |tid| {
        if (opts.http_trace_dir) |dir| {
            const line = try std.fmt.allocPrint(
                allocator,
                "      trace:      {s}/{s}-<provider>.txt\n",
                .{ dir, tid },
            );
            defer allocator.free(line);
            try buf.appendSlice(allocator, line);

            if (t.anomalies.items.len > 0) {
                const fixture_line = try std.fmt.allocPrint(
                    allocator,
                    "      → fixture:  franky fixture {s}/{s}-<provider>.txt --name <descriptive>\n",
                    .{ dir, tid },
                );
                defer allocator.free(fixture_line);
                try buf.appendSlice(allocator, fixture_line);
            }
        } else {
            const line = try std.fmt.allocPrint(
                allocator,
                "      trace_id:   {s}  (set --http-trace-dir to capture next time)\n",
                .{tid},
            );
            defer allocator.free(line);
            try buf.appendSlice(allocator, line);
        }
    };

    // reducer-dump path hint when degenerate + session_dir known.
    var has_degenerate = false;
    for (t.anomalies.items) |a| if (a == .degenerate) {
        has_degenerate = true;
    };
    if (has_degenerate) {
        if (opts.session_dir) |sd| {
            const line = try std.fmt.allocPrint(
                allocator,
                "      reducer:    {s}/events/turn-<N>.reducer-dump.json\n",
                .{sd},
            );
            defer allocator.free(line);
            try buf.appendSlice(allocator, line);
        } else {
            try buf.appendSlice(
                allocator,
                "      reducer:    <not available — interactive mode has no on-disk dumps>\n",
            );
        }
    }

    // Per-failure detail. Comes BEFORE the generic anomaly hints so
    // the most actionable info (the actual sub-agent error message
    // + hint) is closest to the FLAGS line.
    for (t.tool_failures.items) |f| {
        const code_str = f.code orelse "(no code)";
        const msg_str = f.message orelse "(no message)";
        const max_msg: usize = 200;
        const trimmed_msg = if (msg_str.len > max_msg) msg_str[0..max_msg] else msg_str;
        const ellipsis = if (msg_str.len > max_msg) "…" else "";
        const failure_line = try std.fmt.allocPrint(
            allocator,
            "      tool failure: {s} ({s}) — {s}: {s}{s}\n",
            .{ f.tool_name, f.call_id, code_str, trimmed_msg, ellipsis },
        );
        defer allocator.free(failure_line);
        try buf.appendSlice(allocator, failure_line);

        if (f.hint) |h| {
            const line = try std.fmt.allocPrint(allocator, "        provider hint: {s}\n", .{h});
            defer allocator.free(line);
            try buf.appendSlice(allocator, line);
        }
        // Targeted recovery suggestion based on code+message.
        const recovery = hintForToolError(f.code, f.message);
        const line2 = try std.fmt.allocPrint(allocator, "        HINT: {s}\n", .{recovery});
        defer allocator.free(line2);
        try buf.appendSlice(allocator, line2);
    }

    // Hints, one per anomaly. Skip TOOL_ERROR — the per-failure
    // bullet above already gave the actionable hint.
    for (t.anomalies.items) |a| {
        if (a == .tool_error) continue;
        const line = try std.fmt.allocPrint(allocator, "      HINT ({s}): {s}\n", .{ a.label(), a.hint() });
        defer allocator.free(line);
        try buf.appendSlice(allocator, line);
    }
}

/// Resolve `$FRANKY_HOME` (preferred) or `$HOME/.franky`. Returns
/// a caller-owned slice, or `null` when neither env var is set.
pub fn resolveFrankyHome(
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
) !?[]u8 {
    if (environ_map.get("FRANKY_HOME")) |h| if (h.len > 0) {
        return try allocator.dupe(u8, h);
    };
    if (environ_map.get("HOME")) |h| if (h.len > 0) {
        return try std.fs.path.join(allocator, &.{ h, ".franky" });
    };
    return null;
}

// ─── persistence ───────────────────────────────────────────────────

pub const PersistOptions = struct {
    /// Resolved `$FRANKY_HOME` (default `$HOME/.franky`). Caller
    /// owns; analyzer only reads.
    franky_home: []const u8,
    /// Identifier for the session sub-directory. For modes with a
    /// real on-disk session id (print/proxy) this is the ULID; for
    /// modes without (interactive/rpc) the caller synthesizes a
    /// stable label like `interactive-<startup_ms>` so multiple
    /// `/diagnostics` invocations land alongside each other.
    session_id: []const u8,
    /// Unix millis used for the filename — caller-supplied so tests
    /// can pin a deterministic value. Production callers pass
    /// `ai.stream.nowMillis()`.
    timestamp_ms: i64,
};

pub const PersistResult = struct {
    /// Absolute path to the written file. Caller owns this slice.
    path: []u8,

    pub fn deinit(self: PersistResult, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

/// Serialize a `Report` to a stable, machine-readable JSON shape.
/// Used by the cross-session aggregator (`coding/improvement.zig`)
/// to mine patterns across many sessions without re-running the
/// per-session analyzer. Schema version is bumped (v2, v3, …) when
/// fields are renamed or removed; consumers must check
/// `schema_version` before parsing.
///
/// `report_path` is the absolute path to the human-rendered TXT
/// report this summary corresponds to (i.e. the file `persist`
/// just wrote). Embedded in the JSON so an aggregator pulling a
/// finding from `summary.json` can hand the user a direct pointer
/// to the human-readable detail. `null` when toJson is called
/// outside `runAndPersist`'s orchestration.
///
/// Note: this is a SUMMARY view — the per-turn anomaly detail is
/// rolled into counts. Callers that need turn-level data should
/// load the full transcript.json or re-run `analyze`.
pub fn toJson(
    allocator: std.mem.Allocator,
    report: *const Report,
    opts: Options,
    report_path: ?[]const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"schema_version\":1,");

    try writeIdentityFields(&buf, allocator, &opts, report_path);
    try writeTotalsFields(&buf, allocator, report);
    try writeAnomalyCounts(&buf, allocator, report);
    try writeTokenTotals(&buf, allocator, report);
    try writeToolFailures(&buf, allocator, report);

    try buf.appendSlice(allocator, "]}");

    return buf.toOwnedSlice(allocator);
}

fn writeIdentityFields(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, opts: *const Options, report_path: ?[]const u8) !void {
    try buf.appendSlice(allocator, "\"session_id\":");
    try writeOptStr(buf, allocator, opts.session_label);
    try buf.appendSlice(allocator, ",\"model\":");
    try writeOptStr(buf, allocator, opts.model);
    try buf.appendSlice(allocator, ",\"provider\":");
    try writeOptStr(buf, allocator, opts.provider);
    try buf.appendSlice(allocator, ",\"mode\":");
    try writeOptStr(buf, allocator, opts.mode_name);
    try buf.appendSlice(allocator, ",\"report_path\":");
    try writeOptStr(buf, allocator, report_path);
}

fn writeTotalsFields(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, report: *const Report) !void {
    const tool_calls = report.totalToolCalls();
    const tool_failures = report.totalToolFailures();
    try buf.appendSlice(allocator, ",\"totals\":{");
    try writeIntField(buf, allocator, "messages", @intCast(report.total_messages));
    try buf.appendSlice(allocator, ",");
    try writeIntField(buf, allocator, "assistant_turns", @intCast(report.total_assistant_turns));
    try buf.appendSlice(allocator, ",");
    try writeIntField(buf, allocator, "tool_calls", @intCast(tool_calls));
    try buf.appendSlice(allocator, ",");
    try writeIntField(buf, allocator, "tool_failures", @intCast(tool_failures));
    try buf.appendSlice(allocator, ",");
    try writeIntField(buf, allocator, "anomalies", @intCast(report.total_anomalies));
    try buf.appendSlice(allocator, "}");
}

fn writeAnomalyCounts(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, report: *const Report) !void {
    const ac = report.anomalyCounts();
    try buf.appendSlice(allocator, ",\"anomaly_counts\":{");
    try writeIntField(buf, allocator, "degenerate", @intCast(ac[@intFromEnum(Anomaly.degenerate)]));
    try buf.appendSlice(allocator, ",");
    try writeIntField(buf, allocator, "prose_tool_call", @intCast(ac[@intFromEnum(Anomaly.prose_tool_call)]));
    try buf.appendSlice(allocator, ",");
    try writeIntField(buf, allocator, "thinking_budget_exhaustion", @intCast(ac[@intFromEnum(Anomaly.thinking_budget_exhaustion)]));
    try buf.appendSlice(allocator, ",");
    try writeIntField(buf, allocator, "saved_error", @intCast(ac[@intFromEnum(Anomaly.saved_error)]));
    try buf.appendSlice(allocator, ",");
    try writeIntField(buf, allocator, "tool_error", @intCast(ac[@intFromEnum(Anomaly.tool_error)]));
    try buf.appendSlice(allocator, "}");
}

fn writeTokenTotals(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, report: *const Report) !void {
    const tt = report.tokenTotals();
    try buf.appendSlice(allocator, ",\"tokens\":{");
    try writeIntField(buf, allocator, "candidates", @intCast(tt.candidates));
    try buf.appendSlice(allocator, ",");
    try writeIntField(buf, allocator, "thoughts", @intCast(tt.thoughts));
    try buf.appendSlice(allocator, ",");
    try writeIntField(buf, allocator, "parts_seen", @intCast(tt.parts_seen));
    try buf.appendSlice(allocator, "}");
}

fn writeToolFailures(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, report: *const Report) !void {
    try buf.appendSlice(allocator, ",\"tool_failures\":[");
    var first = true;
    for (report.turns.items, 0..) |turn, turn_ord| {
        for (turn.tool_failures.items) |f| {
            if (!first) try buf.appendSlice(allocator, ",");
            first = false;
            try buf.appendSlice(allocator, "{");
            try writeIntField(buf, allocator, "turn_index", @intCast(turn_ord));
            try buf.appendSlice(allocator, ",\"tool_name\":");
            try utils.appendJsonStr(buf, allocator, f.tool_name);
            try buf.appendSlice(allocator, ",\"code\":");
            try writeOptStr(buf, allocator, f.code);
            try buf.appendSlice(allocator, ",\"message\":");
            try writeOptStr(buf, allocator, f.message);
            try buf.appendSlice(allocator, ",\"hint\":");
            try writeOptStr(buf, allocator, f.hint);
            try buf.appendSlice(allocator, "}");
        }
    }
}

fn writeOptStr(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, s: ?[]const u8) !void {
    if (s) |v| {
        try utils.appendJsonStr(buf, allocator, v);
    } else {
        try buf.appendSlice(allocator, "null");
    }
}

fn writeIntField(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, name: []const u8, n: i64) !void {
    try buf.append(allocator, '"');
    try buf.appendSlice(allocator, name);
    try buf.appendSlice(allocator, "\":");
    try utils.appendJsonInt(buf, allocator, n);
}

/// Persist a rendered diagnostics report to
/// `<franky_home>/diagnostics/<session_id>/<timestamp_ms>.txt`.
/// Creates the parent dir on demand. Returns the absolute path
/// the caller can surface to the user. IO errors propagate — let
/// the caller decide whether a persist failure should swallow or
/// loudly surface (interactive surfaces; proxy surfaces).
pub fn persist(
    allocator: std.mem.Allocator,
    io: std.Io,
    opts: PersistOptions,
    rendered: []const u8,
) !PersistResult {
    const dir = try std.fmt.allocPrint(
        allocator,
        "{s}/diagnostics/{s}",
        .{ opts.franky_home, opts.session_id },
    );
    defer allocator.free(dir);

    std.Io.Dir.cwd().createDirPath(io, dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };

    const path = try std.fmt.allocPrint(
        allocator,
        "{s}/{d}.txt",
        .{ dir, opts.timestamp_ms },
    );
    errdefer allocator.free(path);

    var f = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, rendered);

    return .{ .path = path };
}

/// Persist the structured `summary.json` to
/// `<franky_home>/diagnostics/<session_id>/summary.json`. Filename
/// is deterministic — the latest invocation overwrites the prior.
/// Same dir as `persist`'s timestamped TXT files; the cross-session
/// aggregator (`coding/improvement.zig`) reads this file rather
/// than parsing the human-rendered TXT.
pub fn persistJson(
    allocator: std.mem.Allocator,
    io: std.Io,
    opts: PersistOptions,
    json: []const u8,
) !PersistResult {
    const dir = try std.fmt.allocPrint(
        allocator,
        "{s}/diagnostics/{s}",
        .{ opts.franky_home, opts.session_id },
    );
    defer allocator.free(dir);

    std.Io.Dir.cwd().createDirPath(io, dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };

    const path = try std.fmt.allocPrint(
        allocator,
        "{s}/summary.json",
        .{dir},
    );
    errdefer allocator.free(path);

    var f = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, json);

    return .{ .path = path };
}

/// Convenience: analyze + render + persist in one call. Useful for
/// callers that don't need the intermediate `Report` struct.
/// Returns the rendered text AND the persisted path; caller frees
/// both. On persist failure, returns the rendered text + a null
/// path so the user still sees the report (file write is a
/// best-effort side channel).
pub const RunResult = struct {
    rendered: []u8,
    /// `null` when persistence wasn't attempted (no `persist`
    /// passed) OR the write failed. Callers should treat null as
    /// "not persisted" and continue rather than retrying.
    persisted_path: ?[]u8 = null,

    pub fn deinit(self: RunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.rendered);
        if (self.persisted_path) |p| allocator.free(p);
    }
};

pub fn runAndPersist(
    allocator: std.mem.Allocator,
    io: std.Io,
    opts: Options,
    persist_opts: ?PersistOptions,
) !RunResult {
    var report = try analyze(allocator, opts);
    defer report.deinit();
    const text = try render(allocator, &report, opts);
    errdefer allocator.free(text);

    var path_owned: ?[]u8 = null;
    if (persist_opts) |po| {
        if (persist(allocator, io, po, text)) |res| {
            path_owned = res.path;
        } else |_| {
            // Best-effort: a full diagnostics pipeline must not
            // fail because of a disk hiccup. Caller sees rendered
            // text; persisted_path stays null.
            path_owned = null;
        }
        // Also write the machine-readable summary.json. Failure to
        // write this is even more best-effort than the TXT — the
        // user-facing report is what matters; the JSON is an
        // optional input to the cross-session aggregator and a
        // missing file there just means that session won't show up
        // in trend reports until the user re-runs /diagnostics.
        // Path is deterministic (`<dir>/summary.json`) so we don't
        // surface it; the result's path slice is freed immediately.
        // Embed the TXT report path so aggregator findings can
        // drill back to the human-readable detail.
        if (toJson(allocator, &report, opts, path_owned)) |json| {
            defer allocator.free(json);
            if (persistJson(allocator, io, po, json)) |res| {
                allocator.free(res.path);
            } else |_| {}
        } else |_| {}
    }
    return .{ .rendered = text, .persisted_path = path_owned };
}

// ─── tests ────────────────────────────────────────────────────────

const testing = std.testing;

fn mkAssistant(
    allocator: std.mem.Allocator,
    text: []const u8,
    diag: ?ai.types.Diagnostics,
    stop: ai.types.StopReason,
) !ai.types.Message {
    const c = try allocator.alloc(ai.types.ContentBlock, 1);
    c[0] = .{ .text = .{ .text = try allocator.dupe(u8, text) } };
    return .{
        .role = .assistant,
        .content = c,
        .timestamp = 100,
        .stop_reason = stop,
        .diagnostics = diag,
    };
}

test "looksLikeProseToolCall flags Gemini call: pattern" {
    try testing.expect(looksLikeProseToolCall("call:read{path:src/coding/tools/grep.zig}"));
    try testing.expect(looksLikeProseToolCall("  call:read{path:foo}  "));
    try testing.expect(!looksLikeProseToolCall("Sure, I'll call:read soon."));
    try testing.expect(!looksLikeProseToolCall(""));
}

test "looksLikeProseToolCall flags JSON-shape leading text" {
    try testing.expect(looksLikeProseToolCall("{\"name\":\"read\",\"parameters\":{\"path\":\"x\"}}"));
    try testing.expect(looksLikeProseToolCall("{\"type\":\"function\",\"function\":{\"name\":\"read\"}}"));
    try testing.expect(!looksLikeProseToolCall("{\"answer\":\"42\"}"));
}

test "analyze on empty transcript: 0 turns, 0 anomalies" {
    const gpa = testing.allocator;
    var report = try analyze(gpa, .{ .transcript = &.{} });
    defer report.deinit();
    try testing.expectEqual(@as(usize, 0), report.total_assistant_turns);
    try testing.expectEqual(@as(usize, 0), report.total_anomalies);
}

test "analyze flags degenerate turn" {
    const gpa = testing.allocator;
    var msgs: [1]ai.types.Message = .{
        try mkAssistant(gpa, "", .{ .was_degenerate = true, .parts_seen = 0 }, .stop),
    };
    defer for (msgs[0..]) |*m| m.deinit(gpa);

    var report = try analyze(gpa, .{ .transcript = &msgs });
    defer report.deinit();
    try testing.expectEqual(@as(usize, 1), report.total_assistant_turns);
    try testing.expectEqual(@as(usize, 1), report.total_anomalies);
    try testing.expectEqual(Anomaly.degenerate, report.turns.items[0].anomalies.items[0]);
}

test "analyze flags prose-shaped tool call as text content" {
    const gpa = testing.allocator;
    var msgs: [1]ai.types.Message = .{
        try mkAssistant(gpa, "call:read{path:foo.zig}", null, .stop),
    };
    defer for (msgs[0..]) |*m| m.deinit(gpa);

    var report = try analyze(gpa, .{ .transcript = &msgs });
    defer report.deinit();
    try testing.expectEqual(@as(usize, 1), report.total_anomalies);
    try testing.expectEqual(Anomaly.prose_tool_call, report.turns.items[0].anomalies.items[0]);
}

test "analyze flags thinking-budget exhaustion shape" {
    const gpa = testing.allocator;
    var msgs: [1]ai.types.Message = .{
        try mkAssistant(gpa, "", .{
            .was_degenerate = true,
            .parts_seen = 0,
            .candidates_tokens = 0,
            .thoughts_tokens = 561,
        }, .stop),
    };
    defer for (msgs[0..]) |*m| m.deinit(gpa);

    var report = try analyze(gpa, .{ .transcript = &msgs });
    defer report.deinit();
    // Both degenerate AND thinking_budget_exhaustion fire.
    try testing.expect(report.total_anomalies >= 2);
    var saw_thinking = false;
    for (report.turns.items[0].anomalies.items) |a| {
        if (a == .thinking_budget_exhaustion) saw_thinking = true;
    }
    try testing.expect(saw_thinking);
}

test "render: clean transcript reports zero anomalies" {
    const gpa = testing.allocator;
    var msgs: [1]ai.types.Message = .{
        try mkAssistant(gpa, "ok", .{
            .parts_seen = 1,
            .candidates_tokens = 4,
            .text_event_count = 1,
        }, .stop),
    };
    defer for (msgs[0..]) |*m| m.deinit(gpa);

    var report = try analyze(gpa, .{ .transcript = &msgs });
    defer report.deinit();
    const out = try render(gpa, &report, .{ .transcript = &msgs, .mode_name = "interactive" });
    defer gpa.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "=== franky diagnostics ===") != null);
    try testing.expect(std.mem.indexOf(u8, out, "0 anomaly across 1 turns") != null);
    try testing.expect(std.mem.indexOf(u8, out, "(all turns clean)") != null);
}

test "render: degenerate + prose turn surfaces FLAGS + HINT lines" {
    const gpa = testing.allocator;
    var msgs: [1]ai.types.Message = .{
        try mkAssistant(gpa, "call:read{path:src/x.zig}", .{
            .trace_id = try gpa.dupe(u8, "1777498943846-0001"),
            .was_degenerate = false, // prose-tool-call still saves text
            .parts_seen = 1,
        }, .stop),
    };
    defer for (msgs[0..]) |*m| m.deinit(gpa);

    var report = try analyze(gpa, .{ .transcript = &msgs });
    defer report.deinit();
    const out = try render(gpa, &report, .{
        .transcript = &msgs,
        .http_trace_dir = "/tmp/franky-trace",
        .mode_name = "interactive",
    });
    defer gpa.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "FLAGS: PROSE_TOOL_CALL") != null);
    try testing.expect(std.mem.indexOf(u8, out, "HINT (PROSE_TOOL_CALL):") != null);
    try testing.expect(std.mem.indexOf(u8, out, "/tmp/franky-trace/1777498943846-0001-") != null);
    try testing.expect(std.mem.indexOf(u8, out, "first text:") != null);
}

// ─── SI-1 — summary.json shape + persist round-trip ────────────────

test "toJson: schema_version + identity fields + zero-counts shape" {
    const gpa = testing.allocator;

    var msgs: [1]ai.types.Message = .{
        try mkAssistant(gpa, "ok", .{ .parts_seen = 3 }, .stop),
    };
    defer for (msgs[0..]) |*m| m.deinit(gpa);

    var report = try analyze(gpa, .{ .transcript = &msgs });
    defer report.deinit();

    const json = try toJson(gpa, &report, .{
        .transcript = &msgs,
        .session_label = "01JTEST",
        .model = "gemini-2.5-pro",
        .provider = "google",
        .mode_name = "interactive",
    }, "/abs/path/to/12345.txt");
    defer gpa.free(json);

    // Spot-check the load-bearing structural pieces. We don't snapshot
    // the whole JSON because field order may shift between Zig versions
    // (we control the field order, but a future refactor might).
    try testing.expect(std.mem.indexOf(u8, json, "\"schema_version\":1") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"session_id\":\"01JTEST\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"model\":\"gemini-2.5-pro\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"provider\":\"google\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"mode\":\"interactive\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"report_path\":\"/abs/path/to/12345.txt\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"messages\":1") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"assistant_turns\":1") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"parts_seen\":3") != null);
    // Empty failures list rendered as `"tool_failures":[]`.
    try testing.expect(std.mem.indexOf(u8, json, "\"tool_failures\":[]") != null);
}

test "toJson: null identity fields render as JSON null" {
    const gpa = testing.allocator;

    var msgs: [1]ai.types.Message = .{
        try mkAssistant(gpa, "ok", null, .stop),
    };
    defer for (msgs[0..]) |*m| m.deinit(gpa);

    var report = try analyze(gpa, .{ .transcript = &msgs });
    defer report.deinit();

    // Pass no labels — every identity field is null.
    const json = try toJson(gpa, &report, .{ .transcript = &msgs }, null);
    defer gpa.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"session_id\":null") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"model\":null") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"provider\":null") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"mode\":null") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"report_path\":null") != null);
}

test "toJson: anomaly_counts reflects flagged turns" {
    const gpa = testing.allocator;

    var msgs: [2]ai.types.Message = .{
        try mkAssistant(gpa, "", .{ .was_degenerate = true, .parts_seen = 0 }, .stop),
        try mkAssistant(gpa, "call:read{path:foo}", null, .stop),
    };
    defer for (msgs[0..]) |*m| m.deinit(gpa);

    var report = try analyze(gpa, .{ .transcript = &msgs });
    defer report.deinit();

    const json = try toJson(gpa, &report, .{ .transcript = &msgs }, null);
    defer gpa.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"degenerate\":1") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"prose_tool_call\":1") != null);
}

test "persistJson + runAndPersist: summary.json lands next to <ts>.txt" {
    const gpa = testing.allocator;
    var threaded = @import("../test_helpers.zig").threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    var msgs: [1]ai.types.Message = .{
        try mkAssistant(gpa, "ok", .{ .parts_seen = 1 }, .stop),
    };
    defer for (msgs[0..]) |*m| m.deinit(gpa);

    const home = "/tmp/franky-diag-summaryjson-test";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};

    const r = try runAndPersist(gpa, io, .{
        .transcript = &msgs,
        .mode_name = "test",
        .session_label = "01JS",
        .model = "gemini-2.5-pro",
    }, .{
        .franky_home = home,
        .session_id = "01JS",
        .timestamp_ms = 7,
    });
    defer r.deinit(gpa);
    try testing.expect(r.persisted_path != null);

    // The summary.json should exist alongside the TXT.
    const json_path = home ++ "/diagnostics/01JS/summary.json";
    var f = std.Io.Dir.cwd().openFile(io, json_path, .{}) catch |e| {
        std.debug.print("failed to open expected summary.json at {s}: {s}\n", .{ json_path, @errorName(e) });
        return e;
    };
    defer f.close(io);
    const len = try f.length(io);
    const buf = try gpa.alloc(u8, @intCast(len));
    defer gpa.free(buf);
    _ = try f.readPositionalAll(io, buf, 0);

    try testing.expect(std.mem.indexOf(u8, buf, "\"schema_version\":1") != null);
    try testing.expect(std.mem.indexOf(u8, buf, "\"session_id\":\"01JS\"") != null);
    try testing.expect(std.mem.indexOf(u8, buf, "\"model\":\"gemini-2.5-pro\"") != null);
    // The TXT report companion lives in the same dir; summary.json
    // points at it so an aggregator can drill back to detail.
    const txt_path = home ++ "/diagnostics/01JS/7.txt";
    try testing.expect(std.mem.indexOf(u8, buf, "\"report_path\":\"" ++ txt_path ++ "\"") != null);
    // And the file at that path must actually exist on disk —
    // ordering invariant: persist() runs before persistJson().
    var txt_f = try std.Io.Dir.cwd().openFile(io, txt_path, .{});
    txt_f.close(io);
}

test "persist writes <home>/diagnostics/<sid>/<ts>.txt with rendered content" {
    const gpa = testing.allocator;
    var threaded = @import("../test_helpers.zig").threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const home = "/tmp/franky-diag-persist-test";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};

    const res = try persist(gpa, io, .{
        .franky_home = home,
        .session_id = "01JTEST",
        .timestamp_ms = 12345,
    }, "hello diagnostics\n");
    defer res.deinit(gpa);

    try testing.expectEqualStrings(home ++ "/diagnostics/01JTEST/12345.txt", res.path);

    // Read it back.
    var f = try std.Io.Dir.cwd().openFile(io, res.path, .{});
    defer f.close(io);
    var rb: [128]u8 = undefined;
    var r = f.reader(io, &rb);
    var rbuf: [128]u8 = undefined;
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(gpa);
    while (true) {
        var vecs: [1][]u8 = .{&rbuf};
        const n = r.interface.readVec(&vecs) catch break;
        if (n == 0) break;
        try got.appendSlice(gpa, rbuf[0..n]);
    }
    try testing.expectEqualStrings("hello diagnostics\n", got.items);
}

test "runAndPersist returns rendered text + path; null persist_opts → no file" {
    const gpa = testing.allocator;
    var threaded = @import("../test_helpers.zig").threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    var msgs: [1]ai.types.Message = .{
        try mkAssistant(gpa, "ok", .{ .parts_seen = 1 }, .stop),
    };
    defer for (msgs[0..]) |*m| m.deinit(gpa);

    // (a) no persist
    {
        const r = try runAndPersist(gpa, io, .{
            .transcript = &msgs,
            .mode_name = "test",
        }, null);
        defer r.deinit(gpa);
        try testing.expect(r.persisted_path == null);
        try testing.expect(std.mem.indexOf(u8, r.rendered, "=== franky diagnostics ===") != null);
    }

    // (b) persisted
    const home = "/tmp/franky-diag-runpersist-test";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
    {
        const r = try runAndPersist(gpa, io, .{
            .transcript = &msgs,
            .mode_name = "test",
        }, .{
            .franky_home = home,
            .session_id = "01J",
            .timestamp_ms = 99,
        });
        defer r.deinit(gpa);
        try testing.expect(r.persisted_path != null);
        try testing.expect(std.mem.indexOf(u8, r.persisted_path.?, "/diagnostics/01J/99.txt") != null);
    }
}

// ─── tool-failure tests (v1.29.3) ─────────────────────────────────

fn mkAssistantWithToolCall(
    allocator: std.mem.Allocator,
    text: []const u8,
    tool_name: []const u8,
    call_id: []const u8,
) !ai.types.Message {
    const c = try allocator.alloc(ai.types.ContentBlock, 2);
    c[0] = .{ .text = .{ .text = try allocator.dupe(u8, text) } };
    c[1] = .{ .tool_call = .{
        .id = try allocator.dupe(u8, call_id),
        .name = try allocator.dupe(u8, tool_name),
        .arguments_json = try allocator.dupe(u8, "{}"),
    } };
    return .{
        .role = .assistant,
        .content = c,
        .timestamp = 100,
        .stop_reason = .tool_use,
    };
}

fn mkToolResult(
    allocator: std.mem.Allocator,
    call_id: []const u8,
    body: []const u8,
    is_error: bool,
) !ai.types.Message {
    const c = try allocator.alloc(ai.types.ContentBlock, 1);
    c[0] = .{ .text = .{ .text = try allocator.dupe(u8, body) } };
    return .{
        .role = .tool_result,
        .content = c,
        .timestamp = 200,
        .tool_call_id = try allocator.dupe(u8, call_id),
        .is_error = is_error,
    };
}

test "analyze flags subagent JSON error (timeout) on parent assistant turn" {
    // Pin the user's exact scenario: assistant calls subagent,
    // subagent tool_result has is_error=true with the JSON
    // envelope `{"ok":false,"error_kind":"timeout","error_message":"…","hint":"…"}`.
    const gpa = testing.allocator;
    var msgs: [2]ai.types.Message = .{
        try mkAssistantWithToolCall(gpa, "Now I will use a subagent…", "subagent", "gcall-0"),
        try mkToolResult(gpa, "gcall-0",
            \\{"ok":false,"error_kind":"timeout","error_message":"sub-agent failed: timeout — first-byte timeout: provider didn't respond within 30000ms","hint":"retry; details in error_message","turn_count":1}
        , true),
    };
    defer for (msgs[0..]) |*m| m.deinit(gpa);

    var report = try analyze(gpa, .{ .transcript = &msgs });
    defer report.deinit();

    try testing.expectEqual(@as(usize, 1), report.turns.items.len);
    const turn = report.turns.items[0];
    try testing.expectEqual(@as(usize, 1), turn.tool_failures.items.len);
    const f = turn.tool_failures.items[0];
    try testing.expectEqualStrings("subagent", f.tool_name);
    try testing.expectEqualStrings("gcall-0", f.call_id);
    try testing.expectEqualStrings("timeout", f.code.?);
    try testing.expect(std.mem.indexOf(u8, f.message.?, "first-byte timeout") != null);
    try testing.expectEqualStrings("retry; details in error_message", f.hint.?);

    // TOOL_ERROR anomaly fires exactly once on the parent turn.
    var saw_tool_err: u32 = 0;
    for (turn.anomalies.items) |a| if (a == .tool_error) {
        saw_tool_err += 1;
    };
    try testing.expectEqual(@as(u32, 1), saw_tool_err);
}

test "analyze: agent_error envelope wrapping a deeper timeout" {
    // The user's pasted example wraps the timeout in an
    // `agent_error` envelope — error_kind="agent_error", message
    // contains "sub-agent failed: timeout". Our hint generator
    // should still recognize timeout-shaped messages.
    const gpa = testing.allocator;
    var msgs: [2]ai.types.Message = .{
        try mkAssistantWithToolCall(gpa, "calling subagent", "subagent", "gcall-0"),
        try mkToolResult(gpa, "gcall-0",
            \\{"ok":false,"error_kind":"agent_error","error_message":"sub-agent failed: timeout — first-byte timeout: provider didn't respond within 30000ms; raise --first-byte-timeout-ms"}
        , true),
    };
    defer for (msgs[0..]) |*m| m.deinit(gpa);

    var report = try analyze(gpa, .{ .transcript = &msgs });
    defer report.deinit();
    const f = report.turns.items[0].tool_failures.items[0];
    try testing.expectEqualStrings("agent_error", f.code.?);
    // Even though code is generic agent_error, the message-based
    // detection should prefer the timeout hint.
    const recovery = hintForToolError(f.code, f.message);
    try testing.expect(std.mem.indexOf(u8, recovery, "first-byte-timeout") != null);
}

test "analyze parses built-in `[code] msg` shape (edit_no_match)" {
    const gpa = testing.allocator;
    var msgs: [2]ai.types.Message = .{
        try mkAssistantWithToolCall(gpa, "let me edit", "edit", "toolu_42"),
        try mkToolResult(gpa, "toolu_42", "[edit_no_match] old text not found in file", true),
    };
    defer for (msgs[0..]) |*m| m.deinit(gpa);

    var report = try analyze(gpa, .{ .transcript = &msgs });
    defer report.deinit();
    const f = report.turns.items[0].tool_failures.items[0];
    try testing.expectEqualStrings("edit_no_match", f.code.?);
    try testing.expectEqualStrings("old text not found in file", f.message.?);
    try testing.expect(f.hint == null);
}

test "render: tool failure surfaces tool name, code, message, and HINT" {
    const gpa = testing.allocator;
    var msgs: [2]ai.types.Message = .{
        try mkAssistantWithToolCall(gpa, "calling subagent", "subagent", "gcall-0"),
        try mkToolResult(gpa, "gcall-0",
            \\{"ok":false,"error_kind":"timeout","error_message":"sub-agent failed: timeout","hint":"retry"}
        , true),
    };
    defer for (msgs[0..]) |*m| m.deinit(gpa);

    var report = try analyze(gpa, .{ .transcript = &msgs });
    defer report.deinit();
    const out = try render(gpa, &report, .{ .transcript = &msgs, .mode_name = "test" });
    defer gpa.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "FLAGS: TOOL_ERROR") != null);
    try testing.expect(std.mem.indexOf(u8, out, "tool failure: subagent (gcall-0) — timeout:") != null);
    try testing.expect(std.mem.indexOf(u8, out, "provider hint: retry") != null);
    try testing.expect(std.mem.indexOf(u8, out, "first-byte-timeout-ms") != null);
}

test "hintForToolError: recognizes canonical codes" {
    try testing.expect(std.mem.indexOf(u8, hintForToolError("timeout", null), "first-byte-timeout") != null);
    try testing.expect(std.mem.indexOf(u8, hintForToolError("auth", null), "auth.json") != null);
    try testing.expect(std.mem.indexOf(u8, hintForToolError("rate_limited", null), "rate-limited") != null);
    try testing.expect(std.mem.indexOf(u8, hintForToolError("role_denied", null), "--role") != null);
    try testing.expect(std.mem.indexOf(u8, hintForToolError("path_escape_workspace", null), "workspace") != null);
    try testing.expect(std.mem.indexOf(u8, hintForToolError("bash_timeout", null), "timeoutMs") != null);
    try testing.expect(std.mem.indexOf(u8, hintForToolError("read_too_large", null), "Paginate") != null);
}

// v1.29.6 — split edit hints + write_exists + invalid_args.
test "hintForToolError: edit_no_match steers AWAY from widening" {
    // Real-user incident: gemini-2.5-pro got `edit_no_match`,
    // interpreted "Read the file again to get the current bytes"
    // as "widen the old string with more context" — making it
    // worse, since the bigger guess still doesn't match. The new
    // hint explicitly tells the model NOT to widen.
    const h = hintForToolError("edit_no_match", null);
    try testing.expect(std.mem.indexOf(u8, h, "DO NOT widen") != null);
    try testing.expect(std.mem.indexOf(u8, h, "Re-read") != null);
    try testing.expect(std.mem.indexOf(u8, h, "copy-paste") != null);
}

test "hintForToolError: edit_ambiguous DOES tell the model to widen" {
    const h = hintForToolError("edit_ambiguous", null);
    try testing.expect(std.mem.indexOf(u8, h, "Widen") != null);
    try testing.expect(std.mem.indexOf(u8, h, "context") != null);
    // Must NOT say to re-read (the file content is fine; the
    // problem is just that `old` isn't unique).
    try testing.expect(std.mem.indexOf(u8, h, "Re-read") == null);
}

test "hintForToolError: write_exists points at overwrite=true and edit alternative" {
    const h = hintForToolError("write_exists", null);
    try testing.expect(std.mem.indexOf(u8, h, "overwrite") != null);
    try testing.expect(std.mem.indexOf(u8, h, "edit") != null);
}

test "hintForToolError: invalid_args points at the error message" {
    const h = hintForToolError("invalid_args", null);
    try testing.expect(std.mem.indexOf(u8, h, "missing") != null);
    try testing.expect(std.mem.indexOf(u8, h, "schema") != null);
}

test "hintForToolError: legacy no-match-in-message fallback still fires" {
    // Older transcripts and sub-agent envelopes can carry "no
    // match" in the message without a structured tool_code.
    const h = hintForToolError(null, "edit failed: old not found, no match in file");
    try testing.expect(std.mem.indexOf(u8, h, "Re-read") != null);
    try testing.expect(std.mem.indexOf(u8, h, "do not widen") != null);
}

test "render: empty transcript prints (no assistant turns yet)" {
    const gpa = testing.allocator;
    var report = try analyze(gpa, .{ .transcript = &.{} });
    defer report.deinit();
    const out = try render(gpa, &report, .{ .transcript = &.{}, .mode_name = "interactive" });
    defer gpa.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "no assistant turns yet") != null);
}

test "render: header includes provider + model when set" {
    const gpa = testing.allocator;
    var report = try analyze(gpa, .{ .transcript = &.{} });
    defer report.deinit();
    const out = try render(gpa, &report, .{
        .transcript = &.{},
        .mode_name = "franky-do",
        .provider = "google",
        .model = "gemini-2.5-pro",
    });
    defer gpa.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "provider:    google") != null);
    try testing.expect(std.mem.indexOf(u8, out, "model:       gemini-2.5-pro") != null);
}

test "render: header shows '?' when provider/model unset" {
    const gpa = testing.allocator;
    var report = try analyze(gpa, .{ .transcript = &.{} });
    defer report.deinit();
    const out = try render(gpa, &report, .{ .transcript = &.{}, .mode_name = "interactive" });
    defer gpa.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "provider:    ?") != null);
    try testing.expect(std.mem.indexOf(u8, out, "model:       ?") != null);
}
