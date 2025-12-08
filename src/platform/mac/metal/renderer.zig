//! Metal Renderer - handles GPU rendering with clean API types
const std = @import("std");

const objc = @import("objc");

const geometry = @import("../../../core/geometry.zig");
const scene_mod = @import("../../../core/scene.zig");
const mtl = @import("api.zig");
const quad_shader = @import("quad.zig");
const shadow_shader = @import("shadow.zig");
const text_pipeline = @import("text.zig");
const Atlas = @import("../../../font/atlas.zig").Atlas;

/// Vertex data: position (x, y) + color (r, g, b, a)
pub const Vertex = extern struct {
    position: [2]f32,
    color: [4]f32,
};

pub const Renderer = struct {
    device: objc.Object,
    command_queue: objc.Object,
    layer: objc.Object,

    unified_memory: bool, // True on Apple Silicon

    // Quad pipeline (new)
    quad_pipeline_state: ?objc.Object,
    quad_unit_vertex_buffer: ?objc.Object,
    quad_instance_buffer: ?objc.Object,
    quad_instance_capacity: usize,

    // Shadow pipeline
    shadow_pipeline_state: ?objc.Object,
    shadow_instance_buffer: ?objc.Object,
    shadow_instance_capacity: usize,

    text_pipeline_state: ?text_pipeline.TextPipeline,

    // MSAA
    msaa_texture: ?objc.Object,
    size: geometry.Size(f64),
    scale_factor: f64,
    sample_count: u32,

    const Self = @This();
    const INITIAL_QUAD_CAPACITY = 256;

    pub fn init(layer: objc.Object, size: geometry.Size(f64), scale_factor: f64) !Self {

        // Get default Metal device
        const device_ptr = mtl.MTLCreateSystemDefaultDevice() orelse
            return error.MetalNotAvailable;

        const device = objc.Object.fromId(device_ptr);

        // Detect unified memory (Apple Silicon)
        const unified_memory = device.msgSend(bool, "hasUnifiedMemory", .{});

        // Create command queue
        const command_queue = device.msgSend(objc.Object, "newCommandQueue", .{});

        // Set device on layer
        layer.msgSend(void, "setDevice:", .{device.value});

        // Set drawable size on layer (physical pixels)
        const drawable_size = mtl.CGSize{
            .width = size.width * scale_factor,
            .height = size.height * scale_factor,
        };
        layer.msgSend(void, "setDrawableSize:", .{drawable_size});

        var self = Self{
            .device = device,
            .command_queue = command_queue,
            .layer = layer,
            .quad_pipeline_state = null,
            .quad_unit_vertex_buffer = null,
            .quad_instance_buffer = null,
            .quad_instance_capacity = 0,
            .shadow_pipeline_state = null,
            .shadow_instance_buffer = null,
            .shadow_instance_capacity = 0,
            .text_pipeline_state = null, // Initialize as null first
            .msaa_texture = null,
            .size = size,
            .scale_factor = scale_factor,
            .sample_count = 4, // MSAA 4x
            .unified_memory = unified_memory,
        };

        try self.createMSAATexture();
        try self.setupQuadPipeline();
        try self.setupShadowPipeline();

        // Initialize text pipeline AFTER we know pixel format and sample count
        self.text_pipeline_state = text_pipeline.TextPipeline.init(
            device,
            mtl.MTLPixelFormat.bgra8unorm,
            self.sample_count,
        ) catch null;

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

        // Create 2D multisample texture descriptor
        const desc = MTLTextureDescriptor.msgSend(
            objc.Object,
            "texture2DDescriptorWithPixelFormat:width:height:mipmapped:",
            .{
                @intFromEnum(mtl.MTLPixelFormat.bgra8unorm),
                @as(c_ulong, @intFromFloat(self.size.width * self.scale_factor)),
                @as(c_ulong, @intFromFloat(self.size.height * self.scale_factor)),
                false,
            },
        );

        // Set texture type to 2DMultisample
        desc.msgSend(void, "setTextureType:", .{@intFromEnum(mtl.MTLTextureType.type_2d_multisample)});
        desc.msgSend(void, "setSampleCount:", .{@as(c_ulong, self.sample_count)});

        // Set texture usage
        const usage = mtl.MTLTextureUsage.render_target_only;
        desc.msgSend(void, "setUsage:", .{@as(c_ulong, @bitCast(usage))});

        // Use memoryless on unified memory (Apple Silicon)
        // MSAA textures are only needed during the render pass
        const storage_mode: mtl.MTLStorageMode = if (self.unified_memory)
            .memoryless // No backing memory needed!
        else
            .private; // GPU-only memory for discrete GPUs

        desc.msgSend(void, "setStorageMode:", .{@intFromEnum(storage_mode)});

        const texture_ptr = self.device.msgSend(?*anyopaque, "newTextureWithDescriptor:", .{desc.value});
        if (texture_ptr == null) {
            return error.MSAATextureCreationFailed;
        }
        self.msaa_texture = objc.Object.fromId(texture_ptr);
    }

    fn setupShadowPipeline(self: *Self) !void {
        const NSString = objc.getClass("NSString") orelse return error.ClassNotFound;
        const source_str = NSString.msgSend(
            objc.Object,
            "stringWithUTF8String:",
            .{shadow_shader.shadow_shader_source.ptr},
        );

        const library_ptr = self.device.msgSend(
            ?*anyopaque,
            "newLibraryWithSource:options:error:",
            .{ source_str.value, @as(?*anyopaque, null), @as(?*anyopaque, null) },
        );
        if (library_ptr == null) {
            std.debug.print("Failed to compile shadow shader\n", .{});
            return error.ShaderCompilationFailed;
        }
        const library = objc.Object.fromId(library_ptr);
        defer library.msgSend(void, "release", .{});

        // Get vertex and fragment functions
        const vertex_name = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"shadow_vertex"});
        const fragment_name = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"shadow_fragment"});

        const vertex_fn = library.msgSend(objc.Object, "newFunctionWithName:", .{vertex_name.value});
        const fragment_fn = library.msgSend(objc.Object, "newFunctionWithName:", .{fragment_name.value});
        defer vertex_fn.msgSend(void, "release", .{});
        defer fragment_fn.msgSend(void, "release", .{});

        // Create pipeline descriptor
        const MTLRenderPipelineDescriptor = objc.getClass("MTLRenderPipelineDescriptor") orelse
            return error.ClassNotFound;
        const desc = MTLRenderPipelineDescriptor.msgSend(objc.Object, "alloc", .{})
            .msgSend(objc.Object, "init", .{});
        defer desc.msgSend(void, "release", .{});

        desc.msgSend(void, "setVertexFunction:", .{vertex_fn.value});
        desc.msgSend(void, "setFragmentFunction:", .{fragment_fn.value});
        desc.msgSend(void, "setSampleCount:", .{@as(c_ulong, self.sample_count)});

        // Configure blending for transparency
        const color_attachments = desc.msgSend(objc.Object, "colorAttachments", .{});
        const attachment0 = color_attachments.msgSend(objc.Object, "objectAtIndexedSubscript:", .{@as(c_ulong, 0)});
        attachment0.msgSend(void, "setPixelFormat:", .{@intFromEnum(mtl.MTLPixelFormat.bgra8unorm)});
        attachment0.msgSend(void, "setBlendingEnabled:", .{true});
        attachment0.msgSend(void, "setSourceRGBBlendFactor:", .{@intFromEnum(mtl.MTLBlendFactor.source_alpha)});
        attachment0.msgSend(void, "setDestinationRGBBlendFactor:", .{@intFromEnum(mtl.MTLBlendFactor.one_minus_source_alpha)});
        attachment0.msgSend(void, "setSourceAlphaBlendFactor:", .{@intFromEnum(mtl.MTLBlendFactor.one)});
        attachment0.msgSend(void, "setDestinationAlphaBlendFactor:", .{@intFromEnum(mtl.MTLBlendFactor.one_minus_source_alpha)});

        // Create pipeline state
        const pipeline_ptr = self.device.msgSend(
            ?*anyopaque,
            "newRenderPipelineStateWithDescriptor:error:",
            .{ desc.value, @as(?*anyopaque, null) },
        );
        if (pipeline_ptr == null) {
            return error.PipelineCreationFailed;
        }
        self.shadow_pipeline_state = objc.Object.fromId(pipeline_ptr);

        std.debug.print("Shadow pipeline created successfully\n", .{});
    }

    fn setupQuadPipeline(self: *Self) !void {
        const NSString = objc.getClass("NSString") orelse return error.ClassNotFound;
        const source_str = NSString.msgSend(
            objc.Object,
            "stringWithUTF8String:",
            .{quad_shader.quad_shader_source.ptr},
        );

        // Compile shader library
        const library_ptr = self.device.msgSend(
            ?*anyopaque,
            "newLibraryWithSource:options:error:",
            .{ source_str.value, @as(?*anyopaque, null), @as(?*anyopaque, null) },
        );
        if (library_ptr == null) {
            std.debug.print("Failed to compile quad shader library\n", .{});
            return error.ShaderCompilationFailed;
        }
        const library = objc.Object.fromId(library_ptr);
        defer library.msgSend(void, "release", .{});

        // Get vertex and fragment functions
        const vertex_name = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"quad_vertex"});
        const fragment_name = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"quad_fragment"});

        const vertex_fn_ptr = library.msgSend(?*anyopaque, "newFunctionWithName:", .{vertex_name.value});
        const fragment_fn_ptr = library.msgSend(?*anyopaque, "newFunctionWithName:", .{fragment_name.value});

        if (vertex_fn_ptr == null or fragment_fn_ptr == null) {
            std.debug.print("Failed to find quad shader functions\n", .{});
            return error.ShaderFunctionNotFound;
        }
        const vertex_fn = objc.Object.fromId(vertex_fn_ptr);
        const fragment_fn = objc.Object.fromId(fragment_fn_ptr);
        defer vertex_fn.msgSend(void, "release", .{});
        defer fragment_fn.msgSend(void, "release", .{});

        // Create pipeline descriptor
        const MTLRenderPipelineDescriptor = objc.getClass("MTLRenderPipelineDescriptor") orelse
            return error.ClassNotFound;
        const pipeline_desc = MTLRenderPipelineDescriptor.msgSend(objc.Object, "alloc", .{});
        const pipeline_desc_init = pipeline_desc.msgSend(objc.Object, "init", .{});

        pipeline_desc_init.msgSend(void, "setVertexFunction:", .{vertex_fn.value});
        pipeline_desc_init.msgSend(void, "setFragmentFunction:", .{fragment_fn.value});
        pipeline_desc_init.msgSend(void, "setSampleCount:", .{@as(c_ulong, self.sample_count)});

        // Set pixel format and blending
        const color_attachments = pipeline_desc_init.msgSend(objc.Object, "colorAttachments", .{});
        const color_attachment_0 = color_attachments.msgSend(objc.Object, "objectAtIndexedSubscript:", .{@as(c_ulong, 0)});
        color_attachment_0.msgSend(void, "setPixelFormat:", .{@intFromEnum(mtl.MTLPixelFormat.bgra8unorm)});

        // Enable alpha blending
        color_attachment_0.msgSend(void, "setBlendingEnabled:", .{true});
        color_attachment_0.msgSend(void, "setSourceRGBBlendFactor:", .{@intFromEnum(mtl.MTLBlendFactor.source_alpha)});
        color_attachment_0.msgSend(void, "setDestinationRGBBlendFactor:", .{@intFromEnum(mtl.MTLBlendFactor.one_minus_source_alpha)});
        color_attachment_0.msgSend(void, "setSourceAlphaBlendFactor:", .{@intFromEnum(mtl.MTLBlendFactor.one)});
        color_attachment_0.msgSend(void, "setDestinationAlphaBlendFactor:", .{@intFromEnum(mtl.MTLBlendFactor.one_minus_source_alpha)});

        // Create pipeline state
        const pipeline_ptr = self.device.msgSend(
            ?*anyopaque,
            "newRenderPipelineStateWithDescriptor:error:",
            .{ pipeline_desc_init.value, @as(?*anyopaque, null) },
        );
        if (pipeline_ptr == null) {
            return error.PipelineCreationFailed;
        }
        self.quad_pipeline_state = objc.Object.fromId(pipeline_ptr);

        const buffer_storage: mtl.MTLResourceOptions = if (self.unified_memory)
            .{ .storage_mode = .shared }
        else
            .{ .storage_mode = .managed };

        // Create unit vertex buffer (6 vertices for 2 triangles forming a quad)
        const buffer_ptr = self.device.msgSend(
            ?*anyopaque,
            "newBufferWithBytes:length:options:",
            .{
                @as(*const anyopaque, @ptrCast(&quad_shader.unit_vertices)),
                @as(c_ulong, @sizeOf(@TypeOf(quad_shader.unit_vertices))),
                @as(c_ulong, @bitCast(buffer_storage)),
            },
        );
        if (buffer_ptr == null) {
            return error.BufferCreationFailed;
        }
        self.quad_unit_vertex_buffer = objc.Object.fromId(buffer_ptr);

        // Pre-allocate instance buffer
        try self.ensureQuadCapacity(INITIAL_QUAD_CAPACITY);
    }

    fn ensureQuadCapacity(self: *Self, count: usize) !void {
        if (count <= self.quad_instance_capacity) return;

        // Release old buffer
        if (self.quad_instance_buffer) |buf| {
            buf.msgSend(void, "release", .{});
        }

        // Allocate new buffer with room to grow
        const new_capacity = @max(count, self.quad_instance_capacity * 2);
        const buffer_size = new_capacity * @sizeOf(scene_mod.Quad);

        // Use shared storage on unified memory (zero-copy!)
        const storage_options: mtl.MTLResourceOptions = if (self.unified_memory)
            .{ .storage_mode = .shared } // CPU + GPU same memory
        else
            .{ .storage_mode = .managed }; // Needs explicit sync

        const buffer_ptr = self.device.msgSend(
            ?*anyopaque,
            "newBufferWithLength:options:",
            .{
                @as(c_ulong, buffer_size),
                @as(c_ulong, @bitCast(storage_options)),
            },
        );
        if (buffer_ptr == null) {
            return error.BufferCreationFailed;
        }

        self.quad_instance_buffer = objc.Object.fromId(buffer_ptr);
        self.quad_instance_capacity = new_capacity;
    }

    pub fn deinit(self: *Self) void {
        if (self.msaa_texture) |tex| tex.msgSend(void, "release", .{});
        if (self.quad_pipeline_state) |ps| ps.msgSend(void, "release", .{});
        if (self.quad_unit_vertex_buffer) |vb| vb.msgSend(void, "release", .{});
        if (self.quad_instance_buffer) |ib| ib.msgSend(void, "release", .{});
        if (self.text_pipeline_state) |*tp| tp.deinit();
        self.command_queue.msgSend(void, "release", .{});
        self.device.msgSend(void, "release", .{});
    }

    pub fn clear(self: *Self, color: geometry.Color) void {
        self.render(color);
    }

    pub fn render(self: *Self, clear_color: geometry.Color) void {
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

        color_attachment_0.msgSend(void, "setTexture:", .{msaa_tex.value});
        color_attachment_0.msgSend(void, "setResolveTexture:", .{resolve_texture.value});
        color_attachment_0.msgSend(void, "setLoadAction:", .{@intFromEnum(mtl.MTLLoadAction.clear)});
        color_attachment_0.msgSend(void, "setStoreAction:", .{@intFromEnum(mtl.MTLStoreAction.multisample_resolve)});
        color_attachment_0.msgSend(void, "setClearColor:", .{mtl.MTLClearColor.fromColor(clear_color)});

        const command_buffer = self.command_queue.msgSend(objc.Object, "commandBuffer", .{});
        const encoder_ptr = command_buffer.msgSend(?*anyopaque, "renderCommandEncoderWithDescriptor:", .{render_pass.value});
        if (encoder_ptr == null) return;
        const encoder = objc.Object.fromId(encoder_ptr);

        encoder.msgSend(void, "endEncoding", .{});
        command_buffer.msgSend(void, "presentDrawable:", .{drawable.value});
        command_buffer.msgSend(void, "commit", .{});
    }

    pub fn renderScene(self: *Self, s: *const scene_mod.Scene, clear_color: geometry.Color) !void {
        const shadows = s.getShadows();
        const quads = s.getQuads();

        if (shadows.len == 0 and quads.len == 0) {
            self.render(clear_color);
            return;
        }

        // Begin rendering - get drawable and textures
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

        color_attachment_0.msgSend(void, "setTexture:", .{msaa_tex.value});
        color_attachment_0.msgSend(void, "setResolveTexture:", .{resolve_texture.value});
        color_attachment_0.msgSend(void, "setLoadAction:", .{@intFromEnum(mtl.MTLLoadAction.clear)});
        color_attachment_0.msgSend(void, "setStoreAction:", .{@intFromEnum(mtl.MTLStoreAction.multisample_resolve)});
        color_attachment_0.msgSend(void, "setClearColor:", .{mtl.MTLClearColor.fromColor(clear_color)});

        const command_buffer = self.command_queue.msgSend(objc.Object, "commandBuffer", .{});
        const encoder_ptr = command_buffer.msgSend(?*anyopaque, "renderCommandEncoderWithDescriptor:", .{render_pass.value});
        if (encoder_ptr == null) return;
        const encoder = objc.Object.fromId(encoder_ptr);

        // =========================================================================
        // COMMON SETUP - viewport and shared data (BEFORE any drawing)
        // =========================================================================
        const viewport = mtl.MTLViewport{
            .x = 0,
            .y = 0,
            .width = self.size.width * self.scale_factor,
            .height = self.size.height * self.scale_factor,
            .znear = 0,
            .zfar = 1,
        };
        encoder.msgSend(void, "setViewport:", .{viewport});

        const viewport_size: [2]f32 = .{
            @floatCast(self.size.width),
            @floatCast(self.size.height),
        };

        // Unit vertices buffer is shared between shadows and quads
        const unit_verts = self.quad_unit_vertex_buffer orelse {
            encoder.msgSend(void, "endEncoding", .{});
            return;
        };

        // =========================================================================
        // DRAW SHADOWS (first - they render behind everything)
        // =========================================================================
        if (shadows.len > 0) {
            if (self.shadow_pipeline_state) |pipeline| {
                encoder.msgSend(void, "setRenderPipelineState:", .{pipeline.value});

                // Buffer 0: unit vertices
                encoder.msgSend(void, "setVertexBuffer:offset:atIndex:", .{
                    unit_verts.value,
                    @as(c_ulong, 0),
                    @as(c_ulong, 0),
                });

                // Buffer 1: shadow instances
                encoder.msgSend(void, "setVertexBytes:length:atIndex:", .{
                    @as(*const anyopaque, @ptrCast(shadows.ptr)),
                    @as(c_ulong, shadows.len * @sizeOf(scene_mod.Shadow)),
                    @as(c_ulong, 1),
                });

                // Buffer 2: viewport size
                encoder.msgSend(void, "setVertexBytes:length:atIndex:", .{
                    @as(*const anyopaque, @ptrCast(&viewport_size)),
                    @as(c_ulong, @sizeOf([2]f32)),
                    @as(c_ulong, 2),
                });

                // Draw instanced shadows (6 vertices per shadow)
                encoder.msgSend(void, "drawPrimitives:vertexStart:vertexCount:instanceCount:", .{
                    @intFromEnum(mtl.MTLPrimitiveType.triangle),
                    @as(c_ulong, 0),
                    @as(c_ulong, 6),
                    @as(c_ulong, shadows.len),
                });
            }
        }

        // =========================================================================
        // DRAW QUADS (on top of shadows)
        // =========================================================================
        if (quads.len > 0) {
            if (self.quad_pipeline_state) |pipeline| {
                encoder.msgSend(void, "setRenderPipelineState:", .{pipeline.value});

                // Buffer 0: unit vertices (same buffer, just re-bind after pipeline change)
                encoder.msgSend(void, "setVertexBuffer:offset:atIndex:", .{
                    unit_verts.value,
                    @as(c_ulong, 0),
                    @as(c_ulong, 0),
                });

                // Buffer 1: quad instances
                encoder.msgSend(void, "setVertexBytes:length:atIndex:", .{
                    @as(*const anyopaque, @ptrCast(quads.ptr)),
                    @as(c_ulong, quads.len * @sizeOf(scene_mod.Quad)),
                    @as(c_ulong, 1),
                });

                // Buffer 2: viewport size
                encoder.msgSend(void, "setVertexBytes:length:atIndex:", .{
                    @as(*const anyopaque, @ptrCast(&viewport_size)),
                    @as(c_ulong, @sizeOf([2]f32)),
                    @as(c_ulong, 2),
                });

                // Draw instanced quads (6 vertices per quad)
                encoder.msgSend(void, "drawPrimitives:vertexStart:vertexCount:instanceCount:", .{
                    @intFromEnum(mtl.MTLPrimitiveType.triangle),
                    @as(c_ulong, 0),
                    @as(c_ulong, 6),
                    @as(c_ulong, quads.len),
                });
            }
        }

        if (self.text_pipeline_state) |*tp| {
            const glyphs = s.getGlyphs();
            if (glyphs.len > 0) {
                tp.render(encoder, glyphs, .{ @as(f32, @floatCast(self.size.width)), @as(f32, @floatCast(self.size.height)) }) catch {};
            }
        }

        // =========================================================================
        // FINISH
        // =========================================================================
        encoder.msgSend(void, "endEncoding", .{});
        command_buffer.msgSend(void, "presentDrawable:", .{drawable.value});
        command_buffer.msgSend(void, "commit", .{});
    }

    /// Synchronous clear - waits for completion, used during live resize
    pub fn clearSynchronous(self: *Self, color: geometry.Color) void {
        self.renderSynchronous(color);
    }

    /// Synchronous render - presents with CATransaction for smooth resize
    fn renderSynchronous(self: *Self, clear_color: geometry.Color) void {
        const CATransaction = objc.getClass("CATransaction") orelse return;

        // Begin CA transaction
        CATransaction.msgSend(void, "begin", .{});
        CATransaction.msgSend(void, "setDisableActions:", .{true});

        const drawable_ptr = self.layer.msgSend(?*anyopaque, "nextDrawable", .{});
        if (drawable_ptr == null) {
            CATransaction.msgSend(void, "commit", .{});
            return;
        }
        const drawable = objc.Object.fromId(drawable_ptr);

        const texture_ptr = drawable.msgSend(?*anyopaque, "texture", .{});
        if (texture_ptr == null) {
            CATransaction.msgSend(void, "commit", .{});
            return;
        }
        const resolve_texture = objc.Object.fromId(texture_ptr);

        const msaa_tex = self.msaa_texture orelse {
            CATransaction.msgSend(void, "commit", .{});
            return;
        };

        const MTLRenderPassDescriptor = objc.getClass("MTLRenderPassDescriptor") orelse {
            CATransaction.msgSend(void, "commit", .{});
            return;
        };
        const render_pass = MTLRenderPassDescriptor.msgSend(objc.Object, "renderPassDescriptor", .{});

        const color_attachments = render_pass.msgSend(objc.Object, "colorAttachments", .{});
        const color_attachment_0 = color_attachments.msgSend(objc.Object, "objectAtIndexedSubscript:", .{@as(c_ulong, 0)});

        color_attachment_0.msgSend(void, "setTexture:", .{msaa_tex.value});
        color_attachment_0.msgSend(void, "setResolveTexture:", .{resolve_texture.value});
        color_attachment_0.msgSend(void, "setLoadAction:", .{@intFromEnum(mtl.MTLLoadAction.clear)});
        color_attachment_0.msgSend(void, "setStoreAction:", .{@intFromEnum(mtl.MTLStoreAction.multisample_resolve)});
        color_attachment_0.msgSend(void, "setClearColor:", .{mtl.MTLClearColor.fromColor(clear_color)});

        const command_buffer = self.command_queue.msgSend(objc.Object, "commandBuffer", .{});
        const encoder_ptr = command_buffer.msgSend(?*anyopaque, "renderCommandEncoderWithDescriptor:", .{render_pass.value});
        if (encoder_ptr == null) {
            CATransaction.msgSend(void, "commit", .{});
            return;
        }
        const encoder = objc.Object.fromId(encoder_ptr);

        encoder.msgSend(void, "endEncoding", .{});

        // Wait until scheduled, then present via drawable (layer has presentsWithTransaction=YES)
        command_buffer.msgSend(void, "commit", .{});
        command_buffer.msgSend(void, "waitUntilScheduled", .{});
        drawable.msgSend(void, "present", .{});

        // Commit CA transaction
        CATransaction.msgSend(void, "commit", .{});
    }

    /// Synchronous scene render - for live resize
    pub fn renderSceneSynchronous(self: *Self, s: *const scene_mod.Scene, clear_color: geometry.Color) !void {
        const shadows = s.getShadows();
        const quads = s.getQuads();

        if (shadows.len == 0 and quads.len == 0) {
            self.renderSynchronous(clear_color);
            return;
        }

        const CATransaction = objc.getClass("CATransaction") orelse return;

        // Begin CA transaction
        CATransaction.msgSend(void, "begin", .{});
        CATransaction.msgSend(void, "setDisableActions:", .{true});

        const drawable_ptr = self.layer.msgSend(?*anyopaque, "nextDrawable", .{});
        if (drawable_ptr == null) {
            CATransaction.msgSend(void, "commit", .{});
            return;
        }
        const drawable = objc.Object.fromId(drawable_ptr);

        const texture_ptr = drawable.msgSend(?*anyopaque, "texture", .{});
        if (texture_ptr == null) {
            CATransaction.msgSend(void, "commit", .{});
            return;
        }
        const resolve_texture = objc.Object.fromId(texture_ptr);

        const msaa_tex = self.msaa_texture orelse {
            CATransaction.msgSend(void, "commit", .{});
            return;
        };

        const MTLRenderPassDescriptor = objc.getClass("MTLRenderPassDescriptor") orelse {
            CATransaction.msgSend(void, "commit", .{});
            return;
        };
        const render_pass = MTLRenderPassDescriptor.msgSend(objc.Object, "renderPassDescriptor", .{});

        const color_attachments = render_pass.msgSend(objc.Object, "colorAttachments", .{});
        const color_attachment_0 = color_attachments.msgSend(objc.Object, "objectAtIndexedSubscript:", .{@as(c_ulong, 0)});

        color_attachment_0.msgSend(void, "setTexture:", .{msaa_tex.value});
        color_attachment_0.msgSend(void, "setResolveTexture:", .{resolve_texture.value});
        color_attachment_0.msgSend(void, "setLoadAction:", .{@intFromEnum(mtl.MTLLoadAction.clear)});
        color_attachment_0.msgSend(void, "setStoreAction:", .{@intFromEnum(mtl.MTLStoreAction.multisample_resolve)});
        color_attachment_0.msgSend(void, "setClearColor:", .{mtl.MTLClearColor.fromColor(clear_color)});

        const command_buffer = self.command_queue.msgSend(objc.Object, "commandBuffer", .{});
        const encoder_ptr = command_buffer.msgSend(?*anyopaque, "renderCommandEncoderWithDescriptor:", .{render_pass.value});
        if (encoder_ptr == null) {
            CATransaction.msgSend(void, "commit", .{});
            return;
        }
        const encoder = objc.Object.fromId(encoder_ptr);

        // =========================================================================
        // COMMON SETUP
        // =========================================================================
        const viewport = mtl.MTLViewport{
            .x = 0,
            .y = 0,
            .width = self.size.width * self.scale_factor,
            .height = self.size.height * self.scale_factor,
            .znear = 0,
            .zfar = 1,
        };
        encoder.msgSend(void, "setViewport:", .{viewport});

        const viewport_size: [2]f32 = .{
            @floatCast(self.size.width),
            @floatCast(self.size.height),
        };

        const unit_verts = self.quad_unit_vertex_buffer orelse {
            encoder.msgSend(void, "endEncoding", .{});
            CATransaction.msgSend(void, "commit", .{});
            return;
        };

        // =========================================================================
        // DRAW SHADOWS (first)
        // =========================================================================
        if (shadows.len > 0) {
            if (self.shadow_pipeline_state) |pipeline| {
                encoder.msgSend(void, "setRenderPipelineState:", .{pipeline.value});

                encoder.msgSend(void, "setVertexBuffer:offset:atIndex:", .{
                    unit_verts.value,
                    @as(c_ulong, 0),
                    @as(c_ulong, 0),
                });

                encoder.msgSend(void, "setVertexBytes:length:atIndex:", .{
                    @as(*const anyopaque, @ptrCast(shadows.ptr)),
                    @as(c_ulong, shadows.len * @sizeOf(scene_mod.Shadow)),
                    @as(c_ulong, 1),
                });

                encoder.msgSend(void, "setVertexBytes:length:atIndex:", .{
                    @as(*const anyopaque, @ptrCast(&viewport_size)),
                    @as(c_ulong, @sizeOf([2]f32)),
                    @as(c_ulong, 2),
                });

                encoder.msgSend(void, "drawPrimitives:vertexStart:vertexCount:instanceCount:", .{
                    @intFromEnum(mtl.MTLPrimitiveType.triangle),
                    @as(c_ulong, 0),
                    @as(c_ulong, 6),
                    @as(c_ulong, shadows.len),
                });
            }
        }

        // =========================================================================
        // DRAW QUADS (on top)
        // =========================================================================
        if (quads.len > 0) {
            if (self.quad_pipeline_state) |pipeline| {
                encoder.msgSend(void, "setRenderPipelineState:", .{pipeline.value});

                encoder.msgSend(void, "setVertexBuffer:offset:atIndex:", .{
                    unit_verts.value,
                    @as(c_ulong, 0),
                    @as(c_ulong, 0),
                });

                encoder.msgSend(void, "setVertexBytes:length:atIndex:", .{
                    @as(*const anyopaque, @ptrCast(quads.ptr)),
                    @as(c_ulong, quads.len * @sizeOf(scene_mod.Quad)),
                    @as(c_ulong, 1),
                });

                encoder.msgSend(void, "setVertexBytes:length:atIndex:", .{
                    @as(*const anyopaque, @ptrCast(&viewport_size)),
                    @as(c_ulong, @sizeOf([2]f32)),
                    @as(c_ulong, 2),
                });

                encoder.msgSend(void, "drawPrimitives:vertexStart:vertexCount:instanceCount:", .{
                    @intFromEnum(mtl.MTLPrimitiveType.triangle),
                    @as(c_ulong, 0),
                    @as(c_ulong, 6),
                    @as(c_ulong, quads.len),
                });
            }
        }

        if (self.text_pipeline_state) |*tp| {
            const glyphs = s.getGlyphs();
            if (glyphs.len > 0) {
                tp.render(encoder, glyphs, .{ @as(f32, @floatCast(self.size.width)), @as(f32, @floatCast(self.size.height)) }) catch {};
            }
        }

        // =========================================================================
        // FINISH
        // =========================================================================
        encoder.msgSend(void, "endEncoding", .{});

        // Wait until scheduled, then present via drawable
        command_buffer.msgSend(void, "commit", .{});
        command_buffer.msgSend(void, "waitUntilScheduled", .{});
        drawable.msgSend(void, "present", .{});

        // Commit CA transaction
        CATransaction.msgSend(void, "commit", .{});
    }

    pub fn resize(self: *Self, size: geometry.Size(f64), scale_factor: f64) void {
        self.size = size;
        self.scale_factor = scale_factor;
        self.layer.msgSend(void, "setDrawableSize:", .{mtl.CGSize{
            .width = size.width * scale_factor,
            .height = size.height * scale_factor,
        }});
        self.createMSAATexture() catch |err| {
            std.debug.print("Failed to recreate MSAA texture on resize: {}\n", .{err});
        };
    }

    /// Update the text atlas texture (lazy - checks generation)
    pub fn updateTextAtlas(self: *Self, atlas: *const Atlas) !void {
        if (self.text_pipeline_state) |*tp| {
            try tp.updateAtlas(atlas);
        }
    }

    // =========================================================================
    // Scissor/Clip Region Support
    // =========================================================================

    /// Scissor rectangle in pixels
    pub const ScissorRect = struct {
        x: c_ulong,
        y: c_ulong,
        width: c_ulong,
        height: c_ulong,
    };

    /// Set scissor rectangle on encoder for clipping
    /// Call this between setRenderPipelineState and draw calls
    pub fn setScissor(encoder: objc.Object, rect: ScissorRect) void {
        encoder.msgSend(void, "setScissorRect:", .{rect});
    }

    /// Convert layout bounding box to scissor rect
    /// Accounts for Retina scale factor and Metal's bottom-left origin
    pub fn boundsToScissorRect(
        x: f32,
        y: f32,
        width: f32,
        height: f32,
        viewport_height: f32,
        scale: f64,
    ) ScissorRect {
        // Metal scissor Y is from bottom, but our layout Y is from top
        const scale_f: f32 = @floatCast(scale);
        const flipped_y = viewport_height - y - height;

        return .{
            .x = @intFromFloat(@max(0, x * scale_f)),
            .y = @intFromFloat(@max(0, flipped_y * scale_f)),
            .width = @intFromFloat(@max(1, width * scale_f)),
            .height = @intFromFloat(@max(1, height * scale_f)),
        };
    }

    /// Reset scissor to full viewport
    pub fn resetScissor(self: *const Self, encoder: objc.Object) void {
        const rect = ScissorRect{
            .x = 0,
            .y = 0,
            .width = @intFromFloat(self.size.width * self.scale_factor),
            .height = @intFromFloat(self.size.height * self.scale_factor),
        };
        encoder.msgSend(void, "setScissorRect:", .{rect});
    }

    /// Helper to set scissor from layout bounds
    pub fn setScissorFromBounds(
        self: *const Self,
        encoder: objc.Object,
        x: f32,
        y: f32,
        width: f32,
        height: f32,
    ) void {
        const rect = boundsToScissorRect(
            x,
            y,
            width,
            height,
            @floatCast(self.size.height),
            self.scale_factor,
        );
        setScissor(encoder, rect);
    }
};
