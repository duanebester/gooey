const std = @import("std");
const geometry = @import("../core/geometry.zig");

/// Virtual key codes (based on macOS keycodes, used cross-platform)
pub const KeyCode = enum(u16) {
    // Letters
    a = 0x00,
    s = 0x01,
    d = 0x02,
    f = 0x03,
    h = 0x04,
    g = 0x05,
    z = 0x06,
    x = 0x07,
    c = 0x08,
    v = 0x09,
    b = 0x0B,
    q = 0x0C,
    w = 0x0D,
    e = 0x0E,
    r = 0x0F,
    y = 0x10,
    t = 0x11,
    o = 0x1F,
    u = 0x20,
    i = 0x22,
    p = 0x23,
    l = 0x25,
    j = 0x26,
    k = 0x28,
    n = 0x2D,
    m = 0x2E,

    // Numbers
    @"1" = 0x12,
    @"2" = 0x13,
    @"3" = 0x14,
    @"4" = 0x15,
    @"5" = 0x17,
    @"6" = 0x16,
    @"7" = 0x1A,
    @"8" = 0x1C,
    @"9" = 0x19,
    @"0" = 0x1D,

    // Punctuation. Keycodes are positional (US ANSI layout); on other layouts
    // the physical key at this position may produce a different character, so
    // consumers that care about the typed character must use the event's
    // `characters_ignoring_modifiers` instead of these names.
    minus = 0x1B,
    equal = 0x18,
    left_bracket = 0x21,
    right_bracket = 0x1E,
    backslash = 0x2A,
    semicolon = 0x29,
    quote = 0x27,
    comma = 0x2B,
    period = 0x2F,
    slash = 0x2C,
    grave = 0x32,

    // Special
    @"return" = 0x24,
    tab = 0x30,
    space = 0x31,
    delete = 0x33,
    escape = 0x35,
    forward_delete = 0x75,

    // Keypad (kVK_ANSI_Keypad*). Distinct from the number row so terminal
    // emulators and games can honor application keypad mode (DECKPAM).
    keypad_0 = 0x52,
    keypad_1 = 0x53,
    keypad_2 = 0x54,
    keypad_3 = 0x55,
    keypad_4 = 0x56,
    keypad_5 = 0x57,
    keypad_6 = 0x58,
    keypad_7 = 0x59,
    keypad_8 = 0x5B,
    keypad_9 = 0x5C,
    keypad_decimal = 0x41,
    keypad_multiply = 0x43,
    keypad_plus = 0x45,
    keypad_clear = 0x47, // NumLock position on PC keyboards
    keypad_divide = 0x4B,
    keypad_enter = 0x4C,
    keypad_minus = 0x4E,
    keypad_equals = 0x51,

    // Modifiers
    command = 0x37,
    shift = 0x38,
    caps_lock = 0x39,
    option = 0x3A,
    control = 0x3B,
    right_command = 0x36,
    right_shift = 0x3C,
    right_option = 0x3D,
    right_control = 0x3E,

    // Arrows
    left = 0x7B,
    right = 0x7C,
    down = 0x7D,
    up = 0x7E,

    // Function keys
    f1 = 0x7A,
    f2 = 0x78,
    f3 = 0x63,
    f4 = 0x76,
    f5 = 0x60,
    f6 = 0x61,
    f7 = 0x62,
    f8 = 0x64,
    f9 = 0x65,
    f10 = 0x6D,
    f11 = 0x67,
    f12 = 0x6F,
    f13 = 0x69,
    f14 = 0x6B,
    f15 = 0x71,
    f16 = 0x6A,
    f17 = 0x40,
    f18 = 0x4F,
    f19 = 0x50,
    f20 = 0x5A,

    // Navigation
    home = 0x73,
    end = 0x77,
    page_up = 0x74,
    page_down = 0x79,

    unknown = 0xFFFF,
    _,

    pub fn from(code: u16) KeyCode {
        const result: KeyCode = @enumFromInt(code);
        if (std.enums.tagName(KeyCode, result) == null) return .unknown;
        return result;
    }
};

pub const MouseButton = enum(u8) {
    left = 0,
    right = 1,
    middle = 2,
};

pub const Modifiers = packed struct(u8) {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    cmd: bool = false,
    _pad: u4 = 0,
};

pub const MouseEvent = struct {
    position: geometry.Point(f64),
    button: MouseButton,
    click_count: u32,
    modifiers: Modifiers,
};

pub const ScrollEvent = struct {
    position: geometry.Point(f64),
    delta: geometry.Point(f64),
    modifiers: Modifiers,
};

pub const KeyEvent = struct {
    key: KeyCode,
    modifiers: Modifiers,
    /// The characters produced by this key event (UTF-8)
    /// May be empty for non-printable keys
    characters: ?[]const u8,
    /// Characters ignoring modifiers (for shortcuts)
    characters_ignoring_modifiers: ?[]const u8,
    /// Key repeat
    is_repeat: bool,
};

/// Text inserted via IME (Input Method Editor)
/// This includes emoji picker, dead keys, CJK input, dictation, etc.
pub const TextInputEvent = struct {
    /// The inserted text (UTF-8 encoded)
    text: []const u8,
};

/// IME composition (preedit) state changed
pub const CompositionEvent = struct {
    /// The composing text (UTF-8 encoded), empty if composition ended
    text: []const u8,
};

/// A single touch point on a touch screen or trackpad
pub const TouchEvent = struct {
    position: geometry.Point(f64),
    /// Touch point identifier, unique per active touch within a gesture sequence.
    id: i32,
};

pub const InputEvent = union(enum) {
    mouse_down: MouseEvent,
    mouse_up: MouseEvent,
    mouse_moved: MouseEvent,
    mouse_dragged: MouseEvent,
    mouse_entered: MouseEvent,
    mouse_exited: MouseEvent,
    scroll: ScrollEvent,
    key_down: KeyEvent,
    key_up: KeyEvent,
    modifiers_changed: Modifiers,
    /// Text inserted via IME (final, committed text)
    text_input: TextInputEvent,
    /// IME composition state changed (preedit text)
    composition: CompositionEvent,
    touch_down: TouchEvent,
    touch_up: TouchEvent,
    touch_moved: TouchEvent,
    /// All active touch points on the surface were cancelled by the compositor.
    touch_cancelled,
};

// Goal: `KeyCode.from` must resolve every named virtual keycode to its tag and
// collapse only genuinely unnamed codes to `.unknown`. Keypad, punctuation,
// and extended function keys were historically absent from the enum and were
// destroyed here before any consumer could see them; these cases pin the fix.
test "KeyCode.from resolves named codes and collapses unnamed ones" {
    const testing = std.testing;

    // Writing keys, one per historical group.
    try testing.expectEqual(KeyCode.a, KeyCode.from(0x00));
    try testing.expectEqual(KeyCode.@"5", KeyCode.from(0x17));
    try testing.expectEqual(KeyCode.@"return", KeyCode.from(0x24));

    // Punctuation (kVK_ANSI_*).
    try testing.expectEqual(KeyCode.minus, KeyCode.from(0x1B));
    try testing.expectEqual(KeyCode.left_bracket, KeyCode.from(0x21));
    try testing.expectEqual(KeyCode.grave, KeyCode.from(0x32));

    // Keypad. KeypadEnter (0x4C) is the key regression case: it produces no
    // printable text, so collapsing it to `.unknown` drops the keystroke.
    try testing.expectEqual(KeyCode.keypad_enter, KeyCode.from(0x4C));
    try testing.expectEqual(KeyCode.keypad_0, KeyCode.from(0x52));
    try testing.expectEqual(KeyCode.keypad_9, KeyCode.from(0x5C));
    try testing.expectEqual(KeyCode.keypad_clear, KeyCode.from(0x47));

    // Extended function keys.
    try testing.expectEqual(KeyCode.f13, KeyCode.from(0x69));
    try testing.expectEqual(KeyCode.f20, KeyCode.from(0x5A));

    // Negative space: codes with no name still collapse to `.unknown`.
    try testing.expectEqual(KeyCode.unknown, KeyCode.from(0x42)); // gap in kVK table
    try testing.expectEqual(KeyCode.unknown, KeyCode.from(0xFFFF));
    try testing.expectEqual(KeyCode.unknown, KeyCode.from(0x1234));
}
