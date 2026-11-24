//! Golden-bytes integration test for the `json_meta` migration.
//!
//! Locks the exact wire output of every type whose hand-written
//! `jsonStringify`/`jsonParseFromValue` was replaced by the generic
//! `json_meta.stringifyWithMeta` / `json_meta.parseWithMeta` helpers:
//!
//!   - `ai.types.Usage`        (compute + omit_default + float_force_decimal + aliases + merge)
//!   - `ai.types.Diagnostics`  (omit_default + null-optional omission)
//!   - `coding.session.SessionHeader` (json_prefix version + camelCase renames)
//!   - `coding.branching.Branch`      (omit_default on empty head_hash)
//!   - `coding.auth.ProviderAuth`     (enum→wire-string + wire-twin delegation)
//!   - `coding.model_catalog` Cost/Capabilities/Entry (shortest_float + renames)
//!
//! Each test pins the exact byte sequence (so any formatting drift in the
//! comptime helpers fails loudly) AND round-trips the value back through
//! the parser to confirm (de)serialization stays symmetric.

const std = @import("std");
const franky = @import("franky");

const ai = franky.ai;
const session = franky.coding.session;
const branching = franky.coding.branching;
const auth = franky.coding.auth;
const models = franky.coding.model_catalog.models;

const testing = std.testing;
const gpa = testing.allocator;

fn stringify(value: anytype) ![]u8 {
    return std.json.Stringify.valueAlloc(gpa, value, .{
        .emit_null_optional_fields = false,
    });
}

test "golden: Usage wire bytes with all quirks" {
    const u = ai.types.Usage{
        .input = 1000, // total; 1000 - 200 - 50 = 750 uncached
        .output = 42,
        .cache_read = 200,
        .cache_write = 50,
        .thinking_tokens = 7,
        .cost_input = 0.0, // whole-number f64 → forced decimal "0.0"
        .cost_output = 1.5,
    };
    const json = try stringify(u);
    defer gpa.free(json);

    // input_tokens = uncached (750), zero ints omitted, cost_input forced to
    // 0.0, cost_output keeps natural form. Field order = struct declaration order.
    try testing.expectEqualStrings(
        "{\"input_tokens\":750,\"output_tokens\":42,\"cache_read_input_tokens\":200,\"cache_creation_input_tokens\":50,\"thinking_tokens\":7,\"cost_input\":0.0,\"cost_output\":1.5}",
        json,
    );
}

test "golden: Usage round-trip restores provider total from uncached" {
    const u = ai.types.Usage{
        .input = 1000,
        .output = 42,
        .cache_read = 200,
        .cache_write = 50,
    };
    const json = try stringify(u);
    defer gpa.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
    defer parsed.deinit();
    const back = try std.json.parseFromValueLeaky(ai.types.Usage, gpa, parsed.value, .{});
    // v5 uncached (750) + cache_read + cache_write restores the total (1000).
    try testing.expectEqual(@as(u64, 1000), back.input);
    try testing.expectEqual(@as(u64, 42), back.output);
    try testing.expectEqual(@as(u64, 200), back.cache_read);
    try testing.expectEqual(@as(u64, 50), back.cache_write);
}

test "golden: Usage v4 camelCase aliases parse (merge=first keeps v4 total)" {
    // v4 wire shape: `input` is the TOTAL and must outrank the v5 alias.
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        gpa,
        "{\"input\":5000,\"cacheRead\":300,\"costInput\":2.5}",
        .{},
    );
    defer parsed.deinit();
    const u = try std.json.parseFromValueLeaky(ai.types.Usage, gpa, parsed.value, .{});
    try testing.expectEqual(@as(u64, 5000), u.input); // v4 total, NOT 5000+300
    try testing.expectEqual(@as(u64, 300), u.cache_read);
    try testing.expectEqual(@as(?f64, 2.5), u.cost_input);
}

test "golden: Diagnostics omits zero ints, false bool, null optionals" {
    const d = ai.types.Diagnostics{
        .trace_id = "trace_abc",
        .parts_seen = 5,
        .was_degenerate = true,
    };
    const json = try stringify(d);
    defer gpa.free(json);
    try testing.expectEqualStrings(
        "{\"traceId\":\"trace_abc\",\"partsSeen\":5,\"wasDegenerate\":true}",
        json,
    );

    // Round-trip: omitted fields come back as their defaults.
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
    defer parsed.deinit();
    const back = try std.json.parseFromValueLeaky(ai.types.Diagnostics, gpa, parsed.value, .{});
    try testing.expectEqual(@as(u32, 5), back.parts_seen);
    try testing.expectEqual(@as(u32, 0), back.text_event_count);
    try testing.expect(back.was_degenerate);
    gpa.free(back.trace_id.?);
}

test "golden: SessionHeader emits version first, then camelCase fields" {
    const h = session.SessionHeader{
        .id = "01K",
        .created_at_ms = 100,
        .updated_at_ms = 200,
        .title = "t",
        .provider = "p",
        .model = "m",
        .api = "a",
        .thinking_level = "off",
        .active_branch = "main",
        .system_prompt_hash = "",
    };
    const json = try stringify(h);
    defer gpa.free(json);

    const version = session.current_session_version;
    const expected = try std.fmt.allocPrint(gpa,
        "{{\"version\":{},\"id\":\"01K\",\"createdAtMs\":100,\"updatedAtMs\":200,\"title\":\"t\",\"provider\":\"p\",\"model\":\"m\",\"api\":\"a\",\"thinkingLevel\":\"off\",\"activeBranch\":\"main\",\"systemPromptHash\":\"\"}}",
        .{version});
    defer gpa.free(expected);
    try testing.expectEqualStrings(expected, json);

    // Round-trip ignores the version envelope field.
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
    defer parsed.deinit();
    const back = try std.json.parseFromValueLeaky(session.SessionHeader, gpa, parsed.value, .{ .ignore_unknown_fields = true });
    defer session.freeSessionHeader(gpa, back);
    try testing.expectEqualStrings("01K", back.id);
    try testing.expectEqual(@as(i64, 100), back.created_at_ms);
}

test "golden: Branch omits empty head_hash" {
    const b = branching.Branch{
        .name = "main",
        .parent = null,
        .fork_index = 0,
        .message_count = 3,
        .head_hash = "",
    };
    const json = try stringify(b);
    defer gpa.free(json);
    try testing.expectEqualStrings(
        "{\"name\":\"main\",\"forkIndex\":0,\"messageCount\":3}",
        json,
    );

    // With a head_hash it is emitted.
    const b2 = branching.Branch{
        .name = "feat",
        .parent = "main",
        .fork_index = 1,
        .message_count = 2,
        .head_hash = "abc123",
    };
    const json2 = try stringify(b2);
    defer gpa.free(json2);
    try testing.expectEqualStrings(
        "{\"name\":\"feat\",\"parent\":\"main\",\"forkIndex\":1,\"messageCount\":2,\"headHash\":\"abc123\"}",
        json2,
    );
}

test "golden: ProviderAuth serializes enum as apiKey + camelCase optionals" {
    const pa = auth.ProviderAuth{
        .type = .api_key,
        .api_key = "sk-test",
        .expires_at = "2030-01-01",
    };
    const json = try stringify(pa);
    defer gpa.free(json);
    try testing.expectEqualStrings(
        "{\"type\":\"apiKey\",\"apiKey\":\"sk-test\",\"expiresAt\":\"2030-01-01\"}",
        json,
    );

    // oauth variant.
    const po = auth.ProviderAuth{ .type = .oauth, .access_token = "tok" };
    const json2 = try stringify(po);
    defer gpa.free(json2);
    try testing.expectEqualStrings(
        "{\"type\":\"oauth\",\"accessToken\":\"tok\"}",
        json2,
    );

    // Round-trip: type parses back from the wire string.
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
    defer parsed.deinit();
    var back = try std.json.parseFromValueLeaky(auth.ProviderAuth, gpa, parsed.value, .{});
    defer back.deinit(gpa);
    try testing.expectEqual(auth.ProviderAuthType.api_key, back.type);
    try testing.expectEqualStrings("sk-test", back.api_key.?);
}

test "golden: models Cost uses shortest-round-trip floats" {
    const c = models.Cost{
        .input_per_1m = 3.0,
        .output_per_1m = 15.0,
        .cache_read_per_1m = 0.30,
        .cache_write_per_1m = 3.75,
    };
    const json = try stringify(c);
    defer gpa.free(json);
    try testing.expectEqualStrings(
        "{\"inputPer1M\":3,\"outputPer1M\":15,\"cacheReadPer1M\":0.3,\"cacheWritePer1M\":3.75}",
        json,
    );
}

test "golden: models Entry + Capabilities nested render" {
    const e = models.Entry{
        .id = "m1",
        .provider = "prov",
        .api = "anthropic-messages",
        .display_name = "Model One",
        .context_window = 200_000,
        .max_output = 8192,
        .capabilities = .{ .vision = true, .tool_use = true, .reasoning = true, .cache = true, .streaming = true },
        .cost = .{ .input_per_1m = 3.0, .output_per_1m = 15.0, .cache_read_per_1m = 0.30, .cache_write_per_1m = 3.75 },
        .knowledge_cutoff = "2025-12",
    };
    const json = try stringify(e);
    defer gpa.free(json);
    try testing.expectEqualStrings(
        "{\"id\":\"m1\",\"provider\":\"prov\",\"api\":\"anthropic-messages\",\"displayName\":\"Model One\",\"contextWindow\":200000,\"maxOutput\":8192,\"capabilities\":{\"vision\":true,\"toolUse\":true,\"reasoning\":true,\"cache\":true,\"streaming\":true},\"cost\":{\"inputPer1M\":3,\"outputPer1M\":15,\"cacheReadPer1M\":0.3,\"cacheWritePer1M\":3.75},\"knowledgeCutoff\":\"2025-12\"}",
        json,
    );
}

test "golden: edit details_json anonymous struct (with and without diff)" {
    // With a diff: `format` precedes `diff`.
    const with_diff = try std.json.Stringify.valueAlloc(gpa, .{
        .edits = @as(usize, 2),
        .format = "unified-diff-v1",
        .diff = @as([]const u8, "-old\n+new \"quoted\""),
        .path = @as([]const u8, "/tmp/x.txt"),
    }, .{});
    defer gpa.free(with_diff);
    try testing.expectEqualStrings(
        "{\"edits\":2,\"format\":\"unified-diff-v1\",\"diff\":\"-old\\n+new \\\"quoted\\\"\",\"path\":\"/tmp/x.txt\"}",
        with_diff,
    );

    // Without a diff: `format` is omitted and `diff` is null.
    const no_diff = try std.json.Stringify.valueAlloc(gpa, .{
        .edits = @as(usize, 1),
        .diff = @as(?[]const u8, null),
        .path = @as([]const u8, "/tmp/y.txt"),
    }, .{});
    defer gpa.free(no_diff);
    try testing.expectEqualStrings(
        "{\"edits\":1,\"diff\":null,\"path\":\"/tmp/y.txt\"}",
        no_diff,
    );
}

test "golden: write details_json anonymous struct" {
    const details = try std.json.Stringify.valueAlloc(gpa, .{
        .bytesWritten = @as(usize, 512),
        .parentCreated = true,
    }, .{});
    defer gpa.free(details);
    try testing.expectEqualStrings(
        "{\"bytesWritten\":512,\"parentCreated\":true}",
        details,
    );
}

// ─── End-to-end faux-provider → transcript persistence ───────────────
//
// Drives a real agent-loop turn against the scripted faux provider
// (streaming text + a usage event), then runs the actual
// `session.writeTranscript` persistence pipeline and asserts the
// `usage` object inside the emitted transcript.jsonl matches the
// Claude-Code-compatible wire shape produced by the migrated
// `Usage.jsonStringify` (json_meta) hook.

const agent = franky.agent;
const loop = franky.agent.loop;
const at = franky.agent.types;
const faux_mod = ai.providers.faux;

fn fauxStreamShim(ctx: ai.registry.StreamCtx) anyerror!void {
    const faux_ptr: *faux_mod.FauxProvider = @ptrCast(@alignCast(ctx.userdata.?));
    try faux_ptr.runSync(ctx.io, ctx.context, ctx.out);
}

test "e2e faux provider: usage flows through transcript.jsonl with json_meta wire shape" {
    var threaded = franky.test_helpers.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const alloc = franky.global_allocator.gpa;

    var faux = faux_mod.FauxProvider.init(alloc);
    defer faux.deinit();
    try faux.push(.{ .events = &.{
        .{ .text = .{ .text = "hello world", .chunk_size = 4 } },
        .{ .usage = .{
            .input = 1000,
            .output = 42,
            .cache_read = 200,
            .cache_write = 50,
            .cost_input = 0.0, // whole-number → forced decimal
            .cost_output = 1.5,
        } },
        .{ .done = .{ .stop_reason = .stop } },
    } });

    var reg = ai.registry.Registry.init(alloc);
    defer reg.deinit();
    try reg.register(.{
        .api = "faux",
        .provider = "faux",
        .stream_fn = fauxStreamShim,
        .userdata = @ptrCast(&faux),
    });

    var cancel = ai.stream.Cancel{};
    var transcript = loop.Transcript.init(alloc);
    defer transcript.deinit();

    var ch = try loop.AgentChannel.initWithDrop(alloc, 128, at.AgentEvent.deinit, alloc);
    defer ch.deinit();

    const config = loop.Config{
        .model = .{ .id = "faux-1", .provider = "faux", .api = "faux" },
        .system_prompt = "test",
        .tools = &.{},
        .registry = &reg,
        .cancel = &cancel,
    };
    loop.agentLoop(alloc, io, &transcript, config, &ch);
    while (ch.next(io)) |ev| ev.deinit(alloc);

    try testing.expectEqual(@as(usize, 1), transcript.messages.items.len);
    const msg = transcript.messages.items[0];
    try testing.expectEqual(ai.types.Role.assistant, msg.role);
    const usage = msg.usage orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u64, 1000), usage.input);

    // Persist via the real pipeline and inspect the emitted bytes.
    const sess_dir = "/tmp/franky_e2e_json_wire/01E2E";
    _ = std.Io.Dir.cwd().deleteTree(io, "/tmp/franky_e2e_json_wire") catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, "/tmp/franky_e2e_json_wire") catch {};
    try std.Io.Dir.cwd().createDirPath(io, sess_dir);

    try session.writeTranscript(alloc, io, sess_dir, &transcript, "main", null, "sess-e2e");

    const jsonl_path = try std.fmt.allocPrint(alloc, "{s}/transcript.jsonl", .{sess_dir});
    defer alloc.free(jsonl_path);
    var jsonl_file = try std.Io.Dir.cwd().openFile(io, jsonl_path, .{});
    const jsonl_len = try jsonl_file.length(io);
    const bytes = try alloc.alloc(u8, @intCast(jsonl_len));
    defer alloc.free(bytes);
    _ = try jsonl_file.readPositionalAll(io, bytes, 0);
    jsonl_file.close(io);

    // The usage object must carry the json_meta wire shape: uncached
    // input_tokens (1000-200-50=750), omitted zeros, forced-decimal
    // cost_input (0.0), natural cost_output (1.5).
    const expected_usage =
        "\"usage\":{\"input_tokens\":750,\"output_tokens\":42,\"cache_read_input_tokens\":200,\"cache_creation_input_tokens\":50,\"cost_input\":0.0,\"cost_output\":1.5}";
    try testing.expect(std.mem.indexOf(u8, bytes, expected_usage) != null);

    // And the full transcript must round-trip back through readTranscript.
    var loaded = try session.readTranscript(alloc, io, sess_dir);
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 1), loaded.messages.items.len);
    const lu = loaded.messages.items[0].usage orelse return error.TestUnexpectedResult;
    // v5 uncached (750) + cache_read + cache_write restores the total.
    try testing.expectEqual(@as(u64, 1000), lu.input);
    try testing.expectEqual(@as(u64, 42), lu.output);
}
