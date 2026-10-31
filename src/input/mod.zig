//! Input System
//!
//! Input events, keycodes, and keystrokes.
//!
//! - `events` - InputEvent, KeyEvent, MouseEvent, KeyCode, Modifiers
//! - `keystroke` - Keystroke, parsed from strings such as "cmd-shift-z"

const std = @import("std");

// =============================================================================
// Events (input primitives)
// =============================================================================

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

// =============================================================================
// Keystrokes (keymaps live in the core, `core/keymap.zig`)
// =============================================================================

pub const Keystroke = @import("keystroke.zig").Keystroke;

// =============================================================================
// Event propagation (capture/bubble phases)
// =============================================================================

pub const event = @import("event.zig");
pub const EventPhase = event.EventPhase;
pub const EventResult = event.EventResult;

// =============================================================================
// Tests
// =============================================================================

test {
    std.testing.refAllDecls(@This());
}
