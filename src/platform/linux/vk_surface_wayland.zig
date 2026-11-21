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

    /// The caller owns the returned `VkSurfaceKHR`.
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

    pub fn swapchainDestroyBegin(self: *const WaylandSurface) void {
        _ = wayland.wl_display_flush(self.display);
        _ = wayland.wl_display_roundtrip(self.display);
    }

    // Roundtrips drain compositor wl_buffer.release events after swapchain
    // destruction. A "queue destroyed while proxies still attached" warning
    // may still appear: Mesa creates an internal wl_buffer per swapchain
    // image, destroys them with the swapchain, and the compositor may send
    // releases after the app exits. The warning is a libwayland-client debug
    // message, not a resource leak; the roundtrips minimize but cannot fully
    // eliminate the race.
    pub fn swapchainDestroyEnd(self: *const WaylandSurface) void {
        _ = wayland.wl_display_flush(self.display);
        _ = wayland.wl_display_roundtrip(self.display);
        _ = wayland.wl_display_roundtrip(self.display);
    }
};

comptime {
    assert(@sizeOf(WaylandSurface) == 2 * @sizeOf(usize));
}
