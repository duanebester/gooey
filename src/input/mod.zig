const std = @import("std");

pub const events = @import("events.zig");

pub const InputEvent = events.InputEvent;
pub const MouseEvent = events.MouseEvent;
pub const MouseButton = events.MouseButton;
pub const ScrollEvent = events.ScrollEvent;
pub const KeyEvent = events.KeyEvent;
pub const KeyCode = events.KeyCode;
pub const Modifiers = events.Modifiers;
pub const TextInputEvent = events.TextInputEvent;
pub const CompositionEvent = events.CompositionEvent;
pub const FocusLostEvent = events.FocusLostEvent;
pub const HeldKeys = events.HeldKeys;
pub const held_key_count_max = events.held_key_count_max;

pub const Keystroke = @import("keystroke.zig").Keystroke;

test {
    std.testing.refAllDecls(@This());
}
