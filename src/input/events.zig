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

    // Special
    @"return" = 0x24,
    tab = 0x30,
    space = 0x31,
    delete = 0x33,
    escape = 0x35,
    forward_delete = 0x75,

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
};
