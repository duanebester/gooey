//! WebPlatform - Platform implementation for WebAssembly/Browser

const std = @import("std");
const imports = @import("imports.zig");
const interface_mod = @import("../../interface.zig");
const file_dialog = @import("file_dialog.zig");

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
        .clipboard = true,
        .file_dialogs = true, // Via <input type="file"> and Blob downloads
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
