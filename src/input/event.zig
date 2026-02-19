//! Event wrapper with capture/bubble phase support
//!
//! Events flow through the element tree in two phases:
//! 1. Capture: root -> target (top-down)
//! 2. Bubble: target -> root (bottom-up)
//!
//! This matches the DOM event model and allows parent elements
//! to intercept events before children see them (capture) or
//! handle events that children didn't consume (bubble).

const std = @import("std");
const input = @import("events.zig");
const element_id_mod = @import("../core/element_id.zig");

pub const ElementId = element_id_mod.ElementId;

/// Result of handling an event
pub const EventResult = enum {
    /// Event was not handled, continue propagation
    ignored,
    /// Event was handled, but allow propagation to continue
    handled,
    /// Event was handled, stop all propagation
    stop,
};

/// Phase of event propagation
pub const EventPhase = enum {
    /// Event is traveling down from root to target
    capture,
    /// Event has reached the target element
    target,
    /// Event is traveling up from target to root
    bubble,
};

/// Wrapped event with propagation control
pub const Event = struct {
    /// The underlying input event
    inner: input.InputEvent,
    /// Current phase of propagation
    phase: EventPhase,
    /// The element that the event is targeted at (from hit test)
    target: ?ElementId,
    /// If true, event won't propagate to further elements
    propagation_stopped: bool = false,
    /// If true, default browser/OS behavior should be prevented
    default_prevented: bool = false,
    /// The element currently processing the event
    current_target: ?ElementId = null,

    const Self = @This();

    /// Create a new event wrapper
    pub fn init(inner: input.InputEvent, target: ?ElementId) Self {
        return .{
            .inner = inner,
            .phase = .capture,
            .target = target,
        };
    }

    /// Stop event from propagating to other elements
    pub fn stopPropagation(self: *Self) void {
        self.propagation_stopped = true;
    }

    /// Stop propagation and prevent default behavior
    pub fn stopImmediatePropagation(self: *Self) void {
        self.propagation_stopped = true;
        self.default_prevented = true;
    }

    /// Prevent the default action (e.g., text input on keypress)
    pub fn preventDefault(self: *Self) void {
        self.default_prevented = true;
    }

    /// Check if this is a mouse event
    pub fn isMouseEvent(self: *const Self) bool {
        return switch (self.inner) {
            .mouse_down, .mouse_up, .mouse_moved, .mouse_dragged, .mouse_entered, .mouse_exited => true,
            else => false,
        };
    }

    /// Check if this is a keyboard event
    pub fn isKeyboardEvent(self: *const Self) bool {
        return switch (self.inner) {
            .key_down, .key_up, .modifiers_changed => true,
            else => false,
        };
    }

    /// Get mouse position if this is a mouse event
    pub fn mousePosition(self: *const Self) ?struct { x: f64, y: f64 } {
        return switch (self.inner) {
            .mouse_down, .mouse_up, .mouse_moved, .mouse_dragged, .mouse_entered, .mouse_exited => |m| .{
                .x = m.position.x,
                .y = m.position.y,
            },
            else => null,
        };
    }
};

test "Event phases" {
    const mouse_event = input.InputEvent{ .mouse_down = .{
        .position = .{ .x = 100, .y = 200 },
        .button = .left,
        .click_count = 1,
        .modifiers = .{},
    } };

    var ev = Event.init(mouse_event, ElementId.named("test"));
    try std.testing.expectEqual(EventPhase.capture, ev.phase);
    try std.testing.expect(!ev.propagation_stopped);

    ev.stopPropagation();
    try std.testing.expect(ev.propagation_stopped);
}
