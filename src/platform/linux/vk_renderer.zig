const std = @import("std");
const assert = std.debug.assert;
const vk = @import("vulkan.zig");
const backend = @import("../../core/backend.zig");
const packed_mod = @import("../../core/packed_frame.zig");
const limits_mod = @import("../../core/limits.zig");
pub const vk_types = @import("vk_types.zig");
const vk_pipelines = @import("vk_pipelines.zig");
const vk_atlas = @import("vk_atlas.zig");
const vk_instance = @import("vk_instance.zig");
const vk_swapchain = @import("vk_swapchain.zig");
const vk_buffers = @import("vk_buffers.zig");
const vk_descriptors = @import("vk_descriptors.zig");
const vk_draw = @import("vk_draw.zig");
pub const NativeSurface = @import("vk_surface.zig").NativeSurface;

const PackedFrame = backend.PackedFrame;
const Pipeline = packed_mod.Pipeline;
const FrameCapacity = vk_types.FrameCapacity;
const FrameBuffer = vk_types.FrameBuffer;
const WindowLimits = limits_mod.WindowLimits;
const AtlasLimits = limits_mod.AtlasLimits;
const Uniforms = vk_types.Uniforms;

pub const enable_validation_layers = vk_instance.enable_validation_layers;

pub const frame_count_max = vk_types.frame_count_max;
const swapchain_image_count_max = vk_swapchain.MAX_SWAPCHAIN_IMAGES;

const pipeline_count = vk_draw.pipeline_count;

const AtlasSlot = enum(u8) { glyph, svg, image };
const atlas_slot_count: u32 = vk_descriptors.atlas_binding_count;

comptime {
    assert(@typeInfo(AtlasSlot).@"enum".field_names.len == atlas_slot_count);
}

const FrameResources = struct {
    buffers: [vk_types.frame_buffer_count]vk.Buffer = @splat(null),
    mapped: [vk_types.frame_buffer_count][*]u8 = undefined,
    uniform_buffer: vk.Buffer = null,
    uniform_mapped: ?*Uniforms = null,
    descriptor_set: vk.DescriptorSet = null,
    fence: vk.Fence = null,
    image_available_semaphore: vk.Semaphore = null,
    command_buffer: vk.CommandBuffer = null,
};

const UploadBatch = struct {
    regions: [vk_atlas.copy_region_count_max]vk.BufferImageCopy = undefined,
    len: u32 = 0,
};

const PipelineShaders = struct {
    vert: []align(4) const u8,
    frag: []align(4) const u8,
    blend: vk_pipelines.BlendMode,
};

fn spirv(comptime name: []const u8) []align(4) const u8 {
    return @alignCast(@embedFile("shaders/" ++ name ++ ".spv"));
}

const pipeline_shaders = [pipeline_count]PipelineShaders{
    .{ .vert = spirv("unified.vert"), .frag = spirv("unified.frag"), .blend = .standard },
    .{ .vert = spirv("text.vert"), .frag = spirv("text.frag"), .blend = .standard },
    .{ .vert = spirv("svg.vert"), .frag = spirv("svg.frag"), .blend = .premultiplied },
    .{ .vert = spirv("image.vert"), .frag = spirv("image.frag"), .blend = .standard },
    .{ .vert = spirv("triangles.vert"), .frag = spirv("mesh.frag"), .blend = .premultiplied },
    .{ .vert = spirv("strip_expanded.vert"), .frag = spirv("mesh.frag"), .blend = .premultiplied },
    .{ .vert = spirv("point_instanced.vert"), .frag = spirv("mesh.frag"), .blend = .premultiplied },
};

comptime {
    assert(@backingInt(Pipeline.quad) == 0);
    assert(@backingInt(Pipeline.glyph) == 1);
    assert(@backingInt(Pipeline.svg) == 2);
    assert(@backingInt(Pipeline.image) == 3);
    assert(@backingInt(Pipeline.triangles) == 4);
    assert(@backingInt(Pipeline.strip_expanded) == 5);
    assert(@backingInt(Pipeline.point_instanced) == 6);
}

pub const VulkanRenderer = struct {
    comptime {
        backend.verifyRenderer(@This());
    }

    native_surface: ?NativeSurface = null,

    instance: vk.Instance = null,
    debug_messenger: vk.DebugUtilsMessengerEXT = null,
    physical_device: vk.PhysicalDevice = null,
    device: vk.Device = null,
    graphics_queue: vk.Queue = null,
    present_queue: vk.Queue = null,
    surface: vk.Surface = null,
    graphics_family: u32 = 0,
    present_family: u32 = 0,
    mem_properties: vk.PhysicalDeviceMemoryProperties = undefined,
    allocation_bytes_max: vk.DeviceSize = 0,
    storage_range_bytes_max: u64 = 0,

    swapchain: vk.Swapchain = null,
    swapchain_images: [swapchain_image_count_max]vk.Image = @splat(null),
    swapchain_image_views: [swapchain_image_count_max]vk.ImageView = @splat(null),
    present_semaphores: [swapchain_image_count_max]vk.Semaphore = @splat(null),
    swapchain_image_count: u32 = 0,
    swapchain_format: vk.Format = vk.VK_FORMAT_B8G8R8A8_UNORM,
    swapchain_extent: vk.Extent2D = .{ .width = 0, .height = 0 },
    swapchain_needs_recreate: bool = false,
    render_pass: vk.RenderPass = null,
    framebuffers: [swapchain_image_count_max]vk.Framebuffer = @splat(null),

    window_limits: WindowLimits = undefined,
    size_px: backend.SizePx = .{ .width = 0, .height = 0 },

    pipeline_cache: vk.PipelineCache = null,
    pipeline_layout: vk.PipelineLayout = null,
    pipelines: [pipeline_count]vk.Pipeline = @splat(null),
    descriptor_layout: vk.DescriptorSetLayout = null,
    descriptor_pool: vk.DescriptorPool = null,
    atlas_sampler: vk.Sampler = null,

    command_pool: vk.CommandPool = null,

    frames: [frame_count_max]FrameResources = @splat(.{}),
    frame_count: u32 = 0,
    current_frame: u32 = 0,
    recording: bool = false,

    host_memory_pool: vk_buffers.MemoryPool = .{},
    capacity: FrameCapacity = undefined,

    staging_pool: vk_buffers.MemoryPool = .{},
    staging_buffer: vk.Buffer = null,
    staging_mapped: ?[*]u8 = null,
    staging_lane_bytes: vk.DeviceSize = 0,
    staging_lane_used: vk.DeviceSize = 0,
    upload_batches: [atlas_slot_count]UploadBatch = @splat(.{}),

    atlases: [atlas_slot_count]vk_atlas.AtlasResources = @splat(.{}),

    frame_number: u64 = 0,
    skip_logged: bool = false,

    initialized: bool = false,

    const Self = @This();

    pub fn initInPlace(
        self: *Self,
        surface: *const backend.Surface,
        limits: *const backend.RenderLimits,
    ) !void {
        assert(!self.initialized);
        assert(self.native_surface == null);
        const native: *const NativeSurface = @ptrCast(@alignCast(surface.native.?));
        assert(surface.size_px.width > 0);
        assert(surface.size_px.height > 0);
        assertFits(surface.size_px, &limits.window);
        self.size_px = surface.size_px;
        self.capacity = FrameCapacity.fromPaintLimits(&limits.paint);
        self.window_limits = limits.window;
        self.staging_lane_bytes = limits.atlas.upload_bytes_frame_max;
        self.frame_count = limits.frame.in_flight_count;
        assert(self.frame_count >= limits_mod.MIN_FRAMES_IN_FLIGHT);
        assert(self.frame_count <= frame_count_max);
        self.native_surface = native.*;
        errdefer self.native_surface = null;

        try self.initDevice();
        errdefer self.destroyDevice();
        try self.initSwapchainTargets(.{
            .width = surface.size_px.width,
            .height = surface.size_px.height,
        });
        errdefer self.destroySwapchainTargets();
        try self.initCommands();
        errdefer self.destroyCommands();
        try self.initHostReservations();
        errdefer self.destroyHostReservations();
        try self.createAtlasImages(&limits.atlas);
        errdefer self.destroyAtlasImages();
        try self.createFrameBuffers();
        errdefer self.destroyFrameBuffers();
        try self.initDescriptors();
        errdefer self.destroyDescriptors();
        try self.createPipelines();

        self.initialized = true;
        std.log.info(
            "VulkanRenderer initialized: {d}x{d} px (scale {d:.2}), 1 sample per pixel, " ++
                "frames in flight: {d}, swapchain images: {d}, frame buffers {d} B, " ++
                "atlas staging {d} B",
            .{
                self.swapchain_extent.width, self.swapchain_extent.height,
                surface.scale_factor,        self.frame_count,
                self.swapchain_image_count,  self.capacity.frameBytes(),
                self.staging_pool.size,
            },
        );
    }

    pub fn deinit(self: *Self) void {
        if (!self.initialized) return;
        assert(self.device != null);
        _ = vk.vkDeviceWaitIdle(self.device);
        self.destroyPipelines();
        self.destroyDescriptors();
        self.destroyFrameBuffers();
        self.destroyAtlasImages();
        self.destroyHostReservations();
        self.destroyCommands();
        self.destroySwapchainTargets();
        self.destroyDevice();
        self.native_surface = null;
        self.initialized = false;
    }

    pub fn uploadAtlas(
        self: *Self,
        atlas: backend.AtlasKind,
        dirty: backend.RectPx,
        pixels: []const u8,
    ) void {
        assert(self.initialized);
        assert(dirty.width > 0);
        assert(dirty.height > 0);
        const slot = atlasSlot(atlas);
        const resources = &self.atlases[@backingInt(slot)];
        assert(dirty.x <= resources.width);
        assert(dirty.width <= resources.width - dirty.x);
        assert(dirty.y <= resources.height);
        assert(dirty.height <= resources.height - dirty.y);
        const bytes_per_pixel = resources.format.bytesPerPixel();
        assert(pixels.len == @as(u64, dirty.width) * dirty.height * bytes_per_pixel);

        const frame = self.beginCommands();
        const offset = std.mem.alignForward(vk.DeviceSize, self.staging_lane_used, 4);
        if (offset > self.staging_lane_bytes or pixels.len > self.staging_lane_bytes - offset) {
            std.debug.panic("Vulkan atlas staging lane exhausted: capacity {d} B " ++
                "(ResourceLimits.atlas.upload_bytes_frame_max), {d} B in use, {d} B requested, " ++
                "after frame {d}.", .{
                self.staging_lane_bytes,
                self.staging_lane_used,
                pixels.len,
                self.frame_number,
            });
        }
        const lane_start = @as(vk.DeviceSize, self.current_frame) * self.staging_lane_bytes;
        const staging = self.staging_mapped.?;
        @memcpy(staging[@intCast(lane_start + offset)..][0..pixels.len], pixels);
        self.staging_lane_used = offset + pixels.len;

        const batch = &self.upload_batches[@backingInt(slot)];
        assert(batch.len < batch.regions.len);
        batch.regions[batch.len] = vk_atlas.copyRegion(
            lane_start + offset,
            dirty.x,
            dirty.y,
            dirty.width,
            dirty.height,
        );
        batch.len += 1;
        if (batch.len == batch.regions.len) self.flushUploads(frame.command_buffer, slot);
    }

    pub fn draw(
        self: *Self,
        frame: *const PackedFrame,
        viewport: backend.Viewport,
        clear: backend.Color,
    ) void {
        assert(self.initialized);
        assert(viewport.scale_factor > 0);
        assert(clear.a >= 0);
        assert(clear.a <= 1);
        assert(std.meta.eql(viewport.size_px, self.size_px));
        self.frame_number = frame.frame_number;
        const resources = self.beginCommands();
        const cmd = resources.command_buffer;
        for (std.enums.values(AtlasSlot)) |slot| self.flushUploads(cmd, slot);

        const visible = viewport.size_px.width > 0 and viewport.size_px.height > 0;
        const image_index = if (visible) self.acquireImage(resources) else null;
        if (image_index) |index| {
            const uniforms = Uniforms{
                .viewport_width = logicalSize(viewport.size_px.width, viewport.scale_factor),
                .viewport_height = logicalSize(viewport.size_px.height, viewport.scale_factor),
            };
            vk_draw.writeInstances(frame, &resources.mapped, &self.capacity);
            resources.uniform_mapped.?.* = uniforms;
            self.recordRenderPass(resources, frame, index, .{
                .clear = clear,
                .logical_width = uniforms.viewport_width,
                .logical_height = uniforms.viewport_height,
            });
        }
        _ = vk.vkEndCommandBuffer(cmd);
        _ = vk.vkResetFences(self.device, 1, (&resources.fence)[0..1]);
        self.submit(resources, image_index);
        if (image_index) |index| self.present(index);
        self.recording = false;
        self.staging_lane_used = 0;
        self.current_frame = (self.current_frame + 1) % self.frame_count;
    }

    pub fn resize(self: *Self, size_px: backend.SizePx) void {
        assert(self.initialized);
        assertFits(size_px, &self.window_limits);
        self.size_px = size_px;
        if (size_px.width == 0 or size_px.height == 0) return;
        self.waitAllFrames();
        self.recreateSwapchain(.{ .width = size_px.width, .height = size_px.height }) catch |err| {
            std.log.err("Vulkan: swapchain rebuild for {d}x{d} px failed: {t}", .{
                size_px.width,
                size_px.height,
                err,
            });
            self.swapchain_needs_recreate = true;
        };
    }

    pub fn capabilities(self: *const Self) backend.Capabilities {
        assert(self.initialized);
        assert(self.pipelines[@backingInt(Pipeline.triangles)] != null);
        return .{ .meshes = true };
    }

    fn beginCommands(self: *Self) *FrameResources {
        const frame = &self.frames[self.current_frame];
        assert(frame.command_buffer != null);
        if (self.recording) return frame;
        self.waitFrame(frame);
        _ = vk.vkResetCommandBuffer(frame.command_buffer, 0);
        const begin_info = vk.CommandBufferBeginInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = null,
            .flags = 0,
            .pInheritanceInfo = null,
        };
        _ = vk.vkBeginCommandBuffer(frame.command_buffer, &begin_info);
        self.recording = true;
        assert(self.staging_lane_used == 0);
        for (self.upload_batches) |batch| assert(batch.len == 0);
        return frame;
    }

    fn flushUploads(self: *Self, cmd: vk.CommandBuffer, slot: AtlasSlot) void {
        assert(self.recording);
        const batch = &self.upload_batches[@backingInt(slot)];
        assert(batch.len <= batch.regions.len);
        if (batch.len == 0) return;
        const resources = &self.atlases[@backingInt(slot)];
        const regions = batch.regions[0..batch.len];
        vk_atlas.recordAtlasCopies(cmd, resources, self.staging_buffer, regions);
        batch.len = 0;
        assert(resources.layout_ready);
    }

    fn acquireImage(self: *Self, frame: *const FrameResources) ?u32 {
        if (self.swapchain_needs_recreate or !self.swapchainUsable()) {
            self.swapchain_needs_recreate = false;
            self.waitOtherFrames();
            self.recreateSwapchain(self.swapchain_extent) catch |err| {
                if (!self.skip_logged) {
                    std.log.err("Vulkan: frame {d} skipped: swapchain rebuild failed: {t}", .{
                        self.frame_number,
                        err,
                    });
                }
                self.skip_logged = true;
                self.swapchain_needs_recreate = true;
                return null;
            };
        }
        self.skip_logged = false;
        var image_index: u32 = 0;
        const result = vk.vkAcquireNextImageKHR(
            self.device,
            self.swapchain,
            std.math.maxInt(u64),
            frame.image_available_semaphore,
            null,
            &image_index,
        );
        switch (result) {
            vk.SUCCESS => {},
            vk.SUBOPTIMAL_KHR => self.swapchain_needs_recreate = true,
            vk.ERROR_OUT_OF_DATE_KHR, vk.TIMEOUT, vk.NOT_READY => {
                self.swapchain_needs_recreate = true;
                return null;
            },
            else => failFast("vkAcquireNextImageKHR", result),
        }
        assert(image_index < self.swapchain_image_count);
        return image_index;
    }

    const PassOptions = struct {
        clear: backend.Color,
        logical_width: f32,
        logical_height: f32,
    };

    fn recordRenderPass(
        self: *Self,
        resources: *const FrameResources,
        frame: *const PackedFrame,
        image_index: u32,
        options: PassOptions,
    ) void {
        assert(image_index < self.swapchain_image_count);
        assert(options.logical_width > 0);
        assert(options.logical_height > 0);
        const cmd = resources.command_buffer;
        const extent = self.swapchain_extent;
        const clear = options.clear;
        const clear_value = vk.clearColor(clear.r, clear.g, clear.b, clear.a);
        const render_pass_info = vk.RenderPassBeginInfo{
            .sType = vk.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
            .pNext = null,
            .renderPass = self.render_pass,
            .framebuffer = self.framebuffers[image_index],
            .renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = extent },
            .clearValueCount = 1,
            .pClearValues = (&clear_value)[0..1],
        };
        vk.vkCmdBeginRenderPass(cmd, &render_pass_info, vk.VK_SUBPASS_CONTENTS_INLINE);
        const viewport = vk.makeViewport(@floatFromInt(extent.width), @floatFromInt(extent.height));
        vk.vkCmdSetViewport(cmd, 0, 1, (&viewport)[0..1]);
        _ = vk_draw.recordDraws(&.{
            .command = cmd,
            .layout = self.pipeline_layout,
            .pipelines = &self.pipelines,
            .descriptor_set = resources.descriptor_set,
            .extent = extent,
            .scale_x = @as(f32, @floatFromInt(extent.width)) / options.logical_width,
            .scale_y = @as(f32, @floatFromInt(extent.height)) / options.logical_height,
        }, frame);
        vk.vkCmdEndRenderPass(cmd);
    }

    fn submit(self: *Self, frame: *const FrameResources, image_index: ?u32) void {
        assert(self.graphics_queue != null);
        const wait_stages = [_]u32{vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT};
        const semaphore_count: u32 = @intFromBool(image_index != null);
        const present_semaphore = if (image_index) |index| self.presentSemaphore(index) else null;
        const submit_info = vk.SubmitInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .pNext = null,
            .waitSemaphoreCount = semaphore_count,
            .pWaitSemaphores = (&frame.image_available_semaphore)[0..1],
            .pWaitDstStageMask = &wait_stages,
            .commandBufferCount = 1,
            .pCommandBuffers = (&frame.command_buffer)[0..1],
            .signalSemaphoreCount = semaphore_count,
            .pSignalSemaphores = (&present_semaphore)[0..1],
        };
        const result = vk.vkQueueSubmit(self.graphics_queue, 1, (&submit_info)[0..1], frame.fence);
        if (result != vk.SUCCESS) failFast("vkQueueSubmit", result);
    }

    fn present(self: *Self, image_index: u32) void {
        assert(image_index < self.swapchain_image_count);
        const present_semaphore = self.presentSemaphore(image_index);
        const present_info = vk.PresentInfoKHR{
            .sType = vk.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
            .pNext = null,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = (&present_semaphore)[0..1],
            .swapchainCount = 1,
            .pSwapchains = (&self.swapchain)[0..1],
            .pImageIndices = (&image_index)[0..1],
            .pResults = null,
        };
        const result = vk.vkQueuePresentKHR(self.present_queue, &present_info);
        switch (result) {
            vk.SUCCESS => {},
            vk.SUBOPTIMAL_KHR, vk.ERROR_OUT_OF_DATE_KHR => self.swapchain_needs_recreate = true,
            else => failFast("vkQueuePresentKHR", result),
        }
    }

    fn presentSemaphore(self: *const Self, image_index: u32) vk.Semaphore {
        assert(image_index < self.swapchain_image_count);
        const semaphore = self.present_semaphores[image_index];
        assert(semaphore != null);
        return semaphore;
    }

    fn failFast(call: []const u8, result: vk.Result) noreturn {
        assert(call.len > 0);
        assert(!vk.succeeded(result));
        std.debug.panic("Vulkan: {s} failed with {s} ({d}); the renderer cannot recover", .{
            call,
            vk.resultName(result),
            result,
        });
    }

    fn swapchainUsable(self: *const Self) bool {
        if (self.swapchain == null) return false;
        if (self.swapchain_image_count == 0) return false;
        assert(self.swapchain_image_count <= self.framebuffers.len);
        for (self.framebuffers[0..self.swapchain_image_count]) |framebuffer| {
            if (framebuffer == null) return false;
        }
        return true;
    }

    fn waitFrame(self: *const Self, frame: *const FrameResources) void {
        assert(self.device != null);
        assert(frame.fence != null);
        const fences = (&frame.fence)[0..1];
        _ = vk.vkWaitForFences(self.device, 1, fences, vk.TRUE, std.math.maxInt(u64));
    }

    fn waitAllFrames(self: *Self) void {
        assert(self.frame_count <= frame_count_max);
        for (self.frames[0..self.frame_count]) |*frame| {
            self.waitFrame(frame);
        }
    }

    fn waitOtherFrames(self: *Self) void {
        assert(self.recording);
        for (self.frames[0..self.frame_count], 0..) |*frame, index| {
            if (index == self.current_frame) continue;
            self.waitFrame(frame);
        }
    }

    fn recreateSwapchain(self: *Self, extent: vk.Extent2D) !void {
        assert(extent.width <= self.window_limits.framebuffer_width_max);
        assert(extent.height <= self.window_limits.framebuffer_height_max);
        vk_swapchain.destroyFramebuffers(self.device, &self.framebuffers);
        vk_swapchain.destroyImageViews(self.device, &self.swapchain_image_views);

        const old_swapchain = self.swapchain;
        const sc = try vk_swapchain.createSwapchain(
            self.device,
            self.physical_device,
            self.surface,
            extent,
            self.frame_count,
            old_swapchain,
        );
        _ = vk.vkQueueWaitIdle(self.present_queue);
        vk_buffers.destroySemaphores(self.device, &self.present_semaphores);
        if (old_swapchain) |old| vk.vkDestroySwapchainKHR(self.device, old, null);
        self.swapchain = sc.swapchain;
        self.swapchain_images = sc.images;
        self.swapchain_image_views = sc.image_views;
        self.swapchain_image_count = sc.image_count;
        self.swapchain_extent = sc.extent;
        assert(sc.format == self.swapchain_format);
        const count = self.swapchain_image_count;
        try vk_buffers.createSemaphores(self.device, self.present_semaphores[0..count]);

        try vk_swapchain.createFramebuffers(
            self.device,
            self.render_pass,
            &self.swapchain_image_views,
            self.swapchain_image_count,
            self.swapchain_extent,
            &self.framebuffers,
        );
    }

    fn initDevice(self: *Self) !void {
        assert(self.instance == null);
        const native = &self.native_surface.?;
        const inst = try vk_instance.createInstance(NativeSurface.instance_extension_name);
        self.instance = inst.instance;
        self.debug_messenger = inst.debug_messenger;
        errdefer self.destroyDevice();

        self.surface = try native.create(self.instance);
        const phys = try vk_instance.pickPhysicalDevice(self.instance, self.surface);
        self.physical_device = phys.physical_device;
        self.graphics_family = phys.families.graphics;
        self.present_family = phys.families.present;

        const dev = try vk_instance.createLogicalDevice(self.physical_device, phys.families);
        self.device = dev.device;
        self.graphics_queue = dev.graphics_queue;
        self.present_queue = dev.present_queue;
        vk.vkGetPhysicalDeviceMemoryProperties(self.physical_device, &self.mem_properties);
        self.allocation_bytes_max = vk_buffers.queryAllocationBytesMax(self.physical_device);
        var properties: vk.PhysicalDeviceProperties = undefined;
        vk.vkGetPhysicalDeviceProperties(self.physical_device, &properties);
        self.storage_range_bytes_max = properties.limits.maxStorageBufferRange;
        assert(self.storage_range_bytes_max >= vk_types.storage_buffer_range_guaranteed_bytes);
        assert(self.device != null);
    }

    fn destroyDevice(self: *Self) void {
        if (self.device) |device| vk.vkDestroyDevice(device, null);
        self.device = null;
        if (self.surface) |surface| vk.vkDestroySurfaceKHR(self.instance, surface, null);
        self.surface = null;
        vk_instance.destroyDebugMessenger(self.instance, self.debug_messenger);
        self.debug_messenger = null;
        if (self.instance) |instance| vk.vkDestroyInstance(instance, null);
        self.instance = null;
    }

    fn initSwapchainTargets(self: *Self, extent: vk.Extent2D) !void {
        assert(self.device != null);
        assert(self.swapchain == null);
        const sc = try vk_swapchain.createSwapchain(
            self.device,
            self.physical_device,
            self.surface,
            extent,
            self.frame_count,
            null,
        );
        self.swapchain = sc.swapchain;
        self.swapchain_images = sc.images;
        self.swapchain_image_views = sc.image_views;
        self.swapchain_image_count = sc.image_count;
        self.swapchain_format = sc.format;
        self.swapchain_extent = sc.extent;
        errdefer self.destroySwapchainTargets();

        const count = self.swapchain_image_count;
        try vk_buffers.createSemaphores(self.device, self.present_semaphores[0..count]);

        self.render_pass = try vk_swapchain.createRenderPass(self.device, self.swapchain_format);
        try vk_swapchain.createFramebuffers(
            self.device,
            self.render_pass,
            &self.swapchain_image_views,
            self.swapchain_image_count,
            self.swapchain_extent,
            &self.framebuffers,
        );
    }

    fn destroySwapchainTargets(self: *Self) void {
        assert(self.device != null);
        _ = vk.vkDeviceWaitIdle(self.device);
        vk_swapchain.destroyFramebuffers(self.device, &self.framebuffers);
        if (self.render_pass) |render_pass| vk.vkDestroyRenderPass(self.device, render_pass, null);
        self.render_pass = null;
        if (self.native_surface) |*native| native.swapchainDestroyBegin();
        vk_swapchain.destroyImageViews(self.device, &self.swapchain_image_views);
        vk_buffers.destroySemaphores(self.device, &self.present_semaphores);
        if (self.swapchain) |swapchain| vk.vkDestroySwapchainKHR(self.device, swapchain, null);
        self.swapchain = null;
        self.swapchain_image_count = 0;
        if (self.native_surface) |*native| native.swapchainDestroyEnd();
    }

    fn initCommands(self: *Self) !void {
        assert(self.command_pool == null);
        self.command_pool = try vk_buffers.createCommandPool(self.device, self.graphics_family);
        errdefer self.destroyCommands();
        const command_buffers = try vk_buffers.allocateCommandBuffers(
            self.device,
            self.command_pool,
            self.frame_count,
        );
        const sync = try vk_buffers.createSyncObjects(self.device, self.frame_count);
        for (self.frames[0..self.frame_count], 0..) |*frame, index| {
            frame.fence = sync.in_flight_fences[index];
            frame.image_available_semaphore = sync.image_available_semaphores[index];
            frame.command_buffer = command_buffers.render[index];
            assert(frame.fence != null);
        }
    }

    fn destroyCommands(self: *Self) void {
        for (&self.frames) |*frame| {
            if (frame.fence) |fence| vk.vkDestroyFence(self.device, fence, null);
            frame.fence = null;
            if (frame.image_available_semaphore) |s| vk.vkDestroySemaphore(self.device, s, null);
            frame.image_available_semaphore = null;
            frame.command_buffer = null;
        }
        if (self.command_pool) |pool| vk.vkDestroyCommandPool(self.device, pool, null);
        self.command_pool = null;
    }

    fn initHostReservations(self: *Self) !void {
        assert(self.staging_lane_bytes > 0);
        assert(self.allocation_bytes_max > 0);
        if (self.capacity.bufferPastRange(self.storage_range_bytes_max)) |buffer| {
            std.log.err("Vulkan: frame buffer '{t}' needs {d} B (ResourceLimits.paint), past " ++
                "this device's maxStorageBufferRange of {d} B", .{
                buffer,
                self.capacity.bufferBytes(buffer),
                self.storage_range_bytes_max,
            });
            return error.VulkanFrameBufferExceedsStorageRange;
        }
        const host_visible = vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
            vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
        const properties = &self.mem_properties;
        self.host_memory_pool = try vk_buffers.MemoryPool.init(self.device, properties, &.{
            .name = "frame and uniform buffers",
            .size = self.capacity.hostPoolBytes(self.frame_count),
            .allocation_bytes_max = self.allocation_bytes_max,
            .required_properties = host_visible,
        });
        errdefer self.destroyHostReservations();

        const staging_bytes = @as(vk.DeviceSize, self.frame_count) * self.staging_lane_bytes;
        self.staging_pool = try vk_buffers.MemoryPool.init(self.device, properties, &.{
            .name = "atlas staging",
            .size = staging_bytes + vk_types.host_pool_alignment_slack_bytes,
            .allocation_bytes_max = self.allocation_bytes_max,
            .required_properties = host_visible,
        });
        const staging = try vk_buffers.createMappedBufferFromPool(
            self.device,
            &self.staging_pool,
            staging_bytes,
            vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
        );
        self.staging_buffer = staging.buffer;
        self.staging_mapped = @ptrCast(staging.mapped);
    }

    fn destroyHostReservations(self: *Self) void {
        vk_buffers.destroyBufferOnly(self.device, self.staging_buffer);
        self.staging_buffer = null;
        self.staging_mapped = null;
        self.staging_pool.destroy(self.device);
        self.host_memory_pool.destroy(self.device);
    }

    fn createAtlasImages(self: *Self, limits: *const AtlasLimits) !void {
        assert(self.device != null);
        errdefer self.destroyAtlasImages();
        const sizes = [atlas_slot_count]u32{ limits.text_size, limits.svg_size, limits.image_size };
        const formats = [atlas_slot_count]vk_atlas.AtlasFormat{ .r8, .rgba8, .rgba8 };
        for (&self.atlases, sizes, formats) |*atlas, size, format| {
            try vk_atlas.createAtlas(atlas, size, format, self.device, &self.mem_properties);
            assert(atlas.view != null);
        }
    }

    fn destroyAtlasImages(self: *Self) void {
        for (&self.atlases) |*atlas| atlas.destroy(self.device);
    }

    fn createFrameBuffers(self: *Self) !void {
        assert(self.host_memory_pool.offset == 0);
        errdefer self.destroyFrameBuffers();
        for (self.frames[0..self.frame_count]) |*frame| {
            const uniform = try vk_buffers.createMappedBufferFromPool(
                self.device,
                &self.host_memory_pool,
                @sizeOf(Uniforms),
                vk.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
            );
            frame.uniform_buffer = uniform.buffer;
            frame.uniform_mapped = @ptrCast(@alignCast(uniform.mapped));
            for (std.enums.values(FrameBuffer)) |buffer| {
                const storage = try vk_buffers.createMappedBufferFromPool(
                    self.device,
                    &self.host_memory_pool,
                    self.capacity.bufferBytes(buffer),
                    vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
                );
                frame.buffers[@backingInt(buffer)] = storage.buffer;
                frame.mapped[@backingInt(buffer)] = @ptrCast(storage.mapped);
            }
        }
    }

    fn destroyFrameBuffers(self: *Self) void {
        for (&self.frames) |*frame| {
            vk_buffers.destroyBufferOnly(self.device, frame.uniform_buffer);
            frame.uniform_buffer = null;
            frame.uniform_mapped = null;
            for (&frame.buffers) |*buffer| {
                vk_buffers.destroyBufferOnly(self.device, buffer.*);
                buffer.* = null;
            }
        }
    }

    fn initDescriptors(self: *Self) !void {
        assert(self.descriptor_layout == null);
        self.descriptor_layout = try vk_descriptors.createFrameLayout(self.device);
        errdefer self.destroyDescriptors();
        self.descriptor_pool = try vk_descriptors.createDescriptorPool(
            self.device,
            self.frame_count,
        );
        self.atlas_sampler = try vk_descriptors.createAtlasSampler(self.device);
        for (self.frames[0..self.frame_count]) |*frame| {
            frame.descriptor_set = try vk_descriptors.allocateDescriptorSet(
                self.device,
                self.descriptor_pool,
                self.descriptor_layout,
            );
            var bindings = vk_descriptors.FrameBindings{
                .storage = undefined,
                .uniform = frame.uniform_buffer,
                .atlas_views = undefined,
                .sampler = self.atlas_sampler,
            };
            for (std.enums.values(FrameBuffer)) |buffer| {
                bindings.storage[@backingInt(buffer)] = .{
                    .buffer = frame.buffers[@backingInt(buffer)],
                    .offset = 0,
                    .range = self.capacity.bufferBytes(buffer),
                };
            }
            for (&bindings.atlas_views, self.atlases) |*view, atlas| view.* = atlas.view;
            vk_descriptors.updateFrameDescriptorSet(self.device, frame.descriptor_set, &bindings);
        }
    }

    fn destroyDescriptors(self: *Self) void {
        if (self.atlas_sampler) |sampler| vk.vkDestroySampler(self.device, sampler, null);
        self.atlas_sampler = null;
        if (self.descriptor_pool) |pool| vk.vkDestroyDescriptorPool(self.device, pool, null);
        self.descriptor_pool = null;
        for (&self.frames) |*frame| frame.descriptor_set = null;
        if (self.descriptor_layout) |layout| {
            vk.vkDestroyDescriptorSetLayout(self.device, layout, null);
        }
        self.descriptor_layout = null;
    }

    fn createPipelines(self: *Self) !void {
        assert(self.render_pass != null);
        assert(self.descriptor_layout != null);
        self.pipeline_cache = try vk_pipelines.createPipelineCache(self.device, null);
        errdefer self.destroyPipelines();
        self.pipeline_layout = try vk_pipelines.createPipelineLayout(
            self.device,
            self.descriptor_layout,
        );
        for (&self.pipelines, pipeline_shaders) |*pipeline, shaders| {
            pipeline.* = try vk_pipelines.createGraphicsPipeline(self.device, self.render_pass, .{
                .vert_spv = shaders.vert,
                .frag_spv = shaders.frag,
                .pipeline_layout = self.pipeline_layout,
                .blend_mode = shaders.blend,
            }, self.pipeline_cache);
        }
    }

    fn destroyPipelines(self: *Self) void {
        for (&self.pipelines) |*pipeline| {
            vk_pipelines.destroyPipeline(self.device, pipeline.*);
            pipeline.* = null;
        }
        if (self.pipeline_layout) |layout| vk.vkDestroyPipelineLayout(self.device, layout, null);
        self.pipeline_layout = null;
        if (self.pipeline_cache) |cache| vk.vkDestroyPipelineCache(self.device, cache, null);
        self.pipeline_cache = null;
    }
};

fn atlasSlot(atlas: backend.AtlasKind) AtlasSlot {
    return switch (atlas) {
        .glyph => .glyph,
        .svg => .svg,
        .image => .image,
        .glyph_color => std.debug.panic("Vulkan: no glyph_color atlas; nothing emits colour " ++
            "glyphs yet (contract §9, phase 5)", .{}),
    };
}

fn assertFits(size_px: backend.SizePx, window: *const WindowLimits) void {
    assert(window.framebuffer_width_max > 0);
    assert(size_px.width <= window.framebuffer_width_max);
    assert(size_px.height <= window.framebuffer_height_max);
}

fn logicalSize(size_px: u32, scale_factor: f32) f32 {
    assert(size_px > 0);
    assert(scale_factor > 0);
    return @as(f32, @floatFromInt(size_px)) / scale_factor;
}

test "VUID-vkQueueSubmit-pSignalSemaphores-00067: no signal while a present waits" {
    const handles: [swapchain_image_count_max]u8 = @splat(0);
    const orders = [_][]const u32{
        &.{ 0, 1, 2, 0, 1, 2, 0, 1, 2, 0, 1, 2 },
        &.{ 0, 1, 2, 3, 1, 0, 3, 2, 0, 1, 3, 2 },
    };
    for (orders) |order| {
        var renderer = VulkanRenderer{};
        renderer.frame_count = 2;
        renderer.swapchain_image_count = 4;
        for (renderer.present_semaphores[0..4], 0..) |*semaphore, index| {
            semaphore.* = @ptrCast(@constCast(&handles[index]));
        }
        var waiting: [swapchain_image_count_max]vk.Semaphore = @splat(null);
        for (order) |image_index| {
            assert(image_index < renderer.swapchain_image_count);
            waiting[image_index] = null;
            const semaphore = renderer.presentSemaphore(image_index);
            for (waiting) |pending| try std.testing.expect(pending != semaphore);
            waiting[image_index] = semaphore;
            renderer.current_frame = (renderer.current_frame + 1) % renderer.frame_count;
        }
    }
}
