//! Metal Image Rendering Pipeline
//!
//! Renders atlas-cached images as textured quads with instancing.
//! Supports tinting, opacity, grayscale effects, and rounded corners.

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
const ImageInstance = @import("../../../scene/image_instance.zig").ImageInstance;
const Atlas = @import("../../../text/atlas.zig").Atlas;

pub const image_shader_source =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\
    \\struct ImageInstance {
    \\    uint order;
    \\    uint _pad0;
    \\    float pos_x;
    \\    float pos_y;
    \\    float dest_width;
    \\    float dest_height;
    \\    float uv_left;
    \\    float uv_top;
    \\    float uv_right;
    \\    float uv_bottom;
    \\    uint _pad1;
    \\    uint _pad2;
    \\    float4 tint;          // HSLA tint color - at 16-byte aligned offset
    \\    float clip_x;
    \\    float clip_y;
    \\    float clip_width;
    \\    float clip_height;
    \\    float corner_tl;
    \\    float corner_tr;
    \\    float corner_br;
    \\    float corner_bl;
    \\    float grayscale;
    \\    float opacity;
    \\    float _pad3;
    \\    float _pad4;
    \\};
    \\
    \\struct VertexOut {
    \\    float4 position [[position]];
    \\    float2 tex_coord;
    \\    float4 tint_rgba;
    \\    float4 clip_bounds;
    \\    float2 screen_pos;
    \\    float2 image_origin;  // Top-left of image in screen coords
    \\    float2 size;
    \\    float4 corner_radii;
    \\    float grayscale;
    \\    float opacity;
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
    \\vertex VertexOut image_vertex(
    \\    uint vid [[vertex_id]],
    \\    uint iid [[instance_id]],
    \\    constant float2 *unit_vertices [[buffer(0)]],
    \\    device const ImageInstance *images [[buffer(1)]],
    \\    constant float2 *viewport_size [[buffer(2)]]
    \\) {
    \\    float2 unit = unit_vertices[vid];
    \\    ImageInstance img = images[iid];
    \\
    \\    float2 pos = float2(img.pos_x, img.pos_y) + unit * float2(img.dest_width, img.dest_height);
    \\    float2 ndc = pos / *viewport_size * float2(2.0, -2.0) + float2(-1.0, 1.0);
    \\
    \\    float2 uv = float2(
    \\        mix(img.uv_left, img.uv_right, unit.x),
    \\        mix(img.uv_top, img.uv_bottom, unit.y)
    \\    );
    \\
    \\    VertexOut out;
    \\    out.position = float4(ndc, 0.0, 1.0);
    \\    out.tex_coord = uv;
    \\    out.tint_rgba = hsla_to_rgba(img.tint);
    \\    out.clip_bounds = float4(img.clip_x, img.clip_y, img.clip_width, img.clip_height);
    \\    out.screen_pos = pos;
    \\    out.image_origin = float2(img.pos_x, img.pos_y);
    \\    out.size = float2(img.dest_width, img.dest_height);
    \\    out.corner_radii = float4(img.corner_tl, img.corner_tr, img.corner_br, img.corner_bl);
    \\    out.grayscale = img.grayscale;
    \\    out.opacity = img.opacity;
    \\    return out;
    \\}
    \\
    \\// Signed distance function for rounded rectangle
    \\float roundedRectSDF(float2 pos, float2 half_size, float4 radii) {
    \\    // Select correct corner radius based on quadrant
    \\    float r = pos.x > 0.0
    \\        ? (pos.y > 0.0 ? radii.z : radii.y)  // BR : TR
    \\        : (pos.y > 0.0 ? radii.w : radii.x); // BL : TL
    \\
    \\    float2 q = abs(pos) - half_size + r;
    \\    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
    \\}
    \\
    \\fragment float4 image_fragment(
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
    \\    // Rounded corners with anti-aliasing
    \\    float corner_alpha = 1.0;
    \\    float max_radius = max(max(in.corner_radii.x, in.corner_radii.y),
    \\                          max(in.corner_radii.z, in.corner_radii.w));
    \\    if (max_radius > 0.0) {
    \\        float2 half_size = in.size * 0.5;
    \\        // Compute position relative to image center
    \\        float2 local_pos = in.screen_pos - in.image_origin - half_size;
    \\
    \\        float dist = roundedRectSDF(local_pos, half_size, in.corner_radii);
    \\        // Smooth anti-aliased edge (1px transition)
    \\        corner_alpha = 1.0 - smoothstep(-0.5, 0.5, dist);
    \\        if (corner_alpha < 0.001) {
    \\            discard_fragment();
    \\        }
    \\    }
    \\
    \\    // Sample texture
    \\    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    \\    float4 color = atlas.sample(s, in.tex_coord);
    \\
    \\    // Apply grayscale effect
    \\    if (in.grayscale > 0.0) {
    \\        float gray = dot(color.rgb, float3(0.299, 0.587, 0.114));
    \\        color.rgb = mix(color.rgb, float3(gray), in.grayscale);
    \\    }
    \\
    \\    // Apply tint (multiply blend)
    \\    color *= in.tint_rgba;
    \\
    \\    // Apply corner anti-aliasing and opacity
    \\    color.a *= corner_alpha * in.opacity;
    \\
    \\    if (color.a < 0.001) discard_fragment();
    \\
    \\    return color;
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
    assert(@sizeOf(ImageInstance) == 112);
}

/// Image pipeline state.
///
/// Resource sketch (CLAUDE.md §7): each frame in flight owns one instance buffer
/// of `image_count_frame_max` × 112 B image instances, sized in `init` from
/// `ResourceLimits.scene` and never replaced. `.standard`: 28,672 B per frame,
/// 86,016 B per window for three frames. Per batch: one claim, one sequential copy and one
/// instanced draw. The scene holds at most the same number of images, so a claim
/// past the budget is a programmer error and panics with the pool name.
pub const ImagePipeline = struct {
    device: objc.Object,
    pipeline_state: objc.Object,
    unit_vertex_buffer: objc.Object,
    instance_buffers: pipelines.FrameBuffers,
    frame_index: u32,
    /// The window's instance budget (`ResourceLimits.scene`).
    instance_budget: InstanceCounts,
    /// Images claimed this frame; also the slot's write offset.
    instance_usage: InstanceCounts,

    // Atlas texture
    atlas_texture: ?objc.Object,
    atlas_generation: u32,

    // Reference to current atlas
    current_atlas: ?*const Atlas,

    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        device: objc.Object,
        sample_count: u32,
        limits: *const ResourceLimits,
    ) !ImagePipeline {
        const scene_limits = &limits.scene;
        assert(sample_count > 0);
        assert(scene_limits.check() == null);
        const budget = InstanceCounts.from_limits(scene_limits);
        const image_count_max: u64 = budget.counts[@backingInt(InstancePool.images)];

        const pipeline = createPipeline(device, sample_count) orelse
            return error.PipelineCreationFailed;
        errdefer pipeline.release();

        const unit_buffer_ptr = device.msgSend(
            ?*anyopaque,
            "newBufferWithBytes:length:options:",
            .{
                @as(*const anyopaque, @ptrCast(&unit_vertices)),
                @as(c_ulong, @sizeOf(@TypeOf(unit_vertices))),
                @as(c_ulong, @bitCast(mtl.MTLResourceOptions.storage_shared)),
            },
        ) orelse return error.BufferCreationFailed;
        const unit_buffer = objc.Object.fromId(unit_buffer_ptr);
        errdefer unit_buffer.release();

        const instance_buffers = try pipelines.createFrameBuffers(
            device,
            image_count_max * @sizeOf(ImageInstance),
            "image_instances",
            limits.frame.in_flight_count,
        );
        return ImagePipeline{
            .device = device,
            .pipeline_state = pipeline,
            .unit_vertex_buffer = unit_buffer,
            .instance_buffers = instance_buffers,
            .frame_index = 0,
            .instance_budget = budget,
            .instance_usage = .{},
            .atlas_texture = null,
            .atlas_generation = 0,
            .current_atlas = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ImagePipeline) void {
        self.instance_buffers.release();
        self.unit_vertex_buffer.release();
        self.pipeline_state.release();
        if (self.atlas_texture) |tex| tex.release();
    }

    /// Advance to the next frame-in-flight slot and release the previous frame's
    /// claims. Call once per rendered frame, before any batch is drawn.
    pub fn nextFrame(self: *ImagePipeline) void {
        self.frame_index = self.instance_buffers.nextIndex(self.frame_index);
        self.instance_usage = .{};
    }

    /// Bind this frame's atlas and upload it if its generation changed.
    pub fn prepareFrame(self: *ImagePipeline, atlas: *const Atlas) void {
        assert(atlas.size > 0);
        self.updateAtlasTexture(atlas);
    }

    /// Render a batch of images, appended to this frame's slot after the images
    /// already claimed. Safe for multiple calls per frame.
    pub fn renderBatch(
        self: *ImagePipeline,
        encoder: objc.Object,
        images: []const ImageInstance,
        options: struct { viewport_size: [2]f32, frame: u64 },
    ) void {
        assert(images.len > 0);
        assert(images.len <= scene.MAX_IMAGES_PER_FRAME);
        // Claimed even when no atlas is bound yet, so the count matches the scene.
        const first = self.instance_usage.claim(&self.instance_budget, .{
            .pool = .images,
            .requested = @intCast(images.len),
            .frame = options.frame,
        });
        const atlas_texture = self.atlas_texture orelse return;

        const buffer = self.instance_buffers.at(self.frame_index);
        const base = pipelines.frameBufferContents(ImageInstance, buffer);
        @memcpy(base[first..][0..images.len], images);
        const viewport_size = options.viewport_size;

        encoder.msgSend(void, "setRenderPipelineState:", .{self.pipeline_state.value});
        encoder.msgSend(void, "setVertexBuffer:offset:atIndex:", .{
            self.unit_vertex_buffer.value,
            @as(c_ulong, 0),
            @as(c_ulong, 0),
        });
        encoder.msgSend(void, "setVertexBuffer:offset:atIndex:", .{
            buffer.value,
            @as(c_ulong, first) * @sizeOf(ImageInstance),
            @as(c_ulong, 1),
        });
        encoder.msgSend(void, "setVertexBytes:length:atIndex:", .{
            @as(*const anyopaque, @ptrCast(&viewport_size)),
            @as(c_ulong, @sizeOf([2]f32)),
            @as(c_ulong, 2),
        });
        encoder.msgSend(void, "setFragmentTexture:atIndex:", .{
            atlas_texture.value,
            @as(c_ulong, 0),
        });
        encoder.msgSend(void, "drawPrimitives:vertexStart:vertexCount:instanceCount:", .{
            @backingInt(mtl.MTLPrimitiveType.triangle),
            @as(c_ulong, 0),
            @as(c_ulong, 6),
            @as(c_ulong, images.len),
        });
    }

    fn updateAtlasTexture(self: *ImagePipeline, atlas: *const Atlas) void {
        self.current_atlas = atlas;

        // Check if we need to update
        if (self.atlas_texture != null and self.atlas_generation == atlas.generation) {
            return;
        }

        const size = atlas.size;
        const data = atlas.getData();

        // Release old texture if size changed
        if (self.atlas_texture) |old_tex| {
            const old_width = old_tex.msgSend(c_ulong, "width", .{});
            if (old_width != size) {
                old_tex.release();
                self.atlas_texture = null;
            }
        }

        if (self.atlas_texture == null) {
            // Create new texture (RGBA format for images)
            const MTLTextureDescriptor = objc.getClass("MTLTextureDescriptor") orelse return;
            const desc = MTLTextureDescriptor.msgSend(
                objc.Object,
                "texture2DDescriptorWithPixelFormat:width:height:mipmapped:",
                .{
                    @backingInt(mtl.MTLPixelFormat.rgba8unorm),
                    @as(c_ulong, size),
                    @as(c_ulong, size),
                    @as(bool, false),
                },
            );
            desc.msgSend(void, "setUsage:", .{@as(c_ulong, 0x0001)}); // MTLTextureUsageShaderRead
            self.atlas_texture = self.device.msgSend(objc.Object, "newTextureWithDescriptor:", .{desc.value});
        }

        // Upload data
        if (self.atlas_texture) |tex| {
            const region = mtl.MTLRegion{
                .origin = .{ .x = 0, .y = 0, .z = 0 },
                .size = .{ .width = size, .height = size, .depth = 1 },
            };
            tex.msgSend(void, "replaceRegion:mipmapLevel:withBytes:bytesPerRow:", .{
                region,
                @as(c_ulong, 0),
                @as(*const anyopaque, @ptrCast(data.ptr)),
                @as(c_ulong, size * 4), // RGBA = 4 bytes per pixel
            });
        }

        self.atlas_generation = atlas.generation;
    }
};

fn createPipeline(device: objc.Object, sample_count: u32) ?objc.Object {
    const NSString = objc.getClass("NSString") orelse return null;
    const MTLRenderPipelineDescriptor = objc.getClass("MTLRenderPipelineDescriptor") orelse return null;

    // Compile shader
    var err: ?*anyopaque = null;
    const source_str = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{image_shader_source.ptr});

    const library_ptr = device.msgSend(
        ?*anyopaque,
        "newLibraryWithSource:options:error:",
        .{ source_str.value, @as(?*anyopaque, null), &err },
    ) orelse return null;
    const library = objc.Object.fromId(library_ptr);
    defer library.release();

    const vertex_fn_name = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"image_vertex"});
    const fragment_fn_name = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"image_fragment"});

    const vertex_fn = objc.Object.fromId(library.msgSend(?*anyopaque, "newFunctionWithName:", .{vertex_fn_name.value}) orelse return null);
    defer vertex_fn.release();

    const fragment_fn = objc.Object.fromId(library.msgSend(?*anyopaque, "newFunctionWithName:", .{fragment_fn_name.value}) orelse return null);
    defer fragment_fn.release();

    // Create pipeline descriptor
    const desc = MTLRenderPipelineDescriptor.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});
    defer desc.release();

    desc.msgSend(void, "setVertexFunction:", .{vertex_fn.value});
    desc.msgSend(void, "setFragmentFunction:", .{fragment_fn.value});
    desc.msgSend(void, "setSampleCount:", .{@as(c_ulong, sample_count)});

    // Color attachment with alpha blending
    const attachments = desc.msgSend(objc.Object, "colorAttachments", .{});
    const attachment0 = attachments.msgSend(objc.Object, "objectAtIndexedSubscript:", .{@as(c_ulong, 0)});
    attachment0.msgSend(void, "setPixelFormat:", .{@backingInt(mtl.MTLPixelFormat.bgra8unorm)});
    attachment0.msgSend(void, "setBlendingEnabled:", .{@as(bool, true)});
    attachment0.msgSend(void, "setSourceRGBBlendFactor:", .{@backingInt(mtl.MTLBlendFactor.source_alpha)});
    attachment0.msgSend(void, "setDestinationRGBBlendFactor:", .{@backingInt(mtl.MTLBlendFactor.one_minus_source_alpha)});
    attachment0.msgSend(void, "setSourceAlphaBlendFactor:", .{@backingInt(mtl.MTLBlendFactor.one)});
    attachment0.msgSend(void, "setDestinationAlphaBlendFactor:", .{@backingInt(mtl.MTLBlendFactor.one_minus_source_alpha)});

    const pipeline_ptr = device.msgSend(?*anyopaque, "newRenderPipelineStateWithDescriptor:error:", .{
        desc.value, @as(?*anyopaque, null),
    }) orelse return null;

    return objc.Object.fromId(pipeline_ptr);
}
