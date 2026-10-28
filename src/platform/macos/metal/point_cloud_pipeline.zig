//! Point Cloud Pipeline - Metal rendering for instanced circles
//!
//! Renders point clouds as SDF (signed distance field) circles for smooth
//! anti-aliased rendering. Optimized for scatter plots and data markers
//! with thousands of points.
//!
//! The GPU buffer holds source positions only. The vertex shader expands each
//! point (one instance) into a quad of half-size `radius`, and the fragment
//! shader computes a smooth circle with an SDF. Corners are `position ± radius`,
//! bit for bit what the former CPU expansion wrote, so the buffer stores 8 B per
//! point rather than 88 B (4 vertices and 6 indices).

const std = @import("std");
const assert = std.debug.assert;

const objc = @import("objc");
const mtl = @import("api.zig");
const pipelines = @import("pipelines.zig");
const scene = @import("../../../scene/mod.zig");
const GeometryCounts = scene.GeometryCounts;
const GeometryPool = scene.GeometryPool;
const SceneLimits = scene.SceneLimits;
const ResourceLimits = @import("../../../core/limits.zig").ResourceLimits;
const PointCloud = @import("../../../scene/point_cloud.zig").PointCloud;

// =============================================================================
// Shader Source
// =============================================================================

pub const point_cloud_shader_source =
    \\#include <metal_stdlib>
    \\using namespace metal;
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
    \\// SDF UV corner of each vertex of triangles 0-1-2 and 0-2-3 of the quad
    \\// (-1,-1)--(1,-1) over (-1,1)--(1,1): the former CPU index order.
    \\constant float2 quad_corners[6] = {
    \\    float2(-1.0, -1.0), float2(1.0, -1.0), float2(1.0, 1.0),
    \\    float2(-1.0, -1.0), float2(1.0, 1.0), float2(-1.0, 1.0),
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
    \\// One instance per point. The quad reaches one logical pixel past the
    \\// radius so the fragment falloff can straddle the circle's edge; uv stays
    \\// 1.0 at the radius. Multiplying by a +-1 corner is exact, so even a fused
    \\// multiply-add yields `position +- extent` correctly rounded.
    \\vertex VertexOut point_cloud_vertex(
    \\    uint vid [[vertex_id]],
    \\    uint point [[instance_id]],
    \\    device const float2 *positions [[buffer(0)]],
    \\    constant PointCloudUniforms *uniforms [[buffer(1)]],
    \\    constant float2 *viewport_size [[buffer(2)]]
    \\) {
    \\    PointCloudUniforms u = *uniforms;
    \\    float2 corner = quad_corners[vid];
    \\    float extent = u.radius + 1.0;
    \\    float2 pos = positions[point] + corner * extent;
    \\
    \\    // Convert to NDC
    \\    float2 ndc = pos / *viewport_size * float2(2.0, -2.0) + float2(-1.0, 1.0);
    \\
    \\    VertexOut out;
    \\    out.position = float4(ndc, 0.0, 1.0);
    \\    out.color = hsla_to_rgba(u.color);
    \\    out.clip_bounds = u.clip_bounds;
    \\    out.screen_pos = pos;
    \\    out.uv = corner * (extent / u.radius);
    \\    return out;
    \\}
    \\
    \\fragment float4 point_cloud_fragment(VertexOut in [[stage_in]]) {
    \\    // Derivatives first: they are undefined after a non-uniform discard.
    \\    float uv_pixel = length(float2(dfdx(in.uv.x), dfdy(in.uv.x)));
    \\
    \\    // Clip test
    \\    float2 clip_min = in.clip_bounds.xy;
    \\    float2 clip_max = clip_min + in.clip_bounds.zw;
    \\    if (in.screen_pos.x < clip_min.x || in.screen_pos.x > clip_max.x ||
    \\        in.screen_pos.y < clip_min.y || in.screen_pos.y > clip_max.y) {
    \\        discard_fragment();
    \\    }
    \\
    \\    // Shared point falloff (cpu/mesh.zig `pointFalloff`, Vulkan mesh.frag).
    \\    // From a 6.7 device pixel radius up it is the historical falloff over
    \\    // the outer 15% of the radius. Smaller points get a one-pixel band that
    \\    // moves outward to straddle the edge, so a sub-pixel dot keeps about
    \\    // its area.
    \\    float radius_px = 1.0 / max(uv_pixel, 1e-6);
    \\    float dist = length(in.uv);
    \\    float alpha;
    \\    if (radius_px >= 1.0 / 0.15) {
    \\        alpha = 1.0 - smoothstep(0.85, 1.0, dist);
    \\    } else {
    \\        float end_px = radius_px + 0.5 * (1.0 - 0.15 * radius_px);
    \\        alpha = 1.0 - smoothstep(end_px - 1.0, end_px, dist * radius_px);
    \\    }
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

/// Per-point-cloud uniforms (matches shader)
pub const PointCloudUniforms = extern struct {
    color: [4]f32, // HSLA
    clip_bounds: [4]f32, // x, y, width, height
    radius: f32,
    _pad: [3]f32 = @splat(0),
};

comptime {
    assert(@sizeOf(PointCloudUniforms) == 48);
    assert(@sizeOf(scene.Point) == 8);
}

// =============================================================================
// Pipeline
// =============================================================================

/// Uniform-color point clouds, one SDF quad per point expanded in the vertex
/// shader from the source positions (one instance per point), one draw per cloud.
///
/// Resource sketch (CLAUDE.md §7): each frame in flight owns one buffer of
/// `point_count_frame_max` × 8 B source positions, sized in `init` from
/// `ResourceLimits.scene` and never replaced. `.standard`: 131,072 B per frame,
/// 393,216 B per window for three frames. Per cloud: one claim, one copy of its positions, and
/// one draw of 6 vertices × points instances. Every cloud is claimed against the
/// same `GeometryCounts` as the Vulkan and CPU renderers before it is written, so
/// an over-budget frame panics with the pool name.
pub const PointCloudPipeline = struct {
    pipeline_state: objc.Object,
    position_buffers: pipelines.FrameBuffers,
    frame_index: u32,
    /// The window's aggregate geometry budget (`ResourceLimits.scene`).
    geometry_budget: GeometryCounts,
    /// Points claimed this frame; also the slot's write offset.
    geometry_usage: GeometryCounts,

    const Self = @This();

    /// Bytes of one frame's position buffer for `scene_limits`.
    pub fn frameBytes(scene_limits: *const SceneLimits) u64 {
        return @as(u64, scene_limits.point_count_frame_max) * @sizeOf(scene.Point);
    }

    pub fn init(device: objc.Object, limits: *const ResourceLimits) !Self {
        const scene_limits = &limits.scene;
        assert(device.value != null);
        assert(scene_limits.check() == null);
        const pipeline_state = try createPipeline(device);
        errdefer pipeline_state.release();

        const position_buffers = try pipelines.createFrameBuffers(
            device,
            frameBytes(scene_limits),
            "point_positions",
            limits.frame.in_flight_count,
        );
        errdefer position_buffers.release();

        return .{
            .pipeline_state = pipeline_state,
            .position_buffers = position_buffers,
            .frame_index = 0,
            .geometry_budget = GeometryCounts.from_limits(scene_limits),
            .geometry_usage = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.position_buffers.release();
        self.pipeline_state.release();
        self.* = undefined;
    }

    /// Advance to the next frame-in-flight slot and release the previous frame's
    /// geometry claims. Call once per rendered frame, before any batch is drawn.
    pub fn nextFrame(self: *Self) void {
        self.frame_index = self.position_buffers.nextIndex(self.frame_index);
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
        const position_buffer = self.position_buffers.at(self.frame_index);
        const positions_target = pipelines.frameBufferContents(scene.Point, position_buffer);

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
            @memcpy(positions_target[point_first..][0..positions.len], positions);

            const uniforms = PointCloudUniforms{
                .color = .{ cloud.color.h, cloud.color.s, cloud.color.l, cloud.color.a },
                .clip_bounds = .{ cloud.clip_x, cloud.clip_y, cloud.clip_width, cloud.clip_height },
                .radius = cloud.radius,
            };
            // The shader reads `device` memory, so an 8 B-aligned offset suffices.
            encoder.msgSend(void, "setVertexBuffer:offset:atIndex:", .{
                position_buffer.value,
                @as(c_ulong, point_first) * @sizeOf(scene.Point),
                @as(c_ulong, 0),
            });
            encoder.msgSend(void, "setVertexBytes:length:atIndex:", .{
                @as(*const anyopaque, @ptrCast(&uniforms)),
                @as(c_ulong, @sizeOf(PointCloudUniforms)),
                @as(c_ulong, 1),
            });
            // Instances draw in order, so points blend in the order the former
            // indexed draw emitted them.
            encoder.msgSend(void, "drawPrimitives:vertexStart:vertexCount:instanceCount:", .{
                @backingInt(mtl.MTLPrimitiveType.triangle),
                @as(c_ulong, 0),
                @as(c_ulong, 6),
                @as(c_ulong, positions.len),
            });
        }
    }
};

// =============================================================================
// Helper Functions
// =============================================================================

fn createPipeline(device: objc.Object) !objc.Object {
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
    desc.msgSend(void, "setSampleCount:", .{@as(c_ulong, pipelines.sample_count)});

    const color_attachments = desc.msgSend(objc.Object, "colorAttachments", .{});
    const attachment0 = color_attachments.msgSend(objc.Object, "objectAtIndexedSubscript:", .{@as(c_ulong, 0)});

    // The fragment shader outputs premultiplied alpha, so source RGB blends
    // with ONE, as Vulkan's mesh pipelines do. With SOURCE_ALPHA the point
    // falloff would apply twice (rgb * a * a).
    attachment0.msgSend(void, "setPixelFormat:", .{@backingInt(mtl.MTLPixelFormat.bgra8unorm)});
    attachment0.msgSend(void, "setBlendingEnabled:", .{true});
    attachment0.msgSend(void, "setSourceRGBBlendFactor:", .{@backingInt(mtl.MTLBlendFactor.one)});
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
