//! `zig build profile -- [options]` — drive perf + heaptrack + inferno
//! against the FP-preserved test binaries to produce CPU and memory
//! flamegraphs. Spec: docs/spec/v2.md §8. Long-form how-to:
//! docs/archive/profiling_guide.md (archived; the perf / heaptrack
//! mechanics this binary wraps haven't moved).
//!
//! Run:
//!
//!   zig build profile                                                # CPU + 5-cost mem against franky-test
//!   zig build profile -- --binary franky-agent_loop_test             # different binary
//!   zig build profile -Dprofile-filter=parallel -- --mode cpu        # narrowed, CPU only
//!   zig build profile -- --check                                     # verify tools, exit
//!   zig build profile -- --list                                      # list installed test binaries
//!
//! Note on filtering: Zig 0.17's standalone test binary does not
//! accept --test-filter at runtime, so test narrowing happens at
//! build time via `-Dprofile-filter=PATTERN` (repeatable).
//!
//! The driver is intentionally a thin wrapper around the manual
//! perf / heaptrack commands. When something doesn't look right,
//! drop down to those commands by hand — the archived guide
//! documents the full pipeline.

const std = @import("std");
const franky = @import("franky");

const test_binaries = [_][]const u8{
    "franky-test",
    "franky-agent_loop_test",
    "franky-agent_class_test",
    "franky-gitignore_test",
    "franky-parallel_tools_test",
    "franky-kitchen_sink_test",
    "franky-replay_test",
};

// `heaptrack_print --flamegraph-cost-type` dimensions. heaptrack 1.5
// only accepts these four — see `heaptrack_print --help`. Spec
// §8.4 explains what each one tells you.
const memory_costs = [_][]const u8{
    "peak",
    "leaked",
    "allocations",
    "temporary",
};

const usage =
    \\usage: zig build profile -- [options]
    \\
    \\options:
    \\  --binary NAME        Test binary under zig-out/bin/ to profile.
    \\                       Default: franky-test. The `franky-` prefix
    \\                       is optional. See --list for available names.
    \\  --mode MODE          cpu | mem | both. Default: both.
    \\  --out-dir PATH       Output directory. Default:
    \\                       zig-out/profile/<binary>/<unix_ms>.
    \\  --freq HZ            perf sampling frequency. Default: 997
    \\                       (prime, avoids aliasing with timer interrupts).
    \\  --call-graph MODE    fp | dwarf. Default: fp (cheap; needs the
    \\                       test-profile FP-preserved build, which is
    \\                       the default for `zig build test-profile`).
    \\                       Use `dwarf` when the optimiser elided
    \\                       frames (§8.5).
    \\  --no-keep-trace      Delete perf.data and heaptrack.*.zst after
    \\                       rendering the SVGs. Default: keep, so SVGs
    \\                       can be re-rendered without re-capturing.
    \\  --check              Verify prerequisites and exit.
    \\  --list               List installed test binaries and exit.
    \\  -h, --help           Print this help and exit.
    \\
    \\modes need:
    \\  cpu: perf, inferno-collapse-perf, inferno-flamegraph
    \\  mem: heaptrack, heaptrack_print, inferno-flamegraph
    \\
    \\test filtering happens at build time, not driver time:
    \\  zig build profile -Dprofile-filter=parallel
    \\  zig build profile -Dprofile-filter=edit -Dprofile-filter=grep
    \\
    \\see docs/spec/v2.md §8 (or the archived how-to at
    \\docs/archive/profiling_guide.md) for the full spec.
    \\
;

const Mode = enum { cpu, mem, both };
const CallGraph = enum { fp, dwarf };

const Options = struct {
    binary: []const u8 = "franky-test",
    mode: Mode = .both,
    out_dir: ?[]const u8 = null,
    freq: u32 = 997,
    call_graph: CallGraph = .fp,
    keep_trace: bool = true,
    check_only: bool = false,
    list_only: bool = false,
};

const ArgError = error{
    HelpRequested,
    UnknownFlag,
    MissingValue,
    BadValue,
};

fn parseArgs(argv: []const []const u8) ArgError!Options {
    var opts: Options = .{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (eq(a, "-h") or eq(a, "--help")) return ArgError.HelpRequested;
        if (eq(a, "--check")) {
            opts.check_only = true;
        } else if (eq(a, "--list")) {
            opts.list_only = true;
        } else if (eq(a, "--no-keep-trace")) {
            opts.keep_trace = false;
        } else if (eq(a, "--binary")) {
            opts.binary = try takeValue(argv, &i);
        } else if (eq(a, "--out-dir")) {
            opts.out_dir = try takeValue(argv, &i);
        } else if (eq(a, "--freq")) {
            const v = try takeValue(argv, &i);
            opts.freq = std.fmt.parseInt(u32, v, 10) catch return ArgError.BadValue;
        } else if (eq(a, "--mode")) {
            const v = try takeValue(argv, &i);
            opts.mode = if (eq(v, "cpu")) .cpu else if (eq(v, "mem")) .mem else if (eq(v, "both")) .both else return ArgError.BadValue;
        } else if (eq(a, "--call-graph")) {
            const v = try takeValue(argv, &i);
            opts.call_graph = if (eq(v, "fp")) .fp else if (eq(v, "dwarf")) .dwarf else return ArgError.BadValue;
        } else {
            return ArgError.UnknownFlag;
        }
    }
    return opts;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn takeValue(argv: []const []const u8, i: *usize) ArgError![]const u8 {
    i.* += 1;
    if (i.* >= argv.len) return ArgError.MissingValue;
    return argv[i.*];
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var args_list: std.ArrayList([]const u8) = .empty;
    defer {
        for (args_list.items) |a| gpa.free(a);
        args_list.deinit(gpa);
    }
    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer it.deinit();
    while (it.next()) |raw| {
        try args_list.append(gpa, try gpa.dupe(u8, raw));
    }

    const opts_or_err = parseArgs(args_list.items);
    const opts = opts_or_err catch |err| switch (err) {
        ArgError.HelpRequested => {
            try writeOut(io, usage);
            return;
        },
        ArgError.UnknownFlag => return die(io, "franky profile: unknown flag\n"),
        ArgError.MissingValue => return die(io, "franky profile: flag requires a value\n"),
        ArgError.BadValue => return die(io, "franky profile: bad value for flag\n"),
    };

    if (opts.list_only) return listBinaries(gpa, io);

    if (@import("builtin").os.tag != .linux) {
        try writeErr(io, "franky profile: this driver is Linux-only.\n" ++
            "  perf and heaptrack don't work on macOS; use Instruments / dtrace.\n" ++
            "  See docs/archive/profiling_guide.md §2 for the macOS pointers.\n");
        std.process.exit(2);
    }

    const need_cpu = opts.mode == .cpu or opts.mode == .both;
    const need_mem = opts.mode == .mem or opts.mode == .both;

    const tools = try checkTools(io, init.environ_map, need_cpu, need_mem);
    if (opts.check_only) {
        try printToolStatus(io, tools);
        if (!tools.ok()) std.process.exit(1);
        return;
    }
    if (!tools.ok()) {
        try printToolStatus(io, tools);
        std.process.exit(1);
    }

    const paranoid = readPerfParanoid(io) catch null;
    if (need_cpu and paranoid != null and paranoid.? > 1) {
        try writeErrFmt(io, "franky profile: kernel.perf_event_paranoid={d} (need ≤ 1)\n" ++
            "  hint: sudo sysctl -w kernel.perf_event_paranoid=1\n" ++
            "  proceeding anyway — perf record will fail loudly if it can't sample.\n", .{paranoid.?});
    }

    const binary_basename = try resolveBinaryName(gpa, opts.binary);
    defer gpa.free(binary_basename);
    const binary_rel = try std.fmt.allocPrint(gpa, "zig-out/bin/{s}", .{binary_basename});
    defer gpa.free(binary_rel);
    const binary_abs = std.Io.Dir.cwd().realPathFileAlloc(io, binary_rel, gpa) catch |err| switch (err) {
        error.FileNotFound => {
            try writeErrFmt(io, "franky profile: {s} not found.\n  hint: zig build test-profile\n", .{binary_rel});
            std.process.exit(2);
        },
        else => return err,
    };
    defer gpa.free(binary_abs);

    const ts_ms = franky.ai.stream.nowMillis();
    const out_dir = if (opts.out_dir) |d|
        try gpa.dupe(u8, d)
    else
        try std.fmt.allocPrint(gpa, "zig-out/profile/{s}/{d}", .{ binary_basename, ts_ms });
    defer gpa.free(out_dir);

    try std.Io.Dir.cwd().createDirPath(io, out_dir);
    const out_dir_abs = try std.Io.Dir.cwd().realPathFileAlloc(io, out_dir, gpa);
    defer gpa.free(out_dir_abs);

    try writeOutFmt(io,
        \\franky profile
        \\  binary:      {s}
        \\  out-dir:     {s}
        \\  mode:        {s}
        \\  freq:        {d} Hz
        \\  call-graph:  {s}
        \\
    , .{
        binary_abs,
        out_dir_abs,
        @tagName(opts.mode),
        opts.freq,
        @tagName(opts.call_graph),
    });

    if (need_cpu) try runCpuPipeline(gpa, io, init.environ_map, opts, binary_abs, out_dir_abs);
    if (need_mem) try runMemPipeline(gpa, io, init.environ_map, opts, binary_abs, out_dir_abs);

    try printSummary(io, out_dir_abs);
}

const Tools = struct {
    perf: ?bool,
    heaptrack: ?bool,
    heaptrack_print: ?bool,
    inferno_collapse_perf: ?bool,
    inferno_flamegraph: ?bool,

    fn ok(t: Tools) bool {
        inline for (.{ t.perf, t.heaptrack, t.heaptrack_print, t.inferno_collapse_perf, t.inferno_flamegraph }) |maybe| {
            if (maybe) |present| if (!present) return false;
        }
        return true;
    }
};

fn checkTools(
    io: std.Io,
    env: *std.process.Environ.Map,
    need_cpu: bool,
    need_mem: bool,
) !Tools {
    return .{
        .perf = if (need_cpu) try haveCommand(io, env, "perf") else null,
        .heaptrack = if (need_mem) try haveCommand(io, env, "heaptrack") else null,
        .heaptrack_print = if (need_mem) try haveCommand(io, env, "heaptrack_print") else null,
        .inferno_collapse_perf = if (need_cpu) try haveCommand(io, env, "inferno-collapse-perf") else null,
        .inferno_flamegraph = if (need_cpu or need_mem) try haveCommand(io, env, "inferno-flamegraph") else null,
    };
}

fn haveCommand(
    io: std.Io,
    env: *std.process.Environ.Map,
    name: []const u8,
) !bool {
    const argv = [_][]const u8{ "/bin/sh", "-c", "command -v \"$1\" >/dev/null 2>&1", "_", name };
    var child = std.process.spawn(io, .{
        .argv = &argv,
        .environ_map = env,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| {
        try writeErrFmt(io, "franky profile: cannot spawn /bin/sh: {s}\n", .{@errorName(err)});
        return false;
    };
    const term = child.wait(io) catch return false;
    return termOk(term);
}

fn termOk(t: std.process.Child.Term) bool {
    return switch (t) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn printToolStatus(io: std.Io, t: Tools) !void {
    try writeOut(io, "tool availability:\n");
    if (t.perf) |p| try writeOutFmt(io, "  {s} perf\n", .{tick(p)});
    if (t.inferno_collapse_perf) |p| try writeOutFmt(io, "  {s} inferno-collapse-perf\n", .{tick(p)});
    if (t.inferno_flamegraph) |p| try writeOutFmt(io, "  {s} inferno-flamegraph\n", .{tick(p)});
    if (t.heaptrack) |p| try writeOutFmt(io, "  {s} heaptrack\n", .{tick(p)});
    if (t.heaptrack_print) |p| try writeOutFmt(io, "  {s} heaptrack_print\n", .{tick(p)});
    if (!t.ok()) {
        try writeOut(io,
            \\
            \\install hints (Debian/Ubuntu):
            \\  sudo apt install linux-perf heaptrack binutils
            \\  cargo install inferno
            \\
        );
    }
}

fn tick(present: bool) []const u8 {
    return if (present) "[ok]   " else "[miss] ";
}

fn readPerfParanoid(io: std.Io) !u32 {
    var buf: [16]u8 = undefined;
    const slice = try std.Io.Dir.cwd().readFile(io, "/proc/sys/kernel/perf_event_paranoid", &buf);
    const trimmed = std.mem.trim(u8, slice, " \t\n\r");
    return std.fmt.parseInt(u32, trimmed, 10) catch return error.BadValue;
}

fn fileExists(io: std.Io, path: []const u8) !bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn resolveBinaryName(gpa: std.mem.Allocator, name: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, name, "franky-")) return gpa.dupe(u8, name);
    return std.fmt.allocPrint(gpa, "franky-{s}", .{name});
}

fn listBinaries(gpa: std.mem.Allocator, io: std.Io) !void {
    try writeOut(io, "available test binaries:\n");
    for (test_binaries) |name| {
        const path = try std.fmt.allocPrint(gpa, "zig-out/bin/{s}", .{name});
        defer gpa.free(path);
        const exists = try fileExists(io, path);
        try writeOutFmt(io, "  {s} {s}\n", .{ if (exists) "[built]  " else "[missing]", name });
    }
    try writeOut(io,
        \\
        \\If a binary is missing, run:
        \\  zig build test-profile
        \\
    );
}

fn runCpuPipeline(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    opts: Options,
    binary_abs: []const u8,
    out_dir_abs: []const u8,
) !void {
    try writeOut(io, "\n=== CPU pipeline ===\n");

    // perf record cannot write to FUSE filesystems ("Bad address" error).
    // Write perf.data to /tmp and copy it to the output directory after.
    const perf_data_tmp = try std.fmt.allocPrint(gpa, "/tmp/franky-perf-{d}.data", .{franky.ai.stream.nowMillis()});
    defer gpa.free(perf_data_tmp);
    const perf_data = try std.fmt.allocPrint(gpa, "{s}/perf.data", .{out_dir_abs});
    defer gpa.free(perf_data);
    const cpu_folded = try std.fmt.allocPrint(gpa, "{s}/cpu.folded", .{out_dir_abs});
    defer gpa.free(cpu_folded);
    const cpu_svg = try std.fmt.allocPrint(gpa, "{s}/cpu.svg", .{out_dir_abs});
    defer gpa.free(cpu_svg);

    const freq_str = try std.fmt.allocPrint(gpa, "{d}", .{opts.freq});
    defer gpa.free(freq_str);
    const cg_str: []const u8 = switch (opts.call_graph) {
        .fp => "fp",
        .dwarf => "dwarf,16384",
    };

    const perf_argv = [_][]const u8{
        "perf", "record", "-F", freq_str, "--call-graph", cg_str, "-o", perf_data_tmp, "--",
        binary_abs,
    };
    try writeOutFmt(io, "$ perf record (freq={d}, call-graph={s})\n", .{ opts.freq, cg_str });
    try runInherit(io, env, &perf_argv, null, "perf record");

    // Copy perf.data from /tmp to the output directory (FUSE-safe write).
    {
        const src_q = try shellQuoteAlloc(gpa, perf_data_tmp);
        defer gpa.free(src_q);
        const dst_q = try shellQuoteAlloc(gpa, perf_data);
        defer gpa.free(dst_q);
        const cmd = try std.fmt.allocPrint(gpa, "cp {s} {s}", .{ src_q, dst_q });
        defer gpa.free(cmd);
        try writeOut(io, "$ cp perf.data to output directory\n");
        try runShell(io, env, cmd, "copy perf.data");
    }

    {
        const a = try shellQuoteAlloc(gpa, perf_data);
        defer gpa.free(a);
        const b = try shellQuoteAlloc(gpa, cpu_folded);
        defer gpa.free(b);
        const cmd = try std.fmt.allocPrint(gpa, "perf script --input {s} | sed 's/→/->/g' | inferno-collapse-perf > {s}", .{ a, b });
        defer gpa.free(cmd);
        try writeOut(io, "$ perf script | sed 's/→/->/g' | inferno-collapse-perf > cpu.folded\n");
        try runShell(io, env, cmd, "collapse perf");
    }
    {
        const a = try shellQuoteAlloc(gpa, cpu_folded);
        defer gpa.free(a);
        const b = try shellQuoteAlloc(gpa, cpu_svg);
        defer gpa.free(b);
        const cmd = try std.fmt.allocPrint(gpa, "inferno-flamegraph --title 'franky-profile CPU' --colors aqua {s} > {s}", .{ a, b });
        defer gpa.free(cmd);
        try writeOut(io, "$ inferno-flamegraph cpu.folded > cpu.svg\n");
        try runShell(io, env, cmd, "render cpu flamegraph");
    }

    if (!opts.keep_trace) {
        std.Io.Dir.cwd().deleteFile(io, perf_data) catch {};
    }
    // Always clean up the temp perf.data.
    std.Io.Dir.cwd().deleteFile(io, perf_data_tmp) catch {};
}

fn runMemPipeline(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    opts: Options,
    binary_abs: []const u8,
    out_dir_abs: []const u8,
) !void {
    try writeOut(io, "\n=== Memory pipeline ===\n");

    const heap_argv = [_][]const u8{ "heaptrack", binary_abs };
    try writeOut(io, "$ heaptrack <binary>\n");
    try runInherit(io, env, &heap_argv, out_dir_abs, "heaptrack");

    const trace = try findHeaptrackTrace(gpa, io, out_dir_abs) orelse {
        return die(io, "franky profile: heaptrack capture finished but no .zst trace was produced.\n");
    };
    defer gpa.free(trace);
    try writeOutFmt(io, "  trace: {s}\n", .{trace});

    for (memory_costs) |cost| {
        const folded = try std.fmt.allocPrint(gpa, "{s}/mem-{s}.folded", .{ out_dir_abs, cost });
        defer gpa.free(folded);
        const svg = try std.fmt.allocPrint(gpa, "{s}/mem-{s}.svg", .{ out_dir_abs, cost });
        defer gpa.free(svg);

        {
            // `-F` is `--print-flamegraph PATH` (the *output file*),
            // not the cost selector. Cost goes through
            // `--flamegraph-cost-type`. `-p 0 -a 0 -T 0` suppresses
            // the default text reports on stdout so the redirect
            // isn't needed and the run stays quiet.
            const cost_q = try shellQuoteAlloc(gpa, cost);
            defer gpa.free(cost_q);
            const trace_q = try shellQuoteAlloc(gpa, trace);
            defer gpa.free(trace_q);
            const folded_q = try shellQuoteAlloc(gpa, folded);
            defer gpa.free(folded_q);
            const cmd = try std.fmt.allocPrint(
                gpa,
                "heaptrack_print -p 0 -a 0 -T 0 --flamegraph-cost-type {s} -F {s} -f {s}",
                .{ cost_q, folded_q, trace_q },
            );
            defer gpa.free(cmd);
            try writeOutFmt(io, "$ heaptrack_print --flamegraph-cost-type {s} -F mem-{s}.folded -f <trace>\n", .{ cost, cost });
            try runShell(io, env, cmd, "heaptrack_print");
        }
        {
            const title_buf = try std.fmt.allocPrint(gpa, "franky-profile mem ({s})", .{cost});
            defer gpa.free(title_buf);
            const title_q = try shellQuoteAlloc(gpa, title_buf);
            defer gpa.free(title_q);
            const folded_q = try shellQuoteAlloc(gpa, folded);
            defer gpa.free(folded_q);
            const svg_q = try shellQuoteAlloc(gpa, svg);
            defer gpa.free(svg_q);
            const cmd = try std.fmt.allocPrint(gpa, "inferno-flamegraph --title {s} --countname=bytes --colors=mem {s} > {s}", .{ title_q, folded_q, svg_q });
            defer gpa.free(cmd);
            try writeOutFmt(io, "$ inferno-flamegraph --colors=mem mem-{s}.folded > mem-{s}.svg\n", .{ cost, cost });
            try runShell(io, env, cmd, "render mem flamegraph");
        }
    }

    if (!opts.keep_trace) {
        std.Io.Dir.cwd().deleteFile(io, trace) catch {};
    }
}

fn findHeaptrackTrace(
    gpa: std.mem.Allocator,
    io: std.Io,
    out_dir_abs: []const u8,
) !?[]u8 {
    var dir = try std.Io.Dir.cwd().openDir(io, out_dir_abs, .{ .iterate = true });
    defer dir.close(io);
    var iter = dir.iterate();
    var last_name: ?[]u8 = null;
    errdefer if (last_name) |n| gpa.free(n);
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, "heaptrack.")) continue;
        // heaptrack 1.4+ writes .zst when zstd is on $PATH, otherwise
        // falls back to .gz. Both are valid inputs for heaptrack_print.
        const is_zst = std.mem.endsWith(u8, entry.name, ".zst");
        const is_gz = std.mem.endsWith(u8, entry.name, ".gz");
        if (!is_zst and !is_gz) continue;
        if (last_name) |old| gpa.free(old);
        last_name = try gpa.dupe(u8, entry.name);
    }
    if (last_name) |name| {
        defer gpa.free(name);
        return try std.fmt.allocPrint(gpa, "{s}/{s}", .{ out_dir_abs, name });
    }
    return null;
}

fn runInherit(
    io: std.Io,
    env: *std.process.Environ.Map,
    argv: []const []const u8,
    cwd: ?[]const u8,
    label: []const u8,
) !void {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .environ_map = env,
        .cwd = if (cwd) |c| std.process.Child.Cwd{ .path = c } else .inherit,
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(io);
    if (!termOk(term)) {
        try writeErrFmt(io, "franky profile: {s} failed: {any}\n", .{ label, term });
        std.process.exit(1);
    }
}

fn runShell(
    io: std.Io,
    env: *std.process.Environ.Map,
    cmd: []const u8,
    label: []const u8,
) !void {
    const argv = [_][]const u8{ "/bin/sh", "-c", cmd };
    return runInherit(io, env, &argv, null, label);
}

/// Wraps `s` in single quotes, escaping any embedded single quote
/// using the standard `'\''` POSIX-shell trick. Caller owns the
/// returned slice.
fn shellQuoteAlloc(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.append(gpa, '\'');
    for (s) |c| {
        if (c == '\'') {
            try buf.appendSlice(gpa, "'\\''");
        } else {
            try buf.append(gpa, c);
        }
    }
    try buf.append(gpa, '\'');
    return buf.toOwnedSlice(gpa);
}

fn printSummary(io: std.Io, out_dir_abs: []const u8) !void {
    try writeOut(io, "\n=== Artefacts ===\n");
    var dir = try std.Io.Dir.cwd().openDir(io, out_dir_abs, .{ .iterate = true });
    defer dir.close(io);
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const stat = dir.statFile(io, entry.name, .{}) catch continue;
        try writeOutFmt(io, "  {s:<48} {d:>10} bytes\n", .{ entry.name, stat.size });
    }
    try writeOutFmt(io, "\nopen any .svg in a browser. directory: {s}\n", .{out_dir_abs});
}

fn die(io: std.Io, msg: []const u8) noreturn {
    writeErr(io, msg) catch {};
    std.process.exit(2);
}

fn writeOut(io: std.Io, s: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.writeAll(s);
    try w.interface.flush();
}

fn writeOutFmt(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.print(fmt, args);
    try w.interface.flush();
}

fn writeErr(io: std.Io, s: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    try w.interface.writeAll(s);
    try w.interface.flush();
}

fn writeErrFmt(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    try w.interface.print(fmt, args);
    try w.interface.flush();
}
