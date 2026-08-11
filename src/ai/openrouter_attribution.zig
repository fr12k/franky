//! OpenRouter app-attribution headers — §openrouter-app-attribution.
//!
//! OpenRouter tracks *app attribution* purely through HTTP headers on
//! every chat-completions request (no registration, no API-key binding):
//!
//!   - `HTTP-Referer`           (required) — unique app identifier / ranking key.
//!   - `X-OpenRouter-Title`     (recommended) — display name in rankings.
//!   - `X-OpenRouter-Categories` (optional) — marketplace categories
//!     (comma-separated, max 2/request, each ≤30 chars, lowercase
//!     hyphen-separated). Recognized Coding-group values include
//!     `cli-agent`, `ide-extension`, `cloud-agent`, `programming-app`.
//!
//! See: https://openrouter.ai/docs/app-attribution
//!
//! This module computes the header slice once (per session config) and
//! returns `null` for non-OpenRouter endpoints, so attribution metadata
//! is never leaked to unrelated gateways (Cerebras, xAI, Ollama, …).
//! The returned slice + duplicated strings are allocated on the caller's
//! arena and ownership transfers with the slice.

const std = @import("std");
const registry_mod = @import("registry.zig");

/// Resolved attribution identity. `referer` and `title` are always
/// present; `categories` is optional (omitted from the wire when null).
pub const Attribution = struct {
    referer: []const u8,
    title: []const u8,
    categories: ?[]const u8 = null,
};

/// Caller-supplied overrides, each independently optional. Any field
/// left null falls back to the corresponding `default_attribution`
/// field. Constructed by the config layer from profile fields
/// (`http_referer`, `openrouter_title`, `openrouter_categories`) and
/// env vars (`FRANKY_HTTP_REFERER`, `FRANKY_OPENROUTER_TITLE`,
/// `FRANKY_OPENROUTER_CATEGORIES`).
pub const Overrides = struct {
    referer: ?[]const u8 = null,
    title: ?[]const u8 = null,
    categories: ?[]const u8 = null,
};

/// Built-in identity for the franky project. A fork / rehost should
/// override `referer` (and usually `title`) via profile/env so it
/// claims its own OpenRouter ranking identity.
pub const default_attribution: Attribution = .{
    .referer = "https://github.com/fr12k/franky",
    .title = "franky",
};

/// True when `base_url`'s host is an OpenRouter endpoint. Matches
/// `openrouter.ai` and any subdomain (`*.openrouter.ai`). Returns
/// false for null, non-`http(s)` schemes, loopback, or unrelated hosts.
pub fn isOpenRouterEndpoint(maybe_url: ?[]const u8) bool {
    const url = maybe_url orelse return false;
    // Strip the scheme.
    const after_scheme = blk: {
        if (std.mem.indexOf(u8, url, "://")) |i| break :blk url[i + 3 ..];
        break :blk url;
    };
    // Extract the host (up to the first port/path/query/fragment).
    const host_end = std.mem.indexOfAny(u8, after_scheme, ":/?#") orelse after_scheme.len;
    const host = after_scheme[0..host_end];
    if (host.len == 0) return false;
    // Exact match or subdomain.
    if (std.mem.eql(u8, host, "openrouter.ai")) return true;
    if (std.mem.endsWith(u8, host, ".openrouter.ai")) return true;
    return false;
}

/// Compute the attribution header slice for a resolved `base_url`.
///
/// Returns `null` when the endpoint is not an OpenRouter host — callers
/// then leave `StreamOptions.headers` null and no attribution metadata
/// is sent. Otherwise returns a heap-allocated slice (caller owns both
/// the slice and the duplicated value strings — they share the
/// allocator's arena lifetime) containing 2 or 3 `StreamOptions.Header`
/// entries:
///
///   - `{ "HTTP-Referer", <referer> }`
///   - `{ "X-OpenRouter-Title", <title> }`
///   - `{ "X-OpenRouter-Categories", <categories> }` (only when non-null)
///
/// `overrides` (any field non-null) take precedence over
/// `default_attribution`. The default identity is used for every field
/// the caller leaves null.
pub fn attributionHeaders(
    allocator: std.mem.Allocator,
    base_url: ?[]const u8,
    overrides: Overrides,
) !?[]registry_mod.StreamOptions.Header {
    if (!isOpenRouterEndpoint(base_url)) return null;

    const referer = overrides.referer orelse default_attribution.referer;
    const title = overrides.title orelse default_attribution.title;
    const categories = overrides.categories;

    const count: usize = if (categories != null) 3 else 2;
    const headers = try allocator.alloc(registry_mod.StreamOptions.Header, count);

    headers[0] = .{
        .name = try allocator.dupe(u8, "HTTP-Referer"),
        .value = try allocator.dupe(u8, referer),
    };
    headers[1] = .{
        .name = try allocator.dupe(u8, "X-OpenRouter-Title"),
        .value = try allocator.dupe(u8, title),
    };
    if (categories) |cats| {
        headers[2] = .{
            .name = try allocator.dupe(u8, "X-OpenRouter-Categories"),
            .value = try allocator.dupe(u8, cats),
        };
    }
    return headers;
}

// ─── tests ────────────────────────────────────────────────────────────

const testing = std.testing;

test "isOpenRouterEndpoint: rejects null" {
    try testing.expect(!isOpenRouterEndpoint(null));
}

test "isOpenRouterEndpoint: rejects unrelated hosts" {
    try testing.expect(!isOpenRouterEndpoint("https://api.openai.com/v1/chat/completions"));
    try testing.expect(!isOpenRouterEndpoint("https://api.cerebras.ai/v1/chat/completions"));
    try testing.expect(!isOpenRouterEndpoint("http://localhost:11434/v1/chat/completions"));
    try testing.expect(!isOpenRouterEndpoint("https://generativelanguage.googleapis.com/v1beta/models"));
}

test "isOpenRouterEndpoint: accepts openrouter.ai and subdomains" {
    try testing.expect(isOpenRouterEndpoint("https://openrouter.ai/api/v1/chat/completions"));
    try testing.expect(isOpenRouterEndpoint("https://api.openrouter.ai/api/v1/chat/completions"));
}

test "isOpenRouterEndpoint: handles missing scheme / empty host" {
    // A bare host with no scheme is treated as the host itself;
    // `openrouter.ai` is recognized (harmless and more robust), while
    // an empty host / scheme-only URLs are rejected.
    try testing.expect(isOpenRouterEndpoint("openrouter.ai"));
    try testing.expect(!isOpenRouterEndpoint(""));
    try testing.expect(!isOpenRouterEndpoint("https:///path"));
}

test "attributionHeaders: returns null for non-openrouter host" {
    const h = try attributionHeaders(testing.allocator, "https://api.openai.com/v1", .{});
    try testing.expect(h == null);
}

test "attributionHeaders: defaults produce 2 headers" {
    const h = (try attributionHeaders(testing.allocator, "https://openrouter.ai/api/v1/chat/completions", .{})).?;
    defer {
        for (h) |hdr| {
            testing.allocator.free(hdr.name);
            testing.allocator.free(hdr.value);
        }
        testing.allocator.free(h);
    }
    try testing.expectEqual(@as(usize, 2), h.len);
    try testing.expectEqualStrings("HTTP-Referer", h[0].name);
    try testing.expectEqualStrings("https://github.com/fr12k/franky", h[0].value);
    try testing.expectEqualStrings("X-OpenRouter-Title", h[1].name);
    try testing.expectEqualStrings("franky", h[1].value);
}

test "attributionHeaders: overrides win and categories add a 3rd header" {
    const h = (try attributionHeaders(testing.allocator, "https://openrouter.ai/api/v1/chat/completions", .{
        .referer = "https://myfork.example",
        .title = "myfork",
        .categories = "cli-agent",
    })).?;
    defer {
        for (h) |hdr| {
            testing.allocator.free(hdr.name);
            testing.allocator.free(hdr.value);
        }
        testing.allocator.free(h);
    }
    try testing.expectEqual(@as(usize, 3), h.len);
    try testing.expectEqualStrings("https://myfork.example", h[0].value);
    try testing.expectEqualStrings("myfork", h[1].value);
    try testing.expectEqualStrings("X-OpenRouter-Categories", h[2].name);
    try testing.expectEqualStrings("cli-agent", h[2].value);
}

test "attributionHeaders: partial override falls back to defaults" {
    const h = (try attributionHeaders(testing.allocator, "https://openrouter.ai/api/v1/chat/completions", .{
        .title = "custom-title",
    })).?;
    defer {
        for (h) |hdr| {
            testing.allocator.free(hdr.name);
            testing.allocator.free(hdr.value);
        }
        testing.allocator.free(h);
    }
    try testing.expectEqual(@as(usize, 2), h.len);
    // referer fell back to default
    try testing.expectEqualStrings("https://github.com/fr12k/franky", h[0].value);
    // title overridden
    try testing.expectEqualStrings("custom-title", h[1].value);
}

test "default_attribution: referer is the project GitHub URL" {
    try testing.expectEqualStrings("https://github.com/fr12k/franky", default_attribution.referer);
    try testing.expectEqualStrings("franky", default_attribution.title);
    try testing.expect(default_attribution.categories == null);
}