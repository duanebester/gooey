//! Metal text rendering pipeline
//!
//! Renders glyph quads from a texture atlas using instanced rendering. Instance
//! buffers are reserved per frame in flight from `ResourceLimits.scene` at init.

const std = @import("std");
const assert = std.debug.assert;

const objc = @import("objc");
const mtl = @import("api.zig");
const pipelines = @import("pipelines.zig");
const scene = @import("../../../scene/mod.zig");
const InstanceCounts = scene.InstanceCounts;
const InstancePool = scene.InstancePool;
const SceneLimits = scene.SceneLimits;
const ResourceLimits = @import("../../../core/limits.zig").ResourceLimits;
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
    \\    device const GlyphInstance *glyphs [[buffer(1)]],
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

comptime {
    assert(@sizeOf(scene.GlyphInstance) == 80);
}

/// Text rendering pipeline state.
///
/// Resource sketch (CLAUDE.md §7): each frame in flight owns one instance buffer
/// of `glyph_count_frame_max` × 80 B glyph instances, sized in `init` from
/// `ResourceLimits.scene` and never replaced. `.standard`: 655,360 B per frame,
/// 1,966,080 B per window for three frames; `.nano`: 81,920 B per frame, 163,840 B
/// for two. Per batch: one claim, one sequential copy and one
/// instanced draw. The scene holds at most the same number of glyphs, so a claim
/// past the budget is a programmer error and panics with the pool name.
pub const TextPipeline = struct {
    device: objc.Object,
    pipeline_state: objc.Object,
    unit_vertex_buffer: objc.Object,

    instance_buffers: pipelines.FrameBuffers,
    frame_index: u32,
    /// The window's instance budget (`ResourceLimits.scene`).
    instance_budget: InstanceCounts,
    /// Glyphs claimed this frame; also the slot's write offset.
    instance_usage: InstanceCounts,

    atlas_texture: ?objc.Object,
    atlas_generation: u32,
    sampler_state: objc.Object,

    const Self = @This();

    pub fn init(
        device: objc.Object,
        pixel_format: mtl.MTLPixelFormat,
        sample_count: u32,
        limits: *const ResourceLimits,
    ) !Self {
        const scene_limits = &limits.scene;
        assert(sample_count > 0);
        assert(scene_limits.check() == null);
        const budget = InstanceCounts.from_limits(scene_limits);
        const glyph_count_max: u64 = budget.counts[@backingInt(InstancePool.glyphs)];

        const pipeline_state = try createPipelineState(device, pixel_format, sample_count);
        errdefer pipeline_state.release();

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
        errdefer unit_vertex_buffer.release();

        const instance_buffers = try pipelines.createFrameBuffers(
            device,
            glyph_count_max * @sizeOf(scene.GlyphInstance),
            "glyph_instances",
            limits.frame.in_flight_count,
        );
        errdefer instance_buffers.release();

        const sampler_state = try createSampler(device);
        return .{
            .device = device,
            .pipeline_state = pipeline_state,
            .unit_vertex_buffer = unit_vertex_buffer,
            .instance_buffers = instance_buffers,
            .frame_index = 0,
            .instance_budget = budget,
            .instance_usage = .{},
            .atlas_texture = null,
            .atlas_generation = 0,
            .sampler_state = sampler_state,
        };
    }

    pub fn deinit(self: *Self) void {
        self.pipeline_state.release();
        self.unit_vertex_buffer.release();
        self.instance_buffers.release();
        self.sampler_state.release();
        if (self.atlas_texture) |tex| tex.release();
        self.* = undefined;
    }

    /// Advance to the next frame-in-flight slot and release the previous frame's
    /// claims. Call once per rendered frame, before any batch is drawn.
    pub fn nextFrame(self: *Self) void {
        self.frame_index = self.instance_buffers.nextIndex(self.frame_index);
        self.instance_usage = .{};
    }

    /// Update atlas texture if generation changed
    pub fn updateAtlas(self: *Self, atlas: *const Atlas) !void {
        if (self.atlas_generation == atlas.generation and self.atlas_texture != null) {
            return; // Already up to date
        }

        // Release old texture
        if (self.atlas_texture) |tex| {
            tex.release();
            self.atlas_texture = null;
        }

        // Create texture descriptor
        const MTLTextureDescriptor = objc.getClass("MTLTextureDescriptor") orelse
            return error.ClassNotFound;
        const tex_desc = MTLTextureDescriptor.msgSend(objc.Object, "alloc", .{})
            .msgSend(objc.Object, "init", .{});
        defer tex_desc.release();

        tex_desc.msgSend(void, "setTextureType:", .{@backingInt(mtl.MTLTextureType.type_2d)});
        tex_desc.msgSend(void, "setPixelFormat:", .{@backingInt(mtl.MTLPixelFormat.r8unorm)});
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

    /// Render a batch of glyphs, appended to this frame's slot after the glyphs
    /// already claimed. Safe for multiple calls per frame.
    pub fn renderBatch(
        self: *Self,
        encoder: objc.Object,
        glyphs: []const scene.GlyphInstance,
        options: struct { viewport_size: [2]f32, frame: u64 },
    ) void {
        assert(glyphs.len > 0);
        assert(glyphs.len <= scene.MAX_GLYPHS_PER_FRAME);
        // Claimed even when no atlas is bound yet, so the count matches the scene.
        const first = self.instance_usage.claim(&self.instance_budget, .{
            .pool = .glyphs,
            .requested = @intCast(glyphs.len),
            .frame = options.frame,
        });
        if (self.atlas_texture == null) return;

        const idx = self.frame_index;
        const byte_offset = @as(c_ulong, first) * @sizeOf(scene.GlyphInstance);
        const buffer = self.instance_buffers.at(idx);
        const base = pipelines.frameBufferContents(scene.GlyphInstance, buffer);
        @memcpy(base[first..][0..glyphs.len], glyphs);
        const viewport_size = options.viewport_size;

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
            buffer,
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
};

/// Compile the text shaders and build the alpha-blended glyph pipeline state.
fn createPipelineState(
    device: objc.Object,
    pixel_format: mtl.MTLPixelFormat,
    sample_count: u32,
) !objc.Object {
    assert(sample_count > 0);
    const library = try createLibrary(device);
    defer library.release();

    const NSString = objc.getClass("NSString") orelse return error.ClassNotFound;
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
    defer vert_fn.release();
    defer frag_fn.release();

    const MTLRenderPipelineDescriptor = objc.getClass("MTLRenderPipelineDescriptor") orelse
        return error.ClassNotFound;
    const desc = MTLRenderPipelineDescriptor.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "init", .{});
    defer desc.release();

    desc.msgSend(void, "setVertexFunction:", .{vert_fn.value});
    desc.msgSend(void, "setFragmentFunction:", .{frag_fn.value});
    desc.msgSend(void, "setSampleCount:", .{@as(c_ulong, sample_count)});

    // Color attachment with straight-alpha blending.
    const color_attachments = desc.msgSend(objc.Object, "colorAttachments", .{});
    const attachment0 = color_attachments.msgSend(
        objc.Object,
        "objectAtIndexedSubscript:",
        .{@as(c_ulong, 0)},
    );
    const one_minus_source_alpha = @backingInt(mtl.MTLBlendFactor.one_minus_source_alpha);
    attachment0.msgSend(void, "setPixelFormat:", .{@backingInt(pixel_format)});
    attachment0.msgSend(void, "setBlendingEnabled:", .{true});
    attachment0.msgSend(void, "setSourceRGBBlendFactor:", .{
        @backingInt(mtl.MTLBlendFactor.source_alpha),
    });
    attachment0.msgSend(void, "setDestinationRGBBlendFactor:", .{one_minus_source_alpha});
    attachment0.msgSend(void, "setSourceAlphaBlendFactor:", .{
        @backingInt(mtl.MTLBlendFactor.one),
    });
    attachment0.msgSend(void, "setDestinationAlphaBlendFactor:", .{one_minus_source_alpha});

    var pipeline_error: ?*anyopaque = null;
    const pipeline_ptr = device.msgSend(
        ?*anyopaque,
        "newRenderPipelineStateWithDescriptor:error:",
        .{ desc.value, &pipeline_error },
    ) orelse return error.PipelineCreationFailed;
    return objc.Object.fromId(pipeline_ptr);
}

fn createLibrary(device: objc.Object) !objc.Object {
    const NSString = objc.getClass("NSString") orelse return error.ClassNotFound;
    const source_str = NSString.msgSend(
        objc.Object,
        "stringWithUTF8String:",
        .{text_shader_source.ptr},
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
            std.debug.print("Text shader compile error: {s}\n", .{cstr});
        }
        return error.ShaderCompileFailed;
    }
    return objc.Object.fromId(library_ptr);
}

fn createSampler(device: objc.Object) !objc.Object {
    const MTLSamplerDescriptor = objc.getClass("MTLSamplerDescriptor") orelse
        return error.ClassNotFound;
    const sampler_desc = MTLSamplerDescriptor.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "init", .{});
    defer sampler_desc.release();

    sampler_desc.msgSend(void, "setMinFilter:", .{@as(c_ulong, 1)}); // linear
    sampler_desc.msgSend(void, "setMagFilter:", .{@as(c_ulong, 1)}); // linear

    const sampler_ptr = device.msgSend(
        ?*anyopaque,
        "newSamplerStateWithDescriptor:",
        .{sampler_desc.value},
    ) orelse return error.SamplerCreationFailed;
    return objc.Object.fromId(sampler_ptr);
}
