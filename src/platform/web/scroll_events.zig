//! Scroll Event Ring Buffer
//! Zero-copy shared memory between JS and Zig
//!
//! This implements a lock-free SPSC (Single-Producer Single-Consumer) ring buffer
//! for scroll/wheel events. JavaScript writes to the buffer, Zig reads from it.
//! No JS↔WASM calls needed during frame processing.

const input = @import("../../input/events.zig");
const geometry = @import("../../core/geometry.zig");

/// Packed scroll event - exactly 24 bytes
/// Layout matches JavaScript writer:
///   bytes 0-7: position_x (f64, little-endian)
///   bytes 8-15: position_y (f64, little-endian)
///   bytes 16-19: delta_x (f32, little-endian)
///   bytes 20-23: delta_y (f32, little-endian)
pub const RawScrollEvent = extern struct {
    position_x: f64,
    position_y: f64,
    delta_x: f32,
    delta_y: f32,
};

comptime {
    if (@sizeOf(RawScrollEvent) != 24) @compileError("RawScrollEvent must be exactly 24 bytes");
}

pub const RING_SIZE = 16; // Power of 2, enough for scroll events

/// Lock-free Single-Producer Single-Consumer ring buffer
pub const ScrollEventRing = extern struct {
    write_head: u32 align(4) = 0, // JS increments
    read_head: u32 align(4) = 0, // Zig increments
    events: [RING_SIZE]RawScrollEvent = undefined,

    const Self = @This();

    pub fn hasEvents(self: *volatile Self) bool {
        return self.write_head != self.read_head;
    }

    pub fn pop(self: *volatile Self) ?RawScrollEvent {
        const write = self.write_head;
        const read = self.read_head;

        if (read == write) return null;

        const event = self.events[read & (RING_SIZE - 1)];
        self.read_head = read +% 1;
        return event;
    }
};

comptime {
    // Header (8 bytes) + events (16 * 24 = 384 bytes) = 392 bytes
    if (@sizeOf(ScrollEventRing) != 8 + RING_SIZE * 24) @compileError("ScrollEventRing size mismatch");
}

// Global instance
pub var g_scroll_ring: ScrollEventRing = .{};

// Export pointer for JS
fn getScrollRingPtr() callconv(.c) [*]u8 {
    return @ptrCast(&g_scroll_ring);
}

comptime {
    @export(&getScrollRingPtr, .{ .name = "getScrollRingPtr" });
}

const InputEvent = input.InputEvent;

/// Convert raw scroll event to InputEvent
fn toInputEvent(raw: RawScrollEvent) InputEvent {
    return .{
        .scroll = .{
            .position = .{ .x = raw.position_x, .y = raw.position_y },
            .delta = .{ .x = raw.delta_x, .y = raw.delta_y },
            .modifiers = .{},
        },
    };
}

/// Process all pending scroll events
pub fn processEvents(handler: *const fn (InputEvent) bool) u32 {
    var processed: u32 = 0;

    while (@as(*volatile ScrollEventRing, &g_scroll_ring).pop()) |raw| {
        const event = toInputEvent(raw);
        _ = handler(event);
        processed += 1;
    }

    return processed;
}
