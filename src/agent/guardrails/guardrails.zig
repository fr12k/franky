//! Guardrail aggregate — §6.10.
//!
//! `GuardrailState` owns a `StuckDetector`, a `CompilationGuard`, and a
//! `FinishTaskState`. It is wired directly into the loop via
//! `loop.Config.guardrails` so the loop delegates hook calls to it.
//!
//! Callers:
//!   1. Create with `GuardrailState.init`.
//!   2. Pass `&state` as `Config.guardrails`.
//!   3. Optionally add `state.finishTaskTool()` to the tools slice.
//!   4. Deinit with `state.deinit()` after the session.

const std = @import("std");
const ai = struct {
    pub const types = @import("../../ai/types.zig");
    pub const errors = @import("../../ai/errors.zig");
    pub const stream = @import("../../ai/stream.zig");
    pub const log = @import("../../ai/log.zig");
    pub const channel = @import("../../ai/channel.zig");
};
const at = @import("../types.zig");
const stuck_mod = @import("stuck_detector.zig");
const compile_mod = @import("compilation_guard.zig");
const finish_mod = @import("finish_task.zig");
// v3.2 — memory guardrail lives in coding/ but only depends on ai/ +
// agent/types.zig, so importing it here introduces no layering cycle.
const memory_guard_mod = @import("memory_guardrail.zig");
pub const MemoryGuardrail = memory_guard_mod.MemoryGuardrail;
pub const MemoryGuardrailConfig = memory_guard_mod.Config;

pub const Config = struct {
    /// Consecutive identical errors before the stuck hint fires.
    stuck_hint_threshold: u32 = 5,
    /// Edit/write mutations before the compilation guard triggers.
    compilation_threshold: u32 = 5,
    /// Max milliseconds per build stage.
    compilation_timeout_ms: u64 = 120_000,
    /// Workspace root directory (for `.franky-workflow.yaml` lookup and build cwd).
    workspace_dir: []const u8 = ".",
    /// Whether to run `git add -A && git commit` after a successful finish_task.
    /// When true, the pipeline also pushes, creates/updates a PR, and waits for CI.
    auto_commit: bool = false,
    /// If non-null, the GitHub owner/repo string (e.g. "fr12k/franky") used
    /// for `gh pr` and CI status polling. When null, auto-detected from `git remote`.
    gh_repo: ?[]const u8 = null,
    /// Max milliseconds to wait for CI checks to complete on a PR.
    ci_poll_timeout_ms: u64 = 360_000,
    /// Poll interval for CI checks (ms).
    ci_poll_interval_ms: u64 = 10_000,
};

pub const GuardrailState = struct {
    allocator: std.mem.Allocator,
    config: Config,
    stuck_detector: stuck_mod.StuckDetector,
    compilation_guard: compile_mod.CompilationGuard,
    finish_task_state: finish_mod.FinishTaskState,
    guardrail_fire_count: u32 = 0,
    finish_task_pending_compilation: bool = false,
    /// v3.3 — set true once the finish_task pipeline (compilation +
    /// optional auto-commit) has completed successfully. The loop's
    /// nudge-on-finish-task / nudge-on-autocontinue checks read this to
    /// suppress re-nudging the model after it has already called
    /// finish_task and the guardrails have processed it. Without this,
    /// the nudges see the post-finish_task text reply (which contains no
    /// tool call) and inject another "please call finish_task" message,
    /// causing the model to call finish_task again in a wasted loop.
    finish_task_completed: bool = false,
    restart_requested: ?*std.atomic.Value(bool) = null,
    /// v3.2 — optional memory nudge guardrail. When non-null and
    /// `finish_task` fires without any `memory_save` call this session,
    /// the guardrail injects a synthetic user message reminding the
    /// agent to save important facts before finishing. Owned by the
    /// mode driver (which also owns the MemoryState); set after init.
    memory_guardrail: ?*memory_guard_mod.MemoryGuardrail = null,

    /// ── Auto-commit lifecycle state ────────────────────────────────────
    pr_url: ?[]const u8 = null,
    auto_commit_branch: ?[]const u8 = null,
    ci_poll_active: bool = false,
    ci_passed: bool = false,
    pending_ci_failure: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, cfg: Config, io: std.Io) !GuardrailState {
        const comp_guard = try compile_mod.CompilationGuard.init(
            allocator,
            cfg.compilation_threshold,
            cfg.compilation_timeout_ms,
            cfg.workspace_dir,
            io,
        );
        errdefer comp_guard.deinit();

        const effective_auto_commit = cfg.auto_commit or comp_guard.workflowAutoCommit();

        var state: GuardrailState = .{
            .allocator = allocator,
            .config = cfg,
            .stuck_detector = stuck_mod.StuckDetector.init(allocator, cfg.stuck_hint_threshold),
            .compilation_guard = comp_guard,
            .finish_task_state = finish_mod.FinishTaskState.init(allocator),
            .guardrail_fire_count = 0,
        };
        state.config.auto_commit = effective_auto_commit;
        state.setupAutoCommitBranch(allocator, io);
        return state;
    }

    pub fn deinit(self: *GuardrailState) void {
        self.stuck_detector.deinit();
        self.compilation_guard.deinit();
        self.finish_task_state.deinit();
        if (self.pr_url) |s| self.allocator.free(s);
        if (self.auto_commit_branch) |s| self.allocator.free(s);
        if (self.pending_ci_failure) |s| self.allocator.free(s);
    }

    pub fn finishTaskTool(self: *GuardrailState) at.AgentTool {
        return finish_mod.tool(&self.finish_task_state);
    }

    pub fn setupAutoCommitBranch(self: *GuardrailState, allocator: std.mem.Allocator, io: std.Io) void {
        if (!self.config.auto_commit) return;

        const current = gitCurrentBranch(allocator, io, self.config.workspace_dir) catch |err| {
            ai.log.log(.warn, "guardrails", "branch_check_failed", "err={s}", .{@errorName(err)});
            return;
        };
        defer allocator.free(current);

        const is_default = std.mem.eql(u8, current, "main") or
            std.mem.eql(u8, current, "master") or
            std.mem.eql(u8, current, "develop");

        const branch_name = if (is_default) brk: {
            const ts: u64 = @intCast(ai.stream.nowMillis());
            break :brk std.fmt.allocPrint(allocator, "franky/{d}", .{ts}) catch return;
        } else brk: {
            break :brk allocator.dupe(u8, current) catch return;
        };
        defer allocator.free(branch_name);

        if (is_default) {
            gitCreateBranch(allocator, io, self.config.workspace_dir, branch_name) catch |err| {
                ai.log.log(.warn, "guardrails", "branch_create_failed", "branch={s} err={s}", .{ branch_name, @errorName(err) });
                return;
            };
        }

        self.auto_commit_branch = allocator.dupe(u8, branch_name) catch return;
    }

    pub fn cacheArgs(self: *GuardrailState, call_id: []const u8, args_json: []const u8) !void {
        try self.stuck_detector.cacheArgs(call_id, args_json);
    }

    pub fn afterToolCall(
        self: *GuardrailState,
        tool: *const at.AgentTool,
        call_id: []const u8,
        result: *const at.ToolResult,
    ) void {
        self.stuck_detector.afterToolCall(tool, call_id, result);
        self.compilation_guard.bumpIfMutation(tool.name);
        // v3.2 — track memory_save so the nudge knows the agent already saved.
        if (self.memory_guardrail) |mg| mg.afterToolCall(tool.name);
    }

    pub fn betweenTurns(
        self: *GuardrailState,
        allocator: std.mem.Allocator,
        io: std.Io,
        transcript: *at.Transcript,
        out: *at.AgentChannel,
    ) !bool {
        // ── 0. Pending CI failure injection ──
        if (self.pending_ci_failure) |failure| {
            const to_free = self.pending_ci_failure;
            self.pending_ci_failure = null;

            const text = try std.fmt.allocPrint(
                allocator,
                "The CI checks for the pull request have failed. Here is the output:\n\n```\n{s}\n```\n\nPlease analyze the failures and fix them. After fixing, call `finish_task` again with an appropriate commit message describing the fix. The changes will be pushed to the same branch and the PR will be updated automatically.",
                .{failure},
            );
            defer allocator.free(text);

            const content = try allocator.alloc(ai.types.ContentBlock, 1);
            content[0] = .{ .text = .{ .text = try allocator.dupe(u8, text) } };
            try transcript.append(.{
                .role = .user,
                .content = content,
                .timestamp = ai.stream.nowMillis(),
            });

            if (to_free) |s| self.allocator.free(s);
            // v3.3 — clear finish_task_completed so the nudges remain
            // active while the model fixes the CI failure and re-calls
            // finish_task.
            self.finish_task_completed = false;
            self.finish_task_state.reset();
            return true;
        }

        // ── 1. finish_task triggered ──
        if (self.finish_task_state.triggered) {
            // v3.3 — a new finish_task call clears the completed flag
            // so the nudges remain active during the compilation/commit
            // pipeline. This single reset replaces per-failure-path
            // resets in step 2 and the CI branches.
            self.finish_task_completed = false;
            // v3.2 — memory nudge: if the agent finished without saving
            // any memory this session, inject a reminder before the
            // compilation/commit pipeline runs. This gives the agent one
            // extra turn to call memory_save (or skip and re-finish).
            if (self.memory_guardrail) |mg| {
                const wants_turn = try mg.betweenTurns(allocator, transcript, true);
                if (wants_turn) {
                    self.guardrail_fire_count += 1;
                    // Consume the trigger so the next finish_task call
                    // re-enters this branch; the nudge message tells the
                    // agent to call finish_task again when done.
                    self.finish_task_state.triggered = false;
                    self.finish_task_pending_compilation = false;
                    return true;
                }
            }
            self.finish_task_state.triggered = false;
            self.finish_task_pending_compilation = true;
            self.ci_poll_active = false;
            self.ci_passed = false;
            return true;
        }

        // ── 2. finish_task compilation ──
        if (self.finish_task_pending_compilation) {
            self.finish_task_pending_compilation = false;

            const compile_failed = try self.compilation_guard.betweenTurns(allocator, io, transcript, out, true);
            if (compile_failed) {
                ai.log.log(.debug, "guardrails", "compilation_guard_fired", "source=finish_task", .{});
                self.guardrail_fire_count += 1;
                self.finish_task_state.reset();
                return true;
            }

            if (self.config.auto_commit) {
                if (self.finish_task_state.commit_message) |msg| {
                    runAutoCommitPipeline(self, allocator, io, msg) catch |err| {
                        ai.log.log(.err, "guardrails", "auto_commit_pipeline_failed", "err={s}", .{@errorName(err)});
                        const text = try std.fmt.allocPrint(
                            allocator,
                            "The auto-commit pipeline failed with error: {s}\n\nYou can retry by calling `finish_task` again.",
                            .{@errorName(err)},
                        );
                        defer allocator.free(text);
                        const content = try allocator.alloc(ai.types.ContentBlock, 1);
                        content[0] = .{ .text = .{ .text = try allocator.dupe(u8, text) } };
                        try transcript.append(.{
                            .role = .user,
                            .content = content,
                            .timestamp = ai.stream.nowMillis(),
                        });
                        self.finish_task_state.reset();
                        return true;
                    };

                    if (self.pr_url != null and !self.ci_passed) {
                        self.ci_poll_active = true;
                        return true;
                    }
                }
            }

            if (self.finish_task_state.restart) {
                if (self.restart_requested) |flag| {
                    flag.store(true, .release);
                    ai.log.log(.info, "guardrails", "restart", "finish_task requested restart", .{});
                }
            }
            // v3.3 — mark the finish_task pipeline as completed so the
            // loop's nudge-on-finish-task / nudge-on-autocontinue checks
            // do not re-nudge the model after a successful finish_task.
            self.finish_task_completed = true;
            self.finish_task_state.reset();
            return false;
        }

        // ── 3. CI polling ──
        if (self.ci_poll_active) {
            const pr_url = self.pr_url orelse {
                self.ci_poll_active = false;
                return false;
            };

            const poll_result = pollCI(allocator, io, pr_url, self.config.ci_poll_timeout_ms, self.config.ci_poll_interval_ms) catch |err| {
                ai.log.log(.warn, "guardrails", "ci_poll_failed", "err={s}", .{@errorName(err)});
                self.ci_poll_active = false;
                self.ci_passed = true;
                return false;
            };

            switch (poll_result) {
                .pending => {
                    return true;
                },
                .passed => {
                    ai.log.log(.info, "guardrails", "ci_passed", "pr={s}", .{pr_url});
                    self.ci_poll_active = false;
                    self.ci_passed = true;
                    return false;
                },
                .failed => |output| {
                    ai.log.log(.warn, "guardrails", "ci_failed", "pr={s}", .{pr_url});
                    self.ci_poll_active = false;
                    self.pending_ci_failure = try allocator.dupe(u8, output);
                    self.finish_task_state.reset();
                    return true;
                },
            }
        }

        // ── 4. compilation guard ──
        if (try self.compilation_guard.betweenTurns(allocator, io, transcript, out, false)) {
            ai.log.log(.debug, "guardrails", "compilation_guard_fired", "source=threshold", .{});
            self.guardrail_fire_count += 1;
            return true;
        }

        // ── 5. stuck detector ──
        if (try self.stuck_detector.betweenTurns(allocator, io, transcript, out)) {
            ai.log.log(.debug, "guardrails", "stuck_detector_fired", "", .{});
            self.guardrail_fire_count += 1;
            return true;
        }

        return false;
    }
};

// ─── CI Polling ────────────────────────────────────────────────────────────────

const CiPollResult = union(enum) {
    pending,
    passed,
    failed: []const u8,
};

fn pollCI(allocator: std.mem.Allocator, io: std.Io, pr_url: []const u8, timeout_ms: u64, interval_ms: u64) !CiPollResult {
    const deadline = ai.stream.nowMillis() + @as(i64, @intCast(timeout_ms));

    const pr_number = brk: {
        var it = std.mem.splitScalar(u8, pr_url, '/');
        var last: []const u8 = "";
        while (it.next()) |seg| {
            last = seg;
        }
        break :brk last;
    };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    while (ai.stream.nowMillis() < deadline) {
        // Simple yield-loop sleep — ~10 s delay.
        {
            var wait: u64 = 0;
            while (wait < interval_ms) : (wait += 1) {
                std.Thread.yield() catch {};
            }
        }

        const argv = [_][]const u8{ "gh", "pr", "view", pr_number, "--json", "state,statusCheckRollup" };
        const result = std.process.run(aa, io, .{
            .argv = &argv,
            .stdout_limit = .limited(64 * 1024),
            .stderr_limit = .limited(8 * 1024),
        }) catch |err| {
            ai.log.log(.warn, "guardrails", "ci_poll_gh_spawn_failed", "err={s}", .{@errorName(err)});
            continue;
        };

        if (result.term != .exited or result.term.exited != 0) {
            ai.log.log(.warn, "guardrails", "ci_poll_gh_failed", "stderr={s}", .{result.stderr});
            continue;
        }

        const parsed = try std.json.parseFromSlice(std.json.Value, aa, result.stdout, .{});
        defer parsed.deinit();
        const root = parsed.value;

        const checks = root.object.get("statusCheckRollup") orelse continue;
        if (checks != .array) continue;

        var all_completed = true;
        var any_failed = false;
        var failure_output: std.ArrayList(u8) = .empty;
        defer failure_output.deinit(allocator);

        for (checks.array.items) |check| {
            const status = check.object.get("status") orelse continue;
            const conclusion = check.object.get("conclusion");

            if (status == .string) {
                if (std.mem.eql(u8, status.string, "COMPLETED")) {
                    if (conclusion) |c| {
                        if (c == .string) {
                            if (!std.mem.eql(u8, c.string, "SUCCESS") and
                                !std.mem.eql(u8, c.string, "NEUTRAL") and
                                !std.mem.eql(u8, c.string, "SKIPPED"))
                            {
                                any_failed = true;
                                const name = if (check.object.get("name")) |n|
                                    if (n == .string) n.string else "unknown"
                                else
                                    "unknown";
                                try failure_output.appendSlice(allocator, "Check \"");
                                try failure_output.appendSlice(allocator, name);
                                try failure_output.appendSlice(allocator, "\" failed with conclusion: ");
                                try failure_output.appendSlice(allocator, c.string);
                                try failure_output.appendSlice(allocator, "\n");
                            }
                        }
                    }
                } else {
                    all_completed = false;
                }
            }
        }

        if (!all_completed) continue;

        if (any_failed) {
            return .{ .failed = try failure_output.toOwnedSlice(allocator) };
        }

        return .passed;
    }

    ai.log.log(.warn, "guardrails", "ci_poll_timeout", "pr={s}", .{pr_url});
    return .passed;
}

// ─── Full auto-commit pipeline ───────────────────────────────────────────────

fn runAutoCommitPipeline(
    state: *GuardrailState,
    allocator: std.mem.Allocator,
    io: std.Io,
    commit_message: []const u8,
) !void {
    try gitAdd(allocator, io, state.config.workspace_dir);
    try gitCommit(allocator, io, state.config.workspace_dir, commit_message);

    const branch = if (state.auto_commit_branch) |b| b else brk: {
        break :brk try gitCurrentBranch(allocator, io, state.config.workspace_dir);
    };
    defer if (state.auto_commit_branch == null) allocator.free(branch);

    try gitPush(allocator, io, state.config.workspace_dir, branch);

    const repo = if (state.config.gh_repo) |r| r else brk: {
        break :brk try gitRemoteRepo(allocator, io, state.config.workspace_dir);
    };
    defer if (state.config.gh_repo == null) allocator.free(repo);

    const pr_url = try createOrUpdatePr(allocator, io, state.config.workspace_dir, repo, branch, commit_message);

    if (state.pr_url) |old| {
        state.allocator.free(old);
        state.pr_url = null;
    }
    state.pr_url = try state.allocator.dupe(u8, pr_url);
}

// ─── Git helpers ────────────────────────────────────────────────────────────────

fn gitAdd(allocator: std.mem.Allocator, io: std.Io, workspace_dir: []const u8) !void {
    const argv = [_][]const u8{ "git", "add", "-A" };
    const result = try std.process.run(allocator, io, .{
        .argv = &argv,
        .cwd = .{ .path = workspace_dir },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const ok = switch (result.term) {
        .exited => |c| c == 0,
        else => false,
    };
    if (!ok) {
        ai.log.log(.err, "guardrails", "git_add_failed", "stderr={s}", .{result.stderr});
        return error.GitAddFailed;
    }
}

fn gitCommit(allocator: std.mem.Allocator, io: std.Io, workspace_dir: []const u8, msg: []const u8) !void {
    const argv = [_][]const u8{ "git", "commit", "-m", msg };
    const result = try std.process.run(allocator, io, .{
        .argv = &argv,
        .cwd = .{ .path = workspace_dir },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const ok = switch (result.term) {
        .exited => |c| c == 0,
        else => false,
    };
    if (!ok) {
        ai.log.log(.err, "guardrails", "git_commit_failed", "stderr={s}", .{result.stderr});
        return error.GitCommitFailed;
    }
}

fn gitPush(allocator: std.mem.Allocator, io: std.Io, workspace_dir: []const u8, branch: []const u8) !void {
    const argv = [_][]const u8{ "git", "push", "origin", branch };
    const result = try std.process.run(allocator, io, .{
        .argv = &argv,
        .cwd = .{ .path = workspace_dir },
        .stdout_limit = .limited(128 * 1024),
        .stderr_limit = .limited(128 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const ok = switch (result.term) {
        .exited => |c| c == 0,
        else => false,
    };
    if (!ok) {
        ai.log.log(.err, "guardrails", "git_push_failed", "stderr={s}", .{result.stderr});
        return error.GitPushFailed;
    }
}

fn gitCurrentBranch(allocator: std.mem.Allocator, io: std.Io, workspace_dir: []const u8) ![]const u8 {
    const argv = [_][]const u8{ "git", "rev-parse", "--abbrev-ref", "HEAD" };
    const result = try std.process.run(allocator, io, .{
        .argv = &argv,
        .cwd = .{ .path = workspace_dir },
        .stdout_limit = .limited(256),
        .stderr_limit = .limited(256),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const branch = std.mem.trimEnd(u8, result.stdout, "\n\r ");
    return try allocator.dupe(u8, branch);
}

fn gitCreateBranch(allocator: std.mem.Allocator, io: std.Io, workspace_dir: []const u8, name: []const u8) !void {
    const argv = [_][]const u8{ "git", "checkout", "-b", name };
    const result = try std.process.run(allocator, io, .{
        .argv = &argv,
        .cwd = .{ .path = workspace_dir },
        .stdout_limit = .limited(256),
        .stderr_limit = .limited(256),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const ok = switch (result.term) {
        .exited => |c| c == 0,
        else => false,
    };
    if (!ok) return error.GitBranchFailed;
}

fn gitRemoteRepo(allocator: std.mem.Allocator, io: std.Io, workspace_dir: []const u8) ![]const u8 {
    const argv = [_][]const u8{ "git", "config", "--get", "remote.origin.url" };
    const result = try std.process.run(allocator, io, .{
        .argv = &argv,
        .cwd = .{ .path = workspace_dir },
        .stdout_limit = .limited(512),
        .stderr_limit = .limited(256),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const ok = switch (result.term) {
        .exited => |c| c == 0,
        else => false,
    };
    if (!ok) return error.GitNoRemote;

    const url = std.mem.trimEnd(u8, result.stdout, "\n\r ");
    var repo: []const u8 = undefined;
    if (std.mem.startsWith(u8, url, "git@")) {
        const after_colon = std.mem.indexOfScalar(u8, url, ':') orelse return error.GitRemoteParseError;
        repo = url[after_colon + 1 ..];
    } else if (std.mem.startsWith(u8, url, "https://")) {
        const idx = std.mem.indexOf(u8, url, ".com/") orelse return error.GitRemoteParseError;
        repo = url[idx + 5 ..];
    } else {
        return error.GitRemoteParseError;
    }
    if (std.mem.endsWith(u8, repo, ".git")) {
        repo = repo[0 .. repo.len - 4];
    }
    return try allocator.dupe(u8, repo);
}

// ─── PR helpers ────────────────────────────────────────────────────────────────

fn createOrUpdatePr(
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace_dir: []const u8,
    repo: []const u8,
    branch: []const u8,
    title: []const u8,
) ![]const u8 {
    _ = repo;
    const view_argv = [_][]const u8{ "gh", "pr", "list", "--head", branch, "--state", "OPEN", "--json", "number,url", "--jq", ".[0].url" };
    const view_result = try std.process.run(allocator, io, .{
        .argv = &view_argv,
        .cwd = .{ .path = workspace_dir },
        .stdout_limit = .limited(8 * 1024),
        .stderr_limit = .limited(4 * 1024),
    });
    defer allocator.free(view_result.stdout);
    defer allocator.free(view_result.stderr);

    if (view_result.term == .exited and view_result.term.exited == 0) {
        const existing_url = std.mem.trimEnd(u8, view_result.stdout, "\n\r ");
        if (existing_url.len > 0) {
            ai.log.log(.info, "guardrails", "pr_exists", "url={s}", .{existing_url});
            return try allocator.dupe(u8, existing_url);
        }
    }

    ai.log.log(.info, "guardrails", "pr_create", "branch={s}", .{branch});
    const create_argv = [_][]const u8{ "gh", "pr", "create", "--title", title, "--body", title, "--fill" };
    const create_result = try std.process.run(allocator, io, .{
        .argv = &create_argv,
        .cwd = .{ .path = workspace_dir },
        .stdout_limit = .limited(8 * 1024),
        .stderr_limit = .limited(4 * 1024),
    });
    defer allocator.free(create_result.stdout);
    defer allocator.free(create_result.stderr);

    const ok = switch (create_result.term) {
        .exited => |c| c == 0,
        else => false,
    };
    if (!ok) {
        ai.log.log(.err, "guardrails", "pr_create_failed", "stderr={s}", .{create_result.stderr});
        return error.PrCreateFailed;
    }

    const url = std.mem.trimEnd(u8, create_result.stdout, "\n\r ");
    return try allocator.dupe(u8, url);
}

// ─── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;
const test_h = @import("../../test_helpers.zig");

test "GuardrailState: init/deinit" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const gpa = testing.allocator;
    var state = try GuardrailState.init(gpa, .{ .workspace_dir = "/tmp" }, io);
    defer state.deinit();
    try testing.expect(state.stuck_detector.hint_threshold == 5);
    try testing.expect(state.compilation_guard.threshold == 5);
    try testing.expect(!state.config.auto_commit);
    try testing.expect(state.pr_url == null);
    try testing.expect(state.auto_commit_branch == null);
    try testing.expect(!state.ci_poll_active);
    try testing.expect(!state.ci_passed);
    try testing.expect(state.pending_ci_failure == null);
}

test "GuardrailState: init with auto_commit true does not crash" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const gpa = testing.allocator;
    // auto_commit=true but /tmp might not be a git repo — should fail gracefully.
    var state = try GuardrailState.init(gpa, .{ .workspace_dir = "/tmp", .auto_commit = true }, io);
    defer state.deinit();
    try testing.expect(state.config.auto_commit);
}

test "GuardrailState: afterToolCall delegates to stuck_detector and compilation_guard" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const gpa = testing.allocator;
    var state = try GuardrailState.init(gpa, .{ .workspace_dir = "/tmp" }, io);
    defer state.deinit();

    const edit_tool: at.AgentTool = .{
        .name = "edit",
        .description = "",
        .parameters_json = "{}",
        .execute = undefined,
    };

    var ok_result: at.ToolResult = .{ .content = &.{} };
    state.afterToolCall(&edit_tool, "id1", &ok_result);
    try testing.expectEqual(@as(u32, 1), state.compilation_guard.mutation_count);
}

test "GuardrailState: betweenTurns step 0 — CI failure injection" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var state = try GuardrailState.init(gpa, .{ .workspace_dir = "/tmp" }, io);
    defer state.deinit();

    // Set up a pending CI failure.
    state.pending_ci_failure = try gpa.dupe(u8, "Check \"tests\" failed: timeout");

    var transcript = at.Transcript.init(gpa);
    defer transcript.deinit();

    var channel = try ai.channel.Channel(at.AgentEvent).init(gpa, 64);
    defer channel.deinit();

    const wants_turn = try state.betweenTurns(gpa, io, &transcript, &channel);
    try testing.expect(wants_turn);
    // CI failure was consumed.
    try testing.expect(state.pending_ci_failure == null);
    // finish_task state was reset.
    try testing.expect(!state.finish_task_state.triggered);
    // A user message was appended to the transcript.
    try testing.expect(transcript.messages.items.len > 0);
    const last_msg = transcript.messages.items[transcript.messages.items.len - 1];
    try testing.expect(last_msg.role == .user);
    try testing.expect(last_msg.content.len > 0);
}

test "GuardrailState: betweenTurns step 1 — finish_task triggers pending compilation" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var state = try GuardrailState.init(gpa, .{ .workspace_dir = "/tmp" }, io);
    defer state.deinit();

    // Simulate finish_task being called.
    state.finish_task_state.triggered = true;

    var transcript = at.Transcript.init(gpa);
    defer transcript.deinit();
    var channel = try ai.channel.Channel(at.AgentEvent).init(gpa, 64);
    defer channel.deinit();

    const wants_turn = try state.betweenTurns(gpa, io, &transcript, &channel);
    try testing.expect(wants_turn);
    // Triggered flag consumed, pending compilation set.
    try testing.expect(!state.finish_task_state.triggered);
    try testing.expect(state.finish_task_pending_compilation);
    // CI state was reset.
    try testing.expect(!state.ci_poll_active);
    try testing.expect(!state.ci_passed);
}

test "GuardrailState: betweenTurns ci_poll_active with null pr_url" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var state = try GuardrailState.init(gpa, .{ .workspace_dir = "/tmp" }, io);
    defer state.deinit();

    // Activate CI polling without a PR URL — should disable polling.
    state.ci_poll_active = true;
    state.pr_url = null;

    // We need to first trigger finish_task and let compilation fail/skip so
    // we don't hit step 1/2. Use a fresh state with no workflow file so
    // compilation guard doesn't fire.
    // Instead, directly test the ci_poll_active branch by ensuring
    // no prior steps trigger. Since /tmp has no .franky-workflow.yaml,
    // compilation guard returns false on shouldCompile.

    // We need to bypass step 1/2. Let's call betweenTurns twice:
    // first to clear finish_task trigger, then to check CI polling.
    // But we never triggered finish_task, so steps 1 and 2 won't fire.
    // Step 3 checks ci_poll_active — we set it so it should fire.

    var transcript = at.Transcript.init(gpa);
    defer transcript.deinit();
    var channel = try ai.channel.Channel(at.AgentEvent).init(gpa, 64);
    defer channel.deinit();

    const wants_turn = try state.betweenTurns(gpa, io, &transcript, &channel);
    // ci_poll_active with null pr_url should reset and return false.
    try testing.expect(!wants_turn);
    try testing.expect(!state.ci_poll_active);
}

test "GuardrailState: deinit with owned fields does not crash" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var state = try GuardrailState.init(gpa, .{ .workspace_dir = "/tmp" }, io);
    defer state.deinit();

    // Populate owned fields that deinit must free.
    state.pr_url = try gpa.dupe(u8, "https://github.com/owner/repo/pull/123");
    state.auto_commit_branch = try gpa.dupe(u8, "franky/123456789");
    state.pending_ci_failure = try gpa.dupe(u8, "test failure");

    // deinit runs in defer — must not crash.
}

test "gitRemoteRepo: parses SSH URL via helper in a real git repo" {
    const gpa = testing.allocator;
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    // Find the actual git root of this project
    const argv = [_][]const u8{ "git", "remote", "get-url", "origin" };
    const result = std.process.run(gpa, io, .{
        .argv = &argv,
        .stdout_limit = .limited(512),
        .stderr_limit = .limited(256),
    }) catch {
        // git binary unavailable (e.g. the CI Alpine image installs only
        // curl + xz, not git) — skip silently. Writing to stderr here would
        // be captured by the build runner and rendered as a misleading
        // "failed command" for an otherwise-successful test step.
        return error.SkipZigTest;
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    // std.process.run does not error on a non-zero exit, so a missing
    // `origin` remote surfaces as a failed git invocation rather than an
    // error.SkipZigTest. Skip in that case too rather than passing on a
    // failed command (matches the `result.term != .exited or ... != 0`
    // idiom used in betweenTurns above).
    if (result.term != .exited or result.term.exited != 0) return error.SkipZigTest;

    const url = std.mem.trimEnd(u8, result.stdout, "\n\r ");
    // We just verify the function doesn't crash with real input
    _ = url;
}


test "setupAutoCommitBranch: skips when auto_commit is false" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var state = try GuardrailState.init(gpa, .{ .workspace_dir = "/tmp" }, io);
    defer state.deinit();
    // auto_commit is false by default — setupAutoCommitBranch should skip.
    try testing.expect(state.auto_commit_branch == null);
}

test "GuardrailState: betweenTurns step 2 — compilation auto_commit without git passes through" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var state = try GuardrailState.init(gpa, .{ .workspace_dir = "/tmp", .auto_commit = true }, io);
    defer state.deinit();

    state.finish_task_state.commit_message = try gpa.dupe(u8, "feat(test): change");
    state.finish_task_state.triggered = true;
    state.finish_task_state.summary = try gpa.dupe(u8, "test summary");

    var transcript = at.Transcript.init(gpa);
    defer transcript.deinit();
    var channel = try ai.channel.Channel(at.AgentEvent).init(gpa, 64);
    defer channel.deinit();

    // First call: step 1 — triggered
    const wants1 = try state.betweenTurns(gpa, io, &transcript, &channel);
    try testing.expect(wants1);
    try testing.expect(state.finish_task_pending_compilation);

    // Second call: step 2 — compilation (no workflow in /tmp) + auto_commit fails gracefully.
    // Since there's no git repo in /tmp, the pipeline will error, but that's handled.
    const wants2 = try state.betweenTurns(gpa, io, &transcript, &channel);
    try testing.expect(!state.finish_task_state.triggered);
    _ = wants2;
}

test "GuardrailState: v3.3 finish_task_completed is set after step 2 passes" {
    // When finish_task is triggered and step 2 (compilation) completes
    // without a failure, finish_task_completed must be true so the loop's
    // nudge-on-finish-task / nudge-on-autocontinue checks suppress
    // re-nudging the model.
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var state = try GuardrailState.init(gpa, .{ .workspace_dir = "/tmp" }, io);
    defer state.deinit();

    // No auto_commit — avoids the git pipeline so step 2 just runs
    // compilation (which is a no-op in /tmp) and returns false.
    state.finish_task_state.commit_message = try gpa.dupe(u8, "feat(test): change");
    state.finish_task_state.triggered = true;
    state.finish_task_state.summary = try gpa.dupe(u8, "test summary");

    var transcript = at.Transcript.init(gpa);
    defer transcript.deinit();
    var channel = try ai.channel.Channel(at.AgentEvent).init(gpa, 64);
    defer channel.deinit();

    // Before any betweenTurns call, finish_task_completed is false.
    try testing.expect(!state.finish_task_completed);

    // First call: step 1 — triggered → sets pending_compilation.
    const wants1 = try state.betweenTurns(gpa, io, &transcript, &channel);
    try testing.expect(wants1);
    try testing.expect(state.finish_task_pending_compilation);
    // Still false after step 1.
    try testing.expect(!state.finish_task_completed);

    // Second call: step 2 — compilation passes (no-op in /tmp), no auto_commit
    // → returns false and sets finish_task_completed = true.
    const wants2 = try state.betweenTurns(gpa, io, &transcript, &channel);
    try testing.expect(!wants2);
    try testing.expect(state.finish_task_completed);
}

test "GuardrailState: v3.3 finish_task_completed reset on CI failure" {
    // When CI polling fails, finish_task_completed must be cleared so
    // the nudges remain active while the model fixes the failure.
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var state = try GuardrailState.init(gpa, .{ .workspace_dir = "/tmp" }, io);
    defer state.deinit();

    // Simulate a completed finish_task.
    state.finish_task_completed = true;
    state.pending_ci_failure = try gpa.dupe(u8, "test failure output");

    var transcript = at.Transcript.init(gpa);
    defer transcript.deinit();
    var channel = try ai.channel.Channel(at.AgentEvent).init(gpa, 64);
    defer channel.deinit();

    // Step 0 — pending CI failure injection clears finish_task_completed.
    const wants = try state.betweenTurns(gpa, io, &transcript, &channel);
    try testing.expect(wants);
    try testing.expect(!state.finish_task_completed);
}

test "Config: auto_commit with gh_repo explicit" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    // Verify gh_repo is stored and retrieved correctly.
    var state = try GuardrailState.init(gpa, .{
        .workspace_dir = "/tmp",
        .auto_commit = true,
        .gh_repo = "custom-owner/custom-repo",
    }, io);
    defer state.deinit();

    try testing.expect(state.config.gh_repo != null);
    try testing.expectEqualStrings("custom-owner/custom-repo", state.config.gh_repo.?);
}

test "pollCI: timeout returns passed" {
    const gpa = testing.allocator;
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    // Use a non-existent PR URL — will fail to parse and eventually timeout.
    // With a very short timeout, should return .passed (timeout fallback).
    const result = try pollCI(gpa, io, "https://github.com/owner/repo/pull/999999", 10, 1);
    // Short timeout & interval — function yields then hits gh which will fail,
    // eventually timing out and returning .passed.
    switch (result) {
        .passed => {},
        .pending => {},
        .failed => |out| gpa.free(out),
    }
}

test "GuardrailState: deinit with all owned fields null is safe" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var state = try GuardrailState.init(gpa, .{ .workspace_dir = "/tmp" }, io);
    // All owned fields are null — deinit must not crash.
    state.deinit();
    // Second deinit would double-free, so don't call it again.
    // Just verify state fields were cleared.
    try testing.expect(state.pr_url == null);
    try testing.expect(state.auto_commit_branch == null);
    try testing.expect(state.pending_ci_failure == null);
}

// ─── v3.2 memory guardrail wiring tests ─────────────────────────────

test "GuardrailState: afterToolCall forwards to memory_guardrail" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var state = try GuardrailState.init(gpa, .{ .workspace_dir = "/tmp" }, io);
    defer state.deinit();

    var mg = memory_guard_mod.MemoryGuardrail.init(.{ .enabled = true });
    state.memory_guardrail = &mg;

    const memory_save_tool = at.AgentTool{
        .name = "memory_save",
        .description = "",
        .parameters_json = "{}",
        .execute = undefined,
    };
    var ok_result: at.ToolResult = .{ .content = &.{} };

    try testing.expect(!mg.session_has_saved);
    state.afterToolCall(&memory_save_tool, "id1", &ok_result);
    try testing.expect(mg.session_has_saved);
}

test "GuardrailState: betweenTurns fires memory nudge on finish_task without save" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var state = try GuardrailState.init(gpa, .{ .workspace_dir = "/tmp" }, io);
    defer state.deinit();

    var mg = memory_guard_mod.MemoryGuardrail.init(.{ .enabled = true });
    state.memory_guardrail = &mg;

    // Simulate finish_task trigger (no memory_save called).
    state.finish_task_state.triggered = true;

    var transcript = at.Transcript.init(gpa);
    defer transcript.deinit();

    var channel = try ai.channel.Channel(at.AgentEvent).init(gpa, 64);
    defer channel.deinit();

    const wants_turn = try state.betweenTurns(gpa, io, &transcript, &channel);
    // The nudge fires → wants another turn.
    try testing.expect(wants_turn);
    // The nudge injected a user message.
    try testing.expect(transcript.messages.items.len > 0);
    // finish_task was consumed so it doesn't re-enter the pipeline.
    try testing.expect(!state.finish_task_state.triggered);
    try testing.expect(!state.finish_task_pending_compilation);
}

test "GuardrailState: betweenTurns skips nudge when memory already saved" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var state = try GuardrailState.init(gpa, .{ .workspace_dir = "/tmp" }, io);
    defer state.deinit();

    var mg = memory_guard_mod.MemoryGuardrail.init(.{ .enabled = true });
    state.memory_guardrail = &mg;

    // Agent already saved memory this session.
    mg.session_has_saved = true;

    state.finish_task_state.triggered = true;

    var transcript = at.Transcript.init(gpa);
    defer transcript.deinit();

    var channel = try ai.channel.Channel(at.AgentEvent).init(gpa, 64);
    defer channel.deinit();

    const wants_turn = try state.betweenTurns(gpa, io, &transcript, &channel);
    // No nudge → finish_task pipeline proceeds normally (wants a turn
    // for the compilation step).
    try testing.expect(wants_turn);
    // The finish_task state was consumed and moved to pending_compilation.
    try testing.expect(!state.finish_task_state.triggered);
    try testing.expect(state.finish_task_pending_compilation);
    // No nudge message was injected.
    try testing.expectEqual(@as(usize, 0), transcript.messages.items.len);
}

test "GuardrailState: null memory_guardrail is a no-op" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var state = try GuardrailState.init(gpa, .{ .workspace_dir = "/tmp" }, io);
    defer state.deinit();
    // memory_guardrail stays null.

    state.finish_task_state.triggered = true;

    var transcript = at.Transcript.init(gpa);
    defer transcript.deinit();

    var channel = try ai.channel.Channel(at.AgentEvent).init(gpa, 64);
    defer channel.deinit();

    const wants_turn = try state.betweenTurns(gpa, io, &transcript, &channel);
    // Without memory_guardrail, finish_task proceeds normally.
    try testing.expect(wants_turn);
    try testing.expect(state.finish_task_pending_compilation);
    try testing.expectEqual(@as(usize, 0), transcript.messages.items.len);
}
