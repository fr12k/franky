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
//!     The first line is a header `{"type":"meta","version":4,
//!     "branch":"<name>"}`; each subsequent line is one message.
//!     `readTranscript`/`readBranchTranscript` transparently read
//!     legacy `.json` files (v ≤ 3) so existing sessions resume
//!     without a migration step.

const std = @import("std");
const builtin = @import("builtin");
const ai = struct {
    pub const types = @import("../../ai/types.zig");
};
const agent_mod = @import("../../agent/mod.zig");
const object_store = @import("object_store.zig");

pub const current_session_version: u32 = 3;
/// v1.30.0 — transcript schema bumped to 4 for the JSON Lines
/// on-disk format. Legacy `.json` transcripts at version ≤ 3 are
/// still readable (`readTranscript` detects the old shape).
pub const current_transcript_version: u32 = 4;
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
) !void {
    const store_dir = try std.fs.path.join(allocator, &.{ session_dir, "objects" });
    defer allocator.free(store_dir);

    // Line 1 — header / meta line. Compact (not pretty-printed) like
    // every subsequent line; Claude Code transcripts use the same
    // one-JSON-object-per-line convention.
    try out.appendSlice(allocator, "{\"type\":\"meta\",\"version\":");
    const ver = try std.fmt.allocPrint(allocator, "{d}", .{current_transcript_version});
    defer allocator.free(ver);
    try out.appendSlice(allocator, ver);
    try out.appendSlice(allocator, ",\"branch\":");
    try appendJsonStr(out, allocator, branch);
    try out.appendSlice(allocator, "}");
    try out.append(allocator, '\n');

    // One message per line.
    for (transcript.messages.items) |m| {
        try appendMessageJson(out, allocator, io, store_dir, m);
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
) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try renderTranscriptJsonl(&buf, allocator, io, session_dir, transcript, branch);

    const path = try std.fs.path.join(allocator, &.{ session_dir, "transcript.jsonl" });
    defer allocator.free(path);
    try atomicWrite(io, path, buf.items);

    // Best-effort cleanup of a pre-v1.30 `transcript.json` so we don't
    // leave a stale duplicate on disk. A failure here is harmless —
    // the reader prefers `.jsonl` and only falls back to `.json` when
    // the new file is missing.
    const legacy_path = try std.fs.path.join(allocator, &.{ session_dir, "transcript.json" });
    defer allocator.free(legacy_path);
    std.Io.Dir.cwd().deleteFile(io, legacy_path) catch {};
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

    // Prefer the v1.30 JSON Lines file.
    const jsonl_path = try std.fs.path.join(allocator, &.{ session_dir, "transcript.jsonl" });
    defer allocator.free(jsonl_path);
    if (readWholeFile(allocator, io, jsonl_path)) |bytes| {
        defer allocator.free(bytes);
        return try parseTranscriptJsonl(allocator, io, store_dir, bytes);
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    // Fall back to the legacy single-JSON `transcript.json`.
    const legacy_path = try std.fs.path.join(allocator, &.{ session_dir, "transcript.json" });
    defer allocator.free(legacy_path);
    const bytes = try readWholeFile(allocator, io, legacy_path);
    defer allocator.free(bytes);
    return try parseTranscriptLegacyJson(allocator, io, store_dir, bytes);
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
    try renderTranscriptJsonl(&buf, allocator, io, session_dir, transcript, branch);

    const file_name = try std.fmt.allocPrint(allocator, "{s}.jsonl", .{branch});
    defer allocator.free(file_name);
    const path = try std.fs.path.join(allocator, &.{ snap_dir, file_name });
    defer allocator.free(path);
    try atomicWrite(io, path, buf.items);

    // Best-effort cleanup of a pre-v1.30 `<branch>.json` snapshot.
    const legacy_name = try std.fmt.allocPrint(allocator, "{s}.json", .{branch});
    defer allocator.free(legacy_name);
    const legacy_path = try std.fs.path.join(allocator, &.{ snap_dir, legacy_name });
    defer allocator.free(legacy_path);
    std.Io.Dir.cwd().deleteFile(io, legacy_path) catch {};
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

    // Prefer the v1.30 JSON Lines file.
    const jsonl_name = try std.fmt.allocPrint(allocator, "transcripts/{s}.jsonl", .{branch});
    defer allocator.free(jsonl_name);
    const jsonl_path = try std.fs.path.join(allocator, &.{ session_dir, jsonl_name });
    defer allocator.free(jsonl_path);
    if (readWholeFile(allocator, io, jsonl_path)) |bytes| {
        defer allocator.free(bytes);
        return try parseTranscriptJsonl(allocator, io, store_dir, bytes);
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    // Fall back to the legacy single-JSON `<branch>.json`.
    const legacy_name = try std.fmt.allocPrint(allocator, "transcripts/{s}.json", .{branch});
    defer allocator.free(legacy_name);
    const legacy_path = try std.fs.path.join(allocator, &.{ session_dir, legacy_name });
    defer allocator.free(legacy_path);
    const bytes = try readWholeFile(allocator, io, legacy_path);
    defer allocator.free(bytes);
    return try parseTranscriptLegacyJson(allocator, io, store_dir, bytes);
}

// ─── v1.30.0 transcript parsers ───────────────────────────────────

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

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const obj = parsed.value.object;

        // First non-empty line may be the meta header. We validate the
        // version but otherwise ignore it — the branch is already known
        // to the caller (it's the active branch or the requested
        // `--checkout` name).
        if (first_line) {
            first_line = false;
            const type_str = strOpt(obj, "type") orelse "";
            if (std.mem.eql(u8, type_str, "meta")) {
                const version = if (obj.get("version")) |v| v.integer else 0;
                if (version > current_transcript_version) return error.UnsupportedTranscriptVersion;
                continue;
            }
            // Not a meta line — fall through and treat as a message.
        }

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
    const version = if (root.get("version")) |v| v.integer else 0;
    if (version > legacy_transcript_version) return error.UnsupportedTranscriptVersion;

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

fn appendMessageJson(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    io: std.Io,
    store_dir: []const u8,
    m: ai.types.Message,
) !void {
    try buf.appendSlice(allocator, "{");
    const role_name = switch (m.role) {
        .user => "user",
        .assistant => "assistant",
        .tool_result => "toolResult",
        .custom => m.custom_role orelse "custom",
    };
    try buf.appendSlice(allocator, "\"role\":");
    try appendJsonStr(buf, allocator, role_name);
    try appendJsonNumField(buf, allocator, ",\"timestamp\":", m.timestamp);

    if (m.tool_call_id) |tid| {
        try buf.appendSlice(allocator, ",\"toolCallId\":");
        try appendJsonStr(buf, allocator, tid);
    }
    if (m.is_error) try buf.appendSlice(allocator, ",\"isError\":true");

    try buf.appendSlice(allocator, ",\"content\":[");
    for (m.content, 0..) |cb, i| {
        if (i > 0) try buf.appendSlice(allocator, ",");
        try appendContentBlockJsonMaybeExtern(buf, allocator, io, store_dir, cb);
    }
    try buf.appendSlice(allocator, "]");

    if (m.stop_reason) |sr| {
        try buf.appendSlice(allocator, ",\"stopReason\":");
        try appendJsonStr(buf, allocator, sr.toString());
    }
    if (m.provider) |p| {
        try buf.appendSlice(allocator, ",\"provider\":");
        try appendJsonStr(buf, allocator, p);
    }
    if (m.model) |p| {
        try buf.appendSlice(allocator, ",\"model\":");
        try appendJsonStr(buf, allocator, p);
    }
    if (m.api) |p| {
        try buf.appendSlice(allocator, ",\"api\":");
        try appendJsonStr(buf, allocator, p);
    }
    // v1.29.0 — Message.Diagnostics. Only emit when at least one
    // field is non-default; pre-v1.29 transcripts round-trip
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
    try buf.appendSlice(allocator, "}");
}

/// Render a content block's canonical JSON inline. Pure — no IO.
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
            try appendJsonStr(buf, allocator, "toolCall");
            try buf.appendSlice(allocator, ",\"id\":");
            try appendJsonStr(buf, allocator, t.id);
            try buf.appendSlice(allocator, ",\"name\":");
            try appendJsonStr(buf, allocator, t.name);
            // arguments is emitted as a raw JSON value (we trust it to be
            // valid JSON — it came from the model via the partial-json
            // parser or, on round-trip, from a prior serialization).
            try buf.appendSlice(allocator, ",\"arguments\":");
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

fn parseMessage(
    allocator: std.mem.Allocator,
    io: std.Io,
    store_dir: []const u8,
    o: std.json.ObjectMap,
) !ai.types.Message {
    const role_str = strOpt(o, "role") orelse "user";
    const role: ai.types.Role = if (std.mem.eql(u8, role_str, "user"))
        .user
    else if (std.mem.eql(u8, role_str, "assistant"))
        .assistant
    else if (std.mem.eql(u8, role_str, "toolResult"))
        .tool_result
    else
        .custom;

    var content: std.ArrayList(ai.types.ContentBlock) = .empty;
    errdefer {
        for (content.items) |cb| cb.deinit(allocator);
        content.deinit(allocator);
    }

    if (o.get("content")) |cv| if (cv == .array) {
        for (cv.array.items) |v| {
            if (v != .object) continue;
            const cb = try parseContentBlockMaybeDeref(allocator, io, store_dir, v.object);
            try content.append(allocator, cb);
        }
    };

    // v1.29.0 — Diagnostics round-trip. Old transcripts without
    // the field decode as null and round-trip cleanly.
    var diag_opt: ?ai.types.Diagnostics = null;
    if (o.get("diagnostics")) |dv| if (dv == .object) {
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

    return .{
        .role = role,
        .content = try content.toOwnedSlice(allocator),
        .timestamp = if (o.get("timestamp")) |v| v.integer else 0,
        .stop_reason = if (o.get("stopReason")) |v| ai.types.StopReason.fromString(v.string) else null,
        .tool_call_id = if (o.get("toolCallId")) |v| try allocator.dupe(u8, v.string) else null,
        .is_error = if (o.get("isError")) |v| (v == .bool and v.bool) else false,
        .provider = if (o.get("provider")) |v| try allocator.dupe(u8, v.string) else null,
        .model = if (o.get("model")) |v| try allocator.dupe(u8, v.string) else null,
        .api = if (o.get("api")) |v| try allocator.dupe(u8, v.string) else null,
        .custom_role = if (role == .custom) try allocator.dupe(u8, role_str) else null,
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
    if (std.mem.eql(u8, type_str, "toolCall")) {
        const args_str: []u8 = if (o.get("arguments")) |av|
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
