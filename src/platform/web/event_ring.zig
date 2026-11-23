const std = @import("std");

const assert = std.debug.assert;

pub fn EventRing(comptime Raw: type) type {
    return extern struct {
        write_head: u32 align(4) = 0,
        read_head: u32 align(4) = 0,
        capacity: u32 = 0,
        events: [*]Raw = undefined,

        const Self = @This();

        comptime {
            if (@sizeOf(usize) == 4) assert(@sizeOf(Self) == 16);
        }

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
