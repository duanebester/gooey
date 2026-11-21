// Extern functions provided by the JavaScript host; they bridge WASM and
// browser APIs.

const std = @import("std");

pub extern "env" fn consoleLog(ptr: [*]const u8, len: u32) void;
pub extern "env" fn consoleError(ptr: [*]const u8, len: u32) void;

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

pub extern "env" fn getCanvasWidth() u32;
pub extern "env" fn getCanvasHeight() u32;
/// `window.devicePixelRatio`; `f64` because a JS `Number` is an IEEE-754
/// double, so this is the host's own width.
pub extern "env" fn getDevicePixelRatio() f64;
/// Resizing clears the canvas.
pub extern "env" fn setCanvasSize(width: u32, height: u32) void;
pub extern "env" fn setDocumentTitle(ptr: [*]const u8, len: u32) void;

/// `@intFromEnum(interface.CursorShape)`, in the order `default`, `text`,
/// `pointer`.
pub extern "env" fn setCanvasCursor(shape: u32) void;

pub extern "env" fn setImeCursorPosition(x: f32, y: f32, width: f32, height: f32) void;

// WebGPU. JavaScript owns the device, the queue, and every GPU object; WASM
// holds their handles (non-zero `u32`s). The bind group layout is fixed:
// storage buffers 0 to 4 and the uniform buffer 5 for the vertex stage,
// textures 6 to 8 and the sampler 9 for the fragment stage
// (`shaders/packed.wgsl`).

/// Compilation errors reach the console asynchronously.
pub extern "env" fn createShaderModule(code_ptr: [*]const u8, code_len: u32) u32;

pub extern "env" fn createBuffer(size: u32, usage: u32) u32;

/// Copies `data_len` bytes from WASM memory before it returns; the write
/// lands on the queue after every earlier submit.
pub extern "env" fn writeBuffer(
    handle: u32,
    offset: u32,
    data_ptr: [*]const u8,
    data_len: u32,
) void;

/// The device's `maxTextureDimension2D` and `maxStorageBufferBindingSize`.
pub extern "env" fn deviceMaxTextureDimension2D() u32;
pub extern "env" fn deviceMaxStorageBufferBindingSize() u32;

pub extern "env" fn createPackedLayout() u32;

/// `premultiplied` selects the blend for a fragment shader that already
/// multiplies colour by alpha.
pub extern "env" fn createPackedPipeline(
    layout: u32,
    shader: u32,
    vertex_entry: [*]const u8,
    vertex_entry_len: u32,
    fragment_entry: [*]const u8,
    fragment_entry_len: u32,
    premultiplied: bool,
) u32;

/// Bindings: six buffers (0 to 5), three atlas textures (6 to 8), and a
/// sampler (9).
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

pub extern "env" fn setPipeline(pipeline_handle: u32) void;
pub extern "env" fn setBindGroup(group_index: u32, bind_group_handle: u32) void;
pub extern "env" fn setScissorRect(x: u32, y: u32, width: u32, height: u32) void;
pub extern "env" fn draw(
    vertex_count: u32,
    instance_count: u32,
    first_vertex: u32,
    first_instance: u32,
) void;

pub extern "env" fn endFrame() void;

/// JS will call back into WASM.
pub extern "env" fn requestAnimationFrame() void;

/// Milliseconds.
pub extern "env" fn getFrameTime() f64;

/// Milliseconds (JS `Date.now()`).
pub extern "env" fn getTimestampMillis() f64;

pub extern "env" fn getFontMetrics(
    font_ptr: [*]const u8,
    font_len: u32,
    size: f32,
    out_ascent: *f32,
    out_descent: *f32,
    out_line_height: *f32,
) void;

pub extern "env" fn measureText(
    font_ptr: [*]const u8,
    font_len: u32,
    size: f32,
    text_ptr: [*]const u8,
    text_len: u32,
) f32;

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

/// Zero-initialized: R8 when `bytes_per_pixel` is 1, RGBA8 when it is 4.
pub extern "env" fn createAtlasTexture(width: u32, height: u32, bytes_per_pixel: u32) u32;

/// `queue.writeTexture`: copies before it returns, landing after every
/// earlier submit.
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

/// Linear filtering, clamped to the edge.
pub extern "env" fn createSampler() u32;

/// Fire-and-forget (async in JS).
pub extern "env" fn clipboardWriteText(ptr: [*]const u8, len: u32) void;

/// Whether the browser runs on macOS or iOS, whose text fields take edit
/// commands with Cmd rather than Ctrl.
pub extern "env" fn isApplePlatform() bool;
