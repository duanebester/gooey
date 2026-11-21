const std = @import("std");
const builtin = @import("builtin");

pub const interface = @import("interface.zig");

pub const contract = @import("contract.zig");

// `PlatformWindow` and the framework-level `Window` are deliberately distinct
// names for very different things: `PlatformWindow` is the OS-level handle
// (NSWindow on macOS, wl_surface on Linux, canvas on web); the framework-level
// `Window` holds per-window frame state.

pub const WindowOptions = interface.WindowOptions;

pub const CursorShape = interface.CursorShape;

pub const RendererCapabilities = interface.RendererCapabilities;

pub const WindowId = interface.WindowId;

pub const WindowRegistry = interface.WindowRegistry;

pub const PathPromptOptions = interface.PathPromptOptions;

pub const SavePromptOptions = interface.SavePromptOptions;

pub const PathPromptResult = interface.PathPromptResult;

pub const is_wasm = builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64;

pub const is_linux = builtin.os.tag == .linux;

// Read by policy that follows platform convention rather than by backend
// selection, which goes through `backend` below.
pub const is_macos = builtin.os.tag == .macos;

pub const is_windows = builtin.os.tag == .windows;

pub const backend = if (is_wasm)
    @import("web/mod.zig")
else switch (builtin.os.tag) {
    .macos => @import("macos/mod.zig"),
    .linux => switch (@import("linux_backend.zig").selected) {
        .wayland_vulkan, .wayland_cpu => @import("linux/mod.zig"),
        .fbdev => @import("fbdev/mod.zig"),
        .eve => @import("eve/mod.zig"),
    },
    .windows => @import("windows/mod.zig"),
    else => @compileError("Unsupported platform: " ++ @tagName(builtin.os.tag)),
};

// Every backend namespace declares `Platform` and `PlatformWindow`, so the
// aliases below do not have to know what any backend calls its own types.

// Every renderer, the CPU renderer included, keeps atlas pixels only in its
// own textures and receives them through `AtlasUploads` (`Renderer.uploadAtlas`).
// Synthetic-text builds draw with the `NullRenderer`, which reads the glyph
// atlas in place, so they keep CPU pixels.
pub const atlas_storage: @import("../text/atlas_uploads.zig").AtlasStorage = if (text_is_synthetic)
    .cpu_texture
else
    .gpu_upload;

const text_is_synthetic = @import("../text/mod.zig").is_synthetic;

pub const Platform = backend.Platform;

// The platform's native window object: `NSWindow` on macOS (wrapped),
// `wl_surface` plus xdg-shell state on Linux/Wayland, an
// `HTMLCanvasElement`-backed shim on web. Framework code should treat it as
// opaque and reach for it through `Window` (the framework-level wrapper).
// Named `PlatformWindow` so the framework wrapper can own the name `Window`.
pub const PlatformWindow = backend.PlatformWindow;

pub const macos = if (is_macos) @import("macos/mod.zig") else struct {};

// Short alias for `macos`, kept so existing callers compile.
pub const mac = macos;

pub const linux = if (is_linux) struct {
    pub const platform = @import("linux/platform.zig");
    pub const window = @import("linux/window.zig");
    pub const wayland = @import("linux/wayland.zig");
    pub const vulkan = @import("linux/vulkan.zig");
    pub const vk_renderer = @import("linux/vk_renderer.zig");
    pub const clipboard = @import("linux/clipboard.zig");
    pub const dbus = @import("linux/dbus.zig");
    pub const file_dialog = @import("linux/file_dialog.zig");
    pub const cpu = @import("cpu/renderer.zig");
    pub const LinuxPlatform = platform.LinuxPlatform;
    pub const Window = window.Window;
    pub const VulkanRenderer = vk_renderer.VulkanRenderer;
} else struct {};

pub const web = if (is_wasm) struct {
    pub const platform = @import("web/platform.zig");
    pub const window = @import("web/window.zig");
    pub const imports = @import("web/imports.zig");
} else struct {};
