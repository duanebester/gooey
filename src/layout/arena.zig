//! Per-frame arena for layout calculations.
//!
//! Every layout allocation, text copies and wrapped lines, comes from one
//! buffer the engine reserved at initialization and resets at the start of
//! each frame. Exhausting it is an error the caller reports, so layout never
//! reaches a general-purpose allocator after initialization (CLAUDE.md §2).

const std = @import("std");

/// Per-frame arena over a reserved buffer.
pub const LayoutArena = struct {
    fixed: std.heap.FixedBufferAllocator,

    const Self = @This();

    /// Serve every allocation from `buffer`, which the caller reserved and
    /// keeps alive for the arena's lifetime.
    pub fn init(buffer: []u8) Self {
        std.debug.assert(buffer.len > 0);
        const arena: Self = .{ .fixed = std.heap.FixedBufferAllocator.init(buffer) };
        std.debug.assert(arena.fixed.end_index == 0);
        return arena;
    }

    /// Bytes served since the last reset.
    pub fn bytesUsed(self: *const Self) usize {
        std.debug.assert(self.fixed.end_index <= self.fixed.buffer.len);
        return self.fixed.end_index;
    }

    /// Get allocator for per-frame data.
    pub fn allocator(self: *Self) std.mem.Allocator {
        return self.fixed.allocator();
    }

    /// Reset for the next frame: O(1), the buffer is reused from its start.
    pub fn reset(self: *Self) void {
        self.fixed.reset();
        std.debug.assert(self.fixed.end_index == 0);
    }

    /// Allocate a slice for this frame.
    pub fn alloc(self: *Self, comptime T: type, n: usize) ![]T {
        return self.allocator().alloc(T, n);
    }

    /// Create a single item for this frame.
    pub fn create(self: *Self, comptime T: type) !*T {
        return self.allocator().create(T);
    }

    /// Duplicate a string for this frame.
    pub fn dupe(self: *Self, str: []const u8) ![]u8 {
        return self.allocator().dupe(u8, str);
    }
};

test "arena reset reuses the buffer and reports exhaustion" {
    // Goal: a frame's allocations fill the buffer exactly, one more byte fails
    // as an error rather than growing, and a reset makes the whole buffer
    // available again for the next frame.
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
