//! A generic, fixed-capacity array that never allocates after initialization.

const std = @import("std");

pub fn FixedArray(comptime T: type, comptime capacity: u32) type {
    return struct {
        buffer: [capacity]T = undefined,
        len: usize = 0,

        const Self = @This();

        pub fn appendAssumeCapacity(self: *Self, item: T) void {
            std.debug.assert(self.len < capacity);
            self.buffer[self.len] = item;
            self.len += 1;
        }

        /// Read the item at `index`.
        pub fn get(self: *const Self, index: usize) T {
            std.debug.assert(index < self.len);
            return self.buffer[index];
        }

        pub fn slice(self: *Self) []T {
            return self.buffer[0..self.len];
        }

        pub fn constSlice(self: *const Self) []const T {
            return self.buffer[0..self.len];
        }

        pub fn orderedRemove(self: *Self, index: usize) T {
            std.debug.assert(index < self.len);
            std.debug.assert(self.len > 0);
            const item = self.buffer[index];
            const tail_len = self.len - 1 - index;
            if (tail_len > 0) {
                std.mem.copyForwards(T, self.buffer[index..][0..tail_len], self.buffer[index + 1 ..][0..tail_len]);
            }
            self.len -= 1;
            return item;
        }

        pub fn swapRemove(self: *Self, index: usize) T {
            std.debug.assert(index < self.len);
            std.debug.assert(self.len > 0);
            const item = self.buffer[index];
            self.len -= 1;
            if (index < self.len) {
                self.buffer[index] = self.buffer[self.len];
            }
            return item;
        }

        pub fn pop(self: *Self) T {
            std.debug.assert(self.len > 0);
            self.len -= 1;
            return self.buffer[self.len];
        }

        /// Reset length to zero without touching buffer contents.
        pub fn clear(self: *Self) void {
            self.len = 0;
        }
    };
}

test "appendAssumeCapacity and get" {
    var arr: FixedArray(u32, 4) = .{};
    std.debug.assert(arr.len == 0);

    arr.appendAssumeCapacity(10);
    arr.appendAssumeCapacity(20);

    try std.testing.expectEqual(@as(u32, 10), arr.get(0));
    try std.testing.expectEqual(@as(u32, 20), arr.get(1));
    try std.testing.expectEqual(@as(usize, 2), arr.len);
}

test "slice and constSlice" {
    var arr: FixedArray(u8, 8) = .{};
    arr.appendAssumeCapacity('a');
    arr.appendAssumeCapacity('b');
    arr.appendAssumeCapacity('c');

    const s = arr.slice();
    try std.testing.expectEqual(@as(usize, 3), s.len);
    try std.testing.expectEqual(@as(u8, 'b'), s[1]);

    s[0] = 'z';
    try std.testing.expectEqual(@as(u8, 'z'), arr.get(0));

    const cs = arr.constSlice();
    try std.testing.expectEqual(@as(usize, 3), cs.len);
}

test "orderedRemove preserves order" {
    var arr: FixedArray(i32, 8) = .{};
    arr.appendAssumeCapacity(1);
    arr.appendAssumeCapacity(2);
    arr.appendAssumeCapacity(3);
    arr.appendAssumeCapacity(4);

    const removed = arr.orderedRemove(1); // Remove '2'
    try std.testing.expectEqual(@as(i32, 2), removed);
    try std.testing.expectEqual(@as(usize, 3), arr.len);
    try std.testing.expectEqual(@as(i32, 1), arr.get(0));
    try std.testing.expectEqual(@as(i32, 3), arr.get(1));
    try std.testing.expectEqual(@as(i32, 4), arr.get(2));
}

test "orderedRemove last element" {
    var arr: FixedArray(u32, 4) = .{};
    arr.appendAssumeCapacity(42);

    const removed = arr.orderedRemove(0);
    try std.testing.expectEqual(@as(u32, 42), removed);
    try std.testing.expectEqual(@as(usize, 0), arr.len);
}

test "swapRemove is O(1) and does not preserve order" {
    var arr: FixedArray(i32, 8) = .{};
    arr.appendAssumeCapacity(10);
    arr.appendAssumeCapacity(20);
    arr.appendAssumeCapacity(30);
    arr.appendAssumeCapacity(40);

    // Remove index 1 (value 20).
    const removed = arr.swapRemove(1);
    try std.testing.expectEqual(@as(i32, 20), removed);
    try std.testing.expectEqual(@as(usize, 3), arr.len);
    try std.testing.expectEqual(@as(i32, 10), arr.get(0));
    try std.testing.expectEqual(@as(i32, 40), arr.get(1));
    try std.testing.expectEqual(@as(i32, 30), arr.get(2));
}

test "swapRemove last element" {
    var arr: FixedArray(u32, 4) = .{};
    arr.appendAssumeCapacity(7);
    arr.appendAssumeCapacity(8);

    const removed = arr.swapRemove(1);
    try std.testing.expectEqual(@as(u32, 8), removed);
    try std.testing.expectEqual(@as(usize, 1), arr.len);
    try std.testing.expectEqual(@as(u32, 7), arr.get(0));
}

test "pop returns last element" {
    var arr: FixedArray(u32, 4) = .{};
    arr.appendAssumeCapacity(1);
    arr.appendAssumeCapacity(2);
    arr.appendAssumeCapacity(3);

    try std.testing.expectEqual(@as(u32, 3), arr.pop());
    try std.testing.expectEqual(@as(usize, 2), arr.len);
    try std.testing.expectEqual(@as(u32, 2), arr.pop());
    try std.testing.expectEqual(@as(usize, 1), arr.len);
}

test "clear resets length to zero" {
    var arr: FixedArray(u8, 8) = .{};
    arr.appendAssumeCapacity('x');
    arr.appendAssumeCapacity('y');
    arr.appendAssumeCapacity('z');
    try std.testing.expectEqual(@as(usize, 3), arr.len);

    arr.clear();
    try std.testing.expectEqual(@as(usize, 0), arr.len);

    arr.appendAssumeCapacity('a');
    try std.testing.expectEqual(@as(u8, 'a'), arr.get(0));
}
