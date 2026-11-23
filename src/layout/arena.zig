const std = @import("std");

pub const LayoutArena = struct {
    fixed: std.heap.FixedBufferAllocator,

    const Self = @This();

    pub fn init(buffer: []u8) Self {
        std.debug.assert(buffer.len > 0);
        const arena: Self = .{ .fixed = std.heap.FixedBufferAllocator.init(buffer) };
        std.debug.assert(arena.fixed.end_index == 0);
        return arena;
    }

    pub fn bytesUsed(self: *const Self) usize {
        std.debug.assert(self.fixed.end_index <= self.fixed.buffer.len);
        return self.fixed.end_index;
    }

    pub fn allocator(self: *Self) std.mem.Allocator {
        return self.fixed.allocator();
    }

    pub fn reset(self: *Self) void {
        self.fixed.reset();
        std.debug.assert(self.fixed.end_index == 0);
    }

    pub fn alloc(self: *Self, comptime T: type, n: usize) ![]T {
        return self.allocator().alloc(T, n);
    }

    pub fn create(self: *Self, comptime T: type) !*T {
        return self.allocator().create(T);
    }

    pub fn dupe(self: *Self, str: []const u8) ![]u8 {
        return self.allocator().dupe(u8, str);
    }
};

test "arena reset reuses the buffer and reports exhaustion" {
    var buffer: [4096]u8 = undefined;
    var arena = LayoutArena.init(&buffer);
    for (0..10) |_| {
        _ = try arena.alloc(u8, buffer.len);
        try std.testing.expectEqual(buffer.len, arena.bytesUsed());
        try std.testing.expectError(error.OutOfMemory, arena.alloc(u8, 1));
        arena.reset();
        try std.testing.expectEqual(@as(usize, 0), arena.bytesUsed());
    }
}
