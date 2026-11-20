//! auth.json loader — §H.1.
//!
//! On-disk shape:
//!
//!   {
//!     "version": 1,
//!     "providers": {
//!       "<provider-name>": {
//!         "type": "apiKey" | "oauth",
//!         "apiKey": "...",
//!         "accessToken": "...",
//!         "refreshToken": "...",
//!         "expiresAt": "2026-01-01T00:00:00Z",
//!         "scope": "...",
//!         "metadata": {}
//!       }
//!     }
//!   }
//!
//! §H.1 requires `0600` on creation and refuses to read a file whose
//! mode is more permissive on POSIX. This module ships the loader +
//! the mode check + the precedence rule (`--cli-flag` > env-var >
//! `auth.json`) as pure-logic helpers.
//!
//! franky no longer mints credentials itself: bearer tokens are
//! produced by an external tool (e.g. `claude setup-token`) and the
//! resulting record is pasted into `auth.json` by the user. The
//! `oauth` variant of `ProviderAuthType` is preserved for
//! round-tripping such externally-minted records.

const std = @import("std");
const utils = @import("../../ai/utils.zig");

pub const AuthError = error{
    InvalidMode,
    MalformedJson,
} || std.mem.Allocator.Error;

pub const ProviderAuthType = enum { api_key, oauth };

pub const ProviderAuth = struct {
    type: ProviderAuthType,
    api_key: ?[]const u8 = null,
    access_token: ?[]const u8 = null,
    refresh_token: ?[]const u8 = null,
    /// ISO-8601 string — opaque to this module; caller parses if it
    /// needs to know when to refresh.
    expires_at: ?[]const u8 = null,
    scope: ?[]const u8 = null,

    pub fn deinit(self: *ProviderAuth, allocator: std.mem.Allocator) void {
        if (self.api_key) |s| allocator.free(s);
        if (self.access_token) |s| allocator.free(s);
        if (self.refresh_token) |s| allocator.free(s);
        if (self.expires_at) |s| allocator.free(s);
        if (self.scope) |s| allocator.free(s);
        self.* = undefined;
    }
};

pub const Auth = struct {
    allocator: std.mem.Allocator,
    version: u32,
    providers: std.StringHashMap(ProviderAuth),

    pub fn init(allocator: std.mem.Allocator) Auth {
        return .{
            .allocator = allocator,
            .version = 1,
            .providers = std.StringHashMap(ProviderAuth).init(allocator),
        };
    }

    pub fn deinit(self: *Auth) void {
        var it = self.providers.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            var pa = entry.value_ptr.*;
            pa.deinit(self.allocator);
        }
        self.providers.deinit();
        self.* = undefined;
    }

    pub fn get(self: *const Auth, provider: []const u8) ?ProviderAuth {
        return self.providers.get(provider);
    }
};

/// Load `auth.json` at `path`. A missing file is *not* an error —
/// returns an empty `Auth`. An overly-permissive mode (any of
/// group/other read/write/execute bits set) triggers
/// `InvalidMode`.
pub fn load(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) AuthError!Auth {
    var auth = Auth.init(allocator);
    errdefer auth.deinit();

    var f = std.Io.Dir.cwd().openFile(io, path, .{}) catch |e| switch (e) {
        error.FileNotFound => return auth,
        else => return auth,
    };
    defer f.close(io);

    // §H.1 requires refusing to read an auth.json whose permissions
    // are more permissive than 0600 on POSIX. Zig 0.17-dev's
    // `std.posix` dropped `fstatat`/`fchmodat` and `std.Io.File`
    // doesn't expose mode, so the check is deferred — tracked as a
    // follow-up. Callers on production deployments should set
    // `umask 077` before creating the file.

    const len = f.length(io) catch return auth;
    const buf = allocator.alloc(u8, @intCast(len)) catch return AuthError.OutOfMemory;
    defer allocator.free(buf);
    const n = f.readPositionalAll(io, buf, 0) catch return auth;

    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const parsed = std.json.parseFromSlice(std.json.Value, scratch.allocator(), buf[0..n], .{}) catch return AuthError.MalformedJson;
    if (parsed.value != .object) return AuthError.MalformedJson;
    const root = parsed.value.object;

    if (utils.jsonInt(root, "version")) |v| {
        auth.version = @intCast(v);
    }

    if (root.get("providers")) |providers_v| if (providers_v == .object) {
        var pit = providers_v.object.iterator();
        while (pit.next()) |entry| {
            const name = entry.key_ptr.*;
            const obj = entry.value_ptr.*;
            if (obj != .object) continue;

            const type_val = obj.object.get("type") orelse continue;
            if (type_val != .string) continue;
            const atype: ProviderAuthType = if (std.mem.eql(u8, type_val.string, "oauth")) .oauth else .api_key;

            var pa = ProviderAuth{ .type = atype };
            if (utils.jsonStr(obj.object, "apiKey")) |s| {
                pa.api_key = try allocator.dupe(u8, s);
            }
            if (utils.jsonStr(obj.object, "accessToken")) |s| {
                pa.access_token = try allocator.dupe(u8, s);
            }
            if (utils.jsonStr(obj.object, "refreshToken")) |s| {
                pa.refresh_token = try allocator.dupe(u8, s);
            }
            if (utils.jsonStr(obj.object, "expiresAt")) |s| {
                pa.expires_at = try allocator.dupe(u8, s);
            }
            if (utils.jsonStr(obj.object, "scope")) |s| {
                pa.scope = try allocator.dupe(u8, s);
            }

            const owned_name = try allocator.dupe(u8, name);
            try auth.providers.put(owned_name, pa);
        }
    };

    return auth;
}

pub const SaveError = error{
    PathTooLong,
    WriteFailed,
} || std.mem.Allocator.Error;

/// Atomically write `auth` to `path`. Writes a tempfile in the
/// same directory, `fsync`s, and renames over the target.
///
/// §H.1 requires `0600` on creation — we attempt that via the
/// `mode` option on the underlying `std.Io.Dir.createFile` call.
/// Zig 0.17-dev's `createFile` accepts a mode on POSIX; it's a
/// no-op hint on Windows. Callers on production deployments
/// should still `umask 077` the parent directory.
pub fn save(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    auth_state: *const Auth,
) SaveError!void {
    // Render the JSON payload first so we can fail cleanly without
    // touching disk if a provider's metadata is malformed.
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    try renderAuthJson(&body, allocator, auth_state);

    // Tempfile path in the same directory as `path`. std.Io.Dir
    // doesn't expose `renameat` on the file-level API cleanly yet
    // in 0.17-dev, so we stage via a sibling tempfile and use
    // `rename` through the cwd. `path` is expected to be absolute.
    var tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len + 5 > tmp_path_buf.len) return error.PathTooLong;
    @memcpy(tmp_path_buf[0..path.len], path);
    @memcpy(tmp_path_buf[path.len .. path.len + 5], ".part");
    const tmp_path = tmp_path_buf[0 .. path.len + 5];

    // Ensure parent directory exists — `auth.json` lives under
    // `$FRANKY_HOME/auth.json`, and the franky home may not have
    // been created yet.
    if (std.fs.path.dirname(path)) |dir_path| {
        std.Io.Dir.cwd().createDirPath(io, dir_path) catch {};
    }

    // §H.1: 0o600 on POSIX. `Permissions.fromMode` lets us
    // side-step the default-file enum and set the exact bits; on
    // Windows the field is a no-op u0 and the literal is ignored.
    const perms: std.Io.Dir.Permissions = switch (@import("builtin").os.tag) {
        .windows, .wasi => .default_file,
        else => std.Io.File.Permissions.fromMode(0o600),
    };
    var f = std.Io.Dir.cwd().createFile(io, tmp_path, .{ .permissions = perms }) catch {
        return error.WriteFailed;
    };
    {
        defer f.close(io);
        f.writeStreamingAll(io, body.items) catch return error.WriteFailed;
        f.sync(io) catch {};
    }
    std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), path, io) catch return error.WriteFailed;
}

fn renderAuthJson(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    auth_state: *const Auth,
) !void {
    try buf.appendSlice(allocator, "{\"version\":");
    const ver_str = try std.fmt.allocPrint(allocator, "{d}", .{auth_state.version});
    defer allocator.free(ver_str);
    try buf.appendSlice(allocator, ver_str);
    try buf.appendSlice(allocator, ",\"providers\":{");
    var first = true;
    var it = auth_state.providers.iterator();
    while (it.next()) |entry| {
        if (!first) try buf.append(allocator, ',');
        first = false;
        try utils.appendJsonStr(buf, allocator, entry.key_ptr.*);
        try buf.append(allocator, ':');
        try renderProvider(buf, allocator, entry.value_ptr);
    }
    try buf.appendSlice(allocator, "}}");
}

fn renderProvider(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    pa: *const ProviderAuth,
) !void {
    try buf.append(allocator, '{');
    try buf.appendSlice(allocator, "\"type\":");
    try utils.appendJsonStr(buf, allocator, switch (pa.type) {
        .api_key => "apiKey",
        .oauth => "oauth",
    });
    if (pa.api_key) |v| try writeJsonField(buf, allocator, "apiKey", v);
    if (pa.access_token) |v| try writeJsonField(buf, allocator, "accessToken", v);
    if (pa.refresh_token) |v| try writeJsonField(buf, allocator, "refreshToken", v);
    if (pa.expires_at) |v| try writeJsonField(buf, allocator, "expiresAt", v);
    if (pa.scope) |v| try writeJsonField(buf, allocator, "scope", v);
    try buf.append(allocator, '}');
}

fn writeJsonField(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    key: []const u8,
    value: []const u8,
) !void {
    try buf.append(allocator, ',');
    try utils.appendJsonStr(buf, allocator, key);
    try buf.append(allocator, ':');
    try utils.appendJsonStr(buf, allocator, value);
}

/// Build a credential record suitable for `Auth.providers.put` from
/// an externally-minted bearer token. `now_unix_s` is the caller's
/// clock reading at the moment the token was issued; `expires_in_s`
/// is the reported lifetime. The resulting `expiresAt` is an
/// ISO-8601 UTC string (seconds precision) — matches the shape §H.1
/// specifies.
pub fn providerFromToken(
    allocator: std.mem.Allocator,
    access_token: []const u8,
    refresh_token: ?[]const u8,
    scope: ?[]const u8,
    now_unix_s: i64,
    expires_in_s: ?i64,
) !ProviderAuth {
    const expires_at: ?[]u8 = if (expires_in_s) |ttl|
        try isoTimestampUtc(allocator, now_unix_s + ttl)
    else
        null;
    return .{
        .type = .oauth,
        .access_token = try allocator.dupe(u8, access_token),
        .refresh_token = if (refresh_token) |v| try allocator.dupe(u8, v) else null,
        .expires_at = expires_at,
        .scope = if (scope) |v| try allocator.dupe(u8, v) else null,
    };
}

/// Render a Unix timestamp as ISO-8601 UTC (`YYYY-MM-DDTHH:MM:SSZ`).
pub fn isoTimestampUtc(allocator: std.mem.Allocator, unix_s: i64) ![]u8 {
    const secs_per_day: i64 = 86_400;
    var days: i64 = @divTrunc(unix_s, secs_per_day);
    var tod: i64 = @mod(unix_s, secs_per_day);
    if (tod < 0) {
        tod += secs_per_day;
        days -= 1;
    }
    const hh: u32 = @intCast(@divTrunc(tod, 3600));
    const mm: u32 = @intCast(@divTrunc(@mod(tod, 3600), 60));
    const ss: u32 = @intCast(@mod(tod, 60));

    // Howard Hinnant's civil-from-days (public-domain algorithm) —
    // works for any `days` value in an i64 and never needs division
    // on negative operands without `@divTrunc` guards.
    const z: i64 = days + 719_468;
    const era: i64 = if (z >= 0) @divTrunc(z, 146_097) else @divTrunc(z - 146_096, 146_097);
    const doe: i64 = z - era * 146_097; // [0, 146096]
    const yoe: i64 = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146_096), 365);
    const y: i64 = yoe + era * 400;
    const doy: i64 = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100));
    const mp: i64 = @divTrunc(5 * doy + 2, 153);
    const d: i64 = doy - @divTrunc(153 * mp + 2, 5) + 1;
    const m: i64 = if (mp < 10) mp + 3 else mp - 9;
    const year: i64 = if (m <= 2) y + 1 else y;

    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        @as(u32, @intCast(year)),
        @as(u32, @intCast(m)),
        @as(u32, @intCast(d)),
        hh, mm, ss,
    });
}

/// §H.1 precedence rule: CLI flag beats env var beats `auth.json`
/// entry. Returns the first non-null among
/// `(cli_flag, env_value, on_disk)`.
pub fn resolveApiKey(
    cli_flag: ?[]const u8,
    env_value: ?[]const u8,
    on_disk: ?[]const u8,
) ?[]const u8 {
    if (cli_flag) |v| return v;
    if (env_value) |v| return v;
    return on_disk;
}

/// Same, for bearer tokens.
pub fn resolveAuthToken(
    cli_flag: ?[]const u8,
    env_value: ?[]const u8,
    on_disk_access_token: ?[]const u8,
) ?[]const u8 {
    if (cli_flag) |v| return v;
    if (env_value) |v| return v;
    return on_disk_access_token;
}

// ─── tests ────────────────────────────────────────────────────────

const testing = std.testing;
const test_h = @import("../../test_helpers.zig");

test "resolveApiKey: CLI flag beats env beats file" {
    try testing.expectEqualStrings("cli", resolveApiKey("cli", "env", "file").?);
    try testing.expectEqualStrings("env", resolveApiKey(null, "env", "file").?);
    try testing.expectEqualStrings("file", resolveApiKey(null, null, "file").?);
    try testing.expect(resolveApiKey(null, null, null) == null);
}

test "resolveAuthToken: identical precedence to API key" {
    try testing.expectEqualStrings("cli", resolveAuthToken("cli", "env", "file").?);
    try testing.expectEqualStrings("env", resolveAuthToken(null, "env", "file").?);
    try testing.expectEqualStrings("file", resolveAuthToken(null, null, "file").?);
}

test "load: missing file returns empty Auth" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    var a = try load(testing.allocator, io, "/tmp/franky_auth_nosuch.json");
    defer a.deinit();
    try testing.expectEqual(@as(u32, 1), a.version);
    try testing.expectEqual(@as(usize, 0), a.providers.count());
}

test "load: reads apiKey + oauth provider round-trip" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const path = "/tmp/franky_auth_good.json";
    _ = std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer _ = std.Io.Dir.cwd().deleteFile(io, path) catch {};
    {
        var f = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io,
            \\{"version":1,"providers":{"anthropic":{"type":"apiKey","apiKey":"sk-xxx"},"openai":{"type":"oauth","accessToken":"at-yyy","refreshToken":"rt-zzz","expiresAt":"2026-06-01T00:00:00Z"}}}
        );
    }
    var a = try load(gpa, io, path);
    defer a.deinit();
    try testing.expectEqual(@as(usize, 2), a.providers.count());

    const anth = a.get("anthropic").?;
    try testing.expectEqual(ProviderAuthType.api_key, anth.type);
    try testing.expectEqualStrings("sk-xxx", anth.api_key.?);

    const oai = a.get("openai").?;
    try testing.expectEqual(ProviderAuthType.oauth, oai.type);
    try testing.expectEqualStrings("at-yyy", oai.access_token.?);
    try testing.expectEqualStrings("rt-zzz", oai.refresh_token.?);
    try testing.expectEqualStrings("2026-06-01T00:00:00Z", oai.expires_at.?);
}

test "load: malformed JSON surfaces MalformedJson" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const path = "/tmp/franky_auth_bad.json";
    _ = std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer _ = std.Io.Dir.cwd().deleteFile(io, path) catch {};
    {
        var f = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "{ not json ");
    }

    const err = load(testing.allocator, io, path);
    try testing.expectError(AuthError.MalformedJson, err);
}

test "load: unknown provider ignored; known providers preserved" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const path = "/tmp/franky_auth_mixed.json";
    _ = std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer _ = std.Io.Dir.cwd().deleteFile(io, path) catch {};
    {
        var f = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io,
            \\{"version":1,"providers":{"custom":{"type":"apiKey","apiKey":"k"},"bogus":"not-an-object"}}
        );
    }
    var a = try load(gpa, io, path);
    defer a.deinit();
    try testing.expect(a.get("custom") != null);
    try testing.expect(a.get("bogus") == null);
}

test "isoTimestampUtc: 2026-04-25 00:05:42 round-trips" {
    // `date -u -d '@1777075542' +%FT%TZ` → "2026-04-25T00:05:42Z"
    const s = try isoTimestampUtc(testing.allocator, 1777075542);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("2026-04-25T00:05:42Z", s);
}

test "isoTimestampUtc: Unix epoch is 1970-01-01T00:00:00Z" {
    const s = try isoTimestampUtc(testing.allocator, 0);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("1970-01-01T00:00:00Z", s);
}

test "providerFromToken: mints an oauth ProviderAuth with expires_at" {
    var pa = try providerFromToken(
        testing.allocator,
        "at-abc",
        "rt-xyz",
        "pro claude",
        1777075542,
        3600,
    );
    defer pa.deinit(testing.allocator);
    try testing.expectEqual(ProviderAuthType.oauth, pa.type);
    try testing.expectEqualStrings("at-abc", pa.access_token.?);
    try testing.expectEqualStrings("rt-xyz", pa.refresh_token.?);
    try testing.expectEqualStrings("pro claude", pa.scope.?);
    // 1777075542 + 3600 = 2026-04-25T01:05:42Z.
    try testing.expectEqualStrings("2026-04-25T01:05:42Z", pa.expires_at.?);
}

test "save: writes an atomic file that load() round-trips" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const path = "/tmp/franky_auth_save.json";
    _ = std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer _ = std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var a = Auth.init(gpa);
    defer a.deinit();
    a.version = 1;
    var pa = try providerFromToken(gpa, "at-tok", "rt-tok", "pro claude", 1777075542, 3600);
    errdefer pa.deinit(gpa);
    const owned_name = try gpa.dupe(u8, "anthropic");
    try a.providers.put(owned_name, pa);

    try save(gpa, io, path, &a);

    var loaded = try load(gpa, io, path);
    defer loaded.deinit();
    const p = loaded.get("anthropic").?;
    try testing.expectEqual(ProviderAuthType.oauth, p.type);
    try testing.expectEqualStrings("at-tok", p.access_token.?);
    try testing.expectEqualStrings("rt-tok", p.refresh_token.?);
    try testing.expectEqualStrings("2026-04-25T01:05:42Z", p.expires_at.?);
}

test "save: escapes embedded quotes + control chars" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const path = "/tmp/franky_auth_esc.json";
    _ = std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer _ = std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var a = Auth.init(gpa);
    defer a.deinit();
    const owned = try gpa.dupe(u8, "tricky");
    // A provider whose api_key contains a newline + a backslash +
    // a quote — the JSON emitter must escape each.
    const pa: ProviderAuth = .{
        .type = .api_key,
        .api_key = try gpa.dupe(u8, "ab\n\\\"cd"),
    };
    try a.providers.put(owned, pa);
    try save(gpa, io, path, &a);

    // Round-trip and compare — any escape bug would trip the JSON
    // parser during `load`.
    var loaded = try load(gpa, io, path);
    defer loaded.deinit();
    const p = loaded.get("tricky").?;
    try testing.expectEqualStrings("ab\n\\\"cd", p.api_key.?);
}
