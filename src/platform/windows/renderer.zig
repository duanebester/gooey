//! The renderer a Win32 window draws through, chosen with
//! `-Dwindows-renderer=<value>` and fixed at compile time, so the unselected
//! renderer is never analyzed, linked, or loaded:
//!
//! - `vulkan` (default): the Vulkan renderer shared with Linux, presented
//!   through `vk_surface_win32.zig`.
//! - `dx11`: Direct3D 11 (`dx11_renderer.zig`), which falls back to WARP on
//!   machines without a hardware driver.
//!
//! Only Windows-target code may import this file: every target imports the
//! `gooey_build_options` module, but `windows_renderer` means nothing
//! elsewhere.

const build_options = @import("gooey_build_options");

pub const WindowsRenderer = @TypeOf(build_options.windows_renderer);

pub const selected: WindowsRenderer = build_options.windows_renderer;

pub const Renderer = switch (selected) {
    .vulkan => @import("../linux/vk_renderer.zig").VulkanRenderer,
    .dx11 => @import("dx11_renderer.zig").Dx11Renderer,
};
