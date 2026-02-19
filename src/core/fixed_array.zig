//! Fixed-capacity array — static allocation container
//!
//! A generic, fixed-capacity array that never allocates after initialization.
//! Used throughout Gooey to avoid dynamic allocation during frame rendering
//! (per CLAUDE.md: "No dynamic allocation after initialization").
//!
//! Preferred over growing `ArrayList`s for render-time buffers like glyph
//! caches, command buffers, clip stacks, stroke outlines, and triangle indices.

const std = @import("std");

/// A fixed-capacity array that doesn't allocate after initialization.
/// Capacity is `u32` for explicit cross-platform sizing (per Rule #15).
pub fn FixedArray(comptime T: type, comptime capacity: u32) type {
    return struct {
        buffer: [capacity]T = undefined,
        len: usize = 0,

        const Self = @This();

        /// Append an item. Caller must ensure capacity is not exceeded.
        pub fn appendAssumeCapacity(self: *Self, item: T) void {
            std.debug.assert(self.len < capacity);
            self.buffer[self.len] = item;
            self.len += 1;
        }

        /// Read the item at `index`. Asserts in-bounds.
        pub fn get(self: *const Self, index: usize) T {
            std.debug.assert(index < self.len);
            return self.buffer[index];
        }

        /// Mutable slice over the populated region.
        pub fn slice(self: *Self) []T {
            return self.buffer[0..self.len];
        }

        /// Immutable slice over the populated region.
        pub fn constSlice(self: *const Self) []const T {
            return self.buffer[0..self.len];
        }

        /// Remove the element at `index`, shifting subsequent elements left.
        /// O(n) — preserves order. Returns the removed item. Asserts in-bounds.
        pub fn orderedRemove(self: *Self, index: usize) T {
            std.debug.assert(index < self.len);
            std.debug.assert(self.len > 0);
            const item = self.buffer[index];
            // Shift elements left to fill the gap.
            const len = self.len;
            for (index..len - 1) |i| {
                self.buffer[i] = self.buffer[i + 1];
            }
            self.len -= 1;
            return item;
        }

        /// Remove the element at `index` by swapping it with the last element.
        /// O(1) — does NOT preserve order. Returns the removed item.
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

        /// Remove and return the last element. Asserts non-empty.
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

// =============================================================================
// Tests
// =============================================================================

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

    // Mutate through slice.
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

    // Remove index 1 (value 20) — last element (40) takes its place.
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

    // Removing the last element is just a length decrement.
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

    // Buffer is reusable after clear.
    arr.appendAssumeCapacity('a');
    try std.testing.expectEqual(@as(u8, 'a'), arr.get(0));
}
