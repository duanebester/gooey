//! Linux framebuffer device output (`/dev/fb0`) for the fbdev backend.
//!
//! The device is opened and mapped once during initialization. Frames are
//! rendered into a RAM back buffer and copied here row by row, because
//! framebuffer memory is often uncached or write-combined and the renderer's
//! read-modify-write blending would be slow on it. The copy also converts to
//! the panel's pixel format: 32 bpp XRGB/ARGB is a plain copy, and any other
//! 16 or 32 bpp layout with channels of at most 8 bits (RGB565, BGR, and so
//! on) is converted per pixel.
//!
//! When the driver supports `FBIO_WAITFORVSYNC`, each copy starts at vertical
//! blank to reduce tearing. There is no page flipping: a full copy of an
//! 800x480 frame is about 1.5 MB and finishes well within one refresh.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const raster = @import("../cpu/raster.zig");
const limits = @import("../../core/limits.zig");

const assert = std.debug.assert;

// `ioctl` requests from <linux/fb.h>.
const FBIOGET_VSCREENINFO: u32 = 0x4600;
const FBIOGET_FSCREENINFO: u32 = 0x4602;
/// `_IOW('F', 0x20, __u32)`.
const FBIO_WAITFORVSYNC: u32 = 0x4004_4620;

/// Largest panel the backend accepts: the framework's framebuffer ceiling.
/// The window then checks the panel against the app's own budget.
const width_max = limits.MAX_FRAMEBUFFER_WIDTH;
const height_max = limits.MAX_FRAMEBUFFER_HEIGHT;

pub const Bitfield = extern struct {
    offset: u32,
    length: u32,
    msb_right: u32,
};

/// `struct fb_var_screeninfo`.
pub const VarScreenInfo = extern struct {
    xres: u32,
    yres: u32,
    xres_virtual: u32,
    yres_virtual: u32,
    xoffset: u32,
    yoffset: u32,
    bits_per_pixel: u32,
    grayscale: u32,
    red: Bitfield,
    green: Bitfield,
    blue: Bitfield,
    transp: Bitfield,
    nonstd: u32,
    activate: u32,
    height: u32,
    width: u32,
    accel_flags: u32,
    pixclock: u32,
    left_margin: u32,
    right_margin: u32,
    upper_margin: u32,
    lower_margin: u32,
    hsync_len: u32,
    vsync_len: u32,
    sync: u32,
    vmode: u32,
    rotate: u32,
    colorspace: u32,
    reserved: [4]u32,
};

/// `struct fb_fix_screeninfo`. `unsigned long` fields follow the target ABI.
pub const FixScreenInfo = extern struct {
    id: [16]u8,
    smem_start: c_ulong,
    smem_len: u32,
    type: u32,
    type_aux: u32,
    visual: u32,
    xpanstep: u16,
    ypanstep: u16,
    ywrapstep: u16,
    line_length: u32,
    mmio_start: c_ulong,
    mmio_len: u32,
    accel: u32,
    capabilities: u16,
    reserved: [2]u16,
};

comptime {
    // Sizes are fixed by the kernel ABI; a mismatch would make the `ioctl`
    // write past the struct.
    assert(@sizeOf(VarScreenInfo) == 160);
    assert(@sizeOf(FixScreenInfo) == if (@sizeOf(c_ulong) == 8) 80 else 68);
}

/// One color channel's position within a device pixel.
pub const Channel = struct {
    offset: u5,
    /// Bits in the channel, 1 through 8.
    length: u4,
};

/// How a device pixel is laid out.
pub const PixelLayout = struct {
    bytes_per_pixel: u8,
    red: Channel,
    green: Channel,
    blue: Channel,
    /// Alpha bits, set to all ones, or null when the format has none.
    alpha: ?Channel,

    /// The renderer's own `0xAARRGGBB` format, presented with a plain copy.
    pub fn isNative(self: PixelLayout) bool {
        assert(self.bytes_per_pixel == 2 or self.bytes_per_pixel == 4);
        return self.bytes_per_pixel == 4 and
            self.red.offset == 16 and self.red.length == 8 and
            self.green.offset == 8 and self.green.length == 8 and
            self.blue.offset == 0 and self.blue.length == 8;
    }

    pub fn fromScreenInfo(info: *const VarScreenInfo) error{UnsupportedPixelFormat}!PixelLayout {
        assert(info.xres > 0);
        assert(info.yres > 0);
        if (info.bits_per_pixel != 16 and info.bits_per_pixel != 32) {
            return error.UnsupportedPixelFormat;
        }
        // Grayscale and FOURCC (`grayscale > 1`) panels have no RGB fields.
        if (info.grayscale != 0) return error.UnsupportedPixelFormat;
        const layout = PixelLayout{
            .bytes_per_pixel = @intCast(info.bits_per_pixel / 8),
            .red = try channel(info.red, info.bits_per_pixel),
            .green = try channel(info.green, info.bits_per_pixel),
            .blue = try channel(info.blue, info.bits_per_pixel),
            .alpha = if (info.transp.length == 0)
                null
            else
                try channel(info.transp, info.bits_per_pixel),
        };
        assert(layout.bytes_per_pixel == 2 or layout.bytes_per_pixel == 4);
        return layout;
    }

    fn channel(field: Bitfield, bits_per_pixel: u32) error{UnsupportedPixelFormat}!Channel {
        assert(bits_per_pixel == 16 or bits_per_pixel == 32);
        // `msb_right` panels store channel bits reversed; none are in use on
        // current drivers, so reject them rather than draw garbage.
        if (field.msb_right != 0) return error.UnsupportedPixelFormat;
        if (field.length == 0 or field.length > 8) return error.UnsupportedPixelFormat;
        if (field.offset + field.length > bits_per_pixel) return error.UnsupportedPixelFormat;
        return .{ .offset = @intCast(field.offset), .length = @intCast(field.length) };
    }
};

/// Convert one `0xAARRGGBB` pixel to the device layout, truncating each
/// channel to its width.
pub fn convertPixel(pixel: u32, layout: PixelLayout) u32 {
    assert(layout.red.length >= 1);
    assert(layout.red.length <= 8);
    assert(layout.blue.length >= 1);
    assert(layout.blue.length <= 8);
    var result = placeChannel((pixel >> 16) & 0xFF, layout.red) |
        placeChannel((pixel >> 8) & 0xFF, layout.green) |
        placeChannel(pixel & 0xFF, layout.blue);
    if (layout.alpha) |alpha| result |= placeChannel(0xFF, alpha);
    return result;
}

fn placeChannel(value: u32, field: Channel) u32 {
    assert(value <= 0xFF);
    assert(field.length >= 1);
    assert(field.length <= 8);
    const shift: u5 = @intCast(8 - @as(u32, field.length));
    return (value >> shift) << field.offset;
}

/// Write one row of renderer pixels into device memory.
pub fn convertRow(source: []const u32, target: []u8, layout: PixelLayout) void {
    assert(target.len == source.len * layout.bytes_per_pixel);
    assert(layout.bytes_per_pixel == 2 or layout.bytes_per_pixel == 4);
    if (layout.isNative()) {
        @memcpy(target, std.mem.sliceAsBytes(source));
        return;
    }
    for (source, 0..) |pixel, index| {
        const value = convertPixel(pixel, layout);
        if (layout.bytes_per_pixel == 4) {
            std.mem.writeInt(u32, target[index * 4 ..][0..4], value, .little);
        } else {
            std.mem.writeInt(u16, target[index * 2 ..][0..2], @intCast(value), .little);
        }
    }
}

pub const Framebuffer = struct {
    fd: posix.fd_t = -1,
    memory: []align(std.heap.page_size_min) u8 = &.{},
    /// Visible resolution in pixels.
    width: u32 = 0,
    height: u32 = 0,
    /// Bytes between the starts of consecutive device rows.
    line_length: u32 = 0,
    /// Byte offset of the visible area's first pixel within `memory`.
    visible_offset: usize = 0,
    layout: PixelLayout = undefined,
    /// Cleared after the first `FBIO_WAITFORVSYNC` failure.
    vsync_supported: bool = true,

    /// Open and map the device at `path`.
    pub fn open(self: *Framebuffer, path: [*:0]const u8) !void {
        assert(self.fd < 0);
        assert(self.memory.len == 0);
        const fd = try posix.openatZ(posix.AT.FDCWD, path, .{
            .ACCMODE = .RDWR,
            .CLOEXEC = true,
        }, 0);
        errdefer _ = std.c.close(fd);

        var variable: VarScreenInfo = undefined;
        try ioctlChecked(fd, FBIOGET_VSCREENINFO, @intFromPtr(&variable));
        var fixed: FixScreenInfo = undefined;
        try ioctlChecked(fd, FBIOGET_FSCREENINFO, @intFromPtr(&fixed));
        try validateGeometry(&variable, &fixed);
        const layout = try PixelLayout.fromScreenInfo(&variable);

        const memory = try posix.mmap(
            null,
            fixed.smem_len,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            fd,
            0,
        );
        self.* = .{
            .fd = fd,
            .memory = memory,
            .width = variable.xres,
            .height = variable.yres,
            .line_length = fixed.line_length,
            .visible_offset = @as(usize, variable.yoffset) * fixed.line_length +
                @as(usize, variable.xoffset) * layout.bytes_per_pixel,
            .layout = layout,
        };
        assert(self.visible_offset + self.visibleBytes() <= self.memory.len);
    }

    pub fn close(self: *Framebuffer) void {
        assert(self.memory.len == 0 or self.fd >= 0);
        if (self.memory.len > 0) posix.munmap(self.memory);
        if (self.fd >= 0) _ = std.c.close(self.fd);
        self.* = .{};
        assert(self.fd < 0);
    }

    fn visibleBytes(self: *const Framebuffer) usize {
        assert(self.height > 0);
        assert(self.width * self.layout.bytes_per_pixel <= self.line_length);
        return @as(usize, self.height - 1) * self.line_length +
            @as(usize, self.width) * self.layout.bytes_per_pixel;
    }

    /// Copy a full frame to the device, converting its pixel format.
    pub fn present(self: *Framebuffer, frame: raster.Target) void {
        assert(frame.width == self.width);
        assert(frame.height == self.height);
        self.waitForVsync();
        const row_bytes = @as(usize, self.width) * self.layout.bytes_per_pixel;
        var y: u32 = 0;
        while (y < self.height) : (y += 1) {
            const start = self.visible_offset + @as(usize, y) * self.line_length;
            convertRow(frame.row(y), self.memory[start..][0..row_bytes], self.layout);
        }
    }

    fn waitForVsync(self: *Framebuffer) void {
        assert(self.fd >= 0);
        if (!self.vsync_supported) return;
        var screen: u32 = 0;
        const rc = linux.ioctl(self.fd, FBIO_WAITFORVSYNC, @intFromPtr(&screen));
        // Most fbdev drivers, including DRM's fbdev emulation, do not
        // implement it; stop asking after the first refusal.
        if (linux.errno(rc) != .SUCCESS) self.vsync_supported = false;
    }
};

fn ioctlChecked(fd: posix.fd_t, request: u32, argument: usize) error{FramebufferQueryFailed}!void {
    assert(fd >= 0);
    assert(argument != 0);
    const rc = linux.ioctl(fd, request, argument);
    if (linux.errno(rc) != .SUCCESS) return error.FramebufferQueryFailed;
}

fn validateGeometry(
    variable: *const VarScreenInfo,
    fixed: *const FixScreenInfo,
) error{UnsupportedFramebufferGeometry}!void {
    assert(@intFromPtr(variable) != 0);
    assert(@intFromPtr(fixed) != 0);
    const bad = error.UnsupportedFramebufferGeometry;
    if (variable.xres == 0 or variable.yres == 0) return bad;
    if (variable.xres > width_max) return bad;
    if (variable.yres > height_max) return bad;
    const row_bytes = @as(u64, variable.xres) * (variable.bits_per_pixel / 8);
    if (fixed.line_length < row_bytes) return bad;
    const offset = @as(u64, variable.yoffset) * fixed.line_length +
        @as(u64, variable.xoffset) * (variable.bits_per_pixel / 8);
    const visible = @as(u64, variable.yres - 1) * fixed.line_length + row_bytes;
    if (offset + visible > fixed.smem_len) return bad;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

fn testScreenInfo(bits: u32, red: Bitfield, green: Bitfield, blue: Bitfield) VarScreenInfo {
    var info = std.mem.zeroes(VarScreenInfo);
    info.xres = 2;
    info.yres = 1;
    info.bits_per_pixel = bits;
    info.red = red;
    info.green = green;
    info.blue = blue;
    return info;
}

test "RGB565 conversion keeps each channel's high bits in its own field" {
    // Goal: a 16 bpp panel must receive red in bits 11-15, green in 5-10, and
    // blue in 0-4. Distinct channel values catch a swapped or mis-shifted field:
    // 0xFF8040 truncates to red 31, green 32, blue 8.
    const info = testScreenInfo(
        16,
        .{ .offset = 11, .length = 5, .msb_right = 0 },
        .{ .offset = 5, .length = 6, .msb_right = 0 },
        .{ .offset = 0, .length = 5, .msb_right = 0 },
    );
    const layout = try PixelLayout.fromScreenInfo(&info);
    try testing.expect(!layout.isNative());
    const expected: u32 = (31 << 11) | (32 << 5) | 8;
    try testing.expectEqual(expected, convertPixel(0xFFFF_8040, layout));

    var row: [4]u8 = undefined;
    convertRow(&.{ 0xFFFF_8040, 0xFF00_0000 }, &row, layout);
    try testing.expectEqualSlices(u8, &.{ 0x08, 0xFC, 0x00, 0x00 }, &row);
}

test "BGR 32 bpp panels swap red and blue; XRGB panels copy unchanged" {
    // Goal: only the renderer's own layout may take the copy fast path; a BGR
    // panel must be converted or every red would show as blue.
    const bgr = try PixelLayout.fromScreenInfo(&testScreenInfo(
        32,
        .{ .offset = 0, .length = 8, .msb_right = 0 },
        .{ .offset = 8, .length = 8, .msb_right = 0 },
        .{ .offset = 16, .length = 8, .msb_right = 0 },
    ));
    try testing.expect(!bgr.isNative());
    try testing.expectEqual(@as(u32, 0x0000_00FF), convertPixel(0xFFFF_0000, bgr));

    const xrgb = try PixelLayout.fromScreenInfo(&testScreenInfo(
        32,
        .{ .offset = 16, .length = 8, .msb_right = 0 },
        .{ .offset = 8, .length = 8, .msb_right = 0 },
        .{ .offset = 0, .length = 8, .msb_right = 0 },
    ));
    try testing.expect(xrgb.isNative());
}

test "unsupported pixel formats are rejected at initialization" {
    // Goal: 24 bpp and wider-than-8-bit channels are refused up front instead
    // of being drawn incorrectly.
    const packed24 = testScreenInfo(
        24,
        .{ .offset = 16, .length = 8, .msb_right = 0 },
        .{ .offset = 8, .length = 8, .msb_right = 0 },
        .{ .offset = 0, .length = 8, .msb_right = 0 },
    );
    try testing.expectError(error.UnsupportedPixelFormat, PixelLayout.fromScreenInfo(&packed24));
    const deep = testScreenInfo(
        32,
        .{ .offset = 20, .length = 10, .msb_right = 0 },
        .{ .offset = 10, .length = 10, .msb_right = 0 },
        .{ .offset = 0, .length = 10, .msb_right = 0 },
    );
    try testing.expectError(error.UnsupportedPixelFormat, PixelLayout.fromScreenInfo(&deep));
}
