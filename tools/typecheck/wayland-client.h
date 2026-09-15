/*
 * Minimal `wayland-client.h` stand-in for the `typecheck-linux` build step.
 *
 * Why this file exists: `src/platform/linux/vulkan.zig` @cImports
 * `vulkan/vulkan.h` with `VK_USE_PLATFORM_WAYLAND_KHR` defined, which makes
 * `vulkan_wayland.h` pull in `wayland-client.h` for `struct wl_display` and
 * `struct wl_surface`. Those two incomplete types are the *only* thing the
 * Vulkan WSI extension headers need, and Gooey's own Wayland bindings
 * (`src/platform/linux/wayland.zig`) are plain `extern` declarations with no
 * C include of their own. So four lines of forward declarations are enough to
 * make the whole Linux tree semantically analyzable from a non-Linux host.
 *
 * Why it is committed rather than generated: it is our own file, not a
 * third-party dependency (CLAUDE.md §12), and committing it means the step
 * needs exactly one build option (`-Dvulkan-headers`) instead of two. The
 * real Vulkan headers are large and versioned upstream, so those stay out of
 * the tree and are supplied by the operator.
 *
 * This header must never be used for linking or code generation — it
 * deliberately declares no functions.
 */
#ifndef GOOEY_TYPECHECK_WAYLAND_CLIENT_H
#define GOOEY_TYPECHECK_WAYLAND_CLIENT_H
struct wl_display;
struct wl_surface;
#endif
