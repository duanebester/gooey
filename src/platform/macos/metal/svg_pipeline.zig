//! SVG Pipeline - Metal rendering for atlas-cached SVG icons
//!
//! Renders SVG icons as textured quads, sampling from an RGBA atlas.
//! Structure mirrors TextPipeline for consistency.

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
const SvgInstance = @import("../../../scene/svg_instance.zig").SvgInstance;

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
    \\    device const SvgInstance *icons [[buffer(1)]],
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

comptime {
    assert(@sizeOf(SvgInstance) == 96);
}

/// SVG icon pipeline state.
///
/// Resource sketch (CLAUDE.md §7): each frame in flight owns one instance buffer
/// of `svg_count_frame_max` × 96 B SVG instances, sized in `init` from
/// `ResourceLimits.scene` and never replaced. `.standard`: 98,304 B per frame,
/// 294,912 B per window for three frames. Per batch: one claim, one sequential copy and one
/// instanced draw. The scene holds at most the same number of SVGs, so a claim
/// past the budget is a programmer error and panics with the pool name.
pub const SvgPipeline = struct {
    device: objc.Object,
    pipeline_state: objc.Object,
    unit_vertex_buffer: objc.Object,
    instance_buffers: pipelines.FrameBuffers,
    frame_index: u32,
    /// The window's instance budget (`ResourceLimits.scene`).
    instance_budget: InstanceCounts,
    /// SVGs claimed this frame; also the slot's write offset.
    instance_usage: InstanceCounts,

    /// The renderer's SVG atlas texture (`AtlasTextures`); not owned.
    atlas_texture: objc.Object,

    pub fn init(
        device: objc.Object,
        sample_count: u32,
        limits: *const ResourceLimits,
        atlas_texture: objc.Object,
    ) !SvgPipeline {
        const scene_limits = &limits.scene;
        assert(sample_count > 0);
        assert(scene_limits.check() == null);
        const budget = InstanceCounts.from_limits(scene_limits);
        const svg_count_max: u64 = budget.counts[@backingInt(InstancePool.svgs)];

        const pipeline_state = try createPipeline(device, sample_count);
        errdefer pipeline_state.release();

        // Unit vertex buffer
        const vert_ptr = device.msgSend(?*anyopaque, "newBufferWithBytes:length:options:", .{
            @as(*const anyopaque, @ptrCast(&unit_vertices)),
            @as(c_ulong, @sizeOf(@TypeOf(unit_vertices))),
            @as(c_ulong, @bitCast(mtl.MTLResourceOptions{ .storage_mode = .shared })),
        }) orelse return error.BufferCreationFailed;
        const unit_vertex_buffer = objc.Object.fromId(vert_ptr);
        errdefer unit_vertex_buffer.release();

        const instance_buffers = try pipelines.createFrameBuffers(
            device,
            svg_count_max * @sizeOf(SvgInstance),
            "svg_instances",
            limits.frame.in_flight_count,
        );
        return .{
            .device = device,
            .pipeline_state = pipeline_state,
            .unit_vertex_buffer = unit_vertex_buffer,
            .instance_buffers = instance_buffers,
            .frame_index = 0,
            .instance_budget = budget,
            .instance_usage = .{},
            .atlas_texture = atlas_texture,
        };
    }

    pub fn deinit(self: *SvgPipeline) void {
        self.pipeline_state.release();
        self.unit_vertex_buffer.release();
        self.instance_buffers.release();
    }

    /// Advance to the next frame-in-flight slot and release the previous frame's
    /// claims. Call once per rendered frame, before any batch is drawn.
    pub fn nextFrame(self: *SvgPipeline) void {
        self.frame_index = self.instance_buffers.nextIndex(self.frame_index);
        self.instance_usage = .{};
    }

    /// Render a batch of SVG instances, appended to this frame's slot after the
    /// SVGs already claimed. Safe for multiple calls per frame.
    pub fn renderBatch(
        self: *SvgPipeline,
        encoder: objc.Object,
        instances: []const SvgInstance,
        options: struct { viewport_size: [2]f32, frame: u64 },
    ) void {
        assert(instances.len > 0);
        assert(instances.len <= scene.MAX_SVGS_PER_FRAME);
        const first = self.instance_usage.claim(&self.instance_budget, .{
            .pool = .svgs,
            .requested = @intCast(instances.len),
            .frame = options.frame,
        });

        const idx = self.frame_index;
        const byte_offset = @as(c_ulong, first) * @sizeOf(SvgInstance);
        const base = pipelines.frameBufferContents(SvgInstance, self.instance_buffers.at(idx));
        @memcpy(base[first..][0..instances.len], instances);
        const viewport_size = options.viewport_size;

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
            self.instance_buffers.at(idx).value,
            byte_offset,
            @as(c_ulong, 1),
        });
        encoder.msgSend(void, "setVertexBytes:length:atIndex:", .{
            @as(*const anyopaque, @ptrCast(&viewport_size)),
            @as(c_ulong, @sizeOf([2]f32)),
            @as(c_ulong, 2),
        });

        encoder.msgSend(void, "setFragmentTexture:atIndex:", .{
            self.atlas_texture.value,
            @as(c_ulong, 0),
        });

        // Draw
        encoder.msgSend(void, "drawPrimitives:vertexStart:vertexCount:instanceCount:", .{
            @backingInt(mtl.MTLPrimitiveType.triangle),
            @as(c_ulong, 0),
            @as(c_ulong, 6),
            @as(c_ulong, instances.len),
        });
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
    attach0.msgSend(void, "setPixelFormat:", .{@backingInt(mtl.MTLPixelFormat.bgra8unorm)});
    attach0.msgSend(void, "setBlendingEnabled:", .{true});
    // SVG shader outputs premultiplied alpha (rgb already multiplied by alpha), so use ONE
    attach0.msgSend(void, "setSourceRGBBlendFactor:", .{@backingInt(mtl.MTLBlendFactor.one)});
    attach0.msgSend(void, "setDestinationRGBBlendFactor:", .{@backingInt(mtl.MTLBlendFactor.one_minus_source_alpha)});
    attach0.msgSend(void, "setSourceAlphaBlendFactor:", .{@backingInt(mtl.MTLBlendFactor.one)});
    attach0.msgSend(void, "setDestinationAlphaBlendFactor:", .{@backingInt(mtl.MTLBlendFactor.one_minus_source_alpha)});

    const pipeline_ptr = device.msgSend(?*anyopaque, "newRenderPipelineStateWithDescriptor:error:", .{
        desc.value, @as(?*anyopaque, null),
    }) orelse return error.PipelineCreationFailed;

    return objc.Object.fromId(pipeline_ptr);
}
