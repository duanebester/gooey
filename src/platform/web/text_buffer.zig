//! Append buffer for text input from JavaScript: typed characters, IME
//! commits and pastes. It holds `ResourceLimits.events.text_bytes_max`
//! bytes, reserved by the core host at init, so a chunk always fits the core
//! queue's text when the queue is empty; JavaScript keeps the longest prefix
//! that fits, cut on a codepoint boundary.
//!
//! Exported layout, read by JavaScript after `init`: byte 0 `len`, byte 4
//! `capacity`, byte 8 the address of the bytes.

const std = @import("std");

const assert = std.debug.assert;

/// Single-threaded on WASM, but volatile keeps JavaScript's writes visible.
pub const TextInputBuffer = extern struct {
    len: u32 align(4) = 0, // JS writes, Zig reads/clears
    capacity: u32 = 0,
    data: [*]u8 = undefined,

    const Self = @This();

    comptime {
        if (@sizeOf(usize) == 4) assert(@sizeOf(Self) == 12);
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

    pub fn hasText(self: *const volatile Self) bool {
        assert(self.len <= self.capacity);
        return self.len > 0;
    }

    /// Valid until `clear`.
    pub fn getText(self: *volatile Self) []const u8 {
        const length = self.len;
        assert(length <= self.capacity);
        // Cast away volatile: data won't change mid-read in single-threaded WASM.
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
