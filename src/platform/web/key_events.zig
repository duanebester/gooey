const input = @import("../../input/events.zig");
const event_ring = @import("event_ring.zig");

/// Layout matches the JavaScript writer.
pub const RawKeyEvent = packed struct(u64) {
    event_type: EventType,
    key_code: u16,
    modifiers: Modifiers,
    flags: Flags,
    _reserved: u24 = 0,

    pub const EventType = enum(u8) {
        key_down = 0,
        key_up = 1,
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

    pub const Flags = packed struct(u8) {
        is_repeat: bool = false,
        is_composing: bool = false,
        _pad: u6 = 0,
    };
};

comptime {
    if (@sizeOf(RawKeyEvent) != 8) @compileError("RawKeyEvent must be exactly 8 bytes");
}

/// Events reserved by the core host from `events.queue_count_max`.
pub var g_key_ring: event_ring.EventRing(RawKeyEvent) = .{};

fn getKeyRingPtr() callconv(.c) [*]u8 {
    return @ptrCast(&g_key_ring);
}

comptime {
    @export(&getKeyRingPtr, .{ .name = "getKeyRingPtr" });
}

const InputEvent = input.InputEvent;
const KeyEvent = input.KeyEvent;
const KeyCode = input.KeyCode;

pub fn toInputEvent(raw: RawKeyEvent) InputEvent {
    const key_event = KeyEvent{
        .key = KeyCode.from(raw.key_code),
        .modifiers = raw.modifiers.toInput(),
        .characters = null, // Text comes via TextInputBuffer
        .characters_ignoring_modifiers = null,
        .is_repeat = raw.flags.is_repeat,
    };

    return switch (raw.event_type) {
        .key_down => .{ .key_down = key_event },
        .key_up => .{ .key_up = key_event },
    };
}
