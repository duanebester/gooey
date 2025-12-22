//! SVG Pipeline - Metal rendering for tessellated SVG meshes
//!
//! Renders SVG meshes as indexed triangle lists with instancing support.
//! Each mesh can be drawn multiple times with different transforms/colors.

const std = @import("std");
const objc = @import("objc");
const mtl = @import("api.zig");
const scene = @import("../../../core/scene.zig");
const svg_mesh = @import("../../../core/svg_mesh.zig");

/// Metal shader source for SVG rendering
pub const svg_shader_source =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\
    \\struct Vertex {
    \\    float2 position;
    \\};
    \\
    \\struct Instance {
    \\    float offset_x;
    \\    float offset_y;
    \\    float scale_x;
    \\    float scale_y;
    \\    float4 color;       // HSLA
    \\    float clip_x;
    \\    float clip_y;
    \\    float clip_width;
    \\    float clip_height;
    \\    uint order;
    \\    float _pad1;
    \\    float _pad2;
    \\    float _pad3;
    \\};
    \\
    \\struct VertexOut {
    \\    float4 position [[position]];
    \\    float4 color;
    \\    float2 screen_pos;
    \\    float4 clip_bounds;
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
    \\vertex VertexOut svg_vertex(
    \\    uint vid [[vertex_id]],
    \\    uint iid [[instance_id]],
    \\    constant Vertex* vertices [[buffer(0)]],
    \\    constant Instance* instances [[buffer(1)]],
    \\    constant float2* viewport_size [[buffer(2)]]
    \\) {
    \\    Vertex v = vertices[vid];
    \\    Instance inst = instances[iid];
    \\
    \\    // Apply transform
    \\    float2 pos = float2(
    \\        v.position.x * inst.scale_x + inst.offset_x,
    \\        v.position.y * inst.scale_y + inst.offset_y
    \\    );
    \\
    \\    // Convert to NDC
    \\    float2 ndc = pos / *viewport_size * float2(2.0, -2.0) + float2(-1.0, 1.0);
    \\
    \\    VertexOut out;
    \\    out.position = float4(ndc, 0.0, 1.0);
    \\    out.color = hsla_to_rgba(inst.color);
    \\    out.screen_pos = pos;
    \\    out.clip_bounds = float4(inst.clip_x, inst.clip_y, inst.clip_width, inst.clip_height);
    \\    return out;
    \\}
    \\
    \\fragment float4 svg_fragment(VertexOut in [[stage_in]]) {
    \\    // Clip test
    \\    float2 clip_min = in.clip_bounds.xy;
    \\    float2 clip_max = clip_min + in.clip_bounds.zw;
    \\    if (in.screen_pos.x < clip_min.x || in.screen_pos.x > clip_max.x ||
    \\        in.screen_pos.y < clip_min.y || in.screen_pos.y > clip_max.y) {
    \\        discard_fragment();
    \\    }
    \\    return in.color;
    \\}
;

/// SVG rendering pipeline
pub const SvgPipeline = struct {
    device: objc.Object,
    pipeline_state: objc.Object,
    vertex_buffer: ?objc.Object,
    index_buffer: ?objc.Object,
    vertex_count: usize,
    index_count: usize,

    pub fn init(device: objc.Object, sample_count: u32) !SvgPipeline {
        const pipeline_state = try createPipeline(device, sample_count);
        return .{
            .device = device,
            .pipeline_state = pipeline_state,
            .vertex_buffer = null,
            .index_buffer = null,
            .vertex_count = 0,
            .index_count = 0,
        };
    }

    pub fn deinit(self: *SvgPipeline) void {
        self.pipeline_state.msgSend(void, "release", .{});
        if (self.vertex_buffer) |buf| buf.msgSend(void, "release", .{});
        if (self.index_buffer) |buf| buf.msgSend(void, "release", .{});
    }

    /// Upload mesh data to GPU buffers
    pub fn uploadMesh(self: *SvgPipeline, mesh: *const svg_mesh.SvgMesh) !void {
        // Release old buffers
        if (self.vertex_buffer) |buf| buf.msgSend(void, "release", .{});
        if (self.index_buffer) |buf| buf.msgSend(void, "release", .{});

        // Create vertex buffer
        const vert_size = mesh.vertices.len * @sizeOf(svg_mesh.Vec2);
        const vert_ptr = self.device.msgSend(
            ?*anyopaque,
            "newBufferWithBytes:length:options:",
            .{
                @as(*const anyopaque, @ptrCast(mesh.vertices.ptr)),
                @as(c_ulong, vert_size),
                @as(c_ulong, @bitCast(mtl.MTLResourceOptions{ .storage_mode = .shared })),
            },
        );
        if (vert_ptr == null) return error.BufferCreationFailed;
        self.vertex_buffer = objc.Object.fromId(vert_ptr);
        self.vertex_count = mesh.vertices.len;

        // Create index buffer
        const idx_size = mesh.indices.len * @sizeOf(u16);
        const idx_ptr = self.device.msgSend(
            ?*anyopaque,
            "newBufferWithBytes:length:options:",
            .{
                @as(*const anyopaque, @ptrCast(mesh.indices.ptr)),
                @as(c_ulong, idx_size),
                @as(c_ulong, @bitCast(mtl.MTLResourceOptions{ .storage_mode = .shared })),
            },
        );
        if (idx_ptr == null) return error.BufferCreationFailed;
        self.index_buffer = objc.Object.fromId(idx_ptr);
        self.index_count = mesh.indices.len;
    }

    /// Render the mesh with given instances
    pub fn render(
        self: *SvgPipeline,
        encoder: objc.Object,
        instances: []const svg_mesh.SvgInstance,
        viewport_size: [2]f32,
    ) void {
        std.debug.print("SVG render called: {} instances, vbuf={}, ibuf={}, idx_count={}\n", .{
            instances.len,
            self.vertex_buffer != null,
            self.index_buffer != null,
            self.index_count,
        });
        if (self.vertex_buffer == null or self.index_buffer == null) return;
        if (instances.len == 0) return;

        encoder.msgSend(void, "setRenderPipelineState:", .{self.pipeline_state.value});

        // Vertex buffer
        encoder.msgSend(void, "setVertexBuffer:offset:atIndex:", .{
            self.vertex_buffer.?.value,
            @as(c_ulong, 0),
            @as(c_ulong, 0),
        });

        // Instance data
        encoder.msgSend(void, "setVertexBytes:length:atIndex:", .{
            @as(*const anyopaque, @ptrCast(instances.ptr)),
            @as(c_ulong, instances.len * @sizeOf(svg_mesh.SvgInstance)),
            @as(c_ulong, 1),
        });

        // Viewport size
        encoder.msgSend(void, "setVertexBytes:length:atIndex:", .{
            @as(*const anyopaque, @ptrCast(&viewport_size)),
            @as(c_ulong, @sizeOf([2]f32)),
            @as(c_ulong, 2),
        });

        // Draw indexed triangles with instancing
        encoder.msgSend(void, "drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:", .{
            @intFromEnum(mtl.MTLPrimitiveType.triangle),
            @as(c_ulong, self.index_count),
            @intFromEnum(mtl.MTLIndexType.uint16),
            self.index_buffer.?.value,
            @as(c_ulong, 0),
            @as(c_ulong, instances.len),
        });

        std.debug.print("SVG draw call issued: {} triangles, {} instances\n", .{
            self.index_count / 3,
            instances.len,
        });
    }
};

fn createPipeline(device: objc.Object, sample_count: u32) !objc.Object {
    const NSString = objc.getClass("NSString") orelse return error.ClassNotFound;
    const source_str = NSString.msgSend(
        objc.Object,
        "stringWithUTF8String:",
        .{svg_shader_source.ptr},
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
            std.debug.print("SVG shader compilation error: {s}\n", .{cstr});
        }
        return error.ShaderCompilationFailed;
    }

    const library = objc.Object.fromId(library_ptr);
    defer library.msgSend(void, "release", .{});

    const vertex_name = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"svg_vertex"});
    const fragment_name = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"svg_fragment"});

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

    const pipeline_ptr = device.msgSend(
        ?*anyopaque,
        "newRenderPipelineStateWithDescriptor:error:",
        .{ desc.value, @as(?*anyopaque, null) },
    );
    if (pipeline_ptr == null) {
        return error.PipelineCreationFailed;
    }

    std.debug.print("SVG pipeline created successfully\n", .{});
    return objc.Object.fromId(pipeline_ptr);
}
