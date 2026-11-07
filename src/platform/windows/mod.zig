//! Windows Platform Module
//!
//! Win32 windowing with a Vulkan or DirectX 11 renderer, selected at compile
//! time via `-Dgpu-backend`. `win32/` holds a curated subset of the generated
//! zigwin32 bindings (see `win32/README.md`); the platform files call those
//! declarations directly, with no hand-maintained facade.
//!
//! The Vulkan core, swapchain, pipelines, descriptors, buffers, atlas, and
//! scene renderer are reused from the Linux backend through thin re-export
//! shims. The higher-level `vk_renderer`, `vk_instance`, `window`, `platform`,
//! and `input` files are Windows-side implementations, and the Vulkan shaders
//! are embedded from `../linux/shaders` so there is one GLSL/SPIR-V source.
//! The DX11 renderer is a native D3D11/DXGI twin with its own HLSL shaders.
//!
//! Services (clipboard, file dialogs, IME) are not wired up in this first
//! pass, so `capabilities` does not advertise them.
//!
//! ## Usage
//!
//! ```zig
//! var plat: windows.Platform = undefined;
//! try plat.initInPlace(allocator);
//! defer plat.deinit();
//!
//! const options = gooey.platform.WindowOptions{};
//! var win = try windows.PlatformWindow.init(allocator, &plat, &options);
//! defer win.deinit();
//!
//! plat.run();
//! ```

const interface = @import("../interface.zig");
const contract = @import("../contract.zig");

pub const platform = @import("platform.zig");
pub const window = @import("window.zig");
pub const win32 = @import("win32/mod.zig");
pub const input = @import("input.zig");

// Shared GPU modules (thin re-exports of ../linux/*).
pub const vulkan = @import("vulkan.zig");
pub const vk_swapchain = @import("vk_swapchain.zig");
pub const vk_pipelines = @import("vk_pipelines.zig");
pub const vk_descriptors = @import("vk_descriptors.zig");
pub const vk_buffers = @import("vk_buffers.zig");
pub const vk_atlas = @import("vk_atlas.zig");
pub const vk_types = @import("vk_types.zig");
pub const scene_renderer = @import("scene_renderer.zig");
pub const unified = @import("../unified.zig");

// Windows-specific Vulkan surface + instance.
pub const vk_win32 = @import("vk_win32.zig");
pub const vk_instance = @import("vk_instance.zig");
pub const vk_renderer = @import("vk_renderer.zig");

// Alternative GPU backend: DirectX 11, selected via `-Dgpu-backend=dx11`
// (`window.Renderer` is the compile-time switch). Windows-only — no Linux
// twin: the shared scene layer (`batch_iterator`, `vk_types`, `unified.zig`)
// feeds it, but WSI/swapchain/atlas-upload are native D3D11/DXGI.
pub const dx11_renderer = @import("dx11_renderer.zig");
pub const dx11_atlas = @import("dx11_atlas.zig");
pub const dx11_scene_renderer = @import("dx11_scene_renderer.zig");

/// Canonical backend surface. `platform/mod.zig` derives its public aliases
/// from exactly these names, and `contract.verifyBackend` pins their types.
pub const Platform = platform.WindowsPlatform;
pub const PlatformWindow = window.Window;

/// `Platform.run` blocks inside the Win32 message loop until quit.
pub const drive_model: interface.DriveModel = .blocking_event_loop;

pub const capabilities = Platform.capabilities;

// Convenience aliases.
pub const WindowsPlatform = platform.WindowsPlatform;
pub const Window = window.Window;
pub const VulkanRenderer = vk_renderer.VulkanRenderer;
pub const Renderer = window.Renderer;

// Fail at compile time, in this file, if the backend drifts from the shared
// contract — rather than at some distant shared call site.
comptime {
    contract.verifyBackend(@This());
}
