//! Interactive mode — §5.5 of the spec.
//!
//! A raw-terminal REPL: paint the scrollback-style transcript above,
//! an editor line at the bottom, and stream assistant text into the
//! transcript as the agent loop produces events. Keybindings come
//! from `tui.keybindings` (emacs preset default), terminal I/O from
//! `coding.terminal` (raw mode + alt-screen), and the agent worker
//! reuses the same `runPrint`-style plumbing so provider selection,
//! session persistence, and logging stay identical to print mode.
//!
//! Scope (v0.11.3):
//!   * Single-line editor (multi-line composition is a future follow-up;
//!     Shift-Enter / `\` continuation keys are already recognized by
//!     the editor primitive — we just don't render multi-row input
//!     here yet).
//!   * Transcript scrollback is append-only; no history nav yet.
//!   * One in-flight agent turn at a time — the UI switches to a
//!     "thinking…" status line while the worker runs and disables
//!     submission until the current turn ends.
//!   * Ctrl-C during a turn fires `cancel`; the worker joins and the
//!     prompt comes back for another try. Ctrl-C at an empty prompt
//!     exits.
//!
//! Non-TTY fallback: if stdout isn't a terminal (piped run,
//! `franky --mode interactive | cat`), we print a clear error to
//! stderr and exit 2 instead of scribbling escape codes into the
//! captured output.

const std = @import("std");
const builtin = @import("builtin");
const franky = @import("../../root.zig");
const ai = franky.ai;
const agent = franky.agent;
const tui = franky.tui;
const at = agent.types;
const tools_mod = franky.coding.tools;
const cli_mod = franky.coding.cli;
const slash_mod = franky.coding.slash;
const diagnostics_mod = franky.coding.diagnostics;
const improvement_mod = franky.coding.improvement;
const skills_mod = franky.coding.skills;
const templates_mod = franky.coding.templates;
const extensions_mod = franky.coding.extensions;
const ext_catalog = franky.coding.extensions_builtin.catalog;
const compaction_mod = franky.coding.compaction;
const compression_mod = franky.coding.compression;
const branching_mod = franky.coding.branching;
const role_mod = franky.coding.role;
const permissions_mod = franky.coding.permissions;
const models_mod = franky.coding.models;
const restart_mod = franky.coding.restart;
const term_mod = @import("../terminal.zig");
const print_mode = @import("print.zig");
const review_mod = @import("../review.zig");

const RunError = error{InteractiveNotSupported} || std.mem.Allocator.Error;

/// Entry point, called by `print.zig` when `--mode interactive` is
/// selected. We mirror print's signature so the dispatch is a single
/// one-liner.
pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    environ_map: *std.process.Environ.Map,
    cfg: *cli_mod.Config,
) !void {
    if (builtin.os.tag == .windows) {
        try writeStderr(io, "interactive mode is not yet supported on Windows — use --mode print\n");
        std.process.exit(2);
    }

    const stdin = std.Io.File.stdin();
    const stdout = std.Io.File.stdout();

    // A piped run (stdout ↛ tty) means the transcript would end up
    // in whatever captured the pipe, with escape codes mixed in.
    // Refuse early with a clear error instead — the user almost
    // certainly wanted print mode.
    const stdout_is_tty = stdout.isTty(io) catch false;
    const stdin_is_tty = stdin.isTty(io) catch false;
    if (!stdout_is_tty or !stdin_is_tty) {
        try writeStderr(io,
            "interactive mode requires a terminal on stdin and stdout.\n" ++
            "Pipe input? Use `franky \"prompt\"` (print mode) instead.\n");
        std.process.exit(2);
    }

    try runInteractive(allocator, io, environ, environ_map, cfg, stdin, stdout);
}

fn runInteractive(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    environ_map: *std.process.Environ.Map,
    cfg: *cli_mod.Config,
    stdin: std.Io.File,
    stdout: std.Io.File,
) !void {
    // ── v1.13.0 — auto-divert logs to a file ───────────────────────
    //
    // Interactive mode owns the terminal via raw-mode stdout. The
    // logger writes to stderr by default — same TTY → garbled TUI.
    // Three resolution branches:
    //   1. `--log-file PATH` (or `FRANKY_LOG_FILE`) → use it.
    //   2. No explicit file but level > `warn` → mint a default at
    //      `$FRANKY_HOME/logs/franky-<unix_ms>.log` (falling back to
    //      `$HOME/.franky/logs/...`); print a one-line stderr
    //      banner before raw mode so the user knows where to tail.
    //   3. Level ≤ `warn` (the default) and no explicit file →
    //      keep stderr; warnings/errors are sparse enough that
    //      the occasional pre-TUI line is tolerable.
    blk: {
        const explicit = print_mode.resolveLogFileFromMap(cfg, environ_map);
        const level = ai.log.currentLevel();
        var auto_path: ?[]u8 = null;
        defer if (auto_path) |p| allocator.free(p);

        const target: ?[]const u8 = explicit orelse mint: {
            if (@intFromEnum(level) <= @intFromEnum(ai.log.Level.warn)) break :mint null;
            const home = environ_map.get("FRANKY_HOME")
                orelse environ_map.get("HOME")
                orelse break :mint null;
            const ts = ai.stream.nowMillis();
            // Use the conventional `$HOME/.franky/logs` subdir when
            // we fell back from FRANKY_HOME; honor `FRANKY_HOME` as
            // its own root otherwise.
            auto_path = if (environ_map.get("FRANKY_HOME") != null)
                std.fmt.allocPrint(allocator, "{s}/logs/franky-{d}.log", .{ home, ts }) catch break :mint null
            else
                std.fmt.allocPrint(allocator, "{s}/.franky/logs/franky-{d}.log", .{ home, ts }) catch break :mint null;
            break :mint auto_path;
        };

        if (target) |path| {
            ai.log.initWithFile(io, level, path) catch break :blk;
            // Banner before raw-mode entry. Raw stderr is fine here.
            var stderr_buf: [256]u8 = undefined;
            var stderr = std.Io.File.stderr().writer(io, &stderr_buf);
            stderr.interface.print("📝 logs → {s}\n", .{path}) catch {};
            stderr.interface.flush() catch {};
        }
    }


    // ── Terminal setup ─────────────────────────────────────────────
    var terminal = term_mod.Terminal.enter(stdin.handle, stdout.handle) catch |err| {
        const msg = switch (err) {
            error.NotATty => "stdin is not a terminal\n",
            error.NotSupported => "interactive mode is not supported on this platform\n",
            else => "failed to enter raw mode\n",
        };
        try writeStderr(io, msg);
        std.process.exit(2);
    };
    // Restore runs on normal exit AND on fatal-signal path via the
    // registered `g_active` pointer.
    defer terminal.restore();
    _ = term_mod.setActive(&terminal);
    defer _ = term_mod.setActive(null);
    try term_mod.installFatalHandlers();
    try term_mod.Resize.install();

    // Enter alt screen + enable bracketed paste + hide cursor. These
    // are written raw because we haven't allocated the Buffer yet.
    writeAllFile(io, stdout,
        term_mod.seq.enter_alt_screen ++
        term_mod.seq.hide_cursor ++
        term_mod.seq.enable_bracketed_paste ++
        term_mod.seq.clear_screen ++
        term_mod.seq.cursor_home);

    var size = terminal.size();
    var buf = try tui.buffer.Buffer.init(allocator, size.rows, size.cols);
    defer buf.deinit();
    var renderer = try tui.diff_renderer.Renderer.init(allocator, size.rows, size.cols);
    defer renderer.deinit();

    var decoder = tui.key_decoder.Decoder.init(allocator);
    defer decoder.deinit();

    var editor = tui.editor.Editor.init(allocator);
    defer editor.deinit();
    if (cfg.theme) |_| {} // future hook — theme application is post-v0.11

    // Prompt history ring (v1.5.5) — walked by up/down arrows via
    // the editor's `history_prev`/`history_next` outcomes.
    var history = PromptHistory.init(allocator);
    defer history.deinit();

    // Transcript for the UI — a bounded ring of rendered lines; the
    // authoritative transcript still lives in the agent session
    // (see `SessionBinding` below). This view is display-only.
    var scrollback = Scrollback.init(allocator);
    defer scrollback.deinit();

    // ── Preset registry (shared with SessionBinding) ────────────────
    // Created here so it lives across extension init and SessionBinding
    // init. Extensions register custom presets via ext_manager, then
    // SessionBinding registers built-in presets and wires the subagent
    // tool.
    var preset_registry = tools_mod.subagent.PresetRegistry.init(allocator);
    defer preset_registry.deinit();

    // Reserve session-level state identical to print mode so
    // --resume / --session / provider lookup / tool selection all
    // keep working. The `SessionBinding` encapsulates what would
    // otherwise be ~100 lines of ceremony.
    //
    // Construct the binding in-place at its final stack address;
    // the registry stores `&session.faux` as an opaque userdata
    // pointer, so the struct must not move after init.
    var session: SessionBinding = undefined;
    try SessionBinding.init(&session, allocator, io, environ, environ_map, cfg, &preset_registry);
    defer session.deinit();

    // Note: `--log-per-session` is a no-op in interactive mode.
    // The transcript is held in memory and never assigned a
    // persisted session id, so there's no name to route the log
    // file to. Use `--log-file <path>` to capture interactive logs.

    const session_role = session.role_gate.role;
    try scrollback.appendLine(try std.fmt.allocPrint(
        allocator,
        "franky {s} — {s} ({s}) · role={s}  · Ctrl-D/:quit to exit  · Ctrl-C to abort a run  · type /help",
        .{ franky.version, session.provider.provider_name, session.provider.model_id, session_role.toString() },
    ));
    if (!role_mod.detectSandbox(environ) and (session_role == .code or session_role == .full)) {
        try scrollback.appendStyledLine(
            try std.fmt.allocPrint(
                allocator,
                "⚠ role={s} outside a sandbox — bash runs on the host. Try `zerobox -- franky --role {s} --mode interactive` or restart with --role plan.",
                .{ session_role.toString(), session_role.toString() },
            ),
            .{ .fg = .{ .basic = .yellow }, .bold = true },
        );
    }

    // ── Slash-command registry ─────────────────────────────────────
    // Built-in /help/model/clear/quit live in `coding/slash.zig`;
    // interactive-mode overrides them here with real handlers, plus
    // the new /template handler that loads + expands a prompt file
    // and enqueues the result as the next user turn.
    var slash_registry = slash_mod.Registry.init(allocator);
    defer slash_registry.deinit();
    try slash_registry.register(.{ .name = "help", .description = "Show slash-command help", .handler = slash_mod.helpHandler });
    try slash_registry.register(.{ .name = "clear", .description = "Clear transcript", .handler = interactiveClearHandler });
    try slash_registry.register(.{ .name = "quit", .description = "Exit", .handler = interactiveQuitHandler });
    try slash_registry.register(.{ .name = "restart", .description = "Restart the process (spawn fresh binary)", .handler = interactiveRestartHandler });
    try slash_registry.register(.{ .name = "model", .description = "Print active model", .handler = interactiveModelHandler });
    try slash_registry.register(.{ .name = "template", .description = "Expand and submit a prompt template", .handler = interactiveTemplateHandler });
    // v1.5.3 — §J remainder.
    try slash_registry.register(.{ .name = "tools", .description = "List registered tools", .handler = interactiveToolsHandler });
    try slash_registry.register(.{ .name = "tool", .description = "Show one tool's schema", .handler = interactiveToolHandler });
    try slash_registry.register(.{ .name = "cost", .description = "Accumulated usage", .handler = interactiveCostHandler });
    try slash_registry.register(.{ .name = "cwd", .description = "Show or set workspace cwd", .handler = interactiveCwdHandler });
    try slash_registry.register(.{ .name = "thinking", .description = "Set thinking level", .handler = interactiveThinkingHandler });
    try slash_registry.register(.{ .name = "role", .description = "Show current capability role + permitted tools", .handler = interactiveRoleHandler });
    try slash_registry.register(.{ .name = "permissions", .description = "Inspect / clear / revoke per-tool permission entries", .handler = interactivePermissionsHandler });
    try slash_registry.register(.{ .name = "retry", .description = "Re-run the last user turn", .handler = interactiveRetryHandler });
    try slash_registry.register(.{ .name = "edit", .description = "Edit and resubmit the last user msg", .handler = interactiveEditHandler });
    try slash_registry.register(.{ .name = "export", .description = "Dump transcript to markdown|json", .handler = interactiveExportHandler });
    try slash_registry.register(.{ .name = "compact", .description = "Summarize and compact the transcript", .handler = interactiveCompactHandler });
    try slash_registry.register(.{ .name = "branch", .description = "Fork a new branch at the head", .handler = interactiveBranchHandler });
    try slash_registry.register(.{ .name = "branches", .description = "List branches", .handler = interactiveBranchesHandler });
    try slash_registry.register(.{ .name = "checkout", .description = "Switch active branch", .handler = interactiveCheckoutHandler });
    try slash_registry.register(.{ .name = "diagnostics", .description = "Per-turn diagnostic report (anomalies + trace pointers)", .handler = interactiveDiagnosticsHandler });
    try slash_registry.register(.{ .name = "improve", .description = "Cross-session self-improvement report (mines past summaries)", .handler = interactiveImproveHandler });
    try slash_registry.register(.{ .name = "skills", .description = "List loaded skills + which are active for this workspace", .handler = interactiveSkillsHandler });
    // v2.16 — multi-model review pass-through. The skill file
    // (multimodel-review.md) instructs the model what to do; we just
    // forward the invocation so the model sees it as a user prompt.
    try slash_registry.register(.{ .name = "review", .description = "Multi-model code review (requires --skill multimodel-review)", .handler = interactiveReviewHandler });

    // ── Extensions runtime ────────────────────────────────────────
    // Tier-1 extensions are compiled in and opt-in via `--extensions
    // <csv>`. Each activation runs the extension's `init_fn` which
    // may register slash commands + tools + subscriptions via a
    // `Host` view. On unknown names we surface a warning line into
    // the scrollback so the user sees the typo.
    var ext_manager = extensions_mod.Manager.init(allocator);
    ext_manager.presets = &preset_registry;
    defer ext_manager.deinit();
    if (cfg.extensions) |csv| {
        const names = try extensions_mod.Manager.parseOptIn(allocator, csv);
        defer allocator.free(names);
        for (names) |name| {
            const entry = ext_catalog.lookup(name) orelse {
                try scrollback.appendLine(try std.fmt.allocPrint(
                    allocator,
                    "extension '{s}' not in built-in catalog; ignored",
                    .{name},
                ));
                continue;
            };
            ext_manager.register(entry.factory(), &slash_registry) catch |err| {
                try scrollback.appendLine(try std.fmt.allocPrint(
                    allocator,
                    "extension '{s}' failed to initialize: {s}",
                    .{ name, @errorName(err) },
                ));
                continue;
            };
            try scrollback.appendLine(try std.fmt.allocPrint(
                allocator,
                "extension '{s}' loaded",
                .{name},
            ));
        }
    }

    // v2.17 — merge extension-registered tools into session.tools.
    // SessionBinding.init finalized the tool list before extensions
    // loaded; now append any tools the extensions registered via
    // the Host view. The merge copies ext_manager.tools() into the
    // session's arena so tool lifetimes match session lifetime.
    {
        const ext_tools = ext_manager.tools();
        if (ext_tools.len > 0) {
            const arena = session.arena.allocator();
            const merged = try arena.alloc(at.AgentTool, session.tools.len + ext_tools.len);
            @memcpy(merged[0..session.tools.len], session.tools);
            @memcpy(merged[session.tools.len..], ext_tools);
            session.tools = merged;
        }
    }

    // If the user passed a prompt on the command line, submit it
    // immediately — matches print-mode semantics.
    var pending_prompt: ?[]u8 = null;
    if (cfg.prompt.len > 0) {
        pending_prompt = try allocator.dupe(u8, cfg.prompt);
    }
    defer if (pending_prompt) |p| allocator.free(p);

    // ── Main loop ──────────────────────────────────────────────────
    var running = true;
    var status_text: []const u8 = "ready";
    var read_buf: [4096]u8 = undefined;
    var fd_writer = FdWriter{ .file = stdout, .io = io };
    // v1.1.1 — scroll offset, expressed as "rows to walk back from
    // the most recent line". 0 means "at the bottom" (normal paint).
    // Page-Up increases it; Page-Down decreases; new character
    // insertion auto-snaps to 0.
    var scroll_offset: u32 = 0;

    // v1.1.2 — transcript search. When non-null, keystrokes go to
    // the search query instead of the main editor; matching
    // scrollback lines get highlighted.
    var search: ?SearchState = null;
    defer if (search) |*s| s.deinit();

    // v1.2.0 — NO_COLOR env-var spec (no-color.org). Set once at
    // startup; paint-time `Style.neutralize(no_color)` strips
    // fg/bg while preserving typographic attributes. Consumed
    // by the paint path where semantic colors are applied
    // (error/warn lines — QW4+5).
    const no_color: bool = blk: {
        const v = environ.getPosix("NO_COLOR") orelse break :blk false;
        break :blk v.len > 0;
    };

    // v1.2.0 (QW6) — `?` help overlay. Full-screen modal listing
    // keybindings + slash commands. Toggled by `?` (when the
    // editor is empty + search is inactive); dismissed by any
    // key.
    var show_help: bool = false;

    // v1.2.0 (QW7) — unread-below badge. Freezes the scrollback
    // length at the moment the user scrolls off the live edge so
    // we can compute how many new lines landed since. Returns to
    // "auto-track" mode when they scroll back to bottom.
    var scrollback_len_at_bottom: usize = 0;

    // Bridge struct that the slash handlers see through
    // `Ctx.userdata`. Declared AFTER `running` so both addresses
    // are available; lives for the whole loop.
    var slash_bridge = SlashBridge{
        .allocator = allocator,
        .io = io,
        .session = &session,
        .pending_prompt = &pending_prompt,
        .running = &running,
        .prompts_dir = cfg.prompts_dir,
    };

    paintFrame(&buf, &scrollback, &editor, .{ .status = status_text });
    try renderer.render(&fd_writer, &buf);
    buf.clear();

    while (running) {
        // v2.17 - poll restart flag. If set, break out of the loop.
        if (session.restart_requested.load(.acquire)) break;

        // Handle SIGWINCH between frames.
        if (term_mod.Resize.take()) {
            size = terminal.size();
            try bufferResize(&buf, allocator, size.rows, size.cols);
            try renderer.resize(size.rows, size.cols);
            writeAllFile(io, stdout, term_mod.seq.clear_screen);
        }

        // Submit a pending prompt (either from the CLI or from the
        // editor's last `submit` outcome).
        if (pending_prompt) |p| {
            status_text = "thinking…";
            paintFrame(&buf, &scrollback, &editor, .{ .status = status_text });
            try renderer.render(&fd_writer, &buf);
            buf.clear();

            try scrollback.appendLine(try std.fmt.allocPrint(allocator, "› {s}", .{p}));
            // Faux provider needs a scripted step per turn — the
            // echo-style "you said: …" response keeps interactive
            // demos self-contained without an API key. The canned
            // text is owned by the session arena so it outlives the
            // stream drain.
            try session.seedFauxIfNeeded(p);
            const turn_io: TurnIo = .{
                .editor = &editor,
                .history = &history,
                .slash_registry = &slash_registry,
                .slash_bridge = &slash_bridge,
                .pending_prompt = &pending_prompt,
            };
            runOneTurn(allocator, io, &session, p, &scrollback, &buf, &renderer, turn_io, stdout, &size, &decoder, &read_buf) catch |err| {
                try scrollback.appendLine(try std.fmt.allocPrint(allocator, "error: {s}", .{@errorName(err)}));
            };
            allocator.free(p);
            pending_prompt = null;
            status_text = "ready";
        }

        // Poll stdin. VMIN=0 VTIME=0 means this returns immediately.
        const n = std.posix.read(stdin.handle, &read_buf) catch |err| switch (err) {
            error.WouldBlock => 0,
            else => blk: {
                try scrollback.appendLine(try std.fmt.allocPrint(allocator, "read error: {s}", .{@errorName(err)}));
                break :blk 0;
            },
        };
        if (n > 0) try decoder.feed(read_buf[0..n]);

        var any_input = false;
        while (try decoder.next()) |key| {
            any_input = true;

            // v1.2.0 (QW6) — `?` help overlay. When visible, any
            // key dismisses. When hidden and the editor is empty
            // and search is inactive, `?` opens it. If the editor
            // has text, `?` passes through as a normal character.
            if (show_help) {
                show_help = false;
                continue;
            }
            switch (key) {
                .char => |c| if (c.cp == '?' and !c.mods.ctrl and !c.mods.alt and
                    search == null and editor.text().len == 0)
                {
                    show_help = true;
                    continue;
                },
                else => {},
            }

            // v1.1.2 — Ctrl-F (preferred) / Ctrl-S (legacy) enter
            // or exit search. Ctrl-F is the de facto standard
            // (less, lazygit, k9s, fzf); Ctrl-S is kept as a
            // backup but collides with XON/XOFF flow control on
            // many terminals, so users should prefer Ctrl-F.
            switch (key) {
                .char => |c| if (c.mods.ctrl and (c.cp == 'f' or c.cp == 's')) {
                    if (search == null) {
                        search = SearchState.init(allocator);
                    } else {
                        search.?.deinit();
                        search = null;
                    }
                    continue;
                },
                .escape => if (search != null) {
                    search.?.deinit();
                    search = null;
                    continue;
                },
                else => {},
            }
            if (search) |*s| {
                try handleSearchKey(s, &scrollback, &scroll_offset, buf.rows, key);
                continue;
            }

            // v1.1.1 — scroll keys are consumed before the editor
            // so PgUp/PgDn/Ctrl-Home/Ctrl-End never turn into text.
            // Typing any printable character auto-snaps to the
            // bottom so new messages aren't hidden.
            const transcript_rows_guess: u32 = if (buf.rows >= 3) @max(1, buf.rows / 2) else 1;
            switch (key) {
                .page_up => {
                    const max_offset: u32 = @intCast(@min(
                        @as(u64, std.math.maxInt(u32)),
                        scrollback.lines.items.len,
                    ));
                    scroll_offset = @min(scroll_offset + transcript_rows_guess, max_offset);
                    continue;
                },
                .page_down => {
                    if (scroll_offset >= transcript_rows_guess) {
                        scroll_offset -= transcript_rows_guess;
                    } else {
                        scroll_offset = 0;
                    }
                    continue;
                },
                .end => {
                    // Not Ctrl-End — plain End is line-end in the
                    // editor. We route this only when the editor is
                    // empty so the user still gets normal editor
                    // End-key behavior on non-empty lines.
                    if (editor.text().len == 0) {
                        scroll_offset = 0;
                        continue;
                    }
                },
                .char => |c| {
                    if (!c.mods.ctrl and !c.mods.alt) {
                        // Normal character typed — snap to bottom so
                        // the next message lands visibly.
                        scroll_offset = 0;
                    }
                },
                else => {},
            }

            const outcome = try editor.feedKey(key);
            switch (outcome) {
                .none => {},
                .submit => {
                    const txt = editor.text();
                    if (txt.len > 0) {
                        // Slash command?  Dispatch through the
                        // registry before treating the line as a
                        // prompt for the LLM.  /template may leave
                        // expanded text in `pending_prompt` so the
                        // next loop iteration submits it.
                        if (try maybeDispatchSlash(allocator, io, &slash_registry, &slash_bridge, txt, &scrollback, &session, &pending_prompt, &running)) {
                            try history.push(txt);
                            editor.reset();
                            break;
                        }
                        try history.push(txt);
                        pending_prompt = try allocator.dupe(u8, txt);
                        editor.reset();
                        // Flush the prompt through the turn runner
                        // before consuming further keys — this lets
                        // the user watch the response arrive before
                        // subsequent input steals focus.
                        break;
                    }
                },
                .history_prev => {
                    if (try history.prev(editor.text())) |entry| {
                        try editor.setText(entry);
                    }
                },
                .history_next => {
                    if (history.next()) |entry| {
                        try editor.setText(entry);
                    }
                },
                .completion_trigger => {
                    // Tab: complete the slash-command name if unique
                    // (or advance to the longest common prefix).
                    if (try completeSlash(allocator, &slash_registry, editor.text())) |completed| {
                        defer allocator.free(completed);
                        try editor.setText(completed);
                    }
                },
                .quit, .cancel => {
                    running = false;
                    break;
                },
                else => {},
            }
        }

        // v1.5.5 slash palette hint: compute once per frame so the
        // overhead is flat regardless of typing speed.
        const palette_line = try computeSlashHint(allocator, &slash_registry, editor.text());
        defer if (palette_line) |p| allocator.free(p);

        // v1.1.1 — when scrolled into history, append a "[scrolled
        // N/total]" marker to the status so the user sees the
        // offset. v1.1.2 — when search is active, status becomes
        // the `find: <query>` prompt + match counter.
        // v1.2.0 (QW7) — when scrolled away and new content has
        // arrived, also show a "↓ N new ↓" badge.
        const n_lines: u32 = @intCast(@min(@as(u64, std.math.maxInt(u32)), scrollback.lines.items.len));

        // QW7: auto-track the live-edge length while at bottom.
        // When the user scrolls up (offset becomes > 0), the
        // previous value sticks as the "last-seen" watermark.
        if (scroll_offset == 0) scrollback_len_at_bottom = scrollback.lines.items.len;
        const unread: usize = if (scroll_offset > 0 and scrollback.lines.items.len > scrollback_len_at_bottom)
            scrollback.lines.items.len - scrollback_len_at_bottom
        else
            0;

        const status_line = blk: {
            if (search) |s| {
                const cm = s.current_match orelse 0;
                const total = s.matches.items.len;
                const pos_shown = if (total == 0) 0 else cm + 1;
                break :blk try std.fmt.allocPrint(
                    allocator,
                    "find: {s}   ({d}/{d} matches, Esc to exit, Enter/↓ next, ↑ prev)",
                    .{ s.query.items, pos_shown, total },
                );
            }
            if (scroll_offset > 0) {
                if (unread > 0) break :blk try std.fmt.allocPrint(
                    allocator,
                    "{s} [scrolled {d}/{d}]   ↓ {d} new ↓  (End: jump to bottom)",
                    .{ status_text, scroll_offset, n_lines, unread },
                );
                break :blk try std.fmt.allocPrint(
                    allocator,
                    "{s} [scrolled {d}/{d}]",
                    .{ status_text, scroll_offset, n_lines },
                );
            }
            break :blk try allocator.dupe(u8, status_text);
        };
        defer allocator.free(status_line);
        const search_query: ?[]const u8 = if (search) |s|
            (if (s.query.items.len > 0) s.query.items else null)
        else
            null;
        if (show_help) {
            paintHelpOverlay(&buf, no_color);
        } else {
            paintFrame(&buf, &scrollback, &editor, .{ .status = status_line, .palette = palette_line, .scroll_offset = scroll_offset, .search_query = search_query, .no_color = no_color });
        }
        try renderer.render(&fd_writer, &buf);
        buf.clear();

        if (!any_input and n == 0) {
            // Idle — sleep a little to avoid pegging a CPU.
            io.sleep(.fromMilliseconds(10), .awake) catch {};
        }
    }

    // v2.17 - restart sequence: spawn fresh binary, exit.
    if (session.restart_requested.load(.acquire)) {
        restart_mod.spawnAndExit(io) catch |err| {
            try scrollback.appendLine(try std.fmt.allocPrint(
                allocator,
                "restart failed: {s} - continuing without restart",
                .{@errorName(err)},
            ));
        };
        return;
    }

    // Leave alt-screen; `defer terminal.restore` handles the rest.
    writeAllFile(io, stdout, term_mod.seq.leave_alt_screen);
}

// ─── rendering ──────────────────────────────────────────────────

/// v1.3.0 R3 — single paint entry point. All layout decisions
/// (scroll offset, palette hint, search highlight, NO_COLOR)
/// travel through `cfg`; every field has a sensible default so
/// the common case is `paintFrame(&buf, &sb, &ed, .{ .status = s })`.
pub const PaintConfig = struct {
    status: []const u8 = "",
    palette: ?[]const u8 = null,
    scroll_offset: u32 = 0,
    search_query: ?[]const u8 = null,
    no_color: bool = false,
};

fn paintFrame(
    buf: *tui.buffer.Buffer,
    scrollback: *Scrollback,
    editor: *const tui.editor.Editor,
    cfg: PaintConfig,
) void {
    buf.clear();
    if (buf.rows == 0 or buf.cols == 0) return;

    const rows = buf.rows;
    // v1.5.5 multi-line: the editor grows downward as the user
    // inserts Shift-Enter newlines. Cap at ~⅓ of the terminal so
    // the scrollback doesn't vanish on very tall compositions.
    const max_editor_rows = @max(@as(u32, 1), rows / 3);
    const desired_editor_rows = @min(editor.lineCount(), max_editor_rows);
    const editor_rows: u32 = if (rows >= 3) desired_editor_rows else 1;
    const palette_rows: u32 = if (cfg.palette != null and rows >= 4) 1 else 0;
    const editor_first_row: u32 = rows - editor_rows;
    const palette_row: u32 = if (palette_rows > 0 and editor_first_row > 0) editor_first_row - 1 else 0;
    const status_row: u32 = blk: {
        var r = if (editor_first_row > 0) editor_first_row - 1 else 0;
        if (palette_rows > 0 and r > 0) r -= 1;
        break :blk r;
    };
    const transcript_rows: u32 = if (status_row > 0) status_row else 0;

    // Transcript — paint the window of scrollback that fits. With
    // `cfg.scroll_offset == 0` this is the tail (the original
    // behavior). When cfg.scroll_offset > 0, the window walks back
    // into history — `cfg.scroll_offset` rows further up than the
    // tail. Clamped so we never paint past the end or the start.
    if (transcript_rows > 0) {
        const n_u: u32 = @intCast(@min(@as(u64, std.math.maxInt(u32)), scrollback.lines.items.len));
        // `end` is exclusive: the last line to include in the
        // window. offset=0 → end=n (tail); offset=k → end=n-k.
        const clamped_offset: u32 = @min(cfg.scroll_offset, n_u);
        const end: u32 = n_u - clamped_offset;
        const start: u32 = if (end > transcript_rows) end - transcript_rows else 0;
        var r: u32 = 0;
        var i: u32 = start;
        while (i < end) : (i += 1) {
            if (r >= transcript_rows) break;
            const line = scrollback.lines.items[i];
            // v1.2.0 — per-line style from the scrollback's
            // parallel `styles` array, neutralized for NO_COLOR.
            const base_style = if (i < scrollback.styles.items.len)
                scrollback.styles.items[i].neutralize(cfg.no_color)
            else
                tui.cell.Style{};
            // v1.1.2 — search highlight: reverse-video trumps the
            // base style for match lines so the user can locate
            // them at a glance.
            const highlighted = cfg.search_query != null and
                containsCaseInsensitive(line, cfg.search_query.?);
            const style: tui.cell.Style = if (highlighted) .{ .reverse = true } else base_style;
            _ = buf.writeUtf8(r, 0, style, line);
            r += 1;
        }
    }

    // Status line — dim + reverse so it's visually distinct.
    if (rows >= 2) {
        const style: tui.cell.Style = .{ .dim = true, .reverse = true };
        buf.fill(status_row, 0, status_row + 1, buf.cols, .{
            .codepoint = ' ',
            .width = .narrow,
            .style = style,
        });
        _ = buf.writeUtf8(status_row, 1, style, cfg.status);
    }

    // Editor — multi-row region; `draw` renders each `\n`-separated
    // line on successive rows of its region.
    const region_mod = tui.region;
    const ed_region = region_mod.Region.fromBuffer(buf).subRegion(editor_first_row, 0, editor_rows, buf.cols);
    // Visual prompt marker on the first row.
    _ = ed_region.writeUtf8(0, 0, .{ .bold = true }, "› ");
    const inner = region_mod.Region.fromBuffer(buf).subRegion(editor_first_row, 2, editor_rows, if (buf.cols >= 2) buf.cols - 2 else 0);
    // v1.2.0 — placeholder hint when empty (disappears on first
    // keystroke because the editor stops being empty). Painted
    // *before* editor.draw so the editor's cursor still lands on
    // top of whichever cell it wants.
    if (editor.text().len == 0) {
        _ = inner.writeUtf8(0, 0, .{ .dim = true }, "Type a message or /help");
    }
    editor.draw(inner, .{});

    // Slash-command hint strip directly above the editor.
    if (cfg.palette) |line| if (palette_rows > 0) {
        const hint_style: tui.cell.Style = .{ .dim = true };
        buf.fill(palette_row, 0, palette_row + 1, buf.cols, .{
            .codepoint = ' ',
            .width = .narrow,
            .style = hint_style,
        });
        _ = buf.writeUtf8(palette_row, 1, hint_style, line);
    };
}

/// v1.2.0 (QW6) — `?` help overlay. Full-screen modal showing
/// keybindings and the slash-command surface. Any key dismisses.
/// Read-only (no interaction beyond dismiss); listing is static
/// to keep the rendering cheap.
fn paintHelpOverlay(buf: *tui.buffer.Buffer, no_color: bool) void {
    buf.clear();
    if (buf.rows == 0 or buf.cols == 0) return;

    const title = "franky — help  (press any key to dismiss)";
    const title_style = (tui.cell.Style{ .bold = true, .reverse = true }).neutralize(no_color);
    const hdr_style = (tui.cell.Style{ .bold = true }).neutralize(no_color);
    const dim_style = (tui.cell.Style{ .dim = true }).neutralize(no_color);

    _ = buf.writeUtf8(0, 1, title_style, title);

    // Two columns: keybindings on the left, slash commands on the
    // right. Column width = cols / 2 - 1.
    const left_col: u32 = 2;
    const right_col: u32 = if (buf.cols >= 48) buf.cols / 2 + 1 else 2;

    const keys = [_][2][]const u8{
        .{ "Enter", "submit prompt / next search match" },
        .{ "Alt-Enter", "insert newline (multi-line compose)" },
        .{ "Shift-Enter", "insert newline (terminal-dependent)" },
        .{ "Tab", "complete slash-command prefix" },
        .{ "↑ / ↓", "walk prompt history / nav search matches" },
        .{ "Page-Up / Down", "scroll transcript" },
        .{ "End (empty)", "jump transcript to bottom" },
        .{ "Ctrl-F / Ctrl-S", "enter transcript search" },
        .{ "Ctrl-C", "abort in-flight turn / exit at prompt" },
        .{ "Ctrl-D", "exit at empty prompt" },
        .{ "?", "toggle this help overlay" },
        .{ "Esc", "exit search / dismiss help" },
    };
    const slash = [_][2][]const u8{
        .{ "/help", "slash-command list" },
        .{ "/model [id]", "show or swap the active model" },
        .{ "/thinking LVL", "set thinking level" },
        .{ "/tools", "list registered tools" },
        .{ "/tool NAME", "show a tool's schema" },
        .{ "/cost", "accumulated usage" },
        .{ "/cwd", "show workspace root" },
        .{ "/retry", "re-run the last user turn" },
        .{ "/edit TEXT", "edit + resubmit last user msg" },
        .{ "/export md|json", "dump transcript to /tmp" },
        .{ "/compact", "summarize + compact transcript" },
        .{ "/branch NAME", "fork a new branch" },
        .{ "/branches", "list branches" },
        .{ "/checkout NAME", "switch active branch" },
        .{ "/diagnostics", "per-turn anomaly report (see docs/reference/diagnostics.md)" },
        .{ "/improve", "cross-session self-improvement report" },
        .{ "/skills", "list loaded skills + which are active" },
        .{ "/template NAME", "expand + submit a prompt template" },
        .{ "/clear", "reset the transcript" },
        .{ "/quit", "exit franky" },
    };

    _ = buf.writeUtf8(2, left_col, hdr_style, "Keybindings");
    var r: u32 = 3;
    for (keys) |pair| {
        if (r >= buf.rows - 1) break;
        _ = buf.writeUtf8(r, left_col, hdr_style, pair[0]);
        _ = buf.writeUtf8(r, left_col + 20, dim_style, pair[1]);
        r += 1;
    }

    _ = buf.writeUtf8(2, right_col, hdr_style, "Slash commands");
    r = 3;
    for (slash) |pair| {
        if (r >= buf.rows - 1) break;
        _ = buf.writeUtf8(r, right_col, hdr_style, pair[0]);
        _ = buf.writeUtf8(r, right_col + 18, dim_style, pair[1]);
        r += 1;
    }

    // Footer hint.
    const footer = "any key dismisses — see franky-spec-v1.md §J for full surface";
    if (buf.rows >= 1) {
        const footer_style = (tui.cell.Style{ .dim = true, .reverse = true }).neutralize(no_color);
        buf.fill(buf.rows - 1, 0, buf.rows, buf.cols, .{
            .codepoint = ' ',
            .width = .narrow,
            .style = footer_style,
        });
        _ = buf.writeUtf8(buf.rows - 1, 1, footer_style, footer);
    }
}

/// v1.5.5 — compute the palette hint line for `buffer`. Returns an
/// allocated string (caller owns) when the buffer starts with `/`
/// and has commands to suggest; returns null when the palette
/// shouldn't display (not a slash command, or no matches).
fn computeSlashHint(
    allocator: std.mem.Allocator,
    registry: *const slash_mod.Registry,
    buffer: []const u8,
) !?[]u8 {
    if (buffer.len == 0 or buffer[0] != '/') return null;
    // If the line already contains a space, the user is past the
    // name and writing args — palette is no longer useful.
    if (std.mem.indexOfScalar(u8, buffer, ' ') != null) return null;
    const typed = buffer[1..];

    var matches: std.ArrayList([]const u8) = .empty;
    defer matches.deinit(allocator);
    for (registry.commands.items) |cmd| {
        if (typed.len == 0 or std.mem.startsWith(u8, cmd.name, typed)) {
            try matches.append(allocator, cmd.name);
            if (matches.items.len >= 6) break;
        }
    }
    if (matches.items.len == 0) return null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "commands: ");
    for (matches.items, 0..) |n, i| {
        if (i > 0) try out.appendSlice(allocator, "  ");
        try out.append(allocator, '/');
        try out.appendSlice(allocator, n);
    }
    try out.appendSlice(allocator, "    Tab: complete  Esc: dismiss");
    return try out.toOwnedSlice(allocator);
}

/// v1.5.5 — Tab completion. Returns the longest common prefix of
/// the slash commands that match the typed prefix, or the buffer
/// unchanged when no unique completion exists. Caller owns the
/// returned string.
fn completeSlash(
    allocator: std.mem.Allocator,
    registry: *const slash_mod.Registry,
    buffer: []const u8,
) !?[]u8 {
    if (buffer.len == 0 or buffer[0] != '/') return null;
    if (std.mem.indexOfScalar(u8, buffer, ' ') != null) return null;
    const typed = buffer[1..];

    // Find matches.
    var matches: std.ArrayList([]const u8) = .empty;
    defer matches.deinit(allocator);
    for (registry.commands.items) |cmd| {
        if (typed.len == 0 or std.mem.startsWith(u8, cmd.name, typed)) {
            try matches.append(allocator, cmd.name);
        }
    }
    if (matches.items.len == 0) return null;
    if (matches.items.len == 1) {
        // Unique — complete with a trailing space.
        return try std.fmt.allocPrint(allocator, "/{s} ", .{matches.items[0]});
    }
    // Longest common prefix of all matches.
    var lcp_len: usize = typed.len;
    const first = matches.items[0];
    while (lcp_len < first.len) : (lcp_len += 1) {
        const c = first[lcp_len];
        var all_match = true;
        for (matches.items[1..]) |m| {
            if (lcp_len >= m.len or m[lcp_len] != c) {
                all_match = false;
                break;
            }
        }
        if (!all_match) break;
    }
    if (lcp_len == typed.len) {
        // No extra chars are shared; keep the buffer as-is.
        return null;
    }
    return try std.fmt.allocPrint(allocator, "/{s}", .{first[0..lcp_len]});
}

// ─── one agent turn ─────────────────────────────────────────────

/// v1.1.0 — bundle the REPL state that `runOneTurn` needs to keep
/// the editor live while a turn is streaming (typing while the
/// model is thinking). Pointers so mutations stick when runOneTurn
/// returns.
const TurnIo = struct {
    editor: *tui.editor.Editor,
    history: *PromptHistory,
    slash_registry: *slash_mod.Registry,
    slash_bridge: *SlashBridge,
    pending_prompt: *?[]u8,
};

/// v1.11.2 — interactive permission-prompt modal. When `active`
/// is true, the drain loop's stdin handler intercepts `a/A/d/D/Esc`
/// and routes them to the resolver instead of the editor.
const ModalState = struct {
    active: bool = false,
    /// Owned copies of the request payload — used to render the
    /// prompt and keep the call_id / tool name available after the
    /// originating event has been freed.
    call_id: []u8 = &[_]u8{},
    tool_name: []u8 = &[_]u8{},
    args_preview: []u8 = &[_]u8{},
    fingerprint: []u8 = &[_]u8{},

    fn arm(
        self: *ModalState,
        allocator: std.mem.Allocator,
        call_id: []const u8,
        tool_name: []const u8,
        args_json: []const u8,
        fingerprint: []const u8,
    ) !void {
        // If a stale modal is still armed, clear it first so we
        // don't leak its strings.
        self.deinit(allocator);
        self.* = .{
            .active = true,
            .call_id = try allocator.dupe(u8, call_id),
            .tool_name = try allocator.dupe(u8, tool_name),
            .args_preview = try allocator.dupe(u8, argsPreviewSlice(args_json)),
            .fingerprint = try allocator.dupe(u8, fingerprint),
        };
    }

    fn clear(self: *ModalState, allocator: std.mem.Allocator) void {
        self.deinit(allocator);
        self.* = .{};
    }

    fn deinit(self: *ModalState, allocator: std.mem.Allocator) void {
        if (self.call_id.len > 0) allocator.free(self.call_id);
        if (self.tool_name.len > 0) allocator.free(self.tool_name);
        if (self.args_preview.len > 0) allocator.free(self.args_preview);
        if (self.fingerprint.len > 0) allocator.free(self.fingerprint);
    }
};

/// v1.11.2 — keystroke → permission `Resolution`. `null` means
/// the key isn't a modal binding and should be ignored. Esc and
/// the `q` quit binding both resolve as `deny_once` so the user
/// can't accidentally allow a tool by mashing keys.
fn modalKeyResolution(key: tui.key_decoder.Key) ?permissions_mod.Resolution {
    return switch (key) {
        .escape => .deny_once,
        .char => |c| switch (c.cp) {
            'a' => .allow_once,
            'A' => .always_allow,
            'd' => .deny_once,
            'D' => .always_deny,
            else => null,
        },
        else => null,
    };
}

/// First ~80 bytes of the args JSON for the modal preview.
/// Truncates with an ellipsis on overflow; preserves the full
/// `command` field literal for bash since that's what the user
/// most needs to see.
fn argsPreviewSlice(args_json: []const u8) []const u8 {
    const max = 160;
    if (args_json.len <= max) return args_json;
    return args_json[0..max];
}

fn renderResolutionLine(
    allocator: std.mem.Allocator,
    scrollback: *Scrollback,
    tool_name: []const u8,
    resolution: permissions_mod.Resolution,
) !void {
    const allowed = resolution.isAllow();
    const glyph: []const u8 = if (allowed) "✓ allowed:" else "✗ denied:";
    const tag: []const u8 = switch (resolution) {
        .allow_once => "allow_once",
        .always_allow => "always_allow",
        .deny_once => "deny_once",
        .always_deny => "always_deny",
    };
    const line = try std.fmt.allocPrint(allocator, "{s} {s} ({s})", .{ glyph, tool_name, tag });
    try scrollback.appendStyledLine(line, .{
        .fg = .{ .basic = if (allowed) .green else .red },
        .bold = true,
    });
}

fn runOneTurn(
    allocator: std.mem.Allocator,
    io: std.Io,
    session: *SessionBinding,
    prompt: []const u8,
    scrollback: *Scrollback,
    buf: *tui.buffer.Buffer,
    renderer: *tui.diff_renderer.Renderer,
    turn_io: TurnIo,
    stdout: std.Io.File,
    size: *term_mod.Size,
    decoder: *tui.key_decoder.Decoder,
    read_buf: *[4096]u8,
) !void {
    _ = size;
    const editor = turn_io.editor;
    // Append the user prompt to the live transcript so the agent
    // sees it.
    {
        const content = try allocator.alloc(ai.types.ContentBlock, 1);
        content[0] = .{ .text = .{ .text = try allocator.dupe(u8, prompt) } };
        try session.transcript.append(.{
            .role = .user,
            .content = content,
            .timestamp = ai.stream.nowMillis(),
        });
    }

    var cancel: ai.stream.Cancel = .{};
    // vN — graceful stop signal. Set by a new keybinding (Ctrl-G)
    // during a turn. Unlike `cancel.fire()`, this lets the current
    // turn finish before the loop exits with `agent_interrupted`.
    var stop_requested: std.atomic.Value(bool) = .init(false);
    var ch = try agent.loop.AgentChannel.initWithDrop(
        allocator,
        16384,
        at.AgentEvent.deinit,
        allocator,
    );
    defer ch.deinit();

    // v1.11.2 — per-turn `PermissionPrompter`. The channel is
    // per-turn but `session_gates` lives on `SessionBinding`; we
    // bind the prompter for this turn and clear it after the
    // worker joins so a slash handler can't reach into a freed
    // prompter between turns.
    var prompter = permissions_mod.PermissionPrompter.init(allocator, io, &ch);
    defer prompter.deinit();
    if (session.prompts_enabled) {
        session.session_gates.prompter = &prompter;
    }
    defer session.session_gates.prompter = null;

    var modal: ModalState = .{};
    defer modal.deinit(allocator);

    // v1.1.4 — live status-line data.
    const turn_start_ms: i64 = ai.stream.nowMillis();

    const worker_args: WorkerArgs = .{
        .allocator = allocator,
        .io = io,
        .transcript = &session.transcript,
        .config = blk: {
            var lc: agent.loop.Config = .{
                .model = session.modelType(),
                .system_prompt = session.system_prompt,
                .tools = session.tools,
                .registry = &session.registry,
                .cancel = &cancel,
                .guardrails = &session.guardrail_state,
                .hook_userdata = @ptrCast(&stop_requested),
                .role_denied = permissions_mod.SessionGates.roleDenied,
                .before_tool_call = permissions_mod.SessionGates.beforeToolCall,
                .text_tool_call_fallback = session.cfg.text_tool_call_fallback,
                .stop_requested_fn = interactiveStopRequestedFn,
                .stream_options = .{
                    .api_key = session.provider.api_key,
                    .auth_token = session.provider.auth_token,
                    .base_url = session.provider.base_url,
                    .environ_map = session.environ_map,
                    .thinking = session.cfg.thinking,
                    .timeouts = print_mode.resolveTimeoutsFromMap(session.cfg, session.environ_map),
                    .retry_policy = print_mode.resolveRetryPolicyFromMap(session.cfg, null),
                    .http_trace_dir = print_mode.resolveHttpTraceDirFromMap(session.cfg, session.environ_map),
                },
            };
            if (print_mode.resolveMaxTurnsFromMap(session.cfg, session.environ_map)) |v| lc.max_turns = v;
            lc.nudge_on_autocontinue = session.cfg.autocontinue;
            // v3.0 — wire compression into the agent loop
            if (session.cfg.compress) {
                lc.compression = compression_mod.CompressionConfig{
                    .enabled = true,
                    .min_bytes_to_compress = session.cfg.compress_min_bytes,
                    .smart_crusher_enabled = session.cfg.compress_json,
                    .log_compressor_enabled = session.cfg.compress_logs,
                    .search_compressor_enabled = session.cfg.compress_search,
                    .diff_compressor_enabled = session.cfg.compress_diff,
                    .code_compressor_enabled = session.cfg.compress_code,
                    .plain_text_compressor_enabled = session.cfg.compress_plain_text,
                    .ccr_enabled = session.cfg.compress_ccr,
                };
                lc.ccr_store = &session.ccr_store;
                lc.compression_stats = &session.compression_stats;
            }
            break :blk lc;
        },
        .ch = &ch,
    };
    const worker = try std.Thread.spawn(.{}, workerMain, .{worker_args});
    defer worker.join();

    // Drain loop — interleave channel events with stdin polling so
    // Ctrl-C still fires.
    var assistant_accum: std.ArrayList(u8) = .empty;
    defer assistant_accum.deinit(allocator);

    drain: while (true) {
        switch (ch.tryNext(io)) {
            .closed => break :drain,
            .event => |ev| {
                defer ev.deinit(allocator);
                switch (ev) {
                    .message_update => |u| switch (u) {
                        .text => |t| try assistant_accum.appendSlice(allocator, t.delta),
                        else => {},
                    },
                    .tool_execution_start => |s| {
                        try scrollback.appendLine(try std.fmt.allocPrint(
                            allocator,
                            "  · tool {s} (id={s})",
                            .{ s.name, s.call_id },
                        ));
                    },
                    .tool_permission_request => |r| {
                        // v1.11.2 — render prompt + arm the modal.
                        // Worker is suspended on a Condition until
                        // we route the user's keystroke to
                        // `prompter.resolve(call_id, …)`.
                        try modal.arm(allocator, r.call_id, r.tool_name, r.args_json, r.fingerprint);
                        const header = try std.fmt.allocPrint(
                            allocator,
                            "🔒 permission required: {s} (fingerprint: {s})",
                            .{ r.tool_name, r.fingerprint },
                        );
                        try scrollback.appendStyledLine(header, .{
                            .fg = .{ .basic = .yellow },
                            .bold = true,
                        });
                        const args_line = try std.fmt.allocPrint(
                            allocator,
                            "   args: {s}{s}",
                            .{ modal.args_preview, if (r.args_json.len > modal.args_preview.len) "…" else "" },
                        );
                        try scrollback.appendStyledLine(args_line, .{
                            .fg = .{ .basic = .yellow },
                        });
                        const legend = try allocator.dupe(
                            u8,
                            "   [a]llow once  [A]lways allow  [d]eny once  [D]eny always  (Esc=deny)",
                        );
                        try scrollback.appendStyledLine(legend, .{
                            .fg = .{ .basic = .yellow },
                        });
                    },
                    .agent_error => |d| {
                        // v1.2.0 (QW4+5) — semantic red + inline
                        // ✗ glyph. Glyph survives NO_COLOR mode;
                        // colorblind users still see the error
                        // prefix. `tool_code` subcode is appended
                        // in parens for callers that want to
                        // diagnose the failure mode.
                        const line = try std.fmt.allocPrint(
                            allocator,
                            "✗ error: {s} ({s})",
                            .{ d.message, d.code.toString() },
                        );
                        try scrollback.appendStyledLine(line, .{
                            .fg = .{ .basic = .red },
                            .bold = true,
                        });
                        // vN — `max_turns_exceeded` is the one error
                        // class the user can actually fix mid-session
                        // by raising the cap. Append a hint line so
                        // they don't have to dig through --help. The
                        // mid-session "extend now?" prompt is a v3
                        // follow-up; for now we surface the knobs.
                        if (d.code == .max_turns_exceeded) {
                            const hint = try allocator.dupe(
                                u8,
                                "  hint: raise the cap with --max-turns N, FRANKY_MAX_TURNS, or `max_turns` in settings.json / profile",
                            );
                            try scrollback.appendStyledLine(hint, .{
                                .fg = .{ .basic = .yellow },
                            });
                        }
                    },
                    .agent_interrupted => {
                        // vN — graceful stop: the current turn finished
                        // and the loop exited because the user requested
                        // a stop. Show a subtle indicator.
                        const line = try allocator.dupe(u8, "⏹ turn stopped gracefully");
                        try scrollback.appendStyledLine(line, .{
                            .fg = .{ .basic = .yellow },
                            .bold = true,
                        });
                    },
                    .turn_end => {
                        // Commit any accumulated text as a scrollback
                        // paragraph.
                        if (assistant_accum.items.len > 0) {
                            // Break on newlines so long responses
                            // don't overflow the single-line view.
                            var it = std.mem.splitScalar(u8, assistant_accum.items, '\n');
                            while (it.next()) |line| {
                                const copy = try allocator.dupe(u8, line);
                                try scrollback.appendLine(copy);
                            }
                            assistant_accum.clearRetainingCapacity();
                        }
                    },
                    else => {},
                }
            },
            .empty => {
                // v1.1.0 — typing-while-thinking. Keep the editor
                // live during the turn: feed keys the same way the
                // main REPL loop does. Submissions queue into
                // `pending_prompt` so the main loop dispatches them
                // immediately after this turn ends. Slash commands
                // must NOT dispatch mid-turn — they mutate shared
                // session state (transcript, cfg) while the worker
                // reads it. We queue the slash line as a pending
                // prompt and let the main loop's dispatch path run
                // it after this turn closes.
                const n = std.posix.read(std.Io.File.stdin().handle, read_buf) catch |err| switch (err) {
                    error.WouldBlock => 0,
                    else => 0,
                };
                if (n > 0) try decoder.feed(read_buf[0..n]);
                while (try decoder.next()) |key| {
                    if (modal.active) {
                        // v1.11.2 — consume keys for the modal.
                        // Unrecognized keys are dropped (no-op);
                        // a/A/d/D/Esc resolve and clear the modal.
                        if (modalKeyResolution(key)) |resolution| {
                            const tool_name_owned = try allocator.dupe(u8, modal.tool_name);
                            defer allocator.free(tool_name_owned);
                            prompter.resolve(modal.call_id, resolution) catch {};
                            try renderResolutionLine(allocator, scrollback, tool_name_owned, resolution);
                            modal.clear(allocator);
                        }
                        continue;
                    }
                    const outcome = editor.feedKey(key) catch continue;
                    switch (outcome) {
                        .none => {},
                        .submit => {
                            const txt = editor.text();
                            if (txt.len > 0) {
                                // Stash for post-turn dispatch;
                                // replace any earlier queued line
                                // (last-write-wins — the editor has
                                // one buffer anyway).
                                if (turn_io.pending_prompt.*) |old| allocator.free(old);
                                turn_io.pending_prompt.* = try allocator.dupe(u8, txt);
                                try turn_io.history.push(txt);
                                editor.reset();
                            }
                        },
                        .history_prev => {
                            if (try turn_io.history.prev(editor.text())) |entry| {
                                try editor.setText(entry);
                            }
                        },
                        .history_next => {
                            if (turn_io.history.next()) |entry| {
                                try editor.setText(entry);
                            }
                        },
                        .completion_trigger => {
                            if (try completeSlash(allocator, turn_io.slash_registry, editor.text())) |completed| {
                                defer allocator.free(completed);
                                try editor.setText(completed);
                            }
                        },
                        .cancel, .quit => {
                            // Ctrl-C / Ctrl-D during a turn aborts
                            // the turn (not the REPL). The user can
                            // hit it again at the idle prompt to
                            // actually exit.
                            cancel.fire();
                        },
                        else => {},
                    }
                }
                // Repaint the status bar / partial assistant output
                // so the user sees progress.
                const palette_line = try computeSlashHint(allocator, turn_io.slash_registry, editor.text());
                defer if (palette_line) |p| allocator.free(p);
                const queued_marker: []const u8 = if (turn_io.pending_prompt.*) |_| " ▸ queued" else "";
                const status = if (cancel.isFired()) "cancelling…" else "thinking…";
                // v1.1.4 — live elapsed + running usage total.
                const elapsed_s: i64 = @divFloor(ai.stream.nowMillis() - turn_start_ms, 1000);
                var usage_in: u64 = 0;
                var usage_out: u64 = 0;
                for (session.transcript.messages.items) |m| {
                    if (m.role == .assistant) if (m.usage) |u| {
                        usage_in += u.input;
                        usage_out += u.output;
                    };
                }
                const status_full = try std.fmt.allocPrint(
                    allocator,
                    "{s}{s}  ({d}s · in {d} + out {d} tokens)",
                    .{ status, queued_marker, elapsed_s, usage_in, usage_out },
                );
                defer allocator.free(status_full);
                paintFrame(buf, scrollback, editor, .{ .status = status_full, .palette = palette_line });
                if (assistant_accum.items.len > 0) {
                    // Echo the partial text at the last transcript row.
                    const row = if (buf.rows >= 3) buf.rows - 3 else 0;
                    _ = buf.writeUtf8(row, 0, .{ .italic = true }, assistant_accum.items);
                }
                var drain_writer = FdWriter{ .file = stdout, .io = io };
                try renderer.render(&drain_writer, buf);
                buf.clear();
                io.sleep(.fromMilliseconds(10), .awake) catch {};
            },
        }
    }
}

// ─── worker thread shim ────────────────────────────────────────

const WorkerArgs = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    transcript: *agent.loop.Transcript,
    config: agent.loop.Config,
    ch: *agent.loop.AgentChannel,
};

fn workerMain(args: WorkerArgs) void {
    agent.loop.agentLoop(args.allocator, args.io, args.transcript, args.config, args.ch);
}

/// vN — callback for `loop.Config.stop_requested_fn` in interactive
/// mode. `userdata` is a pointer to the per-turn `stop_requested`
/// atomic flag set by the Ctrl-G keybinding.
fn interactiveStopRequestedFn(userdata: ?*anyopaque) bool {
    const flag: *std.atomic.Value(bool) = @ptrCast(@alignCast(userdata.?));
    return flag.load(.acquire);
}

// ─── transcript search (v1.1.2) ────────────────────────────────

/// Search state lives in the REPL while `Ctrl-S` has been pressed
/// and not yet `Esc`'d. Keys go to `query` instead of the main
/// editor; matching scrollback lines get highlighted.
pub const SearchState = struct {
    allocator: std.mem.Allocator,
    query: std.ArrayList(u8) = .empty,
    /// Indices into `scrollback.lines` that match the current
    /// query. Cleared + re-computed on every query mutation.
    matches: std.ArrayList(usize) = .empty,
    /// Index into `matches` — which match the user is focused on.
    /// When non-null, the REPL sets `scroll_offset` to land that
    /// match near the top of the visible window.
    current_match: ?usize = null,

    pub fn init(allocator: std.mem.Allocator) SearchState {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SearchState) void {
        self.query.deinit(self.allocator);
        self.matches.deinit(self.allocator);
        self.* = undefined;
    }

    /// Recompute match indices for the current query against
    /// `lines`. Case-insensitive substring match.
    pub fn recompute(
        self: *SearchState,
        lines: []const []const u8,
    ) !void {
        self.matches.clearRetainingCapacity();
        if (self.query.items.len == 0) {
            self.current_match = null;
            return;
        }
        for (lines, 0..) |line, i| {
            if (containsCaseInsensitive(line, self.query.items)) {
                try self.matches.append(self.allocator, i);
            }
        }
        self.current_match = if (self.matches.items.len > 0) 0 else null;
    }
};

fn containsCaseInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) break;
        }
        if (j == needle.len) return true;
    }
    return false;
}

/// v1.1.2 — key dispatch while search is active. Supports query
/// editing (chars, backspace), navigation (Enter → next match,
/// up/down arrows → prev/next), and recomputes matches when the
/// query changes. On each recompute, `scroll_offset` jumps to the
/// current match so it's visible.
fn handleSearchKey(
    search: *SearchState,
    scrollback: *Scrollback,
    scroll_offset: *u32,
    buf_rows: u32,
    key: tui.key_decoder.Key,
) !void {
    var dirty = false;
    switch (key) {
        .char => |c| {
            if (c.mods.ctrl or c.mods.alt) return;
            // Simple: allocate one byte if it fits UTF-8 in 1 byte.
            if (c.cp < 0x80) {
                try search.query.append(search.allocator, @intCast(c.cp));
                dirty = true;
            }
        },
        .backspace => {
            if (search.query.items.len > 0) {
                _ = search.query.pop();
                dirty = true;
            }
        },
        .enter => {
            // Cycle to next match.
            if (search.current_match) |cm| {
                if (search.matches.items.len > 0) {
                    search.current_match = (cm + 1) % search.matches.items.len;
                    dirty = true;
                }
            }
        },
        .up => {
            if (search.current_match) |cm| {
                if (search.matches.items.len > 0) {
                    search.current_match = if (cm == 0)
                        search.matches.items.len - 1
                    else
                        cm - 1;
                    dirty = true;
                }
            }
        },
        .down => {
            if (search.current_match) |cm| {
                if (search.matches.items.len > 0) {
                    search.current_match = (cm + 1) % search.matches.items.len;
                    dirty = true;
                }
            }
        },
        else => {},
    }
    if (dirty) {
        try search.recompute(scrollback.lines.items);
    }
    // Land the current match near the top of the visible window.
    if (search.current_match) |cm| {
        const match_idx = search.matches.items[cm];
        const n: usize = scrollback.lines.items.len;
        const transcript_rows: u32 = if (buf_rows >= 3) @max(1, buf_rows - 2) else 1;
        // Want `match_idx` to appear at row 0 of the window:
        //   end = match_idx + 1 → offset = n - end.
        const end: usize = match_idx + @min(transcript_rows, @as(u32, @intCast(n - match_idx)));
        scroll_offset.* = @intCast(@min(@as(u64, std.math.maxInt(u32)), n - end));
    }
}

// ─── prompt history ring (v1.5.5) ──────────────────────────────

/// Bounded ring of prior user prompts. The REPL cursor walks
/// backward on `history_prev`, forward on `history_next`. Only
/// lives for the REPL's lifetime — cross-session history is a
/// post-1.0 polish item.
pub const PromptHistory = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList([]u8) = .empty,
    capacity: usize = 100,
    /// Position during navigation. `null` = not navigating.
    /// When navigating, `cursor` ∈ [0, entries.len). `0` is the
    /// oldest, `entries.len - 1` is the most recent.
    cursor: ?usize = null,
    /// Snapshot of the in-progress line when navigation started,
    /// so we can restore it when the user walks past the newest
    /// entry.
    draft: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator) PromptHistory {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *PromptHistory) void {
        for (self.entries.items) |e| self.allocator.free(e);
        self.entries.deinit(self.allocator);
        if (self.draft) |d| self.allocator.free(d);
        self.* = undefined;
    }

    /// Add `text` to the ring. Duplicates of the most recent entry
    /// are coalesced (common pattern: user resubmits a tweaked
    /// prompt and doesn't want the exact same line twice in a row).
    pub fn push(self: *PromptHistory, text: []const u8) !void {
        if (self.entries.items.len > 0) {
            const last = self.entries.items[self.entries.items.len - 1];
            if (std.mem.eql(u8, last, text)) return;
        }
        if (self.entries.items.len >= self.capacity) {
            const dropped = self.entries.orderedRemove(0);
            self.allocator.free(dropped);
        }
        try self.entries.append(self.allocator, try self.allocator.dupe(u8, text));
        self.resetCursor();
    }

    pub fn resetCursor(self: *PromptHistory) void {
        self.cursor = null;
        if (self.draft) |d| {
            self.allocator.free(d);
            self.draft = null;
        }
    }

    /// Walk one entry backward. Saves `current_draft` on the first
    /// step so `next` past the newest restores it. Returns the entry
    /// to display (borrowed; valid until the next history mutation)
    /// or `null` when already at the oldest entry.
    pub fn prev(self: *PromptHistory, current_draft: []const u8) !?[]const u8 {
        if (self.entries.items.len == 0) return null;
        if (self.cursor == null) {
            if (self.draft) |d| self.allocator.free(d);
            self.draft = try self.allocator.dupe(u8, current_draft);
            self.cursor = self.entries.items.len - 1;
        } else if (self.cursor.? > 0) {
            self.cursor = self.cursor.? - 1;
        } else {
            // Already at the oldest.
            return self.entries.items[0];
        }
        return self.entries.items[self.cursor.?];
    }

    /// Walk one entry forward. Returns the next entry (borrowed
    /// from the ring), or the saved draft (borrowed from `self`),
    /// or null when not currently navigating. Returned slices are
    /// valid until the next mutation of this PromptHistory.
    pub fn next(self: *PromptHistory) ?[]const u8 {
        const c = self.cursor orelse return null;
        if (c + 1 < self.entries.items.len) {
            self.cursor = c + 1;
            return self.entries.items[c + 1];
        }
        // Stepped past the newest — surface the saved draft and
        // exit nav mode. The draft slice stays alive on `self`
        // until the next `push`/`prev`/`resetCursor`/`deinit`.
        self.cursor = null;
        return self.draft orelse "";
    }
};

// ─── scrollback ring ───────────────────────────────────────────

/// Append-only line list with a cap; the oldest line is dropped
/// when capacity is reached. Each line is heap-allocated and owned.
pub const Scrollback = struct {
    allocator: std.mem.Allocator,
    lines: std.ArrayList([]u8) = .empty,
    /// v1.2.0 (QW4+5) — parallel style array. `styles[i]` is
    /// applied to `lines[i]` at paint time. Default `.{}` keeps
    /// normal rendering; error lines use red, warnings use yellow,
    /// metadata can use `.dim`. `Style.neutralize(no_color)` in
    /// the paint path honors the NO_COLOR env var.
    styles: std.ArrayList(tui.cell.Style) = .empty,
    capacity: usize = 1_000,

    pub fn init(allocator: std.mem.Allocator) Scrollback {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Scrollback) void {
        for (self.lines.items) |l| self.allocator.free(l);
        self.lines.deinit(self.allocator);
        self.styles.deinit(self.allocator);
        self.* = undefined;
    }

    /// Takes ownership of `line`. Style defaults to `.{}`.
    pub fn appendLine(self: *Scrollback, line: []u8) !void {
        return self.appendStyledLine(line, .{});
    }

    /// Takes ownership of `line`. `style` is applied verbatim at
    /// paint time (modulo NO_COLOR neutralization).
    pub fn appendStyledLine(self: *Scrollback, line: []u8, style: tui.cell.Style) !void {
        if (self.lines.items.len >= self.capacity) {
            const dropped = self.lines.orderedRemove(0);
            self.allocator.free(dropped);
            _ = self.styles.orderedRemove(0);
        }
        try self.lines.append(self.allocator, line);
        try self.styles.append(self.allocator, style);
    }
};

// ─── session binding ───────────────────────────────────────────
//
// Small wrapper that reuses print-mode's provider resolution and
// tool registration so interactive mode stays in lock-step with
// `--mode print`. The goal is: anything the user can do with
// `franky <prompt>` they can also do at the interactive prompt
// without re-plumbing.

const SessionBinding = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    cfg: *cli_mod.Config,
    arena: std.heap.ArenaAllocator,
    registry: ai.registry.Registry,
    faux: ai.providers.faux.FauxProvider,
    provider: print_mode.ProviderInfo,
    tools: []const at.AgentTool,
    /// Capability role + filtered ToolSet bound at session init.
    /// Stable address for the worker thread's `hook_userdata`.
    role_gate: role_mod.RoleGate = role_mod.RoleGate.init(.plan),
    /// v1.11.0 — per-tool permission gate. Disabled by default;
    /// `--prompts` opts in. Stable address (worker thread reads).
    permission_store: permissions_mod.Store = undefined,
    /// v1.19.0 — resolved per-tool-prompt toggle. CLI `--prompts`
    /// wins; otherwise honors settings.json `prompts: bool`.
    prompts_enabled: bool = false,
    /// Combined gates struct passed as `hook_userdata`.
    session_gates: permissions_mod.SessionGates = .{},
    system_prompt: []u8,
    transcript: agent.loop.Transcript,
    /// v1.6.0 — persistent branch tree. Mirrors print.zig's
    /// `SessionState.tree`; slash handlers operate on this.
    tree: branching_mod.Tree,
    /// §R workspace + bash session state. Populated when PWD is
    /// available; held as optionals so the address of each struct
    /// is stable for the whole session (tool ctx pointers).
    workspace: ?tools_mod.workspace.Workspace = null,
    bash_state: tools_mod.bash.SessionBashState = undefined,
    bash_ctx: tools_mod.bash.BashCtx = .{},
    web_search_ctx: tools_mod.web_search.WebSearchCtx = .{},
    /// v1.19.0 — ReadCtx for the read tool (workspace + settings
    /// overlay). Stable address: tool ctx pointers reference it.
    read_ctx: tools_mod.read.ReadCtx = .{},
    /// v1.29.2 — wall-clock at SessionBinding.init. Used by
    /// `/diagnostics` to synthesize a stable per-run id
    /// (`interactive-<startup_ms>`) for the persist path; rpc and
    /// proxy use real session ids instead.
    startup_ms: i64 = 0,
    /// v2.17 - restart signal. Set by `/restart` or finish_task.restart.
    /// The main loop polls this flag and breaks out to perform the
    /// spawn-and-exit restart sequence.
    restart_requested: std.atomic.Value(bool) = .init(false),
    guardrail_state: agent.guardrails.GuardrailState = undefined,
    /// v3.0 — session-scoped CCR store for reversible compression.
    ccr_store: compression_mod.CcrSessionStore = undefined,
    /// v3.0 — compression statistics.
    compression_stats: compression_mod.CompressionStats = .{},
    /// v3.0 — CCR context bundling store + stats for ccr_retrieve tool.
    ccr_ctx: compression_mod.CcrContext = undefined,

    /// Fills `binding` in place. Taking the destination pointer is
    /// required: the `FauxProvider`'s address gets registered with
    /// the `ai.registry.Registry` as `userdata`, so a by-value move
    /// after init would leave a dangling pointer — which is what
    /// trivial `return self;` patterns silently produce.
    fn init(
        binding: *SessionBinding,
        allocator: std.mem.Allocator,
        io: std.Io,
        environ: std.process.Environ,
        environ_map: *std.process.Environ.Map,
        cfg: *cli_mod.Config,
        preset_registry: *tools_mod.subagent.PresetRegistry,
    ) !void {
        binding.* = .{
            .allocator = allocator,
            .io = io,
            .environ_map = environ_map,
            .cfg = cfg,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .registry = ai.registry.Registry.init(allocator),
            .faux = ai.providers.faux.FauxProvider.init(allocator),
            .provider = undefined,
            .tools = undefined, // filled in below after workspace is set
            .system_prompt = undefined,
            .transcript = agent.loop.Transcript.init(allocator),
            .tree = try branching_mod.Tree.init(allocator),
            .bash_state = tools_mod.bash.SessionBashState.init(allocator),
            .workspace = if (environ.getPosix("PWD")) |pwd|
                tools_mod.workspace.Workspace{ .root = pwd, .host_env = environ_map }
            else
                null,
            .startup_ms = ai.stream.nowMillis(),
            .ccr_store = compression_mod.CcrSessionStore.init(allocator),
        };
        binding.ccr_ctx = .{ .store = &binding.ccr_store, .stats = &binding.compression_stats };
        binding.read_ctx = .{
            .workspace = if (binding.workspace) |*ws| ws else null,
        };
        // v1.19.0 — apply settings-layer overlay
        // (tools.bash.timeoutMs + tools.read.maxBytes).
        {
            var settings = try print_mode.loadSettingsForOverlay(allocator, io, environ);
            defer settings.deinit();
            print_mode.applyBashSettingsOverlay(&binding.bash_state, &settings);
            print_mode.applyReadSettingsOverlay(&binding.read_ctx, &settings);

            // v2.16 — pre-render the review config block for system-prompt injection.
            // Only populate when profiles are configured so the block is non-empty.
            if (settings.review_profiles.len > 0) {
                const ca = cfg.arena.allocator();
                // Build a comma-separated profile list for readability.
                var pb: std.ArrayList(u8) = .empty;
                defer pb.deinit(ca);
                for (settings.review_profiles, 0..) |p, i| {
                    if (i > 0) try pb.appendSlice(ca, ", ");
                    try pb.appendSlice(ca, p);
                }
                const profiles_csv = try pb.toOwnedSlice(ca);
                defer ca.free(profiles_csv);
                cfg.review_config_block = try std.fmt.allocPrint(
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
        }
        binding.bash_ctx = .{
            .state = &binding.bash_state,
            .workspace = if (binding.workspace) |*ws| ws else null,
        };
        binding.web_search_ctx = .{ .environ_map = environ_map };
        // Path-taking tools get workspace routing when PWD is known;
        // read additionally carries the settings-layer ReadCtx.
        const all_tools: [9]at.AgentTool = if (binding.workspace) |*ws| .{
            tools_mod.read.toolWithCtx(&binding.read_ctx),
            tools_mod.write.toolWithWorkspace(ws),
            tools_mod.edit.toolWithWorkspace(ws),
            tools_mod.bash.toolWithStateAndWorkspace(&binding.bash_ctx),
            tools_mod.ls.toolWithWorkspace(ws),
            tools_mod.find.toolWithWorkspace(ws),
            tools_mod.grep.toolWithWorkspace(ws),
            tools_mod.web_search.toolWithCtx(&binding.web_search_ctx),
            tools_mod.web_fetch.toolWithCtx(&binding.web_search_ctx),
        } else .{
            tools_mod.read.tool(),
            tools_mod.write.tool(),
            tools_mod.edit.tool(),
            tools_mod.bash.toolWithState(&binding.bash_state),
            tools_mod.ls.tool(),
            tools_mod.find.tool(),
            tools_mod.grep.tool(),
            tools_mod.web_search.toolWithCtx(&binding.web_search_ctx),
            tools_mod.web_fetch.toolWithCtx(&binding.web_search_ctx),
        };

        const active_role = if (cfg.role) |s|
            role_mod.Role.fromString(s) catch return error.UnknownRole
        else
            role_mod.Role.plan;
        binding.role_gate = role_mod.RoleGate.init(active_role);
        binding.tools = try role_mod.filterTools(binding.arena.allocator(), &all_tools, binding.role_gate.set);

        binding.permission_store = permissions_mod.Store.init(allocator);
        // v1.19.0 — settings-layer overlay first; CLI overlay below.
        {
            var settings = try print_mode.loadSettingsForOverlay(allocator, io, environ);
            defer settings.deinit();
            try print_mode.applyPermissionsSettingsOverlay(&binding.permission_store, &settings);
            binding.prompts_enabled = print_mode.resolvePromptsDefault(cfg, &settings);
            print_mode.applyMaxTurnsSettingsOverlay(cfg, &settings);

            // v2.16 — pre-render the review config block for system-prompt injection.
            // Only populate when profiles are configured so the block is non-empty.
            if (settings.review_profiles.len > 0) {
                const ca = cfg.arena.allocator();
                // Build a comma-separated profile list for readability.
                var pb: std.ArrayList(u8) = .empty;
                defer pb.deinit(ca);
                for (settings.review_profiles, 0..) |p, i| {
                    if (i > 0) try pb.appendSlice(ca, ", ");
                    try pb.appendSlice(ca, p);
                }
                const profiles_csv = try pb.toOwnedSlice(ca);
                defer ca.free(profiles_csv);
                cfg.review_config_block = try std.fmt.allocPrint(
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
        }
        if (cfg.yes) binding.permission_store.yes_to_all = true;
        if (cfg.allow_tools_csv) |s| try binding.permission_store.addAllowList(s);
        if (cfg.deny_tools_csv) |s| try binding.permission_store.addDenyList(s);
        if (cfg.ask_tools_csv) |s| try binding.permission_store.addAskList(s);
        try permissions_mod.maybeAttachPersistence(
            &binding.permission_store,
            cfg.remember_permissions,
            cfg.arena.allocator(),
            io,
            environ_map,
        );
        binding.session_gates = .{
            .role = &binding.role_gate,
            .permissions = if (binding.prompts_enabled) &binding.permission_store else null,
        };
        errdefer binding.registry.deinit();
        errdefer binding.faux.deinit();
        errdefer binding.arena.deinit();
        errdefer binding.permission_store.deinit();

        const wr_dir = if (binding.workspace) |ws| ws.root else ".";
        binding.guardrail_state = try agent.guardrails.GuardrailState.init(
            allocator,
            .{ .workspace_dir = wr_dir },
            io,
        );
        errdefer binding.guardrail_state.deinit();
        // v2.17 - wire guardrail restart signal to session flag.
        binding.guardrail_state.restart_requested = &binding.restart_requested;

        binding.provider = try print_mode.resolveProvider(allocator, environ, cfg);
        try binding.registry.register(.{
            .api = "faux",
            .provider = "faux",
            .stream_fn = fauxShim,
            .userdata = @ptrCast(&binding.faux),
        });
        try binding.registry.register(.{
            .api = "anthropic-messages",
            .provider = "anthropic",
            .stream_fn = ai.providers.anthropic.streamFn,
        });
        try binding.registry.register(.{
            .api = "openai-chat-completions",
            .provider = "openai",
            .stream_fn = ai.providers.openai_chat.streamFn,
        });
        try binding.registry.register(.{
            .api = "openai-compatible-gateway",
            .provider = "gateway",
            .stream_fn = ai.providers.openai_gateway.streamFn,
        });
        try binding.registry.register(.{
            .api = "google-gemini",
            .provider = "google-gemini",
            .stream_fn = ai.providers.google_gemini.streamFn,
        });

        // §5 — subagent + list_subagent_presets tools.
        // Extensions may have already registered custom presets
        // (via ext_manager.presets). Register built-in presets now,
        // then build the combined parameters JSON from the arena.
        {
            const aa = binding.arena.allocator();
            try tools_mod.subagent.registerBuiltinPresets(preset_registry);

            const params_json = try tools_mod.subagent.buildParametersJson(aa, preset_registry);

            const subagent_ctx = try aa.create(tools_mod.subagent.Ctx);
            subagent_ctx.* = .{
                .registry = &binding.registry,
                .environ = environ,
                .environ_map = environ_map,
                .parent_tools = binding.tools,
                .parent_role = binding.role_gate.role,
                .parent_profile = cfg.profile orelse "",
                .presets = preset_registry,
                .parameters_json_owned = params_json,
                .permission_store = if (binding.prompts_enabled) &binding.permission_store else null,
                // v1.24.3 — interactive's prompter lives on a per-
                // turn stack frame, not a session field, so we
                // can't take its address stably. Sub-agents in
                // interactive mode run un-gated for now (same as
                // print). v2 follow-up: hoist the prompter to a
                // session field OR add a callback registry.
                .permission_prompter_slot = null,
                .parent_session_dir = null,
            };
            const final_tools = try aa.alloc(at.AgentTool, binding.tools.len + 4);
            @memcpy(final_tools[0..binding.tools.len], binding.tools);
            final_tools[binding.tools.len] = tools_mod.subagent.toolWithCtx(subagent_ctx);
            final_tools[binding.tools.len + 1] = tools_mod.subagent.listPresetsToolWithCtx(preset_registry);
            final_tools[binding.tools.len + 2] = binding.guardrail_state.finishTaskTool();
            // v3.0 — ccr_retrieve tool for reversible compression
            final_tools[binding.tools.len + 3] = tools_mod.ccr_retrieve.toolWithCtxAndStats(&binding.ccr_ctx);
            binding.tools = final_tools;
        }

        binding.system_prompt = try print_mode.buildSystemPromptIo(allocator, io, environ, cfg);
    }

    fn deinit(self: *SessionBinding) void {
        self.transcript.deinit();
        self.tree.deinit();
        self.allocator.free(self.system_prompt);
        self.registry.deinit();
        self.faux.deinit();
        self.permission_store.deinit();
        self.bash_state.deinit();
        self.guardrail_state.deinit();
        self.ccr_store.deinit();
        self.arena.deinit();
    }

    /// When the resolved provider is `faux`, push one scripted
    /// echo step before each turn so `--mode interactive` has
    /// something to stream back without any API key.
    fn seedFauxIfNeeded(self: *SessionBinding, prompt: []const u8) !void {
        if (!std.mem.eql(u8, self.provider.provider_name, "faux")) return;
        const a = self.arena.allocator();
        const reply = try std.fmt.allocPrint(a, "you said: {s}", .{prompt});
        // `Step.events` is a slice reference — allocate the
        // one-element backing array in the arena too.
        const events = try a.alloc(ai.providers.faux.Event, 1);
        events[0] = .{ .text = .{ .text = reply, .chunk_size = 8 } };
        try self.faux.push(.{ .events = events });
    }

    fn modelType(self: *const SessionBinding) ai.types.Model {
        return .{
            .id = self.provider.model_id,
            .provider = self.provider.provider_name,
            .api = self.provider.api_tag,
            .context_window = self.provider.context_window,
            .max_output = self.provider.max_output,
            .capabilities = .{
                .vision = false,
                .tool_use = true,
                .reasoning = self.cfg.thinking != .off,
            },
        };
    }
};

fn fauxShim(ctx: ai.registry.StreamCtx) anyerror!void {
    const faux_ptr: *ai.providers.faux.FauxProvider = @ptrCast(@alignCast(ctx.userdata.?));
    try faux_ptr.runSync(ctx.io, ctx.context, ctx.out);
}

// ─── slash-command integration ──────────────────────────────────

/// What the interactive-mode slash handlers see through
/// `Ctx.userdata`. Gives them mutable access to the pieces of
/// interactive state that commands like `/clear` / `/quit` /
/// `/template` need to poke.
const SlashBridge = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    session: *SessionBinding,
    /// Pointer to the main-loop's pending-prompt slot. `/template`
    /// writes expanded text here so the next loop iteration submits
    /// it just like a user-typed line.
    pending_prompt: *?[]u8,
    /// Pointer to the main-loop's running flag. `/quit` sets this
    /// false so the REPL exits cleanly without faking a Ctrl-D.
    running: *bool,
    /// Root directory for `/template <name>` lookups. When null
    /// (no `--prompts <dir>` and no settings fallback yet), the
    /// handler surfaces a clear error rather than guessing.
    prompts_dir: ?[]const u8,
};

/// Try to treat `line` as a slash command. Returns `true` if it
/// was dispatched (including error paths — the caller should
/// *not* forward the line to the agent), `false` if it wasn't a
/// slash line at all. Any output the handler wrote is appended
/// to the scrollback for the next paint.
fn maybeDispatchSlash(
    allocator: std.mem.Allocator,
    io: std.Io,
    registry: *slash_mod.Registry,
    bridge: *SlashBridge,
    line: []const u8,
    scrollback: *Scrollback,
    session: *SessionBinding,
    pending_prompt: *?[]u8,
    running: *bool,
) !bool {
    _ = io;
    _ = session;
    _ = pending_prompt;
    _ = running;
    if (line.len == 0 or line[0] != '/') return false;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var ctx: slash_mod.Ctx = .{
        .userdata = @ptrCast(bridge),
        .output = &out,
        .allocator = allocator,
    };
    registry.dispatch(&ctx, line) catch |err| {
        const msg = switch (err) {
            slash_mod.Error.UnknownCommand => try std.fmt.allocPrint(allocator, "unknown command: {s}", .{line}),
            slash_mod.Error.ArgRequired => try std.fmt.allocPrint(allocator, "command requires an argument: {s}", .{line}),
            slash_mod.Error.Rejected => try std.fmt.allocPrint(allocator, "rejected: {s}", .{line}),
            else => try std.fmt.allocPrint(allocator, "error: {s}", .{@errorName(err)}),
        };
        try scrollback.appendLine(msg);
        return true;
    };
    // Split handler output by newlines into scrollback lines so
    // each line is independently clipped by the renderer.
    var it = std.mem.splitScalar(u8, out.items, '\n');
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        const copy = try allocator.dupe(u8, seg);
        try scrollback.appendLine(copy);
    }
    return true;
}

fn bridgeFromCtx(ctx: *slash_mod.Ctx) *SlashBridge {
    return @ptrCast(@alignCast(ctx.userdata.?));
}

fn interactiveClearHandler(ctx: *slash_mod.Ctx, _: []const []const u8) slash_mod.Error!void {
    const bridge = bridgeFromCtx(ctx);
    // Reset the session transcript.  Everything inside is
    // allocator-owned, so `deinit + init` is the correct
    // pattern.
    bridge.session.transcript.deinit();
    bridge.session.transcript = agent.loop.Transcript.init(bridge.allocator);
    try ctx.output.appendSlice(ctx.allocator, "transcript cleared");
}

fn interactiveQuitHandler(ctx: *slash_mod.Ctx, _: []const []const u8) slash_mod.Error!void {
    const bridge = bridgeFromCtx(ctx);
    bridge.running.* = false;
    try ctx.output.appendSlice(ctx.allocator, "bye");
}

fn interactiveRestartHandler(ctx: *slash_mod.Ctx, _: []const []const u8) slash_mod.Error!void {
    const bridge = bridgeFromCtx(ctx);
    bridge.session.restart_requested.store(true, .release);
    try ctx.output.appendSlice(ctx.allocator, "Restarting...");
    // Set running false so the main loop breaks and picks up the restart flag.
    bridge.running.* = false;
}

fn interactiveModelHandler(ctx: *slash_mod.Ctx, args: []const []const u8) slash_mod.Error!void {
    const bridge = bridgeFromCtx(ctx);
    if (args.len == 0) {
        const msg = try std.fmt.allocPrint(ctx.allocator, "active model: {s} ({s})", .{
            bridge.session.provider.model_id,
            bridge.session.provider.provider_name,
        });
        defer ctx.allocator.free(msg);
        try ctx.output.appendSlice(ctx.allocator, msg);
        return;
    }
    // v1.1.3 — live model swap. Dupe the new id into the session's
    // arena (the old slice stays referenced by `provider.model_id`
    // until overwritten, which is safe because arena outlives it).
    // Re-lookup in the built-in catalog so `context_window`,
    // `max_output`, `capabilities` refresh for the new model;
    // unknown ids keep the conservative defaults.
    const new_id = try bridge.session.arena.allocator().dupe(u8, args[0]);
    bridge.session.provider.model_id = new_id;
    if (models_mod.lookup(&.{}, new_id)) |entry| {
        bridge.session.provider.context_window = entry.context_window;
        bridge.session.provider.max_output = entry.max_output;
        bridge.session.provider.capabilities = .{
            .vision = entry.capabilities.vision,
            .tool_use = entry.capabilities.tool_use,
            .reasoning = if (bridge.session.cfg.thinking != .off)
                true
            else
                entry.capabilities.reasoning,
            .cache = entry.capabilities.cache,
            .streaming = entry.capabilities.streaming,
        };
    }
    const entry_tag = if (models_mod.lookup(&.{}, new_id) != null) "known" else "unknown";
    const msg = try std.fmt.allocPrint(
        ctx.allocator,
        "model swapped to '{s}' ({s}); next turn uses it",
        .{ new_id, entry_tag },
    );
    defer ctx.allocator.free(msg);
    try ctx.output.appendSlice(ctx.allocator, msg);
}

fn interactiveTemplateHandler(ctx: *slash_mod.Ctx, args: []const []const u8) slash_mod.Error!void {
    if (args.len == 0) return slash_mod.Error.ArgRequired;
    const bridge = bridgeFromCtx(ctx);
    const prompts_dir = bridge.prompts_dir orelse {
        try ctx.output.appendSlice(ctx.allocator, "no prompts dir configured (pass --prompts <dir>)");
        return;
    };
    const name = args[0];
    const positional = args[1..];

    const template_bytes = templates_mod.loadTemplate(ctx.allocator, bridge.io, prompts_dir, name) catch |err| {
        const msg = switch (err) {
            templates_mod.TemplateError.NotFound => try std.fmt.allocPrint(ctx.allocator, "template not found: {s}/{s}.md", .{ prompts_dir, name }),
            else => try std.fmt.allocPrint(ctx.allocator, "template load error: {s}", .{@errorName(err)}),
        };
        defer ctx.allocator.free(msg);
        try ctx.output.appendSlice(ctx.allocator, msg);
        return;
    };
    defer ctx.allocator.free(template_bytes);

    const expanded = templates_mod.expand(ctx.allocator, template_bytes, .{ .positional = positional }) catch |err| {
        const msg = switch (err) {
            templates_mod.TemplateError.MissingArg => try std.fmt.allocPrint(ctx.allocator, "template '{s}' expects more positional args", .{name}),
            templates_mod.TemplateError.MalformedPlaceholder => try std.fmt.allocPrint(ctx.allocator, "template '{s}' has a malformed placeholder", .{name}),
            else => try std.fmt.allocPrint(ctx.allocator, "template expand error: {s}", .{@errorName(err)}),
        };
        defer ctx.allocator.free(msg);
        try ctx.output.appendSlice(ctx.allocator, msg);
        return;
    };
    // Enqueue the expanded text as the next pending prompt.  Free
    // any previous pending prompt first — we're replacing it.
    if (bridge.pending_prompt.*) |p| bridge.allocator.free(p);
    bridge.pending_prompt.* = expanded;
    const ack = try std.fmt.allocPrint(ctx.allocator, "template '{s}' expanded; submitting…", .{name});
    defer ctx.allocator.free(ack);
    try ctx.output.appendSlice(ctx.allocator, ack);
}

// ─── v1.5.3 — §J remainder handlers ─────────────────────────────

fn interactiveReviewHandler(ctx: *slash_mod.Ctx, args: []const []const u8) slash_mod.Error!void {
    const bridge = bridgeFromCtx(ctx);

    // Build a self-contained multi-model review prompt.
    // Instructions are embedded here so /review works without
    // requiring the multimodel-review skill to be active.
    var pb: std.ArrayList(u8) = .empty;
    errdefer pb.deinit(bridge.allocator);

    const review_prompt = try review_mod.buildReviewPrompt(bridge.allocator);
    defer bridge.allocator.free(review_prompt);
    try pb.appendSlice(bridge.allocator, review_prompt);

    if (bridge.session.cfg.review_config_block) |block| {
        try pb.appendSlice(bridge.allocator, "\n\n");
        try pb.appendSlice(bridge.allocator, block);
        try pb.appendSlice(bridge.allocator, "\n");
    }
    try pb.appendSlice(bridge.allocator, "\n\nFiles/revision to review:");
    for (args) |a| {
        try pb.appendSlice(bridge.allocator, " ");
        try pb.appendSlice(bridge.allocator, a);
    }
    const prompt = try pb.toOwnedSlice(bridge.allocator);
    errdefer bridge.allocator.free(prompt);

    // Enqueue as pending prompt so the next loop iteration submits it.
    if (bridge.pending_prompt.*) |p| bridge.allocator.free(p);
    bridge.pending_prompt.* = prompt;

    const ack = try std.fmt.allocPrint(bridge.allocator, "multi-model review submitted; see results shortly...", .{});
    defer bridge.allocator.free(ack);
    try ctx.output.appendSlice(ctx.allocator, ack);
}

fn interactiveToolsHandler(ctx: *slash_mod.Ctx, _: []const []const u8) slash_mod.Error!void {
    const bridge = bridgeFromCtx(ctx);
    try ctx.output.appendSlice(ctx.allocator, "registered tools:\n");
    for (bridge.session.tools) |t| {
        const line = try std.fmt.allocPrint(ctx.allocator, "  {s} — {s}\n", .{ t.name, t.description });
        defer ctx.allocator.free(line);
        try ctx.output.appendSlice(ctx.allocator, line);
    }
}

fn interactiveToolHandler(ctx: *slash_mod.Ctx, args: []const []const u8) slash_mod.Error!void {
    if (args.len == 0) return slash_mod.Error.ArgRequired;
    const bridge = bridgeFromCtx(ctx);
    const name = args[0];
    for (bridge.session.tools) |t| {
        if (std.mem.eql(u8, t.name, name)) {
            const line = try std.fmt.allocPrint(
                ctx.allocator,
                "{s}\n  description: {s}\n  parameters: {s}\n",
                .{ t.name, t.description, t.parameters_json },
            );
            defer ctx.allocator.free(line);
            try ctx.output.appendSlice(ctx.allocator, line);
            return;
        }
    }
    const msg = try std.fmt.allocPrint(ctx.allocator, "unknown tool: {s}", .{name});
    defer ctx.allocator.free(msg);
    try ctx.output.appendSlice(ctx.allocator, msg);
}

/// v1.29.1 — `/diagnostics` runs the
/// `coding/diagnostics` analyzer over the live transcript and
/// renders the report into `ctx.output`. Mirrors the process in
/// `docs/reference/diagnostics.md` — Layer 1 (Message.diagnostics)
/// always; Layer 4 (HTTP traces) when `--http-trace-dir` is set;
/// Layer 3 (reducer dumps) is interactive-mode-deferred per v1
/// spec §J (no on-disk session).
///
/// v1.29.2 — also persists the rendered report to
/// `<franky_home>/diagnostics/<sid>/<unix_ms>.txt`. Interactive
/// has no real session id; we synthesize
/// `interactive-<startup_ms>` from the binding's startup
/// timestamp so multiple invocations within one run group
/// together. The output stays out of the LLM's transcript by
/// construction — slash commands write to `ctx.output`
/// (scrollback), never to `bridge.session.transcript.messages`.
fn interactiveImproveHandler(ctx: *slash_mod.Ctx, _: []const []const u8) slash_mod.Error!void {
    const bridge = bridgeFromCtx(ctx);
    const cfg = bridge.session.cfg;

    // Resolve $FRANKY_HOME → diagnostics + improvements roots.
    const home_owned = diagnostics_mod.resolveFrankyHome(ctx.allocator, bridge.session.environ_map) catch |e| switch (e) {
        error.OutOfMemory => return slash_mod.Error.OutOfMemory,
    };
    defer if (home_owned) |h| ctx.allocator.free(h);
    const home = home_owned orelse {
        try ctx.output.appendSlice(
            ctx.allocator,
            "/improve: $FRANKY_HOME and $HOME both unset; cannot resolve diagnostics dir.\n",
        );
        return;
    };

    const diag_dir = std.fmt.allocPrint(ctx.allocator, "{s}/diagnostics", .{home}) catch return slash_mod.Error.OutOfMemory;
    defer ctx.allocator.free(diag_dir);
    const imp_root = std.fmt.allocPrint(ctx.allocator, "{s}/improvements", .{home}) catch return slash_mod.Error.OutOfMemory;
    defer ctx.allocator.free(imp_root);

    const result = improvement_mod.runAndPersist(ctx.allocator, bridge.session.io, .{
        .diagnostics_dir = diag_dir,
        .improvements_root = imp_root,
        // Filter to the active session's model — most useful default.
        .model_filter = cfg.model,
        .timestamp_ms = ai.stream.nowMillis(),
    }) catch |e| switch (e) {
        error.OutOfMemory => return slash_mod.Error.OutOfMemory,
        else => {
            const msg = std.fmt.allocPrint(
                ctx.allocator,
                "/improve: failed to run analyzer: {s}\n",
                .{@errorName(e)},
            ) catch return slash_mod.Error.OutOfMemory;
            defer ctx.allocator.free(msg);
            try ctx.output.appendSlice(ctx.allocator, msg);
            return;
        },
    };
    defer result.deinit(ctx.allocator);

    try ctx.output.appendSlice(ctx.allocator, result.rendered);
    if (result.persisted_path) |path| {
        try ctx.output.appendSlice(ctx.allocator, "\nReport saved to: ");
        try ctx.output.appendSlice(ctx.allocator, path);
        try ctx.output.append(ctx.allocator, '\n');
    }
}

fn interactiveSkillsHandler(ctx: *slash_mod.Ctx, _: []const []const u8) slash_mod.Error!void {
    const bridge = bridgeFromCtx(ctx);
    const cfg = bridge.session.cfg;

    const text = skills_mod.buildListingFromMap(
        ctx.allocator,
        bridge.session.io,
        bridge.session.environ_map,
        cfg.skills_path,
        cfg.skills_select_csv,
    ) catch |e| switch (e) {
        error.OutOfMemory => return slash_mod.Error.OutOfMemory,
        else => {
            const msg = std.fmt.allocPrint(
                ctx.allocator,
                "/skills: failed to enumerate skills: {s}\n",
                .{@errorName(e)},
            ) catch return slash_mod.Error.OutOfMemory;
            defer ctx.allocator.free(msg);
            try ctx.output.appendSlice(ctx.allocator, msg);
            return;
        },
    };
    defer ctx.allocator.free(text);
    try ctx.output.appendSlice(ctx.allocator, text);
}

fn interactiveDiagnosticsHandler(ctx: *slash_mod.Ctx, _: []const []const u8) slash_mod.Error!void {
    const bridge = bridgeFromCtx(ctx);
    const cfg = bridge.session.cfg;

    const opts: diagnostics_mod.Options = .{
        .transcript = bridge.session.transcript.messages.items,
        .http_trace_dir = if (cfg.http_trace_dir) |s| (if (s.len > 0) s else null) else null,
        .session_dir = null,
        .session_label = "interactive (in-memory transcript)",
        .mode_name = "interactive",
        .provider = cfg.provider,
        .model = cfg.model,
    };

    // Resolve $FRANKY_HOME / $HOME/.franky for the persist path.
    const home_owned = diagnostics_mod.resolveFrankyHome(ctx.allocator, bridge.session.environ_map) catch |e| switch (e) {
        error.OutOfMemory => return slash_mod.Error.OutOfMemory,
    };
    defer if (home_owned) |h| ctx.allocator.free(h);

    const sid_owned = std.fmt.allocPrint(
        ctx.allocator,
        "interactive-{d}",
        .{bridge.session.startup_ms},
    ) catch |e| switch (e) {
        error.OutOfMemory => return slash_mod.Error.OutOfMemory,
    };
    defer ctx.allocator.free(sid_owned);

    const persist_opts: ?diagnostics_mod.PersistOptions = if (home_owned) |h| .{
        .franky_home = h,
        .session_id = sid_owned,
        .timestamp_ms = ai.stream.nowMillis(),
    } else null;

    const result = diagnostics_mod.runAndPersist(
        ctx.allocator,
        bridge.session.io,
        opts,
        persist_opts,
    ) catch |e| switch (e) {
        error.OutOfMemory => return slash_mod.Error.OutOfMemory,
    };
    defer result.deinit(ctx.allocator);

    try ctx.output.appendSlice(ctx.allocator, result.rendered);
    if (result.persisted_path) |path| {
        try ctx.output.appendSlice(ctx.allocator, "\nReport saved to: ");
        try ctx.output.appendSlice(ctx.allocator, path);
        try ctx.output.append(ctx.allocator, '\n');
    } else {
        try ctx.output.appendSlice(
            ctx.allocator,
            "\n(persist skipped: $FRANKY_HOME and $HOME both unset, or write failed)\n",
        );
    }
}

fn interactiveCostHandler(ctx: *slash_mod.Ctx, _: []const []const u8) slash_mod.Error!void {
    const bridge = bridgeFromCtx(ctx);
    var input_total: u64 = 0;
    var output_total: u64 = 0;
    var turns: u32 = 0;
    for (bridge.session.transcript.messages.items) |m| {
        if (m.role == .assistant) {
            if (m.usage) |u| {
                input_total += u.input;
                output_total += u.output;
                turns += 1;
            }
        }
    }
    const line = try std.fmt.allocPrint(
        ctx.allocator,
        "usage across {d} assistant turns: input={d} tokens, output={d} tokens",
        .{ turns, input_total, output_total },
    );
    defer ctx.allocator.free(line);
    try ctx.output.appendSlice(ctx.allocator, line);
}

fn interactiveCwdHandler(ctx: *slash_mod.Ctx, args: []const []const u8) slash_mod.Error!void {
    const bridge = bridgeFromCtx(ctx);
    if (args.len == 0) {
        const root = if (bridge.session.workspace) |ws| ws.root else "(unset — no PWD on startup)";
        const line = try std.fmt.allocPrint(ctx.allocator, "workspace root: {s}", .{root});
        defer ctx.allocator.free(line);
        try ctx.output.appendSlice(ctx.allocator, line);
        return;
    }
    // Writing a new workspace root safely requires refreshing every
    // tool's canonicalizer — a mid-session re-anchor. Surface a clear
    // "not wired" note rather than silently mutating only one field.
    try ctx.output.appendSlice(
        ctx.allocator,
        "mid-session cwd change not yet wired; restart franky from the target directory",
    );
}

fn interactiveThinkingHandler(ctx: *slash_mod.Ctx, args: []const []const u8) slash_mod.Error!void {
    if (args.len == 0) return slash_mod.Error.ArgRequired;
    const bridge = bridgeFromCtx(ctx);
    const level = ai.types.ThinkingLevel.fromString(args[0]) orelse {
        try ctx.output.appendSlice(ctx.allocator, "unknown thinking level (use off|minimal|low|medium|high|xhigh)");
        return;
    };
    bridge.session.cfg.thinking = level;
    const line = try std.fmt.allocPrint(ctx.allocator, "thinking set to: {s}", .{level.toString()});
    defer ctx.allocator.free(line);
    try ctx.output.appendSlice(ctx.allocator, line);
}

/// Read-only role inspection. Mid-session escalation is intentionally
/// not wired (permission.md): escalation paths are reliable
/// bug surfaces. To change role, restart franky with `--role <name>`.
fn interactiveRoleHandler(ctx: *slash_mod.Ctx, _: []const []const u8) slash_mod.Error!void {
    const bridge = bridgeFromCtx(ctx);
    const gate = bridge.session.role_gate;
    const names = try role_mod.allowedNames(ctx.allocator, gate.set);
    defer ctx.allocator.free(names);

    const sandboxed = role_mod.detectSandboxFromMap(bridge.session.environ_map);

    const header = try std.fmt.allocPrint(
        ctx.allocator,
        "role: {s} — {s}\nsandbox: {s}\nallowed tools:",
        .{ gate.role.toString(), gate.role.shortDescription(), if (sandboxed) "detected" else "none detected" },
    );
    defer ctx.allocator.free(header);
    try ctx.output.appendSlice(ctx.allocator, header);
    for (names) |n| {
        const line = try std.fmt.allocPrint(ctx.allocator, "\n  {s}", .{n});
        defer ctx.allocator.free(line);
        try ctx.output.appendSlice(ctx.allocator, line);
    }
    try ctx.output.appendSlice(
        ctx.allocator,
        "\n(read-only — restart with --role <name> to change)",
    );
}

/// `/permissions` (no args) → status. `/permissions clear` →
/// wipe everything. `/permissions revoke <entry>` → drop one
/// entry (e.g. `bash:git` or `write`). Auto-persists when
/// `--remember-permissions` is on.
fn interactivePermissionsHandler(ctx: *slash_mod.Ctx, args: []const []const u8) slash_mod.Error!void {
    const bridge = bridgeFromCtx(ctx);
    const store = &bridge.session.permission_store;
    const gate_active = bridge.session.session_gates.permissions != null;

    if (args.len == 0) {
        try renderPermissionsStatus(ctx, store, gate_active);
        return;
    }
    const sub = args[0];

    if (std.mem.eql(u8, sub, "clear")) {
        store.clearAll();
        const persisted_hint: []const u8 = if (store.persist_path != null)
            " (persisted file rewritten with empty arrays)"
        else
            "";
        const line = try std.fmt.allocPrint(
            ctx.allocator,
            "permissions: cleared all entries{s}",
            .{persisted_hint},
        );
        defer ctx.allocator.free(line);
        try ctx.output.appendSlice(ctx.allocator, line);
        return;
    }

    if (std.mem.eql(u8, sub, "revoke")) {
        if (args.len < 2) {
            try ctx.output.appendSlice(
                ctx.allocator,
                "usage: /permissions revoke <entry>\n  e.g. write, edit, bash:git, bash:rm",
            );
            return;
        }
        const entry = args[1];
        const removed = store.revoke(entry);
        const verb: []const u8 = if (removed) "removed" else "no entry to remove for";
        const persisted_hint: []const u8 = if (removed and store.persist_path != null)
            " (persisted)"
        else
            "";
        const line = try std.fmt.allocPrint(
            ctx.allocator,
            "permissions: {s} {s}{s}",
            .{ verb, entry, persisted_hint },
        );
        defer ctx.allocator.free(line);
        try ctx.output.appendSlice(ctx.allocator, line);
        return;
    }

    const usage = try std.fmt.allocPrint(
        ctx.allocator,
        "unknown subcommand: {s}\n" ++
            "usage:\n" ++
            "  /permissions             — show status\n" ++
            "  /permissions clear       — wipe all entries\n" ++
            "  /permissions revoke X    — drop one entry (write, bash:git, …)",
        .{sub},
    );
    defer ctx.allocator.free(usage);
    try ctx.output.appendSlice(ctx.allocator, usage);
}

fn renderPermissionsStatus(
    ctx: *slash_mod.Ctx,
    store: *const permissions_mod.Store,
    gate_active: bool,
) slash_mod.Error!void {
    const allocator = ctx.allocator;

    const header = try std.fmt.allocPrint(
        allocator,
        "permissions overlay:\n  enabled:  {s}\n  default:  read/ls/find/grep auto-allow; write/edit/bash ask",
        .{if (gate_active) "yes (--prompts)" else "no (omit --prompts to enable)"},
    );
    defer allocator.free(header);
    try ctx.output.appendSlice(allocator, header);

    try appendSetLine(ctx, "allow (tools)", &store.allow_tools);
    try appendSetLine(ctx, "deny  (tools)", &store.deny_tools);
    try appendSetLine(ctx, "ask   (tools)", &store.ask_tools);
    try appendSetLine(ctx, "allow (bash)", &store.allow_bash);
    try appendSetLine(ctx, "deny  (bash)", &store.deny_bash);
    try appendSetLine(ctx, "ask   (bash)", &store.ask_bash);

    const flags = try std.fmt.allocPrint(
        allocator,
        "\n  yes_to_all: {s}\n  ask_all:    {s}",
        .{
            if (store.yes_to_all) "yes" else "no",
            if (store.ask_all) "yes" else "no",
        },
    );
    defer allocator.free(flags);
    try ctx.output.appendSlice(allocator, flags);

    if (store.persist_path) |p| {
        const persisted = try std.fmt.allocPrint(
            allocator,
            "\n  persisted: {s} ({d} entries)",
            .{ p, store.entryCount() },
        );
        defer allocator.free(persisted);
        try ctx.output.appendSlice(allocator, persisted);
    } else {
        try ctx.output.appendSlice(allocator,
            "\n  persisted: no (start with --remember-permissions to enable)");
    }

    try ctx.output.appendSlice(
        allocator,
        "\n\nuse `/permissions clear` or `/permissions revoke <entry>` to mutate.",
    );
}

fn appendSetLine(
    ctx: *slash_mod.Ctx,
    label: []const u8,
    set: *const std.StringHashMapUnmanaged(void),
) slash_mod.Error!void {
    const allocator = ctx.allocator;
    if (set.count() == 0) {
        const line = try std.fmt.allocPrint(allocator, "\n  {s}: (empty)", .{label});
        defer allocator.free(line);
        try ctx.output.appendSlice(allocator, line);
        return;
    }
    // Sort keys for stable display.
    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(allocator);
    var it = set.keyIterator();
    while (it.next()) |k| try keys.append(allocator, k.*);
    std.mem.sort([]const u8, keys.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    const head = try std.fmt.allocPrint(allocator, "\n  {s}: ", .{label});
    defer allocator.free(head);
    try ctx.output.appendSlice(allocator, head);
    for (keys.items, 0..) |k, i| {
        if (i > 0) try ctx.output.appendSlice(allocator, ", ");
        try ctx.output.appendSlice(allocator, k);
    }
}

fn interactiveRetryHandler(ctx: *slash_mod.Ctx, _: []const []const u8) slash_mod.Error!void {
    const bridge = bridgeFromCtx(ctx);
    // Walk back to the most recent .user message; re-submit its text.
    var i = bridge.session.transcript.messages.items.len;
    while (i > 0) {
        i -= 1;
        const m = bridge.session.transcript.messages.items[i];
        if (m.role == .user) {
            if (m.content.len > 0) switch (m.content[0]) {
                .text => |t| {
                    if (bridge.pending_prompt.*) |p| bridge.allocator.free(p);
                    bridge.pending_prompt.* = try bridge.allocator.dupe(u8, t.text);
                    try ctx.output.appendSlice(ctx.allocator, "re-submitting last user turn");
                    return;
                },
                else => {},
            };
        }
    }
    try ctx.output.appendSlice(ctx.allocator, "no prior user turn to retry");
}

fn interactiveEditHandler(ctx: *slash_mod.Ctx, args: []const []const u8) slash_mod.Error!void {
    if (args.len == 0) {
        try ctx.output.appendSlice(
            ctx.allocator,
            "usage: /edit <new text> (rewrites the most recent user message)",
        );
        return;
    }
    const bridge = bridgeFromCtx(ctx);
    // Stitch args back into a single prompt with single spaces.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(ctx.allocator);
    for (args, 0..) |a, idx| {
        if (idx > 0) try buf.append(ctx.allocator, ' ');
        try buf.appendSlice(ctx.allocator, a);
    }
    const new_text = try ctx.allocator.dupe(u8, buf.items);
    defer ctx.allocator.free(new_text);

    // Find and replace the last user message's first text block.
    var i = bridge.session.transcript.messages.items.len;
    while (i > 0) {
        i -= 1;
        const m = &bridge.session.transcript.messages.items[i];
        if (m.role == .user and m.content.len > 0) switch (m.content[0]) {
            .text => |*t| {
                bridge.allocator.free(t.text);
                t.text = try bridge.allocator.dupe(u8, new_text);
                // Re-submit so the model sees the replacement.
                if (bridge.pending_prompt.*) |p| bridge.allocator.free(p);
                bridge.pending_prompt.* = try bridge.allocator.dupe(u8, new_text);
                try ctx.output.appendSlice(ctx.allocator, "last user message edited; re-submitting");
                return;
            },
            else => {},
        };
    }
    try ctx.output.appendSlice(ctx.allocator, "no prior user turn to edit");
}

fn interactiveExportHandler(ctx: *slash_mod.Ctx, args: []const []const u8) slash_mod.Error!void {
    const fmt = if (args.len > 0) args[0] else "markdown";
    const bridge = bridgeFromCtx(ctx);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(ctx.allocator);

    if (std.ascii.eqlIgnoreCase(fmt, "markdown") or std.ascii.eqlIgnoreCase(fmt, "md")) {
        for (bridge.session.transcript.messages.items, 0..) |m, i| {
            if (i > 0) try buf.append(ctx.allocator, '\n');
            const header = try std.fmt.allocPrint(ctx.allocator, "### {s}\n\n", .{@tagName(m.role)});
            defer ctx.allocator.free(header);
            try buf.appendSlice(ctx.allocator, header);
            for (m.content) |cb| switch (cb) {
                .text => |t| {
                    try buf.appendSlice(ctx.allocator, t.text);
                    try buf.append(ctx.allocator, '\n');
                },
                .tool_call => |tc| {
                    const line = try std.fmt.allocPrint(ctx.allocator, "`[tool: {s}({s})]`\n", .{ tc.name, tc.arguments_json });
                    defer ctx.allocator.free(line);
                    try buf.appendSlice(ctx.allocator, line);
                },
                else => {},
            };
        }
    } else if (std.ascii.eqlIgnoreCase(fmt, "json")) {
        // Thin JSON: list of {role,text} records. Full transcript
        // serialization already lives in `session_mod.writeTranscript`;
        // this is a user-visible preview suitable for copy-paste.
        try buf.appendSlice(ctx.allocator, "[\n");
        for (bridge.session.transcript.messages.items, 0..) |m, i| {
            if (i > 0) try buf.appendSlice(ctx.allocator, ",\n");
            const role_s = @tagName(m.role);
            var text: []const u8 = "";
            for (m.content) |cb| switch (cb) {
                .text => |t| {
                    text = t.text;
                    break;
                },
                else => {},
            };
            const line = try std.fmt.allocPrint(ctx.allocator, "  {{\"role\":\"{s}\",\"text\":", .{role_s});
            defer ctx.allocator.free(line);
            try buf.appendSlice(ctx.allocator, line);
            try appendJsonEscaped(&buf, ctx.allocator, text);
            try buf.appendSlice(ctx.allocator, "}");
        }
        try buf.appendSlice(ctx.allocator, "\n]\n");
    } else {
        const msg = try std.fmt.allocPrint(ctx.allocator, "unknown format: {s} (use markdown or json)", .{fmt});
        defer ctx.allocator.free(msg);
        try ctx.output.appendSlice(ctx.allocator, msg);
        return;
    }

    // Write to a tempfile in /tmp and surface the path.
    const path = try std.fmt.allocPrint(ctx.allocator, "/tmp/franky-export-{d}.{s}", .{
        ai.stream.nowMillis(),
        if (std.ascii.eqlIgnoreCase(fmt, "json")) "json" else "md",
    });
    defer ctx.allocator.free(path);
    const cwd = std.Io.Dir.cwd();
    var f = cwd.createFile(bridge.io, path, .{}) catch {
        try ctx.output.appendSlice(ctx.allocator, "export write failed");
        return;
    };
    defer f.close(bridge.io);
    f.writeStreamingAll(bridge.io, buf.items) catch {
        try ctx.output.appendSlice(ctx.allocator, "export write failed");
        return;
    };
    const ack = try std.fmt.allocPrint(ctx.allocator, "transcript exported to {s}", .{path});
    defer ctx.allocator.free(ack);
    try ctx.output.appendSlice(ctx.allocator, ack);
}

fn appendJsonEscaped(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
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

fn interactiveCompactHandler(ctx: *slash_mod.Ctx, _: []const []const u8) slash_mod.Error!void {
    const bridge = bridgeFromCtx(ctx);

    // Compaction needs a Tree; interactive mode doesn't yet carry a
    // persistent session-scoped Tree, so we build a throwaway one
    // just for the checkpoint step. The branch survives in-memory
    // for the duration of this REPL session; tree persistence across
    // restarts is a v1.6 follow-up.
    var tree = branching_mod.Tree.init(bridge.allocator) catch {
        try ctx.output.appendSlice(ctx.allocator, "compact: tree init failed");
        return;
    };
    defer tree.deinit();
    const len = bridge.session.transcript.messages.items.len;
    var i: u32 = 0;
    while (i < len) : (i += 1) tree.appendOnActive(null) catch {};

    const pinned = bridge.allocator.alloc(bool, len) catch {
        try ctx.output.appendSlice(ctx.allocator, "compact: alloc failed");
        return;
    };
    defer bridge.allocator.free(pinned);
    @memset(pinned, false);

    var cancel: ai.stream.Cancel = .{};
    const result = compaction_mod.run(bridge.allocator, bridge.io, &bridge.session.transcript, &tree, .{
        .model = bridge.session.modelType(),
        .registry = &bridge.session.registry,
        .stream_options = .{ .cancel = &cancel },
        .pinned = pinned,
        .timestamp_ms = ai.stream.nowMillis(),
        .cancel = &cancel,
    }) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "compact failed: {s}", .{@errorName(err)});
        defer ctx.allocator.free(msg);
        try ctx.output.appendSlice(ctx.allocator, msg);
        return;
    };
    if (!result.proceeded) {
        try ctx.output.appendSlice(ctx.allocator, "compact: span too short; nothing to do");
        return;
    }
    const msg = try std.fmt.allocPrint(ctx.allocator, "compacted {d} messages → 1 summary", .{result.replaced_count});
    defer ctx.allocator.free(msg);
    try ctx.output.appendSlice(ctx.allocator, msg);
}

fn interactiveBranchHandler(ctx: *slash_mod.Ctx, args: []const []const u8) slash_mod.Error!void {
    if (args.len == 0) return slash_mod.Error.ArgRequired;
    const bridge = bridgeFromCtx(ctx);
    const name = args[0];
    const msg_count: u32 = @intCast(bridge.session.transcript.messages.items.len);
    bridge.session.tree.fork(name, bridge.session.tree.active, msg_count) catch |err| {
        const msg = switch (err) {
            error.BranchExists => try std.fmt.allocPrint(ctx.allocator, "branch '{s}' already exists", .{name}),
            else => try std.fmt.allocPrint(ctx.allocator, "branch failed: {s}", .{@errorName(err)}),
        };
        defer ctx.allocator.free(msg);
        try ctx.output.appendSlice(ctx.allocator, msg);
        return;
    };
    const ok = try std.fmt.allocPrint(
        ctx.allocator,
        "forked '{s}' at message {d} (parent: {s})",
        .{ name, msg_count, bridge.session.tree.active },
    );
    defer ctx.allocator.free(ok);
    try ctx.output.appendSlice(ctx.allocator, ok);
}

fn interactiveBranchesHandler(ctx: *slash_mod.Ctx, _: []const []const u8) slash_mod.Error!void {
    const bridge = bridgeFromCtx(ctx);
    try ctx.output.appendSlice(ctx.allocator, "branches:\n");
    var it = bridge.session.tree.branches.iterator();
    while (it.next()) |entry| {
        const b = entry.value_ptr.*;
        const marker: []const u8 = if (std.mem.eql(u8, b.name, bridge.session.tree.active)) "* " else "  ";
        const parent_str = b.parent orelse "—";
        const line = try std.fmt.allocPrint(
            ctx.allocator,
            "{s}{s}  (parent: {s}, fork_index: {d}, messages: {d})\n",
            .{ marker, b.name, parent_str, b.fork_index, b.message_count },
        );
        defer ctx.allocator.free(line);
        try ctx.output.appendSlice(ctx.allocator, line);
    }
}

fn interactiveCheckoutHandler(ctx: *slash_mod.Ctx, args: []const []const u8) slash_mod.Error!void {
    if (args.len == 0) return slash_mod.Error.ArgRequired;
    const bridge = bridgeFromCtx(ctx);
    const name = args[0];
    bridge.session.tree.switchTo(name) catch {
        const msg = try std.fmt.allocPrint(ctx.allocator, "no such branch: {s}", .{name});
        defer ctx.allocator.free(msg);
        try ctx.output.appendSlice(ctx.allocator, msg);
        return;
    };
    const ok = try std.fmt.allocPrint(
        ctx.allocator,
        "switched to branch '{s}' (note: transcript not re-materialized — per-branch transcript swap is v1.7)",
        .{name},
    );
    defer ctx.allocator.free(ok);
    try ctx.output.appendSlice(ctx.allocator, ok);
}

// ─── buffer resize helper ───────────────────────────────────────

// `tui.buffer.Buffer` doesn't ship a resize method today; we
// re-init it in place. Keeping the helper here keeps the interactive
// module self-contained without loosening the buffer's invariants.
fn bufferResize(
    self: *tui.buffer.Buffer,
    allocator: std.mem.Allocator,
    rows: u32,
    cols: u32,
) !void {
    self.deinit();
    self.* = try tui.buffer.Buffer.init(allocator, rows, cols);
}

// ─── small IO helpers ──────────────────────────────────────────

/// Thin `writeAll` adapter so the `DiffRenderer` (anytype writer)
/// can emit bytes straight through `std.Io.File`. Uses
/// `writeStreamingAll` so the same code path lights up on every
/// target (Linux: direct write syscall; macOS: libc write through
/// the Io vtable; Windows: WriteFile). Earlier versions of this
/// struct held a raw fd and called `std.os.linux.write` directly
/// — that was silently a no-op on macOS, which is why the REPL
/// screen stayed blank there. See https://github.com/… notes.
const FdWriter = struct {
    file: std.Io.File,
    io: std.Io,
    pub fn writeAll(self: *FdWriter, bytes: []const u8) !void {
        try self.file.writeStreamingAll(self.io, bytes);
    }
};

fn writeAllFile(io: std.Io, file: std.Io.File, bytes: []const u8) void {
    file.writeStreamingAll(io, bytes) catch {};
}

fn writeStderr(io: std.Io, s: []const u8) !void {
    var buf: [1024]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    w.interface.writeAll(s) catch {};
    w.interface.flush() catch {};
}

// ─── tests ────────────────────────────────────────────────────

const testing = std.testing;

test "Scrollback drops oldest line when capacity is reached" {
    var sb = Scrollback.init(testing.allocator);
    defer sb.deinit();
    sb.capacity = 3;
    try sb.appendLine(try testing.allocator.dupe(u8, "one"));
    try sb.appendLine(try testing.allocator.dupe(u8, "two"));
    try sb.appendLine(try testing.allocator.dupe(u8, "three"));
    try sb.appendLine(try testing.allocator.dupe(u8, "four"));
    try testing.expectEqual(@as(usize, 3), sb.lines.items.len);
    try testing.expectEqualStrings("two", sb.lines.items[0]);
    try testing.expectEqualStrings("four", sb.lines.items[2]);
}

test "paintFrame places the prompt marker and editor glyphs at the bottom" {
    const gpa = testing.allocator;
    var buf = try tui.buffer.Buffer.init(gpa, 5, 20);
    defer buf.deinit();
    var sb = Scrollback.init(gpa);
    defer sb.deinit();
    try sb.appendLine(try gpa.dupe(u8, "hello"));

    var ed = tui.editor.Editor.init(gpa);
    defer ed.deinit();
    try ed.buffer.setText("hi");

    paintFrame(&buf, &sb, &ed, .{ .status = "ready" });

    // Transcript: row 0 shows 'hello'.
    try testing.expectEqual(@as(u21, 'h'), buf.get(0, 0).codepoint);
    try testing.expectEqual(@as(u21, 'l'), buf.get(0, 3).codepoint);

    // Status row (row 3) has reverse-video fill.
    try testing.expect(buf.get(3, 0).style.reverse);

    // Editor row (row 4): prompt marker then editor content.
    try testing.expectEqual(@as(u21, 0x203A), buf.get(4, 0).codepoint); // '›'
    try testing.expectEqual(@as(u21, 'h'), buf.get(4, 2).codepoint);
    try testing.expectEqual(@as(u21, 'i'), buf.get(4, 3).codepoint);
}

// ─── v1.5.5 — history, multi-line, palette tests ───────────────

test "PromptHistory: push coalesces consecutive duplicates" {
    var h = PromptHistory.init(testing.allocator);
    defer h.deinit();
    try h.push("hello");
    try h.push("hello"); // should coalesce
    try h.push("world");
    try testing.expectEqual(@as(usize, 2), h.entries.items.len);
    try testing.expectEqualStrings("hello", h.entries.items[0]);
    try testing.expectEqualStrings("world", h.entries.items[1]);
}

test "PromptHistory: prev walks back, next walks forward and restores draft" {
    var h = PromptHistory.init(testing.allocator);
    defer h.deinit();
    try h.push("one");
    try h.push("two");
    try h.push("three");

    const a = (try h.prev("draft-in-progress")).?;
    try testing.expectEqualStrings("three", a);
    const b = (try h.prev("draft-in-progress")).?;
    try testing.expectEqualStrings("two", b);
    const c = h.next().?;
    try testing.expectEqualStrings("three", c);
    const d = h.next().?;
    // Stepped past newest → draft restored.
    try testing.expectEqualStrings("draft-in-progress", d);
    // Cursor cleared.
    try testing.expectEqual(@as(?usize, null), h.cursor);
}

test "PromptHistory: prev on empty ring returns null" {
    var h = PromptHistory.init(testing.allocator);
    defer h.deinit();
    try testing.expect((try h.prev("")) == null);
}

test "computeSlashHint: slash + partial name lists matches" {
    const gpa = testing.allocator;
    var reg = slash_mod.Registry.init(gpa);
    defer reg.deinit();
    try reg.register(.{ .name = "help", .description = "", .handler = slash_mod.helpHandler });
    try reg.register(.{ .name = "clear", .description = "", .handler = slash_mod.clearHandler });
    try reg.register(.{ .name = "compact", .description = "", .handler = slash_mod.clearHandler });

    const hint = (try computeSlashHint(gpa, &reg, "/c")).?;
    defer gpa.free(hint);
    try testing.expect(std.mem.indexOf(u8, hint, "/clear") != null);
    try testing.expect(std.mem.indexOf(u8, hint, "/compact") != null);
    // '/help' doesn't start with 'c' → not listed.
    try testing.expect(std.mem.indexOf(u8, hint, "/help") == null);
}

test "computeSlashHint: non-slash input returns null" {
    const gpa = testing.allocator;
    var reg = slash_mod.Registry.init(gpa);
    defer reg.deinit();
    try reg.register(.{ .name = "help", .description = "", .handler = slash_mod.helpHandler });
    try testing.expect((try computeSlashHint(gpa, &reg, "hello")) == null);
    // Line with a space is past the command name — palette hides.
    try testing.expect((try computeSlashHint(gpa, &reg, "/help ")) == null);
}

test "completeSlash: unique match completes with trailing space" {
    const gpa = testing.allocator;
    var reg = slash_mod.Registry.init(gpa);
    defer reg.deinit();
    try reg.register(.{ .name = "compact", .description = "", .handler = slash_mod.clearHandler });

    const out = (try completeSlash(gpa, &reg, "/com")).?;
    defer gpa.free(out);
    try testing.expectEqualStrings("/compact ", out);
}

test "completeSlash: multiple matches advance to longest common prefix" {
    const gpa = testing.allocator;
    var reg = slash_mod.Registry.init(gpa);
    defer reg.deinit();
    try reg.register(.{ .name = "compact", .description = "", .handler = slash_mod.clearHandler });
    try reg.register(.{ .name = "compose", .description = "", .handler = slash_mod.clearHandler });

    const out = (try completeSlash(gpa, &reg, "/co")).?;
    defer gpa.free(out);
    // `compact` and `compose` share `comp`.
    try testing.expectEqualStrings("/comp", out);
}

test "Editor: multi-line lineCount + cursorRow/Column" {
    const gpa = testing.allocator;
    var ed = tui.editor.Editor.init(gpa);
    defer ed.deinit();
    try ed.setText("hi\nthere\nyou");
    try testing.expectEqual(@as(u32, 3), ed.lineCount());
    // Cursor lands at end of buffer after setText.
    try testing.expectEqual(@as(u32, 2), ed.cursorRow());
    try testing.expectEqual(@as(u32, 3), ed.cursorColumn()); // "you" = 3 cells
}

// ─── v1.1.2 — transcript search tests ─────────────────────────

test "containsCaseInsensitive: basic + case + empty + no-match" {
    try testing.expect(containsCaseInsensitive("Hello World", "world"));
    try testing.expect(containsCaseInsensitive("Hello World", "WORLD"));
    try testing.expect(containsCaseInsensitive("Hello World", ""));
    try testing.expect(!containsCaseInsensitive("Hello World", "foo"));
    try testing.expect(!containsCaseInsensitive("abc", "abcd"));
}

test "SearchState.recompute: matches lines that contain the query" {
    const gpa = testing.allocator;
    var s = SearchState.init(gpa);
    defer s.deinit();
    try s.query.appendSlice(gpa, "error");
    const lines = [_][]const u8{
        "hello world",
        "got an ERROR here",
        "more logs",
        "another error at end",
    };
    try s.recompute(&lines);
    try testing.expectEqual(@as(usize, 2), s.matches.items.len);
    try testing.expectEqual(@as(usize, 1), s.matches.items[0]);
    try testing.expectEqual(@as(usize, 3), s.matches.items[1]);
    try testing.expectEqual(@as(?usize, 0), s.current_match);
}

test "SearchState.recompute: empty query clears matches" {
    const gpa = testing.allocator;
    var s = SearchState.init(gpa);
    defer s.deinit();
    try s.query.appendSlice(gpa, "x");
    const lines = [_][]const u8{"hello"};
    try s.recompute(&lines);
    try testing.expectEqual(@as(usize, 0), s.matches.items.len);

    // Now clear the query and recompute — no matches + no current.
    s.query.clearRetainingCapacity();
    try s.recompute(&lines);
    try testing.expectEqual(@as(?usize, null), s.current_match);
}

test "paintHelpOverlay: renders title + both columns" {
    const gpa = testing.allocator;
    var buf = try tui.buffer.Buffer.init(gpa, 20, 80);
    defer buf.deinit();

    paintHelpOverlay(&buf, false);

    // Title at row 0 col 1.
    try testing.expectEqual(@as(u21, 'f'), buf.get(0, 1).codepoint);
    try testing.expectEqual(@as(u21, 'r'), buf.get(0, 2).codepoint);
    // Header "Keybindings" at row 2 col 2.
    try testing.expectEqual(@as(u21, 'K'), buf.get(2, 2).codepoint);
    // "Slash commands" header on the same row, right column.
    const right_col: u32 = 80 / 2 + 1;
    try testing.expectEqual(@as(u21, 'S'), buf.get(2, right_col).codepoint);
}

test "paintHelpOverlay: NO_COLOR strips fg on header styles" {
    const gpa = testing.allocator;
    var buf = try tui.buffer.Buffer.init(gpa, 10, 60);
    defer buf.deinit();

    paintHelpOverlay(&buf, true);
    // Title cell — reverse-video SGR stays, but fg/bg are default.
    const title_cell = buf.get(0, 1);
    try testing.expect(title_cell.style.fg == .default);
    try testing.expect(title_cell.style.bg == .default);
}

test "Scrollback.appendStyledLine: stores a parallel style per line" {
    const gpa = testing.allocator;
    var sb = Scrollback.init(gpa);
    defer sb.deinit();

    try sb.appendLine(try gpa.dupe(u8, "normal"));
    try sb.appendStyledLine(
        try gpa.dupe(u8, "✗ error: boom"),
        .{ .fg = .{ .basic = .red }, .bold = true },
    );
    try sb.appendLine(try gpa.dupe(u8, "another normal"));

    try testing.expectEqual(@as(usize, 3), sb.lines.items.len);
    try testing.expectEqual(@as(usize, 3), sb.styles.items.len);
    try testing.expect(sb.styles.items[0].fg == .default);
    try testing.expect(sb.styles.items[1].fg != .default);
    try testing.expect(sb.styles.items[1].bold);
    try testing.expect(sb.styles.items[2].fg == .default);
}

test "paintFrame: error style paints red + bold; NO_COLOR strips fg" {
    const gpa = testing.allocator;
    var buf = try tui.buffer.Buffer.init(gpa, 5, 30);
    defer buf.deinit();
    var sb = Scrollback.init(gpa);
    defer sb.deinit();
    try sb.appendStyledLine(
        try gpa.dupe(u8, "✗ error: boom"),
        .{ .fg = .{ .basic = .red }, .bold = true },
    );

    var ed = tui.editor.Editor.init(gpa);
    defer ed.deinit();

    // no_color=false: fg stays red, bold stays on.
    paintFrame(&buf, &sb, &ed, .{ .status = "ready", .palette = null, .scroll_offset = 0, .search_query = null, .no_color = false });
    const colored = buf.get(0, 0);
    try testing.expect(colored.style.fg != .default);
    try testing.expect(colored.style.bold);

    // no_color=true: fg flattens to default, bold survives.
    paintFrame(&buf, &sb, &ed, .{ .status = "ready", .palette = null, .scroll_offset = 0, .search_query = null, .no_color = true });
    const neutral = buf.get(0, 0);
    try testing.expect(neutral.style.fg == .default);
    try testing.expect(neutral.style.bold);
}

test "paintFrame: search_query highlights matching lines in reverse-video" {
    const gpa = testing.allocator;
    var buf = try tui.buffer.Buffer.init(gpa, 5, 20);
    defer buf.deinit();
    var sb = Scrollback.init(gpa);
    defer sb.deinit();
    try sb.appendLine(try gpa.dupe(u8, "hello"));
    try sb.appendLine(try gpa.dupe(u8, "an error happened"));
    try sb.appendLine(try gpa.dupe(u8, "more text"));

    var ed = tui.editor.Editor.init(gpa);
    defer ed.deinit();
    paintFrame(&buf, &sb, &ed, .{ .status = "find: error", .palette = null, .scroll_offset = 0, .search_query = "error", .no_color = false });

    // Row 0: "hello" (no match → normal style).
    try testing.expect(!buf.get(0, 0).style.reverse);
    // Row 1: "an error happened" (match → reverse).
    try testing.expect(buf.get(1, 0).style.reverse);
    // Row 2: "more text" (no match).
    try testing.expect(!buf.get(2, 0).style.reverse);
}

// ─── v1.1.1 — scrollable transcript tests ─────────────────────

test "paintFrame: scroll_offset=0 paints the tail (regression check)" {
    const gpa = testing.allocator;
    var buf = try tui.buffer.Buffer.init(gpa, 5, 20);
    defer buf.deinit();
    var sb = Scrollback.init(gpa);
    defer sb.deinit();
    // 5 lines, only 3 rows of transcript → shows lines 2, 3, 4.
    for (0..5) |i| {
        const line = try std.fmt.allocPrint(gpa, "line-{d}", .{i});
        try sb.appendLine(line);
    }

    var ed = tui.editor.Editor.init(gpa);
    defer ed.deinit();
    paintFrame(&buf, &sb, &ed, .{ .status = "ready", .palette = null, .scroll_offset = 0 });

    // Transcript rows 0..2 (rows reserved: transcript=3, status=1, editor=1).
    // offset=0 → last 3 of 5: line-2, line-3, line-4.
    try testing.expectEqual(@as(u21, '2'), buf.get(0, 5).codepoint);
    try testing.expectEqual(@as(u21, '3'), buf.get(1, 5).codepoint);
    try testing.expectEqual(@as(u21, '4'), buf.get(2, 5).codepoint);
}

test "paintFrame: scroll_offset=2 walks the window 2 lines backwards" {
    const gpa = testing.allocator;
    var buf = try tui.buffer.Buffer.init(gpa, 5, 20);
    defer buf.deinit();
    var sb = Scrollback.init(gpa);
    defer sb.deinit();
    for (0..5) |i| {
        const line = try std.fmt.allocPrint(gpa, "line-{d}", .{i});
        try sb.appendLine(line);
    }

    var ed = tui.editor.Editor.init(gpa);
    defer ed.deinit();
    paintFrame(&buf, &sb, &ed, .{ .status = "scrolled", .palette = null, .scroll_offset = 2 });

    // offset=2 → end=3 → slice [0..3] → line-0, line-1, line-2.
    try testing.expectEqual(@as(u21, '0'), buf.get(0, 5).codepoint);
    try testing.expectEqual(@as(u21, '1'), buf.get(1, 5).codepoint);
    try testing.expectEqual(@as(u21, '2'), buf.get(2, 5).codepoint);
}

test "paintFrame: scroll_offset clamps to scrollback length" {
    const gpa = testing.allocator;
    var buf = try tui.buffer.Buffer.init(gpa, 5, 20);
    defer buf.deinit();
    var sb = Scrollback.init(gpa);
    defer sb.deinit();
    for (0..5) |i| {
        const line = try std.fmt.allocPrint(gpa, "line-{d}", .{i});
        try sb.appendLine(line);
    }

    var ed = tui.editor.Editor.init(gpa);
    defer ed.deinit();
    // offset=999 — far past the top. Expect: paint nothing (end=0 → slice empty).
    paintFrame(&buf, &sb, &ed, .{ .status = "top", .palette = null, .scroll_offset = 999 });

    // Rows 0..2 should have no transcript digit painted — the
    // cells remain as blank (space = 0x20) set by `buf.clear`.
    const c0 = buf.get(0, 5).codepoint;
    const c1 = buf.get(1, 5).codepoint;
    try testing.expect(c0 != '0' and c0 != '1' and c0 != '2' and c0 != '3' and c0 != '4');
    try testing.expect(c1 != '0' and c1 != '1' and c1 != '2' and c1 != '3' and c1 != '4');
}

test "paintFrame: multi-line editor grows the editor region down" {
    const gpa = testing.allocator;
    var buf = try tui.buffer.Buffer.init(gpa, 10, 20);
    defer buf.deinit();
    var sb = Scrollback.init(gpa);
    defer sb.deinit();

    var ed = tui.editor.Editor.init(gpa);
    defer ed.deinit();
    try ed.setText("line1\nline2\nline3");

    paintFrame(&buf, &sb, &ed, .{ .status = "ready" });

    // Editor now takes 3 rows (capped at rows/3 = 3). So first
    // editor row is at rows - 3 = 7. Prompt marker on row 7.
    try testing.expectEqual(@as(u21, 0x203A), buf.get(7, 0).codepoint);
    // Lines 2 and 3 on rows 8 and 9.
    try testing.expectEqual(@as(u21, 'l'), buf.get(8, 2).codepoint);
    try testing.expectEqual(@as(u21, '2'), buf.get(8, 6).codepoint);
    try testing.expectEqual(@as(u21, 'l'), buf.get(9, 2).codepoint);
    try testing.expectEqual(@as(u21, '3'), buf.get(9, 6).codepoint);
}

// ─── v1.11.2 — permission-prompt modal ────────────────────────────

test "modalKeyResolution: a/A/d/D map to the four resolutions" {
    try testing.expectEqual(permissions_mod.Resolution.allow_once, modalKeyResolution(.{ .char = .{ .cp = 'a' } }).?);
    try testing.expectEqual(permissions_mod.Resolution.always_allow, modalKeyResolution(.{ .char = .{ .cp = 'A' } }).?);
    try testing.expectEqual(permissions_mod.Resolution.deny_once, modalKeyResolution(.{ .char = .{ .cp = 'd' } }).?);
    try testing.expectEqual(permissions_mod.Resolution.always_deny, modalKeyResolution(.{ .char = .{ .cp = 'D' } }).?);
}

test "modalKeyResolution: Esc resolves as deny_once (cancel = deny)" {
    try testing.expectEqual(permissions_mod.Resolution.deny_once, modalKeyResolution(.escape).?);
}

test "modalKeyResolution: unrelated keys return null (no-op)" {
    try testing.expect(modalKeyResolution(.enter) == null);
    try testing.expect(modalKeyResolution(.{ .char = .{ .cp = 'x' } }) == null);
    try testing.expect(modalKeyResolution(.up) == null);
    try testing.expect(modalKeyResolution(.tab) == null);
}

test "ModalState.arm/clear: round-trip frees owned strings" {
    const gpa = testing.allocator;
    var m: ModalState = .{};
    defer m.deinit(gpa);

    try m.arm(gpa, "c1", "bash", "{\"command\":\"git status\"}", "git");
    try testing.expect(m.active);
    try testing.expectEqualStrings("c1", m.call_id);
    try testing.expectEqualStrings("bash", m.tool_name);
    try testing.expectEqualStrings("git", m.fingerprint);

    m.clear(gpa);
    try testing.expect(!m.active);
    try testing.expectEqual(@as(usize, 0), m.call_id.len);
}

test "ModalState.arm: re-arming releases previous strings (no leak)" {
    const gpa = testing.allocator;
    var m: ModalState = .{};
    defer m.deinit(gpa);

    try m.arm(gpa, "c1", "bash", "{}", "git");
    // Re-arm with a different call (e.g. previous resolve was lost
    // and a fresh request landed). The first arm's strings must be
    // freed by `arm` itself or the gpa's leak detector trips.
    try m.arm(gpa, "c2", "write", "{\"path\":\"x\"}", "write");
    try testing.expectEqualStrings("c2", m.call_id);
    try testing.expectEqualStrings("write", m.tool_name);
}

test "argsPreviewSlice: short input returns whole, long input truncates" {
    try testing.expectEqualStrings("{}", argsPreviewSlice("{}"));
    var long_buf: [200]u8 = @splat('x');
    const long: []const u8 = long_buf[0..];
    const preview = argsPreviewSlice(long);
    try testing.expectEqual(@as(usize, 160), preview.len);
}
