//! In-process clipboard for the fbdev backend.
//!
//! Without a display server there is no system clipboard to share with other
//! processes, so copy and paste work within the application only. The text
//! lives in static storage of `text_bytes_max` bytes; longer copies are
//! refused rather than truncated, so a paste never yields a silently cut
//! string. The API matches `linux/clipboard.zig`, which the text widgets call.

const std = @import("std");

const assert = std.debug.assert;

pub const text_bytes_max: usize = 64 * 1024;

var storage: [text_bytes_max]u8 = undefined;
var stored_len: usize = 0;

/// Copy of the clipboard text owned by the caller, or null when empty or the
/// copy cannot be allocated.
pub fn getText(allocator: std.mem.Allocator) ?[]const u8 {
    assert(stored_len <= text_bytes_max);
    if (stored_len == 0) return null;
    const copy = allocator.dupe(u8, storage[0..stored_len]) catch return null;
    assert(copy.len == stored_len);
    return copy;
}

/// Replace the clipboard text. Returns false when it does not fit.
pub fn setText(text: []const u8) bool {
    assert(stored_len <= text_bytes_max);
    if (text.len > text_bytes_max) return false;
    @memcpy(storage[0..text.len], text);
    stored_len = text.len;
    return true;
}

test "clipboard round-trips text and refuses oversized copies intact" {
    // Goal: a copy that does not fit must leave the previous text in place
    // instead of truncating it or clearing the clipboard.
    try std.testing.expect(setText("hello"));
    const oversized: [text_bytes_max + 1]u8 = @splat('x');
    try std.testing.expect(!setText(&oversized));
    const text = getText(std.testing.allocator) orelse return error.TestExpectedText;
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("hello", text);
}
