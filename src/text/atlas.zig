//! Texture atlas with skyline bin packing for glyph storage
//!
//! Platform-agnostic - uses the "skyline bottom-left" algorithm which is
//! simple and efficient for many small, similarly-sized rectangles (glyphs).
//!
//! Uses fixed-capacity arrays for skyline nodes (no dynamic allocation after init).

const std = @import("std");

/// A region within the atlas
pub const Region = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,

    pub fn uv(self: Region, atlas_size: u32) struct { u0: f32, v0: f32, u1: f32, v1: f32 } {
        const size_f: f32 = @floatFromInt(atlas_size);
        return .{
            .u0 = @as(f32, @floatFromInt(self.x)) / size_f,
            .v0 = @as(f32, @floatFromInt(self.y)) / size_f,
            .u1 = @as(f32, @floatFromInt(self.x + self.width)) / size_f,
            .v1 = @as(f32, @floatFromInt(self.y + self.height)) / size_f,
        };
    }
};

/// Skyline node for bin packing
const SkylineNode = struct {
    x: u16,
    y: u16,
    width: u16,
};

/// Texture atlas format
pub const Format = enum {
    /// Single channel (grayscale text)
    grayscale,
    /// RGBA (color emoji, subpixel rendering)
    rgba,

    pub fn bytesPerPixel(self: Format) u8 {
        return switch (self) {
            .grayscale => 1,
            .rgba => 4,
        };
    }
};

/// Texture atlas for storing rendered glyphs
pub const Atlas = struct {
    allocator: std.mem.Allocator,
    /// Pixel data (CPU side)
    data: []u8,
    /// Atlas size (always square: size x size)
    size: u32,
    /// Pixel format
    format: Format,
    /// Skyline nodes for bin packing (fixed capacity)
    nodes: [MAX_SKYLINE_NODES]SkylineNode,
    /// Number of active skyline nodes
    node_count: u16,
    /// Generation counter (incremented on changes)
    generation: u32,
    /// Padding between glyphs (prevents texture bleeding)
    padding: u8,

    const Self = @This();

    /// Initial atlas size
    pub const INITIAL_SIZE: u32 = 512;
    /// Maximum atlas size
    pub const MAX_SIZE: u32 = 4096;
    /// Maximum skyline nodes (sufficient for 4096x4096 atlas with small glyphs)
    pub const MAX_SKYLINE_NODES: usize = 128;

    pub fn init(allocator: std.mem.Allocator, format: Format) !Self {
        return initWithSize(allocator, format, INITIAL_SIZE);
    }

    pub fn initWithSize(allocator: std.mem.Allocator, format: Format, size: u32) !Self {
        std.debug.assert(size >= 64); // Minimum reasonable atlas size
        std.debug.assert(size <= MAX_SIZE);

        const bytes_per_pixel = format.bytesPerPixel();
        const data_size = size * size * bytes_per_pixel;
        const data = try allocator.alloc(u8, data_size);
        @memset(data, 0);

        var self = Self{
            .allocator = allocator,
            .data = data,
            .size = size,
            .format = format,
            .nodes = undefined,
            .node_count = 1,
            .generation = 0,
            .padding = 1,
        };

        // Start with single node spanning entire width
        self.nodes[0] = .{ .x = 0, .y = 0, .width = @intCast(size) };

        std.debug.assert(self.node_count == 1);
        std.debug.assert(self.nodes[0].width == size);

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.data);
        self.* = undefined;
    }

    /// Reserve space for a glyph, returns region or null if no space
    pub fn reserve(self: *Self, width: u32, height: u32) !?Region {
        if (width == 0 or height == 0) return null;

        std.debug.assert(width <= self.size);
        std.debug.assert(height <= self.size);

        const padded_w = width + self.padding;
        const padded_h = height + self.padding;

        // Find best position using skyline algorithm
        var best_idx: ?usize = null;
        var best_x: u16 = 0;
        var best_y: u16 = std.math.maxInt(u16);
        var best_width: u16 = std.math.maxInt(u16);

        var i: usize = 0;
        while (i < self.node_count) : (i += 1) {
            if (self.fitSkyline(i, @intCast(padded_w), @intCast(padded_h))) |y| {
                const node = self.nodes[i];
                // Prefer lower Y, then shorter span width
                if (y < best_y or (y == best_y and node.width < best_width)) {
                    best_idx = i;
                    best_x = node.x;
                    best_y = y;
                    best_width = node.width;
                }
            }
        }

        if (best_idx) |idx| {
            // Add new skyline node
            const new_node = SkylineNode{
                .x = best_x,
                .y = best_y + @as(u16, @intCast(padded_h)),
                .width = @intCast(padded_w),
            };

            // Insert new node at idx
            if (self.node_count >= MAX_SKYLINE_NODES) {
                return error.SkylineFull;
            }
            self.insertNode(idx, new_node);

            // Shrink/remove nodes covered by new node
            var j = idx + 1;
            while (j < self.node_count) {
                const prev = self.nodes[j - 1];
                const node = &self.nodes[j];
                const prev_right = prev.x + prev.width;

                if (node.x < prev_right) {
                    const shrink = prev_right - node.x;
                    if (node.width <= shrink) {
                        self.removeNode(j);
                        continue;
                    } else {
                        node.x += shrink;
                        node.width -= shrink;
                        break;
                    }
                }
                j += 1;
            }

            // Merge adjacent nodes at same height
            self.mergeSkyline();

            self.generation += 1;

            return Region{
                .x = best_x,
                .y = best_y,
                .width = @intCast(width),
                .height = @intCast(height),
            };
        }

        return null; // No space available
    }

    /// Insert a node at the given index, shifting subsequent nodes
    fn insertNode(self: *Self, idx: usize, node: SkylineNode) void {
        std.debug.assert(idx <= self.node_count);
        std.debug.assert(self.node_count < MAX_SKYLINE_NODES);

        // Shift nodes to make room
        var i: usize = self.node_count;
        while (i > idx) : (i -= 1) {
            self.nodes[i] = self.nodes[i - 1];
        }
        self.nodes[idx] = node;
        self.node_count += 1;

        std.debug.assert(self.node_count <= MAX_SKYLINE_NODES);
    }

    /// Remove a node at the given index, shifting subsequent nodes
    fn removeNode(self: *Self, idx: usize) void {
        std.debug.assert(idx < self.node_count);
        std.debug.assert(self.node_count > 0);

        // Shift nodes to fill gap
        var i: usize = idx;
        while (i + 1 < self.node_count) : (i += 1) {
            self.nodes[i] = self.nodes[i + 1];
        }
        self.node_count -= 1;
    }

    /// Check if rectangle fits at skyline index, returns Y position
    fn fitSkyline(self: *const Self, idx: usize, width: u16, height: u16) ?u16 {
        std.debug.assert(idx < self.node_count);

        const x = self.nodes[idx].x;
        if (x + width > self.size) return null;

        var y = self.nodes[idx].y;
        var remaining = width;
        var i = idx;

        while (remaining > 0 and i < self.node_count) {
            const node = self.nodes[i];
            y = @max(y, node.y);

            if (y + height > self.size) return null;

            if (node.width >= remaining) {
                return y;
            }

            remaining -= node.width;
            i += 1;
        }

        return null;
    }

    /// Merge adjacent skyline nodes at same height
    fn mergeSkyline(self: *Self) void {
        var i: usize = 0;
        while (i + 1 < self.node_count) {
            const curr = self.nodes[i];
            const next = self.nodes[i + 1];

            if (curr.y == next.y) {
                self.nodes[i].width += next.width;
                self.removeNode(i + 1);
            } else {
                i += 1;
            }
        }
    }

    /// Write pixel data to a reserved region
    pub fn set(self: *Self, region: Region, src_data: []const u8) void {
        // Validate region bounds
        std.debug.assert(region.x + region.width <= self.size);
        std.debug.assert(region.y + region.height <= self.size);

        const bpp = self.format.bytesPerPixel();
        const row_bytes: usize = @as(usize, region.width) * bpp;
        const atlas_stride: usize = @as(usize, self.size) * bpp;

        // Validate source data size
        std.debug.assert(src_data.len >= row_bytes * region.height);

        for (0..region.height) |row| {
            const src_offset = row * row_bytes;
            const dst_offset = (@as(usize, region.y) + row) * atlas_stride + @as(usize, region.x) * bpp;

            std.debug.assert(src_offset + row_bytes <= src_data.len);
            std.debug.assert(dst_offset + row_bytes <= self.data.len);

            @memcpy(
                self.data[dst_offset..][0..row_bytes],
                src_data[src_offset..][0..row_bytes],
            );
        }

        self.generation += 1;
    }

    /// Grow the atlas to a larger size (preserves existing data)
    pub fn grow(self: *Self) !void {
        const new_size = self.size * 2;
        if (new_size > MAX_SIZE) return error.AtlasFull;

        std.debug.assert(new_size <= MAX_SIZE);

        const bpp = self.format.bytesPerPixel();
        const new_data = try self.allocator.alloc(u8, new_size * new_size * bpp);
        @memset(new_data, 0);

        // Copy existing data row by row
        const old_stride = self.size * bpp;
        const new_stride = new_size * bpp;

        for (0..self.size) |row| {
            const src_offset = row * old_stride;
            const dst_offset = row * new_stride;
            @memcpy(new_data[dst_offset..][0..old_stride], self.data[src_offset..][0..old_stride]);
        }

        self.allocator.free(self.data);
        self.data = new_data;
        self.size = new_size;

        // Extend the last skyline node to cover new space
        if (self.node_count > 0) {
            const last = &self.nodes[self.node_count - 1];
            const old_right = last.x + last.width;
            if (old_right < new_size) {
                if (self.node_count < MAX_SKYLINE_NODES) {
                    self.nodes[self.node_count] = .{
                        .x = @intCast(old_right),
                        .y = 0,
                        .width = @intCast(new_size - old_right),
                    };
                    self.node_count += 1;
                }
                // If at capacity, we can't add a new node but the atlas still works
                // (just less efficiently for the new space)
            }
        }

        self.generation += 1;

        std.debug.assert(self.size == new_size);
    }

    /// Clear the atlas and reset packing
    pub fn clear(self: *Self) void {
        @memset(self.data, 0);

        // Reset to single node spanning entire width
        self.nodes[0] = .{ .x = 0, .y = 0, .width = @intCast(self.size) };
        self.node_count = 1;

        self.generation += 1;

        std.debug.assert(self.node_count == 1);
    }

    /// Get raw pixel data for GPU upload
    pub fn getData(self: *const Self) []const u8 {
        return self.data;
    }

    /// Calculate utilization percentage
    pub fn utilization(self: *const Self) f32 {
        var used_area: u32 = 0;
        for (self.nodes[0..self.node_count]) |node| {
            used_area += @as(u32, node.width) * @as(u32, node.y);
        }
        const total_area = self.size * self.size;
        return @as(f32, @floatFromInt(used_area)) / @as(f32, @floatFromInt(total_area));
    }

    /// Get current skyline node count (for debugging)
    pub fn getSkylineNodeCount(self: *const Self) u16 {
        return self.node_count;
    }
};

test "atlas basic allocation" {
    var atlas = try Atlas.init(std.testing.allocator, .grayscale);
    defer atlas.deinit();

    const region = try atlas.reserve(32, 32);
    try std.testing.expect(region != null);
    try std.testing.expectEqual(@as(u16, 0), region.?.x);
    try std.testing.expectEqual(@as(u16, 0), region.?.y);
}

test "atlas multiple allocations" {
    var atlas = try Atlas.init(std.testing.allocator, .grayscale);
    defer atlas.deinit();

    _ = try atlas.reserve(64, 64);
    const r2 = try atlas.reserve(64, 64);

    try std.testing.expect(r2 != null);
    // Second allocation should be next to or below first
    try std.testing.expect(r2.?.x >= 64 or r2.?.y >= 64);
}

test "atlas skyline node limit" {
    var atlas = try Atlas.init(std.testing.allocator, .grayscale);
    defer atlas.deinit();

    // Allocate many small regions to exercise skyline node management
    var count: usize = 0;
    while (count < 50) : (count += 1) {
        const region = try atlas.reserve(8, 8);
        if (region == null) break;
    }

    // Should have allocated at least some regions
    try std.testing.expect(count > 0);
    // Skyline node count should be within limits
    try std.testing.expect(atlas.getSkylineNodeCount() <= Atlas.MAX_SKYLINE_NODES);
}
