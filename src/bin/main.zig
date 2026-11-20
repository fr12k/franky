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
// This custom handler does two things:
//
// 1. Walks the frame-pointer chain directly (no DWARF unwind info
//    needed) to collect return addresses.
// 2. Attempts to resolve each address to a source location
//    (file:line:col function) via std.debug.getSelfDebugInfo().
//    If the DWARF debug info cannot be loaded (the gvisor failure
//    mode), it falls back to printing raw hex addresses which can
//    be resolved offline with:
//
//      addr2line -e franky -f -C 0x<addr> ...
//
// Frame-pointer unwinding requires that the binary was compiled with
// `omit_frame_pointer = false` (set in build.zig for the exe module).
// On architectures where FP unwinding is "unsafe" (x86_64, aarch64
// non-Darwin) we still use it because we're crashing anyway and the
// alternative (DWARF) doesn't work under gvisor.
//
// All output goes through a bare write(2) syscall to fd 2 — no
// allocator, no IO abstraction, no mutex. The DWARF resolution path
// uses std.debug's API with the std.Options.debug_io (single-threaded
// Threaded instance) and a page_allocator-backed arena, which is safe
// in a panic context.

pub const panic = std.debug.FullPanic(gvisorPanic);

fn gvisorPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    @branchHint(.cold);

    const fd: i32 = 2;

    // ── Phase 1: collect return addresses via FP walk ───────────
    var addresses: [64]usize = undefined;
    var addr_count: usize = 0;

    if (first_trace_addr) |addr| {
        if (addr_count < addresses.len) {
            addresses[addr_count] = addr;
            addr_count += 1;
        }
    }

    var fp: usize = @frameAddress();
    while (addr_count < addresses.len and fp != 0 and fp != std.math.maxInt(usize)) {
        const fp_ptr: [*]volatile usize = @ptrFromInt(fp);
        const next_fp = fp_ptr[0];
        const ret_addr = fp_ptr[1];
        if (ret_addr == 0) break;
        addresses[addr_count] = ret_addr;
        addr_count += 1;
        if (next_fp <= fp) break; // stack grows down
        fp = next_fp;
    }

    // ── Phase 2: attempt DWARF source resolution ────────────────
    //
    // Try to load debug info and resolve each address to
    // file:line:col function. If this fails (the gvisor case where
    // /proc/self/exe can't be read through the IO layer), fall back
    // to raw hex addresses.
    var resolved = false;
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();

    if (std.debug.getSelfDebugInfo()) |di| {
        // We have debug info — resolve each address to source locations.
        // Frames that can't be resolved (e.g. libc addresses) print as
        // raw hex so the trace is still complete.
        resolved = true;
        var buf: [8192]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);

        w.print("thread {d} panic: {s}\n", .{ std.Thread.getCurrentId(), msg }) catch {};
        w.writeAll("stack trace:\n") catch {};

        const debug_io = std.Options.debug_io;
        var i: usize = 0;
        while (i < addr_count) : (i += 1) {
            // Subtract 1 to get an address *inside* the call instruction
            // for better source location (same as std.debug does).
            const addr = addresses[i] -| 1;

            var sym_buf: [4]std.debug.Symbol = undefined;
            var bfa: std.heap.BufferFirstAllocator = .init(
                std.mem.sliceAsBytes(&sym_buf),
                std.heap.page_allocator,
            );
            const sym_alloc = bfa.allocator();
            var symbols = std.ArrayList(std.debug.Symbol).initCapacity(sym_alloc, 1) catch {
                // OOM — print raw address for this frame and continue.
                w.print("  ???:?:? in ??? (0x{x})\n", .{addresses[i]}) catch {};
                continue;
            };
            defer symbols.deinit(sym_alloc);

            di.getSymbols(
                debug_io,
                sym_alloc,
                arena.allocator(),
                addr,
                true, // resolve inline callers
                &symbols,
            ) catch {
                // Resolution failed for this address (e.g. libc frame) —
                // print raw hex and move on.
                w.print("  ???:?:? in ??? (0x{x})\n", .{addresses[i]}) catch {};
                continue;
            };

            if (symbols.items.len == 0) {
                w.print("  ???:?:? in ??? (0x{x})\n", .{addresses[i]}) catch {};
                continue;
            }

            for (symbols.items) |sym| {
                if (sym.source_location) |sl| {
                    if (sl.column == 0) {
                        w.print("  {s}:{d}", .{ sl.file_name, sl.line }) catch {};
                    } else {
                        w.print("  {s}:{d}:{d}", .{ sl.file_name, sl.line, sl.column }) catch {};
                    }
                } else {
                    w.writeAll("  ???:?:?") catch {};
                }
                w.print(" in {s} (0x{x})\n", .{ sym.name orelse "???", addresses[i] }) catch {};
            }
        }

        {
            const written = w.buffered();
            _ = std.os.linux.write(fd, written.ptr, written.len);
        }
    } else |_| {}

    // ── Phase 3: fallback — raw hex addresses ───────────────────
    if (!resolved) {
        var buf: [4096]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);

        w.print("thread {d} panic: {s}\n", .{ std.Thread.getCurrentId(), msg }) catch {};
        w.writeAll("stack trace (raw addresses — resolve with addr2line):\n") catch {};

        var i: usize = 0;
        while (i < addr_count) : (i += 1) {
            w.print("  [{d: >2}] 0x{x:0>16}\n", .{ i, addresses[i] }) catch {};
        }

        if (addr_count == addresses.len) {
            w.writeAll("  … (truncated at 64 frames)\n") catch {};
        }

        const written = w.buffered();
        _ = std.os.linux.write(fd, written.ptr, written.len);
    }

    std.process.abort();
}
