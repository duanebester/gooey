const std = @import("std");
const assert = std.debug.assert;
const wayland = @import("wayland.zig");
const CursorShape = @import("../interface.zig").CursorShape;

const cursor_size_default: u32 = 24;
const cursor_size_max: u32 = 256;
const output_scale_max: u32 = 8;
const image_edge_px_max: u32 = cursor_size_max * output_scale_max;
const shape_name_count_max: u32 = 3;
const surface_version_min: u32 = 4;
const shape_count = @typeInfo(CursorShape).@"enum".field_names.len;

comptime {
    for (@typeInfo(CursorShape).@"enum".field_values, 0..) |value, index| {
        assert(value == index);
    }
    assert(cursor_size_default >= 1);
    assert(cursor_size_default <= cursor_size_max);
    assert(image_edge_px_max <= std.math.maxInt(i32));
    assert(shape_count >= 1);
}

pub const CursorSurface = struct {
    theme: ?*wayland.CursorTheme = null,
    surface: ?*wayland.Surface = null,
    images: [shape_count]?Image = @splat(null),

    pub const Image = struct {
        buffer: *wayland.Buffer,
        width_px: i32,
        height_px: i32,
        hotspot_x: i32,
        hotspot_y: i32,
        buffer_scale: i32,
    };

    pub const LoadOptions = struct {
        compositor: *wayland.Compositor,
        shm: *wayland.Shm,
        output_scale: i32,
    };

    pub fn load(self: *CursorSurface, options: LoadOptions) void {
        assert(self.theme == null);
        assert(self.surface == null);
        assert(options.output_scale >= 1);

        if (wayland.wl_proxy_get_version(@ptrCast(options.compositor)) < surface_version_min) {
            std.log.warn("cursor: wl_compositor is older than version {d}; keeping the " ++
                "compositor's cursor", .{surface_version_min});
            return;
        }
        const scale: u32 = @min(@as(u32, @intCast(options.output_scale)), output_scale_max);
        const size_px = cursor_size_from_text(environment("XCURSOR_SIZE")) * scale;
        assert(size_px <= image_edge_px_max);

        const theme_name = std.c.getenv("XCURSOR_THEME");
        const size: c_int = @intCast(size_px);
        const theme = wayland.wl_cursor_theme_load(theme_name, size, options.shm) orelse {
            std.log.warn("cursor: cannot load cursor theme at {d} px", .{size_px});
            return;
        };
        if (!load_images(&self.images, theme, scale)) {
            std.log.warn("cursor: the cursor theme has no default arrow", .{});
            wayland.wl_cursor_theme_destroy(theme);
            return;
        }
        const surface = wayland.compositorCreateSurface(options.compositor) orelse {
            std.log.warn("cursor: cannot create the cursor surface", .{});
            wayland.wl_cursor_theme_destroy(theme);
            self.images = @splat(null);
            return;
        };
        self.theme = theme;
        self.surface = surface;
        assert(self.images[@backingInt(CursorShape.default)] != null);
    }

    pub fn deinit(self: *CursorSurface) void {
        if (self.surface) |surface| {
            assert(self.theme != null);
            wayland.surfaceDestroy(surface);
            self.surface = null;
        }
        if (self.theme) |theme| {
            wayland.wl_cursor_theme_destroy(theme);
            self.theme = null;
        }
        self.images = @splat(null);
        assert(self.surface == null);
    }

    pub fn show(
        self: *const CursorSurface,
        pointer: *wayland.Pointer,
        serial: u32,
        shape: CursorShape,
    ) bool {
        const surface = self.surface orelse {
            assert(self.theme == null);
            return false;
        };
        assert(self.theme != null);
        const image = self.images[@backingInt(shape)].?;
        assert(image.width_px > 0);
        assert(image.height_px > 0);
        assert(image.buffer_scale >= 1);

        wayland.pointer_set_cursor(pointer, serial, surface, .{
            .x = image.hotspot_x,
            .y = image.hotspot_y,
        });
        wayland.surfaceSetBufferScale(surface, image.buffer_scale);
        wayland.surfaceAttach(surface, image.buffer, 0, 0);
        wayland.surfaceDamageBuffer(surface, 0, 0, image.width_px, image.height_px);
        wayland.surfaceCommit(surface);
        return true;
    }
};

fn load_images(
    images: *[shape_count]?CursorSurface.Image,
    theme: *wayland.CursorTheme,
    scale: u32,
) bool {
    assert(scale >= 1);
    assert(scale <= output_scale_max);

    const default_image = load_image(theme, .default, scale) orelse return false;
    for (images, 0..) |*image, index| {
        const shape: CursorShape = @fromBackingInt(@intCast(index));
        image.* = load_image(theme, shape, scale) orelse default_image;
    }
    assert(images[@backingInt(CursorShape.default)] != null);
    return true;
}

fn load_image(theme: *wayland.CursorTheme, shape: CursorShape, scale: u32) ?CursorSurface.Image {
    const names = shape_names(shape);
    assert(names.len >= 1);
    assert(names.len <= shape_name_count_max);

    for (names) |name| {
        const cursor = wayland.wl_cursor_theme_get_cursor(theme, name) orelse continue;
        if (cursor.image_count == 0) continue;
        if (image_from_frame(cursor.images[0], scale)) |image| return image;
    }
    return null;
}

fn shape_names(shape: CursorShape) []const [*:0]const u8 {
    return switch (shape) {
        .default => &.{ "default", "left_ptr" },
        .text => &.{ "text", "xterm" },
        .pointer => &.{ "pointer", "hand2", "hand1" },
        .resize_left_right => &.{ "col-resize", "sb_h_double_arrow" },
        .resize_up_down => &.{ "row-resize", "sb_v_double_arrow" },
    };
}

fn image_from_frame(frame: *wayland.CursorImage, scale: u32) ?CursorSurface.Image {
    assert(scale >= 1);
    if (frame.width == 0) return null;
    if (frame.height == 0) return null;
    if (frame.width > image_edge_px_max) return null;
    if (frame.height > image_edge_px_max) return null;
    if (frame.hotspot_x > frame.width) return null;
    if (frame.hotspot_y > frame.height) return null;

    const buffer = wayland.wl_cursor_image_get_buffer(frame) orelse return null;
    const buffer_scale = buffer_scale_for_image(frame.width, frame.height, scale);
    return .{
        .buffer = buffer,
        .width_px = @intCast(frame.width),
        .height_px = @intCast(frame.height),
        .hotspot_x = @intCast(@divFloor(frame.hotspot_x, buffer_scale)),
        .hotspot_y = @intCast(@divFloor(frame.hotspot_y, buffer_scale)),
        .buffer_scale = @intCast(buffer_scale),
    };
}

fn buffer_scale_for_image(width_px: u32, height_px: u32, scale: u32) u32 {
    assert(width_px >= 1);
    assert(height_px >= 1);
    assert(scale >= 1);
    if (width_px % scale != 0) return 1;
    if (height_px % scale != 0) return 1;
    return scale;
}

fn cursor_size_from_text(text: ?[]const u8) u32 {
    const value = text orelse return cursor_size_default;
    const size = std.fmt.parseInt(u32, value, 10) catch return cursor_size_default;
    if (size >= 1) {
        if (size <= cursor_size_max) return size;
    }
    return cursor_size_default;
}

fn environment(name: [*:0]const u8) ?[]const u8 {
    const value = std.c.getenv(name) orelse return null;
    return std.mem.span(value);
}

test "cursor_size_from_text accepts 1 through cursor_size_max and nothing else" {
    const expectEqual = std.testing.expectEqual;
    try expectEqual(cursor_size_default, cursor_size_from_text(null));
    try expectEqual(cursor_size_default, cursor_size_from_text(""));
    try expectEqual(cursor_size_default, cursor_size_from_text("big"));
    try expectEqual(cursor_size_default, cursor_size_from_text(" 32"));
    try expectEqual(cursor_size_default, cursor_size_from_text("-1"));
    try expectEqual(cursor_size_default, cursor_size_from_text("0"));
    try expectEqual(@as(u32, 1), cursor_size_from_text("1"));
    try expectEqual(@as(u32, 48), cursor_size_from_text("48"));
    try expectEqual(cursor_size_max, cursor_size_from_text("256"));
    try expectEqual(cursor_size_default, cursor_size_from_text("257"));
    try expectEqual(cursor_size_default, cursor_size_from_text("4294967296"));
}

test "buffer_scale_for_image keeps the output scale only for exact multiples" {
    const expectEqual = std.testing.expectEqual;
    try expectEqual(@as(u32, 2), buffer_scale_for_image(48, 48, 2));
    try expectEqual(@as(u32, 1), buffer_scale_for_image(47, 48, 2));
    try expectEqual(@as(u32, 1), buffer_scale_for_image(48, 49, 2));
    try expectEqual(@as(u32, 3), buffer_scale_for_image(72, 96, 3));
    try expectEqual(@as(u32, 1), buffer_scale_for_image(64, 64, 3));
    try expectEqual(@as(u32, 1), buffer_scale_for_image(31, 17, 1));
}
