const input = @import("../../input/events.zig");
const event_ring = @import("event_ring.zig");

/// Layout matches the JavaScript writer.
pub const RawMouseEvent = extern struct {
    position_x: f64,
    position_y: f64,
    event_type: EventType,
    button: Button,
    click_count: u8,
    modifiers: Modifiers,
    _reserved: u32 = 0,

    pub const EventType = enum(u8) {
        mouse_down = 0,
        mouse_up = 1,
        mouse_moved = 2,
        mouse_dragged = 3,
        mouse_entered = 4,
        mouse_exited = 5,
        /// The page took the gesture away (`pointercancel`, a lost pointer
        /// capture with a button held, or the window losing focus).
        pointer_cancelled = 6,
    };

    pub const Button = enum(u8) {
        left = 0,
        right = 1,
        middle = 2,

        pub fn toInput(self: Button) input.MouseButton {
            return switch (self) {
                .left => .left,
                .right => .right,
                .middle => .middle,
            };
        }
    };

    pub const Modifiers = packed struct(u8) {
        shift: bool = false,
        ctrl: bool = false,
        alt: bool = false,
        cmd: bool = false,
        _pad: u4 = 0,

        pub fn toInput(self: Modifiers) input.Modifiers {
            return .{
                .shift = self.shift,
                .ctrl = self.ctrl,
                .alt = self.alt,
                .cmd = self.cmd,
            };
        }
    };
};

comptime {
    if (@sizeOf(RawMouseEvent) != 24) @compileError("RawMouseEvent must be exactly 24 bytes");
}

/// Events reserved by the core host from `events.queue_count_max`.
pub var g_mouse_ring: event_ring.EventRing(RawMouseEvent) = .{};

fn getMouseRingPtr() callconv(.c) [*]u8 {
    return @ptrCast(&g_mouse_ring);
}

comptime {
    @export(&getMouseRingPtr, .{ .name = "getMouseRingPtr" });
}

const InputEvent = input.InputEvent;
const MouseEvent = input.MouseEvent;

pub fn toInputEvent(raw: RawMouseEvent) InputEvent {
    const mouse_event = MouseEvent{
        .position = .{ .x = raw.position_x, .y = raw.position_y },
        .button = raw.button.toInput(),
        .click_count = raw.click_count,
        .modifiers = raw.modifiers.toInput(),
    };

    return switch (raw.event_type) {
        .mouse_down => .{ .mouse_down = mouse_event },
        .mouse_up => .{ .mouse_up = mouse_event },
        .mouse_moved => .{ .mouse_moved = mouse_event },
        .mouse_dragged => .{ .mouse_dragged = mouse_event },
        .mouse_entered => .{ .mouse_entered = mouse_event },
        .mouse_exited => .{ .mouse_exited = mouse_event },
        .pointer_cancelled => .pointer_cancelled,
    };
}
