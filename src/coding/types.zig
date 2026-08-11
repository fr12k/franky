//! Centralised type-import aliases for the coding package.
//!
//! Every tool/mode file previously copy-pasted its own
//! `const ai = struct { pub const types = @import(...); ... }` block.
//! This module is the single source of truth — updating an import
//! path for the whole package touches exactly one file.

pub const ai = struct {
    pub const types = @import("../ai/types.zig");
    pub const stream = @import("../ai/stream.zig");
    pub const registry = @import("../ai/registry.zig");
    pub const log = @import("../ai/log.zig");
    pub const utils = @import("../ai/utils.zig");
    pub const http = @import("../ai/http.zig");
    pub const partial_json = @import("../ai/partial_json.zig");
    pub const openrouter_attribution = @import("../ai/openrouter_attribution.zig");
};

pub const agent = struct {
    pub const types = @import("../agent/types.zig");
};
