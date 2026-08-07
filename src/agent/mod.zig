//! agent — stateful tool-using runtime.

pub const types = @import("types.zig");
pub const loop = @import("loop.zig");
pub const proxy = @import("proxy.zig");
pub const wire = @import("wire.zig");
pub const guardrails = @import("guardrails/guardrails.zig");
const agent_mod = @import("agent.zig");
pub const Agent = agent_mod.Agent;

test {
    _ = types;
    _ = loop;
    _ = proxy;
    _ = wire;
    _ = agent_mod;
    _ = guardrails;
    _ = @import("guardrails/stuck_detector.zig");
    _ = @import("guardrails/compilation_guard.zig");
    _ = @import("guardrails/finish_task.zig");
    _ = @import("guardrails/memory_guardrail.zig");
}
