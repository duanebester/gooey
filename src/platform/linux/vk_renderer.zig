//! VulkanRenderer - Direct Vulkan rendering for Linux
//!
//! Takes a gooey Scene and renders it using Vulkan directly.
//! This replaces the wgpu-native approach for better control and stability.

const std = @import("std");
const vk = @import("vulkan.zig");
const wayland = @import("wayland.zig");
const interface_verify = @import("../../core/interface_verify.zig");
const unified = @import("../wgpu/unified.zig");
const scene_mod = @import("../../scene/mod.zig");
const text_mod = @import("../../text/mod.zig");
const svg_instance_mod = @import("../../scene/svg_instance.zig");
const image_instance_mod = @import("../../scene/image_instance.zig");
const scene_renderer = @import("scene_renderer.zig");

const SvgInstance = svg_instance_mod.SvgInstance;
const ImageInstance = image_instance_mod.ImageInstance;

const Scene = scene_mod.Scene;
const Allocator = std.mem.Allocator;

// =============================================================================
// Configuration
// =============================================================================

/// Enable Vulkan validation layers in debug builds.
/// Set to true to enable VK_LAYER_KHRONOS_validation for API error checking.
/// This adds runtime overhead but catches many common Vulkan usage errors.
pub const enable_validation_layers = @import("builtin").mode == .Debug;

// =============================================================================
// Constants
// =============================================================================

pub const MAX_PRIMITIVES: u32 = 4096;
pub const MAX_GLYPHS: u32 = 8192;
pub const MAX_SVGS: u32 = 2048;
pub const MAX_IMAGES: u32 = 1024;
pub const MAX_FRAMES_IN_FLIGHT: u32 = 2;
pub const MAX_SURFACE_FORMATS: u32 = 128;
pub const MAX_PRESENT_MODES: u32 = 16;

// =============================================================================
// GPU Types
// =============================================================================

pub const Uniforms = extern struct {
    viewport_width: f32,
    viewport_height: f32,
    _pad0: f32 = 0,
    _pad1: f32 = 0,
};

pub const GpuGlyph = extern struct {
    pos_x: f32 = 0,
    pos_y: f32 = 0,
    size_x: f32 = 0,
    size_y: f32 = 0,
    uv_left: f32 = 0,
    uv_top: f32 = 0,
    uv_right: f32 = 0,
    uv_bottom: f32 = 0,
    color_h: f32 = 0,
    color_s: f32 = 0,
    color_l: f32 = 1,
    color_a: f32 = 1,
    clip_x: f32 = 0,
    clip_y: f32 = 0,
    clip_width: f32 = 99999,
    clip_height: f32 = 99999,

    pub fn fromScene(g: scene_mod.GlyphInstance) GpuGlyph {
        return .{
            .pos_x = g.pos_x,
            .pos_y = g.pos_y,
            .size_x = g.size_x,
            .size_y = g.size_y,
            .uv_left = g.uv_left,
            .uv_top = g.uv_top,
            .uv_right = g.uv_right,
            .uv_bottom = g.uv_bottom,
            .color_h = g.color.h,
            .color_s = g.color.s,
            .color_l = g.color.l,
            .color_a = g.color.a,
            .clip_x = g.clip_x,
            .clip_y = g.clip_y,
            .clip_width = g.clip_width,
            .clip_height = g.clip_height,
        };
    }
};

/// GPU-ready SVG instance data (matches shader struct layout)
pub const GpuSvg = extern struct {
    // Position and size
    pos_x: f32 = 0,
    pos_y: f32 = 0,
    size_x: f32 = 0,
    size_y: f32 = 0,
    // UV coordinates
    uv_left: f32 = 0,
    uv_top: f32 = 0,
    uv_right: f32 = 0,
    uv_bottom: f32 = 0,
    // Fill color (HSLA)
    fill_h: f32 = 0,
    fill_s: f32 = 0,
    fill_l: f32 = 0,
    fill_a: f32 = 0,
    // Stroke color (HSLA)
    stroke_h: f32 = 0,
    stroke_s: f32 = 0,
    stroke_l: f32 = 0,
    stroke_a: f32 = 0,
    // Clip bounds
    clip_x: f32 = 0,
    clip_y: f32 = 0,
    clip_width: f32 = 99999,
    clip_height: f32 = 99999,

    pub fn fromScene(s: SvgInstance) GpuSvg {
        return .{
            .pos_x = s.pos_x,
            .pos_y = s.pos_y,
            .size_x = s.size_x,
            .size_y = s.size_y,
            .uv_left = s.uv_left,
            .uv_top = s.uv_top,
            .uv_right = s.uv_right,
            .uv_bottom = s.uv_bottom,
            .fill_h = s.color.h,
            .fill_s = s.color.s,
            .fill_l = s.color.l,
            .fill_a = s.color.a,
            .stroke_h = s.stroke_color.h,
            .stroke_s = s.stroke_color.s,
            .stroke_l = s.stroke_color.l,
            .stroke_a = s.stroke_color.a,
            .clip_x = s.clip_x,
            .clip_y = s.clip_y,
            .clip_width = s.clip_width,
            .clip_height = s.clip_height,
        };
    }
};

/// GPU-ready Image instance data (matches shader struct layout)
/// 96 bytes = 24 floats
pub const GpuImage = extern struct {
    // Position and size
    pos_x: f32 = 0,
    pos_y: f32 = 0,
    dest_width: f32 = 0,
    dest_height: f32 = 0,
    // UV coordinates
    uv_left: f32 = 0,
    uv_top: f32 = 0,
    uv_right: f32 = 0,
    uv_bottom: f32 = 0,
    // Tint color (HSLA)
    tint_h: f32 = 0,
    tint_s: f32 = 0,
    tint_l: f32 = 1,
    tint_a: f32 = 1,
    // Clip bounds
    clip_x: f32 = 0,
    clip_y: f32 = 0,
    clip_width: f32 = 99999,
    clip_height: f32 = 99999,
    // Corner radii
    corner_tl: f32 = 0,
    corner_tr: f32 = 0,
    corner_br: f32 = 0,
    corner_bl: f32 = 0,
    // Effects
    grayscale: f32 = 0,
    opacity: f32 = 1,
    _pad0: f32 = 0,
    _pad1: f32 = 0,

    pub fn fromScene(img: ImageInstance) GpuImage {
        return .{
            .pos_x = img.pos_x,
            .pos_y = img.pos_y,
            .dest_width = img.dest_width,
            .dest_height = img.dest_height,
            .uv_left = img.uv_left,
            .uv_top = img.uv_top,
            .uv_right = img.uv_right,
            .uv_bottom = img.uv_bottom,
            .tint_h = img.tint.h,
            .tint_s = img.tint.s,
            .tint_l = img.tint.l,
            .tint_a = img.tint.a,
            .clip_x = img.clip_x,
            .clip_y = img.clip_y,
            .clip_width = img.clip_width,
            .clip_height = img.clip_height,
            .corner_tl = img.corner_tl,
            .corner_tr = img.corner_tr,
            .corner_br = img.corner_br,
            .corner_bl = img.corner_bl,
            .grayscale = img.grayscale,
            .opacity = img.opacity,
        };
    }
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

    // Pipelines
    unified_pipeline_layout: vk.PipelineLayout = null,
    unified_pipeline: vk.Pipeline = null,
    text_pipeline_layout: vk.PipelineLayout = null,
    text_pipeline: vk.Pipeline = null,
    svg_pipeline_layout: vk.PipelineLayout = null,
    svg_pipeline: vk.Pipeline = null,
    image_pipeline_layout: vk.PipelineLayout = null,
    image_pipeline: vk.Pipeline = null,

    // Command buffers
    command_pool: vk.CommandPool = null,
    command_buffers: [MAX_FRAMES_IN_FLIGHT]vk.CommandBuffer = [_]vk.CommandBuffer{null} ** MAX_FRAMES_IN_FLIGHT,
    transfer_command_buffer: vk.CommandBuffer = null,

    // Synchronization
    image_available_semaphores: [MAX_FRAMES_IN_FLIGHT]vk.Semaphore = [_]vk.Semaphore{null} ** MAX_FRAMES_IN_FLIGHT,
    render_finished_semaphores: [MAX_FRAMES_IN_FLIGHT]vk.Semaphore = [_]vk.Semaphore{null} ** MAX_FRAMES_IN_FLIGHT,
    in_flight_fences: [MAX_FRAMES_IN_FLIGHT]vk.Fence = [_]vk.Fence{null} ** MAX_FRAMES_IN_FLIGHT,
    transfer_fence: vk.Fence = null,
    current_frame: u32 = 0,
    swapchain_needs_recreate: bool = false,

    // Buffers
    uniform_buffer: vk.Buffer = null,
    uniform_memory: vk.DeviceMemory = null,
    uniform_mapped: ?*anyopaque = null,

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

    // Staging buffer for texture uploads
    staging_buffer: vk.Buffer = null,
    staging_memory: vk.DeviceMemory = null,
    staging_mapped: ?*anyopaque = null,
    staging_size: vk.DeviceSize = 0,

    // Text atlas texture (R8 format)
    atlas_image: vk.Image = null,
    atlas_memory: vk.DeviceMemory = null,
    atlas_view: vk.ImageView = null,
    atlas_sampler: vk.Sampler = null,
    atlas_width: u32 = 0,
    atlas_height: u32 = 0,
    atlas_generation: u32 = 0,

    // SVG atlas texture (RGBA format)
    svg_atlas_image: vk.Image = null,
    svg_atlas_memory: vk.DeviceMemory = null,
    svg_atlas_view: vk.ImageView = null,
    svg_atlas_width: u32 = 0,
    svg_atlas_height: u32 = 0,
    svg_atlas_generation: u32 = 0,

    // Image atlas texture (RGBA format)
    image_atlas_image: vk.Image = null,
    image_atlas_memory: vk.DeviceMemory = null,
    image_atlas_view: vk.ImageView = null,
    image_atlas_width: u32 = 0,
    image_atlas_height: u32 = 0,
    image_atlas_generation: u32 = 0,

    // Descriptors
    unified_descriptor_layout: vk.DescriptorSetLayout = null,
    text_descriptor_layout: vk.DescriptorSetLayout = null,
    svg_descriptor_layout: vk.DescriptorSetLayout = null,
    image_descriptor_layout: vk.DescriptorSetLayout = null,
    descriptor_pool: vk.DescriptorPool = null,
    unified_descriptor_set: vk.DescriptorSet = null,
    text_descriptor_set: vk.DescriptorSet = null,
    svg_descriptor_set: vk.DescriptorSet = null,
    image_descriptor_set: vk.DescriptorSet = null,

    // Memory properties
    mem_properties: vk.PhysicalDeviceMemoryProperties = undefined,

    // CPU-side buffers (fixed capacity, no runtime allocation)
    primitives: [MAX_PRIMITIVES]unified.Primitive = undefined,
    gpu_glyphs: [MAX_GLYPHS]GpuGlyph = undefined,
    gpu_svgs: [MAX_SVGS]GpuSvg = undefined,
    gpu_images: [MAX_IMAGES]GpuImage = undefined,

    initialized: bool = false,

    const Self = @This();

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

        // Wait for device to be idle
        if (self.device) |dev| {
            _ = vk.vkDeviceWaitIdle(dev);
        }

        // Destroy synchronization primitives
        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            if (self.image_available_semaphores[i]) |sem| {
                vk.vkDestroySemaphore(self.device, sem, null);
            }
            if (self.render_finished_semaphores[i]) |sem| {
                vk.vkDestroySemaphore(self.device, sem, null);
            }
            if (self.in_flight_fences[i]) |fence| {
                vk.vkDestroyFence(self.device, fence, null);
            }
        }

        // Destroy transfer fence
        if (self.transfer_fence) |fence| {
            vk.vkDestroyFence(self.device, fence, null);
        }

        // Destroy command pool (frees command buffers)
        if (self.command_pool) |pool| {
            vk.vkDestroyCommandPool(self.device, pool, null);
        }

        // Destroy descriptor pool (frees descriptor sets)
        if (self.descriptor_pool) |pool| {
            vk.vkDestroyDescriptorPool(self.device, pool, null);
        }

        // Destroy descriptor layouts
        if (self.unified_descriptor_layout) |layout| {
            vk.vkDestroyDescriptorSetLayout(self.device, layout, null);
        }
        if (self.text_descriptor_layout) |layout| {
            vk.vkDestroyDescriptorSetLayout(self.device, layout, null);
        }
        if (self.svg_descriptor_layout) |layout| {
            vk.vkDestroyDescriptorSetLayout(self.device, layout, null);
        }
        if (self.image_descriptor_layout) |layout| {
            vk.vkDestroyDescriptorSetLayout(self.device, layout, null);
        }

        // Destroy pipelines
        if (self.unified_pipeline) |pipeline| {
            vk.vkDestroyPipeline(self.device, pipeline, null);
        }
        if (self.text_pipeline) |pipeline| {
            vk.vkDestroyPipeline(self.device, pipeline, null);
        }
        if (self.svg_pipeline) |pipeline| {
            vk.vkDestroyPipeline(self.device, pipeline, null);
        }
        if (self.image_pipeline) |pipeline| {
            vk.vkDestroyPipeline(self.device, pipeline, null);
        }
        if (self.unified_pipeline_layout) |layout| {
            vk.vkDestroyPipelineLayout(self.device, layout, null);
        }
        if (self.text_pipeline_layout) |layout| {
            vk.vkDestroyPipelineLayout(self.device, layout, null);
        }
        if (self.svg_pipeline_layout) |layout| {
            vk.vkDestroyPipelineLayout(self.device, layout, null);
        }
        if (self.image_pipeline_layout) |layout| {
            vk.vkDestroyPipelineLayout(self.device, layout, null);
        }

        // Destroy framebuffers
        for (&self.framebuffers) |fb| {
            if (fb) |framebuffer| {
                vk.vkDestroyFramebuffer(self.device, framebuffer, null);
            }
        }

        // Destroy render pass
        if (self.render_pass) |rp| {
            vk.vkDestroyRenderPass(self.device, rp, null);
        }

        // Destroy MSAA resources
        if (self.msaa_view) |view| {
            vk.vkDestroyImageView(self.device, view, null);
        }
        if (self.msaa_image) |image| {
            vk.vkDestroyImage(self.device, image, null);
        }
        if (self.msaa_memory) |mem| {
            vk.vkFreeMemory(self.device, mem, null);
        }

        // Destroy swapchain image views
        for (&self.swapchain_image_views) |iv| {
            if (iv) |view| {
                vk.vkDestroyImageView(self.device, view, null);
            }
        }

        // Destroy swapchain
        if (self.swapchain) |sc| {
            vk.vkDestroySwapchainKHR(self.device, sc, null);
        }

        // Destroy buffers
        self.destroyBuffer(self.uniform_buffer, self.uniform_memory);
        self.destroyBuffer(self.primitive_buffer, self.primitive_memory);
        self.destroyBuffer(self.glyph_buffer, self.glyph_memory);
        self.destroyBuffer(self.svg_buffer, self.svg_memory);
        self.destroyBuffer(self.image_buffer, self.image_memory);
        self.destroyBuffer(self.staging_buffer, self.staging_memory);

        // Destroy text atlas
        if (self.atlas_sampler) |sampler| {
            vk.vkDestroySampler(self.device, sampler, null);
        }
        if (self.atlas_view) |view| {
            vk.vkDestroyImageView(self.device, view, null);
        }
        if (self.atlas_image) |image| {
            vk.vkDestroyImage(self.device, image, null);
        }
        if (self.atlas_memory) |mem| {
            vk.vkFreeMemory(self.device, mem, null);
        }

        // Destroy SVG atlas
        if (self.svg_atlas_view) |view| {
            vk.vkDestroyImageView(self.device, view, null);
        }
        if (self.svg_atlas_image) |image| {
            vk.vkDestroyImage(self.device, image, null);
        }
        if (self.svg_atlas_memory) |mem| {
            vk.vkFreeMemory(self.device, mem, null);
        }

        // Destroy Image atlas
        if (self.image_atlas_view) |view| {
            vk.vkDestroyImageView(self.device, view, null);
        }
        if (self.image_atlas_image) |image| {
            vk.vkDestroyImage(self.device, image, null);
        }
        if (self.image_atlas_memory) |mem| {
            vk.vkFreeMemory(self.device, mem, null);
        }

        // Destroy surface
        if (self.surface) |surf| {
            vk.vkDestroySurfaceKHR(self.instance, surf, null);
        }

        // Destroy device
        if (self.device) |dev| {
            vk.vkDestroyDevice(dev, null);
        }

        // Destroy debug messenger before instance
        self.destroyDebugMessenger();

        // Destroy instance
        if (self.instance) |inst| {
            vk.vkDestroyInstance(inst, null);
        }

        self.initialized = false;
    }

    fn destroyBuffer(self: *Self, buffer: vk.Buffer, memory: vk.DeviceMemory) void {
        if (buffer) |buf| {
            vk.vkDestroyBuffer(self.device, buf, null);
        }
        if (memory) |mem| {
            vk.vkFreeMemory(self.device, mem, null);
        }
    }

    // Helper functions for errdefer cleanup chains
    fn destroySwapchainResources(self: *Self) void {
        // Wait for device to be idle before destroying swapchain
        // This ensures all GPU work is complete before cleanup
        if (self.device) |dev| {
            _ = vk.vkDeviceWaitIdle(dev);
        }

        // Flush pending Wayland requests before destroying swapchain
        if (self.wl_display) |display| {
            _ = wayland.wl_display_flush(display);
            _ = wayland.wl_display_roundtrip(display);
        }

        for (&self.swapchain_image_views) |iv| {
            if (iv) |view| vk.vkDestroyImageView(self.device, view, null);
        }
        @memset(&self.swapchain_image_views, null);
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

    fn destroyFramebuffers(self: *Self) void {
        for (&self.framebuffers) |fb| {
            if (fb) |framebuffer| vk.vkDestroyFramebuffer(self.device, framebuffer, null);
        }
        @memset(&self.framebuffers, null);
    }

    fn destroySyncObjects(self: *Self) void {
        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            if (self.image_available_semaphores[i]) |sem| vk.vkDestroySemaphore(self.device, sem, null);
            if (self.render_finished_semaphores[i]) |sem| vk.vkDestroySemaphore(self.device, sem, null);
            if (self.in_flight_fences[i]) |fence| vk.vkDestroyFence(self.device, fence, null);
        }
        @memset(&self.image_available_semaphores, null);
        @memset(&self.render_finished_semaphores, null);
        @memset(&self.in_flight_fences, null);
        if (self.transfer_fence) |fence| vk.vkDestroyFence(self.device, fence, null);
        self.transfer_fence = null;
    }

    fn destroyAllBuffers(self: *Self) void {
        self.destroyBuffer(self.uniform_buffer, self.uniform_memory);
        self.uniform_buffer = null;
        self.uniform_memory = null;
        self.uniform_mapped = null;
        self.destroyBuffer(self.primitive_buffer, self.primitive_memory);
        self.primitive_buffer = null;
        self.primitive_memory = null;
        self.primitive_mapped = null;
        self.destroyBuffer(self.glyph_buffer, self.glyph_memory);
        self.glyph_buffer = null;
        self.glyph_memory = null;
        self.glyph_mapped = null;
        self.destroyBuffer(self.svg_buffer, self.svg_memory);
        self.svg_buffer = null;
        self.svg_memory = null;
        self.svg_mapped = null;
        self.destroyBuffer(self.image_buffer, self.image_memory);
        self.image_buffer = null;
        self.image_memory = null;
        self.image_mapped = null;
        self.destroyBuffer(self.staging_buffer, self.staging_memory);
        self.staging_buffer = null;
        self.staging_memory = null;
        self.staging_mapped = null;
    }

    fn destroyDescriptorLayouts(self: *Self) void {
        if (self.unified_descriptor_layout) |layout| vk.vkDestroyDescriptorSetLayout(self.device, layout, null);
        self.unified_descriptor_layout = null;
        if (self.text_descriptor_layout) |layout| vk.vkDestroyDescriptorSetLayout(self.device, layout, null);
        self.text_descriptor_layout = null;
        if (self.svg_descriptor_layout) |layout| vk.vkDestroyDescriptorSetLayout(self.device, layout, null);
        self.svg_descriptor_layout = null;
        if (self.image_descriptor_layout) |layout| vk.vkDestroyDescriptorSetLayout(self.device, layout, null);
        self.image_descriptor_layout = null;
    }

    fn destroyUnifiedPipeline(self: *Self) void {
        if (self.unified_pipeline) |pipeline| vk.vkDestroyPipeline(self.device, pipeline, null);
        self.unified_pipeline = null;
        if (self.unified_pipeline_layout) |layout| vk.vkDestroyPipelineLayout(self.device, layout, null);
        self.unified_pipeline_layout = null;
    }

    fn destroyTextPipeline(self: *Self) void {
        if (self.text_pipeline) |pipeline| vk.vkDestroyPipeline(self.device, pipeline, null);
        self.text_pipeline = null;
        if (self.text_pipeline_layout) |layout| vk.vkDestroyPipelineLayout(self.device, layout, null);
        self.text_pipeline_layout = null;
    }

    fn destroySvgPipeline(self: *Self) void {
        if (self.svg_pipeline) |pipeline| vk.vkDestroyPipeline(self.device, pipeline, null);
        self.svg_pipeline = null;
        if (self.svg_pipeline_layout) |layout| vk.vkDestroyPipelineLayout(self.device, layout, null);
        self.svg_pipeline_layout = null;
    }

    fn destroyImagePipeline(self: *Self) void {
        if (self.image_pipeline) |pipeline| vk.vkDestroyPipeline(self.device, pipeline, null);
        self.image_pipeline = null;
        if (self.image_pipeline_layout) |layout| vk.vkDestroyPipelineLayout(self.device, layout, null);
        self.image_pipeline_layout = null;
    }

    /// Initialize with Wayland surface
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

        // Create Vulkan instance
        try self.createInstance();
        errdefer {
            if (self.instance) |inst| vk.vkDestroyInstance(inst, null);
            self.instance = null;
        }

        // Create Wayland surface
        try self.createWaylandSurface(wl_display, wl_surface);
        errdefer {
            if (self.surface) |surf| vk.vkDestroySurfaceKHR(self.instance, surf, null);
            self.surface = null;
        }

        // Pick physical device and find queue families
        try self.pickPhysicalDevice();

        // Query and select MSAA sample count
        self.sample_count = self.getMaxUsableSampleCount();
        std.log.info("Using MSAA sample count: {}", .{self.sample_count});

        // Create logical device
        try self.createLogicalDevice();
        errdefer {
            if (self.device) |dev| vk.vkDestroyDevice(dev, null);
            self.device = null;
        }

        // Get memory properties
        vk.vkGetPhysicalDeviceMemoryProperties(self.physical_device, &self.mem_properties);

        // Calculate physical pixel dimensions for HiDPI rendering
        const physical_width: u32 = @intFromFloat(@as(f64, @floatFromInt(width)) * scale_factor);
        const physical_height: u32 = @intFromFloat(@as(f64, @floatFromInt(height)) * scale_factor);

        // Create swapchain at physical pixel resolution for crisp HiDPI rendering
        try self.createSwapchain(physical_width, physical_height);
        errdefer self.destroySwapchainResources();

        // Create MSAA color buffer (if MSAA enabled)
        try self.createMSAAResources();
        errdefer self.destroyMSAAResources();

        // Create render pass
        try self.createRenderPass();
        errdefer {
            if (self.render_pass) |rp| vk.vkDestroyRenderPass(self.device, rp, null);
            self.render_pass = null;
        }

        // Create framebuffers
        try self.createFramebuffers();
        errdefer self.destroyFramebuffers();

        // Create command pool and buffers
        try self.createCommandPool();
        errdefer {
            if (self.command_pool) |pool| vk.vkDestroyCommandPool(self.device, pool, null);
            self.command_pool = null;
        }
        try self.allocateCommandBuffers();

        // Create synchronization objects
        try self.createSyncObjects();
        errdefer self.destroySyncObjects();

        // Create buffers
        try self.createBuffers();
        errdefer self.destroyAllBuffers();

        // Create descriptor layouts
        try self.createDescriptorLayouts();
        errdefer self.destroyDescriptorLayouts();

        // Create descriptor pool
        try self.createDescriptorPool();
        errdefer {
            if (self.descriptor_pool) |pool| vk.vkDestroyDescriptorPool(self.device, pool, null);
            self.descriptor_pool = null;
        }

        // Allocate descriptor sets
        try self.allocateDescriptorSets();

        // Create sampler for atlas
        try self.createSampler();
        errdefer {
            if (self.atlas_sampler) |sampler| vk.vkDestroySampler(self.device, sampler, null);
            self.atlas_sampler = null;
        }

        // Create pipelines
        try self.createUnifiedPipeline();
        errdefer self.destroyUnifiedPipeline();
        try self.createTextPipeline();
        errdefer self.destroyTextPipeline();
        try self.createSvgPipeline();
        errdefer self.destroySvgPipeline();
        try self.createImagePipeline();
        errdefer self.destroyImagePipeline();

        // Update uniform buffer with LOGICAL pixel dimensions
        // Scene coordinates are in logical pixels, so the shader needs logical viewport size
        // to correctly normalize to NDC. The swapchain/framebuffers use physical pixels.
        self.updateUniformBuffer(width, height);

        // Update descriptor sets
        self.updateUnifiedDescriptorSet();

        self.initialized = true;

        std.log.info("VulkanRenderer initialized: {}x{} logical, {}x{} physical (scale: {d:.2}, MSAA: {}x)", .{ width, height, physical_width, physical_height, scale_factor, self.sample_count });
    }

    /// Query the maximum usable MSAA sample count supported by the device
    fn getMaxUsableSampleCount(self: *Self) c_uint {
        var props: vk.PhysicalDeviceProperties = undefined;
        vk.vkGetPhysicalDeviceProperties(self.physical_device, &props);

        // Get the sample counts supported for both color and depth
        const counts = props.limits.framebufferColorSampleCounts & props.limits.framebufferDepthSampleCounts;

        // Prefer 4x MSAA for good quality/performance balance
        if ((counts & vk.VK_SAMPLE_COUNT_4_BIT) != 0) return vk.VK_SAMPLE_COUNT_4_BIT;
        if ((counts & vk.VK_SAMPLE_COUNT_2_BIT) != 0) return vk.VK_SAMPLE_COUNT_2_BIT;
        return vk.VK_SAMPLE_COUNT_1_BIT;
    }

    /// Create MSAA color buffer
    fn createMSAAResources(self: *Self) !void {
        // Only create if using MSAA
        if (self.sample_count == vk.VK_SAMPLE_COUNT_1_BIT) return;

        const image_info = vk.ImageCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .imageType = vk.VK_IMAGE_TYPE_2D,
            .format = self.swapchain_format,
            .extent = .{
                .width = self.swapchain_extent.width,
                .height = self.swapchain_extent.height,
                .depth = 1,
            },
            .mipLevels = 1,
            .arrayLayers = 1,
            .samples = self.sample_count,
            .tiling = vk.VK_IMAGE_TILING_OPTIMAL,
            .usage = vk.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | vk.VK_IMAGE_USAGE_TRANSIENT_ATTACHMENT_BIT,
            .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
            .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
        };

        var result = vk.vkCreateImage(self.device, &image_info, null, &self.msaa_image);
        if (!vk.succeeded(result)) return error.MSAAImageCreationFailed;

        // Get memory requirements and allocate
        var mem_reqs: vk.MemoryRequirements = undefined;
        vk.vkGetImageMemoryRequirements(self.device, self.msaa_image, &mem_reqs);

        const mem_type = vk.findMemoryType(
            &self.mem_properties,
            mem_reqs.memoryTypeBits,
            vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        ) orelse return error.NoSuitableMemoryType;

        const alloc_info = vk.MemoryAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = null,
            .allocationSize = mem_reqs.size,
            .memoryTypeIndex = mem_type,
        };

        result = vk.vkAllocateMemory(self.device, &alloc_info, null, &self.msaa_memory);
        if (!vk.succeeded(result)) return error.MSAAMemoryAllocationFailed;

        result = vk.vkBindImageMemory(self.device, self.msaa_image, self.msaa_memory, 0);
        if (!vk.succeeded(result)) return error.MSAAMemoryBindFailed;

        // Create image view
        const view_info = vk.ImageViewCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .image = self.msaa_image,
            .viewType = vk.VK_IMAGE_VIEW_TYPE_2D,
            .format = self.swapchain_format,
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

        result = vk.vkCreateImageView(self.device, &view_info, null, &self.msaa_view);
        if (!vk.succeeded(result)) return error.MSAAImageViewCreationFailed;
    }

    fn createInstance(self: *Self) !void {
        const app_info = vk.ApplicationInfo{
            .sType = vk.VK_STRUCTURE_TYPE_APPLICATION_INFO,
            .pNext = null,
            .pApplicationName = "Gooey",
            .applicationVersion = 1,
            .pEngineName = "Gooey",
            .engineVersion = 1,
            .apiVersion = vk.c.VK_API_VERSION_1_0,
        };

        // Check if validation layers should be enabled
        const use_validation = enable_validation_layers and vk.isValidationLayerAvailable();
        if (enable_validation_layers and !use_validation) {
            std.log.warn("Validation layers requested but VK_LAYER_KHRONOS_validation not available", .{});
        }

        // Extensions - add debug utils if validation enabled
        const base_extensions = [_][*:0]const u8{
            "VK_KHR_surface",
            "VK_KHR_wayland_surface",
        };
        const debug_extensions = [_][*:0]const u8{
            "VK_KHR_surface",
            "VK_KHR_wayland_surface",
            "VK_EXT_debug_utils",
        };
        const extensions: []const [*:0]const u8 = if (use_validation) &debug_extensions else &base_extensions;

        // Validation layer
        const validation_layers = [_][*:0]const u8{vk.VALIDATION_LAYER_NAME};

        // Debug messenger create info (chained via pNext when validation enabled)
        var debug_create_info = vk.DebugUtilsMessengerCreateInfoEXT{
            .sType = vk.VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
            .pNext = null,
            .flags = 0,
            .messageSeverity = vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT |
                vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT,
            .messageType = vk.VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT |
                vk.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT |
                vk.VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT,
            .pfnUserCallback = debugCallback,
            .pUserData = null,
        };

        const create_info = vk.InstanceCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .pNext = if (use_validation) @ptrCast(&debug_create_info) else null,
            .flags = 0,
            .pApplicationInfo = &app_info,
            .enabledLayerCount = if (use_validation) validation_layers.len else 0,
            .ppEnabledLayerNames = if (use_validation) &validation_layers else null,
            .enabledExtensionCount = @intCast(extensions.len),
            .ppEnabledExtensionNames = extensions.ptr,
        };

        const result = vk.vkCreateInstance(&create_info, null, &self.instance);
        if (!vk.succeeded(result)) {
            std.log.err("Failed to create Vulkan instance: {}", .{result});
            return error.VulkanInstanceCreationFailed;
        }

        // Create debug messenger after instance creation
        if (use_validation) {
            self.createDebugMessenger(&debug_create_info);
        }
    }

    /// Debug callback for validation layer messages
    fn debugCallback(
        severity: c_uint,
        msg_type: c_uint,
        callback_data: [*c]const vk.DebugUtilsMessengerCallbackDataEXT,
        _: ?*anyopaque,
    ) callconv(.c) vk.Bool32 {
        _ = msg_type;

        // Dereference C pointer to access fields
        const message: [*c]const u8 = if (callback_data != null) callback_data.*.pMessage else "unknown";

        if ((severity & vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT) != 0) {
            std.log.err("[Vulkan Validation] {s}", .{message});
        } else if ((severity & vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT) != 0) {
            std.log.warn("[Vulkan Validation] {s}", .{message});
        } else {
            std.log.info("[Vulkan Validation] {s}", .{message});
        }

        return vk.FALSE; // Don't abort the call
    }

    /// Create the debug messenger (called after instance creation)
    fn createDebugMessenger(self: *Self, create_info: *const vk.DebugUtilsMessengerCreateInfoEXT) void {
        // Get function pointer dynamically since it's an extension
        const func = @as(
            ?*const fn (vk.Instance, *const vk.DebugUtilsMessengerCreateInfoEXT, ?*const anyopaque, *vk.DebugUtilsMessengerEXT) callconv(.c) vk.Result,
            @ptrCast(vk.vkGetInstanceProcAddr(self.instance, "vkCreateDebugUtilsMessengerEXT")),
        );

        if (func) |create_fn| {
            const result = create_fn(self.instance, create_info, null, &self.debug_messenger);
            if (vk.succeeded(result)) {
                std.log.info("Vulkan validation layers enabled", .{});
            } else {
                std.log.warn("Failed to create debug messenger: {}", .{result});
            }
        } else {
            std.log.warn("vkCreateDebugUtilsMessengerEXT not available", .{});
        }
    }

    /// Destroy the debug messenger (called before instance destruction)
    fn destroyDebugMessenger(self: *Self) void {
        if (self.debug_messenger == null) return;

        const func = @as(
            ?*const fn (vk.Instance, vk.DebugUtilsMessengerEXT, ?*const anyopaque) callconv(.c) void,
            @ptrCast(vk.vkGetInstanceProcAddr(self.instance, "vkDestroyDebugUtilsMessengerEXT")),
        );

        if (func) |destroy_fn| {
            destroy_fn(self.instance, self.debug_messenger, null);
        }
        self.debug_messenger = null;
    }

    fn createWaylandSurface(self: *Self, wl_display: *anyopaque, wl_surface: *anyopaque) !void {
        const create_info = vk.WaylandSurfaceCreateInfoKHR{
            .sType = vk.VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR,
            .pNext = null,
            .flags = 0,
            .display = @ptrCast(wl_display),
            .surface = @ptrCast(wl_surface),
        };

        const result = vk.vkCreateWaylandSurfaceKHR(self.instance, &create_info, null, &self.surface);
        if (!vk.succeeded(result)) {
            std.log.err("Failed to create Wayland surface: {}", .{result});
            return error.WaylandSurfaceCreationFailed;
        }
    }

    fn pickPhysicalDevice(self: *Self) !void {
        var device_count: u32 = 0;
        _ = vk.vkEnumeratePhysicalDevices(self.instance, &device_count, null);
        if (device_count == 0) {
            return error.NoVulkanDevicesFound;
        }

        // Assert device count fits our fixed array - fail fast if assumption violated
        // (16 devices should be more than enough for any reasonable system)
        std.debug.assert(device_count <= 16);
        var devices: [16]vk.PhysicalDevice = [_]vk.PhysicalDevice{null} ** 16;
        var count: u32 = @min(device_count, 16);
        _ = vk.vkEnumeratePhysicalDevices(self.instance, &count, &devices);

        // Find a suitable device
        for (devices[0..count]) |dev| {
            if (dev == null) continue;

            if (self.isDeviceSuitable(dev)) {
                self.physical_device = dev;

                var props: vk.PhysicalDeviceProperties = undefined;
                vk.vkGetPhysicalDeviceProperties(dev, &props);
                std.log.info("Selected GPU: {s}", .{@as([*:0]const u8, @ptrCast(&props.deviceName))});
                return;
            }
        }

        return error.NoSuitableVulkanDevice;
    }

    fn isDeviceSuitable(self: *Self, device: vk.PhysicalDevice) bool {
        // Find queue families
        var queue_family_count: u32 = 0;
        vk.vkGetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, null);

        // Assert queue family count fits our fixed array - fail fast if assumption violated
        std.debug.assert(queue_family_count <= 32);
        var queue_families: [32]vk.QueueFamilyProperties = undefined;
        var count: u32 = @min(queue_family_count, 32);
        vk.vkGetPhysicalDeviceQueueFamilyProperties(device, &count, &queue_families);

        var found_graphics = false;
        var found_present = false;

        for (queue_families[0..count], 0..) |family, i| {
            const idx: u32 = @intCast(i);

            // Check for graphics support
            if ((family.queueFlags & vk.VK_QUEUE_GRAPHICS_BIT) != 0) {
                self.graphics_family = idx;
                found_graphics = true;
            }

            // Check for present support
            var present_support: vk.Bool32 = vk.FALSE;
            _ = vk.vkGetPhysicalDeviceSurfaceSupportKHR(device, idx, self.surface, &present_support);
            if (present_support == vk.TRUE) {
                self.present_family = idx;
                found_present = true;
            }

            if (found_graphics and found_present) break;
        }

        return found_graphics and found_present;
    }

    fn createLogicalDevice(self: *Self) !void {
        const queue_priority: f32 = 1.0;

        // May need 1 or 2 queue create infos depending on if families are the same
        var queue_create_infos: [2]vk.DeviceQueueCreateInfo = undefined;
        var queue_create_count: u32 = 1;

        queue_create_infos[0] = .{
            .sType = vk.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .queueFamilyIndex = self.graphics_family,
            .queueCount = 1,
            .pQueuePriorities = &queue_priority,
        };

        if (self.graphics_family != self.present_family) {
            queue_create_infos[1] = .{
                .sType = vk.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .queueFamilyIndex = self.present_family,
                .queueCount = 1,
                .pQueuePriorities = &queue_priority,
            };
            queue_create_count = 2;
        }

        const device_extensions = [_][*:0]const u8{
            "VK_KHR_swapchain",
        };

        const create_info = vk.DeviceCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .queueCreateInfoCount = queue_create_count,
            .pQueueCreateInfos = &queue_create_infos,
            .enabledLayerCount = 0,
            .ppEnabledLayerNames = null,
            .enabledExtensionCount = device_extensions.len,
            .ppEnabledExtensionNames = &device_extensions,
            .pEnabledFeatures = null,
        };

        const result = vk.vkCreateDevice(self.physical_device, &create_info, null, &self.device);
        if (!vk.succeeded(result)) {
            return error.DeviceCreationFailed;
        }

        // Get queue handles
        vk.vkGetDeviceQueue(self.device, self.graphics_family, 0, &self.graphics_queue);
        vk.vkGetDeviceQueue(self.device, self.present_family, 0, &self.present_queue);
    }

    fn createSwapchain(self: *Self, width: u32, height: u32) !void {
        // Query surface capabilities
        var capabilities: vk.SurfaceCapabilitiesKHR = undefined;
        _ = vk.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(self.physical_device, self.surface, &capabilities);

        // Query surface formats
        var format_count: u32 = 0;
        _ = vk.vkGetPhysicalDeviceSurfaceFormatsKHR(self.physical_device, self.surface, &format_count, null);

        // Use fixed buffer - we only need to find one suitable format.
        // Some drivers report 99+ formats; we just use what fits since we're searching for
        // a specific format anyway (B8G8R8A8_UNORM or B8G8R8A8_SRGB).
        var formats: [MAX_SURFACE_FORMATS]vk.SurfaceFormatKHR = undefined;
        var fmt_count: u32 = @min(format_count, MAX_SURFACE_FORMATS);
        _ = vk.vkGetPhysicalDeviceSurfaceFormatsKHR(self.physical_device, self.surface, &fmt_count, &formats);

        // Choose format - prefer UNORM since our colors are already in sRGB space
        // Using SRGB format would double-gamma-correct (GPU applies linear→sRGB on output)
        var chosen_format = formats[0];
        var found_unorm = false;
        for (formats[0..fmt_count]) |format| {
            // Prefer UNORM - we write sRGB values directly, no conversion needed
            if (format.format == vk.VK_FORMAT_B8G8R8A8_UNORM and
                format.colorSpace == vk.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR)
            {
                chosen_format = format;
                found_unorm = true;
                break;
            }
        }
        // Fallback: accept any UNORM or SRGB format
        if (!found_unorm) {
            for (formats[0..fmt_count]) |format| {
                if (format.format == vk.VK_FORMAT_B8G8R8A8_UNORM or
                    format.format == vk.VK_FORMAT_B8G8R8A8_SRGB)
                {
                    chosen_format = format;
                    break;
                }
            }
        }
        self.swapchain_format = chosen_format.format;

        // Query present modes
        var present_mode_count: u32 = 0;
        _ = vk.vkGetPhysicalDeviceSurfacePresentModesKHR(self.physical_device, self.surface, &present_mode_count, null);

        // Use fixed buffer for present modes - typically only 4-6 modes exist.
        var present_modes: [MAX_PRESENT_MODES]c_uint = undefined;
        var pm_count: u32 = @min(present_mode_count, MAX_PRESENT_MODES);
        _ = vk.vkGetPhysicalDeviceSurfacePresentModesKHR(self.physical_device, self.surface, &pm_count, @ptrCast(&present_modes));

        // Choose present mode (prefer FIFO for vsync)
        var chosen_present_mode: c_uint = @intCast(vk.VK_PRESENT_MODE_FIFO_KHR);
        for (present_modes[0..pm_count]) |mode| {
            if (mode == vk.VK_PRESENT_MODE_MAILBOX_KHR) {
                chosen_present_mode = mode;
                break;
            }
        }

        // Choose composite alpha mode - prefer in order: OPAQUE, PRE_MULTIPLIED, POST_MULTIPLIED, INHERIT
        // This ensures compatibility across different Wayland compositors
        const preferred_alpha_modes = [_]c_uint{
            vk.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
            vk.VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR,
            vk.VK_COMPOSITE_ALPHA_POST_MULTIPLIED_BIT_KHR,
            vk.VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR,
        };
        var chosen_composite_alpha: c_uint = vk.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
        var found_alpha = false;
        for (preferred_alpha_modes) |alpha_mode| {
            if ((capabilities.supportedCompositeAlpha & alpha_mode) != 0) {
                chosen_composite_alpha = alpha_mode;
                found_alpha = true;
                break;
            }
        }
        // Assert at least one mode is supported (should always be true per Vulkan spec)
        std.debug.assert(found_alpha);
        std.debug.assert(capabilities.supportedCompositeAlpha != 0);

        // Determine extent
        var extent: vk.Extent2D = undefined;
        if (capabilities.currentExtent.width != 0xFFFFFFFF) {
            // Compositor specifies exact extent (rare on Wayland)
            extent = capabilities.currentExtent;
        } else {
            // We choose the extent - use our requested physical pixel size
            extent.width = std.math.clamp(width, capabilities.minImageExtent.width, capabilities.maxImageExtent.width);
            extent.height = std.math.clamp(height, capabilities.minImageExtent.height, capabilities.maxImageExtent.height);
        }
        self.swapchain_extent = extent;

        // Image count
        var image_count = capabilities.minImageCount + 1;
        if (capabilities.maxImageCount > 0 and image_count > capabilities.maxImageCount) {
            image_count = capabilities.maxImageCount;
        }

        const create_info = vk.SwapchainCreateInfoKHR{
            .sType = vk.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
            .pNext = null,
            .flags = 0,
            .surface = self.surface,
            .minImageCount = image_count,
            .imageFormat = chosen_format.format,
            .imageColorSpace = chosen_format.colorSpace,
            .imageExtent = extent,
            .imageArrayLayers = 1,
            .imageUsage = vk.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
            .imageSharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
            .preTransform = capabilities.currentTransform,
            .compositeAlpha = chosen_composite_alpha,
            .presentMode = chosen_present_mode,
            .clipped = vk.TRUE,
            .oldSwapchain = null,
        };

        const result = vk.vkCreateSwapchainKHR(self.device, &create_info, null, &self.swapchain);
        if (!vk.succeeded(result)) {
            return error.SwapchainCreationFailed;
        }

        // Get swapchain images
        _ = vk.vkGetSwapchainImagesKHR(self.device, self.swapchain, &self.swapchain_image_count, null);
        // Assert swapchain image count fits our fixed array - fail fast if assumption violated
        std.debug.assert(self.swapchain_image_count <= 8);
        var img_count: u32 = @min(self.swapchain_image_count, 8);
        _ = vk.vkGetSwapchainImagesKHR(self.device, self.swapchain, &img_count, &self.swapchain_images);
        self.swapchain_image_count = img_count;

        // Create image views
        for (0..img_count) |i| {
            const view_info = vk.ImageViewCreateInfo{
                .sType = vk.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .image = self.swapchain_images[i],
                .viewType = vk.VK_IMAGE_VIEW_TYPE_2D,
                .format = self.swapchain_format,
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

            const res = vk.vkCreateImageView(self.device, &view_info, null, &self.swapchain_image_views[i]);
            if (!vk.succeeded(res)) {
                return error.ImageViewCreationFailed;
            }
        }
    }

    fn createRenderPass(self: *Self) !void {
        const use_msaa = self.sample_count != vk.VK_SAMPLE_COUNT_1_BIT;

        if (use_msaa) {
            // MSAA render pass with resolve
            // Attachment 0: MSAA color buffer (multisampled)
            // Attachment 1: Resolve target (swapchain image, single-sampled)
            const attachments = [_]vk.AttachmentDescription{
                // MSAA color attachment
                .{
                    .flags = 0,
                    .format = @intCast(self.swapchain_format),
                    .samples = self.sample_count,
                    .loadOp = vk.VK_ATTACHMENT_LOAD_OP_CLEAR,
                    .storeOp = vk.VK_ATTACHMENT_STORE_OP_DONT_CARE, // Don't need to store MSAA buffer
                    .stencilLoadOp = vk.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
                    .stencilStoreOp = vk.VK_ATTACHMENT_STORE_OP_DONT_CARE,
                    .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
                    .finalLayout = vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
                },
                // Resolve attachment (swapchain image)
                .{
                    .flags = 0,
                    .format = @intCast(self.swapchain_format),
                    .samples = vk.VK_SAMPLE_COUNT_1_BIT,
                    .loadOp = vk.VK_ATTACHMENT_LOAD_OP_DONT_CARE, // Will be resolved into
                    .storeOp = vk.VK_ATTACHMENT_STORE_OP_STORE,
                    .stencilLoadOp = vk.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
                    .stencilStoreOp = vk.VK_ATTACHMENT_STORE_OP_DONT_CARE,
                    .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
                    .finalLayout = vk.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
                },
            };

            const color_attachment_ref = vk.AttachmentReference{
                .attachment = 0, // MSAA buffer
                .layout = vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            };

            const resolve_attachment_ref = vk.AttachmentReference{
                .attachment = 1, // Swapchain image
                .layout = vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            };

            const subpass = vk.SubpassDescription{
                .flags = 0,
                .pipelineBindPoint = vk.VK_PIPELINE_BIND_POINT_GRAPHICS,
                .inputAttachmentCount = 0,
                .pInputAttachments = null,
                .colorAttachmentCount = 1,
                .pColorAttachments = &color_attachment_ref,
                .pResolveAttachments = &resolve_attachment_ref,
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
                .attachmentCount = 2,
                .pAttachments = &attachments,
                .subpassCount = 1,
                .pSubpasses = &subpass,
                .dependencyCount = 1,
                .pDependencies = &dependency,
            };

            const result = vk.vkCreateRenderPass(self.device, &render_pass_info, null, &self.render_pass);
            if (!vk.succeeded(result)) {
                return error.RenderPassCreationFailed;
            }
        } else {
            // Non-MSAA render pass (single attachment)
            const color_attachment = vk.AttachmentDescription{
                .flags = 0,
                .format = @intCast(self.swapchain_format),
                .samples = vk.VK_SAMPLE_COUNT_1_BIT,
                .loadOp = vk.VK_ATTACHMENT_LOAD_OP_CLEAR,
                .storeOp = vk.VK_ATTACHMENT_STORE_OP_STORE,
                .stencilLoadOp = vk.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
                .stencilStoreOp = vk.VK_ATTACHMENT_STORE_OP_DONT_CARE,
                .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
                .finalLayout = vk.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
            };

            const color_attachment_ref = vk.AttachmentReference{
                .attachment = 0,
                .layout = vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            };

            const subpass = vk.SubpassDescription{
                .flags = 0,
                .pipelineBindPoint = vk.VK_PIPELINE_BIND_POINT_GRAPHICS,
                .inputAttachmentCount = 0,
                .pInputAttachments = null,
                .colorAttachmentCount = 1,
                .pColorAttachments = &color_attachment_ref,
                .pResolveAttachments = null,
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
                .attachmentCount = 1,
                .pAttachments = &color_attachment,
                .subpassCount = 1,
                .pSubpasses = &subpass,
                .dependencyCount = 1,
                .pDependencies = &dependency,
            };

            const result = vk.vkCreateRenderPass(self.device, &render_pass_info, null, &self.render_pass);
            if (!vk.succeeded(result)) {
                return error.RenderPassCreationFailed;
            }
        }
    }

    fn createFramebuffers(self: *Self) !void {
        const use_msaa = self.sample_count != vk.VK_SAMPLE_COUNT_1_BIT;

        for (0..self.swapchain_image_count) |i| {
            if (use_msaa) {
                // MSAA: attachment 0 = MSAA color, attachment 1 = resolve (swapchain)
                const attachments = [_]vk.ImageView{ self.msaa_view, self.swapchain_image_views[i] };

                const framebuffer_info = vk.FramebufferCreateInfo{
                    .sType = vk.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
                    .pNext = null,
                    .flags = 0,
                    .renderPass = self.render_pass,
                    .attachmentCount = 2,
                    .pAttachments = &attachments,
                    .width = self.swapchain_extent.width,
                    .height = self.swapchain_extent.height,
                    .layers = 1,
                };

                const result = vk.vkCreateFramebuffer(self.device, &framebuffer_info, null, &self.framebuffers[i]);
                if (!vk.succeeded(result)) {
                    return error.FramebufferCreationFailed;
                }
            } else {
                // Non-MSAA: single attachment
                const attachments = [_]vk.ImageView{self.swapchain_image_views[i]};

                const framebuffer_info = vk.FramebufferCreateInfo{
                    .sType = vk.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
                    .pNext = null,
                    .flags = 0,
                    .renderPass = self.render_pass,
                    .attachmentCount = 1,
                    .pAttachments = &attachments,
                    .width = self.swapchain_extent.width,
                    .height = self.swapchain_extent.height,
                    .layers = 1,
                };

                const result = vk.vkCreateFramebuffer(self.device, &framebuffer_info, null, &self.framebuffers[i]);
                if (!vk.succeeded(result)) {
                    return error.FramebufferCreationFailed;
                }
            }
        }
    }

    fn createCommandPool(self: *Self) !void {
        const pool_info = vk.CommandPoolCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .pNext = null,
            .flags = vk.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
            .queueFamilyIndex = self.graphics_family,
        };

        const result = vk.vkCreateCommandPool(self.device, &pool_info, null, &self.command_pool);
        if (!vk.succeeded(result)) {
            return error.CommandPoolCreationFailed;
        }
    }

    fn allocateCommandBuffers(self: *Self) !void {
        // Allocate render command buffers (one per frame in flight)
        const alloc_info = vk.CommandBufferAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .pNext = null,
            .commandPool = self.command_pool,
            .level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = MAX_FRAMES_IN_FLIGHT,
        };

        const result = vk.vkAllocateCommandBuffers(self.device, &alloc_info, &self.command_buffers);
        if (!vk.succeeded(result)) {
            return error.CommandBufferAllocationFailed;
        }

        // Allocate dedicated transfer command buffer for atlas uploads
        // This avoids race conditions with render command buffers
        const transfer_alloc_info = vk.CommandBufferAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .pNext = null,
            .commandPool = self.command_pool,
            .level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        };

        const transfer_result = vk.vkAllocateCommandBuffers(self.device, &transfer_alloc_info, &self.transfer_command_buffer);
        if (!vk.succeeded(transfer_result)) {
            return error.CommandBufferAllocationFailed;
        }
    }

    fn createSyncObjects(self: *Self) !void {
        const semaphore_info = vk.SemaphoreCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
        };

        const fence_info = vk.FenceCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
            .pNext = null,
            .flags = vk.VK_FENCE_CREATE_SIGNALED_BIT,
        };

        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            var res = vk.vkCreateSemaphore(self.device, &semaphore_info, null, &self.image_available_semaphores[i]);
            if (!vk.succeeded(res)) return error.SyncObjectCreationFailed;

            res = vk.vkCreateSemaphore(self.device, &semaphore_info, null, &self.render_finished_semaphores[i]);
            if (!vk.succeeded(res)) return error.SyncObjectCreationFailed;

            res = vk.vkCreateFence(self.device, &fence_info, null, &self.in_flight_fences[i]);
            if (!vk.succeeded(res)) return error.SyncObjectCreationFailed;
        }

        // Create dedicated fence for transfer operations (starts signaled so first wait succeeds)
        const transfer_res = vk.vkCreateFence(self.device, &fence_info, null, &self.transfer_fence);
        if (!vk.succeeded(transfer_res)) return error.SyncObjectCreationFailed;
    }

    fn createBuffers(self: *Self) !void {
        // Uniform buffer
        try self.createBuffer(
            @sizeOf(Uniforms),
            vk.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
            vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            &self.uniform_buffer,
            &self.uniform_memory,
        );
        _ = vk.vkMapMemory(self.device, self.uniform_memory, 0, @sizeOf(Uniforms), 0, &self.uniform_mapped);

        // Primitive buffer (storage)
        const prim_size = @sizeOf(unified.Primitive) * MAX_PRIMITIVES;
        try self.createBuffer(
            prim_size,
            vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
            vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            &self.primitive_buffer,
            &self.primitive_memory,
        );
        _ = vk.vkMapMemory(self.device, self.primitive_memory, 0, prim_size, 0, &self.primitive_mapped);

        // Glyph buffer (storage)
        const glyph_size = @sizeOf(GpuGlyph) * MAX_GLYPHS;
        try self.createBuffer(
            glyph_size,
            vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
            vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            &self.glyph_buffer,
            &self.glyph_memory,
        );
        _ = vk.vkMapMemory(self.device, self.glyph_memory, 0, glyph_size, 0, &self.glyph_mapped);

        // SVG buffer (storage)
        const svg_size = @sizeOf(GpuSvg) * MAX_SVGS;
        try self.createBuffer(
            svg_size,
            vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
            vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            &self.svg_buffer,
            &self.svg_memory,
        );
        _ = vk.vkMapMemory(self.device, self.svg_memory, 0, svg_size, 0, &self.svg_mapped);

        // Image buffer (storage)
        const image_size = @sizeOf(GpuImage) * MAX_IMAGES;
        try self.createBuffer(
            image_size,
            vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
            vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            &self.image_buffer,
            &self.image_memory,
        );
        _ = vk.vkMapMemory(self.device, self.image_memory, 0, image_size, 0, &self.image_mapped);
    }

    fn createBuffer(
        self: *Self,
        size: vk.DeviceSize,
        usage: u32,
        properties: u32,
        buffer: *vk.Buffer,
        memory: *vk.DeviceMemory,
    ) !void {
        const buffer_info = vk.BufferCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .size = size,
            .usage = usage,
            .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
        };

        var result = vk.vkCreateBuffer(self.device, &buffer_info, null, buffer);
        if (!vk.succeeded(result)) {
            return error.BufferCreationFailed;
        }

        var mem_requirements: vk.MemoryRequirements = undefined;
        vk.vkGetBufferMemoryRequirements(self.device, buffer.*, &mem_requirements);

        const mem_type_index = vk.findMemoryType(&self.mem_properties, mem_requirements.memoryTypeBits, properties) orelse {
            return error.NoSuitableMemoryType;
        };

        const alloc_info = vk.MemoryAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = null,
            .allocationSize = mem_requirements.size,
            .memoryTypeIndex = mem_type_index,
        };

        result = vk.vkAllocateMemory(self.device, &alloc_info, null, memory);
        if (!vk.succeeded(result)) {
            return error.MemoryAllocationFailed;
        }

        _ = vk.vkBindBufferMemory(self.device, buffer.*, memory.*, 0);
    }

    fn createDescriptorLayouts(self: *Self) !void {
        // Unified pipeline: storage buffer + uniform buffer
        const unified_bindings = [_]vk.DescriptorSetLayoutBinding{
            .{
                .binding = 0,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .descriptorCount = 1,
                .stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT,
                .pImmutableSamplers = null,
            },
            .{
                .binding = 1,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                .descriptorCount = 1,
                .stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT | vk.VK_SHADER_STAGE_FRAGMENT_BIT,
                .pImmutableSamplers = null,
            },
        };

        const unified_layout_info = vk.DescriptorSetLayoutCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .bindingCount = unified_bindings.len,
            .pBindings = &unified_bindings,
        };

        var result = vk.vkCreateDescriptorSetLayout(self.device, &unified_layout_info, null, &self.unified_descriptor_layout);
        if (!vk.succeeded(result)) {
            return error.DescriptorSetLayoutCreationFailed;
        }

        // Text pipeline: storage buffer + uniform buffer + texture + sampler
        const text_bindings = [_]vk.DescriptorSetLayoutBinding{
            .{
                .binding = 0,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .descriptorCount = 1,
                .stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT,
                .pImmutableSamplers = null,
            },
            .{
                .binding = 1,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                .descriptorCount = 1,
                .stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT,
                .pImmutableSamplers = null,
            },
            .{
                .binding = 2,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE,
                .descriptorCount = 1,
                .stageFlags = vk.VK_SHADER_STAGE_FRAGMENT_BIT,
                .pImmutableSamplers = null,
            },
            .{
                .binding = 3,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_SAMPLER,
                .descriptorCount = 1,
                .stageFlags = vk.VK_SHADER_STAGE_FRAGMENT_BIT,
                .pImmutableSamplers = null,
            },
        };

        const text_layout_info = vk.DescriptorSetLayoutCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .bindingCount = text_bindings.len,
            .pBindings = &text_bindings,
        };

        result = vk.vkCreateDescriptorSetLayout(self.device, &text_layout_info, null, &self.text_descriptor_layout);
        if (!vk.succeeded(result)) {
            return error.DescriptorSetLayoutCreationFailed;
        }

        // SVG pipeline: storage buffer + uniform buffer + texture + sampler (same layout as text)
        const svg_bindings = [_]vk.DescriptorSetLayoutBinding{
            .{
                .binding = 0,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .descriptorCount = 1,
                .stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT,
                .pImmutableSamplers = null,
            },
            .{
                .binding = 1,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                .descriptorCount = 1,
                .stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT,
                .pImmutableSamplers = null,
            },
            .{
                .binding = 2,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE,
                .descriptorCount = 1,
                .stageFlags = vk.VK_SHADER_STAGE_FRAGMENT_BIT,
                .pImmutableSamplers = null,
            },
            .{
                .binding = 3,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_SAMPLER,
                .descriptorCount = 1,
                .stageFlags = vk.VK_SHADER_STAGE_FRAGMENT_BIT,
                .pImmutableSamplers = null,
            },
        };

        const svg_layout_info = vk.DescriptorSetLayoutCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .bindingCount = svg_bindings.len,
            .pBindings = &svg_bindings,
        };

        result = vk.vkCreateDescriptorSetLayout(self.device, &svg_layout_info, null, &self.svg_descriptor_layout);
        if (!vk.succeeded(result)) {
            return error.DescriptorSetLayoutCreationFailed;
        }

        // Image pipeline: storage buffer + uniform buffer + texture + sampler (same layout as SVG/text)
        const image_bindings = [_]vk.DescriptorSetLayoutBinding{
            .{
                .binding = 0,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .descriptorCount = 1,
                .stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT,
                .pImmutableSamplers = null,
            },
            .{
                .binding = 1,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                .descriptorCount = 1,
                .stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT,
                .pImmutableSamplers = null,
            },
            .{
                .binding = 2,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE,
                .descriptorCount = 1,
                .stageFlags = vk.VK_SHADER_STAGE_FRAGMENT_BIT,
                .pImmutableSamplers = null,
            },
            .{
                .binding = 3,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_SAMPLER,
                .descriptorCount = 1,
                .stageFlags = vk.VK_SHADER_STAGE_FRAGMENT_BIT,
                .pImmutableSamplers = null,
            },
        };

        const image_layout_info = vk.DescriptorSetLayoutCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .bindingCount = image_bindings.len,
            .pBindings = &image_bindings,
        };

        result = vk.vkCreateDescriptorSetLayout(self.device, &image_layout_info, null, &self.image_descriptor_layout);
        if (!vk.succeeded(result)) {
            return error.DescriptorSetLayoutCreationFailed;
        }
    }

    fn createDescriptorPool(self: *Self) !void {
        const pool_sizes = [_]vk.DescriptorPoolSize{
            .{ .type = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 8 },
            .{ .type = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = 8 },
            .{ .type = vk.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, .descriptorCount = 6 },
            .{ .type = vk.VK_DESCRIPTOR_TYPE_SAMPLER, .descriptorCount = 6 },
        };

        const pool_info = vk.DescriptorPoolCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .maxSets = 8,
            .poolSizeCount = pool_sizes.len,
            .pPoolSizes = &pool_sizes,
        };

        const result = vk.vkCreateDescriptorPool(self.device, &pool_info, null, &self.descriptor_pool);
        if (!vk.succeeded(result)) {
            return error.DescriptorPoolCreationFailed;
        }
    }

    fn allocateDescriptorSets(self: *Self) !void {
        // Allocate unified descriptor set
        const unified_layouts = [_]vk.DescriptorSetLayout{self.unified_descriptor_layout};
        const unified_alloc_info = vk.DescriptorSetAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .pNext = null,
            .descriptorPool = self.descriptor_pool,
            .descriptorSetCount = 1,
            .pSetLayouts = &unified_layouts,
        };

        var result = vk.vkAllocateDescriptorSets(self.device, &unified_alloc_info, &self.unified_descriptor_set);
        if (!vk.succeeded(result)) {
            return error.DescriptorSetAllocationFailed;
        }

        // Allocate text descriptor set
        const text_layouts = [_]vk.DescriptorSetLayout{self.text_descriptor_layout};
        const text_alloc_info = vk.DescriptorSetAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .pNext = null,
            .descriptorPool = self.descriptor_pool,
            .descriptorSetCount = 1,
            .pSetLayouts = &text_layouts,
        };

        result = vk.vkAllocateDescriptorSets(self.device, &text_alloc_info, &self.text_descriptor_set);
        if (!vk.succeeded(result)) {
            return error.DescriptorSetAllocationFailed;
        }

        // Allocate SVG descriptor set
        const svg_layouts = [_]vk.DescriptorSetLayout{self.svg_descriptor_layout};
        const svg_alloc_info = vk.DescriptorSetAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .pNext = null,
            .descriptorPool = self.descriptor_pool,
            .descriptorSetCount = 1,
            .pSetLayouts = &svg_layouts,
        };

        result = vk.vkAllocateDescriptorSets(self.device, &svg_alloc_info, &self.svg_descriptor_set);
        if (!vk.succeeded(result)) {
            return error.DescriptorSetAllocationFailed;
        }

        // Allocate image descriptor set
        const image_layouts = [_]vk.DescriptorSetLayout{self.image_descriptor_layout};
        const image_alloc_info = vk.DescriptorSetAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .pNext = null,
            .descriptorPool = self.descriptor_pool,
            .descriptorSetCount = 1,
            .pSetLayouts = &image_layouts,
        };

        result = vk.vkAllocateDescriptorSets(self.device, &image_alloc_info, &self.image_descriptor_set);
        if (!vk.succeeded(result)) {
            return error.DescriptorSetAllocationFailed;
        }
    }

    fn createSampler(self: *Self) !void {
        const sampler_info = vk.SamplerCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .magFilter = vk.VK_FILTER_LINEAR,
            .minFilter = vk.VK_FILTER_LINEAR,
            .mipmapMode = vk.VK_SAMPLER_MIPMAP_MODE_LINEAR,
            .addressModeU = vk.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            .addressModeV = vk.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            .addressModeW = vk.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            .mipLodBias = 0,
            .anisotropyEnable = vk.FALSE,
            .maxAnisotropy = 1,
            .compareEnable = vk.FALSE,
            .compareOp = vk.VK_COMPARE_OP_NEVER,
            .minLod = 0,
            .maxLod = 0,
            .borderColor = vk.VK_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK,
            .unnormalizedCoordinates = vk.FALSE,
        };

        const result = vk.vkCreateSampler(self.device, &sampler_info, null, &self.atlas_sampler);
        if (!vk.succeeded(result)) {
            return error.SamplerCreationFailed;
        }
    }

    fn updateUniformBuffer(self: *Self, width: u32, height: u32) void {
        const uniforms = Uniforms{
            .viewport_width = @floatFromInt(width),
            .viewport_height = @floatFromInt(height),
        };
        if (self.uniform_mapped) |ptr| {
            const dest: *Uniforms = @ptrCast(@alignCast(ptr));
            dest.* = uniforms;
        }
    }

    fn updateUnifiedDescriptorSet(self: *Self) void {
        const buffer_infos = [_]vk.DescriptorBufferInfo{
            .{
                .buffer = self.primitive_buffer,
                .offset = 0,
                .range = @sizeOf(unified.Primitive) * MAX_PRIMITIVES,
            },
            .{
                .buffer = self.uniform_buffer,
                .offset = 0,
                .range = @sizeOf(Uniforms),
            },
        };

        const writes = [_]vk.WriteDescriptorSet{
            .{
                .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .pNext = null,
                .dstSet = self.unified_descriptor_set,
                .dstBinding = 0,
                .dstArrayElement = 0,
                .descriptorCount = 1,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .pImageInfo = null,
                .pBufferInfo = &buffer_infos[0],
                .pTexelBufferView = null,
            },
            .{
                .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .pNext = null,
                .dstSet = self.unified_descriptor_set,
                .dstBinding = 1,
                .dstArrayElement = 0,
                .descriptorCount = 1,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                .pImageInfo = null,
                .pBufferInfo = &buffer_infos[1],
                .pTexelBufferView = null,
            },
        };

        vk.vkUpdateDescriptorSets(self.device, writes.len, &writes, 0, null);
    }

    fn createUnifiedPipeline(self: *Self) !void {
        // Create shader modules
        const vert_module = try self.createShaderModule(unified_vert_spv);
        defer vk.vkDestroyShaderModule(self.device, vert_module, null);

        const frag_module = try self.createShaderModule(unified_frag_spv);
        defer vk.vkDestroyShaderModule(self.device, frag_module, null);

        const shader_stages = [_]vk.PipelineShaderStageCreateInfo{
            .{
                .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .stage = vk.VK_SHADER_STAGE_VERTEX_BIT,
                .module = vert_module,
                .pName = "main",
                .pSpecializationInfo = null,
            },
            .{
                .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .stage = vk.VK_SHADER_STAGE_FRAGMENT_BIT,
                .module = frag_module,
                .pName = "main",
                .pSpecializationInfo = null,
            },
        };

        // No vertex input (generated in shader)
        const vertex_input_info = vk.PipelineVertexInputStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .vertexBindingDescriptionCount = 0,
            .pVertexBindingDescriptions = null,
            .vertexAttributeDescriptionCount = 0,
            .pVertexAttributeDescriptions = null,
        };

        const input_assembly = vk.PipelineInputAssemblyStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .topology = vk.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
            .primitiveRestartEnable = vk.FALSE,
        };

        const viewport_state = vk.PipelineViewportStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .viewportCount = 1,
            .pViewports = null, // Dynamic
            .scissorCount = 1,
            .pScissors = null, // Dynamic
        };

        const rasterizer = vk.PipelineRasterizationStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .depthClampEnable = vk.FALSE,
            .rasterizerDiscardEnable = vk.FALSE,
            .polygonMode = vk.VK_POLYGON_MODE_FILL,
            .cullMode = vk.VK_CULL_MODE_NONE,
            .frontFace = vk.VK_FRONT_FACE_CLOCKWISE,
            .depthBiasEnable = vk.FALSE,
            .depthBiasConstantFactor = 0,
            .depthBiasClamp = 0,
            .depthBiasSlopeFactor = 0,
            .lineWidth = 1.0,
        };

        const multisampling = vk.PipelineMultisampleStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .rasterizationSamples = self.sample_count,
            .sampleShadingEnable = vk.FALSE,
            .minSampleShading = 1.0,
            .pSampleMask = null,
            .alphaToCoverageEnable = vk.FALSE,
            .alphaToOneEnable = vk.FALSE,
        };

        const color_blend_attachment = vk.PipelineColorBlendAttachmentState{
            .blendEnable = vk.TRUE,
            .srcColorBlendFactor = vk.VK_BLEND_FACTOR_SRC_ALPHA,
            .dstColorBlendFactor = vk.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
            .colorBlendOp = vk.VK_BLEND_OP_ADD,
            .srcAlphaBlendFactor = vk.VK_BLEND_FACTOR_ONE,
            .dstAlphaBlendFactor = vk.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
            .alphaBlendOp = vk.VK_BLEND_OP_ADD,
            .colorWriteMask = vk.VK_COLOR_COMPONENT_ALL,
        };

        const color_blending = vk.PipelineColorBlendStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .logicOpEnable = vk.FALSE,
            .logicOp = 0,
            .attachmentCount = 1,
            .pAttachments = &color_blend_attachment,
            .blendConstants = .{ 0, 0, 0, 0 },
        };

        const dynamic_states = [_]c_uint{ vk.VK_DYNAMIC_STATE_VIEWPORT, vk.VK_DYNAMIC_STATE_SCISSOR };
        const dynamic_state = vk.PipelineDynamicStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .dynamicStateCount = dynamic_states.len,
            .pDynamicStates = &dynamic_states,
        };

        // Create pipeline layout
        const layouts = [_]vk.DescriptorSetLayout{self.unified_descriptor_layout};
        const layout_info = vk.PipelineLayoutCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .setLayoutCount = 1,
            .pSetLayouts = &layouts,
            .pushConstantRangeCount = 0,
            .pPushConstantRanges = null,
        };

        var result = vk.vkCreatePipelineLayout(self.device, &layout_info, null, &self.unified_pipeline_layout);
        if (!vk.succeeded(result)) {
            return error.PipelineLayoutCreationFailed;
        }

        const pipeline_info = vk.GraphicsPipelineCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .stageCount = shader_stages.len,
            .pStages = &shader_stages,
            .pVertexInputState = &vertex_input_info,
            .pInputAssemblyState = &input_assembly,
            .pTessellationState = null,
            .pViewportState = &viewport_state,
            .pRasterizationState = &rasterizer,
            .pMultisampleState = &multisampling,
            .pDepthStencilState = null,
            .pColorBlendState = &color_blending,
            .pDynamicState = &dynamic_state,
            .layout = self.unified_pipeline_layout,
            .renderPass = self.render_pass,
            .subpass = 0,
            .basePipelineHandle = null,
            .basePipelineIndex = -1,
        };

        result = vk.vkCreateGraphicsPipelines(self.device, null, 1, &pipeline_info, null, &self.unified_pipeline);
        if (!vk.succeeded(result)) {
            return error.PipelineCreationFailed;
        }
    }

    fn createTextPipeline(self: *Self) !void {
        // Create shader modules
        const vert_module = try self.createShaderModule(text_vert_spv);
        defer vk.vkDestroyShaderModule(self.device, vert_module, null);

        const frag_module = try self.createShaderModule(text_frag_spv);
        defer vk.vkDestroyShaderModule(self.device, frag_module, null);

        const shader_stages = [_]vk.PipelineShaderStageCreateInfo{
            .{
                .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .stage = vk.VK_SHADER_STAGE_VERTEX_BIT,
                .module = vert_module,
                .pName = "main",
                .pSpecializationInfo = null,
            },
            .{
                .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .stage = vk.VK_SHADER_STAGE_FRAGMENT_BIT,
                .module = frag_module,
                .pName = "main",
                .pSpecializationInfo = null,
            },
        };

        // No vertex input (generated in shader)
        const vertex_input_info = vk.PipelineVertexInputStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .vertexBindingDescriptionCount = 0,
            .pVertexBindingDescriptions = null,
            .vertexAttributeDescriptionCount = 0,
            .pVertexAttributeDescriptions = null,
        };

        const input_assembly = vk.PipelineInputAssemblyStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .topology = vk.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
            .primitiveRestartEnable = vk.FALSE,
        };

        const viewport_state = vk.PipelineViewportStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .viewportCount = 1,
            .pViewports = null, // Dynamic
            .scissorCount = 1,
            .pScissors = null, // Dynamic
        };

        const rasterizer = vk.PipelineRasterizationStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .depthClampEnable = vk.FALSE,
            .rasterizerDiscardEnable = vk.FALSE,
            .polygonMode = vk.VK_POLYGON_MODE_FILL,
            .cullMode = vk.VK_CULL_MODE_NONE,
            .frontFace = vk.VK_FRONT_FACE_CLOCKWISE,
            .depthBiasEnable = vk.FALSE,
            .depthBiasConstantFactor = 0,
            .depthBiasClamp = 0,
            .depthBiasSlopeFactor = 0,
            .lineWidth = 1.0,
        };

        const multisampling = vk.PipelineMultisampleStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .rasterizationSamples = self.sample_count,
            .sampleShadingEnable = vk.FALSE,
            .minSampleShading = 1.0,
            .pSampleMask = null,
            .alphaToCoverageEnable = vk.FALSE,
            .alphaToOneEnable = vk.FALSE,
        };

        // Text uses premultiplied alpha blending
        const color_blend_attachment = vk.PipelineColorBlendAttachmentState{
            .blendEnable = vk.TRUE,
            .srcColorBlendFactor = vk.VK_BLEND_FACTOR_SRC_ALPHA,
            .dstColorBlendFactor = vk.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
            .colorBlendOp = vk.VK_BLEND_OP_ADD,
            .srcAlphaBlendFactor = vk.VK_BLEND_FACTOR_ONE,
            .dstAlphaBlendFactor = vk.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
            .alphaBlendOp = vk.VK_BLEND_OP_ADD,
            .colorWriteMask = vk.VK_COLOR_COMPONENT_ALL,
        };

        const color_blending = vk.PipelineColorBlendStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .logicOpEnable = vk.FALSE,
            .logicOp = 0,
            .attachmentCount = 1,
            .pAttachments = &color_blend_attachment,
            .blendConstants = .{ 0, 0, 0, 0 },
        };

        const dynamic_states = [_]c_uint{ vk.VK_DYNAMIC_STATE_VIEWPORT, vk.VK_DYNAMIC_STATE_SCISSOR };
        const dynamic_state = vk.PipelineDynamicStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .dynamicStateCount = dynamic_states.len,
            .pDynamicStates = &dynamic_states,
        };

        // Create pipeline layout using text descriptor layout
        const layouts = [_]vk.DescriptorSetLayout{self.text_descriptor_layout};
        const layout_info = vk.PipelineLayoutCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .setLayoutCount = 1,
            .pSetLayouts = &layouts,
            .pushConstantRangeCount = 0,
            .pPushConstantRanges = null,
        };

        var result = vk.vkCreatePipelineLayout(self.device, &layout_info, null, &self.text_pipeline_layout);
        if (!vk.succeeded(result)) {
            return error.PipelineLayoutCreationFailed;
        }

        const pipeline_info = vk.GraphicsPipelineCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .stageCount = shader_stages.len,
            .pStages = &shader_stages,
            .pVertexInputState = &vertex_input_info,
            .pInputAssemblyState = &input_assembly,
            .pTessellationState = null,
            .pViewportState = &viewport_state,
            .pRasterizationState = &rasterizer,
            .pMultisampleState = &multisampling,
            .pDepthStencilState = null,
            .pColorBlendState = &color_blending,
            .pDynamicState = &dynamic_state,
            .layout = self.text_pipeline_layout,
            .renderPass = self.render_pass,
            .subpass = 0,
            .basePipelineHandle = null,
            .basePipelineIndex = -1,
        };

        result = vk.vkCreateGraphicsPipelines(self.device, null, 1, &pipeline_info, null, &self.text_pipeline);
        if (!vk.succeeded(result)) {
            return error.PipelineCreationFailed;
        }
    }

    fn createSvgPipeline(self: *Self) !void {
        // Create shader modules
        const vert_module = try self.createShaderModule(svg_vert_spv);
        defer vk.vkDestroyShaderModule(self.device, vert_module, null);

        const frag_module = try self.createShaderModule(svg_frag_spv);
        defer vk.vkDestroyShaderModule(self.device, frag_module, null);

        const shader_stages = [_]vk.PipelineShaderStageCreateInfo{
            .{
                .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .stage = vk.VK_SHADER_STAGE_VERTEX_BIT,
                .module = vert_module,
                .pName = "main",
                .pSpecializationInfo = null,
            },
            .{
                .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .stage = vk.VK_SHADER_STAGE_FRAGMENT_BIT,
                .module = frag_module,
                .pName = "main",
                .pSpecializationInfo = null,
            },
        };

        // No vertex input (generated in shader)
        const vertex_input_info = vk.PipelineVertexInputStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .vertexBindingDescriptionCount = 0,
            .pVertexBindingDescriptions = null,
            .vertexAttributeDescriptionCount = 0,
            .pVertexAttributeDescriptions = null,
        };

        const input_assembly = vk.PipelineInputAssemblyStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .topology = vk.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
            .primitiveRestartEnable = vk.FALSE,
        };

        const viewport_state = vk.PipelineViewportStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .viewportCount = 1,
            .pViewports = null, // Dynamic
            .scissorCount = 1,
            .pScissors = null, // Dynamic
        };

        const rasterizer = vk.PipelineRasterizationStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .depthClampEnable = vk.FALSE,
            .rasterizerDiscardEnable = vk.FALSE,
            .polygonMode = vk.VK_POLYGON_MODE_FILL,
            .cullMode = vk.VK_CULL_MODE_NONE,
            .frontFace = vk.VK_FRONT_FACE_CLOCKWISE,
            .depthBiasEnable = vk.FALSE,
            .depthBiasConstantFactor = 0,
            .depthBiasClamp = 0,
            .depthBiasSlopeFactor = 0,
            .lineWidth = 1.0,
        };

        const multisampling = vk.PipelineMultisampleStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .rasterizationSamples = self.sample_count,
            .sampleShadingEnable = vk.FALSE,
            .minSampleShading = 1.0,
            .pSampleMask = null,
            .alphaToCoverageEnable = vk.FALSE,
            .alphaToOneEnable = vk.FALSE,
        };

        // SVG uses premultiplied alpha blending (shader outputs pre-multiplied RGB)
        const color_blend_attachment = vk.PipelineColorBlendAttachmentState{
            .blendEnable = vk.TRUE,
            .srcColorBlendFactor = vk.VK_BLEND_FACTOR_ONE,
            .dstColorBlendFactor = vk.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
            .colorBlendOp = vk.VK_BLEND_OP_ADD,
            .srcAlphaBlendFactor = vk.VK_BLEND_FACTOR_ONE,
            .dstAlphaBlendFactor = vk.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
            .alphaBlendOp = vk.VK_BLEND_OP_ADD,
            .colorWriteMask = vk.VK_COLOR_COMPONENT_ALL,
        };

        const color_blending = vk.PipelineColorBlendStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .logicOpEnable = vk.FALSE,
            .logicOp = 0,
            .attachmentCount = 1,
            .pAttachments = &color_blend_attachment,
            .blendConstants = .{ 0, 0, 0, 0 },
        };

        const dynamic_states = [_]c_uint{ vk.VK_DYNAMIC_STATE_VIEWPORT, vk.VK_DYNAMIC_STATE_SCISSOR };
        const dynamic_state = vk.PipelineDynamicStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .dynamicStateCount = dynamic_states.len,
            .pDynamicStates = &dynamic_states,
        };

        // Create pipeline layout using SVG descriptor layout
        const layouts = [_]vk.DescriptorSetLayout{self.svg_descriptor_layout};
        const layout_info = vk.PipelineLayoutCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .setLayoutCount = 1,
            .pSetLayouts = &layouts,
            .pushConstantRangeCount = 0,
            .pPushConstantRanges = null,
        };

        var result = vk.vkCreatePipelineLayout(self.device, &layout_info, null, &self.svg_pipeline_layout);
        if (!vk.succeeded(result)) {
            return error.PipelineLayoutCreationFailed;
        }

        const pipeline_info = vk.GraphicsPipelineCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .stageCount = shader_stages.len,
            .pStages = &shader_stages,
            .pVertexInputState = &vertex_input_info,
            .pInputAssemblyState = &input_assembly,
            .pTessellationState = null,
            .pViewportState = &viewport_state,
            .pRasterizationState = &rasterizer,
            .pMultisampleState = &multisampling,
            .pDepthStencilState = null,
            .pColorBlendState = &color_blending,
            .pDynamicState = &dynamic_state,
            .layout = self.svg_pipeline_layout,
            .renderPass = self.render_pass,
            .subpass = 0,
            .basePipelineHandle = null,
            .basePipelineIndex = -1,
        };

        result = vk.vkCreateGraphicsPipelines(self.device, null, 1, &pipeline_info, null, &self.svg_pipeline);
        if (!vk.succeeded(result)) {
            return error.PipelineCreationFailed;
        }
    }

    fn createImagePipeline(self: *Self) !void {
        // Create shader modules
        const vert_module = try self.createShaderModule(image_vert_spv);
        defer vk.vkDestroyShaderModule(self.device, vert_module, null);

        const frag_module = try self.createShaderModule(image_frag_spv);
        defer vk.vkDestroyShaderModule(self.device, frag_module, null);

        const shader_stages = [_]vk.PipelineShaderStageCreateInfo{
            .{
                .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .stage = vk.VK_SHADER_STAGE_VERTEX_BIT,
                .module = vert_module,
                .pName = "main",
                .pSpecializationInfo = null,
            },
            .{
                .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .stage = vk.VK_SHADER_STAGE_FRAGMENT_BIT,
                .module = frag_module,
                .pName = "main",
                .pSpecializationInfo = null,
            },
        };

        // No vertex input (generated in shader)
        const vertex_input_info = vk.PipelineVertexInputStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .vertexBindingDescriptionCount = 0,
            .pVertexBindingDescriptions = null,
            .vertexAttributeDescriptionCount = 0,
            .pVertexAttributeDescriptions = null,
        };

        const input_assembly = vk.PipelineInputAssemblyStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .topology = vk.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
            .primitiveRestartEnable = vk.FALSE,
        };

        const viewport_state = vk.PipelineViewportStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .viewportCount = 1,
            .pViewports = null, // Dynamic
            .scissorCount = 1,
            .pScissors = null, // Dynamic
        };

        const rasterizer = vk.PipelineRasterizationStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .depthClampEnable = vk.FALSE,
            .rasterizerDiscardEnable = vk.FALSE,
            .polygonMode = vk.VK_POLYGON_MODE_FILL,
            .cullMode = vk.VK_CULL_MODE_NONE,
            .frontFace = vk.VK_FRONT_FACE_CLOCKWISE,
            .depthBiasEnable = vk.FALSE,
            .depthBiasConstantFactor = 0,
            .depthBiasClamp = 0,
            .depthBiasSlopeFactor = 0,
            .lineWidth = 1.0,
        };

        const multisampling = vk.PipelineMultisampleStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .rasterizationSamples = self.sample_count,
            .sampleShadingEnable = vk.FALSE,
            .minSampleShading = 1.0,
            .pSampleMask = null,
            .alphaToCoverageEnable = vk.FALSE,
            .alphaToOneEnable = vk.FALSE,
        };

        // Image uses premultiplied alpha blending
        const color_blend_attachment = vk.PipelineColorBlendAttachmentState{
            .blendEnable = vk.TRUE,
            .srcColorBlendFactor = vk.VK_BLEND_FACTOR_SRC_ALPHA,
            .dstColorBlendFactor = vk.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
            .colorBlendOp = vk.VK_BLEND_OP_ADD,
            .srcAlphaBlendFactor = vk.VK_BLEND_FACTOR_ONE,
            .dstAlphaBlendFactor = vk.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
            .alphaBlendOp = vk.VK_BLEND_OP_ADD,
            .colorWriteMask = vk.VK_COLOR_COMPONENT_ALL,
        };

        const color_blending = vk.PipelineColorBlendStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .logicOpEnable = vk.FALSE,
            .logicOp = 0,
            .attachmentCount = 1,
            .pAttachments = &color_blend_attachment,
            .blendConstants = .{ 0, 0, 0, 0 },
        };

        const dynamic_states = [_]c_uint{ vk.VK_DYNAMIC_STATE_VIEWPORT, vk.VK_DYNAMIC_STATE_SCISSOR };
        const dynamic_state = vk.PipelineDynamicStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .dynamicStateCount = dynamic_states.len,
            .pDynamicStates = &dynamic_states,
        };

        // Create pipeline layout using image descriptor layout
        const layouts = [_]vk.DescriptorSetLayout{self.image_descriptor_layout};
        const layout_info = vk.PipelineLayoutCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .setLayoutCount = 1,
            .pSetLayouts = &layouts,
            .pushConstantRangeCount = 0,
            .pPushConstantRanges = null,
        };

        var result = vk.vkCreatePipelineLayout(self.device, &layout_info, null, &self.image_pipeline_layout);
        if (!vk.succeeded(result)) {
            return error.PipelineLayoutCreationFailed;
        }

        const pipeline_info = vk.GraphicsPipelineCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .stageCount = shader_stages.len,
            .pStages = &shader_stages,
            .pVertexInputState = &vertex_input_info,
            .pInputAssemblyState = &input_assembly,
            .pTessellationState = null,
            .pViewportState = &viewport_state,
            .pRasterizationState = &rasterizer,
            .pMultisampleState = &multisampling,
            .pDepthStencilState = null,
            .pColorBlendState = &color_blending,
            .pDynamicState = &dynamic_state,
            .layout = self.image_pipeline_layout,
            .renderPass = self.render_pass,
            .subpass = 0,
            .basePipelineHandle = null,
            .basePipelineIndex = -1,
        };

        result = vk.vkCreateGraphicsPipelines(self.device, null, 1, &pipeline_info, null, &self.image_pipeline);
        if (!vk.succeeded(result)) {
            return error.PipelineCreationFailed;
        }
    }

    fn createShaderModule(self: *Self, code: []align(4) const u8) !vk.ShaderModule {
        const create_info = vk.ShaderModuleCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .codeSize = code.len,
            .pCode = @ptrCast(code.ptr),
        };

        var shader_module: vk.ShaderModule = null;
        const result = vk.vkCreateShaderModule(self.device, &create_info, null, &shader_module);
        if (!vk.succeeded(result)) {
            return error.ShaderModuleCreationFailed;
        }
        return shader_module;
    }

    /// Resize the renderer (recreates swapchain)
    /// width/height are logical pixels, scale_factor converts to physical pixels
    pub fn resize(self: *Self, width: u32, height: u32, scale_factor: f64) void {
        if (!self.initialized) return;
        if (width == 0 or height == 0) return;

        // Store new scale factor
        self.scale_factor = scale_factor;

        // Calculate physical pixel dimensions
        const physical_width: u32 = @intFromFloat(@as(f64, @floatFromInt(width)) * scale_factor);
        const physical_height: u32 = @intFromFloat(@as(f64, @floatFromInt(height)) * scale_factor);

        _ = vk.vkDeviceWaitIdle(self.device);

        // Update uniform buffer with LOGICAL pixel dimensions
        // Scene coordinates are in logical pixels, so the shader needs logical viewport size
        // to correctly normalize to NDC. The swapchain/framebuffers use physical pixels.
        self.updateUniformBuffer(width, height);

        // Recreate swapchain at physical resolution for HiDPI
        self.recreateSwapchain(physical_width, physical_height) catch |err| {
            std.debug.print("Failed to recreate swapchain: {}\n", .{err});
        };
    }

    /// Recreate swapchain and all dependent resources (framebuffers, image views, MSAA)
    fn recreateSwapchain(self: *Self, width: u32, height: u32) !void {
        // Destroy old framebuffers
        for (0..self.swapchain_image_count) |i| {
            if (self.framebuffers[i] != null) {
                vk.vkDestroyFramebuffer(self.device, self.framebuffers[i], null);
                self.framebuffers[i] = null;
            }
        }

        // Destroy old MSAA resources
        if (self.msaa_view) |view| {
            vk.vkDestroyImageView(self.device, view, null);
            self.msaa_view = null;
        }
        if (self.msaa_image) |image| {
            vk.vkDestroyImage(self.device, image, null);
            self.msaa_image = null;
        }
        if (self.msaa_memory) |mem| {
            vk.vkFreeMemory(self.device, mem, null);
            self.msaa_memory = null;
        }

        // Destroy old image views
        for (0..self.swapchain_image_count) |i| {
            if (self.swapchain_image_views[i] != null) {
                vk.vkDestroyImageView(self.device, self.swapchain_image_views[i], null);
                self.swapchain_image_views[i] = null;
            }
        }

        // Store old swapchain for recycling
        const old_swapchain = self.swapchain;

        // Query surface capabilities for new size
        var capabilities: vk.SurfaceCapabilitiesKHR = undefined;
        _ = vk.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(self.physical_device, self.surface, &capabilities);

        // Determine extent
        var extent: vk.Extent2D = undefined;
        if (capabilities.currentExtent.width != 0xFFFFFFFF) {
            extent = capabilities.currentExtent;
        } else {
            extent.width = std.math.clamp(width, capabilities.minImageExtent.width, capabilities.maxImageExtent.width);
            extent.height = std.math.clamp(height, capabilities.minImageExtent.height, capabilities.maxImageExtent.height);
        }
        self.swapchain_extent = extent;

        // Image count
        var image_count = capabilities.minImageCount + 1;
        if (capabilities.maxImageCount > 0 and image_count > capabilities.maxImageCount) {
            image_count = capabilities.maxImageCount;
        }

        // Create new swapchain, passing old one for recycling
        const create_info = vk.SwapchainCreateInfoKHR{
            .sType = vk.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
            .pNext = null,
            .flags = 0,
            .surface = self.surface,
            .minImageCount = image_count,
            .imageFormat = self.swapchain_format,
            .imageColorSpace = vk.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR,
            .imageExtent = extent,
            .imageArrayLayers = 1,
            .imageUsage = vk.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
            .imageSharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
            .preTransform = capabilities.currentTransform,
            .compositeAlpha = vk.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
            .presentMode = vk.VK_PRESENT_MODE_FIFO_KHR,
            .clipped = vk.TRUE,
            .oldSwapchain = old_swapchain,
        };

        const result = vk.vkCreateSwapchainKHR(self.device, &create_info, null, &self.swapchain);
        if (!vk.succeeded(result)) {
            return error.SwapchainCreationFailed;
        }

        // Destroy old swapchain after new one is created
        if (old_swapchain != null) {
            vk.vkDestroySwapchainKHR(self.device, old_swapchain, null);
        }

        // Get new swapchain images
        _ = vk.vkGetSwapchainImagesKHR(self.device, self.swapchain, &self.swapchain_image_count, null);
        // Assert swapchain image count fits our fixed array - fail fast if assumption violated
        std.debug.assert(self.swapchain_image_count <= 8);
        var img_count: u32 = @min(self.swapchain_image_count, 8);
        _ = vk.vkGetSwapchainImagesKHR(self.device, self.swapchain, &img_count, &self.swapchain_images);
        self.swapchain_image_count = img_count;

        // Create new image views
        for (0..img_count) |i| {
            const view_info = vk.ImageViewCreateInfo{
                .sType = vk.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .image = self.swapchain_images[i],
                .viewType = vk.VK_IMAGE_VIEW_TYPE_2D,
                .format = self.swapchain_format,
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

            const res = vk.vkCreateImageView(self.device, &view_info, null, &self.swapchain_image_views[i]);
            if (!vk.succeeded(res)) {
                return error.ImageViewCreationFailed;
            }
        }

        // Recreate MSAA resources if needed
        try self.createMSAAResources();

        // Recreate framebuffers
        const use_msaa = self.sample_count != vk.VK_SAMPLE_COUNT_1_BIT;

        for (0..self.swapchain_image_count) |i| {
            if (use_msaa) {
                // MSAA: attachment 0 = MSAA color, attachment 1 = resolve (swapchain)
                const attachments = [_]vk.ImageView{ self.msaa_view, self.swapchain_image_views[i] };

                const framebuffer_info = vk.FramebufferCreateInfo{
                    .sType = vk.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
                    .pNext = null,
                    .flags = 0,
                    .renderPass = self.render_pass,
                    .attachmentCount = 2,
                    .pAttachments = &attachments,
                    .width = self.swapchain_extent.width,
                    .height = self.swapchain_extent.height,
                    .layers = 1,
                };

                const res = vk.vkCreateFramebuffer(self.device, &framebuffer_info, null, &self.framebuffers[i]);
                if (!vk.succeeded(res)) {
                    return error.FramebufferCreationFailed;
                }
            } else {
                // Non-MSAA: single attachment
                const attachments = [_]vk.ImageView{self.swapchain_image_views[i]};

                const framebuffer_info = vk.FramebufferCreateInfo{
                    .sType = vk.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
                    .pNext = null,
                    .flags = 0,
                    .renderPass = self.render_pass,
                    .attachmentCount = 1,
                    .pAttachments = &attachments,
                    .width = self.swapchain_extent.width,
                    .height = self.swapchain_extent.height,
                    .layers = 1,
                };

                const res = vk.vkCreateFramebuffer(self.device, &framebuffer_info, null, &self.framebuffers[i]);
                if (!vk.succeeded(res)) {
                    return error.FramebufferCreationFailed;
                }
            }
        }
    }

    /// Upload atlas texture
    pub fn uploadAtlas(self: *Self, data: []const u8, width: u32, height: u32) !void {
        if (!self.initialized) return error.NotInitialized;

        // Skip if same size and already uploaded
        if (self.atlas_width == width and self.atlas_height == height and self.atlas_image != null) {
            // Just update the data via staging buffer
            try self.uploadAtlasData(data, width, height);
            return;
        }

        // Destroy old atlas if exists
        if (self.atlas_view) |view| {
            vk.vkDestroyImageView(self.device, view, null);
            self.atlas_view = null;
        }
        if (self.atlas_image) |image| {
            vk.vkDestroyImage(self.device, image, null);
            self.atlas_image = null;
        }
        if (self.atlas_memory) |mem| {
            vk.vkFreeMemory(self.device, mem, null);
            self.atlas_memory = null;
        }

        // Create new atlas image
        const image_info = vk.ImageCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .imageType = vk.VK_IMAGE_TYPE_2D,
            .format = vk.VK_FORMAT_R8_UNORM,
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

        var result = vk.vkCreateImage(self.device, &image_info, null, &self.atlas_image);
        if (!vk.succeeded(result)) {
            return error.AtlasImageCreationFailed;
        }

        // Allocate memory for image
        var mem_requirements: vk.MemoryRequirements = undefined;
        vk.vkGetImageMemoryRequirements(self.device, self.atlas_image, &mem_requirements);

        const mem_type_index = vk.findMemoryType(
            &self.mem_properties,
            mem_requirements.memoryTypeBits,
            vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        ) orelse return error.NoSuitableMemoryType;

        const alloc_info = vk.MemoryAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = null,
            .allocationSize = mem_requirements.size,
            .memoryTypeIndex = mem_type_index,
        };

        result = vk.vkAllocateMemory(self.device, &alloc_info, null, &self.atlas_memory);
        if (!vk.succeeded(result)) {
            return error.AtlasMemoryAllocationFailed;
        }

        _ = vk.vkBindImageMemory(self.device, self.atlas_image, self.atlas_memory, 0);

        // Create image view
        const view_info = vk.ImageViewCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .image = self.atlas_image,
            .viewType = vk.VK_IMAGE_VIEW_TYPE_2D,
            .format = vk.VK_FORMAT_R8_UNORM,
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

        result = vk.vkCreateImageView(self.device, &view_info, null, &self.atlas_view);
        if (!vk.succeeded(result)) {
            return error.AtlasImageViewCreationFailed;
        }

        self.atlas_width = width;
        self.atlas_height = height;

        // Upload data
        try self.uploadAtlasData(data, width, height);

        // Update text descriptor set
        self.updateTextDescriptorSet();
    }

    fn uploadAtlasData(self: *Self, data: []const u8, width: u32, height: u32) !void {
        // Assertions: validate input data
        std.debug.assert(width > 0 and height > 0);
        std.debug.assert(data.len == width * height);
        std.debug.assert(self.transfer_command_buffer != null);
        std.debug.assert(self.transfer_fence != null);

        const image_size: vk.DeviceSize = @intCast(width * height);

        // Create or resize staging buffer if needed
        if (self.staging_buffer == null or self.staging_size < image_size) {
            if (self.staging_buffer) |buf| {
                vk.vkDestroyBuffer(self.device, buf, null);
            }
            if (self.staging_memory) |mem| {
                vk.vkUnmapMemory(self.device, mem);
                vk.vkFreeMemory(self.device, mem, null);
            }

            try self.createBuffer(
                image_size,
                vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                &self.staging_buffer,
                &self.staging_memory,
            );
            _ = vk.vkMapMemory(self.device, self.staging_memory, 0, image_size, 0, &self.staging_mapped);
            self.staging_size = image_size;
        }

        // Copy data to staging buffer
        if (self.staging_mapped) |ptr| {
            const dest: [*]u8 = @ptrCast(ptr);
            @memcpy(dest[0..data.len], data);
        }

        // Use dedicated transfer command buffer (avoids race with render command buffers)
        const cmd = self.transfer_command_buffer;
        _ = vk.vkResetCommandBuffer(cmd, 0);

        const begin_info = vk.CommandBufferBeginInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = null,
            .flags = 0,
            .pInheritanceInfo = null,
        };
        _ = vk.vkBeginCommandBuffer(cmd, &begin_info);

        // Transition image to transfer dst
        const barrier_to_transfer = vk.ImageMemoryBarrier{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .pNext = null,
            .srcAccessMask = 0,
            .dstAccessMask = vk.VK_ACCESS_TRANSFER_WRITE_BIT,
            .oldLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
            .newLayout = vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
            .image = self.atlas_image,
            .subresourceRange = .{
                .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };

        vk.vkCmdPipelineBarrier(
            cmd,
            vk.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
            vk.VK_PIPELINE_STAGE_TRANSFER_BIT,
            0,
            0,
            null,
            0,
            null,
            1,
            &barrier_to_transfer,
        );

        // Copy buffer to image
        const region = vk.BufferImageCopy{
            .bufferOffset = 0,
            .bufferRowLength = 0,
            .bufferImageHeight = 0,
            .imageSubresource = .{
                .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
                .mipLevel = 0,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
            .imageOffset = .{ .x = 0, .y = 0, .z = 0 },
            .imageExtent = .{ .width = width, .height = height, .depth = 1 },
        };

        vk.vkCmdCopyBufferToImage(
            cmd,
            self.staging_buffer,
            self.atlas_image,
            vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            1,
            &region,
        );

        // Transition image to shader read
        const barrier_to_shader = vk.ImageMemoryBarrier{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .pNext = null,
            .srcAccessMask = vk.VK_ACCESS_TRANSFER_WRITE_BIT,
            .dstAccessMask = vk.VK_ACCESS_SHADER_READ_BIT,
            .oldLayout = vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .newLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            .srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
            .image = self.atlas_image,
            .subresourceRange = .{
                .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };

        vk.vkCmdPipelineBarrier(
            cmd,
            vk.VK_PIPELINE_STAGE_TRANSFER_BIT,
            vk.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
            0,
            0,
            null,
            0,
            null,
            1,
            &barrier_to_shader,
        );

        _ = vk.vkEndCommandBuffer(cmd);

        // Reset fence before submit
        _ = vk.vkResetFences(self.device, 1, &self.transfer_fence);

        // Submit with fence for synchronization
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

        // Wait for transfer to complete before returning
        _ = vk.vkWaitForFences(self.device, 1, &self.transfer_fence, vk.TRUE, std.math.maxInt(u64));

        self.atlas_generation += 1;
    }

    fn updateTextDescriptorSet(self: *Self) void {
        if (self.atlas_view == null or self.atlas_sampler == null) return;

        const buffer_infos = [_]vk.DescriptorBufferInfo{
            .{
                .buffer = self.glyph_buffer,
                .offset = 0,
                .range = @sizeOf(GpuGlyph) * MAX_GLYPHS,
            },
            .{
                .buffer = self.uniform_buffer,
                .offset = 0,
                .range = @sizeOf(Uniforms),
            },
        };

        const image_info = vk.DescriptorImageInfo{
            .sampler = null,
            .imageView = self.atlas_view,
            .imageLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        };

        const sampler_info = vk.DescriptorImageInfo{
            .sampler = self.atlas_sampler,
            .imageView = null,
            .imageLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
        };

        const writes = [_]vk.WriteDescriptorSet{
            .{
                .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .pNext = null,
                .dstSet = self.text_descriptor_set,
                .dstBinding = 0,
                .dstArrayElement = 0,
                .descriptorCount = 1,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .pImageInfo = null,
                .pBufferInfo = &buffer_infos[0],
                .pTexelBufferView = null,
            },
            .{
                .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .pNext = null,
                .dstSet = self.text_descriptor_set,
                .dstBinding = 1,
                .dstArrayElement = 0,
                .descriptorCount = 1,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                .pImageInfo = null,
                .pBufferInfo = &buffer_infos[1],
                .pTexelBufferView = null,
            },
            .{
                .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .pNext = null,
                .dstSet = self.text_descriptor_set,
                .dstBinding = 2,
                .dstArrayElement = 0,
                .descriptorCount = 1,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE,
                .pImageInfo = &image_info,
                .pBufferInfo = null,
                .pTexelBufferView = null,
            },
            .{
                .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .pNext = null,
                .dstSet = self.text_descriptor_set,
                .dstBinding = 3,
                .dstArrayElement = 0,
                .descriptorCount = 1,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_SAMPLER,
                .pImageInfo = &sampler_info,
                .pBufferInfo = null,
                .pTexelBufferView = null,
            },
        };

        vk.vkUpdateDescriptorSets(self.device, writes.len, &writes, 0, null);
    }

    /// Upload SVG atlas texture (RGBA format)
    pub fn uploadSvgAtlas(self: *Self, data: []const u8, width: u32, height: u32) !void {
        if (!self.initialized) return error.NotInitialized;

        // Skip if same size and already uploaded
        if (self.svg_atlas_width == width and self.svg_atlas_height == height and self.svg_atlas_image != null) {
            // Just update the data via staging buffer
            try self.uploadSvgAtlasData(data, width, height);
            return;
        }

        // Destroy old SVG atlas if exists
        if (self.svg_atlas_view) |view| {
            vk.vkDestroyImageView(self.device, view, null);
            self.svg_atlas_view = null;
        }
        if (self.svg_atlas_image) |image| {
            vk.vkDestroyImage(self.device, image, null);
            self.svg_atlas_image = null;
        }
        if (self.svg_atlas_memory) |mem| {
            vk.vkFreeMemory(self.device, mem, null);
            self.svg_atlas_memory = null;
        }

        // Create new SVG atlas image (RGBA format)
        const image_info = vk.ImageCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .imageType = vk.VK_IMAGE_TYPE_2D,
            .format = vk.VK_FORMAT_R8G8B8A8_UNORM,
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

        var result = vk.vkCreateImage(self.device, &image_info, null, &self.svg_atlas_image);
        if (!vk.succeeded(result)) {
            return error.AtlasImageCreationFailed;
        }

        // Allocate memory for image
        var mem_requirements: vk.MemoryRequirements = undefined;
        vk.vkGetImageMemoryRequirements(self.device, self.svg_atlas_image, &mem_requirements);

        const mem_type_index = vk.findMemoryType(
            &self.mem_properties,
            mem_requirements.memoryTypeBits,
            vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        ) orelse return error.NoSuitableMemoryType;

        const alloc_info = vk.MemoryAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = null,
            .allocationSize = mem_requirements.size,
            .memoryTypeIndex = mem_type_index,
        };

        result = vk.vkAllocateMemory(self.device, &alloc_info, null, &self.svg_atlas_memory);
        if (!vk.succeeded(result)) {
            return error.AtlasMemoryAllocationFailed;
        }

        _ = vk.vkBindImageMemory(self.device, self.svg_atlas_image, self.svg_atlas_memory, 0);

        // Create image view
        const view_info = vk.ImageViewCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .image = self.svg_atlas_image,
            .viewType = vk.VK_IMAGE_VIEW_TYPE_2D,
            .format = vk.VK_FORMAT_R8G8B8A8_UNORM,
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

        result = vk.vkCreateImageView(self.device, &view_info, null, &self.svg_atlas_view);
        if (!vk.succeeded(result)) {
            return error.AtlasImageViewCreationFailed;
        }

        self.svg_atlas_width = width;
        self.svg_atlas_height = height;

        // Upload data
        try self.uploadSvgAtlasData(data, width, height);

        // Update SVG descriptor set
        self.updateSvgDescriptorSet();
    }

    fn uploadSvgAtlasData(self: *Self, data: []const u8, width: u32, height: u32) !void {
        // Assertions: validate input data
        std.debug.assert(width > 0 and height > 0);
        std.debug.assert(data.len == width * height * 4); // RGBA
        std.debug.assert(self.transfer_command_buffer != null);
        std.debug.assert(self.transfer_fence != null);

        const image_size: vk.DeviceSize = @intCast(width * height * 4); // RGBA = 4 bytes per pixel

        // Create or resize staging buffer if needed
        if (self.staging_buffer == null or self.staging_size < image_size) {
            if (self.staging_buffer) |buf| {
                vk.vkDestroyBuffer(self.device, buf, null);
            }
            if (self.staging_memory) |mem| {
                vk.vkUnmapMemory(self.device, mem);
                vk.vkFreeMemory(self.device, mem, null);
            }

            try self.createBuffer(
                image_size,
                vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                &self.staging_buffer,
                &self.staging_memory,
            );
            _ = vk.vkMapMemory(self.device, self.staging_memory, 0, image_size, 0, &self.staging_mapped);
            self.staging_size = image_size;
        }

        // Copy data to staging buffer
        if (self.staging_mapped) |ptr| {
            const dest: [*]u8 = @ptrCast(ptr);
            @memcpy(dest[0..data.len], data);
        }

        // Use dedicated transfer command buffer (avoids race with render command buffers)
        const cmd = self.transfer_command_buffer;
        _ = vk.vkResetCommandBuffer(cmd, 0);

        const begin_info = vk.CommandBufferBeginInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = null,
            .flags = 0,
            .pInheritanceInfo = null,
        };
        _ = vk.vkBeginCommandBuffer(cmd, &begin_info);

        // Transition image to transfer dst
        const barrier_to_transfer = vk.ImageMemoryBarrier{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .pNext = null,
            .srcAccessMask = 0,
            .dstAccessMask = vk.VK_ACCESS_TRANSFER_WRITE_BIT,
            .oldLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
            .newLayout = vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
            .image = self.svg_atlas_image,
            .subresourceRange = .{
                .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };

        vk.vkCmdPipelineBarrier(
            cmd,
            vk.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
            vk.VK_PIPELINE_STAGE_TRANSFER_BIT,
            0,
            0,
            null,
            0,
            null,
            1,
            &barrier_to_transfer,
        );

        // Copy buffer to image
        const region = vk.BufferImageCopy{
            .bufferOffset = 0,
            .bufferRowLength = 0,
            .bufferImageHeight = 0,
            .imageSubresource = .{
                .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
                .mipLevel = 0,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
            .imageOffset = .{ .x = 0, .y = 0, .z = 0 },
            .imageExtent = .{ .width = width, .height = height, .depth = 1 },
        };

        vk.vkCmdCopyBufferToImage(
            cmd,
            self.staging_buffer,
            self.svg_atlas_image,
            vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            1,
            &region,
        );

        // Transition image to shader read
        const barrier_to_shader = vk.ImageMemoryBarrier{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .pNext = null,
            .srcAccessMask = vk.VK_ACCESS_TRANSFER_WRITE_BIT,
            .dstAccessMask = vk.VK_ACCESS_SHADER_READ_BIT,
            .oldLayout = vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .newLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            .srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
            .image = self.svg_atlas_image,
            .subresourceRange = .{
                .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };

        vk.vkCmdPipelineBarrier(
            cmd,
            vk.VK_PIPELINE_STAGE_TRANSFER_BIT,
            vk.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
            0,
            0,
            null,
            0,
            null,
            1,
            &barrier_to_shader,
        );

        _ = vk.vkEndCommandBuffer(cmd);

        // Reset fence before submit
        _ = vk.vkResetFences(self.device, 1, &self.transfer_fence);

        // Submit with fence for synchronization
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

        // Wait for transfer to complete before returning
        _ = vk.vkWaitForFences(self.device, 1, &self.transfer_fence, vk.TRUE, std.math.maxInt(u64));

        self.svg_atlas_generation += 1;
    }

    fn updateSvgDescriptorSet(self: *Self) void {
        if (self.svg_atlas_view == null or self.atlas_sampler == null) return;

        const buffer_infos = [_]vk.DescriptorBufferInfo{
            .{
                .buffer = self.svg_buffer,
                .offset = 0,
                .range = @sizeOf(GpuSvg) * MAX_SVGS,
            },
            .{
                .buffer = self.uniform_buffer,
                .offset = 0,
                .range = @sizeOf(Uniforms),
            },
        };

        const image_info = vk.DescriptorImageInfo{
            .sampler = null,
            .imageView = self.svg_atlas_view,
            .imageLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        };

        const sampler_info = vk.DescriptorImageInfo{
            .sampler = self.atlas_sampler,
            .imageView = null,
            .imageLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
        };

        const writes = [_]vk.WriteDescriptorSet{
            .{
                .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .pNext = null,
                .dstSet = self.svg_descriptor_set,
                .dstBinding = 0,
                .dstArrayElement = 0,
                .descriptorCount = 1,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .pImageInfo = null,
                .pBufferInfo = &buffer_infos[0],
                .pTexelBufferView = null,
            },
            .{
                .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .pNext = null,
                .dstSet = self.svg_descriptor_set,
                .dstBinding = 1,
                .dstArrayElement = 0,
                .descriptorCount = 1,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                .pImageInfo = null,
                .pBufferInfo = &buffer_infos[1],
                .pTexelBufferView = null,
            },
            .{
                .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .pNext = null,
                .dstSet = self.svg_descriptor_set,
                .dstBinding = 2,
                .dstArrayElement = 0,
                .descriptorCount = 1,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE,
                .pImageInfo = &image_info,
                .pBufferInfo = null,
                .pTexelBufferView = null,
            },
            .{
                .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .pNext = null,
                .dstSet = self.svg_descriptor_set,
                .dstBinding = 3,
                .dstArrayElement = 0,
                .descriptorCount = 1,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_SAMPLER,
                .pImageInfo = &sampler_info,
                .pBufferInfo = null,
                .pTexelBufferView = null,
            },
        };

        vk.vkUpdateDescriptorSets(self.device, writes.len, &writes, 0, null);
    }

    /// Upload Image atlas texture (RGBA format)
    pub fn uploadImageAtlas(self: *Self, data: []const u8, width: u32, height: u32) !void {
        if (!self.initialized) return error.NotInitialized;

        // Skip if same size and already uploaded
        if (self.image_atlas_width == width and self.image_atlas_height == height and self.image_atlas_image != null) {
            // Just update the data via staging buffer
            try self.uploadImageAtlasData(data, width, height);
            return;
        }

        // Destroy old Image atlas if exists
        if (self.image_atlas_view) |view| {
            vk.vkDestroyImageView(self.device, view, null);
            self.image_atlas_view = null;
        }
        if (self.image_atlas_image) |image| {
            vk.vkDestroyImage(self.device, image, null);
            self.image_atlas_image = null;
        }
        if (self.image_atlas_memory) |mem| {
            vk.vkFreeMemory(self.device, mem, null);
            self.image_atlas_memory = null;
        }

        // Create new Image atlas image (RGBA format)
        const image_info = vk.ImageCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .imageType = vk.VK_IMAGE_TYPE_2D,
            .format = vk.VK_FORMAT_R8G8B8A8_UNORM,
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

        var result = vk.vkCreateImage(self.device, &image_info, null, &self.image_atlas_image);
        if (!vk.succeeded(result)) {
            return error.AtlasImageCreationFailed;
        }

        // Allocate memory for image
        var mem_requirements: vk.MemoryRequirements = undefined;
        vk.vkGetImageMemoryRequirements(self.device, self.image_atlas_image, &mem_requirements);

        const mem_type_index = vk.findMemoryType(
            &self.mem_properties,
            mem_requirements.memoryTypeBits,
            vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        ) orelse return error.NoSuitableMemoryType;

        const alloc_info = vk.MemoryAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = null,
            .allocationSize = mem_requirements.size,
            .memoryTypeIndex = mem_type_index,
        };

        result = vk.vkAllocateMemory(self.device, &alloc_info, null, &self.image_atlas_memory);
        if (!vk.succeeded(result)) {
            return error.AtlasMemoryAllocationFailed;
        }

        _ = vk.vkBindImageMemory(self.device, self.image_atlas_image, self.image_atlas_memory, 0);

        // Create image view
        const view_info = vk.ImageViewCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .image = self.image_atlas_image,
            .viewType = vk.VK_IMAGE_VIEW_TYPE_2D,
            .format = vk.VK_FORMAT_R8G8B8A8_UNORM,
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

        result = vk.vkCreateImageView(self.device, &view_info, null, &self.image_atlas_view);
        if (!vk.succeeded(result)) {
            return error.AtlasImageViewCreationFailed;
        }

        self.image_atlas_width = width;
        self.image_atlas_height = height;

        // Upload data
        try self.uploadImageAtlasData(data, width, height);

        // Update Image descriptor set
        self.updateImageDescriptorSet();
    }

    fn uploadImageAtlasData(self: *Self, data: []const u8, width: u32, height: u32) !void {
        // Assertions: validate input data
        std.debug.assert(width > 0 and height > 0);
        std.debug.assert(data.len == width * height * 4); // RGBA
        std.debug.assert(self.transfer_command_buffer != null);
        std.debug.assert(self.transfer_fence != null);

        const image_size: vk.DeviceSize = @intCast(width * height * 4); // RGBA = 4 bytes per pixel

        // Create or resize staging buffer if needed
        if (self.staging_buffer == null or self.staging_size < image_size) {
            if (self.staging_buffer) |buf| {
                vk.vkDestroyBuffer(self.device, buf, null);
            }
            if (self.staging_memory) |mem| {
                vk.vkUnmapMemory(self.device, mem);
                vk.vkFreeMemory(self.device, mem, null);
            }

            try self.createBuffer(
                image_size,
                vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                &self.staging_buffer,
                &self.staging_memory,
            );
            _ = vk.vkMapMemory(self.device, self.staging_memory, 0, image_size, 0, &self.staging_mapped);
            self.staging_size = image_size;
        }

        // Copy data to staging buffer
        if (self.staging_mapped) |ptr| {
            const dest: [*]u8 = @ptrCast(ptr);
            @memcpy(dest[0..data.len], data);
        }

        // Use dedicated transfer command buffer (avoids race with render command buffers)
        const cmd = self.transfer_command_buffer;
        _ = vk.vkResetCommandBuffer(cmd, 0);

        const begin_info = vk.CommandBufferBeginInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = null,
            .flags = 0,
            .pInheritanceInfo = null,
        };
        _ = vk.vkBeginCommandBuffer(cmd, &begin_info);

        // Transition image to transfer dst
        const barrier_to_transfer = vk.ImageMemoryBarrier{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .pNext = null,
            .srcAccessMask = 0,
            .dstAccessMask = vk.VK_ACCESS_TRANSFER_WRITE_BIT,
            .oldLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
            .newLayout = vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
            .image = self.image_atlas_image,
            .subresourceRange = .{
                .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };

        vk.vkCmdPipelineBarrier(
            cmd,
            vk.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
            vk.VK_PIPELINE_STAGE_TRANSFER_BIT,
            0,
            0,
            null,
            0,
            null,
            1,
            &barrier_to_transfer,
        );

        // Copy buffer to image
        const region = vk.BufferImageCopy{
            .bufferOffset = 0,
            .bufferRowLength = 0,
            .bufferImageHeight = 0,
            .imageSubresource = .{
                .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
                .mipLevel = 0,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
            .imageOffset = .{ .x = 0, .y = 0, .z = 0 },
            .imageExtent = .{ .width = width, .height = height, .depth = 1 },
        };

        vk.vkCmdCopyBufferToImage(
            cmd,
            self.staging_buffer,
            self.image_atlas_image,
            vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            1,
            &region,
        );

        // Transition image to shader read
        const barrier_to_shader = vk.ImageMemoryBarrier{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .pNext = null,
            .srcAccessMask = vk.VK_ACCESS_TRANSFER_WRITE_BIT,
            .dstAccessMask = vk.VK_ACCESS_SHADER_READ_BIT,
            .oldLayout = vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .newLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            .srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
            .image = self.image_atlas_image,
            .subresourceRange = .{
                .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };

        vk.vkCmdPipelineBarrier(
            cmd,
            vk.VK_PIPELINE_STAGE_TRANSFER_BIT,
            vk.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
            0,
            0,
            null,
            0,
            null,
            1,
            &barrier_to_shader,
        );

        _ = vk.vkEndCommandBuffer(cmd);

        // Reset fence before submit
        _ = vk.vkResetFences(self.device, 1, &self.transfer_fence);

        // Submit with fence for synchronization
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

        // Wait for transfer to complete before returning
        _ = vk.vkWaitForFences(self.device, 1, &self.transfer_fence, vk.TRUE, std.math.maxInt(u64));

        self.image_atlas_generation += 1;
    }

    fn updateImageDescriptorSet(self: *Self) void {
        if (self.image_atlas_view == null or self.atlas_sampler == null) return;

        const buffer_infos = [_]vk.DescriptorBufferInfo{
            .{
                .buffer = self.image_buffer,
                .offset = 0,
                .range = @sizeOf(GpuImage) * MAX_IMAGES,
            },
            .{
                .buffer = self.uniform_buffer,
                .offset = 0,
                .range = @sizeOf(Uniforms),
            },
        };

        const image_info = vk.DescriptorImageInfo{
            .sampler = null,
            .imageView = self.image_atlas_view,
            .imageLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        };

        const sampler_info = vk.DescriptorImageInfo{
            .sampler = self.atlas_sampler,
            .imageView = null,
            .imageLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
        };

        const writes = [_]vk.WriteDescriptorSet{
            .{
                .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .pNext = null,
                .dstSet = self.image_descriptor_set,
                .dstBinding = 0,
                .dstArrayElement = 0,
                .descriptorCount = 1,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .pImageInfo = null,
                .pBufferInfo = &buffer_infos[0],
                .pTexelBufferView = null,
            },
            .{
                .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .pNext = null,
                .dstSet = self.image_descriptor_set,
                .dstBinding = 1,
                .dstArrayElement = 0,
                .descriptorCount = 1,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                .pImageInfo = null,
                .pBufferInfo = &buffer_infos[1],
                .pTexelBufferView = null,
            },
            .{
                .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .pNext = null,
                .dstSet = self.image_descriptor_set,
                .dstBinding = 2,
                .dstArrayElement = 0,
                .descriptorCount = 1,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE,
                .pImageInfo = &image_info,
                .pBufferInfo = null,
                .pTexelBufferView = null,
            },
            .{
                .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .pNext = null,
                .dstSet = self.image_descriptor_set,
                .dstBinding = 3,
                .dstArrayElement = 0,
                .descriptorCount = 1,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_SAMPLER,
                .pImageInfo = &sampler_info,
                .pBufferInfo = null,
                .pTexelBufferView = null,
            },
        };

        vk.vkUpdateDescriptorSets(self.device, writes.len, &writes, 0, null);
    }

    /// Render a frame using batched scene renderer for proper z-ordering
    pub fn render(self: *Self, scene: *const Scene) void {
        if (!self.initialized) return;

        // Check if swapchain needs recreation from previous frame
        if (self.swapchain_needs_recreate) {
            self.swapchain_needs_recreate = false;
            _ = vk.vkDeviceWaitIdle(self.device);
            self.recreateSwapchain(self.swapchain_extent.width, self.swapchain_extent.height) catch |err| {
                std.debug.print("Failed to recreate swapchain: {}\n", .{err});
                return;
            };
        }

        const frame = self.current_frame;

        // Wait for previous frame
        _ = vk.vkWaitForFences(self.device, 1, &self.in_flight_fences[frame], vk.TRUE, std.math.maxInt(u64));
        _ = vk.vkResetFences(self.device, 1, &self.in_flight_fences[frame]);

        // Acquire next image
        var image_index: u32 = 0;
        const acquire_result = vk.vkAcquireNextImageKHR(
            self.device,
            self.swapchain,
            std.math.maxInt(u64),
            self.image_available_semaphores[frame],
            null,
            &image_index,
        );

        // Handle acquire result exhaustively
        switch (acquire_result) {
            vk.SUCCESS => {
                // Image acquired successfully, continue rendering
            },
            vk.SUBOPTIMAL_KHR => {
                // Image acquired but swapchain properties don't match surface
                // We can still render this frame, but schedule recreation for next frame
                self.swapchain_needs_recreate = true;
            },
            vk.ERROR_OUT_OF_DATE_KHR => {
                // Swapchain is incompatible with surface, must recreate before rendering
                self.swapchain_needs_recreate = true;
                return;
            },
            vk.TIMEOUT, vk.NOT_READY => {
                // Should not happen with maxInt timeout, but handle gracefully
                std.debug.print("vkAcquireNextImageKHR returned unexpected timeout/not_ready\n", .{});
                return;
            },
            else => {
                // Any other result is an error we don't expect
                std.debug.print("vkAcquireNextImageKHR failed with unexpected result: {}\n", .{acquire_result});
                unreachable;
            },
        }

        // Assert image index is valid
        std.debug.assert(image_index < self.swapchain_image_count);

        // Record command buffer
        const cmd = self.command_buffers[frame];
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

        // Use batched scene renderer for proper z-ordering
        const pipelines = scene_renderer.Pipelines{
            .unified_pipeline = self.unified_pipeline,
            .unified_pipeline_layout = self.unified_pipeline_layout,
            .text_pipeline = self.text_pipeline,
            .text_pipeline_layout = self.text_pipeline_layout,
            .svg_pipeline = self.svg_pipeline,
            .svg_pipeline_layout = self.svg_pipeline_layout,
            .image_pipeline = self.image_pipeline,
            .image_pipeline_layout = self.image_pipeline_layout,
            .unified_descriptor_set = self.unified_descriptor_set,
            .text_descriptor_set = self.text_descriptor_set,
            .svg_descriptor_set = self.svg_descriptor_set,
            .image_descriptor_set = self.image_descriptor_set,
            .primitive_mapped = self.primitive_mapped,
            .glyph_mapped = self.glyph_mapped,
            .svg_mapped = self.svg_mapped,
            .image_mapped = self.image_mapped,
            .atlas_view = self.atlas_view,
            .svg_atlas_view = self.svg_atlas_view,
            .image_atlas_view = self.image_atlas_view,
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
            .pWaitSemaphores = &self.image_available_semaphores[frame],
            .pWaitDstStageMask = &wait_stages,
            .commandBufferCount = 1,
            .pCommandBuffers = &cmd,
            .signalSemaphoreCount = 1,
            .pSignalSemaphores = &self.render_finished_semaphores[frame],
        };

        _ = vk.vkQueueSubmit(self.graphics_queue, 1, &submit_info, self.in_flight_fences[frame]);

        // Present
        const present_info = vk.PresentInfoKHR{
            .sType = vk.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
            .pNext = null,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &self.render_finished_semaphores[frame],
            .swapchainCount = 1,
            .pSwapchains = &self.swapchain,
            .pImageIndices = &image_index,
            .pResults = null,
        };

        const present_result = vk.vkQueuePresentKHR(self.present_queue, &present_info);

        // Handle present result exhaustively
        switch (present_result) {
            vk.SUCCESS => {
                // Presented successfully
            },
            vk.SUBOPTIMAL_KHR => {
                // Presented but swapchain properties don't match surface
                // Schedule recreation for next frame
                self.swapchain_needs_recreate = true;
            },
            vk.ERROR_OUT_OF_DATE_KHR => {
                // Swapchain became incompatible during present
                // Schedule recreation for next frame
                self.swapchain_needs_recreate = true;
            },
            else => {
                // Any other result is an error we don't expect
                std.debug.print("vkQueuePresentKHR failed with unexpected result: {}\n", .{present_result});
                unreachable;
            },
        }

        self.current_frame = (frame + 1) % MAX_FRAMES_IN_FLIGHT;
    }
};
