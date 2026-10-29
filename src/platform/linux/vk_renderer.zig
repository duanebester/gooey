//! VulkanRenderer — Vulkan rendering coordinator for Linux.
//!
//! Takes a gooey Scene and renders it using Vulkan directly.
//! Delegates to one module per subsystem:
//!   - `vk_instance`    : Instance, device, debug messenger
//!   - `vk_surface`     : Window-system surface and its swapchain teardown
//!   - `vk_swapchain`   : Swapchain lifecycle, render pass, framebuffers
//!   - `vk_buffers`     : Buffer, command pool, command buffer, sync object creation
//!   - `vk_descriptors` : Descriptor layouts, pool, sets, sampler, updates
//!   - `vk_pipelines`   : Generic pipeline creation
//!   - `vk_atlas`       : Atlas texture upload

const std = @import("std");
const assert = std.debug.assert;
const vk = @import("vulkan.zig");
const interface_verify = @import("../../core/interface_verify.zig");
const unified = @import("../unified.zig");
const scene_mod = @import("../../scene/mod.zig");
const text_mod = @import("../../text/mod.zig");
const svg_instance_mod = @import("../../scene/svg_instance.zig");
const image_instance_mod = @import("../../scene/image_instance.zig");
const scene_renderer = @import("scene_renderer.zig");
const geometry = @import("../../geometry/geometry.zig");
pub const vk_types = @import("vk_types.zig");
const vk_pipelines = @import("vk_pipelines.zig");
const vk_atlas = @import("vk_atlas.zig");
const vk_instance = @import("vk_instance.zig");
const vk_swapchain = @import("vk_swapchain.zig");
const vk_buffers = @import("vk_buffers.zig");
const vk_descriptors = @import("vk_descriptors.zig");
const NativeSurface = @import("vk_surface.zig").NativeSurface;

const SvgInstance = svg_instance_mod.SvgInstance;
const ImageInstance = image_instance_mod.ImageInstance;

const Scene = scene_mod.Scene;
const SceneLimits = scene_mod.SceneLimits;
const limits_mod = @import("../../core/limits.zig");
const ResourceLimits = limits_mod.ResourceLimits;
const WindowLimits = limits_mod.WindowLimits;
const AtlasLimits = limits_mod.AtlasLimits;
const AtlasUploads = text_mod.AtlasUploads;
const AtlasUpload = text_mod.AtlasUpload;
const InstanceCapacity = vk_types.InstanceCapacity;
const Allocator = std.mem.Allocator;

// =============================================================================
// Configuration
// =============================================================================

/// Enable Vulkan validation layers in debug builds.
pub const enable_validation_layers = vk_instance.enable_validation_layers;

// =============================================================================
// Re-exported types and constants from vk_types.zig
// =============================================================================

pub const frame_count_max = vk_types.frame_count_max;
pub const MAX_SURFACE_FORMATS = vk_types.MAX_SURFACE_FORMATS;
pub const MAX_PRESENT_MODES = vk_types.MAX_PRESENT_MODES;

pub const Uniforms = vk_types.Uniforms;
pub const GpuGlyph = vk_types.GpuGlyph;
pub const GpuSvg = vk_types.GpuSvg;
pub const GpuImage = vk_types.GpuImage;

// =============================================================================
// Atlas uploads
// =============================================================================

/// The atlas journal this renderer consumes, and its consumer identity.
const AtlasSource = struct {
    uploads: *AtlasUploads,
    /// The platform window's address; registered by the framework `Window`.
    key: usize,
};

// =============================================================================
// Per-Frame Resources (one set per frame in flight)
// =============================================================================

/// Per-frame GPU resources, one set per frame in flight (two or three, from
/// the window budget's `ResourceLimits.frame`).
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

    // Queue family indices
    graphics_family: u32 = 0,
    present_family: u32 = 0,

    // Swapchain
    swapchain: vk.Swapchain = null,
    swapchain_images: [8]vk.Image = @splat(null),
    swapchain_image_views: [8]vk.ImageView = @splat(null),
    swapchain_image_count: u32 = 0,
    swapchain_format: vk.Format = vk.VK_FORMAT_B8G8R8A8_UNORM,
    swapchain_extent: vk.Extent2D = .{ .width = 0, .height = 0 },

    // Scale factor for HiDPI
    scale_factor: f64 = 1.0,

    // Largest swapchain extent, from `ResourceLimits.window`. A window larger
    // than this renders at a reduced device scale (see `fitExtent`).
    window_limits: WindowLimits = undefined,
    extent_downscaled: bool = false,

    // Framebuffer clear color, republished by `Window.renderFrame` from
    // `Window.getClearColor()` before every frame. The default only covers the
    // window's very first record, before the owner has spoken.
    clear_color: geometry.Color = geometry.Color.rgba(0.1, 0.1, 0.12, 1.0),

    // Render pass & framebuffers
    render_pass: vk.RenderPass = null,
    framebuffers: [8]vk.Framebuffer = @splat(null),

    // Pipeline layouts (2 handles; text, SVG, and image share one)
    unified_pipeline_layout: vk.PipelineLayout = null,
    textured_pipeline_layout: vk.PipelineLayout = null, // shared by text, SVG, image

    // Pipeline cache (amortizes shader compilation)
    pipeline_cache: vk.PipelineCache = null,

    // Pipelines
    unified_pipeline: vk.Pipeline = null,
    text_pipeline: vk.Pipeline = null,
    svg_pipeline: vk.Pipeline = null,
    image_pipeline: vk.Pipeline = null,

    mesh: @import("vk_mesh.zig").Renderer = .{},

    // Command pool (shared — frees all command buffers on destruction)
    command_pool: vk.CommandPool = null,

    current_frame: u32 = 0,
    swapchain_needs_recreate: bool = false,

    // Per-frame resources: buffers, descriptor sets, sync objects, command buffers.
    // One set per frame in flight so the CPU can write frame N+1 while the GPU
    // reads frame N. Declared at the ceiling; only `frame_count` are created.
    frames: [frame_count_max]FrameResources = @splat(.{}),
    // The window budget's `ResourceLimits.frame.in_flight_count`, set once in
    // `initWithNativeSurface` before any per-frame resource is created.
    frame_count: u32 = 0,

    // Staging buffer for atlas uploads: one lane of `staging_lane_bytes`
    // (`ResourceLimits.atlas.upload_bytes_frame_max`) per frame in flight.
    staging_pool: vk_buffers.MemoryPool = .{},
    staging_buffer: vk.Buffer = null,
    staging_mapped: ?*anyopaque = null,
    staging_lane_bytes: vk.DeviceSize = 0,

    // Atlas textures (text=R8, SVG/image=RGBA8)
    text_atlas: vk_atlas.AtlasResources = .{},
    svg_atlas: vk_atlas.AtlasResources = .{},
    image_atlas: vk_atlas.AtlasResources = .{},
    atlas_sampler: vk.Sampler = null,

    // Atlas journal consumed each frame, bound by the window before render().
    atlas_source: ?AtlasSource = null,

    // Descriptors (layouts + pool shared; per-frame sets live in FrameResources)
    unified_descriptor_layout: vk.DescriptorSetLayout = null,
    textured_descriptor_layout: vk.DescriptorSetLayout = null, // shared by text, SVG, image
    descriptor_pool: vk.DescriptorPool = null,

    // Memory properties
    mem_properties: vk.PhysicalDeviceMemoryProperties = undefined,

    // Memory pool for per-frame buffer sub-allocation (1 vkAllocateMemory instead of ~15)
    host_memory_pool: vk_buffers.MemoryPool = .{},

    // `maxMemoryAllocationSize`; every reservation is checked against it.
    allocation_bytes_max: vk.DeviceSize = 0,

    // Per-frame instance buffer capacities, from the window's `ResourceLimits.scene`.
    // Set once in `initWithNativeSurface` before any buffer is created; read-only
    // afterwards (buffers never grow). Meaningful only while `initialized`.
    instance_capacity: InstanceCapacity = undefined,

    initialized: bool = false,

    const Self = @This();

    /// Atlas type identifier for descriptor set routing.
    const AtlasKind = enum(u8) { text, svg, image };
    const atlas_kind_count: u32 = @typeInfo(AtlasKind).@"enum".field_names.len;

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
        self.mesh.deinit();
        self.destroyAllPipelines();

        // Framebuffers + render pass
        vk_swapchain.destroyFramebuffers(self.device, &self.framebuffers);
        if (self.render_pass) |rp| {
            vk.vkDestroyRenderPass(self.device, rp, null);
        }

        // Swapchain image views + swapchain
        vk_swapchain.destroyImageViews(self.device, &self.swapchain_image_views);
        if (self.swapchain) |sc| {
            vk.vkDestroySwapchainKHR(self.device, sc, null);
        }

        // Staging buffer (shared, not in FrameResources)
        self.destroyStagingBuffer();

        // Atlas textures + sampler
        self.destroyAtlasImages();
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

        if (self.native_surface) |native| native.swapchainDestroyBegin();

        vk_swapchain.destroyImageViews(self.device, &self.swapchain_image_views);
        if (self.swapchain) |sc| vk.vkDestroySwapchainKHR(self.device, sc, null);
        self.swapchain = null;

        if (self.native_surface) |native| native.swapchainDestroyEnd();
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
        vk_buffers.destroyBufferOnly(self.device, self.staging_buffer);
        self.staging_pool.destroy(self.device);
        self.staging_buffer = null;
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

        // Destroy shared pipeline layouts (2 handles)
        if (self.unified_pipeline_layout) |l| vk.vkDestroyPipelineLayout(self.device, l, null);
        self.unified_pipeline_layout = null;
        if (self.textured_pipeline_layout) |l| vk.vkDestroyPipelineLayout(self.device, l, null);
        self.textured_pipeline_layout = null;

        // Destroy pipeline cache
        // TODO: serialize cache to $XDG_CACHE_HOME/gooey/pipeline_cache.bin
        // before destroying for cross-session shader compilation reuse.
        if (self.pipeline_cache) |cache| vk.vkDestroyPipelineCache(self.device, cache, null);
        self.pipeline_cache = null;
    }

    // =========================================================================
    // Initialization
    // =========================================================================

    pub fn initWithNativeSurface(
        self: *Self,
        native_surface: NativeSurface,
        width: u32,
        height: u32,
        scale_factor: f64,
        limits: *const ResourceLimits,
    ) !void {
        std.debug.assert(!self.initialized);
        std.debug.assert(self.native_surface == null);
        std.debug.assert(limits.check() == null);

        // Every per-frame buffer and the staging lanes are sized from the
        // window's budget here, once, before the first frame (CLAUDE.md §2).
        self.instance_capacity = InstanceCapacity.fromSceneLimits(&limits.scene);
        self.window_limits = limits.window;
        self.staging_lane_bytes = limits.atlas.upload_bytes_frame_max;
        self.frame_count = limits.frame.in_flight_count;
        assert(self.frame_count >= limits_mod.MIN_FRAMES_IN_FLIGHT);
        assert(self.frame_count <= frame_count_max);

        // Registered first so it runs last: swapchain errdefers below still
        // bracket their teardown with it.
        self.native_surface = native_surface;
        errdefer self.native_surface = null;

        // Store scale factor
        self.scale_factor = scale_factor;

        // ---- Instance + debug messenger (vk_instance) ----
        const inst = try vk_instance.createInstance(NativeSurface.instance_extension_name);
        self.instance = inst.instance;
        self.debug_messenger = inst.debug_messenger;
        errdefer {
            vk_instance.destroyDebugMessenger(self.instance, self.debug_messenger);
            if (self.instance) |i| vk.vkDestroyInstance(i, null);
            self.instance = null;
        }

        // ---- Presentation surface (vk_surface) ----
        self.surface = try native_surface.create(self.instance);
        errdefer {
            if (self.surface) |surf| vk.vkDestroySurfaceKHR(self.instance, surf, null);
            self.surface = null;
        }

        // ---- Physical device + queue families (vk_instance) ----
        const phys = try vk_instance.pickPhysicalDevice(self.instance, self.surface);
        self.physical_device = phys.physical_device;
        self.graphics_family = phys.families.graphics;
        self.present_family = phys.families.present;

        // ---- Logical device + queues (vk_instance) ----
        const dev = try vk_instance.createLogicalDevice(self.physical_device, phys.families);
        self.device = dev.device;
        self.graphics_queue = dev.graphics_queue;
        self.present_queue = dev.present_queue;
        errdefer {
            if (self.device) |d| vk.vkDestroyDevice(d, null);
            self.device = null;
        }

        // ---- Memory properties and the single-allocation limit ----
        vk.vkGetPhysicalDeviceMemoryProperties(self.physical_device, &self.mem_properties);
        self.allocation_bytes_max = vk_buffers.queryAllocationBytesMax(self.physical_device);

        try self.initSwapchainTargets(width, height, scale_factor);
        errdefer self.destroySwapchainTargets();

        // ---- Command pool + buffers (vk_buffers) ----
        self.command_pool = try vk_buffers.createCommandPool(self.device, self.graphics_family);
        errdefer {
            if (self.command_pool) |pool| vk.vkDestroyCommandPool(self.device, pool, null);
            self.command_pool = null;
        }
        const cmd_bufs = try vk_buffers.allocateCommandBuffers(
            self.device,
            self.command_pool,
            self.frame_count,
        );

        // ---- Synchronization objects (vk_buffers) ----
        const sync = try vk_buffers.createSyncObjects(self.device, self.frame_count);

        // Distribute per-frame sync objects and command buffers
        for (0..self.frame_count) |i| {
            self.frames[i].fence = sync.in_flight_fences[i];
            self.frames[i].image_available_semaphore = sync.image_available_semaphores[i];
            self.frames[i].render_finished_semaphore = sync.render_finished_semaphores[i];
            self.frames[i].command_buffer = cmd_bufs.render[i];
        }
        errdefer self.destroyFrameResources();

        try self.initHostReservations();
        errdefer {
            self.destroyStagingBuffer();
            self.host_memory_pool.destroy(self.device);
        }

        // ---- Atlas images, created once at their budget sizes ----
        try self.createAtlasImages(&limits.atlas);
        errdefer self.destroyAtlasImages();

        // ---- Per-frame GPU buffers (sub-allocated from host pool) ----
        try self.createFrameBuffers();

        // ---- Descriptor layouts (vk_descriptors) ----
        try self.createDescriptorLayouts();
        errdefer self.destroyDescriptorLayouts();

        // ---- Descriptor pool (vk_descriptors) ----
        self.descriptor_pool = try vk_descriptors.createDescriptorPool(
            self.device,
            self.frame_count,
        );
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

        // Bind the atlas images once; they are never recreated.
        self.updateAllDescriptorSets(.text, &self.text_atlas);
        self.updateAllDescriptorSets(.svg, &self.svg_atlas);
        self.updateAllDescriptorSets(.image, &self.image_atlas);

        // ---- Pipelines (vk_pipelines) ----
        try self.createAllPipelines();
        errdefer self.destroyAllPipelines();

        try self.mesh.init(self.allocator, self.device, &self.mem_properties, &limits.scene, &.{
            .render_pass = self.render_pass,
            .cache = self.pipeline_cache,
            .frame_count = self.frame_count,
            .allocation_bytes_max = self.allocation_bytes_max,
        });
        errdefer self.mesh.deinit();

        // ---- Initial descriptor writes ----
        // Uniform buffer with LOGICAL pixel dimensions
        // Scene coordinates are in logical pixels, so the shader needs logical viewport size
        // to correctly normalize to NDC. The swapchain/framebuffers use physical pixels.
        self.updateUniformBuffer(width, height);

        for (self.frames[0..self.frame_count]) |*frame| {
            vk_descriptors.updateUnifiedDescriptorSet(
                self.device,
                frame.unified_descriptor_set,
                frame.primitive_buffer,
                self.instance_capacity.bufferBytes(.primitives),
                frame.uniform_buffer,
                @sizeOf(Uniforms),
            );
        }

        self.initialized = true;

        std.log.info(
            "VulkanRenderer initialized: {}x{} logical, {}x{} physical (scale: {d:.2}), " ++
                "1 sample per pixel, frames in flight: {d}, swapchain images: {d}, " ++
                "atlas staging {d} B",
            .{
                width,
                height,
                self.swapchain_extent.width,
                self.swapchain_extent.height,
                scale_factor,
                self.frame_count,
                self.swapchain_image_count,
                self.staging_pool.size,
            },
        );
    }

    /// Swapchain, render pass and framebuffers. None of them is Gooey memory:
    /// the swapchain images belong to the driver, bounded by the window budget
    /// (extent) and the frames in flight (count).
    fn initSwapchainTargets(self: *Self, width: u32, height: u32, scale_factor: f64) !void {
        assert(self.device != null);
        assert(self.swapchain == null);
        const sc = try vk_swapchain.createSwapchain(
            self.device,
            self.physical_device,
            self.surface,
            self.fitExtent(width, height, scale_factor),
            self.frame_count,
            null,
        );
        self.swapchain = sc.swapchain;
        self.swapchain_images = sc.images;
        self.swapchain_image_views = sc.image_views;
        self.swapchain_image_count = sc.image_count;
        self.swapchain_format = sc.format;
        self.swapchain_extent = sc.extent;
        errdefer self.destroySwapchainResources();

        self.render_pass = try vk_swapchain.createRenderPass(self.device, self.swapchain_format);
        errdefer {
            if (self.render_pass) |rp| vk.vkDestroyRenderPass(self.device, rp, null);
            self.render_pass = null;
        }

        errdefer vk_swapchain.destroyFramebuffers(self.device, &self.framebuffers);
        try vk_swapchain.createFramebuffers(
            self.device,
            self.render_pass,
            &self.swapchain_image_views,
            self.swapchain_image_count,
            self.swapchain_extent,
            &self.framebuffers,
        );
    }

    /// Undo `initSwapchainTargets` during a failed initialization.
    fn destroySwapchainTargets(self: *Self) void {
        vk_swapchain.destroyFramebuffers(self.device, &self.framebuffers);
        if (self.render_pass) |rp| vk.vkDestroyRenderPass(self.device, rp, null);
        self.render_pass = null;
        self.destroySwapchainResources();
    }

    /// The two host-visible reservations besides the mesh pools: the per-frame
    /// instance and uniform buffers, and the atlas staging lanes. Each is one
    /// `vkAllocateMemory`, checked against the device's allocation and heap
    /// limits before it is made.
    fn initHostReservations(self: *Self) !void {
        // `AtlasLimits.check` proved a lane holds the largest glyph or icon.
        assert(self.staging_lane_bytes > 0);
        assert(self.allocation_bytes_max > 0);
        const host_visible = vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
            vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
        const host_pool = &self.host_memory_pool;
        host_pool.* = try vk_buffers.MemoryPool.init(self.device, &self.mem_properties, &.{
            .name = "instance and uniform buffers",
            .size = self.instance_capacity.hostPoolBytes(self.frame_count),
            .allocation_bytes_max = self.allocation_bytes_max,
            .required_properties = host_visible,
        });
        errdefer self.host_memory_pool.destroy(self.device);

        // One lane per frame in flight, plus alignment slack for the buffer.
        assert(self.frame_count >= limits_mod.MIN_FRAMES_IN_FLIGHT);
        const staging_bytes = @as(vk.DeviceSize, self.frame_count) * self.staging_lane_bytes;
        self.staging_pool = try vk_buffers.MemoryPool.init(self.device, &self.mem_properties, &.{
            .name = "atlas staging",
            .size = staging_bytes + vk_types.host_pool_alignment_slack_bytes,
            .allocation_bytes_max = self.allocation_bytes_max,
            .required_properties = host_visible,
        });
        errdefer self.staging_pool.destroy(self.device);
        const staging = try vk_buffers.createMappedBufferFromPool(
            self.device,
            &self.staging_pool,
            staging_bytes,
            vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
        );
        self.staging_buffer = staging.buffer;
        self.staging_mapped = staging.mapped;
    }

    // =========================================================================
    // Subsystem Setup — thin orchestrators calling module free functions
    // =========================================================================

    /// Create per-frame GPU buffers (uniform, primitive, glyph, SVG, image) for all frames.
    /// Each is host-visible + host-coherent for direct CPU writes.
    /// One set per frame in flight so CPU and GPU don't contend.
    /// Create per-frame GPU buffers, sub-allocated from the host memory pool.
    ///
    /// Reduces ~15 individual `vkAllocateMemory` calls to 0 (the pool's single
    /// allocation happened earlier). Each buffer gets its own VkBuffer handle
    /// but shares the pool's backing VkDeviceMemory at different offsets.
    fn createFrameBuffers(self: *Self) !void {
        std.debug.assert(self.host_memory_pool.offset == 0);
        std.debug.assert(
            self.host_memory_pool.size == self.instance_capacity.hostPoolBytes(self.frame_count),
        );
        for (self.frames[0..self.frame_count]) |*frame| {
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
                self.instance_capacity.bufferBytes(.primitives),
                vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
            );
            frame.primitive_buffer = prim.buffer;
            frame.primitive_memory = null; // Pool owns memory
            frame.primitive_mapped = prim.mapped;

            const glyph = try vk_buffers.createMappedBufferFromPool(
                self.device,
                &self.host_memory_pool,
                self.instance_capacity.bufferBytes(.glyphs),
                vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
            );
            frame.glyph_buffer = glyph.buffer;
            frame.glyph_memory = null; // Pool owns memory
            frame.glyph_mapped = glyph.mapped;

            const svg = try vk_buffers.createMappedBufferFromPool(
                self.device,
                &self.host_memory_pool,
                self.instance_capacity.bufferBytes(.svgs),
                vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
            );
            frame.svg_buffer = svg.buffer;
            frame.svg_memory = null; // Pool owns memory
            frame.svg_mapped = svg.mapped;

            const img = try vk_buffers.createMappedBufferFromPool(
                self.device,
                &self.host_memory_pool,
                self.instance_capacity.bufferBytes(.images),
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

        // Single textured layout shared by text, SVG, and image pipelines.
        self.textured_descriptor_layout = try vk_descriptors.createTexturedLayout(self.device);
    }

    /// Allocate descriptor sets for all frames (4 sets per frame × `frame_count` frames).
    fn allocateDescriptorSets(self: *Self) !void {
        for (self.frames[0..self.frame_count]) |*frame| {
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

        // Create pipeline cache (in-memory only).
        // TODO: load initial data from $XDG_CACHE_HOME/gooey/pipeline_cache.bin
        // for cross-session shader compilation reuse.
        self.pipeline_cache = try vk_pipelines.createPipelineCache(self.device, null);

        // Create shared pipeline layouts (2 handles).
        // Unified pipeline uses its own layout; text/SVG/image share one.
        self.unified_pipeline_layout = try vk_pipelines.createPipelineLayout(
            self.device,
            self.unified_descriptor_layout,
        );
        self.textured_pipeline_layout = try vk_pipelines.createPipelineLayout(
            self.device,
            self.textured_descriptor_layout,
        );

        const device = self.device;
        const render_pass = self.render_pass;
        self.unified_pipeline = try vk_pipelines.createGraphicsPipeline(device, render_pass, .{
            .vert_spv = unified_vert_spv,
            .frag_spv = unified_frag_spv,
            .pipeline_layout = self.unified_pipeline_layout,
        }, self.pipeline_cache);

        self.text_pipeline = try vk_pipelines.createGraphicsPipeline(device, render_pass, .{
            .vert_spv = text_vert_spv,
            .frag_spv = text_frag_spv,
            .pipeline_layout = self.textured_pipeline_layout,
        }, self.pipeline_cache);

        self.svg_pipeline = try vk_pipelines.createGraphicsPipeline(device, render_pass, .{
            .vert_spv = svg_vert_spv,
            .frag_spv = svg_frag_spv,
            .pipeline_layout = self.textured_pipeline_layout,
            .blend_mode = .premultiplied, // SVG shader outputs pre-multiplied RGB
        }, self.pipeline_cache);

        self.image_pipeline = try vk_pipelines.createGraphicsPipeline(device, render_pass, .{
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

    /// Set the color the render pass clears the framebuffer to.
    ///
    /// Recorded into the next command buffer rather than applied immediately:
    /// frames in flight must keep the clear they were recorded with.
    pub fn setClearColor(self: *Self, color: geometry.Color) void {
        std.debug.assert(color.a >= 0.0);
        std.debug.assert(color.a <= 1.0);

        self.clear_color = color;
    }

    /// Resize the renderer (recreates swapchain).
    /// width/height are logical pixels, scale_factor converts to physical pixels.
    pub fn resize(self: *Self, width: u32, height: u32, scale_factor: f64) void {
        if (!self.initialized) return;
        if (width == 0 or height == 0) return;

        // Store new scale factor
        self.scale_factor = scale_factor;

        // Wait only for our frames — not ALL GPU work
        for (0..self.frame_count) |i| {
            _ = vk.vkWaitForFences(
                self.device,
                1,
                (&self.frames[i].fence)[0..1],
                vk.TRUE,
                std.math.maxInt(u64),
            );
        }

        // Update uniform buffer with LOGICAL pixel dimensions
        self.updateUniformBuffer(width, height);

        // Recreate swapchain at physical resolution for HiDPI
        self.recreateSwapchain(self.fitExtent(width, height, scale_factor)) catch |err| {
            std.debug.print("Failed to recreate swapchain: {}\n", .{err});
        };
    }

    /// Physical swapchain extent for a logical size: the scale factor, lowered
    /// uniformly when the window would exceed `ResourceLimits.window`. The
    /// compositor scales the smaller buffer up through the window's viewport
    /// (wp_viewporter), as the CPU backend does. Logged once per transition.
    fn fitExtent(self: *Self, width: u32, height: u32, scale_factor: f64) vk.Extent2D {
        assert(width > 0 and height > 0);
        assert(scale_factor > 0);
        const width_f: f64 = @floatFromInt(width);
        const height_f: f64 = @floatFromInt(height);
        const width_max: f64 = @floatFromInt(self.window_limits.framebuffer_width_max);
        const height_max: f64 = @floatFromInt(self.window_limits.framebuffer_height_max);
        const scale = @min(scale_factor, width_max / width_f, height_max / height_f);
        const extent = vk.Extent2D{
            .width = @max(1, @as(u32, @intFromFloat(width_f * scale))),
            .height = @max(1, @as(u32, @intFromFloat(height_f * scale))),
        };
        const downscaled = scale < scale_factor;
        if (downscaled and !self.extent_downscaled) {
            std.log.warn(
                "Vulkan: a {d}x{d} window at scale {d} exceeds ResourceLimits.window " ++
                    "({d}x{d} px); rendering at scale {d}",
                .{ width, height, scale_factor, width_max, height_max, scale },
            );
        }
        self.extent_downscaled = downscaled;
        assert(extent.width <= self.window_limits.framebuffer_width_max);
        assert(extent.height <= self.window_limits.framebuffer_height_max);
        return extent;
    }

    /// Recreate the swapchain and its framebuffers for a new extent.
    ///
    /// Nothing Gooey allocates is resized: the render pass depends only on the
    /// format, there is no multisampled target, and the swapchain images belong
    /// to the driver, bounded by the window budget and the frames in flight.
    fn recreateSwapchain(self: *Self, extent: vk.Extent2D) !void {
        assert(extent.width <= self.window_limits.framebuffer_width_max);
        assert(extent.height <= self.window_limits.framebuffer_height_max);
        // Destroy old resources in dependency order
        vk_swapchain.destroyFramebuffers(self.device, &self.framebuffers);
        vk_swapchain.destroyImageViews(self.device, &self.swapchain_image_views);

        // Create new swapchain, passing old one for resource recycling
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
        // Format must not change on resize — assert per CLAUDE.md Rule #11
        std.debug.assert(sc.format == self.swapchain_format);

        // Destroy old swapchain after new one is created
        if (old_swapchain) |old| {
            vk.vkDestroySwapchainKHR(self.device, old, null);
        }

        // Recreate framebuffers through the shared helper rather than inline copies
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
    // Atlas Upload — journal records staged per frame (no synchronous fence)
    //
    // Flow: the window binds the shared `AtlasUploads` journal → render() waits
    // the frame fence and acquires an image → recordAtlasUploads() copies the
    // records this window has not uploaded into the frame's staging lane and
    // records barrier → copies → barrier per atlas into the render cmd buf.
    //
    // No CPU copy of atlas pixels exists: the journal holds only this frame's
    // rasterized items (bounded by `AtlasLimits.upload_bytes_frame_max`), and
    // each lane holds one journal's worth.
    // =========================================================================

    /// Bind the atlas journal this renderer consumes. Call before render().
    pub fn bindAtlasUploads(self: *Self, uploads: *AtlasUploads, key: usize) void {
        std.debug.assert(key != 0);
        std.debug.assert(uploads.storage == .gpu_upload);
        self.atlas_source = .{ .uploads = uploads, .key = key };
    }

    /// True when the journal holds records this window has not uploaded, such
    /// as glyphs another window placed in the shared atlases.
    pub fn hasPendingAtlasUploads(self: *const Self) bool {
        const source = self.atlas_source orelse return false;
        std.debug.assert(source.key != 0);
        return source.uploads.hasPending(source.key);
    }

    fn createAtlasImages(self: *Self, limits: *const AtlasLimits) !void {
        std.debug.assert(self.device != null);
        std.debug.assert(self.text_atlas.image == null);
        errdefer self.destroyAtlasImages();
        try vk_atlas.createAtlas(
            &self.text_atlas,
            limits.text_size,
            .r8,
            self.device,
            &self.mem_properties,
        );
        try vk_atlas.createAtlas(
            &self.svg_atlas,
            limits.svg_size,
            .rgba8,
            self.device,
            &self.mem_properties,
        );
        try vk_atlas.createAtlas(
            &self.image_atlas,
            limits.image_size,
            .rgba8,
            self.device,
            &self.mem_properties,
        );
    }

    fn destroyAtlasImages(self: *Self) void {
        self.text_atlas.destroy(self.device);
        self.svg_atlas.destroy(self.device);
        self.image_atlas.destroy(self.device);
    }

    /// Stage the journal records this window has not uploaded into the current
    /// frame's lane and record their copies. Must run after the frame fence wait
    /// (the lane is free) and after a successful acquire (the frame is
    /// submitted, so consumed records are never lost).
    fn recordAtlasUploads(self: *Self, cmd: vk.CommandBuffer) void {
        std.debug.assert(cmd != null);
        const source = self.atlas_source orelse return;
        const pending = source.uploads.consumeBegin(source.key);
        defer source.uploads.consumeEnd(source.key);
        if (pending.records.len == 0) return;

        const lane_bytes = self.staging_lane_bytes;
        const lane_start = @as(vk.DeviceSize, self.current_frame) * lane_bytes;
        std.debug.assert(pending.bytes.len <= lane_bytes);
        const staging: [*]u8 = @ptrCast(self.staging_mapped orelse return);
        @memcpy(staging[@intCast(lane_start)..][0..pending.bytes.len], pending.bytes);

        self.recordAtlasKind(cmd, &self.text_atlas, .text, pending.records, lane_start);
        self.recordAtlasKind(cmd, &self.svg_atlas, .svg, pending.records, lane_start);
        self.recordAtlasKind(cmd, &self.image_atlas, .image, pending.records, lane_start);
    }

    /// Record one atlas's copies from `records`, batching regions on the stack.
    fn recordAtlasKind(
        self: *const Self,
        cmd: vk.CommandBuffer,
        resources: *vk_atlas.AtlasResources,
        kind: text_mod.AtlasKind,
        records: []const AtlasUpload,
        lane_start: vk.DeviceSize,
    ) void {
        std.debug.assert(resources.image != null);
        var count: usize = 0;
        for (records) |record| {
            if (record.kind == kind) count += 1;
        }
        if (count == 0) return;
        // Regions are recorded in batches; each batch is one barrier-free run
        // of non-overlapping copies inside a single transfer scope.
        var batch: [vk_atlas.copy_region_count_max]vk.BufferImageCopy = undefined;
        var batch_len: usize = 0;
        for (records) |record| {
            if (record.kind != kind) continue;
            std.debug.assert(@as(u32, record.x) + record.width <= resources.width);
            std.debug.assert(@as(u32, record.y) + record.height <= resources.height);
            batch[batch_len] = vk_atlas.copyRegion(
                lane_start + record.offset,
                record.x,
                record.y,
                record.width,
                record.height,
            );
            batch_len += 1;
            if (batch_len == batch.len) {
                vk_atlas.recordAtlasCopies(
                    cmd,
                    resources,
                    self.staging_buffer,
                    batch[0..batch_len],
                );
                batch_len = 0;
            }
        }
        vk_atlas.recordAtlasCopies(cmd, resources, self.staging_buffer, batch[0..batch_len]);
        std.debug.assert(resources.layout_ready);
    }

    /// Update all frames' descriptor sets for a given atlas kind.
    /// Called after VkImage (re)creation — the new image view must be bound.
    fn updateAllDescriptorSets(self: *Self, kind: AtlasKind, resources: *const vk_atlas.AtlasResources) void {
        std.debug.assert(self.device != null);
        std.debug.assert(resources.view != null);
        for (self.frames[0..self.frame_count]) |*frame| {
            switch (kind) {
                .text => vk_atlas.updateAtlasDescriptorSet(
                    self.device,
                    frame.text_descriptor_set,
                    frame.glyph_buffer,
                    self.instance_capacity.bufferBytes(.glyphs),
                    frame.uniform_buffer,
                    resources.view,
                    self.atlas_sampler,
                ),
                .svg => vk_atlas.updateAtlasDescriptorSet(
                    self.device,
                    frame.svg_descriptor_set,
                    frame.svg_buffer,
                    self.instance_capacity.bufferBytes(.svgs),
                    frame.uniform_buffer,
                    resources.view,
                    self.atlas_sampler,
                ),
                .image => vk_atlas.updateAtlasDescriptorSet(
                    self.device,
                    frame.image_descriptor_set,
                    frame.image_buffer,
                    self.instance_capacity.bufferBytes(.images),
                    frame.uniform_buffer,
                    resources.view,
                    self.atlas_sampler,
                ),
            }
        }
    }

    // =========================================================================
    // Render
    // =========================================================================

    /// Render a frame: atlas transfers + scene draw in a single command buffer.
    ///
    /// Atlas transfers (barrier → copy → barrier) are recorded BEFORE the
    /// render pass. Pipeline barriers guarantee the copies complete before
    /// fragment shaders read from the atlas textures — no extra fence needed.
    pub fn render(self: *Self, scene: *const Scene) void {
        if (!self.initialized) return;
        assertSceneFitsCapacity(&scene.limits, &self.instance_capacity);

        // Check if swapchain needs recreation from previous frame
        if (self.swapchain_needs_recreate) {
            self.swapchain_needs_recreate = false;
            for (0..self.frame_count) |i| {
                _ = vk.vkWaitForFences(
                    self.device,
                    1,
                    (&self.frames[i].fence)[0..1],
                    vk.TRUE,
                    std.math.maxInt(u64),
                );
            }
            self.recreateSwapchain(self.swapchain_extent) catch |err| {
                std.debug.print("Failed to recreate swapchain: {}\n", .{err});
                return;
            };
        }

        const frame = &self.frames[self.current_frame];

        // Wait only for THIS frame's fence — GPU is done reading this
        // frame's staging lane and command buffer.
        _ = vk.vkWaitForFences(self.device, 1, (&frame.fence)[0..1], vk.TRUE, std.math.maxInt(u64));
        _ = vk.vkResetFences(self.device, 1, (&frame.fence)[0..1]);

        // Acquire swapchain image
        var image_index: u32 = 0;
        switch (self.acquireNextImage(frame, &image_index)) {
            .ok => {},
            .out_of_date => return,
            .fatal => unreachable,
        }

        // Record command buffer: atlas transfers → render pass → draw
        const cmd = frame.command_buffer;
        self.recordFrame(cmd, frame, scene, image_index);

        // Submit + present
        self.submitAndPresent(cmd, frame, image_index);

        self.current_frame = (self.current_frame + 1) % self.frame_count;
    }

    /// The renderer never truncates a frame, so the scene it draws must not be
    /// able to outgrow the buffers sized at init: the window's scenes and its
    /// renderer share one budget. A larger scene budget is a programmer error.
    fn assertSceneFitsCapacity(
        scene_limits: *const SceneLimits,
        capacity: *const InstanceCapacity,
    ) void {
        std.debug.assert(scene_limits.unifiedPrimitiveCountMax() <= capacity.primitive_count_max);
        std.debug.assert(scene_limits.glyph_count_frame_max <= capacity.glyph_count_max);
        std.debug.assert(scene_limits.svg_count_frame_max <= capacity.svg_count_max);
        std.debug.assert(scene_limits.image_count_frame_max <= capacity.image_count_max);
    }

    const AcquireResult = enum { ok, out_of_date, fatal };

    /// Acquire the next swapchain image. Returns `.out_of_date` if the
    /// swapchain needs recreation (caller should skip this frame).
    fn acquireNextImage(self: *Self, frame: *const FrameResources, image_index: *u32) AcquireResult {
        const result = vk.vkAcquireNextImageKHR(
            self.device,
            self.swapchain,
            std.math.maxInt(u64),
            frame.image_available_semaphore,
            null,
            image_index,
        );
        switch (result) {
            vk.SUCCESS => return .ok,
            vk.SUBOPTIMAL_KHR => {
                self.swapchain_needs_recreate = true;
                return .ok;
            },
            vk.ERROR_OUT_OF_DATE_KHR => {
                self.swapchain_needs_recreate = true;
                return .out_of_date;
            },
            vk.TIMEOUT, vk.NOT_READY => {
                std.debug.print("vkAcquireNextImageKHR returned unexpected timeout/not_ready\n", .{});
                return .out_of_date;
            },
            else => {
                std.debug.print("vkAcquireNextImageKHR failed: {}\n", .{result});
                return .fatal;
            },
        }
    }

    /// Record the full frame command buffer: atlas transfers + render pass + scene draw.
    fn recordFrame(
        self: *Self,
        cmd: vk.CommandBuffer,
        frame: *const FrameResources,
        scene: *const Scene,
        image_index: u32,
    ) void {
        std.debug.assert(cmd != null);
        std.debug.assert(image_index < self.swapchain_image_count);

        _ = vk.vkResetCommandBuffer(cmd, 0);
        const begin_info = vk.CommandBufferBeginInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = null,
            .flags = 0,
            .pInheritanceInfo = null,
        };
        _ = vk.vkBeginCommandBuffer(cmd, &begin_info);

        // Atlas transfers: barrier → copy → barrier BEFORE render pass.
        // VK_PIPELINE_STAGE_TRANSFER_BIT → VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT
        // guarantees the copy finishes before any fragment shader reads.
        self.recordAtlasUploads(cmd);

        // Begin render pass
        const clear_value = vk.clearColor(
            self.clear_color.r,
            self.clear_color.g,
            self.clear_color.b,
            self.clear_color.a,
        );
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
            .pClearValues = (&clear_value)[0..1],
        };
        vk.vkCmdBeginRenderPass(cmd, &render_pass_info, vk.VK_SUBPASS_CONTENTS_INLINE);

        // Viewport + scissor
        const viewport = vk.makeViewport(
            @floatFromInt(self.swapchain_extent.width),
            @floatFromInt(self.swapchain_extent.height),
        );
        vk.vkCmdSetViewport(cmd, 0, 1, (&viewport)[0..1]);
        const scissor = vk.makeScissor(self.swapchain_extent.width, self.swapchain_extent.height);
        vk.vkCmdSetScissor(cmd, 0, 1, (&scissor)[0..1]);

        // Draw scene with per-frame descriptor sets and buffer pointers
        const pipelines = scene_renderer.Pipelines{
            .mesh = &self.mesh,
            .mesh_frame = &self.mesh.frames[self.current_frame],
            .uniform_buffer = frame.uniform_buffer,
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
            .capacity = self.instance_capacity,
            .frame = scene.frame_count_finished,
        };
        _ = scene_renderer.drawScene(cmd, scene, &pipelines);

        vk.vkCmdEndRenderPass(cmd);
        _ = vk.vkEndCommandBuffer(cmd);
    }

    /// Submit the recorded command buffer and present the frame.
    fn submitAndPresent(self: *Self, cmd: vk.CommandBuffer, frame: *const FrameResources, image_index: u32) void {
        std.debug.assert(cmd != null);
        std.debug.assert(self.graphics_queue != null);

        const wait_stages = [_]u32{vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT};
        const submit_info = vk.SubmitInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .pNext = null,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = (&frame.image_available_semaphore)[0..1],
            .pWaitDstStageMask = &wait_stages,
            .commandBufferCount = 1,
            .pCommandBuffers = (&cmd)[0..1],
            .signalSemaphoreCount = 1,
            .pSignalSemaphores = (&frame.render_finished_semaphore)[0..1],
        };
        _ = vk.vkQueueSubmit(self.graphics_queue, 1, (&submit_info)[0..1], frame.fence);

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
        const present_result = vk.vkQueuePresentKHR(self.present_queue, &present_info);
        switch (present_result) {
            vk.SUCCESS => {},
            vk.SUBOPTIMAL_KHR, vk.ERROR_OUT_OF_DATE_KHR => {
                self.swapchain_needs_recreate = true;
            },
            else => {
                std.debug.print("vkQueuePresentKHR failed: {}\n", .{present_result});
                unreachable;
            },
        }
    }
};
