//! Gradient - Linear and radial gradient definitions for path rendering
//!
//! Gradients are used to fill paths with smooth color transitions.
//! Supports up to 16 color stops per gradient.
//!
//! ## Usage
//! ```zig
//! const gradient = @import("gradient.zig");
//!
//! // Linear gradient from red to blue
//! var linear = gradient.LinearGradient.init(0, 0, 100, 0);
//! linear.addStop(0.0, Hsla.red);
//! linear.addStop(1.0, Hsla.blue);
//!
//! // Radial gradient from center
//! var radial = gradient.RadialGradient.init(50, 50, 50);
//! radial.addStop(0.0, Hsla.white);
//! radial.addStop(1.0, Hsla.black);
//! ```

const std = @import("std");
const scene = @import("scene.zig");

// =============================================================================
// Constants (per CLAUDE.md: "put a limit on everything")
// =============================================================================

/// Maximum color stops per gradient
pub const MAX_GRADIENT_STOPS: usize = 16;

// =============================================================================
// GradientStop - Single color stop in a gradient
// =============================================================================

/// A single color stop in a gradient.
/// Offset is normalized [0, 1] where 0 = start, 1 = end.
pub const GradientStop = struct {
    /// Position along gradient [0, 1]
    offset: f32,
    /// Color at this stop (HSLA)
    color: scene.Hsla,

    pub fn init(offset: f32, color: scene.Hsla) GradientStop {
        std.debug.assert(offset >= 0.0 and offset <= 1.0);
        std.debug.assert(!std.math.isNan(offset));
        return .{ .offset = offset, .color = color };
    }
};

// =============================================================================
// GradientType - Discriminator for gradient uniforms
// =============================================================================

/// Type of gradient for GPU shader selection
pub const GradientType = enum(u32) {
    /// No gradient, use solid fill color
    none = 0,
    /// Linear gradient between two points
    linear = 1,
    /// Radial gradient from center outward
    radial = 2,
};

// =============================================================================
// LinearGradient - Gradient between two points
// =============================================================================

/// Linear gradient defined by start and end points.
/// Colors interpolate along the line connecting these points.
pub const LinearGradient = struct {
    /// Start point X (in path local coordinates)
    start_x: f32,
    /// Start point Y (in path local coordinates)
    start_y: f32,
    /// End point X (in path local coordinates)
    end_x: f32,
    /// End point Y (in path local coordinates)
    end_y: f32,
    /// Color stops (sorted by offset)
    stops: [MAX_GRADIENT_STOPS]GradientStop,
    /// Number of active stops
    stop_count: u32,

    const Self = @This();

    /// Initialize a linear gradient with start and end points.
    /// Add color stops with `addStop()`.
    pub fn init(start_x: f32, start_y: f32, end_x: f32, end_y: f32) Self {
        std.debug.assert(!std.math.isNan(start_x) and !std.math.isNan(start_y));
        std.debug.assert(!std.math.isNan(end_x) and !std.math.isNan(end_y));

        return .{
            .start_x = start_x,
            .start_y = start_y,
            .end_x = end_x,
            .end_y = end_y,
            .stops = undefined,
            .stop_count = 0,
        };
    }

    /// Create a horizontal gradient (left to right).
    pub fn horizontal(width: f32) Self {
        std.debug.assert(width > 0);
        return init(0, 0, width, 0);
    }

    /// Create a vertical gradient (top to bottom).
    pub fn vertical(height: f32) Self {
        std.debug.assert(height > 0);
        return init(0, 0, 0, height);
    }

    /// Create a diagonal gradient (top-left to bottom-right).
    pub fn diagonal(width: f32, height: f32) Self {
        std.debug.assert(width > 0 and height > 0);
        return init(0, 0, width, height);
    }

    /// Add a color stop. Returns self for chaining.
    /// Stops should be added in order of increasing offset.
    pub fn addStop(self: *Self, offset: f32, color: scene.Hsla) *Self {
        std.debug.assert(offset >= 0.0 and offset <= 1.0);
        std.debug.assert(self.stop_count < MAX_GRADIENT_STOPS);

        self.stops[self.stop_count] = GradientStop.init(offset, color);
        self.stop_count += 1;
        return self;
    }

    /// Add a color stop using a Color (converts to Hsla).
    pub fn addStopColor(self: *Self, offset: f32, color: anytype) *Self {
        return self.addStop(offset, scene.Hsla.fromColor(color));
    }

    /// Convenience: create a two-stop gradient.
    pub fn twoStop(
        start_x: f32,
        start_y: f32,
        end_x: f32,
        end_y: f32,
        start_color: scene.Hsla,
        end_color: scene.Hsla,
    ) Self {
        var grad = init(start_x, start_y, end_x, end_y);
        _ = grad.addStop(0.0, start_color);
        _ = grad.addStop(1.0, end_color);
        return grad;
    }

    /// Get the gradient direction vector (normalized).
    pub fn direction(self: *const Self) [2]f32 {
        const dx = self.end_x - self.start_x;
        const dy = self.end_y - self.start_y;
        const len = @sqrt(dx * dx + dy * dy);

        if (len < 0.0001) return .{ 1, 0 }; // Default to horizontal

        return .{ dx / len, dy / len };
    }

    /// Get the gradient length.
    pub fn length(self: *const Self) f32 {
        const dx = self.end_x - self.start_x;
        const dy = self.end_y - self.start_y;
        return @sqrt(dx * dx + dy * dy);
    }
};

// =============================================================================
// RadialGradient - Gradient from center outward
// =============================================================================

/// Radial gradient defined by center point and radius.
/// Colors interpolate from center (offset=0) to edge (offset=1).
pub const RadialGradient = struct {
    /// Center X (in path local coordinates)
    center_x: f32,
    /// Center Y (in path local coordinates)
    center_y: f32,
    /// Radius (in path local coordinates)
    radius: f32,
    /// Optional: inner radius for ring gradients (0 = solid center)
    inner_radius: f32,
    /// Color stops (sorted by offset)
    stops: [MAX_GRADIENT_STOPS]GradientStop,
    /// Number of active stops
    stop_count: u32,

    const Self = @This();

    /// Initialize a radial gradient with center and radius.
    /// Add color stops with `addStop()`.
    pub fn init(center_x: f32, center_y: f32, radius: f32) Self {
        std.debug.assert(!std.math.isNan(center_x) and !std.math.isNan(center_y));
        std.debug.assert(radius > 0);

        return .{
            .center_x = center_x,
            .center_y = center_y,
            .radius = radius,
            .inner_radius = 0,
            .stops = undefined,
            .stop_count = 0,
        };
    }

    /// Initialize a ring gradient (hollow center).
    pub fn ring(center_x: f32, center_y: f32, inner_radius: f32, outer_radius: f32) Self {
        std.debug.assert(inner_radius >= 0 and outer_radius > inner_radius);

        var grad = init(center_x, center_y, outer_radius);
        grad.inner_radius = inner_radius;
        return grad;
    }

    /// Add a color stop. Returns self for chaining.
    /// Stops should be added in order of increasing offset.
    pub fn addStop(self: *Self, offset: f32, color: scene.Hsla) *Self {
        std.debug.assert(offset >= 0.0 and offset <= 1.0);
        std.debug.assert(self.stop_count < MAX_GRADIENT_STOPS);

        self.stops[self.stop_count] = GradientStop.init(offset, color);
        self.stop_count += 1;
        return self;
    }

    /// Add a color stop using a Color (converts to Hsla).
    pub fn addStopColor(self: *Self, offset: f32, color: anytype) *Self {
        return self.addStop(offset, scene.Hsla.fromColor(color));
    }

    /// Convenience: create a two-stop radial gradient.
    pub fn twoStop(
        center_x: f32,
        center_y: f32,
        radius: f32,
        center_color: scene.Hsla,
        edge_color: scene.Hsla,
    ) Self {
        var grad = init(center_x, center_y, radius);
        _ = grad.addStop(0.0, center_color);
        _ = grad.addStop(1.0, edge_color);
        return grad;
    }
};

// =============================================================================
// Gradient - Tagged union for any gradient type
// =============================================================================

/// A gradient that can be either linear or radial.
/// Use this when you need to store/pass gradients generically.
pub const Gradient = union(GradientType) {
    none: void,
    linear: LinearGradient,
    radial: RadialGradient,

    const Self = @This();

    /// Create a linear gradient.
    pub fn fromLinear(grad: LinearGradient) Self {
        return .{ .linear = grad };
    }

    /// Create a radial gradient.
    pub fn fromRadial(grad: RadialGradient) Self {
        return .{ .radial = grad };
    }

    /// Check if this is a valid gradient (has stops).
    pub fn isValid(self: Self) bool {
        return switch (self) {
            .none => false,
            .linear => |g| g.stop_count >= 2,
            .radial => |g| g.stop_count >= 2,
        };
    }

    /// Get the number of stops.
    pub fn stopCount(self: Self) u32 {
        return switch (self) {
            .none => 0,
            .linear => |g| g.stop_count,
            .radial => |g| g.stop_count,
        };
    }

    /// Get a stop by index.
    pub fn getStop(self: Self, index: usize) ?GradientStop {
        return switch (self) {
            .none => null,
            .linear => |g| if (index < g.stop_count) g.stops[index] else null,
            .radial => |g| if (index < g.stop_count) g.stops[index] else null,
        };
    }
};

// =============================================================================
// Tests
// =============================================================================

test "GradientStop init" {
    const stop = GradientStop.init(0.5, scene.Hsla.red);
    try std.testing.expectEqual(@as(f32, 0.5), stop.offset);
    try std.testing.expectEqual(@as(f32, 0), stop.color.h);
}

test "LinearGradient basic" {
    var grad = LinearGradient.init(0, 0, 100, 0);
    _ = grad.addStop(0.0, scene.Hsla.red);
    _ = grad.addStop(1.0, scene.Hsla.blue);

    try std.testing.expectEqual(@as(u32, 2), grad.stop_count);
    try std.testing.expectEqual(@as(f32, 0), grad.start_x);
    try std.testing.expectEqual(@as(f32, 100), grad.end_x);
}

test "LinearGradient twoStop" {
    const grad = LinearGradient.twoStop(0, 0, 100, 100, scene.Hsla.white, scene.Hsla.black);
    try std.testing.expectEqual(@as(u32, 2), grad.stop_count);
    try std.testing.expectEqual(@as(f32, 0.0), grad.stops[0].offset);
    try std.testing.expectEqual(@as(f32, 1.0), grad.stops[1].offset);
}

test "LinearGradient horizontal/vertical/diagonal" {
    const h = LinearGradient.horizontal(200);
    try std.testing.expectEqual(@as(f32, 0), h.start_x);
    try std.testing.expectEqual(@as(f32, 200), h.end_x);

    const v = LinearGradient.vertical(150);
    try std.testing.expectEqual(@as(f32, 0), v.start_y);
    try std.testing.expectEqual(@as(f32, 150), v.end_y);

    const d = LinearGradient.diagonal(100, 100);
    try std.testing.expectEqual(@as(f32, 100), d.end_x);
    try std.testing.expectEqual(@as(f32, 100), d.end_y);
}

test "LinearGradient direction and length" {
    const grad = LinearGradient.init(0, 0, 100, 0);
    const dir = grad.direction();
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), dir[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), dir[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 100.0), grad.length(), 0.001);
}

test "RadialGradient basic" {
    var grad = RadialGradient.init(50, 50, 40);
    _ = grad.addStop(0.0, scene.Hsla.white);
    _ = grad.addStop(1.0, scene.Hsla.black);

    try std.testing.expectEqual(@as(u32, 2), grad.stop_count);
    try std.testing.expectEqual(@as(f32, 50), grad.center_x);
    try std.testing.expectEqual(@as(f32, 40), grad.radius);
    try std.testing.expectEqual(@as(f32, 0), grad.inner_radius);
}

test "RadialGradient ring" {
    const grad = RadialGradient.ring(50, 50, 20, 50);
    try std.testing.expectEqual(@as(f32, 20), grad.inner_radius);
    try std.testing.expectEqual(@as(f32, 50), grad.radius);
}

test "RadialGradient twoStop" {
    const grad = RadialGradient.twoStop(100, 100, 75, scene.Hsla.red, scene.Hsla.transparent);
    try std.testing.expectEqual(@as(u32, 2), grad.stop_count);
    try std.testing.expectEqual(@as(f32, 100), grad.center_x);
    try std.testing.expectEqual(@as(f32, 75), grad.radius);
}

test "Gradient union" {
    const lin = Gradient.fromLinear(LinearGradient.twoStop(0, 0, 100, 0, scene.Hsla.red, scene.Hsla.blue));
    try std.testing.expect(lin.isValid());
    try std.testing.expectEqual(@as(u32, 2), lin.stopCount());

    const none = Gradient{ .none = {} };
    try std.testing.expect(!none.isValid());
    try std.testing.expectEqual(@as(u32, 0), none.stopCount());
}

test "Gradient getStop" {
    const grad = Gradient.fromLinear(LinearGradient.twoStop(0, 0, 100, 0, scene.Hsla.red, scene.Hsla.blue));

    const stop0 = grad.getStop(0);
    try std.testing.expect(stop0 != null);
    try std.testing.expectEqual(@as(f32, 0.0), stop0.?.offset);

    const stop1 = grad.getStop(1);
    try std.testing.expect(stop1 != null);
    try std.testing.expectEqual(@as(f32, 1.0), stop1.?.offset);

    const stop2 = grad.getStop(2);
    try std.testing.expect(stop2 == null);
}
