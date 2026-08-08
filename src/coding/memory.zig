//! Memory integration module — bridges agent-memory-zig with franky.
//!
//! Provides:
//! - `MemoryState` — owns the agent_memory.SqliteStore + MemoryContext
//! - `buildMemoryContext()` — recalls L1/L2/L3 and formats as a bounded
//!   context block for system prompt injection.
//! - `captureTurn()` — writes franky messages to L0 (raw conversations).
//!
//! This module is the single integration point between franky and the
//! agent-memory-zig package. It depends on agent_memory (the package)
//! and franky's ai.types (for Message conversion). It does NOT depend
//! on franky's LLM registry — the agent drives memory via tools.

const std = @import("std");
const agent_memory = @import("agent_memory");
const ai = @import("../ai/types.zig");

/// Configuration for the memory integration.
pub const MemoryConfig = struct {
    /// Path to the SQLite database file.
    db_path: []const u8,
    /// Directory for L2/L3 markdown files.
    data_dir: []const u8,
    /// Isolation context (team/user/agent/session).
    iso: agent_memory.IsolationContext = .{},
    /// Max L1 results to inject into the system prompt (default 10).
    recall_top_k: u32 = 10,
    /// Max characters of memory context to inject (0 = unlimited).
    max_context_chars: usize = 4000,
};

/// Owns the memory store and context. Created once at session start,
/// deinit'd at session end.
pub const MemoryState = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    store: agent_memory.SqliteStore,
    ctx: agent_memory.MemoryContext,
    config: MemoryConfig,
    /// Whether memory is enabled (store opened successfully).
    enabled: bool = true,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: MemoryConfig) !MemoryState {
        // db_path needs to be null-terminated for SQLite.
        const db_path_z = try allocator.allocSentinel(u8, config.db_path.len, 0);
        defer allocator.free(db_path_z);
        @memcpy(db_path_z[0..config.db_path.len], config.db_path);

        const store = try agent_memory.SqliteStore.init(allocator, io, db_path_z, config.data_dir);

        var state: MemoryState = .{
            .allocator = allocator,
            .io = io,
            .store = store,
            // ctx.store is patched below — `toMemoryStore()` captures
            // `&store`, so it MUST point at the field in its final
            // location, not the local `store` in this frame.
            .ctx = .{
                .store = undefined,
                .iso = config.iso,
            },
            .config = config,
        };
        state.ctx.store = state.store.toMemoryStore();
        return state;
    }

    /// v3.2 — re-point `ctx.store` at the `store` field in its current
    /// location. `init()` returns by value, so the pointer captured in
    /// `init()` dangles after the caller moves the struct into its
    /// final home (typically `a.create(MemoryState); mem.* = init(...)`).
    /// Call this once after the struct lands at its final address.
    pub fn repointCtx(self: *MemoryState) void {
        self.ctx.store = self.store.toMemoryStore();
    }

    pub fn deinit(self: *MemoryState) void {
        self.store.deinit();
    }

    /// Build the memory context block for system prompt injection.
    /// Returns null if no memory found or memory is disabled.
    /// Caller owns the returned slice.
    pub fn buildContextBlock(self: *MemoryState, query: []const u8) !?[]u8 {
        if (!self.enabled) return null;

        var recall = try self.ctx.recallWithBudget(self.allocator, query, self.config.recall_top_k, self.config.max_context_chars);
        defer recall.deinit(self.allocator);

        if (recall.total_chars == 0) return null;

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);

        try buf.appendSlice(self.allocator, "<memory_context>\n");

        // L3 persona
        if (recall.persona) |p| {
            try buf.appendSlice(self.allocator, "## Persona\n");
            try buf.appendSlice(self.allocator, p);
            try buf.appendSlice(self.allocator, "\n\n");
        }

        // L1 facts
        if (recall.l1_results.len > 0) {
            try buf.appendSlice(self.allocator, "## Relevant Memories\n");
            for (recall.l1_results) |r| {
                const line = try std.fmt.allocPrint(self.allocator, "- [{s}, p={d}] {s}\n", .{
                    r.type.toString(),
                    @as(i32, @intFromFloat(r.priority)),
                    r.content,
                });
                defer self.allocator.free(line);
                try buf.appendSlice(self.allocator, line);
            }
            try buf.appendSlice(self.allocator, "\n");
        }

        // L2 scenarios
        for (recall.scenario_files) |s| {
            const header = try std.fmt.allocPrint(self.allocator, "## Scenario: {s}\n", .{s.path});
            defer self.allocator.free(header);
            try buf.appendSlice(self.allocator, header);
            try buf.appendSlice(self.allocator, s.content);
            try buf.appendSlice(self.allocator, "\n\n");
        }

        try buf.appendSlice(self.allocator, "</memory_context>");

        // Enforce character budget (truncate if needed).
        if (self.config.max_context_chars > 0 and buf.items.len > self.config.max_context_chars) {
            // Truncate — replace the closing tag with a note.
            const trunc_len = self.config.max_context_chars;
            const truncated = try self.allocator.alloc(u8, trunc_len);
            @memcpy(truncated[0..trunc_len], buf.items[0..trunc_len]);
            // Overwrite the end with the closing tag.
            const close_tag = "</memory_context>";
            const start = trunc_len - close_tag.len;
            @memcpy(truncated[start..], close_tag);
            return truncated;
        }

        return try buf.toOwnedSlice(self.allocator);
    }

    /// Capture franky messages to L0 (raw conversations).
    /// This is a cheap SQLite INSERT — no LLM call.
    pub fn captureTurn(
        self: *MemoryState,
        messages: []const ai.Message,
    ) !void {
        if (!self.enabled) return;
        if (messages.len == 0) return;

        var records = try self.allocator.alloc(agent_memory.L0Record, messages.len);
        defer self.allocator.free(records);

        const now_ms = nowMillis();
        const session_id = self.config.iso.session_id orelse "default";

        for (messages, 0..) |msg, i| {
            // Extract text content from the message.
            const text = try extractText(self.allocator, msg);
            records[i] = .{
                .id = try std.fmt.allocPrint(self.allocator, "msg-{d}-{d}", .{ now_ms, i }),
                .session_key = session_id,
                .session_id = session_id,
                .role = try roleString(msg.role),
                .message_text = text,
                .recorded_at = try std.fmt.allocPrint(self.allocator, "{d}", .{now_ms}),
                .timestamp = now_ms + @as(i64, @intCast(i)),
            };
        }

        // Free all allocated strings after the store copies them.
        defer {
            for (records) |r| {
                self.allocator.free(r.id);
                self.allocator.free(r.message_text);
                self.allocator.free(r.recorded_at);
            }
        }

        try self.store.addConversation(records, self.config.iso);
    }
};

// ============================
// Helpers
// ============================

/// Current time as millisecond timestamp (epoch).
/// Matches franky's ai.stream.nowMillis signature.
fn nowMillis() i64 {
    const builtin = @import("builtin");
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var ts: linux.timespec = undefined;
        if (linux.clock_gettime(.REALTIME, &ts) == 0) {
            return @as(i64, ts.sec) * 1000 + @divFloor(@as(i64, ts.nsec), std.time.ns_per_ms);
        }
        return 0;
    }
    if (builtin.link_libc) {
        var ts: std.c.timespec = undefined;
        if (std.c.clock_gettime(.REALTIME, &ts) == 0) {
            return @as(i64, ts.sec) * 1000 + @divFloor(@as(i64, ts.nsec), std.time.ns_per_ms);
        }
    }
    return 0;
}

/// Convert a franky Message role to a string for L0 storage.
fn roleString(role: ai.Role) ![]const u8 {
    return switch (role) {
        .user => "user",
        .assistant => "assistant",
        .tool_result => "tool",
        .custom => "custom",
    };
}

/// Extract text content from a franky Message (concatenates all text blocks).
fn extractText(allocator: std.mem.Allocator, msg: ai.Message) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    for (msg.content) |cb| {
        switch (cb) {
            .text => |t| {
                try buf.appendSlice(allocator, t.text);
            },
            else => {},
        }
    }
    return try buf.toOwnedSlice(allocator);
}