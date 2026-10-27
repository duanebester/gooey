//! Polyline Pipeline - Metal rendering for efficient line strips
//!
//! Renders polylines as expanded quads for line width support.
//! Optimized for chart data visualization with thousands of connected points.
//!
//! Each line segment (2 points) is expanded to a quad (4 vertices) on the CPU,
//! then rendered using indexed drawing. This avoids complex geometry shaders
//! while still providing good performance for typical chart use cases.

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
    \\// Per-vertex data (expanded quad vertex)
    \\struct PolylineVertex {
    \\    float x;
    \\    float y;
    \\};
    \\
    \\// Per-instance uniforms
    \\struct PolylineUniforms {
    \\    float4 color;       // HSLA color
    \\    float4 clip_bounds; // x, y, width, height
    \\};
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
    \\vertex VertexOut polyline_vertex(
    \\    uint vid [[vertex_id]],
    \\    constant PolylineVertex *vertices [[buffer(0)]],
    \\    constant PolylineUniforms *uniforms [[buffer(1)]],
    \\    constant float2 *viewport_size [[buffer(2)]]
    \\) {
    \\    PolylineVertex v = vertices[vid];
    \\    PolylineUniforms u = *uniforms;
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

/// Vertex for expanded quad (matches shader)
pub const PolylineVertex = extern struct {
    x: f32,
    y: f32,
};

/// Per-polyline uniforms (matches shader)
pub const PolylineUniforms = extern struct {
    color: [4]f32, // HSLA
    clip_bounds: [4]f32, // x, y, width, height
};

// =============================================================================
// Pipeline
// =============================================================================

/// Polylines expanded on the CPU into one quad per segment, one draw per polyline.
///
/// Resource sketch (CLAUDE.md §7): a polyline of n points has n - 1 segments, so a
/// frame's segments never exceed `polyline_point_count_frame_max`. Each frame in
/// flight owns 4 vertices × 8 B and 6 indices × 4 B per budgeted point, sized in
/// `init` from `ResourceLimits.scene` and never replaced. `.standard`: 131,072 ×
/// 56 B = 7,340,032 B per frame, 22,020,096 B per window. Every polyline is claimed
/// against the same `GeometryCounts` as the Vulkan and CPU renderers before it is
/// written, so an over-budget frame panics with the pool name.
pub const PolylinePipeline = struct {
    pipeline_state: objc.Object,
    vertex_buffers: [frame_count]objc.Object,
    index_buffers: [frame_count]objc.Object,
    frame_index: u32,
    /// Expanded vertices and indices written into the current slot this frame.
    frame_vertex_count: u32,
    frame_index_count: u32,
    /// The window's aggregate geometry budget (`ResourceLimits.scene`).
    geometry_budget: GeometryCounts,
    /// Source points claimed this frame.
    geometry_usage: GeometryCounts,

    const Self = @This();

    pub fn init(device: objc.Object, sample_count: u32, scene_limits: *const SceneLimits) !Self {
        assert(sample_count > 0);
        assert(scene_limits.check() == null);
        const budget = GeometryCounts.from_limits(scene_limits);
        const point_count_max: u64 = budget.counts[@backingInt(GeometryPool.polyline_points)];

        const pipeline_state = try createPipeline(device, sample_count);
        errdefer pipeline_state.release();

        const vertex_buffers = try pipelines.createFrameBuffers(
            device,
            point_count_max * vertices_per_segment * @sizeOf(PolylineVertex),
            "polyline_vertices",
        );
        errdefer for (vertex_buffers) |buffer| buffer.release();

        const index_buffers = try pipelines.createFrameBuffers(
            device,
            point_count_max * indices_per_segment * @sizeOf(u32),
            "polyline_indices",
        );
        errdefer for (index_buffers) |buffer| buffer.release();

        return .{
            .pipeline_state = pipeline_state,
            .vertex_buffers = vertex_buffers,
            .index_buffers = index_buffers,
            .frame_index = 0,
            .frame_vertex_count = 0,
            .frame_index_count = 0,
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
        assert(self.frame_index_count == self.frame_vertex_count / 4 * 6);
        self.frame_index = (self.frame_index + 1) % frame_count;
        self.frame_vertex_count = 0;
        self.frame_index_count = 0;
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
        const slot = self.frame_index;
        const vertex_buffer = self.vertex_buffers[slot];
        const index_buffer = self.index_buffers[slot];
        const vertices_target = pipelines.frameBufferContents(PolylineVertex, vertex_buffer);
        const indices_target = pipelines.frameBufferContents(u32, index_buffer);

        encoder.msgSend(void, "setRenderPipelineState:", .{self.pipeline_state.value});
        encoder.msgSend(void, "setVertexBytes:length:atIndex:", .{
            @as(*const anyopaque, @ptrCast(&options.viewport_size)),
            @as(c_ulong, @sizeOf([2]f32)),
            @as(c_ulong, 2),
        });

        for (polylines) |*polyline| {
            polyline.validate();
            const points = polyline.getPoints();
            // Same pool and per-draw granularity as the Vulkan and CPU renderers.
            self.geometry_usage.claim(&self.geometry_budget, .{
                .pool = .polyline_points,
                .requested = @intCast(points.len),
                .frame = options.frame,
            });
            const segment_count: u32 = @intCast(points.len - 1);
            const vertex_first = self.frame_vertex_count;
            const index_first = self.frame_index_count;
            expandSegments(
                vertices_target[vertex_first..][0 .. segment_count * vertices_per_segment],
                indices_target[index_first..][0 .. segment_count * indices_per_segment],
                points,
                polyline.width * 0.5,
            );
            self.frame_vertex_count += segment_count * vertices_per_segment;
            self.frame_index_count += segment_count * indices_per_segment;
            // Segments never outnumber claimed points, which the buffers are sized for.
            assert(self.frame_vertex_count <= self.pointsClaimed() * vertices_per_segment);

            const color = polyline.color;
            const uniforms = PolylineUniforms{
                .color = .{ color.h, color.s, color.l, color.a },
                .clip_bounds = .{
                    polyline.clip_x,
                    polyline.clip_y,
                    polyline.clip_width,
                    polyline.clip_height,
                },
            };
            // Indices are relative to the polyline's first vertex, where the buffer binds.
            encoder.msgSend(void, "setVertexBuffer:offset:atIndex:", .{
                vertex_buffer.value,
                @as(c_ulong, vertex_first) * @sizeOf(PolylineVertex),
                @as(c_ulong, 0),
            });
            encoder.msgSend(void, "setVertexBytes:length:atIndex:", .{
                @as(*const anyopaque, @ptrCast(&uniforms)),
                @as(c_ulong, @sizeOf(PolylineUniforms)),
                @as(c_ulong, 1),
            });
            encoder.msgSend(void, "drawIndexedPrimitives:indexCount:indexType:indexBuffer:" ++
                "indexBufferOffset:", .{
                @backingInt(mtl.MTLPrimitiveType.triangle),
                @as(c_ulong, segment_count * indices_per_segment),
                @backingInt(mtl.MTLIndexType.uint32),
                index_buffer.value,
                @as(c_ulong, index_first) * @sizeOf(u32),
            });
        }
    }

    fn pointsClaimed(self: *const Self) u32 {
        return self.geometry_usage.counts[@backingInt(GeometryPool.polyline_points)];
    }
};

const vertices_per_segment: u32 = 4;
const indices_per_segment: u32 = 6;

/// Hot loop: expand each segment into a butt-ended quad of half-width `radius`.
/// Indices are relative to the first vertex of `vertices`.
fn expandSegments(
    vertices: []PolylineVertex,
    indices: []u32,
    points: []const scene.Point,
    radius: f32,
) void {
    assert(points.len >= 2);
    assert(vertices.len == (points.len - 1) * vertices_per_segment);
    assert(indices.len == (points.len - 1) * indices_per_segment);
    for (points[0 .. points.len - 1], points[1..], 0..) |p0, p1, segment| {
        const dx = p1.x - p0.x;
        const dy = p1.y - p0.y;
        const len = @sqrt(dx * dx + dy * dy);
        var perp_x: f32 = 0;
        var perp_y: f32 = radius;
        if (len > 0.0001) {
            perp_x = -dy / len * radius;
            perp_y = dx / len * radius;
        }

        // Quad corners, counter-clockwise: 0--1 over 3--2.
        const base: u32 = @intCast(segment * vertices_per_segment);
        vertices[base + 0] = .{ .x = p0.x + perp_x, .y = p0.y + perp_y };
        vertices[base + 1] = .{ .x = p0.x - perp_x, .y = p0.y - perp_y };
        vertices[base + 2] = .{ .x = p1.x - perp_x, .y = p1.y - perp_y };
        vertices[base + 3] = .{ .x = p1.x + perp_x, .y = p1.y + perp_y };

        // Two triangles: 0-1-2 and 0-2-3.
        const index_base = segment * indices_per_segment;
        indices[index_base..][0..indices_per_segment].* = .{
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
