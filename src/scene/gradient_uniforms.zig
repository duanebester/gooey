//! Gradient Uniforms - GPU-compatible gradient data structures
//!
//! Packs gradient stops and parameters into fixed-size arrays suitable
//! for upload to Metal/WebGPU uniform buffers.
//!
//! Layout is carefully aligned for GPU float4 requirements.

const std = @import("std");
const gradient_mod = @import("gradient.zig");
const scene = @import("scene.zig");

const GradientType = gradient_mod.GradientType;
const LinearGradient = gradient_mod.LinearGradient;
const RadialGradient = gradient_mod.RadialGradient;
const Gradient = gradient_mod.Gradient;
const MAX_GRADIENT_STOPS = gradient_mod.MAX_GRADIENT_STOPS;

// =============================================================================
// Constants
// =============================================================================

/// Maximum stops supported in GPU uniform (must match shader)
pub const GPU_MAX_STOPS: u32 = 16;

// =============================================================================
// GradientUniforms - GPU-ready gradient data
// =============================================================================

/// GPU-compatible gradient uniform data.
/// Layout matches Metal/WebGPU shader expectations.
///
/// Total size: 288 bytes (must be multiple of 16 for GPU alignment)
/// - Header: 32 bytes (gradient_type, stop_count, params)
/// - Stops: 256 bytes (16 stops × 16 bytes each)
pub const GradientUniforms = extern struct {
    // Header (32 bytes) -------------------------------------------------------

    /// Gradient type: 0=none, 1=linear, 2=radial
    gradient_type: u32 = 0,
    /// Number of active color stops [0, 16]
    stop_count: u32 = 0,
    /// Padding for alignment
    _pad0: u32 = 0,
    _pad1: u32 = 0,

    // Linear gradient params (or radial center for radial) - 16 bytes
    /// Linear: start_x, start_y, end_x, end_y
    /// Radial: center_x, center_y, radius, inner_radius
    param0: f32 = 0, // start_x / center_x
    param1: f32 = 0, // start_y / center_y
    param2: f32 = 0, // end_x / radius
    param3: f32 = 0, // end_y / inner_radius

    // Stops (256 bytes = 16 stops × 16 bytes) ---------------------------------
    // Each stop: offset (f32) + color HSLA (4 × f32) packed as:
    // [offset, h, s, l] and [a, 0, 0, 0] - but we pack more efficiently:
    // [offset, h, s, l] per stop, alpha in separate array

    /// Stop offsets [0, 1]
    stop_offsets: [GPU_MAX_STOPS]f32 = [_]f32{0} ** GPU_MAX_STOPS,
    /// Stop colors - hue component
    stop_h: [GPU_MAX_STOPS]f32 = [_]f32{0} ** GPU_MAX_STOPS,
    /// Stop colors - saturation component
    stop_s: [GPU_MAX_STOPS]f32 = [_]f32{0} ** GPU_MAX_STOPS,
    /// Stop colors - lightness component
    stop_l: [GPU_MAX_STOPS]f32 = [_]f32{0} ** GPU_MAX_STOPS,
    /// Stop colors - alpha component
    stop_a: [GPU_MAX_STOPS]f32 = [_]f32{1} ** GPU_MAX_STOPS,

    const Self = @This();

    /// Create uniforms for no gradient (solid color fill)
    pub fn none() Self {
        return .{};
    }

    /// Create uniforms from a linear gradient
    pub fn fromLinear(grad: LinearGradient) Self {
        std.debug.assert(grad.stop_count >= 2);
        std.debug.assert(grad.stop_count <= GPU_MAX_STOPS);

        var uniforms = Self{
            .gradient_type = @intFromEnum(GradientType.linear),
            .stop_count = grad.stop_count,
            .param0 = grad.start_x,
            .param1 = grad.start_y,
            .param2 = grad.end_x,
            .param3 = grad.end_y,
        };

        // Copy stops
        for (0..grad.stop_count) |i| {
            const stop = grad.stops[i];
            uniforms.stop_offsets[i] = stop.offset;
            uniforms.stop_h[i] = stop.color.h;
            uniforms.stop_s[i] = stop.color.s;
            uniforms.stop_l[i] = stop.color.l;
            uniforms.stop_a[i] = stop.color.a;
        }

        return uniforms;
    }

    /// Create uniforms from a radial gradient
    pub fn fromRadial(grad: RadialGradient) Self {
        std.debug.assert(grad.stop_count >= 2);
        std.debug.assert(grad.stop_count <= GPU_MAX_STOPS);

        var uniforms = Self{
            .gradient_type = @intFromEnum(GradientType.radial),
            .stop_count = grad.stop_count,
            .param0 = grad.center_x,
            .param1 = grad.center_y,
            .param2 = grad.radius,
            .param3 = grad.inner_radius,
        };

        // Copy stops
        for (0..grad.stop_count) |i| {
            const stop = grad.stops[i];
            uniforms.stop_offsets[i] = stop.offset;
            uniforms.stop_h[i] = stop.color.h;
            uniforms.stop_s[i] = stop.color.s;
            uniforms.stop_l[i] = stop.color.l;
            uniforms.stop_a[i] = stop.color.a;
        }

        return uniforms;
    }

    /// Create uniforms from a gradient union
    pub fn fromGradient(grad: Gradient) Self {
        return switch (grad) {
            .none => none(),
            .linear => |g| fromLinear(g),
            .radial => |g| fromRadial(g),
        };
    }

    /// Check if this represents a gradient (vs solid color)
    pub fn isGradient(self: *const Self) bool {
        return self.gradient_type != 0 and self.stop_count >= 2;
    }

    /// Get as bytes for GPU upload
    pub fn asBytes(self: *const Self) []const u8 {
        const ptr: [*]const u8 = @ptrCast(self);
        return ptr[0..@sizeOf(Self)];
    }
};

// =============================================================================
// Compile-time Assertions (per CLAUDE.md)
// =============================================================================

comptime {
    // Verify size is multiple of 16 for GPU alignment
    if (@sizeOf(GradientUniforms) % 16 != 0) {
        @compileError(std.fmt.comptimePrint(
            "GradientUniforms size must be multiple of 16, got {}",
            .{@sizeOf(GradientUniforms)},
        ));
    }

    // Verify expected size (header 32 + 5 arrays × 64 = 352 bytes)
    if (@sizeOf(GradientUniforms) != 352) {
        @compileError(std.fmt.comptimePrint(
            "GradientUniforms must be 352 bytes, got {}",
            .{@sizeOf(GradientUniforms)},
        ));
    }

    // Verify stop arrays start at expected offsets for GPU access
    if (@offsetOf(GradientUniforms, "stop_offsets") != 32) {
        @compileError(std.fmt.comptimePrint(
            "stop_offsets must be at offset 32, got {}",
            .{@offsetOf(GradientUniforms, "stop_offsets")},
        ));
    }
}

// =============================================================================
// Tests
// =============================================================================

test "GradientUniforms size" {
    try std.testing.expectEqual(@as(usize, 352), @sizeOf(GradientUniforms));
}

test "GradientUniforms none" {
    const uniforms = GradientUniforms.none();
    try std.testing.expectEqual(@as(u32, 0), uniforms.gradient_type);
    try std.testing.expectEqual(@as(u32, 0), uniforms.stop_count);
    try std.testing.expect(!uniforms.isGradient());
}

test "GradientUniforms fromLinear" {
    var grad = LinearGradient.init(0, 0, 100, 50);
    _ = grad.addStop(0.0, scene.Hsla.red);
    _ = grad.addStop(0.5, scene.Hsla.green);
    _ = grad.addStop(1.0, scene.Hsla.blue);

    const uniforms = GradientUniforms.fromLinear(grad);

    try std.testing.expectEqual(@as(u32, 1), uniforms.gradient_type);
    try std.testing.expectEqual(@as(u32, 3), uniforms.stop_count);
    try std.testing.expectEqual(@as(f32, 0), uniforms.param0);
    try std.testing.expectEqual(@as(f32, 0), uniforms.param1);
    try std.testing.expectEqual(@as(f32, 100), uniforms.param2);
    try std.testing.expectEqual(@as(f32, 50), uniforms.param3);

    try std.testing.expectEqual(@as(f32, 0.0), uniforms.stop_offsets[0]);
    try std.testing.expectEqual(@as(f32, 0.5), uniforms.stop_offsets[1]);
    try std.testing.expectEqual(@as(f32, 1.0), uniforms.stop_offsets[2]);

    try std.testing.expect(uniforms.isGradient());
}

test "GradientUniforms fromRadial" {
    var grad = RadialGradient.init(50, 50, 40);
    _ = grad.addStop(0.0, scene.Hsla.white);
    _ = grad.addStop(1.0, scene.Hsla.black);

    const uniforms = GradientUniforms.fromRadial(grad);

    try std.testing.expectEqual(@as(u32, 2), uniforms.gradient_type);
    try std.testing.expectEqual(@as(u32, 2), uniforms.stop_count);
    try std.testing.expectEqual(@as(f32, 50), uniforms.param0); // center_x
    try std.testing.expectEqual(@as(f32, 50), uniforms.param1); // center_y
    try std.testing.expectEqual(@as(f32, 40), uniforms.param2); // radius
    try std.testing.expectEqual(@as(f32, 0), uniforms.param3); // inner_radius

    try std.testing.expect(uniforms.isGradient());
}

test "GradientUniforms fromGradient" {
    const lin = Gradient.fromLinear(LinearGradient.twoStop(0, 0, 100, 0, scene.Hsla.red, scene.Hsla.blue));
    const uniforms = GradientUniforms.fromGradient(lin);

    try std.testing.expectEqual(@as(u32, 1), uniforms.gradient_type);
    try std.testing.expect(uniforms.isGradient());
}

test "GradientUniforms asBytes" {
    const uniforms = GradientUniforms.none();
    const bytes = uniforms.asBytes();
    try std.testing.expectEqual(@as(usize, 352), bytes.len);
}
