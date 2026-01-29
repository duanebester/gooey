//! Metal text rendering pipeline
//!
//! Renders glyph quads from a texture atlas using instanced rendering.

const std = @import("std");
const objc = @import("objc");
const mtl = @import("api.zig");
const scene = @import("../../../scene/mod.zig");
const Atlas = @import("../../../text/mod.zig").Atlas;

/// Metal shader for text rendering
pub const text_shader_source =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\
    \\struct GlyphInstance {
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
    \\    float4 color;  // HSLA - must be at 16-byte aligned offset
    \\    float clip_x;
    \\    float clip_y;
    \\    float clip_width;
    \\    float clip_height;
    \\};
    \\
    \\struct VertexOut {
    \\    float4 position [[position]];
    \\    float2 tex_coord;
    \\    float4 color;
    \\    float4 clip_bounds;  // x, y, width, height
    \\    float2 screen_pos;   // screen position for clip test
    \\};
    \\
    \\float4 hsla_to_rgba(float4 hsla) {
    \\    float h = hsla.x * 6.0;
    \\    float s = hsla.y;
    \\    float l = hsla.z;
    \\    float a = hsla.w;
    \\
    \\    float c = (1.0 - abs(2.0 * l - 1.0)) * s;
    \\    float x = c * (1.0 - abs(fmod(h, 2.0) - 1.0));
    \\    float m = l - c / 2.0;
    \\
    \\    float3 rgb;
    \\    if (h < 1.0) rgb = float3(c, x, 0);
    \\    else if (h < 2.0) rgb = float3(x, c, 0);
    \\    else if (h < 3.0) rgb = float3(0, c, x);
    \\    else if (h < 4.0) rgb = float3(0, x, c);
    \\    else if (h < 5.0) rgb = float3(x, 0, c);
    \\    else rgb = float3(c, 0, x);
    \\
    \\    return float4(rgb + m, a);
    \\}
    \\
    \\vertex VertexOut text_vertex(
    \\    uint vid [[vertex_id]],
    \\    uint iid [[instance_id]],
    \\    constant float2 *unit_vertices [[buffer(0)]],
    \\    constant GlyphInstance *glyphs [[buffer(1)]],
    \\    constant float2 *viewport_size [[buffer(2)]]
    \\) {
    \\    float2 unit = unit_vertices[vid];
    \\    GlyphInstance g = glyphs[iid];
    \\
    \\    // Calculate screen position
    \\    float2 pos = float2(g.pos_x, g.pos_y) + unit * float2(g.size_x, g.size_y);
    \\
    \\    // Convert to NDC
    \\    float2 ndc = pos / *viewport_size * float2(2.0, -2.0) + float2(-1.0, 1.0);
    \\
    \\    // Interpolate UVs
    \\    float2 uv = float2(
    \\        mix(g.uv_left, g.uv_right, unit.x),
    \\        mix(g.uv_top, g.uv_bottom, unit.y)
    \\    );
    \\
    \\    VertexOut out;
    \\    out.position = float4(ndc, 0.0, 1.0);
    \\    out.tex_coord = uv;
    \\    out.color = hsla_to_rgba(g.color);
    \\    out.clip_bounds = float4(g.clip_x, g.clip_y, g.clip_width, g.clip_height);
    \\    out.screen_pos = pos;
    \\    return out;
    \\}
    \\
    \\fragment float4 text_fragment(
    \\    VertexOut in [[stage_in]],
    \\    texture2d<float> atlas [[texture(0)]]
    \\) {
    \\    // Discard pixels outside clip bounds
    \\    float2 clip_min = in.clip_bounds.xy;
    \\    float2 clip_max = clip_min + in.clip_bounds.zw;
    \\    if (in.screen_pos.x < clip_min.x || in.screen_pos.x > clip_max.x ||
    \\        in.screen_pos.y < clip_min.y || in.screen_pos.y > clip_max.y) {
    \\        discard_fragment();
    \\    }
    \\
    \\    constexpr sampler s(mag_filter::linear, min_filter::linear);
    \\    float alpha = atlas.sample(s, in.tex_coord).r;
    \\    return float4(in.color.rgb, in.color.a * alpha);
    \\}
;

/// Unit quad vertices (two triangles)
pub const unit_vertices = [_][2]f32{
    .{ 0.0, 0.0 },
    .{ 1.0, 0.0 },
    .{ 0.0, 1.0 },
    .{ 1.0, 0.0 },
    .{ 1.0, 1.0 },
    .{ 0.0, 1.0 },
};

const FRAME_COUNT = 3;

/// Text rendering pipeline state
pub const TextPipeline = struct {
    device: objc.Object,
    pipeline_state: objc.Object,
    unit_vertex_buffer: objc.Object,

    // Triple-buffered instance buffers
    instance_buffers: [FRAME_COUNT]objc.Object,
    instance_capacities: [FRAME_COUNT]usize,
    frame_index: usize,
    // Current offset within frame's buffer (for batched rendering)
    current_offset: usize,

    atlas_texture: ?objc.Object,
    atlas_generation: u32,
    sampler_state: objc.Object,

    const Self = @This();
    const INITIAL_CAPACITY: usize = 1024;

    pub fn init(device: objc.Object, pixel_format: mtl.MTLPixelFormat, sample_count: u32) !Self {
        const NSString = objc.getClass("NSString") orelse return error.ClassNotFound;

        // Create shader library from source
        const source_str = NSString.msgSend(
            objc.Object,
            "stringWithUTF8String:",
            .{text_shader_source.ptr},
        );

        // Compile shader library
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
                std.debug.print("Text shader compile error: {s}\n", .{cstr});
            }
            return error.ShaderCompileFailed;
        }
        const library = objc.Object.fromId(library_ptr);
        defer library.msgSend(void, "release", .{});

        // Get shader functions
        const vert_name = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"text_vertex"});
        const frag_name = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"text_fragment"});

        const vert_fn_ptr = library.msgSend(?*anyopaque, "newFunctionWithName:", .{vert_name.value});
        const frag_fn_ptr = library.msgSend(?*anyopaque, "newFunctionWithName:", .{frag_name.value});

        if (vert_fn_ptr == null or frag_fn_ptr == null) {
            std.debug.print("Text shader function not found\n", .{});
            return error.ShaderFunctionNotFound;
        }
        const vert_fn = objc.Object.fromId(vert_fn_ptr);
        const frag_fn = objc.Object.fromId(frag_fn_ptr);
        defer vert_fn.msgSend(void, "release", .{});
        defer frag_fn.msgSend(void, "release", .{});

        // Create pipeline descriptor
        const MTLRenderPipelineDescriptor = objc.getClass("MTLRenderPipelineDescriptor") orelse
            return error.ClassNotFound;
        const desc = MTLRenderPipelineDescriptor.msgSend(objc.Object, "alloc", .{})
            .msgSend(objc.Object, "init", .{});
        defer desc.msgSend(void, "release", .{});

        desc.msgSend(void, "setVertexFunction:", .{vert_fn.value});
        desc.msgSend(void, "setFragmentFunction:", .{frag_fn.value});
        desc.msgSend(void, "setSampleCount:", .{@as(c_ulong, sample_count)});

        // Configure color attachment with alpha blending
        const color_attachments = desc.msgSend(objc.Object, "colorAttachments", .{});
        const attachment0 = color_attachments.msgSend(objc.Object, "objectAtIndexedSubscript:", .{@as(c_ulong, 0)});
        attachment0.msgSend(void, "setPixelFormat:", .{@intFromEnum(pixel_format)});
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
            return error.PipelineCreationFailed;
        }
        const pipeline_state = objc.Object.fromId(pipeline_ptr);

        // Create unit vertex buffer
        const unit_vertex_buffer_ptr = device.msgSend(
            ?*anyopaque,
            "newBufferWithBytes:length:options:",
            .{
                @as(*const anyopaque, @ptrCast(&unit_vertices)),
                @as(c_ulong, @sizeOf(@TypeOf(unit_vertices))),
                @as(c_ulong, @bitCast(mtl.MTLResourceOptions.storage_shared)),
            },
        ) orelse return error.BufferCreationFailed;
        const unit_vertex_buffer = objc.Object.fromId(unit_vertex_buffer_ptr);

        // Create triple instance buffers
        var instance_buffers: [FRAME_COUNT]objc.Object = undefined;
        var instance_capacities: [FRAME_COUNT]usize = undefined;

        // Create instance buffer
        const instance_size = INITIAL_CAPACITY * @sizeOf(scene.GlyphInstance);
        for (0..FRAME_COUNT) |i| {
            const buffer_ptr = device.msgSend(
                ?*anyopaque,
                "newBufferWithLength:options:",
                .{ @as(c_ulong, instance_size), @as(c_ulong, @bitCast(mtl.MTLResourceOptions.storage_shared)) },
            ) orelse return error.BufferCreationFailed;
            instance_buffers[i] = objc.Object.fromId(buffer_ptr);
            instance_capacities[i] = INITIAL_CAPACITY;
        }

        // Create sampler state
        const MTLSamplerDescriptor = objc.getClass("MTLSamplerDescriptor") orelse
            return error.ClassNotFound;
        const sampler_desc = MTLSamplerDescriptor.msgSend(objc.Object, "alloc", .{})
            .msgSend(objc.Object, "init", .{});
        defer sampler_desc.msgSend(void, "release", .{});

        sampler_desc.msgSend(void, "setMinFilter:", .{@as(c_ulong, 1)}); // linear
        sampler_desc.msgSend(void, "setMagFilter:", .{@as(c_ulong, 1)}); // linear

        const sampler_ptr = device.msgSend(?*anyopaque, "newSamplerStateWithDescriptor:", .{sampler_desc.value}) orelse
            return error.SamplerCreationFailed;
        const sampler_state = objc.Object.fromId(sampler_ptr);

        return .{
            .device = device,
            .pipeline_state = pipeline_state,
            .unit_vertex_buffer = unit_vertex_buffer,
            .instance_buffers = instance_buffers,
            .instance_capacities = instance_capacities,
            .frame_index = 0,
            .current_offset = 0,
            .atlas_texture = null,
            .atlas_generation = 0,
            .sampler_state = sampler_state,
        };
    }

    pub fn deinit(self: *Self) void {
        self.pipeline_state.msgSend(void, "release", .{});
        self.unit_vertex_buffer.msgSend(void, "release", .{});
        for (self.instance_buffers) |buf| {
            buf.msgSend(void, "release", .{});
        }
        self.sampler_state.msgSend(void, "release", .{});
        if (self.atlas_texture) |tex| tex.msgSend(void, "release", .{});
        self.* = undefined;
    }

    /// Advance to next buffer (call at start of frame)
    pub fn nextFrame(self: *Self) void {
        self.frame_index = (self.frame_index + 1) % FRAME_COUNT;
        self.current_offset = 0; // Reset offset for new frame
    }

    /// Update atlas texture if generation changed
    pub fn updateAtlas(self: *Self, atlas: *const Atlas) !void {
        if (self.atlas_generation == atlas.generation and self.atlas_texture != null) {
            return; // Already up to date
        }

        // Release old texture
        if (self.atlas_texture) |tex| {
            tex.msgSend(void, "release", .{});
            self.atlas_texture = null;
        }

        // Create texture descriptor
        const MTLTextureDescriptor = objc.getClass("MTLTextureDescriptor") orelse
            return error.ClassNotFound;
        const tex_desc = MTLTextureDescriptor.msgSend(objc.Object, "alloc", .{})
            .msgSend(objc.Object, "init", .{});
        defer tex_desc.msgSend(void, "release", .{});

        tex_desc.msgSend(void, "setTextureType:", .{@intFromEnum(mtl.MTLTextureType.type_2d)});
        tex_desc.msgSend(void, "setPixelFormat:", .{@intFromEnum(mtl.MTLPixelFormat.r8unorm)});
        tex_desc.msgSend(void, "setWidth:", .{@as(c_ulong, atlas.size)});
        tex_desc.msgSend(void, "setHeight:", .{@as(c_ulong, atlas.size)});
        tex_desc.msgSend(void, "setUsage:", .{@as(c_ulong, @bitCast(mtl.MTLTextureUsage.shader_read_only))});

        const texture_ptr = self.device.msgSend(
            ?*anyopaque,
            "newTextureWithDescriptor:",
            .{tex_desc.value},
        ) orelse {
            std.debug.print("Failed to create atlas texture\n", .{});
            return error.TextureCreationFailed;
        };
        const texture = objc.Object.fromId(texture_ptr);

        // Upload data
        const region = mtl.MTLRegion{
            .origin = .{ .x = 0, .y = 0, .z = 0 },
            .size = .{ .width = atlas.size, .height = atlas.size, .depth = 1 },
        };

        texture.msgSend(void, "replaceRegion:mipmapLevel:withBytes:bytesPerRow:", .{
            region,
            @as(c_ulong, 0),
            @as(*const anyopaque, @ptrCast(atlas.data.ptr)),
            @as(c_ulong, atlas.size),
        });

        self.atlas_texture = texture;
        self.atlas_generation = atlas.generation;
    }

    /// Render a batch of glyphs using triple-buffered storage with offset tracking.
    /// Safe for multiple calls per frame - appends to buffer at current offset.
    /// More efficient than setVertexBytes for larger batches.
    pub fn renderBatch(
        self: *Self,
        encoder: objc.Object,
        glyphs: []const scene.GlyphInstance,
        viewport_size: [2]f32,
    ) !void {
        if (glyphs.len == 0) return;
        if (self.atlas_texture == null) return;

        const idx = self.frame_index;
        const byte_offset = self.current_offset * @sizeOf(scene.GlyphInstance);
        const needed_capacity = self.current_offset + glyphs.len;

        // Grow buffer if needed
        if (needed_capacity > self.instance_capacities[idx]) {
            try self.growInstanceBuffer(idx, needed_capacity);
        }

        // Upload glyphs at current offset
        const buffer_ptr = self.instance_buffers[idx].msgSend(*anyopaque, "contents", .{});
        const base: [*]scene.GlyphInstance = @ptrCast(@alignCast(buffer_ptr));
        const dest = base + self.current_offset;
        @memcpy(dest[0..glyphs.len], glyphs);

        // Advance offset for next batch
        self.current_offset += glyphs.len;

        // Set pipeline state
        encoder.msgSend(void, "setRenderPipelineState:", .{self.pipeline_state});

        // Set unit vertex buffer
        encoder.msgSend(void, "setVertexBuffer:offset:atIndex:", .{
            self.unit_vertex_buffer,
            @as(c_ulong, 0),
            @as(c_ulong, 0),
        });

        // Set instance buffer with offset for this batch
        encoder.msgSend(void, "setVertexBuffer:offset:atIndex:", .{
            self.instance_buffers[idx],
            @as(c_ulong, byte_offset),
            @as(c_ulong, 1),
        });
        encoder.msgSend(void, "setVertexBytes:length:atIndex:", .{
            @as(*const anyopaque, @ptrCast(&viewport_size)),
            @as(c_ulong, @sizeOf([2]f32)),
            @as(c_ulong, 2),
        });

        // Set fragment texture
        encoder.msgSend(void, "setFragmentTexture:atIndex:", .{
            self.atlas_texture.?,
            @as(c_ulong, 0),
        });
        encoder.msgSend(void, "setFragmentSamplerState:atIndex:", .{
            self.sampler_state,
            @as(c_ulong, 0),
        });

        // Draw instanced
        encoder.msgSend(void, "drawPrimitives:vertexStart:vertexCount:instanceCount:", .{
            mtl.MTLPrimitiveType.triangle,
            @as(c_ulong, 0),
            @as(c_ulong, 6),
            @as(c_ulong, glyphs.len),
        });
    }

    fn growInstanceBuffer(self: *Self, idx: usize, min_capacity: usize) !void {
        const new_capacity = @max(min_capacity, self.instance_capacities[idx] * 2);
        const new_size = new_capacity * @sizeOf(scene.GlyphInstance);

        const new_buffer_ptr = self.device.msgSend(
            ?*anyopaque,
            "newBufferWithLength:options:",
            .{ @as(c_ulong, new_size), @as(c_ulong, @bitCast(mtl.MTLResourceOptions.storage_shared)) },
        ) orelse return error.BufferCreationFailed;

        self.instance_buffers[idx].msgSend(void, "release", .{});
        self.instance_buffers[idx] = objc.Object.fromId(new_buffer_ptr);
        self.instance_capacities[idx] = new_capacity;
    }
};
