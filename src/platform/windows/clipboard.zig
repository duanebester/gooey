//! Windows clipboard: text through `CF_UNICODETEXT`.
//!
//! The API matches `linux/clipboard.zig`, which the text widgets call:
//! `getText(allocator)` returns caller-owned UTF-8 or null, and `setText`
//! returns whether the system clipboard now holds the text.
//!
//! ## Line endings
//!
//! Windows text uses CR LF. Copy expands every LF not already preceded by CR
//! into CR LF, and paste collapses CR LF into LF, so other applications see
//! the line breaks a `TextArea` holds and a paste never inserts CR into a
//! buffer. A lone CR passes through unchanged in both directions.
//!
//! ## Ownership
//!
//! `SetClipboardData` needs an owner window: with a null owner,
//! `EmptyClipboard` leaves the clipboard ownerless and `SetClipboardData`
//! fails. `WindowsPlatform` creates a message-only owner in `init` and destroys
//! it in `deinit`, so copying does not depend on any application window
//! staying open.
//!
//! ## Allocation (CLAUDE.md section 2)
//!
//! The system clipboard takes ownership of a movable global block that the
//! copying process allocates and hands over; Win32 has no way to publish
//! storage reserved at init. Copy therefore makes one `GlobalAlloc` of at most
//! `copy_block_bytes_max` per call, owned by the system once
//! `SetClipboardData` succeeds and freed here on every failure path. Paste
//! allocates its result from the caller's allocator because the shared
//! `getText` contract returns caller-owned text, as on every other backend.
//!
//! ## Bounds
//!
//! - Text: `text_bytes_max` (64 KiB) of UTF-8 in each direction, as on Linux
//!   and fbdev. Longer text is refused with a warning, never truncated.
//! - Copy block: at most `copy_block_bytes_max` (256 KiB + 2 B), reached when
//!   every byte is a lone LF.
//! - Paste scan: at most `paste_unit_count_max + 1` units are examined, so a
//!   huge or unterminated clipboard block costs bounded work.
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

/// Paste turns at most two units into one byte (CR LF into LF), so a string
/// of more units than this decodes to more than `text_bytes_max` bytes.
const paste_unit_count_max: u32 = 2 * text_bytes_max;

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
    assert(paste_unit_count_max < std.math.maxInt(u32) / 4);
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

/// Copy of the clipboard text owned by the caller, or null when the clipboard
/// holds no text, is busy, holds more than `text_bytes_max`, or the copy
/// cannot be allocated.
pub fn getText(allocator: std.mem.Allocator) ?[]const u8 {
    assert(owner_hwnd != null);
    if (!clipboardOpen()) return null;
    defer clipboardClose();

    // No text on the clipboard is the common case, not an error.
    const block = win32.GetClipboardData(win32.CF_UNICODETEXT) orelse return null;
    const pointer = win32.GlobalLock(block) orelse {
        std.log.warn("windows: clipboard GlobalLock failed (error {d})", .{
            win32.GetLastError(),
        });
        return null;
    };
    // `GlobalUnlock` returns FALSE once the lock count reaches zero, which is
    // the expected outcome of a balanced lock, so its result carries nothing.
    defer _ = win32.GlobalUnlock(block);

    const unit_capacity = win32.GlobalSize(block) / @sizeOf(u16);
    const units_available = @as([*]const u16, @ptrCast(@alignCast(pointer)))[0..unit_capacity];
    const units = pasteUnits(units_available) orelse {
        std.log.warn("windows: clipboard text exceeds {d} units; paste refused", .{
            paste_unit_count_max,
        });
        return null;
    };
    return pasteText(allocator, units);
}

/// Replace the clipboard text. Returns false, leaving the clipboard as it
/// was, when the text is longer than `text_bytes_max`, is not UTF-8, or the
/// clipboard is busy.
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
    _ = win32.GlobalUnlock(block); // FALSE is the expected final unlock; see `getText`.
    return block;
}

/// Hand `block` to the system clipboard. On success the system owns it; on
/// failure the caller still does.
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

/// The text in a clipboard block: the units before the first zero. A block
/// without a terminator is taken whole, as other readers do. Returns null when
/// the text has more than `paste_unit_count_max` units, which cannot decode to
/// `text_bytes_max` bytes or fewer.
fn pasteUnits(units_available: []const u16) ?[]const u16 {
    const scan_count: usize = @min(units_available.len, paste_unit_count_max + 1);
    for (units_available[0..scan_count], 0..) |unit, index| {
        if (unit == 0) {
            assert(index <= paste_unit_count_max);
            return units_available[0..index];
        }
    }
    if (units_available.len <= paste_unit_count_max) return units_available;
    return null;
}

/// Decode `units` into a caller-owned UTF-8 copy, or null when it is longer
/// than `text_bytes_max` or cannot be allocated.
fn pasteText(allocator: std.mem.Allocator, units: []const u16) ?[]const u8 {
    assert(units.len <= paste_unit_count_max);
    const byte_count = pasteByteCount(units);
    if (byte_count > text_bytes_max) {
        std.log.warn("windows: paste of {d} bytes exceeds {d}; refused", .{
            byte_count,
            text_bytes_max,
        });
        return null;
    }

    const text = allocator.alloc(u8, byte_count) catch {
        std.log.warn("windows: paste allocation of {d} bytes failed", .{byte_count});
        return null;
    };
    const written = pasteDecode(units, text);
    assert(written == byte_count);
    assert(std.unicode.utf8ValidateSlice(text));
    return text;
}

/// UTF-8 bytes `pasteDecode` writes for `units`.
fn pasteByteCount(units: []const u16) u32 {
    assert(units.len <= paste_unit_count_max);
    var count: u32 = 0;
    var decoder: PasteDecoder = .{ .units = units };
    while (decoder.next()) |code_point| {
        assert(decoder.index <= units.len);
        count += utf8Length(code_point);
    }
    assert(count <= 3 * units.len);
    return count;
}

/// Decode `units` into `target`, which holds exactly `pasteByteCount(units)`
/// bytes. Returns the bytes written.
fn pasteDecode(units: []const u16, target: []u8) u32 {
    assert(units.len <= paste_unit_count_max);
    assert(target.len <= text_bytes_max);
    var count: u32 = 0;
    var decoder: PasteDecoder = .{ .units = units };
    while (decoder.next()) |code_point| {
        assert(decoder.index <= units.len);
        assert(utf8Length(code_point) <= target.len - count);
        // The decoder yields only scalar values: surrogates become U+FFFD.
        const length = std.unicode.utf8Encode(code_point, target[count..]) catch unreachable;
        count += length;
    }
    assert(count == target.len);
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

/// Decode `units` the way `getText` does, into a test-owned buffer.
fn testPaste(buffer: []u8, units: []const u16) []const u8 {
    const byte_count = pasteByteCount(units);
    const written = pasteDecode(units, buffer[0..byte_count]);
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

test "paste units stop at the terminator and refuse text past the bound" {
    const terminated = [_]u16{ 'a', 'b', 0, 'c' };
    try testing.expectEqual(@as(usize, 2), pasteUnits(&terminated).?.len);
    try testing.expectEqual(@as(usize, 0), pasteUnits(&.{0}).?.len);

    // Unterminated blocks: exactly at the bound is taken whole, one past it
    // is refused, and a terminator at the bound still ends the text.
    const units = try testing.allocator.alloc(u16, paste_unit_count_max + 2);
    defer testing.allocator.free(units);
    @memset(units, 'a');
    try testing.expectEqual(
        @as(usize, paste_unit_count_max),
        pasteUnits(units[0..paste_unit_count_max]).?.len,
    );
    try testing.expect(pasteUnits(units[0 .. paste_unit_count_max + 1]) == null);
    units[paste_unit_count_max] = 0;
    try testing.expectEqual(@as(usize, paste_unit_count_max), pasteUnits(units).?.len);
}

test "paste refuses text that decodes past text_bytes_max" {
    // Goal: the byte bound, not the unit bound, decides. One U+00E9 is one
    // unit and two bytes, so half the byte bound fits and one more does not.
    const fits = try testing.allocator.alloc(u16, text_bytes_max / 2 + 1);
    defer testing.allocator.free(fits);
    @memset(fits, 0xE9);

    const text = pasteText(testing.allocator, fits[0 .. text_bytes_max / 2]).?;
    defer testing.allocator.free(text);
    try testing.expectEqual(@as(usize, text_bytes_max), text.len);
    try testing.expect(pasteText(testing.allocator, fits) == null);
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
    try testing.expect(setText(text));
    const pasted = getText(testing.allocator) orelse return error.TestExpectedText;
    defer testing.allocator.free(pasted);
    try testing.expectEqualStrings("Gooey \u{1F389} clipboard\nsecond line\nthird", pasted);

    try testing.expect(setText(""));
    const empty = getText(testing.allocator) orelse return error.TestExpectedText;
    defer testing.allocator.free(empty);
    try testing.expectEqual(@as(usize, 0), empty.len);
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

    const pasted = getText(testing.allocator) orelse return error.TestExpectedText;
    defer testing.allocator.free(pasted);
    try testing.expectEqualSlices(u8, text[0..text_bytes_max], pasted);
}
