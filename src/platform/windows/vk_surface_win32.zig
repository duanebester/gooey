const std = @import("std");
const assert = std.debug.assert;
const vk = @import("../linux/vulkan.zig");
const win32 = @import("win32.zig");

const structure_type_win32_surface_create_info: vk.StructureType = 1_000_009_000;

const Win32SurfaceCreateInfoKHR = extern struct {
    sType: vk.StructureType,
    pNext: ?*const anyopaque,
    flags: vk.Flags,
    hinstance: win32.HINSTANCE,
    hwnd: win32.HWND,
};

extern fn vkCreateWin32SurfaceKHR(
    instance: vk.Instance,
    pCreateInfo: *const Win32SurfaceCreateInfoKHR,
    pAllocator: ?*const vk.AllocationCallbacks,
    pSurface: *vk.Surface,
) callconv(.c) vk.Result;

pub const Win32Surface = struct {
    hinstance: win32.HINSTANCE,
    hwnd: win32.HWND,

    pub const instance_extension_name: [*:0]const u8 = "VK_KHR_win32_surface";

    pub const CreateError = error{
        Win32SurfaceCreationFailed,
    };

    pub fn create(self: *const Win32Surface, instance: vk.Instance) CreateError!vk.Surface {
        assert(instance != null);

        const create_info = Win32SurfaceCreateInfoKHR{
            .sType = structure_type_win32_surface_create_info,
            .pNext = null,
            .flags = 0,
            .hinstance = self.hinstance,
            .hwnd = self.hwnd,
        };

        var surface: vk.Surface = null;
        const result = vkCreateWin32SurfaceKHR(instance, &create_info, null, &surface);
        if (!vk.succeeded(result)) {
            std.log.err("Failed to create Win32 Vulkan surface: {}", .{result});
            return CreateError.Win32SurfaceCreationFailed;
        }

        assert(surface != null);
        return surface;
    }

    pub fn swapchainDestroyBegin(self: *const Win32Surface) void {
        assert(@intFromPtr(self.hwnd) != 0);
    }

    pub fn swapchainDestroyEnd(self: *const Win32Surface) void {
        assert(@intFromPtr(self.hwnd) != 0);
    }
};

comptime {
    assert(@sizeOf(Win32Surface) == 2 * @sizeOf(usize));
    assert(@sizeOf(Win32SurfaceCreateInfoKHR) == 40);
    assert(@offsetOf(Win32SurfaceCreateInfoKHR, "hinstance") == 24);
    assert(@offsetOf(Win32SurfaceCreateInfoKHR, "hwnd") == 32);
}
