//! macOS Window implementation

const std = @import("std");
const objc = @import("objc");
const geometry = @import("../../core/geometry.zig");
const platform = @import("platform.zig");
const metal = @import("metal/metal.zig");

pub const Window = struct {
    allocator: std.mem.Allocator,
    ns_window: objc.Object,
    ns_view: objc.Object,
    metal_layer: objc.Object,
    renderer: metal.Renderer,
    size: geometry.Size(f64),
    scale_factor: f64,
    title: []const u8,
    background_color: geometry.Color,

    pub const Options = struct {
        title: []const u8 = "Guiz Window",
        width: f64 = 800,
        height: f64 = 600,
        background_color: geometry.Color = geometry.Color.init(0.2, 0.2, 0.25, 1.0),
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
            .size = geometry.Size(f64).init(options.width, options.height),
            .scale_factor = 1.0,
            .title = options.title,
            .background_color = options.background_color,
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

        // Make window key and visible
        self.ns_window.msgSend(void, "makeKeyAndOrderFront:", .{@as(?*anyopaque, null)});

        // Initial render
        self.render();

        return self;
    }

    pub fn deinit(self: *Self) void {
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
    }

    pub fn render(self: *Self) void {
        self.renderer.clear(self.background_color);
    }

    pub fn getSize(self: *const Self) geometry.Size(f64) {
        return self.size;
    }
};

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
