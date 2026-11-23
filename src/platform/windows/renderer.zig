const build_options = @import("gooey_build_options");

pub const WindowsRenderer = @TypeOf(build_options.windows_renderer);

pub const selected: WindowsRenderer = build_options.windows_renderer;

pub const Renderer = switch (selected) {
    .vulkan => @import("../linux/vk_renderer.zig").VulkanRenderer,
    .dx11 => @import("dx11_renderer.zig").Dx11Renderer,
};
