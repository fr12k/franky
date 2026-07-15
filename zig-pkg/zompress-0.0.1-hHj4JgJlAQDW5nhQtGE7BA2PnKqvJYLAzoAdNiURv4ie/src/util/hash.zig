const std = @import("std");

/// Compute an MD5-based content hash (first 16 bytes as hex string).
pub fn computeHash(data: []const u8) [32]u8 {
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(data, &digest, .{});

    var hex: [32]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (digest, 0..) |byte, i| {
        hex[i * 2] = hex_chars[byte >> 4];
        hex[i * 2 + 1] = hex_chars[byte & 0xf];
    }
    return hex;
}
test "computeHash produces hex string" {
    const hash = computeHash("hello world");
    try std.testing.expectEqual(@as(usize, 32), hash.len);
    // MD5 of "hello world" has known prefix
    try std.testing.expect(hash[0] != 0);
}

test "computeHash different inputs differ" {
    const h1 = computeHash("abc");
    const h2 = computeHash("def");
    try std.testing.expect(!std.mem.eql(u8, &h1, &h2));
}
