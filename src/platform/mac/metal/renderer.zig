//! Metal Renderer - handles GPU rendering with clean API types
const std = @import("std");
const objc = @import("objc");
const geometry = @import("../../../core/geometry.zig");
const mtl = @import("api.zig");
const shaders = @import("shaders.zig");

/// Vertex data: position (x, y) + color (r, g, b, a)
pub const Vertex = extern struct {
    position: [2]f32,
    color: [4]f32,
};

pub const Renderer = struct {
    device: objc.Object,
    command_queue: objc.Object,
    layer: objc.Object,
    pipeline_state: ?objc.Object,
    vertex_buffer: ?objc.Object,
    msaa_texture: ?objc.Object,
    size: geometry.Size(f64),
    sample_count: u32,

    const Self = @This();

    pub fn init(layer: objc.Object, size: geometry.Size(f64)) !Self {
        // Get default Metal device using clean extern declaration
        const device_ptr = mtl.MTLCreateSystemDefaultDevice() orelse
            return error.MetalNotAvailable;

        const device = objc.Object.fromId(device_ptr);

        // Create command queue
        const command_queue = device.msgSend(objc.Object, "newCommandQueue", .{});

        // Set device on layer
        layer.msgSend(void, "setDevice:", .{device.value});

        // Set drawable size on layer
        const drawable_size = mtl.CGSize{
            .width = size.width,
            .height = size.height,
        };
        layer.msgSend(void, "setDrawableSize:", .{drawable_size});

        var self = Self{
            .device = device,
            .command_queue = command_queue,
            .layer = layer,
            .pipeline_state = null,
            .vertex_buffer = null,
            .msaa_texture = null,
            .size = size,
            .sample_count = 4, // MSAA 4x
        };

        try self.createMSAATexture();
        try self.setupPipeline();

        return self;
    }

    fn createMSAATexture(self: *Self) !void {
        // Release old texture if it exists
        if (self.msaa_texture) |tex| {
            tex.msgSend(void, "release", .{});
            self.msaa_texture = null;
        }

        const MTLTextureDescriptor = objc.getClass("MTLTextureDescriptor") orelse
            return error.ClassNotFound;

        // Create 2D multisample texture descriptor with clean enum values
        const desc = MTLTextureDescriptor.msgSend(
            objc.Object,
            "texture2DDescriptorWithPixelFormat:width:height:mipmapped:",
            .{
                @intFromEnum(mtl.MTLPixelFormat.bgra8unorm),
                @as(c_ulong, @intFromFloat(self.size.width)),
                @as(c_ulong, @intFromFloat(self.size.height)),
                false,
            },
        );

        // Set texture type to 2DMultisample using clean enum
        desc.msgSend(void, "setTextureType:", .{@intFromEnum(mtl.MTLTextureType.type_2d_multisample)});
        desc.msgSend(void, "setSampleCount:", .{@as(c_ulong, self.sample_count)});

        // Use clean packed struct for texture usage
        const usage = mtl.MTLTextureUsage.render_target_only;
        desc.msgSend(void, "setUsage:", .{@as(c_ulong, @bitCast(usage))});

        // Private storage mode (GPU only)
        desc.msgSend(void, "setStorageMode:", .{@intFromEnum(mtl.MTLResourceOptions.StorageMode.private)});

        const texture_ptr = self.device.msgSend(?*anyopaque, "newTextureWithDescriptor:", .{desc.value});
        if (texture_ptr == null) {
            return error.MSAATextureCreationFailed;
        }
        self.msaa_texture = objc.Object.fromId(texture_ptr);
    }

    fn setupPipeline(self: *Self) !void {
        // Create shader library from source
        const NSString = objc.getClass("NSString") orelse return error.ClassNotFound;
        const source_str = NSString.msgSend(
            objc.Object,
            "stringWithUTF8String:",
            .{shaders.triangle_shader.ptr},
        );

        // Compile shader library
        const library_ptr = self.device.msgSend(
            ?*anyopaque,
            "newLibraryWithSource:options:error:",
            .{ source_str.value, @as(?*anyopaque, null), @as(?*anyopaque, null) },
        );
        if (library_ptr == null) {
            std.debug.print("Failed to compile shader library\n", .{});
            return error.ShaderCompilationFailed;
        }
        const library = objc.Object.fromId(library_ptr);
        defer library.msgSend(void, "release", .{});

        // Get vertex and fragment functions
        const vertex_name = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"vertex_main"});
        const fragment_name = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"fragment_main"});

        const vertex_fn_ptr = library.msgSend(?*anyopaque, "newFunctionWithName:", .{vertex_name.value});
        const fragment_fn_ptr = library.msgSend(?*anyopaque, "newFunctionWithName:", .{fragment_name.value});

        if (vertex_fn_ptr == null or fragment_fn_ptr == null) {
            return error.ShaderFunctionNotFound;
        }
        const vertex_fn = objc.Object.fromId(vertex_fn_ptr);
        const fragment_fn = objc.Object.fromId(fragment_fn_ptr);
        defer vertex_fn.msgSend(void, "release", .{});
        defer fragment_fn.msgSend(void, "release", .{});

        // Create vertex descriptor with clean enum values
        const MTLVertexDescriptor = objc.getClass("MTLVertexDescriptor") orelse
            return error.ClassNotFound;
        const vertex_desc = MTLVertexDescriptor.msgSend(objc.Object, "vertexDescriptor", .{});

        // Position attribute (float2)
        const attributes = vertex_desc.msgSend(objc.Object, "attributes", .{});
        const attr0 = attributes.msgSend(objc.Object, "objectAtIndexedSubscript:", .{@as(c_ulong, 0)});
        attr0.msgSend(void, "setFormat:", .{@intFromEnum(mtl.MTLVertexFormat.float2)});
        attr0.msgSend(void, "setOffset:", .{@as(c_ulong, 0)});
        attr0.msgSend(void, "setBufferIndex:", .{@as(c_ulong, 0)});

        // Color attribute (float4)
        const attr1 = attributes.msgSend(objc.Object, "objectAtIndexedSubscript:", .{@as(c_ulong, 1)});
        attr1.msgSend(void, "setFormat:", .{@intFromEnum(mtl.MTLVertexFormat.float4)});
        attr1.msgSend(void, "setOffset:", .{@as(c_ulong, 8)}); // After float2 (8 bytes)
        attr1.msgSend(void, "setBufferIndex:", .{@as(c_ulong, 0)});

        // Layout
        const layouts = vertex_desc.msgSend(objc.Object, "layouts", .{});
        const layout0 = layouts.msgSend(objc.Object, "objectAtIndexedSubscript:", .{@as(c_ulong, 0)});
        layout0.msgSend(void, "setStride:", .{@as(c_ulong, @sizeOf(Vertex))});

        // Create pipeline descriptor
        const MTLRenderPipelineDescriptor = objc.getClass("MTLRenderPipelineDescriptor") orelse
            return error.ClassNotFound;
        const pipeline_desc = MTLRenderPipelineDescriptor.msgSend(objc.Object, "alloc", .{});
        const pipeline_desc_init = pipeline_desc.msgSend(objc.Object, "init", .{});

        pipeline_desc_init.msgSend(void, "setVertexFunction:", .{vertex_fn.value});
        pipeline_desc_init.msgSend(void, "setFragmentFunction:", .{fragment_fn.value});
        pipeline_desc_init.msgSend(void, "setVertexDescriptor:", .{vertex_desc.value});
        pipeline_desc_init.msgSend(void, "setSampleCount:", .{@as(c_ulong, self.sample_count)});

        // Set pixel format using clean enum
        const color_attachments = pipeline_desc_init.msgSend(objc.Object, "colorAttachments", .{});
        const color_attachment_0 = color_attachments.msgSend(objc.Object, "objectAtIndexedSubscript:", .{@as(c_ulong, 0)});
        color_attachment_0.msgSend(void, "setPixelFormat:", .{@intFromEnum(mtl.MTLPixelFormat.bgra8unorm)});

        // Create pipeline state
        const pipeline_ptr = self.device.msgSend(
            ?*anyopaque,
            "newRenderPipelineStateWithDescriptor:error:",
            .{ pipeline_desc_init.value, @as(?*anyopaque, null) },
        );
        if (pipeline_ptr == null) {
            return error.PipelineCreationFailed;
        }
        self.pipeline_state = objc.Object.fromId(pipeline_ptr);

        // Create vertex buffer with triangle vertices
        const buffer_ptr = self.device.msgSend(
            ?*anyopaque,
            "newBufferWithBytes:length:options:",
            .{
                @as(*const anyopaque, @ptrCast(&shaders.triangle_vertices)),
                @as(c_ulong, @sizeOf(@TypeOf(shaders.triangle_vertices))),
                @as(c_ulong, @bitCast(mtl.MTLResourceOptions.storage_shared)),
            },
        );
        if (buffer_ptr == null) {
            return error.BufferCreationFailed;
        }
        self.vertex_buffer = objc.Object.fromId(buffer_ptr);
    }

    pub fn deinit(self: *Self) void {
        if (self.msaa_texture) |tex| tex.msgSend(void, "release", .{});
        if (self.pipeline_state) |ps| ps.msgSend(void, "release", .{});
        if (self.vertex_buffer) |vb| vb.msgSend(void, "release", .{});
        self.command_queue.msgSend(void, "release", .{});
        self.device.msgSend(void, "release", .{});
    }

    pub fn clear(self: *Self, color: geometry.Color) void {
        self.render(color, true);
    }

    pub fn render(self: *Self, clear_color: geometry.Color, draw_triangle: bool) void {
        const drawable_ptr = self.layer.msgSend(?*anyopaque, "nextDrawable", .{});
        if (drawable_ptr == null) return;
        const drawable = objc.Object.fromId(drawable_ptr);

        const texture_ptr = drawable.msgSend(?*anyopaque, "texture", .{});
        if (texture_ptr == null) return;
        const resolve_texture = objc.Object.fromId(texture_ptr);

        const msaa_tex = self.msaa_texture orelse return;

        // Create render pass descriptor
        const MTLRenderPassDescriptor = objc.getClass("MTLRenderPassDescriptor") orelse return;
        const render_pass = MTLRenderPassDescriptor.msgSend(objc.Object, "renderPassDescriptor", .{});

        const color_attachments = render_pass.msgSend(objc.Object, "colorAttachments", .{});
        const color_attachment_0 = color_attachments.msgSend(objc.Object, "objectAtIndexedSubscript:", .{@as(c_ulong, 0)});

        // Use clean enum values for load/store actions
        color_attachment_0.msgSend(void, "setTexture:", .{msaa_tex.value});
        color_attachment_0.msgSend(void, "setResolveTexture:", .{resolve_texture.value});
        color_attachment_0.msgSend(void, "setLoadAction:", .{@intFromEnum(mtl.MTLLoadAction.clear)});
        color_attachment_0.msgSend(void, "setStoreAction:", .{@intFromEnum(mtl.MTLStoreAction.multisample_resolve)});
        color_attachment_0.msgSend(void, "setClearColor:", .{mtl.MTLClearColor.fromColor(clear_color)});

        const command_buffer = self.command_queue.msgSend(objc.Object, "commandBuffer", .{});
        const encoder_ptr = command_buffer.msgSend(?*anyopaque, "renderCommandEncoderWithDescriptor:", .{render_pass.value});
        if (encoder_ptr == null) return;
        const encoder = objc.Object.fromId(encoder_ptr);

        if (draw_triangle) {
            if (self.pipeline_state) |pipeline| {
                if (self.vertex_buffer) |buffer| {
                    encoder.msgSend(void, "setRenderPipelineState:", .{pipeline.value});
                    encoder.msgSend(void, "setVertexBuffer:offset:atIndex:", .{
                        buffer.value,
                        @as(c_ulong, 0),
                        @as(c_ulong, 0),
                    });
                    encoder.msgSend(void, "drawPrimitives:vertexStart:vertexCount:", .{
                        @intFromEnum(mtl.MTLPrimitiveType.triangle),
                        @as(c_ulong, 0),
                        @as(c_ulong, 3),
                    });
                }
            }
        }

        encoder.msgSend(void, "endEncoding", .{});
        command_buffer.msgSend(void, "presentDrawable:", .{drawable.value});
        command_buffer.msgSend(void, "commit", .{});
    }

    pub fn resize(self: *Self, size: geometry.Size(f64)) void {
        self.size = size;
        self.layer.msgSend(void, "setDrawableSize:", .{mtl.CGSize{
            .width = size.width,
            .height = size.height,
        }});
        self.createMSAATexture() catch {};
    }
};
