//! Per-frame arena allocator for layout calculations
//!
//! All layout data is allocated from this arena and reset at
//! the start of each frame. This provides O(1) cleanup and
//! excellent cache locality.

const std = @import("std");

/// Per-frame arena for layout calculations
pub const LayoutArena = struct {
    arena: std.heap.ArenaAllocator,

    const Self = @This();

    /// Initialize with a backing allocator (typically page_allocator or gpa)
    pub fn init(backing_allocator: std.mem.Allocator) Self {
        return .{
            .arena = std.heap.ArenaAllocator.init(backing_allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.arena.deinit();
    }

    /// Get allocator for per-frame data
    pub fn allocator(self: *Self) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// Reset for next frame - O(1), just resets internal pointers
    /// Call at the start of each frame before layout calculations
    pub fn reset(self: *Self) void {
        _ = self.arena.reset(.retain_capacity);
    }

    /// Get the backing allocator for persistent data
    pub fn backing(self: *Self) std.mem.Allocator {
        return self.arena.child_allocator;
    }

    /// Allocate a slice for this frame
    pub fn alloc(self: *Self, comptime T: type, n: usize) ![]T {
        return self.arena.allocator().alloc(T, n);
    }

    /// Create a single item for this frame
    pub fn create(self: *Self, comptime T: type) !*T {
        return self.arena.allocator().create(T);
    }

    /// Duplicate a string for this frame
    pub fn dupe(self: *Self, str: []const u8) ![]u8 {
        return self.arena.allocator().dupe(u8, str);
    }
};

test "arena reset" {
    var arena = LayoutArena.init(std.testing.allocator);
    defer arena.deinit();

    // Simulate multiple frames
    for (0..10) |_| {
        const data = try arena.alloc(u32, 1000);
        _ = data;
        arena.reset();
    }
}
