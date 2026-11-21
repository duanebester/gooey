const std = @import("std");
const assert = std.debug.assert;
const packed_mod = @import("../../core/packed_frame.zig");
const limits_mod = @import("../../core/limits.zig");

const PaintLimits = limits_mod.PaintLimits;

/// Framework ceiling; a renderer rotates through only the window budget's
/// `ResourceLimits.frame.in_flight_count` of them.
pub const frame_count_max: u32 = limits_mod.MAX_FRAMES_IN_FLIGHT;
pub const MAX_SURFACE_FORMATS: u32 = 128;
pub const MAX_PRESENT_MODES: u32 = 16;

/// Bytes reserved per host-pool sub-allocation for `VkMemoryRequirements.alignment`
/// padding. Drivers report 16 to 256 B for buffers; 4 KiB also covers a page-aligned
/// implementation, and `MemoryPool.allocate` fails fast if a driver asks for more.
pub const host_pool_alignment_slack_bytes: u64 = 4096;

/// The smallest `maxStorageBufferRange` the Vulkan spec guarantees (2^27 bytes).
/// The profiles up to `.large` stay below it; a larger budget, such as the
/// ceiling's mesh points, needs a device that reports a larger range, which
/// `initInPlace` checks (`FrameCapacity.bufferPastRange`).
pub const storage_buffer_range_guaranteed_bytes: u64 = 1 << 27;

/// The per-frame storage buffers, one per packed-frame array, in binding order
/// (`shaders/packed.glsl` bindings 0 to 4).
pub const FrameBuffer = enum(u8) { quads, sprites, meshes, mesh_points, edge_modes };

pub const frame_buffer_count: u32 = @typeInfo(FrameBuffer).@"enum".field_names.len;

pub fn hostPoolAllocationCount(frame_count: u32) u32 {
    assert(frame_count >= limits_mod.MIN_FRAMES_IN_FLIGHT);
    assert(frame_count <= frame_count_max);
    return frame_count * (1 + frame_buffer_count);
}

/// Element counts of one frame's storage buffers: exactly what a packed frame
/// at the same paint limits can hold, so a frame within the budget always fits
/// and the renderer never truncates one.
pub const FrameCapacity = struct {
    counts: [frame_buffer_count]u32,

    pub fn fromPaintLimits(paint_limits: *const PaintLimits) FrameCapacity {
        assert(paint_limits.check() == null);
        var capacity: FrameCapacity = undefined;
        capacity.counts[@backingInt(FrameBuffer.quads)] = packed_mod.quadCapacity(paint_limits);
        capacity.counts[@backingInt(FrameBuffer.sprites)] =
            packed_mod.spriteCapacity(paint_limits);
        capacity.counts[@backingInt(FrameBuffer.meshes)] = packed_mod.meshCapacity(paint_limits);
        // A zero-sized storage buffer is invalid; one unused point costs 8 bytes.
        capacity.counts[@backingInt(FrameBuffer.mesh_points)] =
            @max(packed_mod.meshPointCapacity(paint_limits), 1);
        capacity.counts[@backingInt(FrameBuffer.edge_modes)] =
            packed_mod.triangleCapacity(paint_limits);
        for (capacity.counts) |count| assert(count > 0);
        return capacity;
    }

    pub fn countMax(self: *const FrameCapacity, buffer: FrameBuffer) u32 {
        return self.counts[@backingInt(buffer)];
    }

    /// The shader structs match these sizes.
    pub fn elementBytes(buffer: FrameBuffer) u64 {
        return switch (buffer) {
            .quads => @sizeOf(packed_mod.Quad),
            .sprites => @sizeOf(packed_mod.Sprite),
            .meshes => @sizeOf(packed_mod.Mesh),
            .mesh_points => @sizeOf(packed_mod.MeshPoint),
            .edge_modes => @sizeOf(packed_mod.EdgeModes),
        };
    }

    pub fn bufferBytes(self: *const FrameCapacity, buffer: FrameBuffer) u64 {
        const bytes = @as(u64, self.countMax(buffer)) * elementBytes(buffer);
        assert(bytes > 0);
        return bytes;
    }

    pub fn bufferPastRange(self: *const FrameCapacity, range_bytes_max: u64) ?FrameBuffer {
        assert(range_bytes_max >= storage_buffer_range_guaranteed_bytes);
        for (std.enums.values(FrameBuffer)) |buffer| {
            if (self.bufferBytes(buffer) > range_bytes_max) return buffer;
        }
        return null;
    }

    pub fn frameBytes(self: *const FrameCapacity) u64 {
        var bytes: u64 = @sizeOf(Uniforms);
        for (std.enums.values(FrameBuffer)) |buffer| bytes += self.bufferBytes(buffer);
        assert(bytes > @sizeOf(Uniforms));
        return bytes;
    }

    pub fn hostPoolBytes(self: *const FrameCapacity, frame_count: u32) u64 {
        const allocation_count = hostPoolAllocationCount(frame_count);
        const slack_bytes = @as(u64, allocation_count) * host_pool_alignment_slack_bytes;
        const bytes = @as(u64, frame_count) * self.frameBytes() + slack_bytes;
        assert(bytes > slack_bytes);
        return bytes;
    }

    /// A frame is packed at the limits this capacity was made from, so each
    /// count fits.
    pub fn usedCounts(frame: *const packed_mod.PackedFrame) [frame_buffer_count]u32 {
        assert(frame.mesh_points.len <= std.math.maxInt(u32));
        return .{
            frame.quad_count,
            frame.sprite_count,
            frame.mesh_count,
            @intCast(frame.mesh_points.len),
            frame.triangle_count,
        };
    }
};

/// Framebuffer size in logical pixels, written once per frame (binding 5,
/// std140: a single vec4).
pub const Uniforms = extern struct {
    viewport_width: f32,
    viewport_height: f32,
    _pad0: f32 = 0,
    _pad1: f32 = 0,

    comptime {
        assert(@sizeOf(Uniforms) == 16);
    }
};

/// Index into `meshes`, pushed before each mesh draw.
pub const PushConstants = extern struct {
    mesh: u32,

    comptime {
        assert(@sizeOf(PushConstants) == 4);
    }
};

comptime {
    // `shaders/packed.glsl` reads the packed structs with std430 rules: every
    // vec4 at a 16-byte boundary, scalars after it, arrays at the struct size.
    const Quad = packed_mod.Quad;
    assert(@offsetOf(Quad, "fill") == 16);
    assert(@offsetOf(Quad, "border_color") == 32);
    assert(@offsetOf(Quad, "corners") == 48);
    assert(@offsetOf(Quad, "border_widths") == 64);
    assert(@offsetOf(Quad, "offset") == 80);
    assert(@offsetOf(Quad, "blur") == 88);
    assert(@sizeOf(Quad) == 96);
    const Sprite = packed_mod.Sprite;
    assert(@offsetOf(Sprite, "uv") == 16);
    assert(@offsetOf(Sprite, "tint") == 32);
    assert(@offsetOf(Sprite, "secondary") == 48);
    assert(@offsetOf(Sprite, "corners") == 64);
    assert(@offsetOf(Sprite, "grayscale") == 80);
    assert(@offsetOf(Sprite, "opacity") == 84);
    assert(@sizeOf(Sprite) == 96);
    const Mesh = packed_mod.Mesh;
    assert(@offsetOf(Mesh, "first") == 16);
    assert(@offsetOf(Mesh, "count") == 20);
    assert(@offsetOf(Mesh, "width") == 24);
    assert(@offsetOf(Mesh, "edge_first") == 28);
    assert(@sizeOf(Mesh) == 32);
    // `vec2 mesh_points[]` has an 8-byte stride; `uint triangle_edge_modes[]` 4.
    assert(@sizeOf(packed_mod.MeshPoint) == 8);
    assert(@sizeOf(packed_mod.EdgeModes) == 4);
}

const testing = std.testing;

test "FrameCapacity holds exactly a packed frame of the same budget" {
    const standard = FrameCapacity.fromPaintLimits(&PaintLimits.standard);
    try testing.expectEqual(@as(u32, 4_096 + 512), standard.countMax(.quads));
    try testing.expectEqual(@as(u32, 8_192 + 1_024 + 256), standard.countMax(.sprites));
    try testing.expectEqual(@as(u32, 1_024 + 256 + 256), standard.countMax(.meshes));
    try testing.expectEqual(@as(u32, 16_384 + 32_768 + 16_384), standard.countMax(.mesh_points));
    try testing.expectEqual(@as(u32, 5_461), standard.countMax(.edge_modes));
    try testing.expectEqual(@as(u64, 1_946_980), standard.frameBytes());

    const nano = FrameCapacity.fromPaintLimits(&PaintLimits.nano);
    try testing.expectEqual(@as(u64, 153_060), nano.frameBytes());

    const slack_bytes: u64 = 6 * host_pool_alignment_slack_bytes;
    try testing.expectEqual(2 * (nano.frameBytes() + slack_bytes), nano.hostPoolBytes(2));
    try testing.expectEqual(
        3 * (standard.frameBytes() + slack_bytes),
        standard.hostPoolBytes(limits_mod.ResourceLimits.standard.frame.in_flight_count),
    );
}

test "FrameCapacity.bufferPastRange names the buffer a device range cannot cover" {
    const guaranteed = storage_buffer_range_guaranteed_bytes;
    for ([_]PaintLimits{ .nano, .small, .standard, .large }) |limits| {
        const capacity = FrameCapacity.fromPaintLimits(&limits);
        try testing.expectEqual(null, capacity.bufferPastRange(guaranteed));
    }
    const ceiling = FrameCapacity.fromPaintLimits(&PaintLimits.ceiling);
    try testing.expectEqual(FrameBuffer.mesh_points, ceiling.bufferPastRange(guaranteed).?);
    try testing.expectEqual(null, ceiling.bufferPastRange(1 << 32));
}
