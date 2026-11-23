const std = @import("std");
const assert = std.debug.assert;
const vk = @import("vulkan.zig");
const wayland = @import("wayland.zig");

pub const WaylandSurface = struct {
    display: *wayland.Display,
    surface: *wayland.Surface,

    pub const instance_extension_name: [*:0]const u8 = "VK_KHR_wayland_surface";

    pub const CreateError = error{
        WaylandSurfaceCreationFailed,
    };

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

    pub fn swapchainDestroyBegin(self: *const WaylandSurface) void {
        _ = wayland.wl_display_flush(self.display);
        _ = wayland.wl_display_roundtrip(self.display);
    }

    pub fn swapchainDestroyEnd(self: *const WaylandSurface) void {
        _ = wayland.wl_display_flush(self.display);
        _ = wayland.wl_display_roundtrip(self.display);
        _ = wayland.wl_display_roundtrip(self.display);
    }
};

comptime {
    assert(@sizeOf(WaylandSurface) == 2 * @sizeOf(usize));
}
