//! agent — stateful tool-using runtime.

pub const types = @import("types.zig");
pub const loop = @import("loop.zig");
pub const proxy = @import("proxy.zig");
pub const guardrails = @import("guardrails/guardrails.zig");
const agent_mod = @import("agent.zig");
pub const Agent = agent_mod.Agent;

/// v2.31 — conversation compaction. Re-exported at the agent
/// module level so callers (and tests) can `franky.agent.compaction.*`.
pub const compaction = @import("compaction.zig");
/// v2.31 Phase 3 — CCR (Compress-Cache-Retrieve) integration.
/// Re-exported for the same reason as `compaction`.
pub const ccr_integration = @import("ccr_integration.zig");

test {
    _ = types;
    _ = loop;
    _ = proxy;
    _ = agent_mod;
    _ = guardrails;
    _ = @import("guardrails/stuck_detector.zig");
    _ = @import("guardrails/compilation_guard.zig");
    _ = @import("guardrails/finish_task.zig");
    _ = compaction;
    _ = ccr_integration;
}
