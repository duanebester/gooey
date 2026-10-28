//! Path Pipeline - Metal rendering for triangulated paths
//!
//! Renders triangulated path meshes as de-indexed triangle records with
//! analytic edge anti-aliasing, the same technique and vertex records as the
//! Vulkan renderer (`mesh_edges.zig`, Vulkan `triangles.vert`/`mesh.frag`).
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
const PathMesh = @import("../../../scene/path_mesh.zig").PathMesh;
const mesh_edges = @import("../../mesh_edges.zig");
const TriangleVertex = mesh_edges.TriangleVertex;
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
    \\// One logical pixel is at least one device pixel at every supported scale.
    \\constant float aa_fringe = 1.0;
    \\// A sharp corner's offset point is clamped; tips sharper than about 14
    \\// degrees lose part of their fade band instead of producing long slivers.
    \\constant float miter_max = 4.0 * aa_fringe;
    \\// Draw vertices per triangle (mesh_edges.triangle_draw_vertex_count): the
    \\// triangle at its exact corners (0-2), then one fringe quad of two
    \\// triangles for each of its three edges (3-20).
    \\constant uint triangle_draw_vertex_count = 21;
    \\constant uint fringe_vertex_count = 6;
    \\
    \\// One de-indexed triangle vertex (mesh_edges.TriangleVertex, 20 bytes).
    \\// `edge_modes` holds two bits per triangle edge (v0->v1, v1->v2, v2->v0)
    \\// as an integral float, values from mesh_edges.EdgeMode:
    \\//   0 interior: no coverage change; the edge is drawn by the rasterizer.
    \\//   1 fade:     coverage *= clamp(distance_px + 0.5, 0, 1).
    \\//   2 underlap: full coverage up to half a pixel outside, discard beyond.
    \\struct TriangleVertex {
    \\    float x;
    \\    float y;
    \\    float u;
    \\    float v;
    \\    float edge_modes;
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
    \\    // Signed distances in logical pixels to the three original edges,
    \\    // positive inside. Affine in screen space, so interpolation is exact.
    \\    float3 edge_distance;
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
    \\// Offset of a corner that lies on edges with inward unit normals n0 and
    \\// n1: the intersection of the two edges' offset lines, each pushed
    \\// outward by its offset. Solves dot(shift, n0) = -offset0 and
    \\// dot(shift, n1) = -offset1. Ported from Vulkan's triangles.vert. Every
    \\// fringe vertex at a corner calls this with the same inputs, so
    \\// neighbouring quads share their common side exactly.
    \\float2 corner_shift(float2 n0, float2 n1, float offset0, float offset1) {
    \\    float det = n0.x * n1.y - n0.y * n1.x;
    \\    float2 shift;
    \\    if (abs(det) > 1e-4) {
    \\        shift = float2(-offset0 * n1.y + offset1 * n0.y,
    \\                       -offset1 * n0.x + offset0 * n1.x) / det;
    \\    } else {
    \\        // Nearly straight corner: the two offset lines coincide.
    \\        shift = -max(offset0, offset1) * n0;
    \\    }
    \\    float shift_length = length(shift);
    \\    if (shift_length > miter_max) shift *= miter_max / shift_length;
    \\    return shift;
    \\}
    \\
    \\// The triangle itself is drawn at its exact corners, so every edge it
    \\// shares with another triangle has bit-identical endpoints in both draws
    \\// and the rasterization rule covers each pixel on it exactly once. Each
    \\// fade or underlap edge adds a quad outside it: its inner side is that
    \\// same edge, its outer side joins the two corners' offset points
    \\// (`corner_shift`). An offset point slides along an interior edge or sits
    \\// on the miter of two faded edges, so the quads and the triangle cover
    \\// exactly the triangle grown by `aa_fringe` across those edges. Interior
    \\// edges get no quad: their six vertices collapse onto one point. Distances
    \\// to the original edges and barycentric uv extrapolation keep shading
    \\// identical across the triangle and its quads. Ported from triangles.vert.
    \\vertex VertexOut path_vertex(
    \\    uint vid [[vertex_id]],
    \\    device const TriangleVertex *vertices [[buffer(0)]],
    \\    constant PathInstance *instance [[buffer(1)]],
    \\    constant float2 *viewport_size [[buffer(2)]]
    \\) {
    \\    PathInstance inst = *instance;
    \\    uint triangle = vid / triangle_draw_vertex_count;
    \\    uint slot = vid - triangle * triangle_draw_vertex_count;
    \\    uint first = triangle * 3;
    \\    float2 corners[3];
    \\    float2 uvs[3];
    \\    for (uint j = 0; j < 3; j++) {
    \\        TriangleVertex v = vertices[first + j];
    \\        // Apply transform: scale then translate
    \\        corners[j] = float2(v.x * inst.scale_x + inst.offset_x,
    \\                            v.y * inst.scale_y + inst.offset_y);
    \\        uvs[j] = float2(v.u, v.v);
    \\    }
    \\    uint modes = uint(vertices[first].edge_modes + 0.5);
    \\
    \\    VertexOut out;
    \\    out.fill_color = hsla_to_rgba(inst.fill_color);
    \\    out.clip_bounds = float4(inst.clip_x, inst.clip_y, inst.clip_width, inst.clip_height);
    \\    out.gradient_type = inst.gradient_type;
    \\    out.grad_params = inst.grad_params;
    \\    out.edge_modes = modes;
    \\
    \\    float area = (corners[1].x - corners[0].x) * (corners[2].y - corners[0].y) -
    \\        (corners[1].y - corners[0].y) * (corners[2].x - corners[0].x);
    \\    float2 normals[3];
    \\    float lengths[3];
    \\    for (uint edge = 0; edge < 3; edge++) {
    \\        float2 direction = corners[(edge + 1) % 3] - corners[edge];
    \\        lengths[edge] = length(direction);
    \\        normals[edge] = float2(-direction.y, direction.x) * sign(area) /
    \\            max(lengths[edge], 1e-12);
    \\    }
    \\    float shortest = min(lengths[0], min(lengths[1], lengths[2]));
    \\    bool degenerate = abs(area) < 1e-6 || shortest < 1e-6;
    \\
    \\    // Corner k of the triangle this vertex sits on, and whether it is the
    \\    // corner's offset point (a fringe quad's outer side).
    \\    uint k = slot;
    \\    bool outer = false;
    \\    if (slot >= 3) {
    \\        uint edge = (slot - 3) / fringe_vertex_count;
    \\        uint quad_vertex = slot - 3 - edge * fringe_vertex_count;
    \\        // Quad (inner start, inner end, outer end), (inner start, outer end, outer start).
    \\        bool at_end = quad_vertex == 1 || quad_vertex == 2 || quad_vertex == 4;
    \\        k = at_end ? (edge + 1) % 3 : edge;
    \\        outer = quad_vertex == 2 || quad_vertex == 4 || quad_vertex == 5;
    \\        if (degenerate || ((modes >> (2 * edge)) & 3) == 0) {
    \\            k = edge;
    \\            outer = false;
    \\        }
    \\    }
    \\
    \\    float2 pos = corners[k];
    \\    float3 distances = float3(1e4);
    \\    out.uv = uvs[k];
    \\    if (degenerate) {
    \\        // Covers no pixel samples. Draw it at its corners, unfaded, without quads.
    \\        out.edge_modes = 0;
    \\    } else {
    \\        if (outer) {
    \\            // Corner k lies on edge k (k -> k+1) and edge k-1 (k-1 -> k).
    \\            uint before = (k + 2) % 3;
    \\            float offset_k = ((modes >> (2 * k)) & 3) != 0 ? aa_fringe : 0.0;
    \\            float offset_before = ((modes >> (2 * before)) & 3) != 0 ? aa_fringe : 0.0;
    \\            pos += corner_shift(normals[k], normals[before], offset_k, offset_before);
    \\        }
    \\        for (uint edge = 0; edge < 3; edge++) {
    \\            distances[edge] = dot(pos - corners[edge], normals[edge]);
    \\        }
    \\        if (outer) {
    \\            // Extrapolate uv to the offset point. The barycentric weight of
    \\            // corner j is the distance to its opposite edge (edge j+1)
    \\            // divided by the triangle's height over that edge. A vertex at a
    \\            // corner keeps its exact source uv.
    \\            float2 uv = float2(0.0);
    \\            for (uint j = 0; j < 3; j++) {
    \\                uint opposite = (j + 1) % 3;
    \\                float height = abs(area) / lengths[opposite];
    \\                uv += distances[opposite] / height * uvs[j];
    \\            }
    \\            out.uv = uv;
    \\        }
    \\    }
    \\
    \\    // Convert to NDC
    \\    float2 ndc = pos / *viewport_size * float2(2.0, -2.0) + float2(-1.0, 1.0);
    \\    out.position = float4(ndc, 0.0, 1.0);
    \\    out.screen_pos = pos;
    \\    out.edge_distance = distances;
    \\    return out;
    \\}
    \\
    \\// Coverage of the fragment's pixel from the analytic edges. `pixel` is one
    \\// device pixel measured in edge-distance units per component.
    \\float edge_coverage(float3 distance, float3 pixel, uint modes) {
    \\    float3 distance_px = distance / max(pixel, float3(1e-6));
    \\    float coverage = 1.0;
    \\    for (uint edge = 0; edge < 3; edge++) {
    \\        uint mode = (modes >> (2 * edge)) & 3;
    \\        if (mode == 1) {
    \\            coverage *= clamp(distance_px[edge] + 0.5, 0.0, 1.0);
    \\        } else if (mode == 2 && distance_px[edge] < -0.5) {
    \\            coverage = 0.0;
    \\        }
    \\    }
    \\    return coverage;
    \\}
    \\
    \\fragment float4 path_fragment(
    \\    VertexOut in [[stage_in]],
    \\    constant GradientUniforms &gradient [[buffer(0)]]
    \\) {
    \\    // Derivatives first: they are undefined after a non-uniform discard.
    \\    float3 edge_dx = dfdx(in.edge_distance);
    \\    float3 edge_dy = dfdy(in.edge_distance);
    \\    float3 edge_pixel = sqrt(edge_dx * edge_dx + edge_dy * edge_dy);
    \\
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
    \\        // Linear gradient in uv space: project uv onto the gradient line.
    \\        float2 start = in.grad_params.xy;
    \\        float2 end = in.grad_params.zw;
    \\        float2 dir = end - start;
    \\        float len_sq = dot(dir, dir);
    \\        float t = len_sq < 0.0001 ? 0.0 : dot(in.uv - start, dir) / len_sq;
    \\        color = sample_gradient(t, gradient);
    \\    } else if (in.gradient_type == 2) {
    \\        // Radial gradient: distance from the centre in uv space.
    \\        float2 center = in.grad_params.xy;
    \\        float radius = in.grad_params.z;
    \\        float inner_radius = in.grad_params.w;
    \\        float dist = length(in.uv - center);
    \\        float t = radius <= inner_radius ? 1.0 :
    \\            (dist - inner_radius) / (radius - inner_radius);
    \\        color = sample_gradient(t, gradient);
    \\    } else {
    \\        // Solid color fill
    \\        color = in.fill_color;
    \\    }
    \\
    \\    float coverage = edge_coverage(in.edge_distance, edge_pixel, in.edge_modes);
    \\    if (coverage <= 0.0) discard_fragment();
    \\    color.a *= coverage;
    \\    if (color.a < 0.001) discard_fragment();
    \\
    \\    // Output premultiplied alpha
    \\    return float4(color.rgb * color.a, color.a);
    \\}
;

// `path_shader_source` hard-codes the draw layout as `triangle_draw_vertex_count`.
comptime {
    assert(mesh_edges.triangle_draw_vertex_count == 21);
}

/// De-indexed path triangles, one draw per path instance, in scene order, with
/// analytic edge anti-aliasing (`mesh_edges`). The render target has one
/// sample per pixel.
///
/// Resource sketch (CLAUDE.md §7): each frame in flight owns one buffer of
/// `path_index_count_frame_max` × 20 B triangle records (`TriangleVertex`: the
/// source vertex plus its triangle's edge modes), sized in `init` from
/// `ResourceLimits.scene` and never replaced; Vulkan reserves the same 20 B per
/// path index. `.standard`: 327,680 B per frame, 983,040 B per window for three
/// frames, as before (16 B × 16,384 vertices + 4 B × 16,384 indices). `.nano`
/// grows from 24,576 to 40,960 B per frame because its index budget is twice
/// its vertex budget. The edge table adds 30 B of host memory per path index
/// budget (491,540 B at `.standard`), reserved at init.
///
/// Per frame: one classification pass over every path triangle (three hashed
/// inserts each). Per draw: one claim of each path pool, one de-indexing copy
/// with three edge lookups per triangle, a 112 B `setVertexBytes`, a 352 B
/// `setFragmentBytes` and one non-indexed draw of 21 vertices per triangle
/// (`mesh_edges.triangle_draw_vertex_count`): the triangle and a fringe quad
/// per edge, generated from the same three records, so fringe geometry costs
/// vertex shader invocations, not buffer space. A quad on an interior edge
/// collapses to a point and rasterizes nothing. Every mesh is claimed against
/// the same `GeometryCounts` as the Vulkan and CPU renderers before it is
/// written, so an over-budget frame panics with the pool name.
pub const PathPipeline = struct {
    pipeline_state: objc.Object,
    triangle_buffers: pipelines.FrameBuffers,
    frame_index: u32,
    /// The window's aggregate geometry budget (`ResourceLimits.scene`).
    geometry_budget: GeometryCounts,
    /// Geometry claimed this frame. The path index count is also the slot's
    /// write offset in triangle records: one record per claimed index.
    geometry_usage: GeometryCounts,
    /// Edge modes of the frame being drawn, filled by `classifyEdges`.
    edges: mesh_edges.EdgeTable,
    gpa: std.mem.Allocator,

    const Self = @This();

    /// Bytes of one frame's triangle record buffer for `scene_limits`.
    pub fn frameBytes(scene_limits: *const SceneLimits) u64 {
        return @as(u64, scene_limits.path_index_count_frame_max) * @sizeOf(TriangleVertex);
    }

    pub fn init(gpa: std.mem.Allocator, device: objc.Object, limits: *const ResourceLimits) !Self {
        const scene_limits = &limits.scene;
        assert(scene_limits.check() == null);
        assert(scene_limits.path_index_count_frame_max > 0);
        const pipeline_state = try createPipeline(device);
        errdefer pipeline_state.release();

        const triangle_buffers = try pipelines.createFrameBuffers(
            device,
            frameBytes(scene_limits),
            "path_triangles",
            limits.frame.in_flight_count,
        );
        errdefer triangle_buffers.release();

        var edges: mesh_edges.EdgeTable = .{};
        try edges.init(gpa, scene_limits.path_index_count_frame_max);
        errdefer edges.deinit(gpa);

        return .{
            .pipeline_state = pipeline_state,
            .triangle_buffers = triangle_buffers,
            .frame_index = 0,
            .geometry_budget = GeometryCounts.from_limits(scene_limits),
            .geometry_usage = .{},
            .edges = edges,
            .gpa = gpa,
        };
    }

    pub fn deinit(self: *Self) void {
        self.pipeline_state.release();
        self.triangle_buffers.release();
        self.edges.deinit(self.gpa);
        self.* = undefined;
    }

    /// Advance to the next frame-in-flight slot and release the previous frame's
    /// geometry claims. Call once per rendered frame, before any batch is drawn.
    pub fn nextFrame(self: *Self) void {
        self.frame_index = self.triangle_buffers.nextIndex(self.frame_index);
        self.geometry_usage = .{};
    }

    /// Classify every path edge of `scene` (`mesh_edges.classify`, shared with
    /// Vulkan). Call before the frame's first path batch.
    pub fn classifyEdges(self: *Self, scene_data: *const scene.Scene) void {
        assert(self.edges.entries.len > 0);
        assert(self.edges.edge_count_max == self.geometry_budget.counts[
            @backingInt(GeometryPool.path_indices)
        ]);
        mesh_edges.classify(&self.edges, scene_data);
    }

    /// Draw path instances in order, each with its parallel gradient uniforms.
    /// `path_first` is the index of `instances[0]` in the scene's path list,
    /// the index `classifyEdges` recorded its edges under.
    pub fn renderBatchWithGradients(
        self: *Self,
        encoder: objc.Object,
        instances: []const PathInstance,
        gradients: []const GradientUniforms,
        mesh_pool: *const MeshPool,
        options: struct { viewport_size: [2]f32, frame: u64, path_first: u32 },
    ) void {
        assert(instances.len == gradients.len);
        assert(options.path_first + instances.len <= scene.MAX_PATHS_PER_FRAME);
        assert(options.viewport_size[0] > 0);
        assert(options.viewport_size[1] > 0);
        const triangle_buffer = self.triangle_buffers.at(self.frame_index);
        const records = pipelines.frameBufferContents(TriangleVertex, triangle_buffer);

        encoder.msgSend(void, "setRenderPipelineState:", .{self.pipeline_state.value});
        // Draws address records by vertex start, so the buffer binds at offset 0.
        encoder.msgSend(void, "setVertexBuffer:offset:atIndex:", .{
            triangle_buffer.value,
            @as(c_ulong, 0),
            @as(c_ulong, 0),
        });
        encoder.msgSend(void, "setVertexBytes:length:atIndex:", .{
            @as(*const anyopaque, @ptrCast(&options.viewport_size)),
            @as(c_ulong, @sizeOf([2]f32)),
            @as(c_ulong, 2),
        });

        for (instances, gradients, options.path_first..) |*instance, *gradient, path_index| {
            const mesh = mesh_pool.getMesh(instance.getMeshRef());
            // An empty mesh has no triangles to draw, on every backend.
            if (mesh.indices.len == 0) continue;
            const record_first = self.upload(mesh, records, .{
                .path = instance,
                .path_index = @intCast(path_index),
                .frame = options.frame,
            });

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
            // Every triangle draws `triangle_draw_vertex_count` vertices (itself
            // and three fringe quads) from its three records. `vertex_id`
            // includes the start, so `vid / 21` is the triangle's index in the
            // frame's records, three records each.
            const triangle_first = @divExact(@as(u64, record_first), 3);
            const draw_vertex_count = mesh_edges.draw_vertex_count(@intCast(mesh.indices.len));
            encoder.msgSend(void, "drawPrimitives:vertexStart:vertexCount:", .{
                @backingInt(mtl.MTLPrimitiveType.triangle),
                @as(c_ulong, triangle_first * mesh_edges.triangle_draw_vertex_count),
                @as(c_ulong, draw_vertex_count),
            });
        }
    }

    /// Claim one mesh against the frame's budget, then de-index it into the slot
    /// after the records already claimed this frame. Returns the first record.
    /// Pools, order and per-draw granularity match the Vulkan and CPU renderers, so
    /// every backend panics at the same boundary with the same message.
    fn upload(
        self: *Self,
        mesh: *const PathMesh,
        records: [*]TriangleVertex,
        options: struct { path: *const PathInstance, path_index: mesh_edges.PathIndex, frame: u64 },
    ) u32 {
        const vertices = mesh.vertices.constSlice();
        const indices = mesh.indices.constSlice();
        assert(vertices.len > 0);
        assert(indices.len % 3 == 0);
        const record_first = self.geometry_usage.counts[@backingInt(GeometryPool.path_indices)];
        assert(record_first % 3 == 0);

        self.geometry_usage.claim(&self.geometry_budget, .{
            .pool = .path_vertices,
            .requested = @intCast(vertices.len),
            .frame = options.frame,
        });
        self.geometry_usage.claim(&self.geometry_budget, .{
            .pool = .path_indices,
            .requested = @intCast(indices.len),
            .frame = options.frame,
        });

        mesh_edges.write_triangles(records[record_first..][0..indices.len], &.{
            .edges = &self.edges,
            .path = options.path,
            .path_index = options.path_index,
            .vertices = vertices,
            .indices = indices,
        });
        return record_first;
    }
};

fn createPipeline(device: objc.Object) !objc.Object {
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
    desc.msgSend(void, "setSampleCount:", .{@as(c_ulong, pipelines.sample_count)});

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
