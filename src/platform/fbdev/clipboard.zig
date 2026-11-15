//! In-process clipboard for the fbdev backend.
//!
//! Without a display server there is no system clipboard to share with other
//! processes, so copy and paste work within the application only. The text
//! lives in storage the core host reserves at init (`reserve`), sized to the
//! core clipboard (the largest `bytes_max` of a text kind with engines), so
//! every copy the core makes fits whole and a paste never yields a silently
//! cut string. The API matches `linux/clipboard.zig`'s `readText` and
//! `setText`.

const std = @import("std");
const core_clipboard = @import("../../core/clipboard.zig");

const assert = std.debug.assert;

var storage: []u8 = &.{};
var stored_len: usize = 0;

/// Reserve `bytes` of clipboard storage, during initialization only.
pub fn reserve(gpa: std.mem.Allocator, bytes: u32) !void {
    assert(storage.len == 0);
    assert(bytes > 0);
    storage = try gpa.alloc(u8, bytes);
    stored_len = 0;
    assert(storage.len == bytes);
}

/// Free the storage once the core host has stopped.
pub fn release(gpa: std.mem.Allocator) void {
    assert(storage.len > 0);
    gpa.free(storage);
    storage = &.{};
    stored_len = 0;
}

/// Copy the clipboard text into `out`, cut at a codepoint boundary, and
/// return its length (0 for none): the core host's read, which claims no
/// storage.
pub fn readText(out: []u8) u32 {
    assert(out.len > 0);
    assert(stored_len <= storage.len);
    const kept = core_clipboard.prefixFitting(storage[0..stored_len], out.len);
    @memcpy(out[0..kept], storage[0..kept]);
    return @intCast(kept);
}

/// Replace the clipboard text. The core copies at most its clipboard, the
/// size reserved, so the text always fits.
pub fn setText(text: []const u8) bool {
    assert(storage.len > 0);
    assert(text.len <= storage.len);
    @memcpy(storage[0..text.len], text);
    stored_len = text.len;
    return true;
}

test "clipboard holds a copy of exactly its reserved size and pastes it whole" {
    // Goal: a copy filling the reservation exactly survives intact, a later
    // copy replaces it, and a paste into a smaller buffer is cut on a
    // codepoint boundary. Method: reserve 8 bytes and copy 8, then 2.
    try reserve(std.testing.allocator, 8);
    defer release(std.testing.allocator);
    try std.testing.expect(setText("abcdef\u{e9}"));
    var out: [8]u8 = undefined;
    try std.testing.expectEqualStrings("abcdef\u{e9}", out[0..readText(&out)]);
    var short: [7]u8 = undefined;
    try std.testing.expectEqualStrings("abcdef", short[0..readText(&short)]);
    try std.testing.expect(setText("hi"));
    try std.testing.expectEqualStrings("hi", out[0..readText(&out)]);
}
