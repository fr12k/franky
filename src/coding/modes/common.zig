//! Shared helpers for the four execution modes (print / interactive /
//! rpc / proxy).
//!
//! Prior to the v1.3.0 dedup (see `DEDUP_PLAN.md` Finding 6) every mode
//! carried its own byte-identical copy of:
//!
//!   - `WorkerArgs` + `workerMain` — the thin struct/thread-fn that
//!     hands a turn off to `agent.loop.agentLoop`.
//!   - `fauxShim` — the `registry.StreamFn` trampoline that forwards to
//!     `faux.FauxProvider.runSync`. Identical copies also lived in
//!     `coding/config.zig` and `coding/session/compaction.zig`.
//!
//! This module is the single source of truth; modes import from here
//! instead of re-declaring.

const std = @import("std");
const franky = @import("../../root.zig");
const ai = franky.ai;
const agent = franky.agent;

/// Arguments handed to `workerMain`. The first five fields are common
/// to every mode; `stats` is optional and used by `print` (v2.31 Phase 5
/// compression summary). Modes that don't track compression pass `null`.
pub const WorkerArgs = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    transcript: *agent.loop.Transcript,
    config: agent.loop.Config,
    ch: *agent.loop.AgentChannel,
    /// v2.31 Phase 5 — pointer to run-scoped compression stats the loop
    /// writes to. `null` for modes that don't emit a session summary.
    stats: ?*agent.types.CompressionStats = null,
};

/// Thread entry point that drives one agent loop turn. Identical across
/// all modes; extracted here so a future loop-signature change touches
/// one place.
pub fn workerMain(args: WorkerArgs) void {
    agent.loop.agentLoop(args.allocator, args.io, args.transcript, args.config, args.ch);
}

/// `registry.StreamFn` trampoline for the faux provider. Delegates
/// to `faux.FauxProvider.shim` (the canonical implementation lives
/// next to the provider itself; see `DEDUP_PLAN.md` Finding 6).
/// Kept as a re-export so existing mode call sites (`fauxShim`) stay
/// unchanged after the dedup.
pub const fauxShim = ai.providers.faux.FauxProvider.shim;

/// `loop.Config.stop_requested_fn` callback for a bare atomic flag.
/// `userdata` is `*std.atomic.Value(bool)`; the caller sets it from a
/// keybinding / HTTP handler / RPC dispatch to request a graceful stop.
pub fn stopRequestedFromAtomic(userdata: ?*anyopaque) bool {
    const flag: *std.atomic.Value(bool) = @ptrCast(@alignCast(userdata.?));
    return flag.load(.acquire);
}