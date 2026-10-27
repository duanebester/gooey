//! ColoredPointCloudPipeline - Metal rendering for per-point colored circles
//!
//! Like PointCloudPipeline, but each point has its own color.
//! The GPU buffer holds 24 B source points (position and HSLA color, the same
//! `ColoredPoint` layout the Vulkan renderer uploads). The vertex shader expands
//! each point (one instance) into an SDF quad of half-size `radius`; corners are
//! `position ± radius`, bit for bit what the former CPU expansion wrote, so the
//! buffer stores 24 B per point rather than 152 B (4 vertices and 6 indices).

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
const colored_point_cloud = @import("../../../scene/colored_point_cloud.zig");
const ColoredPoint = colored_point_cloud.ColoredPoint;
const ColoredPointCloud = colored_point_cloud.ColoredPointCloud;

// =============================================================================
// Shader Source
// =============================================================================

pub const colored_point_cloud_shader_source =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\
    \\// Source point: position and HSLA color (Zig `ColoredPoint`, 24 B).
    \\struct ColoredPoint {
    \\    float x;
    \\    float y;
    \\    float h;
    \\    float s;
    \\    float l;
    \\    float a;
    \\};
    \\
    \\// Per-draw uniforms (color is per point)
    \\struct ColoredPointCloudUniforms {
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
    \\vertex VertexOut colored_point_cloud_vertex(
    \\    uint vid [[vertex_id]],
    \\    uint point [[instance_id]],
    \\    device const ColoredPoint *points [[buffer(0)]],
    \\    constant ColoredPointCloudUniforms *uniforms [[buffer(1)]],
    \\    constant float2 *viewport_size [[buffer(2)]]
    \\) {
    \\    ColoredPoint p = points[point];
    \\    ColoredPointCloudUniforms u = *uniforms;
    \\    float2 corner = quad_corners[vid];
    \\    float extent = u.radius + 1.0;
    \\    float2 pos = float2(p.x, p.y) + corner * extent;
    \\
    \\    // Convert to NDC
    \\    float2 ndc = pos / *viewport_size * float2(2.0, -2.0) + float2(-1.0, 1.0);
    \\
    \\    VertexOut out;
    \\    out.position = float4(ndc, 0.0, 1.0);
    \\    out.color = hsla_to_rgba(float4(p.h, p.s, p.l, p.a));
    \\    out.clip_bounds = u.clip_bounds;
    \\    out.screen_pos = pos;
    \\    out.uv = corner * (extent / u.radius);
    \\    return out;
    \\}
    \\
    \\fragment float4 colored_point_cloud_fragment(VertexOut in [[stage_in]]) {
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
    \\    // its area. MSAA does not change it: the fragment runs once per pixel.
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

/// Per-draw uniforms (matches shader). Color is per point.
pub const ColoredPointCloudUniforms = extern struct {
    clip_bounds: [4]f32, // x, y, width, height
    radius: f32,
    _pad: [3]f32 = @splat(0),
};

comptime {
    assert(@sizeOf(ColoredPointCloudUniforms) == 32);
    assert(@sizeOf(ColoredPoint) == 24);
    assert(@sizeOf(scene.Point) == 8);
}

// =============================================================================
// Pipeline
// =============================================================================

/// Per-point-color clouds, one SDF quad per point expanded in the vertex shader
/// from the source points (one instance per point), one draw per cloud.
///
/// Resource sketch (CLAUDE.md §7): each frame in flight owns one buffer of
/// `colored_point_count_frame_max` × 24 B source points, sized in `init` from
/// `ResourceLimits.scene` and never replaced. `.standard`: 393,216 B per frame,
/// 1,179,648 B per window for three frames. Per cloud: one claim, one interleaving copy of its
/// positions and colors, and one draw of 6 vertices × points instances. Every
/// cloud is claimed against the same `GeometryCounts` as the Vulkan and CPU
/// renderers before it is written, so an over-budget frame panics with the pool
/// name.
pub const ColoredPointCloudPipeline = struct {
    pipeline_state: objc.Object,
    point_buffers: pipelines.FrameBuffers,
    frame_index: u32,
    /// The window's aggregate geometry budget (`ResourceLimits.scene`).
    geometry_budget: GeometryCounts,
    /// Points claimed this frame; also the slot's write offset.
    geometry_usage: GeometryCounts,

    const Self = @This();

    /// Bytes of one frame's point buffer for `scene_limits`.
    pub fn frameBytes(scene_limits: *const SceneLimits) u64 {
        return @as(u64, scene_limits.colored_point_count_frame_max) * @sizeOf(ColoredPoint);
    }

    pub fn init(device: objc.Object, sample_count: u32, limits: *const ResourceLimits) !Self {
        const scene_limits = &limits.scene;
        assert(sample_count > 0);
        assert(scene_limits.check() == null);
        const pipeline_state = try createPipeline(device, sample_count);
        errdefer pipeline_state.release();

        const point_buffers = try pipelines.createFrameBuffers(
            device,
            frameBytes(scene_limits),
            "colored_points",
            limits.frame.in_flight_count,
        );
        errdefer point_buffers.release();

        return .{
            .pipeline_state = pipeline_state,
            .point_buffers = point_buffers,
            .frame_index = 0,
            .geometry_budget = GeometryCounts.from_limits(scene_limits),
            .geometry_usage = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.point_buffers.release();
        self.pipeline_state.release();
        self.* = undefined;
    }

    /// Advance to the next frame-in-flight slot and release the previous frame's
    /// geometry claims. Call once per rendered frame, before any batch is drawn.
    pub fn nextFrame(self: *Self) void {
        self.frame_index = self.point_buffers.nextIndex(self.frame_index);
        self.geometry_usage = .{};
    }

    /// Render a batch of colored point clouds, one draw per cloud. Every cloud is
    /// clipped to the first cloud's bounds, as the former single batched draw was;
    /// canvas clouds share their clip. (Vulkan clips each cloud to its own bounds.)
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
        const point_buffer = self.point_buffers.at(self.frame_index);
        const points_target = pipelines.frameBufferContents(ColoredPoint, point_buffer);
        const first = clouds[0];
        const clip_bounds = [4]f32{
            first.clip_x, first.clip_y, first.clip_width, first.clip_height,
        };

        encoder.msgSend(void, "setRenderPipelineState:", .{self.pipeline_state.value});
        encoder.msgSend(void, "setVertexBytes:length:atIndex:", .{
            @as(*const anyopaque, @ptrCast(&options.viewport_size)),
            @as(c_ulong, @sizeOf([2]f32)),
            @as(c_ulong, 2),
        });

        for (clouds) |*cloud| {
            cloud.validate();
            const positions = cloud.getPositions();
            const pool_index = @backingInt(GeometryPool.colored_points);
            const point_first = self.geometry_usage.counts[pool_index];
            // Same pool and per-draw granularity as the Vulkan and CPU renderers.
            self.geometry_usage.claim(&self.geometry_budget, .{
                .pool = .colored_points,
                .requested = @intCast(positions.len),
                .frame = options.frame,
            });
            copyColoredPoints(
                points_target[point_first..][0..positions.len],
                positions,
                cloud.getColors(),
            );

            const uniforms = ColoredPointCloudUniforms{
                .clip_bounds = clip_bounds,
                .radius = cloud.radius,
            };
            // The shader reads `device` memory, so a 4 B-aligned offset suffices.
            encoder.msgSend(void, "setVertexBuffer:offset:atIndex:", .{
                point_buffer.value,
                @as(c_ulong, point_first) * @sizeOf(ColoredPoint),
                @as(c_ulong, 0),
            });
            encoder.msgSend(void, "setVertexBytes:length:atIndex:", .{
                @as(*const anyopaque, @ptrCast(&uniforms)),
                @as(c_ulong, @sizeOf(ColoredPointCloudUniforms)),
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

/// Hot loop: interleave a cloud's structure-of-arrays positions and colors into
/// the source points the vertex shader reads, as the Vulkan renderer does.
fn copyColoredPoints(
    target: []ColoredPoint,
    positions: []const scene.Point,
    colors: []const scene.Hsla,
) void {
    assert(target.len == positions.len);
    assert(colors.len == positions.len);
    assert(positions.len <= colored_point_cloud.MAX_POINTS_PER_COLORED_CLOUD);
    for (target, positions, colors) |*point, position, color| {
        point.* = .{ .x = position.x, .y = position.y, .color = color };
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
