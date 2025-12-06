//! macOS Window implementation with vsync-synchronized rendering

const std = @import("std");
const objc = @import("objc");
const geometry = @import("../../core/geometry.zig");
const platform = @import("platform.zig");
const metal = @import("metal/metal.zig");
const display_link = @import("display_link.zig");
const DisplayLink = display_link.DisplayLink;

pub const Window = struct {
    allocator: std.mem.Allocator,
    ns_window: objc.Object,
    ns_view: objc.Object,
    metal_layer: objc.Object,
    renderer: metal.Renderer,
    display_link: ?DisplayLink,
    size: geometry.Size(f64),
    scale_factor: f64,
    title: []const u8,
    background_color: geometry.Color,
    needs_render: std.atomic.Value(bool),

    pub const Options = struct {
        title: []const u8 = "Guiz Window",
        width: f64 = 800,
        height: f64 = 600,
        background_color: geometry.Color = geometry.Color.init(0.2, 0.2, 0.25, 1.0),
        use_display_link: bool = true, // Enable vsync by default
    };

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, plat: *platform.MacPlatform, options: Options) !*Self {
        _ = plat;

        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .ns_window = undefined,
            .ns_view = undefined,
            .metal_layer = undefined,
            .renderer = undefined,
            .display_link = null,
            .size = geometry.Size(f64).init(options.width, options.height),
            .scale_factor = 1.0,
            .title = options.title,
            .background_color = options.background_color,
            .needs_render = std.atomic.Value(bool).init(true),
        };

        // Create NSWindow
        const NSWindow = objc.getClass("NSWindow") orelse return error.ClassNotFound;

        // Style mask: titled, closable, miniaturizable, resizable
        const style_mask: u64 = (1 << 0) | (1 << 1) | (1 << 2) | (1 << 3);

        // Content rect
        const content_rect = NSRect{
            .origin = .{ .x = 100, .y = 100 },
            .size = .{ .width = options.width, .height = options.height },
        };

        // Alloc and init window
        const window_alloc = NSWindow.msgSend(objc.Object, "alloc", .{});
        self.ns_window = window_alloc.msgSend(
            objc.Object,
            "initWithContentRect:styleMask:backing:defer:",
            .{
                content_rect,
                style_mask,
                @as(u64, 2), // NSBackingStoreBuffered
                false,
            },
        );

        // Set window title
        self.setTitle(options.title);

        // Get content view
        self.ns_view = self.ns_window.msgSend(objc.Object, "contentView", .{});

        // Get backing scale factor for Retina displays
        self.scale_factor = self.ns_window.msgSend(f64, "backingScaleFactor", .{});

        // Setup Metal layer
        try self.setupMetalLayer();

        // Initialize renderer with scaled drawable size
        const drawable_size = geometry.Size(f64).init(
            self.size.width * self.scale_factor,
            self.size.height * self.scale_factor,
        );
        self.renderer = try metal.Renderer.init(self.metal_layer, drawable_size);

        // Setup display link for vsync
        if (options.use_display_link) {
            self.display_link = try DisplayLink.init();

            // Now set callback - 'self' is heap-allocated so pointer is stable
            try self.display_link.?.setCallback(displayLinkCallback, @ptrCast(self));
            try self.display_link.?.start();

            const refresh_rate = self.display_link.?.getRefreshRate();
            std.debug.print("DisplayLink started at {d:.1}Hz\n", .{refresh_rate});
        }

        // Make window key and visible
        self.ns_window.msgSend(void, "makeKeyAndOrderFront:", .{@as(?*anyopaque, null)});

        // Mark for initial render
        self.requestRender();

        return self;
    }

    pub fn deinit(self: *Self) void {
        // Stop display link first
        if (self.display_link) |*dl| {
            dl.deinit();
        }
        self.renderer.deinit();
        self.ns_window.msgSend(void, "close", .{});
        self.allocator.destroy(self);
    }

    fn setupMetalLayer(self: *Self) !void {
        // Create CAMetalLayer
        const CAMetalLayer = objc.getClass("CAMetalLayer") orelse return error.ClassNotFound;
        self.metal_layer = CAMetalLayer.msgSend(objc.Object, "layer", .{});

        // Configure the layer
        // Set pixel format to BGRA8Unorm
        self.metal_layer.msgSend(void, "setPixelFormat:", .{@as(u64, 80)}); // MTLPixelFormatBGRA8Unorm

        // Set contents scale for Retina
        self.metal_layer.msgSend(void, "setContentsScale:", .{self.scale_factor});

        // Disable CAMetalLayer's vsync - CVDisplayLink handles timing
        self.metal_layer.msgSend(void, "setDisplaySyncEnabled:", .{false});

        // Triple buffering for smooth rendering
        self.metal_layer.msgSend(void, "setMaximumDrawableCount:", .{@as(u64, 3)});

        // Set the layer on the view
        self.ns_view.msgSend(void, "setWantsLayer:", .{true});
        self.ns_view.msgSend(void, "setLayer:", .{self.metal_layer});

        // Set drawable size (scaled for Retina)
        const drawable_size = CGSize{
            .width = self.size.width * self.scale_factor,
            .height = self.size.height * self.scale_factor,
        };
        self.metal_layer.msgSend(void, "setDrawableSize:", .{drawable_size});
    }

    /// Request a render on the next vsync
    pub fn requestRender(self: *Self) void {
        self.needs_render.store(true, .release);
    }

    /// Manual render (for when display link is disabled)
    pub fn render(self: *Self) void {
        self.renderer.clear(self.background_color);
    }

    pub fn setTitle(self: *Self, title: []const u8) void {
        self.title = title;

        // Create NSString from title
        const NSString = objc.getClass("NSString") orelse return;
        const ns_title = NSString.msgSend(
            objc.Object,
            "stringWithUTF8String:",
            .{title.ptr},
        );

        self.ns_window.msgSend(void, "setTitle:", .{ns_title});
    }

    pub fn setBackgroundColor(self: *Self, color: geometry.Color) void {
        self.background_color = color;
        self.requestRender(); // Mark dirty for next vsync
    }

    pub fn getSize(self: *const Self) geometry.Size(f64) {
        return self.size;
    }
};

/// CVDisplayLink callback - runs on high-priority background thread
/// user_info points to the Window (heap-allocated, stable pointer)
fn displayLinkCallback(
    dl: display_link.CVDisplayLinkRef,
    in_now: *const display_link.CVTimeStamp,
    in_output_time: *const display_link.CVTimeStamp,
    flags_in: u64,
    flags_out: *u64,
    user_info: ?*anyopaque,
) callconv(.c) display_link.CVReturn {
    _ = dl;
    _ = in_now;
    _ = in_output_time;
    _ = flags_in;
    _ = flags_out;

    if (user_info) |ptr| {
        const window: *Window = @ptrCast(@alignCast(ptr));

        // Always render for now (to see Metal HUD)
        // window.renderer.clear(window.background_color);

        // Only render if needed (dirty flag pattern)
        if (window.needs_render.swap(false, .acq_rel)) {
            window.renderer.clear(window.background_color);
        }
    }

    return .success;
}

// CoreGraphics types for Objective-C interop
const CGFloat = f64;

const CGPoint = extern struct {
    x: CGFloat,
    y: CGFloat,
};

const CGSize = extern struct {
    width: CGFloat,
    height: CGFloat,
};

const NSRect = extern struct {
    origin: CGPoint,
    size: CGSize,
};
