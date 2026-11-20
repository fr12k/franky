const std = @import("std");
const franky = @import("franky");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    // Collect argv into []const []const u8 for the mode driver.
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

    try franky.coding.modes.print.run(gpa, io, init.minimal.environ, init.environ_map, args_list.items);
}

// ── Custom panic handler ───────────────────────────────────────────
//
// v0.62.3 — The default Zig 0.17-dev panic handler (std.debug.defaultPanic)
// prints a stack trace by loading DWARF debug info from the executable
// file on disk (getSelfDebugInfo → SelfInfo/Elf.zig opens /proc/self/exe
// or the binary path). Under gvisor sandboxes this file read fails
// silently — the panic message ("thread N panic: …") prints but the
// stack trace is skipped, leaving no diagnostic information.
//
// This custom handler replaces the DWARF-based trace with a
// frame-pointer-based backtrace that needs no filesystem access. It
// walks the frame-pointer chain (RBP on x86_64, X29 on aarch64) and
// prints raw return addresses. These can be resolved offline with:
//
//   addr2line -e franky -f -C 0x<major> 0x<minor> …
//
// Frame-pointer unwinding requires that the binary was compiled with
// `omit_frame_pointer = false` (set in build.zig for the exe module).
// On architectures where FP unwinding is "unsafe" (x86_64, aarch64
// non-Darwin) we still use it because we're crashing anyway and the
// alternative (DWARF) doesn't work under gvisor.

pub const panic = std.debug.FullPanic(gvisorPanic);

fn gvisorPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    @branchHint(.cold);

    // Write directly to fd 2 (stderr) via the write syscall — no
    // allocator, no IO abstraction, no mutex. This is the most
    // fragile-safe path.
    const fd: i32 = 2;
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    // Header: "thread N panic: msg\n"
    if (@import("builtin").single_threaded) {
        w.print("panic: ", .{}) catch {};
    } else {
        const tid = std.Thread.getCurrentId();
        w.print("thread {d} panic: ", .{tid}) catch {};
    }
    w.print("{s}\n", .{msg}) catch {};
    w.writeAll("stack trace (raw addresses — resolve with addr2line):\n") catch {};

    // Walk the frame-pointer chain.
    // On x86_64: RBP points to saved-RBP; return address is at RBP+8.
    // On aarch64: X29 points to saved-X29; return address is at X29+8.
    // The layout is identical for our purposes.
    var fp: usize = @frameAddress();
    var depth: u32 = 0;
    const max_depth: u32 = 64;

    // If a specific trace address was passed (safety panic), include it.
    if (first_trace_addr) |addr| {
        w.print("  [{d: >2}] 0x{x:0>16}\n", .{ depth, addr }) catch {};
        depth += 1;
    }

    while (depth < max_depth and fp != 0 and fp != std.math.maxInt(usize)) {
        // Read saved frame pointer (at *fp) and return address (at *(fp+8)).
        // Use volatile reads to prevent the compiler from optimizing away
        // the memory access.
        const fp_ptr: [*]volatile usize = @ptrFromInt(fp);
        const next_fp = fp_ptr[0];
        const ret_addr = fp_ptr[1];

        if (ret_addr == 0) break;

        w.print("  [{d: >2}] 0x{x:0>16}\n", .{ depth, ret_addr }) catch {};
        depth += 1;

        // Sanity: frame pointers must monotonically increase (stack grows
        // down). If they don't, we've hit garbage — stop.
        if (next_fp <= fp) break;
        fp = next_fp;
    }

    if (depth == max_depth) {
        w.writeAll("  … (truncated at 64 frames)\n") catch {};
    }

    // Flush buffer to stderr.
    const written = w.buffered();
    _ = std.os.linux.write(fd, written.ptr, written.len);

    std.process.abort();
}
