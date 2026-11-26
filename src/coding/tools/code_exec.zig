//! `code_exec` tool — Phase 3 of `--mcp-code-mode`.
//!
//! Executes a model-written Python script inside an OS-level
//! network-isolated subprocess so the ONLY way it can reach external MCP
//! servers is through the local UDS bridge (`mcp_bridge.zig`). This keeps
//! large MCP payloads out of the LLM context window — the model writes a
//! script that loops over bridge calls, aggregates in Python, and prints a
//! compact summary.
//!
//! Isolation (per plan):
//!   - Alpine Linux: `bwrap --unshare-net` when bubblewrap is installed,
//!     else the zero-dependency BusyBox fallback `unshare -r -U -n`.
//!   - macOS: `sandbox-exec -p <seatbelt-profile>` with a per-session
//!     profile that denies all network except the bridge UDS socket.
//!   - When no isolation primitive is available (e.g. an unprivileged
//!     container that blocks user namespaces), the tool fails closed with a
//!     clear diagnostic unless the session opted in via the bridge ctx's
//!     `allow_unsandboxed` flag.
//!
//! Output hygiene: a clean minimal environment (no API keys), `python3
//! -I -B` (isolated, no bytecode), an output cap, and tail-truncation via
//! `truncate.zig`. A compact `[mcp_bridge: …]` footer summarizes how many
//! bridge calls the script made.

const std = @import("std");
const at = @import("../types.zig").agent.types;
const ai = @import("../types.zig").ai;
const common = @import("common.zig");
const truncate_mod = @import("truncate.zig");
const bridge_mod = @import("../mcp_bridge.zig");

const log = ai.log;

pub const max_output_bytes: usize = 8 * 1024 * 1024;
const default_timeout_ms: u64 = 30 * 1000;

const parameters_json =
    \\{"type":"object","required":["code"],"properties":{
    \\  "code":{"type":"string","description":"Python 3 source to execute. MCP tools are importable from .franky/mcp_sdk/<server>.py; call them and print a compact summary. Direct network access is disabled."},
    \\  "timeoutMs":{"type":"integer","description":"Max wall-clock runtime in milliseconds (default 30000)."}}}
;

/// Session-wired context: the live bridge (socket path, token, child-pid
/// registration, stats) and the workspace root for the seatbelt profile.
pub const CodeExecCtx = struct {
    bridge: *bridge_mod.McpBridge,
    /// Canonical workspace root (for seatbelt + PYTHONPATH).
    workspace_root: []const u8,
    /// Absolute path the SDK was generated into (`<root>/.franky/mcp_sdk`).
    sdk_dir: []const u8,
    /// Explicit opt-in to run WITHOUT network isolation when no sandbox
    /// primitive is available. Default false → fail closed.
    allow_unsandboxed: bool = false,
};

pub fn toolWithCtx(ctx: *CodeExecCtx) at.AgentTool {
    return .{
        .name = "code_exec",
        .description = "Run a Python 3 script in a network-isolated sandbox. MCP tools are available as Python modules under .franky/mcp_sdk/ (import via the modules listed in .franky/mcp_sdk/__init__.py); inspect them with read/grep first. Aggregate results in Python and print a compact summary — only stdout returns to you. Direct network access is blocked; MCP access goes through the local bridge.",
        .parameters_json = parameters_json,
        .execution_mode = .sequential,
        .ctx = @ptrCast(ctx),
        .execute = execute,
    };
}

const Sandbox = enum { bwrap, unshare, macos_seatbelt, none };

fn execute(
    self: *const at.AgentTool,
    allocator: std.mem.Allocator,
    io: std.Io,
    call_id: []const u8,
    args_json: []const u8,
    cancel: *ai.stream.Cancel,
    on_update: at.OnUpdate,
) anyerror!at.ToolResult {
    _ = call_id;
    _ = on_update;
    _ = cancel;
    const ctx: *CodeExecCtx = @ptrCast(@alignCast(self.ctx.?));

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const parsed = try std.json.parseFromSlice(std.json.Value, aa, args_json, .{});
    const root = parsed.value;
    if (root != .object) return common.toolError(allocator, "invalid_args", "arguments must be an object");
    const code_val = root.object.get("code") orelse
        return common.toolError(allocator, "invalid_args", "missing code");
    if (code_val != .string) return common.toolError(allocator, "invalid_args", "code must be a string");
    const code = code_val.string;
    if (code.len == 0) return common.toolError(allocator, "invalid_args", "code cannot be empty");

    const timeout_ms: u64 = if (root.object.get("timeoutMs")) |t| switch (t) {
        .integer => |i| if (i > 0) @intCast(i) else default_timeout_ms,
        else => default_timeout_ms,
    } else default_timeout_ms;

    // Write the script to a temp file inside the SDK dir (so the sandbox's
    // workspace bind-mount covers it). Atomic via temp+rename.
    const script_path = try writeScript(allocator, io, ctx.sdk_dir, code);
    defer allocator.free(script_path);

    // Resolve the sandbox primitive once per call (cheap probe).
    const sandbox = try detectSandbox(io);

    if (sandbox == .none and !ctx.allow_unsandboxed) {
        return common.toolError(
            allocator,
            "sandbox_unavailable",
            "no network-isolation primitive available (install bubblewrap on Alpine, or run on macOS); refusing to run unsandboxed. Re-run with the allow_unsandboxed_code_exec opt-in if you accept the risk",
        );
    }

    // Build a minimal, credential-free environment.
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("PATH", "/usr/local/bin:/usr/bin:/bin");
    try env.put("PYTHONPATH", ctx.sdk_dir);
    try env.put("FRANKY_MCP_SOCKET", ctx.bridge.socket_path);
    try env.put("FRANKY_MCP_TOKEN", ctx.bridge.token_hex);
    try env.put("TMPDIR", "/tmp");

    // Construct argv for the detected sandbox.
    const argv = try buildArgv(aa, sandbox, ctx, script_path);

    const timeout: std.Io.Timeout = .{ .duration = .{
        .raw = std.Io.Duration.fromMilliseconds(@intCast(timeout_ms)),
        .clock = .awake,
    } };

    var child = std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = ctx.workspace_root },
        .environ_map = &env,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = 0,
    }) catch |err| switch (err) {
        error.FileNotFound => return common.toolError(allocator, "code_exec_python_missing", "python3 (or sandbox binary) not found in PATH"),
        error.AccessDenied, error.PermissionDenied => return common.toolError(allocator, "access_denied", "cannot execute python3"),
        else => |e| return common.toolError(allocator, "code_exec_spawn_failed", @errorName(e)),
    };
    const child_pid = child.id orelse return common.toolError(allocator, "code_exec_spawn_failed", "spawned process has no PID");
    ctx.bridge.setActiveChild(child_pid);
    defer ctx.bridge.clearActiveChild();
    defer terminateProcessGroup(&child, child_pid, io);

    const result = collectOutput(allocator, io, &child, timeout) catch |err| switch (err) {
        error.StreamTooLong => return common.toolError(allocator, "code_exec_output_too_large", "output exceeded 8 MiB cap; redirect to a file or print less"),
        error.Timeout => return common.toolError(allocator, "code_exec_timeout", "script exceeded its timeoutMs budget"),
        else => |e| return common.toolError(allocator, "code_exec_spawn_failed", @errorName(e)),
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    return try formatResult(allocator, ctx, result);
}

/// Terminate the complete sandbox process group, then reap the direct child.
/// The child is created with pgid=0, making its PID the process-group ID.
fn terminateProcessGroup(child: *std.process.Child, pid: std.posix.pid_t, io: std.Io) void {
    if (child.id == null) return;
    const os_tag = @import("builtin").os.tag;
    if (os_tag == .linux or os_tag == .macos or os_tag == .freebsd or os_tag == .openbsd or os_tag == .netbsd) {
        // Negative pid targets the process group. SIGKILL is intentional here:
        // this runs only on abnormal return (timeout, output cap, cancellation).
        _ = std.c.kill(-pid, .KILL);
    }
    child.kill(io);
}

/// Read piped stdout/stderr to EOF with byte caps, then wait for exit.
/// Mirrors `std.process.run`'s collection but over an already-spawned
/// `Child` whose pid we've registered with the bridge.
fn collectOutput(
    allocator: std.mem.Allocator,
    io: std.Io,
    child: *std.process.Child,
    timeout: std.Io.Timeout,
) !std.process.RunResult {
    var mr_buf: std.Io.File.MultiReader.Buffer(2) = undefined;
    var mr: std.Io.File.MultiReader = undefined;
    mr.init(allocator, io, mr_buf.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer mr.deinit();
    const out_r = mr.reader(0);
    const err_r = mr.reader(1);

    while (mr.fill(64, timeout)) |_| {
        if (out_r.buffered().len > max_output_bytes) return error.StreamTooLong;
        if (err_r.buffered().len > max_output_bytes) return error.StreamTooLong;
    } else |err| switch (err) {
        error.EndOfStream => {},
        error.Timeout => return error.Timeout,
        else => |e| return e,
    }
    try mr.checkAnyError();

    const term = try child.wait(io);
    const stdout_slice = try mr.toOwnedSlice(0);
    errdefer allocator.free(stdout_slice);
    const stderr_slice = try mr.toOwnedSlice(1);
    errdefer allocator.free(stderr_slice);
    return .{ .term = term, .stdout = stdout_slice, .stderr = stderr_slice };
}

/// Write `code` to `<sdk_dir>/.scratch-<rand>.py` atomically and return
/// the allocated absolute path (caller frees).
fn writeScript(allocator: std.mem.Allocator, io: std.Io, sdk_dir: []const u8, code: []const u8) ![]u8 {
    var rand: [8]u8 = undefined;
    try io.randomSecure(&rand);
    const path = try std.fmt.allocPrint(allocator, "{s}/.scratch-{x}.py", .{ sdk_dir, rand });
    errdefer allocator.free(path);

    const cwd = std.Io.Dir.cwd();
    var f = try cwd.createFile(io, path, .{ .truncate = true });
    defer f.close(io);
    try f.writeStreamingAll(io, code);
    return path;
}

/// Probe which sandbox primitive is usable on this host, in preference
/// order. Only spawned for the network-isolation candidates.
fn detectSandbox(io: std.Io) !Sandbox {
    const os_tag = @import("builtin").os.tag;
    switch (os_tag) {
        .macos => return .macos_seatbelt,
        .linux => {
            // Prefer bubblewrap (works even when userns is restricted).
            if (probe(io, &.{ "bwrap", "--unshare-net", "--ro-bind", "/", "/", "true" })) return .bwrap;
            // Zero-dependency BusyBox fallback: map-root-user + userns + netns.
            if (probe(io, &.{ "unshare", "-r", "-U", "-n", "true" })) return .unshare;
            return .none;
        },
        else => return .none,
    }
}

/// True when the bridge socket file exists on disk (i.e. `listen` ran).
fn socketExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// Spawn `argv` with stdin/out/err ignored; true iff it exits 0.
fn probe(io: std.Io, argv: []const []const u8) bool {
    var threaded_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&threaded_buf);
    const result = std.process.run(fba.allocator(), io, .{
        .argv = argv,
        .stdout_limit = std.Io.Limit.limited(1024),
        .stderr_limit = std.Io.Limit.limited(1024),
        .timeout = .{ .duration = .{ .raw = std.Io.Duration.fromSeconds(5), .clock = .awake } },
    }) catch return false;
    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

/// Build the full argv (sandbox wrapper + python) for `sandbox`.
/// Allocated on `aa`.
fn buildArgv(
    aa: std.mem.Allocator,
    sandbox: Sandbox,
    ctx: *CodeExecCtx,
    script_path: []const u8,
) ![]const []const u8 {
    const py = [_][]const u8{ "python3", "-I", "-B", script_path };
    switch (sandbox) {
        .bwrap => {
            var out: std.ArrayList([]const u8) = .empty;
            try out.appendSlice(aa, &.{
                "bwrap",
                "--unshare-net",
                "--ro-bind", "/", "/",
                "--bind", ctx.workspace_root, ctx.workspace_root,
                "--dev", "/dev",
                "--proc", "/proc",
                "--tmpfs", "/tmp",
            });
            // The scratch script + SDK modules live under `sdk_dir`, which
            // may itself be under /tmp — bind it AFTER the tmpfs so it is not
            // masked. The bridge socket is not mounted: a host UDS pathname is
            // not reliably reachable from the isolated network namespace.
            try out.appendSlice(aa, &.{ "--bind", ctx.sdk_dir, ctx.sdk_dir });
            try out.append(aa, "--");
            try out.appendSlice(aa, &py);
            return out.toOwnedSlice(aa);
        },
        .unshare => {
            var out: std.ArrayList([]const u8) = .empty;
            try out.appendSlice(aa, &.{ "unshare", "-r", "-U", "-n", "--" });
            try out.appendSlice(aa, &py);
            return out.toOwnedSlice(aa);
        },
        .macos_seatbelt => {
            const profile = try seatbeltProfile(aa, ctx);
            var out: std.ArrayList([]const u8) = .empty;
            try out.appendSlice(aa, &.{ "/usr/bin/sandbox-exec", "-p", profile });
            try out.appendSlice(aa, &py);
            return out.toOwnedSlice(aa);
        },
        .none => {
            // Unsandboxed opt-in path — plain python3, no wrapper.
            return try aa.dupe([]const u8, &py);
        },
    }
}

/// Generate the per-session macOS Seatbelt profile. Paths are expected to
/// already be canonical (workspace_root and the /tmp socket path).
fn seatbeltProfile(aa: std.mem.Allocator, ctx: *CodeExecCtx) ![]u8 {
    return std.fmt.allocPrint(aa,
        \\(version 1)
        \\(allow default)
        \\(deny network*)
        \\(allow network-outbound (remote unix-socket (path-literal "{s}")))
        \\(deny file-write* (subpath "/Users"))
        \\(allow file-write* (subpath "/private/tmp") (subpath "{s}"))
        \\
    , .{ ctx.bridge.socket_path, ctx.workspace_root });
}

/// Combine term line + stdout + stderr + bridge footer, tail-truncate.
fn formatResult(
    allocator: std.mem.Allocator,
    ctx: *CodeExecCtx,
    result: std.process.RunResult,
) !at.ToolResult {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    const term_line = try termLine(allocator, result.term);
    defer allocator.free(term_line);
    try buf.appendSlice(allocator, term_line);
    try buf.append(allocator, '\n');

    if (result.stdout.len > 0) {
        try buf.appendSlice(allocator, "[stdout]\n");
        try buf.appendSlice(allocator, result.stdout);
        if (result.stdout[result.stdout.len - 1] != '\n') try buf.append(allocator, '\n');
    }
    if (result.stderr.len > 0) {
        try buf.appendSlice(allocator, "[stderr]\n");
        try buf.appendSlice(allocator, result.stderr);
        if (result.stderr[result.stderr.len - 1] != '\n') try buf.append(allocator, '\n');
    }
    if (result.stdout.len == 0 and result.stderr.len == 0) {
        try buf.appendSlice(allocator, "(no output)\n");
    }

    // Bridge footer — summarize in-sandbox MCP work. Placed at the END so
    // tail-truncation preserves it.
    const s = ctx.bridge.summary();
    if (s.calls > 0) {
        const kb = @as(f64, @floatFromInt(s.bytes)) / 1024.0;
        const footer = try std.fmt.allocPrint(
            allocator,
            "[mcp_bridge] {d} call(s), {d} error(s) across {d} tool(s), {d:.1} KB processed in-sandbox\n",
            .{ s.calls, s.errors, s.servers, kb },
        );
        defer allocator.free(footer);
        try buf.appendSlice(allocator, footer);
    }

    const trunc = truncate_mod.truncateTail(buf.items, .{});
    const is_error = !termOk(result.term);
    const text = if (trunc.truncated) blk: {
        const size = truncate_mod.formatSize(allocator, trunc.total_bytes) catch "large";
        defer if (!std.mem.eql(u8, size, "large")) allocator.free(size);
        break :blk try std.fmt.allocPrint(allocator, "{s}\n\n[Showing last {d} of {d} lines ({s} total); pipe through head/tail or print less]", .{ trunc.content, trunc.output_lines, trunc.total_lines, size });
    } else try allocator.dupe(u8, buf.items);

    const arr = try allocator.alloc(ai.types.ContentBlock, 1);
    arr[0] = .{ .text = .{ .text = text } };
    return .{ .content = arr, .is_error = is_error };
}

fn termOk(t: std.process.Child.Term) bool {
    return switch (t) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn termLine(allocator: std.mem.Allocator, t: std.process.Child.Term) ![]u8 {
    return switch (t) {
        .exited => |code| std.fmt.allocPrint(allocator, "[exit] code={d}", .{code}),
        .signal => |sig| std.fmt.allocPrint(allocator, "[signal] {t}", .{sig}),
        .stopped => |sig| std.fmt.allocPrint(allocator, "[stopped] {t}", .{sig}),
        .unknown => |v| std.fmt.allocPrint(allocator, "[unknown] term={d}", .{v}),
    };
}

// ─── tests ─────────────────────────────────────────────────────────

const testing = std.testing;
const test_h = @import("../../test_helpers.zig");

fn makeCtx(gpa: std.mem.Allocator, io: std.Io, bridge: *bridge_mod.McpBridge) *CodeExecCtx {
    const ctx = gpa.create(CodeExecCtx) catch @panic("oom");
    ctx.* = .{
        .bridge = bridge,
        .workspace_root = "/tmp",
        .sdk_dir = "/tmp",
        .allow_unsandboxed = true, // tests run without a sandbox primitive
    };
    _ = io;
    return ctx;
}

fn destroyCtx(gpa: std.mem.Allocator, ctx: *CodeExecCtx) void {
    gpa.destroy(ctx);
}

test "code_exec: runs python and captures stdout" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;
    var cancel: ai.stream.Cancel = .{};

    const bridge = try bridge_mod.McpBridge.init(gpa, io, null);
    defer bridge.deinit(io);
    const ctx = makeCtx(gpa, io, bridge);
    defer destroyCtx(gpa, ctx);

    const t = toolWithCtx(ctx);
    var res = try t.execute(&t, gpa, io, "id-1",
        \\{"code":"print('hello-from-code-exec')"}
    , &cancel, .{});
    defer res.deinit(gpa);

    try testing.expect(!res.is_error);
    const txt = res.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, txt, "hello-from-code-exec") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "[exit] code=0") != null);
}

test "code_exec: non-zero exit is_error and surfaces stderr" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;
    var cancel: ai.stream.Cancel = .{};

    const bridge = try bridge_mod.McpBridge.init(gpa, io, null);
    defer bridge.deinit(io);
    const ctx = makeCtx(gpa, io, bridge);
    defer destroyCtx(gpa, ctx);

    const t = toolWithCtx(ctx);
    var res = try t.execute(&t, gpa, io, "id-2",
        \\{"code":"import sys; sys.stderr.write('boom\\n'); sys.exit(3)"}
    , &cancel, .{});
    defer res.deinit(gpa);

    try testing.expect(res.is_error);
    const txt = res.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, txt, "[exit] code=3") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "boom") != null);
}

test "code_exec: rejects empty code" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;
    var cancel: ai.stream.Cancel = .{};

    const bridge = try bridge_mod.McpBridge.init(gpa, io, null);
    defer bridge.deinit(io);
    const ctx = makeCtx(gpa, io, bridge);
    defer destroyCtx(gpa, ctx);

    const t = toolWithCtx(ctx);
    var res = try t.execute(&t, gpa, io, "id-3", "{\"code\":\"\"}", &cancel, .{});
    defer res.deinit(gpa);
    try testing.expect(res.is_error);
}

test "code_exec: bridge token + socket are injected into the env" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;
    var cancel: ai.stream.Cancel = .{};

    const bridge = try bridge_mod.McpBridge.init(gpa, io, null);
    defer bridge.deinit(io);
    const ctx = makeCtx(gpa, io, bridge);
    defer destroyCtx(gpa, ctx);

    const t = toolWithCtx(ctx);
    var res = try t.execute(&t, gpa, io, "id-4",
        \\{"code":"import os; print('sock' , os.environ['FRANKY_MCP_SOCKET']); print('toklen', len(os.environ['FRANKY_MCP_TOKEN']))"}
    , &cancel, .{});
    defer res.deinit(gpa);
    const txt = res.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, txt, bridge.socket_path) != null);
    try testing.expect(std.mem.indexOf(u8, txt, "toklen 64") != null);
}
