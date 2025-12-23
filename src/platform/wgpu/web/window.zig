//! WebWindow - Window implementation for WebAssembly/Browser

const std = @import("std");
const imports = @import("imports.zig");
const geometry = @import("../../../core/geometry.zig");
const scene_mod = @import("../../../core/scene.zig");
const shader_mod = @import("../../../core/shader.zig");
const text_mod = @import("../../../text/mod.zig");

pub const WebWindow = struct {
    allocator: std.mem.Allocator,
    background_color: Color,
    size: Size,
    scale_factor: f64,

    const Self = @This();

    /// Glass style (no-op on web, for API compatibility with macOS)
    pub const GlassStyle = enum(u8) {
        none = 0,
        blur = 1,
        glass_regular = 2,
        glass_clear = 3,
        vibrancy = 4,
    };

    pub const Color = geometry.Color;

    pub const Size = struct {
        width: f64,
        height: f64,
    };

    pub const Options = struct {
        title: []const u8 = "Gooey",
        width: f64 = 800,
        height: f64 = 600,
        background_color: geometry.Color = geometry.Color.init(0.95, 0.95, 0.95, 1.0),
        custom_shaders: []const shader_mod.CustomShader = &.{},
        background_opacity: f64 = 1.0,
        glass_style: GlassStyle = .none,
        glass_corner_radius: f64 = 16.0,
        titlebar_transparent: bool = false,
        full_size_content: bool = false,
    };

    pub fn init(allocator: std.mem.Allocator, _: anytype, options: Options) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .background_color = options.background_color,
            .size = .{
                .width = @floatFromInt(imports.getCanvasWidth()),
                .height = @floatFromInt(imports.getCanvasHeight()),
            },
            .scale_factor = imports.getDevicePixelRatio(),
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.destroy(self);
    }

    pub fn updateSize(self: *Self) void {
        self.size.width = @floatFromInt(imports.getCanvasWidth());
        self.size.height = @floatFromInt(imports.getCanvasHeight());
        self.scale_factor = imports.getDevicePixelRatio();
    }

    pub fn width(self: *const Self) u32 {
        return @intFromFloat(self.size.width);
    }

    pub fn height(self: *const Self) u32 {
        return @intFromFloat(self.size.height);
    }

    pub fn getSize(self: *const Self) geometry.Size(f64) {
        return .{ .width = self.size.width, .height = self.size.height };
    }

    pub fn getScaleFactor(self: *const Self) f32 {
        return @floatCast(self.scale_factor);
    }

    pub fn getClearColor(self: *const Self) geometry.Color {
        return self.background_color;
    }

    pub fn getMousePosition(_: *const Self) geometry.Point(f64) {
        return .{
            .x = @floatCast(imports.getMouseX()),
            .y = @floatCast(imports.getMouseY()),
        };
    }

    pub fn getMouseX(_: *const Self) f32 {
        return imports.getMouseX();
    }

    pub fn getMouseY(_: *const Self) f32 {
        return imports.getMouseY();
    }

    pub fn isMouseInside(_: *const Self) bool {
        return imports.isMouseInCanvas();
    }

    pub fn requestRender(_: *Self) void {
        // On web, rendering is driven by requestAnimationFrame
    }

    pub fn setTitle(_: *Self, title: []const u8) void {
        imports.setDocumentTitle(title.ptr, @intCast(title.len));
    }

    pub fn setImeCursorRect(_: *Self, x: f32, y: f32, w: f32, h: f32) void {
        imports.setImeCursorPosition(x, y, w, h);
    }

    // =========================================================================
    // Stubs for API compatibility (no-ops on web)
    // =========================================================================

    pub fn setBackgroundColor(self: *Self, color: geometry.Color) void {
        self.background_color = color;
    }
    pub fn setGlassStyle(_: *Self, _: GlassStyle, _: f64, _: f64) void {}
    pub fn performClose(_: *Self) void {}

    // Callbacks (no-op - web uses @export instead)
    pub fn setRenderCallback(_: *Self, _: anytype) void {}
    pub fn setInputCallback(_: *Self, _: anytype) void {}
    pub fn setUserData(_: *Self, _: ?*anyopaque) void {}
    pub fn getUserData(_: *Self, comptime T: type) ?*T {
        return null;
    }

    // Scene/Atlas (no-op - web manages these separately in WebApp)
    pub fn setScene(_: *Self, _: *const scene_mod.Scene) void {}
    pub fn setTextAtlas(_: *Self, _: *const text_mod.Atlas) void {}

    // IME (not yet supported on web)
    pub fn setMarkedText(_: *Self, _: []const u8) void {}
    pub fn setInsertedText(_: *Self, _: []const u8) void {}

    // Hover (managed differently on web)
    pub fn getHoveredQuad(_: *const Self) ?*const scene_mod.Quad {
        return null;
    }
};

/// Alias for API compatibility
pub const Window = WebWindow;
