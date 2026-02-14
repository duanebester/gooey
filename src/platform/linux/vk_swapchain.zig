//! Swapchain lifecycle, MSAA resources, render pass, and framebuffers.
//!
//! Free functions with targeted parameters — each takes only what it needs.
//! All functions in this module are coupled to swapchain extent/format and
//! are re-invoked together on resize. Extracting them groups the resize-path
//! code into a single module.

const std = @import("std");
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
    format: c_uint,
    extent: vk.Extent2D,
    images: [MAX_SWAPCHAIN_IMAGES]vk.Image,
    image_views: [MAX_SWAPCHAIN_IMAGES]vk.ImageView,
    image_count: u32,
};

pub const MSAAResources = struct {
    image: vk.Image = null,
    memory: vk.DeviceMemory = null,
    view: vk.ImageView = null,

    pub fn destroy(self: *MSAAResources, device: vk.Device) void {
        std.debug.assert(device != null);
        if (self.view) |v| vk.vkDestroyImageView(device, v, null);
        self.view = null;
        if (self.image) |img| vk.vkDestroyImage(device, img, null);
        self.image = null;
        if (self.memory) |mem| vk.vkFreeMemory(device, mem, null);
        self.memory = null;
    }
};

// =============================================================================
// Error Types
// =============================================================================

pub const SwapchainError = error{
    SwapchainCreationFailed,
    ImageViewCreationFailed,
};

pub const MSAAError = error{
    MSAAImageCreationFailed,
    NoSuitableMemoryType,
    MSAAMemoryAllocationFailed,
    MSAAMemoryBindFailed,
    MSAAImageViewCreationFailed,
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

/// Query the maximum usable MSAA sample count for the physical device.
/// Prefers 4x MSAA for a good quality/performance balance.
pub fn getMaxUsableSampleCount(physical_device: vk.PhysicalDevice) c_uint {
    std.debug.assert(physical_device != null);

    var props: vk.PhysicalDeviceProperties = undefined;
    vk.vkGetPhysicalDeviceProperties(physical_device, &props);

    const counts = props.limits.framebufferColorSampleCounts &
        props.limits.framebufferDepthSampleCounts;

    // Prefer 4x MSAA — best quality/performance tradeoff for UI rendering
    if ((counts & vk.VK_SAMPLE_COUNT_4_BIT) != 0) return vk.VK_SAMPLE_COUNT_4_BIT;
    if ((counts & vk.VK_SAMPLE_COUNT_2_BIT) != 0) return vk.VK_SAMPLE_COUNT_2_BIT;
    return vk.VK_SAMPLE_COUNT_1_BIT;
}

/// Create a swapchain, retrieve its images, and create image views.
///
/// On initial creation, pass `null` for `old_swapchain`. On resize, pass the
/// previous swapchain handle — Vulkan can recycle internal resources.
pub fn createSwapchain(
    device: vk.Device,
    physical_device: vk.PhysicalDevice,
    surface: vk.Surface,
    width: u32,
    height: u32,
    old_swapchain: vk.Swapchain,
) SwapchainError!SwapchainResult {
    std.debug.assert(device != null);
    std.debug.assert(physical_device != null);
    std.debug.assert(surface != null);

    const config = querySwapchainConfig(physical_device, surface, width, height);
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

/// Create MSAA color buffer resources. Returns empty resources if sample_count is 1.
pub fn createMSAAResources(
    device: vk.Device,
    format: c_uint,
    extent: vk.Extent2D,
    sample_count: c_uint,
    mem_properties: *const vk.PhysicalDeviceMemoryProperties,
) MSAAError!MSAAResources {
    std.debug.assert(device != null);
    std.debug.assert(extent.width > 0 and extent.height > 0);

    if (sample_count == vk.VK_SAMPLE_COUNT_1_BIT) return .{};

    var result: MSAAResources = .{};

    result.image = try createMSAAImage(device, format, extent, sample_count);
    errdefer {
        vk.vkDestroyImage(device, result.image, null);
        result.image = null;
    }

    result.memory = try allocateMSAAMemory(device, result.image, mem_properties);
    errdefer {
        vk.vkFreeMemory(device, result.memory, null);
        result.memory = null;
    }

    const bind_res = vk.vkBindImageMemory(device, result.image, result.memory, 0);
    if (!vk.succeeded(bind_res)) return MSAAError.MSAAMemoryBindFailed;

    result.view = try createMSAAView(device, result.image, format);

    return result;
}

/// Create a render pass. Uses MSAA resolve if sample_count > 1.
pub fn createRenderPass(
    device: vk.Device,
    format: c_uint,
    sample_count: c_uint,
) RenderPassError!vk.RenderPass {
    std.debug.assert(device != null);
    std.debug.assert(format != vk.VK_FORMAT_UNDEFINED);

    if (sample_count != vk.VK_SAMPLE_COUNT_1_BIT) {
        return createMSAARenderPass(device, format, sample_count);
    } else {
        return createSimpleRenderPass(device, format);
    }
}

/// Create framebuffers for each swapchain image.
///
/// When MSAA is active (sample_count > 1), each framebuffer has two attachments:
///   0 = shared MSAA color buffer, 1 = per-image resolve target.
/// Without MSAA, each framebuffer has a single swapchain image attachment.
pub fn createFramebuffers(
    device: vk.Device,
    render_pass: vk.RenderPass,
    image_views: []const vk.ImageView,
    image_count: u32,
    msaa_view: vk.ImageView,
    extent: vk.Extent2D,
    sample_count: c_uint,
    out_framebuffers: *[MAX_SWAPCHAIN_IMAGES]vk.Framebuffer,
) FramebufferError!void {
    std.debug.assert(device != null);
    std.debug.assert(render_pass != null);
    std.debug.assert(image_count <= MAX_SWAPCHAIN_IMAGES);

    const use_msaa = sample_count != vk.VK_SAMPLE_COUNT_1_BIT;

    for (0..image_count) |i| {
        out_framebuffers[i] = try createSingleFramebuffer(
            device,
            render_pass,
            image_views[i],
            if (use_msaa) msaa_view else null,
            extent,
            use_msaa,
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
    format: c_uint,
    color_space: c_uint,
    extent: vk.Extent2D,
    min_image_count: u32,
    present_mode: c_uint,
    composite_alpha: c_uint,
    pre_transform: c_uint,
};

fn querySwapchainConfig(
    physical_device: vk.PhysicalDevice,
    surface: vk.Surface,
    width: u32,
    height: u32,
) SwapchainConfig {
    var capabilities: vk.SurfaceCapabilitiesKHR = undefined;
    _ = vk.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(physical_device, surface, &capabilities);

    const format_result = chooseFormat(physical_device, surface);
    const present_mode = choosePresentMode(physical_device, surface);
    const composite_alpha = chooseCompositeAlpha(capabilities);
    const extent = chooseExtent(capabilities, width, height);
    const image_count = chooseImageCount(capabilities);

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

const FormatChoice = struct { format: c_uint, color_space: c_uint };

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

fn choosePresentMode(physical_device: vk.PhysicalDevice, surface: vk.Surface) c_uint {
    var present_mode_count: u32 = 0;
    _ = vk.vkGetPhysicalDeviceSurfacePresentModesKHR(physical_device, surface, &present_mode_count, null);

    var present_modes: [MAX_PRESENT_MODES]c_uint = undefined;
    var pm_count: u32 = @min(present_mode_count, MAX_PRESENT_MODES);
    _ = vk.vkGetPhysicalDeviceSurfacePresentModesKHR(physical_device, surface, &pm_count, @ptrCast(&present_modes));

    std.debug.assert(pm_count > 0);

    // Prefer MAILBOX (triple-buffer vsync), fall back to FIFO (always available per spec)
    for (present_modes[0..pm_count]) |mode| {
        if (mode == vk.VK_PRESENT_MODE_MAILBOX_KHR) return mode;
    }
    return @intCast(vk.VK_PRESENT_MODE_FIFO_KHR);
}

fn chooseCompositeAlpha(capabilities: vk.SurfaceCapabilitiesKHR) c_uint {
    const preferred = [_]c_uint{
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

fn chooseExtent(
    capabilities: vk.SurfaceCapabilitiesKHR,
    width: u32,
    height: u32,
) vk.Extent2D {
    if (capabilities.currentExtent.width != 0xFFFFFFFF) {
        return capabilities.currentExtent;
    }
    return .{
        .width = std.math.clamp(width, capabilities.minImageExtent.width, capabilities.maxImageExtent.width),
        .height = std.math.clamp(height, capabilities.minImageExtent.height, capabilities.maxImageExtent.height),
    };
}

fn chooseImageCount(capabilities: vk.SurfaceCapabilitiesKHR) u32 {
    var count = capabilities.minImageCount + 1;
    if (capabilities.maxImageCount > 0 and count > capabilities.maxImageCount) {
        count = capabilities.maxImageCount;
    }
    std.debug.assert(count >= capabilities.minImageCount);
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
        .items = [_]vk.Image{null} ** MAX_SWAPCHAIN_IMAGES,
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
    format: c_uint,
) SwapchainError![MAX_SWAPCHAIN_IMAGES]vk.ImageView {
    std.debug.assert(count <= MAX_SWAPCHAIN_IMAGES);

    var views: [MAX_SWAPCHAIN_IMAGES]vk.ImageView = [_]vk.ImageView{null} ** MAX_SWAPCHAIN_IMAGES;

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
// Internal — MSAA Helpers
// =============================================================================

fn createMSAAImage(
    device: vk.Device,
    format: c_uint,
    extent: vk.Extent2D,
    sample_count: c_uint,
) MSAAError!vk.Image {
    const image_info = vk.ImageCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .imageType = vk.VK_IMAGE_TYPE_2D,
        .format = format,
        .extent = .{
            .width = extent.width,
            .height = extent.height,
            .depth = 1,
        },
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = sample_count,
        .tiling = vk.VK_IMAGE_TILING_OPTIMAL,
        .usage = vk.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | vk.VK_IMAGE_USAGE_TRANSIENT_ATTACHMENT_BIT,
        .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
        .queueFamilyIndexCount = 0,
        .pQueueFamilyIndices = null,
        .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
    };

    var image: vk.Image = null;
    const result = vk.vkCreateImage(device, &image_info, null, &image);
    if (!vk.succeeded(result)) return MSAAError.MSAAImageCreationFailed;

    std.debug.assert(image != null);
    return image;
}

fn allocateMSAAMemory(
    device: vk.Device,
    image: vk.Image,
    mem_properties: *const vk.PhysicalDeviceMemoryProperties,
) MSAAError!vk.DeviceMemory {
    std.debug.assert(image != null);

    var mem_reqs: vk.MemoryRequirements = undefined;
    vk.vkGetImageMemoryRequirements(device, image, &mem_reqs);

    const mem_type = vk.findMemoryType(
        mem_properties,
        mem_reqs.memoryTypeBits,
        vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
    ) orelse return MSAAError.NoSuitableMemoryType;

    const alloc_info = vk.MemoryAllocateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .pNext = null,
        .allocationSize = mem_reqs.size,
        .memoryTypeIndex = mem_type,
    };

    var memory: vk.DeviceMemory = null;
    const result = vk.vkAllocateMemory(device, &alloc_info, null, &memory);
    if (!vk.succeeded(result)) return MSAAError.MSAAMemoryAllocationFailed;

    std.debug.assert(memory != null);
    return memory;
}

fn createMSAAView(
    device: vk.Device,
    image: vk.Image,
    format: c_uint,
) MSAAError!vk.ImageView {
    std.debug.assert(image != null);

    const view_info = vk.ImageViewCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .image = image,
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

    var view: vk.ImageView = null;
    const result = vk.vkCreateImageView(device, &view_info, null, &view);
    if (!vk.succeeded(result)) return MSAAError.MSAAImageViewCreationFailed;

    std.debug.assert(view != null);
    return view;
}

// =============================================================================
// Internal — Render Pass Helpers
// =============================================================================

/// MSAA render pass: attachment 0 = multisampled color, attachment 1 = resolve target.
fn createMSAARenderPass(
    device: vk.Device,
    format: c_uint,
    sample_count: c_uint,
) RenderPassError!vk.RenderPass {
    const attachments = [_]vk.AttachmentDescription{
        // MSAA color attachment
        .{
            .flags = 0,
            .format = @intCast(format),
            .samples = sample_count,
            .loadOp = vk.VK_ATTACHMENT_LOAD_OP_CLEAR,
            .storeOp = vk.VK_ATTACHMENT_STORE_OP_DONT_CARE,
            .stencilLoadOp = vk.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
            .stencilStoreOp = vk.VK_ATTACHMENT_STORE_OP_DONT_CARE,
            .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
            .finalLayout = vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        },
        // Resolve attachment (swapchain image)
        .{
            .flags = 0,
            .format = @intCast(format),
            .samples = vk.VK_SAMPLE_COUNT_1_BIT,
            .loadOp = vk.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
            .storeOp = vk.VK_ATTACHMENT_STORE_OP_STORE,
            .stencilLoadOp = vk.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
            .stencilStoreOp = vk.VK_ATTACHMENT_STORE_OP_DONT_CARE,
            .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
            .finalLayout = vk.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
        },
    };

    const color_ref = vk.AttachmentReference{
        .attachment = 0,
        .layout = vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
    };
    const resolve_ref = vk.AttachmentReference{
        .attachment = 1,
        .layout = vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
    };

    return buildRenderPass(device, &attachments, 2, &color_ref, &resolve_ref);
}

/// Simple render pass: single swapchain image attachment, no MSAA.
fn createSimpleRenderPass(
    device: vk.Device,
    format: c_uint,
) RenderPassError!vk.RenderPass {
    const attachment = [_]vk.AttachmentDescription{.{
        .flags = 0,
        .format = @intCast(format),
        .samples = vk.VK_SAMPLE_COUNT_1_BIT,
        .loadOp = vk.VK_ATTACHMENT_LOAD_OP_CLEAR,
        .storeOp = vk.VK_ATTACHMENT_STORE_OP_STORE,
        .stencilLoadOp = vk.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
        .stencilStoreOp = vk.VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
        .finalLayout = vk.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
    }};

    const color_ref = vk.AttachmentReference{
        .attachment = 0,
        .layout = vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
    };

    return buildRenderPass(device, &attachment, 1, &color_ref, null);
}

/// Shared render pass construction — subpass + dependency are identical for both paths.
fn buildRenderPass(
    device: vk.Device,
    attachments: [*]const vk.AttachmentDescription,
    attachment_count: u32,
    color_ref: *const vk.AttachmentReference,
    resolve_ref: ?*const vk.AttachmentReference,
) RenderPassError!vk.RenderPass {
    std.debug.assert(attachment_count >= 1 and attachment_count <= 2);

    const subpass = vk.SubpassDescription{
        .flags = 0,
        .pipelineBindPoint = vk.VK_PIPELINE_BIND_POINT_GRAPHICS,
        .inputAttachmentCount = 0,
        .pInputAttachments = null,
        .colorAttachmentCount = 1,
        .pColorAttachments = color_ref,
        .pResolveAttachments = resolve_ref,
        .pDepthStencilAttachment = null,
        .preserveAttachmentCount = 0,
        .pPreserveAttachments = null,
    };

    const dependency = vk.SubpassDependency{
        .srcSubpass = vk.SUBPASS_EXTERNAL,
        .dstSubpass = 0,
        .srcStageMask = vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        .dstStageMask = vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        .srcAccessMask = 0,
        .dstAccessMask = vk.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
        .dependencyFlags = 0,
    };

    const render_pass_info = vk.RenderPassCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .attachmentCount = attachment_count,
        .pAttachments = attachments,
        .subpassCount = 1,
        .pSubpasses = &subpass,
        .dependencyCount = 1,
        .pDependencies = &dependency,
    };

    var render_pass: vk.RenderPass = null;
    const result = vk.vkCreateRenderPass(device, &render_pass_info, null, &render_pass);
    if (!vk.succeeded(result)) return RenderPassError.RenderPassCreationFailed;

    std.debug.assert(render_pass != null);
    return render_pass;
}

// =============================================================================
// Internal — Framebuffer Helper
// =============================================================================

fn createSingleFramebuffer(
    device: vk.Device,
    render_pass: vk.RenderPass,
    image_view: vk.ImageView,
    msaa_view: ?vk.ImageView,
    extent: vk.Extent2D,
    use_msaa: bool,
) FramebufferError!vk.Framebuffer {
    std.debug.assert(image_view != null);
    if (use_msaa) std.debug.assert(msaa_view != null);

    // MSAA: [0]=MSAA color, [1]=resolve. Non-MSAA: [0]=swapchain image.
    var attachment_buf: [2]vk.ImageView = undefined;
    var attachment_count: u32 = undefined;

    if (use_msaa) {
        attachment_buf[0] = msaa_view.?;
        attachment_buf[1] = image_view;
        attachment_count = 2;
    } else {
        attachment_buf[0] = image_view;
        attachment_count = 1;
    }

    const framebuffer_info = vk.FramebufferCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .renderPass = render_pass,
        .attachmentCount = attachment_count,
        .pAttachments = &attachment_buf,
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
