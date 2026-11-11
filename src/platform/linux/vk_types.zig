//! GPU types and constants for the Vulkan renderer.
//!
//! Pure data — no Vulkan state, no device handles, no side effects. The
//! packed frame's instance structs (`core/packed_frame.zig`) are the GPU
//! layout: the renderer copies each array into its storage buffer as is, and
//! `shaders/packed.glsl` declares the same structs. The comptime block below
//! pins the offsets that std430 must agree with.

const std = @import("std");
const assert = std.debug.assert;
const packed_mod = @import("../../core/packed_frame.zig");
const limits_mod = @import("../../core/limits.zig");

const SceneLimits = limits_mod.SceneLimits;

// =============================================================================
// Capacity Limits (CLAUDE.md §2 and §4)
// =============================================================================

/// Storage for per-frame resources is declared at the framework ceiling; a
/// renderer creates and rotates through only the window budget's
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

/// Host-pool sub-allocations: one uniform buffer plus the storage buffers, for
/// each frame in flight.
pub fn hostPoolAllocationCount(frame_count: u32) u32 {
    assert(frame_count >= limits_mod.MIN_FRAMES_IN_FLIGHT);
    assert(frame_count <= frame_count_max);
    return frame_count * (1 + frame_buffer_count);
}

/// Element counts of one frame's storage buffers: exactly what a packed frame
/// at the same scene limits can hold (`packed_frame.zig` capacities), so a
/// frame within the budget always fits and the renderer never truncates one.
///
/// Resource sketch, one frame in flight (96 B quads and sprites, 32 B meshes,
/// 8 B points, 4 B edge modes, 16 B uniform):
/// - `.nano`: 272×96 + 1,044×96 + 24×32 + 3,072×8 + 341×4 + 16 = 153,060 B,
///   0.29 MiB for its two frames.
/// - `.standard`: 4,608×96 + 9,472×96 + 1,536×32 + 65,536×8 + 5,461×4 + 16
///   = 1,946,980 B, 5.57 MiB for three frames.
/// The host pool adds `hostPoolAllocationCount × host_pool_alignment_slack_bytes`
/// (48 KiB for two frames, 72 KiB for three) of alignment headroom on top. A
/// frame uploads only the used prefix of each array.
pub const FrameCapacity = struct {
    counts: [frame_buffer_count]u32,

    pub fn fromSceneLimits(scene_limits: *const SceneLimits) FrameCapacity {
        assert(scene_limits.check() == null);
        var capacity: FrameCapacity = undefined;
        capacity.counts[@backingInt(FrameBuffer.quads)] = packed_mod.quadCapacity(scene_limits);
        capacity.counts[@backingInt(FrameBuffer.sprites)] =
            packed_mod.spriteCapacity(scene_limits);
        capacity.counts[@backingInt(FrameBuffer.meshes)] = packed_mod.meshCapacity(scene_limits);
        // A zero-sized storage buffer is invalid; one unused point costs 8 bytes.
        capacity.counts[@backingInt(FrameBuffer.mesh_points)] =
            @max(packed_mod.meshPointCapacity(scene_limits), 1);
        capacity.counts[@backingInt(FrameBuffer.edge_modes)] =
            packed_mod.triangleCapacity(scene_limits);
        for (capacity.counts) |count| assert(count > 0);
        return capacity;
    }

    pub fn countMax(self: *const FrameCapacity, buffer: FrameBuffer) u32 {
        return self.counts[@backingInt(buffer)];
    }

    /// Size of one element of `buffer`; the shader structs match it.
    pub fn elementBytes(buffer: FrameBuffer) u64 {
        return switch (buffer) {
            .quads => @sizeOf(packed_mod.Quad),
            .sprites => @sizeOf(packed_mod.Sprite),
            .meshes => @sizeOf(packed_mod.Mesh),
            .mesh_points => @sizeOf(packed_mod.MeshPoint),
            .edge_modes => @sizeOf(packed_mod.EdgeModes),
        };
    }

    /// Bytes of one frame's storage buffer (count → size: × unit).
    pub fn bufferBytes(self: *const FrameCapacity, buffer: FrameBuffer) u64 {
        const bytes = @as(u64, self.countMax(buffer)) * elementBytes(buffer);
        assert(bytes > 0);
        return bytes;
    }

    /// The first buffer larger than a device's `maxStorageBufferRange`, which
    /// a descriptor could not cover whole, or null when every one fits.
    pub fn bufferPastRange(self: *const FrameCapacity, range_bytes_max: u64) ?FrameBuffer {
        assert(range_bytes_max >= storage_buffer_range_guaranteed_bytes);
        for (std.enums.values(FrameBuffer)) |buffer| {
            if (self.bufferBytes(buffer) > range_bytes_max) return buffer;
        }
        return null;
    }

    /// Bytes of every buffer one frame in flight owns: the storage buffers and
    /// the uniform buffer.
    pub fn frameBytes(self: *const FrameCapacity) u64 {
        var bytes: u64 = @sizeOf(Uniforms);
        for (std.enums.values(FrameBuffer)) |buffer| bytes += self.bufferBytes(buffer);
        assert(bytes > @sizeOf(Uniforms));
        return bytes;
    }

    /// Size of the single host-visible allocation that backs every per-frame
    /// buffer: all `frame_count` frames in flight plus worst-case alignment padding.
    pub fn hostPoolBytes(self: *const FrameCapacity, frame_count: u32) u64 {
        const allocation_count = hostPoolAllocationCount(frame_count);
        const slack_bytes = @as(u64, allocation_count) * host_pool_alignment_slack_bytes;
        const bytes = @as(u64, frame_count) * self.frameBytes() + slack_bytes;
        assert(bytes > slack_bytes);
        return bytes;
    }

    /// The packed frame's used counts, buffer by buffer. A frame is packed at
    /// the limits this capacity was made from, so each count fits.
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

// =============================================================================
// GPU Types
// =============================================================================

/// The framebuffer in logical pixels, written once per frame (binding 5).
/// 16 bytes — single vec4 in std140 layout.
pub const Uniforms = extern struct {
    viewport_width: f32,
    viewport_height: f32,
    _pad0: f32 = 0,
    _pad1: f32 = 0,

    comptime {
        assert(@sizeOf(Uniforms) == 16);
    }
};

/// The mesh a mesh draw renders, `meshes[mesh]`, pushed before each mesh draw.
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

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "FrameCapacity holds exactly a packed frame of the same budget" {
    // Goal: the renderer's per-frame buffers hold what the window's packed frame
    // can hold. Methodology: derive capacities from two named profiles and check
    // counts and byte sizes against the hand-computed resource sketch above.
    const standard = FrameCapacity.fromSceneLimits(&SceneLimits.standard);
    try testing.expectEqual(@as(u32, 4_096 + 512), standard.countMax(.quads));
    try testing.expectEqual(@as(u32, 8_192 + 1_024 + 256), standard.countMax(.sprites));
    try testing.expectEqual(@as(u32, 1_024 + 256 + 256), standard.countMax(.meshes));
    try testing.expectEqual(@as(u32, 16_384 + 32_768 + 16_384), standard.countMax(.mesh_points));
    try testing.expectEqual(@as(u32, 5_461), standard.countMax(.edge_modes));
    try testing.expectEqual(@as(u64, 1_946_980), standard.frameBytes());

    const nano = FrameCapacity.fromSceneLimits(&SceneLimits.nano);
    try testing.expectEqual(@as(u64, 153_060), nano.frameBytes());

    // The pool covers each of the budget's frames in flight plus six
    // allocations' alignment headroom per frame, and nothing for frames the
    // budget does not keep: two frames at `nano`, three at `standard`.
    const slack_bytes: u64 = 6 * host_pool_alignment_slack_bytes;
    try testing.expectEqual(2 * (nano.frameBytes() + slack_bytes), nano.hostPoolBytes(2));
    try testing.expectEqual(
        3 * (standard.frameBytes() + slack_bytes),
        standard.hostPoolBytes(limits_mod.ResourceLimits.standard.frame.in_flight_count),
    );
}

test "FrameCapacity.bufferPastRange names the buffer a device range cannot cover" {
    // Goal: every named profile up to `.large` fits the range every device
    // guarantees, and a budget past a device's range is caught by name.
    // Methodology: the ceiling's mesh points (4,096 paths x 512 vertices, plus
    // 4,096 polylines x 8,192 and 4,096 clouds x 65,536 points, 8 B each) pass
    // 2^27 bytes but fit a 4 GiB range.
    const guaranteed = storage_buffer_range_guaranteed_bytes;
    for ([_]SceneLimits{ .nano, .small, .standard, .large }) |limits| {
        const capacity = FrameCapacity.fromSceneLimits(&limits);
        try testing.expectEqual(null, capacity.bufferPastRange(guaranteed));
    }
    const ceiling = FrameCapacity.fromSceneLimits(&SceneLimits.ceiling);
    try testing.expectEqual(FrameBuffer.mesh_points, ceiling.bufferPastRange(guaranteed).?);
    try testing.expectEqual(null, ceiling.bufferPastRange(1 << 32));
}
