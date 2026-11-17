//! EveWindow - the single full-screen window of the EVE backend.
//!
//! The window covers the whole panel at scale 1: `WindowOptions.width` and
//! `height` are ignored, and the size never changes after initialization.
//! Frames become display lists in the window's `EveRenderer`, which the chip
//! draws itself. A touch panel shows no cursor.
//!
//! The core host (`core_host.zig`) owns the loop: it routes touch through
//! `handleInput` and presents each frame it packs with `presentFrame`.
//!
//! ## Memory (CLAUDE.md §2)
//!
//! The panel's size is read from the chip before the window opens. `init`
//! checks it against the app's `ResourceLimits.window` and fails when it does
//! not fit, then reserves the renderer (`renderer.zig`). Nothing is allocated
//! afterwards.

const std = @import("std");
const interface_mod = @import("../interface.zig");
const geometry = @import("../../geometry/geometry.zig");
const PackedFrame = @import("../../core/packed_frame.zig").PackedFrame;
const backend = @import("../../core/backend.zig");
const input = @import("../../input/events.zig");
const EveRenderer = @import("renderer.zig").EveRenderer;
const ResourceLimits = @import("../../core/limits.zig").ResourceLimits;
const eve_platform = @import("platform.zig");
const EvePlatform = eve_platform.EvePlatform;

const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const WindowId = interface_mod.WindowId;
const WindowOptions = interface_mod.WindowOptions;

pub const Window = struct {
    allocator: Allocator,
    platform: *EvePlatform,
    window_id: WindowId = .invalid,

    /// Logical size: the panel, at scale 1.
    size: geometry.Size(f64),
    scale_factor: f64 = 1,
    closed: bool = false,

    mouse_x: f64 = 0,
    mouse_y: f64 = 0,

    renderer: EveRenderer,

    // Written only by the section of 0.3.1 calls below.
    dark_appearance: bool = false,
    needs_redraw: bool = true,
    render_deadline_ms: ?i64 = null,
    title_buffer: [title_bytes_max]u8 = undefined,
    title_len: usize = 0,

    on_input: ?InputCallback = null,
    user_data: ?*anyopaque = null,

    pub const InputCallback = *const fn (*Self, input.InputEvent) bool;

    pub const title_bytes_max: usize = 255;

    const Self = @This();

    pub fn init(allocator: Allocator, plat: *EvePlatform, options: *const WindowOptions) !*Self {
        assert(options.width > 0);
        assert(options.height > 0);
        assert(options.title.len <= title_bytes_max);
        const chip = &plat.chip;
        assert(options.limits.check() == null);
        const window_limits = &options.limits.window;
        if (chip.panel_width > window_limits.framebuffer_width_max or
            chip.panel_height > window_limits.framebuffer_height_max)
        {
            std.log.err("eve: the {d}x{d} panel exceeds ResourceLimits.window ({d}x{d})", .{
                chip.panel_width,
                chip.panel_height,
                window_limits.framebuffer_width_max,
                window_limits.framebuffer_height_max,
            });
            return error.PanelExceedsResourceLimits;
        }

        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        // Field by field: the renderer makes the window about 150 KiB, too
        // large for a struct literal's stack temporary (CLAUDE.md §13).
        self.allocator = allocator;
        self.platform = plat;
        self.window_id = .invalid;
        self.size = .{
            .width = @floatFromInt(chip.panel_width),
            .height = @floatFromInt(chip.panel_height),
        };
        self.scale_factor = 1;
        self.closed = false;
        self.mouse_x = 0;
        self.mouse_y = 0;
        self.dark_appearance = false;
        self.needs_redraw = true;
        self.render_deadline_ms = null;
        self.on_input = null;
        self.user_data = null;
        self.setTitle(options.title);
        try self.initRenderer(&options.limits);
        errdefer self.renderer.deinit();

        self.window_id = try plat.registerWindow(self);
        plat.window = self;
        plat.setActiveWindowId(self.window_id);
        assert(self.window_id.isValid());
        assert(self.renderer.size_px.width == chip.panel_width);
        return self;
    }

    fn initRenderer(self: *Self, limits: *const ResourceLimits) !void {
        const chip = &self.platform.chip;
        assert(chip.panel_width > 0);
        self.renderer.chip = null;
        const render_limits = backend.RenderLimits.fromResourceLimits(limits);
        try self.renderer.initInPlace(&.{
            .native = chip,
            .size_px = .{ .width = chip.panel_width, .height = chip.panel_height },
            .scale_factor = 1,
        }, &render_limits);
        assert(self.renderer.chip == chip);
    }

    pub fn deinit(self: *Self) void {
        assert(@intFromPtr(self) != 0);
        if (self.window_id.isValid()) {
            self.platform.unregisterWindow(self.window_id);
            self.window_id = .invalid;
        }
        if (self.platform.window == self) self.platform.window = null;
        self.renderer.deinit();
        assert(self.platform.window != self);
        self.allocator.destroy(self);
    }

    /// The panel at scale 1: the viewport every frame draws at.
    pub fn viewport(self: *const Self) backend.Viewport {
        assert(self.scale_factor == 1);
        assert(self.renderer.size_px.width > 0);
        return .{ .size_px = self.renderer.size_px, .scale_factor = 1 };
    }

    /// Draw `frame` as one display list. The core host calls it as its
    /// presenter, after feeding the renderer the frame's atlas records.
    pub fn presentFrame(self: *Self, frame: *const PackedFrame, clear: geometry.Color) void {
        assert(!self.closed);
        assert(clear.a >= 0);
        self.renderer.draw(frame, self.viewport(), clear);
    }

    /// Route one input event to the application.
    pub fn handleInput(self: *Self, event: input.InputEvent) bool {
        assert(!self.closed);
        switch (event) {
            .mouse_down, .mouse_up, .mouse_moved, .mouse_dragged => |mouse| {
                self.mouse_x = mouse.position.x;
                self.mouse_y = mouse.position.y;
            },
            else => {},
        }
        const callback = self.on_input orelse return false;
        return callback(self, event);
    }

    /// Records the close; the core host's loop ends at its next turn.
    pub fn close(self: *Self) void {
        if (self.closed) return;
        self.closed = true;
        assert(self.isClosed());
    }

    pub fn isClosed(self: *const Self) bool {
        return self.closed;
    }

    // =========================================================================
    // Calls from the 0.3.1 `context/window.zig` and `cx.zig`
    // =========================================================================
    //
    // The core never makes these calls. They stay only while those files
    // compile, and go when phase 6 deletes them.

    /// Stored only: the panel has no title bar.
    pub fn setTitle(self: *Self, title: []const u8) void {
        assert(title.len <= title_bytes_max);
        const len = @min(title.len, title_bytes_max);
        @memcpy(self.title_buffer[0..len], title[0..len]);
        self.title_len = len;
    }

    pub fn setAppearance(self: *Self, dark: bool) void {
        self.dark_appearance = dark;
        assert(self.dark_appearance == dark);
    }

    pub fn getPlatform(self: *Self) *EvePlatform {
        assert(@intFromPtr(self.platform) != 0);
        return self.platform;
    }

    pub fn requestRender(self: *Self) void {
        if (self.closed) return;
        self.needs_redraw = true;
    }

    /// Keeps only the earliest deadline.
    pub fn requestRenderAfter(self: *Self, delay_ms: u32) void {
        assert(delay_ms <= interface_mod.render_delay_ms_max);
        if (self.closed) return;
        if (delay_ms == 0) {
            self.requestRender();
            return;
        }
        const deadline_ms = eve_platform.nowMilliseconds() + delay_ms;
        if (self.render_deadline_ms) |armed_ms| {
            if (armed_ms <= deadline_ms) return;
        }
        self.render_deadline_ms = deadline_ms;
        assert(self.render_deadline_ms.? <= deadline_ms);
    }

    // =========================================================================
    // Core host binding
    // =========================================================================

    pub fn setInputCallback(self: *Self, callback: ?InputCallback) void {
        self.on_input = callback;
    }

    pub fn setUserData(self: *Self, data: ?*anyopaque) void {
        self.user_data = data;
    }

    pub fn getUserData(self: *Self, comptime T: type) ?*T {
        const ptr = self.user_data orelse return null;
        return @ptrCast(@alignCast(ptr));
    }
};
