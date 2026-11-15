//! Keyboard Event Ring Buffer
//! Zero-copy shared memory between JS and Zig
//!
//! This implements a lock-free SPSC (Single-Producer Single-Consumer) ring buffer
//! for keyboard events. JavaScript writes to the buffer, Zig reads from it.
//! No JS↔WASM calls needed during frame processing.

const input = @import("../../input/events.zig");
const event_ring = @import("event_ring.zig");

/// Packed key event - exactly 8 bytes
/// Layout matches JavaScript writer:
///   byte 0: event_type
///   bytes 1-2: key_code (little-endian u16)
///   byte 3: modifiers
///   byte 4: flags
///   bytes 5-7: reserved
pub const RawKeyEvent = packed struct(u64) {
    event_type: EventType, // 8 bits
    key_code: u16, // 16 bits
    modifiers: Modifiers, // 8 bits
    flags: Flags, // 8 bits
    _reserved: u24 = 0, // 24 bits

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
        is_composing: bool = false, // Inside IME composition
        _pad: u6 = 0,
    };
};

comptime {
    if (@sizeOf(RawKeyEvent) != 8) @compileError("RawKeyEvent must be exactly 8 bytes");
}

// Global instance
/// Events reserved by the core host from `events.queue_count_max`.
pub var g_key_ring: event_ring.EventRing(RawKeyEvent) = .{};

// Export pointer for JS
fn getKeyRingPtr() callconv(.c) [*]u8 {
    return @ptrCast(&g_key_ring);
}

comptime {
    @export(&getKeyRingPtr, .{ .name = "getKeyRingPtr" });
}

// =========================================================
// Event Processing
// =========================================================

const InputEvent = input.InputEvent;
const KeyEvent = input.KeyEvent;
const KeyCode = input.KeyCode;

/// Convert raw key event to InputEvent
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
