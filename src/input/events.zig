const std = @import("std");
const geometry = @import("../core/geometry.zig");

/// Platform-neutral key tag.
///
/// Describes only "which key was pressed", named by US ANSI physical
/// position, and carries no platform's raw codes. Each platform backend is
/// responsible for translating its native scancode / virtual key / evdev /
/// DOM code into these names (see `platform/<os>/input.zig`).
///
/// Consumers match on names directly, e.g. `if (key == .escape) win.close();`,
/// and never need to know which underlying code triggered the event.
pub const KeyTag = enum {
    // Letters
    a,
    s,
    d,
    f,
    h,
    g,
    z,
    x,
    c,
    v,
    b,
    q,
    w,
    e,
    r,
    y,
    t,
    o,
    u,
    i,
    p,
    l,
    j,
    k,
    n,
    m,

    // Numbers
    @"1",
    @"2",
    @"3",
    @"4",
    @"5",
    @"6",
    @"7",
    @"8",
    @"9",
    @"0",

    // Punctuation. Tag names are positional (US ANSI layout); on other layouts
    // the physical key at this position may produce a different character, so
    // consumers that care about the typed character must use the event's
    // `characters_ignoring_modifiers` instead of these names.
    minus,
    equal,
    left_bracket,
    right_bracket,
    backslash,
    semicolon,
    quote,
    comma,
    period,
    slash,
    grave,

    // Special
    @"return",
    tab,
    space,
    backspace,
    escape,
    delete,

    // Keypad. Distinct from the number row so terminal emulators and games
    // can honor application keypad mode (DECKPAM).
    keypad_0,
    keypad_1,
    keypad_2,
    keypad_3,
    keypad_4,
    keypad_5,
    keypad_6,
    keypad_7,
    keypad_8,
    keypad_9,
    keypad_decimal,
    keypad_multiply,
    keypad_plus,
    keypad_clear, // NumLock position on PC keyboards
    keypad_divide,
    keypad_enter,
    keypad_minus,
    keypad_equals,

    // Modifiers. Neutral names: `super` is the Windows/Meta key, `alt` is
    // Alt/Option. Platforms map their native keys onto these names.
    super,
    shift,
    caps_lock,
    alt,
    control,
    right_super,
    right_shift,
    right_alt,
    right_control,

    // Arrows
    left,
    right,
    down,
    up,

    // Function keys
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    f13,
    f14,
    f15,
    f16,
    f17,
    f18,
    f19,
    f20,

    // Navigation
    home,
    end,
    page_up,
    page_down,

    /// Key the backend could not recognize.
    unknown,
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
    key: KeyTag,
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

// Platform decoding tests live at each platform boundary: macOS maps kVK_*
// codes in `platform/macos/appkit.zig`, Linux maps evdev codes in
// `platform/linux/input.zig`, and Web maps DOM codes in `platform/web/key_events.zig`.
// KeyTag itself is a pure name set with no numeric identity, so it has no
// decoder to test here.
