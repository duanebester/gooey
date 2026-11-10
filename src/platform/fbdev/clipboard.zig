//! In-process clipboard for the fbdev backend.
//!
//! Without a display server there is no system clipboard to share with other
//! processes, so copy and paste work within the application only. The text
//! lives in static storage of `text_bytes_max` bytes; longer copies are
//! refused rather than truncated, so a paste never yields a silently cut
//! string. The API matches `linux/clipboard.zig`'s `readText` and `setText`.

const std = @import("std");
const core_clipboard = @import("../../core/clipboard.zig");

const assert = std.debug.assert;

pub const text_bytes_max: usize = 64 * 1024;

var storage: [text_bytes_max]u8 = undefined;
var stored_len: usize = 0;

/// Copy the clipboard text into `out`, cut at a codepoint boundary, and
/// return its length (0 for none): the core host's read, which claims no
/// storage.
pub fn readText(out: []u8) u32 {
    assert(out.len > 0);
    assert(stored_len <= text_bytes_max);
    const kept = core_clipboard.prefixFitting(storage[0..stored_len], out.len);
    @memcpy(out[0..kept], storage[0..kept]);
    return @intCast(kept);
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
    var out: [16]u8 = undefined;
    const len = readText(&out);
    try std.testing.expectEqualStrings("hello", out[0..len]);
}
