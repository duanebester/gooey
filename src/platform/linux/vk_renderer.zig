//! VulkanRenderer — Vulkan rendering coordinator for Linux.
//!
//! Takes a gooey Scene and renders it using Vulkan directly.
//! Delegates to one module per subsystem:
//!   - `vk_instance`    : Instance, device, surface, debug messenger
//!   - `vk_swapchain`   : Swapchain lifecycle, render pass, framebuffers
//!   - `vk_buffers`     : Buffer, command pool, command buffer, sync object creation
//!   - `vk_descriptors` : Descriptor layouts, pool, sets, sampler, updates
//!   - `vk_pipelines`   : Generic pipeline creation
//!   - `vk_atlas`       : Atlas texture upload

const std = @import("std");
const assert = std.debug.assert;
const vk = @import("vulkan.zig");
const wayland = @import("wayland.zig");
const interface_verify = @import("../../core/interface_verify.zig");
const unified = @import("../unified.zig");
const scene_mod = @import("../../scene/mod.zig");
const text_mod = @import("../../text/mod.zig");
const svg_instance_mod = @import("../../scene/svg_instance.zig");
const image_instance_mod = @import("../../scene/image_instance.zig");
const scene_renderer = @import("scene_renderer.zig");
const geometry = @import("../../core/geometry.zig");
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
const SceneLimits = scene_mod.SceneLimits;
const limits_mod = @import("../../core/limits.zig");
const ResourceLimits = limits_mod.ResourceLimits;
const WindowLimits = limits_mod.WindowLimits;
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
// Atlas Uploads (bounded per frame)
// =============================================================================

/// The rows one atlas still owes the GPU.
///
/// `stageTextAtlas()` and friends record the CPU atlas and union its dirty
/// region in; `render()` then uploads at most one band of rows per atlas per
/// frame, and all three atlases share one staging lane of
/// `ResourceLimits.atlas.upload_bytes_frame_max` bytes. Bands advance through
/// the region and wrap, and every stage restarts the count of rows owed, so
/// each row reaches the GPU within one pass after its latest change even while
/// new glyphs keep arriving. Until then a not-yet-uploaded row samples as the
/// previous contents (or as transparent after the image was re-created).
const AtlasUpload = struct {
    /// CPU atlas pixels. Valid across frames: `Window.syncAtlases` stages
    /// before every render, and an atlas reallocates only when it grows, which
    /// bumps its generation so the new pointer is staged before the next render.
    data: []const u8 = &.{},
    width: u32 = 0,
    height: u32 = 0,
    format: vk_atlas.AtlasFormat = .r8,
    /// Union of the dirty regions staged and not yet uploaded, or null.
    region: ?vk_atlas.DirtyRegion = null,
    /// Next row of `region` to upload.
    cursor_y: u32 = 0,
    /// Rows of `region` still to upload since the latest stage.
    rows_owed: u32 = 0,
    /// A stage arrived since the last render: the image may need (re)creation.
    staged: bool = false,
    /// The image was (re)created and is cleared before its first copy.
    initialize: bool = false,

    fn pending(self: *const AtlasUpload) bool {
        if (self.region != null) assert(self.rows_owed > 0);
        return self.region != null or self.initialize or self.staged;
    }
};

/// Info needed to record a single atlas transfer into the render command buffer.
const AtlasTransferRecord = struct {
    image: vk.Image,
    copy: ?vk_atlas.StagedCopy,
    initialize: bool,
};

/// Maximum atlas transfers per frame (text + SVG + image).
const MAX_ATLAS_TRANSFERS: u32 = 3;

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
    // `initWithWaylandSurface` before any per-frame resource is created.
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

    // Atlas rows owed to the GPU — populated by stageXxxAtlas(), drained by
    // render() within the per-frame upload budget. Indexed by `AtlasKind`.
    uploads: [atlas_kind_count]AtlasUpload = @splat(.{}),
    // The atlas served first this frame; rotates so none starves the others.
    upload_rotation: u32 = 0,

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
    // Set once in `initWithWaylandSurface` before any buffer is created; read-only
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

    pub fn initWithWaylandSurface(
        self: *Self,
        wl_display: *anyopaque,
        wl_surface: *anyopaque,
        width: u32,
        height: u32,
        scale_factor: f64,
        limits: *const ResourceLimits,
    ) !void {
        std.debug.assert(!self.initialized);
        std.debug.assert(limits.check() == null);

        // Every per-frame buffer and the staging lanes are sized from the
        // window's budget here, once, before the first frame (CLAUDE.md §2).
        self.instance_capacity = InstanceCapacity.fromSceneLimits(&limits.scene);
        self.window_limits = limits.window;
        self.staging_lane_bytes = limits.atlas.upload_bytes_frame_max;
        self.frame_count = limits.frame.in_flight_count;
        assert(self.frame_count >= limits_mod.MIN_FRAMES_IN_FLIGHT);
        assert(self.frame_count <= frame_count_max);

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
        assert(self.staging_lane_bytes >= limits_mod.MAX_ATLAS_ROW_BYTES);
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
    // Atlas Upload — bounded partial transfers (no synchronous fence)
    //
    // Flow: stageXxxAtlas() records the CPU atlas and unions its dirty region
    // → render() waits the frame fence → processAtlasUploads() (re)creates
    // images and stages at most one band of rows per atlas into this frame's
    // lane → recordAtlasTransfers() records clear/copy/barriers into the render
    // command buffer.
    //
    // Resource sketch (CLAUDE.md §7): the staging buffer is one lane of
    // `ResourceLimits.atlas.upload_bytes_frame_max` per frame in flight
    // (`ResourceLimits.frame.in_flight_count`): 0.5 MiB at `.nano`, 2 MiB at
    // `.small`, 3 MiB at `.standard` (previously 144 MiB: three 4096² atlases). Per frame: at most that many
    // bytes memcpy'd, three copies, three to five barriers. Lanes are reused
    // only after the frame's fence, so CPU writes never race GPU reads.
    // =========================================================================

    /// Notify renderer that the text atlas has new data. Call before render().
    /// The data must stay valid until the atlas changes generation.
    pub fn stageTextAtlas(self: *Self, data: []const u8, width: u32, height: u32, dirty: ?vk_atlas.DirtyRegion) void {
        std.debug.assert(data.len == @as(usize, width) * @as(usize, height));
        std.debug.assert(width > 0 and height > 0);
        self.stageAtlas(.text, data, .{ .width = width, .height = height }, .r8, dirty);
    }

    /// Notify renderer that the SVG atlas has new data. Call before render().
    pub fn stageSvgAtlas(self: *Self, data: []const u8, width: u32, height: u32, dirty: ?vk_atlas.DirtyRegion) void {
        std.debug.assert(data.len == @as(usize, width) * @as(usize, height) * 4);
        std.debug.assert(width > 0 and height > 0);
        self.stageAtlas(.svg, data, .{ .width = width, .height = height }, .rgba8, dirty);
    }

    /// Notify renderer that the image atlas has new data. Call before render().
    pub fn stageImageAtlas(self: *Self, data: []const u8, width: u32, height: u32, dirty: ?vk_atlas.DirtyRegion) void {
        std.debug.assert(data.len == @as(usize, width) * @as(usize, height) * 4);
        std.debug.assert(width > 0 and height > 0);
        self.stageAtlas(.image, data, .{ .width = width, .height = height }, .rgba8, dirty);
    }

    /// Whether atlas rows are still owed to the GPU. The window keeps
    /// requesting frames until this is false, so a frame budget that splits an
    /// upload never leaves a partially uploaded atlas on screen.
    pub fn atlasUploadsPending(self: *const Self) bool {
        for (&self.uploads) |*upload| {
            if (upload.pending()) return true;
        }
        return false;
    }

    /// Record the CPU atlas and union its dirty region into the rows owed.
    /// The atlas's dirty region is cumulative since its last reset, so the
    /// union never loses rows; a size change starts over, because the image
    /// is re-created and cleared and the CPU atlas then reports itself fully
    /// dirty.
    fn stageAtlas(
        self: *Self,
        kind: AtlasKind,
        data: []const u8,
        size: vk.Extent2D,
        format: vk_atlas.AtlasFormat,
        dirty: ?vk_atlas.DirtyRegion,
    ) void {
        const upload = &self.uploads[@backingInt(kind)];
        if (upload.width != size.width or upload.height != size.height) {
            upload.region = null;
            upload.rows_owed = 0;
        }
        upload.data = data;
        upload.width = size.width;
        upload.height = size.height;
        upload.format = format;
        upload.staged = true;
        const region = dirty orelse return;
        assert(region.width > 0 and region.height > 0);
        assert(region.x + region.width <= size.width);
        assert(region.y + region.height <= size.height);
        const merged = if (upload.region) |owed| unionRegion(owed, region) else region;
        upload.region = merged;
        upload.rows_owed = merged.height;
        const cursor_inside = upload.cursor_y >= merged.y and
            upload.cursor_y < merged.y + merged.height;
        if (!cursor_inside) upload.cursor_y = merged.y;
    }

    fn unionRegion(a: vk_atlas.DirtyRegion, b: vk_atlas.DirtyRegion) vk_atlas.DirtyRegion {
        const x = @min(a.x, b.x);
        const y = @min(a.y, b.y);
        const right = @max(a.x + a.width, b.x + b.width);
        const bottom = @max(a.y + a.height, b.y + b.height);
        assert(right > x);
        assert(bottom > y);
        return .{ .x = x, .y = y, .width = right - x, .height = bottom - y };
    }

    /// Prepare every atlas for this frame and stage the rows the frame's lane
    /// has room for, rotating which atlas is served first.
    ///
    /// Must be called AFTER vkWaitForFences(current_frame) — the staging lane
    /// is only safe to write once the previous use of this frame slot is done.
    fn processAtlasUploads(
        self: *Self,
        transfers: *[MAX_ATLAS_TRANSFERS]AtlasTransferRecord,
        count: *u32,
    ) void {
        std.debug.assert(self.staging_mapped != null);
        std.debug.assert(count.* == 0);

        const lane_start = @as(vk.DeviceSize, self.current_frame) * self.staging_lane_bytes;
        const lane_end = lane_start + self.staging_lane_bytes;
        var cursor = lane_start;
        for (0..atlas_kind_count) |index| {
            const kind_index: u32 = (self.upload_rotation + @as(u32, @intCast(index))) %
                atlas_kind_count;
            const kind: AtlasKind = @fromBackingInt(@intCast(kind_index));
            const record = self.processSingleUpload(kind, &cursor, lane_end) orelse continue;
            assert(count.* < MAX_ATLAS_TRANSFERS);
            transfers[count.*] = record;
            count.* += 1;
        }
        self.upload_rotation = (self.upload_rotation + 1) % atlas_kind_count;

        // Every staged byte stayed inside this frame's lane.
        std.debug.assert(cursor >= lane_start);
        std.debug.assert(cursor <= lane_end);
    }

    /// (Re)create one atlas's image when its size changed, then stage the next
    /// band of its owed rows that fits in the lane. Returns the transfer to
    /// record, or null when this atlas has nothing to do this frame.
    fn processSingleUpload(
        self: *Self,
        kind: AtlasKind,
        cursor: *vk.DeviceSize,
        lane_end: vk.DeviceSize,
    ) ?AtlasTransferRecord {
        const upload = &self.uploads[@backingInt(kind)];
        const resources = self.atlasResources(kind);
        if (upload.staged) {
            upload.staged = false;
            assert(upload.width > 0 and upload.height > 0);
            const recreated = vk_atlas.ensureAtlasImage(
                resources,
                upload.width,
                upload.height,
                upload.format,
                self.device,
                &self.mem_properties,
            ) catch |err| {
                std.log.err("Atlas image creation failed: {}", .{err});
                return null;
            };
            if (recreated) {
                // Other frames may still reference old descriptor sets — wait for them.
                // Current frame's fence was already waited by the caller.
                self.waitOtherFrameFences();
                self.updateAllDescriptorSets(kind, resources);
                upload.initialize = true;
            }
        }
        const copy = self.stageAtlasBand(upload, cursor, lane_end);
        if (copy == null and !upload.initialize) return null;
        const record = AtlasTransferRecord{
            .image = resources.image,
            .copy = copy,
            .initialize = upload.initialize,
        };
        upload.initialize = false;
        return record;
    }

    fn atlasResources(self: *Self, kind: AtlasKind) *vk_atlas.AtlasResources {
        return switch (kind) {
            .text => &self.text_atlas,
            .svg => &self.svg_atlas,
            .image => &self.image_atlas,
        };
    }

    /// Copy the next band of owed rows that fits between `cursor` and
    /// `lane_end` into the staging buffer, and advance the band. A band never
    /// wraps within one frame; the next frame continues from the region's top.
    fn stageAtlasBand(
        self: *Self,
        upload: *AtlasUpload,
        cursor: *vk.DeviceSize,
        lane_end: vk.DeviceSize,
    ) ?vk_atlas.StagedCopy {
        const region = upload.region orelse return null;
        assert(upload.rows_owed > 0);
        assert(upload.cursor_y >= region.y);
        assert(upload.cursor_y < region.y + region.height);

        const offset = std.mem.alignForward(
            vk.DeviceSize,
            cursor.*,
            vk_atlas.STAGING_COPY_ALIGNMENT_BYTES,
        );
        if (offset >= lane_end) return null;
        const row_bytes = @as(vk.DeviceSize, region.width) * upload.format.bytesPerPixel();
        const rows_fit = (lane_end - offset) / row_bytes;
        const rows_to_bottom = region.y + region.height - upload.cursor_y;
        const rows: u32 = @intCast(@min(rows_fit, rows_to_bottom, upload.rows_owed));
        if (rows == 0) return null;

        const band = vk_atlas.DirtyRegion{
            .x = region.x,
            .y = upload.cursor_y,
            .width = region.width,
            .height = rows,
        };
        const staging_ptr: [*]u8 = @ptrCast(self.staging_mapped.?);
        const bytes = vk_atlas.stageDirtyRegion(
            staging_ptr,
            offset,
            upload.data,
            upload.width,
            upload.format,
            band,
        );
        assert(bytes == row_bytes * rows);
        assert(offset + bytes <= lane_end);
        cursor.* = offset + bytes;

        upload.cursor_y += rows;
        if (upload.cursor_y == region.y + region.height) upload.cursor_y = region.y;
        upload.rows_owed -= rows;
        if (upload.rows_owed == 0) upload.region = null;
        return .{ .staging_offset = offset, .region = band };
    }

    /// Record atlas transfer commands (barrier → clear/copy → barrier) into a
    /// command buffer. Called after vkBeginCommandBuffer, before vkCmdBeginRenderPass.
    /// Pipeline barriers guarantee transfers complete before fragment shaders read.
    fn recordAtlasTransfers(self: *const Self, cmd: vk.CommandBuffer, transfers: []const AtlasTransferRecord) void {
        std.debug.assert(cmd != null);
        for (transfers) |t| {
            std.debug.assert(t.image != null);
            vk_atlas.recordAtlasTransfer(cmd, t.image, self.staging_buffer, t.copy, t.initialize);
        }
    }

    /// Wait for all frame fences EXCEPT the current frame (already waited).
    /// Needed when (re)creating a VkImage — descriptor sets for all frames
    /// must be updated, so all frames must be idle.
    fn waitOtherFrameFences(self: *Self) void {
        std.debug.assert(self.device != null);
        for (0..self.frame_count) |i| {
            if (i != self.current_frame) {
                _ = vk.vkWaitForFences(
                    self.device,
                    1,
                    (&self.frames[i].fence)[0..1],
                    vk.TRUE,
                    std.math.maxInt(u64),
                );
            }
        }
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

        // Stage pending atlas dirty rects into per-frame staging lane.
        // MUST happen after frame fence wait — the lane is only safe to
        // overwrite once the previous GPU read from it is complete.
        var transfer_count: u32 = 0;
        var transfers: [MAX_ATLAS_TRANSFERS]AtlasTransferRecord = undefined;
        self.processAtlasUploads(&transfers, &transfer_count);

        // Acquire swapchain image
        var image_index: u32 = 0;
        switch (self.acquireNextImage(frame, &image_index)) {
            .ok => {},
            .out_of_date => return,
            .fatal => unreachable,
        }

        // Record command buffer: atlas transfers → render pass → draw
        const cmd = frame.command_buffer;
        self.recordFrame(cmd, frame, scene, image_index, transfers[0..transfer_count]);

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
        transfers: []const AtlasTransferRecord,
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
        self.recordAtlasTransfers(cmd, transfers);

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
