//! The window-system half of Vulkan presentation (WSI).
//!
//! `VulkanRenderer` is window-system neutral except at three points: the
//! instance extension it enables, the `VkSurfaceKHR` it creates, and what the
//! window system needs around swapchain destruction. `NativeSurface` owns all
//! three, so a new window system adds one implementation and one arm below
//! instead of editing the renderer.
//!
//! Destroying the `VkSurfaceKHR` stays in the renderer: `vkDestroySurfaceKHR`
//! is the same call for every window system.

const builtin = @import("builtin");
const vk = @import("vulkan.zig");
const contract = @import("../contract.zig");

/// The presentation surface for the target OS, selected like `platform.backend`.
pub const NativeSurface = switch (builtin.os.tag) {
    .linux => @import("vk_surface_wayland.zig").WaylandSurface,
    else => @compileError("No Vulkan presentation surface for " ++ @tagName(builtin.os.tag)),
};

comptime {
    verify(NativeSurface);
}

/// Pin the surface interface on an implementation, so drift fails to compile
/// with a message naming the declaration.
///
/// Required declarations:
///   - `instance_extension_name: [*:0]const u8`, the `VK_KHR_*_surface`
///     extension enabled beside `VK_KHR_surface` at instance creation.
///   - `create(*const Self, vk.Instance) !vk.Surface`, which returns a
///     non-null surface the renderer owns from then on.
///   - `swapchainDestroyBegin(*const Self) void` and
///     `swapchainDestroyEnd(*const Self) void`, which bracket destroying the
///     swapchain once the device is idle. Window systems with nothing to
///     synchronize implement them as no-ops.
pub fn verify(comptime Surface: type) void {
    comptime {
        contract.verifyConst(Surface, "instance_extension_name", [*:0]const u8);
        contract.verifyFn(Surface, "create", .{
            .params = &.{ *const Surface, vk.Instance },
            .returns = vk.Surface,
            .errors = .required,
        });
        contract.verifyFn(Surface, "swapchainDestroyBegin", .{
            .params = &.{*const Surface},
            .returns = void,
            .errors = .forbidden,
        });
        contract.verifyFn(Surface, "swapchainDestroyEnd", .{
            .params = &.{*const Surface},
            .returns = void,
            .errors = .forbidden,
        });
    }
}
