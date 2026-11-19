//! Session persistence — §H of the spec.
//!
//! Implemented subset:
//!   - ULID session ids.
//!   - `session.json` + `transcript.jsonl` round-trip (JSON Lines —
//!     one JSON object per line, Claude-Code-style append-only log).
//!   - Atomic writes (tempfile + rename).
//!   - Schema version field with forward migrations.
//!   - **v1.5.0**: content-addressed blob extraction — any content
//!     block whose canonical JSON is ≥ `object_store.inline_threshold_bytes`
//!     (32 KiB) is spilled into `<session_dir>/objects/<first2>/<rest62>`
//!     and replaced in `transcript.jsonl` with a `{"type":"ref",
//!     "hash":"sha256:<hex>"}` pointer per §H.4.
//!   - **v1.7.0**: per-branch transcript snapshots at
//!     `<session_dir>/transcripts/<branch>.jsonl`. `transcript.jsonl`
//!     stays the "active branch" view for quick-read compatibility;
//!     the snapshot directory lets `--checkout <branch>` resume a
//!     different branch's history.
//!   - **v1.30.0**: transcript on-disk format switched from a single
//!     JSON object (`{"version":…,"messages":[…]}`) to JSON Lines.
//!     The first line is a header `{"type":"meta","version":5,
//!     "branch":"<name>"}`; each subsequent line is one message.
//!     `readTranscript`/`readBranchTranscript` transparently read
//!     legacy `.json` files (v ≤ 3) so existing sessions resume
//!     without a migration step.
//!   - **v1.33.0**: transcript record shape changed to match Claude
//!     Code's format for downstream-tooling compatibility. Each
//!     message line is now `{"type":"user"|"assistant","sessionId":…,
//!     "timestamp":"<ISO-8601>","message":{"role":…,"model":…,
//!     "content":[…],"stop_reason":…,"usage":{…}}}`. Tool-call
//!     blocks use `"type":"tool_use"` with `"input"`; tool results
//!     are `"user"` records whose content is a `"tool_result"`
//!     block with `"tool_use_id"`. Usage keys are snake_case
//!     (`input_tokens`, `output_tokens`, `cache_read_input_tokens`,
//!     `cache_creation_input_tokens`); `input_tokens` is the
//!     uncached portion (total minus cache_read + cache_write).
//!     Legacy v4 lines (no `type`, top-level `role`, `toolCall`/
//!     `arguments`, epoch-ms `timestamp`) are still read transparently.
//!     Schema version bumped to 5.

const std = @import("std");
const builtin = @import("builtin");
const ai = struct {
    pub const types = @import("../../ai/types.zig");
    pub const log = @import("../../ai/log.zig");
};
const agent_mod = @import("../../agent/mod.zig");
const object_store = @import("object_store.zig");

pub const current_session_version: u32 = 3;
/// v1.30.0 — transcript schema bumped to 4 for the JSON Lines
/// on-disk format. Legacy `.json` transcripts at version ≤ 3 are
/// still readable (`readTranscript` detects the old shape).
/// v1.33.0 — schema bumped to 5 for Claude-Code-compatible record
/// shape: each message line gains `"type":"user"|"assistant"`,
/// a `"message":{role,model,content,usage,stop_reason}` wrapper,
/// `sessionId`, ISO-8601 `timestamp`, `tool_use`/`tool_result`/
/// `input`/`tool_use_id` block names, and Claude `usage` keys
/// (`input_tokens` etc.). Legacy v4 lines (no `type`, top-level
/// `role`, `toolCall`/`arguments`, epoch-ms timestamp) are still
/// read transparently.
pub const current_transcript_version: u32 = 5;
/// Highest version accepted when reading a *legacy* single-JSON
/// transcript (the pre-v1.30.0 `{"version":…,"messages":[…]}` shape).
pub const legacy_transcript_version: u32 = 3;

/// 26-char Crockford base32 identifier, prefix sortable by creation time.
pub const Ulid = struct {
    bytes: [26]u8,

    pub fn asSlice(self: *const Ulid) []const u8 {
        return &self.bytes;
    }
};

/// Crockford base32 alphabet (ULID spec): excludes I, L, O, U.
pub const crockford = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

/// Generate a new ULID. `time_ms` is wall-clock milliseconds since epoch;
/// `rand` supplies 80 bits of entropy.
pub fn newUlid(time_ms: u64, rand: std.Random) Ulid {
    var bytes: [26]u8 = undefined;
    // First 48 bits = timestamp, rendered as 10 base32 chars.
    var t = time_ms;
    var i: usize = 10;
    while (i > 0) {
        i -= 1;
        bytes[i] = crockford[@intCast(t & 0x1f)];
        t >>= 5;
    }
    // Next 80 bits = random, rendered as 16 base32 chars.
    var j: usize = 10;
    while (j < 26) : (j += 1) {
        const v: u32 = rand.int(u5);
        bytes[j] = crockford[@intCast(v)];
    }
    return .{ .bytes = bytes };
}

pub const SessionHeader = struct {
    id: []const u8,
    created_at_ms: i64,
    updated_at_ms: i64,
    title: []const u8,
    provider: []const u8,
    model: []const u8,
    api: []const u8,
    thinking_level: []const u8,
    active_branch: []const u8 = "main",
    system_prompt_hash: []const u8 = "",
};

/// Write `session.json` atomically under `session_dir`.
pub fn writeSessionHeader(
    allocator: std.mem.Allocator,
    io: std.Io,
    session_dir: []const u8,
    header: SessionHeader,
) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\n");
    try writeJsonField(&buf, allocator, "version", current_session_version, false);
    try writeJsonStrField(&buf, allocator, "id", header.id, false);
    try writeJsonField(&buf, allocator, "createdAtMs", header.created_at_ms, false);
    try writeJsonField(&buf, allocator, "updatedAtMs", header.updated_at_ms, false);
    try writeJsonStrField(&buf, allocator, "title", header.title, false);
    try writeJsonStrField(&buf, allocator, "provider", header.provider, false);
    try writeJsonStrField(&buf, allocator, "model", header.model, false);
    try writeJsonStrField(&buf, allocator, "api", header.api, false);
    try writeJsonStrField(&buf, allocator, "thinkingLevel", header.thinking_level, false);
    try writeJsonStrField(&buf, allocator, "activeBranch", header.active_branch, false);
    try writeJsonStrField(&buf, allocator, "systemPromptHash", header.system_prompt_hash, true);
    try buf.appendSlice(allocator, "\n}\n");

    const path = try std.fs.path.join(allocator, &.{ session_dir, "session.json" });
    defer allocator.free(path);
    try atomicWrite(io, path, buf.items);
}

/// Read `session.json` and populate `out`. Caller owns the strings.
pub fn readSessionHeader(
    allocator: std.mem.Allocator,
    io: std.Io,
    session_dir: []const u8,
) !SessionHeader {
    const path = try std.fs.path.join(allocator, &.{ session_dir, "session.json" });
    defer allocator.free(path);

    const bytes = try readWholeFile(allocator, io, path);
    defer allocator.free(bytes);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    const version = if (obj.get("version")) |v| v.integer else 0;
    if (version > current_session_version) return error.UnsupportedSessionVersion;

    return .{
        .id = try allocator.dupe(u8, strOpt(obj, "id") orelse ""),
        .created_at_ms = if (obj.get("createdAtMs")) |v| v.integer else 0,
        .updated_at_ms = if (obj.get("updatedAtMs")) |v| v.integer else 0,
        .title = try allocator.dupe(u8, strOpt(obj, "title") orelse ""),
        .provider = try allocator.dupe(u8, strOpt(obj, "provider") orelse ""),
        .model = try allocator.dupe(u8, strOpt(obj, "model") orelse ""),
        .api = try allocator.dupe(u8, strOpt(obj, "api") orelse ""),
        .thinking_level = try allocator.dupe(u8, strOpt(obj, "thinkingLevel") orelse "off"),
        .active_branch = try allocator.dupe(u8, strOpt(obj, "activeBranch") orelse "main"),
        .system_prompt_hash = try allocator.dupe(u8, strOpt(obj, "systemPromptHash") orelse ""),
    };
}

/// Free all strings allocated by `readSessionHeader`.
/// v2.18 — uses comptime reflection to discover all `[]const u8` fields
/// so adding a new owning-string field to `SessionHeader` automatically
/// frees it without updating this function.
pub fn freeSessionHeader(allocator: std.mem.Allocator, h: SessionHeader) void {
    const struct_info = @typeInfo(SessionHeader).@"struct";
    inline for (struct_info.field_names, struct_info.field_types) |field_name, field_type| {
        if (field_type == []const u8) {
            allocator.free(@field(h, field_name));
        }
    }
}

/// Render a transcript as JSON Lines into `out` — one JSON object
/// per line. The first line is a header `{"type":"meta","version":4,
/// "branch":"<name>"}`; each subsequent line is one message object
/// (identical shape to the per-message JSON the legacy array emitted).
/// Oversize content blocks are spilled to `<session_dir>/objects/…`
/// and replaced with `{"type":"ref","hash":"sha256:<hex>"}` per §H.4.
///
/// v1.30.0 — replaces the pre-v1.30 `renderTranscriptJson` which
/// produced a single `{"version":…,"messages":[…]}` JSON object.
/// Shared body between `writeTranscript` (top-level `transcript.jsonl`)
/// and `writeBranchTranscript` (per-branch snapshot at
/// `transcripts/<branch>.jsonl`). Both wrappers handle only the
/// path-construction + file IO around this renderer.
fn renderTranscriptJsonl(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    io: std.Io,
    session_dir: []const u8,
    transcript: *const agent_mod.loop.Transcript,
    branch: []const u8,
    cost_state: ?*const ai.types.CostState,
    session_id: ?[]const u8,
) !void {
    const store_dir = try std.fs.path.join(allocator, &.{ session_dir, "objects" });
    defer allocator.free(store_dir);

    // Line 1 — header / meta line. Compact (not pretty-printed) like
    // every subsequent line; Claude Code transcripts use the same
    // one-JSON-object-per-line convention. The meta line is a
    // franky-specific bookkeeping record (Claude Code has no header);
    // downstream tooling ignores unknown `type` values.
    try out.appendSlice(allocator, "{\"type\":\"meta\",\"version\":");
    const ver = try std.fmt.allocPrint(allocator, "{d}", .{current_transcript_version});
    defer allocator.free(ver);
    try out.appendSlice(allocator, ver);
    try out.appendSlice(allocator, ",\"branch\":");
    try appendJsonStr(out, allocator, branch);
    try out.appendSlice(allocator, "}");
    try out.append(allocator, '\n');

    // One message per line — v1.33.0 Claude-Code-compatible shape.
    for (transcript.messages.items) |m| {
        try appendMessageJson(out, allocator, io, store_dir, m, session_id);
        try out.append(allocator, '\n');
    }

    // v1.32.0 — cost-state aggregate line. Appended LAST so it reflects
    // the complete session totals at write time. Omitted when no
    // `cost_state` accumulator was provided (pre-v1.32 callers, or
    // --no-session tooling that re-renders without a live session).
    if (cost_state) |cs| {
        try renderCostStateLine(out, allocator, cs, session_id, transcript);
        try out.append(allocator, '\n');
    }
}

/// Serialize the transcript to `session_dir/transcript.jsonl` (JSON
/// Lines — one JSON object per line). Content blocks whose canonical
/// JSON is ≥ `object_store.inline_threshold_bytes` are spilled to
/// `<session_dir>/objects/<first2>/<rest62>` and replaced in the
/// transcript with a `{"type":"ref","hash":"sha256:<hex>"}` pointer
/// per §H.4.
///
/// v1.30.0 — the on-disk extension changed from `.json` to `.jsonl`.
/// `readTranscript` transparently reads the legacy `.json` file when
/// the `.jsonl` file is absent, so existing sessions resume cleanly.
pub fn writeTranscript(
    allocator: std.mem.Allocator,
    io: std.Io,
    session_dir: []const u8,
    transcript: *const agent_mod.loop.Transcript,
    branch: []const u8,
    cost_state: ?*const ai.types.CostState,
    session_id: ?[]const u8,
) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try renderTranscriptJsonl(&buf, allocator, io, session_dir, transcript, branch, cost_state, session_id);

    const path = try std.fs.path.join(allocator, &.{ session_dir, "transcript.jsonl" });
    defer allocator.free(path);
    try atomicWrite(io, path, buf.items);

    // Best-effort cleanup of a pre-v1.30 `transcript.json` so we don't
    // leave a stale duplicate on disk.
    deleteLegacyFile(io, session_dir, "transcript.json");
}

/// Load `transcript.jsonl` into an owned `Transcript`. Caller deinits it.
/// Content blocks stored as `{"type":"ref","hash":"sha256:<hex>"}` are
/// resolved from `<session_dir>/objects/…` transparently.
///
/// v1.30.0 — reads the new JSON Lines format. When `transcript.jsonl`
/// is absent, falls back to the pre-v1.30 `transcript.json` (single
/// JSON object with a `messages` array) so existing sessions resume
/// without a migration step. Returns `error.FileNotFound` only when
/// *neither* file exists.
pub fn readTranscript(
    allocator: std.mem.Allocator,
    io: std.Io,
    session_dir: []const u8,
) !agent_mod.loop.Transcript {
    const store_dir = try std.fs.path.join(allocator, &.{ session_dir, "objects" });
    defer allocator.free(store_dir);
    return try readTranscriptWithFallback(allocator, io, session_dir, "transcript", store_dir);
}

/// v1.7.0 — write a branch-scoped snapshot at
/// `<session_dir>/transcripts/<branch>.jsonl`. Same serialization
/// rules as `writeTranscript`: oversize blocks still externalize
/// into the shared `objects/` store (`--checkout` round-trips them
/// transparently via `readBranchTranscript`).
///
/// v1.30.0 — the on-disk extension changed from `.json` to `.jsonl`.
/// `readBranchTranscript` transparently reads the legacy `.json`
/// snapshot when the `.jsonl` file is absent.
pub fn writeBranchTranscript(
    allocator: std.mem.Allocator,
    io: std.Io,
    session_dir: []const u8,
    transcript: *const agent_mod.loop.Transcript,
    branch: []const u8,
) !void {
    const snap_dir = try std.fs.path.join(allocator, &.{ session_dir, "transcripts" });
    defer allocator.free(snap_dir);
    std.Io.Dir.cwd().createDirPath(io, snap_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try renderTranscriptJsonl(&buf, allocator, io, session_dir, transcript, branch, null, null);

    const file_name = try std.fmt.allocPrint(allocator, "{s}.jsonl", .{branch});
    defer allocator.free(file_name);
    const path = try std.fs.path.join(allocator, &.{ snap_dir, file_name });
    defer allocator.free(path);
    try atomicWrite(io, path, buf.items);

    // Best-effort cleanup of a pre-v1.30 `<branch>.json` snapshot.
    const legacy_name = try std.fmt.allocPrint(allocator, "{s}.json", .{branch});
    defer allocator.free(legacy_name);
    deleteLegacyFile(io, snap_dir, legacy_name);
}

/// v1.7.0 — load a branch-scoped snapshot. Returns
/// `error.FileNotFound` when the snapshot doesn't exist (caller
/// decides whether to surface it or fall back to `transcript.jsonl`).
///
/// v1.30.0 — reads the new JSON Lines `<branch>.jsonl` file; falls
/// back to the legacy `<branch>.json` snapshot when the `.jsonl` is
/// absent.
pub fn readBranchTranscript(
    allocator: std.mem.Allocator,
    io: std.Io,
    session_dir: []const u8,
    branch: []const u8,
) !agent_mod.loop.Transcript {
    const store_dir = try std.fs.path.join(allocator, &.{ session_dir, "objects" });
    defer allocator.free(store_dir);

    const snap_dir = try std.fs.path.join(allocator, &.{ session_dir, "transcripts" });
    defer allocator.free(snap_dir);
    return try readTranscriptWithFallback(allocator, io, snap_dir, branch, store_dir);
}

// ─── v1.30.0 transcript parsers ───────────────────────────────────

/// Safely extract a `version` integer from a JSON object map.
/// Returns 0 when the field is absent or not a non-negative integer.
/// Guards against a union-tag panic on non-integer values.
fn parseVersionField(o: std.json.ObjectMap) u32 {
    if (o.get("version")) |v| if (v == .integer and v.integer >= 0) return @intCast(v.integer);
    return 0;
}

/// Read a transcript from `dir`, preferring `<stem>.jsonl` and
/// falling back to the pre-v1.30 `<stem>.json` when the `.jsonl`
/// is absent. `store_dir` is the shared `objects/` path for `ref`
/// resolution. Returns `error.FileNotFound` only when neither file
/// exists.
fn readTranscriptWithFallback(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
    stem: []const u8,
    store_dir: []const u8,
) !agent_mod.loop.Transcript {
    const jsonl_name = try std.fmt.allocPrint(allocator, "{s}.jsonl", .{stem});
    defer allocator.free(jsonl_name);
    const jsonl_path = try std.fs.path.join(allocator, &.{ dir, jsonl_name });
    defer allocator.free(jsonl_path);
    if (readWholeFile(allocator, io, jsonl_path)) |bytes| {
        defer allocator.free(bytes);
        return try parseTranscriptJsonl(allocator, io, store_dir, bytes);
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    const legacy_name = try std.fmt.allocPrint(allocator, "{s}.json", .{stem});
    defer allocator.free(legacy_name);
    const legacy_path = try std.fs.path.join(allocator, &.{ dir, legacy_name });
    defer allocator.free(legacy_path);
    const bytes = try readWholeFile(allocator, io, legacy_path);
    defer allocator.free(bytes);
    return try parseTranscriptLegacyJson(allocator, io, store_dir, bytes);
}

/// Best-effort delete of a legacy file at `dir/<name>`. Suppresses
/// `FileNotFound` (the common case — no pre-v1.30 file exists); logs
/// any other error as a warning.
fn deleteLegacyFile(io: std.Io, dir: []const u8, name: []const u8) void {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, name }) catch return;
    std.Io.Dir.cwd().deleteFile(io, path) catch |e| switch (e) {
        error.FileNotFound => {},
        else => ai.log.log(.warn, "session", "legacy_delete_failed", "path={s} error={s}", .{ path, @errorName(e) }),
    };
}

/// Parse a JSON Lines transcript (v4) — the first line is a header
/// `{"type":"meta","version":4,"branch":…}`; each subsequent line is
/// one message. `store_dir` is the `<session_dir>/objects` path used
/// to resolve `ref` content blocks. Caller owns the returned
/// `Transcript`.
fn parseTranscriptJsonl(
    allocator: std.mem.Allocator,
    io: std.Io,
    store_dir: []const u8,
    bytes: []const u8,
) !agent_mod.loop.Transcript {
    var transcript = agent_mod.loop.Transcript.init(allocator);
    errdefer transcript.deinit();

    var first_line = true;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| {
        // Skip a trailing empty line (file ends with '\n').
        if (line.len == 0) continue;

        // Crash-resilience: if a line fails to parse as JSON, skip it
        // rather than aborting the entire transcript read. A truncated
        // final line (process killed mid-append) is the most common
        // cause; the prior complete lines are still valuable. We lose
        // at most the in-flight message.
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch {
            ai.log.log(.warn, "session", "jsonl_skip_line", "len={d}", .{line.len});
            continue;
        };
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const obj = parsed.value.object;

        // v1.32.0 — typed non-message lines. The meta header carries
        // `type:"meta"`; the cost-state aggregate carries
        // `type:"cost-state"`. v1.33.0 — message lines now ALSO carry a
        // `type` field (`"user"` or `"assistant"`), so we only skip
        // lines whose `type` is a recognized bookkeeping kind.
        // Unknown `type` values are also skipped (forward-compat) rather
        // than mis-parsed as empty user messages — UNLESS the type is
        // `"user"` or `"assistant"`, which are the v5 message record
        // types.
        const type_str = strOpt(obj, "type") orelse "";
        if (type_str.len > 0) {
            // Validate the schema version whenever we see a meta line,
            // regardless of position — a hand-edited file could place
            // a cost-state line before the meta header.
            if (std.mem.eql(u8, type_str, "meta")) {
                if (parseVersionField(obj) > current_transcript_version) return error.UnsupportedTranscriptVersion;
            }
            // v1.32.0 — restore the CostState accumulator from the
            // last cost-state line so resumed sessions keep their
            // cumulative durations / line counts / start time.
            if (std.mem.eql(u8, type_str, "cost-state")) {
                transcript.cost_state = parseCostState(obj);
            }
            first_line = false;
            // v1.33.0 — `user`/`assistant` are message record types,
            // not bookkeeping. Fall through to the message parser.
            if (std.mem.eql(u8, type_str, "user") or std.mem.eql(u8, type_str, "assistant")) {
                // handled below
            } else {
                // All other typed lines (meta, cost-state, …) are
                // bookkeeping — they are not conversation messages.
                continue;
            }
        }
        first_line = false;

        const msg = try parseMessage(allocator, io, store_dir, obj);
        try transcript.append(msg);
    }
    return transcript;
}

/// Parse a pre-v1.30 legacy transcript — a single JSON object
/// `{"version":…,"messages":[…]}`. `store_dir` resolves `ref`
/// content blocks. Caller owns the returned `Transcript`.
fn parseTranscriptLegacyJson(
    allocator: std.mem.Allocator,
    io: std.Io,
    store_dir: []const u8,
    bytes: []const u8,
) !agent_mod.loop.Transcript {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    if (parseVersionField(root) > legacy_transcript_version) return error.UnsupportedTranscriptVersion;

    var transcript = agent_mod.loop.Transcript.init(allocator);
    errdefer transcript.deinit();

    const messages_val = root.get("messages") orelse return transcript;
    if (messages_val != .array) return transcript;

    for (messages_val.array.items) |mv| {
        if (mv != .object) continue;
        const msg = try parseMessage(allocator, io, store_dir, mv.object);
        try transcript.append(msg);
    }
    return transcript;
}

/// v1.32.0 — parse a `cost-state` line back into a `CostState` so
/// resumed sessions keep their cumulative durations, line counts, and
/// start time. Only the fields that cannot be derived from
/// per-message usage are restored; `modelUsage` / `totalCostUSD` /
/// `hasUnknownModelCost` are always recomputed from the transcript
/// at write time, so they are not stored here.
fn parseCostState(o: std.json.ObjectMap) ai.types.CostState {
    var cs: ai.types.CostState = .{};
    if (o.get("totalAPIDuration")) |v| if (v == .integer and v.integer >= 0) {
        cs.total_api_duration_ms = @intCast(v.integer);
    };
    if (o.get("totalAPIDurationWithoutRetries")) |v| if (v == .integer and v.integer >= 0) {
        cs.total_api_duration_without_retries_ms = @intCast(v.integer);
    };
    if (o.get("totalToolDuration")) |v| if (v == .integer and v.integer >= 0) {
        cs.total_tool_duration_ms = @intCast(v.integer);
    };
    if (o.get("totalLinesAdded")) |v| if (v == .integer and v.integer >= 0) {
        cs.total_lines_added = @intCast(v.integer);
    };
    if (o.get("totalLinesRemoved")) |v| if (v == .integer and v.integer >= 0) {
        cs.total_lines_removed = @intCast(v.integer);
    };
    if (o.get("startTime")) |v| if (v == .integer) {
        cs.start_time_ms = v.integer;
        cs.started = true;
    };
    return cs;
}

/// Compute the SHA-256 of a canonical UTF-8 string. Used for
/// `system_prompt_hash` so prompts can be compared across sessions.
pub fn sha256Hex(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var h: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &h, .{});
    const hex_chars = "0123456789abcdef";
    const out = try allocator.alloc(u8, h.len * 2);
    for (h, 0..) |b, i| {
        out[i * 2] = hex_chars[b >> 4];
        out[i * 2 + 1] = hex_chars[b & 0x0f];
    }
    return out;
}

// ─── JSON helpers ─────────────────────────────────────────────────

fn strOpt(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    if (o.get(key)) |v| if (v == .string) return v.string;
    return null;
}

/// Extract an f64 from a JSON value that may be either `.float`
/// or `.integer` (whole-number costs serialized as `0` or `1` are
/// tagged `.integer` by the JSON parser). Returns `null` for any
/// other variant.
fn jsonF64(v: std.json.Value) ?f64 {
    return switch (v) {
        .float => v.float,
        .integer => @floatFromInt(v.integer),
        else => null,
    };
}

/// Look up `key` in `o` and return its value as a u64 integer,
/// or null if absent/not an integer.
fn jsonInt(o: std.json.ObjectMap, key: []const u8) ?u64 {
    if (o.get(key)) |v| if (v == .integer) return @intCast(v.integer);
    return null;
}

/// Look up `key` in `o` and return its value as f64, or null if
/// absent/not numeric.
fn jsonFloat(o: std.json.ObjectMap, key: []const u8) ?f64 {
    if (o.get(key)) |v| return jsonF64(v);
    return null;
}

/// Look up `key` in `o` and return its value as a string slice,
/// or null if absent/not a string.
fn jsonStr(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    if (o.get(key)) |v| if (v == .string) return v.string;
    return null;
}

/// Format an epoch-millisecond timestamp as a Claude-Code-compatible
/// ISO-8601 string: `YYYY-MM-DDTHH:MM:SS.mmmZ` (UTC, millisecond
/// precision, trailing `Z`). Writes into the caller-provided
/// `buf` (needs ≥ 24 bytes) and returns the written slice.
fn formatIso8601(ts_ms: i64, buf: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    const ms: u64 = if (ts_ms < 0) 0 else @intCast(ts_ms);
    const total_sec: u64 = ms / 1000;
    const millis: u64 = ms % 1000;

    // Days from 1970-01-01 to the civil date using the Howard Hinnant
    // algorithm (days_from_civil in reverse). We split total_sec into
    // day + seconds-of-day first.
    const days: i64 = @intCast(total_sec / 86400);
    const secs_of_day: u64 = total_sec % 86400;
    const hour: u64 = secs_of_day / 3600;
    const minute: u64 = (secs_of_day % 3600) / 60;
    const second: u64 = secs_of_day % 60;

    // civil_from_days — https://howardhinnant.github.io/date_algorithms.html
    const z = days + 719468;
    const era: i64 = @divFloor(z, 146097);
    const doe: u64 = @intCast(z - era * 146097); // [0, 146096]
    const yoe: u64 = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365; // [0, 399]
    const y: i64 = @as(i64, @intCast(yoe)) + era * 400;
    const doy: u64 = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    const mp: u64 = (5 * doy + 2) / 153; // [0, 11]
    const day: u64 = doy - (153 * mp + 2) / 5 + 1; // [1, 31]
    const month: u64 = if (mp < 10) mp + 3 else mp - 9; // [1, 12]
    const year: i64 = y + @as(i64, if (month <= 2) 1 else 0);

    // Format year: for non-negative years, use unsigned formatting to
    // avoid the `+` sign that `{d}` would emit for i64. For negative
    // years (pre-epoch), fall back to signed formatting.
    const year_buf = try std.fmt.allocPrint(allocator, "{d}", .{year});
    defer allocator.free(year_buf);

    const s = try std.fmt.allocPrint(allocator, "{s:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        year_buf, month, day, hour, minute, second, millis,
    });
    defer allocator.free(s);
    try buf.appendSlice(allocator, s);
}

fn appendMessageJson(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    io: std.Io,
    store_dir: []const u8,
    m: ai.types.Message,
    session_id: ?[]const u8,
) !void {
    // v1.33.0 — Claude-Code-compatible record shape:
    //   {"type":"user"|"assistant","sessionId":…,"timestamp":"ISO","message":{…}}
    // tool_result messages are emitted as `type:"user"` records whose
    // content is a `tool_result` block, matching Claude Code exactly.
    const record_type: []const u8 = switch (m.role) {
        .user, .tool_result => "user",
        .assistant => "assistant",
        .custom => "user",
    };
    try buf.appendSlice(allocator, "{\"type\":");
    try appendJsonStr(buf, allocator, record_type);
    if (session_id) |sid| if (sid.len > 0) {
        try buf.appendSlice(allocator, ",\"sessionId\":");
        try appendJsonStr(buf, allocator, sid);
    };
    try buf.appendSlice(allocator, ",\"timestamp\":");
    try buf.append(allocator, '"');
    try formatIso8601(m.timestamp, buf, allocator);
    try buf.append(allocator, '"');

    // `message` wrapper.
    try buf.appendSlice(allocator, ",\"message\":{");
    const role_name = switch (m.role) {
        .user => "user",
        .assistant => "assistant",
        .tool_result => "user",
        .custom => m.custom_role orelse "custom",
    };
    try buf.appendSlice(allocator, "\"role\":");
    try appendJsonStr(buf, allocator, role_name);

    // v1.33.0 — `isError` at the message-wrapper level is only emitted
    // for non-tool_result rows. For tool_result, the `is_error` flag is
    // placed inside the `tool_result` content block below (matching
    // Claude Code's shape) to avoid duplicate/conflicting keys.
    if (m.is_error and m.role != .tool_result) try buf.appendSlice(allocator, ",\"isError\":true");

    try buf.appendSlice(allocator, ",\"content\":[");
    if (m.role == .tool_result) {
        // Claude Code serializes a tool result as a `tool_result` content
        // block inside a `user` message: {"type":"tool_result",
        // "tool_use_id":"…","content":[{"type":"text","text":"…"}]}
        // The franky Message carries `tool_call_id` at the message level
        // and the result text as content blocks; we wrap them here.
        try buf.appendSlice(allocator, "{\"type\":\"tool_result\"");
        if (m.tool_call_id) |tid| {
            try buf.appendSlice(allocator, ",\"tool_use_id\":");
            try appendJsonStr(buf, allocator, tid);
        }
        if (m.is_error) try buf.appendSlice(allocator, ",\"is_error\":true");
        try buf.appendSlice(allocator, ",\"content\":[");
        for (m.content, 0..) |cb, i| {
            if (i > 0) try buf.appendSlice(allocator, ",");
            try appendContentBlockJsonMaybeExtern(buf, allocator, io, store_dir, cb);
        }
        try buf.appendSlice(allocator, "]}");
    } else {
        for (m.content, 0..) |cb, i| {
            if (i > 0) try buf.appendSlice(allocator, ",");
            try appendContentBlockJsonMaybeExtern(buf, allocator, io, store_dir, cb);
        }
    }
    try buf.appendSlice(allocator, "]");

    if (m.stop_reason) |sr| {
        try buf.appendSlice(allocator, ",\"stop_reason\":");
        try appendJsonStr(buf, allocator, sr.toClaudeCodeString());
    }
    if (m.model) |p| {
        try buf.appendSlice(allocator, ",\"model\":");
        try appendJsonStr(buf, allocator, p);
    }
    // v1.33.0 — `provider` and `api` are franky-specific extensions
    // emitted inside the `message` wrapper. Claude Code doesn't write
    // them, but downstream tooling ignores unknown keys and franky's
    // own read path restores them.
    if (m.provider) |p| {
        try buf.appendSlice(allocator, ",\"provider\":");
        try appendJsonStr(buf, allocator, p);
    }
    if (m.api) |p| {
        try buf.appendSlice(allocator, ",\"api\":");
        try appendJsonStr(buf, allocator, p);
    }
    // v1.31.0 — Message.Usage (per-turn token counts + USD costs).
    // v1.33.0 — Claude-Code-compatible key names inside `message.usage`.
    // Only emit when at least one field is non-default; pre-v1.31
    // transcripts (and user/tool_result rows that never carry usage)
    // round-trip unchanged.
    if (m.usage) |u| if (!u.isEmpty()) {
        try buf.appendSlice(allocator, ",\"usage\":{");
        var first = true;
        // Claude Code reports only the uncached portion in
        // `input_tokens`. Franky's `Usage.input` includes cached
        // tokens (the provider's total `prompt_tokens`), so subtract
        // cache_read + cache_write (clamped ≥ 0). Saturating add guards
        // against u64 overflow on adversarial inputs.
        const cached = u.cache_read +| u.cache_write;
        const uncached_input: u64 = if (u.input > cached) u.input - cached else 0;
        if (uncached_input != 0) {
            try appendJsonU64Field(buf, allocator, "\"input_tokens\":", uncached_input);
            first = false;
        }
        if (u.output != 0) {
            if (!first) try buf.append(allocator, ',');
            try appendJsonU64Field(buf, allocator, "\"output_tokens\":", u.output);
            first = false;
        }
        if (u.cache_read != 0) {
            if (!first) try buf.append(allocator, ',');
            try appendJsonU64Field(buf, allocator, "\"cache_read_input_tokens\":", u.cache_read);
            first = false;
        }
        if (u.cache_write != 0) {
            if (!first) try buf.append(allocator, ',');
            try appendJsonU64Field(buf, allocator, "\"cache_creation_input_tokens\":", u.cache_write);
            first = false;
        }
        // Franky-specific extensions (not in Claude Code's usage) —
        // emitted with snake_case names for consistency. Downstream
        // readers that only know Claude's keys ignore these.
        if (u.thinking_tokens != 0) {
            if (!first) try buf.append(allocator, ',');
            try appendJsonU64Field(buf, allocator, "\"thinking_tokens\":", u.thinking_tokens);
            first = false;
        }
        if (u.cache_creation_ephemeral_5m != 0) {
            if (!first) try buf.append(allocator, ',');
            try appendJsonU64Field(buf, allocator, "\"cache_creation_5m_input_tokens\":", u.cache_creation_ephemeral_5m);
            first = false;
        }
        if (u.cache_creation_ephemeral_1h != 0) {
            if (!first) try buf.append(allocator, ',');
            try appendJsonU64Field(buf, allocator, "\"cache_creation_1h_input_tokens\":", u.cache_creation_ephemeral_1h);
            first = false;
        }
        if (u.web_search_requests != 0) {
            if (!first) try buf.append(allocator, ',');
            try appendJsonU64Field(buf, allocator, "\"web_search_requests\":", u.web_search_requests);
            first = false;
        }
        if (u.cost_input) |ci| {
            if (!first) try buf.append(allocator, ',');
            try appendJsonF64Field(buf, allocator, "\"cost_input\":", ci);
            first = false;
        }
        if (u.cost_output) |co| {
            if (!first) try buf.append(allocator, ',');
            try appendJsonF64Field(buf, allocator, "\"cost_output\":", co);
            first = false;
        }
        if (u.cost_cache_read) |cr| {
            if (!first) try buf.append(allocator, ',');
            try appendJsonF64Field(buf, allocator, "\"cost_cache_read\":", cr);
            first = false;
        }
        if (u.cost_cache_write) |cw| {
            if (!first) try buf.append(allocator, ',');
            try appendJsonF64Field(buf, allocator, "\"cost_cache_write\":", cw);
            first = false;
        }
        try buf.append(allocator, '}');
    };
    // v1.29.0 — Message.Diagnostics. Franky-specific; emitted inside
    // the `message` wrapper under `diagnostics`. Only emit when at
    // least one field is non-default; pre-v1.29 transcripts round-trip
    // unchanged.
    if (m.diagnostics) |d| if (!d.isEmpty()) {
        try buf.appendSlice(allocator, ",\"diagnostics\":{");
        var first = true;
        if (d.trace_id) |s| {
            try buf.appendSlice(allocator, "\"traceId\":");
            try appendJsonStr(buf, allocator, s);
            first = false;
        }
        if (d.finish_reason_raw) |s| {
            if (!first) try buf.append(allocator, ',');
            try buf.appendSlice(allocator, "\"finishReasonRaw\":");
            try appendJsonStr(buf, allocator, s);
            first = false;
        }
        if (d.parts_seen != 0) {
            if (!first) try buf.append(allocator, ',');
            try appendJsonU64Field(buf, allocator, "\"partsSeen\":", d.parts_seen);
            first = false;
        }
        if (d.candidates_tokens) |n| {
            if (!first) try buf.append(allocator, ',');
            try appendJsonU64Field(buf, allocator, "\"candidatesTokens\":", n);
            first = false;
        }
        if (d.thoughts_tokens) |n| {
            if (!first) try buf.append(allocator, ',');
            try appendJsonU64Field(buf, allocator, "\"thoughtsTokens\":", n);
            first = false;
        }
        if (d.text_event_count != 0) {
            if (!first) try buf.append(allocator, ',');
            try appendJsonU64Field(buf, allocator, "\"textEvents\":", d.text_event_count);
            first = false;
        }
        if (d.thinking_event_count != 0) {
            if (!first) try buf.append(allocator, ',');
            try appendJsonU64Field(buf, allocator, "\"thinkingEvents\":", d.thinking_event_count);
            first = false;
        }
        if (d.tool_call_event_count != 0) {
            if (!first) try buf.append(allocator, ',');
            try appendJsonU64Field(buf, allocator, "\"toolCallEvents\":", d.tool_call_event_count);
            first = false;
        }
        if (d.was_degenerate) {
            if (!first) try buf.append(allocator, ',');
            try buf.appendSlice(allocator, "\"wasDegenerate\":true");
        }
        try buf.append(allocator, '}');
    };
    // Close `message` wrapper.
    try buf.appendSlice(allocator, "}");
    // Close record.
    try buf.appendSlice(allocator, "}");
}

/// v1.32.0 — per-model usage accumulator used while building the
/// `cost-state` line's `modelUsage` map. Keyed by `"<provider>/<model>"`.
const ModelUsageAccum = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    thinking_tokens: u64 = 0,
    cache_read_input_tokens: u64 = 0,
    cache_creation_input_tokens: u64 = 0,
    cache_creation_ephemeral_5m_input_tokens: u64 = 0,
    cache_creation_ephemeral_1h_input_tokens: u64 = 0,
    web_search_requests: u64 = 0,
    cost_usd: f64 = 0,
    /// True when at least one turn for this model reported no cost data.
    has_unknown_cost: bool = false,
};

/// v1.32.0 — render the `cost-state` aggregate line.
///
/// `totalCostUSD`, `modelUsage`, and `hasUnknownModelCost` are computed
/// by scanning the transcript's assistant messages (each carries a
/// `usage` object populated by the stream Reducer). The duration and
/// line-count fields come from the live `CostState` accumulator updated
/// by `agentLoop`/`runTurn`. `totalDuration` is `now - startTime`.
///
/// Matches the Claude Code transcript `cost-state` line shape so the
/// two formats are interchangeable for downstream tooling.
fn renderCostStateLine(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    cs: *const ai.types.CostState,
    session_id: ?[]const u8,
    transcript: *const agent_mod.loop.Transcript,
) !void {
    // Aggregate per-model usage from assistant messages.
    var models = std.StringHashMap(*ModelUsageAccum).init(allocator);
    defer {
        var it = models.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            allocator.destroy(e.value_ptr.*);
        }
        models.deinit();
    }
    var total_cost_usd: f64 = 0;
    var any_unknown_cost = false;
    for (transcript.messages.items) |m| {
        if (m.role != .assistant) continue;
        const u = m.usage orelse continue;
        if (u.isEmpty()) continue;
        const prov = m.provider orelse "unknown";
        const mdl = m.model orelse "unknown";
        // Allocate the accumulator BEFORE inserting so a create() failure
        // can't leave an uninitialized value pointer in the map. The
        // key is freed on the found-existing path or owned by the map
        // on the insert path; errdefer covers the getOrPut-failure case.
        const key = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prov, mdl });
        errdefer allocator.free(key);
        const gop = try models.getOrPut(key);
        if (gop.found_existing) {
            allocator.free(key);
        } else {
            const acc = try allocator.create(ModelUsageAccum);
            acc.* = .{};
            gop.value_ptr.* = acc;
        }
        const acc = gop.value_ptr.*;
        // v1.33.0 — Claude Code reports only the uncached portion in
        // `inputTokens`. Franky's `Usage.input` includes cached tokens,
        // so subtract cache_read + cache_write (clamped ≥ 0) per turn.
        // Saturating add guards against u64 overflow.
        const cached = u.cache_read +| u.cache_write;
        const uncached_input: u64 = if (u.input > cached) u.input - cached else 0;
        acc.input_tokens += uncached_input;
        acc.output_tokens += u.output;
        acc.thinking_tokens += u.thinking_tokens;
        acc.cache_read_input_tokens += u.cache_read;
        acc.cache_creation_input_tokens += u.cache_write;
        acc.cache_creation_ephemeral_5m_input_tokens += u.cache_creation_ephemeral_5m;
        acc.cache_creation_ephemeral_1h_input_tokens += u.cache_creation_ephemeral_1h;
        acc.web_search_requests += u.web_search_requests;
        if (u.costTotal()) |c| {
            acc.cost_usd += c;
            total_cost_usd += c;
        } else {
            acc.has_unknown_cost = true;
            any_unknown_cost = true;
        }
    }

    // totalDuration = now - startTime (wall-clock session length).
    const now_ms = @import("../../ai/stream.zig").nowMillis();
    const total_duration: u64 = if (cs.started)
        @intCast(@max(0, now_ms - cs.start_time_ms))
    else
        0;

    try out.appendSlice(allocator, "{\"type\":\"cost-state\"");
    if (session_id) |sid| if (sid.len > 0) {
        try out.appendSlice(allocator, ",\"sessionId\":");
        try appendJsonStr(out, allocator, sid);
    };
    try appendJsonF64Field(out, allocator, ",\"totalCostUSD\":", total_cost_usd);
    try appendJsonU64Field(out, allocator, ",\"totalAPIDuration\":", cs.total_api_duration_ms);
    try appendJsonU64Field(out, allocator, ",\"totalAPIDurationWithoutRetries\":", cs.total_api_duration_without_retries_ms);
    try appendJsonU64Field(out, allocator, ",\"totalToolDuration\":", cs.total_tool_duration_ms);
    try appendJsonU64Field(out, allocator, ",\"totalLinesAdded\":", cs.total_lines_added);
    try appendJsonU64Field(out, allocator, ",\"totalLinesRemoved\":", cs.total_lines_removed);
    try appendJsonU64Field(out, allocator, ",\"totalDuration\":", total_duration);
    try appendJsonU64Field(out, allocator, ",\"startTime\":", @as(u64, @intCast(cs.start_time_ms)));

    // modelUsage map.
    try out.appendSlice(allocator, ",\"modelUsage\":{");
    var first = true;
    var mit = models.iterator();
    while (mit.next()) |e| {
        if (!first) try out.append(allocator, ',');
        first = false;
        try appendJsonStr(out, allocator, e.key_ptr.*);
        try out.appendSlice(allocator, ":{\"inputTokens\":");
        try appendJsonU64Field(out, allocator, "", e.value_ptr.*.input_tokens);
        try appendJsonU64Field(out, allocator, ",\"outputTokens\":", e.value_ptr.*.output_tokens);
        try appendJsonU64Field(out, allocator, ",\"thinkingTokens\":", e.value_ptr.*.thinking_tokens);
        try appendJsonU64Field(out, allocator, ",\"cacheReadInputTokens\":", e.value_ptr.*.cache_read_input_tokens);
        try appendJsonU64Field(out, allocator, ",\"cacheCreationInputTokens\":", e.value_ptr.*.cache_creation_input_tokens);
        try appendJsonU64Field(out, allocator, ",\"cacheCreationEphemeral5mInputTokens\":", e.value_ptr.*.cache_creation_ephemeral_5m_input_tokens);
        try appendJsonU64Field(out, allocator, ",\"cacheCreationEphemeral1hInputTokens\":", e.value_ptr.*.cache_creation_ephemeral_1h_input_tokens);
        try appendJsonU64Field(out, allocator, ",\"webSearchRequests\":", e.value_ptr.*.web_search_requests);
        try appendJsonF64Field(out, allocator, ",\"costUSD\":", e.value_ptr.*.cost_usd);
        try out.appendSlice(allocator, "}");
    }
    try out.appendSlice(allocator, "}");

    try out.appendSlice(allocator, ",\"hasUnknownModelCost\":");
    try out.appendSlice(allocator, if (any_unknown_cost) "true" else "false");
    try out.append(allocator, '}');
}

/// Render a content block's canonical JSON inline. Pure — no IO.
/// v1.33.0 — block `type` names match Claude Code (`tool_use` rather
/// than `toolCall`; the tool-call arguments field is `input` rather
/// than `arguments`). Text/thinking/image blocks are unchanged.
/// `appendContentBlockJson` is also called from non-transcript paths
/// (e.g. proxy snapshot tests); those callers have been updated to
/// expect the new names where they assert on them.
pub fn appendContentBlockJson(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    cb: ai.types.ContentBlock,
) !void {
    try buf.appendSlice(allocator, "{\"type\":");
    switch (cb) {
        .text => |t| {
            try appendJsonStr(buf, allocator, "text");
            try buf.appendSlice(allocator, ",\"text\":");
            try appendJsonStr(buf, allocator, t.text);
            if (t.text_signature) |sig| {
                try buf.appendSlice(allocator, ",\"textSignature\":");
                try appendJsonStr(buf, allocator, sig);
            }
        },
        .thinking => |t| {
            try appendJsonStr(buf, allocator, "thinking");
            try buf.appendSlice(allocator, ",\"thinking\":");
            try appendJsonStr(buf, allocator, t.thinking);
            if (t.thinking_signature) |sig| {
                try buf.appendSlice(allocator, ",\"thinkingSignature\":");
                try appendJsonStr(buf, allocator, sig);
            }
            if (t.redacted) try buf.appendSlice(allocator, ",\"redacted\":true");
        },
        .image => |t| {
            try appendJsonStr(buf, allocator, "image");
            try buf.appendSlice(allocator, ",\"data\":");
            try appendJsonStr(buf, allocator, t.data);
            try buf.appendSlice(allocator, ",\"mimeType\":");
            try appendJsonStr(buf, allocator, t.mime_type);
        },
        .tool_call => |t| {
            try appendJsonStr(buf, allocator, "tool_use");
            try buf.appendSlice(allocator, ",\"id\":");
            try appendJsonStr(buf, allocator, t.id);
            try buf.appendSlice(allocator, ",\"name\":");
            try appendJsonStr(buf, allocator, t.name);
            // `input` is emitted as a raw JSON value (we trust it to be
            // valid JSON — it came from the model via the partial-json
            // parser or, on round-trip, from a prior serialization).
            // Claude Code uses `input`; franky v4 used `arguments`.
            try buf.appendSlice(allocator, ",\"input\":");
            if (t.arguments_json.len == 0) {
                try buf.appendSlice(allocator, "{}");
            } else {
                try buf.appendSlice(allocator, t.arguments_json);
            }
        },
    }
    try buf.appendSlice(allocator, "}");
}

/// Render a content block, possibly extracting its canonical JSON to
/// `<store_dir>/<first2>/<rest62>` and emitting a `{"type":"ref",…}`
/// pointer instead when the rendered size crosses
/// `object_store.inline_threshold_bytes` (§H.4). Caller owns `store_dir`.
fn appendContentBlockJsonMaybeExtern(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    io: std.Io,
    store_dir: []const u8,
    cb: ai.types.ContentBlock,
) !void {
    var tmp: std.ArrayList(u8) = .empty;
    defer tmp.deinit(allocator);
    try appendContentBlockJson(&tmp, allocator, cb);

    if (tmp.items.len < object_store.inline_threshold_bytes) {
        try buf.appendSlice(allocator, tmp.items);
        return;
    }

    const hex = try sha256Hex(allocator, tmp.items);
    defer allocator.free(hex);
    try object_store.writeObject(allocator, io, store_dir, hex, tmp.items);

    try buf.appendSlice(allocator, "{\"type\":\"ref\",\"hash\":\"sha256:");
    try buf.appendSlice(allocator, hex);
    try buf.appendSlice(allocator, "\"}");
}

/// Parse an ISO-8601 timestamp (`YYYY-MM-DDTHH:MM:SS.mmmZ`) into
/// epoch milliseconds. Returns null for malformed input. Accepts
/// timestamps without milliseconds (`.mmm` omitted) for robustness.
fn parseIso8601(s: []const u8) ?i64 {
    // Minimal calendar-days → epoch-days (Howard Hinnant).
    if (s.len < 19) return null;
    const year = std.fmt.parseInt(i64, s[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u64, s[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u64, s[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(u64, s[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(u64, s[14..16], 10) catch return null;
    const second = std.fmt.parseInt(u64, s[17..19], 10) catch return null;

    // days_from_civil — https://howardhinnant.github.io/date_algorithms.html
    const y: i64 = if (month <= 2) year - 1 else year;
    const m: u64 = if (month <= 2) month + 9 else month - 3;
    const era: i64 = @divFloor(y, 400);
    const yoe: u64 = @intCast(y - era * 400); // [0, 399]
    const doy: u64 = (153 * m + 2) / 5 + day - 1; // [0, 365]
    const doe: u64 = yoe * 365 + yoe / 4 - yoe / 100 + doy; // [0, 146096]
    const days: i64 = era * 146097 + @as(i64, @intCast(doe)) - 719468;

    var millis: u64 = 0;
    if (s.len > 20 and s[19] == '.') {
        // Parse up to 3 fractional digits (milliseconds).
        var i: usize = 20;
        var digits: u64 = 0;
        while (i < s.len and digits < 3) : (i += 1) {
            if (s[i] < '0' or s[i] > '9') break;
            millis = millis * 10 + @as(u64, s[i] - '0');
            digits += 1;
        }
        // If fewer than 3 digits, scale up (e.g. `.5` → 500ms).
        while (digits < 3) : (digits += 1) millis *|= 10;
    }

    return days * 86_400_000 +
        @as(i64, @intCast(hour)) * 3_600_000 +
        @as(i64, @intCast(minute)) * 60_000 +
        @as(i64, @intCast(second)) * 1_000 +
        @as(i64, @intCast(millis));
}

fn parseMessage(
    allocator: std.mem.Allocator,
    io: std.Io,
    store_dir: []const u8,
    o: std.json.ObjectMap,
) !ai.types.Message {
    // v1.33.0 — v5 records wrap the message inside `"message":{…}` and
    // carry `type`/`sessionId`/`timestamp` at the record level. Legacy
    // v4 records have role/content/usage at the top level. Detect the
    // wrapper and parse from the right place.
    const msg_obj: std.json.ObjectMap = blk: {
        if (o.get("message")) |mv| if (mv == .object) break :blk mv.object;
        break :blk o; // legacy v4 — fields are top-level
    };

    // Role: v5 uses `message.role`; v4 uses top-level `role`. For v5
    // `user` records that contain a `tool_result` content block, the
    // franky-internal role is `.tool_result`.
    const role_src = strOpt(msg_obj, "role") orelse strOpt(o, "role") orelse "user";

    var content: std.ArrayList(ai.types.ContentBlock) = .empty;
    errdefer {
        for (content.items) |cb| cb.deinit(allocator);
        content.deinit(allocator);
    }

    // Extracted from a tool_result content block (v5 shape).
    var tool_call_id_opt: ?[]const u8 = null;
    errdefer if (tool_call_id_opt) |t| allocator.free(t);
    var is_error_from_block = false;

    if (msg_obj.get("content")) |cv| if (cv == .array) {
        for (cv.array.items) |v| {
            if (v != .object) continue;
            const block_obj = v.object;
            const block_type = strOpt(block_obj, "type") orelse "text";
            if (std.mem.eql(u8, block_type, "tool_result")) {
                // v5 tool_result: extract tool_use_id → message-level,
                // and inline the nested `content` array as the message's
                // content blocks.
                if (strOpt(block_obj, "tool_use_id")) |tid| {
                    tool_call_id_opt = try allocator.dupe(u8, tid);
                }
                if (block_obj.get("is_error")) |ie| if (ie == .bool) {
                    is_error_from_block = ie.bool;
                } else if (block_obj.get("isError")) |ie2| if (ie2 == .bool) {
                    is_error_from_block = ie2.bool;
                };
                if (block_obj.get("content")) |inner| if (inner == .array) {
                    for (inner.array.items) |iv| {
                        if (iv != .object) continue;
                        const cb = try parseContentBlockMaybeDeref(allocator, io, store_dir, iv.object);
                        try content.append(allocator, cb);
                    }
                };
            } else {
                const cb = try parseContentBlockMaybeDeref(allocator, io, store_dir, block_obj);
                try content.append(allocator, cb);
            }
        }
    };

    // Determine the internal role. A v5 `user` record with a tool_result
    // block becomes `.tool_result`; a legacy `toolResult` stays as-is.
    const role: ai.types.Role = blk: {
        if (tool_call_id_opt != null) break :blk .tool_result;
        if (std.mem.eql(u8, role_src, "user")) break :blk .user;
        if (std.mem.eql(u8, role_src, "assistant")) break :blk .assistant;
        if (std.mem.eql(u8, role_src, "toolResult")) break :blk .tool_result;
        break :blk .custom;
    };

    // v1.29.0 — Diagnostics round-trip. Old transcripts without
    // the field decode as null and round-trip cleanly.
    var diag_opt: ?ai.types.Diagnostics = null;
    if (msg_obj.get("diagnostics")) |dv| if (dv == .object) {
        const dobj = dv.object;
        var diag: ai.types.Diagnostics = .{};
        if (dobj.get("traceId")) |v| if (v == .string) {
            diag.trace_id = try allocator.dupe(u8, v.string);
        };
        if (dobj.get("finishReasonRaw")) |v| if (v == .string) {
            diag.finish_reason_raw = try allocator.dupe(u8, v.string);
        };
        if (dobj.get("partsSeen")) |v| if (v == .integer) {
            diag.parts_seen = @intCast(v.integer);
        };
        if (dobj.get("candidatesTokens")) |v| if (v == .integer) {
            diag.candidates_tokens = @intCast(v.integer);
        };
        if (dobj.get("thoughtsTokens")) |v| if (v == .integer) {
            diag.thoughts_tokens = @intCast(v.integer);
        };
        if (dobj.get("textEvents")) |v| if (v == .integer) {
            diag.text_event_count = @intCast(v.integer);
        };
        if (dobj.get("thinkingEvents")) |v| if (v == .integer) {
            diag.thinking_event_count = @intCast(v.integer);
        };
        if (dobj.get("toolCallEvents")) |v| if (v == .integer) {
            diag.tool_call_event_count = @intCast(v.integer);
        };
        if (dobj.get("wasDegenerate")) |v| if (v == .bool) {
            diag.was_degenerate = v.bool;
        };
        diag_opt = diag;
    };

    // v1.31.0 — Usage round-trip. v1.33.0 — accept Claude-Code key
    // names (`input_tokens` etc.) in addition to franky v4 names
    // (`input` etc.). Token counts arrive as JSON integers; cost
    // fields as JSON floats.
    var usage_opt: ?ai.types.Usage = null;
    if (msg_obj.get("usage")) |uv| if (uv == .object) {
        const uobj = uv.object;
        var usage: ai.types.Usage = .{};
        // v5 `input_tokens` is the uncached portion; v4 `input` is the
        // total (incl. cached). We restore the TOTAL into `Usage.input`
        // so the internal model sees the provider-reported total.
        const input_from_v4 = jsonInt(uobj, "input");
        const input_from_v5 = jsonInt(uobj, "input_tokens");
        usage.output = jsonInt(uobj, "output") orelse jsonInt(uobj, "output_tokens") orelse 0;
        usage.cache_read = jsonInt(uobj, "cacheRead") orelse jsonInt(uobj, "cache_read_input_tokens") orelse 0;
        usage.cache_write = jsonInt(uobj, "cacheWrite") orelse jsonInt(uobj, "cache_creation_input_tokens") orelse 0;
        usage.thinking_tokens = jsonInt(uobj, "thinkingTokens") orelse jsonInt(uobj, "thinking_tokens") orelse 0;
        usage.cache_creation_ephemeral_5m = jsonInt(uobj, "cacheCreationEphemeral5m") orelse jsonInt(uobj, "cache_creation_5m_input_tokens") orelse 0;
        usage.cache_creation_ephemeral_1h = jsonInt(uobj, "cacheCreationEphemeral1h") orelse jsonInt(uobj, "cache_creation_1h_input_tokens") orelse 0;
        usage.web_search_requests = jsonInt(uobj, "webSearchRequests") orelse jsonInt(uobj, "web_search_requests") orelse 0;
        usage.cost_input = jsonFloat(uobj, "costInput") orelse jsonFloat(uobj, "cost_input");
        usage.cost_output = jsonFloat(uobj, "costOutput") orelse jsonFloat(uobj, "cost_output");
        usage.cost_cache_read = jsonFloat(uobj, "costCacheRead") orelse jsonFloat(uobj, "cost_cache_read");
        usage.cost_cache_write = jsonFloat(uobj, "costCacheWrite") orelse jsonFloat(uobj, "cost_cache_write");
        // Fix up: if we only had v5 `input_tokens` (uncached), add back
        // the cached tokens to restore the provider-reported total.
        usage.input = input_from_v4 orelse (input_from_v5 orelse 0) + usage.cache_read + usage.cache_write;
        usage_opt = usage;
    };

    // Timestamp: v5 is ISO-8601 string at record level; v4 is epoch-ms
    // integer at message level (which is `o` when no wrapper).
    const timestamp: i64 = blk: {
        const ts_src = if (o.get("timestamp")) |v| v else msg_obj.get("timestamp") orelse break :blk 0;
        if (ts_src == .string) break :blk parseIso8601(ts_src.string) orelse 0;
        if (ts_src == .integer) break :blk ts_src.integer;
        break :blk 0;
    };

    // stop_reason: v5 uses `stop_reason`; v4 uses `stopReason`.
    const stop_reason: ?ai.types.StopReason = blk: {
        if (msg_obj.get("stop_reason")) |v| if (v == .string) {
            break :blk ai.types.StopReason.fromString(v.string);
        };
        if (msg_obj.get("stopReason")) |v| if (v == .string) {
            break :blk ai.types.StopReason.fromString(v.string);
        };
        break :blk null;
    };

    // tool_call_id: v5 extracts from the tool_result content block
    // (already done above); v4 carries it at the message top level.
    const tool_call_id: ?[]const u8 = blk: {
        if (tool_call_id_opt) |t| break :blk t;
        if (o.get("toolCallId")) |v| if (v == .string) {
            break :blk try allocator.dupe(u8, v.string);
        };
        break :blk null;
    };

    const is_error: bool = blk: {
        if (is_error_from_block) break :blk true;
        if (o.get("isError")) |v| if (v == .bool) break :blk v.bool;
        if (msg_obj.get("isError")) |v| if (v == .bool) break :blk v.bool;
        break :blk false;
    };

    return .{
        .role = role,
        .content = try content.toOwnedSlice(allocator),
        .timestamp = timestamp,
        .stop_reason = stop_reason,
        .tool_call_id = tool_call_id,
        .is_error = is_error,
        .provider = if (jsonStr(msg_obj, "provider")) |s| try allocator.dupe(u8, s) else if (jsonStr(o, "provider")) |s| try allocator.dupe(u8, s) else null,
        .model = if (jsonStr(msg_obj, "model")) |s| try allocator.dupe(u8, s) else if (jsonStr(o, "model")) |s| try allocator.dupe(u8, s) else null,
        .api = if (jsonStr(msg_obj, "api")) |s| try allocator.dupe(u8, s) else if (jsonStr(o, "api")) |s| try allocator.dupe(u8, s) else null,
        .custom_role = if (role == .custom) try allocator.dupe(u8, role_src) else null,
        .usage = usage_opt,
        .diagnostics = diag_opt,
    };
}

/// Parse a content block, transparently resolving `{"type":"ref",
/// "hash":"sha256:<hex>"}` pointers via `object_store` (§H.4).
fn parseContentBlockMaybeDeref(
    allocator: std.mem.Allocator,
    io: std.Io,
    store_dir: []const u8,
    o: std.json.ObjectMap,
) !ai.types.ContentBlock {
    const type_str = strOpt(o, "type") orelse "text";
    if (std.mem.eql(u8, type_str, "ref")) {
        const hash_str = strOpt(o, "hash") orelse return error.MalformedRef;
        const prefix = "sha256:";
        if (!std.mem.startsWith(u8, hash_str, prefix)) return error.MalformedRef;
        const hex = hash_str[prefix.len..];
        if (hex.len != 64) return error.MalformedRef;

        const bytes = try object_store.readObject(allocator, io, store_dir, hex);
        defer allocator.free(bytes);

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.MalformedRef;
        // Resolved objects must not themselves be refs — guard against
        // loops even though the hash is content-addressed (defence in
        // depth; a cycle would require a SHA-256 collision).
        const inner_type = strOpt(parsed.value.object, "type") orelse "text";
        if (std.mem.eql(u8, inner_type, "ref")) return error.MalformedRef;
        return try parseContentBlock(allocator, parsed.value.object);
    }
    return try parseContentBlock(allocator, o);
}

fn parseContentBlock(allocator: std.mem.Allocator, o: std.json.ObjectMap) !ai.types.ContentBlock {
    const type_str = strOpt(o, "type") orelse "text";
    if (std.mem.eql(u8, type_str, "text")) {
        return .{ .text = .{
            .text = try allocator.dupe(u8, strOpt(o, "text") orelse ""),
            .text_signature = if (strOpt(o, "textSignature")) |s| try allocator.dupe(u8, s) else null,
        } };
    }
    if (std.mem.eql(u8, type_str, "thinking")) {
        return .{ .thinking = .{
            .thinking = try allocator.dupe(u8, strOpt(o, "thinking") orelse ""),
            .thinking_signature = if (strOpt(o, "thinkingSignature")) |s| try allocator.dupe(u8, s) else null,
            .redacted = if (o.get("redacted")) |v| (v == .bool and v.bool) else false,
        } };
    }
    if (std.mem.eql(u8, type_str, "image")) {
        return .{ .image = .{
            .data = try allocator.dupe(u8, strOpt(o, "data") orelse ""),
            .mime_type = try allocator.dupe(u8, strOpt(o, "mimeType") orelse "application/octet-stream"),
        } };
    }
    if (std.mem.eql(u8, type_str, "toolCall") or std.mem.eql(u8, type_str, "tool_use")) {
        // v1.33.0 — Claude Code uses `tool_use` with an `input` field;
        // franky v4 used `toolCall` with `arguments`. Accept both.
        const args_str: []u8 = if (o.get("input")) |av|
            try std.json.Stringify.valueAlloc(allocator, av, .{})
        else if (o.get("arguments")) |av|
            try std.json.Stringify.valueAlloc(allocator, av, .{})
        else
            try allocator.dupe(u8, "{}");
        return .{ .tool_call = .{
            .id = try allocator.dupe(u8, strOpt(o, "id") orelse ""),
            .name = try allocator.dupe(u8, strOpt(o, "name") orelse ""),
            .arguments_json = args_str,
        } };
    }
    // Unknown type → text fallback.
    return .{ .text = .{ .text = try allocator.dupe(u8, "") } };
}

fn writeJsonField(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    name: []const u8,
    value: anytype,
    last: bool,
) !void {
    try buf.appendSlice(allocator, "  ");
    try appendJsonStr(buf, allocator, name);
    try buf.append(allocator, ':');
    try buf.append(allocator, ' ');
    switch (@typeInfo(@TypeOf(value))) {
        .int, .comptime_int => {
            const s = try std.fmt.allocPrint(allocator, "{d}", .{value});
            defer allocator.free(s);
            try buf.appendSlice(allocator, s);
        },
        else => @compileError("writeJsonField only supports integers"),
    }
    if (!last) try buf.append(allocator, ',');
    try buf.append(allocator, '\n');
}

fn writeJsonStrField(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    name: []const u8,
    value: []const u8,
    last: bool,
) !void {
    try buf.appendSlice(allocator, "  ");
    try appendJsonStr(buf, allocator, name);
    try buf.appendSlice(allocator, ": ");
    try appendJsonStr(buf, allocator, value);
    if (!last) try buf.append(allocator, ',');
    try buf.append(allocator, '\n');
}

fn appendJsonStr(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try buf.append(allocator, '"');
    for (s) |c| switch (c) {
        '"' => try buf.appendSlice(allocator, "\\\""),
        '\\' => try buf.appendSlice(allocator, "\\\\"),
        '\n' => try buf.appendSlice(allocator, "\\n"),
        '\r' => try buf.appendSlice(allocator, "\\r"),
        '\t' => try buf.appendSlice(allocator, "\\t"),
        0...0x07, 0x0b, 0x0e...0x1f => {
            const hex = try std.fmt.allocPrint(allocator, "\\u{x:0>4}", .{c});
            defer allocator.free(hex);
            try buf.appendSlice(allocator, hex);
        },
        else => try buf.append(allocator, c),
    };
    try buf.append(allocator, '"');
}

fn appendJsonNumField(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    prefix: []const u8,
    value: i64,
) !void {
    try buf.appendSlice(allocator, prefix);
    const s = try std.fmt.allocPrint(allocator, "{d}", .{value});
    defer allocator.free(s);
    try buf.appendSlice(allocator, s);
}

/// v1.29.0 — same shape but for unsigned 64-bit values used in
/// the diagnostics serializer (token counts can exceed i64 range
/// in pathological cases; cheap to keep them unsigned).
fn appendJsonU64Field(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    prefix: []const u8,
    value: u64,
) !void {
    try buf.appendSlice(allocator, prefix);
    const s = try std.fmt.allocPrint(allocator, "{d}", .{value});
    defer allocator.free(s);
    try buf.appendSlice(allocator, s);
}

/// Serialize an f64 cost field as a JSON number. Always emits a
/// decimal point (even for whole numbers like `0` or `1`) so the
/// JSON parser tags it as `.float` on round-trip. Guards against
/// non-finite values (nan/inf are not valid JSON).
fn appendJsonF64Field(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    prefix: []const u8,
    value: f64,
) !void {
    if (!std.math.isFinite(value)) return; // skip nan/inf
    try buf.appendSlice(allocator, prefix);
    const s = try std.fmt.allocPrint(allocator, "{d}", .{value});
    defer allocator.free(s);
    try buf.appendSlice(allocator, s);
    // Ensure a decimal point so the value is always tagged .float.
    if (std.mem.indexOfScalar(u8, s, '.') == null and
        std.mem.indexOfScalar(u8, s, 'e') == null)
    {
        try buf.appendSlice(allocator, ".0");
    }
}

// ─── filesystem ───────────────────────────────────────────────────

var tmp_counter: std.atomic.Value(u32) = .init(0);

pub fn atomicWrite(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var tmp_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    // Avoid direct wall-clock: use a process counter (unique enough for
    // atomic-rename scratch paths).
    const counter = tmp_counter.fetchAdd(1, .monotonic);
    const tmp_path = try std.fmt.bufPrint(&tmp_path_buf, "{s}.tmp.{d}", .{ path, counter });

    const cwd = std.Io.Dir.cwd();
    {
        var f = try cwd.createFile(io, tmp_path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, bytes);
        f.sync(io) catch {}; // best-effort on platforms that don't support it
    }
    cwd.rename(tmp_path, cwd, path, io) catch |e| {
        cwd.deleteFile(io, tmp_path) catch {};
        return e;
    };
}

pub fn readWholeFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const cwd = std.Io.Dir.cwd();
    var f = try cwd.openFile(io, path, .{});
    defer f.close(io);
    const len = try f.length(io);
    const buf = try allocator.alloc(u8, @intCast(len));
    const n = try f.readPositionalAll(io, buf, 0);
    return buf[0..n];
}

// ─── session migrations — §H.5 ────────────────────────────────────
//
// Each pre-existing on-disk session declares a `version`. When the
// session was written at a version lower than
// `current_session_version`, `migrateSessionIfNeeded` runs the
// migration chain step-by-step, writes the pre-migration file to
// `<path>.bak`, and rewrites the file at the current version.
// `version > current` always fails with `UnsupportedSessionVersion`
// — newer files stay unreadable until the binary is upgraded.
//
// Today every `version <= 2 → 3` step is a no-op on the observable
// fields (v2 already had every field we need; `readSessionHeader`
// supplied defaults for missing ones). This module ships the
// framework — adding a real schema change only needs a new
// MigrationFn entry in `session_migrations` and a matching
// `current_session_version` bump.

pub const SessionMigrationError = error{
    UnsupportedSessionVersion,
    FileNotFound,
} || std.mem.Allocator.Error;

pub const MigratedSession = struct {
    original_version: u32,
    current_version: u32,
    migrated: bool,
};

/// Probe `<session_dir>/session.json` and, if it's older than the
/// current version, back it up and re-emit at the current version.
/// Returns metadata describing the migration outcome. A missing
/// session file surfaces as the caller's `FileNotFound` error; this
/// helper is only ever called by an explicit resume path.
pub fn migrateSessionIfNeeded(
    allocator: std.mem.Allocator,
    io: std.Io,
    session_dir: []const u8,
) anyerror!MigratedSession {
    const path = try std.fs.path.join(allocator, &.{ session_dir, "session.json" });
    defer allocator.free(path);

    const bytes = try readWholeFile(allocator, io, path);
    defer allocator.free(bytes);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();

    const version: u32 = blk: {
        const obj = parsed.value.object;
        if (obj.get("version")) |v| {
            if (v == .integer and v.integer >= 0) break :blk @intCast(v.integer);
        }
        break :blk 1; // absent version → oldest shape
    };

    if (version == current_session_version) {
        return .{
            .original_version = version,
            .current_version = current_session_version,
            .migrated = false,
        };
    }
    if (version > current_session_version) {
        return SessionMigrationError.UnsupportedSessionVersion;
    }

    // Back up the pre-migration file.
    const bak_path = try std.fmt.allocPrint(allocator, "{s}.bak", .{path});
    defer allocator.free(bak_path);
    try atomicWrite(io, bak_path, bytes);

    // Load into `SessionHeader` — existing defaults cover every
    // v1/v2-era missing field, so the shared path is the migration.
    const header = try readSessionHeader(allocator, io, session_dir);
    defer freeSessionHeader(allocator, header);

    // Re-emit at `current_session_version`.
    try writeSessionHeader(allocator, io, session_dir, header);

    return .{
        .original_version = version,
        .current_version = current_session_version,
        .migrated = true,
    };
}

// ─── v2.18 — sweep assertion ────────────────────────────────────

/// Development assertion: every content-block `.ref` in the transcript
/// must have its hash present in `keep`. Panics on mismatch.
/// Stripped in ReleaseFast/ReleaseSmall, so the check is a debugging
/// aid, not a security boundary.
///
/// Since in-memory `ContentBlock` does not carry a `.ref` variant
/// (refs are created during serialization via `appendContentBlockJsonMaybeExtern`),
/// this function re-serializes each content block and, if the rendered JSON
/// exceeds `object_store.inline_threshold_bytes`, computes its SHA-256 hex
/// and asserts it is present in `keep`. This catches call-site bugs where
/// the `keep` list is assembled incompletely.
pub fn assertRefsInKeep(
    allocator: std.mem.Allocator,
    transcript: *const agent_mod.loop.Transcript,
    keep: []const []const u8,
) void {
    if (builtin.mode == .fast or builtin.mode == .small) return;

    var tmp: std.ArrayList(u8) = .empty;
    defer tmp.deinit(allocator);
    for (transcript.messages.items) |msg| {
        for (msg.content) |cb| {
            tmp.clearRetainingCapacity();
            appendContentBlockJson(&tmp, allocator, cb) catch @panic("assertRefsInKeep: appendContentBlockJson failed");

            if (tmp.items.len < object_store.inline_threshold_bytes) continue;

            const hex = sha256Hex(allocator, tmp.items) catch @panic("assertRefsInKeep: sha256Hex failed");
            defer allocator.free(hex);

            var found = false;
            for (keep) |h| {
                if (std.mem.eql(u8, h, hex)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                @panic("object_store ref hash not in keep list — data loss risk");
            }
        }
    }
}
