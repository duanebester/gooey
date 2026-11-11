//! VulkanRenderer — the Vulkan backend of the core's `Renderer` contract
//! (`core/backend.zig`, contract §9), shared by Linux (Wayland) and Windows
//! (Win32).
//!
//! It draws the packed frame (`core/packed_frame.zig`) as it is: each frame
//! copies the used prefix of every instance array into that frame's storage
//! buffers and records the draw list in order (`vk_draw.zig`). Delegates to
//! one module per subsystem:
//!   - `vk_instance`    : Instance, device, debug messenger
//!   - `vk_surface`     : Window-system surface and its swapchain teardown
//!   - `vk_swapchain`   : Swapchain lifecycle, render pass, framebuffers
//!   - `vk_buffers`     : Buffer, command pool, command buffer, sync object creation
//!   - `vk_descriptors` : The frame's descriptor layout, pool, sets, sampler
//!   - `vk_pipelines`   : Generic pipeline creation
//!   - `vk_atlas`       : Atlas images and their batched uploads
//!   - `vk_draw`        : Recording the packed frame's draws
//!
//! ## One frame
//!
//! The frame's command buffer begins at the first `uploadAtlas` or at `draw`,
//! after the frame's fence shows the GPU is done with its buffers and staging
//! lane. `uploadAtlas` copies pixels into the lane and records the copies;
//! `draw` adds the render pass, then submits and presents. When no swapchain
//! image can be had (an out-of-date or unusable swapchain), `draw` still
//! submits the uploads, so they are never lost or re-staged, and skips only
//! the render pass; the host draws again once the swapchain is rebuilt.
//!
//! ## Resource sketch (CLAUDE.md §7)
//!
//! Reserved at `initInPlace` from the window's `RenderLimits`, never resized:
//! per frame in flight, the packed frame's storage buffers and a 16 B uniform
//! (`vk_types.FrameCapacity`: 1.9 MB at `.standard`, 5.6 MiB for three frames),
//! one atlas staging lane of `atlas.upload_bytes_frame_max`, and the three
//! atlas images at their budget sizes. Per frame the CPU copies only the used
//! prefix of each array (about 11 KiB for todo) and the atlas regions uploaded
//! since the last frame; the GPU draws at most one call per draw and per mesh.

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

/// Enable Vulkan validation layers in debug builds.
pub const enable_validation_layers = vk_instance.enable_validation_layers;

pub const frame_count_max = vk_types.frame_count_max;

const pipeline_count = vk_draw.pipeline_count;

/// The atlases the renderer samples, in descriptor binding order.
const AtlasSlot = enum(u8) { glyph, svg, image };
const atlas_slot_count: u32 = vk_descriptors.atlas_binding_count;

comptime {
    assert(@typeInfo(AtlasSlot).@"enum".field_names.len == atlas_slot_count);
}

/// Per-frame GPU resources, one set per frame in flight (two or three, from
/// the window budget's `ResourceLimits.frame`). The CPU writes frame N's
/// buffers while the GPU reads frame N-1 or N-2.
const FrameResources = struct {
    /// Host-visible storage buffers, persistently mapped; indexed by `FrameBuffer`.
    buffers: [vk_types.frame_buffer_count]vk.Buffer = @splat(null),
    mapped: [vk_types.frame_buffer_count][*]u8 = undefined,
    uniform_buffer: vk.Buffer = null,
    uniform_mapped: ?*Uniforms = null,
    descriptor_set: vk.DescriptorSet = null,
    fence: vk.Fence = null,
    image_available_semaphore: vk.Semaphore = null,
    render_finished_semaphore: vk.Semaphore = null,
    command_buffer: vk.CommandBuffer = null,
};

/// Atlas regions staged for one atlas, recorded as one barrier-copy-barrier
/// run when full and before the render pass.
const UploadBatch = struct {
    regions: [vk_atlas.copy_region_count_max]vk.BufferImageCopy = undefined,
    len: u32 = 0,
};

/// The shaders and blend mode of each packed pipeline, indexed by `Pipeline`.
const PipelineShaders = struct {
    vert: []align(4) const u8,
    frag: []align(4) const u8,
    blend: vk_pipelines.BlendMode,
};

fn spirv(comptime name: []const u8) []align(4) const u8 {
    // Vulkan requires 4-byte aligned SPIR-V.
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
    // `pipeline_shaders` is indexed by the packed pipeline's tag.
    assert(@backingInt(Pipeline.quad) == 0);
    assert(@backingInt(Pipeline.glyph) == 1);
    assert(@backingInt(Pipeline.svg) == 2);
    assert(@backingInt(Pipeline.image) == 3);
    assert(@backingInt(Pipeline.triangles) == 4);
    assert(@backingInt(Pipeline.strip_expanded) == 5);
    assert(@backingInt(Pipeline.point_instanced) == 6);
}

// =============================================================================
// VulkanRenderer
// =============================================================================

pub const VulkanRenderer = struct {
    comptime {
        backend.verifyRenderer(@This());
    }

    // Window-system objects the surface was created from; consulted again
    // around swapchain destruction.
    native_surface: ?NativeSurface = null,

    // Core Vulkan objects
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
    // `maxMemoryAllocationSize`; every reservation is checked against it.
    allocation_bytes_max: vk.DeviceSize = 0,
    // `maxStorageBufferRange`; every frame buffer is checked against it.
    storage_range_bytes_max: u64 = 0,

    // Swapchain
    swapchain: vk.Swapchain = null,
    swapchain_images: [8]vk.Image = @splat(null),
    swapchain_image_views: [8]vk.ImageView = @splat(null),
    swapchain_image_count: u32 = 0,
    swapchain_format: vk.Format = vk.VK_FORMAT_B8G8R8A8_UNORM,
    swapchain_extent: vk.Extent2D = .{ .width = 0, .height = 0 },
    swapchain_needs_recreate: bool = false,
    render_pass: vk.RenderPass = null,
    framebuffers: [8]vk.Framebuffer = @splat(null),

    // Largest framebuffer, from `ResourceLimits.window`; `resize` asserts it.
    window_limits: WindowLimits = undefined,

    // Pipelines: one layout and one descriptor layout for all of them.
    pipeline_cache: vk.PipelineCache = null,
    pipeline_layout: vk.PipelineLayout = null,
    pipelines: [pipeline_count]vk.Pipeline = @splat(null),
    descriptor_layout: vk.DescriptorSetLayout = null,
    descriptor_pool: vk.DescriptorPool = null,
    atlas_sampler: vk.Sampler = null,

    // Command pool (shared — frees all command buffers on destruction)
    command_pool: vk.CommandPool = null,

    // Declared at the ceiling; only `frame_count` are created and rotated.
    frames: [frame_count_max]FrameResources = @splat(.{}),
    frame_count: u32 = 0,
    current_frame: u32 = 0,
    // The current frame's command buffer has begun (uploads or a draw).
    recording: bool = false,

    // Memory pool for per-frame buffer sub-allocation (one vkAllocateMemory).
    host_memory_pool: vk_buffers.MemoryPool = .{},
    // Per-frame storage buffer capacities, from the window's scene limits.
    // Set once in `initInPlace`; buffers never grow.
    capacity: FrameCapacity = undefined,

    // Atlas staging: one lane of `staging_lane_bytes`
    // (`ResourceLimits.atlas.upload_bytes_frame_max`) per frame in flight.
    staging_pool: vk_buffers.MemoryPool = .{},
    staging_buffer: vk.Buffer = null,
    staging_mapped: ?[*]u8 = null,
    staging_lane_bytes: vk.DeviceSize = 0,
    staging_lane_used: vk.DeviceSize = 0,
    upload_batches: [atlas_slot_count]UploadBatch = @splat(.{}),

    // Atlas images (glyph R8, SVG and image RGBA8), indexed by `AtlasSlot`.
    atlases: [atlas_slot_count]vk_atlas.AtlasResources = @splat(.{}),

    // The last frame drawn, named in failure reports.
    frame_number: u64 = 0,
    // A frame skipped for an unusable swapchain was logged; reset on success.
    skip_logged: bool = false,

    initialized: bool = false,

    const Self = @This();

    // =========================================================================
    // Contract (§9)
    // =========================================================================

    /// Create the device, swapchain, and every buffer the window's budget
    /// needs. `surface.native` points at a `NativeSurface`, copied here; its
    /// window-system objects must outlive the renderer.
    pub fn initInPlace(
        self: *Self,
        surface: *const backend.Surface,
        limits: *const backend.RenderLimits,
    ) !void {
        assert(!self.initialized);
        assert(self.native_surface == null);
        const native: *const NativeSurface = @ptrCast(@alignCast(surface.native.?));
        assertFits(surface.size_px, &limits.window);
        // Every per-frame buffer and the staging lanes are sized from the
        // window's budget here, once, before the first frame (CLAUDE.md §2).
        self.capacity = FrameCapacity.fromSceneLimits(&limits.scene);
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

    /// Copy `pixels`, tightly packed rows of `dirty`, into the frame's staging
    /// lane and record the copy into the atlas before the next draw samples it.
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
        // Buffer-to-image copies need 4-byte aligned offsets, as the journal
        // that feeds this keeps them, so a lane holds what the journal holds.
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

    /// Render every draw of `frame` into the next swapchain image, cleared to
    /// `clear`, and present it. `viewport.size_px / viewport.scale_factor` is
    /// the frame's logical size.
    pub fn draw(
        self: *Self,
        frame: *const PackedFrame,
        viewport: backend.Viewport,
        clear: backend.Color,
    ) void {
        assert(self.initialized);
        assert(viewport.scale_factor > 0);
        assert(clear.a >= 0 and clear.a <= 1);
        self.frame_number = frame.frame_number;
        const resources = self.beginCommands();
        const cmd = resources.command_buffer;
        for (std.enums.values(AtlasSlot)) |slot| self.flushUploads(cmd, slot);

        const image_index = self.acquireImage(resources);
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
        // Reset only now that the frame is certain to be submitted: a fence
        // left unsignalled would block the next wait on it forever.
        _ = vk.vkResetFences(self.device, 1, (&resources.fence)[0..1]);
        self.submit(resources, image_index != null);
        if (image_index) |index| self.present(resources, index);
        self.recording = false;
        self.staging_lane_used = 0;
        self.current_frame = (self.current_frame + 1) % self.frame_count;
    }

    /// Rebuild the swapchain at `size_px`, within the window budget. A failed
    /// rebuild is logged; `draw` retries it and skips frames until it works.
    pub fn resize(self: *Self, size_px: backend.SizePx) void {
        assert(self.initialized);
        assertFits(size_px, &self.window_limits);
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

    // =========================================================================
    // Frame recording
    // =========================================================================

    /// The current frame's resources, its command buffer begun. The first call
    /// of a frame waits for the GPU to finish the frame that last used them.
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

    /// Record one atlas's staged regions: barrier, copies, barrier. The
    /// barriers order the copies before every later fragment shader read.
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

    /// The swapchain image to draw into, or null when there is none this
    /// frame: the swapchain is out of date or could not be rebuilt.
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
            // No image was acquired and the semaphore stays unsignalled.
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
        /// The frame's size in logical pixels, mapped onto the whole framebuffer.
        logical_width: f32,
        logical_height: f32,
    };

    /// Begin the render pass on `image_index`, then record the frame's draws
    /// over the whole framebuffer.
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

    /// Submit the frame's command buffer. With an image, it waits for the
    /// image and signals presentation; without one it carries only uploads.
    fn submit(self: *Self, frame: *const FrameResources, has_image: bool) void {
        assert(self.graphics_queue != null);
        const wait_stages = [_]u32{vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT};
        const semaphore_count: u32 = @intFromBool(has_image);
        const submit_info = vk.SubmitInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .pNext = null,
            .waitSemaphoreCount = semaphore_count,
            .pWaitSemaphores = (&frame.image_available_semaphore)[0..1],
            .pWaitDstStageMask = &wait_stages,
            .commandBufferCount = 1,
            .pCommandBuffers = (&frame.command_buffer)[0..1],
            .signalSemaphoreCount = semaphore_count,
            .pSignalSemaphores = (&frame.render_finished_semaphore)[0..1],
        };
        const result = vk.vkQueueSubmit(self.graphics_queue, 1, (&submit_info)[0..1], frame.fence);
        if (result != vk.SUCCESS) failFast("vkQueueSubmit", result);
    }

    fn present(self: *Self, frame: *const FrameResources, image_index: u32) void {
        assert(image_index < self.swapchain_image_count);
        const present_info = vk.PresentInfoKHR{
            .sType = vk.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
            .pNext = null,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = (&frame.render_finished_semaphore)[0..1],
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

    /// Fail fast on a Vulkan error the renderer cannot recover from, naming
    /// the call and the result. Unlike `unreachable`, this stops every build
    /// mode, including ReleaseFast.
    fn failFast(call: []const u8, result: vk.Result) noreturn {
        assert(call.len > 0);
        assert(!vk.succeeded(result));
        std.debug.panic("Vulkan: {s} failed with {s} ({d}); the renderer cannot recover", .{
            call,
            vk.resultName(result),
            result,
        });
    }

    // =========================================================================
    // Swapchain
    // =========================================================================

    /// A swapchain handle and one framebuffer per image. A failed rebuild
    /// leaves the framebuffers destroyed.
    fn swapchainUsable(self: *const Self) bool {
        if (self.swapchain == null) return false;
        if (self.swapchain_image_count == 0) return false;
        assert(self.swapchain_image_count <= self.framebuffers.len);
        for (self.framebuffers[0..self.swapchain_image_count]) |framebuffer| {
            if (framebuffer == null) return false;
        }
        return true;
    }

    /// Block until the GPU finishes the last submit that used `frame`.
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

    /// Wait for every frame but the one being recorded, whose fence was
    /// waited when its recording began and stays signalled until its submit.
    fn waitOtherFrames(self: *Self) void {
        assert(self.recording);
        for (self.frames[0..self.frame_count], 0..) |*frame, index| {
            if (index == self.current_frame) continue;
            self.waitFrame(frame);
        }
    }

    /// Recreate the swapchain and its framebuffers for a new extent.
    ///
    /// Nothing Gooey allocates is resized: the render pass depends only on the
    /// format, there is no multisampled target, and the swapchain images belong
    /// to the driver, bounded by the window budget and the frames in flight.
    fn recreateSwapchain(self: *Self, extent: vk.Extent2D) !void {
        assert(extent.width <= self.window_limits.framebuffer_width_max);
        assert(extent.height <= self.window_limits.framebuffer_height_max);
        vk_swapchain.destroyFramebuffers(self.device, &self.framebuffers);
        vk_swapchain.destroyImageViews(self.device, &self.swapchain_image_views);

        // Pass the old swapchain so the driver can recycle its resources.
        const old_swapchain = self.swapchain;
        const sc = try vk_swapchain.createSwapchain(
            self.device,
            self.physical_device,
            self.surface,
            extent,
            self.frame_count,
            old_swapchain,
        );
        self.swapchain = sc.swapchain;
        self.swapchain_images = sc.images;
        self.swapchain_image_views = sc.image_views;
        self.swapchain_image_count = sc.image_count;
        self.swapchain_extent = sc.extent;
        // The render pass was made for the format, which a resize keeps.
        assert(sc.format == self.swapchain_format);
        if (old_swapchain) |old| vk.vkDestroySwapchainKHR(self.device, old, null);

        try vk_swapchain.createFramebuffers(
            self.device,
            self.render_pass,
            &self.swapchain_image_views,
            self.swapchain_image_count,
            self.swapchain_extent,
            &self.framebuffers,
        );
    }

    // =========================================================================
    // Initialization and teardown, in creation order
    // =========================================================================

    /// Instance, presentation surface, physical and logical device.
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
        // The spec guarantees at least this much.
        assert(self.storage_range_bytes_max >= vk_types.storage_buffer_range_guaranteed_bytes);
        assert(self.device != null);
    }

    /// Surface → device → debug → instance (reverse creation order).
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

    /// Swapchain, render pass and framebuffers. None of them is Gooey memory:
    /// the swapchain images belong to the driver, bounded by the window budget
    /// (extent) and the frames in flight (count).
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

    /// Framebuffers, render pass, image views, then the swapchain, bracketed
    /// by the window system's teardown hooks once the device is idle.
    fn destroySwapchainTargets(self: *Self) void {
        assert(self.device != null);
        _ = vk.vkDeviceWaitIdle(self.device);
        vk_swapchain.destroyFramebuffers(self.device, &self.framebuffers);
        if (self.render_pass) |render_pass| vk.vkDestroyRenderPass(self.device, render_pass, null);
        self.render_pass = null;
        if (self.native_surface) |*native| native.swapchainDestroyBegin();
        vk_swapchain.destroyImageViews(self.device, &self.swapchain_image_views);
        if (self.swapchain) |swapchain| vk.vkDestroySwapchainKHR(self.device, swapchain, null);
        self.swapchain = null;
        self.swapchain_image_count = 0;
        if (self.native_surface) |*native| native.swapchainDestroyEnd();
    }

    /// Command pool, one command buffer and one set of sync objects per frame.
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
            frame.render_finished_semaphore = sync.render_finished_semaphores[index];
            frame.command_buffer = command_buffers.render[index];
            assert(frame.fence != null);
        }
    }

    /// Sync objects, then the pool, which frees the command buffers.
    fn destroyCommands(self: *Self) void {
        for (&self.frames) |*frame| {
            if (frame.fence) |fence| vk.vkDestroyFence(self.device, fence, null);
            frame.fence = null;
            if (frame.image_available_semaphore) |s| vk.vkDestroySemaphore(self.device, s, null);
            frame.image_available_semaphore = null;
            if (frame.render_finished_semaphore) |s| vk.vkDestroySemaphore(self.device, s, null);
            frame.render_finished_semaphore = null;
            frame.command_buffer = null;
        }
        if (self.command_pool) |pool| vk.vkDestroyCommandPool(self.device, pool, null);
        self.command_pool = null;
    }

    /// The two host-visible reservations: the per-frame storage and uniform
    /// buffers, and the atlas staging lanes. Each is one `vkAllocateMemory`,
    /// checked against the device's allocation and heap limits first.
    fn initHostReservations(self: *Self) !void {
        // `AtlasLimits.check` proved a lane holds the largest glyph or icon.
        assert(self.staging_lane_bytes > 0);
        assert(self.allocation_bytes_max > 0);
        if (self.capacity.bufferPastRange(self.storage_range_bytes_max)) |buffer| {
            std.log.err("Vulkan: frame buffer '{t}' needs {d} B (ResourceLimits.scene), past " ++
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

        // One lane per frame in flight, plus alignment slack for the buffer.
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

    /// The atlas images, created once at their budget sizes.
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

    /// Per-frame storage and uniform buffers, sub-allocated from the host pool:
    /// one `VkBuffer` each, sharing the pool's single `VkDeviceMemory`.
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

    /// Buffer handles only; the host pool owns their memory.
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

    /// The frame layout, a pool, the atlas sampler, and one set per frame
    /// written once: its buffers and the atlas images are never recreated.
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

    /// The pool frees the sets.
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

    /// The pipeline cache, the shared layout, and one pipeline per packed
    /// pipeline, indexed by its tag.
    fn createPipelines(self: *Self) !void {
        assert(self.render_pass != null);
        assert(self.descriptor_layout != null);
        // In-memory only; nothing is serialized across sessions.
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

    /// Pipelines first: they reference the layout.
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

/// The renderer's atlas for a contract atlas kind. Nothing emits colour
/// glyphs yet, so there is no colour glyph atlas to upload into.
fn atlasSlot(atlas: backend.AtlasKind) AtlasSlot {
    return switch (atlas) {
        .glyph => .glyph,
        .svg => .svg,
        .image => .image,
        .glyph_color => std.debug.panic("Vulkan: no glyph_color atlas; nothing emits colour " ++
            "glyphs yet (contract §9, phase 5)", .{}),
    };
}

/// A framebuffer size the window budget allows (`resize` and `initInPlace`).
fn assertFits(size_px: backend.SizePx, window: *const WindowLimits) void {
    assert(size_px.width > 0);
    assert(size_px.height > 0);
    assert(size_px.width <= window.framebuffer_width_max);
    assert(size_px.height <= window.framebuffer_height_max);
}

/// Logical pixels across `size_px` device pixels.
fn logicalSize(size_px: u32, scale_factor: f32) f32 {
    assert(size_px > 0);
    assert(scale_factor > 0);
    return @as(f32, @floatFromInt(size_px)) / scale_factor;
}
