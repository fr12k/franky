//! ai — provider-agnostic LLM streaming.
//!
//! Per §3 of the spec: every provider exposes `stream(model, context, options)`
//! returning an `AssistantMessageEventStream`. Consumers drain events until a
//! terminal `.done` or `.error_ev` event is seen.

pub const types = @import("types.zig");
pub const errors = @import("errors.zig");
pub const sse = @import("sse.zig");
pub const partial_json = @import("partial_json.zig");
pub const channel = @import("channel.zig");
pub const stream = @import("stream.zig");
pub const registry = @import("registry.zig");
pub const http = @import("http.zig");
pub const retry = @import("retry.zig");
pub const error_map = @import("error_map.zig");
pub const log = @import("log.zig");
pub const transform = @import("transform.zig");
pub const utils = @import("utils.zig");
pub const openrouter_attribution = @import("openrouter_attribution.zig");
pub const providers = struct {
    pub const faux = @import("providers/faux.zig");
    pub const anthropic = @import("providers/anthropic.zig");
    pub const openai_chat = @import("providers/openai_chat.zig");
    pub const openai_gateway = @import("providers/openai_gateway.zig");
    pub const openai_responses = @import("providers/openai_responses.zig");
    pub const google_gemini = @import("providers/google_gemini.zig");
};

test {
    _ = types;
    _ = errors;
    _ = sse;
    _ = partial_json;
    _ = channel;
    _ = stream;
    _ = registry;
    _ = http;
    _ = retry;
    _ = error_map;
    _ = log;
    _ = transform;
    _ = utils;
    _ = openrouter_attribution;
    _ = providers.faux;
    _ = providers.anthropic;
    // Direct import avoids forcing the `providers` aggregator to
    // analyze WIP siblings (gemini.zig) while this file tests.
    _ = @import("providers/openai_chat.zig");
    _ = @import("providers/openai_gateway.zig");
    _ = @import("providers/openai_responses.zig");
    _ = @import("providers/google_gemini.zig");
    _ = @import("providers/google_vertex.zig");
}
