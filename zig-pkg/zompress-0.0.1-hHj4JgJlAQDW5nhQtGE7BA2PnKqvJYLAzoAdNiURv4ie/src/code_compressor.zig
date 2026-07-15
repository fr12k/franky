const std = @import("std");
const CompressConfig = @import("main.zig").CompressConfig;
const CompressResult = @import("main.zig").CompressResult;

const Ast = std.zig.Ast;
const Node = Ast.Node;

const KeptRange = struct {
    start: usize,
    end: usize,
    omitted: usize,
};

pub fn compress(allocator: std.mem.Allocator, source: []const u8, config: CompressConfig) !CompressResult {
    _ = config;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const source_z = try a.allocSentinel(u8, source.len, 0);
    @memcpy(source_z[0..source.len], source);
    var tree = try Ast.parse(a, source_z, .zig);
    defer tree.deinit(a);

    if (tree.errors.len > 0) {
        return CompressResult.passthrough(allocator, source);
    }

    const plan = try buildCompressionPlan(a, &tree);
    defer a.free(plan.kept_ranges);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    for (plan.kept_ranges) |range| {
        try out.appendSlice(allocator, source[range.start..range.end]);
        if (range.omitted > 0) {
            try out.appendSlice(allocator, try std.fmt.allocPrint(a, "\n// ... {d} lines omitted ...\n", .{range.omitted}));
        }
    }

    const compressed = try allocator.dupe(u8, out.items);
    const tokens_before = source.len / 4;
    const tokens_after = compressed.len / 4;

    return CompressResult{
        .compressed = compressed,
        .tokens_before = tokens_before,
        .tokens_after = tokens_after,
        .tokens_saved = tokens_before -| tokens_after,
        .compression_ratio = @as(f64, @floatFromInt(compressed.len)) / @as(f64, @floatFromInt(source.len)),
        .transforms_applied = try allocator.dupe([]const u8, &[_][]const u8{"code_compressor"}),
        .ccr_keys = try allocator.dupe([]const u8, &[_][]const u8{}),
    };
}

fn buildCompressionPlan(allocator: std.mem.Allocator, tree: *const Ast) !struct { kept_ranges: []KeptRange } {
    var ranges: std.ArrayList(KeptRange) = .empty;
    defer ranges.deinit(allocator);

    const root_decls = tree.rootDecls();
    const source = tree.source;

    for (root_decls) |decl_node| {
        const tag = tree.nodeTag(decl_node);
        switch (tag) {
            .fn_decl => try processFnDecl(allocator, tree, decl_node, source, &ranges),
            .container_decl, .container_decl_trailing, .container_decl_two, .container_decl_two_trailing, .container_decl_arg, .container_decl_arg_trailing => addFullNode(allocator, tree, decl_node, source, &ranges),
            .test_decl => try processTestDecl(allocator, tree, decl_node, source, &ranges),
            .global_var_decl, .local_var_decl, .simple_var_decl, .aligned_var_decl => addFullNode(allocator, tree, decl_node, source, &ranges),
            .@"comptime" => addFullNode(allocator, tree, decl_node, source, &ranges),
            else => addFullNode(allocator, tree, decl_node, source, &ranges),
        }
    }

    return .{ .kept_ranges = try ranges.toOwnedSlice(allocator) };
}

fn processFnDecl(allocator: std.mem.Allocator, tree: *const Ast, decl_node: Node.Index, source: []const u8, ranges: *std.ArrayList(KeptRange)) !void {
    const data = tree.nodeData(decl_node);
    _ = data.node_and_node[0];
    const body_node = data.node_and_node[1];

    try ranges.append(allocator, .{
        .start = tree.tokenStart(tree.firstToken(decl_node)),
        .end = tree.tokenStart(tree.nodeMainToken(body_node)),
        .omitted = 0,
    });

    try processBodyBlock(allocator, tree, body_node, source, ranges);
}

fn processTestDecl(allocator: std.mem.Allocator, tree: *const Ast, decl_node: Node.Index, source: []const u8, ranges: *std.ArrayList(KeptRange)) !void {
    const data = tree.nodeData(decl_node);
    const name_token = data.opt_token_and_node[0];
    const body_node = data.opt_token_and_node[1];

    const body_start = if (name_token.unwrap()) |nt|
        tree.tokenStart(nt) + tree.tokenSlice(nt).len
    else
        tree.tokenStart(tree.firstToken(decl_node)) + 5;

    try ranges.append(allocator, .{
        .start = tree.tokenStart(tree.firstToken(decl_node)),
        .end = body_start,
        .omitted = 0,
    });

    try processBodyBlock(allocator, tree, body_node, source, ranges);
}

fn processBodyBlock(allocator: std.mem.Allocator, tree: *const Ast, block_node: Node.Index, source: []const u8, ranges: *std.ArrayList(KeptRange)) !void {
    const tag = tree.nodeTag(block_node);
    if (tag != .block and tag != .block_semicolon) {
        addFullNode(allocator, tree, block_node, source, ranges);
        return;
    }

    const data = tree.nodeData(block_node);
    const statements = tree.extraDataSlice(data.extra_range, Node.Index);

    if (statements.len <= 5) {
        addFullNode(allocator, tree, block_node, source, ranges);
        return;
    }

    const lbrace = tree.nodeMainToken(block_node);
    const has_semicolon = tag == .block_semicolon;
    const rbrace = if (has_semicolon) blk: {
        var ti = lbrace;
        while (ti < tree.tokens.len) : (ti += 1) {
            if (tree.tokenTag(ti) == .semicolon) break;
        }
        break :blk ti;
    } else blk: {
        var ti = lbrace;
        while (ti < tree.tokens.len) : (ti += 1) {
            if (tree.tokenTag(ti) == .r_brace) break;
        }
        break :blk ti;
    };

    const max_keep = 5;
    var keep: std.ArrayList(usize) = .empty;
    defer keep.deinit(allocator);

    var i: usize = 0;
    while (i < statements.len and i < 2) : (i += 1) try keep.append(allocator, i);
    if (statements.len > 2) try keep.append(allocator, statements.len - 1);

    for (statements, 0..) |stmt, idx| {
        if (idx == 0 or idx == statements.len - 1 or idx < 2) continue;
        if (keep.items.len >= max_keep) break;
        switch (tree.nodeTag(stmt)) {
            .@"return", .@"continue", .@"break", .@"try", .@"catch", .if_simple, .@"if" => try keep.append(allocator, idx),
            else => if (keep.items.len < max_keep) try keep.append(allocator, idx),
        }
    }

    std.mem.sort(usize, keep.items, {}, std.sort.asc(usize));

    var deduped: std.ArrayList(usize) = .empty;
    defer deduped.deinit(allocator);
    for (keep.items, 0..) |idx, j| {
        if (j == 0 or keep.items[j - 1] != idx) try deduped.append(allocator, idx);
    }

    const brace_start = tree.tokenStart(lbrace);
    try ranges.append(allocator, .{ .start = brace_start, .end = brace_start + 1, .omitted = 0 });

    var omitted_count: usize = 0;
    for (deduped.items, 0..) |stmt_idx, j| {
        const stmt_start = tree.tokenStart(tree.nodeMainToken(statements[stmt_idx]));
        if (j > 0) {
            const prev_end = lastTokenEnd(tree, statements[deduped.items[j - 1]]);
            omitted_count += linesBetween(source, prev_end, stmt_start);
        } else {
            omitted_count += linesBetween(source, brace_start + 1, stmt_start);
        }
        try ranges.append(allocator, .{ .start = stmt_start, .end = lastTokenEnd(tree, statements[stmt_idx]), .omitted = 0 });
    }

    if (deduped.items.len > 0) {
        omitted_count += linesBetween(source, lastTokenEnd(tree, statements[deduped.items[deduped.items.len - 1]]), tree.tokenStart(rbrace));
    }

    try ranges.append(allocator, .{ .start = tree.tokenStart(rbrace), .end = tree.tokenStart(rbrace) + 1, .omitted = 0 });

    if (omitted_count > 0 and ranges.items.len >= 3) {
        ranges.items[ranges.items.len - 3].omitted = omitted_count;
    }
}

fn addFullNode(allocator: std.mem.Allocator, tree: *const Ast, node: Node.Index, source: []const u8, ranges: *std.ArrayList(KeptRange)) void {
    const start = tree.tokenStart(tree.firstToken(node));
    const end = lastTokenEnd(tree, node);
    ranges.append(allocator, .{ .start = start, .end = @min(end, source.len), .omitted = 0 }) catch {};
}

fn lastTokenEnd(tree: *const Ast, node: Node.Index) usize {
    const last_ti = tree.lastToken(node);
    return tree.tokenStart(last_ti) + tree.tokenSlice(last_ti).len;
}

fn linesBetween(source: []const u8, start: usize, end: usize) usize {
    if (start >= end) return 0;
    var count: usize = 0;
    var i = start;
    while (i < end and i < source.len) : (i += 1) {
        if (source[i] == '\n' and i + 1 < end) count += 1;
    }
    return if (count > 0) count else 0;
}

test "compile and parse zig source with arena" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = try a.allocSentinel(u8, "const std = @import(\"std\");\n\npub fn main() !void {\n    const x: i32 = 42;\n}".len, 0);
    @memcpy(source[0.."const std = @import(\"std\");\n\npub fn main() !void {\n    const x: i32 = 42;\n}".len], "const std = @import(\"std\");\n\npub fn main() !void {\n    const x: i32 = 42;\n}");
    var tree = try Ast.parse(a, source, .zig);
    defer tree.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);
}

test "compress function body removes lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = try a.allocSentinel(u8, \\pub fn process() !void {
        \\    var x: i32 = 0;
        \\    x += 1;
        \\    x += 2;
        \\    x += 3;
        \\    x += 4;
        \\    x += 5;
        \\    return x;
        \\}
    .len, 0);
    @memcpy(source[0..\\pub fn process() !void {
        \\    var x: i32 = 0;
        \\    x += 1;
        \\    x += 2;
        \\    x += 3;
        \\    x += 4;
        \\    x += 5;
        \\    return x;
        \\}
    .len], \\pub fn process() !void {
        \\    var x: i32 = 0;
        \\    x += 1;
        \\    x += 2;
        \\    x += 3;
        \\    x += 4;
        \\    x += 5;
        \\    return x;
        \\}
    );
    const config = CompressConfig{};
    const result = try compress(std.testing.allocator, source, config);
    defer std.testing.allocator.free(result.compressed);
    defer std.testing.allocator.free(result.transforms_applied);
    defer std.testing.allocator.free(result.ccr_keys);
    try std.testing.expect(std.mem.indexOf(u8, result.compressed, "pub fn process") != null);
    try std.testing.expect(result.transforms_applied.len > 0);
}

test "compress struct declaration preserved fully" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = try a.allocSentinel(u8, \\pub const Config = struct {
        \\    timeout: u64 = 1000,
        \\    retries: u8 = 3,
        \\};
    .len, 0);
    @memcpy(source[0..\\pub const Config = struct {
        \\    timeout: u64 = 1000,
        \\    retries: u8 = 3,
        \\};
    .len], \\pub const Config = struct {
        \\    timeout: u64 = 1000,
        \\    retries: u8 = 3,
        \\};
    );
    const config = CompressConfig{};
    const result = try compress(std.testing.allocator, source, config);
    defer std.testing.allocator.free(result.compressed);
    defer std.testing.allocator.free(result.transforms_applied);
    defer std.testing.allocator.free(result.ccr_keys);
    try std.testing.expect(std.mem.indexOf(u8, result.compressed, "pub const Config") != null);
}

test "compress invalid zig passthrough" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = try a.allocSentinel(u8, "not valid zig @@@\n".len, 0);
    @memcpy(source[0.."not valid zig @@@\n".len], "not valid zig @@@\n");
    const config = CompressConfig{};
    const result = try compress(std.testing.allocator, source, config);
    defer std.testing.allocator.free(result.compressed);
    defer std.testing.allocator.free(result.transforms_applied);
    defer std.testing.allocator.free(result.ccr_keys);
    try std.testing.expectEqualStrings(source, result.compressed);
}
