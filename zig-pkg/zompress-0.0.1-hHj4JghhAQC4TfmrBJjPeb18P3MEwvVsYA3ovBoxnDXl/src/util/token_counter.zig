const std = @import("std");

/// Estimate the number of tokens in a text (rough approximation: 4 chars per token).
pub fn estimateTokens(text: []const u8) usize {
    // Simple rule-of-thumb: ~4 characters per token for most text
    // This is intentionally rough — for production, use a proper tokenizer
    if (text.len == 0) return 0;
    const est = text.len / 4;
    return if (est < 1) 1 else est;
}

test "estimate empty text" {
    try std.testing.expectEqual(@as(usize, 0), estimateTokens(""));
}

test "estimate short text" {
    try std.testing.expect(estimateTokens("hello world") >= 1);
}
test "estimateTokens longer text" {
    const text = "hello world this is a longer piece of text for testing purposes";
    try std.testing.expect(estimateTokens(text) >= 5);
}
