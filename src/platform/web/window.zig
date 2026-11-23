const std = @import("std");
const imports = @import("imports.zig");
const geometry = @import("../../geometry/geometry.zig");
const interface = @import("../interface.zig");
const platform_mod = @import("platform.zig");

const WindowId = interface.WindowId;
const WebPlatform = platform_mod.WebPlatform;

pub const WebWindow = struct {
    platform: *WebPlatform,

    size: geometry.Size(f64),

    scale_factor: f64,

    cursor_shape: interface.CursorShape,

    dark_appearance: bool,

    window_id: WindowId = .invalid,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        plat: *WebPlatform,
        options: *const interface.WindowOptions,
    ) !*Self {
        std.debug.assert(options.width > 0);
        std.debug.assert(options.height > 0);
        std.debug.assert(options.title.len <= title_bytes_max);

        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.platform = plat;
        self.size = .{ .width = options.width, .height = options.height };
        self.scale_factor = 1.0;
        self.cursor_shape = .default;
        self.dark_appearance = false;
        self.window_id = .invalid;

        self.updateSize();
        imports.setDocumentTitle(options.title.ptr, @intCast(options.title.len));

        self.window_id = try plat.registerWindow(self);

        plat.setActiveWindowId(self.window_id);

        std.debug.assert(self.window_id.isValid());
        std.debug.assert(plat.getActiveWindowId().? == self.window_id);
        return self;
    }

    pub fn updateSize(self: *Self) void {
        const canvas_width = imports.getCanvasWidth();
        const canvas_height = imports.getCanvasHeight();
        std.debug.assert(canvas_width <= size_px_max);
        std.debug.assert(canvas_height <= size_px_max);

        self.size.width = @floatFromInt(canvas_width);
        self.size.height = @floatFromInt(canvas_height);

        const ratio: f64 = imports.getDevicePixelRatio();
        self.scale_factor = if (ratio > 0.0) ratio else 1.0;

        std.debug.assert(self.scale_factor > 0.0);
    }

    pub fn setCursorShape(self: *Self, shape: interface.CursorShape) void {
        std.debug.assert(self.window_id.isValid());
        std.debug.assert(@backingInt(shape) <= @backingInt(interface.CursorShape.resize_up_down));
        if (self.cursor_shape == shape) return;

        imports.setCanvasCursor(@backingInt(shape));
        self.cursor_shape = shape;

        std.debug.assert(self.cursor_shape == shape);
    }

    pub fn setImeCursorRect(self: *Self, x: f32, y: f32, w: f32, h: f32) void {
        std.debug.assert(w >= 0.0);
        std.debug.assert(h >= 0.0);
        std.debug.assert(self.window_id.isValid());

        imports.setImeCursorPosition(x, y, w, h);
    }

    pub fn getPlatform(self: *Self) *WebPlatform {
        std.debug.assert(@intFromPtr(self.platform) != 0);
        return self.platform;
    }

    pub fn setAppearance(self: *Self, dark: bool) void {
        std.debug.assert(self.window_id.isValid());
        self.dark_appearance = dark;
        std.debug.assert(self.dark_appearance == dark);
    }

    pub fn requestRender(self: *Self) void {
        std.debug.assert(self.window_id.isValid());
        imports.requestAnimationFrame();
    }

    pub fn requestRenderAfter(self: *Self, delay_ms: u32) void {
        std.debug.assert(self.window_id.isValid());
        std.debug.assert(delay_ms <= interface.render_delay_ms_max);
    }

    const size_px_max: u32 = 32_768;

    const title_bytes_max: usize = 1024;
};
