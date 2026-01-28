//! PathInstance - GPU instance data for triangulated path rendering
//!
//! Each PathInstance represents one filled path on screen, referencing
//! a mesh from the MeshPool. Multiple instances can share the same mesh
//! with different transforms and colors.
//!
//! Supports solid color fills and gradient fills (linear/radial).

const std = @import("std");
const scene = @import("scene.zig");
const MeshRef = @import("mesh_pool.zig").MeshRef;
const gradient_mod = @import("../core/gradient.zig");

// =============================================================================
// PathInstance - GPU-compatible instance data
// =============================================================================

/// Gradient type enum for GPU (matches shader expectations)
pub const GradientType = enum(u32) {
    none = 0,
    linear = 1,
    radial = 2,
};

/// Clip bounds for batching paths with matching clip regions
/// Used for Phase 1 optimization: group consecutive same-clip paths
pub const ClipBounds = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    const Self = @This();

    /// Compare two clip bounds for equality (exact match)
    pub fn equals(self: Self, other: Self) bool {
        return self.x == other.x and
            self.y == other.y and
            self.w == other.w and
            self.h == other.h;
    }

    /// Create from ContentMask.ClipBounds
    pub fn fromContentMask(clip: scene.ContentMask.ClipBounds) Self {
        return .{ .x = clip.x, .y = clip.y, .w = clip.width, .h = clip.height };
    }
};

/// GPU-ready instance data for path rendering
/// Layout carefully aligned for Metal/WebGPU float4 requirements
pub const PathInstance = extern struct {
    // Draw order for z-index interleaving (8 bytes with padding)
    order: scene.DrawOrder = 0,
    _pad0: u32 = 0, // Maintain 8-byte alignment

    // Transform: position offset (8 bytes)
    offset_x: f32 = 0,
    offset_y: f32 = 0,

    // Transform: scale (8 bytes)
    scale_x: f32 = 1,
    scale_y: f32 = 1,

    // Mesh reference - stored as u32 for GPU compatibility (8 bytes)
    mesh_ref_type: u32 = 0, // 0 = persistent, 1 = frame
    mesh_ref_index: u32 = 0,

    // Vertex/index ranges in shared GPU buffer (16 bytes)
    vertex_offset: u32 = 0,
    index_offset: u32 = 0,
    index_count: u32 = 0,
    _pad1: u32 = 0, // Align fill_color to 16-byte boundary

    // Fill color (HSLA) - must be at 16-byte aligned offset for Metal float4 (16 bytes)
    fill_color: scene.Hsla = scene.Hsla.black,

    // Clip bounds (16 bytes)
    clip_x: f32 = 0,
    clip_y: f32 = 0,
    clip_width: f32 = 99999,
    clip_height: f32 = 99999,

    // Gradient type and padding (16 bytes)
    // 0 = none (solid color), 1 = linear, 2 = radial
    gradient_type: u32 = 0,
    gradient_stop_count: u32 = 0, // Number of gradient stops [0, 16]
    _grad_pad0: u32 = 0,
    _grad_pad1: u32 = 0,

    // Gradient parameters (16 bytes)
    // Linear: start_x, start_y, end_x, end_y
    // Radial: center_x, center_y, radius, inner_radius
    grad_param0: f32 = 0,
    grad_param1: f32 = 0,
    grad_param2: f32 = 0,
    grad_param3: f32 = 0,

    const Self = @This();

    /// Initialize path instance with mesh reference and basic properties
    pub fn init(
        mesh_ref: MeshRef,
        offset_x: f32,
        offset_y: f32,
        fill: scene.Hsla,
    ) Self {
        // Assertions at API boundary (per CLAUDE.md: minimum 2 per function)
        std.debug.assert(!std.math.isNan(offset_x));
        std.debug.assert(!std.math.isNan(offset_y));

        const gpu_ref = mesh_ref.toGpuRef();

        return .{
            .mesh_ref_type = gpu_ref.ref_type,
            .mesh_ref_index = gpu_ref.ref_index,
            .offset_x = offset_x,
            .offset_y = offset_y,
            .fill_color = fill,
        };
    }

    /// Initialize with explicit vertex/index buffer ranges
    pub fn initWithBufferRanges(
        mesh_ref: MeshRef,
        offset_x: f32,
        offset_y: f32,
        fill: scene.Hsla,
        vertex_offset: u32,
        index_offset: u32,
        index_count: u32,
    ) Self {
        std.debug.assert(!std.math.isNan(offset_x));
        std.debug.assert(!std.math.isNan(offset_y));
        std.debug.assert(index_count % 3 == 0); // Must be complete triangles

        const gpu_ref = mesh_ref.toGpuRef();

        return .{
            .mesh_ref_type = gpu_ref.ref_type,
            .mesh_ref_index = gpu_ref.ref_index,
            .offset_x = offset_x,
            .offset_y = offset_y,
            .vertex_offset = vertex_offset,
            .index_offset = index_offset,
            .index_count = index_count,
            .fill_color = fill,
        };
    }

    /// Set clip bounds from ContentMask
    pub fn withClipBounds(self: Self, clip: scene.ContentMask.ClipBounds) Self {
        var inst = self;
        inst.clip_x = clip.x;
        inst.clip_y = clip.y;
        inst.clip_width = clip.width;
        inst.clip_height = clip.height;
        return inst;
    }

    /// Set clip bounds explicitly
    pub fn withClip(self: Self, x: f32, y: f32, width: f32, height: f32) Self {
        std.debug.assert(!std.math.isNan(x) and !std.math.isNan(y));
        std.debug.assert(width >= 0 and height >= 0);

        var inst = self;
        inst.clip_x = x;
        inst.clip_y = y;
        inst.clip_width = width;
        inst.clip_height = height;
        return inst;
    }

    /// Set uniform scale
    pub fn withScale(self: Self, s: f32) Self {
        std.debug.assert(!std.math.isNan(s) and s > 0);

        var inst = self;
        inst.scale_x = s;
        inst.scale_y = s;
        return inst;
    }

    /// Set non-uniform scale
    pub fn withScaleXY(self: Self, sx: f32, sy: f32) Self {
        std.debug.assert(!std.math.isNan(sx) and !std.math.isNan(sy));
        std.debug.assert(sx > 0 and sy > 0);

        var inst = self;
        inst.scale_x = sx;
        inst.scale_y = sy;
        return inst;
    }

    /// Set fill color (clears any gradient)
    pub fn withColor(self: Self, color: scene.Hsla) Self {
        var inst = self;
        inst.fill_color = color;
        inst.gradient_type = 0;
        return inst;
    }

    /// Set linear gradient fill
    pub fn withLinearGradient(
        self: Self,
        start_x: f32,
        start_y: f32,
        end_x: f32,
        end_y: f32,
        stop_count: u32,
    ) Self {
        std.debug.assert(stop_count >= 2 and stop_count <= 16);
        std.debug.assert(!std.math.isNan(start_x) and !std.math.isNan(start_y));
        std.debug.assert(!std.math.isNan(end_x) and !std.math.isNan(end_y));

        var inst = self;
        inst.gradient_type = @intFromEnum(GradientType.linear);
        inst.gradient_stop_count = stop_count;
        inst.grad_param0 = start_x;
        inst.grad_param1 = start_y;
        inst.grad_param2 = end_x;
        inst.grad_param3 = end_y;
        return inst;
    }

    /// Set radial gradient fill
    pub fn withRadialGradient(
        self: Self,
        center_x: f32,
        center_y: f32,
        radius: f32,
        inner_radius: f32,
        stop_count: u32,
    ) Self {
        std.debug.assert(stop_count >= 2 and stop_count <= 16);
        std.debug.assert(!std.math.isNan(center_x) and !std.math.isNan(center_y));
        std.debug.assert(radius > 0 and inner_radius >= 0);

        var inst = self;
        inst.gradient_type = @intFromEnum(GradientType.radial);
        inst.gradient_stop_count = stop_count;
        inst.grad_param0 = center_x;
        inst.grad_param1 = center_y;
        inst.grad_param2 = radius;
        inst.grad_param3 = inner_radius;
        return inst;
    }

    /// Check if this instance uses a gradient fill
    pub fn hasGradient(self: Self) bool {
        return self.gradient_type != 0 and self.gradient_stop_count >= 2;
    }

    /// Get clip bounds as a comparable struct for batch grouping
    /// Used for Phase 1 optimization: group consecutive paths with matching clips
    pub fn getClipBounds(self: Self) ClipBounds {
        return .{
            .x = self.clip_x,
            .y = self.clip_y,
            .w = self.clip_width,
            .h = self.clip_height,
        };
    }

    /// Set position offset
    pub fn withOffset(self: Self, x: f32, y: f32) Self {
        std.debug.assert(!std.math.isNan(x) and !std.math.isNan(y));

        var inst = self;
        inst.offset_x = x;
        inst.offset_y = y;
        return inst;
    }

    /// Check if this instance uses persistent mesh
    pub fn usesPersistentMesh(self: Self) bool {
        return self.mesh_ref_type == 0;
    }

    /// Check if this instance uses frame-local mesh
    pub fn usesFrameMesh(self: Self) bool {
        return self.mesh_ref_type == 1;
    }

    /// Get the MeshRef for this instance
    pub fn getMeshRef(self: Self) MeshRef {
        return if (self.mesh_ref_type == 0)
            MeshRef{ .persistent = @intCast(self.mesh_ref_index) }
        else
            MeshRef{ .frame = @intCast(self.mesh_ref_index) };
    }
};

// =============================================================================
// Compile-time Assertions (per CLAUDE.md)
// =============================================================================

comptime {
    // Verify exact size for GPU buffer layout (80 + 32 for gradient = 112)
    if (@sizeOf(PathInstance) != 112) {
        @compileError(std.fmt.comptimePrint(
            "PathInstance must be 112 bytes, got {}",
            .{@sizeOf(PathInstance)},
        ));
    }

    // Verify fill_color is at 16-byte aligned offset for Metal float4
    if (@offsetOf(PathInstance, "fill_color") != 48) {
        @compileError(std.fmt.comptimePrint(
            "PathInstance.fill_color must be at offset 48 for Metal float4 alignment, got {}",
            .{@offsetOf(PathInstance, "fill_color")},
        ));
    }

    // Verify clip bounds follow fill_color at expected offset
    if (@offsetOf(PathInstance, "clip_x") != 64) {
        @compileError(std.fmt.comptimePrint(
            "PathInstance.clip_x must be at offset 64, got {}",
            .{@offsetOf(PathInstance, "clip_x")},
        ));
    }

    // Verify gradient_type is at expected offset (after clip bounds)
    if (@offsetOf(PathInstance, "gradient_type") != 80) {
        @compileError(std.fmt.comptimePrint(
            "PathInstance.gradient_type must be at offset 80, got {}",
            .{@offsetOf(PathInstance, "gradient_type")},
        ));
    }

    // Verify gradient params are at 16-byte aligned offset
    if (@offsetOf(PathInstance, "grad_param0") != 96) {
        @compileError(std.fmt.comptimePrint(
            "PathInstance.grad_param0 must be at offset 96, got {}",
            .{@offsetOf(PathInstance, "grad_param0")},
        ));
    }
}

// =============================================================================
// Tests
// =============================================================================

test "PathInstance size is 112 bytes" {
    try std.testing.expectEqual(@as(usize, 112), @sizeOf(PathInstance));
}

test "PathInstance fill_color alignment" {
    try std.testing.expectEqual(@as(usize, 48), @offsetOf(PathInstance, "fill_color"));
}

test "PathInstance init" {
    const ref = MeshRef{ .persistent = 42 };
    const inst = PathInstance.init(ref, 100, 200, scene.Hsla.red);

    try std.testing.expectEqual(@as(u32, 0), inst.mesh_ref_type);
    try std.testing.expectEqual(@as(u32, 42), inst.mesh_ref_index);
    try std.testing.expectEqual(@as(f32, 100), inst.offset_x);
    try std.testing.expectEqual(@as(f32, 200), inst.offset_y);
    try std.testing.expectEqual(@as(f32, 1), inst.scale_x);
    try std.testing.expectEqual(@as(f32, 1), inst.scale_y);
}

test "PathInstance withClip" {
    const ref = MeshRef{ .frame = 5 };
    const inst = PathInstance.init(ref, 0, 0, scene.Hsla.black)
        .withClip(10, 20, 100, 200);

    try std.testing.expectEqual(@as(f32, 10), inst.clip_x);
    try std.testing.expectEqual(@as(f32, 20), inst.clip_y);
    try std.testing.expectEqual(@as(f32, 100), inst.clip_width);
    try std.testing.expectEqual(@as(f32, 200), inst.clip_height);
}

test "PathInstance withScale" {
    const ref = MeshRef{ .persistent = 0 };
    const inst = PathInstance.init(ref, 0, 0, scene.Hsla.black)
        .withScale(2.5);

    try std.testing.expectEqual(@as(f32, 2.5), inst.scale_x);
    try std.testing.expectEqual(@as(f32, 2.5), inst.scale_y);
}

test "PathInstance getMeshRef" {
    const ref_persistent = MeshRef{ .persistent = 10 };
    const inst1 = PathInstance.init(ref_persistent, 0, 0, scene.Hsla.black);
    try std.testing.expect(inst1.usesPersistentMesh());
    try std.testing.expect(!inst1.usesFrameMesh());
    try std.testing.expectEqual(@as(u16, 10), inst1.getMeshRef().index());

    const ref_frame = MeshRef{ .frame = 20 };
    const inst2 = PathInstance.init(ref_frame, 0, 0, scene.Hsla.black);
    try std.testing.expect(!inst2.usesPersistentMesh());
    try std.testing.expect(inst2.usesFrameMesh());
    try std.testing.expectEqual(@as(u16, 20), inst2.getMeshRef().index());
}

test "PathInstance initWithBufferRanges" {
    const ref = MeshRef{ .persistent = 1 };
    const inst = PathInstance.initWithBufferRanges(
        ref,
        50,
        75,
        scene.Hsla.green,
        100,
        300,
        12,
    );

    try std.testing.expectEqual(@as(u32, 100), inst.vertex_offset);
    try std.testing.expectEqual(@as(u32, 300), inst.index_offset);
    try std.testing.expectEqual(@as(u32, 12), inst.index_count);
}

test "PathInstance withLinearGradient" {
    const ref = MeshRef{ .persistent = 0 };
    const inst = PathInstance.init(ref, 0, 0, scene.Hsla.black)
        .withLinearGradient(0, 0, 100, 50, 3);

    try std.testing.expectEqual(@as(u32, 1), inst.gradient_type);
    try std.testing.expectEqual(@as(u32, 3), inst.gradient_stop_count);
    try std.testing.expectEqual(@as(f32, 0), inst.grad_param0);
    try std.testing.expectEqual(@as(f32, 0), inst.grad_param1);
    try std.testing.expectEqual(@as(f32, 100), inst.grad_param2);
    try std.testing.expectEqual(@as(f32, 50), inst.grad_param3);
    try std.testing.expect(inst.hasGradient());
}

test "PathInstance withRadialGradient" {
    const ref = MeshRef{ .persistent = 0 };
    const inst = PathInstance.init(ref, 0, 0, scene.Hsla.black)
        .withRadialGradient(50, 50, 40, 10, 2);

    try std.testing.expectEqual(@as(u32, 2), inst.gradient_type);
    try std.testing.expectEqual(@as(u32, 2), inst.gradient_stop_count);
    try std.testing.expectEqual(@as(f32, 50), inst.grad_param0);
    try std.testing.expectEqual(@as(f32, 50), inst.grad_param1);
    try std.testing.expectEqual(@as(f32, 40), inst.grad_param2);
    try std.testing.expectEqual(@as(f32, 10), inst.grad_param3);
    try std.testing.expect(inst.hasGradient());
}

test "PathInstance hasGradient" {
    const ref = MeshRef{ .persistent = 0 };

    // Solid color - no gradient
    const solid = PathInstance.init(ref, 0, 0, scene.Hsla.red);
    try std.testing.expect(!solid.hasGradient());

    // With gradient
    const grad = solid.withLinearGradient(0, 0, 100, 0, 2);
    try std.testing.expect(grad.hasGradient());

    // Color clears gradient
    const cleared = grad.withColor(scene.Hsla.blue);
    try std.testing.expect(!cleared.hasGradient());
}

test "PathInstance getClipBounds" {
    const ref = MeshRef{ .persistent = 0 };
    const inst = PathInstance.init(ref, 0, 0, scene.Hsla.black)
        .withClip(10, 20, 100, 200);

    const clip = inst.getClipBounds();
    try std.testing.expectEqual(@as(f32, 10), clip.x);
    try std.testing.expectEqual(@as(f32, 20), clip.y);
    try std.testing.expectEqual(@as(f32, 100), clip.w);
    try std.testing.expectEqual(@as(f32, 200), clip.h);
}

test "ClipBounds equals" {
    const a = ClipBounds{ .x = 10, .y = 20, .w = 100, .h = 200 };
    const b = ClipBounds{ .x = 10, .y = 20, .w = 100, .h = 200 };
    const c = ClipBounds{ .x = 10, .y = 20, .w = 100, .h = 201 };

    try std.testing.expect(a.equals(b));
    try std.testing.expect(!a.equals(c));
}

test "ClipBounds batch grouping scenario" {
    // Simulate grouping consecutive paths with same clip
    const ref = MeshRef{ .persistent = 0 };
    const instances = [_]PathInstance{
        PathInstance.init(ref, 0, 0, scene.Hsla.red).withClip(0, 0, 100, 100),
        PathInstance.init(ref, 10, 10, scene.Hsla.blue).withClip(0, 0, 100, 100), // Same clip
        PathInstance.init(ref, 20, 20, scene.Hsla.green).withClip(50, 50, 200, 200), // Different clip
        PathInstance.init(ref, 30, 30, scene.Hsla.white).withClip(50, 50, 200, 200), // Same as previous
    };

    // Count batch transitions (should be 2: one batch of 2, then one batch of 2)
    var batch_count: u32 = 1;
    var current_clip = instances[0].getClipBounds();
    for (instances[1..]) |inst| {
        const clip = inst.getClipBounds();
        if (!clip.equals(current_clip)) {
            batch_count += 1;
            current_clip = clip;
        }
    }

    try std.testing.expectEqual(@as(u32, 2), batch_count);
}
