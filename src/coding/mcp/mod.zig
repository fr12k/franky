//! MCP (Model Context Protocol) integration for franky.
//!
//! This package provides:
//!   - `config`  — parse `mcpServers` JSON config files with env substitution
//!   - `client`  — connect to external MCP servers over HTTP and expose
//!                 their tools as franky `AgentTool` wrappers
//!   - `config.ServerConfig` — the parsed server definition
//!
//! Used by `--mcp-configs <file1,file2,...>` to let franky act as an
//! MCP client that proxies external tool servers (Atlassian, Slack,
//! ArgoCD, etc.) into the agent's tool set.

pub const config = @import("config.zig");
pub const client = @import("client.zig");

pub const ServerConfig = config.ServerConfig;
pub const McpClient = client.McpClient;
pub const McpToolCtx = client.McpToolCtx;

/// Convenience: parse config files + discover tools in one call.
/// Returns the tool slice and fills `client_out`.
pub fn loadAndDiscover(
    arena: std.mem.Allocator,
    io: std.Io,
    config_paths: []const []const u8,
    environ_map: *const std.process.Environ.Map,
    cancel: *ai.stream.Cancel,
    client_out: *McpClient,
) ![]agent.types.AgentTool {
    const servers = try config.parseConfigs(arena, config_paths, environ_map, io);
    return client.discoverTools(arena, io, servers, environ_map, cancel, client_out);
}

const std = @import("std");
const ai = @import("../../ai/mod.zig");
const agent = @import("../../agent/mod.zig");
