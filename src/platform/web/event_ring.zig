//! SPSC event ring shared with JavaScript, which writes events and advances
//! `write_head`; the core host reads and advances `read_head`. The browser
//! runs both on one thread, so volatile reads are enough to see the writes.
//!
//! Header layout JavaScript reads once after `init`: byte 0 `write_head`,
//! byte 4 `read_head`, byte 8 `capacity` (a power of two), byte 12 the
//! address of `events`. Events are reserved during initialization from
//! `ResourceLimits.events.queue_count_max`, so one frame's worth of input
//! always fits; JavaScript drops an event that finds the ring full.

const std = @import("std");

const assert = std.debug.assert;

pub fn EventRing(comptime Raw: type) type {
    return extern struct {
        write_head: u32 align(4) = 0,
        read_head: u32 align(4) = 0,
        /// Events in `events`, a power of two; 0 until `reserve`.
        capacity: u32 = 0,
        events: [*]Raw = undefined,

        const Self = @This();

        comptime {
            // JavaScript reads the header as four `u32` words on wasm32.
            if (@sizeOf(usize) == 4) assert(@sizeOf(Self) == 16);
        }

        /// Reserve `capacity` events; initialization only.
        pub fn reserve(self: *Self, gpa: std.mem.Allocator, capacity: u32) !void {
            assert(self.capacity == 0);
            assert(std.math.isPowerOfTwo(capacity));
            const events = try gpa.alloc(Raw, capacity);
            self.events = events.ptr;
            self.write_head = 0;
            self.read_head = 0;
            self.capacity = capacity;
            assert(self.capacity == events.len);
        }

        pub fn pop(self: *volatile Self) ?Raw {
            const write = self.write_head;
            const read = self.read_head;
            const capacity = self.capacity;
            assert(write -% read <= capacity);
            if (read == write) return null;
            const event = self.events[read & (capacity - 1)];
            self.read_head = read +% 1;
            return event;
        }
    };
}
