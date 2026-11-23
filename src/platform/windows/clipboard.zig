const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("win32.zig");
const limits = @import("../../core/limits.zig");

const assert = std.debug.assert;

pub const text_bytes_max: u32 = @max(
    limits.TextLimits.ceiling.input.bytes_max,
    limits.TextLimits.ceiling.area.bytes_max,
    limits.TextLimits.ceiling.editor.bytes_max,
);

const copy_unit_count_max: u32 = 2 * text_bytes_max;

const copy_block_bytes_max: u32 = (copy_unit_count_max + 1) * @sizeOf(u16);

const open_attempt_count_max: u32 = 5;
const open_retry_delay_ms: u32 = 5;

const owner_class_name = std.unicode.utf8ToUtf16LeStringLiteral("STATIC");

var owner_hwnd: ?win32.HWND = null;

comptime {
    assert(builtin.cpu.arch.endian() == .little);
    assert(copy_block_bytes_max == 4 * text_bytes_max + 2);
    assert(text_bytes_max == 16 * 1024 * 1024);
}

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

pub fn deinit() void {
    const hwnd = owner_hwnd orelse unreachable;
    if (win32.DestroyWindow(hwnd) == win32.FALSE) {
        std.log.warn("windows: clipboard owner destruction failed (error {d})", .{
            win32.GetLastError(),
        });
    }
    owner_hwnd = null;
    assert(owner_hwnd == null);
}

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
    defer _ = win32.GlobalUnlock(block);

    const unit_capacity = win32.GlobalSize(block) / @sizeOf(u16);
    const scan_count = @min(unit_capacity, 2 * out.len + 1);
    const units_scanned = @as([*]const u16, @ptrCast(@alignCast(pointer)))[0..scan_count];
    const end = std.mem.indexOfScalar(u16, units_scanned, 0) orelse scan_count;
    const written = pasteDecodePrefix(units_scanned[0..end], out);
    assert(written <= out.len);
    return written;
}

pub fn setText(text: []const u8) bool {
    const owner = owner_hwnd orelse unreachable;
    assert(text.len <= text_bytes_max);
    if (!std.unicode.utf8ValidateSlice(text)) {
        std.log.warn("windows: copy of invalid UTF-8 refused", .{});
        return false;
    }

    const block = copyBlockCreate(text) orelse return false;
    if (clipboardPublish(owner, block)) return true;

    globalFree(block);
    return false;
}

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
    assert(units[unit_count] == 0);
    _ = win32.GlobalUnlock(block);
    return block;
}

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
    const owner = owner_hwnd orelse unreachable;
    return clipboardOpenAs(owner);
}

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

fn globalFree(block: win32.HGLOBAL) void {
    if (win32.GlobalFree(block) != null) {
        std.log.warn("windows: clipboard GlobalFree failed (error {d})", .{
            win32.GetLastError(),
        });
    }
}

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

fn pasteDecodePrefix(units: []const u16, target: []u8) u32 {
    var count: u32 = 0;
    var decoder: PasteDecoder = .{ .units = units };
    while (decoder.next()) |code_point| {
        assert(decoder.index <= units.len);
        if (utf8Length(code_point) > target.len - count) break;
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

const testing = std.testing;

fn testCopy(buffer: []u16, text: []const u8) []const u16 {
    const unit_count = copyUnitCount(text);
    const written = copyEncode(text, buffer[0..unit_count]);
    return buffer[0..written];
}

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

    const ill_formed = [_]u16{ 0xDC00, 'x', 0xD800, 'y', 0xD800 };
    try testing.expectEqualStrings(
        "\u{FFFD}x\u{FFFD}y\u{FFFD}",
        testPaste(&buffer, &ill_formed),
    );
    try testing.expectEqual(@as(usize, 0), testPaste(&buffer, &.{}).len);
}

test "a paste into a short buffer keeps whole codepoints and collapses CR LF" {
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

test "system clipboard copies text_bytes_max whole and keeps it on a refused copy" {
    try testOwnerInit();
    defer deinit();

    const text = try testing.allocator.alloc(u8, text_bytes_max);
    defer testing.allocator.free(text);
    @memset(text, '\n');

    try testing.expect(setText(text));
    try testing.expect(!setText("\xFF"));

    const out = try testing.allocator.alloc(u8, text_bytes_max + 1);
    defer testing.allocator.free(out);
    try testing.expectEqual(text_bytes_max, readText(out));
    try testing.expectEqualSlices(u8, text, out[0..text_bytes_max]);
}
