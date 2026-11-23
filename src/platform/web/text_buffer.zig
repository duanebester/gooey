const std = @import("std");

const assert = std.debug.assert;

pub const TextInputBuffer = extern struct {
    len: u32 align(4) = 0,
    capacity: u32 = 0,
    data: [*]u8 = undefined,

    const Self = @This();

    comptime {
        if (@sizeOf(usize) == 4) assert(@sizeOf(Self) == 12);
    }

    pub fn reserve(self: *Self, gpa: std.mem.Allocator, capacity: u32) !void {
        assert(self.capacity == 0);
        assert(capacity > 0);
        const data = try gpa.alloc(u8, capacity);
        self.data = data.ptr;
        self.len = 0;
        self.capacity = capacity;
        assert(self.capacity == data.len);
    }

    pub fn hasText(self: *const volatile Self) bool {
        assert(self.len <= self.capacity);
        return self.len > 0;
    }

    pub fn getText(self: *volatile Self) []const u8 {
        const length = self.len;
        assert(length <= self.capacity);
        const non_volatile_self = @as(*Self, @volatileCast(self));
        return non_volatile_self.data[0..length];
    }

    pub fn clear(self: *volatile Self) void {
        self.len = 0;
    }
};

pub var g_text_buffer: TextInputBuffer = .{};

fn getTextBufferPtr() callconv(.c) [*]u8 {
    return @ptrCast(&g_text_buffer);
}

comptime {
    @export(&getTextBufferPtr, .{ .name = "getTextBufferPtr" });
}
