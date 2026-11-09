//! IME Composition Buffer
//! Handles preedit/marked text during IME composition
//!
//! This buffer stores the composing text that appears with underlines
//! before the user commits their input (e.g., typing Chinese pinyin).

pub const BUFFER_SIZE = 256;

/// Composition state from IME
pub const CompositionBuffer = extern struct {
    /// Current length of composing text
    len: u32 align(4) = 0,
    /// Whether composition is active
    active: u8 = 0,
    /// One-shot event flag, including the empty event emitted on end/cancel.
    pending: u8 = 0,
    _pad: [2]u8 = .{ 0, 0 },
    /// The composing/preedit text
    data: [BUFFER_SIZE]u8 = undefined,

    const Self = @This();

    pub fn hasText(self: *const volatile Self) bool {
        return self.len > 0;
    }

    pub fn hasPending(self: *const volatile Self) bool {
        return self.pending != 0;
    }

    pub fn getText(self: *volatile Self) []const u8 {
        const length = self.len;
        const non_volatile = @as(*Self, @volatileCast(self));
        return non_volatile.data[0..length];
    }

    pub fn clear(self: *volatile Self) void {
        self.len = 0;
        self.active = 0;
        self.pending = 0;
    }
};

comptime {
    if (@sizeOf(CompositionBuffer) != 8 + BUFFER_SIZE) @compileError("CompositionBuffer size mismatch");
}

// Global instance
pub var g_composition_buffer: CompositionBuffer = .{};

// Export pointer for JS
fn getCompositionBufferPtr() callconv(.c) [*]u8 {
    return @ptrCast(&g_composition_buffer);
}

comptime {
    @export(&getCompositionBufferPtr, .{ .name = "getCompositionBufferPtr" });
}
