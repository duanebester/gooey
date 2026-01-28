//! WebRenderer - GPU rendering for WebAssembly/WebGPU
//!
//! Takes a gooey Scene and renders it to WebGPU. This is the web equivalent
//! of the Metal renderer on macOS.

const std = @import("std");
const imports = @import("imports.zig");
const unified = @import("../unified.zig");
const scene_mod = @import("../../../scene/mod.zig");
const GradientUniforms = scene_mod.GradientUniforms;
const batch_iter = @import("../../../scene/batch_iterator.zig");
const text_mod = @import("../../../text/mod.zig");
const svg_mod = @import("../../../svg/mod.zig");
const image_mod = @import("../../../image/mod.zig");
const custom_shader = @import("custom_shader.zig");
const path_mesh_mod = @import("../../../scene/path_mesh.zig");
const path_instance_mod = @import("../../../scene/path_instance.zig");
const mesh_pool_mod = @import("../../../scene/mesh_pool.zig");
const polyline_mod = @import("../../../scene/polyline.zig");
const point_cloud_mod = @import("../../../scene/point_cloud.zig");

const Scene = scene_mod.Scene;
const SvgInstance = scene_mod.SvgInstance;
const TextSystem = text_mod.TextSystem;
const SvgAtlas = svg_mod.SvgAtlas;
const ImageAtlas = image_mod.ImageAtlas;
const ImageInstance = scene_mod.ImageInstance;
const PostProcessState = custom_shader.PostProcessState;
const PathInstance = path_instance_mod.PathInstance;
const ClipBounds = path_instance_mod.ClipBounds;
const PathVertex = path_mesh_mod.PathVertex;
const SolidPathVertex = path_mesh_mod.SolidPathVertex;
const MeshPool = mesh_pool_mod.MeshPool;
const Polyline = polyline_mod.Polyline;
const PointCloud = point_cloud_mod.PointCloud;

// =============================================================================
// Constants
// =============================================================================

pub const MAX_PRIMITIVES: u32 = 4096;
pub const MAX_GLYPHS: u32 = 8192;
pub const MAX_SVGS: u32 = 1024;
pub const MAX_IMAGES: u32 = 512;

// Path batch buffer limits - these are LARGER than per-path limits because
// these buffers hold MULTIPLE paths in a single batch upload.
// See src/core/limits.zig for the full limit hierarchy documentation.
//
// Per-path limit: 512 vertices, 1530 indices (from triangulator.zig)
// Batch capacity: ~32 max-size paths (16384 / 512)
pub const MAX_PATHS = 256;
pub const MAX_PATH_VERTICES = 16384;
pub const MAX_PATH_INDICES = 49152;

// Phase 4: Gradient path batching - storage buffer for instance + gradient data
pub const MAX_GRADIENT_BATCH_PATHS = 64;
pub const MAX_GRADIENT_BATCH_VERTICES = 8192;
pub const MAX_GRADIENT_BATCH_INDICES = MAX_GRADIENT_BATCH_VERTICES * 3;

// Phase 2: Solid path batching limits (static allocation per CLAUDE.md)
pub const MAX_SOLID_BATCH_VERTICES: u32 = path_mesh_mod.MAX_SOLID_BATCH_VERTICES;
pub const MAX_SOLID_BATCH_INDICES: u32 = MAX_SOLID_BATCH_VERTICES * 3; // Worst case: 3 indices per vertex

// Polyline buffer limits - expanded quads (4 vertices per segment)
// Supports ~4000 line segments per batch
pub const MAX_POLYLINE_VERTICES: u32 = 16384;
pub const MAX_POLYLINE_INDICES: u32 = 24576;

// Point cloud buffer limits - quads for SDF circles (4 vertices per point)
// Supports ~4000 points per batch
pub const MAX_POINT_CLOUD_VERTICES: u32 = 16384;
pub const MAX_POINT_CLOUD_INDICES: u32 = 24576;

// =============================================================================
// GPU Types
// =============================================================================

pub const Uniforms = extern struct {
    viewport_width: f32,
    viewport_height: f32,
};

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

/// GPU-ready SVG instance data (matches SvgInstance layout - 80 bytes)
pub const GpuSvgInstance = extern struct {
    // Screen position (top-left, logical pixels)
    pos_x: f32 = 0,
    pos_y: f32 = 0,
    // Size (logical pixels)
    size_x: f32 = 0,
    size_y: f32 = 0,
    // Atlas UV coordinates
    uv_left: f32 = 0,
    uv_top: f32 = 0,
    uv_right: f32 = 0,
    uv_bottom: f32 = 0,
    // Fill color (HSLA)
    fill_h: f32 = 0,
    fill_s: f32 = 0,
    fill_l: f32 = 0,
    fill_a: f32 = 1,
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

    pub fn fromScene(s: SvgInstance) GpuSvgInstance {
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

// Verify GpuSvgInstance matches SvgInstance size
comptime {
    if (@sizeOf(GpuSvgInstance) != 80) {
        @compileError(std.fmt.comptimePrint(
            "GpuSvgInstance must be 80 bytes, got {}",
            .{@sizeOf(GpuSvgInstance)},
        ));
    }
}

/// GPU-ready path instance data for WGSL shader
/// Matches the PathInstance struct layout in path.wgsl
pub const GpuPathInstance = extern struct {
    offset_x: f32 = 0,
    offset_y: f32 = 0,
    scale_x: f32 = 1,
    scale_y: f32 = 1,
    // Fill color (HSLA) - 4 floats
    fill_h: f32 = 0,
    fill_s: f32 = 0,
    fill_l: f32 = 0,
    fill_a: f32 = 1,
    // Clip bounds
    clip_x: f32 = 0,
    clip_y: f32 = 0,
    clip_width: f32 = 99999,
    clip_height: f32 = 99999,
    // Gradient fields
    gradient_type: u32 = 0, // 0=none, 1=linear, 2=radial
    gradient_stop_count: u32 = 0,
    _grad_pad0: u32 = 0,
    _grad_pad1: u32 = 0,
    // Gradient params: linear(start_x, start_y, end_x, end_y) / radial(center_x, center_y, radius, inner_radius)
    grad_param0: f32 = 0,
    grad_param1: f32 = 0,
    grad_param2: f32 = 0,
    grad_param3: f32 = 0,

    pub fn fromScene(p: PathInstance) GpuPathInstance {
        return .{
            .offset_x = p.offset_x,
            .offset_y = p.offset_y,
            .scale_x = p.scale_x,
            .scale_y = p.scale_y,
            .fill_h = p.fill_color.h,
            .fill_s = p.fill_color.s,
            .fill_l = p.fill_color.l,
            .fill_a = p.fill_color.a,
            .clip_x = p.clip_x,
            .clip_y = p.clip_y,
            .clip_width = p.clip_width,
            .clip_height = p.clip_height,
            .gradient_type = p.gradient_type,
            .gradient_stop_count = p.gradient_stop_count,
            .grad_param0 = p.grad_param0,
            .grad_param1 = p.grad_param1,
            .grad_param2 = p.grad_param2,
            .grad_param3 = p.grad_param3,
        };
    }
};

// Verify GpuPathInstance size (80 bytes = 20 floats/uints)
comptime {
    if (@sizeOf(GpuPathInstance) != 80) {
        @compileError(std.fmt.comptimePrint(
            "GpuPathInstance must be 80 bytes, got {}",
            .{@sizeOf(GpuPathInstance)},
        ));
    }
}

/// GPU gradient uniforms (352 bytes)
/// Matches GradientUniforms in gradient_uniforms.zig
/// Note: Arrays use [4][4]f32 (equivalent to array<vec4<f32>, 4>) for WGSL uniform
/// 16-byte alignment requirements. Each inner [4]f32 maps to a vec4.
pub const GpuGradientUniforms = extern struct {
    gradient_type: u32 = 0,
    stop_count: u32 = 0,
    _pad0: u32 = 0,
    _pad1: u32 = 0,
    param0: f32 = 0,
    param1: f32 = 0,
    param2: f32 = 0,
    param3: f32 = 0,
    // Each array is 4 vec4s = 16 floats, matching WGSL array<vec4<f32>, 4>
    stop_offsets: [4][4]f32 = [_][4]f32{[_]f32{0} ** 4} ** 4,
    stop_h: [4][4]f32 = [_][4]f32{[_]f32{0} ** 4} ** 4,
    stop_s: [4][4]f32 = [_][4]f32{[_]f32{0} ** 4} ** 4,
    stop_l: [4][4]f32 = [_][4]f32{[_]f32{0} ** 4} ** 4,
    stop_a: [4][4]f32 = [_][4]f32{[_]f32{1} ** 4} ** 4,

    /// Create empty gradient uniforms (for solid color fills)
    pub fn none() GpuGradientUniforms {
        return .{};
    }

    /// Copy a flat [16]f32 array into the packed [4][4]f32 format
    fn copyToPacked(dst: *[4][4]f32, src: *const [16]f32) void {
        for (0..4) |i| {
            for (0..4) |j| {
                dst[i][j] = src[i * 4 + j];
            }
        }
    }

    /// Initialize from a scene GradientUniforms
    pub fn fromScene(scene_gradient: GradientUniforms) GpuGradientUniforms {
        var result = GpuGradientUniforms{
            .gradient_type = scene_gradient.gradient_type,
            .stop_count = scene_gradient.stop_count,
            .param0 = scene_gradient.param0,
            .param1 = scene_gradient.param1,
            .param2 = scene_gradient.param2,
            .param3 = scene_gradient.param3,
        };
        copyToPacked(&result.stop_offsets, &scene_gradient.stop_offsets);
        copyToPacked(&result.stop_h, &scene_gradient.stop_h);
        copyToPacked(&result.stop_s, &scene_gradient.stop_s);
        copyToPacked(&result.stop_l, &scene_gradient.stop_l);
        copyToPacked(&result.stop_a, &scene_gradient.stop_a);
        return result;
    }
};

// Verify GpuGradientUniforms size (352 bytes)
comptime {
    if (@sizeOf(GpuGradientUniforms) != 352) {
        @compileError(std.fmt.comptimePrint(
            "GpuGradientUniforms must be 352 bytes, got {}",
            .{@sizeOf(GpuGradientUniforms)},
        ));
    }
}

/// Draw call info for batched path rendering
/// Records the parameters needed to issue a drawIndexed call after batch upload
pub const DrawCallInfo = struct {
    index_count: u32,
    index_offset: u32,
    instance_index: u32,
};

// =============================================================================
// Phase 2: Solid Path Batching GPU Types
// =============================================================================

/// GPU-ready solid path vertex for batched rendering (32 bytes)
/// Transform and color baked in at upload time - matches SolidPathVertex in path_solid.wgsl
pub const GpuSolidPathVertex = extern struct {
    x: f32 = 0, // Already transformed screen position
    y: f32 = 0,
    u: f32 = 0, // UV (preserved for future use)
    v: f32 = 0,
    color_h: f32 = 0, // HSLA color baked in
    color_s: f32 = 0,
    color_l: f32 = 0,
    color_a: f32 = 1,

    /// Create from a base PathVertex with transform and color baked in
    pub fn fromPathVertex(
        pv: PathVertex,
        offset_x: f32,
        offset_y: f32,
        scale_x: f32,
        scale_y: f32,
        color_h: f32,
        color_s: f32,
        color_l: f32,
        color_a: f32,
    ) GpuSolidPathVertex {
        return .{
            // Bake transform into position: scale then translate
            .x = pv.x * scale_x + offset_x,
            .y = pv.y * scale_y + offset_y,
            .u = pv.u,
            .v = pv.v,
            .color_h = color_h,
            .color_s = color_s,
            .color_l = color_l,
            .color_a = color_a,
        };
    }
};

// Verify GpuSolidPathVertex size (32 bytes)
comptime {
    if (@sizeOf(GpuSolidPathVertex) != 32) {
        @compileError(std.fmt.comptimePrint(
            "GpuSolidPathVertex must be 32 bytes, got {}",
            .{@sizeOf(GpuSolidPathVertex)},
        ));
    }
}

/// GPU-ready clip bounds for solid path shader (16 bytes)
/// Uniform shared by entire batch - matches ClipBounds in path_solid.wgsl
pub const GpuClipBounds = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 99999,
    height: f32 = 99999,

    /// Create from scene ClipBounds
    pub fn fromClipBounds(cb: ClipBounds) GpuClipBounds {
        return .{
            .x = cb.x,
            .y = cb.y,
            .width = cb.w,
            .height = cb.h,
        };
    }
};

// Verify GpuClipBounds size (16 bytes)
comptime {
    if (@sizeOf(GpuClipBounds) != 16) {
        @compileError(std.fmt.comptimePrint(
            "GpuClipBounds must be 16 bytes, got {}",
            .{@sizeOf(GpuClipBounds)},
        ));
    }
}

/// GPU-ready polyline vertex (8 bytes)
/// Matches PolylineVertex in polyline.wgsl
pub const GpuPolylineVertex = extern struct {
    x: f32 = 0,
    y: f32 = 0,
};

/// GPU-ready polyline uniforms (32 bytes)
/// Matches PolylineUniforms in polyline.wgsl
pub const GpuPolylineUniforms = extern struct {
    color_h: f32 = 0,
    color_s: f32 = 0,
    color_l: f32 = 0,
    color_a: f32 = 1,
    clip_x: f32 = 0,
    clip_y: f32 = 0,
    clip_width: f32 = 99999,
    clip_height: f32 = 99999,
};

// Verify GpuPolylineUniforms size (32 bytes)
comptime {
    if (@sizeOf(GpuPolylineUniforms) != 32) {
        @compileError(std.fmt.comptimePrint(
            "GpuPolylineUniforms must be 32 bytes, got {}",
            .{@sizeOf(GpuPolylineUniforms)},
        ));
    }
}

/// GPU-ready point cloud vertex (16 bytes)
/// Matches PointVertex in point_cloud.wgsl
pub const GpuPointVertex = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    u: f32 = 0, // UV for SDF (-1 to 1)
    v: f32 = 0,
};

/// GPU-ready point cloud uniforms (48 bytes)
/// Matches PointCloudUniforms in point_cloud.wgsl
pub const GpuPointCloudUniforms = extern struct {
    color_h: f32 = 0,
    color_s: f32 = 0,
    color_l: f32 = 0,
    color_a: f32 = 1,
    clip_x: f32 = 0,
    clip_y: f32 = 0,
    clip_width: f32 = 99999,
    clip_height: f32 = 99999,
    radius: f32 = 4,
    _pad0: f32 = 0,
    _pad1: f32 = 0,
    _pad2: f32 = 0,
};

// Verify GpuPointCloudUniforms size (48 bytes)
comptime {
    if (@sizeOf(GpuPointCloudUniforms) != 48) {
        @compileError(std.fmt.comptimePrint(
            "GpuPointCloudUniforms must be 48 bytes, got {}",
            .{@sizeOf(GpuPointCloudUniforms)},
        ));
    }
}

// =============================================================================
// WebRenderer
// =============================================================================

/// Batch descriptor for deferred rendering
const BatchDesc = struct {
    kind: batch_iter.PrimitiveKind,
    start: u32,
    count: u32,
};

const MAX_BATCHES: u32 = 256;

// Phase 1 batching: max clip regions per frame (per CLAUDE.md: put a limit on everything)
const MAX_CLIP_BATCHES: u32 = 64;

/// Clip batch info for Phase 1 optimization
/// Tracks a contiguous range of paths sharing the same clip bounds
const ClipBatch = struct {
    clip: ClipBounds,
    start_index: u32,
    end_index: u32, // exclusive

    pub fn count(self: ClipBatch) u32 {
        return self.end_index - self.start_index;
    }
};

pub const WebRenderer = struct {
    allocator: std.mem.Allocator,

    // Primitives (quads, shadows)
    pipeline: u32 = 0,
    primitive_buffer: u32 = 0,
    bind_group: u32 = 0,
    primitives: [MAX_PRIMITIVES]unified.Primitive = undefined,

    // Shared
    uniform_buffer: u32 = 0,
    sampler: u32 = 0,

    // Text rendering
    text_pipeline: u32 = 0,
    glyph_buffer: u32 = 0,
    text_bind_group: u32 = 0,
    atlas_texture: u32 = 0,
    atlas_generation: u32 = 0,
    atlas_texture_size: u32 = 0,
    gpu_glyphs: [MAX_GLYPHS]GpuGlyph = undefined,

    // SVG rendering
    svg_pipeline: u32 = 0,
    svg_buffer: u32 = 0,
    svg_bind_group: u32 = 0,
    svg_atlas_texture: u32 = 0,
    svg_atlas_generation: u32 = 0,
    svg_atlas_texture_size: u32 = 0,
    gpu_svgs: [MAX_SVGS]GpuSvgInstance = undefined,

    // Image rendering
    image_pipeline: u32 = 0,
    image_buffer: u32 = 0,
    image_bind_group: u32 = 0,
    image_atlas_texture: u32 = 0,
    image_atlas_generation: u32 = 0,
    image_atlas_texture_size: u32 = 0,
    gpu_images: [MAX_IMAGES]ImageInstance = undefined,

    // Path rendering (triangulated meshes)
    path_pipeline: u32 = 0,
    path_vertex_buffer: u32 = 0,
    path_index_buffer: u32 = 0,
    path_instance_buffer: u32 = 0,
    path_gradient_buffer: u32 = 0,
    path_bind_group: u32 = 0,

    // Phase 2: Solid path rendering (batched, no gradients)
    solid_path_pipeline: u32 = 0,
    solid_path_vertex_buffer: u32 = 0,
    solid_path_index_buffer: u32 = 0,
    solid_path_clip_buffer: u32 = 0,
    solid_path_bind_group: u32 = 0,

    // Polyline rendering (for efficient chart lines)
    polyline_pipeline: u32 = 0,
    polyline_vertex_buffer: u32 = 0,
    polyline_index_buffer: u32 = 0,
    polyline_uniform_buffer: u32 = 0,
    polyline_bind_group: u32 = 0,

    // Point cloud rendering (for efficient scatter plots)
    point_cloud_pipeline: u32 = 0,
    point_cloud_vertex_buffer: u32 = 0,
    point_cloud_index_buffer: u32 = 0,
    point_cloud_uniform_buffer: u32 = 0,
    point_cloud_bind_group: u32 = 0,

    initialized: bool = false,

    // MSAA state
    msaa_texture: u32 = 0,
    msaa_width: u32 = 0,
    msaa_height: u32 = 0,
    sample_count: u32 = 4,

    // Post-processing state for custom shaders
    post_process_state: ?PostProcessState = null,

    // Batch descriptors for deferred rendering
    batches: [MAX_BATCHES]BatchDesc = undefined,

    // =========================================================================
    // P0 Batch Path Rendering - Staging Buffers (static allocation per CLAUDE.md)
    // =========================================================================
    // These staging buffers accumulate data from multiple paths before a single
    // GPU upload, reducing JS↔WASM↔WebGPU boundary crossings from 3×N to 3+N.

    /// Staging buffer for merged path vertices
    staging_vertices: [MAX_PATH_VERTICES]PathVertex = undefined,
    /// Staging buffer for merged path indices (adjusted for vertex offsets)
    staging_indices: [MAX_PATH_INDICES]u32 = undefined,
    /// Staging buffer for path instance data
    staging_instances: [MAX_PATHS]GpuPathInstance = undefined,
    /// Staging buffer for gradient uniforms
    staging_gradients: [MAX_PATHS]GpuGradientUniforms = undefined,
    /// Draw call parameters for each path in the batch
    staging_draw_calls: [MAX_PATHS]DrawCallInfo = undefined,

    // =========================================================================
    // Phase 2: Solid Path Batching - Staging Buffers
    // =========================================================================
    // These staging buffers hold baked (transformed + colored) vertices for
    // solid paths, enabling single draw call per clip region.

    /// Staging buffer for solid path vertices (32 bytes each, transform/color baked)
    staging_solid_vertices: [MAX_SOLID_BATCH_VERTICES]GpuSolidPathVertex = undefined,
    /// Staging buffer for solid path indices
    staging_solid_indices: [MAX_SOLID_BATCH_INDICES]u32 = undefined,

    const Self = @This();

    const unified_shader = @embedFile("unified_wgsl");
    const text_shader = @embedFile("text_wgsl");
    const svg_shader = @embedFile("svg_wgsl");
    const image_shader = @embedFile("image_wgsl");
    const path_shader = @embedFile("path_wgsl");
    const solid_path_shader = @embedFile("solid_path_wgsl");
    const polyline_shader = @embedFile("polyline_wgsl");
    const point_cloud_shader = @embedFile("point_cloud_wgsl");

    const unified_wgsl = "../shaders/unified.wgsl";
    const text_wgsl = "../shaders/text.wgsl";
    const svg_wgsl = "../shaders/svg.wgsl";
    const image_wgsl = "../shaders/image.wgsl";
    const path_wgsl = "../shaders/path.wgsl";
    const solid_path_wgsl = "../shaders/path_solid.wgsl";
    const polyline_wgsl = "../shaders/polyline.wgsl";
    const point_cloud_wgsl = "../shaders/point_cloud.wgsl";

    /// Initialize WebRenderer in-place using out-pointer pattern.
    /// Avoids stack overflow on WASM where WebRenderer is ~1.15MB
    /// (primitives: 512KB, gpu_glyphs: 512KB, etc.)
    /// Marked noinline to prevent stack accumulation in WASM builds.
    pub noinline fn initInPlace(self: *Self, allocator: std.mem.Allocator) void {
        // Zero all fields to handle the large undefined arrays safely
        // This avoids creating a stack temporary for the arrays
        self.allocator = allocator;
        self.pipeline = 0;
        self.primitive_buffer = 0;
        self.bind_group = 0;
        self.uniform_buffer = 0;
        self.sampler = 0;
        self.text_pipeline = 0;
        self.glyph_buffer = 0;
        self.text_bind_group = 0;
        self.atlas_texture = 0;
        self.atlas_generation = 0;
        self.svg_pipeline = 0;
        self.svg_buffer = 0;
        self.svg_bind_group = 0;
        self.svg_atlas_texture = 0;
        self.svg_atlas_generation = 0;
        self.image_pipeline = 0;
        self.image_buffer = 0;
        self.image_bind_group = 0;
        self.image_atlas_texture = 0;
        self.image_atlas_generation = 0;
        self.path_pipeline = 0;
        self.path_vertex_buffer = 0;
        self.path_index_buffer = 0;
        self.path_instance_buffer = 0;
        self.path_gradient_buffer = 0;
        self.path_bind_group = 0;
        self.solid_path_pipeline = 0;
        self.solid_path_vertex_buffer = 0;
        self.solid_path_index_buffer = 0;
        self.solid_path_clip_buffer = 0;
        self.solid_path_bind_group = 0;
        self.polyline_pipeline = 0;
        self.polyline_vertex_buffer = 0;
        self.polyline_index_buffer = 0;
        self.polyline_uniform_buffer = 0;
        self.polyline_bind_group = 0;
        self.point_cloud_pipeline = 0;
        self.point_cloud_vertex_buffer = 0;
        self.point_cloud_index_buffer = 0;
        self.point_cloud_uniform_buffer = 0;
        self.point_cloud_bind_group = 0;
        self.initialized = false;
        self.msaa_texture = 0;
        self.msaa_width = 0;
        self.msaa_height = 0;
        self.sample_count = 4;
        self.post_process_state = null;
        // Note: primitives, gpu_glyphs, gpu_svgs, gpu_images, batches arrays
        // are left undefined - they get overwritten during rendering anyway

        // Get MSAA sample count from JS (usually 4)
        self.sample_count = imports.getMSAASampleCount();

        // Create shader modules
        const unified_module = imports.createShaderModule(unified_shader.ptr, unified_shader.len);
        const text_module = imports.createShaderModule(text_shader.ptr, text_shader.len);
        const svg_module = imports.createShaderModule(svg_shader.ptr, svg_shader.len);
        const image_module = imports.createShaderModule(image_shader.ptr, image_shader.len);
        const path_module = imports.createShaderModule(path_shader.ptr, path_shader.len);
        const solid_path_module = imports.createShaderModule(solid_path_shader.ptr, solid_path_shader.len);
        const polyline_module = imports.createShaderModule(polyline_shader.ptr, polyline_shader.len);
        const point_cloud_module = imports.createShaderModule(point_cloud_shader.ptr, point_cloud_shader.len);

        // Create MSAA-enabled pipelines
        if (self.sample_count > 1) {
            self.pipeline = imports.createMSAARenderPipeline(unified_module, "vs_main", 7, "fs_main", 7, self.sample_count);
            self.text_pipeline = imports.createMSAARenderPipeline(text_module, "vs_main", 7, "fs_main", 7, self.sample_count);
            // SVG shader outputs premultiplied alpha, needs ONE for srcRGB blend factor
            self.svg_pipeline = imports.createMSAAPremultipliedAlphaPipeline(svg_module, "vs_main", 7, "fs_main", 7, self.sample_count);
            self.image_pipeline = imports.createMSAARenderPipeline(image_module, "vs_main", 7, "fs_main", 7, self.sample_count);
            // Path shader outputs premultiplied alpha
            self.path_pipeline = imports.createPathPipeline(path_module, "vs_main", 7, "fs_main", 7, self.sample_count);
            // Phase 2: Solid path shader outputs premultiplied alpha
            self.solid_path_pipeline = imports.createPathPipeline(solid_path_module, "vs_main", 7, "fs_main", 7, self.sample_count);
            // Polyline and point cloud shaders output premultiplied alpha
            self.polyline_pipeline = imports.createPathPipeline(polyline_module, "vs_main", 7, "fs_main", 7, self.sample_count);
            self.point_cloud_pipeline = imports.createPathPipeline(point_cloud_module, "vs_main", 7, "fs_main", 7, self.sample_count);
        } else {
            // Fallback to non-MSAA pipelines
            self.pipeline = imports.createRenderPipeline(unified_module, "vs_main", 7, "fs_main", 7);
            self.text_pipeline = imports.createRenderPipeline(text_module, "vs_main", 7, "fs_main", 7);
            // SVG shader outputs premultiplied alpha, needs ONE for srcRGB blend factor
            self.svg_pipeline = imports.createPremultipliedAlphaPipeline(svg_module, "vs_main", 7, "fs_main", 7);
            self.image_pipeline = imports.createRenderPipeline(image_module, "vs_main", 7, "fs_main", 7);
            // Path shader outputs premultiplied alpha (fallback non-MSAA)
            self.path_pipeline = imports.createPremultipliedAlphaPipeline(path_module, "vs_main", 7, "fs_main", 7);
            // Phase 2: Solid path shader outputs premultiplied alpha (fallback non-MSAA)
            self.solid_path_pipeline = imports.createPremultipliedAlphaPipeline(solid_path_module, "vs_main", 7, "fs_main", 7);
            // Polyline and point cloud shaders output premultiplied alpha (fallback non-MSAA)
            self.polyline_pipeline = imports.createPremultipliedAlphaPipeline(polyline_module, "vs_main", 7, "fs_main", 7);
            self.point_cloud_pipeline = imports.createPremultipliedAlphaPipeline(point_cloud_module, "vs_main", 7, "fs_main", 7);
        }

        const storage_copy = 0x0080 | 0x0008; // STORAGE | COPY_DST
        const uniform_copy = 0x0040 | 0x0008; // UNIFORM | COPY_DST

        // Create buffers
        self.primitive_buffer = imports.createBuffer(@sizeOf(unified.Primitive) * MAX_PRIMITIVES, storage_copy);
        self.glyph_buffer = imports.createBuffer(@sizeOf(GpuGlyph) * MAX_GLYPHS, storage_copy);
        self.svg_buffer = imports.createBuffer(@sizeOf(GpuSvgInstance) * MAX_SVGS, storage_copy);
        self.image_buffer = imports.createBuffer(@sizeOf(ImageInstance) * MAX_IMAGES, storage_copy);
        self.uniform_buffer = imports.createBuffer(@sizeOf(Uniforms), uniform_copy);

        // Path buffers - vertex storage, index storage, instance uniform, gradient uniform
        self.path_vertex_buffer = imports.createBuffer(@sizeOf(PathVertex) * MAX_PATH_VERTICES, storage_copy);
        self.path_index_buffer = imports.createBuffer(@sizeOf(u32) * MAX_PATH_INDICES, storage_copy);
        self.path_instance_buffer = imports.createBuffer(@sizeOf(GpuPathInstance), uniform_copy);
        self.path_gradient_buffer = imports.createBuffer(@sizeOf(GpuGradientUniforms), uniform_copy);

        // Phase 2: Solid path buffers - larger capacity, 32-byte vertices with baked transform/color
        self.solid_path_vertex_buffer = imports.createBuffer(@sizeOf(GpuSolidPathVertex) * MAX_SOLID_BATCH_VERTICES, storage_copy);
        self.solid_path_index_buffer = imports.createBuffer(@sizeOf(u32) * MAX_SOLID_BATCH_INDICES, storage_copy);
        self.solid_path_clip_buffer = imports.createBuffer(@sizeOf(GpuClipBounds), uniform_copy);

        // Polyline buffers - vertex storage, index storage, uniform
        self.polyline_vertex_buffer = imports.createBuffer(@sizeOf(GpuPolylineVertex) * MAX_POLYLINE_VERTICES, storage_copy);
        self.polyline_index_buffer = imports.createBuffer(@sizeOf(u32) * MAX_POLYLINE_INDICES, storage_copy);
        self.polyline_uniform_buffer = imports.createBuffer(@sizeOf(GpuPolylineUniforms), uniform_copy);

        // Point cloud buffers - vertex storage, index storage, uniform
        self.point_cloud_vertex_buffer = imports.createBuffer(@sizeOf(GpuPointVertex) * MAX_POINT_CLOUD_VERTICES, storage_copy);
        self.point_cloud_index_buffer = imports.createBuffer(@sizeOf(u32) * MAX_POINT_CLOUD_INDICES, storage_copy);
        self.point_cloud_uniform_buffer = imports.createBuffer(@sizeOf(GpuPointCloudUniforms), uniform_copy);

        // Create bind groups
        const prim_bufs = [_]u32{ self.primitive_buffer, self.uniform_buffer };
        self.bind_group = imports.createBindGroup(self.pipeline, 0, &prim_bufs, 2);
        self.sampler = imports.createSampler();

        // Path bind group: vertex buffer, instance buffer, uniform buffer, gradient buffer
        self.path_bind_group = imports.createPathBindGroupWithGradient(
            self.path_pipeline,
            0,
            self.path_vertex_buffer,
            self.path_instance_buffer,
            self.uniform_buffer,
            self.path_gradient_buffer,
        );

        // Phase 2: Solid path bind group: vertex buffer, clip buffer, uniform buffer
        self.solid_path_bind_group = imports.createPathBindGroup(
            self.solid_path_pipeline,
            0,
            self.solid_path_vertex_buffer,
            self.solid_path_clip_buffer,
            self.uniform_buffer,
        );

        // Polyline bind group: vertex buffer, uniform buffer, viewport uniform buffer
        self.polyline_bind_group = imports.createPathBindGroup(
            self.polyline_pipeline,
            0,
            self.polyline_vertex_buffer,
            self.polyline_uniform_buffer,
            self.uniform_buffer,
        );

        // Point cloud bind group: vertex buffer, uniform buffer, viewport uniform buffer
        self.point_cloud_bind_group = imports.createPathBindGroup(
            self.point_cloud_pipeline,
            0,
            self.point_cloud_vertex_buffer,
            self.point_cloud_uniform_buffer,
            self.uniform_buffer,
        );

        self.initialized = true;
    }

    pub fn deinit(self: *Self) void {
        if (self.post_process_state) |*state| {
            state.deinit();
        }
    }

    /// Ensure MSAA texture is the right size
    fn ensureMSAATexture(self: *Self, width: u32, height: u32) void {
        if (self.sample_count <= 1) return;

        // Recreate if size changed
        if (self.msaa_texture != 0 and (self.msaa_width != width or self.msaa_height != height)) {
            imports.destroyTexture(self.msaa_texture);
            self.msaa_texture = 0;
        }

        // Create if needed
        if (self.msaa_texture == 0) {
            self.msaa_texture = imports.createMSAATexture(width, height, self.sample_count);
            self.msaa_width = width;
            self.msaa_height = height;
        }
    }

    /// Initialize post-processing state (lazy initialization)
    fn initPostProcess(self: *Self) !void {
        if (self.post_process_state != null) return;
        self.post_process_state = PostProcessState.init(self.allocator);
    }

    /// Add a custom WGSL shader for post-processing
    pub fn addCustomShader(self: *Self, shader_source: []const u8, name: []const u8) !void {
        try self.initPostProcess();
        if (self.post_process_state) |*state| {
            try state.addShader(shader_source, name);
            imports.log("Added shader, pipeline count: {}", .{state.pipelines.items.len});
        }
    }

    /// Check if we have custom shaders enabled
    pub fn hasCustomShaders(self: *const Self) bool {
        if (self.post_process_state) |*state| {
            return state.hasShaders();
        }
        return false;
    }

    // =========================================================================
    // Text Atlas Management
    // =========================================================================

    pub fn uploadAtlas(self: *Self, text_system: *TextSystem) void {
        const atlas = text_system.getAtlas();
        const pixels = atlas.getData();
        const size = atlas.size;

        if (self.atlas_texture == 0) {
            self.atlas_texture = imports.createTexture(size, size, pixels.ptr, @intCast(pixels.len));
            self.atlas_texture_size = size;
        }

        self.text_bind_group = imports.createTextBindGroup(
            self.text_pipeline,
            0,
            self.glyph_buffer,
            self.uniform_buffer,
            self.atlas_texture,
            self.sampler,
        );
    }

    pub fn syncAtlas(self: *Self, text_system: *TextSystem) void {
        const atlas = text_system.getAtlas();

        // Only update if generation changed
        if (atlas.generation == self.atlas_generation) return;

        if (self.atlas_texture != 0) {
            const pixels = atlas.getData();
            const size = atlas.size;

            // Check if atlas size changed - need to recreate texture
            if (size != self.atlas_texture_size) {
                imports.destroyTexture(self.atlas_texture);
                self.atlas_texture = imports.createTexture(size, size, pixels.ptr, @intCast(pixels.len));
                self.atlas_texture_size = size;

                // Recreate bind group with new texture
                self.text_bind_group = imports.createTextBindGroup(
                    self.text_pipeline,
                    0,
                    self.glyph_buffer,
                    self.uniform_buffer,
                    self.atlas_texture,
                    self.sampler,
                );
            } else {
                imports.updateTexture(self.atlas_texture, size, size, pixels.ptr, @intCast(pixels.len));
            }
            self.atlas_generation = atlas.generation;
        }
    }

    // =========================================================================
    // SVG Atlas Management
    // =========================================================================

    pub fn uploadSvgAtlas(self: *Self, svg_atlas: *SvgAtlas) void {
        const atlas = svg_atlas.getAtlas();
        const pixels = atlas.getData();
        const size = atlas.size;

        if (self.svg_atlas_texture == 0) {
            // SVG atlas uses RGBA format
            self.svg_atlas_texture = imports.createRgbaTexture(size, size, pixels.ptr, @intCast(pixels.len));
            self.svg_atlas_texture_size = size;
        }

        self.svg_bind_group = imports.createSvgBindGroup(
            self.svg_pipeline,
            0,
            self.svg_buffer,
            self.uniform_buffer,
            self.svg_atlas_texture,
            self.sampler,
        );

        self.svg_atlas_generation = atlas.generation;
    }

    pub fn syncSvgAtlas(self: *Self, svg_atlas: *SvgAtlas) void {
        const atlas = svg_atlas.getAtlas();
        const generation = svg_atlas.getGeneration();

        // Only update if generation changed
        if (generation == self.svg_atlas_generation) return;

        if (self.svg_atlas_texture != 0) {
            const pixels = atlas.getData();
            const size = atlas.size;

            // Check if atlas size changed - need to recreate texture
            if (size != self.svg_atlas_texture_size) {
                imports.destroyTexture(self.svg_atlas_texture);
                self.svg_atlas_texture = imports.createRgbaTexture(size, size, pixels.ptr, @intCast(pixels.len));
                self.svg_atlas_texture_size = size;

                // Recreate bind group with new texture
                self.svg_bind_group = imports.createSvgBindGroup(
                    self.svg_pipeline,
                    0,
                    self.svg_buffer,
                    self.uniform_buffer,
                    self.svg_atlas_texture,
                    self.sampler,
                );
            } else {
                imports.updateRgbaTexture(self.svg_atlas_texture, size, size, pixels.ptr, @intCast(pixels.len));
            }
            self.svg_atlas_generation = generation;
        } else {
            // First time - create the texture
            self.uploadSvgAtlas(svg_atlas);
        }
    }

    // =========================================================================
    // Image Atlas Management
    // =========================================================================

    pub fn uploadImageAtlas(self: *Self, image_atlas: *ImageAtlas) void {
        const atlas = image_atlas.getAtlas();
        const pixels = atlas.getData();
        const size = atlas.size;

        if (self.image_atlas_texture == 0) {
            // Image atlas uses RGBA format
            self.image_atlas_texture = imports.createRgbaTexture(size, size, pixels.ptr, @intCast(pixels.len));
            self.image_atlas_texture_size = size;
        }

        self.image_bind_group = imports.createImageBindGroup(
            self.image_pipeline,
            0,
            self.image_buffer,
            self.uniform_buffer,
            self.image_atlas_texture,
            self.sampler,
        );

        self.image_atlas_generation = atlas.generation;
    }

    pub fn syncImageAtlas(self: *Self, image_atlas: *ImageAtlas) void {
        const atlas = image_atlas.getAtlas();
        const generation = image_atlas.getGeneration();

        // Only update if generation changed
        if (generation == self.image_atlas_generation) return;

        if (self.image_atlas_texture != 0) {
            const pixels = atlas.getData();
            const size = atlas.size;

            // Check if atlas size changed - need to recreate texture
            if (size != self.image_atlas_texture_size) {
                imports.destroyTexture(self.image_atlas_texture);
                self.image_atlas_texture = imports.createRgbaTexture(size, size, pixels.ptr, @intCast(pixels.len));
                self.image_atlas_texture_size = size;

                // Recreate bind group with new texture
                self.image_bind_group = imports.createImageBindGroup(
                    self.image_pipeline,
                    0,
                    self.image_buffer,
                    self.uniform_buffer,
                    self.image_atlas_texture,
                    self.sampler,
                );
            } else {
                imports.updateRgbaTexture(self.image_atlas_texture, size, size, pixels.ptr, @intCast(pixels.len));
            }
            self.image_atlas_generation = generation;
        } else {
            // First time - create the texture
            self.uploadImageAtlas(image_atlas);
        }
    }

    // =========================================================================
    // Rendering
    // =========================================================================

    pub fn render(
        self: *Self,
        scene: *Scene,
        viewport_width: f32,
        viewport_height: f32,
        clear_r: f32,
        clear_g: f32,
        clear_b: f32,
        clear_a: f32,
    ) void {
        if (!self.initialized) return;

        // Upload uniforms
        const uniforms = Uniforms{ .viewport_width = viewport_width, .viewport_height = viewport_height };
        imports.writeBuffer(self.uniform_buffer, 0, std.mem.asBytes(&uniforms).ptr, @sizeOf(Uniforms));

        // Ensure MSAA texture is sized correctly (use actual canvas pixel dimensions)
        if (self.sample_count > 1) {
            const device_width = imports.getCanvasPixelWidth();
            const device_height = imports.getCanvasPixelHeight();
            self.ensureMSAATexture(device_width, device_height);
        }

        // Check if we need post-processing
        const has_post_process = if (self.post_process_state) |*state| state.hasShaders() else false;
        if (has_post_process) {
            // Render to offscreen texture first for post-processing
            const prim_count = unified.convertScene(scene, &self.primitives);

            var glyph_count: u32 = 0;
            for (scene.getGlyphs()) |g| {
                if (glyph_count >= MAX_GLYPHS) break;
                self.gpu_glyphs[glyph_count] = GpuGlyph.fromScene(g);
                glyph_count += 1;
            }

            var svg_count: u32 = 0;
            for (scene.getSvgInstances()) |s| {
                if (svg_count >= MAX_SVGS) break;
                self.gpu_svgs[svg_count] = GpuSvgInstance.fromScene(s);
                svg_count += 1;
            }

            // Upload all buffers for post-process path
            if (prim_count > 0) {
                imports.writeBuffer(
                    self.primitive_buffer,
                    0,
                    std.mem.sliceAsBytes(self.primitives[0..prim_count]).ptr,
                    @intCast(@sizeOf(unified.Primitive) * prim_count),
                );
            }
            if (glyph_count > 0) {
                imports.writeBuffer(
                    self.glyph_buffer,
                    0,
                    std.mem.sliceAsBytes(self.gpu_glyphs[0..glyph_count]).ptr,
                    @intCast(@sizeOf(GpuGlyph) * glyph_count),
                );
            }
            if (svg_count > 0) {
                imports.writeBuffer(
                    self.svg_buffer,
                    0,
                    std.mem.sliceAsBytes(self.gpu_svgs[0..svg_count]).ptr,
                    @intCast(@sizeOf(GpuSvgInstance) * svg_count),
                );
            }

            self.renderWithPostProcess(
                prim_count,
                glyph_count,
                svg_count,
                viewport_width,
                viewport_height,
                clear_r,
                clear_g,
                clear_b,
                clear_a,
            );
        } else {
            // Render directly to screen using batched rendering for correct z-order
            self.renderBatched(scene, clear_r, clear_g, clear_b, clear_a);
        }
    }

    /// Render using batch iteration for correct z-ordering across primitive types.
    /// This ensures text and SVGs are properly interleaved with quads/shadows.
    ///
    /// Two-pass approach to avoid WebGPU queue ordering issues:
    /// 1. First pass: iterate batches, convert data, record batch descriptors
    /// 2. Upload all converted data to GPU buffers
    /// 3. Second pass: begin render pass, draw each batch using recorded descriptors
    fn renderBatched(
        self: *Self,
        scene: *const Scene,
        clear_r: f32,
        clear_g: f32,
        clear_b: f32,
        clear_a: f32,
    ) void {
        // Pass 1: Convert all data and record batch descriptors
        var iter = batch_iter.BatchIterator.init(scene);
        var batch_count: u32 = 0;
        var prim_offset: u32 = 0;
        var glyph_offset: u32 = 0;
        var svg_offset: u32 = 0;
        var image_offset: u32 = 0;
        var path_offset: u32 = 0;
        var polyline_offset: u32 = 0;
        var point_cloud_offset: u32 = 0;

        while (iter.next()) |batch| {
            if (batch_count >= MAX_BATCHES) break;

            switch (batch) {
                .shadow => |shadows| {
                    const count: u32 = @intCast(@min(shadows.len, MAX_PRIMITIVES - prim_offset));
                    if (count == 0) continue;

                    for (shadows[0..count], 0..) |shadow, i| {
                        self.primitives[prim_offset + i] = unified.Primitive.fromShadow(shadow);
                    }

                    self.batches[batch_count] = .{
                        .kind = .shadow,
                        .start = prim_offset,
                        .count = count,
                    };
                    prim_offset += count;
                    batch_count += 1;
                },
                .quad => |quads| {
                    const count: u32 = @intCast(@min(quads.len, MAX_PRIMITIVES - prim_offset));
                    if (count == 0) continue;

                    for (quads[0..count], 0..) |quad, i| {
                        self.primitives[prim_offset + i] = unified.Primitive.fromQuad(quad);
                    }

                    self.batches[batch_count] = .{
                        .kind = .quad,
                        .start = prim_offset,
                        .count = count,
                    };
                    prim_offset += count;
                    batch_count += 1;
                },
                .glyph => |glyphs| {
                    const count: u32 = @intCast(@min(glyphs.len, MAX_GLYPHS - glyph_offset));
                    if (count == 0) continue;

                    for (glyphs[0..count], 0..) |g, i| {
                        self.gpu_glyphs[glyph_offset + i] = GpuGlyph.fromScene(g);
                    }

                    self.batches[batch_count] = .{
                        .kind = .glyph,
                        .start = glyph_offset,
                        .count = count,
                    };
                    glyph_offset += count;
                    batch_count += 1;
                },
                .svg => |svgs| {
                    const count: u32 = @intCast(@min(svgs.len, MAX_SVGS - svg_offset));
                    if (count == 0) continue;

                    for (svgs[0..count], 0..) |s, i| {
                        self.gpu_svgs[svg_offset + i] = GpuSvgInstance.fromScene(s);
                    }

                    self.batches[batch_count] = .{
                        .kind = .svg,
                        .start = svg_offset,
                        .count = count,
                    };
                    svg_offset += count;
                    batch_count += 1;
                },
                .image => |images| {
                    const count: u32 = @intCast(@min(images.len, MAX_IMAGES - image_offset));
                    if (count == 0) continue;

                    // ImageInstance is already GPU-ready (extern struct), direct copy
                    for (images[0..count], 0..) |img, i| {
                        self.gpu_images[image_offset + i] = img;
                    }

                    self.batches[batch_count] = .{
                        .kind = .image,
                        .start = image_offset,
                        .count = count,
                    };
                    image_offset += count;
                    batch_count += 1;
                },
                .path => |paths| {
                    // Paths are rendered individually (each has its own mesh)
                    // Record batch for deferred rendering - actual mesh upload happens during draw
                    if (paths.len == 0) continue;

                    const count: u32 = @intCast(paths.len);
                    self.batches[batch_count] = .{
                        .kind = .path,
                        .start = path_offset, // Offset into scene's path_instances array
                        .count = count,
                    };
                    path_offset += count;
                    batch_count += 1;
                },
                .polyline => |polylines| {
                    // Polylines are rendered individually (each has its own expanded vertex data)
                    // Record batch for deferred rendering - actual vertex expansion happens during draw
                    if (polylines.len == 0) continue;

                    const count: u32 = @intCast(polylines.len);
                    self.batches[batch_count] = .{
                        .kind = .polyline,
                        .start = polyline_offset, // Offset into scene's polylines array
                        .count = count,
                    };
                    polyline_offset += count;
                    batch_count += 1;
                },
                .point_cloud => |point_clouds| {
                    // Point clouds are rendered individually (each has its own expanded vertex data)
                    // Record batch for deferred rendering - actual vertex expansion happens during draw
                    if (point_clouds.len == 0) continue;

                    const count: u32 = @intCast(point_clouds.len);
                    self.batches[batch_count] = .{
                        .kind = .point_cloud,
                        .start = point_cloud_offset, // Offset into scene's point_clouds array
                        .count = count,
                    };
                    point_cloud_offset += count;
                    batch_count += 1;
                },
                .colored_point_cloud => |colored_point_clouds| {
                    // TODO: Implement colored point cloud rendering for WASM
                    // For now, stub that skips rendering (API validation phase)
                    if (colored_point_clouds.len == 0) continue;
                    // Colored point clouds not yet implemented for WASM
                },
            }
        }

        // Pass 2: Upload all data to GPU buffers BEFORE starting render pass
        if (prim_offset > 0) {
            imports.writeBuffer(
                self.primitive_buffer,
                0,
                std.mem.sliceAsBytes(self.primitives[0..prim_offset]).ptr,
                @intCast(@sizeOf(unified.Primitive) * prim_offset),
            );
        }
        if (glyph_offset > 0) {
            imports.writeBuffer(
                self.glyph_buffer,
                0,
                std.mem.sliceAsBytes(self.gpu_glyphs[0..glyph_offset]).ptr,
                @intCast(@sizeOf(GpuGlyph) * glyph_offset),
            );
        }
        if (svg_offset > 0) {
            imports.writeBuffer(
                self.svg_buffer,
                0,
                std.mem.sliceAsBytes(self.gpu_svgs[0..svg_offset]).ptr,
                @intCast(@sizeOf(GpuSvgInstance) * svg_offset),
            );
        }
        if (image_offset > 0) {
            imports.writeBuffer(
                self.image_buffer,
                0,
                std.mem.sliceAsBytes(self.gpu_images[0..image_offset]).ptr,
                @intCast(@sizeOf(ImageInstance) * image_offset),
            );
        }

        // Pass 3: Begin render pass and draw each batch
        const texture_view = imports.getCurrentTextureView();

        if (self.sample_count > 1 and self.msaa_texture != 0) {
            imports.beginMSAARenderPass(self.msaa_texture, texture_view, clear_r, clear_g, clear_b, clear_a);
        } else {
            imports.beginRenderPass(texture_view, clear_r, clear_g, clear_b, clear_a);
        }

        for (self.batches[0..batch_count]) |batch_desc| {
            switch (batch_desc.kind) {
                .shadow, .quad => {
                    imports.setPipeline(self.pipeline);
                    imports.setBindGroup(0, self.bind_group);
                    imports.drawInstancedWithOffset(6, batch_desc.count, batch_desc.start);
                },
                .glyph => {
                    if (self.text_bind_group != 0) {
                        imports.setPipeline(self.text_pipeline);
                        imports.setBindGroup(0, self.text_bind_group);
                        imports.drawInstancedWithOffset(6, batch_desc.count, batch_desc.start);
                    }
                },
                .svg => {
                    if (self.svg_bind_group != 0) {
                        imports.setPipeline(self.svg_pipeline);
                        imports.setBindGroup(0, self.svg_bind_group);
                        imports.drawInstancedWithOffset(6, batch_desc.count, batch_desc.start);
                    }
                },
                .image => {
                    if (self.image_bind_group != 0) {
                        imports.setPipeline(self.image_pipeline);
                        imports.setBindGroup(0, self.image_bind_group);
                        imports.drawInstancedWithOffset(6, batch_desc.count, batch_desc.start);
                    }
                },
                .path => {
                    // Path rendering requires indexed drawing with per-instance mesh data
                    // Each path instance references a mesh in the MeshPool
                    if (self.path_bind_group != 0) {
                        self.renderPathBatch(scene, batch_desc.start, batch_desc.count);
                    }
                },
                .polyline => {
                    // Polyline rendering: expand to quads and draw indexed
                    if (self.polyline_bind_group != 0) {
                        self.renderPolylineBatch(scene, batch_desc.start, batch_desc.count);
                    }
                },
                .point_cloud => {
                    // Point cloud rendering: expand to quads with SDF and draw indexed
                    if (self.point_cloud_bind_group != 0) {
                        self.renderPointCloudBatch(scene, batch_desc.start, batch_desc.count);
                    }
                },
                .colored_point_cloud => {
                    // TODO: Implement colored point cloud rendering for WASM
                    // For now, stub that skips rendering (API validation phase)
                },
            }
        }

        imports.endRenderPass();
        imports.releaseTextureView(texture_view);
    }

    /// Render a batch of path instances using batched buffer uploads.
    ///
    /// P0 Optimization: Reduces JS↔WASM↔WebGPU boundary crossings from 3×N to 3+N
    /// by merging all path vertex/index data into staging buffers before upload.
    ///
    /// Before: 100 paths = 400 API calls (3 writeBuffer + 1 drawIndexed per path)
    /// After:  100 paths = 103 API calls (3 writeBuffer total + 100 drawIndexed)
    fn renderPathBatch(self: *Self, scene: *const Scene, start: u32, count: u32) void {
        if (count == 0) return;

        const all_paths = scene.getPathInstances();
        const all_gradients = scene.getPathGradients();
        const mesh_pool = scene.getMeshPool();

        // Slice to the batch we're rendering
        const end = @min(start + count, @as(u32, @intCast(all_paths.len)));
        if (start >= end) return;

        const paths = all_paths[start..end];
        const gradients = all_gradients[start..@min(start + count, @as(u32, @intCast(all_gradients.len)))];

        // Assertions per CLAUDE.md: minimum 2 per function
        std.debug.assert(paths.len > 0);
        std.debug.assert(paths.len <= MAX_PATHS);

        // =====================================================================
        // Phase 1a: Build clip batches (group consecutive same-clip paths)
        // Important: We group consecutive paths, NOT sort, to preserve draw order
        // =====================================================================
        var clip_batches: [MAX_CLIP_BATCHES]ClipBatch = undefined;
        var clip_batch_count: u32 = 0;

        {
            var batch_start: u32 = 0;
            var current_clip = paths[0].getClipBounds();

            for (paths[1..], 1..) |inst, i| {
                const clip = inst.getClipBounds();
                if (!clip.equals(current_clip)) {
                    // End current batch, start new one
                    if (clip_batch_count < MAX_CLIP_BATCHES) {
                        clip_batches[clip_batch_count] = .{
                            .clip = current_clip,
                            .start_index = batch_start,
                            .end_index = @intCast(i),
                        };
                        clip_batch_count += 1;
                    }
                    batch_start = @intCast(i);
                    current_clip = clip;
                }
            }
            // Final batch
            if (clip_batch_count < MAX_CLIP_BATCHES) {
                clip_batches[clip_batch_count] = .{
                    .clip = current_clip,
                    .start_index = batch_start,
                    .end_index = @intCast(paths.len),
                };
                clip_batch_count += 1;
            }
        }

        // =====================================================================
        // Phase 1b: Calculate totals and validate capacity
        // =====================================================================
        var total_vertices: u32 = 0;
        var total_indices: u32 = 0;
        var valid_path_count: u32 = 0;

        for (paths) |path_inst| {
            const mesh = mesh_pool.getMesh(path_inst.getMeshRef());
            if (mesh.isEmpty()) continue;

            const vert_count: u32 = @intCast(mesh.vertices.len);
            const idx_count: u32 = @intCast(mesh.indices.len);

            // Check if adding this path would exceed batch limits
            if (total_vertices + vert_count > MAX_PATH_VERTICES or
                total_indices + idx_count > MAX_PATH_INDICES or
                valid_path_count >= MAX_PATHS)
            {
                // Batch is full - render what we have and continue with chunked approach
                if (valid_path_count > 0) {
                    self.flushPathBatch(valid_path_count, total_vertices, total_indices);
                }
                // Fall back to rendering remaining paths one at a time
                // (This is the overflow case - should be rare with reasonable limits)
                self.renderPathsUnbatched(paths[valid_path_count..], gradients, mesh_pool);
                return;
            }

            total_vertices += vert_count;
            total_indices += idx_count;
            valid_path_count += 1;
        }

        if (valid_path_count == 0 or total_vertices == 0 or total_indices == 0) return;

        // Assertions per CLAUDE.md: validate buffer capacity
        std.debug.assert(total_vertices <= MAX_PATH_VERTICES);
        std.debug.assert(total_indices <= MAX_PATH_INDICES);

        // =====================================================================
        // Phase 2: Build merged buffers in staging arrays
        // =====================================================================
        var vertex_offset: u32 = 0;
        var index_offset: u32 = 0;
        var draw_call_count: u32 = 0;

        for (paths, 0..) |path_inst, path_idx| {
            const mesh = mesh_pool.getMesh(path_inst.getMeshRef());
            if (mesh.isEmpty()) continue;

            const vert_count: u32 = @intCast(mesh.vertices.len);
            const idx_count: u32 = @intCast(mesh.indices.len);

            // Copy vertices to staging buffer
            const vertices_src = mesh.vertices.constSlice();
            @memcpy(self.staging_vertices[vertex_offset..][0..vert_count], vertices_src);

            // Copy indices with vertex offset adjustment (critical for merged buffer!)
            const indices_src = mesh.indices.constSlice();
            for (indices_src, 0..) |src_idx, j| {
                self.staging_indices[index_offset + @as(u32, @intCast(j))] = src_idx + vertex_offset;
            }

            // Record draw call parameters
            self.staging_draw_calls[draw_call_count] = .{
                .index_count = idx_count,
                .index_offset = index_offset,
                .instance_index = draw_call_count,
            };

            // Build GPU instance data
            self.staging_instances[draw_call_count] = GpuPathInstance.fromScene(path_inst);

            // Build GPU gradient data (converts flat [16]f32 to packed [4][4]f32 for WGSL alignment)
            const scene_gradient = if (path_idx < gradients.len) gradients[path_idx] else GradientUniforms.none();
            self.staging_gradients[draw_call_count] = GpuGradientUniforms.fromScene(scene_gradient);

            vertex_offset += vert_count;
            index_offset += idx_count;
            draw_call_count += 1;
        }

        // Assertion: verify we processed the expected count
        std.debug.assert(draw_call_count == valid_path_count);

        // =====================================================================
        // Phase 3: Single batch upload (3 API calls instead of 3×N)
        // =====================================================================
        // Upload merged vertex buffer
        imports.writeBuffer(
            self.path_vertex_buffer,
            0,
            @as([*]const u8, @ptrCast(&self.staging_vertices)),
            total_vertices * @sizeOf(PathVertex),
        );

        // Upload merged index buffer
        imports.writeBuffer(
            self.path_index_buffer,
            0,
            @as([*]const u8, @ptrCast(&self.staging_indices)),
            total_indices * @sizeOf(u32),
        );

        // Note: Instance and gradient buffers are still per-draw-call because
        // the shader expects them as uniforms, not storage buffers with indexing.
        // This is a limitation of the current shader design - P2 (instanced rendering)
        // would address this by moving to storage buffers with instance_index lookup.

        // =====================================================================
        // Phase 4: Issue draw calls grouped by clip batches
        // Each clip batch shares the same clip bounds - draw paths within each batch
        // This reduces state transitions when many paths share the same clip region
        // =====================================================================
        imports.setPipeline(self.path_pipeline);
        imports.setBindGroup(0, self.path_bind_group);

        // Set index buffer once for all draws (pointing to merged buffer)
        imports.setIndexBuffer(
            self.path_index_buffer,
            imports.IndexFormat.uint32,
            0,
            total_indices * @sizeOf(u32),
        );

        // Draw grouped by clip batches (Phase 1 optimization)
        for (clip_batches[0..clip_batch_count]) |batch| {
            // Draw all paths in this clip batch
            for (batch.start_index..batch.end_index) |i| {
                const dc = self.staging_draw_calls[i];

                // Upload per-instance data (still needed - shader uses uniform, not storage)
                imports.writeBuffer(
                    self.path_instance_buffer,
                    0,
                    @as([*]const u8, @ptrCast(&self.staging_instances[dc.instance_index])),
                    @sizeOf(GpuPathInstance),
                );

                imports.writeBuffer(
                    self.path_gradient_buffer,
                    0,
                    @as([*]const u8, @ptrCast(&self.staging_gradients[dc.instance_index])),
                    @sizeOf(GpuGradientUniforms),
                );

                // Draw this path's triangles from the merged index buffer
                imports.drawIndexed(dc.index_count, 1, dc.index_offset, 0, 0);
            }
        }
    }

    /// Flush the current batch of paths to GPU
    /// Called when staging buffers are full and we need to render before continuing
    fn flushPathBatch(self: *Self, path_count: u32, total_vertices: u32, total_indices: u32) void {
        if (path_count == 0) return;

        // Upload merged buffers
        imports.writeBuffer(
            self.path_vertex_buffer,
            0,
            @as([*]const u8, @ptrCast(&self.staging_vertices)),
            total_vertices * @sizeOf(PathVertex),
        );

        imports.writeBuffer(
            self.path_index_buffer,
            0,
            @as([*]const u8, @ptrCast(&self.staging_indices)),
            total_indices * @sizeOf(u32),
        );

        imports.setPipeline(self.path_pipeline);
        imports.setBindGroup(0, self.path_bind_group);

        imports.setIndexBuffer(
            self.path_index_buffer,
            imports.IndexFormat.uint32,
            0,
            total_indices * @sizeOf(u32),
        );

        for (self.staging_draw_calls[0..path_count]) |dc| {
            imports.writeBuffer(
                self.path_instance_buffer,
                0,
                @as([*]const u8, @ptrCast(&self.staging_instances[dc.instance_index])),
                @sizeOf(GpuPathInstance),
            );

            imports.writeBuffer(
                self.path_gradient_buffer,
                0,
                @as([*]const u8, @ptrCast(&self.staging_gradients[dc.instance_index])),
                @sizeOf(GpuGradientUniforms),
            );

            imports.drawIndexed(dc.index_count, 1, dc.index_offset, 0, 0);
        }
    }

    /// Fallback: render paths without batching (used for overflow)
    /// This is the original per-path upload approach, used when batch limits are exceeded
    fn renderPathsUnbatched(
        self: *Self,
        paths: []const PathInstance,
        gradients: []const GradientUniforms,
        mesh_pool: *const MeshPool,
    ) void {
        imports.setPipeline(self.path_pipeline);
        imports.setBindGroup(0, self.path_bind_group);

        for (paths, 0..) |path_inst, path_idx| {
            const mesh = mesh_pool.getMesh(path_inst.getMeshRef());
            if (mesh.isEmpty()) continue;

            const vertex_count = mesh.vertices.len;
            const index_count = mesh.indices.len;

            // Skip if single mesh exceeds buffer capacity
            if (vertex_count > MAX_PATH_VERTICES or index_count > MAX_PATH_INDICES) continue;

            imports.writeBuffer(
                self.path_vertex_buffer,
                0,
                mesh.vertexBytes().ptr,
                @intCast(vertex_count * @sizeOf(PathVertex)),
            );

            imports.writeBuffer(
                self.path_index_buffer,
                0,
                mesh.indexBytes().ptr,
                @intCast(index_count * @sizeOf(u32)),
            );

            const gpu_instance = GpuPathInstance.fromScene(path_inst);
            imports.writeBuffer(
                self.path_instance_buffer,
                0,
                @as([*]const u8, @ptrCast(&gpu_instance)),
                @sizeOf(GpuPathInstance),
            );

            const scene_gradient = if (path_idx < gradients.len) gradients[path_idx] else GradientUniforms.none();
            const gpu_gradient = GpuGradientUniforms.fromScene(scene_gradient);

            imports.writeBuffer(
                self.path_gradient_buffer,
                0,
                @as([*]const u8, @ptrCast(&gpu_gradient)),
                @sizeOf(GpuGradientUniforms),
            );

            imports.setIndexBuffer(self.path_index_buffer, imports.IndexFormat.uint32, 0, @intCast(index_count * @sizeOf(u32)));
            imports.drawIndexed(@intCast(index_count), 1, 0, 0, 0);
        }
    }

    /// Phase 2: Render solid-color paths with single draw call per clip region
    /// Transform and color are baked into vertices at upload time
    /// This is the main optimization - reduces N draw calls to 1 for solid paths sharing a clip
    fn renderSolidPathBatch(
        self: *Self,
        instances: []const PathInstance,
        mesh_pool: *const MeshPool,
        clip_bounds: ClipBounds,
    ) void {
        if (instances.len == 0) return;

        // Assertions per CLAUDE.md: minimum 2 per function
        std.debug.assert(instances.len <= 256);
        std.debug.assert(clip_bounds.w > 0 and clip_bounds.h > 0);

        // =====================================================================
        // Phase 1: Calculate totals and validate capacity
        // =====================================================================
        var total_vertices: u32 = 0;
        var total_indices: u32 = 0;

        for (instances) |*instance| {
            const mesh = mesh_pool.getMesh(instance.getMeshRef());
            if (mesh.isEmpty()) continue;

            const vert_count: u32 = @intCast(mesh.vertices.len);
            const idx_count: u32 = @intCast(mesh.indices.len);

            // Check capacity limits (static allocation per CLAUDE.md)
            if (total_vertices + vert_count > MAX_SOLID_BATCH_VERTICES or
                total_indices + idx_count > MAX_SOLID_BATCH_INDICES)
            {
                // Batch is full - render what we have, skip the rest
                break;
            }

            total_vertices += vert_count;
            total_indices += idx_count;
        }

        if (total_vertices == 0 or total_indices == 0) return;

        // Assertions per CLAUDE.md: validate buffer capacity
        std.debug.assert(total_vertices <= MAX_SOLID_BATCH_VERTICES);
        std.debug.assert(total_indices <= MAX_SOLID_BATCH_INDICES);

        // =====================================================================
        // Phase 2: Bake transforms and colors into vertices
        // =====================================================================
        var vertex_offset: u32 = 0;
        var index_offset: u32 = 0;

        for (instances) |*instance| {
            const mesh = mesh_pool.getMesh(instance.getMeshRef());
            if (mesh.isEmpty()) continue;

            const vert_count: u32 = @intCast(mesh.vertices.len);
            const idx_count: u32 = @intCast(mesh.indices.len);

            // Check if we'd exceed capacity (stop if so)
            if (vertex_offset + vert_count > MAX_SOLID_BATCH_VERTICES or
                index_offset + idx_count > MAX_SOLID_BATCH_INDICES)
            {
                break;
            }

            // Bake transform and color into each vertex
            for (mesh.vertices.constSlice(), 0..) |src_v, j| {
                self.staging_solid_vertices[vertex_offset + @as(u32, @intCast(j))] = GpuSolidPathVertex.fromPathVertex(
                    src_v,
                    instance.offset_x,
                    instance.offset_y,
                    instance.scale_x,
                    instance.scale_y,
                    instance.fill_color.h,
                    instance.fill_color.s,
                    instance.fill_color.l,
                    instance.fill_color.a,
                );
            }

            // Copy indices with vertex offset adjustment
            for (mesh.indices.constSlice(), 0..) |src_idx, j| {
                self.staging_solid_indices[index_offset + @as(u32, @intCast(j))] = src_idx + vertex_offset;
            }

            vertex_offset += vert_count;
            index_offset += idx_count;
        }

        // =====================================================================
        // Phase 3: Upload and issue SINGLE draw call
        // =====================================================================
        // Upload baked vertex buffer
        imports.writeBuffer(
            self.solid_path_vertex_buffer,
            0,
            @as([*]const u8, @ptrCast(&self.staging_solid_vertices)),
            total_vertices * @sizeOf(GpuSolidPathVertex),
        );

        // Upload index buffer
        imports.writeBuffer(
            self.solid_path_index_buffer,
            0,
            @as([*]const u8, @ptrCast(&self.staging_solid_indices)),
            total_indices * @sizeOf(u32),
        );

        // Upload clip bounds uniform (shared by entire batch)
        const gpu_clip = GpuClipBounds.fromClipBounds(clip_bounds);
        imports.writeBuffer(
            self.solid_path_clip_buffer,
            0,
            @as([*]const u8, @ptrCast(&gpu_clip)),
            @sizeOf(GpuClipBounds),
        );

        // Set solid path pipeline and bind group
        imports.setPipeline(self.solid_path_pipeline);
        imports.setBindGroup(0, self.solid_path_bind_group);

        // Set index buffer
        imports.setIndexBuffer(
            self.solid_path_index_buffer,
            imports.IndexFormat.uint32,
            0,
            total_indices * @sizeOf(u32),
        );

        // ONE draw call for entire batch - this is the main optimization!
        imports.drawIndexed(index_offset, 1, 0, 0, 0);
    }

    /// Phase 2+3: Optimized batch rendering with solid/gradient partitioning
    /// Partitions paths by gradient type, then renders:
    ///   - Solid paths: batched by clip region (1 draw call per clip)
    ///   - Gradient paths: individual draw calls (existing approach)
    /// This is the main entry point for optimized path rendering.
    fn renderPathBatchOptimized(self: *Self, scene: *const Scene, start: u32, count: u32) void {
        if (count == 0) return;

        const all_paths = scene.getPathInstances();
        const all_gradients = scene.getPathGradients();
        const mesh_pool = scene.getMeshPool();

        // Slice to the batch we're rendering
        const end = @min(start + count, @as(u32, @intCast(all_paths.len)));
        if (start >= end) return;

        const paths = all_paths[start..end];
        const gradients = all_gradients[start..@min(start + count, @as(u32, @intCast(all_gradients.len)))];

        // Assertions per CLAUDE.md: minimum 2 per function
        std.debug.assert(paths.len > 0);
        std.debug.assert(paths.len <= MAX_PATHS);

        // =====================================================================
        // Phase 3a: Partition paths into solid vs gradient
        // Use existing hasGradient() method from PathInstance
        // =====================================================================
        var solid_instances: [256]PathInstance = undefined;
        var gradient_instances: [256]PathInstance = undefined;
        var gradient_uniforms: [256]GradientUniforms = undefined;
        var solid_count: u32 = 0;
        var gradient_count: u32 = 0;

        for (paths, 0..) |inst, i| {
            if (inst.hasGradient()) {
                gradient_instances[gradient_count] = inst;
                gradient_uniforms[gradient_count] = if (i < gradients.len) gradients[i] else GradientUniforms.none();
                gradient_count += 1;
            } else {
                solid_instances[solid_count] = inst;
                solid_count += 1;
            }
        }

        // Assertion per CLAUDE.md: verify partition is complete
        std.debug.assert(solid_count + gradient_count == paths.len);

        // =====================================================================
        // Phase 3b: Render solid paths (batched by clip region)
        // Group consecutive same-clip paths for single draw call each
        // =====================================================================
        if (solid_count > 0) {
            const solid_slice = solid_instances[0..solid_count];

            // Build clip batches for solid paths
            var clip_batches: [MAX_CLIP_BATCHES]ClipBatch = undefined;
            var clip_batch_count: u32 = 0;

            var batch_start: u32 = 0;
            var current_clip = solid_slice[0].getClipBounds();

            for (solid_slice[1..], 1..) |inst, i| {
                const clip = inst.getClipBounds();
                if (!clip.equals(current_clip)) {
                    // End current batch, start new one
                    if (clip_batch_count < MAX_CLIP_BATCHES) {
                        clip_batches[clip_batch_count] = .{
                            .clip = current_clip,
                            .start_index = batch_start,
                            .end_index = @intCast(i),
                        };
                        clip_batch_count += 1;
                    }
                    batch_start = @intCast(i);
                    current_clip = clip;
                }
            }
            // Final batch
            if (clip_batch_count < MAX_CLIP_BATCHES) {
                clip_batches[clip_batch_count] = .{
                    .clip = current_clip,
                    .start_index = batch_start,
                    .end_index = solid_count,
                };
                clip_batch_count += 1;
            }

            // Render each clip batch with a single draw call
            for (clip_batches[0..clip_batch_count]) |batch| {
                self.renderSolidPathBatch(
                    solid_slice[batch.start_index..batch.end_index],
                    mesh_pool,
                    batch.clip,
                );
            }
        }

        // =====================================================================
        // Phase 3c: Render gradient paths (individual draw calls)
        // Uses existing renderPathBatch approach for gradient paths
        // =====================================================================
        if (gradient_count > 0) {
            // Use the existing path rendering infrastructure for gradients
            self.renderGradientPathsOnly(gradient_instances[0..gradient_count], gradient_uniforms[0..gradient_count], mesh_pool);
        }
    }

    /// Phase 4: Batched gradient path rendering
    /// Uploads all vertices and indices ONCE, then issues draws with offset tracking.
    /// This reduces writeBuffer calls from 4×N to 2 + 2×N (eliminating per-path vertex/index uploads).
    fn renderGradientPathsOnly(
        self: *Self,
        paths: []const PathInstance,
        gradients: []const GradientUniforms,
        mesh_pool: *const MeshPool,
    ) void {
        if (paths.len == 0) return;

        // Assertions per CLAUDE.md: minimum 2 per function
        std.debug.assert(paths.len <= MAX_GRADIENT_BATCH_PATHS);
        std.debug.assert(gradients.len <= paths.len or gradients.len == 0);

        // =====================================================================
        // Phase 1: Calculate totals and build offset table
        // =====================================================================
        const OffsetInfo = struct {
            vertex_offset: u32,
            index_offset: u32,
            index_count: u32,
        };
        var offsets: [MAX_GRADIENT_BATCH_PATHS]OffsetInfo = undefined;

        var total_vertices: u32 = 0;
        var total_indices: u32 = 0;
        var valid_count: u32 = 0;

        for (paths, 0..) |path_inst, i| {
            const mesh = mesh_pool.getMesh(path_inst.getMeshRef());
            if (mesh.isEmpty()) {
                offsets[i] = .{ .vertex_offset = 0, .index_offset = 0, .index_count = 0 };
                continue;
            }

            const vert_count: u32 = @intCast(mesh.vertices.len);
            const idx_count: u32 = @intCast(mesh.indices.len);

            // Check capacity limits
            if (total_vertices + vert_count > MAX_PATH_VERTICES or
                total_indices + idx_count > MAX_PATH_INDICES)
            {
                // Would exceed buffer capacity - mark remaining as empty
                offsets[i] = .{ .vertex_offset = 0, .index_offset = 0, .index_count = 0 };
                continue;
            }

            offsets[i] = .{
                .vertex_offset = total_vertices,
                .index_offset = total_indices,
                .index_count = idx_count,
            };

            total_vertices += vert_count;
            total_indices += idx_count;
            valid_count += 1;
        }

        if (valid_count == 0) return;

        // Assertions per CLAUDE.md: validate buffer capacity
        std.debug.assert(total_vertices <= MAX_PATH_VERTICES);
        std.debug.assert(total_indices <= MAX_PATH_INDICES);

        // =====================================================================
        // Phase 2: Merge all mesh data into staging buffers
        // =====================================================================
        for (paths, 0..) |path_inst, i| {
            const info = offsets[i];
            if (info.index_count == 0) continue;

            const mesh = mesh_pool.getMesh(path_inst.getMeshRef());
            const vert_count: u32 = @intCast(mesh.vertices.len);

            // Copy vertices directly (no transform - gradient shader handles it)
            for (mesh.vertices.constSlice(), 0..) |src_v, j| {
                self.staging_vertices[info.vertex_offset + @as(u32, @intCast(j))] = src_v;
            }

            // Copy indices with vertex offset adjustment
            for (mesh.indices.constSlice(), 0..) |src_idx, j| {
                self.staging_indices[info.index_offset + @as(u32, @intCast(j))] = src_idx + info.vertex_offset;
            }

            _ = vert_count;
        }

        // =====================================================================
        // Phase 3: Upload merged buffers ONCE (main optimization)
        // =====================================================================
        imports.writeBuffer(
            self.path_vertex_buffer,
            0,
            @as([*]const u8, @ptrCast(&self.staging_vertices)),
            total_vertices * @sizeOf(PathVertex),
        );

        imports.writeBuffer(
            self.path_index_buffer,
            0,
            @as([*]const u8, @ptrCast(&self.staging_indices)),
            total_indices * @sizeOf(u32),
        );

        // =====================================================================
        // Phase 4: Issue draw calls with per-path instance/gradient uniforms
        // =====================================================================
        imports.setPipeline(self.path_pipeline);
        imports.setBindGroup(0, self.path_bind_group);

        for (paths, 0..) |path_inst, path_idx| {
            const info = offsets[path_idx];
            if (info.index_count == 0) continue;

            // Upload instance data for this path
            const gpu_instance = GpuPathInstance.fromScene(path_inst);
            imports.writeBuffer(
                self.path_instance_buffer,
                0,
                @as([*]const u8, @ptrCast(&gpu_instance)),
                @sizeOf(GpuPathInstance),
            );

            // Upload gradient data for this path
            const scene_gradient = if (path_idx < gradients.len) gradients[path_idx] else GradientUniforms.none();
            const gpu_gradient = GpuGradientUniforms.fromScene(scene_gradient);
            imports.writeBuffer(
                self.path_gradient_buffer,
                0,
                @as([*]const u8, @ptrCast(&gpu_gradient)),
                @sizeOf(GpuGradientUniforms),
            );

            // Set index buffer with offset for this path's indices
            imports.setIndexBuffer(
                self.path_index_buffer,
                imports.IndexFormat.uint32,
                info.index_offset * @sizeOf(u32),
                info.index_count * @sizeOf(u32),
            );

            // Draw this path
            imports.drawIndexed(info.index_count, 1, 0, 0, 0);
        }
    }

    /// Render a batch of polylines
    /// Each polyline is expanded to quads on the CPU and uploaded individually
    fn renderPolylineBatch(self: *Self, scene: *const Scene, start: u32, count: u32) void {
        if (count == 0) return;

        const all_polylines = scene.getPolylines();

        // Slice to the batch we're rendering
        const end = @min(start + count, @as(u32, @intCast(all_polylines.len)));
        if (start >= end) return;

        const polylines = all_polylines[start..end];

        imports.setPipeline(self.polyline_pipeline);
        imports.setBindGroup(0, self.polyline_bind_group);

        // Temporary buffers for vertex expansion (on stack - reasonable size for WASM)
        var vertices: [MAX_POLYLINE_VERTICES]GpuPolylineVertex = undefined;
        var indices: [MAX_POLYLINE_INDICES]u32 = undefined;

        // Render each polyline
        for (polylines) |pl| {
            const points = pl.getPoints();
            if (points.len < 2) continue;

            const half_width = pl.width * 0.5;

            var vertex_offset: u32 = 0;
            var index_offset: u32 = 0;

            // Expand each segment to a quad
            for (0..points.len - 1) |i| {
                const p0 = points[i];
                const p1 = points[i + 1];

                // Calculate direction and perpendicular
                const dx = p1.x - p0.x;
                const dy = p1.y - p0.y;
                const len = @sqrt(dx * dx + dy * dy);

                var perp_x: f32 = 0;
                var perp_y: f32 = half_width;

                if (len > 0.0001) {
                    perp_x = -dy / len * half_width;
                    perp_y = dx / len * half_width;
                }

                // Skip if we'd overflow buffers
                if (vertex_offset + 4 > MAX_POLYLINE_VERTICES or index_offset + 6 > MAX_POLYLINE_INDICES) break;

                const seg_base = vertex_offset;

                // Quad corners
                vertices[vertex_offset] = .{ .x = p0.x + perp_x, .y = p0.y + perp_y };
                vertex_offset += 1;
                vertices[vertex_offset] = .{ .x = p0.x - perp_x, .y = p0.y - perp_y };
                vertex_offset += 1;
                vertices[vertex_offset] = .{ .x = p1.x - perp_x, .y = p1.y - perp_y };
                vertex_offset += 1;
                vertices[vertex_offset] = .{ .x = p1.x + perp_x, .y = p1.y + perp_y };
                vertex_offset += 1;

                // Two triangles: 0-1-2 and 0-2-3
                indices[index_offset] = seg_base;
                index_offset += 1;
                indices[index_offset] = seg_base + 1;
                index_offset += 1;
                indices[index_offset] = seg_base + 2;
                index_offset += 1;
                indices[index_offset] = seg_base;
                index_offset += 1;
                indices[index_offset] = seg_base + 2;
                index_offset += 1;
                indices[index_offset] = seg_base + 3;
                index_offset += 1;
            }

            if (vertex_offset == 0 or index_offset == 0) continue;

            // Upload vertex data
            imports.writeBuffer(
                self.polyline_vertex_buffer,
                0,
                std.mem.sliceAsBytes(vertices[0..vertex_offset]).ptr,
                @intCast(vertex_offset * @sizeOf(GpuPolylineVertex)),
            );

            // Upload index data
            imports.writeBuffer(
                self.polyline_index_buffer,
                0,
                std.mem.sliceAsBytes(indices[0..index_offset]).ptr,
                @intCast(index_offset * @sizeOf(u32)),
            );

            // Upload uniforms
            const gpu_uniforms = GpuPolylineUniforms{
                .color_h = pl.color.h,
                .color_s = pl.color.s,
                .color_l = pl.color.l,
                .color_a = pl.color.a,
                .clip_x = pl.clip_x,
                .clip_y = pl.clip_y,
                .clip_width = pl.clip_width,
                .clip_height = pl.clip_height,
            };
            imports.writeBuffer(
                self.polyline_uniform_buffer,
                0,
                @as([*]const u8, @ptrCast(&gpu_uniforms)),
                @sizeOf(GpuPolylineUniforms),
            );

            // Draw indexed triangles
            imports.setIndexBuffer(self.polyline_index_buffer, imports.IndexFormat.uint32, 0, @intCast(index_offset * @sizeOf(u32)));
            imports.drawIndexed(index_offset, 1, 0, 0, 0);
        }
    }

    /// Render a batch of point clouds
    /// Each point is expanded to a quad with UV for SDF circle rendering
    fn renderPointCloudBatch(self: *Self, scene: *const Scene, start: u32, count: u32) void {
        if (count == 0) return;

        const all_point_clouds = scene.getPointClouds();

        // Slice to the batch we're rendering
        const end = @min(start + count, @as(u32, @intCast(all_point_clouds.len)));
        if (start >= end) return;

        const point_clouds = all_point_clouds[start..end];

        imports.setPipeline(self.point_cloud_pipeline);
        imports.setBindGroup(0, self.point_cloud_bind_group);

        // Temporary buffers for vertex expansion (on stack - reasonable size for WASM)
        var vertices: [MAX_POINT_CLOUD_VERTICES]GpuPointVertex = undefined;
        var indices: [MAX_POINT_CLOUD_INDICES]u32 = undefined;

        // Render each point cloud
        for (point_clouds) |pc| {
            const positions = pc.getPositions();
            if (positions.len == 0) continue;

            const radius = pc.radius;

            var vertex_offset: u32 = 0;
            var index_offset: u32 = 0;

            // Expand each point to a quad
            for (positions) |pos| {
                // Skip if we'd overflow buffers
                if (vertex_offset + 4 > MAX_POINT_CLOUD_VERTICES or index_offset + 6 > MAX_POINT_CLOUD_INDICES) break;

                const pt_base = vertex_offset;

                // Quad corners with UV for SDF
                vertices[vertex_offset] = .{ .x = pos.x - radius, .y = pos.y - radius, .u = -1.0, .v = -1.0 };
                vertex_offset += 1;
                vertices[vertex_offset] = .{ .x = pos.x + radius, .y = pos.y - radius, .u = 1.0, .v = -1.0 };
                vertex_offset += 1;
                vertices[vertex_offset] = .{ .x = pos.x + radius, .y = pos.y + radius, .u = 1.0, .v = 1.0 };
                vertex_offset += 1;
                vertices[vertex_offset] = .{ .x = pos.x - radius, .y = pos.y + radius, .u = -1.0, .v = 1.0 };
                vertex_offset += 1;

                // Two triangles: 0-1-2 and 0-2-3
                indices[index_offset] = pt_base;
                index_offset += 1;
                indices[index_offset] = pt_base + 1;
                index_offset += 1;
                indices[index_offset] = pt_base + 2;
                index_offset += 1;
                indices[index_offset] = pt_base;
                index_offset += 1;
                indices[index_offset] = pt_base + 2;
                index_offset += 1;
                indices[index_offset] = pt_base + 3;
                index_offset += 1;
            }

            if (vertex_offset == 0 or index_offset == 0) continue;

            // Upload vertex data
            imports.writeBuffer(
                self.point_cloud_vertex_buffer,
                0,
                std.mem.sliceAsBytes(vertices[0..vertex_offset]).ptr,
                @intCast(vertex_offset * @sizeOf(GpuPointVertex)),
            );

            // Upload index data
            imports.writeBuffer(
                self.point_cloud_index_buffer,
                0,
                std.mem.sliceAsBytes(indices[0..index_offset]).ptr,
                @intCast(index_offset * @sizeOf(u32)),
            );

            // Upload uniforms
            const gpu_uniforms = GpuPointCloudUniforms{
                .color_h = pc.color.h,
                .color_s = pc.color.s,
                .color_l = pc.color.l,
                .color_a = pc.color.a,
                .clip_x = pc.clip_x,
                .clip_y = pc.clip_y,
                .clip_width = pc.clip_width,
                .clip_height = pc.clip_height,
                .radius = radius,
            };
            imports.writeBuffer(
                self.point_cloud_uniform_buffer,
                0,
                @as([*]const u8, @ptrCast(&gpu_uniforms)),
                @sizeOf(GpuPointCloudUniforms),
            );

            // Draw indexed triangles
            imports.setIndexBuffer(self.point_cloud_index_buffer, imports.IndexFormat.uint32, 0, @intCast(index_offset * @sizeOf(u32)));
            imports.drawIndexed(index_offset, 1, 0, 0, 0);
        }
    }

    /// Render with post-processing shaders
    fn renderWithPostProcess(
        self: *Self,
        prim_count: u32,
        glyph_count: u32,
        svg_count: u32,
        _: f32, // viewport_width - unused, we use device pixels instead
        _: f32, // viewport_height - unused, we use device pixels instead
        clear_r: f32,
        clear_g: f32,
        clear_b: f32,
        clear_a: f32,
    ) void {
        const state: *PostProcessState = blk: {
            if (self.post_process_state) |*s| break :blk s;
            return; // shouldn't happen if hasCustomShaders was true
        };

        // Ensure textures are the right size (use device pixels for sharp rendering)
        const device_width = imports.getCanvasPixelWidth();
        const device_height = imports.getCanvasPixelHeight();
        state.ensureSize(device_width, device_height) catch return;

        // Ensure MSAA texture matches post-process texture size
        if (self.sample_count > 1) {
            self.ensureMSAATexture(device_width, device_height);
        }

        // Update timing uniforms
        state.updateTiming();
        state.uploadUniforms();

        // Step 1: Render scene to front texture (with MSAA if available)
        if (self.sample_count > 1 and self.msaa_texture != 0) {
            imports.beginMSAATextureRenderPass(self.msaa_texture, state.front_texture, clear_r, clear_g, clear_b, clear_a);
        } else {
            const front_view = state.getFrontTextureView();
            imports.beginTextureRenderPass(front_view, clear_r, clear_g, clear_b, clear_a);
        }

        if (prim_count > 0) {
            imports.setPipeline(self.pipeline);
            imports.setBindGroup(0, self.bind_group);
            imports.drawInstanced(6, prim_count);
        }

        if (glyph_count > 0 and self.text_bind_group != 0) {
            imports.setPipeline(self.text_pipeline);
            imports.setBindGroup(0, self.text_bind_group);
            imports.drawInstanced(6, glyph_count);
        }

        if (svg_count > 0 and self.svg_bind_group != 0) {
            imports.setPipeline(self.svg_pipeline);
            imports.setBindGroup(0, self.svg_bind_group);
            imports.drawInstanced(6, svg_count);
        }

        imports.endRenderPass();

        // Step 2: Apply each post-process shader in sequence
        const num_shaders = state.pipelines.items.len;
        for (0..num_shaders) |i| {
            const is_last = (i == num_shaders - 1);
            const pipeline_entry = state.pipelines.items[i];

            // Update bind group to use current front texture
            state.updateBindGroup(i);
            const bind_group = state.bind_groups.items[i];

            if (is_last) {
                // Final pass: render to screen
                const screen_view = imports.getCurrentTextureView();
                imports.beginRenderPass(screen_view, 0, 0, 0, 1);
                imports.setPipeline(pipeline_entry.pipeline);
                imports.setBindGroup(0, bind_group);
                imports.drawInstanced(3, 1); // Fullscreen triangle
                imports.endRenderPass();
                imports.releaseTextureView(screen_view);
            } else {
                // Intermediate pass: render to back texture
                const back_view = state.getBackTextureView();
                imports.beginTextureRenderPass(back_view, 0, 0, 0, 1);
                imports.setPipeline(pipeline_entry.pipeline);
                imports.setBindGroup(0, bind_group);
                imports.drawInstanced(3, 1); // Fullscreen triangle
                imports.endRenderPass();

                // Swap textures for next pass
                state.swapTextures();
            }
        }
    }
};

// =============================================================================
// Tests for GPU struct alignment (WGSL compatibility)
// =============================================================================

test "GpuGradientUniforms size and alignment for WGSL" {
    const testing = std.testing;

    // Total size must be 352 bytes (matches Metal and scene GradientUniforms)
    try testing.expectEqual(@as(usize, 352), @sizeOf(GpuGradientUniforms));

    // WGSL uniform arrays require 16-byte element alignment.
    // Each [4]f32 inner array is 16 bytes, satisfying vec4<f32> alignment.
    try testing.expectEqual(@as(usize, 16), @sizeOf([4]f32));

    // Verify field offsets match WGSL struct layout expectations
    try testing.expectEqual(@as(usize, 0), @offsetOf(GpuGradientUniforms, "gradient_type"));
    try testing.expectEqual(@as(usize, 4), @offsetOf(GpuGradientUniforms, "stop_count"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(GpuGradientUniforms, "_pad0"));
    try testing.expectEqual(@as(usize, 12), @offsetOf(GpuGradientUniforms, "_pad1"));
    try testing.expectEqual(@as(usize, 16), @offsetOf(GpuGradientUniforms, "param0"));
    try testing.expectEqual(@as(usize, 20), @offsetOf(GpuGradientUniforms, "param1"));
    try testing.expectEqual(@as(usize, 24), @offsetOf(GpuGradientUniforms, "param2"));
    try testing.expectEqual(@as(usize, 28), @offsetOf(GpuGradientUniforms, "param3"));

    // Arrays start at offset 32, each is 4 * 16 = 64 bytes
    try testing.expectEqual(@as(usize, 32), @offsetOf(GpuGradientUniforms, "stop_offsets"));
    try testing.expectEqual(@as(usize, 96), @offsetOf(GpuGradientUniforms, "stop_h"));
    try testing.expectEqual(@as(usize, 160), @offsetOf(GpuGradientUniforms, "stop_s"));
    try testing.expectEqual(@as(usize, 224), @offsetOf(GpuGradientUniforms, "stop_l"));
    try testing.expectEqual(@as(usize, 288), @offsetOf(GpuGradientUniforms, "stop_a"));
}

test "GpuGradientUniforms.fromScene converts flat arrays to packed vec4 format" {
    const testing = std.testing;
    const LinearGradient = scene_mod.LinearGradient;
    const Hsla = scene_mod.Hsla;

    // Create a gradient with known stop values
    var grad = LinearGradient.init(10, 20, 110, 120);
    _ = grad.addStop(0.0, Hsla{ .h = 0.0, .s = 1.0, .l = 0.5, .a = 1.0 }); // red
    _ = grad.addStop(0.5, Hsla{ .h = 0.33, .s = 1.0, .l = 0.5, .a = 0.8 }); // green
    _ = grad.addStop(1.0, Hsla{ .h = 0.66, .s = 1.0, .l = 0.5, .a = 0.6 }); // blue

    const scene_gradient = GradientUniforms.fromLinear(grad);
    const gpu_gradient = GpuGradientUniforms.fromScene(scene_gradient);

    // Verify scalar fields copied correctly
    try testing.expectEqual(@as(u32, 1), gpu_gradient.gradient_type);
    try testing.expectEqual(@as(u32, 3), gpu_gradient.stop_count);
    try testing.expectEqual(@as(f32, 10), gpu_gradient.param0);
    try testing.expectEqual(@as(f32, 20), gpu_gradient.param1);

    // Verify packed array format: index i maps to [i/4][i%4]
    // Stop offsets: 0.0, 0.5, 1.0
    try testing.expectEqual(@as(f32, 0.0), gpu_gradient.stop_offsets[0][0]); // index 0
    try testing.expectEqual(@as(f32, 0.5), gpu_gradient.stop_offsets[0][1]); // index 1
    try testing.expectEqual(@as(f32, 1.0), gpu_gradient.stop_offsets[0][2]); // index 2

    // Hue values: 0.0, 0.33, 0.66
    try testing.expectApproxEqAbs(@as(f32, 0.0), gpu_gradient.stop_h[0][0], 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0.33), gpu_gradient.stop_h[0][1], 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0.66), gpu_gradient.stop_h[0][2], 0.01);

    // Alpha values: 1.0, 0.8, 0.6
    try testing.expectApproxEqAbs(@as(f32, 1.0), gpu_gradient.stop_a[0][0], 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0.8), gpu_gradient.stop_a[0][1], 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0.6), gpu_gradient.stop_a[0][2], 0.01);
}

test "GpuGradientUniforms.none creates valid empty gradient" {
    const testing = std.testing;

    const gpu_gradient = GpuGradientUniforms.none();

    try testing.expectEqual(@as(u32, 0), gpu_gradient.gradient_type);
    try testing.expectEqual(@as(u32, 0), gpu_gradient.stop_count);
}
