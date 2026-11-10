//! Windows clipboard: text through `CF_UNICODETEXT`.
//!
//! The API matches `linux/clipboard.zig`: `readText(out)` decodes into the
//! core text engines' reserved paste buffer, and `setText` returns whether
//! the system clipboard now holds the text.
//!
//! ## Line endings
//!
//! Windows text uses CR LF. Copy expands every LF not already preceded by CR
//! into CR LF, and paste collapses CR LF into LF, so other applications see
//! the line breaks a text area holds and a paste never inserts CR into a
//! buffer. A lone CR passes through unchanged in both directions.
//!
//! ## Ownership
//!
//! `SetClipboardData` needs an owner window: with a null owner,
//! `EmptyClipboard` leaves the clipboard ownerless and `SetClipboardData`
//! fails. `WindowsPlatform.initInPlace` calls `init`, which creates a
//! message-only owner, and `WindowsPlatform.deinit` calls `deinit`, which
//! destroys it, so copying does not depend on any application window staying
//! open.
//!
//! ## Allocation (CLAUDE.md section 2)
//!
//! The system clipboard takes ownership of a movable global block that the
//! copying process allocates and hands over; Win32 has no way to publish
//! storage reserved at init. Copy therefore makes one `GlobalAlloc` of at most
//! `copy_block_bytes_max` per call, owned by the system once
//! `SetClipboardData` succeeds and freed here on every failure path. Paste
//! decodes into the caller's buffer and allocates nothing.
//!
//! ## Bounds
//!
//! - Text: `text_bytes_max` (64 KiB) of UTF-8 copied, as on Linux and fbdev.
//!   A longer copy is refused with a warning, never truncated. A paste is cut
//!   at a codepoint boundary to the caller's buffer.
//! - Copy block: at most `copy_block_bytes_max` (256 KiB + 2 B), reached when
//!   every byte is a lone LF.
//! - Paste scan: at most `2 * out.len + 1` units are examined, so a huge or
//!   unterminated clipboard block costs bounded work.
//! - Contention: another process holding the clipboard makes `OpenClipboard`
//!   fail. At most `open_attempt_count_max` attempts, `open_retry_delay_ms`
//!   apart, so a busy clipboard stalls the UI thread for at most 20 ms.

const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("win32.zig");

const assert = std.debug.assert;

/// Largest text copied or pasted, in UTF-8 bytes.
pub const text_bytes_max: u32 = 64 * 1024;

/// Copy expands a lone LF to two units; every other UTF-8 sequence becomes no
/// more UTF-16 units than it has bytes (1→1, 2→1, 3→1, 4→2).
const copy_unit_count_max: u32 = 2 * text_bytes_max;

/// Copy block size: the units plus the terminating zero.
const copy_block_bytes_max: u32 = (copy_unit_count_max + 1) * @sizeOf(u16);

const open_attempt_count_max: u32 = 5;
const open_retry_delay_ms: u32 = 5;

/// UTF-16 name of the system class used for the owner window. Its window
/// procedure ignores clipboard messages, which is all an owner of immediately
/// rendered data receives.
const owner_class_name = std.unicode.utf8ToUtf16LeStringLiteral("STATIC");

/// The message-only window that owns what Gooey copies, or null outside
/// `init`..`deinit`.
var owner_hwnd: ?win32.HWND = null;

comptime {
    // `CF_UNICODETEXT` is UTF-16LE, read and written here as native `u16`.
    assert(builtin.cpu.arch.endian() == .little);
    assert(copy_block_bytes_max == 4 * text_bytes_max + 2);
}

/// Create the owner window. Part of `WindowsPlatform` initialization.
pub fn init(hinstance: win32.HINSTANCE) !void {
    assert(owner_hwnd == null);

    const hwnd = win32.CreateWindowExW(
        0,
        owner_class_name,
        owner_class_name,
        0,
        0,
        0,
        0,
        0,
        win32.HWND_MESSAGE,
        null,
        hinstance,
        null,
    ) orelse {
        std.log.err("windows: clipboard owner creation failed (error {d})", .{
            win32.GetLastError(),
        });
        return error.ClipboardOwnerCreationFailed;
    };
    owner_hwnd = hwnd;
    assert(owner_hwnd != null);
}

/// Destroy the owner window. Text already copied stays on the clipboard: the
/// system owns the data block, and only the owner becomes null.
pub fn deinit() void {
    const hwnd = owner_hwnd orelse unreachable; // `deinit` without `init`.
    if (win32.DestroyWindow(hwnd) == win32.FALSE) {
        std.log.warn("windows: clipboard owner destruction failed (error {d})", .{
            win32.GetLastError(),
        });
    }
    owner_hwnd = null;
    assert(owner_hwnd == null);
}

/// Read the clipboard text into `out`, cut at a codepoint boundary, and
/// return its length (0 for none or a busy clipboard). Claims no storage
/// (core hosts). Every output byte consumes at most two units, so at most
/// `2 * out.len + 1` units are scanned, the extra one completing a CR LF.
pub fn readText(out: []u8) u32 {
    assert(out.len > 0);
    assert(owner_hwnd != null);
    if (!clipboardOpen()) return 0;
    defer clipboardClose();

    const block = win32.GetClipboardData(win32.CF_UNICODETEXT) orelse return 0;
    const pointer = win32.GlobalLock(block) orelse {
        std.log.warn("windows: clipboard GlobalLock failed (error {d})", .{
            win32.GetLastError(),
        });
        return 0;
    };
    defer _ = win32.GlobalUnlock(block); // FALSE is the expected final unlock.

    const unit_capacity = win32.GlobalSize(block) / @sizeOf(u16);
    const scan_count = @min(unit_capacity, 2 * out.len + 1);
    const units_scanned = @as([*]const u16, @ptrCast(@alignCast(pointer)))[0..scan_count];
    const end = std.mem.indexOfScalar(u16, units_scanned, 0) orelse scan_count;
    const written = pasteDecodePrefix(units_scanned[0..end], out);
    assert(written <= out.len);
    return written;
}

/// Replace the clipboard text. Returns false, leaving the clipboard as it
/// was, when the text is longer than `text_bytes_max`, is not UTF-8, the copy
/// block cannot be allocated, or the clipboard is busy. Returns false with the
/// clipboard left empty when `SetClipboardData` fails after `EmptyClipboard`;
/// see `clipboardPublish`.
pub fn setText(text: []const u8) bool {
    const owner = owner_hwnd orelse unreachable; // Copy before `init`.
    if (text.len > text_bytes_max) {
        std.log.warn("windows: copy of {d} bytes exceeds {d}; refused", .{
            text.len,
            text_bytes_max,
        });
        return false;
    }
    if (!std.unicode.utf8ValidateSlice(text)) {
        std.log.warn("windows: copy of invalid UTF-8 refused", .{});
        return false;
    }

    // Fill the block before opening the clipboard, so other processes are
    // locked out only for the hand-over.
    const block = copyBlockCreate(text) orelse return false;
    if (clipboardPublish(owner, block)) return true;

    globalFree(block);
    return false;
}

/// Allocate a movable block and encode `text` into it as terminated UTF-16.
/// The block is zero-initialized because `GlobalSize` may round it up and
/// readers may scan to its end (CLAUDE.md section 21).
fn copyBlockCreate(text: []const u8) ?win32.HGLOBAL {
    assert(text.len <= text_bytes_max);
    const unit_count = copyUnitCount(text);
    assert(unit_count <= copy_unit_count_max);
    const block_bytes = (unit_count + 1) * @sizeOf(u16);
    assert(block_bytes <= copy_block_bytes_max);

    const block = win32.GlobalAlloc(win32.GMEM_MOVEABLE | win32.GMEM_ZEROINIT, block_bytes) orelse {
        std.log.warn("windows: clipboard GlobalAlloc of {d} bytes failed (error {d})", .{
            block_bytes,
            win32.GetLastError(),
        });
        return null;
    };
    const pointer = win32.GlobalLock(block) orelse {
        std.log.warn("windows: clipboard GlobalLock failed (error {d})", .{
            win32.GetLastError(),
        });
        globalFree(block);
        return null;
    };
    assert(win32.GlobalSize(block) >= block_bytes);

    const units: [*]u16 = @ptrCast(@alignCast(pointer));
    const written = copyEncode(text, units[0..unit_count]);
    assert(written == unit_count);
    assert(units[unit_count] == 0); // Zero-initialized terminator.
    _ = win32.GlobalUnlock(block); // FALSE is the expected final unlock; see `readText`.
    return block;
}

/// Hand `block` to the system clipboard. On success the system owns it; on
/// failure the caller still does. A failure after `EmptyClipboard` leaves the
/// clipboard empty: the previous contents are gone and cannot be restored.
fn clipboardPublish(owner: win32.HWND, block: win32.HGLOBAL) bool {
    if (!clipboardOpenAs(owner)) return false;
    defer clipboardClose();

    if (win32.EmptyClipboard() == win32.FALSE) {
        std.log.warn("windows: EmptyClipboard failed (error {d})", .{win32.GetLastError()});
        return false;
    }
    if (win32.SetClipboardData(win32.CF_UNICODETEXT, block) == null) {
        std.log.warn("windows: SetClipboardData failed (error {d})", .{win32.GetLastError()});
        return false;
    }
    return true;
}

fn clipboardOpen() bool {
    const owner = owner_hwnd orelse unreachable; // Checked by both entry points.
    return clipboardOpenAs(owner);
}

/// Open the clipboard, retrying a bounded number of times while another
/// process holds it.
fn clipboardOpenAs(owner: win32.HWND) bool {
    var attempt: u32 = 0;
    while (attempt < open_attempt_count_max) : (attempt += 1) {
        if (win32.OpenClipboard(owner) != win32.FALSE) return true;
        if (attempt + 1 < open_attempt_count_max) win32.Sleep(open_retry_delay_ms);
    }
    assert(attempt == open_attempt_count_max);
    std.log.warn("windows: clipboard busy after {d} attempts (error {d})", .{
        open_attempt_count_max,
        win32.GetLastError(),
    });
    return false;
}

fn clipboardClose() void {
    if (win32.CloseClipboard() == win32.FALSE) {
        std.log.warn("windows: CloseClipboard failed (error {d})", .{win32.GetLastError()});
    }
}

/// `GlobalFree` returns null on success and the handle on failure.
fn globalFree(block: win32.HGLOBAL) void {
    if (win32.GlobalFree(block) != null) {
        std.log.warn("windows: clipboard GlobalFree failed (error {d})", .{
            win32.GetLastError(),
        });
    }
}

// =============================================================================
// Copy: UTF-8 with LF into UTF-16 with CR LF
// =============================================================================

/// UTF-16 units `copyEncode` writes for `text`, excluding the terminator.
fn copyUnitCount(text: []const u8) u32 {
    assert(text.len <= text_bytes_max);
    assert(std.unicode.utf8ValidateSlice(text));

    var count: u32 = 0;
    var previous: u21 = 0;
    var iterator = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (iterator.nextCodepoint()) |code_point| {
        assert(iterator.i <= text.len);
        if (code_point == '\n') {
            if (previous != '\r') count += 1;
        }
        count += utf16Length(code_point);
        previous = code_point;
    }
    assert(count <= 2 * text.len);
    return count;
}

/// Encode `text` into `target`, which holds exactly `copyUnitCount(text)`
/// units. Returns the units written.
fn copyEncode(text: []const u8, target: []u16) u32 {
    assert(text.len <= text_bytes_max);
    assert(target.len <= copy_unit_count_max);

    var count: u32 = 0;
    var previous: u21 = 0;
    var iterator = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (iterator.nextCodepoint()) |code_point| {
        assert(iterator.i <= text.len);
        if (code_point == '\n') {
            if (previous != '\r') {
                assert(count < target.len);
                target[count] = '\r';
                count += 1;
            }
        }
        assert(utf16Length(code_point) <= target.len - count);
        if (code_point < 0x1_0000) {
            target[count] = @intCast(code_point);
            count += 1;
        } else {
            const offset = code_point - 0x1_0000;
            target[count] = @intCast(0xD800 + (offset >> 10));
            target[count + 1] = @intCast(0xDC00 + (offset & 0x3FF));
            count += 2;
        }
        previous = code_point;
    }
    assert(count == target.len);
    return count;
}

fn utf16Length(code_point: u21) u32 {
    assert(code_point <= 0x10_FFFF);
    return if (code_point < 0x1_0000) 1 else 2;
}

// =============================================================================
// Paste: UTF-16 with CR LF into UTF-8 with LF
// =============================================================================

/// Decode the longest prefix of `units` whose UTF-8 fits in `target`, so a
/// cut never splits a codepoint. Returns the bytes written.
fn pasteDecodePrefix(units: []const u16, target: []u8) u32 {
    var count: u32 = 0;
    var decoder: PasteDecoder = .{ .units = units };
    while (decoder.next()) |code_point| {
        assert(decoder.index <= units.len);
        if (utf8Length(code_point) > target.len - count) break;
        // The decoder yields only scalar values: surrogates become U+FFFD.
        const length = std.unicode.utf8Encode(code_point, target[count..]) catch unreachable;
        count += length;
    }
    assert(count <= target.len);
    return count;
}

fn utf8Length(code_point: u21) u32 {
    assert(code_point <= 0x10_FFFF);
    if (code_point < 0x80) return 1;
    if (code_point < 0x800) return 2;
    if (code_point < 0x1_0000) return 3;
    return 4;
}

/// Walks clipboard UTF-16 as Unicode scalar values. CR LF becomes LF and an
/// unpaired surrogate becomes U+FFFD, because other applications may place
/// ill-formed UTF-16 on the clipboard and a paste must still yield UTF-8.
const PasteDecoder = struct {
    units: []const u16,
    index: usize = 0,

    fn next(self: *PasteDecoder) ?u21 {
        assert(self.index <= self.units.len);
        if (self.index == self.units.len) return null;

        const unit = self.units[self.index];
        const has_next = self.index + 1 < self.units.len;
        if (has_next) {
            const following = self.units[self.index + 1];
            if (unit == '\r' and following == '\n') {
                self.index += 2;
                return '\n';
            }
            if (isHighSurrogate(unit) and isLowSurrogate(following)) {
                self.index += 2;
                const high: u21 = unit - 0xD800;
                const low: u21 = following - 0xDC00;
                return 0x1_0000 + (high << 10) + low;
            }
        }
        self.index += 1;
        if (isHighSurrogate(unit) or isLowSurrogate(unit)) return std.unicode.replacement_character;
        return unit;
    }
};

fn isHighSurrogate(unit: u16) bool {
    return unit >= 0xD800 and unit <= 0xDBFF;
}

fn isLowSurrogate(unit: u16) bool {
    return unit >= 0xDC00 and unit <= 0xDFFF;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

/// Encode `text` the way `setText` does, into a test-owned buffer.
fn testCopy(buffer: []u16, text: []const u8) []const u16 {
    const unit_count = copyUnitCount(text);
    const written = copyEncode(text, buffer[0..unit_count]);
    return buffer[0..written];
}

/// Decode `units` the way `readText` does, into a test-owned buffer large
/// enough for all of them.
fn testPaste(buffer: []u8, units: []const u16) []const u8 {
    assert(buffer.len >= 3 * units.len);
    const written = pasteDecodePrefix(units, buffer);
    return buffer[0..written];
}

test "copy expands lone LF to CR LF and keeps existing CR LF and lone CR" {
    var buffer: [16]u16 = undefined;
    const expected = std.unicode.utf8ToUtf16LeStringLiteral("a\r\nb\r\nc\rd");
    try testing.expectEqualSlices(u16, expected, testCopy(&buffer, "a\nb\r\nc\rd"));
    try testing.expectEqual(@as(usize, 0), testCopy(&buffer, "").len);

    const breaks = std.unicode.utf8ToUtf16LeStringLiteral("\r\n\r\n");
    try testing.expectEqualSlices(u16, breaks, testCopy(&buffer, "\n\n"));
}

test "copy encodes every UTF-8 sequence length" {
    // Methodology: one scalar of each UTF-8 length, the last outside the
    // BMP, checked against the standard library's UTF-16 conversion.
    var buffer: [16]u16 = undefined;
    const text = "a\u{E9}\u{65E5}\u{1F389}";
    const expected = std.unicode.utf8ToUtf16LeStringLiteral(text);
    try testing.expectEqualSlices(u16, expected, testCopy(&buffer, text));
    try testing.expectEqual(@as(u32, 5), copyUnitCount(text));
}

test "paste collapses CR LF, keeps lone CR, and replaces unpaired surrogates" {
    var buffer: [32]u8 = undefined;
    const crlf = std.unicode.utf8ToUtf16LeStringLiteral("a\r\nb\rc\r");
    try testing.expectEqualStrings("a\nb\rc\r", testPaste(&buffer, crlf));

    const pair = std.unicode.utf8ToUtf16LeStringLiteral("\u{1F389}");
    try testing.expectEqualStrings("\u{1F389}", testPaste(&buffer, pair));

    // A lone high surrogate at the end, a lone low surrogate, and a high
    // surrogate followed by a non-surrogate each become one U+FFFD.
    const ill_formed = [_]u16{ 0xDC00, 'x', 0xD800, 'y', 0xD800 };
    try testing.expectEqualStrings(
        "\u{FFFD}x\u{FFFD}y\u{FFFD}",
        testPaste(&buffer, &ill_formed),
    );
    try testing.expectEqual(@as(usize, 0), testPaste(&buffer, &.{}).len);
}

test "a paste into a short buffer keeps whole codepoints and collapses CR LF" {
    // Goal: `readText` fills the core's paste buffer with a prefix that never
    // ends inside a codepoint. Methodology: buffers one byte short of each
    // multi-byte sequence, an exact fit, and a CR LF that costs one byte.
    var buffer: [8]u8 = undefined;
    const accented = std.unicode.utf8ToUtf16LeStringLiteral("a\u{E9}\u{E9}");
    try testing.expectEqual(@as(u32, 3), pasteDecodePrefix(accented, buffer[0..4]));
    try testing.expectEqualStrings("a\u{E9}", buffer[0..3]);
    try testing.expectEqual(@as(u32, 5), pasteDecodePrefix(accented, buffer[0..5]));

    const emoji = std.unicode.utf8ToUtf16LeStringLiteral("\u{1F389}");
    try testing.expectEqual(@as(u32, 0), pasteDecodePrefix(emoji, buffer[0..3]));
    try testing.expectEqual(@as(u32, 4), pasteDecodePrefix(emoji, buffer[0..4]));

    const lines = std.unicode.utf8ToUtf16LeStringLiteral("a\r\nb");
    try testing.expectEqual(@as(u32, 3), pasteDecodePrefix(lines, buffer[0..3]));
    try testing.expectEqualStrings("a\nb", buffer[0..3]);
}

/// Owner window for the system clipboard tests. These tests replace the
/// developer's clipboard contents, as the macOS clipboard test does.
fn testOwnerInit() !void {
    const hinstance = win32.GetModuleHandleW(null) orelse return error.NoModuleHandle;
    try init(hinstance);
}

test "system clipboard round-trips text and line endings" {
    try testOwnerInit();
    defer deinit();

    const text = "Gooey \u{1F389} clipboard\nsecond line\r\nthird";
    var out: [64]u8 = undefined;
    try testing.expect(setText(text));
    const pasted = out[0..readText(&out)];
    try testing.expectEqualStrings("Gooey \u{1F389} clipboard\nsecond line\nthird", pasted);

    try testing.expect(setText(""));
    try testing.expectEqual(@as(u32, 0), readText(&out));
}

test "system clipboard fills to text_bytes_max and refuses one byte more intact" {
    // Capacity test: the largest copy, in the worst case for block size
    // (every byte a lone LF), succeeds and round-trips; one byte more is
    // refused and leaves the previous text in place.
    try testOwnerInit();
    defer deinit();

    const text = try testing.allocator.alloc(u8, text_bytes_max + 1);
    defer testing.allocator.free(text);
    @memset(text, '\n');

    try testing.expect(setText(text[0..text_bytes_max]));
    try testing.expect(!setText(text));
    try testing.expect(!setText("\xFF")); // Invalid UTF-8.

    const out = try testing.allocator.alloc(u8, text_bytes_max);
    defer testing.allocator.free(out);
    try testing.expectEqual(text_bytes_max, readText(out));
    try testing.expectEqualSlices(u8, text[0..text_bytes_max], out);
}
