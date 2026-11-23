const std = @import("std");
const imports = @import("imports.zig");
const window_registry = @import("../window_registry.zig");
const WindowId = window_registry.WindowId;
const WindowRegistry = window_registry.WindowRegistry;

pub const WebPlatform = struct {
    running: bool = false,

    window_registry: WindowRegistry,

    const Self = @This();

    pub fn initInPlace(self: *Self) !void {
        self.window_registry = .init();
        self.running = false;

        std.debug.assert(self.window_registry.count() == 0);
        std.debug.assert(self.window_registry.getActiveWindow() == null);
    }

    pub fn registerWindow(self: *Self, window: *anyopaque) !WindowId {
        std.debug.assert(self.window_registry.count() == 0);

        const id = try self.window_registry.register(window);

        std.debug.assert(id.isValid());
        std.debug.assert(self.window_registry.count() == 1);
        return id;
    }

    pub fn getActiveWindowId(self: *const Self) ?WindowId {
        const active = self.window_registry.getActiveWindow();
        if (active) |id| std.debug.assert(id.isValid());
        if (self.window_registry.count() == 0) std.debug.assert(active == null);
        return active;
    }

    pub fn setActiveWindowId(self: *Self, id: ?WindowId) void {
        if (id) |window_id| std.debug.assert(window_id.isValid());

        self.window_registry.setActiveWindow(id);

        std.debug.assert(self.window_registry.getActiveWindow() == id);
    }

    pub fn run(self: *Self) void {
        std.debug.assert(!self.running);
        std.debug.assert(self.window_registry.count() <= 1);

        self.running = true;
        imports.requestAnimationFrame();
    }

    pub fn quit(self: *Self) void {
        std.debug.assert(self.window_registry.count() <= 1);

        self.running = false;
    }

    pub fn isRunning(self: *const Self) bool {
        return self.running;
    }

    pub fn lockRenderThreads(self: *Self) void {
        std.debug.assert(self.window_registry.count() <= 1);
    }

    pub fn unlockRenderThreads(self: *Self) void {
        std.debug.assert(self.window_registry.count() <= 1);
    }
};
