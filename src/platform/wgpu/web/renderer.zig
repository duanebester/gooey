//! WebRenderer - GPU rendering for WebAssembly/WebGPU
//!
//! Takes a gooey Scene and renders it to WebGPU. This is the web equivalent
//! of the Metal renderer on macOS.

const std = @import("std");
const imports = @import("imports.zig");
const unified = @import("../unified.zig");
const scene_mod = @import("../../../scene/mod.zig");
const batch_iter = @import("../../../scene/batch_iterator.zig");
const text_mod = @import("../../../text/mod.zig");
const svg_mod = @import("../../../svg/mod.zig");
const image_mod = @import("../../../image/mod.zig");
const custom_shader = @import("custom_shader.zig");

const Scene = scene_mod.Scene;
const SvgInstance = scene_mod.SvgInstance;
const TextSystem = text_mod.TextSystem;
const SvgAtlas = svg_mod.SvgAtlas;
const ImageAtlas = image_mod.ImageAtlas;
const ImageInstance = scene_mod.ImageInstance;
const PostProcessState = custom_shader.PostProcessState;

// =============================================================================
// Constants
// =============================================================================

pub const MAX_PRIMITIVES: u32 = 4096;
pub const MAX_GLYPHS: u32 = 8192;
pub const MAX_SVGS: u32 = 1024;
pub const MAX_IMAGES: u32 = 512;

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

/// GPU-ready SVG instance data (matches SvgInstance layout - 80 bytes)
pub const GpuSvgInstance = extern struct {
    // Screen position (top-left, logical pixels)
    pos_x: f32 = 0,
    pos_y: f32 = 0,
    // Size (logical pixels)
    size_x: f32 = 0,
    size_y: f32 = 0,
    // Atlas UV coordinates
    uv_left: f32 = 0,
    uv_top: f32 = 0,
    uv_right: f32 = 0,
    uv_bottom: f32 = 0,
    // Fill color (HSLA)
    fill_h: f32 = 0,
    fill_s: f32 = 0,
    fill_l: f32 = 0,
    fill_a: f32 = 1,
    // Stroke color (HSLA)
    stroke_h: f32 = 0,
    stroke_s: f32 = 0,
    stroke_l: f32 = 0,
    stroke_a: f32 = 0,
    // Clip bounds
    clip_x: f32 = 0,
    clip_y: f32 = 0,
    clip_width: f32 = 99999,
    clip_height: f32 = 99999,

    pub fn fromScene(s: SvgInstance) GpuSvgInstance {
        return .{
            .pos_x = s.pos_x,
            .pos_y = s.pos_y,
            .size_x = s.size_x,
            .size_y = s.size_y,
            .uv_left = s.uv_left,
            .uv_top = s.uv_top,
            .uv_right = s.uv_right,
            .uv_bottom = s.uv_bottom,
            .fill_h = s.color.h,
            .fill_s = s.color.s,
            .fill_l = s.color.l,
            .fill_a = s.color.a,
            .stroke_h = s.stroke_color.h,
            .stroke_s = s.stroke_color.s,
            .stroke_l = s.stroke_color.l,
            .stroke_a = s.stroke_color.a,
            .clip_x = s.clip_x,
            .clip_y = s.clip_y,
            .clip_width = s.clip_width,
            .clip_height = s.clip_height,
        };
    }
};

// Verify GpuSvgInstance matches SvgInstance size
comptime {
    if (@sizeOf(GpuSvgInstance) != 80) {
        @compileError(std.fmt.comptimePrint(
            "GpuSvgInstance must be 80 bytes, got {}",
            .{@sizeOf(GpuSvgInstance)},
        ));
    }
}

// =============================================================================
// WebRenderer
// =============================================================================

/// Batch descriptor for deferred rendering
const BatchDesc = struct {
    kind: batch_iter.PrimitiveKind,
    start: u32,
    count: u32,
};

const MAX_BATCHES: u32 = 256;

pub const WebRenderer = struct {
    allocator: std.mem.Allocator,

    // Primitives (quads, shadows)
    pipeline: u32 = 0,
    primitive_buffer: u32 = 0,
    bind_group: u32 = 0,
    primitives: [MAX_PRIMITIVES]unified.Primitive = undefined,

    // Shared
    uniform_buffer: u32 = 0,
    sampler: u32 = 0,

    // Text rendering
    text_pipeline: u32 = 0,
    glyph_buffer: u32 = 0,
    text_bind_group: u32 = 0,
    atlas_texture: u32 = 0,
    atlas_generation: u32 = 0,
    gpu_glyphs: [MAX_GLYPHS]GpuGlyph = undefined,

    // SVG rendering
    svg_pipeline: u32 = 0,
    svg_buffer: u32 = 0,
    svg_bind_group: u32 = 0,
    svg_atlas_texture: u32 = 0,
    svg_atlas_generation: u32 = 0,
    gpu_svgs: [MAX_SVGS]GpuSvgInstance = undefined,

    // Image rendering
    image_pipeline: u32 = 0,
    image_buffer: u32 = 0,
    image_bind_group: u32 = 0,
    image_atlas_texture: u32 = 0,
    image_atlas_generation: u32 = 0,
    gpu_images: [MAX_IMAGES]ImageInstance = undefined,

    initialized: bool = false,

    // MSAA state
    msaa_texture: u32 = 0,
    msaa_width: u32 = 0,
    msaa_height: u32 = 0,
    sample_count: u32 = 4,

    // Post-processing state for custom shaders
    post_process_state: ?PostProcessState = null,

    // Batch descriptors for deferred rendering
    batches: [MAX_BATCHES]BatchDesc = undefined,

    const Self = @This();

    const unified_shader = @embedFile("unified_wgsl");
    const text_shader = @embedFile("text_wgsl");
    const svg_shader = @embedFile("svg_wgsl");
    const image_shader = @embedFile("image_wgsl");

    pub fn init(allocator: std.mem.Allocator) !Self {
        var self = Self{
            .allocator = allocator,
        };

        // Get MSAA sample count from JS (usually 4)
        self.sample_count = imports.getMSAASampleCount();

        // Create shader modules
        const unified_module = imports.createShaderModule(unified_shader.ptr, unified_shader.len);
        const text_module = imports.createShaderModule(text_shader.ptr, text_shader.len);
        const svg_module = imports.createShaderModule(svg_shader.ptr, svg_shader.len);
        const image_module = imports.createShaderModule(image_shader.ptr, image_shader.len);

        // Create MSAA-enabled pipelines
        if (self.sample_count > 1) {
            self.pipeline = imports.createMSAARenderPipeline(unified_module, "vs_main", 7, "fs_main", 7, self.sample_count);
            self.text_pipeline = imports.createMSAARenderPipeline(text_module, "vs_main", 7, "fs_main", 7, self.sample_count);
            // SVG shader outputs premultiplied alpha, needs ONE for srcRGB blend factor
            self.svg_pipeline = imports.createMSAAPremultipliedAlphaPipeline(svg_module, "vs_main", 7, "fs_main", 7, self.sample_count);
            self.image_pipeline = imports.createMSAARenderPipeline(image_module, "vs_main", 7, "fs_main", 7, self.sample_count);
        } else {
            // Fallback to non-MSAA pipelines
            self.pipeline = imports.createRenderPipeline(unified_module, "vs_main", 7, "fs_main", 7);
            self.text_pipeline = imports.createRenderPipeline(text_module, "vs_main", 7, "fs_main", 7);
            // SVG shader outputs premultiplied alpha, needs ONE for srcRGB blend factor
            self.svg_pipeline = imports.createPremultipliedAlphaPipeline(svg_module, "vs_main", 7, "fs_main", 7);
            self.image_pipeline = imports.createRenderPipeline(image_module, "vs_main", 7, "fs_main", 7);
        }

        const storage_copy = 0x0080 | 0x0008; // STORAGE | COPY_DST
        const uniform_copy = 0x0040 | 0x0008; // UNIFORM | COPY_DST

        // Create buffers
        self.primitive_buffer = imports.createBuffer(@sizeOf(unified.Primitive) * MAX_PRIMITIVES, storage_copy);
        self.glyph_buffer = imports.createBuffer(@sizeOf(GpuGlyph) * MAX_GLYPHS, storage_copy);
        self.svg_buffer = imports.createBuffer(@sizeOf(GpuSvgInstance) * MAX_SVGS, storage_copy);
        self.image_buffer = imports.createBuffer(@sizeOf(ImageInstance) * MAX_IMAGES, storage_copy);
        self.uniform_buffer = imports.createBuffer(@sizeOf(Uniforms), uniform_copy);

        // Create bind groups
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

    /// Ensure MSAA texture is the right size
    fn ensureMSAATexture(self: *Self, width: u32, height: u32) void {
        if (self.sample_count <= 1) return;

        // Recreate if size changed
        if (self.msaa_texture != 0 and (self.msaa_width != width or self.msaa_height != height)) {
            imports.destroyTexture(self.msaa_texture);
            self.msaa_texture = 0;
        }

        // Create if needed
        if (self.msaa_texture == 0) {
            self.msaa_texture = imports.createMSAATexture(width, height, self.sample_count);
            self.msaa_width = width;
            self.msaa_height = height;
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

    // =========================================================================
    // Text Atlas Management
    // =========================================================================

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

    // =========================================================================
    // SVG Atlas Management
    // =========================================================================

    pub fn uploadSvgAtlas(self: *Self, svg_atlas: *SvgAtlas) void {
        const atlas = svg_atlas.getAtlas();
        const pixels = atlas.getData();
        const size = atlas.size;

        if (self.svg_atlas_texture == 0) {
            // SVG atlas uses RGBA format
            self.svg_atlas_texture = imports.createRgbaTexture(size, size, pixels.ptr, @intCast(pixels.len));
        }

        self.svg_bind_group = imports.createSvgBindGroup(
            self.svg_pipeline,
            0,
            self.svg_buffer,
            self.uniform_buffer,
            self.svg_atlas_texture,
            self.sampler,
        );

        self.svg_atlas_generation = atlas.generation;
    }

    pub fn syncSvgAtlas(self: *Self, svg_atlas: *SvgAtlas) void {
        const atlas = svg_atlas.getAtlas();
        const generation = svg_atlas.getGeneration();

        // Only update if generation changed
        if (generation == self.svg_atlas_generation) return;

        if (self.svg_atlas_texture != 0) {
            const pixels = atlas.getData();
            const size = atlas.size;
            imports.updateRgbaTexture(self.svg_atlas_texture, size, size, pixels.ptr, @intCast(pixels.len));
            self.svg_atlas_generation = generation;
        } else {
            // First time - create the texture
            self.uploadSvgAtlas(svg_atlas);
        }
    }

    // =========================================================================
    // Image Atlas Management
    // =========================================================================

    pub fn uploadImageAtlas(self: *Self, image_atlas: *ImageAtlas) void {
        const atlas = image_atlas.getAtlas();
        const pixels = atlas.getData();
        const size = atlas.size;

        if (self.image_atlas_texture == 0) {
            // Image atlas uses RGBA format
            self.image_atlas_texture = imports.createRgbaTexture(size, size, pixels.ptr, @intCast(pixels.len));
        }

        self.image_bind_group = imports.createImageBindGroup(
            self.image_pipeline,
            0,
            self.image_buffer,
            self.uniform_buffer,
            self.image_atlas_texture,
            self.sampler,
        );

        self.image_atlas_generation = atlas.generation;
    }

    pub fn syncImageAtlas(self: *Self, image_atlas: *ImageAtlas) void {
        const atlas = image_atlas.getAtlas();
        const generation = image_atlas.getGeneration();

        // Only update if generation changed
        if (generation == self.image_atlas_generation) return;

        if (self.image_atlas_texture != 0) {
            const pixels = atlas.getData();
            const size = atlas.size;
            imports.updateRgbaTexture(self.image_atlas_texture, size, size, pixels.ptr, @intCast(pixels.len));
            self.image_atlas_generation = generation;
        } else {
            // First time - create the texture
            self.uploadImageAtlas(image_atlas);
        }
    }

    // =========================================================================
    // Rendering
    // =========================================================================

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

        // Upload uniforms
        const uniforms = Uniforms{ .viewport_width = viewport_width, .viewport_height = viewport_height };
        imports.writeBuffer(self.uniform_buffer, 0, std.mem.asBytes(&uniforms).ptr, @sizeOf(Uniforms));

        // Ensure MSAA texture is sized correctly (use actual canvas pixel dimensions)
        if (self.sample_count > 1) {
            const device_width = imports.getCanvasPixelWidth();
            const device_height = imports.getCanvasPixelHeight();
            self.ensureMSAATexture(device_width, device_height);
        }

        // Check if we need post-processing
        const has_post_process = if (self.post_process_state) |*state| state.hasShaders() else false;
        if (has_post_process) {
            // Render to offscreen texture first (uses legacy non-batched path)
            const prim_count = unified.convertScene(scene, &self.primitives);

            var glyph_count: u32 = 0;
            for (scene.getGlyphs()) |g| {
                if (glyph_count >= MAX_GLYPHS) break;
                self.gpu_glyphs[glyph_count] = GpuGlyph.fromScene(g);
                glyph_count += 1;
            }

            var svg_count: u32 = 0;
            for (scene.getSvgInstances()) |s| {
                if (svg_count >= MAX_SVGS) break;
                self.gpu_svgs[svg_count] = GpuSvgInstance.fromScene(s);
                svg_count += 1;
            }

            // Upload all buffers for post-process path
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
            if (svg_count > 0) {
                imports.writeBuffer(
                    self.svg_buffer,
                    0,
                    std.mem.sliceAsBytes(self.gpu_svgs[0..svg_count]).ptr,
                    @intCast(@sizeOf(GpuSvgInstance) * svg_count),
                );
            }

            self.renderWithPostProcess(
                prim_count,
                glyph_count,
                svg_count,
                viewport_width,
                viewport_height,
                clear_r,
                clear_g,
                clear_b,
                clear_a,
            );
        } else {
            // Render directly to screen using batched rendering for correct z-order
            self.renderBatched(scene, clear_r, clear_g, clear_b, clear_a);
        }
    }

    /// Render using batch iteration for correct z-ordering across primitive types.
    /// This ensures text and SVGs are properly interleaved with quads/shadows.
    ///
    /// Two-pass approach to avoid WebGPU queue ordering issues:
    /// 1. First pass: iterate batches, convert data, record batch descriptors
    /// 2. Upload all converted data to GPU buffers
    /// 3. Second pass: begin render pass, draw each batch using recorded descriptors
    fn renderBatched(
        self: *Self,
        scene: *const Scene,
        clear_r: f32,
        clear_g: f32,
        clear_b: f32,
        clear_a: f32,
    ) void {
        // Pass 1: Convert all data and record batch descriptors
        var iter = batch_iter.BatchIterator.init(scene);
        var batch_count: u32 = 0;
        var prim_offset: u32 = 0;
        var glyph_offset: u32 = 0;
        var svg_offset: u32 = 0;
        var image_offset: u32 = 0;

        while (iter.next()) |batch| {
            if (batch_count >= MAX_BATCHES) break;

            switch (batch) {
                .shadow => |shadows| {
                    const count: u32 = @intCast(@min(shadows.len, MAX_PRIMITIVES - prim_offset));
                    if (count == 0) continue;

                    for (shadows[0..count], 0..) |shadow, i| {
                        self.primitives[prim_offset + i] = unified.Primitive.fromShadow(shadow);
                    }

                    self.batches[batch_count] = .{
                        .kind = .shadow,
                        .start = prim_offset,
                        .count = count,
                    };
                    prim_offset += count;
                    batch_count += 1;
                },
                .quad => |quads| {
                    const count: u32 = @intCast(@min(quads.len, MAX_PRIMITIVES - prim_offset));
                    if (count == 0) continue;

                    for (quads[0..count], 0..) |quad, i| {
                        self.primitives[prim_offset + i] = unified.Primitive.fromQuad(quad);
                    }

                    self.batches[batch_count] = .{
                        .kind = .quad,
                        .start = prim_offset,
                        .count = count,
                    };
                    prim_offset += count;
                    batch_count += 1;
                },
                .glyph => |glyphs| {
                    const count: u32 = @intCast(@min(glyphs.len, MAX_GLYPHS - glyph_offset));
                    if (count == 0) continue;

                    for (glyphs[0..count], 0..) |g, i| {
                        self.gpu_glyphs[glyph_offset + i] = GpuGlyph.fromScene(g);
                    }

                    self.batches[batch_count] = .{
                        .kind = .glyph,
                        .start = glyph_offset,
                        .count = count,
                    };
                    glyph_offset += count;
                    batch_count += 1;
                },
                .svg => |svgs| {
                    const count: u32 = @intCast(@min(svgs.len, MAX_SVGS - svg_offset));
                    if (count == 0) continue;

                    for (svgs[0..count], 0..) |s, i| {
                        self.gpu_svgs[svg_offset + i] = GpuSvgInstance.fromScene(s);
                    }

                    self.batches[batch_count] = .{
                        .kind = .svg,
                        .start = svg_offset,
                        .count = count,
                    };
                    svg_offset += count;
                    batch_count += 1;
                },
                .image => |images| {
                    const count: u32 = @intCast(@min(images.len, MAX_IMAGES - image_offset));
                    if (count == 0) continue;

                    // ImageInstance is already GPU-ready (extern struct), direct copy
                    for (images[0..count], 0..) |img, i| {
                        self.gpu_images[image_offset + i] = img;
                    }

                    self.batches[batch_count] = .{
                        .kind = .image,
                        .start = image_offset,
                        .count = count,
                    };
                    image_offset += count;
                    batch_count += 1;
                },
            }
        }

        // Pass 2: Upload all data to GPU buffers BEFORE starting render pass
        if (prim_offset > 0) {
            imports.writeBuffer(
                self.primitive_buffer,
                0,
                std.mem.sliceAsBytes(self.primitives[0..prim_offset]).ptr,
                @intCast(@sizeOf(unified.Primitive) * prim_offset),
            );
        }
        if (glyph_offset > 0) {
            imports.writeBuffer(
                self.glyph_buffer,
                0,
                std.mem.sliceAsBytes(self.gpu_glyphs[0..glyph_offset]).ptr,
                @intCast(@sizeOf(GpuGlyph) * glyph_offset),
            );
        }
        if (svg_offset > 0) {
            imports.writeBuffer(
                self.svg_buffer,
                0,
                std.mem.sliceAsBytes(self.gpu_svgs[0..svg_offset]).ptr,
                @intCast(@sizeOf(GpuSvgInstance) * svg_offset),
            );
        }
        if (image_offset > 0) {
            imports.writeBuffer(
                self.image_buffer,
                0,
                std.mem.sliceAsBytes(self.gpu_images[0..image_offset]).ptr,
                @intCast(@sizeOf(ImageInstance) * image_offset),
            );
        }

        // Pass 3: Begin render pass and draw each batch
        const texture_view = imports.getCurrentTextureView();

        if (self.sample_count > 1 and self.msaa_texture != 0) {
            imports.beginMSAARenderPass(self.msaa_texture, texture_view, clear_r, clear_g, clear_b, clear_a);
        } else {
            imports.beginRenderPass(texture_view, clear_r, clear_g, clear_b, clear_a);
        }

        for (self.batches[0..batch_count]) |batch_desc| {
            switch (batch_desc.kind) {
                .shadow, .quad => {
                    imports.setPipeline(self.pipeline);
                    imports.setBindGroup(0, self.bind_group);
                    imports.drawInstancedWithOffset(6, batch_desc.count, batch_desc.start);
                },
                .glyph => {
                    if (self.text_bind_group != 0) {
                        imports.setPipeline(self.text_pipeline);
                        imports.setBindGroup(0, self.text_bind_group);
                        imports.drawInstancedWithOffset(6, batch_desc.count, batch_desc.start);
                    }
                },
                .svg => {
                    if (self.svg_bind_group != 0) {
                        imports.setPipeline(self.svg_pipeline);
                        imports.setBindGroup(0, self.svg_bind_group);
                        imports.drawInstancedWithOffset(6, batch_desc.count, batch_desc.start);
                    }
                },
                .image => {
                    if (self.image_bind_group != 0) {
                        imports.setPipeline(self.image_pipeline);
                        imports.setBindGroup(0, self.image_bind_group);
                        imports.drawInstancedWithOffset(6, batch_desc.count, batch_desc.start);
                    }
                },
            }
        }

        imports.endRenderPass();
        imports.releaseTextureView(texture_view);
    }

    /// Legacy non-batched rendering (used by post-process path)
    fn renderDirect(
        self: *Self,
        prim_count: u32,
        glyph_count: u32,
        svg_count: u32,
        clear_r: f32,
        clear_g: f32,
        clear_b: f32,
        clear_a: f32,
    ) void {
        const texture_view = imports.getCurrentTextureView();

        // Use MSAA if available and texture was created successfully
        if (self.sample_count > 1 and self.msaa_texture != 0) {
            imports.beginMSAARenderPass(self.msaa_texture, texture_view, clear_r, clear_g, clear_b, clear_a);
        } else {
            imports.beginRenderPass(texture_view, clear_r, clear_g, clear_b, clear_a);
        }

        // Render primitives (quads, shadows)
        if (prim_count > 0) {
            imports.setPipeline(self.pipeline);
            imports.setBindGroup(0, self.bind_group);
            imports.drawInstanced(6, prim_count);
        }

        // Render text glyphs
        if (glyph_count > 0 and self.text_bind_group != 0) {
            imports.setPipeline(self.text_pipeline);
            imports.setBindGroup(0, self.text_bind_group);
            imports.drawInstanced(6, glyph_count);
        }

        // Render SVG icons
        if (svg_count > 0 and self.svg_bind_group != 0) {
            imports.setPipeline(self.svg_pipeline);
            imports.setBindGroup(0, self.svg_bind_group);
            imports.drawInstanced(6, svg_count);
        }

        imports.endRenderPass();
        imports.releaseTextureView(texture_view);
    }

    /// Render with post-processing shaders
    fn renderWithPostProcess(
        self: *Self,
        prim_count: u32,
        glyph_count: u32,
        svg_count: u32,
        _: f32, // viewport_width - unused, we use device pixels instead
        _: f32, // viewport_height - unused, we use device pixels instead
        clear_r: f32,
        clear_g: f32,
        clear_b: f32,
        clear_a: f32,
    ) void {
        const state: *PostProcessState = blk: {
            if (self.post_process_state) |*s| break :blk s;
            return; // shouldn't happen if hasCustomShaders was true
        };

        // Ensure textures are the right size (use device pixels for sharp rendering)
        const device_width = imports.getCanvasPixelWidth();
        const device_height = imports.getCanvasPixelHeight();
        state.ensureSize(device_width, device_height) catch return;

        // Ensure MSAA texture matches post-process texture size
        if (self.sample_count > 1) {
            self.ensureMSAATexture(device_width, device_height);
        }

        // Update timing uniforms
        state.updateTiming();
        state.uploadUniforms();

        // Step 1: Render scene to front texture (with MSAA if available)
        if (self.sample_count > 1 and self.msaa_texture != 0) {
            imports.beginMSAATextureRenderPass(self.msaa_texture, state.front_texture, clear_r, clear_g, clear_b, clear_a);
        } else {
            const front_view = state.getFrontTextureView();
            imports.beginTextureRenderPass(front_view, clear_r, clear_g, clear_b, clear_a);
        }

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

        if (svg_count > 0 and self.svg_bind_group != 0) {
            imports.setPipeline(self.svg_pipeline);
            imports.setBindGroup(0, self.svg_bind_group);
            imports.drawInstanced(6, svg_count);
        }

        imports.endRenderPass();

        // Step 2: Apply each post-process shader in sequence
        const num_shaders = state.pipelines.items.len;
        for (0..num_shaders) |i| {
            const is_last = (i == num_shaders - 1);
            const pipeline_entry = state.pipelines.items[i];

            // Update bind group to use current front texture
            state.updateBindGroup(i);
            const bind_group = state.bind_groups.items[i];

            if (is_last) {
                // Final pass: render to screen
                const screen_view = imports.getCurrentTextureView();
                imports.beginRenderPass(screen_view, 0, 0, 0, 1);
                imports.setPipeline(pipeline_entry.pipeline);
                imports.setBindGroup(0, bind_group);
                imports.drawInstanced(3, 1); // Fullscreen triangle
                imports.endRenderPass();
                imports.releaseTextureView(screen_view);
            } else {
                // Intermediate pass: render to back texture
                const back_view = state.getBackTextureView();
                imports.beginTextureRenderPass(back_view, 0, 0, 0, 1);
                imports.setPipeline(pipeline_entry.pipeline);
                imports.setBindGroup(0, bind_group);
                imports.drawInstanced(3, 1); // Fullscreen triangle
                imports.endRenderPass();

                // Swap textures for next pass
                state.swapTextures();
            }
        }
    }
};
