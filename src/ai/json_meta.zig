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
//!   4. **Per-field value formatting** — `std.json.Stringify.write(f32)`
//!      falls back to full precision (e.g. `0.30000001192092896`) whenever
//!      the f32→f64 cast is not exact; `.format = .shortest_float` renders
//!      the value with `{d}` (shortest round-trip, e.g. `0.3`) instead.
//!   5. **Omitting default-valued fields** — wire shapes that drop zero
//!      ints / false bools / empty strings use `.omit_default = true`.
//!   6. **Leading constant envelope fields** — a module-level constant
//!      (e.g. a schema `version`) that isn't stored on the struct is
//!      emitted first via `pub const json_prefix = .{ ... };`.
//!   7. **Forced-decimal floats** — cost fields that must round-trip as
//!      `.float` (not `.integer`) use `.format = .float_force_decimal`
//!      (`0.0` not `0`).
//!   8. **Derived wire values** — `.compute = "method"` serializes a
//!      zero-arg struct method's return instead of the stored field
//!      (e.g. `input_tokens = uncached portion`).
//!   9. **Multi-key parse aliases** — `.aliases = &.{ "oldName" }` accepts
//!      legacy/alternate wire keys on parse (multi-version compatibility);
//!      `.merge = .first` makes the primary key win when both are present.
//!   10. **Raw JSON embedding** — `.format = .raw_json` splices a
//!      pre-serialized `[]const u8` payload verbatim (no quoting/escaping),
//!      e.g. a JSON-RPC `result`/`params` blob.
//!
//! This module closes these gaps with a single `json_meta` anonymous
//! struct declaration per type (plus an optional `json_prefix`). For the
//! common case where the wire keys already match the Zig field names, no
//! `json_meta` is needed at all — a plain anonymous struct serialized via
//! `std.json.Stringify.valueAlloc` handles escaping/ordering directly.
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
    /// Value formatting override for serialization. The vocabulary is a
    /// closed enum (not a raw fmt string) so each variant can type-check
    /// the field at comptime — e.g. `.shortest_float` on a non-float
    /// field is a `@compileError`, not a silent mis-print.
    format: Format = .default,
    /// When `true`, the field is omitted during serialization whenever its
    /// value equals the field's declared default (comptime comparison).
    /// Unifies the common "omit zero ints / omit false bools / omit empty
    /// strings" wire-shape rule. On the parse side the field simply keeps
    /// its default when the key is absent — no parse-side change needed.
    omit_default: bool = false,
    /// Additional wire keys accepted on parse, tried in order after the
    /// primary (`rename` or field-name) key. Used for multi-version wire
    /// compatibility (e.g. v4 camelCase + v5 snake_case). Parse-side only;
    /// serialization always emits the primary key.
    aliases: []const []const u8 = &.{},
    /// Name of a zero-arg method on the struct (`fn(self: T) field_type`)
    /// whose return value is serialized INSTEAD of the stored field. Use
    /// for derived wire values (e.g. `input_tokens = uncached portion`).
    /// Comptime-validated to exist on the struct. Serialize-side only;
    /// parse still reads the stored field via `rename`/`aliases`.
    compute: ?[]const u8 = null,
    /// When several matching keys (primary + `.aliases`) are present in the
    /// same JSON object, which wins. `last` (default) matches the previous
    /// last-write-wins behavior; `first` keeps the first parsed value, so
    /// an earlier key in the wire order takes precedence. Use `first` when
    /// a primary key has higher semantic precedence than its aliases (e.g.
    /// v4 `input` = total outranks v5 `input_tokens` = uncached).
    merge: Merge = .last,

    pub const Merge = enum { last, first };

    pub const Format = enum {
        /// Delegate to `jw.write(value)` — std.json's default formatting.
        default,
        /// Render a float field with `{d}` (shortest round-trip decimal,
        /// e.g. `0.3` instead of `0.30000001192092896`). Only valid on
        /// `.float` fields; anything else fails at comptime.
        shortest_float,
        /// Render an f64 with `{d}` but guarantee a decimal point (e.g.
        /// `0.0` not `0`) so the value round-trips as `.float`, not
        /// `.integer`. Non-finite values (nan/inf) clamp to `0.0`.
        /// Only valid on `.float` fields; anything else fails at comptime.
        float_force_decimal,
        /// Splice the field's bytes verbatim as raw JSON (no quoting or
        /// escaping). For a pre-serialized payload that must be embedded
        /// as-is (e.g. a JSON-RPC `result`/`params` blob). `null` splices
        /// the literal `null`. Only valid on `[]const u8` / `?[]const u8`
        /// fields; anything else fails at comptime. The caller guarantees
        /// the bytes are valid JSON — no validation is performed.
        raw_json,
    };
};

/// Comptime typo check: verify every field named in `T.json_meta` actually
/// exists on `T`. A misspelled key fails the build with a clear message
/// instead of silently corrupting the wire format. No-op when no
/// `json_meta` is declared.
fn validateMeta(comptime T: type) void {
    if (!@hasDecl(T, "json_meta")) return;
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
        .format = if (@hasField(Raw, "format")) raw.format else .default,
        .omit_default = if (@hasField(Raw, "omit_default")) raw.omit_default else false,
        .aliases = if (@hasField(Raw, "aliases")) raw.aliases else &.{},
        .compute = if (@hasField(Raw, "compute")) raw.compute else null,
        .merge = if (@hasField(Raw, "merge")) raw.merge else .last,
    };
}

/// Generic `jsonStringify` implementation that respects `json_meta`.
///
/// Call this from a struct's `pub fn jsonStringify` hook. It:
///   1. Validates at comptime that every field named in `json_meta`
///      actually exists on `T` (catches typos before any binary is built).
///   2. Emits a JSON object with renamed/skipped fields, delegating all
///      value writing (escaping, nesting, optionals) to `std.json`,
///      except fields whose `json_meta` entry sets a `.format` override
///      (dispatched at comptime inside the `inline for`).
pub fn stringifyWithMeta(self: anytype, jw: anytype) !void {
    const T = @TypeOf(self);
    const struct_info = @typeInfo(T).@"struct";

    // 1. Comptime typo check — verify every json_meta field exists on T.
    comptime validateMeta(T);

    // 2. Emit the object, applying rename/skip per field.
    //    Also honour `emit_null_optional_fields = false` for optional
    //    fields whose value is `null`, mirroring the stdlib's default
    //    struct serializer (Stringify.zig:464-471).
    try jw.beginObject();
    // 2a. Optional leading constant fields declared via `json_prefix`,
    //     e.g. `pub const json_prefix = .{ .version = current_version };`.
    //     Emitted first, in declaration order; not part of the struct, so
    //     parseWithMeta ignores them (unknown keys are skipped).
    if (@hasDecl(T, "json_prefix")) {
        const Prefix = @TypeOf(T.json_prefix);
        const prefix_info = @typeInfo(Prefix).@"struct";
        inline for (prefix_info.field_names) |pname| {
            try jw.objectField(pname);
            try jw.write(@field(T.json_prefix, pname));
        }
    }
    // 2b. Struct fields, applying rename/skip/omit_default/format.
    inline for (struct_info.field_names, struct_info.field_types) |field_name, field_type| {
        // `comptime` forces cfg (including cfg.format) to be a comptime
        // value, so writeFieldValue's `comptime format` parameter resolves.
        const cfg = comptime fieldConfig(T, field_name);
        if (!cfg.skip) {
            // `.compute` names a zero-arg struct method whose return value
            // is serialized instead of the stored field (derived wire value).
            const value = if (comptime cfg.compute) |method| blk: {
                if (!@hasDecl(T, method)) {
                    @compileError(
                        "json_meta .compute on '" ++ @typeName(T) ++ "." ++ field_name ++
                            "' references non-existent method '" ++ method ++ "'",
                    );
                }
                break :blk @field(T, method)(self);
            } else @field(self, field_name);
            const is_optional = @typeInfo(field_type) == .optional;
            // `omit_default` compares against the field's declared default
            // (comptime). Fields without a declared default use the type's
            // zero value via defaultInit. `default_value` is comptime-known;
            // the comparison against `value` is a runtime check. Comparison
            // is type-aware: slices use `std.mem.eql`, everything else `==`.
            const default_value = comptime fieldDefault(T, field_name, field_type);
            const omitted_by_default = cfg.omit_default and
                valueIsDefault(field_type, value, default_value);
            // Decide whether to emit. Non-optional fields always emit.
            // Optional fields emit when non-null; a null is emitted only for
            // the `.default` format under emit_null_optional_fields (rendered
            // as JSON `null`). The float/raw_json variants unwrap the payload
            // with `.?`, so they must never receive a null — for those a null
            // is omitted even when emit_null_optional_fields is true (a
            // forced-decimal or raw splice has no meaningful null rendering).
            const null_ok = comptime (cfg.format == .default);
            const emit_this = !omitted_by_default and
                if (comptime is_optional)
                    (value != null) or (null_ok and jw.options.emit_null_optional_fields)
                else
                    true;
            if (emit_this) {
                const key = cfg.rename orelse field_name;
                try jw.objectField(key);
                try writeFieldValue(jw, field_type, value, cfg.format);
            }
        }
    }
    try jw.endObject();
}

/// Runtime equality check for `omit_default`: does `value` equal the
/// field's `default_value`? Slices (strings) compare by contents via
/// `std.mem.eql`; all other types use `==`.
fn valueIsDefault(comptime field_type: type, value: field_type, default_value: field_type) bool {
    return switch (@typeInfo(field_type)) {
        .pointer => |p| if (p.size == .slice)
            std.mem.eql(p.child, value, default_value)
        else
            value == default_value,
        else => value == default_value,
    };
}

/// The default value for a struct field: its declared default when one
/// exists, otherwise `defaultInit(field_type)` (which honours nested
/// defaults and zero-initialises the rest). Comptime-evaluated.
fn fieldDefault(comptime T: type, comptime field_name: []const u8, comptime field_type: type) field_type {
    const si = @typeInfo(T).@"struct";
    inline for (si.field_names, si.field_attrs) |fname, attrs| {
        if (comptime std.mem.eql(u8, fname, field_name)) {
            if (attrs.defaultValue(field_type)) |dv| return dv;
        }
    }
    // No declared default — fall back to the type's zero value. Struct
    // types go through defaultInit to honour their own nested defaults;
    // scalars/slices/optionals zero-init cleanly.
    return switch (@typeInfo(field_type)) {
        .@"struct" => defaultInit(field_type),
        else => std.mem.zeroes(field_type),
    };
}

/// Write one field value, honouring the comptime `format` override.
/// `.default` delegates to `jw.write`; `.shortest_float` uses `{d}`
/// (shortest round-trip decimal) and `@compileError`s on non-float
/// fields, so misuse is caught at build time rather than on the wire.
fn writeFieldValue(
    jw: anytype,
    comptime field_type: type,
    value: field_type,
    comptime format: FieldConfig.Format,
) !void {
    // `.default` writes the value as-is (an optional renders its payload or
    // JSON `null`). The other formats operate on the payload, so unwrap an
    // optional once and dispatch per format on the child type. A null never
    // reaches this point for non-default formats (the emission gate omits
    // it), so the `.?` unwrap is safe.
    switch (format) {
        .default => try jw.write(value),
        inline else => {
            const is_opt = @typeInfo(field_type) == .optional;
            const Inner = if (is_opt) @typeInfo(field_type).optional.child else field_type;
            const inner: Inner = if (is_opt) value.? else value;
            switch (format) {
                .default => unreachable, // handled above
                .shortest_float => switch (@typeInfo(Inner)) {
                    .float => try jw.print("{d}", .{inner}),
                    else => formatTypeError(format, field_type, "a float"),
                },
                .float_force_decimal => switch (@typeInfo(Inner)) {
                    .float => try writeF64ForceDecimal(jw, inner),
                    else => formatTypeError(format, field_type, "a float"),
                },
                // `jw.print("{s}", ...)` splices the bytes verbatim
                // (valueStart/valueDone + raw writer, no quoting/escaping).
                .raw_json => switch (@typeInfo(Inner)) {
                    .pointer => |p| if (p.size == .slice and p.child == u8)
                        try jw.print("{s}", .{inner})
                    else
                        formatTypeError(format, field_type, "a []const u8"),
                    else => formatTypeError(format, field_type, "a []const u8"),
                },
            }
        },
    }
}

/// Comptime type-mismatch error for a `.format` override, naming the
/// offending field type and the required kind.
fn formatTypeError(
    comptime format: FieldConfig.Format,
    comptime field_type: type,
    comptime requirement: []const u8,
) void {
    _ = format;
    @compileError(
        "json_meta .format requires " ++ requirement ++ " field, got " ++ @typeName(field_type),
    );
}

/// Write a float as a JSON number with a guaranteed decimal point
/// (e.g. `0.0` not `0`, `1.0` not `1`). std.json / `{d}` emit whole-number
/// floats without a decimal point, which causes the value to be tagged
/// `.integer` instead of `.float` on round-trip. Non-finite values
/// (nan/inf) are clamped to `0.0` — they are not valid JSON.
fn writeF64ForceDecimal(jw: anytype, value: anytype) !void {
    const f: f64 = @floatCast(value);
    const safe = if (std.math.isFinite(f)) f else 0.0;
    // `{d}` for f64 can emit up to ~330 chars (full decimal expansion of
    // denormals like 5e-324); 512 covers every finite f64 with headroom.
    var tmp: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{safe}) catch unreachable;
    // If the formatted string has no decimal point or exponent, append `.0`.
    if (std.mem.indexOfScalar(u8, s, '.') == null and
        std.mem.indexOfScalar(u8, s, 'e') == null)
    {
        try jw.print("{s}.0", .{s});
    } else {
        try jw.print("{s}", .{s});
    }
}

/// Initialise `T` honouring its declared field defaults: fields with a
/// default get that default, fields without one are zero-initialised. Unlike
/// `std.mem.zeroes(T)` (which zeroes everything, clobbering `true` / non-zero
/// defaults like `Capabilities.tool_use = true`) and `T{}` (which fails to
/// compile when any field lacks a default), this works for any struct.
pub fn defaultInit(comptime T: type) T {
    var r: T = undefined;
    const si = @typeInfo(T).@"struct";
    inline for (si.field_names, si.field_types, si.field_attrs) |fname, ftype, attrs| {
        if (attrs.defaultValue(ftype)) |dv| {
            @field(r, fname) = dv;
        } else if (@typeInfo(ftype) == .@"struct") {
            // A struct-typed field with no declared default (e.g.
            // `Entry.capabilities: Capabilities`) must still honour the
            // nested struct's own field defaults — zeroing it would clobber
            // e.g. `Capabilities.tool_use = true`.
            @field(r, fname) = defaultInit(ftype);
        } else {
            @field(r, fname) = std.mem.zeroes(ftype);
        }
    }
    return r;
}

/// Generic `jsonParseFromValue` implementation that respects `json_meta`.
///
/// Call this from a struct's `pub fn jsonParseFromValue` hook. It:
///   1. Validates at comptime that every field named in `json_meta`
///      actually exists on T (same typo check as `stringifyWithMeta`).
///   2. Iterates the JSON object's keys, matching each against the wire
///      name (renamed or original) of every non-skipped field, and parses
///      the value via `std.json.parseFromValueLeaky` (so nested types with
///      their own hooks recurse correctly).
///   3. Skipped fields retain their default value. Unknown keys are
///      ignored (forward-compatible).
///
/// The returned struct is default-initialized first, so any field absent
/// from the JSON keeps its default. String slices are duped into
/// `allocator` (the caller owns them).
pub fn parseWithMeta(
    comptime T: type,
    allocator: std.mem.Allocator,
    source: std.json.Value,
) std.json.ParseFromValueError!T {
    // 1. Comptime typo check — verify every json_meta field exists on T.
    comptime validateMeta(T);

    const o = switch (source) {
        .object => |obj| obj,
        .null => return defaultInit(T),
        else => return error.UnexpectedToken,
    };

    // Default-initialize from the struct's declared field defaults, NOT
    // `std.mem.zeroes(T)`. Some types have non-zero defaults (e.g.
    // `Capabilities.tool_use = true`, `.streaming = true`) that must be
    // honoured when the key is absent from the JSON.
    var r: T = defaultInit(T);
    const struct_info = @typeInfo(T).@"struct";
    // Per-field "already populated" tracker for `.merge = .first` fields
    // (comptime-sized bitset indexed by field position).
    var seen: std.StaticBitSet(struct_info.field_names.len) = .empty;
    var it = o.iterator();
    while (it.next()) |kv| {
        const wire_name = kv.key_ptr.*;
        inline for (struct_info.field_names, struct_info.field_types, 0..) |f_name, f_type, f_idx| {
            const cfg = comptime fieldConfig(T, f_name);
            if (!cfg.skip) {
                // Match the primary key first, then any `.aliases` (used for
                // multi-version wire compatibility, e.g. v4 + v5 key names).
                const primary = cfg.rename orelse f_name;
                const matched = std.mem.eql(u8, primary, wire_name) or blk: {
                    inline for (cfg.aliases) |alias| {
                        if (std.mem.eql(u8, alias, wire_name)) break :blk true;
                    }
                    break :blk false;
                };
                // `.merge = .first` keeps the earliest matching key; `.last`
                // (default) lets later keys overwrite earlier ones.
                if (matched and (cfg.merge == .last or !seen.isSet(f_idx))) {
                    // Permissive on SHAPE errors only: a field whose value
                    // has an unexpected type is skipped (kept at its
                    // default), matching the old per-field manual parsers.
                    // OutOfMemory is propagated — it is a hard failure, not
                    // a shape mismatch, and swallowing it would silently
                    // truncate the struct under memory pressure.
                    const parsed = std.json.parseFromValueLeaky(
                        f_type,
                        allocator,
                        kv.value_ptr.*,
                        .{ .ignore_unknown_fields = true },
                    ) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => break,
                    };
                    @field(r, f_name) = parsed;
                    seen.set(f_idx);
                    break;
                }
            }
        }
    }
    return r;
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

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        options: std.json.ParseOptions,
    ) !@This() {
        _ = options;
        return parseWithMeta(@This(), allocator, source);
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

test "parseWithMeta: round-trip with rename + skip" {
    const user = TestUser{
        .id = 42,
        .first_name = "Alice",
        .password_hash = "super_secret",
        .tags = &.{},
    };
    const json_str = try std.json.Stringify.valueAlloc(testing.allocator, user, .{
        .emit_null_optional_fields = false,
    });
    defer testing.allocator.free(json_str);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json_str, .{});
    defer parsed.deinit();

    const restored = try std.json.parseFromValueLeaky(TestUser, testing.allocator, parsed.value, .{ .ignore_unknown_fields = true });
    defer testing.allocator.free(restored.first_name);
    testing.allocator.free(restored.tags);

    try testing.expectEqual(@as(u32, 42), restored.id);
    try testing.expectEqualStrings("Alice", restored.first_name);
    // password_hash is skipped → retains default (empty string from zero-init).
    try testing.expectEqual(@as(usize, 0), restored.password_hash.len);
}

const TestPricing = struct {
    input_per_1m: f32 = 0,
    output_per_1m: f32 = 0,

    pub const json_meta = .{
        .input_per_1m = .{ .rename = "inputPer1M", .format = .shortest_float },
        .output_per_1m = .{ .rename = "outputPer1M", .format = .shortest_float },
    };

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try stringifyWithMeta(self, jw);
    }
};

test "stringifyWithMeta: shortest_float emits {d} round-trip decimals" {
    const pricing = TestPricing{ .input_per_1m = 0.30, .output_per_1m = 3.75 };
    const json_str = try std.json.Stringify.valueAlloc(testing.allocator, pricing, .{});
    defer testing.allocator.free(json_str);

    // `{d}` on the f32 yields shortest round-trip (`0.3`), NOT std.json's
    // full-precision fallback (`0.30000001192092896`).
    try testing.expectEqualStrings(
        "{\"inputPer1M\":0.3,\"outputPer1M\":3.75}",
        json_str,
    );
}

const TestMetrics = struct {
    name: []const u8,
    hits: u32 = 0,
    errors: u32 = 0,
    degraded: bool = false,
    note: []const u8 = "",

    pub const json_meta = .{
        .hits = .{ .omit_default = true },
        .errors = .{ .omit_default = true },
        .degraded = .{ .omit_default = true },
        .note = .{ .omit_default = true },
    };

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try stringifyWithMeta(self, jw);
    }
};

test "stringifyWithMeta: omit_default drops zero ints, false bools, empty strings" {
    // All-default struct: only the always-emitted `name` remains.
    const empty = TestMetrics{ .name = "m" };
    const empty_json = try std.json.Stringify.valueAlloc(testing.allocator, empty, .{});
    defer testing.allocator.free(empty_json);
    try testing.expectEqualStrings("{\"name\":\"m\"}", empty_json);

    // Non-default values are emitted; still-default ones are not.
    const some = TestMetrics{ .name = "m", .hits = 7, .degraded = true, .note = "n" };
    const some_json = try std.json.Stringify.valueAlloc(testing.allocator, some, .{});
    defer testing.allocator.free(some_json);
    try testing.expectEqualStrings(
        "{\"name\":\"m\",\"hits\":7,\"degraded\":true,\"note\":\"n\"}",
        some_json,
    );
}

const TestEnvelope = struct {
    id: u32,
    label: []const u8,

    pub const json_prefix = .{
        .version = @as(i64, 3),
    };

    pub const json_meta = .{};

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try stringifyWithMeta(self, jw);
    }
};

test "stringifyWithMeta: json_prefix emits constant fields first" {
    const env = TestEnvelope{ .id = 9, .label = "x" };
    const json_str = try std.json.Stringify.valueAlloc(testing.allocator, env, .{});
    defer testing.allocator.free(json_str);
    try testing.expectEqualStrings(
        "{\"version\":3,\"id\":9,\"label\":\"x\"}",
        json_str,
    );
}

const TestCost = struct {
    usd: f64 = 0,
    ratio: f64 = 0,

    pub const json_meta = .{
        .usd = .{ .format = .float_force_decimal },
        .ratio = .{ .format = .float_force_decimal },
    };

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try stringifyWithMeta(self, jw);
    }
};

test "stringifyWithMeta: float_force_decimal guarantees a decimal point" {
    const cost = TestCost{ .usd = 0, .ratio = 1.5 };
    const json_str = try std.json.Stringify.valueAlloc(testing.allocator, cost, .{});
    defer testing.allocator.free(json_str);
    // Whole-number f64 is forced to `0.0` (round-trips as .float);
    // a value with a fractional part keeps its natural form.
    try testing.expectEqualStrings(
        "{\"usd\":0.0,\"ratio\":1.5}",
        json_str,
    );
}

const TestTokens = struct {
    total: u64 = 0,
    cached: u64 = 0,

    pub fn uncached(self: TestTokens) u64 {
        return if (self.total > self.cached) self.total - self.cached else 0;
    }

    pub const json_meta = .{
        // Serialize the derived `uncached()` value under `total_tokens`,
        // omit when zero; parse accepts `total_tokens` or the legacy
        // camelCase alias `totalTokens`.
        .total = .{
            .rename = "total_tokens",
            .compute = "uncached",
            .omit_default = true,
            .aliases = &.{"totalTokens"},
        },
        .cached = .{ .rename = "cached_tokens", .omit_default = true },
    };

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try stringifyWithMeta(self, jw);
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        options: std.json.ParseOptions,
    ) !@This() {
        _ = options;
        return parseWithMeta(@This(), allocator, source);
    }
};

test "stringifyWithMeta: compute serializes a derived value" {
    const t = TestTokens{ .total = 100, .cached = 30 };
    const json_str = try std.json.Stringify.valueAlloc(testing.allocator, t, .{});
    defer testing.allocator.free(json_str);
    // `total` serializes as the derived uncached value (100 - 30 = 70),
    // not the stored total.
    try testing.expectEqualStrings(
        "{\"total_tokens\":70,\"cached_tokens\":30}",
        json_str,
    );
}

test "stringifyWithMeta: compute + omit_default drops a zero derived value" {
    // total <= cached → uncached() == 0 → field omitted.
    const t = TestTokens{ .total = 30, .cached = 30 };
    const json_str = try std.json.Stringify.valueAlloc(testing.allocator, t, .{});
    defer testing.allocator.free(json_str);
    try testing.expectEqualStrings("{\"cached_tokens\":30}", json_str);
}

test "parseWithMeta: aliases accept a legacy key name" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        "{\"totalTokens\":42,\"cached_tokens\":7}",
        .{},
    );
    defer parsed.deinit();
    const t = try std.json.parseFromValueLeaky(TestTokens, testing.allocator, parsed.value, .{});
    try testing.expectEqual(@as(u64, 42), t.total);
    try testing.expectEqual(@as(u64, 7), t.cached);
}

const TestMerge = struct {
    // `.merge = .first` keeps the earliest matching key — used when the
    // primary rename has higher precedence than its alias.
    v: u32 = 0,

    pub const json_meta = .{
        .v = .{ .rename = "primary", .aliases = &.{"legacy"}, .merge = .first },
    };

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        options: std.json.ParseOptions,
    ) !@This() {
        _ = options;
        return parseWithMeta(@This(), allocator, source);
    }
};

test "parseWithMeta: merge=first keeps the earliest matching key" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        "{\"primary\":1,\"legacy\":2}",
        .{},
    );
    defer parsed.deinit();
    const t = try std.json.parseFromValueLeaky(TestMerge, testing.allocator, parsed.value, .{});
    try testing.expectEqual(@as(u32, 1), t.v);
}

const TestRawEmbed = struct {
    method: []const u8,
    result: ?[]const u8 = null,

    pub const json_prefix = .{
        .jsonrpc = @as([]const u8, "2.0"),
    };

    pub const json_meta = .{
        .result = .{ .format = .raw_json },
    };

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try stringifyWithMeta(self, jw);
    }
};

test "stringifyWithMeta: null optional with a float/raw format is omitted even when emit_null_optional_fields=true" {
    // Regression: the float/raw_json variants unwrap with `.?`, so a null
    // optional must never reach them even when emit_null_optional_fields
    // forces nulls onto the wire for `.default` fields. Previously this
    // panicked (attempt to use null value).
    const Opts = struct {
        plain: ?u32 = null,
        cost: ?f64 = null,
        blob: ?[]const u8 = null,

        pub const json_meta = .{
            .cost = .{ .format = .float_force_decimal },
            .blob = .{ .format = .raw_json },
        };

        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try stringifyWithMeta(self, jw);
        }
    };
    const json_str = try std.json.Stringify.valueAlloc(testing.allocator, Opts{}, .{
        .emit_null_optional_fields = true,
    });
    defer testing.allocator.free(json_str);
    // `plain` (.default) is force-emitted as null; `cost` and `blob`
    // (float/raw formats) are omitted rather than panicking.
    try testing.expectEqualStrings("{\"plain\":null}", json_str);
}

test "stringifyWithMeta: raw_json splices a pre-serialized blob verbatim" {
    // Present raw payload: embedded without quoting/escaping.
    const with_result = TestRawEmbed{ .method = "tools/call", .result = "{\"ok\":true}" };
    const json1 = try std.json.Stringify.valueAlloc(testing.allocator, with_result, .{
        .emit_null_optional_fields = false,
    });
    defer testing.allocator.free(json1);
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"method\":\"tools/call\",\"result\":{\"ok\":true}}",
        json1,
    );

    // Null raw payload with emit_null_optional_fields=false: field omitted.
    const no_result = TestRawEmbed{ .method = "ping" };
    const json2 = try std.json.Stringify.valueAlloc(testing.allocator, no_result, .{
        .emit_null_optional_fields = false,
    });
    defer testing.allocator.free(json2);
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"method\":\"ping\"}",
        json2,
    );
}

