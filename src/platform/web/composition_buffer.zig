//! IME Composition Buffer
//! Handles preedit/marked text during IME composition
//!
//! This buffer stores the composing text that appears with underlines
//! before the user commits their input (e.g., typing Chinese pinyin). It
//! holds `ResourceLimits.text.preedit_bytes_max` bytes, reserved by the core
//! host at init; JavaScript cuts a longer preedit on a codepoint boundary and
//! logs the field (decision R2).
//!
//! Exported layout, read by JavaScript after `init`: byte 0 `len`, byte 4
//! `active`, byte 5 `pending`, byte 8 `capacity`, byte 12 the address of the
//! bytes.

const std = @import("std");

const assert = std.debug.assert;

/// Composition state from IME
pub const CompositionBuffer = extern struct {
    /// Current length of composing text
    len: u32 align(4) = 0,
    /// Whether composition is active
    active: u8 = 0,
    /// One-shot event flag, including the empty event emitted on end/cancel.
    pending: u8 = 0,
    _pad: [2]u8 = .{ 0, 0 },
    capacity: u32 = 0,
    /// The composing/preedit text
    data: [*]u8 = undefined,

    const Self = @This();

    comptime {
        if (@sizeOf(usize) == 4) assert(@sizeOf(Self) == 16);
    }

    /// Reserve `capacity` bytes, during initialization only.
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

// Global instance
pub var g_composition_buffer: CompositionBuffer = .{};

// Export pointer for JS
fn getCompositionBufferPtr() callconv(.c) [*]u8 {
    return @ptrCast(&g_composition_buffer);
}

comptime {
    @export(&getCompositionBufferPtr, .{ .name = "getCompositionBufferPtr" });
}
