//! Linux-only: the backend fixed at compile time by `-Dlinux-backend`.
//! Non-Linux targets import `gooey_build_options` but not this module.

const build_options = @import("gooey_build_options");

pub const LinuxBackend = @TypeOf(build_options.linux_backend);

pub const selected: LinuxBackend = build_options.linux_backend;

pub const uses_cpu_renderer = selected == .wayland_cpu or selected == .fbdev;
