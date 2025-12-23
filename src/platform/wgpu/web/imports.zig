//! JavaScript/Browser API imports for WASM
//!
//! These extern functions are provided by the JavaScript host.
//! They bridge the gap between Zig/WASM and browser APIs.

const std = @import("std");

// =============================================================================
// Console / Debug
// =============================================================================

pub extern "env" fn consoleLog(ptr: [*]const u8, len: u32) void;
pub extern "env" fn consoleError(ptr: [*]const u8, len: u32) void;

pub fn log(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const str = std.fmt.bufPrint(&buf, fmt, args) catch return;
    consoleLog(str.ptr, @intCast(str.len));
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const str = std.fmt.bufPrint(&buf, fmt, args) catch return;
    consoleError(str.ptr, @intCast(str.len));
}

// =============================================================================
// Canvas / Window
// =============================================================================

pub extern "env" fn getCanvasWidth() u32;
pub extern "env" fn getCanvasHeight() u32;
pub extern "env" fn getDevicePixelRatio() f32;
/// Get canvas actual pixel width (canvas.width, not clientWidth)
pub extern "env" fn getCanvasPixelWidth() u32;
pub extern "env" fn getCanvasPixelHeight() u32;
pub extern "env" fn setCanvasSize(width: u32, height: u32) void;
pub extern "env" fn setDocumentTitle(ptr: [*]const u8, len: u32) void;

/// Position the hidden input element for IME candidate window placement
pub extern "env" fn setImeCursorPosition(x: f32, y: f32, width: f32, height: f32) void;

// =============================================================================
// WebGPU - Device/Queue handles are managed by JS
// =============================================================================

/// Request the current frame's texture view for rendering
pub extern "env" fn getCurrentTextureView() u32;

/// Release a texture view handle
pub extern "env" fn releaseTextureView(handle: u32) void;

// =============================================================================
// WebGPU - Post-Processing Support
// =============================================================================

/// Create a render texture (can be rendered to and sampled from)
pub extern "env" fn createRenderTexture(width: u32, height: u32) u32;

/// Create a texture view from a texture handle
pub extern "env" fn createTextureView(texture_handle: u32) u32;

/// Create a post-process render pipeline (fullscreen shader)
pub extern "env" fn createPostProcessPipeline(shader_handle: u32) u32;

/// Create a bind group for post-process shader
pub extern "env" fn createPostProcessBindGroup(
    pipeline_handle: u32,
    uniform_buffer: u32,
    texture_handle: u32,
    sampler_handle: u32,
) u32;

/// Begin a render pass to a texture (not the screen)
pub extern "env" fn beginTextureRenderPass(texture_view: u32, r: f32, g: f32, b: f32, a: f32) void;

/// Copy the current screen to a texture for post-processing
pub extern "env" fn copyToTexture(src_view: u32, dst_texture: u32, width: u32, height: u32) void;

// =============================================================================
// WebGPU - Shader Creation
// =============================================================================

/// Create a shader module from WGSL source
pub extern "env" fn createShaderModule(code_ptr: [*]const u8, code_len: u32) u32;

/// Create a render pipeline
pub extern "env" fn createRenderPipeline(
    shader_handle: u32,
    vertex_entry: [*]const u8,
    vertex_entry_len: u32,
    fragment_entry: [*]const u8,
    fragment_entry_len: u32,
) u32;

/// Create a GPU buffer
pub extern "env" fn createBuffer(size: u32, usage: u32) u32;

/// Write data to a buffer
pub extern "env" fn writeBuffer(handle: u32, offset: u32, data_ptr: [*]const u8, data_len: u32) void;

/// Create a bind group
pub extern "env" fn createBindGroup(pipeline_handle: u32, group_index: u32, buffer_handles_ptr: [*]const u32, buffer_handles_len: u32) u32;

/// Begin a render pass (clears with given color)
pub extern "env" fn beginRenderPass(texture_view: u32, r: f32, g: f32, b: f32, a: f32) void;

/// Set the current pipeline for rendering
pub extern "env" fn setPipeline(pipeline_handle: u32) void;

/// Set the current bind group
pub extern "env" fn setBindGroup(group_index: u32, bind_group_handle: u32) void;

/// Draw instanced primitives
pub extern "env" fn drawInstanced(vertex_count: u32, instance_count: u32) void;

/// End the render pass and submit
pub extern "env" fn endRenderPass() void;

// =============================================================================
// Animation Frame
// =============================================================================

/// Request the next animation frame - JS will call back into WASM
pub extern "env" fn requestAnimationFrame() void;

/// Get the timestamp of the current frame (milliseconds)
pub extern "env" fn getFrameTime() f64;

/// Get current timestamp in milliseconds (from JS Date.now())
pub extern "env" fn getTimestampMillis() f64;

// =============================================================================
// Input Events (polled from JS)
// =============================================================================

pub extern "env" fn getMouseX() f32;
pub extern "env" fn getMouseY() f32;
pub extern "env" fn getMouseButtons() u32; // bitmask: 1=left, 2=right, 4=middle
pub extern "env" fn isMouseInCanvas() bool;

// =============================================================================
// Text / Font
// =============================================================================

/// Get font metrics (returns packed: ascent | descent | line_height as f32s)
pub extern "env" fn getFontMetrics(
    font_ptr: [*]const u8,
    font_len: u32,
    size: f32,
    out_ascent: *f32,
    out_descent: *f32,
    out_line_height: *f32,
) void;

/// Measure text width
pub extern "env" fn measureTextWidth(
    font_ptr: [*]const u8,
    font_len: u32,
    size: f32,
    text_ptr: [*]const u8,
    text_len: u32,
) f32;

/// Rasterize a glyph, returns width/height, writes pixels to buffer
pub extern "env" fn rasterizeGlyph(
    font_ptr: [*]const u8,
    font_len: u32,
    size: f32,
    codepoint: u32,
    out_buffer: [*]u8,
    buffer_size: u32,
    out_width: *u32,
    out_height: *u32,
    out_bearing_x: *f32,
    out_bearing_y: *f32,
    out_advance: *f32,
) void;

/// Rasterize a glyph with subpixel positioning
pub extern "env" fn rasterizeGlyphSubpixel(
    font_ptr: [*]const u8,
    font_len: u32,
    size: f32,
    codepoint: u32,
    subpixel_x: f32,
    subpixel_y: f32,
    out_buffer: [*]u8,
    buffer_size: u32,
    out_width: *u32,
    out_height: *u32,
    out_bearing_x: *f32,
    out_bearing_y: *f32,
    out_advance: *f32,
) void;

/// Create a texture from pixel data
pub extern "env" fn createTexture(width: u32, height: u32, data_ptr: [*]const u8, data_len: u32) u32;

/// Update an existing texture with new pixel data
pub extern "env" fn updateTexture(handle: u32, width: u32, height: u32, data_ptr: [*]const u8, data_len: u32) void;

/// Create a sampler
pub extern "env" fn createSampler() u32;

/// Create bind group with texture
pub extern "env" fn createTextBindGroup(
    pipeline_handle: u32,
    group_index: u32,
    glyph_buffer: u32,
    uniform_buffer: u32,
    texture_handle: u32,
    sampler_handle: u32,
) u32;

// =============================================================================
// SVG Rasterization
// =============================================================================

/// Rasterize an SVG path to an RGBA buffer using JS Path2D/Canvas2D
/// Returns true on success, false on failure
pub extern "env" fn rasterizeSvgPath(
    path_ptr: [*]const u8,
    path_len: u32,
    device_size: u32,
    viewbox: f32,
    has_fill: bool,
    stroke_width: f32,
    out_buffer: [*]u8,
    buffer_size: u32,
    out_width: *u32,
    out_height: *u32,
    out_offset_x: *i16,
    out_offset_y: *i16,
) bool;

/// Create an RGBA texture (for SVG atlas, unlike text atlas which is R8)
pub extern "env" fn createRgbaTexture(width: u32, height: u32, data_ptr: [*]const u8, data_len: u32) u32;

/// Update an existing RGBA texture with new pixel data
pub extern "env" fn updateRgbaTexture(handle: u32, width: u32, height: u32, data_ptr: [*]const u8, data_len: u32) void;

/// Create bind group for SVG pipeline (same layout as text but uses RGBA texture)
pub extern "env" fn createSvgBindGroup(
    pipeline_handle: u32,
    group_index: u32,
    svg_buffer: u32,
    uniform_buffer: u32,
    texture_handle: u32,
    sampler_handle: u32,
) u32;

// =============================================================================
// MSAA (Multisampling Anti-Aliasing) Support
// =============================================================================

/// Create an MSAA texture for multisampled rendering
pub extern "env" fn createMSAATexture(width: u32, height: u32, sample_count: u32) u32;

/// Destroy an MSAA texture (call on resize)
pub extern "env" fn destroyTexture(texture_handle: u32) void;

/// Create a render pipeline with MSAA support
pub extern "env" fn createMSAARenderPipeline(
    shader_handle: u32,
    vertex_entry: [*]const u8,
    vertex_entry_len: u32,
    fragment_entry: [*]const u8,
    fragment_entry_len: u32,
    sample_count: u32,
) u32;

/// Begin an MSAA render pass (renders to MSAA texture, resolves to target)
pub extern "env" fn beginMSAARenderPass(
    msaa_texture_handle: u32,
    resolve_view_handle: u32,
    r: f32,
    g: f32,
    b: f32,
    a: f32,
) void;

/// Get the current MSAA sample count (4 if supported, 1 otherwise)
pub extern "env" fn getMSAASampleCount() u32;
