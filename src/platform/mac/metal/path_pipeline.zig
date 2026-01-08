//! Path Pipeline - Metal rendering for triangulated paths
//!
//! Renders triangulated path meshes using indexed drawing.
//! Supports solid color fills with clip bounds.

const std = @import("std");
const builtin = @import("builtin");

/// Enable verbose gradient debug logging
const DEBUG_GRADIENTS = false;
const objc = @import("objc");
const mtl = @import("api.zig");
const scene = @import("../../../scene/mod.zig");
const PathInstance = @import("../../../scene/path_instance.zig").PathInstance;
const PathVertex = @import("../../../scene/path_mesh.zig").PathVertex;
const PathMesh = @import("../../../scene/path_mesh.zig").PathMesh;
const MeshPool = @import("../../../scene/mesh_pool.zig").MeshPool;
const GradientUniforms = @import("../../../scene/gradient_uniforms.zig").GradientUniforms;

// Comptime verification of GradientUniforms layout for Metal compatibility
comptime {
    // Verify offsets match Metal struct expectations
    if (@offsetOf(GradientUniforms, "gradient_type") != 0) {
        @compileError("gradient_type offset mismatch");
    }
    if (@offsetOf(GradientUniforms, "stop_count") != 4) {
        @compileError("stop_count offset mismatch");
    }
    if (@offsetOf(GradientUniforms, "param0") != 16) {
        @compileError("param0 offset mismatch - Metal expects float4 at offset 16");
    }
    if (@offsetOf(GradientUniforms, "stop_offsets") != 32) {
        @compileError("stop_offsets offset mismatch");
    }
    if (@offsetOf(GradientUniforms, "stop_h") != 96) {
        @compileError("stop_h offset mismatch");
    }
}

pub const path_shader_source =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\
    \\// Maximum gradient stops (must match GradientUniforms)
    \\constant uint MAX_STOPS = 16;
    \\
    \\// Per-vertex data from mesh
    \\struct PathVertex {
    \\    float x;
    \\    float y;
    \\    float u;
    \\    float v;
    \\};
    \\
    \\// Per-instance data (112 bytes)
    \\struct PathInstance {
    \\    uint order;
    \\    uint _pad0;
    \\    float offset_x;
    \\    float offset_y;
    \\    float scale_x;
    \\    float scale_y;
    \\    uint mesh_ref_type;
    \\    uint mesh_ref_index;
    \\    uint vertex_offset;
    \\    uint index_offset;
    \\    uint index_count;
    \\    uint _pad1;
    \\    float4 fill_color;  // HSLA
    \\    float clip_x;
    \\    float clip_y;
    \\    float clip_width;
    \\    float clip_height;
    \\    // Gradient fields (32 bytes)
    \\    uint gradient_type;      // 0=none, 1=linear, 2=radial
    \\    uint gradient_stop_count;
    \\    uint _grad_pad0;
    \\    uint _grad_pad1;
    \\    float4 grad_params;      // linear: start_x, start_y, end_x, end_y
    \\                             // radial: center_x, center_y, radius, inner_radius
    \\};
    \\
    \\// Gradient uniforms (352 bytes)
    \\struct GradientUniforms {
    \\    uint gradient_type;
    \\    uint stop_count;
    \\    uint _pad0;
    \\    uint _pad1;
    \\    float4 params;  // linear: start/end, radial: center/radius
    \\    float stop_offsets[MAX_STOPS];
    \\    float stop_h[MAX_STOPS];
    \\    float stop_s[MAX_STOPS];
    \\    float stop_l[MAX_STOPS];
    \\    float stop_a[MAX_STOPS];
    \\};
    \\
    \\struct VertexOut {
    \\    float4 position [[position]];
    \\    float2 uv;
    \\    float4 fill_color;
    \\    float4 clip_bounds;
    \\    float2 screen_pos;
    \\    uint gradient_type;
    \\    float4 grad_params;
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
    \\// Sample gradient at position t [0, 1]
    \\float4 sample_gradient(float t, constant GradientUniforms &grad) {
    \\    t = clamp(t, 0.0, 1.0);
    \\    uint count = grad.stop_count;
    \\    if (count < 2) return float4(0, 0, 0, 1);
    \\
    \\    // Find the two stops to interpolate between
    \\    uint i0 = 0;
    \\    uint i1 = 1;
    \\    for (uint i = 0; i < count - 1; i++) {
    \\        if (t >= grad.stop_offsets[i] && t <= grad.stop_offsets[i + 1]) {
    \\            i0 = i;
    \\            i1 = i + 1;
    \\            break;
    \\        }
    \\    }
    \\
    \\    // Calculate interpolation factor
    \\    float range = grad.stop_offsets[i1] - grad.stop_offsets[i0];
    \\    float factor = (range > 0.0001) ? (t - grad.stop_offsets[i0]) / range : 0.0;
    \\
    \\    // Interpolate HSLA values
    \\    float4 hsla0 = float4(grad.stop_h[i0], grad.stop_s[i0], grad.stop_l[i0], grad.stop_a[i0]);
    \\    float4 hsla1 = float4(grad.stop_h[i1], grad.stop_s[i1], grad.stop_l[i1], grad.stop_a[i1]);
    \\
    \\    // Handle hue wrapping (shortest path around color wheel)
    \\    float h0 = hsla0.x;
    \\    float h1 = hsla1.x;
    \\    if (abs(h1 - h0) > 0.5) {
    \\        if (h0 < h1) h0 += 1.0;
    \\        else h1 += 1.0;
    \\    }
    \\
    \\    float4 hsla = float4(
    \\        fmod(mix(h0, h1, factor), 1.0),
    \\        mix(hsla0.y, hsla1.y, factor),
    \\        mix(hsla0.z, hsla1.z, factor),
    \\        mix(hsla0.w, hsla1.w, factor)
    \\    );
    \\
    \\    return hsla_to_rgba(hsla);
    \\}
    \\
    \\vertex VertexOut path_vertex(
    \\    uint vid [[vertex_id]],
    \\    constant PathVertex *vertices [[buffer(0)]],
    \\    constant PathInstance *instance [[buffer(1)]],
    \\    constant float2 *viewport_size [[buffer(2)]]
    \\) {
    \\    PathVertex v = vertices[vid];
    \\    PathInstance inst = *instance;
    \\
    \\    // Apply transform: scale then translate
    \\    float2 pos = float2(v.x * inst.scale_x + inst.offset_x,
    \\                        v.y * inst.scale_y + inst.offset_y);
    \\
    \\    // Convert to NDC
    \\    float2 ndc = pos / *viewport_size * float2(2.0, -2.0) + float2(-1.0, 1.0);
    \\
    \\    VertexOut out;
    \\    out.position = float4(ndc, 0.0, 1.0);
    \\    out.uv = float2(v.u, v.v);
    \\    out.fill_color = hsla_to_rgba(inst.fill_color);
    \\    out.clip_bounds = float4(inst.clip_x, inst.clip_y, inst.clip_width, inst.clip_height);
    \\    out.screen_pos = pos;
    \\    out.gradient_type = inst.gradient_type;
    \\    out.grad_params = inst.grad_params;
    \\    return out;
    \\}
    \\
    \\fragment float4 path_fragment(
    \\    VertexOut in [[stage_in]],
    \\    constant GradientUniforms &gradient [[buffer(0)]]
    \\) {
    \\    // Clip test
    \\    float2 clip_min = in.clip_bounds.xy;
    \\    float2 clip_max = clip_min + in.clip_bounds.zw;
    \\    if (in.screen_pos.x < clip_min.x || in.screen_pos.x > clip_max.x ||
    \\        in.screen_pos.y < clip_min.y || in.screen_pos.y > clip_max.y) {
    \\        discard_fragment();
    \\    }
    \\
    \\    float4 color;
    \\
    \\    if (in.gradient_type == 1) {
    \\        // Linear gradient
    \\        // Use UV coordinates directly (already normalized to bounds)
    \\        float2 start = in.grad_params.xy;
    \\        float2 end = in.grad_params.zw;
    \\        float2 dir = end - start;
    \\        float len_sq = dot(dir, dir);
    \\
    \\        // Project UV onto gradient line
    \\        float t;
    \\        if (len_sq < 0.0001) {
    \\            t = 0.0;
    \\        } else {
    \\            // Convert UV [0,1] to local coords for projection
    \\            float2 p = in.uv;
    \\            // Normalize start/end to [0,1] space based on typical use
    \\            // For now, assume UV-space gradient definition
    \\            t = dot(p - start, dir) / len_sq;
    \\        }
    \\
    \\        color = sample_gradient(t, gradient);
    \\    } else if (in.gradient_type == 2) {
    \\        // Radial gradient
    \\        float2 center = in.grad_params.xy;
    \\        float radius = in.grad_params.z;
    \\        float inner_radius = in.grad_params.w;
    \\
    \\        // Calculate distance from center in UV space
    \\        float dist = length(in.uv - center);
    \\
    \\        // Normalize to [0, 1] range
    \\        float t;
    \\        if (radius <= inner_radius) {
    \\            t = 1.0;
    \\        } else {
    \\            t = (dist - inner_radius) / (radius - inner_radius);
    \\        }
    \\
    \\        color = sample_gradient(t, gradient);
    \\    } else {
    \\        // Solid color fill
    \\        color = in.fill_color;
    \\    }
    \\
    \\    if (color.a < 0.001) discard_fragment();
    \\
    \\    // Output premultiplied alpha
    \\    return float4(color.rgb * color.a, color.a);
    \\}
;

const FRAME_COUNT = 3;
const INITIAL_VERTEX_CAPACITY = 4096;
const INITIAL_INDEX_CAPACITY = 8192;

// Gradient uniform size (must match GradientUniforms in gradient_uniforms.zig)
const GRADIENT_UNIFORMS_SIZE = 352;

pub const PathPipeline = struct {
    device: objc.Object,
    pipeline_state: objc.Object,

    // Triple-buffered vertex/index buffers for mesh data
    vertex_buffers: [FRAME_COUNT]objc.Object,
    index_buffers: [FRAME_COUNT]objc.Object,
    gradient_buffers: [FRAME_COUNT]objc.Object,
    vertex_capacities: [FRAME_COUNT]usize,
    index_capacities: [FRAME_COUNT]usize,
    frame_index: usize,

    // Track write offsets within current frame to avoid batch overwrites
    frame_vertex_offset: usize,
    frame_index_offset: usize,

    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, device: objc.Object, sample_count: u32) !Self {
        const pipeline_state = try createPipeline(device, sample_count);

        // Allocate vertex, index, and gradient buffers (triple-buffered)
        var vertex_buffers: [FRAME_COUNT]objc.Object = undefined;
        var index_buffers: [FRAME_COUNT]objc.Object = undefined;
        var gradient_buffers: [FRAME_COUNT]objc.Object = undefined;
        var vertex_capacities: [FRAME_COUNT]usize = undefined;
        var index_capacities: [FRAME_COUNT]usize = undefined;

        const vertex_size = INITIAL_VERTEX_CAPACITY * @sizeOf(PathVertex);
        const index_size = INITIAL_INDEX_CAPACITY * @sizeOf(u32);

        for (0..FRAME_COUNT) |i| {
            // Vertex buffer
            const vbuf_ptr = device.msgSend(?*anyopaque, "newBufferWithLength:options:", .{
                @as(c_ulong, vertex_size),
                @as(c_ulong, @bitCast(mtl.MTLResourceOptions.storage_shared)),
            }) orelse return error.BufferCreationFailed;
            vertex_buffers[i] = objc.Object.fromId(vbuf_ptr);
            vertex_capacities[i] = INITIAL_VERTEX_CAPACITY;

            // Index buffer
            const ibuf_ptr = device.msgSend(?*anyopaque, "newBufferWithLength:options:", .{
                @as(c_ulong, index_size),
                @as(c_ulong, @bitCast(mtl.MTLResourceOptions.storage_shared)),
            }) orelse return error.BufferCreationFailed;
            index_buffers[i] = objc.Object.fromId(ibuf_ptr);
            index_capacities[i] = INITIAL_INDEX_CAPACITY;

            // Gradient uniform buffer
            const gbuf_ptr = device.msgSend(?*anyopaque, "newBufferWithLength:options:", .{
                @as(c_ulong, GRADIENT_UNIFORMS_SIZE),
                @as(c_ulong, @bitCast(mtl.MTLResourceOptions.storage_shared)),
            }) orelse return error.BufferCreationFailed;
            gradient_buffers[i] = objc.Object.fromId(gbuf_ptr);
        }

        return .{
            .device = device,
            .pipeline_state = pipeline_state,
            .vertex_buffers = vertex_buffers,
            .index_buffers = index_buffers,
            .gradient_buffers = gradient_buffers,
            .vertex_capacities = .{ INITIAL_VERTEX_CAPACITY, INITIAL_VERTEX_CAPACITY, INITIAL_VERTEX_CAPACITY },
            .index_capacities = .{ INITIAL_INDEX_CAPACITY, INITIAL_INDEX_CAPACITY, INITIAL_INDEX_CAPACITY },
            .frame_index = 0,
            .frame_vertex_offset = 0,
            .frame_index_offset = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.pipeline_state.msgSend(void, "release", .{});
        for (&self.vertex_buffers) |buf| buf.msgSend(void, "release", .{});
        for (&self.index_buffers) |buf| buf.msgSend(void, "release", .{});
        for (&self.gradient_buffers) |buf| buf.msgSend(void, "release", .{});
    }

    /// Advance to next frame (call at frame start)
    pub fn nextFrame(self: *Self) void {
        self.frame_index = (self.frame_index + 1) % FRAME_COUNT;
        // Reset write offsets for new frame
        self.frame_vertex_offset = 0;
        self.frame_index_offset = 0;
    }

    /// Render a single path instance
    pub fn renderPath(
        self: *Self,
        encoder: objc.Object,
        instance: *const PathInstance,
        mesh: *const PathMesh,
        viewport_size: [2]f32,
    ) !void {
        if (mesh.isEmpty()) return;

        const idx = self.frame_index;
        const vertex_count = mesh.vertices.len;
        const index_count = mesh.indices.len;

        // Grow buffers if needed
        if (vertex_count > self.vertex_capacities[idx]) {
            try self.growVertexBuffer(idx, vertex_count);
        }
        if (index_count > self.index_capacities[idx]) {
            try self.growIndexBuffer(idx, index_count);
        }

        // Upload vertex data
        const vbuf_ptr = self.vertex_buffers[idx].msgSend(*anyopaque, "contents", .{});
        const vertices_dest: [*]PathVertex = @ptrCast(@alignCast(vbuf_ptr));
        @memcpy(vertices_dest[0..vertex_count], mesh.vertices.constSlice());

        // Upload index data
        const ibuf_ptr = self.index_buffers[idx].msgSend(*anyopaque, "contents", .{});
        const indices_dest: [*]u32 = @ptrCast(@alignCast(ibuf_ptr));
        @memcpy(indices_dest[0..index_count], mesh.indices.constSlice());

        // Bind pipeline
        encoder.msgSend(void, "setRenderPipelineState:", .{self.pipeline_state.value});

        // Set vertex buffer
        encoder.msgSend(void, "setVertexBuffer:offset:atIndex:", .{
            self.vertex_buffers[idx].value,
            @as(c_ulong, 0),
            @as(c_ulong, 0),
        });

        // Set instance data
        encoder.msgSend(void, "setVertexBytes:length:atIndex:", .{
            @as(*const anyopaque, @ptrCast(instance)),
            @as(c_ulong, @sizeOf(PathInstance)),
            @as(c_ulong, 1),
        });

        // Set viewport size
        encoder.msgSend(void, "setVertexBytes:length:atIndex:", .{
            @as(*const anyopaque, @ptrCast(&viewport_size)),
            @as(c_ulong, @sizeOf([2]f32)),
            @as(c_ulong, 2),
        });

        // Set gradient uniform buffer for fragment shader
        // For now, use empty gradient (solid color). Gradient data will be populated by caller.
        encoder.msgSend(void, "setFragmentBuffer:offset:atIndex:", .{
            self.gradient_buffers[idx].value,
            @as(c_ulong, 0),
            @as(c_ulong, 0),
        });

        // Draw indexed triangles
        encoder.msgSend(void, "drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:", .{
            @intFromEnum(mtl.MTLPrimitiveType.triangle),
            @as(c_ulong, index_count),
            @intFromEnum(mtl.MTLIndexType.uint32),
            self.index_buffers[idx].value,
            @as(c_ulong, 0),
        });
    }

    /// Render a batch of path instances
    /// Uploads all meshes to shared buffers first, then draws with proper offsets
    pub fn renderBatch(
        self: *Self,
        encoder: objc.Object,
        instances: []const PathInstance,
        mesh_pool: *const MeshPool,
        viewport_size: [2]f32,
    ) !void {
        if (instances.len == 0) return;

        const idx = self.frame_index;

        // First pass: calculate total buffer sizes needed
        var total_vertices: usize = 0;
        var total_indices: usize = 0;
        for (instances) |*instance| {
            const mesh = mesh_pool.getMesh(instance.getMeshRef());
            total_vertices += mesh.vertices.len;
            total_indices += mesh.indices.len;
        }

        if (total_vertices == 0 or total_indices == 0) return;

        // Grow buffers if needed
        if (total_vertices > self.vertex_capacities[idx]) {
            try self.growVertexBuffer(idx, total_vertices);
        }
        if (total_indices > self.index_capacities[idx]) {
            try self.growIndexBuffer(idx, total_indices);
        }

        // Get buffer pointers
        const vbuf_ptr = self.vertex_buffers[idx].msgSend(*anyopaque, "contents", .{});
        const vertices_dest: [*]PathVertex = @ptrCast(@alignCast(vbuf_ptr));
        const ibuf_ptr = self.index_buffers[idx].msgSend(*anyopaque, "contents", .{});
        const indices_dest: [*]u32 = @ptrCast(@alignCast(ibuf_ptr));

        // Second pass: upload all mesh data with offsets
        var vertex_offset: u32 = 0;
        var index_offset: u32 = 0;

        // Store offsets for each instance
        var instance_offsets: [256]struct { vertex_offset: u32, index_offset: u32, index_count: u32 } = undefined;
        std.debug.assert(instances.len <= 256);

        for (instances, 0..) |*instance, i| {
            const mesh = mesh_pool.getMesh(instance.getMeshRef());
            const vert_count: u32 = @intCast(mesh.vertices.len);
            const idx_count: u32 = @intCast(mesh.indices.len);

            if (vert_count == 0 or idx_count == 0) {
                instance_offsets[i] = .{ .vertex_offset = 0, .index_offset = 0, .index_count = 0 };
                continue;
            }

            // Copy vertices
            @memcpy(vertices_dest[vertex_offset..][0..vert_count], mesh.vertices.constSlice());

            // Copy indices, adjusting for vertex offset
            for (mesh.indices.constSlice(), 0..) |src_idx, j| {
                indices_dest[index_offset + j] = src_idx + vertex_offset;
            }

            instance_offsets[i] = .{
                .vertex_offset = vertex_offset,
                .index_offset = index_offset,
                .index_count = idx_count,
            };

            vertex_offset += vert_count;
            index_offset += idx_count;
        }

        // Bind pipeline once for the batch
        encoder.msgSend(void, "setRenderPipelineState:", .{self.pipeline_state.value});

        // Set vertex buffer once
        encoder.msgSend(void, "setVertexBuffer:offset:atIndex:", .{
            self.vertex_buffers[idx].value,
            @as(c_ulong, 0),
            @as(c_ulong, 0),
        });

        // Set viewport size once
        encoder.msgSend(void, "setVertexBytes:length:atIndex:", .{
            @as(*const anyopaque, @ptrCast(&viewport_size)),
            @as(c_ulong, @sizeOf([2]f32)),
            @as(c_ulong, 2),
        });

        // Set gradient uniform buffer for fragment shader
        encoder.msgSend(void, "setFragmentBuffer:offset:atIndex:", .{
            self.gradient_buffers[idx].value,
            @as(c_ulong, 0),
            @as(c_ulong, 0),
        });

        // Third pass: draw each instance with its proper index offset
        for (instances, 0..) |*instance, i| {
            const offsets = instance_offsets[i];
            if (offsets.index_count == 0) continue;

            // Set instance data for this path
            encoder.msgSend(void, "setVertexBytes:length:atIndex:", .{
                @as(*const anyopaque, @ptrCast(instance)),
                @as(c_ulong, @sizeOf(PathInstance)),
                @as(c_ulong, 1),
            });

            // Draw this path's triangles
            encoder.msgSend(void, "drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:", .{
                @intFromEnum(mtl.MTLPrimitiveType.triangle),
                @as(c_ulong, offsets.index_count),
                @intFromEnum(mtl.MTLIndexType.uint32),
                self.index_buffers[idx].value,
                @as(c_ulong, offsets.index_offset * @sizeOf(u32)),
            });
        }
    }

    /// Render a batch of path instances with gradient data
    /// Like renderBatch but uploads per-instance gradient uniforms
    pub fn renderBatchWithGradients(
        self: *Self,
        encoder: objc.Object,
        instances: []const PathInstance,
        gradients: []const GradientUniforms,
        mesh_pool: *const MeshPool,
        viewport_size: [2]f32,
    ) !void {
        if (instances.len == 0) return;

        const idx = self.frame_index;

        // First pass: calculate total buffer sizes needed
        var total_vertices: usize = 0;
        var total_indices: usize = 0;
        for (instances) |*instance| {
            const mesh = mesh_pool.getMesh(instance.getMeshRef());
            total_vertices += mesh.vertices.len;
            total_indices += mesh.indices.len;
        }

        if (total_vertices == 0 or total_indices == 0) return;

        // Calculate required capacity including existing data from previous batches
        const required_vertices = self.frame_vertex_offset + total_vertices;
        const required_indices = self.frame_index_offset + total_indices;

        // Grow buffers if needed
        if (required_vertices > self.vertex_capacities[idx]) {
            try self.growVertexBuffer(idx, required_vertices);
        }
        if (required_indices > self.index_capacities[idx]) {
            try self.growIndexBuffer(idx, required_indices);
        }

        // Get buffer pointers
        const vbuf_ptr = self.vertex_buffers[idx].msgSend(*anyopaque, "contents", .{});
        const vertices_dest: [*]PathVertex = @ptrCast(@alignCast(vbuf_ptr));
        const ibuf_ptr = self.index_buffers[idx].msgSend(*anyopaque, "contents", .{});
        const indices_dest: [*]u32 = @ptrCast(@alignCast(ibuf_ptr));

        // Second pass: upload all mesh data with offsets
        // Start from current frame offset to avoid overwriting previous batches
        var vertex_offset: u32 = @intCast(self.frame_vertex_offset);
        var index_offset: u32 = @intCast(self.frame_index_offset);

        // Store offsets for each instance
        var instance_offsets: [256]struct { vertex_offset: u32, index_offset: u32, index_count: u32 } = undefined;
        std.debug.assert(instances.len <= 256);

        for (instances, 0..) |*instance, i| {
            const mesh_ref = instance.getMeshRef();
            const mesh = mesh_pool.getMesh(mesh_ref);
            const vert_count: u32 = @intCast(mesh.vertices.len);
            const idx_count: u32 = @intCast(mesh.indices.len);

            if (vert_count == 0 or idx_count == 0) {
                instance_offsets[i] = .{ .vertex_offset = 0, .index_offset = 0, .index_count = 0 };
                continue;
            }

            // Copy vertices
            @memcpy(vertices_dest[vertex_offset..][0..vert_count], mesh.vertices.constSlice());

            // Copy indices, adjusting for vertex offset
            for (mesh.indices.constSlice(), 0..) |src_idx, j| {
                indices_dest[index_offset + j] = src_idx + vertex_offset;
            }

            instance_offsets[i] = .{
                .vertex_offset = vertex_offset,
                .index_offset = index_offset,
                .index_count = idx_count,
            };

            vertex_offset += vert_count;
            index_offset += idx_count;
        }

        // Bind pipeline once for the batch
        encoder.msgSend(void, "setRenderPipelineState:", .{self.pipeline_state.value});

        // Set vertex buffer once
        encoder.msgSend(void, "setVertexBuffer:offset:atIndex:", .{
            self.vertex_buffers[idx].value,
            @as(c_ulong, 0),
            @as(c_ulong, 0),
        });

        // Set viewport size once
        encoder.msgSend(void, "setVertexBytes:length:atIndex:", .{
            @as(*const anyopaque, @ptrCast(&viewport_size)),
            @as(c_ulong, @sizeOf([2]f32)),
            @as(c_ulong, 2),
        });

        // Third pass: draw each instance with gradient data
        for (instances, 0..) |*instance, i| {
            const offsets = instance_offsets[i];
            if (offsets.index_count == 0) continue;

            // Set instance data for this path
            encoder.msgSend(void, "setVertexBytes:length:atIndex:", .{
                @as(*const anyopaque, @ptrCast(instance)),
                @as(c_ulong, @sizeOf(PathInstance)),
                @as(c_ulong, 1),
            });

            // Upload gradient data from parallel array
            const gradient = if (i < gradients.len) gradients[i] else GradientUniforms.none();

            // Debug: print ALL path data being uploaded
            if (DEBUG_GRADIENTS and builtin.mode == .Debug) {
                // Print PathInstance params (UV-space, sent to vertex shader)
                std.debug.print("Path[{d}] instance: type={d}, stops={d}, color=({d:.2},{d:.2},{d:.2},{d:.2}), params=({d:.3},{d:.3},{d:.3},{d:.3})\n", .{
                    i,
                    instance.gradient_type,
                    instance.gradient_stop_count,
                    instance.fill_color.h,
                    instance.fill_color.s,
                    instance.fill_color.l,
                    instance.fill_color.a,
                    instance.grad_param0,
                    instance.grad_param1,
                    instance.grad_param2,
                    instance.grad_param3,
                });
                // Print GradientUniforms params (path-space, for reference)
                std.debug.print("         uniform: type={d}, stops={d}, params=({d:.3},{d:.3},{d:.3},{d:.3})\n", .{
                    gradient.gradient_type,
                    gradient.stop_count,
                    gradient.param0,
                    gradient.param1,
                    gradient.param2,
                    gradient.param3,
                });
                if (gradient.gradient_type != 0) {
                    std.debug.print("  stop_offsets: [{d:.2}, {d:.2}, {d:.2}]\n", .{
                        gradient.stop_offsets[0],
                        gradient.stop_offsets[1],
                        gradient.stop_offsets[2],
                    });
                    std.debug.print("  stop_h: [{d:.2}, {d:.2}, {d:.2}]\n", .{
                        gradient.stop_h[0],
                        gradient.stop_h[1],
                        gradient.stop_h[2],
                    });
                }
            }

            // Set gradient data for fragment shader using setFragmentBytes
            // (more efficient than buffer for small uniform data < 4KB)
            encoder.msgSend(void, "setFragmentBytes:length:atIndex:", .{
                @as(*const anyopaque, @ptrCast(&gradient)),
                @as(c_ulong, @sizeOf(GradientUniforms)),
                @as(c_ulong, 0),
            });

            // Draw this path's triangles
            encoder.msgSend(void, "drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:", .{
                @intFromEnum(mtl.MTLPrimitiveType.triangle),
                @as(c_ulong, offsets.index_count),
                @intFromEnum(mtl.MTLIndexType.uint32),
                self.index_buffers[idx].value,
                @as(c_ulong, offsets.index_offset * @sizeOf(u32)),
            });
        }

        // Update frame offsets for next batch
        self.frame_vertex_offset += total_vertices;
        self.frame_index_offset += total_indices;
    }

    fn growVertexBuffer(self: *Self, idx: usize, min_capacity: usize) !void {
        const new_capacity = @max(min_capacity, self.vertex_capacities[idx] * 2);
        const new_size = new_capacity * @sizeOf(PathVertex);

        const new_ptr = self.device.msgSend(?*anyopaque, "newBufferWithLength:options:", .{
            @as(c_ulong, new_size),
            @as(c_ulong, @bitCast(mtl.MTLResourceOptions.storage_shared)),
        }) orelse return error.BufferCreationFailed;

        self.vertex_buffers[idx].msgSend(void, "release", .{});
        self.vertex_buffers[idx] = objc.Object.fromId(new_ptr);
        self.vertex_capacities[idx] = new_capacity;
    }

    fn growIndexBuffer(self: *Self, idx: usize, min_capacity: usize) !void {
        const new_capacity = @max(min_capacity, self.index_capacities[idx] * 2);
        const new_size = new_capacity * @sizeOf(u32);

        const new_ptr = self.device.msgSend(?*anyopaque, "newBufferWithLength:options:", .{
            @as(c_ulong, new_size),
            @as(c_ulong, @bitCast(mtl.MTLResourceOptions.storage_shared)),
        }) orelse return error.BufferCreationFailed;

        self.index_buffers[idx].msgSend(void, "release", .{});
        self.index_buffers[idx] = objc.Object.fromId(new_ptr);
        self.index_capacities[idx] = new_capacity;
    }
};

fn createPipeline(device: objc.Object, sample_count: u32) !objc.Object {
    const NSString = objc.getClass("NSString") orelse return error.ClassNotFound;
    const source_str = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{path_shader_source.ptr});

    var compile_error: ?*anyopaque = null;
    const library_ptr = device.msgSend(?*anyopaque, "newLibraryWithSource:options:error:", .{
        source_str.value, @as(?*anyopaque, null), &compile_error,
    });
    if (library_ptr == null) return error.ShaderCompilationFailed;

    const library = objc.Object.fromId(library_ptr);
    defer library.msgSend(void, "release", .{});

    const vert_name = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"path_vertex"});
    const frag_name = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"path_fragment"});

    const vert_fn = objc.Object.fromId(library.msgSend(?*anyopaque, "newFunctionWithName:", .{vert_name.value}) orelse return error.ShaderFunctionNotFound);
    const frag_fn = objc.Object.fromId(library.msgSend(?*anyopaque, "newFunctionWithName:", .{frag_name.value}) orelse return error.ShaderFunctionNotFound);
    defer vert_fn.msgSend(void, "release", .{});
    defer frag_fn.msgSend(void, "release", .{});

    const MTLRenderPipelineDescriptor = objc.getClass("MTLRenderPipelineDescriptor") orelse return error.ClassNotFound;
    const desc = MTLRenderPipelineDescriptor.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});
    defer desc.msgSend(void, "release", .{});

    desc.msgSend(void, "setVertexFunction:", .{vert_fn.value});
    desc.msgSend(void, "setFragmentFunction:", .{frag_fn.value});
    desc.msgSend(void, "setSampleCount:", .{@as(c_ulong, sample_count)});

    const attachments = desc.msgSend(objc.Object, "colorAttachments", .{});
    const attach0 = attachments.msgSend(objc.Object, "objectAtIndexedSubscript:", .{@as(c_ulong, 0)});
    attach0.msgSend(void, "setPixelFormat:", .{@intFromEnum(mtl.MTLPixelFormat.bgra8unorm)});
    attach0.msgSend(void, "setBlendingEnabled:", .{true});
    // Path shader outputs premultiplied alpha (rgb already multiplied by alpha), so use ONE
    attach0.msgSend(void, "setSourceRGBBlendFactor:", .{@intFromEnum(mtl.MTLBlendFactor.one)});
    attach0.msgSend(void, "setDestinationRGBBlendFactor:", .{@intFromEnum(mtl.MTLBlendFactor.one_minus_source_alpha)});
    attach0.msgSend(void, "setSourceAlphaBlendFactor:", .{@intFromEnum(mtl.MTLBlendFactor.one)});
    attach0.msgSend(void, "setDestinationAlphaBlendFactor:", .{@intFromEnum(mtl.MTLBlendFactor.one_minus_source_alpha)});

    const pipeline_ptr = device.msgSend(?*anyopaque, "newRenderPipelineStateWithDescriptor:error:", .{
        desc.value, @as(?*anyopaque, null),
    }) orelse return error.PipelineCreationFailed;

    return objc.Object.fromId(pipeline_ptr);
}
