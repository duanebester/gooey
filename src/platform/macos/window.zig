const std = @import("std");
const assert = std.debug.assert;
const objc = @import("objc");
const geometry = @import("../../geometry/geometry.zig");
const platform = @import("platform.zig");
const metal = @import("metal/metal.zig");
const backend = @import("../../core/backend.zig");
const limits_mod = @import("../../core/limits.zig");
const input_view = @import("input_view.zig");
const input = @import("../../input/events.zig");
const appkit = @import("appkit.zig");
const interface_mod = @import("../interface.zig");
const WindowOptions = interface_mod.WindowOptions;
const TitleBar = core_events.TitleBar;
const core_events = @import("../../core/events.zig");
const core_router = @import("../../core/router.zig");
const core_clipboard = @import("../../core/clipboard.zig");

pub const CoreBinding = struct {
    queue: *core_events.EventQueue,
    query: *const core_router.Query,
    context: *anyopaque,
    schedule_tick: *const fn (context: *anyopaque) void,
};

pub const title_bytes_max: usize = 255;

const NSRect = appkit.NSRect;
const NSSize = appkit.NSSize;

pub const Window = struct {
    allocator: std.mem.Allocator,

    plat: *platform.MacPlatform,

    ns_window: objc.Object,
    ns_view: objc.Object,
    metal_layer: objc.Object,
    renderer: metal.Renderer,
    size: geometry.Size(f64),
    scale_factor: f64,
    window_limits: limits_mod.WindowLimits,
    min_size: ?geometry.Size(f64),
    max_size: ?geometry.Size(f64),
    size_limits_scale: f64,
    title_buf: [title_bytes_max + 1]u8,
    title_len: u16,
    title_bar: TitleBar,
    title_bar_inset: TitleBar.Inset,

    delegate: ?objc.Object = null,
    tracking_area: ?objc.Object = null,

    cursor_shape: ?interface_mod.CursorShape = null,

    marked_text: []const u8 = "",
    marked_text_buffer: []u8 = &.{},
    marked_length_utf16: c_ulong = 0,
    marked_selection: appkit.NSRange = .{ .location = 0, .length = 0 },
    rendered_marked_length_utf16: c_ulong = 0,

    on_close: ?CloseCallback = null,

    core: ?CoreBinding = null,

    pub const CloseCallback = *const fn (*Window) bool;

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        plat: *platform.MacPlatform,
        options: *const WindowOptions,
    ) !*Self {
        assert(@intFromPtr(plat) != 0);
        assert(options.width >= 1);
        assert(options.height >= 1);

        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        initFields(self, allocator, plat, options);
        const preedit_bytes_max = options.limits.text.preedit_bytes_max;
        self.marked_text_buffer = try allocator.alloc(u8, preedit_bytes_max + 1);
        errdefer allocator.free(self.marked_text_buffer);
        try self.createNSWindow(options);

        const window_delegate = @import("window_delegate.zig");
        self.delegate = try window_delegate.create(self);
        self.ns_window.msgSend(void, "setDelegate:", .{self.delegate.?.value});

        try self.setupTrackingArea();

        assert(self.scale_factor > 0.0);
        assert(self.size_limits_scale == self.scale_factor);

        try self.setupMetalLayer();
        const render_limits = backend.RenderLimits.fromResourceLimits(&options.limits);
        const viewport = framebufferViewport(.{
            .width = self.size.width,
            .height = self.size.height,
            .scale_factor = self.scale_factor,
        }, &render_limits.window);
        try self.renderer.initInPlace(&.{
            .native = self.metal_layer.value,
            .size_px = viewport.size_px,
            .scale_factor = viewport.scale_factor,
        }, &render_limits);

        self.ns_window.msgSend(void, "makeKeyAndOrderFront:", .{@as(?*anyopaque, null)});

        assert(self.core == null);
        assert(self.delegate != null);
        return self;
    }

    noinline fn initFields(
        self: *Self,
        allocator: std.mem.Allocator,
        plat: *platform.MacPlatform,
        options: *const WindowOptions,
    ) void {
        assert(@intFromPtr(self) != 0);
        assert(options.width >= 1);

        self.* = .{
            .allocator = allocator,
            .plat = plat,
            .ns_window = undefined,
            .ns_view = undefined,
            .metal_layer = undefined,
            .renderer = undefined,
            .size = geometry.Size(f64).init(options.width, options.height),
            .scale_factor = 1.0,
            .window_limits = options.limits.window,
            .min_size = options.min_size,
            .max_size = options.max_size,
            .size_limits_scale = 0,
            .title_buf = @splat(0),
            .title_len = 0,
            .title_bar = options.title_bar,
            .title_bar_inset = .{},
        };
        assert(self.core == null);
        assert(self.on_close == null);
    }

    fn createNSWindow(self: *Self, options: *const WindowOptions) !void {
        assert(options.width >= 1);
        assert(options.height >= 1);

        const NSWindow = objc.getClass("NSWindow") orelse return error.ClassNotFound;

        const style_full_size_content: u64 = 1 << 15;
        const style_mask: u64 = (1 << 0) | (1 << 1) | (1 << 2) | (1 << 3) |
            if (options.title_bar == .transparent) style_full_size_content else 0;

        const content_rect = NSRect{
            .origin = .{ .x = 100, .y = 100 },
            .size = .{ .width = options.width, .height = options.height },
        };

        const window_alloc = NSWindow.msgSend(objc.Object, "alloc", .{});
        self.ns_window = window_alloc.msgSend(
            objc.Object,
            "initWithContentRect:styleMask:backing:defer:",
            .{
                content_rect,
                style_mask,
                @as(u64, 2),
                false,
            },
        );
        if (self.ns_window.value == null) return error.WindowCreationFailed;

        self.ns_window.msgSend(void, "setReleasedWhenClosed:", .{false});
        assert(!self.ns_window.msgSend(bool, "isReleasedWhenClosed", .{}));

        self.setTitle(options.title);
        if (options.title_bar == .transparent) {
            const ns_window_title_hidden: c_long = 1;
            self.ns_window.msgSend(void, "setTitlebarAppearsTransparent:", .{true});
            self.ns_window.msgSend(void, "setTitleVisibility:", .{ns_window_title_hidden});
        }

        self.scale_factor = self.ns_window.msgSend(f64, "backingScaleFactor", .{});
        assert(self.scale_factor > 0.0);
        self.applySizeLimits(self.scale_factor);
        self.size = self.contentSize();

        if (options.centered) {
            self.ns_window.msgSend(void, "center", .{});
        }

        const view_frame: NSRect = self.ns_window.msgSend(NSRect, "contentLayoutRect", .{});
        self.ns_view = try input_view.create(view_frame, self);
        self.ns_window.msgSend(void, "setContentView:", .{self.ns_view.value});
        assert(self.ns_view.value != null);
        if (self.title_bar == .transparent) self.title_bar_inset = self.measureTitleBarInset();
        assert(std.meta.eql(self.title_bar_inset, TitleBar.Inset{}) or
            self.title_bar == .transparent);
    }

    pub fn setCloseCallback(self: *Self, callback: ?CloseCallback) void {
        assert(self.ns_window.value != null);
        self.on_close = callback;
        assert((self.on_close == null) == (callback == null));
    }

    pub fn setMarkedText(self: *Self, text: []const u8) void {
        const bytes_max = self.marked_text_buffer.len - 1;
        assert(bytes_max > 0);
        const kept = core_clipboard.prefixFitting(text, bytes_max);
        if (kept < text.len) {
            std.log.warn("IME composition of {d} bytes cut to {d}. Raise " ++
                "ResourceLimits.text.preedit_bytes_max ({d}).", .{ text.len, kept, bytes_max });
        }
        @memcpy(self.marked_text_buffer[0..kept], text[0..kept]);
        self.marked_text_buffer[kept] = 0;
        self.marked_text = self.marked_text_buffer[0..kept];
        assert(self.marked_text.len <= bytes_max);
        if (kept > 0 and kept < text.len) assert(text[kept] & 0xC0 != 0x80);
    }

    pub fn clearMarkedText(self: *Self) void {
        self.marked_text = "";
        self.marked_length_utf16 = 0;
        self.marked_selection = .{ .location = 0, .length = 0 };
    }

    pub fn hasMarkedText(self: *const Self) bool {
        return self.marked_text.len > 0;
    }

    pub fn handleInput(self: *Self, event: input.InputEvent) bool {
        const binding = self.core orelse return false;
        return pushCoreInput(binding, event, self.hasMarkedText());
    }

    fn pushCoreInput(binding: CoreBinding, event: input.InputEvent, composing: bool) bool {
        if (composing) {
            if (event == .key_down) return false;
        }
        binding.queue.push(.{ .input = event });
        binding.schedule_tick(binding.context);
        return switch (event) {
            .key_down => |key| binding.query.keymapClaims(key),
            .mouse_down => |mouse| binding.query.pressClaims(.{
                .x = @floatCast(mouse.position.x),
                .y = @floatCast(mouse.position.y),
            }),
            else => false,
        };
    }

    pub fn bindCore(self: *Self, binding: CoreBinding) void {
        assert(self.core == null);
        assert(self.ns_view.value != null);
        self.core = binding;
        if (self.title_bar == .transparent) {
            binding.queue.push(.{ .window = .{ .title_bar = self.title_bar_inset } });
        }
    }

    pub fn deinit(self: *Self) void {
        assert(self.ns_window.value != null);
        assert(self.ns_view.value != null);
        self.renderer.deinit();
        self.releaseAppKitObjects();
        self.allocator.free(self.marked_text_buffer);
        self.allocator.destroy(self);
    }

    fn releaseAppKitObjects(self: *Self) void {
        assert(self.ns_window.value != null);
        assert(self.ns_view.value != null);
        const nil: objc.Object = .{ .value = null };

        if (self.delegate) |d| {
            self.ns_window.msgSend(void, "setDelegate:", .{@as(?*anyopaque, null)});
            d.setInstanceVariable("_gooeyWindow", nil);
            d.release();
            self.delegate = null;
        }
        if (self.tracking_area) |area| {
            self.ns_view.msgSend(void, "removeTrackingArea:", .{area.value});
            area.release();
            self.tracking_area = null;
        }

        self.ns_view.setInstanceVariable("_gooeyWindow", nil);
        self.ns_window.msgSend(void, "close", .{});
        assert(!self.ns_window.msgSend(bool, "isReleasedWhenClosed", .{}));
        self.ns_window.release();
        self.ns_window = nil;
        self.ns_view.release();
        self.ns_view = nil;
    }

    pub fn handleResize(self: *Self) void {
        const new_scale = self.ns_window.msgSend(f64, "backingScaleFactor", .{});
        assert(new_scale > 0);
        if (new_scale != self.size_limits_scale) self.applySizeLimits(new_scale);
        assert(self.size_limits_scale == new_scale);
        if (self.title_bar == .transparent) self.updateTitleBarInset();

        const bounds: NSRect = self.ns_view.msgSend(NSRect, "bounds", .{});

        const new_width = bounds.size.width;
        const new_height = bounds.size.height;

        if (new_width < 1 or new_height < 1) {
            return;
        }

        if (new_width == self.size.width and
            new_height == self.size.height and
            new_scale == self.scale_factor)
        {
            return;
        }

        const size = geometry.Size(f64).init(new_width, new_height);
        if (self.core) |binding| {
            self.resizeCore(binding, size, new_scale);
        } else {
            self.size = size;
            self.scale_factor = new_scale;
            self.metal_layer.msgSend(void, "setContentsScale:", .{new_scale});
        }
    }

    fn applySizeLimits(self: *Self, scale_factor: f64) void {
        assert(scale_factor > 0);
        assert(self.ns_window.value != null);
        var content_max = contentSizeMax(&self.window_limits, scale_factor);
        if (self.max_size) |max_size| {
            content_max.width = @min(content_max.width, max_size.width);
            content_max.height = @min(content_max.height, max_size.height);
        }
        self.ns_window.msgSend(void, "setContentMaxSize:", .{
            NSSize{ .width = content_max.width, .height = content_max.height },
        });
        if (self.min_size) |min_size| {
            self.ns_window.msgSend(void, "setContentMinSize:", .{NSSize{
                .width = @min(min_size.width, content_max.width),
                .height = @min(min_size.height, content_max.height),
            }});
        }
        self.size_limits_scale = scale_factor;

        const current = self.contentSize();
        if (current.width > content_max.width or current.height > content_max.height) {
            std.log.info("window: content {d}x{d} pt capped at {d}x{d} pt, the " ++
                "ResourceLimits.window framebuffer at scale {d:.2}", .{
                current.width,
                current.height,
                content_max.width,
                content_max.height,
                scale_factor,
            });
            self.ns_window.msgSend(void, "setContentSize:", .{NSSize{
                .width = @min(current.width, content_max.width),
                .height = @min(current.height, content_max.height),
            }});
        }
        const capped = self.contentSize();
        assert(capped.width <= content_max.width);
        assert(capped.height <= content_max.height);
    }

    fn contentSize(self: *const Self) geometry.Size(f64) {
        assert(self.ns_window.value != null);
        const frame: NSRect = self.ns_window.msgSend(NSRect, "frame", .{});
        const content: NSRect =
            self.ns_window.msgSend(NSRect, "contentRectForFrameRect:", .{frame});
        assert(content.size.width >= 0);
        assert(content.size.height >= 0);
        return geometry.Size(f64).init(content.size.width, content.size.height);
    }

    fn resizeCore(self: *Self, binding: CoreBinding, size: geometry.Size(f64), scale: f64) void {
        assert(size.width >= 1);
        assert(size.height >= 1);
        assert(scale > 0);
        self.size = size;
        self.scale_factor = scale;
        self.metal_layer.msgSend(void, "setContentsScale:", .{scale});
        binding.queue.push(.{ .window = .{ .resized = .{
            .width = @floatCast(size.width),
            .height = @floatCast(size.height),
            .scale_factor = @floatCast(scale),
        } } });
        binding.schedule_tick(binding.context);
    }

    pub fn handleClose(self: *Self) bool {
        assert(self.ns_window.value != null);
        if (self.on_close) |callback| return callback(self);
        return true;
    }

    fn updateTitleBarInset(self: *Self) void {
        assert(self.title_bar == .transparent);
        const inset = self.measureTitleBarInset();
        if (std.meta.eql(inset, self.title_bar_inset)) return;
        self.title_bar_inset = inset;
        const binding = self.core orelse return;
        binding.queue.push(.{ .window = .{ .title_bar = inset } });
        binding.schedule_tick(binding.context);
    }

    fn measureTitleBarInset(self: *const Self) TitleBar.Inset {
        assert(self.title_bar == .transparent);
        assert(self.ns_view.value != null);
        const bounds: NSRect = self.ns_view.msgSend(NSRect, "bounds", .{});
        const layout: NSRect = self.ns_window.msgSend(NSRect, "contentLayoutRect", .{});
        const strip_height = bounds.size.height - (layout.origin.y + layout.size.height);
        const close_button: c_ulong = 0;
        const zoom_button: c_ulong = 2;
        const close = self.buttonRect(close_button) orelse return .{};
        const zoom = self.buttonRect(zoom_button) orelse return .{};
        const close_max_x = close.origin.x + close.size.width;
        const zoom_max_x = zoom.origin.x + zoom.size.width;
        return titleBarInset(.{
            .width = bounds.size.width,
            .strip_height = strip_height,
            .buttons_min_x = @min(close.origin.x, zoom.origin.x),
            .buttons_max_x = @max(close_max_x, zoom_max_x),
        });
    }

    fn buttonRect(self: *const Self, kind: c_ulong) ?NSRect {
        assert(kind <= 2);
        const button = self.ns_window.msgSend(objc.c.id, "standardWindowButton:", .{kind});
        if (button == null) return null;
        const view = objc.Object.fromId(button);
        const bounds: NSRect = view.msgSend(NSRect, "bounds", .{});
        const nil: objc.c.id = null;
        const rect: NSRect = view.msgSend(NSRect, "convertRect:toView:", .{ bounds, nil });
        assert(rect.size.width >= 0);
        return rect;
    }

    pub fn titleStripTakesPress(self: *const Self, position: geometry.Point(f64)) bool {
        assert(std.math.isFinite(position.x));
        assert(std.math.isFinite(position.y));
        if (self.title_bar != .transparent) return false;
        if (!(position.y < self.title_bar_inset.top)) return false;
        const binding = self.core orelse return true;
        return !binding.query.pressClaims(.{
            .x = @floatCast(position.x),
            .y = @floatCast(position.y),
        });
    }

    pub fn pressTitleBar(self: *Self, event: objc.c.id, mouse: input.MouseEvent) void {
        assert(event != null);
        assert(mouse.button == .left);
        if (self.title_bar != .transparent) return;
        if (!(mouse.position.y < self.title_bar_inset.top)) return;
        if (mouse.click_count == 2) {
            self.titleBarDoubleClick();
        } else {
            self.ns_window.msgSend(void, "performWindowDragWithEvent:", .{event});
        }
    }

    fn titleBarDoubleClick(self: *Self) void {
        assert(self.title_bar == .transparent);
        const NSUserDefaults = objc.getClass("NSUserDefaults") orelse return;
        const NSString = objc.getClass("NSString") orelse return;
        const defaults = NSUserDefaults.msgSend(objc.Object, "standardUserDefaults", .{});
        const key = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{
            @as([*:0]const u8, "AppleActionOnDoubleClick"),
        });
        const value = defaults.msgSend(objc.c.id, "stringForKey:", .{key.value});
        var action: []const u8 = "";
        if (value != null) {
            const bytes = objc.Object.fromId(value).msgSend(?[*:0]const u8, "UTF8String", .{});
            if (bytes) |pointer| action = std.mem.span(pointer);
        }
        const nil: objc.c.id = null;
        if (std.mem.eql(u8, action, "None")) return;
        if (std.mem.eql(u8, action, "Minimize")) {
            self.ns_window.msgSend(void, "miniaturize:", .{nil});
        } else {
            self.ns_window.msgSend(void, "zoom:", .{nil});
        }
    }

    pub fn setTitle(self: *Self, new_title: []const u8) void {
        assert(self.ns_window.value != null);
        assert(self.title_buf.len == title_bytes_max + 1);

        assert(new_title.len <= title_bytes_max);
        const len = @min(new_title.len, title_bytes_max);

        @memcpy(self.title_buf[0..len], new_title[0..len]);

        @memset(self.title_buf[len..], 0);
        self.title_len = @intCast(len);

        assert(self.title_buf[self.title_len] == 0);

        const NSString = objc.getClass("NSString") orelse return;
        const ns_title = NSString.msgSend(
            objc.Object,
            "stringWithUTF8String:",
            .{@as([*:0]const u8, @ptrCast(&self.title_buf))},
        );

        self.ns_window.msgSend(void, "setTitle:", .{ns_title});
    }

    pub fn setCursorShape(self: *Self, shape: interface_mod.CursorShape) void {
        std.debug.assert(self.ns_window.value != null);
        std.debug.assert(self.ns_view.value != null);
        if (self.cursor_shape) |current| {
            if (current == shape) return;
        }

        const NSCursor = objc.getClass("NSCursor") orelse return;
        const cursor = switch (shape) {
            .default => NSCursor.msgSend(objc.Object, "arrowCursor", .{}),
            .text => NSCursor.msgSend(objc.Object, "IBeamCursor", .{}),
            .pointer => NSCursor.msgSend(objc.Object, "pointingHandCursor", .{}),
            .resize_left_right => NSCursor.msgSend(objc.Object, "resizeLeftRightCursor", .{}),
            .resize_up_down => NSCursor.msgSend(objc.Object, "resizeUpDownCursor", .{}),
        };
        std.debug.assert(cursor.value != null);

        cursor.msgSend(void, "set", .{});
        self.cursor_shape = shape;
    }

    pub fn getPlatform(self: *Self) *platform.MacPlatform {
        assert(@intFromPtr(self.plat) != 0);
        return self.plat;
    }

    pub fn requestRender(self: *Self) void {
        assert(self.ns_window.value != null);
    }

    pub fn requestRenderAfter(self: *Self, delay_ms: u32) void {
        assert(self.ns_window.value != null);
        assert(delay_ms <= interface_mod.render_delay_ms_max);
    }

    pub fn setAppearance(self: *Self, dark: bool) void {
        assert(self.ns_window.value != null);
        const NSAppearance = objc.getClass("NSAppearance") orelse return;
        const NSString = objc.getClass("NSString") orelse return;

        const appearance_name: [*:0]const u8 =
            if (dark) "NSAppearanceNameDarkAqua" else "NSAppearanceNameAqua";
        const ns_name = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{appearance_name});
        const appearance_ptr =
            NSAppearance.msgSend(?*anyopaque, "appearanceNamed:", .{ns_name.value});

        if (appearance_ptr) |ptr| {
            const appearance = objc.Object.fromId(ptr);
            self.ns_window.msgSend(void, "setAppearance:", .{appearance.value});
        }
    }

    fn setupTrackingArea(self: *Self) !void {
        const bounds: NSRect = self.ns_view.msgSend(NSRect, "bounds", .{});

        const NSTrackingArea = objc.getClass("NSTrackingArea") orelse return error.ClassNotFound;

        const opts = appkit.NSTrackingAreaOptions;
        const options = opts.mouse_moved |
            opts.mouse_entered_and_exited |
            opts.active_in_key_window |
            opts.in_visible_rect;

        const tracking_area = NSTrackingArea.msgSend(objc.Object, "alloc", .{})
            .msgSend(objc.Object, "initWithRect:options:owner:userInfo:", .{
            bounds,
            options,
            self.ns_view.value,
            @as(objc.c.id, @ptrFromInt(0)),
        });

        self.ns_view.msgSend(void, "addTrackingArea:", .{tracking_area.value});
        assert(self.tracking_area == null);
        self.tracking_area = tracking_area;
    }

    fn setupMetalLayer(self: *Self) !void {
        const CAMetalLayer = objc.getClass("CAMetalLayer") orelse return error.ClassNotFound;
        self.metal_layer = CAMetalLayer.msgSend(objc.Object, "layer", .{});

        self.metal_layer.msgSend(void, "setPixelFormat:", .{@as(u64, 80)});
        self.metal_layer.msgSend(void, "setContentsScale:", .{self.scale_factor});
        self.metal_layer.msgSend(void, "setDisplaySyncEnabled:", .{false});

        self.metal_layer.msgSend(void, "setOpaque:", .{false});

        self.ns_view.msgSend(void, "setWantsLayer:", .{true});
        self.ns_view.msgSend(void, "setLayer:", .{self.metal_layer});

        const drawable_size = NSSize{
            .width = self.size.width * self.scale_factor,
            .height = self.size.height * self.scale_factor,
        };
        self.metal_layer.msgSend(void, "setDrawableSize:", .{drawable_size});
    }
};

fn titleBarInset(measured: struct {
    width: f64,
    strip_height: f64,
    buttons_min_x: f64,
    buttons_max_x: f64,
}) TitleBar.Inset {
    assert(measured.width >= 0);
    assert(measured.buttons_min_x <= measured.buttons_max_x);
    if (!(measured.strip_height > 0)) return .{};
    const top: f32 = @floatCast(@ceil(measured.strip_height));
    if (measured.buttons_min_x + measured.buttons_max_x <= measured.width) {
        const left = @max(measured.buttons_max_x + measured.buttons_min_x, 0);
        return .{ .top = top, .left = @floatCast(@ceil(left)) };
    } else {
        const right_edge = measured.width - measured.buttons_min_x;
        const right = @max(right_edge + (measured.width - measured.buttons_max_x), 0);
        return .{ .top = top, .right = @floatCast(@ceil(right)) };
    }
}

test "titleBarInset puts the lights' inset on their side and none in full screen" {
    const ltr = titleBarInset(.{
        .width = 500,
        .strip_height = 27.5,
        .buttons_min_x = 7,
        .buttons_max_x = 66.5,
    });
    try std.testing.expectEqual(TitleBar.Inset{ .top = 28, .left = 74 }, ltr);
    const rtl = titleBarInset(.{
        .width = 500,
        .strip_height = 32,
        .buttons_min_x = 433.5,
        .buttons_max_x = 493,
    });
    try std.testing.expectEqual(TitleBar.Inset{ .top = 32, .right = 74 }, rtl);
    const full_screen = titleBarInset(.{
        .width = 1440,
        .strip_height = 0,
        .buttons_min_x = 7,
        .buttons_max_x = 66,
    });
    try std.testing.expectEqual(TitleBar.Inset{}, full_screen);
}

pub fn contentSizeMax(
    window_limits: *const limits_mod.WindowLimits,
    scale_factor: f64,
) geometry.Size(f64) {
    assert(scale_factor > 0);
    assert(window_limits.framebuffer_width_max > 0);
    assert(window_limits.framebuffer_height_max > 0);
    const width_max: f64 = @floatFromInt(window_limits.framebuffer_width_max);
    const height_max: f64 = @floatFromInt(window_limits.framebuffer_height_max);
    const size = geometry.Size(f64).init(
        @floor(width_max / scale_factor),
        @floor(height_max / scale_factor),
    );
    assert(size.width * scale_factor <= width_max);
    assert(size.height * scale_factor <= height_max);
    return size;
}

pub fn framebufferViewport(
    logical: struct { width: f64, height: f64, scale_factor: f64 },
    window_limits: *const limits_mod.WindowLimits,
) backend.Viewport {
    assert(logical.scale_factor > 0);
    assert(logical.width >= 0 and logical.height >= 0);
    const width_max: f64 = @floatFromInt(window_limits.framebuffer_width_max);
    const height_max: f64 = @floatFromInt(window_limits.framebuffer_height_max);
    var scale = logical.scale_factor;
    if (logical.width * scale > width_max) scale = width_max / logical.width;
    if (logical.height * scale > height_max) scale = height_max / logical.height;
    var viewport = backend.Viewport.fromLogical(
        @floatCast(logical.width),
        @floatCast(logical.height),
        @floatCast(scale),
    );
    viewport.size_px.width = @min(viewport.size_px.width, window_limits.framebuffer_width_max);
    viewport.size_px.height = @min(viewport.size_px.height, window_limits.framebuffer_height_max);
    assert(viewport.scale_factor <= logical.scale_factor);
    return viewport;
}

test "a window opens with either title bar and only a transparent one has an inset" {
    const gpa = std.testing.allocator;
    const plat = try gpa.create(platform.MacPlatform);
    defer gpa.destroy(plat);
    try plat.initInPlace();
    defer plat.deinit();
    for ([_]TitleBar{ .standard, .transparent }) |title_bar| {
        const window = try Window.init(gpa, plat, &.{
            .title = "title bar check",
            .width = 320,
            .height = 200,
            .title_bar = title_bar,
            .limits = limits_mod.ResourceLimits.nano,
        });
        defer window.deinit();
        try std.testing.expectEqual(title_bar, window.title_bar);
        switch (title_bar) {
            .standard => try std.testing.expectEqual(TitleBar.Inset{}, window.title_bar_inset),
            .transparent => try std.testing.expect(window.title_bar_inset.top > 0),
        }
    }
}

test "contentSizeMax floors the budget's framebuffer to whole points at each scale" {
    const window_limits = limits_mod.WindowLimits{
        .framebuffer_width_max = 2560,
        .framebuffer_height_max = 1600,
    };
    const retina = contentSizeMax(&window_limits, 2);
    try std.testing.expectEqual(@as(f64, 1280), retina.width);
    try std.testing.expectEqual(@as(f64, 800), retina.height);

    const standard = contentSizeMax(&window_limits, 1);
    try std.testing.expectEqual(@as(f64, 2560), standard.width);
    try std.testing.expectEqual(@as(f64, 1600), standard.height);

    const fractional = contentSizeMax(&window_limits, 1.75);
    try std.testing.expectEqual(@as(f64, 1462), fractional.width);
    try std.testing.expectEqual(@as(f64, 914), fractional.height);
    const viewport = framebufferViewport(.{
        .width = fractional.width,
        .height = fractional.height,
        .scale_factor = 1.75,
    }, &window_limits);
    try std.testing.expectEqual(@as(f32, 1.75), viewport.scale_factor);
    try std.testing.expect(viewport.size_px.width <= 2560);
    try std.testing.expect(viewport.size_px.height <= 1600);
}

test "framebufferViewport keeps the scale within the limits and clamps past them" {
    const window_limits = limits_mod.WindowLimits{
        .framebuffer_width_max = 2560,
        .framebuffer_height_max = 1600,
    };
    const fits = framebufferViewport(.{
        .width = 1280,
        .height = 800,
        .scale_factor = 2,
    }, &window_limits);
    try std.testing.expectEqual(@as(f32, 2), fits.scale_factor);
    try std.testing.expectEqual(@as(u32, 2560), fits.size_px.width);
    try std.testing.expectEqual(@as(u32, 1600), fits.size_px.height);

    const wide = framebufferViewport(.{
        .width = 1281,
        .height = 400,
        .scale_factor = 2,
    }, &window_limits);
    try std.testing.expect(wide.scale_factor < 2);
    try std.testing.expectEqual(@as(u32, 2560), wide.size_px.width);
    try std.testing.expectEqual(@as(u32, 799), wide.size_px.height);

    const tall = framebufferViewport(.{
        .width = 100,
        .height = 1601,
        .scale_factor = 1,
    }, &window_limits);
    try std.testing.expect(tall.size_px.height <= 1600);
    try std.testing.expect(tall.scale_factor < 1);
}
