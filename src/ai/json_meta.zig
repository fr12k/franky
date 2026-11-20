//! Generic JSON (de)serialization helpers with `json_meta` metadata.
//!
//! This module provides a reusable pattern for plugging plain Zig structs
//! into `std.json`'s `jsonStringify` / `jsonParseFromValue` hooks while
//! supporting field renaming and field skipping — capabilities the stdlib
//! does not provide out of the box.
//!
//! ## Why
//!
//! `std.json.Stringify` and `std.json.parseFromValue` already handle
//! nested structs, slices, optionals, escaping, and number formatting
//! automatically. The only gaps are:
//!
//!   1. **Field renaming** — wire formats use `camelCase` or
//!      `snake_case` names that differ from Zig struct field names.
//!   2. **Field skipping** — some fields should never appear on the wire.
//!   3. **Comptime typo validation** — a misspelled key string in manual
//!      `appendSlice("\"createdAtMs\":")` code compiles fine and silently
//!      corrupts the wire format.
//!
//! This module closes all three gaps with a single `json_meta` anonymous
//! struct declaration per type.
//!
//! ## Usage
//!
//! ```zig
//! const json_meta = @import("json_meta.zig");
//!
//! pub const User = struct {
//!     id: u32,
//!     first_name: []const u8,
//!     password_hash: []const u8,
//!
//!     pub const json_meta = .{
//!         .first_name = .{ .rename = "firstName" },
//!         .password_hash = .{ .skip = true },
//!     };
//!
//!     pub fn jsonStringify(self: @This(), jw: anytype) !void {
//!         try json_meta.stringifyWithMeta(self, jw);
//!     }
//! };
//! ```
//!
//! Uncommenting `.typo_field = .{ .skip = true }` in `json_meta` produces
//! a clean `@compileError` at the use site — no more silent wire-format
//! corruption from misspelled keys.

const std = @import("std");

/// Per-field configuration for `json_meta`.
pub const FieldConfig = struct {
    /// Override the JSON key name for this field. When `null`, the Zig
    /// field name is used as-is.
    rename: ?[]const u8 = null,
    /// When `true`, the field is never emitted during serialization.
    /// (On the parse side the field simply retains its default value.)
    skip: bool = false,
};

/// Look up the `FieldConfig` for a struct field, consulting the type's
/// `json_meta` declaration if present. Returns `.{}` (all defaults) when
/// no metadata is declared or the field has no entry.
pub fn fieldConfig(comptime T: type, comptime field_name: []const u8) FieldConfig {
    if (!@hasDecl(T, "json_meta")) return .{};
    const Meta = @TypeOf(T.json_meta);
    if (!@hasField(Meta, field_name)) return .{};
    const raw = @field(T.json_meta, field_name);
    const Raw = @TypeOf(raw);
    return .{
        .rename = if (@hasField(Raw, "rename")) raw.rename else null,
        .skip = if (@hasField(Raw, "skip")) raw.skip else false,
    };
}

/// Generic `jsonStringify` implementation that respects `json_meta`.
///
/// Call this from a struct's `pub fn jsonStringify` hook. It:
///   1. Validates at comptime that every field named in `json_meta`
///      actually exists on `T` (catches typos before any binary is built).
///   2. Emits a JSON object with renamed/skipped fields, delegating all
///      value writing (escaping, nesting, optionals) to `std.json`.
pub fn stringifyWithMeta(self: anytype, jw: anytype) !void {
    const T = @TypeOf(self);
    const struct_info = @typeInfo(T).@"struct";

    // 1. Comptime typo check — verify every json_meta field exists on T.
    if (@hasDecl(T, "json_meta")) {
        const Meta = @TypeOf(T.json_meta);
        const meta_info = @typeInfo(Meta).@"struct";
        inline for (meta_info.field_names) |meta_field_name| {
            if (!@hasField(T, meta_field_name)) {
                @compileError(
                    "json_meta on '" ++ @typeName(T) ++
                        "' references non-existent field '" ++ meta_field_name ++ "'",
                );
            }
        }
    }

    // 2. Emit the object, applying rename/skip per field.
    //    Also honour `emit_null_optional_fields = false` for optional
    //    fields whose value is `null`, mirroring the stdlib's default
    //    struct serializer (Stringify.zig:464-471).
    try jw.beginObject();
    inline for (struct_info.field_names, struct_info.field_types) |field_name, field_type| {
        const cfg = fieldConfig(T, field_name);
        if (!cfg.skip) {
            const is_optional = @typeInfo(field_type) == .optional;
            if (is_optional) {
                // For optional fields, respect emit_null_optional_fields.
                if (jw.options.emit_null_optional_fields or @field(self, field_name) != null) {
                    const key = cfg.rename orelse field_name;
                    try jw.objectField(key);
                    try jw.write(@field(self, field_name));
                }
            } else {
                const key = cfg.rename orelse field_name;
                try jw.objectField(key);
                try jw.write(@field(self, field_name));
            }
        }
    }
    try jw.endObject();
}

// ─── tests ───────────────────────────────────────────────────────────

const testing = std.testing;

const TestUser = struct {
    id: u32,
    first_name: []const u8,
    password_hash: []const u8,
    tags: []const []const u8,
    nickname: ?[]const u8 = null,

    pub const json_meta = .{
        .first_name = .{ .rename = "firstName" },
        .password_hash = .{ .skip = true },
    };

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try stringifyWithMeta(self, jw);
    }
};

test "stringifyWithMeta: rename + skip" {
    const user = TestUser{
        .id = 42,
        .first_name = "Alice \"The Coder\"",
        .password_hash = "super_secret",
        .tags = &.{ "admin", "zig" },
    };
    const json_str = try std.json.Stringify.valueAlloc(testing.allocator, user, .{
        .emit_null_optional_fields = false,
    });
    defer testing.allocator.free(json_str);

    // password_hash is skipped, first_name is renamed to firstName,
    // null nickname is omitted via emit_null_optional_fields = false.
    try testing.expectEqualStrings(
        "{\"id\":42,\"firstName\":\"Alice \\\"The Coder\\\"\",\"tags\":[\"admin\",\"zig\"]}",
        json_str,
    );
}

test "stringifyWithMeta: null optional omitted with emit_null_optional_fields=false" {
    const user = TestUser{
        .id = 99,
        .first_name = "Bob",
        .password_hash = "hash",
        .tags = &.{},
        .nickname = null,
    };
    const json_str = try std.json.Stringify.valueAlloc(testing.allocator, user, .{
        .emit_null_optional_fields = false,
    });
    defer testing.allocator.free(json_str);

    // nickname is null and omitted; password_hash is skipped.
    try testing.expectEqualStrings(
        "{\"id\":99,\"firstName\":\"Bob\",\"tags\":[]}",
        json_str,
    );
}
