//! Input System
//!
//! Input events, keycodes, and action bindings.
//!
//! - `events` - InputEvent, KeyEvent, MouseEvent, KeyCode, Modifiers
//! - `actions` - Keymap, Keystroke, KeyBinding for declarative keybindings

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
// Actions (keybinding system)
// =============================================================================

pub const actions = @import("actions.zig");

pub const Keymap = actions.Keymap;
pub const Keystroke = actions.Keystroke;
pub const KeyBinding = actions.KeyBinding;
pub const ActionTypeId = actions.ActionTypeId;
pub const actionTypeId = actions.actionTypeId;

// =============================================================================
// Event Wrapper (capture/bubble phase support)
// =============================================================================

pub const event = @import("event.zig");
pub const Event = event.Event;
pub const EventPhase = event.EventPhase;
pub const EventResult = event.EventResult;

// =============================================================================
// Tests
// =============================================================================

test {
    std.testing.refAllDecls(@This());
}
