//! Wayland implementation of the Vulkan presentation surface (`vk_surface`).

const std = @import("std");
const assert = std.debug.assert;
const vk = @import("vulkan.zig");
const wayland = @import("wayland.zig");

/// Borrowed Wayland objects a `VkSurfaceKHR` is created from. The window owns
/// both and keeps them alive for as long as the renderer that holds this.
pub const WaylandSurface = struct {
    display: *wayland.Display,
    surface: *wayland.Surface,

    pub const instance_extension_name: [*:0]const u8 = "VK_KHR_wayland_surface";

    pub const CreateError = error{
        WaylandSurfaceCreationFailed,
    };

    /// Create the `VkSurfaceKHR` for presentation; the caller owns it.
    pub fn create(self: *const WaylandSurface, instance: vk.Instance) CreateError!vk.Surface {
        assert(instance != null);

        const create_info = vk.WaylandSurfaceCreateInfoKHR{
            .sType = vk.VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR,
            .pNext = null,
            .flags = 0,
            .display = @ptrCast(self.display),
            .surface = @ptrCast(self.surface),
        };

        var surface: vk.Surface = null;
        const result = vk.vkCreateWaylandSurfaceKHR(instance, &create_info, null, &surface);
        if (!vk.succeeded(result)) {
            std.log.err("Failed to create Wayland surface: {}", .{result});
            return CreateError.WaylandSurfaceCreationFailed;
        }

        assert(surface != null);
        return surface;
    }

    // The flush and roundtrip results below are deliberately unchecked: they
    // only fail once the display connection is lost, and a lost compositor has
    // already released every buffer, so swapchain teardown proceeds either way.

    /// Flush pending Wayland requests before the swapchain is destroyed.
    pub fn swapchainDestroyBegin(self: *const WaylandSurface) void {
        _ = wayland.wl_display_flush(self.display);
        _ = wayland.wl_display_roundtrip(self.display);
    }

    /// Roundtrip after destroying the swapchain to process compositor release
    /// events.
    ///
    /// A "queue destroyed while proxies still attached" warning may still
    /// appear. This is a known limitation of Mesa's Vulkan Wayland WSI:
    /// - Mesa creates internal wl_buffer objects for each swapchain image.
    /// - When the swapchain is destroyed, Mesa destroys these wl_buffers.
    /// - The compositor may still hold references, sending wl_buffer.release later.
    /// - If the app exits before processing release events, the warning appears.
    ///
    /// The warning is harmless: the compositor cleans up properly regardless.
    /// It is a libwayland-client debugging message, not a resource leak. The
    /// roundtrips minimize but cannot fully eliminate this race.
    pub fn swapchainDestroyEnd(self: *const WaylandSurface) void {
        _ = wayland.wl_display_flush(self.display);
        _ = wayland.wl_display_roundtrip(self.display);
        _ = wayland.wl_display_roundtrip(self.display);
    }
};

comptime {
    // Two borrowed pointers: small enough to pass by value (CLAUDE.md §13).
    assert(@sizeOf(WaylandSurface) == 2 * @sizeOf(usize));
}
