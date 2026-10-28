//! Polyline Pipeline - Metal rendering for efficient line strips
//!
//! Renders polylines as expanded quads for line width support.
//! Optimized for chart data visualization with thousands of connected points.
//!
//! The GPU buffer holds source points only. The vertex shader expands each line
//! segment (one instance) into a butt-ended quad, so the buffer stores 8 B per
//! point rather than 56 B per segment (4 vertices and 6 indices). Edges are
//! anti-aliased analytically, as in Vulkan's `strip_expanded.vert`: the quad
//! grows one logical pixel across its sides (and the line's two end caps) and
//! the fragment shader fades coverage across that fringe.

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
const Polyline = @import("../../../scene/polyline.zig").Polyline;

// =============================================================================
// Shader Source
// =============================================================================

pub const polyline_shader_source =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\
    \\// Per-polyline uniforms
    \\struct PolylineUniforms {
    \\    float4 color;       // HSLA color
    \\    float4 clip_bounds; // x, y, width, height
    \\    float half_width;
    \\    uint segment_count; // points - 1: only the line's two ends are capped
    \\    float _pad1;
    \\    float _pad2;
    \\};
    \\
    \\// One logical pixel is at least one device pixel at every supported scale.
    \\constant float aa_fringe = 1.0;
    \\
    \\// Quad corner of each vertex of triangles 0-1-2 and 0-2-3, as (along,
    \\// across) signs: corner 0 is start+perp, 1 start-perp, 2 end-perp and
    \\// 3 end+perp, the triangle order of the former CPU expansion.
    \\constant float2 quad_corners[6] = {
    \\    float2(-1.0, 1.0), float2(-1.0, -1.0), float2(1.0, -1.0),
    \\    float2(-1.0, 1.0), float2(1.0, -1.0), float2(1.0, 1.0),
    \\};
    \\
    \\struct VertexOut {
    \\    float4 position [[position]];
    \\    float4 color;
    \\    float4 clip_bounds;
    \\    float2 screen_pos;
    \\    // Signed distances in logical pixels to the segment's two sides and its
    \\    // start and end, positive inside. Affine, so interpolation is exact.
    \\    float4 edge_distance;
    \\    // Two bits per distance; 1 fades across that edge (mesh_edges.EdgeMode).
    \\    uint edge_modes [[flat]];
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
    \\// One instance per segment: a butt-ended quad from points[segment] to
    \\// points[segment + 1], half_width either side, grown by `aa_fringe` across
    \\// both sides so their fade is rasterized. Only the line's first start cap
    \\// and last end cap extend and fade; interior joints stay hard, so
    \\// consecutive segments still overlap without a seam. Ported from Vulkan's
    \\// strip_expanded.vert.
    \\vertex VertexOut polyline_vertex(
    \\    uint vid [[vertex_id]],
    \\    uint segment [[instance_id]],
    \\    device const float2 *points [[buffer(0)]],
    \\    constant PolylineUniforms *uniforms [[buffer(1)]],
    \\    constant float2 *viewport_size [[buffer(2)]]
    \\) {
    \\    PolylineUniforms u = *uniforms;
    \\    float2 start = points[segment];
    \\    float2 end = points[segment + 1];
    \\    float2 direction = end - start;
    \\    float distance = length(direction);
    \\    // Zero-length segments keep their degenerate quad: they cover no pixels.
    \\    float2 along_unit = float2(1.0, 0.0);
    \\    float2 across_unit = float2(0.0, 1.0);
    \\    bool has_length = distance > 0.0001;
    \\    if (has_length) {
    \\        along_unit = direction / distance;
    \\        across_unit = float2(-along_unit.y, along_unit.x);
    \\    }
    \\    bool cap_start = has_length && segment == 0;
    \\    bool cap_end = has_length && segment + 1 == u.segment_count;
    \\    float2 corner = quad_corners[vid];
    \\    float across = corner.y * (u.half_width + aa_fringe);
    \\    float along = corner.x < 0.0 ? (cap_start ? -aa_fringe : 0.0) :
    \\        distance + (cap_end ? aa_fringe : 0.0);
    \\    float2 pos = start + along_unit * along + across_unit * across;
    \\
    \\    // Convert to NDC
    \\    float2 ndc = pos / *viewport_size * float2(2.0, -2.0) + float2(-1.0, 1.0);
    \\
    \\    VertexOut out;
    \\    out.position = float4(ndc, 0.0, 1.0);
    \\    out.color = hsla_to_rgba(u.color);
    \\    out.clip_bounds = u.clip_bounds;
    \\    out.screen_pos = pos;
    \\    out.edge_distance = float4(u.half_width + across, u.half_width - across,
    \\                               along, distance - along);
    \\    out.edge_modes = 1u | (1u << 2) | (cap_start ? 1u << 4 : 0u) |
    \\        (cap_end ? 1u << 6 : 0u);
    \\    return out;
    \\}
    \\
    \\fragment float4 polyline_fragment(VertexOut in [[stage_in]]) {
    \\    // Derivatives first: they are undefined after a non-uniform discard.
    \\    float4 edge_dx = dfdx(in.edge_distance);
    \\    float4 edge_dy = dfdy(in.edge_distance);
    \\    float4 edge_pixel = sqrt(edge_dx * edge_dx + edge_dy * edge_dy);
    \\
    \\    // Clip test
    \\    float2 clip_min = in.clip_bounds.xy;
    \\    float2 clip_max = clip_min + in.clip_bounds.zw;
    \\    if (in.screen_pos.x < clip_min.x || in.screen_pos.x > clip_max.x ||
    \\        in.screen_pos.y < clip_min.y || in.screen_pos.y > clip_max.y) {
    \\        discard_fragment();
    \\    }
    \\
    \\    // Fade across every flagged edge over one device pixel centred on it.
    \\    float4 distance_px = in.edge_distance / max(edge_pixel, float4(1e-6));
    \\    float coverage = 1.0;
    \\    for (uint edge = 0; edge < 4; edge++) {
    \\        if (((in.edge_modes >> (2 * edge)) & 3) == 1) {
    \\            coverage *= clamp(distance_px[edge] + 0.5, 0.0, 1.0);
    \\        }
    \\    }
    \\    float alpha = in.color.a * coverage;
    \\    if (alpha < 0.001) discard_fragment();
    \\
    \\    // Output premultiplied alpha (the pipeline blends with ONE).
    \\    return float4(in.color.rgb * alpha, alpha);
    \\}
;

// =============================================================================
// GPU Types
// =============================================================================

/// Per-polyline uniforms (matches shader)
pub const PolylineUniforms = extern struct {
    color: [4]f32, // HSLA
    clip_bounds: [4]f32, // x, y, width, height
    half_width: f32,
    /// Points - 1. The shader caps (extends and fades) only the line's first
    /// start and last end, not the joints between segments.
    segment_count: u32,
    _pad: [2]f32 = @splat(0),
};

comptime {
    std.debug.assert(@sizeOf(PolylineUniforms) == 48);
    std.debug.assert(@offsetOf(PolylineUniforms, "segment_count") == 36);
    std.debug.assert(@sizeOf(scene.Point) == 8);
}

// =============================================================================
// Pipeline
// =============================================================================

/// Polylines drawn as one butt-ended quad per segment, expanded in the vertex
/// shader from the source points (one instance per segment), one draw per polyline.
///
/// Resource sketch (CLAUDE.md §7): each frame in flight owns one buffer of
/// `polyline_point_count_frame_max` × 8 B source points, sized in `init` from
/// `ResourceLimits.scene` and never replaced. `.standard`: 262,144 B per frame,
/// 786,432 B per window for three frames. Per polyline: one claim, one copy of its points, and
/// one draw of 6 vertices × (points - 1) instances. Every polyline is claimed
/// against the same `GeometryCounts` as the Vulkan and CPU renderers before it is
/// written, so an over-budget frame panics with the pool name.
pub const PolylinePipeline = struct {
    pipeline_state: objc.Object,
    point_buffers: pipelines.FrameBuffers,
    frame_index: u32,
    /// The window's aggregate geometry budget (`ResourceLimits.scene`).
    geometry_budget: GeometryCounts,
    /// Source points claimed this frame; also the slot's write offset.
    geometry_usage: GeometryCounts,

    const Self = @This();

    /// Bytes of one frame's point buffer for `scene_limits`.
    pub fn frameBytes(scene_limits: *const SceneLimits) u64 {
        return @as(u64, scene_limits.polyline_point_count_frame_max) * @sizeOf(scene.Point);
    }

    pub fn init(device: objc.Object, limits: *const ResourceLimits) !Self {
        const scene_limits = &limits.scene;
        assert(device.value != null);
        assert(scene_limits.check() == null);
        const pipeline_state = try createPipeline(device);
        errdefer pipeline_state.release();

        const point_buffers = try pipelines.createFrameBuffers(
            device,
            frameBytes(scene_limits),
            "polyline_points",
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

    /// Render a batch of polylines.
    pub fn renderBatch(
        self: *Self,
        encoder: objc.Object,
        polylines: []const Polyline,
        options: struct { viewport_size: [2]f32, frame: u64 },
    ) void {
        assert(polylines.len <= scene.MAX_POLYLINES_PER_FRAME);
        assert(options.viewport_size[0] > 0);
        assert(options.viewport_size[1] > 0);
        const point_buffer = self.point_buffers.at(self.frame_index);
        const points_target = pipelines.frameBufferContents(scene.Point, point_buffer);

        encoder.msgSend(void, "setRenderPipelineState:", .{self.pipeline_state.value});
        encoder.msgSend(void, "setVertexBytes:length:atIndex:", .{
            @as(*const anyopaque, @ptrCast(&options.viewport_size)),
            @as(c_ulong, @sizeOf([2]f32)),
            @as(c_ulong, 2),
        });

        for (polylines) |*polyline| {
            polyline.validate();
            const points = polyline.getPoints();
            const pool_index = @backingInt(GeometryPool.polyline_points);
            const point_first = self.geometry_usage.counts[pool_index];
            // Same pool and per-draw granularity as the Vulkan and CPU renderers.
            self.geometry_usage.claim(&self.geometry_budget, .{
                .pool = .polyline_points,
                .requested = @intCast(points.len),
                .frame = options.frame,
            });
            @memcpy(points_target[point_first..][0..points.len], points);

            const color = polyline.color;
            const uniforms = PolylineUniforms{
                .color = .{ color.h, color.s, color.l, color.a },
                .clip_bounds = .{
                    polyline.clip_x,
                    polyline.clip_y,
                    polyline.clip_width,
                    polyline.clip_height,
                },
                .half_width = polyline.width * 0.5,
                .segment_count = @intCast(points.len - 1),
            };
            assert(uniforms.segment_count >= 1);
            // The shader reads `device` memory, so an 8 B-aligned offset suffices.
            encoder.msgSend(void, "setVertexBuffer:offset:atIndex:", .{
                point_buffer.value,
                @as(c_ulong, point_first) * @sizeOf(scene.Point),
                @as(c_ulong, 0),
            });
            encoder.msgSend(void, "setVertexBytes:length:atIndex:", .{
                @as(*const anyopaque, @ptrCast(&uniforms)),
                @as(c_ulong, @sizeOf(PolylineUniforms)),
                @as(c_ulong, 1),
            });
            // Instances draw in order, so segments blend in the order the
            // former indexed draw emitted them.
            encoder.msgSend(void, "drawPrimitives:vertexStart:vertexCount:instanceCount:", .{
                @backingInt(mtl.MTLPrimitiveType.triangle),
                @as(c_ulong, 0),
                @as(c_ulong, 6),
                @as(c_ulong, points.len - 1),
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
        .{polyline_shader_source.ptr},
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
            std.debug.print("Polyline shader compilation error: {s}\n", .{cstr});
        }
        return error.ShaderCompilationFailed;
    }

    const library = objc.Object.fromId(library_ptr);
    defer library.release();

    const vertex_name = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"polyline_vertex"});
    const fragment_name = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"polyline_fragment"});

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
    // with ONE, as the path pipeline and Vulkan's mesh pipelines do. With
    // SOURCE_ALPHA the edge fade would apply twice (rgb * a * a).
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
            std.debug.print("Polyline pipeline creation error: {s}\n", .{cstr});
        }
        return error.PipelineCreationFailed;
    }

    std.debug.print("Polyline pipeline created successfully\n", .{});
    return objc.Object.fromId(pipeline_ptr);
}
