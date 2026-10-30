//! Per-frame arena allocator for layout calculations
//!
//! All layout data is allocated from this arena and reset at
//! the start of each frame. This provides O(1) cleanup and
//! excellent cache locality.

const std = @import("std");

/// Per-frame arena for layout calculations
pub const LayoutArena = struct {
    arena: std.heap.ArenaAllocator,
    /// Reserved per-frame storage. When set, every allocation comes from it
    /// and exhausting it is an error the caller reports, so layout never
    /// reaches the backing allocator after initialization (CLAUDE.md §2).
    /// The 0.4.0 core sets it; the 0.3.1 runtime keeps the growing arena.
    fixed: ?std.heap.FixedBufferAllocator,

    const Self = @This();

    /// Initialize with a backing allocator (typically page_allocator or gpa)
    pub fn init(backing_allocator: std.mem.Allocator) Self {
        return .{
            .arena = std.heap.ArenaAllocator.init(backing_allocator),
            .fixed = null,
        };
    }

    pub fn deinit(self: *Self) void {
        self.arena.deinit();
    }

    /// Serve every later allocation from `buffer`, which the caller reserved
    /// and keeps alive until `deinit`.
    pub fn useFixedBuffer(self: *Self, buffer: []u8) void {
        std.debug.assert(buffer.len > 0);
        std.debug.assert(self.fixed == null);
        self.fixed = std.heap.FixedBufferAllocator.init(buffer);
    }

    /// Get allocator for per-frame data
    pub fn allocator(self: *Self) std.mem.Allocator {
        if (self.fixed) |*fixed| return fixed.allocator();
        return self.arena.allocator();
    }

    /// Reset for next frame - O(1), just resets internal pointers
    /// Call at the start of each frame before layout calculations
    pub fn reset(self: *Self) void {
        if (self.fixed) |*fixed| {
            fixed.reset();
            return;
        }
        _ = self.arena.reset(.retain_capacity);
    }

    /// Get the backing allocator for persistent data
    pub fn backing(self: *Self) std.mem.Allocator {
        return self.arena.child_allocator;
    }

    /// Allocate a slice for this frame
    pub fn alloc(self: *Self, comptime T: type, n: usize) ![]T {
        return self.allocator().alloc(T, n);
    }

    /// Create a single item for this frame
    pub fn create(self: *Self, comptime T: type) !*T {
        return self.allocator().create(T);
    }

    /// Duplicate a string for this frame
    pub fn dupe(self: *Self, str: []const u8) ![]u8 {
        return self.allocator().dupe(u8, str);
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
