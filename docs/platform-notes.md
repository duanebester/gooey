# Platform notes

Facts the code depends on that are not visible in it.

- `src/text/text_system.zig` (shape cache hit): cached glyphs are copied before the mutex is
  released, because another thread can evict the entry afterwards (use-after-free race).
- `src/platform/macos/core_host.zig` (`start`): the main thread spin-waits for the render
  loop so the first tick cannot race the CADisplayLink onto its run loop.
- `src/platform/macos/metal/atlas_textures.zig`: atlas upload ordering relies on Metal hazard
  tracking being enabled on the texture.
- `src/platform/linux/vk_surface_wayland.zig` (`swapchainDestroyEnd`): the double roundtrip
  drains `wl_buffer.release` events for Mesa's internal per-image buffers; a libwayland
  "queue destroyed while proxies still attached" warning can still appear and is not a leak.
- `src/platform/linux/clipboard.zig`: the drag-and-drop stub callbacks prevent null-pointer
  crashes on compositors such as Hyprland that dispatch those events.
- `src/platform/macos/input_view.zig`: `characters` stays null for Cmd key equivalents,
  because reading them can crash.
- `src/text/types.zig`: at the release-tracking capacity in release builds, fonts are leaked
  instead of crashing.
- `src/core/app.zig` and every `src/platform/*/core_host.zig`: the app and host must stay at
  their address after init, because handlers, `Cx`, and bound callbacks capture pointers.
