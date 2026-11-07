//! Shared with the Linux backend; see `../linux/vk_swapchain.zig`.
//! Thin re-export so relative imports inside the shared files
//! resolve against their own directory rather than this one.
const linux = @import("../linux/vk_swapchain.zig");

pub const FramebufferError = linux.FramebufferError;
pub const MAX_SWAPCHAIN_IMAGES = linux.MAX_SWAPCHAIN_IMAGES;
pub const MSAAError = linux.MSAAError;
pub const MSAAResources = linux.MSAAResources;
pub const RenderPassError = linux.RenderPassError;
pub const SwapchainError = linux.SwapchainError;
pub const SwapchainResult = linux.SwapchainResult;
pub const createFramebuffers = linux.createFramebuffers;
pub const createMSAAResources = linux.createMSAAResources;
pub const createRenderPass = linux.createRenderPass;
pub const createSwapchain = linux.createSwapchain;
pub const destroyFramebuffers = linux.destroyFramebuffers;
pub const destroyImageViews = linux.destroyImageViews;
pub const getMaxUsableSampleCount = linux.getMaxUsableSampleCount;
