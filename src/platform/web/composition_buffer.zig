//! IME composition buffer: JavaScript writes the preedit it cuts to
//! `ResourceLimits.text.preedit_bytes_max` on a codepoint boundary (a longer
//! preedit is logged), reserved by the core host at init.
//!
//! Exported layout, read by JavaScript after `init`: byte 0 `len`, byte 4
//! `active`, byte 5 `pending`, byte 8 `capacity`, byte 12 the address of the
//! bytes.

const std = @import("std");

const assert = std.debug.assert;

pub const CompositionBuffer = extern struct {
    len: u32 align(4) = 0,
    active: u8 = 0,
    /// One-shot event flag, including the empty event emitted on end/cancel.
    pending: u8 = 0,
    _pad: [2]u8 = .{ 0, 0 },
    capacity: u32 = 0,
    data: [*]u8 = undefined,

    const Self = @This();

    comptime {
        if (@sizeOf(usize) == 4) assert(@sizeOf(Self) == 16);
    }

    /// Reserve `capacity` bytes; initialization only.
    pub fn reserve(self: *Self, gpa: std.mem.Allocator, capacity: u32) !void {
        assert(self.capacity == 0);
        assert(capacity > 0);
        const data = try gpa.alloc(u8, capacity);
        self.data = data.ptr;
        self.len = 0;
        self.capacity = capacity;
        assert(self.capacity == data.len);
    }

    pub fn hasPending(self: *const volatile Self) bool {
        assert(self.len <= self.capacity);
        return self.pending != 0;
    }

    pub fn getText(self: *volatile Self) []const u8 {
        const length = self.len;
        assert(length <= self.capacity);
        const non_volatile = @as(*Self, @volatileCast(self));
        return non_volatile.data[0..length];
    }
};

pub var g_composition_buffer: CompositionBuffer = .{};

fn getCompositionBufferPtr() callconv(.c) [*]u8 {
    return @ptrCast(&g_composition_buffer);
}

comptime {
    @export(&getCompositionBufferPtr, .{ .name = "getCompositionBufferPtr" });
}
