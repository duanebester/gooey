const builtin = @import("builtin");
const vk = @import("vulkan.zig");
const contract = @import("../contract.zig");

pub const NativeSurface = switch (builtin.os.tag) {
    .linux => @import("vk_surface_wayland.zig").WaylandSurface,
    .windows => @import("../windows/vk_surface_win32.zig").Win32Surface,
    else => @compileError("No Vulkan presentation surface for " ++ @tagName(builtin.os.tag)),
};

comptime {
    verify(NativeSurface);
}

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
