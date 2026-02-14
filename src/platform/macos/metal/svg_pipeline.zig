//! SVG Pipeline - Metal rendering for atlas-cached SVG icons
//!
//! Renders SVG icons as textured quads, sampling from an RGBA atlas.
//! Structure mirrors TextPipeline for consistency.

const std = @import("std");
const objc = @import("objc");
const mtl = @import("api.zig");
const scene = @import("../../../scene/mod.zig");
const SvgInstance = @import("../../../scene/svg_instance.zig").SvgInstance;
const Atlas = @import("../../../text/atlas.zig").Atlas;

pub const svg_shader_source =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\
    \\struct SvgInstance {
    \\    uint order;
    \\    uint _pad0;
    \\    float pos_x;
    \\    float pos_y;
    \\    float size_x;
    \\    float size_y;
    \\    float uv_left;
    \\    float uv_top;
    \\    float uv_right;
    \\    float uv_bottom;
    \\    uint _pad1;  // Align float4 color to 16-byte boundary
    \\    uint _pad2;
    \\    float4 color;         // Fill color (HSLA) - must be at 16-byte aligned offset
    \\    float4 stroke_color;  // Stroke color (HSLA)
    \\    float clip_x;
    \\    float clip_y;
    \\    float clip_width;
    \\    float clip_height;
    \\};
    \\
    \\struct VertexOut {
    \\    float4 position [[position]];
    \\    float2 tex_coord;
    \\    float4 fill_color;
    \\    float4 stroke_color;
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
    \\vertex VertexOut svg_vertex(
    \\    uint vid [[vertex_id]],
    \\    uint iid [[instance_id]],
    \\    constant float2 *unit_vertices [[buffer(0)]],
    \\    constant SvgInstance *icons [[buffer(1)]],
    \\    constant float2 *viewport_size [[buffer(2)]]
    \\) {
    \\    float2 unit = unit_vertices[vid];
    \\    SvgInstance icon = icons[iid];
    \\
    \\    float2 pos = float2(icon.pos_x, icon.pos_y) + unit * float2(icon.size_x, icon.size_y);
    \\    float2 ndc = pos / *viewport_size * float2(2.0, -2.0) + float2(-1.0, 1.0);
    \\
    \\    float2 uv = float2(
    \\        mix(icon.uv_left, icon.uv_right, unit.x),
    \\        mix(icon.uv_top, icon.uv_bottom, unit.y)
    \\    );
    \\
    \\    VertexOut out;
    \\    out.position = float4(ndc, 0.0, 1.0);
    \\    out.tex_coord = uv;
    \\    out.fill_color = hsla_to_rgba(icon.color);
    \\    out.stroke_color = hsla_to_rgba(icon.stroke_color);
    \\    out.clip_bounds = float4(icon.clip_x, icon.clip_y, icon.clip_width, icon.clip_height);
    \\    out.screen_pos = pos;
    \\    return out;
    \\}
    \\
    \\fragment float4 svg_fragment(
    \\    VertexOut in [[stage_in]],
    \\    texture2d<float> atlas [[texture(0)]]
    \\) {
    \\    // Clip test
    \\    float2 clip_min = in.clip_bounds.xy;
    \\    float2 clip_max = clip_min + in.clip_bounds.zw;
    \\    if (in.screen_pos.x < clip_min.x || in.screen_pos.x > clip_max.x ||
    \\        in.screen_pos.y < clip_min.y || in.screen_pos.y > clip_max.y) {
    \\        discard_fragment();
    \\    }
    \\
    \\    constexpr sampler s(mag_filter::linear, min_filter::linear);
    \\    float4 sample = atlas.sample(s, in.tex_coord);
    \\
    \\    // Threshold to eliminate linear filtering bleed between channels
    \\    float fill_alpha = sample.r > 0.02 ? sample.r : 0.0;
    \\    float stroke_alpha = sample.g > 0.02 ? sample.g : 0.0;
    \\
    \\    // Composite: stroke shows only where fill isn't
    \\    float visible_stroke = stroke_alpha * (1.0 - fill_alpha);
    \\
    \\    // Blend colors
    \\    float3 rgb = in.fill_color.rgb * in.fill_color.a * fill_alpha
    \\               + in.stroke_color.rgb * in.stroke_color.a * visible_stroke;
    \\    float alpha = in.fill_color.a * fill_alpha + in.stroke_color.a * visible_stroke;
    \\
    \\    if (alpha < 0.001) discard_fragment();
    \\    return float4(rgb, alpha);
    \\}
;

pub const unit_vertices = [_][2]f32{
    .{ 0.0, 0.0 },
    .{ 1.0, 0.0 },
    .{ 0.0, 1.0 },
    .{ 1.0, 0.0 },
    .{ 1.0, 1.0 },
    .{ 0.0, 1.0 },
};

const FRAME_COUNT = 3;
const INITIAL_CAPACITY = 256;

pub const SvgPipeline = struct {
    device: objc.Object,
    pipeline_state: objc.Object,
    unit_vertex_buffer: objc.Object,
    instance_buffers: [FRAME_COUNT]objc.Object,
    instance_capacities: [FRAME_COUNT]usize,
    frame_index: usize,
    // Current offset within frame's buffer (for batched rendering)
    current_offset: usize,

    // Atlas texture management
    atlas_texture: ?objc.Object,
    atlas_generation: u32,

    // Atlas reference for current frame (set during prepareFrame)
    current_atlas: ?*const Atlas,

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, device: objc.Object, sample_count: u32) !SvgPipeline {
        const pipeline_state = try createPipeline(device, sample_count);

        // Unit vertex buffer
        const vert_ptr = device.msgSend(?*anyopaque, "newBufferWithBytes:length:options:", .{
            @as(*const anyopaque, @ptrCast(&unit_vertices)),
            @as(c_ulong, @sizeOf(@TypeOf(unit_vertices))),
            @as(c_ulong, @bitCast(mtl.MTLResourceOptions{ .storage_mode = .shared })),
        }) orelse return error.BufferCreationFailed;

        // Instance buffers (triple-buffered)
        var instance_buffers: [FRAME_COUNT]objc.Object = undefined;
        var instance_capacities: [FRAME_COUNT]usize = undefined;
        const instance_size = INITIAL_CAPACITY * @sizeOf(SvgInstance);

        for (0..FRAME_COUNT) |i| {
            const buf_ptr = device.msgSend(?*anyopaque, "newBufferWithLength:options:", .{
                @as(c_ulong, instance_size),
                @as(c_ulong, @bitCast(mtl.MTLResourceOptions.storage_shared)),
            }) orelse return error.BufferCreationFailed;
            instance_buffers[i] = objc.Object.fromId(buf_ptr);
            instance_capacities[i] = INITIAL_CAPACITY;
        }

        return .{
            .device = device,
            .pipeline_state = pipeline_state,
            .unit_vertex_buffer = objc.Object.fromId(vert_ptr),
            .instance_buffers = instance_buffers,
            .instance_capacities = instance_capacities,
            .frame_index = 0,
            .current_offset = 0,
            .atlas_texture = null,
            .atlas_generation = 0,
            .current_atlas = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SvgPipeline) void {
        self.pipeline_state.release();
        self.unit_vertex_buffer.release();
        for (&self.instance_buffers) |buf| buf.release();
        if (self.atlas_texture) |tex| tex.release();
    }

    /// Call at start of frame to bind atlas reference and reset offset
    pub fn prepareFrame(self: *SvgPipeline, atlas: *const Atlas) void {
        self.current_atlas = atlas;
        self.current_offset = 0; // Reset offset for new frame
    }

    /// Render a batch of SVG instances using triple-buffered storage with offset tracking.
    /// Safe for multiple calls per frame - appends to buffer at current offset.
    /// More efficient than setVertexBytes for larger batches.
    pub fn renderBatch(
        self: *SvgPipeline,
        encoder: objc.Object,
        instances: []const SvgInstance,
        viewport_size: [2]f32,
    ) !void {
        if (instances.len == 0) return;

        const atlas = self.current_atlas orelse return;

        // Update atlas texture if needed (only once per frame typically)
        try self.updateAtlasTexture(atlas);

        const idx = self.frame_index;
        const byte_offset = self.current_offset * @sizeOf(SvgInstance);
        const needed_capacity = self.current_offset + instances.len;

        // Grow buffer if needed
        if (needed_capacity > self.instance_capacities[idx]) {
            try self.growInstanceBuffer(idx, needed_capacity);
        }

        // Upload instances at current offset
        const buffer_ptr = self.instance_buffers[idx].msgSend(*anyopaque, "contents", .{});
        const base: [*]SvgInstance = @ptrCast(@alignCast(buffer_ptr));
        const dest = base + self.current_offset;
        @memcpy(dest[0..instances.len], instances);

        // Advance offset for next batch
        self.current_offset += instances.len;

        // Bind pipeline
        encoder.msgSend(void, "setRenderPipelineState:", .{self.pipeline_state.value});

        // Set unit vertex buffer
        encoder.msgSend(void, "setVertexBuffer:offset:atIndex:", .{
            self.unit_vertex_buffer.value,
            @as(c_ulong, 0),
            @as(c_ulong, 0),
        });

        // Set instance buffer with offset for this batch
        encoder.msgSend(void, "setVertexBuffer:offset:atIndex:", .{
            self.instance_buffers[idx].value,
            @as(c_ulong, byte_offset),
            @as(c_ulong, 1),
        });
        encoder.msgSend(void, "setVertexBytes:length:atIndex:", .{
            @as(*const anyopaque, @ptrCast(&viewport_size)),
            @as(c_ulong, @sizeOf([2]f32)),
            @as(c_ulong, 2),
        });

        // Bind atlas texture
        if (self.atlas_texture) |tex| {
            encoder.msgSend(void, "setFragmentTexture:atIndex:", .{ tex.value, @as(c_ulong, 0) });
        }

        // Draw
        encoder.msgSend(void, "drawPrimitives:vertexStart:vertexCount:instanceCount:", .{
            @intFromEnum(mtl.MTLPrimitiveType.triangle),
            @as(c_ulong, 0),
            @as(c_ulong, 6),
            @as(c_ulong, instances.len),
        });
    }

    fn updateAtlasTexture(self: *SvgPipeline, atlas: *const Atlas) !void {
        if (self.atlas_generation == atlas.generation and self.atlas_texture != null) {
            return;
        }

        // Release old texture
        if (self.atlas_texture) |tex| {
            tex.release();
            self.atlas_texture = null;
        }

        // Create texture descriptor
        const MTLTextureDescriptor = objc.getClass("MTLTextureDescriptor") orelse return error.ClassNotFound;
        const desc = MTLTextureDescriptor.msgSend(objc.Object, "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", .{
            @intFromEnum(mtl.MTLPixelFormat.rgba8unorm),
            @as(c_ulong, atlas.size),
            @as(c_ulong, atlas.size),
            false,
        });
        desc.msgSend(void, "setUsage:", .{@as(c_ulong, 0x01)}); // ShaderRead

        const tex_ptr = self.device.msgSend(?*anyopaque, "newTextureWithDescriptor:", .{desc.value}) orelse
            return error.TextureCreationFailed;
        const texture = objc.Object.fromId(tex_ptr);

        // Upload atlas data
        const region = mtl.MTLRegion{
            .origin = .{ .x = 0, .y = 0, .z = 0 },
            .size = .{ .width = atlas.size, .height = atlas.size, .depth = 1 },
        };
        texture.msgSend(void, "replaceRegion:mipmapLevel:withBytes:bytesPerRow:", .{
            region,
            @as(c_ulong, 0),
            @as(*const anyopaque, @ptrCast(atlas.data.ptr)),
            @as(c_ulong, atlas.size * 4), // RGBA = 4 bytes per pixel
        });

        self.atlas_texture = texture;
        self.atlas_generation = atlas.generation;
    }

    fn growInstanceBuffer(self: *SvgPipeline, idx: usize, min_capacity: usize) !void {
        const new_capacity = @max(min_capacity, self.instance_capacities[idx] * 2);
        const new_size = new_capacity * @sizeOf(SvgInstance);

        const new_ptr = self.device.msgSend(?*anyopaque, "newBufferWithLength:options:", .{
            @as(c_ulong, new_size),
            @as(c_ulong, @bitCast(mtl.MTLResourceOptions.storage_shared)),
        }) orelse return error.BufferCreationFailed;

        self.instance_buffers[idx].release();
        self.instance_buffers[idx] = objc.Object.fromId(new_ptr);
        self.instance_capacities[idx] = new_capacity;
    }
};

fn createPipeline(device: objc.Object, sample_count: u32) !objc.Object {
    const NSString = objc.getClass("NSString") orelse return error.ClassNotFound;
    const source_str = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{svg_shader_source.ptr});

    var compile_error: ?*anyopaque = null;
    const library_ptr = device.msgSend(?*anyopaque, "newLibraryWithSource:options:error:", .{
        source_str.value, @as(?*anyopaque, null), &compile_error,
    });
    if (library_ptr == null) return error.ShaderCompilationFailed;

    const library = objc.Object.fromId(library_ptr);
    defer library.release();

    const vert_name = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"svg_vertex"});
    const frag_name = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"svg_fragment"});

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
    attach0.msgSend(void, "setPixelFormat:", .{@intFromEnum(mtl.MTLPixelFormat.bgra8unorm)});
    attach0.msgSend(void, "setBlendingEnabled:", .{true});
    // SVG shader outputs premultiplied alpha (rgb already multiplied by alpha), so use ONE
    attach0.msgSend(void, "setSourceRGBBlendFactor:", .{@intFromEnum(mtl.MTLBlendFactor.one)});
    attach0.msgSend(void, "setDestinationRGBBlendFactor:", .{@intFromEnum(mtl.MTLBlendFactor.one_minus_source_alpha)});
    attach0.msgSend(void, "setSourceAlphaBlendFactor:", .{@intFromEnum(mtl.MTLBlendFactor.one)});
    attach0.msgSend(void, "setDestinationAlphaBlendFactor:", .{@intFromEnum(mtl.MTLBlendFactor.one_minus_source_alpha)});

    const pipeline_ptr = device.msgSend(?*anyopaque, "newRenderPipelineStateWithDescriptor:error:", .{
        desc.value, @as(?*anyopaque, null),
    }) orelse return error.PipelineCreationFailed;

    return objc.Object.fromId(pipeline_ptr);
}
