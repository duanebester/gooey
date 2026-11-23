const std = @import("std");
const builtin = @import("builtin");

pub const interface = @import("interface.zig");

pub const contract = @import("contract.zig");

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

pub const atlas_storage: @import("../text/atlas_uploads.zig").AtlasStorage = if (text_is_synthetic)
    .cpu_texture
else
    .gpu_upload;

const text_is_synthetic = @import("../text/mod.zig").is_synthetic;

pub const Platform = backend.Platform;

pub const PlatformWindow = backend.PlatformWindow;

pub const macos = if (is_macos) @import("macos/mod.zig") else struct {};

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
