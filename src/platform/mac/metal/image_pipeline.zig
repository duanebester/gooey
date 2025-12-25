//! Metal Image Rendering Pipeline
//!
//! Renders atlas-cached images as textured quads with instancing.
//! Supports tinting, opacity, grayscale effects, and rounded corners.

const std = @import("std");
const objc = @import("objc");
const mtl = @import("api.zig");
const scene = @import("../../../core/scene.zig");
const ImageInstance = @import("../../../core/image_instance.zig").ImageInstance;
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
    \\    constant ImageInstance *images [[buffer(1)]],
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
    \\    // Premultiply alpha for correct blending
    \\    color.rgb *= color.a;
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

const FRAME_COUNT = 3;
const INITIAL_CAPACITY = 256;

pub const ImagePipeline = struct {
    device: objc.Object,
    pipeline_state: objc.Object,
    unit_vertex_buffer: objc.Object,
    instance_buffers: [FRAME_COUNT]objc.Object,
    instance_capacities: [FRAME_COUNT]usize,
    frame_index: usize,
    // Current write offset for streaming
    current_offset: usize,

    // Atlas texture
    atlas_texture: ?objc.Object,
    atlas_generation: u32,

    // Reference to current atlas
    current_atlas: ?*const Atlas,

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, device: objc.Object, sample_count: u32) !ImagePipeline {
        const pipeline = createPipeline(device, sample_count) orelse return error.PipelineCreationFailed;

        // Create unit vertex buffer
        const unit_buffer = device.msgSend(
            objc.Object,
            "newBufferWithBytes:length:options:",
            .{
                @as(*const anyopaque, @ptrCast(&unit_vertices)),
                @as(c_ulong, @sizeOf(@TypeOf(unit_vertices))),
                @as(c_ulong, 0), // MTLResourceStorageModeShared
            },
        );

        // Create triple-buffered instance buffers
        var instance_buffers: [FRAME_COUNT]objc.Object = undefined;
        var instance_capacities: [FRAME_COUNT]usize = undefined;

        for (0..FRAME_COUNT) |i| {
            const buffer_size = INITIAL_CAPACITY * @sizeOf(ImageInstance);
            instance_buffers[i] = device.msgSend(
                objc.Object,
                "newBufferWithLength:options:",
                .{
                    @as(c_ulong, buffer_size),
                    @as(c_ulong, 0), // MTLResourceStorageModeShared
                },
            );
            instance_capacities[i] = INITIAL_CAPACITY;
        }

        return ImagePipeline{
            .device = device,
            .pipeline_state = pipeline,
            .unit_vertex_buffer = unit_buffer,
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

    pub fn deinit(self: *ImagePipeline) void {
        for (self.instance_buffers) |buffer| {
            buffer.msgSend(void, "release", .{});
        }
        self.unit_vertex_buffer.msgSend(void, "release", .{});
        self.pipeline_state.msgSend(void, "release", .{});
        if (self.atlas_texture) |tex| tex.msgSend(void, "release", .{});
    }

    /// Call at frame start to advance buffer index
    pub fn prepareFrame(self: *ImagePipeline, atlas: *const Atlas) void {
        self.frame_index = (self.frame_index + 1) % FRAME_COUNT;
        self.current_offset = 0;
        self.updateAtlasTexture(atlas);
    }

    /// Render images using pre-allocated buffer (single batch per frame)
    pub fn render(
        self: *ImagePipeline,
        encoder: objc.Object,
        images: []const ImageInstance,
        viewport_size: [2]f32,
    ) !void {
        if (images.len == 0) return;
        if (self.atlas_texture == null) return;

        const buffer = self.instance_buffers[self.frame_index];
        var capacity = self.instance_capacities[self.frame_index];

        // Grow buffer if needed
        if (images.len > capacity) {
            self.growInstanceBuffer(self.frame_index, images.len);
            capacity = self.instance_capacities[self.frame_index];
        }

        // Copy image data to buffer
        const contents = buffer.msgSend(*anyopaque, "contents", .{});
        const dest: [*]ImageInstance = @ptrCast(@alignCast(contents));
        @memcpy(dest[0..images.len], images);

        // Draw
        encoder.msgSend(void, "setRenderPipelineState:", .{self.pipeline_state.value});
        encoder.msgSend(void, "setVertexBuffer:offset:atIndex:", .{
            self.unit_vertex_buffer.value,
            @as(c_ulong, 0),
            @as(c_ulong, 0),
        });
        encoder.msgSend(void, "setVertexBuffer:offset:atIndex:", .{
            buffer.value,
            @as(c_ulong, 0),
            @as(c_ulong, 1),
        });
        encoder.msgSend(void, "setVertexBytes:length:atIndex:", .{
            @as(*const anyopaque, @ptrCast(&viewport_size)),
            @as(c_ulong, @sizeOf([2]f32)),
            @as(c_ulong, 2),
        });
        encoder.msgSend(void, "setFragmentTexture:atIndex:", .{
            self.atlas_texture.?.value,
            @as(c_ulong, 0),
        });
        encoder.msgSend(void, "drawPrimitives:vertexStart:vertexCount:instanceCount:", .{
            @intFromEnum(mtl.MTLPrimitiveType.triangle),
            @as(c_ulong, 0),
            @as(c_ulong, 6),
            @as(c_ulong, images.len),
        });
    }

    /// Render a batch of images (safe for multiple calls per frame)
    /// Uses setVertexBytes for small batches, avoiding buffer contention
    pub fn renderBatch(
        self: *ImagePipeline,
        encoder: objc.Object,
        images: []const ImageInstance,
        viewport_size: [2]f32,
    ) !void {
        if (images.len == 0) return;
        if (self.atlas_texture == null) return;

        const max_inline_bytes: usize = 4096;
        const data_size = images.len * @sizeOf(ImageInstance);

        encoder.msgSend(void, "setRenderPipelineState:", .{self.pipeline_state.value});
        encoder.msgSend(void, "setVertexBuffer:offset:atIndex:", .{
            self.unit_vertex_buffer.value,
            @as(c_ulong, 0),
            @as(c_ulong, 0),
        });

        if (data_size <= max_inline_bytes) {
            // Small batch - use setVertexBytes (copies inline)
            encoder.msgSend(void, "setVertexBytes:length:atIndex:", .{
                @as(*const anyopaque, @ptrCast(images.ptr)),
                @as(c_ulong, data_size),
                @as(c_ulong, 1),
            });
        } else {
            // Large batch - use buffer with offset
            const capacity = self.instance_capacities[self.frame_index];
            const needed = self.current_offset + images.len;

            if (needed > capacity) {
                // Buffer too small, grow it
                self.growInstanceBuffer(self.frame_index, needed);
            }

            const new_buffer = self.instance_buffers[self.frame_index];
            const contents = new_buffer.msgSend(*anyopaque, "contents", .{});
            const dest: [*]ImageInstance = @ptrCast(@alignCast(contents));
            @memcpy(dest[self.current_offset..][0..images.len], images);

            encoder.msgSend(void, "setVertexBuffer:offset:atIndex:", .{
                new_buffer.value,
                @as(c_ulong, self.current_offset * @sizeOf(ImageInstance)),
                @as(c_ulong, 1),
            });

            self.current_offset += images.len;
        }

        encoder.msgSend(void, "setVertexBytes:length:atIndex:", .{
            @as(*const anyopaque, @ptrCast(&viewport_size)),
            @as(c_ulong, @sizeOf([2]f32)),
            @as(c_ulong, 2),
        });
        encoder.msgSend(void, "setFragmentTexture:atIndex:", .{
            self.atlas_texture.?.value,
            @as(c_ulong, 0),
        });
        encoder.msgSend(void, "drawPrimitives:vertexStart:vertexCount:instanceCount:", .{
            @intFromEnum(mtl.MTLPrimitiveType.triangle),
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
                old_tex.msgSend(void, "release", .{});
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
                    @intFromEnum(mtl.MTLPixelFormat.rgba8unorm),
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

    fn growInstanceBuffer(self: *ImagePipeline, index: usize, needed: usize) void {
        var new_capacity = self.instance_capacities[index];
        while (new_capacity < needed) {
            new_capacity *= 2;
        }

        const new_buffer = self.device.msgSend(
            objc.Object,
            "newBufferWithLength:options:",
            .{
                @as(c_ulong, new_capacity * @sizeOf(ImageInstance)),
                @as(c_ulong, 0),
            },
        );

        self.instance_buffers[index].msgSend(void, "release", .{});
        self.instance_buffers[index] = new_buffer;
        self.instance_capacities[index] = new_capacity;
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
    defer library.msgSend(void, "release", .{});

    const vertex_fn_name = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"image_vertex"});
    const fragment_fn_name = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"image_fragment"});

    const vertex_fn = objc.Object.fromId(library.msgSend(?*anyopaque, "newFunctionWithName:", .{vertex_fn_name.value}) orelse return null);
    defer vertex_fn.msgSend(void, "release", .{});

    const fragment_fn = objc.Object.fromId(library.msgSend(?*anyopaque, "newFunctionWithName:", .{fragment_fn_name.value}) orelse return null);
    defer fragment_fn.msgSend(void, "release", .{});

    // Create pipeline descriptor
    const desc = MTLRenderPipelineDescriptor.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});
    defer desc.msgSend(void, "release", .{});

    desc.msgSend(void, "setVertexFunction:", .{vertex_fn.value});
    desc.msgSend(void, "setFragmentFunction:", .{fragment_fn.value});
    desc.msgSend(void, "setSampleCount:", .{@as(c_ulong, sample_count)});

    // Color attachment with alpha blending
    const attachments = desc.msgSend(objc.Object, "colorAttachments", .{});
    const attachment0 = attachments.msgSend(objc.Object, "objectAtIndexedSubscript:", .{@as(c_ulong, 0)});
    attachment0.msgSend(void, "setPixelFormat:", .{@intFromEnum(mtl.MTLPixelFormat.bgra8unorm)});
    attachment0.msgSend(void, "setBlendingEnabled:", .{@as(bool, true)});
    attachment0.msgSend(void, "setSourceRGBBlendFactor:", .{@intFromEnum(mtl.MTLBlendFactor.source_alpha)});
    attachment0.msgSend(void, "setDestinationRGBBlendFactor:", .{@intFromEnum(mtl.MTLBlendFactor.one_minus_source_alpha)});
    attachment0.msgSend(void, "setSourceAlphaBlendFactor:", .{@intFromEnum(mtl.MTLBlendFactor.one)});
    attachment0.msgSend(void, "setDestinationAlphaBlendFactor:", .{@intFromEnum(mtl.MTLBlendFactor.one_minus_source_alpha)});

    const pipeline_ptr = device.msgSend(?*anyopaque, "newRenderPipelineStateWithDescriptor:error:", .{
        desc.value, @as(?*anyopaque, null),
    }) orelse return null;

    return objc.Object.fromId(pipeline_ptr);
}
