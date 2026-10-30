//! The Linux display and renderer pair this build selected.
//!
//! Chosen with `-Dlinux-backend=<value>` (or the `linux-backend` dependency
//! option) and fixed at compile time, so code for the unselected backends is
//! never analyzed, linked, or loaded:
//!
//! - `wayland_vulkan` (default): Wayland window, Vulkan GPU renderer.
//! - `wayland_cpu`: Wayland window, CPU renderer presented through `wl_shm`.
//!   For desktops without a usable Vulkan driver.
//! - `fbdev`: no display server. The CPU renderer draws to `/dev/fb0` and
//!   input comes from evdev. For embedded Linux devices.
//!
//! Only Linux-target code may import this file: every target imports the
//! `gooey_build_options` module, but `linux_backend` means nothing elsewhere.

const build_options = @import("gooey_build_options");

pub const LinuxBackend = @TypeOf(build_options.linux_backend);

pub const selected: LinuxBackend = build_options.linux_backend;

/// True when frames are rasterized on the CPU rather than by Vulkan.
pub const uses_cpu_renderer = selected != .wayland_vulkan;

/// The selected backend's clipboard. Wayland shares text with other clients
/// through the compositor; fbdev keeps it inside the process. Both expose
/// `getText(allocator) ?[]const u8` and `setText([]const u8) bool`.
pub const clipboard = switch (selected) {
    .wayland_vulkan, .wayland_cpu => @import("linux/clipboard.zig"),
    .fbdev => @import("fbdev/clipboard.zig"),
};
