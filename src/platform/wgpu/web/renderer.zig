//! WebRenderer - GPU rendering for WebAssembly/WebGPU
//!
//! Takes a gooey Scene and renders it to WebGPU. This is the web equivalent
//! of the Metal renderer on macOS.

const std = @import("std");
const imports = @import("imports.zig");
const unified = @import("../unified.zig");
const scene_mod = @import("../../../core/scene.zig");
const text_mod = @import("../../../text/mod.zig");
const custom_shader = @import("custom_shader.zig");

const Scene = scene_mod.Scene;
const TextSystem = text_mod.TextSystem;
const PostProcessState = custom_shader.PostProcessState;

// =============================================================================
// Constants
// =============================================================================

pub const MAX_PRIMITIVES: u32 = 4096;
pub const MAX_GLYPHS: u32 = 8192;

// =============================================================================
// GPU Types
// =============================================================================

pub const Uniforms = extern struct {
    viewport_width: f32,
    viewport_height: f32,
};

pub const GpuGlyph = extern struct {
    pos_x: f32 = 0,
    pos_y: f32 = 0,
    size_x: f32 = 0,
    size_y: f32 = 0,
    uv_left: f32 = 0,
    uv_top: f32 = 0,
    uv_right: f32 = 0,
    uv_bottom: f32 = 0,
    color_h: f32 = 0,
    color_s: f32 = 0,
    color_l: f32 = 1,
    color_a: f32 = 1,
    clip_x: f32 = 0,
    clip_y: f32 = 0,
    clip_width: f32 = 99999,
    clip_height: f32 = 99999,

    pub fn fromScene(g: scene_mod.GlyphInstance) GpuGlyph {
        return .{
            .pos_x = g.pos_x,
            .pos_y = g.pos_y,
            .size_x = g.size_x,
            .size_y = g.size_y,
            .uv_left = g.uv_left,
            .uv_top = g.uv_top,
            .uv_right = g.uv_right,
            .uv_bottom = g.uv_bottom,
            .color_h = g.color.h,
            .color_s = g.color.s,
            .color_l = g.color.l,
            .color_a = g.color.a,
            .clip_x = g.clip_x,
            .clip_y = g.clip_y,
            .clip_width = g.clip_width,
            .clip_height = g.clip_height,
        };
    }
};

// =============================================================================
// WebRenderer
// =============================================================================

pub const WebRenderer = struct {
    allocator: std.mem.Allocator,
    pipeline: u32 = 0,
    text_pipeline: u32 = 0,
    primitive_buffer: u32 = 0,
    uniform_buffer: u32 = 0,
    glyph_buffer: u32 = 0,
    bind_group: u32 = 0,
    text_bind_group: u32 = 0,
    atlas_texture: u32 = 0,
    sampler: u32 = 0,
    atlas_generation: u32 = 0,
    primitives: [MAX_PRIMITIVES]unified.Primitive = undefined,
    gpu_glyphs: [MAX_GLYPHS]GpuGlyph = undefined,
    initialized: bool = false,

    // Post-processing state for custom shaders
    post_process_state: ?PostProcessState = null,

    const Self = @This();

    const unified_shader = @embedFile("unified_wgsl");
    const text_shader = @embedFile("text_wgsl");

    pub fn init(allocator: std.mem.Allocator) !Self {
        var self = Self{
            .allocator = allocator,
        };

        const unified_module = imports.createShaderModule(unified_shader.ptr, unified_shader.len);
        const text_module = imports.createShaderModule(text_shader.ptr, text_shader.len);

        self.pipeline = imports.createRenderPipeline(unified_module, "vs_main", 7, "fs_main", 7);
        self.text_pipeline = imports.createRenderPipeline(text_module, "vs_main", 7, "fs_main", 7);

        const storage_copy = 0x0080 | 0x0008;
        const uniform_copy = 0x0040 | 0x0008;

        self.primitive_buffer = imports.createBuffer(@sizeOf(unified.Primitive) * MAX_PRIMITIVES, storage_copy);
        self.glyph_buffer = imports.createBuffer(@sizeOf(GpuGlyph) * MAX_GLYPHS, storage_copy);
        self.uniform_buffer = imports.createBuffer(@sizeOf(Uniforms), uniform_copy);

        const prim_bufs = [_]u32{ self.primitive_buffer, self.uniform_buffer };
        self.bind_group = imports.createBindGroup(self.pipeline, 0, &prim_bufs, 2);
        self.sampler = imports.createSampler();

        self.initialized = true;
        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.post_process_state) |*state| {
            state.deinit();
        }
    }

    /// Initialize post-processing state (lazy initialization)
    fn initPostProcess(self: *Self) !void {
        if (self.post_process_state != null) return;
        self.post_process_state = PostProcessState.init(self.allocator);
    }

    /// Add a custom WGSL shader for post-processing
    pub fn addCustomShader(self: *Self, shader_source: []const u8, name: []const u8) !void {
        try self.initPostProcess();
        if (self.post_process_state) |*state| {
            try state.addShader(shader_source, name);
            imports.log("Added shader, pipeline count: {}", .{state.pipelines.items.len});
        }
    }

    /// Check if we have custom shaders enabled
    pub fn hasCustomShaders(self: *const Self) bool {
        if (self.post_process_state) |*state| {
            return state.hasShaders();
        }
        return false;
    }

    pub fn uploadAtlas(self: *Self, text_system: *TextSystem) void {
        const atlas = text_system.getAtlas();
        const pixels = atlas.getData();
        const size = atlas.size;

        if (self.atlas_texture == 0) {
            self.atlas_texture = imports.createTexture(size, size, pixels.ptr, @intCast(pixels.len));
        }

        self.text_bind_group = imports.createTextBindGroup(
            self.text_pipeline,
            0,
            self.glyph_buffer,
            self.uniform_buffer,
            self.atlas_texture,
            self.sampler,
        );
    }

    pub fn syncAtlas(self: *Self, text_system: *TextSystem) void {
        const atlas = text_system.getAtlas();

        // Only update if generation changed
        if (atlas.generation == self.atlas_generation) return;

        if (self.atlas_texture != 0) {
            const pixels = atlas.getData();
            const size = atlas.size;
            imports.updateTexture(self.atlas_texture, size, size, pixels.ptr, @intCast(pixels.len));
            self.atlas_generation = atlas.generation;
        }
    }

    pub fn render(
        self: *Self,
        scene: *Scene,
        viewport_width: f32,
        viewport_height: f32,
        clear_r: f32,
        clear_g: f32,
        clear_b: f32,
        clear_a: f32,
    ) void {
        if (!self.initialized) return;

        const prim_count = unified.convertScene(scene, &self.primitives);

        var glyph_count: u32 = 0;
        for (scene.getGlyphs()) |g| {
            if (glyph_count >= MAX_GLYPHS) break;
            self.gpu_glyphs[glyph_count] = GpuGlyph.fromScene(g);
            glyph_count += 1;
        }

        const uniforms = Uniforms{ .viewport_width = viewport_width, .viewport_height = viewport_height };
        imports.writeBuffer(self.uniform_buffer, 0, std.mem.asBytes(&uniforms).ptr, @sizeOf(Uniforms));

        if (prim_count > 0) {
            imports.writeBuffer(
                self.primitive_buffer,
                0,
                std.mem.sliceAsBytes(self.primitives[0..prim_count]).ptr,
                @intCast(@sizeOf(unified.Primitive) * prim_count),
            );
        }

        if (glyph_count > 0) {
            imports.writeBuffer(
                self.glyph_buffer,
                0,
                std.mem.sliceAsBytes(self.gpu_glyphs[0..glyph_count]).ptr,
                @intCast(@sizeOf(GpuGlyph) * glyph_count),
            );
        }

        // Check if we need post-processing
        const has_post_process = if (self.post_process_state) |*state| state.hasShaders() else false;
        if (has_post_process) {
            // Render to offscreen texture first
            self.renderWithPostProcess(
                prim_count,
                glyph_count,
                viewport_width,
                viewport_height,
                clear_r,
                clear_g,
                clear_b,
                clear_a,
            );
        } else {
            // Render directly to screen
            self.renderDirect(prim_count, glyph_count, clear_r, clear_g, clear_b, clear_a);
        }
    }

    /// Render directly to the screen (no post-processing)
    fn renderDirect(
        self: *Self,
        prim_count: u32,
        glyph_count: u32,
        clear_r: f32,
        clear_g: f32,
        clear_b: f32,
        clear_a: f32,
    ) void {
        const texture_view = imports.getCurrentTextureView();
        imports.beginRenderPass(texture_view, clear_r, clear_g, clear_b, clear_a);

        if (prim_count > 0) {
            imports.setPipeline(self.pipeline);
            imports.setBindGroup(0, self.bind_group);
            imports.drawInstanced(6, prim_count);
        }

        if (glyph_count > 0 and self.text_bind_group != 0) {
            imports.setPipeline(self.text_pipeline);
            imports.setBindGroup(0, self.text_bind_group);
            imports.drawInstanced(6, glyph_count);
        }

        imports.endRenderPass();
        imports.releaseTextureView(texture_view);
    }

    /// Render with post-processing shaders
    fn renderWithPostProcess(
        self: *Self,
        prim_count: u32,
        glyph_count: u32,
        viewport_width: f32,
        viewport_height: f32,
        clear_r: f32,
        clear_g: f32,
        clear_b: f32,
        clear_a: f32,
    ) void {
        const state: *PostProcessState = blk: {
            if (self.post_process_state) |*s| break :blk s;
            return; // shouldn't happen if hasCustomShaders was true
        };

        // Ensure textures are the right size
        state.ensureSize(@intFromFloat(viewport_width), @intFromFloat(viewport_height)) catch return;

        // Update timing uniforms
        state.updateTiming();
        state.uploadUniforms();

        // Step 1: Render scene to front texture
        const front_view = state.getFrontTextureView();
        imports.beginTextureRenderPass(front_view, clear_r, clear_g, clear_b, clear_a);

        if (prim_count > 0) {
            imports.setPipeline(self.pipeline);
            imports.setBindGroup(0, self.bind_group);
            imports.drawInstanced(6, prim_count);
        }

        if (glyph_count > 0 and self.text_bind_group != 0) {
            imports.setPipeline(self.text_pipeline);
            imports.setBindGroup(0, self.text_bind_group);
            imports.drawInstanced(6, glyph_count);
        }

        imports.endRenderPass();

        // Step 2: Apply each post-process shader in sequence
        const num_shaders = state.pipelines.items.len;
        for (0..num_shaders) |i| {
            const is_last = (i == num_shaders - 1);
            const pipeline = state.pipelines.items[i];

            // Update bind group to use current front texture
            state.updateBindGroup(i);
            const bind_group = state.bind_groups.items[i];

            if (is_last) {
                // Final pass: render to screen
                const screen_view = imports.getCurrentTextureView();
                imports.beginRenderPass(screen_view, 0, 0, 0, 1);
                imports.setPipeline(pipeline.pipeline);
                imports.setBindGroup(0, bind_group);
                imports.drawInstanced(3, 1); // Fullscreen triangle
                imports.endRenderPass();
                imports.releaseTextureView(screen_view);
            } else {
                // Intermediate pass: render to back texture
                const back_view = state.getBackTextureView();
                imports.beginTextureRenderPass(back_view, 0, 0, 0, 1);
                imports.setPipeline(pipeline.pipeline);
                imports.setBindGroup(0, bind_group);
                imports.drawInstanced(3, 1); // Fullscreen triangle
                imports.endRenderPass();

                // Swap textures for next pass
                state.swapTextures();
            }
        }
    }
};
