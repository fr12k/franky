const std = @import("std");

/// Compute the optimal number of items to keep using the Kneedle algorithm.
/// `items` is a list of string representations in importance order
/// (most important first, sorted by descending importance).
/// Returns k (number of items to keep).
pub fn computeOptimalK(items: []const []const u8, bias: f64, min_k: usize, max_k: ?usize) usize {
    if (items.len <= min_k) return items.len;
    if (items.len == 0) return 0;

    // 1. Compute importance curve using item length as proxy for information density
    //    (longer items = more information-dense)
    var importance: std.ArrayList(f64) = .empty;
    defer importance.deinit(std.heap.page_allocator);

    var max_len: f64 = 0;
    for (items) |item| {
        const len = @as(f64, @floatFromInt(item.len));
        importance.append(std.heap.page_allocator, len) catch {};
        if (len > max_len) max_len = len;
    }

    const n = importance.items.len;
    if (n < 3) return @min(n, max_k orelse n);

    // 2. Normalize curve to [0, 1]
    var norm: std.ArrayList(f64) = .empty;
    defer norm.deinit(std.heap.page_allocator);

    if (max_len > 0) {
        for (importance.items) |v| {
            norm.append(std.heap.page_allocator, v / max_len) catch {};
        }
    } else {
        for (importance.items) |_| {
            norm.append(std.heap.page_allocator, 0.0) catch {};
        }
    }

    // 3. Compute difference curve: diff[i] = norm[i+1] - norm[i]
    if (norm.items.len < 2) return @min(n, max_k orelse n);

    var diff: std.ArrayList(f64) = .empty;
    defer diff.deinit(std.heap.page_allocator);

    var i: usize = 0;
    while (i < norm.items.len - 1) : (i += 1) {
        diff.append(std.heap.page_allocator, norm.items[i + 1] - norm.items[i]) catch {};
    }

    // 4. Compute second difference: diff2[i] = diff[i+1] - diff[i]
    if (diff.items.len < 2) return @min(n, max_k orelse n);

    var diff2: std.ArrayList(f64) = .empty;
    defer diff2.deinit(std.heap.page_allocator);

    i = 0;
    while (i < diff.items.len - 1) : (i += 1) {
        diff2.append(std.heap.page_allocator, diff.items[i + 1] - diff.items[i]) catch {};
    }

    // 5. Find the knee: largest positive second difference
    //    (steepest drop in marginal importance)
    var knee_idx: usize = 0;
    var max_diff2: f64 = -std.math.inf(f64);

    for (diff2.items, 0..) |d, idx| {
        if (d > max_diff2) {
            max_diff2 = d;
            knee_idx = idx;
        }
    }

    // 6. Adjust with bias: k = knee_index * bias
    const k_raw = @as(f64, @floatFromInt(knee_idx + 2)) * bias; // +2 because diff2 is shifted by 2
    var k: usize = @intFromFloat(@ceil(k_raw));

    // 7. Clamp to [min_k, max_k] if provided
    if (k < min_k) k = min_k;
    if (max_k) |mk| {
        if (k > mk) k = mk;
    }
    if (k > items.len) k = items.len;

    return k;
}

/// Compute K-split: divide total K budget into first/last/importance portions.
pub fn computeKSplit(items: []const []const u8, max_items_after_crush: usize, bias: f64) struct {
    k_total: usize,
    k_first: usize,
    k_last: usize,
    k_importance: usize,
} {
    const k_total = computeOptimalK(items, bias, 3, max_items_after_crush);

    // Clamp: k_first + k_last <= k_total
    const k_first = @min(@max(@as(usize, 1), @as(usize, @intFromFloat(@round(@as(f64, @floatFromInt(k_total)) * 0.3)))), k_total);
    const k_last = @min(@max(@as(usize, 1), @as(usize, @intFromFloat(@round(@as(f64, @floatFromInt(k_total)) * 0.15)))), k_total -| k_first);

    return .{
        .k_total = k_total,
        .k_first = k_first,
        .k_last = k_last,
        .k_importance = k_total -| k_first -| k_last,
    };
}

test "computeOptimalK: empty or small arrays" {
    try std.testing.expectEqual(@as(usize, 0), computeOptimalK(&[_][]const u8{}, 1.0, 0, null));
    try std.testing.expectEqual(@as(usize, 2), computeOptimalK(&[_][]const u8{"a", "bb", "ccc"}, 1.0, 0, null));
}

test "computeOptimalK: respects min_k" {
    const items = &[_][]const u8{ "a" };
    try std.testing.expectEqual(@as(usize, 1), computeOptimalK(items, 1.0, 1, null));
}

test "computeOptimalK: respects max_k" {
    var items = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h", "i", "j" };
    const k = computeOptimalK(&items, 1.0, 1, 3);
    try std.testing.expect(k <= 3);
}

test "computeKSplit: budget divides correctly" {
    var items = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h", "i", "j" };
    const split = computeKSplit(&items, 10, 1.0);
    try std.testing.expect(split.k_total <= 10);
    try std.testing.expect(split.k_first + split.k_last + split.k_importance <= split.k_total);
    try std.testing.expect(split.k_first >= 1);
}