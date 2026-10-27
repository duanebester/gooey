//! Point Cloud Pipeline - Metal rendering for instanced circles
//!
//! Renders point clouds as SDF (signed distance field) circles for smooth
//! anti-aliased rendering. Optimized for scatter plots and data markers
//! with thousands of points.
//!
//! Each point is rendered as a quad (4 vertices), with the fragment shader
//! computing a smooth circle using SDF. This provides high-quality rendering
//! without tessellation overhead.

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
const PointCloud = @import("../../../scene/point_cloud.zig").PointCloud;

// =============================================================================
// Shader Source
// =============================================================================

pub const point_cloud_shader_source =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\
    \\// Per-vertex data (quad corner with UV for SDF)
    \\struct PointVertex {
    \\    float x;
    \\    float y;
    \\    float u;  // UV for SDF (-1 to 1)
    \\    float v;
    \\};
    \\
    \\// Per-instance uniforms
    \\struct PointCloudUniforms {
    \\    float4 color;       // HSLA color
    \\    float4 clip_bounds; // x, y, width, height
    \\    float radius;       // Point radius in pixels
    \\    float _pad0;
    \\    float _pad1;
    \\    float _pad2;
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
    \\vertex VertexOut point_cloud_vertex(
    \\    uint vid [[vertex_id]],
    \\    constant PointVertex *vertices [[buffer(0)]],
    \\    constant PointCloudUniforms *uniforms [[buffer(1)]],
    \\    constant float2 *viewport_size [[buffer(2)]]
    \\) {
    \\    PointVertex v = vertices[vid];
    \\    PointCloudUniforms u = *uniforms;
    \\
    \\    float2 pos = float2(v.x, v.y);
    \\
    \\    // Convert to NDC
    \\    float2 ndc = pos / *viewport_size * float2(2.0, -2.0) + float2(-1.0, 1.0);
    \\
    \\    VertexOut out;
    \\    out.position = float4(ndc, 0.0, 1.0);
    \\    out.color = hsla_to_rgba(u.color);
    \\    out.clip_bounds = u.clip_bounds;
    \\    out.screen_pos = pos;
    \\    out.uv = float2(v.u, v.v);
    \\    return out;
    \\}
    \\
    \\fragment float4 point_cloud_fragment(VertexOut in [[stage_in]]) {
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

/// Vertex for point quad (matches shader)
pub const PointVertex = extern struct {
    x: f32,
    y: f32,
    u: f32, // UV for SDF (-1 to 1)
    v: f32,
};

/// Per-point-cloud uniforms (matches shader)
pub const PointCloudUniforms = extern struct {
    color: [4]f32, // HSLA
    clip_bounds: [4]f32, // x, y, width, height
    radius: f32,
    _pad0: f32 = 0,
    _pad1: f32 = 0,
    _pad2: f32 = 0,
};

// =============================================================================
// Pipeline
// =============================================================================

/// Uniform-color point clouds expanded on the CPU into one SDF quad per point,
/// one draw per cloud.
///
/// Resource sketch (CLAUDE.md §7): each frame in flight owns 4 vertices × 16 B and
/// 6 indices × 4 B per budgeted point (`point_count_frame_max`), sized in `init`
/// from `ResourceLimits.scene` and never replaced. `.standard`: 65,536 × 88 B =
/// 5,767,168 B per frame, 17,301,504 B per window. Every cloud is claimed against
/// the same `GeometryCounts` as the Vulkan and CPU renderers before it is written,
/// so an over-budget frame panics with the pool name.
pub const PointCloudPipeline = struct {
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
        const point_count_max: u64 = budget.counts[@backingInt(GeometryPool.points)];

        const pipeline_state = try createPipeline(device, sample_count);
        errdefer pipeline_state.release();

        const vertex_buffers = try pipelines.createFrameBuffers(
            device,
            point_count_max * vertices_per_point * @sizeOf(PointVertex),
            "point_vertices",
        );
        errdefer for (vertex_buffers) |buffer| buffer.release();

        const index_buffers = try pipelines.createFrameBuffers(
            device,
            point_count_max * indices_per_point * @sizeOf(u32),
            "point_indices",
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

    /// Render a batch of point clouds.
    pub fn renderBatch(
        self: *Self,
        encoder: objc.Object,
        point_clouds: []const PointCloud,
        options: struct { viewport_size: [2]f32, frame: u64 },
    ) void {
        assert(point_clouds.len <= scene.MAX_POINT_CLOUDS_PER_FRAME);
        assert(options.viewport_size[0] > 0);
        assert(options.viewport_size[1] > 0);
        const slot = self.frame_index;
        const vertex_buffer = self.vertex_buffers[slot];
        const index_buffer = self.index_buffers[slot];
        const vertices_target = pipelines.frameBufferContents(PointVertex, vertex_buffer);
        const indices_target = pipelines.frameBufferContents(u32, index_buffer);

        encoder.msgSend(void, "setRenderPipelineState:", .{self.pipeline_state.value});
        encoder.msgSend(void, "setVertexBytes:length:atIndex:", .{
            @as(*const anyopaque, @ptrCast(&options.viewport_size)),
            @as(c_ulong, @sizeOf([2]f32)),
            @as(c_ulong, 2),
        });

        for (point_clouds) |*cloud| {
            cloud.validate();
            const positions = cloud.getPositions();
            const point_first = self.geometry_usage.counts[@backingInt(GeometryPool.points)];
            // Same pool and per-draw granularity as the Vulkan and CPU renderers.
            self.geometry_usage.claim(&self.geometry_budget, .{
                .pool = .points,
                .requested = @intCast(positions.len),
                .frame = options.frame,
            });
            const vertex_first = point_first * vertices_per_point;
            const index_first = point_first * indices_per_point;
            const point_count: u32 = @intCast(positions.len);
            expandPoints(
                vertices_target[vertex_first..][0 .. point_count * vertices_per_point],
                indices_target[index_first..][0 .. point_count * indices_per_point],
                positions,
                cloud.radius,
            );

            const uniforms = PointCloudUniforms{
                .color = .{ cloud.color.h, cloud.color.s, cloud.color.l, cloud.color.a },
                .clip_bounds = .{ cloud.clip_x, cloud.clip_y, cloud.clip_width, cloud.clip_height },
                .radius = cloud.radius,
            };
            // Indices are relative to the cloud's first vertex, where the buffer binds.
            encoder.msgSend(void, "setVertexBuffer:offset:atIndex:", .{
                vertex_buffer.value,
                @as(c_ulong, vertex_first) * @sizeOf(PointVertex),
                @as(c_ulong, 0),
            });
            encoder.msgSend(void, "setVertexBytes:length:atIndex:", .{
                @as(*const anyopaque, @ptrCast(&uniforms)),
                @as(c_ulong, @sizeOf(PointCloudUniforms)),
                @as(c_ulong, 1),
            });
            encoder.msgSend(void, "drawIndexedPrimitives:indexCount:indexType:indexBuffer:" ++
                "indexBufferOffset:", .{
                @backingInt(mtl.MTLPrimitiveType.triangle),
                @as(c_ulong, point_count * indices_per_point),
                @backingInt(mtl.MTLIndexType.uint32),
                index_buffer.value,
                @as(c_ulong, index_first) * @sizeOf(u32),
            });
        }
    }
};

const vertices_per_point: u32 = 4;
const indices_per_point: u32 = 6;
/// Quad corners in SDF UV space, ordered 0--1 over 3--2.
const quad_corners = [vertices_per_point][2]f32{ .{ -1, -1 }, .{ 1, -1 }, .{ 1, 1 }, .{ -1, 1 } };

/// Hot loop: expand each point into a quad of half-size `radius` with SDF UVs in
/// -1..1. Indices are relative to the first vertex of `vertices`.
fn expandPoints(
    vertices: []PointVertex,
    indices: []u32,
    positions: []const scene.Point,
    radius: f32,
) void {
    assert(vertices.len == positions.len * vertices_per_point);
    assert(indices.len == positions.len * indices_per_point);
    for (positions, 0..) |position, point| {
        const base: u32 = @intCast(point * vertices_per_point);
        // Multiplying by ±1 is exact, so corners equal `position ± radius` bit for bit.
        for (quad_corners, vertices[base..][0..vertices_per_point]) |corner, *vertex| {
            vertex.* = .{
                .x = position.x + corner[0] * radius,
                .y = position.y + corner[1] * radius,
                .u = corner[0],
                .v = corner[1],
            };
        }

        // Two triangles: 0-1-2 and 0-2-3.
        const index_base = point * indices_per_point;
        indices[index_base..][0..indices_per_point].* = .{
            base, base + 1, base + 2, base, base + 2, base + 3,
        };
    }
}

// =============================================================================
// Helper Functions
// =============================================================================

fn createPipeline(device: objc.Object, sample_count: u32) !objc.Object {
    const NSString = objc.getClass("NSString") orelse return error.ClassNotFound;
    const source_str = NSString.msgSend(
        objc.Object,
        "stringWithUTF8String:",
        .{point_cloud_shader_source.ptr},
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
            std.debug.print("Point cloud shader compilation error: {s}\n", .{cstr});
        }
        return error.ShaderCompilationFailed;
    }

    const library = objc.Object.fromId(library_ptr);
    defer library.release();

    const vertex_name = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"point_cloud_vertex"});
    const fragment_name = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"point_cloud_fragment"});

    const vertex_fn_ptr = library.msgSend(?*anyopaque, "newFunctionWithName:", .{vertex_name.value});
    const fragment_fn_ptr = library.msgSend(?*anyopaque, "newFunctionWithName:", .{fragment_name.value});

    if (vertex_fn_ptr == null or fragment_fn_ptr == null) {
        return error.ShaderFunctionNotFound;
    }

    const vertex_fn = objc.Object.fromId(vertex_fn_ptr);
    const fragment_fn = objc.Object.fromId(fragment_fn_ptr);
    defer vertex_fn.release();
    defer fragment_fn.release();

    const MTLRenderPipelineDescriptor = objc.getClass("MTLRenderPipelineDescriptor") orelse
        return error.ClassNotFound;
    const desc = MTLRenderPipelineDescriptor.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "init", .{});
    defer desc.release();

    desc.msgSend(void, "setVertexFunction:", .{vertex_fn.value});
    desc.msgSend(void, "setFragmentFunction:", .{fragment_fn.value});
    desc.msgSend(void, "setSampleCount:", .{@as(c_ulong, sample_count)});

    const color_attachments = desc.msgSend(objc.Object, "colorAttachments", .{});
    const attachment0 = color_attachments.msgSend(objc.Object, "objectAtIndexedSubscript:", .{@as(c_ulong, 0)});

    // Configure blending
    attachment0.msgSend(void, "setPixelFormat:", .{@backingInt(mtl.MTLPixelFormat.bgra8unorm)});
    attachment0.msgSend(void, "setBlendingEnabled:", .{true});
    attachment0.msgSend(void, "setSourceRGBBlendFactor:", .{@backingInt(mtl.MTLBlendFactor.source_alpha)});
    attachment0.msgSend(void, "setDestinationRGBBlendFactor:", .{@backingInt(mtl.MTLBlendFactor.one_minus_source_alpha)});
    attachment0.msgSend(void, "setSourceAlphaBlendFactor:", .{@backingInt(mtl.MTLBlendFactor.one)});
    attachment0.msgSend(void, "setDestinationAlphaBlendFactor:", .{@backingInt(mtl.MTLBlendFactor.one_minus_source_alpha)});

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
            std.debug.print("Point cloud pipeline creation error: {s}\n", .{cstr});
        }
        return error.PipelineCreationFailed;
    }

    std.debug.print("Point cloud pipeline created successfully\n", .{});
    return objc.Object.fromId(pipeline_ptr);
}
