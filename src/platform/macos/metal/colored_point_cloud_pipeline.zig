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
const builtin = @import("builtin");
const objc = @import("objc");

const mtl = @import("api.zig");
const scene = @import("../../../scene/mod.zig");
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
// Constants
// =============================================================================

const FRAME_COUNT = 3;
const INITIAL_VERTEX_CAPACITY: u32 = 16384; // Enough for ~4000 points
const INITIAL_INDEX_CAPACITY: u32 = 24576; // 6 indices per point

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

pub const ColoredPointCloudPipeline = struct {
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
            self.vertex_buffers[i] = try createBuffer(device, INITIAL_VERTEX_CAPACITY * @sizeOf(ColoredPointVertex));
            self.index_buffers[i] = try createBuffer(device, INITIAL_INDEX_CAPACITY * @sizeOf(u32));
            self.vertex_capacities[i] = INITIAL_VERTEX_CAPACITY;
            self.index_capacities[i] = INITIAL_INDEX_CAPACITY;
        }

        return self;
    }

    pub fn deinit(self: *Self) void {
        for (0..FRAME_COUNT) |i| {
            self.vertex_buffers[i].release();
            self.index_buffers[i].release();
        }
        self.pipeline_state.release();
    }

    /// Advance to next frame (call at start of frame)
    pub fn nextFrame(self: *Self) void {
        self.frame_index = (self.frame_index + 1) % FRAME_COUNT;
        self.frame_vertex_offset = 0;
        self.frame_index_offset = 0;
    }

    /// Render a batch of colored point clouds.
    /// All points from all clouds are rendered in a SINGLE draw call!
    pub fn renderBatch(
        self: *Self,
        encoder: objc.Object,
        colored_point_clouds: []const ColoredPointCloud,
        viewport_size: [2]f32,
    ) !void {
        if (colored_point_clouds.len == 0) return;

        // Calculate total vertices and indices needed
        var total_vertices: u32 = 0;
        var total_indices: u32 = 0;
        for (colored_point_clouds) |cpc| {
            total_vertices += cpc.vertexCount();
            total_indices += cpc.indexCount();
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

        const vb_ptr: [*]ColoredPointVertex = @ptrCast(@alignCast(vb.msgSend(*anyopaque, "contents", .{})));
        const ib_ptr: [*]u32 = @ptrCast(@alignCast(ib.msgSend(*anyopaque, "contents", .{})));

        // Track global clip bounds (use first cloud's clip, or compute union)
        // For simplicity, use the clip bounds from the first cloud
        // (In practice, colored point clouds from canvas will share clip bounds)
        var clip_bounds: [4]f32 = .{ 0, 0, 99999, 99999 };
        if (colored_point_clouds.len > 0) {
            const first = colored_point_clouds[0];
            clip_bounds = .{ first.clip_x, first.clip_y, first.clip_width, first.clip_height };
        }

        // Expand all colored point clouds to quads with per-vertex colors
        var vertex_offset = self.frame_vertex_offset;
        var index_offset = self.frame_index_offset;
        const base_vertex = vertex_offset;
        const base_index = index_offset;

        for (colored_point_clouds) |cpc| {
            const positions = cpc.getPositions();
            const colors = cpc.getColors();
            if (positions.len == 0) continue;

            const radius = cpc.radius;

            // Generate quad vertices for each point with its color
            for (positions, colors) |pos, color| {
                const pt_base = vertex_offset;
                const hsla = [4]f32{ color.h, color.s, color.l, color.a };

                // Quad corners with UV for SDF + color
                // 0--1
                // |  |
                // 3--2
                vb_ptr[vertex_offset] = .{
                    .x = pos.x - radius,
                    .y = pos.y - radius,
                    .u = -1.0,
                    .v = -1.0,
                    .color = hsla,
                };
                vertex_offset += 1;

                vb_ptr[vertex_offset] = .{
                    .x = pos.x + radius,
                    .y = pos.y - radius,
                    .u = 1.0,
                    .v = -1.0,
                    .color = hsla,
                };
                vertex_offset += 1;

                vb_ptr[vertex_offset] = .{
                    .x = pos.x + radius,
                    .y = pos.y + radius,
                    .u = 1.0,
                    .v = 1.0,
                    .color = hsla,
                };
                vertex_offset += 1;

                vb_ptr[vertex_offset] = .{
                    .x = pos.x - radius,
                    .y = pos.y + radius,
                    .u = -1.0,
                    .v = 1.0,
                    .color = hsla,
                };
                vertex_offset += 1;

                // Two triangles: 0-1-2 and 0-2-3
                ib_ptr[index_offset] = pt_base;
                index_offset += 1;
                ib_ptr[index_offset] = pt_base + 1;
                index_offset += 1;
                ib_ptr[index_offset] = pt_base + 2;
                index_offset += 1;
                ib_ptr[index_offset] = pt_base;
                index_offset += 1;
                ib_ptr[index_offset] = pt_base + 2;
                index_offset += 1;
                ib_ptr[index_offset] = pt_base + 3;
                index_offset += 1;
            }
        }

        // SINGLE DRAW CALL for ALL points!
        const uniforms = ColoredPointCloudUniforms{
            .clip_bounds = clip_bounds,
        };

        const total_index_count = index_offset - base_index;

        encoder.msgSend(void, "setRenderPipelineState:", .{self.pipeline_state.value});

        encoder.msgSend(void, "setVertexBuffer:offset:atIndex:", .{
            vb.value,
            @as(c_ulong, base_vertex * @sizeOf(ColoredPointVertex)),
            @as(c_ulong, 0),
        });

        encoder.msgSend(void, "setVertexBytes:length:atIndex:", .{
            @as(*const anyopaque, @ptrCast(&uniforms)),
            @as(c_ulong, @sizeOf(ColoredPointCloudUniforms)),
            @as(c_ulong, 1),
        });

        encoder.msgSend(void, "setVertexBytes:length:atIndex:", .{
            @as(*const anyopaque, @ptrCast(&viewport_size)),
            @as(c_ulong, @sizeOf([2]f32)),
            @as(c_ulong, 2),
        });

        encoder.msgSend(void, "drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:", .{
            @intFromEnum(mtl.MTLPrimitiveType.triangle),
            @as(c_ulong, total_index_count),
            @intFromEnum(mtl.MTLIndexType.uint32),
            ib.value,
            @as(c_ulong, base_index * @sizeOf(u32)),
        });

        self.frame_vertex_offset = vertex_offset;
        self.frame_index_offset = index_offset;
    }

    fn growVertexBuffer(self: *Self, frame: usize, min_capacity: u32) !void {
        const new_capacity = @max(min_capacity, self.vertex_capacities[frame] * 2);
        self.vertex_buffers[frame].release();
        self.vertex_buffers[frame] = try createBuffer(self.device, new_capacity * @sizeOf(ColoredPointVertex));
        self.vertex_capacities[frame] = new_capacity;
    }

    fn growIndexBuffer(self: *Self, frame: usize, min_capacity: u32) !void {
        const new_capacity = @max(min_capacity, self.index_capacities[frame] * 2);
        self.index_buffers[frame].release();
        self.index_buffers[frame] = try createBuffer(self.device, new_capacity * @sizeOf(u32));
        self.index_capacities[frame] = new_capacity;
    }
};

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

    attachment0.msgSend(void, "setPixelFormat:", .{@intFromEnum(mtl.MTLPixelFormat.bgra8unorm)});
    attachment0.msgSend(void, "setBlendingEnabled:", .{true});
    attachment0.msgSend(void, "setSourceRGBBlendFactor:", .{@intFromEnum(mtl.MTLBlendFactor.source_alpha)});
    attachment0.msgSend(void, "setDestinationRGBBlendFactor:", .{@intFromEnum(mtl.MTLBlendFactor.one_minus_source_alpha)});
    attachment0.msgSend(void, "setSourceAlphaBlendFactor:", .{@intFromEnum(mtl.MTLBlendFactor.one)});
    attachment0.msgSend(void, "setDestinationAlphaBlendFactor:", .{@intFromEnum(mtl.MTLBlendFactor.one_minus_source_alpha)});

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
