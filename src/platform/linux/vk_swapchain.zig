//! Swapchain lifecycle, render pass, and framebuffers.
//!
//! Free functions with targeted parameters — each takes only what it needs.
//! The swapchain and its framebuffers are the only objects re-created on
//! resize: the WSI requires a new swapchain per extent, and its images belong
//! to the driver. Gooey bounds them instead: the extent never exceeds
//! `ResourceLimits.window` (the caller fits it) and the image count follows the
//! frames in flight. There is no multisampled target: the renderer draws at one
//! sample per pixel and every pipeline anti-aliases analytically, so nothing
//! Gooey allocates depends on the window size.

const std = @import("std");
const limits_mod = @import("../../core/limits.zig");
const vk = @import("vulkan.zig");
const vk_types = @import("vk_types.zig");

// =============================================================================
// Limits (CLAUDE.md Rule #4 — put a limit on everything)
// =============================================================================

pub const MAX_SWAPCHAIN_IMAGES: u32 = 8;
const MAX_SURFACE_FORMATS: u32 = vk_types.MAX_SURFACE_FORMATS;
const MAX_PRESENT_MODES: u32 = vk_types.MAX_PRESENT_MODES;

// =============================================================================
// Result Types
// =============================================================================

pub const SwapchainResult = struct {
    swapchain: vk.Swapchain,
    format: vk.Format,
    extent: vk.Extent2D,
    images: [MAX_SWAPCHAIN_IMAGES]vk.Image,
    image_views: [MAX_SWAPCHAIN_IMAGES]vk.ImageView,
    image_count: u32,
};

// =============================================================================
// Error Types
// =============================================================================

pub const SwapchainError = error{
    SwapchainCreationFailed,
    ImageViewCreationFailed,
};

pub const RenderPassError = error{
    RenderPassCreationFailed,
};

pub const FramebufferError = error{
    FramebufferCreationFailed,
};

// =============================================================================
// Public API
// =============================================================================

/// Create a swapchain, retrieve its images, and create image views.
///
/// `width` and `height` are physical pixels already fitted to the window budget.
/// `image_count_min` is the frames-in-flight count; the driver's own minimum
/// wins when it is higher. On initial creation, pass `null` for
/// `old_swapchain`. On resize, pass the previous swapchain handle — Vulkan can
/// recycle internal resources.
pub fn createSwapchain(
    device: vk.Device,
    physical_device: vk.PhysicalDevice,
    surface: vk.Surface,
    extent: vk.Extent2D,
    /// The window budget's `ResourceLimits.frame.in_flight_count`.
    frame_count: u32,
    old_swapchain: vk.Swapchain,
) SwapchainError!SwapchainResult {
    std.debug.assert(device != null);
    std.debug.assert(physical_device != null);
    std.debug.assert(surface != null);
    std.debug.assert(frame_count >= limits_mod.MIN_FRAMES_IN_FLIGHT);
    std.debug.assert(frame_count <= limits_mod.MAX_FRAMES_IN_FLIGHT);

    const config = querySwapchainConfig(physical_device, surface, extent, frame_count);
    const swapchain = try createSwapchainHandle(device, surface, config, old_swapchain);
    errdefer vk.vkDestroySwapchainKHR(device, swapchain, null);

    const images = try getSwapchainImages(device, swapchain);
    const views = try createImageViews(device, images.items, images.count, config.format);

    return .{
        .swapchain = swapchain,
        .format = config.format,
        .extent = config.extent,
        .images = images.items,
        .image_views = views,
        .image_count = images.count,
    };
}

/// Create the single-subpass render pass: one single-sample swapchain image,
/// cleared on load, stored, and handed to presentation.
///
/// Two external dependencies make every hazard on the attachment explicit:
///
/// - Incoming: the previous use of the image was a colour write (an earlier
///   frame's store) followed by presentation. The acquire semaphore waits at
///   `COLOR_ATTACHMENT_OUTPUT`, so this dependency chains from that stage and
///   orders the load-op clear and the layout transition after the earlier
///   write (`srcAccessMask = COLOR_ATTACHMENT_WRITE`). The old dependency had
///   `srcAccessMask = 0`, which is the WRITE_AFTER_WRITE hazard
///   synchronization validation reported at `vkCmdBeginRenderPass` on the
///   shared MSAA image.
/// - Outgoing: the store and the transition to `PRESENT_SRC_KHR` complete
///   before anything after the pass; presentation waits on a semaphore that
///   is signalled after `BOTTOM_OF_PIPE`.
pub fn createRenderPass(device: vk.Device, format: vk.Format) RenderPassError!vk.RenderPass {
    std.debug.assert(device != null);
    std.debug.assert(format != vk.VK_FORMAT_UNDEFINED);

    const attachment = vk.AttachmentDescription{
        .flags = 0,
        .format = @intCast(format),
        .samples = vk.VK_SAMPLE_COUNT_1_BIT,
        .loadOp = vk.VK_ATTACHMENT_LOAD_OP_CLEAR,
        .storeOp = vk.VK_ATTACHMENT_STORE_OP_STORE,
        .stencilLoadOp = vk.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
        .stencilStoreOp = vk.VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
        .finalLayout = vk.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
    };
    const color_ref = vk.AttachmentReference{
        .attachment = 0,
        .layout = vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
    };
    const subpass = vk.SubpassDescription{
        .flags = 0,
        .pipelineBindPoint = vk.VK_PIPELINE_BIND_POINT_GRAPHICS,
        .inputAttachmentCount = 0,
        .pInputAttachments = null,
        .colorAttachmentCount = 1,
        .pColorAttachments = (&color_ref)[0..1],
        .pResolveAttachments = null,
        .pDepthStencilAttachment = null,
        .preserveAttachmentCount = 0,
        .pPreserveAttachments = null,
    };
    const dependencies = renderPassDependencies();
    const render_pass_info = vk.RenderPassCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .attachmentCount = 1,
        .pAttachments = (&attachment)[0..1],
        .subpassCount = 1,
        .pSubpasses = (&subpass)[0..1],
        .dependencyCount = dependencies.len,
        .pDependencies = &dependencies,
    };

    var render_pass: vk.RenderPass = null;
    const result = vk.vkCreateRenderPass(device, &render_pass_info, null, &render_pass);
    if (!vk.succeeded(result)) return RenderPassError.RenderPassCreationFailed;

    std.debug.assert(render_pass != null);
    return render_pass;
}

/// Create one single-attachment framebuffer per swapchain image.
pub fn createFramebuffers(
    device: vk.Device,
    render_pass: vk.RenderPass,
    image_views: []const vk.ImageView,
    image_count: u32,
    extent: vk.Extent2D,
    out_framebuffers: *[MAX_SWAPCHAIN_IMAGES]vk.Framebuffer,
) FramebufferError!void {
    std.debug.assert(device != null);
    std.debug.assert(render_pass != null);
    std.debug.assert(image_count <= MAX_SWAPCHAIN_IMAGES);
    std.debug.assert(image_count <= image_views.len);

    for (0..image_count) |i| {
        out_framebuffers[i] = try createSingleFramebuffer(
            device,
            render_pass,
            image_views[i],
            extent,
        );
    }
}

/// Destroy swapchain image views. Safe to call with null entries.
pub fn destroyImageViews(
    device: vk.Device,
    views: *[MAX_SWAPCHAIN_IMAGES]vk.ImageView,
) void {
    std.debug.assert(device != null);
    for (views) |*v| {
        if (v.*) |view| vk.vkDestroyImageView(device, view, null);
        v.* = null;
    }
}

/// Destroy framebuffers. Safe to call with null entries.
pub fn destroyFramebuffers(
    device: vk.Device,
    framebuffers: *[MAX_SWAPCHAIN_IMAGES]vk.Framebuffer,
) void {
    std.debug.assert(device != null);
    for (framebuffers) |*fb| {
        if (fb.*) |framebuffer| vk.vkDestroyFramebuffer(device, framebuffer, null);
        fb.* = null;
    }
}

// =============================================================================
// Internal — Swapchain Configuration
// =============================================================================

const SwapchainConfig = struct {
    format: vk.Format,
    color_space: vk.ColorSpaceKHR,
    extent: vk.Extent2D,
    min_image_count: u32,
    present_mode: vk.PresentModeKHR,
    composite_alpha: vk.CompositeAlphaFlagBitsKHR,
    pre_transform: vk.SurfaceTransformFlagBitsKHR,
};

fn querySwapchainConfig(
    physical_device: vk.PhysicalDevice,
    surface: vk.Surface,
    extent_requested: vk.Extent2D,
    frame_count: u32,
) SwapchainConfig {
    var capabilities: vk.SurfaceCapabilitiesKHR = undefined;
    _ = vk.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(physical_device, surface, &capabilities);

    const format_result = chooseFormat(physical_device, surface);
    const present_mode = choosePresentMode(physical_device, surface);
    const composite_alpha = chooseCompositeAlpha(capabilities);
    const extent = chooseExtent(capabilities, extent_requested);
    const image_count = chooseImageCount(capabilities, frame_count);

    return .{
        .format = format_result.format,
        .color_space = format_result.color_space,
        .extent = extent,
        .min_image_count = image_count,
        .present_mode = present_mode,
        .composite_alpha = composite_alpha,
        .pre_transform = capabilities.currentTransform,
    };
}

const FormatChoice = struct { format: vk.Format, color_space: vk.ColorSpaceKHR };

fn chooseFormat(physical_device: vk.PhysicalDevice, surface: vk.Surface) FormatChoice {
    var format_count: u32 = 0;
    _ = vk.vkGetPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, &format_count, null);

    var formats: [MAX_SURFACE_FORMATS]vk.SurfaceFormatKHR = undefined;
    var fmt_count: u32 = @min(format_count, MAX_SURFACE_FORMATS);
    _ = vk.vkGetPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, &fmt_count, &formats);

    std.debug.assert(fmt_count > 0);

    // Prefer UNORM — we write sRGB values directly, no hardware conversion needed
    for (formats[0..fmt_count]) |f| {
        if (f.format == vk.VK_FORMAT_B8G8R8A8_UNORM and
            f.colorSpace == vk.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR)
        {
            return .{ .format = f.format, .color_space = f.colorSpace };
        }
    }
    // Fallback: accept any UNORM or SRGB variant
    for (formats[0..fmt_count]) |f| {
        if (f.format == vk.VK_FORMAT_B8G8R8A8_UNORM or
            f.format == vk.VK_FORMAT_B8G8R8A8_SRGB)
        {
            return .{ .format = f.format, .color_space = f.colorSpace };
        }
    }
    // Last resort: whatever the driver offers first
    return .{ .format = formats[0].format, .color_space = formats[0].colorSpace };
}

fn choosePresentMode(physical_device: vk.PhysicalDevice, surface: vk.Surface) vk.PresentModeKHR {
    var present_mode_count: u32 = 0;
    _ = vk.vkGetPhysicalDeviceSurfacePresentModesKHR(physical_device, surface, &present_mode_count, null);

    var present_modes: [MAX_PRESENT_MODES]vk.PresentModeKHR = undefined;
    var pm_count: u32 = @min(present_mode_count, MAX_PRESENT_MODES);
    _ = vk.vkGetPhysicalDeviceSurfacePresentModesKHR(physical_device, surface, &pm_count, @ptrCast(&present_modes));

    std.debug.assert(pm_count > 0);

    // Prefer MAILBOX (triple-buffer vsync), fall back to FIFO (always available per spec)
    for (present_modes[0..pm_count]) |mode| {
        if (mode == vk.VK_PRESENT_MODE_MAILBOX_KHR) return mode;
    }
    return @intCast(vk.VK_PRESENT_MODE_FIFO_KHR);
}

fn chooseCompositeAlpha(capabilities: vk.SurfaceCapabilitiesKHR) vk.CompositeAlphaFlagBitsKHR {
    const preferred = [_]vk.CompositeAlphaFlagBitsKHR{
        vk.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
        vk.VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR,
        vk.VK_COMPOSITE_ALPHA_POST_MULTIPLIED_BIT_KHR,
        vk.VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR,
    };
    std.debug.assert(capabilities.supportedCompositeAlpha != 0);

    for (preferred) |alpha_mode| {
        if ((capabilities.supportedCompositeAlpha & alpha_mode) != 0) return alpha_mode;
    }
    // Per Vulkan spec, at least one mode must be supported — assert covers this
    unreachable;
}

/// The requested extent, already fitted to the window budget by the caller,
/// clamped to what the surface accepts. A surface that dictates its extent
/// (`currentExtent` defined) can only be smaller than the budget-fitted
/// request when it is also smaller than the window, so it is honoured only
/// when it fits inside the request.
fn chooseExtent(capabilities: vk.SurfaceCapabilitiesKHR, requested: vk.Extent2D) vk.Extent2D {
    std.debug.assert(requested.width > 0);
    std.debug.assert(requested.height > 0);
    var extent = requested;
    if (capabilities.currentExtent.width != 0xFFFFFFFF) {
        extent.width = @min(capabilities.currentExtent.width, requested.width);
        extent.height = @min(capabilities.currentExtent.height, requested.height);
    }
    const width_min = capabilities.minImageExtent.width;
    const height_min = capabilities.minImageExtent.height;
    extent.width = std.math.clamp(extent.width, width_min, capabilities.maxImageExtent.width);
    extent.height = std.math.clamp(extent.height, height_min, capabilities.maxImageExtent.height);
    return extent;
}

/// The driver's minimum image count plus one spare image per frame in flight
/// above `MIN_FRAMES_IN_FLIGHT`: the minimum at two frames (`nano`, `small`),
/// and the minimum plus one at three, the count every budget used before
/// frames in flight became a budget field.
fn chooseImageCount(capabilities: vk.SurfaceCapabilitiesKHR, frame_count: u32) u32 {
    std.debug.assert(frame_count >= limits_mod.MIN_FRAMES_IN_FLIGHT);
    var count = capabilities.minImageCount + (frame_count - limits_mod.MIN_FRAMES_IN_FLIGHT);
    if (capabilities.maxImageCount > 0 and count > capabilities.maxImageCount) {
        count = capabilities.maxImageCount;
    }
    std.debug.assert(count >= capabilities.minImageCount);
    std.debug.assert(count <= MAX_SWAPCHAIN_IMAGES);
    return count;
}

// =============================================================================
// Internal — Object Creation
// =============================================================================

fn createSwapchainHandle(
    device: vk.Device,
    surface: vk.Surface,
    config: SwapchainConfig,
    old_swapchain: vk.Swapchain,
) SwapchainError!vk.Swapchain {
    const create_info = vk.SwapchainCreateInfoKHR{
        .sType = vk.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
        .pNext = null,
        .flags = 0,
        .surface = surface,
        .minImageCount = config.min_image_count,
        .imageFormat = config.format,
        .imageColorSpace = config.color_space,
        .imageExtent = config.extent,
        .imageArrayLayers = 1,
        .imageUsage = vk.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
        .imageSharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
        .queueFamilyIndexCount = 0,
        .pQueueFamilyIndices = null,
        .preTransform = config.pre_transform,
        .compositeAlpha = config.composite_alpha,
        .presentMode = config.present_mode,
        .clipped = vk.TRUE,
        .oldSwapchain = old_swapchain,
    };

    var swapchain: vk.Swapchain = null;
    const result = vk.vkCreateSwapchainKHR(device, &create_info, null, &swapchain);
    if (!vk.succeeded(result)) return SwapchainError.SwapchainCreationFailed;

    std.debug.assert(swapchain != null);
    return swapchain;
}

const ImageArray = struct {
    items: [MAX_SWAPCHAIN_IMAGES]vk.Image,
    count: u32,
};

fn getSwapchainImages(device: vk.Device, swapchain: vk.Swapchain) SwapchainError!ImageArray {
    var result: ImageArray = .{
        .items = @as([MAX_SWAPCHAIN_IMAGES]vk.Image, @splat(null)),
        .count = 0,
    };

    _ = vk.vkGetSwapchainImagesKHR(device, swapchain, &result.count, null);
    std.debug.assert(result.count <= MAX_SWAPCHAIN_IMAGES);

    var img_count: u32 = @min(result.count, MAX_SWAPCHAIN_IMAGES);
    _ = vk.vkGetSwapchainImagesKHR(device, swapchain, &img_count, &result.items);
    result.count = img_count;

    std.debug.assert(result.count > 0);
    return result;
}

fn createImageViews(
    device: vk.Device,
    images: [MAX_SWAPCHAIN_IMAGES]vk.Image,
    count: u32,
    format: vk.Format,
) SwapchainError![MAX_SWAPCHAIN_IMAGES]vk.ImageView {
    std.debug.assert(count <= MAX_SWAPCHAIN_IMAGES);

    var views: [MAX_SWAPCHAIN_IMAGES]vk.ImageView = @splat(null);

    for (0..count) |i| {
        std.debug.assert(images[i] != null);

        const view_info = vk.ImageViewCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .image = images[i],
            .viewType = vk.VK_IMAGE_VIEW_TYPE_2D,
            .format = format,
            .components = .{
                .r = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
                .g = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
                .b = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
                .a = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
            },
            .subresourceRange = .{
                .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };

        const res = vk.vkCreateImageView(device, &view_info, null, &views[i]);
        if (!vk.succeeded(res)) return SwapchainError.ImageViewCreationFailed;
    }

    return views;
}

// =============================================================================
// Internal — Render Pass Helper
// =============================================================================

/// The incoming and outgoing external dependencies documented on
/// `createRenderPass`.
fn renderPassDependencies() [2]vk.SubpassDependency {
    const color_output = vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    const color_write = vk.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
    const dependencies = [2]vk.SubpassDependency{
        .{
            .srcSubpass = vk.SUBPASS_EXTERNAL,
            .dstSubpass = 0,
            .srcStageMask = color_output,
            .dstStageMask = color_output,
            .srcAccessMask = color_write,
            .dstAccessMask = vk.VK_ACCESS_COLOR_ATTACHMENT_READ_BIT | color_write,
            .dependencyFlags = 0,
        },
        .{
            .srcSubpass = 0,
            .dstSubpass = vk.SUBPASS_EXTERNAL,
            .srcStageMask = color_output,
            .dstStageMask = vk.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
            .srcAccessMask = color_write,
            .dstAccessMask = 0,
            .dependencyFlags = 0,
        },
    };
    std.debug.assert(dependencies[0].srcSubpass == vk.SUBPASS_EXTERNAL);
    std.debug.assert(dependencies[1].dstSubpass == vk.SUBPASS_EXTERNAL);
    return dependencies;
}

// =============================================================================
// Internal — Framebuffer Helper
// =============================================================================

fn createSingleFramebuffer(
    device: vk.Device,
    render_pass: vk.RenderPass,
    image_view: vk.ImageView,
    extent: vk.Extent2D,
) FramebufferError!vk.Framebuffer {
    std.debug.assert(image_view != null);
    std.debug.assert(extent.width > 0 and extent.height > 0);

    const framebuffer_info = vk.FramebufferCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .renderPass = render_pass,
        .attachmentCount = 1,
        .pAttachments = (&image_view)[0..1],
        .width = extent.width,
        .height = extent.height,
        .layers = 1,
    };

    var framebuffer: vk.Framebuffer = null;
    const result = vk.vkCreateFramebuffer(device, &framebuffer_info, null, &framebuffer);
    if (!vk.succeeded(result)) return FramebufferError.FramebufferCreationFailed;

    std.debug.assert(framebuffer != null);
    return framebuffer;
}
