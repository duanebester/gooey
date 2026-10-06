//! GPU types and constants for Vulkan shader communication.
//!
//! Pure data — no Vulkan state, no device handles, no side effects.
//! These types define the CPU ↔ GPU interface contract: struct layouts
//! must match the corresponding GLSL shader declarations exactly.

const std = @import("std");
const assert = std.debug.assert;
const scene_mod = @import("../../scene/mod.zig");
const svg_instance_mod = @import("../../scene/svg_instance.zig");
const image_instance_mod = @import("../../scene/image_instance.zig");
const unified = @import("../unified.zig");

const SceneLimits = scene_mod.SceneLimits;
const SvgInstance = svg_instance_mod.SvgInstance;
const ImageInstance = image_instance_mod.ImageInstance;

// =============================================================================
// Capacity Limits (CLAUDE.md §2 and §4)
// =============================================================================

pub const FRAME_COUNT: u32 = 3;
pub const MAX_SURFACE_FORMATS: u32 = 128;
pub const MAX_PRESENT_MODES: u32 = 16;

/// Host-pool sub-allocations: one uniform buffer plus the four instance buffers
/// of `InstancePool`, for each frame in flight.
pub const host_pool_allocation_count: u32 = FRAME_COUNT * (1 + instance_pool_count);
const instance_pool_count: u32 = @typeInfo(InstancePool).@"enum".field_names.len;

/// Bytes reserved per host-pool sub-allocation for `VkMemoryRequirements.alignment`
/// padding. Drivers report 16 to 256 B for buffers; 4 KiB also covers a page-aligned
/// implementation, and `MemoryPool.allocate` fails fast if a driver asks for more.
pub const host_pool_alignment_slack_bytes: u64 = 4096;

/// The smallest `maxStorageBufferRange` the Vulkan spec guarantees (2^27 bytes).
/// Every instance buffer a valid budget can request stays below it (asserted at
/// comptime below), so the range needs no runtime device query.
pub const storage_buffer_range_guaranteed_bytes: u64 = 1 << 27;

/// The four per-frame instance storage buffers, named in pool-exhaustion reports.
pub const InstancePool = enum { primitives, glyphs, svgs, images };

/// Per-frame instance capacities of the Vulkan storage buffers.
///
/// Derived at renderer init from the window's `ResourceLimits.scene`, the same
/// budget the window's scenes are reserved from, and never changed afterwards.
/// A frame that fits its scene therefore always fits these buffers: quads and
/// shadows share the primitive buffer (`quad + shadow`, like the Metal ring), and
/// glyphs, SVGs and images map one to one onto their scene pools.
///
/// Resource sketch (CLAUDE.md §7), host-visible bytes per frame in flight:
/// - `.standard`: 8,704×128 + 16,384×64 + 1,024×80 + 256×96 + 16 = 2,269,200 B,
///   so 6.49 MiB for three frames (previously a fixed 3.75 MiB in an 8 MiB pool).
/// - `.large`: 9,076,752 B per frame, 25.97 MiB for three frames.
/// - `.ceiling`: 14,155,792 B per frame, 40.50 MiB for three frames.
/// The host pool adds `host_pool_allocation_count × host_pool_alignment_slack_bytes`
/// (60 KiB) of alignment headroom on top.
pub const InstanceCapacity = struct {
    primitive_count_max: u32,
    glyph_count_max: u32,
    svg_count_max: u32,
    image_count_max: u32,

    pub fn fromSceneLimits(scene_limits: *const SceneLimits) InstanceCapacity {
        assert(scene_limits.check() == null);
        const capacity: InstanceCapacity = .{
            .primitive_count_max = scene_limits.unifiedPrimitiveCountMax(),
            .glyph_count_max = scene_limits.glyph_count_frame_max,
            .svg_count_max = scene_limits.svg_count_frame_max,
            .image_count_max = scene_limits.image_count_frame_max,
        };
        assert(capacity.primitive_count_max >= scene_limits.quad_count_frame_max);
        assert(capacity.primitive_count_max >= scene_limits.shadow_count_frame_max);
        return capacity;
    }

    pub fn countMax(self: *const InstanceCapacity, pool: InstancePool) u32 {
        return switch (pool) {
            .primitives => self.primitive_count_max,
            .glyphs => self.glyph_count_max,
            .svgs => self.svg_count_max,
            .images => self.image_count_max,
        };
    }

    /// Size of one GPU instance in `pool`; must match the shader struct layouts.
    pub fn elementBytes(pool: InstancePool) u64 {
        return switch (pool) {
            .primitives => @sizeOf(unified.Primitive),
            .glyphs => @sizeOf(GpuGlyph),
            .svgs => @sizeOf(GpuSvg),
            .images => @sizeOf(GpuImage),
        };
    }

    /// Bytes of one frame's storage buffer for `pool` (count → size: × unit).
    pub fn bufferBytes(self: *const InstanceCapacity, pool: InstancePool) u64 {
        const bytes = @as(u64, self.countMax(pool)) * elementBytes(pool);
        assert(bytes > 0);
        assert(bytes <= storage_buffer_range_guaranteed_bytes);
        return bytes;
    }

    /// Bytes of every buffer one frame in flight owns: four instance buffers and
    /// the uniform buffer.
    pub fn frameBytes(self: *const InstanceCapacity) u64 {
        var bytes: u64 = @sizeOf(Uniforms);
        inline for (@typeInfo(InstancePool).@"enum".field_values) |field_value| {
            bytes += self.bufferBytes(@fromBackingInt(@intCast(field_value)));
        }
        assert(bytes > @sizeOf(Uniforms));
        return bytes;
    }

    /// Size of the single host-visible allocation that backs every per-frame
    /// buffer: all frames in flight plus worst-case alignment padding.
    pub fn hostPoolBytes(self: *const InstanceCapacity) u64 {
        const slack_bytes = @as(u64, host_pool_allocation_count) * host_pool_alignment_slack_bytes;
        const bytes = @as(u64, FRAME_COUNT) * self.frameBytes() + slack_bytes;
        assert(bytes > slack_bytes);
        return bytes;
    }

    /// Whether `requested` more instances fit after `in_use` already claimed.
    pub fn fits(
        self: *const InstanceCapacity,
        pool: InstancePool,
        in_use: u32,
        requested: u32,
    ) bool {
        const capacity = self.countMax(pool);
        assert(in_use <= capacity);
        return requested <= capacity - in_use;
    }

    /// Claim `requested` instances in `pool` after `in_use`. Exhaustion means the
    /// scene outgrew the budget this renderer was sized from, a capacity-planning
    /// error, so it stops the program with the pool, capacity, counts and frame
    /// (CLAUDE.md §2) instead of drawing a truncated frame.
    pub fn reserve(
        self: *const InstanceCapacity,
        pool: InstancePool,
        in_use: u32,
        requested: u32,
        frame: u64,
    ) void {
        assert(requested > 0);
        if (self.fits(pool, in_use, requested)) {
            assert(in_use + requested <= self.countMax(pool));
        } else {
            instancePoolExhausted(pool, self.countMax(pool), in_use, requested, frame);
        }
    }

    comptime {
        // The framework ceiling is the largest budget any app can declare; if its
        // buffers fit the guaranteed storage-buffer range, every budget's do.
        const ceiling = fromSceneLimits(&SceneLimits.ceiling);
        for (@typeInfo(InstancePool).@"enum".field_values) |field_value| {
            const pool: InstancePool = @fromBackingInt(@intCast(field_value));
            const bytes = @as(u64, ceiling.countMax(pool)) * elementBytes(pool);
            assert(bytes <= storage_buffer_range_guaranteed_bytes);
        }
    }
};

fn instancePoolExhausted(
    pool: InstancePool,
    capacity: u32,
    in_use: u32,
    requested: u32,
    frame: u64,
) noreturn {
    @branchHint(.cold);
    std.debug.panic(
        "Vulkan instance buffer '{s}' exhausted: capacity {d} (ResourceLimits.scene), " ++
            "{d} in use, {d} requested, frame {d}. The scene outgrew the renderer's budget.",
        .{ @tagName(pool), capacity, in_use, requested, frame },
    );
}

// =============================================================================
// GPU Types
// =============================================================================

/// Uniform buffer data pushed once per frame.
/// 16 bytes — single vec4 in std140 layout.
pub const Uniforms = extern struct {
    viewport_width: f32,
    viewport_height: f32,
    _pad0: f32 = 0,
    _pad1: f32 = 0,

    comptime {
        std.debug.assert(@sizeOf(Uniforms) == 16);
    }
};

/// GPU-ready glyph instance data (matches text shader struct layout).
/// 64 bytes = 16 floats.
pub const GpuGlyph = extern struct {
    pos_x: f32 = 0,
    pos_y: f32 = 0,
    size_x: f32 = 0,
    size_y: f32 = 0,
    uv_left: f32 = 0,
    uv_top: f32 = 0,
    uv_right: f32 = 0,
    uv_bottom: f32 = 0,
    color_h: f32 = 0,
    color_s: f32 = 0,
    color_l: f32 = 1,
    color_a: f32 = 1,
    clip_x: f32 = 0,
    clip_y: f32 = 0,
    clip_width: f32 = 99999,
    clip_height: f32 = 99999,

    comptime {
        std.debug.assert(@sizeOf(GpuGlyph) == 64);
    }

    pub fn fromScene(g: scene_mod.GlyphInstance) GpuGlyph {
        return .{
            .pos_x = g.pos_x,
            .pos_y = g.pos_y,
            .size_x = g.size_x,
            .size_y = g.size_y,
            .uv_left = g.uv_left,
            .uv_top = g.uv_top,
            .uv_right = g.uv_right,
            .uv_bottom = g.uv_bottom,
            .color_h = g.color.h,
            .color_s = g.color.s,
            .color_l = g.color.l,
            .color_a = g.color.a,
            .clip_x = g.clip_x,
            .clip_y = g.clip_y,
            .clip_width = g.clip_width,
            .clip_height = g.clip_height,
        };
    }
};

/// GPU-ready SVG instance data (matches SVG shader struct layout).
/// 80 bytes = 20 floats.
pub const GpuSvg = extern struct {
    // Position and size
    pos_x: f32 = 0,
    pos_y: f32 = 0,
    size_x: f32 = 0,
    size_y: f32 = 0,
    // UV coordinates
    uv_left: f32 = 0,
    uv_top: f32 = 0,
    uv_right: f32 = 0,
    uv_bottom: f32 = 0,
    // Fill color (HSLA)
    fill_h: f32 = 0,
    fill_s: f32 = 0,
    fill_l: f32 = 0,
    fill_a: f32 = 0,
    // Stroke color (HSLA)
    stroke_h: f32 = 0,
    stroke_s: f32 = 0,
    stroke_l: f32 = 0,
    stroke_a: f32 = 0,
    // Clip bounds
    clip_x: f32 = 0,
    clip_y: f32 = 0,
    clip_width: f32 = 99999,
    clip_height: f32 = 99999,

    comptime {
        std.debug.assert(@sizeOf(GpuSvg) == 80);
    }

    pub fn fromScene(s: SvgInstance) GpuSvg {
        return .{
            .pos_x = s.pos_x,
            .pos_y = s.pos_y,
            .size_x = s.size_x,
            .size_y = s.size_y,
            .uv_left = s.uv_left,
            .uv_top = s.uv_top,
            .uv_right = s.uv_right,
            .uv_bottom = s.uv_bottom,
            .fill_h = s.color.h,
            .fill_s = s.color.s,
            .fill_l = s.color.l,
            .fill_a = s.color.a,
            .stroke_h = s.stroke_color.h,
            .stroke_s = s.stroke_color.s,
            .stroke_l = s.stroke_color.l,
            .stroke_a = s.stroke_color.a,
            .clip_x = s.clip_x,
            .clip_y = s.clip_y,
            .clip_width = s.clip_width,
            .clip_height = s.clip_height,
        };
    }
};

/// GPU-ready Image instance data (matches image shader struct layout).
/// 96 bytes = 24 floats.
pub const GpuImage = extern struct {
    // Position and size
    pos_x: f32 = 0,
    pos_y: f32 = 0,
    dest_width: f32 = 0,
    dest_height: f32 = 0,
    // UV coordinates
    uv_left: f32 = 0,
    uv_top: f32 = 0,
    uv_right: f32 = 0,
    uv_bottom: f32 = 0,
    // Tint color (HSLA)
    tint_h: f32 = 0,
    tint_s: f32 = 0,
    tint_l: f32 = 1,
    tint_a: f32 = 1,
    // Clip bounds
    clip_x: f32 = 0,
    clip_y: f32 = 0,
    clip_width: f32 = 99999,
    clip_height: f32 = 99999,
    // Corner radii
    corner_tl: f32 = 0,
    corner_tr: f32 = 0,
    corner_br: f32 = 0,
    corner_bl: f32 = 0,
    // Effects
    grayscale: f32 = 0,
    opacity: f32 = 1,
    _pad0: f32 = 0,
    _pad1: f32 = 0,

    comptime {
        std.debug.assert(@sizeOf(GpuImage) == 96);
    }

    pub fn fromScene(img: ImageInstance) GpuImage {
        return .{
            .pos_x = img.pos_x,
            .pos_y = img.pos_y,
            .dest_width = img.dest_width,
            .dest_height = img.dest_height,
            .uv_left = img.uv_left,
            .uv_top = img.uv_top,
            .uv_right = img.uv_right,
            .uv_bottom = img.uv_bottom,
            .tint_h = img.tint.h,
            .tint_s = img.tint.s,
            .tint_l = img.tint.l,
            .tint_a = img.tint.a,
            .clip_x = img.clip_x,
            .clip_y = img.clip_y,
            .clip_width = img.clip_width,
            .clip_height = img.clip_height,
            .corner_tl = img.corner_tl,
            .corner_tr = img.corner_tr,
            .corner_br = img.corner_br,
            .corner_bl = img.corner_bl,
            .grayscale = img.grayscale,
            .opacity = img.opacity,
        };
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "InstanceCapacity mirrors the scene budget and sizes the host pool from it" {
    // Goal: the renderer's per-frame buffers hold exactly what the window's scene
    // can hold. Methodology: derive capacities from each named profile and check
    // counts and byte sizes against the hand-computed resource sketch above.
    const standard = InstanceCapacity.fromSceneLimits(&SceneLimits.standard);
    try testing.expectEqual(@as(u32, 8_192 + 512), standard.primitive_count_max);
    try testing.expectEqual(@as(u32, 16_384), standard.glyph_count_max);
    try testing.expectEqual(@as(u32, 1_024), standard.svg_count_max);
    try testing.expectEqual(@as(u32, 256), standard.image_count_max);
    try testing.expectEqual(@as(u64, 2_269_200), standard.frameBytes());

    const large = InstanceCapacity.fromSceneLimits(&SceneLimits.large);
    try testing.expectEqual(@as(u64, 9_076_752), large.frameBytes());

    const ceiling = InstanceCapacity.fromSceneLimits(&SceneLimits.ceiling);
    try testing.expectEqual(@as(u64, 14_155_792), ceiling.frameBytes());

    // The pool always covers every frame plus the alignment headroom, so the
    // fixed 8 MiB pool it replaced could not have held `.large` or `.ceiling`.
    const slack_bytes: u64 = host_pool_allocation_count * host_pool_alignment_slack_bytes;
    try testing.expectEqual(3 * standard.frameBytes() + slack_bytes, standard.hostPoolBytes());
    try testing.expect(large.hostPoolBytes() > 8 * 1024 * 1024);
    try testing.expect(ceiling.hostPoolBytes() > large.hostPoolBytes());
}

test "InstanceCapacity.fits accepts a full pool and rejects one more instance" {
    // Goal: the boundary of every pool is exact. Methodology: with a tiny budget,
    // fill each pool to capacity in two claims (the last one lands exactly on the
    // capacity), then ask for one more. `reserve` panics where `fits` is false;
    // `scene-overflow-check vulkan-instances` asserts that panic and its message
    // in a child process, since a panic cannot be caught in-process.
    const tiny: SceneLimits = .{
        .quad_count_frame_max = 3,
        .shadow_count_frame_max = 2,
        .glyph_count_frame_max = @import("../../core/limits.zig").MAX_GLYPHS_PER_RUN,
        .svg_count_frame_max = 4,
        .image_count_frame_max = 4,
        .path_count_frame_max = 4,
        .polyline_count_frame_max = 4,
        .point_cloud_count_frame_max = 4,
        .colored_point_cloud_count_frame_max = 4,
        .clip_depth_max = 4,
    };
    const capacity = InstanceCapacity.fromSceneLimits(&tiny);
    try testing.expectEqual(@as(u32, 5), capacity.primitive_count_max);

    inline for (@typeInfo(InstancePool).@"enum".field_values) |field_value| {
        const pool: InstancePool = @fromBackingInt(@intCast(field_value));
        const count_max = capacity.countMax(pool);
        try testing.expect(capacity.fits(pool, 0, count_max - 1));
        capacity.reserve(pool, 0, count_max - 1, 0);
        try testing.expect(capacity.fits(pool, count_max - 1, 1));
        capacity.reserve(pool, count_max - 1, 1, 0); // last valid claim
        try testing.expect(!capacity.fits(pool, count_max, 1)); // one past the end
        try testing.expect(!capacity.fits(pool, 0, count_max + 1));
    }
}
