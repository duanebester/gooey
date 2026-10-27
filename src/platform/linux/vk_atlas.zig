//! Atlas texture management for Vulkan renderer.
//!
//! One generic implementation, parameterized by pixel format, serves all three
//! atlas upload paths (text, SVG, image). Each atlas follows the same
//! lifecycle: create image → clear it on the GPU → stage dirty rows into the
//! frame's staging lane → barrier → copy → barrier, inside the frame's command
//! buffer. The renderer bounds the rows staged per frame by
//! `ResourceLimits.atlas.upload_bytes_frame_max`.
//!
//! Axes of variation across the three atlases:
//!   1. Pixel format — R8 (text) vs RGBA8 (SVG, image)
//!   2. Which AtlasResources instance to target
//!   3. Which descriptor set / storage buffer to bind
//!
//! Everything else (image creation, staging, barriers, submit) is identical.

const std = @import("std");
const vk = @import("vulkan.zig");

// =============================================================================
// Limits (CLAUDE.md Rule #4)
// =============================================================================

/// Maximum atlas dimension in either axis.
/// 4096×4096 supports ~16M pixels per atlas — plenty for UI workloads.
/// Back-of-envelope (CLAUDE.md Rule #7): 4096² × 4 = 64MB per RGBA atlas.
pub const MAX_ATLAS_DIMENSION: u32 = 4096;

/// Staged copies start at this byte alignment: `vkCmdCopyBufferToImage`
/// requires `bufferOffset` to be a multiple of 4 and of the texel size, and an
/// R8 text band can end at any byte.
pub const STAGING_COPY_ALIGNMENT_BYTES: vk.DeviceSize = 4;

comptime {
    const limits = @import("../../core/limits.zig");
    std.debug.assert(MAX_ATLAS_DIMENSION == limits.MAX_ATLAS_DIMENSION);
    std.debug.assert(MAX_ATLAS_DIMENSION == @import("../../text/atlas.zig").Atlas.MAX_SIZE);
    // The smallest valid lane holds one aligned full-width RGBA row.
    std.debug.assert(limits.MAX_ATLAS_ROW_BYTES == MAX_ATLAS_DIMENSION * 4);
}

// =============================================================================
// Public Types
// =============================================================================

/// Pixel format for atlas textures. Determines Vulkan format and byte stride.
pub const AtlasFormat = enum {
    /// Single-channel (text atlas): 1 byte per pixel, VK_FORMAT_R8_UNORM.
    r8,
    /// Four-channel (SVG/image atlas): 4 bytes per pixel, VK_FORMAT_R8G8B8A8_UNORM.
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

/// All Vulkan resources for a single atlas texture.
/// Groups the 7 per-atlas fields, so three atlases are 3 structs, not 21 fields.
pub const AtlasResources = struct {
    image: vk.Image = null,
    memory: vk.DeviceMemory = null,
    view: vk.ImageView = null,
    width: u32 = 0,
    height: u32 = 0,
    generation: u32 = 0,

    /// Destroy all Vulkan objects owned by this atlas. Safe with null handles.
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

/// Sub-region of an atlas that needs GPU upload.
/// Coordinates are in atlas pixels (not bytes).
pub const DirtyRegion = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

// =============================================================================
// Public API
// =============================================================================

/// Update a textured pipeline's descriptor set (storage + uniform + atlas + sampler).
///
/// Serves the text, SVG, and image pipelines, which differ only in which
/// descriptor set, storage buffer, and atlas view to use.
pub fn updateAtlasDescriptorSet(
    device: vk.Device,
    descriptor_set: vk.DescriptorSet,
    storage_buffer: vk.Buffer,
    storage_range: vk.DeviceSize,
    uniform_buffer: vk.Buffer,
    atlas_view: vk.ImageView,
    sampler: vk.Sampler,
) void {
    std.debug.assert(device != null);
    std.debug.assert(atlas_view != null and sampler != null);

    const buffer_infos = [_]vk.DescriptorBufferInfo{
        .{
            .buffer = storage_buffer,
            .offset = 0,
            .range = storage_range,
        },
        .{
            .buffer = uniform_buffer,
            .offset = 0,
            .range = @sizeOf(@import("vk_types.zig").Uniforms),
        },
    };

    const image_info = vk.DescriptorImageInfo{
        .sampler = null,
        .imageView = atlas_view,
        .imageLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
    };

    const sampler_info = vk.DescriptorImageInfo{
        .sampler = sampler,
        .imageView = null,
        .imageLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
    };

    const writes = descriptorWrites(descriptor_set, &buffer_infos, &image_info, &sampler_info);
    vk.vkUpdateDescriptorSets(device, writes.len, &writes, 0, null);
}

// =============================================================================
// Public API — Async Partial Atlas Uploads (ring staging, no sync fence)
// =============================================================================

/// Ensure an atlas VkImage exists at the given dimensions.
/// (Re)creates the image if dimensions changed or image doesn't exist yet.
/// Returns `true` if the image was (re)created — caller must update
/// descriptor sets for ALL frames, initialize the image, and upload every row.
pub fn ensureAtlasImage(
    resources: *AtlasResources,
    width: u32,
    height: u32,
    format: AtlasFormat,
    device: vk.Device,
    mem_properties: *const vk.PhysicalDeviceMemoryProperties,
) AtlasError!bool {
    std.debug.assert(width > 0 and width <= MAX_ATLAS_DIMENSION);
    std.debug.assert(height > 0 and height <= MAX_ATLAS_DIMENSION);

    const same_size = resources.width == width and
        resources.height == height and
        resources.image != null;
    if (same_size) return false;

    resources.destroy(device);
    try createAtlasImage(device, resources, width, height, format, mem_properties);
    return true;
}

/// Copy dirty atlas rows into a staging buffer at the given offset.
///
/// Only the dirty region's pixel rows are copied, tightly packed in the
/// staging buffer (no atlas-stride padding). This is what
/// `vkCmdCopyBufferToImage` expects when `bufferRowLength = 0`.
///
/// Returns the number of bytes staged.
pub fn stageDirtyRegion(
    staging_ptr: [*]u8,
    staging_offset: vk.DeviceSize,
    atlas_data: []const u8,
    atlas_width: u32,
    format: AtlasFormat,
    dirty: DirtyRegion,
) vk.DeviceSize {
    std.debug.assert(dirty.width > 0 and dirty.height > 0);
    std.debug.assert(dirty.x + dirty.width <= atlas_width);

    const bpp: usize = format.bytesPerPixel();
    const atlas_height: u32 = @intCast(atlas_data.len / (@as(usize, atlas_width) * bpp));
    std.debug.assert(dirty.y + dirty.height <= atlas_height);
    const row_bytes: usize = @as(usize, dirty.width) * bpp;
    const atlas_stride: usize = @as(usize, atlas_width) * bpp;
    var dest_cursor: usize = @intCast(staging_offset);

    for (0..dirty.height) |row| {
        const src_y = @as(usize, dirty.y) + row;
        const src_offset = src_y * atlas_stride + @as(usize, dirty.x) * bpp;
        @memcpy(staging_ptr[dest_cursor..][0..row_bytes], atlas_data[src_offset..][0..row_bytes]);
        dest_cursor += row_bytes;
    }

    const total: vk.DeviceSize = @intCast(dest_cursor - @as(usize, @intCast(staging_offset)));
    std.debug.assert(total == @as(vk.DeviceSize, dirty.width) * @as(vk.DeviceSize, dirty.height) * @as(vk.DeviceSize, bpp));
    return total;
}

/// One staged band of atlas rows and where it lives in the staging buffer.
pub const StagedCopy = struct {
    staging_offset: vk.DeviceSize,
    region: DirtyRegion,
};

/// Record one atlas's transfer commands for this frame.
///
/// `initialize` is set on the first frame after the image was (re)created: the
/// image moves from UNDEFINED and is cleared to zero on the GPU, so rows that
/// have not been uploaded yet sample as transparent rather than as stale
/// memory. Otherwise the image moves from SHADER_READ_ONLY and keeps its
/// pixels. `copy` is the band of rows staged this frame, if any; the budget may
/// leave none for this atlas this frame. Both end in SHADER_READ_ONLY.
pub fn recordAtlasTransfer(
    cmd: vk.CommandBuffer,
    image: vk.Image,
    staging_buffer: vk.Buffer,
    copy: ?StagedCopy,
    initialize: bool,
) void {
    std.debug.assert(cmd != null);
    std.debug.assert(image != null);
    std.debug.assert(staging_buffer != null);
    std.debug.assert(initialize or copy != null);

    if (initialize) {
        recordBarrier(cmd, image, &undefined_state, &transfer_state);
        const zero = vk.ClearColorValue{ .float32 = .{ 0, 0, 0, 0 } };
        const layout = transfer_state.layout;
        vk.vkCmdClearColorImage(cmd, image, layout, &zero, 1, (&color_range)[0..1]);
    } else {
        recordBarrier(cmd, image, &sampled_state, &transfer_state);
    }

    if (copy) |band| {
        std.debug.assert(band.region.width > 0 and band.region.height > 0);
        std.debug.assert(band.staging_offset % STAGING_COPY_ALIGNMENT_BYTES == 0);
        // The clear and the copy both write the image in the transfer stage.
        if (initialize) recordBarrier(cmd, image, &transfer_state, &transfer_state);
        const region = vk.BufferImageCopy{
            .bufferOffset = band.staging_offset,
            .bufferRowLength = 0, // tightly packed (row length = imageExtent.width)
            .bufferImageHeight = 0, // tightly packed (height = imageExtent.height)
            .imageSubresource = .{
                .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
                .mipLevel = 0,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
            .imageOffset = .{ .x = @intCast(band.region.x), .y = @intCast(band.region.y), .z = 0 },
            .imageExtent = .{
                .width = band.region.width,
                .height = band.region.height,
                .depth = 1,
            },
        };
        const layout = transfer_state.layout;
        vk.vkCmdCopyBufferToImage(cmd, staging_buffer, image, layout, 1, (&region)[0..1]);
    }

    recordBarrier(cmd, image, &transfer_state, &sampled_state);
}

/// One side of an atlas image barrier: the stage and access that last touched
/// (or will next touch) the image, and its layout.
const ImageState = struct {
    stage: u32,
    access: u32,
    layout: vk.ImageLayout,
};

/// A freshly created image: no prior access, contents discarded.
const undefined_state = ImageState{
    .stage = vk.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
    .access = 0,
    .layout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
};

/// Being cleared or written by a buffer copy.
const transfer_state = ImageState{
    .stage = vk.VK_PIPELINE_STAGE_TRANSFER_BIT,
    .access = vk.VK_ACCESS_TRANSFER_WRITE_BIT,
    .layout = vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
};

/// Sampled by the text, SVG and image fragment shaders.
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

// =============================================================================
// Internal — Image Creation
// =============================================================================

/// Create a Vulkan image + device memory + image view for an atlas.
fn createAtlasImage(
    device: vk.Device,
    resources: *AtlasResources,
    width: u32,
    height: u32,
    format: AtlasFormat,
    mem_properties: *const vk.PhysicalDeviceMemoryProperties,
) AtlasError!void {
    std.debug.assert(device != null);
    std.debug.assert(resources.image == null); // Must be destroyed first

    const vk_fmt = format.vkFormat();

    // Create image
    resources.image = try createImage(device, width, height, vk_fmt);
    errdefer {
        vk.vkDestroyImage(device, resources.image, null);
        resources.image = null;
    }

    // Allocate and bind memory
    resources.memory = try allocateImageMemory(device, resources.image, mem_properties);
    errdefer {
        vk.vkFreeMemory(device, resources.memory, null);
        resources.memory = null;
    }
    _ = vk.vkBindImageMemory(device, resources.image, resources.memory, 0);

    // Create image view
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

// =============================================================================
// Internal — Descriptor Writes
// =============================================================================

/// Build the 4-write descriptor update array. Shared layout:
///   binding 0: storage buffer (glyph/svg/image instance data)
///   binding 1: uniform buffer (viewport dimensions)
///   binding 2: sampled image  (atlas texture)
///   binding 3: sampler
fn descriptorWrites(
    set: vk.DescriptorSet,
    buffer_infos: *const [2]vk.DescriptorBufferInfo,
    image_info: *const vk.DescriptorImageInfo,
    sampler_info: *const vk.DescriptorImageInfo,
) [4]vk.WriteDescriptorSet {
    return .{
        .{
            .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = set,
            .dstBinding = 0,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .pImageInfo = null,
            .pBufferInfo = buffer_infos[0..1],
            .pTexelBufferView = null,
        },
        .{
            .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = set,
            .dstBinding = 1,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .pImageInfo = null,
            .pBufferInfo = buffer_infos[1..2],
            .pTexelBufferView = null,
        },
        .{
            .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = set,
            .dstBinding = 2,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE,
            .pImageInfo = image_info[0..1],
            .pBufferInfo = null,
            .pTexelBufferView = null,
        },
        .{
            .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = set,
            .dstBinding = 3,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_SAMPLER,
            .pImageInfo = sampler_info[0..1],
            .pBufferInfo = null,
            .pTexelBufferView = null,
        },
    };
}
