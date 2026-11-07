//! `VK_KHR_win32_surface` bindings.
//!
//! The shared Vulkan renderer (`linux/vulkan.zig`, reused verbatim) declares
//! the WSI-neutral core API. The Windows-specific surface creation entry
//! point lives here so the shared bindings stay free of platform conditionals:
//! each backend supplies its own `create*Surface` helper and its own instance
//! extension list. No external Vulkan headers are involved.

const vk = @import("../linux/vulkan.zig");

pub const VK_KHR_WIN32_SURFACE_EXTENSION_NAME: [*:0]const u8 = "VK_KHR_win32_surface";

/// `VkStructureType` value for `VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR`.
pub const VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR: vk.StructureType = 1000009000;

pub const Win32SurfaceCreateFlagsKHR = vk.Flags;

/// `VkWin32SurfaceCreateInfoKHR`. `hinstance`/`hwnd` are opaque Win32 handles;
/// the loader only passes them through to the WSI implementation.
pub const Win32SurfaceCreateInfoKHR = extern struct {
    sType: vk.StructureType,
    pNext: ?*const anyopaque,
    flags: Win32SurfaceCreateFlagsKHR,
    hinstance: ?*anyopaque,
    hwnd: ?*anyopaque,
};

pub extern fn vkCreateWin32SurfaceKHR(
    instance: vk.Instance,
    pCreateInfo: *const Win32SurfaceCreateInfoKHR,
    pAllocator: ?*const vk.AllocationCallbacks,
    pSurface: *vk.Surface,
) callconv(.c) vk.Result;

comptime {
    // x64: sType(4) + pad(4) + pNext(8) + flags(4) + pad(4) + 2 handles(16) = 40.
    if (@sizeOf(usize) == 8) {
        if (@sizeOf(Win32SurfaceCreateInfoKHR) != 40) {
            @compileError("VkWin32SurfaceCreateInfoKHR must be 40 bytes on x64");
        }
    }
}

test "win32 surface create info size matches the SDK layout" {
    if (@sizeOf(usize) == 8) {
        try @import("std").testing.expectEqual(@as(usize, 40), @sizeOf(Win32SurfaceCreateInfoKHR));
    }
}
