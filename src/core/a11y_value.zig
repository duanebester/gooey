//! Long values are cut to whole lines around their selection, stable while the caret moves.

const std = @import("std");
const TextSelection = @import("../accessibility/element.zig").TextSelection;

const assert = std.debug.assert;

/// A byte range of a value, `start <= end`.
pub const Window = struct {
    start: u32,
    end: u32,
};

/// The bytes of `value` a frame keeps: all of it within `bytes_max`, else at
/// most `bytes_max` bytes of whole lines around `selection`, cut at code
/// point boundaries where a line is longer. A selection longer than the
/// budget keeps its start. `selection` ends must be code point boundaries.
pub fn window(value: []const u8, selection: ?TextSelection, bytes_max: u32) Window {
    assert(bytes_max > 0);
    assert(value.len <= std.math.maxInt(u32));
    const len: u32 = @intCast(value.len);
    if (selection) |focus| {
        assert(focus.start <= focus.end);
        assert(focus.end <= len);
        assert(isBoundary(value, focus.start));
        assert(isBoundary(value, focus.end));
    }
    if (len <= bytes_max) return .{ .start = 0, .end = len };
    const focus = selection orelse TextSelection{ .start = 0, .end = 0 };
    const raw_start = rawStart(len, focus, bytes_max);
    const raw_end = raw_start + bytes_max;
    assert(raw_start <= focus.start);
    assert(raw_end <= len);
    // A selection past the budget keeps the bytes from its start.
    const focus_end = if (focus.end <= raw_end)
        focus.end
    else
        boundaryAtOrBefore(value, raw_end, focus.start);
    const start = lineStartFrom(value, raw_start, focus.start);
    const end = lineEndBefore(value, focus_end, raw_end);
    assert(start <= focus.start);
    assert(focus_end <= end);
    assert(end - start <= bytes_max);
    return .{ .start = start, .end = end };
}

pub fn relative(selection: TextSelection, kept: Window) TextSelection {
    assert(kept.start <= kept.end);
    assert(selection.start <= selection.end);
    assert(kept.start <= selection.start);
    const start = @min(selection.start, kept.end) - kept.start;
    const end = @min(selection.end, kept.end) - kept.start;
    assert(start <= end);
    return .{ .start = start, .end = end };
}

/// The window's start before snapping to a line: stable while the caret
/// moves within half the budget, or centred on a selection longer than a
/// quarter of the budget. Never past `len - bytes_max`, so the window ends
/// inside the value.
fn rawStart(len: u32, focus: TextSelection, bytes_max: u32) u32 {
    assert(len > bytes_max);
    assert(focus.end <= len);
    const half = @max(1, bytes_max / 2);
    const span = focus.end - focus.start;
    const start = if (span > bytes_max / 4)
        focus.start - @min(focus.start, (bytes_max -| span) / 2)
    else
        (focus.start / half) * half -| half / 2;
    const result = @min(start, len - bytes_max);
    assert(result <= focus.start);
    return result;
}

/// The start of the first whole line in `[start, limit]`, or the first code
/// point boundary at or after `start` when no line begins there. A window
/// that starts the value keeps its start.
fn lineStartFrom(value: []const u8, start: u32, limit: u32) u32 {
    assert(start <= limit);
    assert(limit <= value.len);
    if (start == 0) return 0;
    if (std.mem.indexOfScalar(u8, value[start..limit], '\n')) |offset| {
        return start + @as(u32, @intCast(offset)) + 1;
    }
    var result = start;
    // A UTF-8 code point has at most three continuation bytes.
    while (result < limit and !isBoundary(value, result)) : (result += 1) {
        assert(result - start < 3);
    }
    assert(result <= limit);
    return result;
}

/// The last code point boundary in `[floor, index]`; `floor` is one.
fn boundaryAtOrBefore(value: []const u8, index: u32, floor: u32) u32 {
    assert(floor <= index);
    assert(isBoundary(value, floor));
    var result = index;
    while (!isBoundary(value, result)) : (result -= 1) {
        assert(index - result < 3);
    }
    assert(result >= floor);
    return result;
}

/// The end of the last whole line in `[limit, end]`, or the last code point
/// boundary at or before `end` when no line ends there. A window that ends
/// the value keeps its end.
fn lineEndBefore(value: []const u8, limit: u32, end: u32) u32 {
    assert(limit <= end);
    assert(end <= value.len);
    if (end == value.len) return end;
    if (std.mem.lastIndexOfScalar(u8, value[limit..end], '\n')) |offset| {
        return limit + @as(u32, @intCast(offset)) + 1;
    }
    return boundaryAtOrBefore(value, end, limit);
}

fn isBoundary(value: []const u8, index: u32) bool {
    assert(index <= value.len);
    if (index == value.len) return true;
    return value[index] & 0xC0 != 0x80;
}

test "a value within the budget is kept whole, one byte past it is cut" {
    const exact = "abcd\nefgh";
    const whole = window(exact, .{ .start = 2, .end = 2 }, exact.len);
    try std.testing.expectEqual(Window{ .start = 0, .end = exact.len }, whole);
    try std.testing.expectEqual(Window{ .start = 0, .end = 9 }, window(exact, null, 9));
    try std.testing.expectEqual(Window{ .start = 0, .end = 5 }, window(exact, null, 8));
}

test "the cut keeps whole lines around the caret and moves the selection with it" {
    var text: [1000]u8 = undefined;
    for (0..100) |line| {
        _ = std.fmt.bufPrint(text[line * 10 ..][0..10], "line {d:0>4}\n", .{line}) catch
            unreachable;
    }
    const caret: u32 = 503;
    const kept = window(&text, .{ .start = caret, .end = caret }, 64);
    try std.testing.expect(kept.end - kept.start <= 64);
    try std.testing.expect(kept.start <= caret);
    try std.testing.expect(caret <= kept.end);
    try std.testing.expectEqual(@as(u32, 0), kept.start % 10);
    try std.testing.expectEqual(@as(u32, 0), kept.end % 10);
    try std.testing.expect(caret - kept.start >= 10);
    try std.testing.expect(kept.end - caret >= 10);
    const moved = relative(.{ .start = caret, .end = caret + 4 }, kept);
    try std.testing.expectEqual(caret - kept.start, moved.start);
    try std.testing.expectEqualStrings("e 00", text[kept.start..][moved.start..moved.end]);
    try std.testing.expectEqual(kept, window(&text, .{ .start = caret + 1, .end = caret + 1 }, 64));
    const last = window(&text, .{ .start = 1000, .end = 1000 }, 64);
    try std.testing.expectEqual(@as(u32, 1000), last.end);
    try std.testing.expectEqual(@as(u32, 940), last.start);
}

test "a long selection keeps its start and a long line is cut at code points" {
    var bytes: [360]u8 = undefined;
    for (0..40) |index| @memcpy(bytes[index * 9 ..][0..9], "日本語");
    const text: []const u8 = &bytes;
    const selection = TextSelection{ .start = 30, .end = 330 };
    const kept = window(text, selection, 100);
    try std.testing.expectEqual(@as(u32, 30), kept.start);
    try std.testing.expect(kept.end - kept.start <= 100);
    try std.testing.expect(std.unicode.utf8ValidateSlice(text[kept.start..kept.end]));
    const moved = relative(selection, kept);
    try std.testing.expectEqual(@as(u32, 0), moved.start);
    try std.testing.expectEqual(kept.end - kept.start, moved.end);
    const caret = window(text, .{ .start = 180, .end = 180 }, 100);
    try std.testing.expect(caret.start <= 180);
    try std.testing.expect(caret.end >= 180);
    try std.testing.expect(std.unicode.utf8ValidateSlice(text[caret.start..caret.end]));
}
