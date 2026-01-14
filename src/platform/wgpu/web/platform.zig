//! WebPlatform - Platform implementation for WebAssembly/Browser

const std = @import("std");
const imports = @import("imports.zig");
const interface_mod = @import("../../interface.zig");
const file_dialog = @import("file_dialog.zig");
const window_registry = @import("../../window_registry.zig");
const WindowId = window_registry.WindowId;
const WindowRegistry = window_registry.WindowRegistry;

pub const WebPlatform = struct {
    running: bool = true,

    /// Registry for tracking windows by ID.
    /// Note: Web only supports a single window, but included for API consistency.
    window_registry: WindowRegistry,

    /// Allocator for platform resources
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Platform capabilities for Web/WASM
    pub const capabilities = interface_mod.PlatformCapabilities{
        .high_dpi = true,
        .multi_window = false, // Browser manages windows
        .gpu_accelerated = true,
        .display_link = false, // Uses requestAnimationFrame
        .can_close_window = false, // Can't close browser tabs
        .glass_effects = false, // CSS backdrop-filter would be separate
        .clipboard = true,
        .file_dialogs = true, // Via <input type="file"> and Blob downloads
        .ime = true, // Via beforeinput/compositionend events
        .custom_cursors = true, // Via CSS cursor property
        .window_drag_by_content = false,
        .name = "Web/WASM",
        .graphics_backend = "WebGPU",
    };

    pub fn init() !Self {
        return initWithAllocator(std.heap.page_allocator);
    }

    pub fn initWithAllocator(allocator: std.mem.Allocator) !Self {
        return .{
            .running = true,
            .window_registry = WindowRegistry.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.window_registry.deinit();
        self.running = false;
    }

    // =========================================================================
    // Window Registry (single window only on web)
    // =========================================================================

    /// Register a window with the platform and return its ID.
    /// Note: Web only supports a single window.
    pub fn registerWindow(self: *Self, window: *anyopaque) !WindowId {
        return self.window_registry.register(window);
    }

    /// Unregister a window by ID.
    pub fn unregisterWindow(self: *Self, id: WindowId) void {
        _ = self.window_registry.unregister(id);
    }

    /// Get a window by ID.
    pub fn getWindow(self: *const Self, id: WindowId) ?*anyopaque {
        return self.window_registry.get(id);
    }

    /// Get the active window ID.
    pub fn getActiveWindowId(self: *const Self) ?WindowId {
        return self.window_registry.getActiveWindow();
    }

    /// Set the active window by ID.
    pub fn setActiveWindowId(self: *Self, id: ?WindowId) void {
        self.window_registry.setActiveWindow(id);
    }

    /// Get the number of registered windows.
    pub fn windowCount(self: *const Self) u32 {
        return self.window_registry.count();
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

    // =========================================================================
    // File Dialog API
    // =========================================================================

    /// Initialize the file dialog system. Call once at startup.
    pub fn initFileDialog(allocator: std.mem.Allocator) void {
        file_dialog.init(allocator);
    }

    /// Deinitialize file dialog system
    pub fn deinitFileDialog() void {
        file_dialog.deinit();
    }

    /// Open files asynchronously. Callback invoked when user selects or cancels.
    /// Returns request_id for tracking, or null on failure.
    pub fn openFilesAsync(
        _: *Self,
        options: file_dialog.OpenDialogOptions,
        callback: file_dialog.FileDialogCallback,
    ) ?u32 {
        return file_dialog.openFilesAsync(options, callback);
    }

    /// Trigger a file download (web "save" dialog).
    /// Fire-and-forget - browser handles the download.
    pub fn saveFile(_: *Self, filename: []const u8, data: []const u8) void {
        file_dialog.saveFile(filename, data);
    }

    /// Cancel a pending file dialog request
    pub fn cancelFileDialog(_: *Self, request_id: u32) void {
        file_dialog.cancelRequest(request_id);
    }

    /// Check if a file dialog request is pending
    pub fn isFileDialogPending(_: *Self, request_id: u32) bool {
        return file_dialog.isPending(request_id);
    }
};
