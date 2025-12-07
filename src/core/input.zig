const std = @import("std");
const geometry = @import("geometry.zig");
const appkit = @import("../platform/mac/appkit.zig");

pub const KeyCode = appkit.KeyCode;

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
