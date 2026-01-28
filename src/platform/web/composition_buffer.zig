//! IME Composition Buffer
//! Handles preedit/marked text during IME composition
//!
//! This buffer stores the composing text that appears with underlines
//! before the user commits their input (e.g., typing Chinese pinyin).

const input = @import("../../input/events.zig");

pub const BUFFER_SIZE = 256;

/// Composition state from IME
pub const CompositionBuffer = extern struct {
    /// Current length of composing text
    len: u32 align(4) = 0,
    /// Whether composition is active
    active: u8 = 0,
    _pad: [3]u8 = .{ 0, 0, 0 },
    /// The composing/preedit text
    data: [BUFFER_SIZE]u8 = undefined,

    const Self = @This();

    pub fn isActive(self: *const volatile Self) bool {
        return self.active != 0;
    }

    pub fn hasText(self: *const volatile Self) bool {
        return self.len > 0;
    }

    pub fn getText(self: *volatile Self) []const u8 {
        const length = self.len;
        const non_volatile = @as(*Self, @volatileCast(self));
        return non_volatile.data[0..length];
    }

    pub fn clear(self: *volatile Self) void {
        self.len = 0;
        self.active = 0;
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

const InputEvent = input.InputEvent;

/// Process pending composition events
pub fn processComposition(handler: *const fn (InputEvent) bool) bool {
    const buf = @as(*volatile CompositionBuffer, &g_composition_buffer);
    if (!buf.isActive()) return false;

    const text = buf.getText();
    const event = InputEvent{ .composition = .{ .text = text } };
    _ = handler(event);

    return true;
}
