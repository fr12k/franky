//! Shared JSON and Utility functions for all AI providers.

const std = @import("std");

/// Appends a JSON-encoded string to the buffer, escaping necessary characters.
pub fn appendJsonStr(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try buf.append(allocator, '"');
    for (s) |c| switch (c) {
        '"' => try buf.appendSlice(allocator, "\\\""),
        '\\' => try buf.appendSlice(allocator, "\\\\"),
        '\n' => try buf.appendSlice(allocator, "\\n"),
        '\r' => try buf.appendSlice(allocator, "\\r"),
        '\t' => try buf.appendSlice(allocator, "\\t"),
        0...0x07, 0x0b, 0x0e...0x1f => {
            var tmp: [8]u8 = undefined;
            const written = std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{c}) catch unreachable;
            try buf.appendSlice(allocator, written);
        },
        else => try buf.append(allocator, c),
    };
    try buf.append(allocator, '"');
}

/// Appends JSON raw data (no escaping applied), used for URIs or fragments.
pub fn appendJsonRaw(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try buf.appendSlice(allocator, s);
}

pub fn appendJsonInt(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, n: i64) !void {
    var tmp: [20]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{n}) catch unreachable;
    try buf.appendSlice(allocator, s);
}

pub fn appendJsonFloat(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, f: f32) !void {
    var tmp: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{f}) catch unreachable;
    try buf.appendSlice(allocator, s);
}

/// v1.16.2 — repair backslash escapes in a string that's claimed to be
/// valid JSON. Walks the input; when a `\` is followed by something
/// other than a valid JSON escape character (`"\/bfnrt` or `u<4hex>`),
/// doubles the backslash so the result decodes to a string with a
/// literal backslash at that position instead of failing JSON parse.
///
/// **Why this exists.** Some open-source models (Gemma, Llama variants
/// served via gateways like Cloudflare Workers AI) emit invalid JSON
/// in `tool_call.arguments` — most commonly a stray `\c` sequence the
/// model meant as a literal backslash before code. Anthropic and OpenAI
/// proper treat `arguments` as opaque so these slip through; strict
/// validators (Cloudflare's openai-compat) parse `arguments` as JSON
/// and 400 the entire request. Sanitization at re-emission keeps
/// franky talking to strict gateways even when the upstream model is
/// sloppy.
///
/// Returns an owned slice (caller frees). Always allocates — even if
/// no fix is needed — so the caller can free unconditionally.
pub fn sanitizeJsonString(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.ensureTotalCapacity(allocator, input.len);

    var i: usize = 0;
    while (i < input.len) {
        const c = input[i];
        if (c != '\\') {
            try buf.append(allocator, c);
            i += 1;
            continue;
        }
        // c == '\\'. Look ahead.
        if (i + 1 >= input.len) {
            // Trailing lone backslash → escape it.
            try buf.appendSlice(allocator, "\\\\");
            i += 1;
            continue;
        }
        const next = input[i + 1];
        switch (next) {
            '"', '\\', '/', 'b', 'f', 'n', 'r', 't' => {
                // Valid one-char escape — pass through.
                try buf.append(allocator, '\\');
                try buf.append(allocator, next);
                i += 2;
            },
            'u' => {
                // \uXXXX needs 4 hex digits. If short or non-hex,
                // treat the `\u` as a malformed escape and double
                // the backslash.
                if (i + 5 < input.len and
                    isHexDigit(input[i + 2]) and isHexDigit(input[i + 3]) and
                    isHexDigit(input[i + 4]) and isHexDigit(input[i + 5]))
                {
                    try buf.appendSlice(allocator, input[i .. i + 6]);
                    i += 6;
                } else {
                    try buf.appendSlice(allocator, "\\\\");
                    i += 1;
                }
            },
            else => {
                // Invalid escape (`\c`, `\x`, …). Double the backslash
                // so JSON parse sees a literal `\` followed by `next`.
                try buf.appendSlice(allocator, "\\\\");
                i += 1;
            },
        }
    }

    return buf.toOwnedSlice(allocator);
}

fn isHexDigit(c: u8) bool {
    return (c >= '0' and c <= '9') or
        (c >= 'a' and c <= 'f') or
        (c >= 'A' and c <= 'F');
}

// ─── JSON-schema sanitization ────────────────────────────────────
//
// Some providers reject keys the standard JSON-Schema spec allows
// (`additionalProperties`, `$schema`, `$defs`, …). Each provider
// keeps its own vendor-specific key list; the walk/strip/re-stringify
// machinery is identical and lives here so it isn't forked per
// provider. See `DEDUP_PLAN.md` Finding 2.

/// Recursively strip `unsupported_keys` from `v`'s objects, in place.
/// Array elements are walked too so unsupported keywords nested inside
/// `items` (e.g. an array of edit-records) are removed.
pub fn sanitizeSchemaValue(v: *std.json.Value, unsupported_keys: []const []const u8) void {
    switch (v.*) {
        .object => |*obj| {
            for (unsupported_keys) |k| _ = obj.swapRemove(k);
            var it = obj.iterator();
            while (it.next()) |entry| sanitizeSchemaValue(entry.value_ptr, unsupported_keys);
        },
        .array => |*arr| {
            for (arr.items) |*item| sanitizeSchemaValue(item, unsupported_keys);
        },
        else => {},
    }
}

/// Parse `schema_json`, walk it recursively dropping `unsupported_keys`,
/// then serialize the result back into `buf`.
///
/// Fast path (most schemas): a substring scan. If none of the
/// unsupported keywords appear, the schema is already valid for the
/// provider and we inline it verbatim — skipping the parse / walk /
/// re-stringify entirely. This is the common case and avoids ~1KB of
/// allocations × N tools per HTTP request.
///
/// Falls back to inlining the original (unsanitized) schema if parsing
/// fails — better to attempt a request with the original than to fail
/// closed; the provider will return its own error which the user can
/// act on.
pub fn appendSanitizedSchema(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    schema_json: []const u8,
    unsupported_keys: []const []const u8,
) !void {
    var needs_sanitize = false;
    for (unsupported_keys) |key| {
        if (std.mem.indexOf(u8, schema_json, key) != null) {
            needs_sanitize = true;
            break;
        }
    }
    if (!needs_sanitize) {
        try buf.appendSlice(allocator, schema_json);
        return;
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aalloc = arena.allocator();

    const parsed = std.json.parseFromSlice(std.json.Value, aalloc, schema_json, .{}) catch {
        try buf.appendSlice(allocator, schema_json);
        return;
    };
    var root = parsed.value;
    sanitizeSchemaValue(&root, unsupported_keys);

    const out = std.json.Stringify.valueAlloc(aalloc, root, .{}) catch {
        try buf.appendSlice(allocator, schema_json);
        return;
    };
    try buf.appendSlice(allocator, out);
}

// ─── tests ──────────────────────────────────────────────────────

const testing = std.testing;

test "appendSanitizedSchema: fast-path inlines when no unsupported keys present" {
    const gpa = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const keys = [_][]const u8{ "additionalProperties", "$schema" };
    const schema = "{\"type\":\"object\"}";
    try appendSanitizedSchema(&buf, gpa, schema, &keys);
    try testing.expectEqualStrings(schema, buf.items);
}

test "appendSanitizedSchema: strips unsupported keys recursively" {
    const gpa = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const keys = [_][]const u8{ "additionalProperties", "$schema" };
    const schema =
        \\{"type":"object","additionalProperties":false,"$schema":"x","properties":{"p":{"type":"string","additionalProperties":true}}}
    ;
    try appendSanitizedSchema(&buf, gpa, schema, &keys);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, buf.items, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expect(root.get("type") != null);
    try testing.expect(root.get("additionalProperties") == null);
    try testing.expect(root.get("$schema") == null);
    const p = root.get("properties").?.object.get("p").?.object;
    try testing.expect(p.get("additionalProperties") == null);
}

test "appendSanitizedSchema: malformed JSON falls back to verbatim" {
    const gpa = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const keys = [_][]const u8{"additionalProperties"};
    const bad = "{not json but has additionalProperties";
    try appendSanitizedSchema(&buf, gpa, bad, &keys);
    try testing.expectEqualStrings(bad, buf.items);
}

test "sanitizeJsonString: valid JSON passes through unchanged" {
    const gpa = testing.allocator;
    const input = "{\"path\": \"/etc/hosts\", \"newline\": \"\\n\", \"tab\": \"\\t\"}";
    const out = try sanitizeJsonString(gpa, input);
    defer gpa.free(out);
    try testing.expectEqualStrings(input, out);
}

test "sanitizeJsonString: \\c gets doubled to \\\\c" {
    const gpa = testing.allocator;
    const input = "<|\\const utils";
    const out = try sanitizeJsonString(gpa, input);
    defer gpa.free(out);
    try testing.expectEqualStrings("<|\\\\const utils", out);
}

test "sanitizeJsonString: trailing lone backslash is escaped" {
    const gpa = testing.allocator;
    const input = "trailing\\";
    const out = try sanitizeJsonString(gpa, input);
    defer gpa.free(out);
    try testing.expectEqualStrings("trailing\\\\", out);
}

test "sanitizeJsonString: \\uXXXX with valid hex passes through" {
    const gpa = testing.allocator;
    const input = "snowman: \\u2603";
    const out = try sanitizeJsonString(gpa, input);
    defer gpa.free(out);
    try testing.expectEqualStrings(input, out);
}

test "sanitizeJsonString: truncated \\u escape is doubled" {
    const gpa = testing.allocator;
    // Only 2 hex digits then end-of-string — invalid.
    const input = "short \\u00";
    const out = try sanitizeJsonString(gpa, input);
    defer gpa.free(out);
    try testing.expectEqualStrings("short \\\\u00", out);
}

test "sanitizeJsonString: \\u followed by non-hex is doubled" {
    const gpa = testing.allocator;
    const input = "junk \\uZZZZ";
    const out = try sanitizeJsonString(gpa, input);
    defer gpa.free(out);
    try testing.expectEqualStrings("junk \\\\uZZZZ", out);
}

test "sanitizeJsonString: empty input returns empty" {
    const gpa = testing.allocator;
    const out = try sanitizeJsonString(gpa, "");
    defer gpa.free(out);
    try testing.expectEqualStrings("", out);
}

test "sanitizeJsonString: result decodes through std.json" {
    const gpa = testing.allocator;
    // Simulate the real-world Cloudflare bug:
    // model emitted `{"new":"<|\const x"}` (invalid `\c` escape)
    const broken = "{\"new\":\"<|\\const x\"}";

    // Stuff it into a JSON string — appendJsonStr would produce
    // a JSON-encoded form that Cloudflare's outer parser accepts
    // BUT Cloudflare's strict-validation reparses the inner string
    // as JSON and fails on `\c`.
    //
    // After sanitization, the inner string parses cleanly: `\c` →
    // `\\c` decodes to a literal `\c` in the string content.
    const fixed = try sanitizeJsonString(gpa, broken);
    defer gpa.free(fixed);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), fixed, .{});
    const new_val = parsed.value.object.get("new").?.string;
    try testing.expectEqualStrings("<|\\const x", new_val);
}
