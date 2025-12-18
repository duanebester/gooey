//! Text Input Buffer
//! Handles arbitrary UTF-8 text including emoji sequences
//!
//! This is a simple append buffer for text input from JavaScript.
//! Supports emoji, CJK, dead keys, IME composition - any valid UTF-8.

const input = @import("../../../core/input.zig");

pub const BUFFER_SIZE = 256; // Handles most input; long paste can chunk

/// Simple append buffer for text input
/// Note: On WASM this is single-threaded, but we use volatile reads
/// to ensure JS writes are visible.
pub const TextInputBuffer = extern struct {
    len: u32 align(4) = 0, // Current length (JS writes, Zig reads/clears)
    data: [BUFFER_SIZE]u8 = undefined,

    const Self = @This();

    /// Check if there's pending text
    pub fn hasText(self: *const volatile Self) bool {
        return self.len > 0;
    }

    /// Get pending text slice (valid until clear)
    pub fn getText(self: *volatile Self) []const u8 {
        const length = self.len;
        // Cast away volatile for the slice - data won't change mid-read in single-threaded WASM
        const non_volatile_self = @as(*Self, @volatileCast(self));
        return non_volatile_self.data[0..length];
    }

    /// Clear buffer after processing
    pub fn clear(self: *volatile Self) void {
        self.len = 0;
    }

    /// Space remaining in buffer
    pub fn remaining(self: *const volatile Self) u32 {
        return BUFFER_SIZE - self.len;
    }
};

comptime {
    if (@sizeOf(TextInputBuffer) != 4 + BUFFER_SIZE) @compileError("TextInputBuffer size mismatch");
}

// Global instance
pub var g_text_buffer: TextInputBuffer = .{};

// Export pointer for JS
fn getTextBufferPtr() callconv(.c) [*]u8 {
    return @ptrCast(&g_text_buffer);
}

comptime {
    @export(&getTextBufferPtr, .{ .name = "getTextBufferPtr" });
}

// =========================================================
// Text Input Processing
// =========================================================

const InputEvent = input.InputEvent;

/// Process pending text input
/// Returns true if text was processed
pub fn processTextInput(handler: *const fn (InputEvent) bool) bool {
    const buf = @as(*volatile TextInputBuffer, &g_text_buffer);
    if (!buf.hasText()) return false;

    const text = buf.getText();
    const event = InputEvent{
        .text_input = .{ .text = text },
    };

    _ = handler(event);
    buf.clear();

    return true;
}
