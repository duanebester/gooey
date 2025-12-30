//! Linux Input Handling
//!
//! Maps Linux evdev keycodes to Gooey's cross-platform input types
//! and provides utilities for parsing Wayland input events.

const std = @import("std");
const input = @import("../../core/input.zig");
const geometry = @import("../../core/geometry.zig");
const wayland = @import("wayland.zig");

// =============================================================================
// Evdev Keycode Constants
// =============================================================================

/// Linux evdev keycodes (from linux/input-event-codes.h)
pub const evdev = struct {
    // Escape and function keys
    pub const KEY_ESC: u32 = 1;
    pub const KEY_F1: u32 = 59;
    pub const KEY_F2: u32 = 60;
    pub const KEY_F3: u32 = 61;
    pub const KEY_F4: u32 = 62;
    pub const KEY_F5: u32 = 63;
    pub const KEY_F6: u32 = 64;
    pub const KEY_F7: u32 = 65;
    pub const KEY_F8: u32 = 66;
    pub const KEY_F9: u32 = 67;
    pub const KEY_F10: u32 = 68;
    pub const KEY_F11: u32 = 87;
    pub const KEY_F12: u32 = 88;

    // Number row
    pub const KEY_1: u32 = 2;
    pub const KEY_2: u32 = 3;
    pub const KEY_3: u32 = 4;
    pub const KEY_4: u32 = 5;
    pub const KEY_5: u32 = 6;
    pub const KEY_6: u32 = 7;
    pub const KEY_7: u32 = 8;
    pub const KEY_8: u32 = 9;
    pub const KEY_9: u32 = 10;
    pub const KEY_0: u32 = 11;

    // Top row (QWERTY)
    pub const KEY_Q: u32 = 16;
    pub const KEY_W: u32 = 17;
    pub const KEY_E: u32 = 18;
    pub const KEY_R: u32 = 19;
    pub const KEY_T: u32 = 20;
    pub const KEY_Y: u32 = 21;
    pub const KEY_U: u32 = 22;
    pub const KEY_I: u32 = 23;
    pub const KEY_O: u32 = 24;
    pub const KEY_P: u32 = 25;

    // Home row (ASDF)
    pub const KEY_A: u32 = 30;
    pub const KEY_S: u32 = 31;
    pub const KEY_D: u32 = 32;
    pub const KEY_F: u32 = 33;
    pub const KEY_G: u32 = 34;
    pub const KEY_H: u32 = 35;
    pub const KEY_J: u32 = 36;
    pub const KEY_K: u32 = 37;
    pub const KEY_L: u32 = 38;

    // Bottom row (ZXCV)
    pub const KEY_Z: u32 = 44;
    pub const KEY_X: u32 = 45;
    pub const KEY_C: u32 = 46;
    pub const KEY_V: u32 = 47;
    pub const KEY_B: u32 = 48;
    pub const KEY_N: u32 = 49;
    pub const KEY_M: u32 = 50;

    // Special keys
    pub const KEY_TAB: u32 = 15;
    pub const KEY_ENTER: u32 = 28;
    pub const KEY_SPACE: u32 = 57;
    pub const KEY_BACKSPACE: u32 = 14;
    pub const KEY_DELETE: u32 = 111;
    pub const KEY_CAPSLOCK: u32 = 58;

    // Arrow keys
    pub const KEY_LEFT: u32 = 105;
    pub const KEY_RIGHT: u32 = 106;
    pub const KEY_UP: u32 = 103;
    pub const KEY_DOWN: u32 = 108;

    // Navigation
    pub const KEY_HOME: u32 = 102;
    pub const KEY_END: u32 = 107;
    pub const KEY_PAGEUP: u32 = 104;
    pub const KEY_PAGEDOWN: u32 = 109;

    // Modifiers
    pub const KEY_LEFTSHIFT: u32 = 42;
    pub const KEY_RIGHTSHIFT: u32 = 54;
    pub const KEY_LEFTCTRL: u32 = 29;
    pub const KEY_RIGHTCTRL: u32 = 97;
    pub const KEY_LEFTALT: u32 = 56;
    pub const KEY_RIGHTALT: u32 = 100;
    pub const KEY_LEFTMETA: u32 = 125;
    pub const KEY_RIGHTMETA: u32 = 126;

    // Punctuation and symbols
    pub const KEY_MINUS: u32 = 12; // - _
    pub const KEY_EQUAL: u32 = 13; // = +
    pub const KEY_LEFTBRACE: u32 = 26; // [ {
    pub const KEY_RIGHTBRACE: u32 = 27; // ] }
    pub const KEY_SEMICOLON: u32 = 39; // ; :
    pub const KEY_APOSTROPHE: u32 = 40; // ' "
    pub const KEY_GRAVE: u32 = 41; // ` ~
    pub const KEY_BACKSLASH: u32 = 43; // \ |
    pub const KEY_COMMA: u32 = 51; // , <
    pub const KEY_DOT: u32 = 52; // . >
    pub const KEY_SLASH: u32 = 53; // / ?
};

// =============================================================================
// Key to Character Conversion
// =============================================================================

/// Convert evdev keycode to a character, considering shift state.
/// Returns null for non-printable keys (modifiers, function keys, etc.)
/// This is a simple US QWERTY layout mapping - full xkbcommon integration
/// would be needed for proper international keyboard support.
pub fn evdevKeyToChar(key: u32, shift: bool) ?u8 {
    // Letters (a-z / A-Z)
    const char: ?u8 = switch (key) {
        evdev.KEY_A => if (shift) 'A' else 'a',
        evdev.KEY_B => if (shift) 'B' else 'b',
        evdev.KEY_C => if (shift) 'C' else 'c',
        evdev.KEY_D => if (shift) 'D' else 'd',
        evdev.KEY_E => if (shift) 'E' else 'e',
        evdev.KEY_F => if (shift) 'F' else 'f',
        evdev.KEY_G => if (shift) 'G' else 'g',
        evdev.KEY_H => if (shift) 'H' else 'h',
        evdev.KEY_I => if (shift) 'I' else 'i',
        evdev.KEY_J => if (shift) 'J' else 'j',
        evdev.KEY_K => if (shift) 'K' else 'k',
        evdev.KEY_L => if (shift) 'L' else 'l',
        evdev.KEY_M => if (shift) 'M' else 'm',
        evdev.KEY_N => if (shift) 'N' else 'n',
        evdev.KEY_O => if (shift) 'O' else 'o',
        evdev.KEY_P => if (shift) 'P' else 'p',
        evdev.KEY_Q => if (shift) 'Q' else 'q',
        evdev.KEY_R => if (shift) 'R' else 'r',
        evdev.KEY_S => if (shift) 'S' else 's',
        evdev.KEY_T => if (shift) 'T' else 't',
        evdev.KEY_U => if (shift) 'U' else 'u',
        evdev.KEY_V => if (shift) 'V' else 'v',
        evdev.KEY_W => if (shift) 'W' else 'w',
        evdev.KEY_X => if (shift) 'X' else 'x',
        evdev.KEY_Y => if (shift) 'Y' else 'y',
        evdev.KEY_Z => if (shift) 'Z' else 'z',

        // Numbers and their shifted symbols
        evdev.KEY_1 => if (shift) '!' else '1',
        evdev.KEY_2 => if (shift) '@' else '2',
        evdev.KEY_3 => if (shift) '#' else '3',
        evdev.KEY_4 => if (shift) '$' else '4',
        evdev.KEY_5 => if (shift) '%' else '5',
        evdev.KEY_6 => if (shift) '^' else '6',
        evdev.KEY_7 => if (shift) '&' else '7',
        evdev.KEY_8 => if (shift) '*' else '8',
        evdev.KEY_9 => if (shift) '(' else '9',
        evdev.KEY_0 => if (shift) ')' else '0',

        // Punctuation
        evdev.KEY_MINUS => if (shift) '_' else '-',
        evdev.KEY_EQUAL => if (shift) '+' else '=',
        evdev.KEY_LEFTBRACE => if (shift) '{' else '[',
        evdev.KEY_RIGHTBRACE => if (shift) '}' else ']',
        evdev.KEY_SEMICOLON => if (shift) ':' else ';',
        evdev.KEY_APOSTROPHE => if (shift) '"' else '\'',
        evdev.KEY_GRAVE => if (shift) '~' else '`',
        evdev.KEY_BACKSLASH => if (shift) '|' else '\\',
        evdev.KEY_COMMA => if (shift) '<' else ',',
        evdev.KEY_DOT => if (shift) '>' else '.',
        evdev.KEY_SLASH => if (shift) '?' else '/',

        // Whitespace
        evdev.KEY_SPACE => ' ',
        evdev.KEY_TAB => '\t',

        else => null,
    };
    return char;
}

// =============================================================================
// XKB Modifier Masks
// =============================================================================

/// Standard XKB modifier bit positions
pub const xkb_mod = struct {
    pub const SHIFT: u32 = 1 << 0;
    pub const CAPS: u32 = 1 << 1;
    pub const CTRL: u32 = 1 << 2;
    pub const ALT: u32 = 1 << 3; // Mod1
    pub const NUM: u32 = 1 << 4; // Mod2
    pub const SUPER: u32 = 1 << 6; // Mod4
};

// =============================================================================
// Keycode Mapping
// =============================================================================

/// Convert Linux evdev keycode to cross-platform KeyCode
pub fn evdevToKeyCode(evdev_key: u32) input.KeyCode {
    return switch (evdev_key) {
        // Letters
        evdev.KEY_A => .a,
        evdev.KEY_B => .b,
        evdev.KEY_C => .c,
        evdev.KEY_D => .d,
        evdev.KEY_E => .e,
        evdev.KEY_F => .f,
        evdev.KEY_G => .g,
        evdev.KEY_H => .h,
        evdev.KEY_I => .i,
        evdev.KEY_J => .j,
        evdev.KEY_K => .k,
        evdev.KEY_L => .l,
        evdev.KEY_M => .m,
        evdev.KEY_N => .n,
        evdev.KEY_O => .o,
        evdev.KEY_P => .p,
        evdev.KEY_Q => .q,
        evdev.KEY_R => .r,
        evdev.KEY_S => .s,
        evdev.KEY_T => .t,
        evdev.KEY_U => .u,
        evdev.KEY_V => .v,
        evdev.KEY_W => .w,
        evdev.KEY_X => .x,
        evdev.KEY_Y => .y,
        evdev.KEY_Z => .z,

        // Numbers
        evdev.KEY_1 => .@"1",
        evdev.KEY_2 => .@"2",
        evdev.KEY_3 => .@"3",
        evdev.KEY_4 => .@"4",
        evdev.KEY_5 => .@"5",
        evdev.KEY_6 => .@"6",
        evdev.KEY_7 => .@"7",
        evdev.KEY_8 => .@"8",
        evdev.KEY_9 => .@"9",
        evdev.KEY_0 => .@"0",

        // Special keys
        evdev.KEY_ESC => .escape,
        evdev.KEY_TAB => .tab,
        evdev.KEY_ENTER => .@"return",
        evdev.KEY_SPACE => .space,
        evdev.KEY_BACKSPACE => .delete,
        evdev.KEY_DELETE => .forward_delete,
        evdev.KEY_CAPSLOCK => .caps_lock,

        // Arrow keys
        evdev.KEY_LEFT => .left,
        evdev.KEY_RIGHT => .right,
        evdev.KEY_UP => .up,
        evdev.KEY_DOWN => .down,

        // Navigation
        evdev.KEY_HOME => .home,
        evdev.KEY_END => .end,
        evdev.KEY_PAGEUP => .page_up,
        evdev.KEY_PAGEDOWN => .page_down,

        // Function keys
        evdev.KEY_F1 => .f1,
        evdev.KEY_F2 => .f2,
        evdev.KEY_F3 => .f3,
        evdev.KEY_F4 => .f4,
        evdev.KEY_F5 => .f5,
        evdev.KEY_F6 => .f6,
        evdev.KEY_F7 => .f7,
        evdev.KEY_F8 => .f8,
        evdev.KEY_F9 => .f9,
        evdev.KEY_F10 => .f10,
        evdev.KEY_F11 => .f11,
        evdev.KEY_F12 => .f12,

        // Modifiers
        evdev.KEY_LEFTSHIFT => .shift,
        evdev.KEY_RIGHTSHIFT => .right_shift,
        evdev.KEY_LEFTCTRL => .control,
        evdev.KEY_RIGHTCTRL => .right_control,
        evdev.KEY_LEFTALT => .option,
        evdev.KEY_RIGHTALT => .right_option,
        evdev.KEY_LEFTMETA => .command,
        evdev.KEY_RIGHTMETA => .right_command,

        else => .unknown,
    };
}

// =============================================================================
// Modifier Parsing
// =============================================================================

/// Parse XKB modifier state into cross-platform Modifiers
pub fn parseModifiers(mods_depressed: u32) input.Modifiers {
    return .{
        .shift = (mods_depressed & xkb_mod.SHIFT) != 0,
        .ctrl = (mods_depressed & xkb_mod.CTRL) != 0,
        .alt = (mods_depressed & xkb_mod.ALT) != 0,
        .cmd = (mods_depressed & xkb_mod.SUPER) != 0,
    };
}

/// Create Modifiers from individual boolean flags
pub fn modifiersFromFlags(shift: bool, ctrl: bool, alt: bool, super: bool) input.Modifiers {
    return .{
        .shift = shift,
        .ctrl = ctrl,
        .alt = alt,
        .cmd = super,
    };
}

// =============================================================================
// Mouse Event Parsing
// =============================================================================

/// Convert Wayland button code to MouseButton
pub fn parseMouseButton(button: u32) input.MouseButton {
    return switch (button) {
        wayland.BTN_LEFT => .left,
        wayland.BTN_RIGHT => .right,
        wayland.BTN_MIDDLE => .middle,
        else => .left,
    };
}

/// Create a MouseEvent from Wayland pointer data
pub fn createMouseEvent(
    x: f64,
    y: f64,
    button: input.MouseButton,
    click_count: u32,
    modifiers: input.Modifiers,
) input.MouseEvent {
    return .{
        .position = geometry.Point(f64).init(x, y),
        .button = button,
        .click_count = click_count,
        .modifiers = modifiers,
    };
}

/// Create a ScrollEvent from Wayland axis data
pub fn createScrollEvent(
    x: f64,
    y: f64,
    delta_x: f64,
    delta_y: f64,
    modifiers: input.Modifiers,
) input.ScrollEvent {
    return .{
        .position = geometry.Point(f64).init(x, y),
        .delta = geometry.Point(f64).init(delta_x, delta_y),
        .modifiers = modifiers,
    };
}

// =============================================================================
// Keyboard Event Parsing
// =============================================================================

/// Create a KeyEvent from Wayland keyboard data
pub fn createKeyEvent(
    evdev_key: u32,
    modifiers: input.Modifiers,
    is_repeat: bool,
) input.KeyEvent {
    return .{
        .key = evdevToKeyCode(evdev_key),
        .modifiers = modifiers,
        .characters = null, // TODO: xkbcommon integration for text input
        .characters_ignoring_modifiers = null,
        .is_repeat = is_repeat,
    };
}

// =============================================================================
// Input Event Construction Helpers
// =============================================================================

/// Construct a mouse_down InputEvent
pub fn mouseDownEvent(
    x: f64,
    y: f64,
    button: u32,
    click_count: u32,
    modifiers: input.Modifiers,
) input.InputEvent {
    return .{
        .mouse_down = createMouseEvent(x, y, parseMouseButton(button), click_count, modifiers),
    };
}

/// Construct a mouse_up InputEvent
pub fn mouseUpEvent(
    x: f64,
    y: f64,
    button: u32,
    modifiers: input.Modifiers,
) input.InputEvent {
    return .{
        .mouse_up = createMouseEvent(x, y, parseMouseButton(button), 0, modifiers),
    };
}

/// Construct a mouse_moved InputEvent
pub fn mouseMovedEvent(
    x: f64,
    y: f64,
    modifiers: input.Modifiers,
) input.InputEvent {
    return .{
        .mouse_moved = createMouseEvent(x, y, .left, 0, modifiers),
    };
}

/// Construct a mouse_dragged InputEvent (mouse moved while button pressed)
pub fn mouseDraggedEvent(
    x: f64,
    y: f64,
    button: input.MouseButton,
    modifiers: input.Modifiers,
) input.InputEvent {
    return .{
        .mouse_dragged = createMouseEvent(x, y, button, 0, modifiers),
    };
}

/// Construct a mouse_entered InputEvent
pub fn mouseEnteredEvent(
    x: f64,
    y: f64,
    modifiers: input.Modifiers,
) input.InputEvent {
    return .{
        .mouse_entered = createMouseEvent(x, y, .left, 0, modifiers),
    };
}

/// Construct a mouse_exited InputEvent
pub fn mouseExitedEvent(
    x: f64,
    y: f64,
    modifiers: input.Modifiers,
) input.InputEvent {
    return .{
        .mouse_exited = createMouseEvent(x, y, .left, 0, modifiers),
    };
}

/// Construct a scroll InputEvent
pub fn scrollEvent(
    x: f64,
    y: f64,
    delta_x: f64,
    delta_y: f64,
    modifiers: input.Modifiers,
) input.InputEvent {
    return .{
        .scroll = createScrollEvent(x, y, delta_x, delta_y, modifiers),
    };
}

/// Construct a key_down InputEvent
pub fn keyDownEvent(
    evdev_key: u32,
    modifiers: input.Modifiers,
    is_repeat: bool,
) input.InputEvent {
    return .{
        .key_down = createKeyEvent(evdev_key, modifiers, is_repeat),
    };
}

/// Construct a key_up InputEvent
pub fn keyUpEvent(
    evdev_key: u32,
    modifiers: input.Modifiers,
) input.InputEvent {
    return .{
        .key_up = createKeyEvent(evdev_key, modifiers, false),
    };
}

/// Construct a modifiers_changed InputEvent
pub fn modifiersChangedEvent(modifiers: input.Modifiers) input.InputEvent {
    return .{
        .modifiers_changed = modifiers,
    };
}

/// Construct a text_input InputEvent
pub fn textInputEvent(text: []const u8) input.InputEvent {
    return .{
        .text_input = .{ .text = text },
    };
}

/// Construct a composition InputEvent (IME preedit)
pub fn compositionEvent(text: []const u8) input.InputEvent {
    return .{
        .composition = .{ .text = text },
    };
}

// =============================================================================
// Click Detection
// =============================================================================

/// Maximum time between clicks for multi-click detection (milliseconds)
pub const MULTI_CLICK_TIME_MS: u32 = 500;

/// Maximum distance between clicks for multi-click detection (pixels)
pub const MULTI_CLICK_DISTANCE: f64 = 5.0;

/// Click state tracker for detecting double/triple clicks
pub const ClickTracker = struct {
    last_click_time: u32 = 0,
    last_click_x: f64 = 0,
    last_click_y: f64 = 0,
    last_click_button: u32 = 0,
    click_count: u32 = 0,

    const Self = @This();

    /// Record a click and return the click count (1 = single, 2 = double, etc.)
    pub fn recordClick(self: *Self, time_ms: u32, x: f64, y: f64, button: u32) u32 {
        const time_delta = time_ms -% self.last_click_time;
        const dx = x - self.last_click_x;
        const dy = y - self.last_click_y;
        const distance = @sqrt(dx * dx + dy * dy);

        // Check if this is a continuation of a multi-click sequence
        if (time_delta < MULTI_CLICK_TIME_MS and
            distance < MULTI_CLICK_DISTANCE and
            button == self.last_click_button)
        {
            self.click_count += 1;
        } else {
            self.click_count = 1;
        }

        // Update state
        self.last_click_time = time_ms;
        self.last_click_x = x;
        self.last_click_y = y;
        self.last_click_button = button;

        return self.click_count;
    }

    /// Reset click tracking (e.g., on focus loss)
    pub fn reset(self: *Self) void {
        self.* = .{};
    }
};

// =============================================================================
// Key Repeat Detection
// =============================================================================

/// Key repeat state tracker
pub const KeyRepeatTracker = struct {
    /// Currently pressed keys (bitset for common keys)
    pressed_keys: std.StaticBitSet(256) = std.StaticBitSet(256).initEmpty(),

    const Self = @This();

    /// Check if a key is already pressed (repeat) and mark it as pressed
    pub fn checkAndPress(self: *Self, evdev_key: u32) bool {
        if (evdev_key >= 256) return false;

        const was_pressed = self.pressed_keys.isSet(evdev_key);
        self.pressed_keys.set(evdev_key);
        return was_pressed;
    }

    /// Mark a key as released
    pub fn release(self: *Self, evdev_key: u32) void {
        if (evdev_key >= 256) return;
        self.pressed_keys.unset(evdev_key);
    }

    /// Reset all key states (e.g., on focus loss)
    pub fn reset(self: *Self) void {
        self.pressed_keys = std.StaticBitSet(256).initEmpty();
    }
};

// =============================================================================
// Tests
// =============================================================================

test "evdev to keycode mapping" {
    const testing = std.testing;

    try testing.expectEqual(input.KeyCode.a, evdevToKeyCode(evdev.KEY_A));
    try testing.expectEqual(input.KeyCode.z, evdevToKeyCode(evdev.KEY_Z));
    try testing.expectEqual(input.KeyCode.@"1", evdevToKeyCode(evdev.KEY_1));
    try testing.expectEqual(input.KeyCode.@"return", evdevToKeyCode(evdev.KEY_ENTER));
    try testing.expectEqual(input.KeyCode.escape, evdevToKeyCode(evdev.KEY_ESC));
    try testing.expectEqual(input.KeyCode.left, evdevToKeyCode(evdev.KEY_LEFT));
    try testing.expectEqual(input.KeyCode.f1, evdevToKeyCode(evdev.KEY_F1));
    try testing.expectEqual(input.KeyCode.unknown, evdevToKeyCode(9999));
}

test "modifier parsing" {
    const testing = std.testing;

    const mods = parseModifiers(xkb_mod.SHIFT | xkb_mod.CTRL);
    try testing.expect(mods.shift);
    try testing.expect(mods.ctrl);
    try testing.expect(!mods.alt);
    try testing.expect(!mods.cmd);
}

test "click tracker" {
    const testing = std.testing;

    var tracker = ClickTracker{};

    // First click
    try testing.expectEqual(@as(u32, 1), tracker.recordClick(1000, 100, 100, wayland.BTN_LEFT));

    // Second click (double-click)
    try testing.expectEqual(@as(u32, 2), tracker.recordClick(1200, 101, 100, wayland.BTN_LEFT));

    // Third click (triple-click)
    try testing.expectEqual(@as(u32, 3), tracker.recordClick(1400, 100, 101, wayland.BTN_LEFT));

    // Click after timeout - resets
    try testing.expectEqual(@as(u32, 1), tracker.recordClick(2500, 100, 100, wayland.BTN_LEFT));
}

test "key repeat tracker" {
    const testing = std.testing;

    var tracker = KeyRepeatTracker{};

    // First press - not a repeat
    try testing.expect(!tracker.checkAndPress(evdev.KEY_A));

    // Second press - is a repeat
    try testing.expect(tracker.checkAndPress(evdev.KEY_A));

    // Release
    tracker.release(evdev.KEY_A);

    // Press again - not a repeat
    try testing.expect(!tracker.checkAndPress(evdev.KEY_A));
}

test "IME text input event" {
    const testing = std.testing;

    const event = textInputEvent("hello");
    switch (event) {
        .text_input => |t| {
            try testing.expectEqualStrings("hello", t.text);
        },
        else => try testing.expect(false),
    }
}

test "evdevKeyToChar" {
    const testing = std.testing;

    // Letters
    try testing.expectEqual(@as(?u8, 'a'), evdevKeyToChar(evdev.KEY_A, false));
    try testing.expectEqual(@as(?u8, 'A'), evdevKeyToChar(evdev.KEY_A, true));
    try testing.expectEqual(@as(?u8, 'z'), evdevKeyToChar(evdev.KEY_Z, false));
    try testing.expectEqual(@as(?u8, 'Z'), evdevKeyToChar(evdev.KEY_Z, true));

    // Numbers and symbols
    try testing.expectEqual(@as(?u8, '1'), evdevKeyToChar(evdev.KEY_1, false));
    try testing.expectEqual(@as(?u8, '!'), evdevKeyToChar(evdev.KEY_1, true));
    try testing.expectEqual(@as(?u8, '2'), evdevKeyToChar(evdev.KEY_2, false));
    try testing.expectEqual(@as(?u8, '@'), evdevKeyToChar(evdev.KEY_2, true));

    // Punctuation
    try testing.expectEqual(@as(?u8, '.'), evdevKeyToChar(evdev.KEY_DOT, false));
    try testing.expectEqual(@as(?u8, '>'), evdevKeyToChar(evdev.KEY_DOT, true));
    try testing.expectEqual(@as(?u8, ' '), evdevKeyToChar(evdev.KEY_SPACE, false));

    // Non-printable keys return null
    try testing.expectEqual(@as(?u8, null), evdevKeyToChar(evdev.KEY_LEFTSHIFT, false));
    try testing.expectEqual(@as(?u8, null), evdevKeyToChar(evdev.KEY_F1, false));
    try testing.expectEqual(@as(?u8, null), evdevKeyToChar(evdev.KEY_LEFT, false));
}

test "IME composition event" {
    const testing = std.testing;

    // Composition with text (preedit)
    const event1 = compositionEvent("日本");
    switch (event1) {
        .composition => |c| {
            try testing.expectEqualStrings("日本", c.text);
        },
        else => try testing.expect(false),
    }

    // Empty composition (composition ended)
    const event2 = compositionEvent("");
    switch (event2) {
        .composition => |c| {
            try testing.expectEqual(@as(usize, 0), c.text.len);
        },
        else => try testing.expect(false),
    }
}
