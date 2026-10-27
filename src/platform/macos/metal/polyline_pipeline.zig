//! Polyline Pipeline - Metal rendering for efficient line strips
//!
//! Renders polylines as expanded quads for line width support.
//! Optimized for chart data visualization with thousands of connected points.
//!
//! The GPU buffer holds source points only. The vertex shader expands each line
//! segment (one instance) into a butt-ended quad, using the same IEEE operations
//! as the CPU expansion it replaced, so the buffer stores 8 B per point rather
//! than 56 B per segment (4 vertices and 6 indices).

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
    \\    float _pad0;
    \\    float _pad1;
    \\    float _pad2;
    \\};
    \\
    \\// Quad corner (0--1 over 3--2) of each vertex of triangles 0-1-2 and 0-2-3.
    \\constant uint quad_corners[6] = { 0, 1, 2, 0, 2, 3 };
    \\
    \\struct VertexOut {
    \\    float4 position [[position]];
    \\    float4 color;
    \\    float4 clip_bounds;
    \\    float2 screen_pos;
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
    \\// points[segment + 1], half_width either side.
    \\vertex VertexOut polyline_vertex(
    \\    uint vid [[vertex_id]],
    \\    uint segment [[instance_id]],
    \\    device const float2 *points [[buffer(0)]],
    \\    constant PolylineUniforms *uniforms [[buffer(1)]],
    \\    constant float2 *viewport_size [[buffer(2)]]
    \\) {
    \\    PolylineUniforms u = *uniforms;
    \\    float2 p0 = points[segment];
    \\    float2 p1 = points[segment + 1];
    \\    uint corner = quad_corners[vid];
    \\
    \\    float2 pos;
    \\    {
    \\        // The same IEEE operations, in the same order, as the CPU expansion this
    \\        // replaced: no contraction or reassociation, correctly rounded sqrt and
    \\        // divide. The clang pragmas cover compilers without the METAL ones.
    \\        #pragma METAL fp math_mode(safe)
    \\        #pragma METAL fp contract(off)
    \\        #pragma clang fp contract(off) reassociate(off)
    \\        float dx = p1.x - p0.x;
    \\        float dy = p1.y - p0.y;
    \\        float len = precise::sqrt(dx * dx + dy * dy);
    \\        float perp_x = 0.0;
    \\        float perp_y = u.half_width;
    \\        if (len > 0.0001) {
    \\            perp_x = precise::divide(-dy, len) * u.half_width;
    \\            perp_y = precise::divide(dx, len) * u.half_width;
    \\        }
    \\        // Corners 0 and 1 sit on p0, 2 and 3 on p1; 0 and 3 add the
    \\        // perpendicular, 1 and 2 subtract it. Negation is exact.
    \\        float2 end = corner < 2 ? p0 : p1;
    \\        float2 perp = float2(perp_x, perp_y);
    \\        pos = (corner == 0 || corner == 3) ? end + perp : end - perp;
    \\    }
    \\
    \\    // Convert to NDC
    \\    float2 ndc = pos / *viewport_size * float2(2.0, -2.0) + float2(-1.0, 1.0);
    \\
    \\    VertexOut out;
    \\    out.position = float4(ndc, 0.0, 1.0);
    \\    out.color = hsla_to_rgba(u.color);
    \\    out.clip_bounds = u.clip_bounds;
    \\    out.screen_pos = pos;
    \\    return out;
    \\}
    \\
    \\fragment float4 polyline_fragment(VertexOut in [[stage_in]]) {
    \\    // Clip test
    \\    float2 clip_min = in.clip_bounds.xy;
    \\    float2 clip_max = clip_min + in.clip_bounds.zw;
    \\    if (in.screen_pos.x < clip_min.x || in.screen_pos.x > clip_max.x ||
    \\        in.screen_pos.y < clip_min.y || in.screen_pos.y > clip_max.y) {
    \\        discard_fragment();
    \\    }
    \\
    \\    if (in.color.a < 0.001) discard_fragment();
    \\
    \\    // Output premultiplied alpha
    \\    return float4(in.color.rgb * in.color.a, in.color.a);
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
    _pad: [3]f32 = @splat(0),
};

comptime {
    std.debug.assert(@sizeOf(PolylineUniforms) == 48);
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
/// `ResourceLimits.scene` and never replaced. `.standard`: 1,048,576 B per frame,
/// 3,145,728 B per window. Per polyline: one claim, one copy of its points, and
/// one draw of 6 vertices × (points - 1) instances. Every polyline is claimed
/// against the same `GeometryCounts` as the Vulkan and CPU renderers before it is
/// written, so an over-budget frame panics with the pool name.
pub const PolylinePipeline = struct {
    pipeline_state: objc.Object,
    point_buffers: [frame_count]objc.Object,
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

    pub fn init(device: objc.Object, sample_count: u32, scene_limits: *const SceneLimits) !Self {
        assert(sample_count > 0);
        assert(scene_limits.check() == null);
        const pipeline_state = try createPipeline(device, sample_count);
        errdefer pipeline_state.release();

        const point_buffers = try pipelines.createFrameBuffers(
            device,
            frameBytes(scene_limits),
            "polyline_points",
        );
        errdefer for (point_buffers) |buffer| buffer.release();

        return .{
            .pipeline_state = pipeline_state,
            .point_buffers = point_buffers,
            .frame_index = 0,
            .geometry_budget = GeometryCounts.from_limits(scene_limits),
            .geometry_usage = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.point_buffers) |buffer| buffer.release();
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
        const point_buffer = self.point_buffers[self.frame_index];
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
            };
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

fn createPipeline(device: objc.Object, sample_count: u32) !objc.Object {
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
            std.debug.print("Polyline pipeline creation error: {s}\n", .{cstr});
        }
        return error.PipelineCreationFailed;
    }

    std.debug.print("Polyline pipeline created successfully\n", .{});
    return objc.Object.fromId(pipeline_ptr);
}
