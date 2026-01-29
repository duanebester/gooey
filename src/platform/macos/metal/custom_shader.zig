//! Custom Shader System - Shadertoy-compatible post-processing shaders
//!
//! This module provides support for custom GLSL shaders in the Shadertoy format.
//! Shaders are wrapped with a prefix that provides Shadertoy-compatible uniforms
//! and converted to Metal Shading Language (MSL) for rendering.
//!
//! Uniforms provided:
//! - iResolution: vec3 - viewport resolution (width, height, 1.0)
//! - iTime: float - time since start in seconds
//! - iTimeDelta: float - frame time delta
//! - iFrame: int - frame counter
//! - iMouse: vec4 - mouse position (x, y, click_x, click_y)
//! - iChannel0: sampler2D - previous pass texture
//!
//! Gooey extensions:
//! - iFocusedBounds: vec4 - bounds of focused element (x, y, w, h)
//! - iHoveredBounds: vec4 - bounds of hovered element
//! - iAccentColor: vec4 - theme accent color
//! - iScrollOffset: vec2 - current scroll offset

const std = @import("std");
const objc = @import("objc");
const mtl = @import("api.zig");

/// Uniform buffer layout for custom shaders (Shadertoy-compatible)
/// This struct is passed to shaders and MUST match the MSL layout exactly
pub const Uniforms = extern struct {
    // Shadertoy standard uniforms
    resolution: [3]f32 align(16), // iResolution - viewport resolution (width, height, 1.0)
    _pad_resolution: f32 = 0, // Padding to match Metal float3 alignment
    time: f32, // iTime - shader playback time in seconds (now at offset 16)
    time_delta: f32, // iTimeDelta - render time in seconds
    frame_rate: f32, // iFrameRate - frames per second
    frame: i32, // iFrame - frame counter
    mouse: [4]f32 align(16), // iMouse - mouse position/click
    date: [4]f32 align(16), // iDate - year, month, day, time in seconds

    // Gooey extensions
    focused_bounds: [4]f32 align(16), // iFocusedBounds - focused element bounds
    hovered_bounds: [4]f32 align(16), // iHoveredBounds - hovered element bounds
    accent_color: [4]f32 align(16), // iAccentColor - theme accent color
    scroll_offset: [2]f32 align(8), // iScrollOffset - current scroll position
    _pad1: [2]f32 align(8), // padding

    pub fn init() Uniforms {
        return .{
            .resolution = .{ 800.0, 600.0, 1.0 },
            ._pad_resolution = 0,
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
            ._pad1 = .{ 0.0, 0.0 },
        };
    }

    pub fn setResolution(self: *Uniforms, width: f32, height: f32) void {
        self.resolution = .{ width, height, 1.0 };
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

/// MSL prefix that provides Shadertoy-compatible interface
pub const msl_prefix =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\
    \\// Shadertoy-compatible uniform buffer
    \\struct ShaderUniforms {
    \\    float3 iResolution;
    \\    float iTime;
    \\    float iTimeDelta;
    \\    float iFrameRate;
    \\    int iFrame;
    \\    int _pad0;
    \\    float4 iMouse;
    \\    float4 iDate;
    \\    // Gooey extensions
    \\    float4 iFocusedBounds;
    \\    float4 iHoveredBounds;
    \\    float4 iAccentColor;
    \\    float2 iScrollOffset;
    \\    float2 _pad1;
    \\};
    \\
    \\// Vertex output for fullscreen quad
    \\struct FullscreenVertexOut {
    \\    float4 position [[position]];
    \\    float2 texCoord;
    \\};
    \\
    \\// Fullscreen triangle vertex shader (more efficient than quad)
    \\vertex FullscreenVertexOut custom_shader_vertex(uint vid [[vertex_id]]) {
    \\    float2 positions[3] = {
    \\        float2(-1.0, -1.0),
    \\        float2( 3.0, -1.0),
    \\        float2(-1.0,  3.0)
    \\    };
    \\
    \\    FullscreenVertexOut out;
    \\    out.position = float4(positions[vid], 0.0, 1.0);
    \\    out.texCoord = positions[vid] * 0.5 + 0.5;
    \\    out.texCoord.y = 1.0 - out.texCoord.y;
    \\    return out;
    \\}
    \\
    \\// Forward declaration - user provides mainImage
    \\void mainImage(thread float4& fragColor, float2 fragCoord,
    \\               constant ShaderUniforms& uniforms,
    \\               texture2d<float> iChannel0,
    \\               sampler iChannel0Sampler);
    \\
;

/// MSL suffix that provides the fragment shader wrapper
pub const msl_suffix =
    \\
    \\// Fragment shader wrapper that calls user's mainImage
    \\fragment float4 custom_shader_fragment(
    \\    FullscreenVertexOut in [[stage_in]],
    \\    constant ShaderUniforms& uniforms [[buffer(0)]],
    \\    texture2d<float> iChannel0 [[texture(0)]],
    \\    sampler iChannel0Sampler [[sampler(0)]]
    \\) {
    \\    float2 fragCoord = in.texCoord * uniforms.iResolution.xy;
    \\    float4 fragColor = float4(0.0);
    \\    mainImage(fragColor, fragCoord, uniforms, iChannel0, iChannel0Sampler);
    \\    return fragColor;
    \\}
;

/// Represents a compiled custom shader pipeline
pub const CustomShaderPipeline = struct {
    pipeline_state: objc.Object,
    name: []const u8,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Compile a custom shader from MSL-compatible source
    pub fn initFromMSL(
        allocator: std.mem.Allocator,
        device: objc.Object,
        shader_source: []const u8,
        name: []const u8,
        pixel_format: mtl.MTLPixelFormat,
        sample_count: u32,
    ) !Self {
        // Combine prefix + user shader + suffix
        // Calculate total length needed
        const total_len = msl_prefix.len + 1 + shader_source.len + 1 + msl_suffix.len + 1; // +1 for newlines and null
        const full_source = try allocator.alloc(u8, total_len);
        defer allocator.free(full_source);

        // Build the combined source
        var offset: usize = 0;
        @memcpy(full_source[offset..][0..msl_prefix.len], msl_prefix);
        offset += msl_prefix.len;
        full_source[offset] = '\n';
        offset += 1;
        @memcpy(full_source[offset..][0..shader_source.len], shader_source);
        offset += shader_source.len;
        full_source[offset] = '\n';
        offset += 1;
        @memcpy(full_source[offset..][0..msl_suffix.len], msl_suffix);
        offset += msl_suffix.len;
        full_source[offset] = 0; // Null terminator

        // Create NSString from source
        const NSString = objc.getClass("NSString") orelse return error.ClassNotFound;
        const source_nsstring = NSString.msgSend(
            objc.Object,
            "stringWithUTF8String:",
            .{full_source.ptr},
        );

        // Compile shader library
        var error_ptr: ?*anyopaque = null;
        const library_ptr = device.msgSend(
            ?*anyopaque,
            "newLibraryWithSource:options:error:",
            .{ source_nsstring.value, @as(?*anyopaque, null), &error_ptr },
        );

        if (library_ptr == null) {
            if (error_ptr) |err| {
                const err_obj = objc.Object.fromId(err);
                const desc = err_obj.msgSend(objc.Object, "localizedDescription", .{});
                const c_str = desc.msgSend([*:0]const u8, "UTF8String", .{});
                std.log.err("Custom shader compilation failed for '{s}': {s}", .{ name, c_str });
            }
            return error.ShaderCompilationFailed;
        }
        const library = objc.Object.fromId(library_ptr);
        defer library.msgSend(void, "release", .{});

        // Get vertex function
        const vertex_name = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"custom_shader_vertex"});
        const vertex_fn = library.msgSend(?*anyopaque, "newFunctionWithName:", .{vertex_name.value});
        if (vertex_fn == null) return error.VertexFunctionNotFound;
        const vertex_func = objc.Object.fromId(vertex_fn);
        defer vertex_func.msgSend(void, "release", .{});

        // Get fragment function
        const fragment_name = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"custom_shader_fragment"});
        const fragment_fn = library.msgSend(?*anyopaque, "newFunctionWithName:", .{fragment_name.value});
        if (fragment_fn == null) return error.FragmentFunctionNotFound;
        const fragment_func = objc.Object.fromId(fragment_fn);
        defer fragment_func.msgSend(void, "release", .{});

        // Create pipeline descriptor
        const MTLRenderPipelineDescriptor = objc.getClass("MTLRenderPipelineDescriptor") orelse return error.ClassNotFound;
        const descriptor = MTLRenderPipelineDescriptor.msgSend(objc.Object, "alloc", .{});
        const desc = descriptor.msgSend(objc.Object, "init", .{});
        defer desc.msgSend(void, "release", .{});

        desc.msgSend(void, "setVertexFunction:", .{vertex_func.value});
        desc.msgSend(void, "setFragmentFunction:", .{fragment_func.value});

        // Configure color attachment (no MSAA for post-process - render to resolve texture)
        const color_attachments = desc.msgSend(objc.Object, "colorAttachments", .{});
        const attachment0 = color_attachments.msgSend(objc.Object, "objectAtIndexedSubscript:", .{@as(c_ulong, 0)});
        attachment0.msgSend(void, "setPixelFormat:", .{@intFromEnum(pixel_format)});

        // No blending - custom shaders fully replace the color
        attachment0.msgSend(void, "setBlendingEnabled:", .{false});

        // Sample count 1 for post-process textures (not MSAA)
        _ = sample_count;
        desc.msgSend(void, "setSampleCount:", .{@as(c_ulong, 1)});

        // Create pipeline state
        var pipeline_error: ?*anyopaque = null;
        const pipeline_ptr = device.msgSend(
            ?*anyopaque,
            "newRenderPipelineStateWithDescriptor:error:",
            .{ desc.value, &pipeline_error },
        );

        if (pipeline_ptr == null) {
            if (pipeline_error) |err| {
                const err_obj = objc.Object.fromId(err);
                const err_desc = err_obj.msgSend(objc.Object, "localizedDescription", .{});
                const c_str = err_desc.msgSend([*:0]const u8, "UTF8String", .{});
                std.log.err("Pipeline creation failed for '{s}': {s}", .{ name, c_str });
            }
            return error.PipelineCreationFailed;
        }

        return Self{
            .pipeline_state = objc.Object.fromId(pipeline_ptr),
            .name = try allocator.dupe(u8, name),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.pipeline_state.msgSend(void, "release", .{});
        self.allocator.free(self.name);
    }
};

/// Post-processing state for custom shader rendering
pub const PostProcessState = struct {
    device: objc.Object,
    allocator: std.mem.Allocator,

    // Ping-pong textures for shader chaining
    front_texture: ?objc.Object,
    back_texture: ?objc.Object,

    // Uniform buffer
    uniform_buffer: ?objc.Object,
    uniforms: Uniforms,

    // Texture sampler
    sampler: ?objc.Object,

    // Compiled shader pipelines
    pipelines: std.ArrayList(CustomShaderPipeline),

    // Timing
    start_time: ?std.time.Instant,
    last_frame_time: ?std.time.Instant,

    // Current texture size
    width: u32,
    height: u32,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, device: objc.Object) Self {
        return Self{
            .device = device,
            .allocator = allocator,
            .front_texture = null,
            .back_texture = null,
            .uniform_buffer = null,
            .uniforms = Uniforms.init(),
            .sampler = null,
            .pipelines = .{},
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

        if (self.front_texture) |tex| tex.msgSend(void, "release", .{});
        if (self.back_texture) |tex| tex.msgSend(void, "release", .{});
        if (self.uniform_buffer) |buf| buf.msgSend(void, "release", .{});
        if (self.sampler) |s| s.msgSend(void, "release", .{});
    }

    /// Add a custom shader from MSL-compatible source
    pub fn addShader(
        self: *Self,
        shader_source: []const u8,
        name: []const u8,
        pixel_format: mtl.MTLPixelFormat,
        sample_count: u32,
    ) !void {
        const pipeline = try CustomShaderPipeline.initFromMSL(
            self.allocator,
            self.device,
            shader_source,
            name,
            pixel_format,
            sample_count,
        );
        try self.pipelines.append(self.allocator, pipeline);
        std.log.info("Custom shader '{s}' loaded successfully", .{name});
    }

    /// Ensure textures and buffers match the given size
    pub fn ensureSize(self: *Self, width: u32, height: u32) !void {
        if (self.width == width and self.height == height) return;

        self.width = width;
        self.height = height;

        // Release old textures
        if (self.front_texture) |tex| {
            tex.msgSend(void, "release", .{});
            self.front_texture = null;
        }
        if (self.back_texture) |tex| {
            tex.msgSend(void, "release", .{});
            self.back_texture = null;
        }

        // Create new textures
        self.front_texture = try self.createTexture(width, height);
        self.back_texture = try self.createTexture(width, height);

        // Create uniform buffer if needed
        if (self.uniform_buffer == null) {
            const buffer_ptr = self.device.msgSend(
                ?*anyopaque,
                "newBufferWithLength:options:",
                .{
                    @as(c_ulong, @sizeOf(Uniforms)),
                    @as(c_ulong, @bitCast(mtl.MTLResourceOptions.storage_shared)),
                },
            );
            if (buffer_ptr) |ptr| {
                self.uniform_buffer = objc.Object.fromId(ptr);
            }
        }

        // Create sampler if needed
        if (self.sampler == null) {
            try self.createSampler();
        }

        self.uniforms.setResolution(@floatFromInt(width), @floatFromInt(height));
    }

    fn createTexture(self: *Self, width: u32, height: u32) !objc.Object {
        const MTLTextureDescriptor = objc.getClass("MTLTextureDescriptor") orelse return error.ClassNotFound;

        const desc = MTLTextureDescriptor.msgSend(
            objc.Object,
            "texture2DDescriptorWithPixelFormat:width:height:mipmapped:",
            .{
                @intFromEnum(mtl.MTLPixelFormat.bgra8unorm),
                @as(c_ulong, width),
                @as(c_ulong, height),
                false,
            },
        );

        const usage = mtl.MTLTextureUsage{ .shader_read = true, .render_target = true };
        desc.msgSend(void, "setUsage:", .{@as(c_ulong, @bitCast(usage))});
        desc.msgSend(void, "setStorageMode:", .{@intFromEnum(mtl.MTLStorageMode.private)});

        const texture_ptr = self.device.msgSend(?*anyopaque, "newTextureWithDescriptor:", .{desc.value});
        if (texture_ptr == null) return error.TextureCreationFailed;

        return objc.Object.fromId(texture_ptr);
    }

    fn createSampler(self: *Self) !void {
        const MTLSamplerDescriptor = objc.getClass("MTLSamplerDescriptor") orelse return error.ClassNotFound;

        const desc = MTLSamplerDescriptor.msgSend(objc.Object, "alloc", .{});
        const sampler_desc = desc.msgSend(objc.Object, "init", .{});
        defer sampler_desc.msgSend(void, "release", .{});

        sampler_desc.msgSend(void, "setMinFilter:", .{@as(c_ulong, 1)}); // Linear
        sampler_desc.msgSend(void, "setMagFilter:", .{@as(c_ulong, 1)}); // Linear
        sampler_desc.msgSend(void, "setSAddressMode:", .{@as(c_ulong, 0)}); // ClampToEdge
        sampler_desc.msgSend(void, "setTAddressMode:", .{@as(c_ulong, 0)}); // ClampToEdge

        const sampler_ptr = self.device.msgSend(?*anyopaque, "newSamplerStateWithDescriptor:", .{sampler_desc.value});
        if (sampler_ptr == null) return error.SamplerCreationFailed;

        self.sampler = objc.Object.fromId(sampler_ptr);
    }

    /// Update timing uniforms
    pub fn updateTiming(self: *Self) void {
        const now = std.time.Instant.now() catch return;

        if (self.start_time == null) {
            self.start_time = now;
        }

        const elapsed_ns = now.since(self.start_time.?);
        const elapsed_s: f32 = @floatCast(@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0);

        var delta_s: f32 = 0.016;
        if (self.last_frame_time) |last| {
            const delta_ns = now.since(last);
            delta_s = @floatCast(@as(f64, @floatFromInt(delta_ns)) / 1_000_000_000.0);
        }

        self.uniforms.updateTime(elapsed_s, delta_s);
        self.last_frame_time = now;
    }

    /// Upload current uniforms to GPU buffer
    pub fn uploadUniforms(self: *Self) void {
        const buffer = self.uniform_buffer orelse return;
        const contents = buffer.msgSend(?*anyopaque, "contents", .{});
        if (contents) |ptr| {
            const dest: *Uniforms = @ptrCast(@alignCast(ptr));
            dest.* = self.uniforms;
        }
    }

    pub fn hasShaders(self: *const Self) bool {
        return self.pipelines.items.len > 0;
    }

    pub fn swapTextures(self: *Self) void {
        const tmp = self.front_texture;
        self.front_texture = self.back_texture;
        self.back_texture = tmp;
    }
};

// ============================================================================
// Built-in Example Shaders
// ============================================================================

/// Simple passthrough shader
pub const passthrough_shader =
    \\void mainImage(thread float4& fragColor, float2 fragCoord,
    \\               constant ShaderUniforms& uniforms,
    \\               texture2d<float> iChannel0,
    \\               sampler iChannel0Sampler) {
    \\    float2 uv = fragCoord / uniforms.iResolution.xy;
    \\    fragColor = iChannel0.sample(iChannel0Sampler, uv);
    \\}
;

/// VHS Glitch - Retro analog video with tracking errors, RGB bleeding, and tape artifacts
pub const vhs_glitch_shader =
    \\void mainImage(thread float4& fragColor, float2 fragCoord,
    \\               constant ShaderUniforms& uniforms,
    \\               texture2d<float> iChannel0,
    \\               sampler iChannel0Sampler) {
    \\    float2 uv = fragCoord / uniforms.iResolution.xy;
    \\    float time = uniforms.iTime;
    \\
    \\    // Tracking wobble - horizontal displacement that varies by scanline
    \\    float wobble = sin(uv.y * 100.0 + time * 2.0) * 0.001;
    \\    wobble += sin(uv.y * 50.0 - time * 3.0) * 0.0005;
    \\
    \\    // Occasional horizontal tear/glitch bands
    \\    float glitchLine = step(0.99, fract(sin(floor(uv.y * 80.0) + time * 5.0) * 43758.5));
    \\    float glitchOffset = glitchLine * (fract(sin(time * 100.0) * 1000.0) - 0.5) * 0.08;
    \\
    \\    // VHS tracking error - big horizontal shifts that roll through
    \\    float trackingPhase = fract(time * 0.1);
    \\    float trackingY = fract(uv.y - trackingPhase);
    \\    float trackingBand = smoothstep(0.0, 0.02, trackingY) * smoothstep(0.08, 0.02, trackingY);
    \\    float trackingShift = trackingBand * sin(time * 20.0) * 0.03;
    \\
    \\    // Apply horizontal distortions
    \\    float2 distortedUV = uv;
    \\    distortedUV.x += wobble + glitchOffset + trackingShift;
    \\
    \\    // RGB channel separation (VHS color bleeding)
    \\    float rgbSplit = 0.004 + glitchLine * 0.01;
    \\    float4 color;
    \\    color.r = iChannel0.sample(iChannel0Sampler, distortedUV + float2(rgbSplit, 0.0)).r;
    \\    color.g = iChannel0.sample(iChannel0Sampler, distortedUV).g;
    \\    color.b = iChannel0.sample(iChannel0Sampler, distortedUV - float2(rgbSplit, 0.0)).b;
    \\    color.a = 1.0;
    \\
    \\    // Scanlines (NTSC-style)
    \\    float scanline = sin(fragCoord.y * 1.5) * 0.5 + 0.5;
    \\    scanline = pow(scanline, 0.8) * 0.12 + 0.88;
    \\    color.rgb *= scanline;
    \\
    \\    // VHS noise/static grain
    \\    float noise = fract(sin(dot(fragCoord + time * 1000.0, float2(12.9898, 78.233))) * 43758.5453);
    \\    color.rgb += (noise - 0.5) * 0.06;
    \\
    \\    // Bottom screen noise band (like worn tape)
    \\    float bottomNoise = smoothstep(0.92, 1.0, uv.y);
    \\    float staticNoise = fract(sin(fragCoord.x * 0.1 + time * 500.0) * 10000.0);
    \\    color.rgb = mix(color.rgb, float3(staticNoise), bottomNoise * 0.7);
    \\
    \\    // Color bleed/smear to the right (VHS artifact)
    \\    float4 smear = iChannel0.sample(iChannel0Sampler, distortedUV - float2(0.01, 0.0));
    \\    color.rgb = mix(color.rgb, smear.rgb, 0.15);
    \\
    \\    // Slight color degradation (reduce saturation)
    \\    float luma = dot(color.rgb, float3(0.299, 0.587, 0.114));
    \\    color.rgb = mix(float3(luma), color.rgb, 0.85);
    \\
    \\    // Warm VHS color cast
    \\    color.r *= 1.05;
    \\    color.b *= 0.92;
    \\
    \\    // Vignette (darker corners like old TV)
    \\    float2 vignetteUV = uv * (1.0 - uv);
    \\    float vignette = vignetteUV.x * vignetteUV.y * 15.0;
    \\    vignette = clamp(pow(vignette, 0.25), 0.0, 1.0);
    \\    color.rgb *= vignette;
    \\
    \\    // Subtle brightness fluctuation
    \\    float flicker = 0.98 + sin(time * 12.0) * 0.01 + sin(time * 23.0) * 0.005;
    \\    color.rgb *= flicker;
    \\
    \\    fragColor = color;
    \\}
;

pub const crt_shader =
    \\void mainImage(thread float4& fragColor, float2 fragCoord,
    \\               constant ShaderUniforms& uniforms,
    \\               texture2d<float> iChannel0,
    \\               sampler iChannel0Sampler) {
    \\    float2 uv = fragCoord / uniforms.iResolution.xy;
    \\
    \\    // Subtle CRT barrel distortion
    \\    float2 center = uv - 0.5;
    \\    float dist = dot(center, center);
    \\    uv = uv + center * dist * 0.1;
    \\
    \\    // Sample with chromatic aberration
    \\    float4 color;
    \\    color.r = iChannel0.sample(iChannel0Sampler, uv + float2(0.002, 0.0)).r;
    \\    color.g = iChannel0.sample(iChannel0Sampler, uv).g;
    \\    color.b = iChannel0.sample(iChannel0Sampler, uv - float2(0.002, 0.0)).b;
    \\    color.a = 1.0;
    \\
    \\    // Visible scanlines (every ~3 pixels)
    \\    float scanline = sin(fragCoord.y * 0.7) * 0.5 + 0.5;
    \\    scanline = pow(scanline, 1.5) * 0.15 + 0.85;
    \\    color.rgb *= scanline;
    \\
    \\    // Animated vertical sync roll
    \\    float roll = sin(uniforms.iTime * 0.5) * 0.002;
    \\    color.rgb += roll;
    \\
    \\    // Flickering
    \\    float flicker = sin(uniforms.iTime * 15.0) * 0.02 + 1.0;
    \\    color.rgb *= flicker;
    \\
    \\    // Vignette
    \\    float vignette = 1.0 - dist * 1.5;
    \\    color.rgb *= vignette;
    \\
    \\    fragColor = color;
    \\}
;

/// Debug shader - visualizes iTime to verify uniforms are working
pub const debug_time_shader =
    \\void mainImage(thread float4& fragColor, float2 fragCoord,
    \\               constant ShaderUniforms& uniforms,
    \\               texture2d<float> iChannel0,
    \\               sampler iChannel0Sampler) {
    \\    float2 uv = fragCoord / uniforms.iResolution.xy;
    \\    float4 color = iChannel0.sample(iChannel0Sampler, uv);
    \\    float pulse = sin(uniforms.iTime * 3.0) * 0.5 + 0.5;
    \\    fragColor = mix(color, float4(pulse, 0.2, 1.0 - pulse, 1.0), 0.3);
    \\}
;

/// Animated wave distortion
pub const wave_shader =
    \\void mainImage(thread float4& fragColor, float2 fragCoord,
    \\               constant ShaderUniforms& uniforms,
    \\               texture2d<float> iChannel0,
    \\               sampler iChannel0Sampler) {
    \\    float2 uv = fragCoord / uniforms.iResolution.xy;
    \\    float time = uniforms.iTime;
    \\
    \\    // Heat shimmer / underwater effect
    \\    float2 distort;
    \\    distort.x = sin(uv.y * 30.0 + time * 4.0) * cos(uv.x * 20.0 + time * 2.0);
    \\    distort.y = cos(uv.y * 25.0 - time * 3.0) * sin(uv.x * 15.0 + time * 2.5);
    \\
    \\    // Apply distortion with edge fade
    \\    float2 center = abs(uv - 0.5) * 2.0;
    \\    float edgeFade = 1.0 - max(center.x, center.y);
    \\    edgeFade = smoothstep(0.0, 0.3, edgeFade);
    \\
    \\    uv += distort * 0.015 * edgeFade;
    \\    fragColor = iChannel0.sample(iChannel0Sampler, uv);
    \\}
;

/// Blur effect
pub const blur_shader =
    \\void mainImage(thread float4& fragColor, float2 fragCoord,
    \\               constant ShaderUniforms& uniforms,
    \\               texture2d<float> iChannel0,
    \\               sampler iChannel0Sampler) {
    \\    float2 uv = fragCoord / uniforms.iResolution.xy;
    \\    float2 pixel = 1.0 / uniforms.iResolution.xy;
    \\    float4 color = float4(0.0);
    \\    for (int x = -1; x <= 1; x++) {
    \\        for (int y = -1; y <= 1; y++) {
    \\            float2 offset = float2(float(x), float(y)) * pixel;
    \\            color += iChannel0.sample(iChannel0Sampler, uv + offset);
    \\        }
    \\    }
    \\    fragColor = color / 9.0;
    \\}
;
