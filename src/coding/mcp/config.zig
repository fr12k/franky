//! MCP client configuration parser.
//!
//! Parses the `mcpServers` JSON config format used by Claude Desktop,
//! Cursor, and other MCP clients. Supports env-variable substitution
//! in header values using `${VAR_NAME}` syntax.
//!
//! Config file format (each file can contain one or more servers):
//!   {
//!     "mcpServers": {
//!       "server-name": {
//!         "type": "http",
//!         "url": "https://example.com/mcp",
//!         "headers": {
//!           "Authorization": "Bearer ${API_KEY}"
//!         }
//!       }
//!     }
//!   }
//!
//! Multiple config files can be passed via --mcp-configs (comma-separated).
//! All servers from all files are merged into a single list.

const std = @import("std");
const jh = @import("json_helpers.zig");
const ai = @import("../../ai/mod.zig");
const log = ai.log;

/// A single configured MCP server.
pub const ServerConfig = struct {
    /// Server name (the key in the mcpServers object).
    name: []const u8,
    /// Transport type. Currently only "http" is supported.
    transport: Transport,
    /// Server URL (for http transport).
    url: []const u8,
    /// HTTP headers to send with every request. Values may contain
    /// `${VAR}` patterns that are expanded from the environment.
    /// Owned by the arena; already env-substituted.
    headers: []const Header,

    pub const Transport = enum { http, stdio };
    pub const Header = struct {
        name: []const u8,
        value: []const u8,
    };
};

/// Parse one or more MCP config files and return the merged list of
/// server configs. All string data is allocated on `arena`.
pub fn parseConfigs(
    arena: std.mem.Allocator,
    config_paths: []const []const u8,
    environ_map: *const std.process.Environ.Map,
    io: std.Io,
) ![]ServerConfig {
    var servers: std.ArrayList(ServerConfig) = .empty;
    errdefer servers.deinit(arena);

    for (config_paths) |path| {
        const trimmed = std.mem.trim(u8, path, " \t");
        if (trimmed.len == 0) continue;
        parseOneFile(arena, &servers, trimmed, environ_map, io) catch |err| {
            ai_log(io, "mcp-config", "failed to parse {s}: {s}", .{ trimmed, @errorName(err) });
            // Continue with other files rather than failing entirely.
        };
    }

    return servers.toOwnedSlice(arena);
}

fn parseOneFile(
    arena: std.mem.Allocator,
    servers: *std.ArrayList(ServerConfig),
    path: []const u8,
    environ_map: *const std.process.Environ.Map,
    io: std.Io,
) !void {
    // Read the file (Zig 0.17 std.Io API).
    var f = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
        ai_log(io, "mcp-config", "cannot read {s}: {s}", .{ path, @errorName(err) });
        return err;
    };
    defer f.close(io);
    const len = f.length(io) catch 4 * 1024 * 1024;
    const file_data = try arena.alloc(u8, @intCast(len));
    const n = f.readPositionalAll(io, file_data, 0) catch |err| return err;
    const data = file_data[0..n];

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, data, .{});
    if (parsed != .object) return error.InvalidConfig;
    const root = parsed.object;

    const mcp_servers = root.get("mcpServers") orelse return error.NoMcpServers;
    if (mcp_servers != .object) return error.InvalidConfig;

    var it = mcp_servers.object.iterator();
    while (it.next()) |entry| {
        const name = try arena.dupe(u8, entry.key_ptr.*);
        const server_val = entry.value_ptr.*;
        if (server_val != .object) continue;
        const so = server_val.object;

        // Parse transport type.
        const type_str = if (so.get("type")) |t| (if (t == .string) t.string else "http") else "http";
        const transport: ServerConfig.Transport = if (std.mem.eql(u8, type_str, "stdio"))
            .stdio
        else
            .http;

        // Parse URL (required for http).
        const url = if (so.get("url")) |u| (if (u == .string) try arena.dupe(u8, u.string) else "") else "";
        if (transport == .http and url.len == 0) {
            ai_log(io, "mcp-config", "http server '{s}' has empty url, skipping", .{name});
            continue;
        }

        // Parse headers with env substitution.
        var headers: std.ArrayList(ServerConfig.Header) = .empty;
        if (so.get("headers")) |hv| if (hv == .object) {
            var hit = hv.object.iterator();
            while (hit.next()) |hentry| {
                const hname = try arena.dupe(u8, hentry.key_ptr.*);
                const hval_raw = if (hentry.value_ptr.* == .string) hentry.value_ptr.string else "";
                const hval = try substituteEnv(arena, hval_raw, environ_map);
                try headers.append(arena, .{ .name = hname, .value = hval });
            }
        };
        const headers_slice = try headers.toOwnedSlice(arena);

        try servers.append(arena, .{
            .name = name,
            .transport = transport,
            .url = url,
            .headers = headers_slice,
        });
    }
}

/// Replace `${VAR_NAME}` patterns in `s` with values from the environment.
/// Unknown variables are replaced with an empty string. Allocates on `arena`.
pub fn substituteEnv(
    arena: std.mem.Allocator,
    s: []const u8,
    environ_map: *const std.process.Environ.Map,
) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (i + 2 < s.len and s[i] == '$' and s[i + 1] == '{') {
            // Find closing '}'.
            const end = std.mem.indexOfScalarPos(u8, s, i + 2, '}') orelse {
                // No closing brace — emit literally.
                try result.append(arena, s[i]);
                i += 1;
                continue;
            };
            const var_name = s[i + 2 .. end];
            if (environ_map.get(var_name)) |raw_val| {
                // Strip CR/LF to prevent HTTP header injection.
                for (raw_val) |c| {
                    if (c != '\r' and c != '\n') try result.append(arena, c);
                }
            }
            // Unknown var → empty string (skip).
            i = end + 1;
        } else {
            try result.append(arena, s[i]);
            i += 1;
        }
    }
    return result.toOwnedSlice(arena);
}

fn ai_log(io: std.Io, scope: []const u8, comptime fmt: []const u8, args: anytype) void {
    _ = io;
    _ = scope;
    log.log(.warn, "mcp-config", "parse", fmt, args);
}

// ─── tests ──────────────────────────────────────────────────────

const testing = std.testing;

test "substituteEnv: known, unknown, identity, multiple vars" {
    const gpa = testing.allocator;
    var env_map = std.process.Environ.Map.init(gpa);
    defer env_map.deinit();
    try env_map.put("MY_TOKEN", "abc123");
    try env_map.put("A", "1");
    try env_map.put("B", "2");

    const Case = struct { input: []const u8, expected: []const u8 };
    const cases = [_]Case{
        .{ .input = "Bearer ${MY_TOKEN}", .expected = "Bearer abc123" },
        .{ .input = "Bearer ${UNKNOWN_VAR}", .expected = "Bearer " },
        .{ .input = "plain text", .expected = "plain text" },
        .{ .input = "${A}-${B}-${A}", .expected = "1-2-1" },
    };
    for (cases) |c| {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const result = try substituteEnv(arena.allocator(), c.input, &env_map);
        try testing.expectEqualStrings(c.expected, result);
    }
}
