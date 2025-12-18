//! WebPlatform - Platform implementation for WebAssembly/Browser

const std = @import("std");
const imports = @import("imports.zig");
const interface_mod = @import("../../interface.zig");

pub const WebPlatform = struct {
    running: bool = true,

    const Self = @This();

    /// Platform capabilities for Web/WASM
    pub const capabilities = interface_mod.PlatformCapabilities{
        .high_dpi = true,
        .multi_window = false, // Browser manages windows
        .gpu_accelerated = true,
        .display_link = false, // Uses requestAnimationFrame
        .can_close_window = false, // Can't close browser tabs
        .glass_effects = false, // CSS backdrop-filter would be separate
        .clipboard = true, // Via async Clipboard API
        .file_dialogs = false, // Would need HTML input element
        .ime = true, // Via beforeinput/compositionend events
        .custom_cursors = true, // Via CSS cursor property
        .window_drag_by_content = false,
        .name = "Web/WASM",
        .graphics_backend = "WebGPU",
    };

    pub fn init() !Self {
        return .{ .running = true };
    }

    pub fn deinit(self: *Self) void {
        self.running = false;
    }

    /// On web, run() kicks off the animation loop (non-blocking)
    pub fn run(self: *Self) void {
        if (self.running) {
            imports.requestAnimationFrame();
        }
    }

    pub fn quit(self: *Self) void {
        self.running = false;
    }

    pub fn isRunning(self: *const Self) bool {
        return self.running;
    }
};
