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
//! - `eve`: no framebuffer. A Bridgetek EVE (BT81x) display controller on
//!   spidev draws display lists; its touch engine is the input. For panels
//!   behind an EVE chip.
//!
//! Only Linux-target code may import this file: every target imports the
//! `gooey_build_options` module, but `linux_backend` means nothing elsewhere.

const build_options = @import("gooey_build_options");

pub const LinuxBackend = @TypeOf(build_options.linux_backend);

pub const selected: LinuxBackend = build_options.linux_backend;

/// True when frames are rasterized on the CPU rather than by Vulkan or by
/// an EVE display controller.
pub const uses_cpu_renderer = selected == .wayland_cpu or selected == .fbdev;
