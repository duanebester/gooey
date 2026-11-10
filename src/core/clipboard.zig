//! The text engines' clipboard (contract decision 10): copy, cut, and paste
//! with no public API, as in 0.3.1.
//!
//! One buffer, reserved at init and sized to the largest text engine kind's
//! `bytes_max`, serves both directions. A copy or cut stores the text and
//! marks it pending; the tick hands it to the platform after the drain, on
//! the main thread. A paste reads the platform clipboard into the same
//! buffer, unless a write is still pending, in which case it returns that
//! text: copy then paste in one drain pastes what was copied. Text longer
//! than the buffer is cut at a codepoint boundary, an operating limit the
//! app declared through `limits.text`.

const std = @import("std");

const assert = std.debug.assert;

/// The platform side, bound by the host. `read` copies the clipboard text
/// into `out`, cut at a codepoint boundary, and returns the byte count (0 for
/// no text). `write` replaces the clipboard text. Both run on the main thread.
pub const Service = struct {
    context: *anyopaque,
    read: *const fn (context: *anyopaque, out: []u8) u32,
    write: *const fn (context: *anyopaque, text: []const u8) void,
};

pub const Clipboard = struct {
    service: ?Service,
    buffer: []u8,
    /// Bytes of `buffer` waiting for `flush`, or null when nothing is.
    pending_len: ?u32,

    pub fn init(buffer: []u8) Clipboard {
        assert(buffer.len > 0);
        assert(buffer.len <= std.math.maxInt(u32));
        return .{ .service = null, .buffer = buffer, .pending_len = null };
    }

    /// Store `text` for the platform. Called from a text engine's handler.
    pub fn write(self: *Clipboard, text: []const u8) void {
        assert(text.len > 0);
        assert(@intFromPtr(text.ptr) != @intFromPtr(self.buffer.ptr));
        const kept = prefixFitting(text, self.buffer.len);
        @memcpy(self.buffer[0..kept], text[0..kept]);
        self.pending_len = @intCast(kept);
    }

    /// The clipboard text, valid until the next `read`, `write`, or `flush`.
    pub fn read(self: *Clipboard) []const u8 {
        if (self.pending_len) |len| return self.buffer[0..len];
        const service = self.service orelse return "";
        const len = service.read(service.context, self.buffer);
        assert(len <= self.buffer.len);
        return self.buffer[0..len];
    }

    /// Hand a pending write to the platform. The tick calls it after the
    /// drain, outside any handler.
    pub fn flush(self: *Clipboard) void {
        const len = self.pending_len orelse return;
        self.pending_len = null;
        assert(len <= self.buffer.len);
        const service = self.service orelse return;
        service.write(service.context, self.buffer[0..len]);
    }
};

/// The longest prefix of `value` that fits `room` bytes without splitting a
/// UTF-8 sequence. Platforms use it to cut what they read.
pub fn prefixFitting(value: []const u8, room: usize) usize {
    if (value.len <= room) return value.len;
    var end = room;
    while (end > 0 and value[end] & 0xC0 == 0x80) end -= 1;
    assert(end <= room);
    return end;
}

/// The length of `bytes` without a trailing partial UTF-8 sequence, for a
/// read that filled its buffer and may have stopped inside a codepoint.
pub fn wholeCodepoints(bytes: []const u8) usize {
    var start = bytes.len;
    var steps: u32 = 0;
    while (start > 0 and steps < 4) : (steps += 1) {
        start -= 1;
        const byte = bytes[start];
        if (byte & 0xC0 == 0x80) continue;
        const needed: usize = std.unicode.utf8ByteSequenceLength(byte) catch return start;
        return if (bytes.len - start >= needed) bytes.len else start;
    }
    return bytes.len;
}

test "wholeCodepoints drops only a cut final sequence" {
    try std.testing.expectEqual(@as(usize, 3), wholeCodepoints("abc"));
    try std.testing.expectEqual(@as(usize, 2), wholeCodepoints("ab\u{e9}"[0..3]));
    try std.testing.expectEqual(@as(usize, 4), wholeCodepoints("ab\u{e9}"));
    try std.testing.expectEqual(@as(usize, 1), wholeCodepoints("a\u{65e5}"[0..3]));
    try std.testing.expectEqual(@as(usize, 0), wholeCodepoints(""));
}

const TestPlatform = struct {
    text: []const u8,
    written: [16]u8 = undefined,
    written_len: usize = 0,

    fn service(self: *TestPlatform) Service {
        return .{ .context = self, .read = read, .write = write };
    }

    fn read(context: *anyopaque, out: []u8) u32 {
        const self: *TestPlatform = @ptrCast(@alignCast(context));
        const kept = prefixFitting(self.text, out.len);
        @memcpy(out[0..kept], self.text[0..kept]);
        return @intCast(kept);
    }

    fn write(context: *anyopaque, text: []const u8) void {
        const self: *TestPlatform = @ptrCast(@alignCast(context));
        @memcpy(self.written[0..text.len], text);
        self.written_len = text.len;
    }
};

test "a pending copy is what a paste in the same drain reads" {
    // Goal: copy then paste before the flush pastes the copy, and the flush
    // reaches the platform once. Methodology: a fake platform records writes.
    var platform = TestPlatform{ .text = "old" };
    var buffer: [8]u8 = undefined;
    var clipboard = Clipboard.init(&buffer);
    clipboard.service = platform.service();
    try std.testing.expectEqualStrings("old", clipboard.read());
    clipboard.write("new");
    try std.testing.expectEqualStrings("new", clipboard.read());
    try std.testing.expectEqual(@as(usize, 0), platform.written_len);
    clipboard.flush();
    try std.testing.expectEqualStrings("new", platform.written[0..platform.written_len]);
    clipboard.flush(); // Nothing pending: no second write.
    try std.testing.expectEqual(@as(usize, 3), platform.written_len);
}

test "text past the buffer is cut at a codepoint boundary" {
    // Goal: an 8-byte buffer drops an "é" (2 bytes) that would end at byte
    // 9 rather than keep half of it, for both a long paste and a long copy.
    var platform = TestPlatform{ .text = "abcdefg\u{e9}" };
    var buffer: [8]u8 = undefined;
    var clipboard = Clipboard.init(&buffer);
    clipboard.service = platform.service();
    try std.testing.expectEqualStrings("abcdefg", clipboard.read());
    clipboard.write("xyzxyzx\u{e9}");
    try std.testing.expectEqualStrings("xyzxyzx", clipboard.read());
    // An "é" that ends exactly at byte 8 is kept.
    clipboard.write("xyzxyz\u{e9}");
    try std.testing.expectEqualStrings("xyzxyz\u{e9}", clipboard.read());
}
