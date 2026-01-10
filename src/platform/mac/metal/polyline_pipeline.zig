//! Polyline Pipeline - Metal rendering for efficient line strips
//!
//! Renders polylines as expanded quads for line width support.
//! Optimized for chart data visualization with thousands of connected points.
//!
//! Each line segment (2 points) is expanded to a quad (4 vertices) on the CPU,
//! then rendered using indexed drawing. This avoids complex geometry shaders
//! while still providing good performance for typical chart use cases.

const std = @import("std");
const builtin = @import("builtin");

const objc = @import("objc");
const mtl = @import("api.zig");
const scene = @import("../../../scene/mod.zig");
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
// Constants
// =============================================================================

const FRAME_COUNT = 3;
const INITIAL_VERTEX_CAPACITY: u32 = 16384; // Enough for ~4000 line segments
const INITIAL_INDEX_CAPACITY: u32 = 24576; // 6 indices per segment

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

pub const PolylinePipeline = struct {
    device: objc.Object,
    pipeline_state: objc.Object,

    // Triple-buffered vertex/index data
    vertex_buffers: [FRAME_COUNT]objc.Object,
    index_buffers: [FRAME_COUNT]objc.Object,
    vertex_capacities: [FRAME_COUNT]u32,
    index_capacities: [FRAME_COUNT]u32,
    frame_index: u32,

    // Per-frame tracking for batched uploads
    frame_vertex_offset: u32,
    frame_index_offset: u32,

    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, device: objc.Object, sample_count: u32) !Self {
        const pipeline = try createPipeline(device, sample_count);

        var self = Self{
            .device = device,
            .pipeline_state = pipeline,
            .vertex_buffers = undefined,
            .index_buffers = undefined,
            .vertex_capacities = undefined,
            .index_capacities = undefined,
            .frame_index = 0,
            .frame_vertex_offset = 0,
            .frame_index_offset = 0,
            .allocator = allocator,
        };

        // Create triple-buffered vertex/index buffers
        for (0..FRAME_COUNT) |i| {
            self.vertex_buffers[i] = try createBuffer(device, INITIAL_VERTEX_CAPACITY * @sizeOf(PolylineVertex));
            self.index_buffers[i] = try createBuffer(device, INITIAL_INDEX_CAPACITY * @sizeOf(u32));
            self.vertex_capacities[i] = INITIAL_VERTEX_CAPACITY;
            self.index_capacities[i] = INITIAL_INDEX_CAPACITY;
        }

        return self;
    }

    pub fn deinit(self: *Self) void {
        for (0..FRAME_COUNT) |i| {
            self.vertex_buffers[i].msgSend(void, "release", .{});
            self.index_buffers[i].msgSend(void, "release", .{});
        }
        self.pipeline_state.msgSend(void, "release", .{});
    }

    /// Advance to next frame (call at start of frame)
    pub fn nextFrame(self: *Self) void {
        self.frame_index = (self.frame_index + 1) % FRAME_COUNT;
        self.frame_vertex_offset = 0;
        self.frame_index_offset = 0;
    }

    /// Render a batch of polylines
    pub fn renderBatch(
        self: *Self,
        encoder: objc.Object,
        polylines: []const Polyline,
        viewport_size: [2]f32,
    ) !void {
        if (polylines.len == 0) return;

        // Calculate total vertices and indices needed
        var total_vertices: u32 = 0;
        var total_indices: u32 = 0;
        for (polylines) |pl| {
            total_vertices += pl.vertexCount();
            total_indices += pl.indexCount();
        }

        if (total_vertices == 0 or total_indices == 0) return;

        const fi = self.frame_index;

        // Grow buffers if needed
        if (self.frame_vertex_offset + total_vertices > self.vertex_capacities[fi]) {
            try self.growVertexBuffer(fi, self.frame_vertex_offset + total_vertices);
        }
        if (self.frame_index_offset + total_indices > self.index_capacities[fi]) {
            try self.growIndexBuffer(fi, self.frame_index_offset + total_indices);
        }

        // Get buffer pointers
        const vb = self.vertex_buffers[fi];
        const ib = self.index_buffers[fi];

        const vb_ptr: [*]PolylineVertex = @ptrCast(@alignCast(vb.msgSend(*anyopaque, "contents", .{})));
        const ib_ptr: [*]u32 = @ptrCast(@alignCast(ib.msgSend(*anyopaque, "contents", .{})));

        // Expand all polylines to quads
        var vertex_offset = self.frame_vertex_offset;
        var index_offset = self.frame_index_offset;

        for (polylines) |pl| {
            const points = pl.getPoints();
            if (points.len < 2) continue;

            const half_width = pl.width * 0.5;
            const base_vertex = vertex_offset;

            // Generate quad vertices for each segment
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

                // Quad corners (CCW winding)
                // 0--1
                // |  |
                // 3--2
                const seg_base = vertex_offset;

                vb_ptr[vertex_offset] = .{ .x = p0.x + perp_x, .y = p0.y + perp_y };
                vertex_offset += 1;
                vb_ptr[vertex_offset] = .{ .x = p0.x - perp_x, .y = p0.y - perp_y };
                vertex_offset += 1;
                vb_ptr[vertex_offset] = .{ .x = p1.x - perp_x, .y = p1.y - perp_y };
                vertex_offset += 1;
                vb_ptr[vertex_offset] = .{ .x = p1.x + perp_x, .y = p1.y + perp_y };
                vertex_offset += 1;

                // Two triangles: 0-1-2 and 0-2-3
                ib_ptr[index_offset] = seg_base;
                index_offset += 1;
                ib_ptr[index_offset] = seg_base + 1;
                index_offset += 1;
                ib_ptr[index_offset] = seg_base + 2;
                index_offset += 1;
                ib_ptr[index_offset] = seg_base;
                index_offset += 1;
                ib_ptr[index_offset] = seg_base + 2;
                index_offset += 1;
                ib_ptr[index_offset] = seg_base + 3;
                index_offset += 1;
            }

            // Draw this polyline
            const uniforms = PolylineUniforms{
                .color = .{ pl.color.h, pl.color.s, pl.color.l, pl.color.a },
                .clip_bounds = .{ pl.clip_x, pl.clip_y, pl.clip_width, pl.clip_height },
            };

            const index_count = pl.indexCount();

            encoder.msgSend(void, "setRenderPipelineState:", .{self.pipeline_state.value});

            encoder.msgSend(void, "setVertexBuffer:offset:atIndex:", .{
                vb.value,
                @as(c_ulong, base_vertex * @sizeOf(PolylineVertex)),
                @as(c_ulong, 0),
            });

            encoder.msgSend(void, "setVertexBytes:length:atIndex:", .{
                @as(*const anyopaque, @ptrCast(&uniforms)),
                @as(c_ulong, @sizeOf(PolylineUniforms)),
                @as(c_ulong, 1),
            });

            encoder.msgSend(void, "setVertexBytes:length:atIndex:", .{
                @as(*const anyopaque, @ptrCast(&viewport_size)),
                @as(c_ulong, @sizeOf([2]f32)),
                @as(c_ulong, 2),
            });

            encoder.msgSend(void, "drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:", .{
                @intFromEnum(mtl.MTLPrimitiveType.triangle),
                @as(c_ulong, index_count),
                @intFromEnum(mtl.MTLIndexType.uint32),
                ib.value,
                @as(c_ulong, self.frame_index_offset * @sizeOf(u32)),
            });

            self.frame_index_offset = index_offset;
        }

        self.frame_vertex_offset = vertex_offset;
    }

    fn growVertexBuffer(self: *Self, frame: usize, min_capacity: u32) !void {
        const new_capacity = @max(min_capacity, self.vertex_capacities[frame] * 2);
        self.vertex_buffers[frame].msgSend(void, "release", .{});
        self.vertex_buffers[frame] = try createBuffer(self.device, new_capacity * @sizeOf(PolylineVertex));
        self.vertex_capacities[frame] = new_capacity;
    }

    fn growIndexBuffer(self: *Self, frame: usize, min_capacity: u32) !void {
        const new_capacity = @max(min_capacity, self.index_capacities[frame] * 2);
        self.index_buffers[frame].msgSend(void, "release", .{});
        self.index_buffers[frame] = try createBuffer(self.device, new_capacity * @sizeOf(u32));
        self.index_capacities[frame] = new_capacity;
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
    defer library.msgSend(void, "release", .{});

    const vertex_name = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"polyline_vertex"});
    const fragment_name = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"polyline_fragment"});

    const vertex_fn_ptr = library.msgSend(?*anyopaque, "newFunctionWithName:", .{vertex_name.value});
    const fragment_fn_ptr = library.msgSend(?*anyopaque, "newFunctionWithName:", .{fragment_name.value});

    if (vertex_fn_ptr == null or fragment_fn_ptr == null) {
        return error.ShaderFunctionNotFound;
    }

    const vertex_fn = objc.Object.fromId(vertex_fn_ptr);
    const fragment_fn = objc.Object.fromId(fragment_fn_ptr);
    defer vertex_fn.msgSend(void, "release", .{});
    defer fragment_fn.msgSend(void, "release", .{});

    const MTLRenderPipelineDescriptor = objc.getClass("MTLRenderPipelineDescriptor") orelse
        return error.ClassNotFound;
    const desc = MTLRenderPipelineDescriptor.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "init", .{});
    defer desc.msgSend(void, "release", .{});

    desc.msgSend(void, "setVertexFunction:", .{vertex_fn.value});
    desc.msgSend(void, "setFragmentFunction:", .{fragment_fn.value});
    desc.msgSend(void, "setSampleCount:", .{@as(c_ulong, sample_count)});

    const color_attachments = desc.msgSend(objc.Object, "colorAttachments", .{});
    const attachment0 = color_attachments.msgSend(objc.Object, "objectAtIndexedSubscript:", .{@as(c_ulong, 0)});

    // Configure blending
    attachment0.msgSend(void, "setPixelFormat:", .{@intFromEnum(mtl.MTLPixelFormat.bgra8unorm)});
    attachment0.msgSend(void, "setBlendingEnabled:", .{true});
    attachment0.msgSend(void, "setSourceRGBBlendFactor:", .{@intFromEnum(mtl.MTLBlendFactor.source_alpha)});
    attachment0.msgSend(void, "setDestinationRGBBlendFactor:", .{@intFromEnum(mtl.MTLBlendFactor.one_minus_source_alpha)});
    attachment0.msgSend(void, "setSourceAlphaBlendFactor:", .{@intFromEnum(mtl.MTLBlendFactor.one)});
    attachment0.msgSend(void, "setDestinationAlphaBlendFactor:", .{@intFromEnum(mtl.MTLBlendFactor.one_minus_source_alpha)});

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

fn createBuffer(device: objc.Object, size: u32) !objc.Object {
    const unified_memory = device.msgSend(bool, "hasUnifiedMemory", .{});
    const storage: mtl.MTLResourceOptions = if (unified_memory)
        .{ .storage_mode = .shared }
    else
        .{ .storage_mode = .managed };

    const buffer_ptr = device.msgSend(
        ?*anyopaque,
        "newBufferWithLength:options:",
        .{
            @as(c_ulong, size),
            @as(c_ulong, @bitCast(storage)),
        },
    );

    if (buffer_ptr == null) {
        return error.BufferCreationFailed;
    }

    return objc.Object.fromId(buffer_ptr);
}
