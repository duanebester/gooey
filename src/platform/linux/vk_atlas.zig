const std = @import("std");
const vk = @import("vulkan.zig");

pub const copy_region_count_max: u32 = 16;

pub const AtlasFormat = enum {
    r8,
    rgba8,

    pub fn vkFormat(self: AtlasFormat) vk.Format {
        return switch (self) {
            .r8 => vk.VK_FORMAT_R8_UNORM,
            .rgba8 => vk.VK_FORMAT_R8G8B8A8_UNORM,
        };
    }

    pub fn bytesPerPixel(self: AtlasFormat) u32 {
        return switch (self) {
            .r8 => 1,
            .rgba8 => 4,
        };
    }
};

pub const AtlasResources = struct {
    image: vk.Image = null,
    memory: vk.DeviceMemory = null,
    view: vk.ImageView = null,
    width: u32 = 0,
    height: u32 = 0,
    format: AtlasFormat = .r8,
    layout_ready: bool = false,

    pub fn destroy(self: *AtlasResources, device: vk.Device) void {
        std.debug.assert(device != null);
        if (self.view) |v| vk.vkDestroyImageView(device, v, null);
        if (self.image) |i| vk.vkDestroyImage(device, i, null);
        if (self.memory) |m| vk.vkFreeMemory(device, m, null);
        self.* = .{};
    }
};

pub const AtlasError = error{
    AtlasImageCreationFailed,
    AtlasMemoryAllocationFailed,
    AtlasImageViewCreationFailed,
    NoSuitableMemoryType,
};

pub fn createAtlas(
    resources: *AtlasResources,
    size: u32,
    format: AtlasFormat,
    device: vk.Device,
    mem_properties: *const vk.PhysicalDeviceMemoryProperties,
) AtlasError!void {
    std.debug.assert(size > 0);
    std.debug.assert(resources.image == null);
    try createAtlasImage(device, resources, size, size, format, mem_properties);
    resources.format = format;
    resources.layout_ready = false;
    std.debug.assert(resources.view != null);
}

pub fn recordAtlasCopies(
    cmd: vk.CommandBuffer,
    resources: *AtlasResources,
    staging_buffer: vk.Buffer,
    regions: []const vk.BufferImageCopy,
) void {
    std.debug.assert(cmd != null);
    std.debug.assert(resources.image != null);
    std.debug.assert(staging_buffer != null);
    if (regions.len == 0) return;

    const from = if (resources.layout_ready) &sampled_state else &undefined_state;
    recordBarrier(cmd, resources.image, from, &transfer_state);

    var start: usize = 0;
    while (start < regions.len) {
        const count = @min(regions.len - start, copy_region_count_max);
        vk.vkCmdCopyBufferToImage(
            cmd,
            staging_buffer,
            resources.image,
            transfer_state.layout,
            @intCast(count),
            regions[start..].ptr,
        );
        start += count;
    }
    std.debug.assert(start == regions.len);

    recordBarrier(cmd, resources.image, &transfer_state, &sampled_state);
    resources.layout_ready = true;
}

pub fn copyRegion(
    staging_offset: vk.DeviceSize,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
) vk.BufferImageCopy {
    std.debug.assert(width > 0);
    std.debug.assert(height > 0);
    return .{
        .bufferOffset = staging_offset,
        .bufferRowLength = 0,
        .bufferImageHeight = 0,
        .imageSubresource = .{
            .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
            .mipLevel = 0,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
        .imageOffset = .{ .x = @intCast(x), .y = @intCast(y), .z = 0 },
        .imageExtent = .{ .width = width, .height = height, .depth = 1 },
    };
}

const ImageState = struct {
    stage: u32,
    access: u32,
    layout: vk.ImageLayout,
};

const undefined_state = ImageState{
    .stage = vk.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
    .access = 0,
    .layout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
};

const transfer_state = ImageState{
    .stage = vk.VK_PIPELINE_STAGE_TRANSFER_BIT,
    .access = vk.VK_ACCESS_TRANSFER_WRITE_BIT,
    .layout = vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
};

const sampled_state = ImageState{
    .stage = vk.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
    .access = vk.VK_ACCESS_SHADER_READ_BIT,
    .layout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
};

const color_range = vk.ImageSubresourceRange{
    .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
    .baseMipLevel = 0,
    .levelCount = 1,
    .baseArrayLayer = 0,
    .layerCount = 1,
};

fn createAtlasImage(
    device: vk.Device,
    resources: *AtlasResources,
    width: u32,
    height: u32,
    format: AtlasFormat,
    mem_properties: *const vk.PhysicalDeviceMemoryProperties,
) AtlasError!void {
    std.debug.assert(device != null);
    std.debug.assert(resources.image == null);

    const vk_fmt = format.vkFormat();

    resources.image = try createImage(device, width, height, vk_fmt);
    errdefer {
        vk.vkDestroyImage(device, resources.image, null);
        resources.image = null;
    }

    resources.memory = try allocateImageMemory(device, resources.image, mem_properties);
    errdefer {
        vk.vkFreeMemory(device, resources.memory, null);
        resources.memory = null;
    }
    _ = vk.vkBindImageMemory(device, resources.image, resources.memory, 0);

    resources.view = try createImageView(device, resources.image, vk_fmt);
    errdefer {
        vk.vkDestroyImageView(device, resources.view, null);
        resources.view = null;
    }

    resources.width = width;
    resources.height = height;
}

fn createImage(device: vk.Device, width: u32, height: u32, format: vk.Format) AtlasError!vk.Image {
    std.debug.assert(device != null);
    std.debug.assert(width > 0 and height > 0);

    const info = vk.ImageCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .imageType = vk.VK_IMAGE_TYPE_2D,
        .format = format,
        .extent = .{ .width = width, .height = height, .depth = 1 },
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = vk.VK_SAMPLE_COUNT_1_BIT,
        .tiling = vk.VK_IMAGE_TILING_OPTIMAL,
        .usage = vk.VK_IMAGE_USAGE_TRANSFER_DST_BIT | vk.VK_IMAGE_USAGE_SAMPLED_BIT,
        .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
        .queueFamilyIndexCount = 0,
        .pQueueFamilyIndices = null,
        .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
    };

    var image: vk.Image = null;
    if (!vk.succeeded(vk.vkCreateImage(device, &info, null, &image))) {
        return AtlasError.AtlasImageCreationFailed;
    }
    std.debug.assert(image != null);
    return image;
}

fn allocateImageMemory(
    device: vk.Device,
    image: vk.Image,
    mem_properties: *const vk.PhysicalDeviceMemoryProperties,
) AtlasError!vk.DeviceMemory {
    std.debug.assert(device != null);
    std.debug.assert(image != null);

    var reqs: vk.MemoryRequirements = undefined;
    vk.vkGetImageMemoryRequirements(device, image, &reqs);

    const type_index = vk.findMemoryType(
        mem_properties,
        reqs.memoryTypeBits,
        vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
    ) orelse return AtlasError.NoSuitableMemoryType;

    const alloc_info = vk.MemoryAllocateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .pNext = null,
        .allocationSize = reqs.size,
        .memoryTypeIndex = type_index,
    };

    var memory: vk.DeviceMemory = null;
    if (!vk.succeeded(vk.vkAllocateMemory(device, &alloc_info, null, &memory))) {
        return AtlasError.AtlasMemoryAllocationFailed;
    }
    std.debug.assert(memory != null);
    return memory;
}

fn createImageView(device: vk.Device, image: vk.Image, format: vk.Format) AtlasError!vk.ImageView {
    std.debug.assert(device != null);
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
    if (!vk.succeeded(vk.vkCreateImageView(device, &view_info, null, &view))) {
        return AtlasError.AtlasImageViewCreationFailed;
    }
    return view;
}

fn recordBarrier(
    cmd: vk.CommandBuffer,
    image: vk.Image,
    from: *const ImageState,
    to: *const ImageState,
) void {
    std.debug.assert(cmd != null);
    std.debug.assert(to.layout != vk.VK_IMAGE_LAYOUT_UNDEFINED);
    const barrier = vk.ImageMemoryBarrier{
        .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .pNext = null,
        .srcAccessMask = from.access,
        .dstAccessMask = to.access,
        .oldLayout = from.layout,
        .newLayout = to.layout,
        .srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresourceRange = color_range,
    };
    vk.vkCmdPipelineBarrier(cmd, from.stage, to.stage, 0, 0, null, 0, null, 1, (&barrier)[0..1]);
}
