//! Mouse Event Ring Buffer
//! Zero-copy shared memory between JS and Zig
//!
//! This implements a lock-free SPSC (Single-Producer Single-Consumer) ring buffer
//! for mouse events. JavaScript writes to the buffer, Zig reads from it.
//! No JS↔WASM calls needed during frame processing.
//!
//! Features:
//! - Double/triple click detection (JS tracks timing)
//! - Left/right/middle button support
//! - Keyboard modifiers on mouse events
//! - Drag events (mouse_moved vs mouse_dragged)

const input = @import("../../input/events.zig");

/// Packed mouse event - exactly 24 bytes
/// Layout matches JavaScript writer:
///   bytes 0-7: position_x (f64, little-endian)
///   bytes 8-15: position_y (f64, little-endian)
///   byte 16: event_type
///   byte 17: button
///   byte 18: click_count
///   byte 19: modifiers
///   bytes 20-23: reserved
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

pub const RING_SIZE = 32; // Power of 2, handles rapid clicks

/// Lock-free Single-Producer Single-Consumer ring buffer
pub const MouseEventRing = extern struct {
    write_head: u32 align(4) = 0, // JS increments
    read_head: u32 align(4) = 0, // Zig increments
    events: [RING_SIZE]RawMouseEvent = undefined,

    const Self = @This();

    pub fn hasEvents(self: *volatile Self) bool {
        return self.write_head != self.read_head;
    }

    pub fn pop(self: *volatile Self) ?RawMouseEvent {
        const write = self.write_head;
        const read = self.read_head;

        if (read == write) return null;

        const event = self.events[read & (RING_SIZE - 1)];
        self.read_head = read +% 1;
        return event;
    }

    pub fn count(self: *const volatile Self) u32 {
        return self.write_head -% self.read_head;
    }
};

comptime {
    // Header (8 bytes) + events (32 * 24 = 768 bytes) = 776 bytes
    if (@sizeOf(MouseEventRing) != 8 + RING_SIZE * 24) @compileError("MouseEventRing size mismatch");
}

// Global instance
pub var g_mouse_ring: MouseEventRing = .{};

// Export pointer for JS
fn getMouseRingPtr() callconv(.c) [*]u8 {
    return @ptrCast(&g_mouse_ring);
}

comptime {
    @export(&getMouseRingPtr, .{ .name = "getMouseRingPtr" });
}

const InputEvent = input.InputEvent;
const MouseEvent = input.MouseEvent;

/// Convert raw mouse event to InputEvent
fn toInputEvent(raw: RawMouseEvent) InputEvent {
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
    };
}

/// Process all pending mouse events
/// Returns number of events processed
pub fn processEvents(handler: *const fn (InputEvent) bool) u32 {
    var processed: u32 = 0;

    while (@as(*volatile MouseEventRing, &g_mouse_ring).pop()) |raw| {
        const event = toInputEvent(raw);
        _ = handler(event);
        processed += 1;
    }

    return processed;
}
