//! VulkanRenderer — Vulkan rendering coordinator for Linux.
//!
//! Takes a gooey Scene and renders it using Vulkan directly.
//! Delegates to extracted modules for each subsystem:
//!   - `vk_instance`    : Instance, device, surface, debug messenger
//!   - `vk_swapchain`   : Swapchain lifecycle, MSAA, render pass, framebuffers
//!   - `vk_buffers`     : Buffer, command pool, command buffer, sync object creation
//!   - `vk_descriptors` : Descriptor layouts, pool, sets, sampler, updates
//!   - `vk_pipelines`   : Generic pipeline creation (Phase 2)
//!   - `vk_atlas`       : Atlas texture upload (Phase 3)

const std = @import("std");
const vk = @import("vulkan.zig");
const wayland = @import("wayland.zig");
const interface_verify = @import("../../core/interface_verify.zig");
const unified = @import("../unified.zig");
const scene_mod = @import("../../scene/mod.zig");
const text_mod = @import("../../text/mod.zig");
const svg_instance_mod = @import("../../scene/svg_instance.zig");
const image_instance_mod = @import("../../scene/image_instance.zig");
const scene_renderer = @import("scene_renderer.zig");
pub const vk_types = @import("vk_types.zig");
const vk_pipelines = @import("vk_pipelines.zig");
const vk_atlas = @import("vk_atlas.zig");
const vk_instance = @import("vk_instance.zig");
const vk_swapchain = @import("vk_swapchain.zig");
const vk_buffers = @import("vk_buffers.zig");
const vk_descriptors = @import("vk_descriptors.zig");

const SvgInstance = svg_instance_mod.SvgInstance;
const ImageInstance = image_instance_mod.ImageInstance;

const Scene = scene_mod.Scene;
const Allocator = std.mem.Allocator;

// =============================================================================
// Configuration
// =============================================================================

/// Enable Vulkan validation layers in debug builds.
pub const enable_validation_layers = vk_instance.enable_validation_layers;

// =============================================================================
// Re-exported types and constants from vk_types.zig
// =============================================================================

pub const MAX_PRIMITIVES = vk_types.MAX_PRIMITIVES;
pub const MAX_GLYPHS = vk_types.MAX_GLYPHS;
pub const MAX_SVGS = vk_types.MAX_SVGS;
pub const MAX_IMAGES = vk_types.MAX_IMAGES;
pub const FRAME_COUNT = vk_types.FRAME_COUNT;
pub const MAX_SURFACE_FORMATS = vk_types.MAX_SURFACE_FORMATS;
pub const MAX_PRESENT_MODES = vk_types.MAX_PRESENT_MODES;

/// Host-visible memory pool size for all per-frame mapped buffers.
/// Back-of-envelope (CLAUDE.md Rule #7):
///   Per frame: 128×4096 + 64×8192 + 80×2048 + 96×1024 + 16 = 1,310,736 bytes
///   × 3 frames = 3,932,208 bytes + ~4KB alignment slack ≈ 4MB
///   Using 8MB for generous headroom.
const HOST_POOL_SIZE: vk.DeviceSize = 8 * 1024 * 1024;

pub const Uniforms = vk_types.Uniforms;
pub const GpuGlyph = vk_types.GpuGlyph;
pub const GpuSvg = vk_types.GpuSvg;
pub const GpuImage = vk_types.GpuImage;

// =============================================================================
// Per-Frame Resources (triple-buffered)
// =============================================================================

/// Per-frame GPU resources for triple-buffering.
///
/// Each frame in flight gets its own buffers, descriptor sets, sync objects,
/// and command buffer. This eliminates CPU/GPU contention: the CPU writes to
/// frame N's buffers while the GPU reads from frame N-1 or N-2.
const FrameResources = struct {
    // Storage buffers (host-visible, persistently mapped)
    primitive_buffer: vk.Buffer = null,
    primitive_memory: vk.DeviceMemory = null,
    primitive_mapped: ?*anyopaque = null,

    glyph_buffer: vk.Buffer = null,
    glyph_memory: vk.DeviceMemory = null,
    glyph_mapped: ?*anyopaque = null,

    svg_buffer: vk.Buffer = null,
    svg_memory: vk.DeviceMemory = null,
    svg_mapped: ?*anyopaque = null,

    image_buffer: vk.Buffer = null,
    image_memory: vk.DeviceMemory = null,
    image_mapped: ?*anyopaque = null,

    // Uniform buffer (host-visible, persistently mapped)
    uniform_buffer: vk.Buffer = null,
    uniform_memory: vk.DeviceMemory = null,
    uniform_mapped: ?*anyopaque = null,

    // Descriptor sets (reference this frame's buffers + shared atlas views)
    unified_descriptor_set: vk.DescriptorSet = null,
    text_descriptor_set: vk.DescriptorSet = null,
    svg_descriptor_set: vk.DescriptorSet = null,
    image_descriptor_set: vk.DescriptorSet = null,

    // Sync objects
    fence: vk.Fence = null,
    image_available_semaphore: vk.Semaphore = null,
    render_finished_semaphore: vk.Semaphore = null,

    // Command buffer
    command_buffer: vk.CommandBuffer = null,
};

// =============================================================================
// VulkanRenderer
// =============================================================================

pub const VulkanRenderer = struct {
    // Compile-time interface verification
    comptime {
        interface_verify.verifyRendererInterface(@This());
    }

    allocator: Allocator,

    // Wayland display reference (for roundtrip during cleanup)
    wl_display: ?*wayland.Display = null,

    // Core Vulkan objects
    instance: vk.Instance = null,
    debug_messenger: vk.DebugUtilsMessengerEXT = null,
    physical_device: vk.PhysicalDevice = null,
    device: vk.Device = null,
    graphics_queue: vk.Queue = null,
    present_queue: vk.Queue = null,
    surface: vk.Surface = null,

    // Queue family indices
    graphics_family: u32 = 0,
    present_family: u32 = 0,

    // Swapchain
    swapchain: vk.Swapchain = null,
    swapchain_images: [8]vk.Image = [_]vk.Image{null} ** 8,
    swapchain_image_views: [8]vk.ImageView = [_]vk.ImageView{null} ** 8,
    swapchain_image_count: u32 = 0,
    swapchain_format: c_uint = vk.VK_FORMAT_B8G8R8A8_UNORM,
    swapchain_extent: vk.Extent2D = .{ .width = 0, .height = 0 },

    // MSAA resources
    msaa_image: vk.Image = null,
    msaa_memory: vk.DeviceMemory = null,
    msaa_view: vk.ImageView = null,
    sample_count: c_uint = vk.VK_SAMPLE_COUNT_4_BIT,

    // Scale factor for HiDPI
    scale_factor: f64 = 1.0,

    // Render pass & framebuffers
    render_pass: vk.RenderPass = null,
    framebuffers: [8]vk.Framebuffer = [_]vk.Framebuffer{null} ** 8,

    // Pipeline layouts (2 shared — improvement #9: 4 → 2 handles)
    unified_pipeline_layout: vk.PipelineLayout = null,
    textured_pipeline_layout: vk.PipelineLayout = null, // shared by text, SVG, image

    // Pipeline cache (improvement #8 — amortizes shader compilation)
    pipeline_cache: vk.PipelineCache = null,

    // Pipelines
    unified_pipeline: vk.Pipeline = null,
    text_pipeline: vk.Pipeline = null,
    svg_pipeline: vk.Pipeline = null,
    image_pipeline: vk.Pipeline = null,

    // Command pool (shared — frees all command buffers on destruction)
    command_pool: vk.CommandPool = null,
    transfer_command_buffer: vk.CommandBuffer = null,

    // Transfer synchronization (shared across frames)
    transfer_fence: vk.Fence = null,
    current_frame: u32 = 0,
    swapchain_needs_recreate: bool = false,

    // Per-frame resources: buffers, descriptor sets, sync objects, command buffers.
    // Triple-buffered so CPU can write frame N+1 while GPU reads frame N.
    frames: [FRAME_COUNT]FrameResources = [_]FrameResources{.{}} ** FRAME_COUNT,

    // Staging buffer for texture uploads (shared across frames)
    staging_buffer: vk.Buffer = null,
    staging_memory: vk.DeviceMemory = null,
    staging_mapped: ?*anyopaque = null,
    staging_size: vk.DeviceSize = 0,

    // Atlas textures (text=R8, SVG/image=RGBA8)
    text_atlas: vk_atlas.AtlasResources = .{},
    svg_atlas: vk_atlas.AtlasResources = .{},
    image_atlas: vk_atlas.AtlasResources = .{},
    atlas_sampler: vk.Sampler = null,

    // Atlas dirty flags for batched upload (improvement #2)
    text_atlas_dirty: bool = false,
    svg_atlas_dirty: bool = false,
    image_atlas_dirty: bool = false,

    // Descriptors (layouts + pool shared; per-frame sets live in FrameResources)
    unified_descriptor_layout: vk.DescriptorSetLayout = null,
    textured_descriptor_layout: vk.DescriptorSetLayout = null, // shared by text, SVG, image
    descriptor_pool: vk.DescriptorPool = null,

    // Memory properties
    mem_properties: vk.PhysicalDeviceMemoryProperties = undefined,

    // Memory pool for per-frame buffer sub-allocation (1 vkAllocateMemory instead of ~15)
    host_memory_pool: vk_buffers.MemoryPool = .{},

    // CPU-side buffers (fixed capacity, no runtime allocation)
    primitives: [MAX_PRIMITIVES]unified.Primitive = undefined,
    gpu_glyphs: [MAX_GLYPHS]GpuGlyph = undefined,
    gpu_svgs: [MAX_SVGS]GpuSvg = undefined,
    gpu_images: [MAX_IMAGES]GpuImage = undefined,

    initialized: bool = false,

    const Self = @This();

    // Staging region offsets for batched atlas uploads.
    // Each atlas type gets a non-overlapping region within the pre-allocated
    // staging buffer so all three can be staged simultaneously.
    const STAGING_REGION_TEXT: vk.DeviceSize = 0;
    const STAGING_REGION_SVG: vk.DeviceSize = vk_atlas.TEXT_STAGING_BYTES;
    const STAGING_REGION_IMAGE: vk.DeviceSize = vk_atlas.TEXT_STAGING_BYTES + vk_atlas.RGBA_STAGING_BYTES;

    // Embedded SPIR-V shaders (compiled from GLSL)
    // Force 4-byte alignment as required by Vulkan for SPIR-V code
    const unified_vert_spv: []align(4) const u8 = @alignCast(@embedFile("shaders/unified.vert.spv"));
    const unified_frag_spv: []align(4) const u8 = @alignCast(@embedFile("shaders/unified.frag.spv"));
    const text_vert_spv: []align(4) const u8 = @alignCast(@embedFile("shaders/text.vert.spv"));
    const text_frag_spv: []align(4) const u8 = @alignCast(@embedFile("shaders/text.frag.spv"));
    const svg_vert_spv: []align(4) const u8 = @alignCast(@embedFile("shaders/svg.vert.spv"));
    const svg_frag_spv: []align(4) const u8 = @alignCast(@embedFile("shaders/svg.frag.spv"));
    const image_vert_spv: []align(4) const u8 = @alignCast(@embedFile("shaders/image.vert.spv"));
    const image_frag_spv: []align(4) const u8 = @alignCast(@embedFile("shaders/image.frag.spv"));

    pub fn init(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        if (!self.initialized) return;

        if (self.device) |dev| {
            _ = vk.vkDeviceWaitIdle(dev);
        }

        // Per-frame resources (buffer handles, sync objects)
        self.destroyFrameResources();

        // Host memory pool (frees the single backing VkDeviceMemory for all frame buffers)
        self.host_memory_pool.destroy(self.device);

        // Transfer fence (shared, not in FrameResources)
        if (self.transfer_fence) |fence| vk.vkDestroyFence(self.device, fence, null);
        self.transfer_fence = null;

        // Command pool (frees command buffers implicitly)
        if (self.command_pool) |pool| {
            vk.vkDestroyCommandPool(self.device, pool, null);
        }

        // Descriptors: pool frees sets implicitly, then destroy layouts
        if (self.descriptor_pool) |pool| {
            vk.vkDestroyDescriptorPool(self.device, pool, null);
        }
        self.destroyDescriptorLayouts();

        // Pipelines
        self.destroyAllPipelines();

        // Framebuffers + render pass
        vk_swapchain.destroyFramebuffers(self.device, &self.framebuffers);
        if (self.render_pass) |rp| {
            vk.vkDestroyRenderPass(self.device, rp, null);
        }

        // MSAA + swapchain image views + swapchain
        self.destroyMSAAResources();
        vk_swapchain.destroyImageViews(self.device, &self.swapchain_image_views);
        if (self.swapchain) |sc| {
            vk.vkDestroySwapchainKHR(self.device, sc, null);
        }

        // Staging buffer (shared, not in FrameResources)
        self.destroyStagingBuffer();

        // Atlas textures + sampler
        self.text_atlas.destroy(self.device);
        self.svg_atlas.destroy(self.device);
        self.image_atlas.destroy(self.device);
        if (self.atlas_sampler) |sampler| {
            vk.vkDestroySampler(self.device, sampler, null);
        }

        // Surface → device → debug → instance (reverse creation order)
        if (self.surface) |surf| {
            vk.vkDestroySurfaceKHR(self.instance, surf, null);
        }
        if (self.device) |dev| {
            vk.vkDestroyDevice(dev, null);
        }
        vk_instance.destroyDebugMessenger(self.instance, self.debug_messenger);
        if (self.instance) |inst| {
            vk.vkDestroyInstance(inst, null);
        }

        self.initialized = false;
    }

    // =========================================================================
    // Cleanup Helpers — null-safe, null-out-after-destroy
    // =========================================================================

    fn destroySwapchainResources(self: *Self) void {
        // Wait for device to be idle before destroying swapchain
        if (self.device) |dev| {
            _ = vk.vkDeviceWaitIdle(dev);
        }

        // Flush pending Wayland requests before destroying swapchain
        if (self.wl_display) |display| {
            _ = wayland.wl_display_flush(display);
            _ = wayland.wl_display_roundtrip(display);
        }

        vk_swapchain.destroyImageViews(self.device, &self.swapchain_image_views);
        if (self.swapchain) |sc| vk.vkDestroySwapchainKHR(self.device, sc, null);
        self.swapchain = null;

        // Roundtrip after destroying swapchain to process compositor release events
        //
        // NOTE: A "queue destroyed while proxies still attached" warning may still appear.
        // This is a KNOWN LIMITATION of Mesa's Vulkan Wayland WSI implementation:
        // - Mesa creates internal wl_buffer objects for each swapchain image
        // - When the swapchain is destroyed, Mesa destroys these wl_buffers
        // - The compositor may still hold references, sending wl_buffer.release later
        // - If the app exits before processing release events, the warning appears
        //
        // This warning is HARMLESS - the compositor cleans up properly regardless.
        // It's a libwayland-client debugging message, not an actual resource leak.
        // The roundtrips here minimize but cannot fully eliminate this race condition.
        if (self.wl_display) |display| {
            _ = wayland.wl_display_flush(display);
            _ = wayland.wl_display_roundtrip(display);
            _ = wayland.wl_display_roundtrip(display);
        }
    }

    fn destroyMSAAResources(self: *Self) void {
        if (self.msaa_view) |view| vk.vkDestroyImageView(self.device, view, null);
        self.msaa_view = null;
        if (self.msaa_image) |image| vk.vkDestroyImage(self.device, image, null);
        self.msaa_image = null;
        if (self.msaa_memory) |mem| vk.vkFreeMemory(self.device, mem, null);
        self.msaa_memory = null;
    }

    fn destroyFrameResources(self: *Self) void {
        for (&self.frames) |*frame| {
            // Sync objects
            if (frame.fence) |f| vk.vkDestroyFence(self.device, f, null);
            frame.fence = null;
            if (frame.image_available_semaphore) |s| vk.vkDestroySemaphore(self.device, s, null);
            frame.image_available_semaphore = null;
            if (frame.render_finished_semaphore) |s| vk.vkDestroySemaphore(self.device, s, null);
            frame.render_finished_semaphore = null;

            // Per-frame buffers — only destroy handles; memory is owned by host_memory_pool
            vk_buffers.destroyBufferOnly(self.device, frame.uniform_buffer);
            frame.uniform_buffer = null;
            frame.uniform_memory = null;
            frame.uniform_mapped = null;
            vk_buffers.destroyBufferOnly(self.device, frame.primitive_buffer);
            frame.primitive_buffer = null;
            frame.primitive_memory = null;
            frame.primitive_mapped = null;
            vk_buffers.destroyBufferOnly(self.device, frame.glyph_buffer);
            frame.glyph_buffer = null;
            frame.glyph_memory = null;
            frame.glyph_mapped = null;
            vk_buffers.destroyBufferOnly(self.device, frame.svg_buffer);
            frame.svg_buffer = null;
            frame.svg_memory = null;
            frame.svg_mapped = null;
            vk_buffers.destroyBufferOnly(self.device, frame.image_buffer);
            frame.image_buffer = null;
            frame.image_memory = null;
            frame.image_mapped = null;

            // Descriptor sets freed implicitly by pool destruction
            frame.unified_descriptor_set = null;
            frame.text_descriptor_set = null;
            frame.svg_descriptor_set = null;
            frame.image_descriptor_set = null;

            // Command buffers freed implicitly by pool destruction
            frame.command_buffer = null;
        }
    }

    fn destroyStagingBuffer(self: *Self) void {
        vk_buffers.destroyBuffer(self.device, self.staging_buffer, self.staging_memory);
        self.staging_buffer = null;
        self.staging_memory = null;
        self.staging_mapped = null;
    }

    fn destroyDescriptorLayouts(self: *Self) void {
        if (self.unified_descriptor_layout) |layout| vk.vkDestroyDescriptorSetLayout(self.device, layout, null);
        self.unified_descriptor_layout = null;
        if (self.textured_descriptor_layout) |layout| vk.vkDestroyDescriptorSetLayout(self.device, layout, null);
        self.textured_descriptor_layout = null;
    }

    fn destroyAllPipelines(self: *Self) void {
        // Destroy pipeline handles first (they reference layouts)
        vk_pipelines.destroyPipeline(self.device, self.unified_pipeline);
        self.unified_pipeline = null;
        vk_pipelines.destroyPipeline(self.device, self.text_pipeline);
        self.text_pipeline = null;
        vk_pipelines.destroyPipeline(self.device, self.svg_pipeline);
        self.svg_pipeline = null;
        vk_pipelines.destroyPipeline(self.device, self.image_pipeline);
        self.image_pipeline = null;

        // Destroy shared pipeline layouts (improvement #9: 2 instead of 4)
        if (self.unified_pipeline_layout) |l| vk.vkDestroyPipelineLayout(self.device, l, null);
        self.unified_pipeline_layout = null;
        if (self.textured_pipeline_layout) |l| vk.vkDestroyPipelineLayout(self.device, l, null);
        self.textured_pipeline_layout = null;

        // Destroy pipeline cache (improvement #8)
        // TODO: serialize cache to $XDG_CACHE_HOME/gooey/pipeline_cache.bin
        // before destroying for cross-session shader compilation reuse.
        if (self.pipeline_cache) |cache| vk.vkDestroyPipelineCache(self.device, cache, null);
        self.pipeline_cache = null;
    }

    // =========================================================================
    // Initialization
    // =========================================================================

    pub fn initWithWaylandSurface(
        self: *Self,
        wl_display: *anyopaque,
        wl_surface: *anyopaque,
        width: u32,
        height: u32,
        scale_factor: f64,
    ) !void {
        std.debug.assert(!self.initialized);

        // Store Wayland display reference for cleanup roundtrips
        self.wl_display = @ptrCast(wl_display);

        // Store scale factor
        self.scale_factor = scale_factor;

        // ---- Instance + debug messenger (vk_instance) ----
        const inst = try vk_instance.createInstance();
        self.instance = inst.instance;
        self.debug_messenger = inst.debug_messenger;
        errdefer {
            vk_instance.destroyDebugMessenger(self.instance, self.debug_messenger);
            if (self.instance) |i| vk.vkDestroyInstance(i, null);
            self.instance = null;
        }

        // ---- Wayland surface (vk_instance) ----
        self.surface = try vk_instance.createWaylandSurface(self.instance, wl_display, wl_surface);
        errdefer {
            if (self.surface) |surf| vk.vkDestroySurfaceKHR(self.instance, surf, null);
            self.surface = null;
        }

        // ---- Physical device + queue families (vk_instance) ----
        const phys = try vk_instance.pickPhysicalDevice(self.instance, self.surface);
        self.physical_device = phys.physical_device;
        self.graphics_family = phys.families.graphics;
        self.present_family = phys.families.present;

        // ---- MSAA sample count (vk_swapchain) ----
        self.sample_count = vk_swapchain.getMaxUsableSampleCount(self.physical_device);
        std.log.info("Using MSAA sample count: {}", .{self.sample_count});

        // ---- Logical device + queues (vk_instance) ----
        const dev = try vk_instance.createLogicalDevice(self.physical_device, phys.families);
        self.device = dev.device;
        self.graphics_queue = dev.graphics_queue;
        self.present_queue = dev.present_queue;
        errdefer {
            if (self.device) |d| vk.vkDestroyDevice(d, null);
            self.device = null;
        }

        // ---- Memory properties ----
        vk.vkGetPhysicalDeviceMemoryProperties(self.physical_device, &self.mem_properties);

        // Calculate physical pixel dimensions for HiDPI rendering
        const physical_width: u32 = @intFromFloat(@as(f64, @floatFromInt(width)) * scale_factor);
        const physical_height: u32 = @intFromFloat(@as(f64, @floatFromInt(height)) * scale_factor);

        // ---- Swapchain (vk_swapchain) ----
        const sc = try vk_swapchain.createSwapchain(
            self.device,
            self.physical_device,
            self.surface,
            physical_width,
            physical_height,
            null,
        );
        self.swapchain = sc.swapchain;
        self.swapchain_images = sc.images;
        self.swapchain_image_views = sc.image_views;
        self.swapchain_image_count = sc.image_count;
        self.swapchain_format = sc.format;
        self.swapchain_extent = sc.extent;
        errdefer self.destroySwapchainResources();

        // ---- MSAA resources (vk_swapchain) ----
        const msaa = try vk_swapchain.createMSAAResources(
            self.device,
            self.swapchain_format,
            self.swapchain_extent,
            self.sample_count,
            &self.mem_properties,
        );
        self.msaa_image = msaa.image;
        self.msaa_memory = msaa.memory;
        self.msaa_view = msaa.view;
        errdefer self.destroyMSAAResources();

        // ---- Render pass (vk_swapchain) ----
        self.render_pass = try vk_swapchain.createRenderPass(
            self.device,
            self.swapchain_format,
            self.sample_count,
        );
        errdefer {
            if (self.render_pass) |rp| vk.vkDestroyRenderPass(self.device, rp, null);
            self.render_pass = null;
        }

        // ---- Framebuffers (vk_swapchain) ----
        try vk_swapchain.createFramebuffers(
            self.device,
            self.render_pass,
            &self.swapchain_image_views,
            self.swapchain_image_count,
            self.msaa_view,
            self.swapchain_extent,
            self.sample_count,
            &self.framebuffers,
        );
        errdefer vk_swapchain.destroyFramebuffers(self.device, &self.framebuffers);

        // ---- Command pool + buffers (vk_buffers) ----
        self.command_pool = try vk_buffers.createCommandPool(self.device, self.graphics_family);
        errdefer {
            if (self.command_pool) |pool| vk.vkDestroyCommandPool(self.device, pool, null);
            self.command_pool = null;
        }
        const cmd_bufs = try vk_buffers.allocateCommandBuffers(self.device, self.command_pool);
        self.transfer_command_buffer = cmd_bufs.transfer;

        // ---- Synchronization objects (vk_buffers) ----
        const sync = try vk_buffers.createSyncObjects(self.device);
        self.transfer_fence = sync.transfer_fence;

        // Distribute per-frame sync objects and command buffers
        for (0..FRAME_COUNT) |i| {
            self.frames[i].fence = sync.in_flight_fences[i];
            self.frames[i].image_available_semaphore = sync.image_available_semaphores[i];
            self.frames[i].render_finished_semaphore = sync.render_finished_semaphores[i];
            self.frames[i].command_buffer = cmd_bufs.render[i];
        }
        errdefer {
            self.destroyFrameResources();
            if (self.transfer_fence) |f| vk.vkDestroyFence(self.device, f, null);
            self.transfer_fence = null;
        }

        // ---- Host memory pool (vk_buffers — 1 vkAllocateMemory instead of ~15) ----
        self.host_memory_pool = try vk_buffers.MemoryPool.init(
            self.device,
            &self.mem_properties,
            HOST_POOL_SIZE,
            vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        );
        errdefer self.host_memory_pool.destroy(self.device);

        // ---- Pre-allocate staging buffer (improvement #3 — zero mid-frame allocations) ----
        const staging_result = try vk_buffers.createMappedBuffer(
            self.device,
            &self.mem_properties,
            vk_atlas.MAX_STAGING_BYTES,
            vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
        );
        self.staging_buffer = staging_result.buffer;
        self.staging_memory = staging_result.memory;
        self.staging_mapped = staging_result.mapped;
        self.staging_size = vk_atlas.MAX_STAGING_BYTES;
        errdefer self.destroyStagingBuffer();

        // ---- Per-frame GPU buffers (sub-allocated from host pool) ----
        try self.createFrameBuffers();

        // ---- Descriptor layouts (vk_descriptors) ----
        try self.createDescriptorLayouts();
        errdefer self.destroyDescriptorLayouts();

        // ---- Descriptor pool (vk_descriptors) ----
        self.descriptor_pool = try vk_descriptors.createDescriptorPool(self.device);
        errdefer {
            if (self.descriptor_pool) |pool| vk.vkDestroyDescriptorPool(self.device, pool, null);
            self.descriptor_pool = null;
        }

        // ---- Descriptor sets (vk_descriptors) ----
        try self.allocateDescriptorSets();

        // ---- Atlas sampler (vk_descriptors) ----
        self.atlas_sampler = try vk_descriptors.createAtlasSampler(self.device);
        errdefer {
            if (self.atlas_sampler) |sampler| vk.vkDestroySampler(self.device, sampler, null);
            self.atlas_sampler = null;
        }

        // ---- Pipelines (vk_pipelines) ----
        try self.createAllPipelines();
        errdefer self.destroyAllPipelines();

        // ---- Initial descriptor writes ----
        // Uniform buffer with LOGICAL pixel dimensions
        // Scene coordinates are in logical pixels, so the shader needs logical viewport size
        // to correctly normalize to NDC. The swapchain/framebuffers use physical pixels.
        self.updateUniformBuffer(width, height);

        for (&self.frames) |*frame| {
            vk_descriptors.updateUnifiedDescriptorSet(
                self.device,
                frame.unified_descriptor_set,
                frame.primitive_buffer,
                @sizeOf(unified.Primitive) * MAX_PRIMITIVES,
                frame.uniform_buffer,
                @sizeOf(Uniforms),
            );
        }

        self.initialized = true;

        std.log.info(
            "VulkanRenderer initialized: {}x{} logical, {}x{} physical (scale: {d:.2}, MSAA: {}x)",
            .{ width, height, physical_width, physical_height, scale_factor, self.sample_count },
        );
    }

    // =========================================================================
    // Subsystem Setup — thin orchestrators calling module free functions
    // =========================================================================

    /// Create per-frame GPU buffers (uniform, primitive, glyph, SVG, image) for all frames.
    /// Each is host-visible + host-coherent for direct CPU writes.
    /// Triple-buffered: each frame gets its own set so CPU and GPU don't contend.
    /// Create per-frame GPU buffers, sub-allocated from the host memory pool.
    ///
    /// Reduces ~15 individual `vkAllocateMemory` calls to 0 (the pool's single
    /// allocation happened earlier). Each buffer gets its own VkBuffer handle
    /// but shares the pool's backing VkDeviceMemory at different offsets.
    fn createFrameBuffers(self: *Self) !void {
        for (&self.frames) |*frame| {
            const uniform = try vk_buffers.createMappedBufferFromPool(
                self.device,
                &self.host_memory_pool,
                @sizeOf(Uniforms),
                vk.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
            );
            frame.uniform_buffer = uniform.buffer;
            frame.uniform_memory = null; // Pool owns memory
            frame.uniform_mapped = uniform.mapped;

            const prim = try vk_buffers.createMappedBufferFromPool(
                self.device,
                &self.host_memory_pool,
                @sizeOf(unified.Primitive) * MAX_PRIMITIVES,
                vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
            );
            frame.primitive_buffer = prim.buffer;
            frame.primitive_memory = null; // Pool owns memory
            frame.primitive_mapped = prim.mapped;

            const glyph = try vk_buffers.createMappedBufferFromPool(
                self.device,
                &self.host_memory_pool,
                @sizeOf(GpuGlyph) * MAX_GLYPHS,
                vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
            );
            frame.glyph_buffer = glyph.buffer;
            frame.glyph_memory = null; // Pool owns memory
            frame.glyph_mapped = glyph.mapped;

            const svg = try vk_buffers.createMappedBufferFromPool(
                self.device,
                &self.host_memory_pool,
                @sizeOf(GpuSvg) * MAX_SVGS,
                vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
            );
            frame.svg_buffer = svg.buffer;
            frame.svg_memory = null; // Pool owns memory
            frame.svg_mapped = svg.mapped;

            const img = try vk_buffers.createMappedBufferFromPool(
                self.device,
                &self.host_memory_pool,
                @sizeOf(GpuImage) * MAX_IMAGES,
                vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
            );
            frame.image_buffer = img.buffer;
            frame.image_memory = null; // Pool owns memory
            frame.image_mapped = img.mapped;
        }
    }

    /// Create descriptor set layouts: one unified (no texture) + one textured (shared).
    fn createDescriptorLayouts(self: *Self) !void {
        self.unified_descriptor_layout = try vk_descriptors.createUnifiedLayout(self.device);
        errdefer {
            vk.vkDestroyDescriptorSetLayout(self.device, self.unified_descriptor_layout, null);
            self.unified_descriptor_layout = null;
        }

        // Single textured layout shared by text, SVG, and image pipelines (Phase 5).
        self.textured_descriptor_layout = try vk_descriptors.createTexturedLayout(self.device);
    }

    /// Allocate descriptor sets for all frames (4 sets per frame × FRAME_COUNT frames).
    fn allocateDescriptorSets(self: *Self) !void {
        for (&self.frames) |*frame| {
            frame.unified_descriptor_set = try vk_descriptors.allocateDescriptorSet(
                self.device,
                self.descriptor_pool,
                self.unified_descriptor_layout,
            );
            frame.text_descriptor_set = try vk_descriptors.allocateDescriptorSet(
                self.device,
                self.descriptor_pool,
                self.textured_descriptor_layout,
            );
            frame.svg_descriptor_set = try vk_descriptors.allocateDescriptorSet(
                self.device,
                self.descriptor_pool,
                self.textured_descriptor_layout,
            );
            frame.image_descriptor_set = try vk_descriptors.allocateDescriptorSet(
                self.device,
                self.descriptor_pool,
                self.textured_descriptor_layout,
            );
        }
    }

    /// Create all four graphics pipelines via the generic vk_pipelines helper.
    fn createAllPipelines(self: *Self) !void {
        std.debug.assert(self.device != null);
        std.debug.assert(self.render_pass != null);
        std.debug.assert(self.unified_descriptor_layout != null);
        std.debug.assert(self.textured_descriptor_layout != null);

        // Create pipeline cache (improvement #8 — in-memory for now).
        // TODO: load initial data from $XDG_CACHE_HOME/gooey/pipeline_cache.bin
        // for cross-session shader compilation reuse.
        self.pipeline_cache = try vk_pipelines.createPipelineCache(self.device, null);

        // Create shared pipeline layouts (improvement #9: 4 → 2 handles).
        // Unified pipeline uses its own layout; text/SVG/image share one.
        self.unified_pipeline_layout = try vk_pipelines.createPipelineLayout(
            self.device,
            self.unified_descriptor_layout,
        );
        self.textured_pipeline_layout = try vk_pipelines.createPipelineLayout(
            self.device,
            self.textured_descriptor_layout,
        );

        self.unified_pipeline = try vk_pipelines.createGraphicsPipeline(self.device, self.render_pass, self.sample_count, .{
            .vert_spv = unified_vert_spv,
            .frag_spv = unified_frag_spv,
            .pipeline_layout = self.unified_pipeline_layout,
        }, self.pipeline_cache);

        self.text_pipeline = try vk_pipelines.createGraphicsPipeline(self.device, self.render_pass, self.sample_count, .{
            .vert_spv = text_vert_spv,
            .frag_spv = text_frag_spv,
            .pipeline_layout = self.textured_pipeline_layout,
        }, self.pipeline_cache);

        self.svg_pipeline = try vk_pipelines.createGraphicsPipeline(self.device, self.render_pass, self.sample_count, .{
            .vert_spv = svg_vert_spv,
            .frag_spv = svg_frag_spv,
            .pipeline_layout = self.textured_pipeline_layout,
            .blend_mode = .premultiplied, // SVG shader outputs pre-multiplied RGB
        }, self.pipeline_cache);

        self.image_pipeline = try vk_pipelines.createGraphicsPipeline(self.device, self.render_pass, self.sample_count, .{
            .vert_spv = image_vert_spv,
            .frag_spv = image_frag_spv,
            .pipeline_layout = self.textured_pipeline_layout,
        }, self.pipeline_cache);
    }

    fn updateUniformBuffer(self: *Self, width: u32, height: u32) void {
        const uniforms = Uniforms{
            .viewport_width = @floatFromInt(width),
            .viewport_height = @floatFromInt(height),
        };
        for (&self.frames) |*frame| {
            if (frame.uniform_mapped) |ptr| {
                const dest: *Uniforms = @ptrCast(@alignCast(ptr));
                dest.* = uniforms;
            }
        }
    }

    // =========================================================================
    // Resize
    // =========================================================================

    /// Resize the renderer (recreates swapchain).
    /// width/height are logical pixels, scale_factor converts to physical pixels.
    pub fn resize(self: *Self, width: u32, height: u32, scale_factor: f64) void {
        if (!self.initialized) return;
        if (width == 0 or height == 0) return;

        // Store new scale factor
        self.scale_factor = scale_factor;

        // Calculate physical pixel dimensions
        const physical_width: u32 = @intFromFloat(@as(f64, @floatFromInt(width)) * scale_factor);
        const physical_height: u32 = @intFromFloat(@as(f64, @floatFromInt(height)) * scale_factor);

        // Wait only for our frames — not ALL GPU work (improvement #4)
        for (0..FRAME_COUNT) |i| {
            _ = vk.vkWaitForFences(self.device, 1, &self.frames[i].fence, vk.TRUE, std.math.maxInt(u64));
        }

        // Update uniform buffer with LOGICAL pixel dimensions
        self.updateUniformBuffer(width, height);

        // Recreate swapchain at physical resolution for HiDPI
        self.recreateSwapchain(physical_width, physical_height) catch |err| {
            std.debug.print("Failed to recreate swapchain: {}\n", .{err});
        };
    }

    /// Recreate swapchain and dependent resources (MSAA, framebuffers).
    ///
    /// The render pass is NOT recreated — it depends only on format and sample count,
    /// neither of which changes on resize.
    fn recreateSwapchain(self: *Self, width: u32, height: u32) !void {
        // Destroy old resources in dependency order
        vk_swapchain.destroyFramebuffers(self.device, &self.framebuffers);
        self.destroyMSAAResources();
        vk_swapchain.destroyImageViews(self.device, &self.swapchain_image_views);

        // Create new swapchain, passing old one for resource recycling
        const old_swapchain = self.swapchain;
        const sc = try vk_swapchain.createSwapchain(
            self.device,
            self.physical_device,
            self.surface,
            width,
            height,
            old_swapchain,
        );
        self.swapchain = sc.swapchain;
        self.swapchain_images = sc.images;
        self.swapchain_image_views = sc.image_views;
        self.swapchain_image_count = sc.image_count;
        self.swapchain_extent = sc.extent;
        // Format must not change on resize — assert per CLAUDE.md Rule #11
        std.debug.assert(sc.format == self.swapchain_format);

        // Destroy old swapchain after new one is created
        if (old_swapchain) |old| {
            vk.vkDestroySwapchainKHR(self.device, old, null);
        }

        // Recreate MSAA resources for new extent
        const msaa = try vk_swapchain.createMSAAResources(
            self.device,
            self.swapchain_format,
            self.swapchain_extent,
            self.sample_count,
            &self.mem_properties,
        );
        self.msaa_image = msaa.image;
        self.msaa_memory = msaa.memory;
        self.msaa_view = msaa.view;

        // Recreate framebuffers — single call replaces 45 lines of inlined copy-paste
        try vk_swapchain.createFramebuffers(
            self.device,
            self.render_pass,
            &self.swapchain_image_views,
            self.swapchain_image_count,
            self.msaa_view,
            self.swapchain_extent,
            self.sample_count,
            &self.framebuffers,
        );
    }

    // =========================================================================
    // Atlas Upload — thin wrappers delegating to vk_atlas module
    // (Phase 3: replaces 6 upload + 3 descriptor update methods with 3 wrappers)
    // =========================================================================

    /// Build a TransferContext from VulkanRenderer fields.
    /// Constructed on the stack at each call site — no heap allocation.
    fn makeTransferContext(self: *Self) vk_atlas.TransferContext {
        std.debug.assert(self.device != null);
        std.debug.assert(self.transfer_command_buffer != null);
        return .{
            .staging_buffer = &self.staging_buffer,
            .staging_memory = &self.staging_memory,
            .staging_mapped = &self.staging_mapped,
            .staging_size = &self.staging_size,
            .transfer_command_buffer = self.transfer_command_buffer,
            .transfer_fence = self.transfer_fence,
            .graphics_queue = self.graphics_queue,
            .device = self.device,
            .mem_properties = &self.mem_properties,
        };
    }

    /// Stage text atlas data for batched upload (R8 format).
    /// Pixel data is copied into a staging region; the actual GPU transfer
    /// happens in `flushAtlasUploads` (called at the start of `render`).
    pub fn uploadAtlas(self: *Self, data: []const u8, width: u32, height: u32) !void {
        if (!self.initialized) return error.NotInitialized;
        std.debug.assert(data.len == @as(usize, width) * @as(usize, height));

        var transfer = self.makeTransferContext();
        const image_recreated = try vk_atlas.prepareAtlasUpload(
            &self.text_atlas,
            data,
            width,
            height,
            .r8,
            &transfer,
            STAGING_REGION_TEXT,
        );

        self.text_atlas_dirty = true;

        if (image_recreated) {
            // Update ALL frames' descriptor sets — any frame could render next
            for (&self.frames) |*frame| {
                vk_atlas.updateAtlasDescriptorSet(
                    self.device,
                    frame.text_descriptor_set,
                    frame.glyph_buffer,
                    @sizeOf(GpuGlyph) * MAX_GLYPHS,
                    frame.uniform_buffer,
                    self.text_atlas.view,
                    self.atlas_sampler,
                );
            }
        }
    }

    /// Stage SVG atlas data for batched upload (RGBA format).
    pub fn uploadSvgAtlas(self: *Self, data: []const u8, width: u32, height: u32) !void {
        if (!self.initialized) return error.NotInitialized;
        std.debug.assert(data.len == @as(usize, width) * @as(usize, height) * 4);

        var transfer = self.makeTransferContext();
        const image_recreated = try vk_atlas.prepareAtlasUpload(
            &self.svg_atlas,
            data,
            width,
            height,
            .rgba8,
            &transfer,
            STAGING_REGION_SVG,
        );

        self.svg_atlas_dirty = true;

        if (image_recreated) {
            for (&self.frames) |*frame| {
                vk_atlas.updateAtlasDescriptorSet(
                    self.device,
                    frame.svg_descriptor_set,
                    frame.svg_buffer,
                    @sizeOf(GpuSvg) * MAX_SVGS,
                    frame.uniform_buffer,
                    self.svg_atlas.view,
                    self.atlas_sampler,
                );
            }
        }
    }

    /// Stage image atlas data for batched upload (RGBA format).
    pub fn uploadImageAtlas(self: *Self, data: []const u8, width: u32, height: u32) !void {
        if (!self.initialized) return error.NotInitialized;
        std.debug.assert(data.len == @as(usize, width) * @as(usize, height) * 4);

        var transfer = self.makeTransferContext();
        const image_recreated = try vk_atlas.prepareAtlasUpload(
            &self.image_atlas,
            data,
            width,
            height,
            .rgba8,
            &transfer,
            STAGING_REGION_IMAGE,
        );

        self.image_atlas_dirty = true;

        if (image_recreated) {
            for (&self.frames) |*frame| {
                vk_atlas.updateAtlasDescriptorSet(
                    self.device,
                    frame.image_descriptor_set,
                    frame.image_buffer,
                    @sizeOf(GpuImage) * MAX_IMAGES,
                    frame.uniform_buffer,
                    self.image_atlas.view,
                    self.atlas_sampler,
                );
            }
        }
    }

    /// Flush all pending atlas uploads in a single GPU submission.
    ///
    /// Records barrier → copy → barrier for each dirty atlas into one command
    /// buffer, then submits once and waits on one fence. This replaces up to 3
    /// sequential submit+wait cycles with a single round-trip.
    fn flushAtlasUploads(self: *Self) void {
        if (!self.text_atlas_dirty and !self.svg_atlas_dirty and !self.image_atlas_dirty) return;

        std.debug.assert(self.transfer_command_buffer != null);
        std.debug.assert(self.transfer_fence != null);
        std.debug.assert(self.staging_buffer != null);

        const cmd = self.transfer_command_buffer;
        _ = vk.vkResetCommandBuffer(cmd, 0);

        const begin_info = vk.CommandBufferBeginInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = null,
            .flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
            .pInheritanceInfo = null,
        };
        _ = vk.vkBeginCommandBuffer(cmd, &begin_info);

        if (self.text_atlas_dirty) {
            vk_atlas.recordAtlasTransfer(cmd, self.text_atlas.image, self.staging_buffer, STAGING_REGION_TEXT, self.text_atlas.width, self.text_atlas.height);
            self.text_atlas_dirty = false;
        }
        if (self.svg_atlas_dirty) {
            vk_atlas.recordAtlasTransfer(cmd, self.svg_atlas.image, self.staging_buffer, STAGING_REGION_SVG, self.svg_atlas.width, self.svg_atlas.height);
            self.svg_atlas_dirty = false;
        }
        if (self.image_atlas_dirty) {
            vk_atlas.recordAtlasTransfer(cmd, self.image_atlas.image, self.staging_buffer, STAGING_REGION_IMAGE, self.image_atlas.width, self.image_atlas.height);
            self.image_atlas_dirty = false;
        }

        _ = vk.vkEndCommandBuffer(cmd);

        // Single submit, single fence wait
        _ = vk.vkResetFences(self.device, 1, &self.transfer_fence);
        const submit_info = vk.SubmitInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .pNext = null,
            .waitSemaphoreCount = 0,
            .pWaitSemaphores = null,
            .pWaitDstStageMask = null,
            .commandBufferCount = 1,
            .pCommandBuffers = &cmd,
            .signalSemaphoreCount = 0,
            .pSignalSemaphores = null,
        };
        _ = vk.vkQueueSubmit(self.graphics_queue, 1, &submit_info, self.transfer_fence);
        _ = vk.vkWaitForFences(self.device, 1, &self.transfer_fence, vk.TRUE, std.math.maxInt(u64));
    }

    // =========================================================================
    // Render
    // =========================================================================

    /// Render a frame using batched scene renderer for proper z-ordering
    pub fn render(self: *Self, scene: *const Scene) void {
        if (!self.initialized) return;

        // Flush any pending atlas uploads (batched — single GPU round-trip)
        self.flushAtlasUploads();

        // Check if swapchain needs recreation from previous frame
        if (self.swapchain_needs_recreate) {
            self.swapchain_needs_recreate = false;
            // Wait only for our frames — not ALL GPU work (improvement #4)
            for (0..FRAME_COUNT) |i| {
                _ = vk.vkWaitForFences(self.device, 1, &self.frames[i].fence, vk.TRUE, std.math.maxInt(u64));
            }
            self.recreateSwapchain(self.swapchain_extent.width, self.swapchain_extent.height) catch |err| {
                std.debug.print("Failed to recreate swapchain: {}\n", .{err});
                return;
            };
        }

        const frame = &self.frames[self.current_frame];

        // Wait only for THIS frame's fence — the other frames are free
        _ = vk.vkWaitForFences(self.device, 1, &frame.fence, vk.TRUE, std.math.maxInt(u64));
        _ = vk.vkResetFences(self.device, 1, &frame.fence);

        // Acquire next image
        var image_index: u32 = 0;
        const acquire_result = vk.vkAcquireNextImageKHR(
            self.device,
            self.swapchain,
            std.math.maxInt(u64),
            frame.image_available_semaphore,
            null,
            &image_index,
        );

        // Handle acquire result exhaustively
        switch (acquire_result) {
            vk.SUCCESS => {},
            vk.SUBOPTIMAL_KHR => {
                self.swapchain_needs_recreate = true;
            },
            vk.ERROR_OUT_OF_DATE_KHR => {
                self.swapchain_needs_recreate = true;
                return;
            },
            vk.TIMEOUT, vk.NOT_READY => {
                std.debug.print("vkAcquireNextImageKHR returned unexpected timeout/not_ready\n", .{});
                return;
            },
            else => {
                std.debug.print("vkAcquireNextImageKHR failed with unexpected result: {}\n", .{acquire_result});
                unreachable;
            },
        }

        // Assert image index is valid
        std.debug.assert(image_index < self.swapchain_image_count);

        // Record command buffer
        const cmd = frame.command_buffer;
        _ = vk.vkResetCommandBuffer(cmd, 0);

        const begin_info = vk.CommandBufferBeginInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = null,
            .flags = 0,
            .pInheritanceInfo = null,
        };
        _ = vk.vkBeginCommandBuffer(cmd, &begin_info);

        // Begin render pass
        const clear_value = vk.clearColor(0.1, 0.1, 0.12, 1.0);
        const render_pass_info = vk.RenderPassBeginInfo{
            .sType = vk.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
            .pNext = null,
            .renderPass = self.render_pass,
            .framebuffer = self.framebuffers[image_index],
            .renderArea = .{
                .offset = .{ .x = 0, .y = 0 },
                .extent = self.swapchain_extent,
            },
            .clearValueCount = 1,
            .pClearValues = &clear_value,
        };

        vk.vkCmdBeginRenderPass(cmd, &render_pass_info, vk.VK_SUBPASS_CONTENTS_INLINE);

        // Set viewport and scissor
        const viewport = vk.makeViewport(
            @floatFromInt(self.swapchain_extent.width),
            @floatFromInt(self.swapchain_extent.height),
        );
        vk.vkCmdSetViewport(cmd, 0, 1, &viewport);

        const scissor = vk.makeScissor(self.swapchain_extent.width, self.swapchain_extent.height);
        vk.vkCmdSetScissor(cmd, 0, 1, &scissor);

        // Use batched scene renderer for proper z-ordering.
        // Per-frame descriptor sets and buffer pointers ensure no CPU/GPU contention.
        const pipelines = scene_renderer.Pipelines{
            .unified_pipeline = self.unified_pipeline,
            .unified_pipeline_layout = self.unified_pipeline_layout,
            .text_pipeline = self.text_pipeline,
            .text_pipeline_layout = self.textured_pipeline_layout,
            .svg_pipeline = self.svg_pipeline,
            .svg_pipeline_layout = self.textured_pipeline_layout,
            .image_pipeline = self.image_pipeline,
            .image_pipeline_layout = self.textured_pipeline_layout,
            .unified_descriptor_set = frame.unified_descriptor_set,
            .text_descriptor_set = frame.text_descriptor_set,
            .svg_descriptor_set = frame.svg_descriptor_set,
            .image_descriptor_set = frame.image_descriptor_set,
            .primitive_mapped = frame.primitive_mapped,
            .glyph_mapped = frame.glyph_mapped,
            .svg_mapped = frame.svg_mapped,
            .image_mapped = frame.image_mapped,
            .atlas_view = self.text_atlas.view,
            .svg_atlas_view = self.svg_atlas.view,
            .image_atlas_view = self.image_atlas.view,
        };

        _ = scene_renderer.drawScene(cmd, scene, pipelines);

        vk.vkCmdEndRenderPass(cmd);
        _ = vk.vkEndCommandBuffer(cmd);

        // Submit
        const wait_stages = [_]u32{vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT};
        const submit_info = vk.SubmitInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .pNext = null,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &frame.image_available_semaphore,
            .pWaitDstStageMask = &wait_stages,
            .commandBufferCount = 1,
            .pCommandBuffers = &cmd,
            .signalSemaphoreCount = 1,
            .pSignalSemaphores = &frame.render_finished_semaphore,
        };

        _ = vk.vkQueueSubmit(self.graphics_queue, 1, &submit_info, frame.fence);

        // Present
        const present_info = vk.PresentInfoKHR{
            .sType = vk.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
            .pNext = null,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &frame.render_finished_semaphore,
            .swapchainCount = 1,
            .pSwapchains = &self.swapchain,
            .pImageIndices = &image_index,
            .pResults = null,
        };

        const present_result = vk.vkQueuePresentKHR(self.present_queue, &present_info);

        // Handle present result exhaustively
        switch (present_result) {
            vk.SUCCESS => {},
            vk.SUBOPTIMAL_KHR => {
                self.swapchain_needs_recreate = true;
            },
            vk.ERROR_OUT_OF_DATE_KHR => {
                self.swapchain_needs_recreate = true;
            },
            else => {
                std.debug.print("vkQueuePresentKHR failed with unexpected result: {}\n", .{present_result});
                unreachable;
            },
        }

        self.current_frame = (self.current_frame + 1) % FRAME_COUNT;
    }
};
