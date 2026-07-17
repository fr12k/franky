//! Agent layer types — §4 of the spec.

const std = @import("std");
const ai = struct {
    pub const types = @import("../ai/types.zig");
    pub const errors = @import("../ai/errors.zig");
    pub const stream = @import("../ai/stream.zig");
    pub const channel = @import("../ai/channel.zig");
};

pub const ToolResult = struct {
    /// Content blocks produced by the tool (text/image). Owned.
    content: []ai.types.ContentBlock,
    /// Opaque renderer metadata (diff, table, …) — not shown to the model.
    details_json: ?[]const u8 = null,
    is_error: bool = false,
    /// §F.2 — tool-specific sub-code (`edit_no_match`,
    /// `path_escape_workspace`, `bash_timeout`, …) when `is_error`
    /// is true. Callers that escalate a tool error to an
    /// `agent_error` stream event copy this into
    /// `ErrorDetails.tool_code` while the top-level `code` stays
    /// `.tool_runtime`. Owned by the result's allocator.
    tool_code: ?[]const u8 = null,
    /// Ask the loop to stop after this tool's batch completes.
    terminate: bool = false,

    pub fn deinit(self: *ToolResult, allocator: std.mem.Allocator) void {
        for (self.content) |cb| cb.deinit(allocator);
        allocator.free(self.content);
        if (self.details_json) |s| allocator.free(s);
        if (self.tool_code) |s| allocator.free(s);
    }
};

pub const ExecutionMode = enum { sequential, parallel };

/// Stable wire-format constant for the `tool_code` value the
/// runtime role gate emits. Web UI / RPC clients key off this
/// string to render denials distinctly from generic tool errors.
pub const role_denied_code = "role_denied";

/// Update streamed from tool execution into the event stream.
pub const ToolUpdate = struct {
    /// Free-form JSON blob the tool wants the UI to render as progress.
    json: []const u8,
};

pub const OnUpdateFn = *const fn (userdata: ?*anyopaque, update: ToolUpdate) void;

pub const OnUpdate = struct {
    ctx: ?*anyopaque = null,
    call: ?OnUpdateFn = null,

    pub fn push(self: OnUpdate, update: ToolUpdate) void {
        if (self.call) |f| f(self.ctx, update);
    }
};

pub const AgentMessage = ai.types.Message;

pub const AgentChannel = ai.channel.Channel(AgentEvent);

/// Ordered sequence of messages that forms the conversation context.
///
/// Callers seed it with prior history; the loop appends assistant and
/// tool-result messages. Ownership of each message is transferred to
/// `messages` — caller deinits the whole thing with `Transcript.deinit`.
pub const Transcript = struct {
    allocator: std.mem.Allocator,
    messages: std.ArrayList(AgentMessage) = .empty,

    pub fn init(allocator: std.mem.Allocator) Transcript {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *Transcript) void {
        for (self.messages.items) |*m| m.deinit(self.allocator);
        self.messages.deinit(self.allocator);
    }
    pub fn append(self: *Transcript, msg: AgentMessage) !void {
        try self.messages.append(self.allocator, msg);
    }
};

/// Tool vtable interface. Tools carry opaque state via `ctx`.
pub const AgentTool = struct {
    name: []const u8,
    description: []const u8,
    parameters_json: []const u8,
    execution_mode: ExecutionMode = .parallel,
    ctx: ?*anyopaque = null,
    /// When true, the tool's result is never compressed even if compression
    /// is enabled. Use this for tools whose output must remain intact for
    /// the LLM to verify its own actions (e.g. edit/write confirmations).
    skip_compression: bool = false,
    /// Runs the tool. Arguments arrive as a JSON string (authoritative).
    /// `on_update` may be invoked any number of times to stream progress.
    /// Returns a `ToolResult`; throwing is allowed — the loop will catch
    /// and wrap it as an error result (§4.5).
    execute: *const fn (
        tool: *const AgentTool,
        allocator: std.mem.Allocator,
        io: std.Io,
        call_id: []const u8,
        args_json: []const u8,
        cancel: *ai.stream.Cancel,
        on_update: OnUpdate,
    ) anyerror!ToolResult,
};

pub const AgentEventKind = enum {
    turn_start,
    message_start,
    message_update,
    message_end,
    tool_execution_start,
    tool_execution_update,
    tool_execution_end,
    /// v1.11.1 — pause-and-prompt for the permission overlay
    /// (§5.11). Emitted from `before_tool_call` when policy says
    /// `ask`; mode drivers handle the prompt and call back via
    /// `permissions.PermissionPrompter.resolve`. The worker
    /// thread blocks on a `Condition` until then.
    tool_permission_request,
    turn_end,
    /// vN — emitted when the loop was interrupted gracefully
    /// (stop-requested flag set) after the current turn finished.
    /// Consumers (UI) can use this to show "turn stopped" vs
    /// "turn ended naturally" vs "turn cancelled". The transcript
    /// up to this point is preserved; no error is logged.
    agent_interrupted,
    /// §6.13 — provider retry in progress.
    provider_retry,
    agent_error,
};

pub const MessageUpdateDelta = union(enum) {
    text: struct { block_index: u32, delta: []const u8 },
    thinking: struct { block_index: u32, delta: []const u8 },
    toolcall_args: struct { block_index: u32, delta: []const u8 },
};

pub const AgentEvent = union(AgentEventKind) {
    turn_start: void,
    message_start: struct {
        role: ai.types.Role,
        /// Custom role string when role == .custom. Owned.
        custom_role: ?[]const u8 = null,
    },
    message_update: MessageUpdateDelta,
    /// Payload is the finalized message. Owned by the event.
    message_end: ai.types.Message,
    tool_execution_start: struct {
        call_id: []const u8,
        name: []const u8,
        args_json: []const u8,
    },
    tool_execution_update: struct {
        call_id: []const u8,
        update_json: []const u8,
    },
    tool_execution_end: struct {
        call_id: []const u8,
        result: ToolResult,
    },
    tool_permission_request: struct {
        call_id: []const u8,
        tool_name: []const u8,
        /// Raw arguments JSON the model emitted — clients use it
        /// to render `bash: rm -rf /tmp/foo` in the prompt.
        args_json: []const u8,
        /// Best-effort verb fingerprint (`fingerprintBash` for
        /// bash; tool name for everything else). Surfaces the
        /// "this is what an `always_*` decision will remember"
        /// hint without forcing every client to re-implement
        /// fingerprint logic.
        fingerprint: []const u8,
    },
    turn_end: void,
    agent_interrupted: void,
    /// §6.13 — provider is being retried after a retryable error.
    /// Non-terminal; loop forwards this from the stream to the
    /// agent event channel so subscribers see \"retrying in Ns\".
    /// String fields are owned and freed via `deinit`.
    provider_retry: struct {
        attempt: u32,
        max_attempts: u32,
        delay_ms: u32,
        reason: ai.errors.Code,
        provider_code: ?[]const u8 = null,
        provider_message: ?[]const u8 = null,
        http_status: ?u16 = null,
    },
    agent_error: ai.errors.ErrorDetails,

    pub fn isTerminal(self: AgentEvent) bool {
        return switch (self) {
            .agent_error => |d| d.is_fatal,
            .agent_interrupted => true,
            else => false,
        };
    }

    pub fn deinit(self: AgentEvent, allocator: std.mem.Allocator) void {
        switch (self) {
            .turn_start, .turn_end, .agent_interrupted => {},
            .provider_retry => |r| {
                if (r.provider_code) |v| allocator.free(v);
                if (r.provider_message) |v| allocator.free(v);
            },
            .message_start => |s| if (s.custom_role) |v| allocator.free(v),
            .message_update => |m| switch (m) {
                .text => |t| allocator.free(t.delta),
                .thinking => |t| allocator.free(t.delta),
                .toolcall_args => |t| allocator.free(t.delta),
            },
            .message_end => |m| {
                var mut = m;
                mut.deinit(allocator);
            },
            .tool_execution_start => |s| {
                allocator.free(s.call_id);
                allocator.free(s.name);
                allocator.free(s.args_json);
            },
            .tool_execution_update => |u| {
                allocator.free(u.call_id);
                allocator.free(u.update_json);
            },
            .tool_execution_end => |e| {
                allocator.free(e.call_id);
                var r = e.result;
                r.deinit(allocator);
            },
            .tool_permission_request => |r| {
                allocator.free(r.call_id);
                allocator.free(r.tool_name);
                allocator.free(r.args_json);
                allocator.free(r.fingerprint);
            },
            .agent_error => |d| {
                allocator.free(d.message);
                if (d.tool_code) |v| allocator.free(v);
                if (d.provider_code) |v| allocator.free(v);
                if (d.provider_message) |v| allocator.free(v);
            },
        }
    }
};

test "AgentEvent.deinit round-trips" {
    const gpa = @import("../global_allocator.zig").gpa;
    const ev = AgentEvent{
        .tool_execution_start = .{
            .call_id = try gpa.dupe(u8, "id-1"),
            .name = try gpa.dupe(u8, "read"),
            .args_json = try gpa.dupe(u8, "{}"),
        },
    };
    ev.deinit(gpa);
}
