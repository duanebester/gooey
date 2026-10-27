//! Path Pipeline - Metal rendering for triangulated paths
//!
//! Renders triangulated path meshes using indexed drawing.
//! Supports solid, linear-gradient and radial-gradient fills with clip bounds.

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
const PathInstance = @import("../../../scene/path_instance.zig").PathInstance;
const path_mesh_mod = @import("../../../scene/path_mesh.zig");
const PathVertex = path_mesh_mod.PathVertex;
const PathMesh = path_mesh_mod.PathMesh;
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

/// Indexed path meshes, one draw per path instance, in scene order.
///
/// Resource sketch (CLAUDE.md §7): each frame in flight owns a vertex buffer of
/// `path_vertex_count_frame_max` × 16 B and an index buffer of
/// `path_index_count_frame_max` × 4 B, sized in `init` from `ResourceLimits.scene`
/// and never replaced. `.standard`: 262,144 + 65,536 = 327,680 B per frame,
/// 983,040 B per window for three frames. Per draw: one mesh copy, one index rebase, a 112 B
/// `setVertexBytes`, a 352 B `setFragmentBytes` and one indexed draw. Every mesh
/// is claimed against the same `GeometryCounts` as the Vulkan and CPU renderers
/// before it is written, so an over-budget frame panics with the pool name.
pub const PathPipeline = struct {
    pipeline_state: objc.Object,
    vertex_buffers: pipelines.FrameBuffers,
    index_buffers: pipelines.FrameBuffers,
    frame_index: u32,
    /// The window's aggregate geometry budget (`ResourceLimits.scene`).
    geometry_budget: GeometryCounts,
    /// Geometry claimed this frame. The path counts are also the slot's write
    /// offsets, because every claimed vertex and index is written exactly once.
    geometry_usage: GeometryCounts,

    const Self = @This();

    /// Bytes of one frame's vertex buffer for `scene_limits`.
    fn vertexFrameBytes(scene_limits: *const SceneLimits) u64 {
        return @as(u64, scene_limits.path_vertex_count_frame_max) * @sizeOf(PathVertex);
    }

    /// Bytes of one frame's index buffer for `scene_limits`.
    fn indexFrameBytes(scene_limits: *const SceneLimits) u64 {
        return @as(u64, scene_limits.path_index_count_frame_max) * @sizeOf(u32);
    }

    /// Bytes of one frame's vertex and index buffers for `scene_limits`.
    pub fn frameBytes(scene_limits: *const SceneLimits) u64 {
        return vertexFrameBytes(scene_limits) + indexFrameBytes(scene_limits);
    }

    pub fn init(device: objc.Object, sample_count: u32, limits: *const ResourceLimits) !Self {
        const scene_limits = &limits.scene;
        assert(sample_count > 0);
        assert(scene_limits.check() == null);
        const pipeline_state = try createPipeline(device, sample_count);
        errdefer pipeline_state.release();

        const vertex_buffers = try pipelines.createFrameBuffers(
            device,
            vertexFrameBytes(scene_limits),
            "path_vertices",
            limits.frame.in_flight_count,
        );
        errdefer vertex_buffers.release();

        const index_buffers = try pipelines.createFrameBuffers(
            device,
            indexFrameBytes(scene_limits),
            "path_indices",
            limits.frame.in_flight_count,
        );
        errdefer index_buffers.release();

        return .{
            .pipeline_state = pipeline_state,
            .vertex_buffers = vertex_buffers,
            .index_buffers = index_buffers,
            .frame_index = 0,
            .geometry_budget = GeometryCounts.from_limits(scene_limits),
            .geometry_usage = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.pipeline_state.release();
        self.vertex_buffers.release();
        self.index_buffers.release();
        self.* = undefined;
    }

    /// Advance to the next frame-in-flight slot and release the previous frame's
    /// geometry claims. Call once per rendered frame, before any batch is drawn.
    pub fn nextFrame(self: *Self) void {
        self.frame_index = self.vertex_buffers.nextIndex(self.frame_index);
        self.geometry_usage = .{};
    }

    /// Draw path instances in order, each with its parallel gradient uniforms.
    pub fn renderBatchWithGradients(
        self: *Self,
        encoder: objc.Object,
        instances: []const PathInstance,
        gradients: []const GradientUniforms,
        mesh_pool: *const MeshPool,
        options: struct { viewport_size: [2]f32, frame: u64 },
    ) void {
        assert(instances.len == gradients.len);
        assert(instances.len <= scene.MAX_PATHS_PER_FRAME);
        assert(options.viewport_size[0] > 0);
        assert(options.viewport_size[1] > 0);
        const slot = self.frame_index;
        const vertex_buffer = self.vertex_buffers.at(slot);
        const vertices_target = pipelines.frameBufferContents(PathVertex, vertex_buffer);
        const indices_target = pipelines.frameBufferContents(u32, self.index_buffers.at(slot));

        encoder.msgSend(void, "setRenderPipelineState:", .{self.pipeline_state.value});
        // Indices are rebased onto the whole slot, so the buffer binds at offset 0.
        encoder.msgSend(void, "setVertexBuffer:offset:atIndex:", .{
            vertex_buffer.value,
            @as(c_ulong, 0),
            @as(c_ulong, 0),
        });
        encoder.msgSend(void, "setVertexBytes:length:atIndex:", .{
            @as(*const anyopaque, @ptrCast(&options.viewport_size)),
            @as(c_ulong, @sizeOf([2]f32)),
            @as(c_ulong, 2),
        });

        for (instances, gradients) |*instance, *gradient| {
            const mesh = mesh_pool.getMesh(instance.getMeshRef());
            // An empty mesh has no triangles to draw, on every backend.
            if (mesh.indices.len == 0) continue;
            const index_first = self.upload(mesh, options.frame, vertices_target, indices_target);

            encoder.msgSend(void, "setVertexBytes:length:atIndex:", .{
                @as(*const anyopaque, @ptrCast(instance)),
                @as(c_ulong, @sizeOf(PathInstance)),
                @as(c_ulong, 1),
            });
            // Gradient uniforms are small (< 4 KiB), so they travel inline.
            encoder.msgSend(void, "setFragmentBytes:length:atIndex:", .{
                @as(*const anyopaque, @ptrCast(gradient)),
                @as(c_ulong, @sizeOf(GradientUniforms)),
                @as(c_ulong, 0),
            });
            encoder.msgSend(void, "drawIndexedPrimitives:indexCount:indexType:indexBuffer:" ++
                "indexBufferOffset:", .{
                @backingInt(mtl.MTLPrimitiveType.triangle),
                @as(c_ulong, mesh.indices.len),
                @backingInt(mtl.MTLIndexType.uint32),
                self.index_buffers.at(slot).value,
                @as(c_ulong, index_first) * @sizeOf(u32),
            });
        }
    }

    /// Claim one mesh against the frame's budget, then append it to the slot after
    /// the geometry already claimed this frame. Returns the copy's first index.
    /// Pools, order and per-draw granularity match the Vulkan and CPU renderers, so
    /// every backend panics at the same boundary with the same message.
    fn upload(
        self: *Self,
        mesh: *const PathMesh,
        frame: u64,
        vertices_target: [*]PathVertex,
        indices_target: [*]u32,
    ) u32 {
        const vertices = mesh.vertices.constSlice();
        const indices = mesh.indices.constSlice();
        assert(vertices.len > 0);
        assert(indices.len % 3 == 0);
        const vertex_first = self.geometry_usage.counts[@backingInt(GeometryPool.path_vertices)];
        const index_first = self.geometry_usage.counts[@backingInt(GeometryPool.path_indices)];

        self.geometry_usage.claim(&self.geometry_budget, .{
            .pool = .path_vertices,
            .requested = @intCast(vertices.len),
            .frame = frame,
        });
        self.geometry_usage.claim(&self.geometry_budget, .{
            .pool = .path_indices,
            .requested = @intCast(indices.len),
            .frame = frame,
        });

        @memcpy(vertices_target[vertex_first..][0..vertices.len], vertices);
        rebaseIndices(indices_target[index_first..][0..indices.len], indices, .{
            .vertex_first = vertex_first,
            .vertex_count = @intCast(vertices.len),
        });
        return index_first;
    }
};

/// Hot loop: copy mesh-local indices into the slot, offset by the mesh's first vertex.
fn rebaseIndices(
    target: []u32,
    source: []const u32,
    options: struct { vertex_first: u32, vertex_count: u32 },
) void {
    assert(target.len == source.len);
    assert(source.len <= path_mesh_mod.MAX_MESH_INDICES);
    for (source, target) |index, *rebased| {
        assert(index < options.vertex_count);
        rebased.* = index + options.vertex_first;
    }
}

fn createPipeline(device: objc.Object, sample_count: u32) !objc.Object {
    const NSString = objc.getClass("NSString") orelse return error.ClassNotFound;
    const source_str = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{path_shader_source.ptr});

    var compile_error: ?*anyopaque = null;
    const library_ptr = device.msgSend(?*anyopaque, "newLibraryWithSource:options:error:", .{
        source_str.value, @as(?*anyopaque, null), &compile_error,
    });
    if (library_ptr == null) return error.ShaderCompilationFailed;

    const library = objc.Object.fromId(library_ptr);
    defer library.release();

    const vert_name = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"path_vertex"});
    const frag_name = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"path_fragment"});

    const vert_fn = objc.Object.fromId(library.msgSend(?*anyopaque, "newFunctionWithName:", .{vert_name.value}) orelse return error.ShaderFunctionNotFound);
    const frag_fn = objc.Object.fromId(library.msgSend(?*anyopaque, "newFunctionWithName:", .{frag_name.value}) orelse return error.ShaderFunctionNotFound);
    defer vert_fn.release();
    defer frag_fn.release();

    const MTLRenderPipelineDescriptor = objc.getClass("MTLRenderPipelineDescriptor") orelse return error.ClassNotFound;
    const desc = MTLRenderPipelineDescriptor.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});
    defer desc.release();

    desc.msgSend(void, "setVertexFunction:", .{vert_fn.value});
    desc.msgSend(void, "setFragmentFunction:", .{frag_fn.value});
    desc.msgSend(void, "setSampleCount:", .{@as(c_ulong, sample_count)});

    const attachments = desc.msgSend(objc.Object, "colorAttachments", .{});
    const attach0 = attachments.msgSend(objc.Object, "objectAtIndexedSubscript:", .{@as(c_ulong, 0)});
    attach0.msgSend(void, "setPixelFormat:", .{@backingInt(mtl.MTLPixelFormat.bgra8unorm)});
    attach0.msgSend(void, "setBlendingEnabled:", .{true});
    // Path shader outputs premultiplied alpha (rgb already multiplied by alpha), so use ONE
    attach0.msgSend(void, "setSourceRGBBlendFactor:", .{@backingInt(mtl.MTLBlendFactor.one)});
    attach0.msgSend(void, "setDestinationRGBBlendFactor:", .{@backingInt(mtl.MTLBlendFactor.one_minus_source_alpha)});
    attach0.msgSend(void, "setSourceAlphaBlendFactor:", .{@backingInt(mtl.MTLBlendFactor.one)});
    attach0.msgSend(void, "setDestinationAlphaBlendFactor:", .{@backingInt(mtl.MTLBlendFactor.one_minus_source_alpha)});

    const pipeline_ptr = device.msgSend(?*anyopaque, "newRenderPipelineStateWithDescriptor:error:", .{
        desc.value, @as(?*anyopaque, null),
    }) orelse return error.PipelineCreationFailed;

    return objc.Object.fromId(pipeline_ptr);
}
