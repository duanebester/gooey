//! Cursor surface for compositors without `wp_cursor_shape_v1`.
//!
//! The cursor-shape protocol lets the compositor draw a named cursor. GNOME added it in
//! mutter 48. On GNOME 43 to 47 and other compositors without it, a client that wants a
//! hand or an I-beam must draw the cursor itself: load an XCursor theme, attach one of its
//! images to a surface the client owns, and pass that surface to `wl_pointer.set_cursor`.
//! `LinuxPlatform` loads this fallback only when the compositor offers no shape manager.
//!
//! Everything is loaded during platform initialization. libwayland-cursor reads the whole
//! theme into one shared-memory pool when it loads, and creates an image's `wl_buffer` on the
//! first `wl_cursor_image_get_buffer`, so `load` asks for the buffer of every `CursorShape`.
//! A hover change after that only sends requests on objects that already exist.
//!
//! Resource sketch:
//! - Resident: the theme's shm pool, which holds every cursor of the theme at the loaded
//!   size (size² × 4 bytes per frame; Adwaita's 478 frames take 1 MiB at 24 px and 4 MiB
//!   at 48 px), one `wl_surface`, and one `wl_buffer` per shape. Gooey's own storage is
//!   the fixed `images` array.
//! - Per hover change: five requests (set_cursor, set_buffer_scale, attach, damage_buffer,
//!   commit), no lookups and no allocation. `LinuxPlatform.setCursorShape` sends them only
//!   when the shape changes, so a frame sends at most one batch.
//! - The theme is loaded at the output scale known at initialization. A window that moves
//!   to an output with another scale keeps that cursor size, because reloading allocates.

const std = @import("std");
const assert = std.debug.assert;
const wayland = @import("wayland.zig");
const CursorShape = @import("../interface.zig").CursorShape;

/// XCursor's conventional size, used when XCURSOR_SIZE is unset or unusable.
const cursor_size_default: u32 = 24;
/// Largest XCURSOR_SIZE accepted, in logical pixels. XCursor themes ship at most 256.
const cursor_size_max: u32 = 256;
/// Largest output scale the theme is loaded at; a larger reported scale is clamped.
const output_scale_max: u32 = 8;
/// Largest image edge accepted from a theme file, in buffer pixels.
const image_edge_px_max: u32 = cursor_size_max * output_scale_max;
/// Most theme names tried for one shape; see `shape_names`.
const shape_name_count_max: u32 = 3;
/// `wl_surface.damage_buffer` needs version 4; `set_buffer_scale` needs 3.
const surface_version_min: u32 = 4;
const shape_count = @typeInfo(CursorShape).@"enum".field_names.len;

comptime {
    // `images` is indexed by `@intFromEnum(shape)`, so the tags must be 0 through count - 1.
    for (@typeInfo(CursorShape).@"enum".field_values, 0..) |value, index| {
        assert(value == index);
    }
    assert(cursor_size_default >= 1);
    assert(cursor_size_default <= cursor_size_max);
    assert(image_edge_px_max <= std.math.maxInt(i32));
    assert(shape_count >= 1);
}

pub const CursorSurface = struct {
    /// Owns the shm pool and every image buffer in `images`.
    theme: ?*wayland.CursorTheme = null,
    /// The surface given the cursor role. Non-null exactly when `theme` is.
    surface: ?*wayland.Surface = null,
    /// Indexed by `CursorShape`. Every entry is set when `surface` is, and none otherwise.
    images: [shape_count]?Image = @splat(null),

    pub const Image = struct {
        buffer: *wayland.Buffer,
        width_px: i32,
        height_px: i32,
        /// Surface-local, so already divided by `buffer_scale`.
        hotspot_x: i32,
        hotspot_y: i32,
        buffer_scale: i32,
    };

    pub const LoadOptions = struct {
        compositor: *wayland.Compositor,
        shm: *wayland.Shm,
        /// `wl_output.scale` of the output known at initialization.
        output_scale: i32,
    };

    /// Load XCURSOR_THEME at XCURSOR_SIZE times the output scale, with one image per shape,
    /// and create the cursor surface. Best effort: when the theme cannot be loaded the
    /// pointer keeps the compositor's cursor, as before this fallback existed.
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

    /// Destroy the surface, then the theme and its buffers. Runs before the display
    /// disconnects; safe when `load` never ran or failed.
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

    /// Show `shape` as the pointer image. `serial` is the latest `wl_pointer.enter` serial.
    /// Returns false when no theme is loaded, so the caller keeps its current state.
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

/// Fill `images` from `theme`. A shape the theme lacks gets the default arrow. Returns false,
/// leaving `images` untouched, when the theme has no default arrow either.
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

/// The first frame of the first theme name for `shape` that loads. Animation is not
/// supported: every shape Gooey sets is a still image in common themes.
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

/// Theme names for `shape`, most preferred first: the CSS name current themes use, then the
/// X11 names of older themes and of libwayland-cursor's built-in set (`left_ptr`, `xterm`,
/// and `hand1`). The switch is exhaustive, so a new `CursorShape` cannot compile without one.
fn shape_names(shape: CursorShape) []const [*:0]const u8 {
    return switch (shape) {
        .default => &.{ "default", "left_ptr" },
        .text => &.{ "text", "xterm" },
        .pointer => &.{ "pointer", "hand2", "hand1" },
        .resize_left_right => &.{ "col-resize", "sb_h_double_arrow" },
        .resize_up_down => &.{ "row-resize", "sb_v_double_arrow" },
    };
}

/// Validate one frame read from a theme file and create its buffer. Returns null for a frame
/// whose size or hotspot is out of range, or when the buffer cannot be created.
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

/// The buffer scale for an image loaded at `scale`. Compositors reject a buffer whose size
/// is not a multiple of its scale, so an image whose theme lacks the exact size shows at
/// scale 1, larger than intended but valid.
fn buffer_scale_for_image(width_px: u32, height_px: u32, scale: u32) u32 {
    assert(width_px >= 1);
    assert(height_px >= 1);
    assert(scale >= 1);
    if (width_px % scale != 0) return 1;
    if (height_px % scale != 0) return 1;
    return scale;
}

/// XCURSOR_SIZE in logical pixels: the default when the text is absent, not a decimal
/// number, zero, or above `cursor_size_max`.
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
    // An unusable XCURSOR_SIZE must load the default size, never a zero-sized or oversized
    // theme. Each boundary is checked on both sides, plus text that is not a number.
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
    // A buffer whose size is not a multiple of its scale is a protocol error, so either
    // edge being off by one pixel must drop to scale 1.
    const expectEqual = std.testing.expectEqual;
    try expectEqual(@as(u32, 2), buffer_scale_for_image(48, 48, 2));
    try expectEqual(@as(u32, 1), buffer_scale_for_image(47, 48, 2));
    try expectEqual(@as(u32, 1), buffer_scale_for_image(48, 49, 2));
    try expectEqual(@as(u32, 3), buffer_scale_for_image(72, 96, 3));
    try expectEqual(@as(u32, 1), buffer_scale_for_image(64, 64, 3));
    try expectEqual(@as(u32, 1), buffer_scale_for_image(31, 17, 1));
}
