//! Platform abstraction layer for gooey
//!
//! This module provides a unified interface for platform-specific functionality.
//! The appropriate backend is selected at compile time based on the target OS.
//!
//! ## Usage
//!
//! ```zig
//! const platform = @import("gooey").platform;
//!
//! // Platform detection
//! if (platform.is_wasm) { ... }
//!
//! // Capabilities
//! const caps = platform.getCapabilities();
//! if (caps.can_close_window) { ... }
//! ```

const std = @import("std");
const builtin = @import("builtin");

// =============================================================================
// Shared contract
// =============================================================================

pub const interface = @import("interface.zig");

/// Exact compile-time verification of the platform boundary.
pub const contract = @import("contract.zig");

// PR 7b.1a — `platform.Window` was renamed to `platform.PlatformWindow`
// to free up the `Window` name for the upcoming `Gooey → Window` rename
// in PR 7b.1b. The two are very different things — `PlatformWindow` is
// the OS-level handle (NSWindow on macOS, wl_surface on Linux, canvas
// on web); the framework-level `Window` will hold per-window frame
// state. Keeping them under one name was always going to bite once the
// `Gooey` god object split landed; this PR pre-empts the collision.
//
// See `docs/cleanup-implementation-plan.md` PR 7b for the broader
// App/Window split, and `architectural-cleanup-plan.md` §10 for the
// GPUI mapping where `platform_window: PlatformWindow` is the pattern
// being adopted.

/// Platform capabilities
pub const PlatformCapabilities = interface.PlatformCapabilities;

/// Window creation options (platform-agnostic)
pub const WindowOptions = interface.WindowOptions;

/// How the selected backend's host hands control to Gooey.
pub const DriveModel = interface.DriveModel;

/// Cursor shapes selected by framework widgets.
pub const CursorShape = interface.CursorShape;

/// Translucent-background style, shared by every backend.
pub const GlassStyle = interface.GlassStyle;

/// Renderer capabilities
pub const RendererCapabilities = interface.RendererCapabilities;

/// Unique identifier for windows
pub const WindowId = interface.WindowId;

/// Central registry for tracking windows by ID
pub const WindowRegistry = interface.WindowRegistry;

/// File dialog options (open)
pub const PathPromptOptions = interface.PathPromptOptions;

/// File dialog options (save)
pub const SavePromptOptions = interface.SavePromptOptions;

/// File dialog result
pub const PathPromptResult = interface.PathPromptResult;

// =============================================================================
// Compile-time Platform Selection
// =============================================================================

pub const is_wasm = builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64;

// =============================================================================
// Backend Selection
// =============================================================================
//
// Note: Time utilities previously lived here as `platform.time`. As of the
// Zig 0.16 `std.Io` migration, callers sample timestamps via
// `std.Io.Timestamp.now(io, .awake)` directly (see `docs/zig-0.16-io-migration.md`,
// phase 5.4/5.6). The `platform/time.zig` shim has been retired.

pub const is_linux = builtin.os.tag == .linux;

pub const backend = if (is_wasm)
    @import("web/mod.zig")
else switch (builtin.os.tag) {
    .macos => @import("macos/mod.zig"),
    .linux => @import("linux/mod.zig"),
    else => @compileError("Unsupported platform: " ++ @tagName(builtin.os.tag)),
};

// Every backend namespace declares `Platform`, `PlatformWindow`, and
// `drive_model`, and pins itself with `contract.verifyBackend`. Deriving the
// public aliases from those canonical names — rather than switching on each
// backend's own spelling (`MacPlatform`, `LinuxPlatform`, `WebPlatform`) —
// means adding a backend cannot silently skip the contract, and the selection
// logic no longer has to know what any backend calls its own types.

/// Platform type for the current target (compile-time selected).
pub const Platform = backend.Platform;

/// OS-level window handle for the current target (compile-time selected).
///
/// This is the platform's native window object — `NSWindow` on macOS
/// (wrapped), `wl_surface` plus xdg-shell state on Linux/Wayland, an
/// `HTMLCanvasElement`-backed shim on web. Framework code should
/// generally treat it as opaque and reach for it through `Window`
/// (the framework-level wrapper, see `context/gooey.zig`) rather than
/// here.
///
/// Renamed from `Window` in PR 7b.1a so the framework wrapper can
/// claim that name in PR 7b.1b without a `platform.Window` collision.
pub const PlatformWindow = backend.PlatformWindow;

/// Host drive model of the selected backend.
///
/// `blocking_event_loop` on macOS and Linux, `host_callback` on web. This is a
/// comptime constant, so branching on it costs nothing and the untaken arm is
/// never analyzed.
///
/// Phase-4 groundwork, not a landed feature: every backend declares it and
/// `contract.verifyBackend` pins its type, but no runtime code branches on it
/// yet. The intended first consumer is `src/runtime/runner.zig`, which runs
/// `plat.run()` and then unwinds its `defer`s — correct for
/// `blocking_event_loop`, wrong for `host_callback`, where `run` returns
/// immediately and teardown must wait for the host to stop calling back. Until
/// that branch exists, this is verified documentation of a host difference
/// rather than something the runtime honours.
pub const drive_model: DriveModel = backend.drive_model;

/// DisplayLink for vsync (native only, not available on Linux)
pub const DisplayLink = if (is_wasm)
    void // Not applicable on web
else if (is_linux)
    void // Linux uses Wayland frame callbacks
else
    backend.DisplayLink;

// =============================================================================
// Platform-specific modules (for advanced usage)
// =============================================================================

pub const macos = if (!is_wasm and !is_linux) @import("macos/mod.zig") else struct {};

// Legacy alias for backwards compatibility
pub const mac = macos;

pub const linux = if (is_linux) struct {
    pub const platform = @import("linux/platform.zig");
    pub const window = @import("linux/window.zig");
    pub const wayland = @import("linux/wayland.zig");
    pub const vulkan = @import("linux/vulkan.zig");
    pub const vk_renderer = @import("linux/vk_renderer.zig");
    pub const unified = @import("unified.zig");
    pub const clipboard = @import("linux/clipboard.zig");
    pub const dbus = @import("linux/dbus.zig");
    pub const file_dialog = @import("linux/file_dialog.zig");
    // Type aliases
    pub const LinuxPlatform = platform.LinuxPlatform;
    pub const Window = window.Window;
    pub const VulkanRenderer = vk_renderer.VulkanRenderer;
} else struct {};

// PR 9 Task 2.5 — `image_loader` moved from `root.wasm_image_loader`
// (and the duplicate private `runtime/render.zig::wasm_loader` shim) into
// `platform.web.image_loader`. The conditional-stub lived in two places
// historically; consolidating it here puts the platform-conditional logic
// next to the rest of the `web` namespace (`platform`, `window`,
// `imports`, `file_dialog`) and lets non-WASM callers resolve through the
// same path without each call site rolling its own stub.
pub const web = if (is_wasm) struct {
    pub const platform = @import("web/platform.zig");
    pub const window = @import("web/window.zig");
    pub const imports = @import("web/imports.zig");
    pub const file_dialog = @import("web/file_dialog.zig");
    pub const image_loader = @import("web/image_loader.zig");
} else struct {
    // Stub mirroring `web/image_loader.zig`'s public surface so non-WASM
    // call sites compile against the same names. All entry points are
    // no-ops on native — runtime image loading on native goes through
    // `image.ImageLoader` instead (the native-only async loader landed
    // in PR 1; the WASM async path remains separate because browser
    // `createImageBitmap` requires a JS round-trip).
    pub const image_loader = struct {
        pub const DecodedImage = struct {
            width: u32,
            height: u32,
            pixels: []u8,
            owned: bool,
            pub fn deinit(_: *@This(), _: std.mem.Allocator) void {}
        };
        pub const DecodeCallback = *const fn (u32, ?DecodedImage) void;
        pub fn init(_: std.mem.Allocator) void {}
        pub fn deinit() void {}
        pub fn loadFromUrlAsync(_: []const u8, _: DecodeCallback) ?u32 {
            return null;
        }
        pub fn loadFromMemoryAsync(_: []const u8, _: DecodeCallback) ?u32 {
            return null;
        }
    };
};

// =============================================================================
// Helpers
// =============================================================================

/// Get the capabilities of the current platform.
pub fn getCapabilities() PlatformCapabilities {
    return Platform.capabilities;
}
