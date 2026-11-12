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

/// Log a comptime string directly - no stack allocation, no formatting.
/// Use this for the earliest possible debugging before stack is verified.
pub fn logRaw(comptime msg: []const u8) void {
    consoleLog(msg.ptr, msg.len);
}

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
/// `window.devicePixelRatio`.
///
/// `f64` because a JS `Number` *is* an IEEE-754 double, so this is the host's
/// own width. Declaring it `f32` narrowed the host value and then
/// `WebWindow.updateSize` widened it straight back, which bought nothing and
/// cost precision on fractional browser-zoom ratios.
pub extern "env" fn getDevicePixelRatio() f64;
/// Size the canvas's drawing buffer to `width` x `height` device pixels and
/// reconfigure its WebGPU context. Resizing clears the canvas.
pub extern "env" fn setCanvasSize(width: u32, height: u32) void;
pub extern "env" fn setDocumentTitle(ptr: [*]const u8, len: u32) void;

/// Set the canvas's CSS cursor: `@intFromEnum(interface.CursorShape)`, in
/// the order `default`, `text`, `pointer`.
pub extern "env" fn setCanvasCursor(shape: u32) void;

/// Position the hidden input element for IME candidate window placement
pub extern "env" fn setImeCursorPosition(x: f32, y: f32, width: f32, height: f32) void;

// =============================================================================
// WebGPU - the packed-frame renderer (`renderer.zig`)
// =============================================================================
//
// JavaScript owns the device, the queue, and every GPU object; WASM holds
// their handles (non-zero `u32`s). The bind group layout is fixed: storage
// buffers 0 to 4 and the uniform buffer 5 for the vertex stage, textures 6 to
// 8 and the sampler 9 for the fragment stage (`shaders/packed.wgsl`).

/// Create a shader module from WGSL source. Compilation errors reach the
/// console asynchronously, as does any validation error the device raises.
pub extern "env" fn createShaderModule(code_ptr: [*]const u8, code_len: u32) u32;

/// Create a GPU buffer of `size` bytes with `GPUBufferUsage` flags `usage`.
pub extern "env" fn createBuffer(size: u32, usage: u32) u32;

/// `queue.writeBuffer`: copies `data_len` bytes from WASM memory before it
/// returns; the write lands on the queue after every earlier submit.
pub extern "env" fn writeBuffer(
    handle: u32,
    offset: u32,
    data_ptr: [*]const u8,
    data_len: u32,
) void;

/// The device's `maxTextureDimension2D` and `maxStorageBufferBindingSize`.
pub extern "env" fn deviceMaxTextureDimension2D() u32;
pub extern "env" fn deviceMaxStorageBufferBindingSize() u32;

/// Create the packed frame's bind group layout and the pipeline layout over
/// it; returns the pipeline layout.
pub extern "env" fn createPackedLayout() u32;

/// Create a render pipeline on `layout` drawing triangle lists into the
/// canvas format with one sample. `premultiplied` selects the blend for a
/// fragment shader that already multiplies colour by alpha.
pub extern "env" fn createPackedPipeline(
    layout: u32,
    shader: u32,
    vertex_entry: [*]const u8,
    vertex_entry_len: u32,
    fragment_entry: [*]const u8,
    fragment_entry_len: u32,
    premultiplied: bool,
) u32;

/// Create the one bind group of `layout`: six buffers (bindings 0 to 5),
/// three atlas textures (6 to 8), and a sampler (9).
pub extern "env" fn createPackedBindGroup(
    layout: u32,
    buffers_ptr: [*]const u32,
    buffers_len: u32,
    textures_ptr: [*]const u32,
    textures_len: u32,
    sampler: u32,
) u32;

/// Begin the frame: take the canvas's current texture, open a command
/// encoder and a render pass cleared to the colour. False when the canvas
/// has no texture to draw into; nothing is open then.
pub extern "env" fn beginFrame(r: f32, g: f32, b: f32, a: f32) bool;

/// Encoding into the open render pass.
pub extern "env" fn setPipeline(pipeline_handle: u32) void;
pub extern "env" fn setBindGroup(group_index: u32, bind_group_handle: u32) void;
pub extern "env" fn setScissorRect(x: u32, y: u32, width: u32, height: u32) void;
pub extern "env" fn draw(
    vertex_count: u32,
    instance_count: u32,
    first_vertex: u32,
    first_instance: u32,
) void;

/// End the render pass and submit the frame; the canvas presents it.
pub extern "env" fn endFrame() void;

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
pub extern "env" fn measureText(
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

/// Create a zero-initialized atlas texture: R8 when `bytes_per_pixel` is 1,
/// RGBA8 when it is 4. Called once per atlas at its budget size.
pub extern "env" fn createAtlasTexture(width: u32, height: u32, bytes_per_pixel: u32) u32;

/// Write tightly packed rows of `width × bytes_per_pixel` bytes into the
/// rectangle at `(x, y)` of an atlas texture with `queue.writeTexture`, which
/// copies them before it returns and lands after every earlier submit.
pub extern "env" fn writeAtlasRegion(
    handle: u32,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    bytes_per_pixel: u32,
    data_ptr: [*]const u8,
    data_len: u32,
) void;

/// Create the atlas sampler: linear filtering, clamped to the edge.
pub extern "env" fn createSampler() u32;

// =============================================================================
// Clipboard
// =============================================================================

/// Write text to clipboard. Fire-and-forget from WASM side (async in JS).
pub extern "env" fn clipboardWriteText(ptr: [*]const u8, len: u32) void;

/// Whether the browser runs on macOS or iOS, whose text fields take edit
/// commands with Cmd rather than Ctrl.
pub extern "env" fn isApplePlatform() bool;
