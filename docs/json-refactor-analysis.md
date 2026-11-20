# JSON Refactor Analysis — `franky` (Zig 0.17)

**Question:** Could we save a lot of JSON-related code by adopting a single
generic `stringifyWithMeta` / `parseWithMeta` helper that plugs into
`std.json` via the `jsonStringify` / `jsonParse` / `jsonParseFromValue`
hooks, with a `json_meta` anonymous struct for `rename` / `skip` plus
comptime typo validation?

**Answer: Yes — conservatively ~1,500–2,000 lines (~3% of the whole
`src/` tree, ~15–25% of the JSON-touching code) are eliminable, and the
change is low-risk because the stdlib already supports every hook the
approach relies on.**

---

## 0. Feasibility check — does the Zig 0.17 stdlib support this?

`build.zig.zon` declares `minimum_zig_version = "0.17.0-dev.1622"`.
Inspecting `/usr/local/zig-x86_64-linux-0.17.0/lib/std/json/`:

| Hook | Present? | Where it's dispatched |
|---|---|---|
| `pub fn jsonStringify(self: *@This(), jw: anytype) !void` | ✅ | `Stringify.zig:400,420,449` — `std.meta.hasFn(T, "jsonStringify")` |
| `pub fn jsonParse(allocator, source, options) !T` | ✅ | `static.zig:260,273,331` — called from `innerParse` (tokenizer source) |
| `pub fn jsonParseFromValue(allocator, source: Value, options) !T` | ✅ | `static.zig:597` — called from `innerParseFromValue` |
| `jw.beginObject / objectField / write / endObject` | ✅ | `Stringify.zig:91,279,348,113` |
| `std.json.Stringify.valueAlloc` | ✅ | `Stringify.zig:618` |
| `std.json.parseFromValue` / `parseFromValueLeaky` | ✅ | `static.zig:159,178` |
| `Options.emit_null_optional_fields = false` | ✅ | `Stringify.zig:539` — omits `null` optionals automatically |
| `ParseOptions.ignore_unknown_fields` | ✅ | `static.zig:29` |

**Conclusion: the approach is fully supported with zero third-party
dependencies.** The only stdlib gap is *no built-in field rename* — which
is exactly what the proposed `json_meta` + generic helper adds. So the
approach complements rather than fights the stdlib.

One caveat for `jsonParse`: `innerParse` dispatches to `T.jsonParse` with
the *tokenizer source* (a `*Scanner` or `*Reader`), not a `Value`. The
reverse-direction helper must call `std.json.innerParse(FieldType, allocator,
source, options)` per field (the stdlib exposes `innerParse` publicly for
exactly this purpose — `static.zig:209-216`). The `jsonParseFromValue`
variant is simpler and operates on `std.json.Value`, which matches the
current codebase's "parse to `Value`, then walk `ObjectMap`" pattern — so
migrating parsing to `jsonParseFromValue` is the lower-friction path.

---

## 1. What the codebase does today

`src/` is ~70,200 LOC across ~140 `.zig` files. JSON is touched in ~35
files. The work splits into three anti-patterns, all hand-rolled:

### Pattern A — Duplicated string-escape / append helpers
*(reimplementing `std.json.Stringify` byte-by-byte)*

The same `appendJsonStr` (manual `"` / `\\` / control-char escaping) is
**copy-pasted in 8 separate files**:

| File | Helper | Body LOC |
|---|---|---|
| `ai/utils.zig` | `appendJsonStr` + `appendJsonRaw` + `appendJsonInt` + `appendJsonFloat` | 30 |
| `ai/utils.zig` | `sanitizeJsonString` (separate 54-line backslash walker) | 54 |
| `coding/session/persistence.zig` | `appendJsonStr`, `writeJsonField`, `writeJsonStrField`, `appendJsonNumField`, `appendJsonU64Field`, `appendJsonF64Field` | 76 |
| `coding/mcp/json_helpers.zig` | `appendJsonStr` + `renderJson` (reimplements stringify for `Value`) | 58 |
| `agent/wire.zig` | `appendJsonStr` + `appendJsonInt` | 22 |
| `coding/rpc.zig` | `appendJsonStr` + `appendJsonInt` + `renderJson` | 61 |
| `coding/security/auth.zig` | `writeJsonField` | 11 |
| `coding/model_catalog/render.zig` | `appendJsonString` | 15 |
| `coding/tools/edit.zig` | `escapeJsonString` | 20 |
| `ai/stream.zig` | `appendJsonStrLocal` | 24 |
| `agent/json_repair.zig` | `appendJsonValueSlice` | ~25 |
| **Subtotal** | | **~396 LOC** |

These exist *only* because the code builds JSON with `buf.appendSlice("{\"model\":")`
instead of letting `std.json.Stringify` emit it. Every one of them is
deletable once the caller switches to `jw.write(value)`.

### Pattern B — Duplicated `ObjectMap` field-extraction helpers
*(reimplementing `std.json.parseFromValue` field-by-field)*

| File | Helpers | Body LOC |
|---|---|---|
| `ai/utils.zig` | `jsonInt`, `jsonStr`, `jsonFloat`, `jsonBool`, `jsonObj`, `jsonArr`, `jsonF64Value` | ~50 |
| `coding/config/profiles.zig` | `optString`, `optBool`, `optInt`, `lookupField` | ~35 |
| `coding/model_catalog/models.zig` | `strOr`, `intOr`, `floatOr` | ~30 |
| `coding/session/persistence.zig` | `strOpt`, `parseVersionField`, `parseCostState` | ~40 |
| **Subtotal** | | **~155 LOC** |

These are the symptom of parsing into `std.json.Value` and then hand-walking
`ObjectMap.get("key")` + `if (v == .string) v.string`. With
`parseFromValue(TypedStruct, ...)`, the stdlib does this automatically
(including optional fields, defaults, and `ignore_unknown_fields`).

### Pattern C — Inline manual serialization/deserialization call sites
*(the actual verbose business logic)*

This is where the bulk of the savings lives.

| File | Total LOC | JSON (de)ser LOC | Pattern |
|---|---|---|---|
| `coding/session/persistence.zig` | 1630 | ~560 | `appendMessageJson` (596–790, ~195 LOC) hand-emits every field of `Message` + `Usage` + `Diagnostics` with `appendJsonStr`/`appendJsonU64Field`; `parseContentBlock`/`parseMessage` (1101–1358, ~260 LOC) hand-walks `ObjectMap` |
| `ai/providers/anthropic.zig` | 929 | ~385 | `buildRequestJson` (52–136) + `appendContentBlock` (138–252) string-build; SSE `handle` (395–580) `ObjectMap.get` chains |
| `ai/providers/openai_chat.zig` | 1154 | ~407 | same dual pattern; 6-deep `if (x == .object) if (x.object.get(...))` chains |
| `ai/providers/google_gemini.zig` | 1093 | ~292 | same; *already* uses `Stringify.valueAlloc` in one spot (`renderArgs`, 441–445) — proof the migration is viable |
| `ai/providers/openai_responses.zig` | 682 | ~272 | same |
| `coding/config/profiles.zig` | 1690 | ~200 | `parseProfileObject` (344–417) — 40+ `optString`/`optBool`/`optInt` calls |
| `coding/model_catalog/fetch.zig` | 927 | ~180 | `parseAnthropic`/`parseOpenAI`/`parseOllama`/`parseGemini` |
| `coding/model_catalog/models.zig` | 304 | ~110 | `strOr`/`intOr` per field |
| `coding/mcp/client.zig` | 536 | ~160 | JSON-RPC literal string-build + `ObjectMap` response parsing |
| `coding/rpc.zig` | 397 | ~170 | `encodeResponse`/`encodeNotification` string-build + `parseRequest` |
| `agent/wire.zig` | ~400 | ~120 | `appendJsonStr`/`appendJsonInt` wire encoding |
| `coding/tools/edit.zig` | 1399 | ~95 | `escapeJsonString` + `allocPrint` JSON-literal details |
| `coding/tools/grep.zig` | 1369 | ~75 | `ObjectMap` arg extraction |
| `coding/tools/bash.zig` | 1859 | ~70 | `ObjectMap` arg extraction |
| `agent/json_repair.zig` | ~450 | ~450 | **NOT replaceable** — hand-written repair parser (see §3) |
| `ai/partial_json.zig` | 586 | ~586 | **NOT replaceable** — incremental streaming parser (see §3) |
| `ai/utils.zig` | 442 | ~134 | the shared helpers themselves (counted in A/B above) |
| **Subtotal (replaceable inline)** | | **~2,900 LOC** | |

---

## 2. Estimated savings

| Bucket | Current LOC | After migration | Saved |
|---|---|---|---|
| **A.** Duplicated append/escape helpers | ~396 | ~0 (deleted) + ~40 LOC for one shared `json_meta` helper module | **~356** |
| **B.** Duplicated `ObjectMap` extraction helpers | ~155 | ~0 (deleted) | **~155** |
| **C.** Inline manual serialization (`appendMessageJson`, `buildRequestJson`, `appendContentBlock`, `encodeResponse`, …) | ~1,500 | ~300 (struct decls + `json_meta` + 2-line `jsonStringify`/`jsonParseFromValue` wrappers) | **~1,200** |
| **C'.** Inline manual deserialization (`parseProfileObject`, `parseContentBlock`, provider SSE `handle`, …) | ~1,400 | ~200 (same struct decls serve both directions) | **~1,200** |
| **Non-replaceable** (`json_repair`, `partial_json`) | ~1,036 | unchanged | 0 |
| **Total replaceable** | **~3,450** | **~540** | **~2,900** |

### Realistic (conservative) estimate

The ~2,900 figure assumes a full migration. In practice some call sites
have provider-specific quirks (e.g. Anthropic's `input_tokens` =
total − cached, Claude-Code-compatible `tool_use` vs franky `toolCall`
shape, the content-addressed `ref` indirection in persistence). These
need custom `jsonStringify`/`jsonParseFromValue` bodies that do a little
real work, so they won't collapse to 2 lines each.

**Conservative estimate: ~1,500–2,000 lines deleted**, with ~150 lines of
shared `json_meta` helper code added → **net ~1,350–1,850 LOC removed**
(~2–2.6% of `src/`, ~15–20% of all JSON-touching code).

The *duplicated helper* bucket (A + B, ~550 LOC) is pure-deletion and
trivially safe — that alone is worth doing regardless of the broader
migration.

---

## 3. What is NOT replaceable (and why)

| File | Why it must stay hand-rolled |
|---|---|
| `ai/partial_json.zig` (~586 LOC) | Incremental recursive-descent parser for *truncated* streaming JSON prefixes. `std.json` requires complete input; this deliberately parses partial documents for UI streaming. Genuinely bespoke. |
| `agent/json_repair.zig` (~450 LOC) | Heuristic repair of malformed LLM-emitted JSON (trailing commas, unquoted keys, truncated arrays). Operates before `std.json` can run. Also bespoke. |
| `ai/schema_sanitize.zig` | Transforms JSON Schema dicts — not (de)serialization of typed structs. |

These ~1,000 lines stay. Everything else is a candidate.

---

## 4. What the migration looks like concretely

### 4a. One shared helper module (new, ~120 LOC)

```zig
// src/ai/json_meta.zig
pub const FieldConfig = struct {
    rename: ?[]const u8 = null,
    skip: bool = false,
};

pub fn stringifyWithMeta(self: anytype, jw: anytype) !void {
    const T = @TypeOf(self);
    const info = @typeInfo(T).@"struct";
    const has_meta = @hasDecl(T, "json_meta");
    if (has_meta) {                           // comptime typo check
        const M = @TypeOf(T.json_meta);
        inline for (@typeInfo(M).@"struct".fields) |mf| {
            if (!@hasField(T, mf.name))
                @compileError("json_meta on " ++ @typeName(T) ++
                    " references unknown field '" ++ mf.name ++ "'");
        }
    }
    try jw.beginObject();
    inline for (info.fields) |f| {
        const cfg: FieldConfig =
            if (has_meta and @hasField(@TypeOf(T.json_meta), f.name))
                @field(T.json_meta, f.name) else .{};
        if (cfg.skip) continue;
        try jw.objectField(cfg.rename orelse f.name);
        try jw.write(@field(self, f.name));
    }
    try jw.endObject();
}

pub fn parseFromValueWithMeta(
    comptime T: type, allocator: Allocator, v: std.json.Value,
) !T { /* symmetric: build T by mapping json keys back via json_meta */ }
```

### 4b. Per-type opt-in (the only change to existing types)

Take `ai/types.zig` `Usage` — currently serialized by ~70 lines of
`appendJsonU64Field` calls in `persistence.zig:693-765`:

```zig
pub const Usage = struct {
    input: u64 = 0,
    output: u64 = 0,
    cache_read: u64 = 0,
    cache_write: u64 = 0,
    thinking_tokens: u64 = 0,
    cache_creation_ephemeral_5m: u64 = 0,
    cache_creation_ephemeral_1h: u64 = 0,
    web_search_requests: u64 = 0,
    cost_input: ?f64 = null,
    cost_output: ?f64 = null,
    cost_cache_read: ?f64 = null,
    cost_cache_write: ?f64 = null,

    // camelCase wire names + comptime-validated rename map
    pub const json_meta = .{
        .cache_read = .{ .rename = "cache_read_input_tokens" },
        .cache_write = .{ .rename = "cache_creation_input_tokens" },
        .cache_creation_ephemeral_5m = .{ .rename = "cache_creation_5m_input_tokens" },
        .cache_creation_ephemeral_1h = .{ .rename = "cache_creation_1h_input_tokens" },
    };

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try json_meta.stringifyWithMeta(self, jw);
    }
    pub fn jsonParseFromValue(
        allocator: Allocator, v: std.json.Value, opts: ParseOptions,
    ) !@This() {
        return json_meta.parseFromValueWithMeta(@This(), allocator, v, opts);
    }
};
```

With `Options.emit_null_optional_fields = false`, the null `cost_*` fields
are omitted automatically — replacing the current `if (u.cost_input) |ci|`
guards. The `isEmpty()` pre-check that gates the whole `usage` object
becomes a one-line caller decision.

### 4c. Call-site before/after

**Before** (`persistence.zig:693-765`, 72 lines):
```zig
if (m.usage) |u| if (!u.isEmpty()) {
    try buf.appendSlice(allocator, ",\"usage\":{");
    var first = true;
    const cached = u.cache_read +| u.cache_write;
    const uncached_input: u64 = if (u.input > cached) u.input - cached else 0;
    if (uncached_input != 0) { try appendJsonU64Field(...); first = false; }
    if (u.output != 0) { if (!first) try buf.append(allocator, ','); ... }
    // ... 60 more lines ...
    try buf.append(allocator, '}');
};
```

**After** (~6 lines):
```zig
if (m.usage) |u| if (!u.isEmpty()) {
    try buf.appendSlice(allocator, ",\"usage\":");
    // uncached_input is a derived field — expose it as a computed
    // property or a pre-massage step; the 70-line block is gone.
    try std.json.Stringify.valueAlloc(allocator, u, .{
        .emit_null_optional_fields = false,
    }) catch {};
};
```

(The `uncached_input` derivation is one of the provider-specific quirks
noted in §2 — it stays as 2 lines of pre-massage, not 70.)

---

## 5. Recommended phasing

1. **Phase 1 — pure deletion (low risk, ~550 LOC).** Land the shared
   `json_meta` module; migrate the leaf structs that already have exact
   field-to-key correspondence (`SessionHeader`, `model_catalog.Entry`,
   `mcp` tool descriptors, `rpc` response envelopes). Delete the
   duplicated `appendJsonStr`/`renderJson`/`escapeJsonString` helpers as
   their last callers move off them. This alone nets ~550 LOC and removes
   8 copies of the same escaper.

2. **Phase 2 — providers (~900 LOC).** Migrate `buildRequestJson` in all
   four providers to `Stringify.valueAlloc(RequestStruct, …)`. The
   request structs are already implicit in the hand-built JSON; make them
   explicit typed structs with `json_meta` renames. SSE response parsing
   migrates to `parseFromValue(ResponseStruct, …)` per event.

3. **Phase 3 — persistence (~1,000 LOC).** The biggest and most intricate
   because of the `ref`/content-addressed blob indirection and the
   Claude-Code-compatible `tool_use`/`tool_result` shape. Keep a thin
   custom `jsonParseFromValue` on `ContentBlock` that handles `ref`
   resolution, but delegate the plain block types to the generic helper.

4. **Never** — `partial_json.zig`, `json_repair.zig`, `schema_sanitize.zig`.

---

## 6. Risks / caveats

- **Field-name casing.** Zig struct fields are `snake_case`; wire formats
  are often `camelCase` (`createdAtMs`, `toolUseId`). The `json_meta.rename`
  handles this, but it's per-field manual metadata — typos are caught at
  comptime (the whole point of the approach), but *forgetting* a rename
  silently emits the snake_case name. A test that round-trips every
  on-disk struct through `parseFromValue`/`Stringify` and asserts the
  emitted keys catches this.
- **`union(enum)` dispatch.** `ContentBlock` is a tagged union. The
  stdlib's default union serialization emits `{"tag": …}` which doesn't
  match the wire shape (`{"type":"text","text":"…"}`). A custom
  `jsonStringify` on `ContentBlock` is required (it's ~20 LOC, still a
  huge win over the current 195-LOC `appendMessageJson`).
- **Ownership.** `parseFromValue` allocates via an arena (`Parsed(T)`).
  Current code hand-manages `allocator.dupe` per field. The arena model
  is simpler but callers must adopt `parsed.deinit()`. Several existing
  call sites already use arenas (e.g. `profiles.zig`), so this is
  consistent.
- **`uncached_input` derivation.** A few fields are computed, not stored
  (Anthropic's `input_tokens` = total − cached). These stay as explicit
  pre-massage or computed properties — the generic helper doesn't try to
  model them.

---

## 7. Bottom line

| | Lines |
|---|---|
| Conservative net deletion | **~1,350–1,850** |
| Aggressive (full migration) net deletion | **~2,500–2,900** |
| Shared helper code added | ~120 |
| Non-replaceable (kept) | ~1,000 |
| Risk | Low — stdlib-native hooks, comptime-validated, incremental phasing |

**Yes, the approach saves a lot of code** — at least ~1,350 lines
realistically, up to ~2,900 with a complete migration — and it does so by
*removing* hand-rolled reimplementations of functionality the Zig 0.17
stdlib already provides, rather than by adding a dependency. The
comptime typo check is a genuine bonus: today a misspelled `appendJsonStr`
key string compiles fine and silently corrupts the wire format.
