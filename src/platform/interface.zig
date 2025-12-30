//! Platform Interface Definitions
//!
//! This module defines the interfaces for platform abstraction in gooey.
//! Includes file dialog support via PathPromptOptions/PathPromptResult.
//! These interfaces enable:
//!
//! 1. **Compile-time selection** - Use `Platform` and `Window` type aliases
//!    for maximum performance (zero-cost abstraction)
//!
//! 2. **Runtime polymorphism** - Use `PlatformVTable` and `WindowVTable`
//!    when you need to dynamically switch implementations
//!
//! ## Usage
//!
//! ### Compile-time (recommended for most apps)
//! ```zig
//! const platform = @import("gooey").platform;
//!
//! var plat = try platform.Platform.init();
//! defer plat.deinit();
//!
//! var window = try platform.Window.init(allocator, &plat, .{});
//! defer window.deinit();
//!
//! plat.run();
//! ```
//!
//! ### Runtime polymorphism (for plugin systems, testing, etc.)
//! ```zig
//! const platform = @import("gooey").platform;
//!
//! var plat_impl = try platform.Platform.init();
//! var plat = plat_impl.interface(); // Get PlatformVTable
//!
//! // Pass around as interface
//! runApp(&plat);
//! ```
//!
//! ## Supported Platforms
//!
//! - macOS: AppKit + Metal
//! - (future) Windows: Win32 + DirectX 12
//! - (future) Linux: X11/Wayland + Vulkan

const std = @import("std");
const geometry = @import("../core/geometry.zig");
const scene_mod = @import("../core/scene.zig");
const input = @import("../core/input.zig");
const text_mod = @import("../text/mod.zig");

// =============================================================================
// Platform Interface
// =============================================================================

/// Platform interface for runtime polymorphism.
///
/// Represents an application platform providing event loop and window creation.
/// For most use cases, prefer the compile-time selected `Platform` type instead.
pub const PlatformVTable = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Run the platform event loop (blocking)
        run: *const fn (ptr: *anyopaque) void,

        /// Signal the platform to quit
        quit: *const fn (ptr: *anyopaque) void,

        /// Clean up platform resources
        deinit: *const fn (ptr: *anyopaque) void,
    };

    /// Run the platform event loop (blocking until quit)
    pub fn run(self: PlatformVTable) void {
        self.vtable.run(self.ptr);
    }

    /// Signal the platform to quit
    pub fn quit(self: PlatformVTable) void {
        self.vtable.quit(self.ptr);
    }

    /// Clean up platform resources
    pub fn deinit(self: PlatformVTable) void {
        self.vtable.deinit(self.ptr);
    }
};

//// Capabilities a platform implementation may support.
/// Used for feature detection at runtime.
pub const PlatformCapabilities = struct {
    /// Platform supports high-DPI (Retina) displays
    high_dpi: bool = true,

    /// Platform supports multiple windows
    multi_window: bool = true,

    /// Platform supports GPU-accelerated rendering
    gpu_accelerated: bool = true,

    /// Platform supports vsync via display link
    display_link: bool = true,

    /// Platform can programmatically close windows
    can_close_window: bool = true,

    /// Platform supports glass/blur effects
    glass_effects: bool = false,

    /// Platform supports clipboard access
    clipboard: bool = true,

    /// Platform supports native file dialogs
    file_dialogs: bool = true,

    /// Platform supports IME (Input Method Editor)
    ime: bool = true,

    /// Platform supports cursor customization
    custom_cursors: bool = true,

    /// Platform supports window dragging by content
    window_drag_by_content: bool = false,

    /// Platform name (for debugging)
    name: []const u8 = "unknown",

    /// Graphics backend name
    graphics_backend: []const u8 = "unknown",
};

// =============================================================================
// File Dialog Types
// =============================================================================

/// Options for file open dialogs
pub const PathPromptOptions = struct {
    /// Allow selecting directories
    directories: bool = false,
    /// Allow selecting files
    files: bool = true,
    /// Allow multiple selection
    multiple: bool = false,
    /// Button text (e.g., "Open", "Select")
    prompt: ?[]const u8 = null,
    /// Window title/message
    message: ?[]const u8 = null,
    /// Starting directory path
    starting_directory: ?[]const u8 = null,
    /// Allowed file extensions (e.g., &.{"txt", "md"})
    allowed_extensions: ?[]const []const u8 = null,
};

/// Options for file save dialogs
pub const SavePromptOptions = struct {
    /// Starting directory path
    directory: ?[]const u8 = null,
    /// Suggested filename
    suggested_name: ?[]const u8 = null,
    /// Button text (e.g., "Save")
    prompt: ?[]const u8 = null,
    /// Window title/message
    message: ?[]const u8 = null,
    /// Allowed file extensions (e.g., &.{"txt", "md"})
    allowed_extensions: ?[]const []const u8 = null,
    /// Allow creating directories
    can_create_directories: bool = true,
};

/// Result from a file dialog
pub const PathPromptResult = struct {
    /// Selected paths (empty if cancelled)
    paths: [][]const u8,
    /// Allocator used - caller must free paths
    allocator: std.mem.Allocator,

    pub fn deinit(self: PathPromptResult) void {
        for (self.paths) |path| {
            self.allocator.free(path);
        }
        self.allocator.free(self.paths);
    }
};

// =============================================================================
// Window Interface
// =============================================================================

/// Window creation options.
pub const WindowOptions = struct {
    /// Window title
    title: []const u8 = "Gooey Window",

    /// Initial width in logical pixels
    width: f64 = 800,

    /// Initial height in logical pixels
    height: f64 = 600,

    /// Background color
    background_color: geometry.Color = geometry.Color.init(0.2, 0.2, 0.25, 1.0),

    /// Enable vsync via display link (recommended)
    use_display_link: bool = true,

    /// Minimum window size (optional)
    min_size: ?geometry.Size(f64) = null,

    /// Maximum window size (optional)
    max_size: ?geometry.Size(f64) = null,

    /// Start window centered on screen
    centered: bool = true,

    // Cross-platform fields (some may be no-ops on certain platforms)

    /// Custom shaders (MSL for macOS, WGSL for web, ignored on Linux)
    custom_shaders: []const @import("../core/shader.zig").CustomShader = &.{},

    /// Background opacity (0.0 = fully transparent, 1.0 = opaque)
    /// Only effective on macOS; other platforms ignore this
    background_opacity: f32 = 1.0,

    /// Glass/blur style for transparent windows (macOS only)
    /// Use platform.Window.GlassStyle for the enum values
    glass_style: GlassStyleCompat = .none,

    /// Corner radius for glass effect (macOS only)
    glass_corner_radius: f32 = 16.0,

    /// Make titlebar transparent (macOS only)
    titlebar_transparent: bool = false,

    /// Extend content under titlebar (macOS only)
    full_size_content: bool = false,

    /// Platform-agnostic glass style (for cross-platform code)
    pub const GlassStyleCompat = enum(u8) {
        /// No glass effect
        none = 0,
        /// macOS 26+ liquid glass (regular density)
        glass_regular = 1,
        /// macOS 26+ liquid glass (clear/lighter)
        glass_clear = 2,
        /// Traditional background blur (works on older macOS)
        blur = 3,
    };
};

/// Window interface for runtime polymorphism.
///
/// Represents a native window with rendering and input handling.
/// For most use cases, prefer the compile-time selected `Window` type instead.
pub const WindowVTable = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        // Lifecycle
        deinit: *const fn (ptr: *anyopaque) void,

        // Properties
        width: *const fn (ptr: *anyopaque) u32,
        height: *const fn (ptr: *anyopaque) u32,
        getSize: *const fn (ptr: *anyopaque) geometry.Size(f64),
        getScaleFactor: *const fn (ptr: *anyopaque) f64,
        setTitle: *const fn (ptr: *anyopaque, title: []const u8) void,
        setBackgroundColor: *const fn (ptr: *anyopaque, color: geometry.Color) void,

        // Input
        getMousePosition: *const fn (ptr: *anyopaque) geometry.Point(f64),
        isMouseInside: *const fn (ptr: *anyopaque) bool,

        // Rendering
        requestRender: *const fn (ptr: *anyopaque) void,
        setScene: *const fn (ptr: *anyopaque, scene: *const scene_mod.Scene) void,
        setTextAtlas: *const fn (ptr: *anyopaque, atlas: *const text_mod.Atlas) void,
    };

    pub fn deinit(self: WindowVTable) void {
        self.vtable.deinit(self.ptr);
    }

    pub fn width(self: WindowVTable) u32 {
        return self.vtable.width(self.ptr);
    }

    pub fn height(self: WindowVTable) u32 {
        return self.vtable.height(self.ptr);
    }

    pub fn getSize(self: WindowVTable) geometry.Size(f64) {
        return self.vtable.getSize(self.ptr);
    }

    pub fn getScaleFactor(self: WindowVTable) f64 {
        return self.vtable.getScaleFactor(self.ptr);
    }

    pub fn setTitle(self: WindowVTable, title: []const u8) void {
        self.vtable.setTitle(self.ptr, title);
    }

    pub fn setBackgroundColor(self: WindowVTable, color: geometry.Color) void {
        self.vtable.setBackgroundColor(self.ptr, color);
    }

    pub fn getMousePosition(self: WindowVTable) geometry.Point(f64) {
        return self.vtable.getMousePosition(self.ptr);
    }

    pub fn isMouseInside(self: WindowVTable) bool {
        return self.vtable.isMouseInside(self.ptr);
    }

    pub fn requestRender(self: WindowVTable) void {
        self.vtable.requestRender(self.ptr);
    }

    pub fn setScene(self: WindowVTable, scene: *const scene_mod.Scene) void {
        self.vtable.setScene(self.ptr, scene);
    }

    pub fn setTextAtlas(self: WindowVTable, atlas: *const text_mod.Atlas) void {
        self.vtable.setTextAtlas(self.ptr, atlas);
    }
};

/// Renderer capabilities for feature detection.
pub const RendererCapabilities = struct {
    max_texture_size: u32 = 4096,
    msaa: bool = true,
    msaa_sample_count: u32 = 4,
    unified_memory: bool = false,
    name: []const u8 = "unknown",
};

/// Helper to generate a PlatformVTable from a concrete Platform implementation.
pub fn makePlatformVTable(comptime T: type, ptr: *T) PlatformVTable {
    const vtable = struct {
        fn run(p: *anyopaque) void {
            const self: *T = @ptrCast(@alignCast(p));
            self.run();
        }

        fn quit(p: *anyopaque) void {
            const self: *T = @ptrCast(@alignCast(p));
            self.quit();
        }

        fn deinitFn(p: *anyopaque) void {
            const self: *T = @ptrCast(@alignCast(p));
            self.deinit();
        }

        const table = PlatformVTable.VTable{
            .run = run,
            .quit = quit,
            .deinit = deinitFn,
        };
    };

    return .{
        .ptr = ptr,
        .vtable = &vtable.table,
    };
}

test "interface compiles" {
    _ = PlatformVTable;
    _ = WindowVTable;
    _ = PlatformCapabilities;
    _ = WindowOptions;
}
