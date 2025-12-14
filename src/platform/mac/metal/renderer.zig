//! Metal Renderer - Main GPU rendering coordinator
//!
//! This module provides the high-level rendering API, delegating to specialized
//! modules for pipeline setup, scene rendering, and post-processing.

const std = @import("std");
const objc = @import("objc");

const geometry = @import("../../../core/geometry.zig");
const scene_mod = @import("../../../core/scene.zig");
const mtl = @import("api.zig");
const pipelines = @import("pipelines.zig");
const render_pass = @import("render_pass.zig");
const scene_renderer = @import("scene_renderer.zig");
const post_process = @import("post_process.zig");
const scissor = @import("scissor.zig");
const text_pipeline = @import("text.zig");
const custom_shader = @import("custom_shader.zig");
const Atlas = @import("../../../text/mod.zig").Atlas;

/// Vertex data: position (x, y) + color (r, g, b, a)
pub const Vertex = extern struct {
    position: [2]f32,
    color: [4]f32,
};

// Re-export scissor types for external use
pub const ScissorRect = scissor.ScissorRect;

pub const Renderer = struct {
    // Core Metal objects
    device: objc.Object,
    command_queue: objc.Object,
    layer: objc.Object,
    unified_memory: bool,

    // Pipeline states
    quad_pipeline_state: ?objc.Object,
    shadow_pipeline_state: ?objc.Object,
    text_pipeline_state: ?text_pipeline.TextPipeline,

    // Buffers
    quad_unit_vertex_buffer: ?objc.Object,

    // MSAA
    msaa_texture: ?objc.Object,
    sample_count: u32,

    // Viewport
    size: geometry.Size(f64),
    scale_factor: f64,

    // Custom shader support
    post_process_state: ?custom_shader.PostProcessState,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, layer: objc.Object, size: geometry.Size(f64), scale_factor: f64) !Self {
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
        layer.msgSend(void, "setDrawableSize:", .{mtl.CGSize{
            .width = size.width * scale_factor,
            .height = size.height * scale_factor,
        }});

        const sample_count: u32 = 4; // MSAA 4x

        var self = Self{
            .device = device,
            .command_queue = command_queue,
            .layer = layer,
            .unified_memory = unified_memory,
            .quad_pipeline_state = null,
            .shadow_pipeline_state = null,
            .text_pipeline_state = null,
            .quad_unit_vertex_buffer = null,
            .msaa_texture = null,
            .sample_count = sample_count,
            .size = size,
            .scale_factor = scale_factor,
            .post_process_state = null,
            .allocator = allocator,
        };

        // Initialize pipelines and textures
        self.msaa_texture = try pipelines.createMSAATexture(
            device,
            size.width,
            size.height,
            scale_factor,
            sample_count,
            unified_memory,
        );

        self.quad_pipeline_state = try pipelines.setupQuadPipeline(device, sample_count);
        self.shadow_pipeline_state = try pipelines.setupShadowPipeline(device, sample_count);
        self.quad_unit_vertex_buffer = try pipelines.createUnitVertexBuffer(device, unified_memory);

        // Initialize text pipeline
        self.text_pipeline_state = text_pipeline.TextPipeline.init(
            device,
            mtl.MTLPixelFormat.bgra8unorm,
            sample_count,
        ) catch null;

        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.msaa_texture) |tex| tex.msgSend(void, "release", .{});
        if (self.quad_pipeline_state) |ps| ps.msgSend(void, "release", .{});
        if (self.shadow_pipeline_state) |ps| ps.msgSend(void, "release", .{});
        if (self.quad_unit_vertex_buffer) |vb| vb.msgSend(void, "release", .{});
        if (self.text_pipeline_state) |*tp| tp.deinit();
        if (self.post_process_state) |*pp| pp.deinit();
        self.command_queue.msgSend(void, "release", .{});
        self.device.msgSend(void, "release", .{});
    }

    // =========================================================================
    // Public Rendering API
    // =========================================================================

    pub fn clear(self: *Self, color: geometry.Color) void {
        self.renderInternal(color, false);
    }

    pub fn clearSynchronous(self: *Self, color: geometry.Color) void {
        self.renderInternal(color, true);
    }

    pub fn render(self: *Self, clear_color: geometry.Color) void {
        self.renderInternal(clear_color, false);
    }

    pub fn renderScene(self: *Self, scene: *const scene_mod.Scene, clear_color: geometry.Color) !void {
        try self.renderSceneInternal(scene, clear_color, false);
    }

    pub fn renderSceneSynchronous(self: *Self, scene: *const scene_mod.Scene, clear_color: geometry.Color) !void {
        try self.renderSceneInternal(scene, clear_color, true);
    }

    pub fn renderSceneWithPostProcess(
        self: *Self,
        scene: *const scene_mod.Scene,
        clear_color: geometry.Color,
    ) !void {
        var pp = &(self.post_process_state orelse {
            try self.renderScene(scene, clear_color);
            return;
        });

        if (!pp.hasShaders()) {
            try self.renderScene(scene, clear_color);
            return;
        }

        // Ensure textures are created at the correct size
        const width: u32 = @intFromFloat(self.size.width * self.scale_factor);
        const height: u32 = @intFromFloat(self.size.height * self.scale_factor);
        try pp.ensureSize(width, height);

        // Update shader uniforms (time, resolution, etc.)
        pp.updateTiming();
        pp.uploadUniforms();

        // Step 1: Render scene to front texture
        try post_process.renderSceneToTexture(
            self.command_queue,
            scene,
            clear_color,
            pp.front_texture.?,
            self.msaa_texture.?,
            self.quad_unit_vertex_buffer.?,
            self.shadow_pipeline_state,
            self.quad_pipeline_state,
            if (self.text_pipeline_state) |*tp| tp else null,
            self.size,
            self.scale_factor,
        );

        // Step 2: Run shader passes (ping-pong between textures)
        for (pp.pipelines.items) |shader_pipeline| {
            try post_process.runPostProcessPass(
                self.command_queue,
                shader_pipeline,
                pp.front_texture.?,
                pp.back_texture.?,
                pp.uniform_buffer.?,
                pp.sampler.?,
                self.size,
                self.scale_factor,
            );
            pp.swapTextures();
        }

        // Step 3: Blit final result to screen
        // After all swaps, the final result is in front_texture
        try post_process.blitToScreen(
            self.command_queue,
            self.layer,
            pp.front_texture.?, // Changed from back_texture to front_texture
            self.size,
            self.scale_factor,
        );
    }

    // =========================================================================
    // Custom Shader Support
    // =========================================================================

    pub fn initPostProcess(self: *Self) !void {
        if (self.post_process_state != null) return;
        self.post_process_state = custom_shader.PostProcessState.init(self.allocator, self.device);
    }

    pub fn addCustomShader(self: *Self, shader_source: []const u8, name: []const u8) !void {
        if (self.post_process_state == null) {
            try self.initPostProcess();
        }
        try self.post_process_state.?.addShader(
            shader_source,
            name,
            mtl.MTLPixelFormat.bgra8unorm,
            1,
        );
    }

    pub fn hasCustomShaders(self: *const Self) bool {
        if (self.post_process_state) |pp| {
            return pp.hasShaders();
        }
        return false;
    }

    pub fn getPostProcess(self: *Self) ?*custom_shader.PostProcessState {
        return if (self.post_process_state) |*pp| pp else null;
    }

    // =========================================================================
    // Resize & Atlas
    // =========================================================================

    pub fn resize(self: *Self, size: geometry.Size(f64), scale_factor: f64) void {
        self.size = size;
        self.scale_factor = scale_factor;
        self.layer.msgSend(void, "setDrawableSize:", .{mtl.CGSize{
            .width = size.width * scale_factor,
            .height = size.height * scale_factor,
        }});

        // Recreate MSAA texture
        if (self.msaa_texture) |tex| tex.msgSend(void, "release", .{});
        self.msaa_texture = pipelines.createMSAATexture(
            self.device,
            size.width,
            size.height,
            scale_factor,
            self.sample_count,
            self.unified_memory,
        ) catch |err| {
            std.debug.print("Failed to recreate MSAA texture on resize: {}\n", .{err});
            return;
        };
    }

    pub fn updateTextAtlas(self: *Self, atlas: *const Atlas) !void {
        if (self.text_pipeline_state) |*tp| {
            try tp.updateAtlas(atlas);
        }
    }

    // =========================================================================
    // Scissor Support
    // =========================================================================

    pub fn setScissor(encoder: objc.Object, rect: ScissorRect) void {
        scissor.setScissor(encoder, rect);
    }

    pub fn boundsToScissorRect(
        x: f32,
        y: f32,
        width: f32,
        height: f32,
        viewport_height: f32,
        scale: f64,
    ) ScissorRect {
        return scissor.boundsToScissorRect(x, y, width, height, viewport_height, scale);
    }

    pub fn resetScissor(self: *const Self, encoder: objc.Object) void {
        scissor.resetScissor(encoder, self.size.width, self.size.height, self.scale_factor);
    }

    pub fn setScissorFromBounds(
        self: *const Self,
        encoder: objc.Object,
        x: f32,
        y: f32,
        width: f32,
        height: f32,
    ) void {
        scissor.setScissorFromBounds(
            encoder,
            x,
            y,
            width,
            height,
            @floatCast(self.size.height),
            self.scale_factor,
        );
    }

    // =========================================================================
    // Internal Implementation
    // =========================================================================

    fn renderInternal(self: *Self, clear_color: geometry.Color, synchronous: bool) void {
        const ca_scope = if (synchronous) render_pass.CATransactionScope.begin() else null;
        defer if (ca_scope) |scope| scope.commit();

        const drawable_info = render_pass.getNextDrawable(self.layer) orelse {
            return;
        };

        const msaa_tex = self.msaa_texture orelse return;

        const rp = render_pass.createRenderPass(.{
            .msaa_texture = msaa_tex,
            .resolve_texture = drawable_info.texture,
            .clear_color = clear_color,
        }) orelse return;

        const command_buffer = self.command_queue.msgSend(objc.Object, "commandBuffer", .{});
        const encoder = render_pass.createEncoder(command_buffer, rp) orelse return;

        if (synchronous) {
            render_pass.finishAndPresentSync(encoder, command_buffer, drawable_info.drawable);
        } else {
            render_pass.finishAndPresent(encoder, command_buffer, drawable_info.drawable);
        }
    }

    fn renderSceneInternal(
        self: *Self,
        scene: *const scene_mod.Scene,
        clear_color: geometry.Color,
        synchronous: bool,
    ) !void {
        // Optional: Print stats every N frames for debugging
        // const stats = render_stats.getStats();
        // stats.reset();

        // Rotate to next instance buffer BEFORE rendering
        if (self.text_pipeline_state) |*tp| {
            tp.nextFrame();
        }

        const shadows = scene.getShadows();
        const quads = scene.getQuads();

        if (shadows.len == 0 and quads.len == 0) {
            self.renderInternal(clear_color, synchronous);
            return;
        }

        const ca_scope = if (synchronous) render_pass.CATransactionScope.begin() else null;
        defer if (ca_scope) |scope| scope.commit();

        const drawable_info = render_pass.getNextDrawable(self.layer) orelse return;
        const msaa_tex = self.msaa_texture orelse return;

        const rp = render_pass.createRenderPass(.{
            .msaa_texture = msaa_tex,
            .resolve_texture = drawable_info.texture,
            .clear_color = clear_color,
        }) orelse return;

        const command_buffer = self.command_queue.msgSend(objc.Object, "commandBuffer", .{});
        const encoder = render_pass.createEncoder(command_buffer, rp) orelse return;

        // Setup viewport
        render_pass.setViewport(encoder, self.size.width, self.size.height, self.scale_factor);

        const viewport_size: [2]f32 = .{
            @floatCast(self.size.width),
            @floatCast(self.size.height),
        };

        const unit_verts = self.quad_unit_vertex_buffer orelse {
            encoder.msgSend(void, "endEncoding", .{});
            return;
        };

        // Draw scene primitives (with stats if wanted)
        scene_renderer.drawScenePrimitivesWithStats(
            encoder,
            scene,
            unit_verts,
            viewport_size,
            self.shadow_pipeline_state,
            self.quad_pipeline_state,
            null, // or pass &stats for debugging
        );

        // Draw text
        if (self.text_pipeline_state) |*tp| {
            scene_renderer.drawText(tp, encoder, scene, viewport_size);
        }

        // Finish
        if (synchronous) {
            render_pass.finishAndPresentSync(encoder, command_buffer, drawable_info.drawable);
        } else {
            render_pass.finishAndPresent(encoder, command_buffer, drawable_info.drawable);
        }
    }
};
