//! Core types for the element system
//!
//! These types are used throughout the element system for layout,
//! rendering, and event handling.

const std = @import("std");

// =============================================================================
// Pixel Unit Type
// =============================================================================

pub const Pixels = f32;
pub const ScaledPixels = f32;

// =============================================================================
// Geometry Types (generic over unit type)
// =============================================================================

pub fn PointT(comptime T: type) type {
    return struct {
        x: T = 0,
        y: T = 0,

        const Self = @This();

        pub fn init(x: T, y: T) Self {
            return .{ .x = x, .y = y };
        }

        pub fn scale(self: Self, factor: T) Self {
            return .{ .x = self.x * factor, .y = self.y * factor };
        }

        pub const zero = Self{};
    };
}

pub const Point = PointT(Pixels);
pub const ScaledPoint = PointT(ScaledPixels);

pub fn SizeT(comptime T: type) type {
    return struct {
        width: T = 0,
        height: T = 0,

        const Self = @This();

        pub fn init(width: T, height: T) Self {
            return .{ .width = width, .height = height };
        }

        pub fn scale(self: Self, factor: T) Self {
            return .{ .width = self.width * factor, .height = self.height * factor };
        }

        pub fn area(self: Self) T {
            return self.width * self.height;
        }

        pub const zero = Self{};
    };
}

pub const Size = SizeT(Pixels);

pub fn BoundsT(comptime T: type) type {
    return struct {
        origin: PointT(T) = .{},
        size: SizeT(T) = .{},

        const Self = @This();

        pub fn init(x: T, y: T, width: T, height: T) Self {
            return .{
                .origin = .{ .x = x, .y = y },
                .size = .{ .width = width, .height = height },
            };
        }

        pub fn contains(self: Self, point: PointT(T)) bool {
            return point.x >= self.origin.x and
                point.x < self.origin.x + self.size.width and
                point.y >= self.origin.y and
                point.y < self.origin.y + self.size.height;
        }

        pub fn inset(self: Self, edges: EdgesT(T)) Self {
            return .{
                .origin = .{ .x = self.origin.x + edges.left, .y = self.origin.y + edges.top },
                .size = .{
                    .width = @max(0, self.size.width - edges.horizontal()),
                    .height = @max(0, self.size.height - edges.vertical()),
                },
            };
        }

        pub fn left(self: Self) T {
            return self.origin.x;
        }
        pub fn top(self: Self) T {
            return self.origin.y;
        }
        pub fn right(self: Self) T {
            return self.origin.x + self.size.width;
        }
        pub fn bottom(self: Self) T {
            return self.origin.y + self.size.height;
        }

        pub const zero = Self{};
    };
}

pub const Bounds = BoundsT(Pixels);

pub fn EdgesT(comptime T: type) type {
    return struct {
        top: T = 0,
        right: T = 0,
        bottom: T = 0,
        left: T = 0,

        const Self = @This();

        pub fn all(value: T) Self {
            return .{ .top = value, .right = value, .bottom = value, .left = value };
        }

        pub fn horizontal(self: Self) T {
            return self.left + self.right;
        }
        pub fn vertical(self: Self) T {
            return self.top + self.bottom;
        }

        pub const zero = Self{};
    };
}

pub const Edges = EdgesT(Pixels);

pub fn CornersT(comptime T: type) type {
    return struct {
        top_left: T = 0,
        top_right: T = 0,
        bottom_right: T = 0,
        bottom_left: T = 0,

        const Self = @This();

        pub fn all(radius: T) Self {
            return .{ .top_left = radius, .top_right = radius, .bottom_right = radius, .bottom_left = radius };
        }

        pub const zero = Self{};
    };
}

pub const Corners = CornersT(Pixels);

// =============================================================================
// Available Space (for layout constraints)
// =============================================================================

pub const AvailableSpace = union(enum) {
    definite: Pixels,
    min_content,
    max_content,

    pub fn unwrapOr(self: AvailableSpace, default: Pixels) Pixels {
        return switch (self) {
            .definite => |v| v,
            else => default,
        };
    }
};

// =============================================================================
// Layout Node ID
// =============================================================================

pub const LayoutNodeId = struct {
    index: u32,

    pub const invalid = LayoutNodeId{ .index = std.math.maxInt(u32) };

    pub fn isValid(self: LayoutNodeId) bool {
        return self.index != std.math.maxInt(u32);
    }
};

// =============================================================================
// Element ID (stable identity across renders)
// =============================================================================

pub const ElementId = union(enum) {
    name: NamedId,
    integer: u64,
    focus_handle: u64,

    pub const NamedId = struct {
        hash: u64,

        pub fn init(name: []const u8) NamedId {
            return .{ .hash = std.hash.Wyhash.hash(0, name) };
        }
    };

    pub fn named(name: []const u8) ElementId {
        return .{ .name = NamedId.init(name) };
    }

    pub fn int(id: u64) ElementId {
        return .{ .integer = id };
    }

    pub fn eql(self: ElementId, other: ElementId) bool {
        return switch (self) {
            .name => |n| switch (other) {
                .name => |on| n.hash == on.hash,
                else => false,
            },
            .integer => |i| switch (other) {
                .integer => |oi| i == oi,
                else => false,
            },
            .focus_handle => |f| switch (other) {
                .focus_handle => |of| f == of,
                else => false,
            },
        };
    }

    pub fn hash(self: ElementId) u64 {
        return switch (self) {
            .name => |n| n.hash,
            .integer, .focus_handle => |i| i,
        };
    }
};

// =============================================================================
// Global Element ID (path from root for disambiguation)
// =============================================================================

pub const GlobalElementId = struct {
    allocator: std.mem.Allocator,
    path: std.ArrayList(ElementId),

    pub fn init(allocator: std.mem.Allocator) GlobalElementId {
        return .{
            .allocator = allocator,
            .path = std.ArrayList(ElementId).init(allocator),
        };
    }

    pub fn deinit(self: *GlobalElementId) void {
        self.path.deinit();
    }

    pub fn push(self: *GlobalElementId, id: ElementId) !void {
        try self.path.append(id);
    }

    pub fn pop(self: *GlobalElementId) ?ElementId {
        return self.path.popOrNull();
    }

    pub fn hash(self: *const GlobalElementId) u64 {
        var h: u64 = 0;
        for (self.path.items) |id| {
            h = std.hash.Wyhash.hash(h, std.mem.asBytes(&id.hash()));
        }
        return h;
    }
};
