const input = @import("../../input/events.zig");
const event_ring = @import("event_ring.zig");
const geometry = @import("../../geometry/geometry.zig");

/// Layout matches the JavaScript writer.
pub const RawScrollEvent = extern struct {
    position_x: f64,
    position_y: f64,
    delta_x: f32,
    delta_y: f32,
};

comptime {
    if (@sizeOf(RawScrollEvent) != 24) @compileError("RawScrollEvent must be exactly 24 bytes");
}

/// Events reserved by the core host from `events.queue_count_max`.
pub var g_scroll_ring: event_ring.EventRing(RawScrollEvent) = .{};

fn getScrollRingPtr() callconv(.c) [*]u8 {
    return @ptrCast(&g_scroll_ring);
}

comptime {
    @export(&getScrollRingPtr, .{ .name = "getScrollRingPtr" });
}

const InputEvent = input.InputEvent;

pub fn toInputEvent(raw: RawScrollEvent) InputEvent {
    return .{
        .scroll = .{
            .position = .{ .x = raw.position_x, .y = raw.position_y },
            .delta = .{ .x = raw.delta_x, .y = raw.delta_y },
            .modifiers = .{},
        },
    };
}
