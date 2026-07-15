const std = @import("std");

pub fn mean(values: []const f64) f64 {
    if (values.len == 0) return 0;
    var sum: f64 = 0;
    for (values) |v| sum += v;
    return sum / @as(f64, @floatFromInt(values.len));
}

pub fn median(values: []const f64) f64 {
    if (values.len == 0) return 0;
    var sorted: std.ArrayList(f64) = .empty;
    defer sorted.deinit(std.heap.page_allocator);
    for (values) |v| sorted.append(std.heap.page_allocator, v) catch {};
    std.mem.sort(f64, sorted.items, {}, std.sort.asc(f64));
    const n = sorted.items.len;
    if (n % 2 == 1) return sorted.items[n / 2];
    return (sorted.items[n / 2 - 1] + sorted.items[n / 2]) / 2.0;
}

pub fn sampleVariance(values: []const f64) !f64 {
    if (values.len < 2) return error.InsufficientData;
    const m = mean(values);
    var sum_sq: f64 = 0;
    for (values) |v| {
        const diff = v - m;
        sum_sq += diff * diff;
    }
    return sum_sq / @as(f64, @floatFromInt(values.len - 1));
}

pub fn sampleStdev(values: []const f64) !f64 {
    const v = try sampleVariance(values);
    return @sqrt(v);
}

/// Go-style format_g: no trailing zeros after decimal
pub fn formatG(value: f64, allocator: std.mem.Allocator) ![]const u8 {
    if (value == @trunc(value)) {
        return std.fmt.allocPrint(allocator, "{d:.0}", .{value});
    }
    // Try to find a reasonable precision
    var s = try std.fmt.allocPrint(allocator, "{d}", .{value});
    // Trim trailing zeros
    if (std.mem.indexOf(u8, s, ".")) |dot| {
        var end = s.len;
        while (end > dot + 1 and s[end - 1] == '0') {
            end -= 1;
        }
        if (end == dot + 1) end = dot;
        return allocator.dupe(u8, s[0..end]);
    }
    return s;
}

test "mean of numbers" {
    const values = [_]f64{ 1.0, 2.0, 3.0, 4.0, 5.0 };
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), mean(&values), 0.001);
}

test "median of odd count" {
    const values = [_]f64{ 5.0, 1.0, 3.0 };
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), median(&values), 0.001);
}
test "sampleVariance of known values" {
    const values = [_]f64{ 2.0, 4.0, 4.0, 4.0, 5.0, 5.0, 7.0, 9.0 };
    const v = try sampleVariance(&values);
    try std.testing.expectApproxEqAbs(@as(f64, 4.571), v, 0.01);
}

test "sampleStdev of known values" {
    const values = [_]f64{ 2.0, 4.0, 4.0, 4.0, 5.0, 5.0, 7.0, 9.0 };
    const s = try sampleStdev(&values);
    try std.testing.expectApproxEqAbs(@as(f64, 2.138), s, 0.01);
}

test "formatG removes trailing zeros" {
    const allocator = std.testing.allocator;
    const s = try formatG(42.0, allocator);
    defer allocator.free(s);
    try std.testing.expectEqualStrings("42", s);
}

test "median of even count" {
    const values = [_]f64{ 1.0, 2.0, 3.0, 4.0 };
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), median(&values), 0.001);
}
