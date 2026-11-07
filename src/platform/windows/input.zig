//! Win32 input translation — virtual keys, mouse, and wheel → `InputEvent`.
//!
//! Gooey's `KeyTag` enum is named after US ANSI physical positions, but every
//! backend maps its native keys onto that same set of names, so this table is
//! a Windows VK → `KeyTag` translation (US ANSI physical positions). Text
//! arrives separately as `WM_CHAR` UTF-16 units, joined across surrogate
//! pairs before dispatch.
//!
//! Coordinate convention: Win32 client coordinates are already Y-down from
//! the top-left, matching the scene coordinate system, so no flipping is
//! needed. Physical mouse coordinates are divided by the window scale factor
//! to get logical pixels.

const std = @import("std");
const win32 = @import("win32/mod.zig");
const input = @import("../../input/mod.zig");
const geometry = @import("../../core/geometry.zig");

pub const KeyTag = input.KeyTag;
pub const Modifiers = input.Modifiers;
pub const MouseButton = input.MouseButton;

// =============================================================================
// Modifiers
// =============================================================================

/// Current keyboard modifier state, read from the thread's key-state table.
/// `cmd` maps to the Windows key so cross-platform consumers see the same
/// "primary modifier" as macOS Cmd / Linux Super.
pub fn currentModifiers() Modifiers {
    const down = struct {
        fn f(vk: win32.WPARAM) bool {
            return win32.GetKeyState(@intCast(vk)) < 0;
        }
    }.f;

    return .{
        .shift = down(win32.VK_SHIFT),
        .ctrl = down(win32.VK_CONTROL),
        .alt = down(win32.VK_MENU),
        .cmd = down(win32.VK_LWIN) or down(win32.VK_RWIN),
    };
}

/// Mouse messages carry an `MK_*` snapshot in `wParam`; fold it into the
/// live table so a modifier released between the snapshot and dispatch is
/// still reported as held for that event.
pub fn modifiersFromMouseWParam(wparam: win32.WPARAM) Modifiers {
    const mods = currentModifiers();
    return .{
        .shift = mods.shift or (wparam & win32.MK_SHIFT) != 0,
        .ctrl = mods.ctrl or (wparam & win32.MK_CONTROL) != 0,
        .alt = mods.alt,
        .cmd = mods.cmd,
    };
}

// =============================================================================
// VK → KeyTag
// =============================================================================

/// Translate a Windows virtual key code into Gooey's `KeyTag`.
///
/// `extended` is bit 24 of the key message's `lParam` (`KF_EXTENDED`): it
/// distinguishes keypad Enter from the main Enter and right Ctrl/Alt from
/// their left-hand counterparts, which share VK codes.
pub fn keyTagFromVirtualKey(vk: win32.WPARAM, extended: bool) KeyTag {
    if (vk >= 'A' and vk <= 'Z') {
        const letter_map = [26]KeyTag{
            .a, .b, .c, .d, .e, .f, .g, .h, .i, .j, .k, .l, .m,
            .n, .o, .p, .q, .r, .s, .t, .u, .v, .w, .x, .y, .z,
        };
        return letter_map[vk - 'A'];
    }

    if (vk >= '0' and vk <= '9') {
        const digit_map = [10]KeyTag{
            .@"0", .@"1", .@"2", .@"3", .@"4",
            .@"5", .@"6", .@"7", .@"8", .@"9",
        };
        return digit_map[vk - '0'];
    }

    if (vk >= win32.VK_F1 and vk <= win32.VK_F24) {
        // Gooey's KeyTag only defines F1–F20; F21+ collapses to unknown.
        const f_map = [24]KeyTag{
            .f1,  .f2,  .f3,  .f4,  .f5,  .f6,  .f7,  .f8,  .f9,      .f10,     .f11,     .f12,
            .f13, .f14, .f15, .f16, .f17, .f18, .f19, .f20, .unknown, .unknown, .unknown, .unknown,
        };
        return f_map[vk - win32.VK_F1];
    }

    if (vk >= win32.VK_NUMPAD0 and vk <= win32.VK_NUMPAD0 + 9) {
        const kp_map = [10]KeyTag{
            .keypad_0, .keypad_1, .keypad_2, .keypad_3, .keypad_4,
            .keypad_5, .keypad_6, .keypad_7, .keypad_8, .keypad_9,
        };
        return kp_map[vk - win32.VK_NUMPAD0];
    }

    return switch (vk) {
        win32.VK_RETURN => if (extended) .keypad_enter else .@"return",
        win32.VK_TAB => .tab,
        win32.VK_SPACE => .space,
        win32.VK_BACK => .backspace,
        win32.VK_ESCAPE => .escape,
        win32.VK_DELETE => .delete,

        // Punctuation (US ANSI positions).
        win32.VK_OEM_MINUS => .minus,
        win32.VK_OEM_PLUS => .equal,
        win32.VK_OEM_4 => .left_bracket,
        win32.VK_OEM_6 => .right_bracket,
        win32.VK_OEM_5 => .backslash,
        win32.VK_OEM_1 => .semicolon,
        win32.VK_OEM_7 => .quote,
        win32.VK_OEM_COMMA => .comma,
        win32.VK_OEM_PERIOD => .period,
        win32.VK_OEM_2 => .slash,
        win32.VK_OEM_3 => .grave,

        // Keypad operators.
        win32.VK_DECIMAL => .keypad_decimal,
        win32.VK_MULTIPLY => .keypad_multiply,
        win32.VK_ADD => .keypad_plus,
        win32.VK_SUBTRACT => .keypad_minus,
        win32.VK_DIVIDE => if (extended) .keypad_divide else .slash,
        win32.VK_CLEAR => .keypad_clear,

        // Modifiers. VK_SHIFT/CONTROL/MENU are the merged codes; L*/R*
        // variants appear in state queries. Right Ctrl/Alt carry KF_EXTENDED.
        // Neutral names: `super` is the Windows/Meta key, `alt` is Alt.
        win32.VK_SHIFT => .shift,
        win32.VK_CONTROL => if (extended) .right_control else .control,
        win32.VK_MENU => if (extended) .right_alt else .alt,
        win32.VK_LSHIFT => .shift,
        win32.VK_RSHIFT => .right_shift,
        win32.VK_LCONTROL => .control,
        win32.VK_RCONTROL => .right_control,
        win32.VK_LMENU => .alt,
        win32.VK_RMENU => .right_alt,
        win32.VK_LWIN => .super,
        win32.VK_RWIN => .right_super,
        win32.VK_CAPITAL => .caps_lock,

        win32.VK_LEFT => .left,
        win32.VK_RIGHT => .right,
        win32.VK_DOWN => .down,
        win32.VK_UP => .up,

        win32.VK_PRIOR => .page_up,
        win32.VK_NEXT => .page_down,
        win32.VK_HOME => .home,
        win32.VK_END => .end,

        else => .unknown,
    };
}

// =============================================================================
// WM_CHAR → UTF-8
// =============================================================================

/// `WM_CHAR`'s `wParam` is one UTF-16 code unit. Non-BMP characters arrive as
/// two consecutive messages; `CharBuffer` holds the high surrogate until the
/// low half arrives, then emits the complete UTF-8 character.
pub const CharBuffer = struct {
    buf: [4]u8 = undefined,
    len: usize = 0,
    pending_high: ?u16 = null,

    /// Returns true when a complete character is ready in `slice()`.
    pub fn pushUtf16(self: *CharBuffer, unit: u16) bool {
        if (std.unicode.utf16IsHighSurrogate(unit)) {
            self.pending_high = unit;
            self.len = 0;
            return false;
        }
        if (std.unicode.utf16IsLowSurrogate(unit)) {
            if (self.pending_high) |high| {
                const pair = [_]u16{ high, unit };
                const cp = std.unicode.utf16DecodeSurrogatePair(&pair) catch {
                    self.pending_high = null;
                    self.len = 0;
                    return false;
                };
                self.len = std.unicode.utf8Encode(cp, &self.buf) catch 0;
                self.pending_high = null;
                return self.len > 0;
            }
            self.len = 0;
            return false;
        }
        self.pending_high = null;
        self.len = std.unicode.utf8Encode(@intCast(unit), &self.buf) catch 0;
        return self.len > 0;
    }

    pub fn slice(self: *const CharBuffer) []const u8 {
        return self.buf[0..self.len];
    }
};

// =============================================================================
// Mouse / wheel
// =============================================================================

/// `GET_X_LPARAM` / `GET_Y_LPARAM`: signed 16-bit client coordinates packed
/// into the low/high words of `lParam`.
pub fn mouseXFromLParam(lparam: win32.LPARAM) i16 {
    return @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam)))));
}

pub fn mouseYFromLParam(lparam: win32.LPARAM) i16 {
    return @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam)) >> 16)));
}

/// Raw wheel delta: ±120 per notch, positive away from the user (up).
pub fn wheelDeltaFromWParam(wparam: win32.WPARAM) i16 {
    return @bitCast(@as(u16, @truncate(wparam >> 16)));
}

/// Logical pixels one physical wheel notch scrolls, matching what a native
/// Windows app scrolls (three lines ≈ 100 px at 15px line height; Chromium
/// and editors land in the same range). Precision sources bypass this —
/// `scrollDelta` passes their device deltas straight through.
pub const WHEEL_NOTCH_PIXELS: f64 = 100.0;

/// Convert a Win32 wheel delta to Gooey's scroll convention.
///
/// Wayland delivers a positive Y delta for scrolling *down* (towards the
/// user); Win32's `WHEEL_DELTA` is positive *up*. Negating puts Windows on
/// the same axis. One notch (raw ±120) becomes `WHEEL_NOTCH_PIXELS` logical
/// pixels so the wheel moves at native Windows speed; sub-notch deltas from
/// high-resolution wheels are proportional, preserving their finer steps.
pub fn scrollDelta(raw: i16) f64 {
    return -@as(f64, @floatFromInt(raw)) / 120.0 * WHEEL_NOTCH_PIXELS;
}

/// Convert physical client coordinates to logical pixels.
pub fn logicalPoint(x: i16, y: i16, scale_factor: f64) geometry.Point(f64) {
    const s = @max(scale_factor, 0.01);
    return .{
        .x = @as(f64, @floatFromInt(x)) / s,
        .y = @as(f64, @floatFromInt(y)) / s,
    };
}

// =============================================================================
// Tests
// =============================================================================

test "letters, digits and keypad map to distinct physical keys" {
    try std.testing.expectEqual(KeyTag.a, keyTagFromVirtualKey('A', false));
    try std.testing.expectEqual(KeyTag.z, keyTagFromVirtualKey('Z', false));
    try std.testing.expectEqual(KeyTag.@"1", keyTagFromVirtualKey('1', false));
    try std.testing.expectEqual(KeyTag.keypad_5, keyTagFromVirtualKey(win32.VK_NUMPAD0 + 5, false));
    try std.testing.expectEqual(KeyTag.keypad_decimal, keyTagFromVirtualKey(win32.VK_DECIMAL, false));
}

test "extended bit splits keypad enter from main enter" {
    try std.testing.expectEqual(KeyTag.@"return", keyTagFromVirtualKey(win32.VK_RETURN, false));
    try std.testing.expectEqual(KeyTag.keypad_enter, keyTagFromVirtualKey(win32.VK_RETURN, true));
}

test "backspace and forward delete map to distinct tags" {
    try std.testing.expectEqual(KeyTag.backspace, keyTagFromVirtualKey(win32.VK_BACK, false));
    try std.testing.expectEqual(KeyTag.delete, keyTagFromVirtualKey(win32.VK_DELETE, false));
}

test "F keys cover F1-F20 only" {
    try std.testing.expectEqual(KeyTag.f1, keyTagFromVirtualKey(win32.VK_F1, false));
    try std.testing.expectEqual(KeyTag.f20, keyTagFromVirtualKey(win32.VK_F1 + 19, false));
    try std.testing.expectEqual(KeyTag.unknown, keyTagFromVirtualKey(win32.VK_F1 + 20, false));
}

test "unmapped VK collapses to unknown" {
    try std.testing.expectEqual(KeyTag.unknown, keyTagFromVirtualKey(win32.VK_SNAPSHOT, false));
    try std.testing.expectEqual(KeyTag.unknown, keyTagFromVirtualKey(0xE0, false));
}

test "CharBuffer encodes BMP characters and surrogate pairs" {
    var cb: CharBuffer = .{};
    try std.testing.expect(cb.pushUtf16('A'));
    try std.testing.expectEqualStrings("A", cb.slice());

    try std.testing.expect(!cb.pushUtf16(0xD83D));
    try std.testing.expect(cb.pushUtf16(0xDE00));
    try std.testing.expectEqualStrings("\xF0\x9F\x98\x80", cb.slice());

    try std.testing.expect(!cb.pushUtf16(0xD83D));
    try std.testing.expectEqual(@as(usize, 0), cb.slice().len);
    try std.testing.expect(cb.pushUtf16(0x4E2D));
    try std.testing.expectEqualStrings("\xE4\xB8\xAD", cb.slice());
}

test "lparam coordinate extraction sign-extends" {
    const lparam: win32.LPARAM = @as(win32.LPARAM, 100) | @as(win32.LPARAM, 50) << 16;
    try std.testing.expectEqual(@as(i16, 100), mouseXFromLParam(lparam));
    try std.testing.expectEqual(@as(i16, 50), mouseYFromLParam(lparam));

    const neg: win32.LPARAM = @bitCast(@as(isize, -20));
    try std.testing.expectEqual(@as(i16, -20), mouseXFromLParam(neg));
}

test "wheel delta extraction and sign normalization" {
    const up: win32.WPARAM = @as(win32.WPARAM, 120) << 16;
    try std.testing.expectEqual(@as(i16, 120), wheelDeltaFromWParam(up));
    // One notch = one native-wheel distance (~100 px), positive when scrolled down.
    try std.testing.expectEqual(@as(f64, -WHEEL_NOTCH_PIXELS), scrollDelta(120));

    const down_bits: u16 = @bitCast(@as(i16, -120));
    const down: win32.WPARAM = @as(win32.WPARAM, down_bits) << 16;
    try std.testing.expectEqual(@as(i16, -120), wheelDeltaFromWParam(down));
    try std.testing.expectEqual(@as(f64, WHEEL_NOTCH_PIXELS), scrollDelta(-120));

    // High-resolution wheels deliver fractional notches, scaled proportionally.
    try std.testing.expectEqual(@as(f64, -WHEEL_NOTCH_PIXELS / 2), scrollDelta(60));
}
