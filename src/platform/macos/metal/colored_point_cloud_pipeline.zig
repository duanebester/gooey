//! ColoredPointCloudPipeline - Metal rendering for per-point colored circles
//!
//! Like PointCloudPipeline, but each point has its own color.
//! Uses GPU instancing with per-vertex color attributes for single-draw-call
//! rendering of thousands of differently-colored points.
//!
//! ## Performance
//! - Single draw call for ALL points regardless of color
//! - SDF circle rendering (no tessellation, pixel-perfect at any size)
//! - Triple-buffered vertex/index data to avoid GPU stalls

const std = @import("std");
const assert = std.debug.assert;
const objc = @import("objc");

const mtl = @import("api.zig");
const pipelines = @import("pipelines.zig");
const frame_count = pipelines.frame_count;
const scene = @import("../../../scene/mod.zig");
const GeometryCounts = scene.GeometryCounts;
const GeometryPool = scene.GeometryPool;
const SceneLimits = scene.SceneLimits;
const ColoredPointCloud = @import("../../../scene/colored_point_cloud.zig").ColoredPointCloud;

// =============================================================================
// Shader Source
// =============================================================================

pub const colored_point_cloud_shader_source =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\
    \\// Per-vertex data (quad corner with UV for SDF + color)
    \\struct ColoredPointVertex {
    \\    float x;
    \\    float y;
    \\    float u;  // UV for SDF (-1 to 1)
    \\    float v;
    \\    float4 color;  // HSLA color per vertex
    \\};
    \\
    \\// Per-draw uniforms (clip bounds only - color is per-vertex)
    \\struct ColoredPointCloudUniforms {
    \\    float4 clip_bounds; // x, y, width, height
    \\};
    \\
    \\struct VertexOut {
    \\    float4 position [[position]];
    \\    float4 color;
    \\    float4 clip_bounds;
    \\    float2 screen_pos;
    \\    float2 uv;          // For SDF circle
    \\};
    \\
    \\float4 hsla_to_rgba(float4 hsla) {
    \\    float h = hsla.x * 6.0;
    \\    float s = hsla.y;
    \\    float l = hsla.z;
    \\    float a = hsla.w;
    \\    float c = (1.0 - abs(2.0 * l - 1.0)) * s;
    \\    float x = c * (1.0 - abs(fmod(h, 2.0) - 1.0));
    \\    float m = l - c / 2.0;
    \\    float3 rgb;
    \\    if (h < 1.0) rgb = float3(c, x, 0);
    \\    else if (h < 2.0) rgb = float3(x, c, 0);
    \\    else if (h < 3.0) rgb = float3(0, c, x);
    \\    else if (h < 4.0) rgb = float3(0, x, c);
    \\    else if (h < 5.0) rgb = float3(x, 0, c);
    \\    else rgb = float3(c, 0, x);
    \\    return float4(rgb + m, a);
    \\}
    \\
    \\vertex VertexOut colored_point_cloud_vertex(
    \\    uint vid [[vertex_id]],
    \\    constant ColoredPointVertex *vertices [[buffer(0)]],
    \\    constant ColoredPointCloudUniforms *uniforms [[buffer(1)]],
    \\    constant float2 *viewport_size [[buffer(2)]]
    \\) {
    \\    ColoredPointVertex v = vertices[vid];
    \\    ColoredPointCloudUniforms u = *uniforms;
    \\
    \\    float2 pos = float2(v.x, v.y);
    \\
    \\    // Convert to NDC
    \\    float2 ndc = pos / *viewport_size * float2(2.0, -2.0) + float2(-1.0, 1.0);
    \\
    \\    VertexOut out;
    \\    out.position = float4(ndc, 0.0, 1.0);
    \\    out.color = hsla_to_rgba(v.color);  // Color from vertex attribute
    \\    out.clip_bounds = u.clip_bounds;
    \\    out.screen_pos = pos;
    \\    out.uv = float2(v.u, v.v);
    \\    return out;
    \\}
    \\
    \\fragment float4 colored_point_cloud_fragment(VertexOut in [[stage_in]]) {
    \\    // Clip test
    \\    float2 clip_min = in.clip_bounds.xy;
    \\    float2 clip_max = clip_min + in.clip_bounds.zw;
    \\    if (in.screen_pos.x < clip_min.x || in.screen_pos.x > clip_max.x ||
    \\        in.screen_pos.y < clip_min.y || in.screen_pos.y > clip_max.y) {
    \\        discard_fragment();
    \\    }
    \\
    \\    // SDF circle: distance from center
    \\    float dist = length(in.uv);
    \\
    \\    // Smooth anti-aliased edge
    \\    float alpha = 1.0 - smoothstep(0.85, 1.0, dist);
    \\
    \\    if (alpha < 0.001) discard_fragment();
    \\
    \\    float4 color = in.color;
    \\    color.a *= alpha;
    \\
    \\    // Output premultiplied alpha
    \\    return float4(color.rgb * color.a, color.a);
    \\}
;

// =============================================================================
// GPU Types
// =============================================================================

/// Vertex for colored point quad (matches shader)
/// Includes per-vertex color for single-draw-call multi-color rendering
pub const ColoredPointVertex = extern struct {
    x: f32,
    y: f32,
    u: f32, // UV for SDF (-1 to 1)
    v: f32,
    color: [4]f32, // HSLA color
};

/// Per-draw uniforms (matches shader)
/// Only clip bounds - color is per-vertex
pub const ColoredPointCloudUniforms = extern struct {
    clip_bounds: [4]f32, // x, y, width, height
};

// Compile-time size assertions (per CLAUDE.md)
comptime {
    // ColoredPointVertex: 4 floats + 4 floats = 32 bytes
    if (@sizeOf(ColoredPointVertex) != 32) {
        @compileError(std.fmt.comptimePrint(
            "ColoredPointVertex must be 32 bytes, got {}",
            .{@sizeOf(ColoredPointVertex)},
        ));
    }
    // ColoredPointCloudUniforms: 4 floats = 16 bytes
    if (@sizeOf(ColoredPointCloudUniforms) != 16) {
        @compileError(std.fmt.comptimePrint(
            "ColoredPointCloudUniforms must be 16 bytes, got {}",
            .{@sizeOf(ColoredPointCloudUniforms)},
        ));
    }
}

// =============================================================================
// Pipeline
// =============================================================================

/// Per-point-color clouds expanded on the CPU into one SDF quad per point, one
/// draw per batch.
///
/// Resource sketch (CLAUDE.md §7): each frame in flight owns 4 vertices × 32 B and
/// 6 indices × 4 B per budgeted point (`colored_point_count_frame_max`), sized in
/// `init` from `ResourceLimits.scene` and never replaced. `.standard`: 65,536 ×
/// 152 B = 9,961,472 B per frame, 29,884,416 B per window. Every cloud is claimed
/// against the same `GeometryCounts` as the Vulkan and CPU renderers before it is
/// written, so an over-budget frame panics with the pool name.
pub const ColoredPointCloudPipeline = struct {
    pipeline_state: objc.Object,
    vertex_buffers: [frame_count]objc.Object,
    index_buffers: [frame_count]objc.Object,
    frame_index: u32,
    /// The window's aggregate geometry budget (`ResourceLimits.scene`).
    geometry_budget: GeometryCounts,
    /// Points claimed this frame. Every claimed point is written as exactly one
    /// quad, so this count also locates the slot's write offsets.
    geometry_usage: GeometryCounts,

    const Self = @This();

    pub fn init(device: objc.Object, sample_count: u32, scene_limits: *const SceneLimits) !Self {
        assert(sample_count > 0);
        assert(scene_limits.check() == null);
        const budget = GeometryCounts.from_limits(scene_limits);
        const point_count_max: u64 = budget.counts[@backingInt(GeometryPool.colored_points)];

        const pipeline_state = try createPipeline(device, sample_count);
        errdefer pipeline_state.release();

        const vertex_buffers = try pipelines.createFrameBuffers(
            device,
            point_count_max * vertices_per_point * @sizeOf(ColoredPointVertex),
            "colored_point_vertices",
        );
        errdefer for (vertex_buffers) |buffer| buffer.release();

        const index_buffers = try pipelines.createFrameBuffers(
            device,
            point_count_max * indices_per_point * @sizeOf(u32),
            "colored_point_indices",
        );
        errdefer for (index_buffers) |buffer| buffer.release();

        return .{
            .pipeline_state = pipeline_state,
            .vertex_buffers = vertex_buffers,
            .index_buffers = index_buffers,
            .frame_index = 0,
            .geometry_budget = budget,
            .geometry_usage = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.vertex_buffers) |buffer| buffer.release();
        for (self.index_buffers) |buffer| buffer.release();
        self.pipeline_state.release();
        self.* = undefined;
    }

    /// Advance to the next frame-in-flight slot and release the previous frame's
    /// geometry claims. Call once per rendered frame, before any batch is drawn.
    pub fn nextFrame(self: *Self) void {
        assert(self.frame_index < frame_count);
        self.frame_index = (self.frame_index + 1) % frame_count;
        self.geometry_usage = .{};
    }

    /// Render a batch of colored point clouds in a single draw call. The batch
    /// is clipped to the first cloud's bounds; canvas clouds share their clip.
    pub fn renderBatch(
        self: *Self,
        encoder: objc.Object,
        clouds: []const ColoredPointCloud,
        options: struct { viewport_size: [2]f32, frame: u64 },
    ) void {
        assert(clouds.len > 0);
        assert(clouds.len <= scene.MAX_COLORED_POINT_CLOUDS_PER_FRAME);
        assert(options.viewport_size[0] > 0);
        assert(options.viewport_size[1] > 0);
        const slot = self.frame_index;
        const vertex_buffer = self.vertex_buffers[slot];
        const index_buffer = self.index_buffers[slot];
        const vertices_target = pipelines.frameBufferContents(ColoredPointVertex, vertex_buffer);
        const indices_target = pipelines.frameBufferContents(u32, index_buffer);

        const batch_point_first = self.pointsClaimed();
        for (clouds) |*cloud| {
            cloud.validate();
            const positions = cloud.getPositions();
            const point_first = self.pointsClaimed();
            // Same pool and per-draw granularity as the Vulkan and CPU renderers.
            self.geometry_usage.claim(&self.geometry_budget, .{
                .pool = .colored_points,
                .requested = @intCast(positions.len),
                .frame = options.frame,
            });
            const point_count: u32 = @intCast(positions.len);
            expandColoredPoints(
                vertices_target[point_first * vertices_per_point ..][0 .. point_count *
                    vertices_per_point],
                indices_target[point_first * indices_per_point ..][0 .. point_count *
                    indices_per_point],
                .{
                    .positions = positions,
                    .colors = cloud.getColors(),
                    .radius = cloud.radius,
                    .vertex_base = (point_first - batch_point_first) * vertices_per_point,
                },
            );
        }
        const point_count = self.pointsClaimed() - batch_point_first;
        assert(point_count > 0);

        const first = clouds[0];
        const uniforms = ColoredPointCloudUniforms{
            .clip_bounds = .{ first.clip_x, first.clip_y, first.clip_width, first.clip_height },
        };
        encoder.msgSend(void, "setRenderPipelineState:", .{self.pipeline_state.value});
        // Indices are relative to the batch's first vertex, where the buffer binds.
        encoder.msgSend(void, "setVertexBuffer:offset:atIndex:", .{
            vertex_buffer.value,
            @as(c_ulong, batch_point_first) * vertices_per_point * @sizeOf(ColoredPointVertex),
            @as(c_ulong, 0),
        });
        encoder.msgSend(void, "setVertexBytes:length:atIndex:", .{
            @as(*const anyopaque, @ptrCast(&uniforms)),
            @as(c_ulong, @sizeOf(ColoredPointCloudUniforms)),
            @as(c_ulong, 1),
        });
        encoder.msgSend(void, "setVertexBytes:length:atIndex:", .{
            @as(*const anyopaque, @ptrCast(&options.viewport_size)),
            @as(c_ulong, @sizeOf([2]f32)),
            @as(c_ulong, 2),
        });
        encoder.msgSend(void, "drawIndexedPrimitives:indexCount:indexType:indexBuffer:" ++
            "indexBufferOffset:", .{
            @backingInt(mtl.MTLPrimitiveType.triangle),
            @as(c_ulong, point_count) * indices_per_point,
            @backingInt(mtl.MTLIndexType.uint32),
            index_buffer.value,
            @as(c_ulong, batch_point_first) * indices_per_point * @sizeOf(u32),
        });
    }

    fn pointsClaimed(self: *const Self) u32 {
        return self.geometry_usage.counts[@backingInt(GeometryPool.colored_points)];
    }
};

const vertices_per_point: u32 = 4;
const indices_per_point: u32 = 6;
/// Quad corners in SDF UV space, ordered 0--1 over 3--2.
const quad_corners = [vertices_per_point][2]f32{ .{ -1, -1 }, .{ 1, -1 }, .{ 1, 1 }, .{ -1, 1 } };

/// Hot loop: expand each point into a quad of half-size `radius` carrying the
/// point's HSLA color. Indices start at `vertex_base`, the cloud's first vertex
/// relative to the batch.
fn expandColoredPoints(
    vertices: []ColoredPointVertex,
    indices: []u32,
    cloud: struct {
        positions: []const scene.Point,
        colors: []const scene.Hsla,
        radius: f32,
        vertex_base: u32,
    },
) void {
    assert(cloud.colors.len == cloud.positions.len);
    assert(vertices.len == cloud.positions.len * vertices_per_point);
    assert(indices.len == cloud.positions.len * indices_per_point);
    for (cloud.positions, cloud.colors, 0..) |position, color, point| {
        const local: u32 = @intCast(point * vertices_per_point);
        const hsla = [4]f32{ color.h, color.s, color.l, color.a };
        // Multiplying by ±1 is exact, so corners equal `position ± radius` bit for bit.
        for (quad_corners, vertices[local..][0..vertices_per_point]) |corner, *vertex| {
            vertex.* = .{
                .x = position.x + corner[0] * cloud.radius,
                .y = position.y + corner[1] * cloud.radius,
                .u = corner[0],
                .v = corner[1],
                .color = hsla,
            };
        }

        // Two triangles: 0-1-2 and 0-2-3.
        const base = cloud.vertex_base + local;
        const index_base = point * indices_per_point;
        indices[index_base..][0..indices_per_point].* = .{
            base, base + 1, base + 2, base, base + 2, base + 3,
        };
    }
}

// =============================================================================
// Pipeline Creation
// =============================================================================

fn createPipeline(device: objc.Object, sample_count: u32) !objc.Object {
    const NSString = objc.getClass("NSString") orelse return error.ClassNotFound;
    const source_str = NSString.msgSend(
        objc.Object,
        "stringWithUTF8String:",
        .{colored_point_cloud_shader_source.ptr},
    );

    var compile_error: ?*anyopaque = null;
    const library_ptr = device.msgSend(
        ?*anyopaque,
        "newLibraryWithSource:options:error:",
        .{ source_str.value, @as(?*anyopaque, null), &compile_error },
    );

    if (library_ptr == null) {
        if (compile_error) |err| {
            const err_obj = objc.Object.fromId(err);
            const desc = err_obj.msgSend(objc.Object, "localizedDescription", .{});
            const cstr = desc.msgSend([*:0]const u8, "UTF8String", .{});
            std.debug.print("Colored point cloud shader compilation error: {s}\n", .{cstr});
        }
        return error.ShaderCompilationFailed;
    }

    const library = objc.Object.fromId(library_ptr);
    defer library.release();

    const vertex_name = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"colored_point_cloud_vertex"});
    const fragment_name = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"colored_point_cloud_fragment"});

    const vertex_fn_ptr = library.msgSend(?*anyopaque, "newFunctionWithName:", .{vertex_name.value});
    const fragment_fn_ptr = library.msgSend(?*anyopaque, "newFunctionWithName:", .{fragment_name.value});

    if (vertex_fn_ptr == null or fragment_fn_ptr == null) {
        return error.ShaderFunctionNotFound;
    }

    const vertex_fn = objc.Object.fromId(vertex_fn_ptr);
    const fragment_fn = objc.Object.fromId(fragment_fn_ptr);
    defer vertex_fn.release();
    defer fragment_fn.release();

    // Create pipeline descriptor
    const MTLRenderPipelineDescriptor = objc.getClass("MTLRenderPipelineDescriptor") orelse
        return error.ClassNotFound;
    const desc = MTLRenderPipelineDescriptor.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "init", .{});
    defer desc.release();

    desc.msgSend(void, "setVertexFunction:", .{vertex_fn.value});
    desc.msgSend(void, "setFragmentFunction:", .{fragment_fn.value});
    desc.msgSend(void, "setSampleCount:", .{@as(c_ulong, sample_count)});

    // Configure color attachment for premultiplied alpha blending
    const color_attachments = desc.msgSend(objc.Object, "colorAttachments", .{});
    const attachment0 = color_attachments.msgSend(objc.Object, "objectAtIndexedSubscript:", .{@as(c_ulong, 0)});

    attachment0.msgSend(void, "setPixelFormat:", .{@backingInt(mtl.MTLPixelFormat.bgra8unorm)});
    attachment0.msgSend(void, "setBlendingEnabled:", .{true});
    attachment0.msgSend(void, "setSourceRGBBlendFactor:", .{@backingInt(mtl.MTLBlendFactor.source_alpha)});
    attachment0.msgSend(void, "setDestinationRGBBlendFactor:", .{@backingInt(mtl.MTLBlendFactor.one_minus_source_alpha)});
    attachment0.msgSend(void, "setSourceAlphaBlendFactor:", .{@backingInt(mtl.MTLBlendFactor.one)});
    attachment0.msgSend(void, "setDestinationAlphaBlendFactor:", .{@backingInt(mtl.MTLBlendFactor.one_minus_source_alpha)});

    // Create pipeline state
    var pipeline_error: ?*anyopaque = null;
    const pipeline_ptr = device.msgSend(
        ?*anyopaque,
        "newRenderPipelineStateWithDescriptor:error:",
        .{ desc.value, &pipeline_error },
    );

    if (pipeline_ptr == null) {
        if (pipeline_error) |err| {
            const err_obj = objc.Object.fromId(err);
            const desc_str = err_obj.msgSend(objc.Object, "localizedDescription", .{});
            const cstr = desc_str.msgSend([*:0]const u8, "UTF8String", .{});
            std.debug.print("Colored point cloud pipeline creation error: {s}\n", .{cstr});
        }
        return error.PipelineCreationFailed;
    }

    std.debug.print("Colored point cloud pipeline created successfully\n", .{});
    return objc.Object.fromId(pipeline_ptr);
}
