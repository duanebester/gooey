//! Custom Shader Support for WebGPU
//!
//! Provides Shadertoy-compatible custom post-processing shaders for web targets.
//! Mirrors the Metal implementation in platform/macos/metal/custom_shader.zig.
//!
//! User shaders implement a mainImage function that receives:
//! - fragCoord: pixel coordinates
//! - iResolution: viewport size
//! - iTime: elapsed time in seconds
//! - iChannel0: the rendered scene texture
//! - iChannel0Sampler: texture sampler

const std = @import("std");
const imports = @import("imports.zig");

/// Uniform buffer layout for custom shaders (Shadertoy-compatible)
/// This struct MUST match the WGSL ShaderUniforms layout exactly
pub const Uniforms = extern struct {
    // iResolution - viewport resolution (width, height, 1.0, padding)
    resolution: [4]f32 align(16),
    // iTime - shader playback time in seconds
    time: f32,
    // iTimeDelta - render time in seconds
    time_delta: f32,
    // iFrameRate - frames per second
    frame_rate: f32,
    // iFrame - frame counter
    frame: i32,
    // iMouse - mouse position (xy = current, zw = click position)
    mouse: [4]f32 align(16),
    // iDate - year, month, day, time in seconds
    date: [4]f32 align(16),
    // Gooey extensions
    focused_bounds: [4]f32 align(16),
    hovered_bounds: [4]f32 align(16),
    accent_color: [4]f32 align(16),
    scroll_offset: [2]f32,
    _pad: [2]f32,

    pub fn init() Uniforms {
        return .{
            .resolution = .{ 800.0, 600.0, 1.0, 0.0 },
            .time = 0.0,
            .time_delta = 0.016,
            .frame_rate = 60.0,
            .frame = 0,
            .mouse = .{ 0.0, 0.0, 0.0, 0.0 },
            .date = .{ 2024.0, 1.0, 1.0, 0.0 },
            .focused_bounds = .{ 0.0, 0.0, 0.0, 0.0 },
            .hovered_bounds = .{ 0.0, 0.0, 0.0, 0.0 },
            .accent_color = .{ 0.2, 0.5, 1.0, 1.0 },
            .scroll_offset = .{ 0.0, 0.0 },
            ._pad = .{ 0.0, 0.0 },
        };
    }

    pub fn setResolution(self: *Uniforms, width: f32, height: f32) void {
        self.resolution = .{ width, height, 1.0, 0.0 };
    }

    pub fn updateTime(self: *Uniforms, elapsed_seconds: f32, delta: f32) void {
        self.time = elapsed_seconds;
        self.time_delta = delta;
        if (delta > 0.0) {
            self.frame_rate = 1.0 / delta;
        }
        self.frame += 1;
    }

    pub fn setMouse(self: *Uniforms, x: f32, y: f32, click_x: f32, click_y: f32) void {
        self.mouse = .{ x, y, click_x, click_y };
    }
};

/// WGSL prefix that provides Shadertoy-compatible interface
pub const wgsl_prefix =
    \\// Custom post-processing shader for WebGPU
    \\// Shadertoy-compatible interface
    \\
    \\struct ShaderUniforms {
    \\    iResolution: vec4<f32>,
    \\    iTime: f32,
    \\    iTimeDelta: f32,
    \\    iFrameRate: f32,
    \\    iFrame: i32,
    \\    iMouse: vec4<f32>,
    \\    iDate: vec4<f32>,
    \\    iFocusedBounds: vec4<f32>,
    \\    iHoveredBounds: vec4<f32>,
    \\    iAccentColor: vec4<f32>,
    \\    iScrollOffset: vec2<f32>,
    \\    _pad: vec2<f32>,
    \\}
    \\
    \\struct VertexOutput {
    \\    @builtin(position) position: vec4<f32>,
    \\    @location(0) texCoord: vec2<f32>,
    \\}
    \\
    \\@group(0) @binding(0) var<uniform> uniforms: ShaderUniforms;
    \\@group(0) @binding(1) var iChannel0: texture_2d<f32>;
    \\@group(0) @binding(2) var iChannel0Sampler: sampler;
    \\
    \\@vertex
    \\fn vs_main(@builtin(vertex_index) vid: u32) -> VertexOutput {
    \\    var positions = array<vec2<f32>, 3>(
    \\        vec2<f32>(-1.0, -1.0),
    \\        vec2<f32>( 3.0, -1.0),
    \\        vec2<f32>(-1.0,  3.0)
    \\    );
    \\    var out: VertexOutput;
    \\    out.position = vec4<f32>(positions[vid], 0.0, 1.0);
    \\    out.texCoord = positions[vid] * 0.5 + 0.5;
    \\    out.texCoord.y = 1.0 - out.texCoord.y;
    \\    return out;
    \\}
    \\
    \\// Forward declaration - user provides mainImage
    \\
;

/// WGSL suffix that provides the fragment shader wrapper
pub const wgsl_suffix =
    \\
    \\@fragment
    \\fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    \\    let fragCoord = in.texCoord * uniforms.iResolution.xy;
    \\    return mainImage(fragCoord, uniforms, iChannel0, iChannel0Sampler);
    \\}
;

/// Compiled custom shader pipeline (WebGPU handles)
pub const CustomShaderPipeline = struct {
    pipeline: u32,
    name: []const u8,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Compile a custom shader from WGSL-compatible source
    pub fn initFromWGSL(
        allocator: std.mem.Allocator,
        shader_source: []const u8,
        name: []const u8,
    ) !Self {
        // Combine prefix + user shader + suffix
        const total_len = wgsl_prefix.len + 1 + shader_source.len + 1 + wgsl_suffix.len;
        const full_source = try allocator.alloc(u8, total_len);
        defer allocator.free(full_source);

        // Build the combined source
        var offset: usize = 0;
        @memcpy(full_source[offset..][0..wgsl_prefix.len], wgsl_prefix);
        offset += wgsl_prefix.len;
        full_source[offset] = '\n';
        offset += 1;
        @memcpy(full_source[offset..][0..shader_source.len], shader_source);
        offset += shader_source.len;
        full_source[offset] = '\n';
        offset += 1;
        @memcpy(full_source[offset..][0..wgsl_suffix.len], wgsl_suffix);

        // Create shader module
        const shader_module = imports.createShaderModule(full_source.ptr, @intCast(total_len));
        if (shader_module == 0) {
            imports.err("Failed to create shader module for '{s}'", .{name});
            return error.ShaderCompilationFailed;
        }

        // Create pipeline using the post-process pipeline creator
        const pipeline = imports.createPostProcessPipeline(shader_module);
        if (pipeline == 0) {
            imports.err("Failed to create pipeline for '{s}'", .{name});
            return error.PipelineCreationFailed;
        }

        imports.log("Custom shader '{s}' loaded successfully", .{name});

        return Self{
            .pipeline = pipeline,
            .name = try allocator.dupe(u8, name),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        // Note: WebGPU handles are managed by JS, we just release our reference
        self.allocator.free(self.name);
    }
};

/// Post-processing state for custom shader rendering
pub const PostProcessState = struct {
    allocator: std.mem.Allocator,

    // Ping-pong textures for shader chaining (WebGPU handles)
    front_texture: u32,
    back_texture: u32,
    front_view: u32,
    back_view: u32,

    // Uniform buffer
    uniform_buffer: u32,
    uniforms: Uniforms,

    // Texture sampler
    sampler: u32,

    // Compiled shader pipelines
    pipelines: std.ArrayList(CustomShaderPipeline),
    bind_groups: std.ArrayList(u32),

    // Timing (in milliseconds from JS)
    start_time: ?f64,
    last_frame_time: ?f64,

    // Current texture size
    width: u32,
    height: u32,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .front_texture = 0,
            .back_texture = 0,
            .front_view = 0,
            .back_view = 0,
            .uniform_buffer = 0,
            .uniforms = Uniforms.init(),
            .sampler = 0,
            .pipelines = .{},
            .bind_groups = .{},
            .start_time = null,
            .last_frame_time = null,
            .width = 0,
            .height = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.pipelines.items) |*pipeline| {
            pipeline.deinit();
        }
        self.pipelines.deinit(self.allocator);
        self.bind_groups.deinit(self.allocator);
        // WebGPU handles are cleaned up by JS
    }

    /// Add a custom shader from WGSL-compatible source
    pub fn addShader(self: *Self, shader_source: []const u8, name: []const u8) !void {
        const pipeline = try CustomShaderPipeline.initFromWGSL(
            self.allocator,
            shader_source,
            name,
        );
        try self.pipelines.append(self.allocator, pipeline);

        // Create bind group for this pipeline if we have textures
        if (self.front_texture != 0) {
            const bind_group = imports.createPostProcessBindGroup(
                pipeline.pipeline,
                self.uniform_buffer,
                self.front_texture,
                self.sampler,
            );
            try self.bind_groups.append(self.allocator, bind_group);
        }
    }

    /// Ensure textures and buffers match the given size
    pub fn ensureSize(self: *Self, width: u32, height: u32) !void {
        if (self.width == width and self.height == height) return;

        self.width = width;
        self.height = height;

        // Create new textures (old ones are released by JS when no longer referenced)
        self.front_texture = imports.createRenderTexture(width, height);
        self.back_texture = imports.createRenderTexture(width, height);
        self.front_view = imports.createTextureView(self.front_texture);
        self.back_view = imports.createTextureView(self.back_texture);

        // Create uniform buffer if needed
        if (self.uniform_buffer == 0) {
            const usage = 0x0040 | 0x0008; // UNIFORM | COPY_DST
            self.uniform_buffer = imports.createBuffer(@sizeOf(Uniforms), usage);
        }

        // Create sampler if needed
        if (self.sampler == 0) {
            self.sampler = imports.createSampler();
        }

        self.uniforms.setResolution(@floatFromInt(width), @floatFromInt(height));

        // Recreate bind groups for all pipelines
        self.bind_groups.clearRetainingCapacity();
        for (self.pipelines.items) |pipeline| {
            const bind_group = imports.createPostProcessBindGroup(
                pipeline.pipeline,
                self.uniform_buffer,
                self.front_texture,
                self.sampler,
            );
            try self.bind_groups.append(self.allocator, bind_group);
        }
    }

    /// Update timing uniforms
    pub fn updateTiming(self: *Self) void {
        const now = imports.getTimestampMillis();

        if (self.start_time == null) {
            self.start_time = now;
        }

        const elapsed_ms = now - self.start_time.?;
        const elapsed_s: f32 = @floatCast(elapsed_ms / 1000.0);

        var delta_s: f32 = 0.016;
        if (self.last_frame_time) |last| {
            const delta_ms = now - last;
            delta_s = @floatCast(delta_ms / 1000.0);
        }

        self.uniforms.updateTime(elapsed_s, delta_s);
        self.last_frame_time = now;
    }

    /// Upload current uniforms to GPU buffer
    pub fn uploadUniforms(self: *Self) void {
        if (self.uniform_buffer == 0) return;
        imports.writeBuffer(
            self.uniform_buffer,
            0,
            @ptrCast(&self.uniforms),
            @sizeOf(Uniforms),
        );
    }

    pub fn hasShaders(self: *const Self) bool {
        return self.pipelines.items.len > 0;
    }

    /// Get the front texture view for rendering the scene into
    pub fn getFrontTextureView(self: *const Self) u32 {
        return self.front_view;
    }

    /// Get the back texture view
    pub fn getBackTextureView(self: *const Self) u32 {
        return self.back_view;
    }

    pub fn swapTextures(self: *Self) void {
        const tmp_tex = self.front_texture;
        const tmp_view = self.front_view;
        self.front_texture = self.back_texture;
        self.front_view = self.back_view;
        self.back_texture = tmp_tex;
        self.back_view = tmp_view;
    }

    /// Update bind group to use current front texture
    pub fn updateBindGroup(self: *Self, index: usize) void {
        if (index >= self.pipelines.items.len) return;
        const pipeline = self.pipelines.items[index];
        self.bind_groups.items[index] = imports.createPostProcessBindGroup(
            pipeline.pipeline,
            self.uniform_buffer,
            self.front_texture,
            self.sampler,
        );
    }
};

// ============================================================================
// Built-in Example Shaders (WGSL versions)
// ============================================================================

/// Simple passthrough shader
pub const passthrough_shader =
    \\fn mainImage(
    \\    fragCoord: vec2<f32>,
    \\    u: ShaderUniforms,
    \\    tex: texture_2d<f32>,
    \\    samp: sampler
    \\) -> vec4<f32> {
    \\    let uv = fragCoord / u.iResolution.xy;
    \\    return textureSample(tex, samp, uv);
    \\}
;

/// Plasma effect shader (WGSL version)
pub const plasma_shader =
    \\fn mainImage(
    \\    fragCoord: vec2<f32>,
    \\    u: ShaderUniforms,
    \\    tex: texture_2d<f32>,
    \\    samp: sampler
    \\) -> vec4<f32> {
    \\    let uv = fragCoord / u.iResolution.xy;
    \\    let scene = textureSample(tex, samp, uv);
    \\    let time = u.iTime * 0.5;
    \\
    \\    // Plasma calculation
    \\    let p = uv * 4.0 - 2.0;
    \\
    \\    let v1 = sin(p.x + time);
    \\    let v2 = sin(p.y + time);
    \\    let v3 = sin(p.x + p.y + time);
    \\    let v4 = sin(length(p) + time * 1.5);
    \\
    \\    var v = v1 + v2 + v3 + v4;
    \\    v = v * 0.5 + 0.5;
    \\
    \\    // Color palette
    \\    var plasma: vec3<f32>;
    \\    plasma.x = sin(v * 3.14159 + time) * 0.5 + 0.5;
    \\    plasma.y = sin(v * 3.14159 + time + 2.094) * 0.5 + 0.5;
    \\    plasma.z = sin(v * 3.14159 + time + 4.188) * 0.5 + 0.5;
    \\
    \\    // Make it more vibrant
    \\    plasma = pow(plasma, vec3<f32>(0.8));
    \\
    \\    // Edge mask
    \\    let center = abs(uv - 0.5) * 2.0;
    \\    var edge = max(center.x, center.y);
    \\    edge = smoothstep(0.3, 1.0, edge);
    \\
    \\    // Blend
    \\    let sceneBrightness = dot(scene.rgb, vec3<f32>(0.299, 0.587, 0.114));
    \\    let final_color = mix(scene.rgb, plasma, edge * 0.7 * (1.0 - sceneBrightness * 0.5));
    \\
    \\    return vec4<f32>(final_color, 1.0);
    \\}
;

/// CRT effect shader (WGSL version)
pub const crt_shader =
    \\fn mainImage(
    \\    fragCoord: vec2<f32>,
    \\    u: ShaderUniforms,
    \\    tex: texture_2d<f32>,
    \\    samp: sampler
    \\) -> vec4<f32> {
    \\    var uv = fragCoord / u.iResolution.xy;
    \\
    \\    // Barrel distortion
    \\    let center = uv - 0.5;
    \\    let dist = dot(center, center);
    \\    uv = uv + center * dist * 0.1;
    \\
    \\    var color = textureSample(tex, samp, uv).rgb;
    \\
    \\    // Scanlines
    \\    let scanline = sin(fragCoord.y * 2.0) * 0.04;
    \\    color = color - scanline;
    \\
    \\    // Vignette
    \\    let vignette = 1.0 - dist * 1.5;
    \\    color = color * vignette;
    \\
    \\    // Chromatic aberration
    \\    let r = textureSample(tex, samp, uv + vec2<f32>(0.002, 0.0)).r;
    \\    let b = textureSample(tex, samp, uv - vec2<f32>(0.002, 0.0)).b;
    \\    color = vec3<f32>(r, color.g, b);
    \\
    \\    return vec4<f32>(color, 1.0);
    \\}
;
