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
pub extern "env" fn getDevicePixelRatio() f64;
pub extern "env" fn setCanvasSize(width: u32, height: u32) void;
pub extern "env" fn setDocumentTitle(ptr: [*]const u8, len: u32) void;

pub extern "env" fn setCanvasCursor(shape: u32) void;

pub extern "env" fn setImeCursorPosition(x: f32, y: f32, width: f32, height: f32) void;

pub extern "env" fn createShaderModule(code_ptr: [*]const u8, code_len: u32) u32;

pub extern "env" fn createBuffer(size: u32, usage: u32) u32;

pub extern "env" fn writeBuffer(
    handle: u32,
    offset: u32,
    data_ptr: [*]const u8,
    data_len: u32,
) void;

pub extern "env" fn deviceMaxTextureDimension2D() u32;
pub extern "env" fn deviceMaxStorageBufferBindingSize() u32;

pub extern "env" fn createPackedLayout() u32;

pub extern "env" fn createPackedPipeline(
    layout: u32,
    shader: u32,
    vertex_entry: [*]const u8,
    vertex_entry_len: u32,
    fragment_entry: [*]const u8,
    fragment_entry_len: u32,
    premultiplied: bool,
) u32;

pub extern "env" fn createPackedBindGroup(
    layout: u32,
    buffers_ptr: [*]const u32,
    buffers_len: u32,
    textures_ptr: [*]const u32,
    textures_len: u32,
    sampler: u32,
) u32;

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

pub extern "env" fn requestAnimationFrame() void;

pub extern "env" fn getFrameTime() f64;

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

pub extern "env" fn createAtlasTexture(width: u32, height: u32, bytes_per_pixel: u32) u32;

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

pub extern "env" fn createSampler() u32;

pub extern "env" fn clipboardWriteText(ptr: [*]const u8, len: u32) void;

pub extern "env" fn isApplePlatform() bool;
