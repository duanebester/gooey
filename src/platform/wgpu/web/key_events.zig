//! Keyboard Event Ring Buffer
//! Zero-copy shared memory between JS and Zig
//!
//! This implements a lock-free SPSC (Single-Producer Single-Consumer) ring buffer
//! for keyboard events. JavaScript writes to the buffer, Zig reads from it.
//! No JS↔WASM calls needed during frame processing.

const input = @import("../../../core/input.zig");

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

pub const RING_SIZE = 32; // Power of 2, handles burst typing

/// Lock-free Single-Producer Single-Consumer ring buffer
/// Note: On WASM this is single-threaded, but we use volatile reads
/// to ensure JS writes are visible.
pub const KeyEventRing = extern struct {
    write_head: u32 align(4) = 0, // JS increments
    read_head: u32 align(4) = 0, // Zig increments
    events: [RING_SIZE]RawKeyEvent = undefined,

    const Self = @This();

    /// Check if buffer has events
    pub fn hasEvents(self: *volatile Self) bool {
        return self.write_head != self.read_head;
    }

    /// Pop next event (returns null if empty)
    pub fn pop(self: *volatile Self) ?RawKeyEvent {
        const write = self.write_head;
        const read = self.read_head;

        if (read == write) return null;

        const event = self.events[read & (RING_SIZE - 1)];
        self.read_head = read +% 1;
        return event;
    }

    /// Number of pending events
    pub fn count(self: *const volatile Self) u32 {
        return self.write_head -% self.read_head;
    }
};

comptime {
    // Header (8 bytes) + events (32 * 8 = 256 bytes) = 264 bytes
    if (@sizeOf(KeyEventRing) != 8 + RING_SIZE * 8) @compileError("KeyEventRing size mismatch");
}

// Global instance
pub var g_key_ring: KeyEventRing = .{};

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
fn toInputEvent(raw: RawKeyEvent) InputEvent {
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

/// Process all pending key events
/// Returns number of events processed
pub fn processEvents(handler: *const fn (InputEvent) bool) u32 {
    var processed: u32 = 0;

    while (@as(*volatile KeyEventRing, &g_key_ring).pop()) |raw| {
        const event = toInputEvent(raw);
        _ = handler(event);
        processed += 1;
    }

    return processed;
}
