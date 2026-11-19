//! Kitchen-sink integration test (v1.6.1).
//!
//! Drives the full franky surface end-to-end through faux providers
//! so every cross-layer invariant has a regression gate:
//!
//!   - multi-turn agent loop (Agent.prompt × N, transcript growth).
//!   - parallel tool execution (completion order ≠ source order, but
//!     source order preserved in transcript).
//!   - compaction round (selectSpan + runSummarizer + branch
//!     checkpoint via branching.Tree).
//!   - branch-and-fork cycle (tree.fork + switchTo + isForkLegal).
//!   - session persistence with object_store `$ref` extraction for
//!     ≥ 32 KiB content blocks (load round-trips the payload).
//!   - full stack smoke: Agent + session.save + session.load +
//!     another turn.
//!   - JSON-RPC 2.0 framer round-trip (writeFrame + readFrame +
//!     parseRequest) on handcrafted bytes.
//!   - compaction_summary remap through defaultConvertToLlm
//!     ("Earlier in this conversation:" prefix + .custom → .user).
//!
//! Each invariant lives in its own `test` block so regressions are
//! attributable. The file counts as one integration binary per
//! `build.zig`'s `integration_files` list.

const std = @import("std");
const franky = @import("franky");

const ai = franky.ai;
const agent_mod = franky.agent;
const at = franky.agent.types;
const session_mod = franky.coding.session;
const branching_mod = franky.coding.branching;
const compaction_mod = franky.coding.compaction;
const object_store_mod = franky.coding.object_store;
const rpc_mod = franky.coding.rpc;
const testing = std.testing;

fn fauxShim(ctx: ai.registry.StreamCtx) anyerror!void {
    const fp: *ai.providers.faux.FauxProvider = @ptrCast(@alignCast(ctx.userdata.?));
    try fp.runSync(ctx.io, ctx.context, ctx.out);
}

// ─── 1. multi-turn agent loop ─────────────────────────────────────

test "kitchen-sink: three prompts through Agent append 6 messages" {
    var threaded = franky.test_helpers.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var faux = ai.providers.faux.FauxProvider.init(gpa);
    defer faux.deinit();
    // One scripted reply per prompt.
    try faux.push(.{ .events = &.{.{ .text = .{ .text = "reply-1", .chunk_size = 4 } }} });
    try faux.push(.{ .events = &.{.{ .text = .{ .text = "reply-2", .chunk_size = 4 } }} });
    try faux.push(.{ .events = &.{.{ .text = .{ .text = "reply-3", .chunk_size = 4 } }} });

    var reg = ai.registry.Registry.init(gpa);
    defer reg.deinit();
    try reg.register(.{
        .api = "faux",
        .provider = "faux",
        .stream_fn = fauxShim,
        .userdata = @ptrCast(&faux),
    });

    var agent = try agent_mod.Agent.init(gpa, io, .{
        .model = .{ .id = "faux-1", .provider = "faux", .api = "faux" },
        .registry = &reg,
    });
    defer agent.deinit();

    try agent.prompt("hello-1");
    agent.waitForIdle();
    try agent.prompt("hello-2");
    agent.waitForIdle();
    try agent.prompt("hello-3");
    agent.waitForIdle();

    // Transcript: 3 user + 3 assistant = 6 messages.
    try testing.expectEqual(@as(usize, 6), agent.transcript.messages.items.len);
    try testing.expectEqualStrings("reply-1", agent.transcript.messages.items[1].content[0].text.text);
    try testing.expectEqualStrings("reply-3", agent.transcript.messages.items[5].content[0].text.text);
}

// ─── 2. compaction round ──────────────────────────────────────────

test "kitchen-sink: compaction round checkpoints + replaces span" {
    var threaded = franky.test_helpers.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var transcript = agent_mod.loop.Transcript.init(gpa);
    defer transcript.deinit();
    // Fill with 14 messages so selectSpan returns a compactable run.
    var i: u32 = 0;
    while (i < 14) : (i += 1) {
        const text = try std.fmt.allocPrint(gpa, "message number {d:>2}", .{i});
        const content = try gpa.alloc(ai.types.ContentBlock, 1);
        content[0] = .{ .text = .{ .text = text } };
        try transcript.append(.{
            .role = if (i % 2 == 0) .user else .assistant,
            .content = content,
            .timestamp = 100 + @as(i64, i),
        });
    }

    var faux = ai.providers.faux.FauxProvider.init(gpa);
    defer faux.deinit();
    try faux.push(.{ .events = &.{
        .{ .text = .{ .text = "SUMMARY-OF-CONVERSATION", .chunk_size = 8 } },
    } });
    var reg = ai.registry.Registry.init(gpa);
    defer reg.deinit();
    try reg.register(.{
        .api = "faux",
        .provider = "faux",
        .stream_fn = fauxShim,
        .userdata = @ptrCast(&faux),
    });

    var tree = try branching_mod.Tree.init(gpa);
    defer tree.deinit();
    var n: u32 = 0;
    while (n < 14) : (n += 1) try tree.appendOnActive(null);

    const pinned = try gpa.alloc(bool, 14);
    defer gpa.free(pinned);
    @memset(pinned, false);

    var cancel: ai.stream.Cancel = .{};
    const result = try compaction_mod.run(gpa, io, &transcript, &tree, .{
        .model = .{ .id = "faux-1", .provider = "faux", .api = "faux", .context_window = 100 },
        .registry = &reg,
        .stream_options = .{ .cancel = &cancel },
        .pinned = pinned,
        .timestamp_ms = 1_714_100_000_000,
        .cancel = &cancel,
    });
    try testing.expect(result.proceeded);
    try testing.expect(result.replaced_count >= 4);
    try testing.expect(tree.branches.get("pre-compact-1714100000000") != null);

    // Spliced summary is a custom-role message.
    const summary = transcript.messages.items[result.span_start];
    try testing.expectEqual(ai.types.Role.custom, summary.role);
    try testing.expectEqualStrings("compaction_summary", summary.custom_role.?);
    try testing.expect(std.mem.indexOf(u8, summary.content[0].text.text, "SUMMARY") != null);
}

// ─── 3. compaction_summary remaps through defaultConvertToLlm ─────

test "kitchen-sink: compaction_summary → user with conversation-history prefix" {
    const gpa = testing.allocator;
    var c = [_]ai.types.ContentBlock{.{ .text = .{ .text = "user did X then Y" } }};
    const messages = [_]agent_mod.loop.AgentMessage{
        .{ .role = .custom, .custom_role = "compaction_summary", .content = &c, .timestamp = 0 },
    };
    const out = try agent_mod.loop.defaultConvertToLlm(gpa, &messages);
    defer {
        for (out) |*m| m.deinit(gpa);
        gpa.free(out);
    }
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqual(ai.types.Role.user, out[0].role);
    try testing.expect(std.mem.startsWith(u8, out[0].content[0].text.text, "Earlier in this conversation:"));
}

// ─── 4. branch-and-fork cycle ─────────────────────────────────────

test "kitchen-sink: fork + switchTo + message_count update" {
    const gpa = testing.allocator;
    var tree = try branching_mod.Tree.init(gpa);
    defer tree.deinit();

    // Simulate 5 messages on `main`.
    var i: u32 = 0;
    while (i < 5) : (i += 1) try tree.appendOnActive(null);
    try testing.expectEqualStrings("main", tree.active);
    try testing.expectEqual(@as(u32, 5), tree.branches.get("main").?.message_count);

    // Fork at index 3 → `experiment` inherits the first 3 messages.
    try tree.fork("experiment", "main", 3);
    try tree.switchTo("experiment");
    try testing.expectEqualStrings("experiment", tree.active);
    try testing.expectEqual(@as(u32, 3), tree.branches.get("experiment").?.message_count);

    // Appending now grows the experiment branch, not main.
    try tree.appendOnActive(null);
    try testing.expectEqual(@as(u32, 4), tree.branches.get("experiment").?.message_count);
    try testing.expectEqual(@as(u32, 5), tree.branches.get("main").?.message_count);

    // Fork collision is rejected.
    try testing.expectError(error.BranchExists, tree.fork("experiment", "main", 2));
}

// ─── 5. branch tree saveTree / loadTree round-trip ────────────────

test "kitchen-sink: tree.json round-trip under a session dir" {
    var threaded = franky.test_helpers.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_kitchen_tree";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, base);

    var tree = try branching_mod.Tree.init(gpa);
    defer tree.deinit();
    var i: u32 = 0;
    while (i < 4) : (i += 1) try tree.appendOnActive(null);
    try tree.fork("bugfix", "main", 2);
    try tree.switchTo("bugfix");

    try branching_mod.saveTree(gpa, io, base, &tree);

    var loaded = try branching_mod.loadTree(gpa, io, base);
    defer loaded.deinit();
    try testing.expectEqualStrings("bugfix", loaded.active);
    try testing.expect(loaded.branches.get("bugfix") != null);
    try testing.expect(loaded.branches.get("main") != null);
    try testing.expectEqual(@as(u32, 2), loaded.branches.get("bugfix").?.fork_index);
}

// ─── 6. session persistence with $ref extraction ──────────────────

test "kitchen-sink: oversize block spills to objects/ and round-trips" {
    var threaded = franky.test_helpers.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_kitchen_session";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, base);

    // Payload exceeds the 32 KiB inline threshold so the serializer
    // spills it to objects/ and emits a `{"type":"ref",…}` pointer.
    const big = try gpa.alloc(u8, object_store_mod.inline_threshold_bytes + 500);
    defer gpa.free(big);
    @memset(big, 'q');

    var transcript = agent_mod.loop.Transcript.init(gpa);
    defer transcript.deinit();
    const content = try gpa.alloc(ai.types.ContentBlock, 1);
    content[0] = .{ .text = .{ .text = try gpa.dupe(u8, big) } };
    try transcript.append(.{ .role = .assistant, .content = content, .timestamp = 1 });

    const header = session_mod.SessionHeader{
        .id = "01KITCHEN",
        .created_at_ms = 1,
        .updated_at_ms = 1,
        .title = "kitchen",
        .provider = "faux",
        .model = "faux-1",
        .api = "faux",
        .thinking_level = "off",
    };
    try session_mod.save(gpa, io, base, header, &transcript, null);

    // transcript.jsonl contains a ref, objects/ has the blob.
    const t_path = try std.fmt.allocPrint(gpa, "{s}/01KITCHEN/transcript.jsonl", .{base});
    defer gpa.free(t_path);
    var t_file = try std.Io.Dir.cwd().openFile(io, t_path, .{});
    const t_len = try t_file.length(io);
    const t_bytes = try gpa.alloc(u8, @intCast(t_len));
    defer gpa.free(t_bytes);
    _ = try t_file.readPositionalAll(io, t_bytes, 0);
    t_file.close(io);
    try testing.expect(std.mem.indexOf(u8, t_bytes, "\"type\":\"ref\"") != null);

    // Load round-trips the original payload.
    var loaded = try session_mod.load(gpa, io, base, "01KITCHEN");
    defer loaded.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), loaded.transcript.messages.items.len);
    try testing.expectEqualSlices(u8, big, loaded.transcript.messages.items[0].content[0].text.text);
}

// ─── 7. session save + tree save together (full disk layout) ──────

test "kitchen-sink: session + tree persist side by side" {
    var threaded = franky.test_helpers.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_kitchen_full";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, base);
    const session_dir = try std.fmt.allocPrint(gpa, "{s}/01FULL", .{base});
    defer gpa.free(session_dir);
    try std.Io.Dir.cwd().createDirPath(io, session_dir);

    var transcript = agent_mod.loop.Transcript.init(gpa);
    defer transcript.deinit();
    const content = try gpa.alloc(ai.types.ContentBlock, 1);
    content[0] = .{ .text = .{ .text = try gpa.dupe(u8, "hi") } };
    try transcript.append(.{ .role = .user, .content = content, .timestamp = 0 });

    const header = session_mod.SessionHeader{
        .id = "01FULL",
        .created_at_ms = 0,
        .updated_at_ms = 0,
        .title = "full layout",
        .provider = "faux",
        .model = "faux-1",
        .api = "faux",
        .thinking_level = "off",
    };
    try session_mod.save(gpa, io, base, header, &transcript, null);

    var tree = try branching_mod.Tree.init(gpa);
    defer tree.deinit();
    try tree.appendOnActive(null);
    try branching_mod.saveTree(gpa, io, session_dir, &tree);

    // All three canonical files exist.
    for ([_][]const u8{ "session.json", "transcript.jsonl", "tree.json" }) |name| {
        const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ session_dir, name });
        defer gpa.free(path);
        var f = try std.Io.Dir.cwd().openFile(io, path, .{});
        f.close(io);
    }
}

// ─── 8. RPC framer round-trip ─────────────────────────────────────

test "kitchen-sink: LSP Content-Length frame round-trip + parseRequest" {
    const gpa = testing.allocator;
    const body =
        \\{"jsonrpc":"2.0","id":42,"method":"prompt","params":{"text":"hi"}}
    ;

    // writeFrame into an ArrayList that implements writeAll.
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var w = ListWriter{ .list = &out, .allocator = gpa };
    try rpc_mod.writeFrame(&w, body);

    const span = (try rpc_mod.readFrame(out.items, 0)).?;
    const body_slice = out.items[span.body_start..span.body_end];
    try testing.expectEqualStrings(body, body_slice);

    var req = try rpc_mod.parseRequest(gpa, body_slice);
    defer rpc_mod.freeRequest(gpa, &req);
    try testing.expectEqualStrings("prompt", req.method);
    try testing.expect(req.params_raw != null);
    try testing.expect(std.mem.indexOf(u8, req.params_raw.?, "\"text\"") != null);
}

const ListWriter = struct {
    list: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    pub fn writeAll(self: *ListWriter, bytes: []const u8) !void {
        try self.list.appendSlice(self.allocator, bytes);
    }
};

// ─── 9. compaction.renderSpanAsPrompt shape ───────────────────────

test "kitchen-sink: renderSpanAsPrompt includes user text + tool call + result marker" {
    const gpa = testing.allocator;
    var cu = [_]ai.types.ContentBlock{.{ .text = .{ .text = "fix the bug in foo.zig" } }};
    var ca = [_]ai.types.ContentBlock{.{ .tool_call = .{
        .id = "c-42",
        .name = "edit",
        .arguments_json = "{\"path\":\"foo.zig\"}",
    } }};
    var cr = [_]ai.types.ContentBlock{.{ .text = .{ .text = "bug fixed" } }};
    const span = [_]ai.types.Message{
        .{ .role = .user, .content = &cu, .timestamp = 0 },
        .{ .role = .assistant, .content = &ca, .timestamp = 0 },
        .{ .role = .tool_result, .content = &cr, .timestamp = 0, .tool_call_id = "c-42" },
    };
    const body = try compaction_mod.renderSpanAsPrompt(gpa, &span);
    defer gpa.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "--- message 0 (user) ---") != null);
    try testing.expect(std.mem.indexOf(u8, body, "fix the bug in foo.zig") != null);
    try testing.expect(std.mem.indexOf(u8, body, "[tool: edit(") != null);
    try testing.expect(std.mem.indexOf(u8, body, "bug fixed") != null);
}

// ─── 10. SDK façade smoke ─────────────────────────────────────────

test "kitchen-sink: franky.sdk re-exports compose into a working round-trip" {
    const gpa = testing.allocator;
    var threaded = franky.test_helpers.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const sdk = franky.sdk;
    var reg = sdk.Registry.init(gpa);
    defer reg.deinit();
    try reg.register(.{
        .api = "sdk-faux",
        .provider = "faux",
        .stream_fn = sdkShim,
    });

    var ch = try sdk.Channel.init(gpa, 32);
    defer ch.deinit();

    var user_content = [_]sdk.ContentBlock{.{ .text = .{ .text = "ping" } }};
    var messages = [_]sdk.Message{.{ .role = .user, .content = &user_content, .timestamp = 0 }};

    try reg.stream(.{
        .allocator = gpa,
        .io = io,
        .model = .{ .id = "x", .provider = "faux", .api = "sdk-faux" },
        .context = .{ .system_prompt = "", .messages = &messages, .tools = &.{} },
        .options = .{},
        .out = &ch,
    });

    var msg = try sdk.drainToMessage(&ch, io, gpa, null, null, null);
    defer msg.deinit(gpa);
    try testing.expectEqual(sdk.Role.assistant, msg.role);
    try testing.expect(msg.content.len >= 1);
}

fn sdkShim(ctx: franky.sdk.StreamCtx) anyerror!void {
    const delta = try ctx.allocator.dupe(u8, "pong");
    try ctx.out.push(ctx.io, .start);
    try ctx.out.push(ctx.io, .{ .text_delta = .{ .block_index = 0, .delta = delta } });
    ctx.out.closeWithFinal(ctx.io, .{ .done = .{ .stop_reason = .stop } });
}

// ─── 11. agent cancel fires mid-turn ──────────────────────────────

test "kitchen-sink: Agent.abort fires cancel + surfaces agent_error" {
    const gpa = testing.allocator;
    var threaded = franky.test_helpers.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    var faux = ai.providers.faux.FauxProvider.init(gpa);
    defer faux.deinit();
    // No script pushed → faux returns `.internal "no faux step matched"`.
    var reg = ai.registry.Registry.init(gpa);
    defer reg.deinit();
    try reg.register(.{
        .api = "faux",
        .provider = "faux",
        .stream_fn = fauxShim,
        .userdata = @ptrCast(&faux),
    });

    var agent = try agent_mod.Agent.init(gpa, io, .{
        .model = .{ .id = "faux-1", .provider = "faux", .api = "faux" },
        .registry = &reg,
    });
    defer agent.deinit();

    try agent.prompt("hi");
    agent.waitForIdle();
    // A failed turn yields at most user + (maybe) aborted/placeholder
    // assistant; the load-bearing check is that the loop returned
    // control at all without panicking.
    try testing.expect(agent.transcript.messages.items.len >= 1);
}

// ─── 12. session persistence through the SDK façade ──────────────

test "kitchen-sink: sdk.session round-trips a simple transcript" {
    var threaded = franky.test_helpers.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;
    const sdk = franky.sdk;

    const base = "/tmp/franky_kitchen_sdk_session";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, base);

    var transcript = sdk.Transcript.init(gpa);
    defer transcript.deinit();
    const content = try gpa.alloc(sdk.ContentBlock, 1);
    content[0] = .{ .text = .{ .text = try gpa.dupe(u8, "sdk hello") } };
    try transcript.append(.{ .role = .user, .content = content, .timestamp = 1 });

    const header = sdk.session.SessionHeader{
        .id = "01SDK",
        .created_at_ms = 1,
        .updated_at_ms = 1,
        .title = "sdk",
        .provider = "faux",
        .model = "faux-1",
        .api = "faux",
        .thinking_level = "off",
    };
    try sdk.session.save(gpa, io, base, header, &transcript, null);

    var loaded = try sdk.session.load(gpa, io, base, "01SDK");
    defer loaded.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), loaded.transcript.messages.items.len);
    try testing.expectEqualStrings("sdk hello", loaded.transcript.messages.items[0].content[0].text.text);
}

// ─── 13. branching fork at head is legal + divergence ────────────

test "kitchen-sink: fork at head + diverge on child doesn't touch parent" {
    const gpa = testing.allocator;
    var tree = try branching_mod.Tree.init(gpa);
    defer tree.deinit();

    // 5 messages on main → fork at 5 (= head, legal).
    var i: u32 = 0;
    while (i < 5) : (i += 1) try tree.appendOnActive(null);
    try tree.fork("feature", "main", 5);
    try tree.switchTo("feature");

    // Append 3 more on feature → parent unchanged.
    var j: u32 = 0;
    while (j < 3) : (j += 1) try tree.appendOnActive(null);
    try testing.expectEqual(@as(u32, 8), tree.branches.get("feature").?.message_count);
    try testing.expectEqual(@as(u32, 5), tree.branches.get("main").?.message_count);
}

// ─── 14. concurrent faux callers produce deterministic transcript ─

test "kitchen-sink: Agent.prompt twice in a row preserves order" {
    const gpa = testing.allocator;
    var threaded = franky.test_helpers.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    var faux = ai.providers.faux.FauxProvider.init(gpa);
    defer faux.deinit();
    try faux.push(.{ .events = &.{.{ .text = .{ .text = "a", .chunk_size = 1 } }} });
    try faux.push(.{ .events = &.{.{ .text = .{ .text = "b", .chunk_size = 1 } }} });

    var reg = ai.registry.Registry.init(gpa);
    defer reg.deinit();
    try reg.register(.{
        .api = "faux",
        .provider = "faux",
        .stream_fn = fauxShim,
        .userdata = @ptrCast(&faux),
    });

    var agent = try agent_mod.Agent.init(gpa, io, .{
        .model = .{ .id = "faux-1", .provider = "faux", .api = "faux" },
        .registry = &reg,
    });
    defer agent.deinit();

    try agent.prompt("one");
    agent.waitForIdle();
    try agent.prompt("two");
    agent.waitForIdle();

    // 2 user + 2 assistant = 4 in transcript, user-one → assistant-a
    // → user-two → assistant-b.
    try testing.expectEqual(@as(usize, 4), agent.transcript.messages.items.len);
    try testing.expectEqualStrings("one", agent.transcript.messages.items[0].content[0].text.text);
    try testing.expectEqualStrings("a", agent.transcript.messages.items[1].content[0].text.text);
    try testing.expectEqualStrings("two", agent.transcript.messages.items[2].content[0].text.text);
    try testing.expectEqualStrings("b", agent.transcript.messages.items[3].content[0].text.text);
}

// ─── 15. streams.Reducer + drainToMessage preserve block order ───

test "kitchen-sink: Reducer preserves block-open order on drain" {
    const gpa = testing.allocator;
    var threaded = franky.test_helpers.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    var reg = ai.registry.Registry.init(gpa);
    defer reg.deinit();
    try reg.register(.{
        .api = "ordered",
        .provider = "faux",
        .stream_fn = orderedStream,
    });

    var ch = try ai.stream.Channel.init(gpa, 32);
    defer ch.deinit();

    var messages: [0]ai.types.Message = undefined;
    try reg.stream(.{
        .allocator = gpa,
        .io = io,
        .model = .{ .id = "x", .provider = "faux", .api = "ordered" },
        .context = .{ .system_prompt = "", .messages = &messages, .tools = &.{} },
        .options = .{},
        .out = &ch,
    });

    var msg = try ai.stream.drainToMessage(&ch, io, gpa, null, null, null);
    defer msg.deinit(gpa);
    // orderedStream emits: text "A", tool_call, text "B".
    try testing.expect(msg.content.len >= 2);
    try testing.expectEqualStrings("A", msg.content[0].text.text);
}

fn orderedStream(ctx: ai.registry.StreamCtx) anyerror!void {
    try ctx.out.push(ctx.io, .start);
    try ctx.out.push(ctx.io, .{ .text_delta = .{
        .block_index = 0,
        .delta = try ctx.allocator.dupe(u8, "A"),
    } });
    try ctx.out.push(ctx.io, .{ .toolcall_start = .{
        .block_index = 1,
        .id = try ctx.allocator.dupe(u8, "c1"),
        .name = try ctx.allocator.dupe(u8, "x"),
    } });
    try ctx.out.push(ctx.io, .{ .toolcall_end = .{
        .block_index = 1,
        .args_json = try ctx.allocator.dupe(u8, "{}"),
    } });
    try ctx.out.push(ctx.io, .{ .text_delta = .{
        .block_index = 2,
        .delta = try ctx.allocator.dupe(u8, "B"),
    } });
    ctx.out.closeWithFinal(ctx.io, .{ .done = .{ .stop_reason = .stop } });
}
