//! Hand-written Vulkan bindings for Linux GPU rendering.
//!
//! These declarations cover only the subset of the Vulkan C API that Gooey's
//! 2D renderer uses on native Linux with Wayland. They replace an `@cImport`
//! of `vulkan/vulkan.h`, which Zig 0.17 removed from the language.
//!
//! Why hand-written rather than generated at build time: every other native
//! backend (Wayland, D-Bus, FreeType, libpng, CoreText, Metal) is declared the
//! same way, CLAUDE.md section 12 forbids package dependencies, and with no C
//! headers involved the Linux tree builds and type-checks from any host.
//!
//! Why this is safe: Khronos never changes the layout of a released struct or
//! the value of a released enumerant, so a binding that matches `vulkan.h`
//! once matches it forever. The struct, union, handle, constant, and function
//! declarations were derived mechanically from the Khronos registry (`vk.xml`)
//! and verified field by field against translate-c output of `vulkan.h`
//! (size, alignment, and every field offset). The comptime block at the end of
//! this file pins those measured layouts so a future edit cannot drift.
//!
//! Conventions:
//! - Handles are distinct nullable opaque pointers, so `null` means
//!   `VK_NULL_HANDLE` and passing a `Buffer` where an `Image` is expected is a
//!   compile error.
//! - Enumerations and flag types are `u32` aliases (`Result` is `i32`), the
//!   exact C ABI on every supported target.
//! - Struct pointer fields are always optional because the C ABI cannot express
//!   count-dependent validity. Array pointers are `[*]`, single objects are
//!   `*`, and null-terminated strings are `[*:0]`.
//! - Function parameters follow the registry's `optional` attribute.
//!
//! Only 64-bit targets are supported: on 32-bit targets Vulkan non-dispatchable
//! handles are `uint64_t`, not pointers.
//!
//! Reference: https://registry.khronos.org/vulkan/specs/1.3/html/

const std = @import("std");
const assert = std.debug.assert;

comptime {
    // Non-dispatchable handles are pointers only on 64-bit targets.
    assert(@sizeOf(usize) == 8);
}

// =============================================================================
// Basic Types
// =============================================================================

pub const Bool32 = u32;
pub const DeviceSize = u64;
pub const Flags = u32;
pub const SampleMask = u32;

pub const FALSE: Bool32 = 0;
pub const TRUE: Bool32 = 1;

pub const WHOLE_SIZE: DeviceSize = ~@as(DeviceSize, 0);
pub const QUEUE_FAMILY_IGNORED: u32 = ~@as(u32, 0);
pub const SUBPASS_EXTERNAL: u32 = ~@as(u32, 0);

/// `VK_MAKE_API_VERSION(0, 1, 0, 0)`: variant in bits 29..31, major in
/// 22..28, minor in 12..21, patch in 0..11.
pub const API_VERSION_1_0: u32 = (1 << 22) | (0 << 12) | 0;

// =============================================================================
// Enumeration and Flag Types
// =============================================================================

pub const AccessFlagBits = u32;
pub const AccessFlags = Flags;
pub const AttachmentDescriptionFlags = Flags;
pub const AttachmentLoadOp = u32;
pub const AttachmentStoreOp = u32;
pub const BlendFactor = u32;
pub const BlendOp = u32;
pub const BorderColor = u32;
pub const BufferCreateFlags = Flags;
pub const BufferUsageFlagBits = u32;
pub const BufferUsageFlags = Flags;
pub const ColorComponentFlagBits = u32;
pub const ColorComponentFlags = Flags;
pub const ColorSpaceKHR = u32;
pub const CommandBufferLevel = u32;
pub const CommandBufferResetFlags = Flags;
pub const CommandBufferUsageFlagBits = u32;
pub const CommandBufferUsageFlags = Flags;
pub const CommandPoolCreateFlagBits = u32;
pub const CommandPoolCreateFlags = Flags;
pub const CompareOp = u32;
pub const ComponentSwizzle = u32;
pub const CompositeAlphaFlagBitsKHR = u32;
pub const CompositeAlphaFlagsKHR = Flags;
pub const CullModeFlagBits = u32;
pub const CullModeFlags = Flags;
pub const DebugUtilsMessageSeverityFlagBitsEXT = u32;
pub const DebugUtilsMessageSeverityFlagsEXT = Flags;
pub const DebugUtilsMessageTypeFlagBitsEXT = u32;
pub const DebugUtilsMessageTypeFlagsEXT = Flags;
pub const DebugUtilsMessengerCallbackDataFlagsEXT = Flags;
pub const DebugUtilsMessengerCreateFlagsEXT = Flags;
pub const DependencyFlagBits = u32;
pub const DependencyFlags = Flags;
pub const DescriptorPoolCreateFlags = Flags;
pub const DescriptorSetLayoutCreateFlags = Flags;
pub const DescriptorType = u32;
pub const DeviceCreateFlags = Flags;
pub const DeviceQueueCreateFlags = Flags;
pub const DynamicState = u32;
pub const FenceCreateFlagBits = u32;
pub const FenceCreateFlags = Flags;
pub const Filter = u32;
pub const Format = u32;
pub const FramebufferCreateFlags = Flags;
pub const FrontFace = u32;
pub const ImageAspectFlagBits = u32;
pub const ImageAspectFlags = Flags;
pub const ImageCreateFlags = Flags;
pub const ImageLayout = u32;
pub const ImageTiling = u32;
pub const ImageType = u32;
pub const ImageUsageFlagBits = u32;
pub const ImageUsageFlags = Flags;
pub const ImageViewCreateFlags = Flags;
pub const ImageViewType = u32;
pub const IndexType = u32;
pub const InstanceCreateFlags = Flags;
pub const LogicOp = u32;
pub const MemoryHeapFlags = Flags;
pub const MemoryMapFlags = Flags;
pub const MemoryPropertyFlagBits = u32;
pub const MemoryPropertyFlags = Flags;
pub const ObjectType = u32;
pub const PhysicalDeviceType = u32;
pub const PipelineBindPoint = u32;
pub const PipelineCacheCreateFlags = Flags;
pub const PipelineColorBlendStateCreateFlags = Flags;
pub const PipelineCreateFlags = Flags;
pub const PipelineDepthStencilStateCreateFlags = Flags;
pub const PipelineDynamicStateCreateFlags = Flags;
pub const PipelineInputAssemblyStateCreateFlags = Flags;
pub const PipelineLayoutCreateFlags = Flags;
pub const PipelineMultisampleStateCreateFlags = Flags;
pub const PipelineRasterizationStateCreateFlags = Flags;
pub const PipelineShaderStageCreateFlags = Flags;
pub const PipelineStageFlagBits = u32;
pub const PipelineStageFlags = Flags;
pub const PipelineTessellationStateCreateFlags = Flags;
pub const PipelineVertexInputStateCreateFlags = Flags;
pub const PipelineViewportStateCreateFlags = Flags;
pub const PolygonMode = u32;
pub const PresentModeKHR = u32;
pub const PrimitiveTopology = u32;
pub const QueryControlFlags = Flags;
pub const QueryPipelineStatisticFlags = Flags;
pub const QueueFlagBits = u32;
pub const QueueFlags = Flags;
pub const RenderPassCreateFlags = Flags;
pub const SampleCountFlagBits = u32;
pub const SampleCountFlags = Flags;
pub const SamplerAddressMode = u32;
pub const SamplerCreateFlags = Flags;
pub const SamplerMipmapMode = u32;
pub const SemaphoreCreateFlags = Flags;
pub const ShaderModuleCreateFlags = Flags;
pub const ShaderStageFlagBits = u32;
pub const ShaderStageFlags = Flags;
pub const SharingMode = u32;
pub const StencilOp = u32;
pub const StructureType = u32;
pub const SubpassContents = u32;
pub const SubpassDescriptionFlags = Flags;
pub const SurfaceTransformFlagBitsKHR = u32;
pub const SurfaceTransformFlagsKHR = Flags;
pub const SwapchainCreateFlagsKHR = Flags;
pub const VertexInputRate = u32;
pub const WaylandSurfaceCreateFlagsKHR = Flags;

// =============================================================================
// Handle Types (distinct nullable opaque pointers)
// =============================================================================

pub const Instance = ?*opaque {};
pub const PhysicalDevice = ?*opaque {};
pub const Device = ?*opaque {};
pub const Queue = ?*opaque {};
pub const Surface = ?*opaque {};
pub const Swapchain = ?*opaque {};
pub const Image = ?*opaque {};
pub const ImageView = ?*opaque {};
pub const Buffer = ?*opaque {};
pub const DeviceMemory = ?*opaque {};
pub const ShaderModule = ?*opaque {};
pub const PipelineLayout = ?*opaque {};
pub const RenderPass = ?*opaque {};
pub const Pipeline = ?*opaque {};
pub const Framebuffer = ?*opaque {};
pub const CommandPool = ?*opaque {};
pub const CommandBuffer = ?*opaque {};
pub const Semaphore = ?*opaque {};
pub const Fence = ?*opaque {};
pub const DescriptorSetLayout = ?*opaque {};
pub const DescriptorPool = ?*opaque {};
pub const DescriptorSet = ?*opaque {};
pub const Sampler = ?*opaque {};
pub const PipelineCache = ?*opaque {};
pub const DebugUtilsMessengerEXT = ?*opaque {};
pub const BufferView = ?*opaque {};

/// Wayland objects, owned by `wayland.zig`; Vulkan only stores the pointers.
pub const WlDisplay = opaque {};
pub const WlSurface = opaque {};

// =============================================================================
// Result
// =============================================================================

pub const Result = i32;

pub const SUCCESS: Result = 0;
pub const NOT_READY: Result = 1;
pub const TIMEOUT: Result = 2;
pub const SUBOPTIMAL_KHR: Result = 1000001003;
pub const ERROR_OUT_OF_DATE_KHR: Result = -1000001004;

pub fn succeeded(result: Result) bool {
    return result >= 0;
}

// =============================================================================
// Constants
// =============================================================================

pub const VK_STRUCTURE_TYPE_APPLICATION_INFO: StructureType = 0;
pub const VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO: StructureType = 1;
pub const VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO: StructureType = 2;
pub const VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO: StructureType = 3;
pub const VK_STRUCTURE_TYPE_SUBMIT_INFO: StructureType = 4;
pub const VK_STRUCTURE_TYPE_PRESENT_INFO_KHR: StructureType = 1000001001;
pub const VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR: StructureType = 1000006000;
pub const VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR: StructureType = 1000001000;
pub const VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO: StructureType = 15;
pub const VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO: StructureType = 14;
pub const VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO: StructureType = 12;
pub const VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO: StructureType = 5;
pub const VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO: StructureType = 16;
pub const VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO: StructureType = 18;
pub const VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO: StructureType = 19;
pub const VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO: StructureType = 20;
pub const VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO: StructureType = 22;
pub const VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO: StructureType = 23;
pub const VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO: StructureType = 24;
pub const VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO: StructureType = 26;
pub const VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO: StructureType = 27;
pub const VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO: StructureType = 30;
pub const VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO: StructureType = 38;
pub const VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO: StructureType = 28;
pub const VK_STRUCTURE_TYPE_PIPELINE_CACHE_CREATE_INFO: StructureType = 17;
pub const VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO: StructureType = 37;
pub const VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO: StructureType = 39;
pub const VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO: StructureType = 40;
pub const VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO: StructureType = 42;
pub const VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO: StructureType = 43;
pub const VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO: StructureType = 9;
pub const VK_STRUCTURE_TYPE_FENCE_CREATE_INFO: StructureType = 8;
pub const VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO: StructureType = 32;
pub const VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO: StructureType = 33;
pub const VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO: StructureType = 34;
pub const VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET: StructureType = 35;
pub const VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO: StructureType = 31;
pub const VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER: StructureType = 45;
pub const VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT: StructureType = 1000128004;

// Format constants
pub const VK_FORMAT_UNDEFINED: Format = 0;
pub const VK_FORMAT_R8_UNORM: Format = 9;
pub const VK_FORMAT_R8G8B8A8_UNORM: Format = 37;
pub const VK_FORMAT_R8G8B8A8_SRGB: Format = 43;
pub const VK_FORMAT_B8G8R8A8_UNORM: Format = 44;
pub const VK_FORMAT_B8G8R8A8_SRGB: Format = 50;
pub const VK_FORMAT_R32_SFLOAT: Format = 100;
pub const VK_FORMAT_R32G32_SFLOAT: Format = 103;
pub const VK_FORMAT_R32G32B32_SFLOAT: Format = 106;
pub const VK_FORMAT_R32G32B32A32_SFLOAT: Format = 109;

// Color space
pub const VK_COLOR_SPACE_SRGB_NONLINEAR_KHR: ColorSpaceKHR = 0;

// Present mode
pub const VK_PRESENT_MODE_IMMEDIATE_KHR: PresentModeKHR = 0;
pub const VK_PRESENT_MODE_MAILBOX_KHR: PresentModeKHR = 1;
pub const VK_PRESENT_MODE_FIFO_KHR: PresentModeKHR = 2;
pub const VK_PRESENT_MODE_FIFO_RELAXED_KHR: PresentModeKHR = 3;

// Image layout
pub const VK_IMAGE_LAYOUT_UNDEFINED: ImageLayout = 0;
pub const VK_IMAGE_LAYOUT_GENERAL: ImageLayout = 1;
pub const VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL: ImageLayout = 2;
pub const VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL: ImageLayout = 5;
pub const VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL: ImageLayout = 6;
pub const VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL: ImageLayout = 7;
pub const VK_IMAGE_LAYOUT_PRESENT_SRC_KHR: ImageLayout = 1000001002;

// Attachment load/store ops
pub const VK_ATTACHMENT_LOAD_OP_LOAD: AttachmentLoadOp = 0;
pub const VK_ATTACHMENT_LOAD_OP_CLEAR: AttachmentLoadOp = 1;
pub const VK_ATTACHMENT_LOAD_OP_DONT_CARE: AttachmentLoadOp = 2;
pub const VK_ATTACHMENT_STORE_OP_STORE: AttachmentStoreOp = 0;
pub const VK_ATTACHMENT_STORE_OP_DONT_CARE: AttachmentStoreOp = 1;

// Image type/view type
pub const VK_IMAGE_TYPE_2D: ImageType = 1;
pub const VK_IMAGE_VIEW_TYPE_2D: ImageViewType = 1;

// Image tiling
pub const VK_IMAGE_TILING_OPTIMAL: ImageTiling = 0;
pub const VK_IMAGE_TILING_LINEAR: ImageTiling = 1;

// Sharing mode
pub const VK_SHARING_MODE_EXCLUSIVE: SharingMode = 0;

// Pipeline bind point
pub const VK_PIPELINE_BIND_POINT_GRAPHICS: PipelineBindPoint = 0;

// Primitive topology
pub const VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST: PrimitiveTopology = 3;
pub const VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP: PrimitiveTopology = 4;

// Polygon mode
pub const VK_POLYGON_MODE_FILL: PolygonMode = 0;

// Cull mode
pub const VK_CULL_MODE_NONE: CullModeFlagBits = 0;
pub const VK_CULL_MODE_BACK_BIT: CullModeFlagBits = 2;

// Front face
pub const VK_FRONT_FACE_COUNTER_CLOCKWISE: FrontFace = 0;
pub const VK_FRONT_FACE_CLOCKWISE: FrontFace = 1;

// Blend factor
pub const VK_BLEND_FACTOR_ZERO: BlendFactor = 0;
pub const VK_BLEND_FACTOR_ONE: BlendFactor = 1;
pub const VK_BLEND_FACTOR_SRC_ALPHA: BlendFactor = 6;
pub const VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA: BlendFactor = 7;
pub const VK_BLEND_FACTOR_DST_ALPHA: BlendFactor = 8;
pub const VK_BLEND_FACTOR_ONE_MINUS_DST_ALPHA: BlendFactor = 9;

// Blend op
pub const VK_BLEND_OP_ADD: BlendOp = 0;

// Dynamic state
pub const VK_DYNAMIC_STATE_VIEWPORT: DynamicState = 0;
pub const VK_DYNAMIC_STATE_SCISSOR: DynamicState = 1;

// Shader stage
pub const VK_SHADER_STAGE_VERTEX_BIT: ShaderStageFlagBits = 1;
pub const VK_SHADER_STAGE_FRAGMENT_BIT: ShaderStageFlagBits = 16;
pub const VK_SHADER_STAGE_ALL_GRAPHICS: ShaderStageFlagBits = 31;

// Descriptor type
pub const VK_DESCRIPTOR_TYPE_SAMPLER: DescriptorType = 0;
pub const VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER: DescriptorType = 1;
pub const VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE: DescriptorType = 2;
pub const VK_DESCRIPTOR_TYPE_STORAGE_IMAGE: DescriptorType = 3;
pub const VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER: DescriptorType = 6;
pub const VK_DESCRIPTOR_TYPE_STORAGE_BUFFER: DescriptorType = 7;

// Vertex input rate
pub const VK_VERTEX_INPUT_RATE_VERTEX: VertexInputRate = 0;
pub const VK_VERTEX_INPUT_RATE_INSTANCE: VertexInputRate = 1;

// Filter
pub const VK_FILTER_NEAREST: Filter = 0;
pub const VK_FILTER_LINEAR: Filter = 1;

// Sampler mipmap mode
pub const VK_SAMPLER_MIPMAP_MODE_NEAREST: SamplerMipmapMode = 0;
pub const VK_SAMPLER_MIPMAP_MODE_LINEAR: SamplerMipmapMode = 1;

// Sampler address mode
pub const VK_SAMPLER_ADDRESS_MODE_REPEAT: SamplerAddressMode = 0;
pub const VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE: SamplerAddressMode = 2;
pub const VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER: SamplerAddressMode = 3;

// Border color
pub const VK_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK: BorderColor = 0;
pub const VK_BORDER_COLOR_FLOAT_OPAQUE_BLACK: BorderColor = 2;
pub const VK_BORDER_COLOR_FLOAT_OPAQUE_WHITE: BorderColor = 4;

// Index type
pub const VK_INDEX_TYPE_UINT16: IndexType = 0;
pub const VK_INDEX_TYPE_UINT32: IndexType = 1;

// Command buffer level
pub const VK_COMMAND_BUFFER_LEVEL_PRIMARY: CommandBufferLevel = 0;
pub const VK_COMMAND_BUFFER_LEVEL_SECONDARY: CommandBufferLevel = 1;

// Command buffer usage flags
pub const VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT: CommandBufferUsageFlagBits = 1;

// Subpass contents
pub const VK_SUBPASS_CONTENTS_INLINE: SubpassContents = 0;

// Sample count
pub const VK_SAMPLE_COUNT_1_BIT: SampleCountFlagBits = 1;
pub const VK_SAMPLE_COUNT_2_BIT: SampleCountFlagBits = 2;
pub const VK_SAMPLE_COUNT_4_BIT: SampleCountFlagBits = 4;
pub const VK_SAMPLE_COUNT_8_BIT: SampleCountFlagBits = 8;

// Queue flags
pub const VK_QUEUE_GRAPHICS_BIT: QueueFlagBits = 1;
pub const VK_QUEUE_COMPUTE_BIT: QueueFlagBits = 2;
pub const VK_QUEUE_TRANSFER_BIT: QueueFlagBits = 4;

// Buffer usage flags
pub const VK_BUFFER_USAGE_TRANSFER_SRC_BIT: BufferUsageFlagBits = 1;
pub const VK_BUFFER_USAGE_TRANSFER_DST_BIT: BufferUsageFlagBits = 2;
pub const VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT: BufferUsageFlagBits = 16;
pub const VK_BUFFER_USAGE_STORAGE_BUFFER_BIT: BufferUsageFlagBits = 32;
pub const VK_BUFFER_USAGE_INDEX_BUFFER_BIT: BufferUsageFlagBits = 64;
pub const VK_BUFFER_USAGE_VERTEX_BUFFER_BIT: BufferUsageFlagBits = 128;

// Image usage flags
pub const VK_IMAGE_USAGE_TRANSFER_SRC_BIT: ImageUsageFlagBits = 1;
pub const VK_IMAGE_USAGE_TRANSFER_DST_BIT: ImageUsageFlagBits = 2;
pub const VK_IMAGE_USAGE_SAMPLED_BIT: ImageUsageFlagBits = 4;
pub const VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT: ImageUsageFlagBits = 16;
pub const VK_IMAGE_USAGE_TRANSIENT_ATTACHMENT_BIT: ImageUsageFlagBits = 64;

// Memory property flags
pub const VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT: MemoryPropertyFlagBits = 1;
pub const VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT: MemoryPropertyFlagBits = 2;
pub const VK_MEMORY_PROPERTY_HOST_COHERENT_BIT: MemoryPropertyFlagBits = 4;

// Color component flags
pub const VK_COLOR_COMPONENT_R_BIT: ColorComponentFlagBits = 1;
pub const VK_COLOR_COMPONENT_G_BIT: ColorComponentFlagBits = 2;
pub const VK_COLOR_COMPONENT_B_BIT: ColorComponentFlagBits = 4;
pub const VK_COLOR_COMPONENT_A_BIT: ColorComponentFlagBits = 8;
pub const VK_COLOR_COMPONENT_ALL: ColorComponentFlags = VK_COLOR_COMPONENT_R_BIT |
    VK_COLOR_COMPONENT_G_BIT | VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT;

// Image aspect flags
pub const VK_IMAGE_ASPECT_COLOR_BIT: ImageAspectFlagBits = 1;

// Pipeline stage flags
pub const VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT: PipelineStageFlagBits = 1;
pub const VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT: PipelineStageFlagBits = 8192;
pub const VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT: PipelineStageFlagBits = 1024;
pub const VK_PIPELINE_STAGE_TRANSFER_BIT: PipelineStageFlagBits = 4096;
pub const VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT: PipelineStageFlagBits = 128;

// Access flags
pub const VK_ACCESS_COLOR_ATTACHMENT_READ_BIT: AccessFlagBits = 128;
pub const VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT: AccessFlagBits = 256;
pub const VK_ACCESS_TRANSFER_READ_BIT: AccessFlagBits = 2048;
pub const VK_ACCESS_TRANSFER_WRITE_BIT: AccessFlagBits = 4096;
pub const VK_ACCESS_SHADER_READ_BIT: AccessFlagBits = 32;
pub const VK_ACCESS_MEMORY_READ_BIT: AccessFlagBits = 32768;

// Composite alpha
pub const VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR: CompositeAlphaFlagBitsKHR = 1;
pub const VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR: CompositeAlphaFlagBitsKHR = 2;
pub const VK_COMPOSITE_ALPHA_POST_MULTIPLIED_BIT_KHR: CompositeAlphaFlagBitsKHR = 4;
pub const VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR: CompositeAlphaFlagBitsKHR = 8;

// Command pool flags
pub const VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT: CommandPoolCreateFlagBits = 2;

// Fence flags
pub const VK_FENCE_CREATE_SIGNALED_BIT: FenceCreateFlagBits = 1;

// Dependency flags
pub const VK_DEPENDENCY_BY_REGION_BIT: DependencyFlagBits = 1;

// Component swizzle
pub const VK_COMPONENT_SWIZZLE_IDENTITY: ComponentSwizzle = 0;

// Compare op
pub const VK_COMPARE_OP_NEVER: CompareOp = 0;

// Debug message severity flags
pub const VK_DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT: DebugUtilsMessageSeverityFlagBitsEXT = 1;
pub const VK_DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT: DebugUtilsMessageSeverityFlagBitsEXT = 16;
pub const VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT: DebugUtilsMessageSeverityFlagBitsEXT =
    256;
pub const VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT: DebugUtilsMessageSeverityFlagBitsEXT =
    4096;

// Debug message type flags
pub const VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT: DebugUtilsMessageTypeFlagBitsEXT = 1;
pub const VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT: DebugUtilsMessageTypeFlagBitsEXT = 2;
pub const VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT: DebugUtilsMessageTypeFlagBitsEXT = 4;

// =============================================================================
// Structs and Unions (layouts pinned at the end of this file)
// =============================================================================

pub const ApplicationInfo = extern struct {
    sType: StructureType,
    pNext: ?*const anyopaque,
    pApplicationName: ?[*:0]const u8,
    applicationVersion: u32,
    pEngineName: ?[*:0]const u8,
    engineVersion: u32,
    apiVersion: u32,
};
pub const InstanceCreateInfo = extern struct {
    sType: StructureType,
    pNext: ?*const anyopaque,
    flags: InstanceCreateFlags,
    pApplicationInfo: ?*const ApplicationInfo,
    enabledLayerCount: u32,
    ppEnabledLayerNames: ?[*]const [*:0]const u8,
    enabledExtensionCount: u32,
    ppEnabledExtensionNames: ?[*]const [*:0]const u8,
};
pub const DeviceQueueCreateInfo = extern struct {
    sType: StructureType,
    pNext: ?*const anyopaque,
    flags: DeviceQueueCreateFlags,
    queueFamilyIndex: u32,
    queueCount: u32,
    pQueuePriorities: ?[*]const f32,
};
pub const DeviceCreateInfo = extern struct {
    sType: StructureType,
    pNext: ?*const anyopaque,
    flags: DeviceCreateFlags,
    queueCreateInfoCount: u32,
    pQueueCreateInfos: ?[*]const DeviceQueueCreateInfo,
    enabledLayerCount: u32,
    ppEnabledLayerNames: ?[*]const [*:0]const u8,
    enabledExtensionCount: u32,
    ppEnabledExtensionNames: ?[*]const [*:0]const u8,
    pEnabledFeatures: ?*const PhysicalDeviceFeatures,
};
pub const WaylandSurfaceCreateInfoKHR = extern struct {
    sType: StructureType,
    pNext: ?*const anyopaque,
    flags: WaylandSurfaceCreateFlagsKHR,
    display: ?*WlDisplay,
    surface: ?*WlSurface,
};
pub const SwapchainCreateInfoKHR = extern struct {
    sType: StructureType,
    pNext: ?*const anyopaque,
    flags: SwapchainCreateFlagsKHR,
    surface: Surface,
    minImageCount: u32,
    imageFormat: Format,
    imageColorSpace: ColorSpaceKHR,
    imageExtent: Extent2D,
    imageArrayLayers: u32,
    imageUsage: ImageUsageFlags,
    imageSharingMode: SharingMode,
    queueFamilyIndexCount: u32,
    pQueueFamilyIndices: ?[*]const u32,
    preTransform: SurfaceTransformFlagBitsKHR,
    compositeAlpha: CompositeAlphaFlagBitsKHR,
    presentMode: PresentModeKHR,
    clipped: Bool32,
    oldSwapchain: Swapchain,
};
pub const ImageViewCreateInfo = extern struct {
    sType: StructureType,
    pNext: ?*const anyopaque,
    flags: ImageViewCreateFlags,
    image: Image,
    viewType: ImageViewType,
    format: Format,
    components: ComponentMapping,
    subresourceRange: ImageSubresourceRange,
};
pub const ImageCreateInfo = extern struct {
    sType: StructureType,
    pNext: ?*const anyopaque,
    flags: ImageCreateFlags,
    imageType: ImageType,
    format: Format,
    extent: Extent3D,
    mipLevels: u32,
    arrayLayers: u32,
    samples: SampleCountFlagBits,
    tiling: ImageTiling,
    usage: ImageUsageFlags,
    sharingMode: SharingMode,
    queueFamilyIndexCount: u32,
    pQueueFamilyIndices: ?[*]const u32,
    initialLayout: ImageLayout,
};
pub const BufferCreateInfo = extern struct {
    sType: StructureType,
    pNext: ?*const anyopaque,
    flags: BufferCreateFlags,
    size: DeviceSize,
    usage: BufferUsageFlags,
    sharingMode: SharingMode,
    queueFamilyIndexCount: u32,
    pQueueFamilyIndices: ?[*]const u32,
};
pub const MemoryAllocateInfo = extern struct {
    sType: StructureType,
    pNext: ?*const anyopaque,
    allocationSize: DeviceSize,
    memoryTypeIndex: u32,
};
pub const ShaderModuleCreateInfo = extern struct {
    sType: StructureType,
    pNext: ?*const anyopaque,
    flags: ShaderModuleCreateFlags,
    codeSize: usize,
    pCode: ?[*]const u32,
};
pub const PipelineShaderStageCreateInfo = extern struct {
    sType: StructureType,
    pNext: ?*const anyopaque,
    flags: PipelineShaderStageCreateFlags,
    stage: ShaderStageFlagBits,
    module: ShaderModule,
    pName: ?[*:0]const u8,
    pSpecializationInfo: ?*const SpecializationInfo,
};
pub const PipelineVertexInputStateCreateInfo = extern struct {
    sType: StructureType,
    pNext: ?*const anyopaque,
    flags: PipelineVertexInputStateCreateFlags,
    vertexBindingDescriptionCount: u32,
    pVertexBindingDescriptions: ?[*]const VertexInputBindingDescription,
    vertexAttributeDescriptionCount: u32,
    pVertexAttributeDescriptions: ?[*]const VertexInputAttributeDescription,
};
pub const PipelineInputAssemblyStateCreateInfo = extern struct {
    sType: StructureType,
    pNext: ?*const anyopaque,
    flags: PipelineInputAssemblyStateCreateFlags,
    topology: PrimitiveTopology,
    primitiveRestartEnable: Bool32,
};
pub const PipelineViewportStateCreateInfo = extern struct {
    sType: StructureType,
    pNext: ?*const anyopaque,
    flags: PipelineViewportStateCreateFlags,
    viewportCount: u32,
    pViewports: ?[*]const Viewport,
    scissorCount: u32,
    pScissors: ?[*]const Rect2D,
};
pub const PipelineRasterizationStateCreateInfo = extern struct {
    sType: StructureType,
    pNext: ?*const anyopaque,
    flags: PipelineRasterizationStateCreateFlags,
    depthClampEnable: Bool32,
    rasterizerDiscardEnable: Bool32,
    polygonMode: PolygonMode,
    cullMode: CullModeFlags,
    frontFace: FrontFace,
    depthBiasEnable: Bool32,
    depthBiasConstantFactor: f32,
    depthBiasClamp: f32,
    depthBiasSlopeFactor: f32,
    lineWidth: f32,
};
pub const PipelineMultisampleStateCreateInfo = extern struct {
    sType: StructureType,
    pNext: ?*const anyopaque,
    flags: PipelineMultisampleStateCreateFlags,
    rasterizationSamples: SampleCountFlagBits,
    sampleShadingEnable: Bool32,
    minSampleShading: f32,
    pSampleMask: ?[*]const SampleMask,
    alphaToCoverageEnable: Bool32,
    alphaToOneEnable: Bool32,
};
pub const PipelineColorBlendAttachmentState = extern struct {
    blendEnable: Bool32,
    srcColorBlendFactor: BlendFactor,
    dstColorBlendFactor: BlendFactor,
    colorBlendOp: BlendOp,
    srcAlphaBlendFactor: BlendFactor,
    dstAlphaBlendFactor: BlendFactor,
    alphaBlendOp: BlendOp,
    colorWriteMask: ColorComponentFlags,
};
pub const PipelineColorBlendStateCreateInfo = extern struct {
    sType: StructureType,
    pNext: ?*const anyopaque,
    flags: PipelineColorBlendStateCreateFlags,
    logicOpEnable: Bool32,
    logicOp: LogicOp,
    attachmentCount: u32,
    pAttachments: ?[*]const PipelineColorBlendAttachmentState,
    blendConstants: [4]f32,
};
pub const PipelineDynamicStateCreateInfo = extern struct {
    sType: StructureType,
    pNext: ?*const anyopaque,
    flags: PipelineDynamicStateCreateFlags,
    dynamicStateCount: u32,
    pDynamicStates: ?[*]const DynamicState,
};
pub const PipelineLayoutCreateInfo = extern struct {
    sType: StructureType,
    pNext: ?*const anyopaque,
    flags: PipelineLayoutCreateFlags,
    setLayoutCount: u32,
    pSetLayouts: ?[*]const DescriptorSetLayout,
    pushConstantRangeCount: u32,
    pPushConstantRanges: ?[*]const PushConstantRange,
};
pub const AttachmentDescription = extern struct {
    flags: AttachmentDescriptionFlags,
    format: Format,
    samples: SampleCountFlagBits,
    loadOp: AttachmentLoadOp,
    storeOp: AttachmentStoreOp,
    stencilLoadOp: AttachmentLoadOp,
    stencilStoreOp: AttachmentStoreOp,
    initialLayout: ImageLayout,
    finalLayout: ImageLayout,
};
pub const AttachmentReference = extern struct {
    attachment: u32,
    layout: ImageLayout,
};
pub const SubpassDescription = extern struct {
    flags: SubpassDescriptionFlags,
    pipelineBindPoint: PipelineBindPoint,
    inputAttachmentCount: u32,
    pInputAttachments: ?[*]const AttachmentReference,
    colorAttachmentCount: u32,
    pColorAttachments: ?[*]const AttachmentReference,
    pResolveAttachments: ?[*]const AttachmentReference,
    pDepthStencilAttachment: ?*const AttachmentReference,
    preserveAttachmentCount: u32,
    pPreserveAttachments: ?[*]const u32,
};
pub const SubpassDependency = extern struct {
    srcSubpass: u32,
    dstSubpass: u32,
    srcStageMask: PipelineStageFlags,
    dstStageMask: PipelineStageFlags,
    srcAccessMask: AccessFlags,
    dstAccessMask: AccessFlags,
    dependencyFlags: DependencyFlags,
};
pub const RenderPassCreateInfo = extern struct {
    sType: StructureType,
    pNext: ?*const anyopaque,
    flags: RenderPassCreateFlags,
    attachmentCount: u32,
    pAttachments: ?[*]const AttachmentDescription,
    subpassCount: u32,
    pSubpasses: ?[*]const SubpassDescription,
    dependencyCount: u32,
    pDependencies: ?[*]const SubpassDependency,
};
pub const GraphicsPipelineCreateInfo = extern struct {
    sType: StructureType,
    pNext: ?*const anyopaque,
    flags: PipelineCreateFlags,
    stageCount: u32,
    pStages: ?[*]const PipelineShaderStageCreateInfo,
    pVertexInputState: ?*const PipelineVertexInputStateCreateInfo,
    pInputAssemblyState: ?*const PipelineInputAssemblyStateCreateInfo,
    pTessellationState: ?*const PipelineTessellationStateCreateInfo,
    pViewportState: ?*const PipelineViewportStateCreateInfo,
    pRasterizationState: ?*const PipelineRasterizationStateCreateInfo,
    pMultisampleState: ?*const PipelineMultisampleStateCreateInfo,
    pDepthStencilState: ?*const PipelineDepthStencilStateCreateInfo,
    pColorBlendState: ?*const PipelineColorBlendStateCreateInfo,
    pDynamicState: ?*const PipelineDynamicStateCreateInfo,
    layout: PipelineLayout,
    renderPass: RenderPass,
    subpass: u32,
    basePipelineHandle: Pipeline,
    basePipelineIndex: i32,
};
pub const FramebufferCreateInfo = extern struct {
    sType: StructureType,
    pNext: ?*const anyopaque,
    flags: FramebufferCreateFlags,
    renderPass: RenderPass,
    attachmentCount: u32,
    pAttachments: ?[*]const ImageView,
    width: u32,
    height: u32,
    layers: u32,
};
pub const CommandPoolCreateInfo = extern struct {
    sType: StructureType,
    pNext: ?*const anyopaque,
    flags: CommandPoolCreateFlags,
    queueFamilyIndex: u32,
};
pub const CommandBufferAllocateInfo = extern struct {
    sType: StructureType,
    pNext: ?*const anyopaque,
    commandPool: CommandPool,
    level: CommandBufferLevel,
    commandBufferCount: u32,
};
pub const CommandBufferBeginInfo = extern struct {
    sType: StructureType,
    pNext: ?*const anyopaque,
    flags: CommandBufferUsageFlags,
    pInheritanceInfo: ?*const CommandBufferInheritanceInfo,
};
pub const RenderPassBeginInfo = extern struct {
    sType: StructureType,
    pNext: ?*const anyopaque,
    renderPass: RenderPass,
    framebuffer: Framebuffer,
    renderArea: Rect2D,
    clearValueCount: u32,
    pClearValues: ?[*]const ClearValue,
};
pub const SemaphoreCreateInfo = extern struct {
    sType: StructureType,
    pNext: ?*const anyopaque,
    flags: SemaphoreCreateFlags,
};
pub const FenceCreateInfo = extern struct {
    sType: StructureType,
    pNext: ?*const anyopaque,
    flags: FenceCreateFlags,
};
pub const SubmitInfo = extern struct {
    sType: StructureType,
    pNext: ?*const anyopaque,
    waitSemaphoreCount: u32,
    pWaitSemaphores: ?[*]const Semaphore,
    pWaitDstStageMask: ?[*]const PipelineStageFlags,
    commandBufferCount: u32,
    pCommandBuffers: ?[*]const CommandBuffer,
    signalSemaphoreCount: u32,
    pSignalSemaphores: ?[*]const Semaphore,
};
pub const PresentInfoKHR = extern struct {
    sType: StructureType,
    pNext: ?*const anyopaque,
    waitSemaphoreCount: u32,
    pWaitSemaphores: ?[*]const Semaphore,
    swapchainCount: u32,
    pSwapchains: ?[*]const Swapchain,
    pImageIndices: ?[*]const u32,
    pResults: ?[*]Result,
};
pub const DescriptorSetLayoutBinding = extern struct {
    binding: u32,
    descriptorType: DescriptorType,
    descriptorCount: u32,
    stageFlags: ShaderStageFlags,
    pImmutableSamplers: ?[*]const Sampler,
};
pub const DescriptorSetLayoutCreateInfo = extern struct {
    sType: StructureType,
    pNext: ?*const anyopaque,
    flags: DescriptorSetLayoutCreateFlags,
    bindingCount: u32,
    pBindings: ?[*]const DescriptorSetLayoutBinding,
};
pub const DescriptorPoolSize = extern struct {
    type: DescriptorType,
    descriptorCount: u32,
};
pub const DescriptorPoolCreateInfo = extern struct {
    sType: StructureType,
    pNext: ?*const anyopaque,
    flags: DescriptorPoolCreateFlags,
    maxSets: u32,
    poolSizeCount: u32,
    pPoolSizes: ?[*]const DescriptorPoolSize,
};
pub const DescriptorSetAllocateInfo = extern struct {
    sType: StructureType,
    pNext: ?*const anyopaque,
    descriptorPool: DescriptorPool,
    descriptorSetCount: u32,
    pSetLayouts: ?[*]const DescriptorSetLayout,
};
pub const DescriptorBufferInfo = extern struct {
    buffer: Buffer,
    offset: DeviceSize,
    range: DeviceSize,
};
pub const DescriptorImageInfo = extern struct {
    sampler: Sampler,
    imageView: ImageView,
    imageLayout: ImageLayout,
};
pub const WriteDescriptorSet = extern struct {
    sType: StructureType,
    pNext: ?*const anyopaque,
    dstSet: DescriptorSet,
    dstBinding: u32,
    dstArrayElement: u32,
    descriptorCount: u32,
    descriptorType: DescriptorType,
    pImageInfo: ?[*]const DescriptorImageInfo,
    pBufferInfo: ?[*]const DescriptorBufferInfo,
    pTexelBufferView: ?[*]const BufferView,
};
pub const SamplerCreateInfo = extern struct {
    sType: StructureType,
    pNext: ?*const anyopaque,
    flags: SamplerCreateFlags,
    magFilter: Filter,
    minFilter: Filter,
    mipmapMode: SamplerMipmapMode,
    addressModeU: SamplerAddressMode,
    addressModeV: SamplerAddressMode,
    addressModeW: SamplerAddressMode,
    mipLodBias: f32,
    anisotropyEnable: Bool32,
    maxAnisotropy: f32,
    compareEnable: Bool32,
    compareOp: CompareOp,
    minLod: f32,
    maxLod: f32,
    borderColor: BorderColor,
    unnormalizedCoordinates: Bool32,
};
pub const ImageMemoryBarrier = extern struct {
    sType: StructureType,
    pNext: ?*const anyopaque,
    srcAccessMask: AccessFlags,
    dstAccessMask: AccessFlags,
    oldLayout: ImageLayout,
    newLayout: ImageLayout,
    srcQueueFamilyIndex: u32,
    dstQueueFamilyIndex: u32,
    image: Image,
    subresourceRange: ImageSubresourceRange,
};
pub const BufferImageCopy = extern struct {
    bufferOffset: DeviceSize,
    bufferRowLength: u32,
    bufferImageHeight: u32,
    imageSubresource: ImageSubresourceLayers,
    imageOffset: Offset3D,
    imageExtent: Extent3D,
};
pub const PipelineCacheCreateInfo = extern struct {
    sType: StructureType,
    pNext: ?*const anyopaque,
    flags: PipelineCacheCreateFlags,
    initialDataSize: usize,
    pInitialData: ?*const anyopaque,
};
pub const DebugUtilsMessengerCreateInfoEXT = extern struct {
    sType: StructureType,
    pNext: ?*const anyopaque,
    flags: DebugUtilsMessengerCreateFlagsEXT,
    messageSeverity: DebugUtilsMessageSeverityFlagsEXT,
    messageType: DebugUtilsMessageTypeFlagsEXT,
    pfnUserCallback: PFN_vkDebugUtilsMessengerCallbackEXT,
    pUserData: ?*anyopaque,
};
pub const DebugUtilsMessengerCallbackDataEXT = extern struct {
    sType: StructureType,
    pNext: ?*const anyopaque,
    flags: DebugUtilsMessengerCallbackDataFlagsEXT,
    pMessageIdName: ?[*:0]const u8,
    messageIdNumber: i32,
    pMessage: ?[*:0]const u8,
    queueLabelCount: u32,
    pQueueLabels: ?[*]const DebugUtilsLabelEXT,
    cmdBufLabelCount: u32,
    pCmdBufLabels: ?[*]const DebugUtilsLabelEXT,
    objectCount: u32,
    pObjects: ?[*]const DebugUtilsObjectNameInfoEXT,
};

/// Debug messenger callback function type
pub const PFN_vkDebugUtilsMessengerCallbackEXT = ?*const fn (
    messageSeverity: DebugUtilsMessageSeverityFlagBitsEXT,
    messageTypes: DebugUtilsMessageTypeFlagsEXT,
    pCallbackData: ?*const DebugUtilsMessengerCallbackDataEXT,
    pUserData: ?*anyopaque,
) callconv(.c) Bool32;

/// Generic function pointer returned by `vkGetInstanceProcAddr`.
pub const PFN_vkVoidFunction = ?*const fn () callconv(.c) void;

pub const Extent2D = extern struct {
    width: u32,
    height: u32,
};
pub const Extent3D = extern struct {
    width: u32,
    height: u32,
    depth: u32,
};
pub const Offset2D = extern struct {
    x: i32,
    y: i32,
};
pub const Offset3D = extern struct {
    x: i32,
    y: i32,
    z: i32,
};
pub const Rect2D = extern struct {
    offset: Offset2D,
    extent: Extent2D,
};
pub const Viewport = extern struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    minDepth: f32,
    maxDepth: f32,
};
pub const ClearValue = extern union {
    color: ClearColorValue,
    depthStencil: ClearDepthStencilValue,
};
pub const ClearColorValue = extern union {
    float32: [4]f32,
    int32: [4]i32,
    uint32: [4]u32,
};
pub const ComponentMapping = extern struct {
    r: ComponentSwizzle,
    g: ComponentSwizzle,
    b: ComponentSwizzle,
    a: ComponentSwizzle,
};
pub const ImageSubresourceRange = extern struct {
    aspectMask: ImageAspectFlags,
    baseMipLevel: u32,
    levelCount: u32,
    baseArrayLayer: u32,
    layerCount: u32,
};
pub const ImageSubresourceLayers = extern struct {
    aspectMask: ImageAspectFlags,
    mipLevel: u32,
    baseArrayLayer: u32,
    layerCount: u32,
};
pub const MemoryRequirements = extern struct {
    size: DeviceSize,
    alignment: DeviceSize,
    memoryTypeBits: u32,
};
pub const QueueFamilyProperties = extern struct {
    queueFlags: QueueFlags,
    queueCount: u32,
    timestampValidBits: u32,
    minImageTransferGranularity: Extent3D,
};
pub const SurfaceCapabilitiesKHR = extern struct {
    minImageCount: u32,
    maxImageCount: u32,
    currentExtent: Extent2D,
    minImageExtent: Extent2D,
    maxImageExtent: Extent2D,
    maxImageArrayLayers: u32,
    supportedTransforms: SurfaceTransformFlagsKHR,
    currentTransform: SurfaceTransformFlagBitsKHR,
    supportedCompositeAlpha: CompositeAlphaFlagsKHR,
    supportedUsageFlags: ImageUsageFlags,
};
pub const SurfaceFormatKHR = extern struct {
    format: Format,
    colorSpace: ColorSpaceKHR,
};
pub const PhysicalDeviceProperties = extern struct {
    apiVersion: u32,
    driverVersion: u32,
    vendorID: u32,
    deviceID: u32,
    deviceType: PhysicalDeviceType,
    deviceName: [256]u8,
    pipelineCacheUUID: [16]u8,
    limits: PhysicalDeviceLimits,
    sparseProperties: PhysicalDeviceSparseProperties,
};
pub const PhysicalDeviceMemoryProperties = extern struct {
    memoryTypeCount: u32,
    memoryTypes: [32]MemoryType,
    memoryHeapCount: u32,
    memoryHeaps: [16]MemoryHeap,
};
pub const PhysicalDeviceFeatures = extern struct {
    robustBufferAccess: Bool32,
    fullDrawIndexUint32: Bool32,
    imageCubeArray: Bool32,
    independentBlend: Bool32,
    geometryShader: Bool32,
    tessellationShader: Bool32,
    sampleRateShading: Bool32,
    dualSrcBlend: Bool32,
    logicOp: Bool32,
    multiDrawIndirect: Bool32,
    drawIndirectFirstInstance: Bool32,
    depthClamp: Bool32,
    depthBiasClamp: Bool32,
    fillModeNonSolid: Bool32,
    depthBounds: Bool32,
    wideLines: Bool32,
    largePoints: Bool32,
    alphaToOne: Bool32,
    multiViewport: Bool32,
    samplerAnisotropy: Bool32,
    textureCompressionETC2: Bool32,
    textureCompressionASTC_LDR: Bool32,
    textureCompressionBC: Bool32,
    occlusionQueryPrecise: Bool32,
    pipelineStatisticsQuery: Bool32,
    vertexPipelineStoresAndAtomics: Bool32,
    fragmentStoresAndAtomics: Bool32,
    shaderTessellationAndGeometryPointSize: Bool32,
    shaderImageGatherExtended: Bool32,
    shaderStorageImageExtendedFormats: Bool32,
    shaderStorageImageMultisample: Bool32,
    shaderStorageImageReadWithoutFormat: Bool32,
    shaderStorageImageWriteWithoutFormat: Bool32,
    shaderUniformBufferArrayDynamicIndexing: Bool32,
    shaderSampledImageArrayDynamicIndexing: Bool32,
    shaderStorageBufferArrayDynamicIndexing: Bool32,
    shaderStorageImageArrayDynamicIndexing: Bool32,
    shaderClipDistance: Bool32,
    shaderCullDistance: Bool32,
    shaderFloat64: Bool32,
    shaderInt64: Bool32,
    shaderInt16: Bool32,
    shaderResourceResidency: Bool32,
    shaderResourceMinLod: Bool32,
    sparseBinding: Bool32,
    sparseResidencyBuffer: Bool32,
    sparseResidencyImage2D: Bool32,
    sparseResidencyImage3D: Bool32,
    sparseResidency2Samples: Bool32,
    sparseResidency4Samples: Bool32,
    sparseResidency8Samples: Bool32,
    sparseResidency16Samples: Bool32,
    sparseResidencyAliased: Bool32,
    variableMultisampleRate: Bool32,
    inheritedQueries: Bool32,
};
pub const VertexInputBindingDescription = extern struct {
    binding: u32,
    stride: u32,
    inputRate: VertexInputRate,
};
pub const VertexInputAttributeDescription = extern struct {
    location: u32,
    binding: u32,
    format: Format,
    offset: u32,
};

// Supporting types: reachable from the structs above but not used directly by
// the renderer. Declared fully so every pointer target has a checked layout.

pub const SpecializationInfo = extern struct {
    mapEntryCount: u32,
    pMapEntries: ?[*]const SpecializationMapEntry,
    dataSize: usize,
    pData: ?*const anyopaque,
};
pub const SpecializationMapEntry = extern struct {
    constantID: u32,
    offset: u32,
    size: usize,
};
pub const PushConstantRange = extern struct {
    stageFlags: ShaderStageFlags,
    offset: u32,
    size: u32,
};
pub const PipelineTessellationStateCreateInfo = extern struct {
    sType: StructureType,
    pNext: ?*const anyopaque,
    flags: PipelineTessellationStateCreateFlags,
    patchControlPoints: u32,
};
pub const PipelineDepthStencilStateCreateInfo = extern struct {
    sType: StructureType,
    pNext: ?*const anyopaque,
    flags: PipelineDepthStencilStateCreateFlags,
    depthTestEnable: Bool32,
    depthWriteEnable: Bool32,
    depthCompareOp: CompareOp,
    depthBoundsTestEnable: Bool32,
    stencilTestEnable: Bool32,
    front: StencilOpState,
    back: StencilOpState,
    minDepthBounds: f32,
    maxDepthBounds: f32,
};
pub const StencilOpState = extern struct {
    failOp: StencilOp,
    passOp: StencilOp,
    depthFailOp: StencilOp,
    compareOp: CompareOp,
    compareMask: u32,
    writeMask: u32,
    reference: u32,
};
pub const CommandBufferInheritanceInfo = extern struct {
    sType: StructureType,
    pNext: ?*const anyopaque,
    renderPass: RenderPass,
    subpass: u32,
    framebuffer: Framebuffer,
    occlusionQueryEnable: Bool32,
    queryFlags: QueryControlFlags,
    pipelineStatistics: QueryPipelineStatisticFlags,
};
pub const ClearDepthStencilValue = extern struct {
    depth: f32,
    stencil: u32,
};
pub const DebugUtilsLabelEXT = extern struct {
    sType: StructureType,
    pNext: ?*const anyopaque,
    pLabelName: ?[*:0]const u8,
    color: [4]f32,
};
pub const DebugUtilsObjectNameInfoEXT = extern struct {
    sType: StructureType,
    pNext: ?*const anyopaque,
    objectType: ObjectType,
    objectHandle: u64,
    pObjectName: ?[*:0]const u8,
};
pub const PhysicalDeviceLimits = extern struct {
    maxImageDimension1D: u32,
    maxImageDimension2D: u32,
    maxImageDimension3D: u32,
    maxImageDimensionCube: u32,
    maxImageArrayLayers: u32,
    maxTexelBufferElements: u32,
    maxUniformBufferRange: u32,
    maxStorageBufferRange: u32,
    maxPushConstantsSize: u32,
    maxMemoryAllocationCount: u32,
    maxSamplerAllocationCount: u32,
    bufferImageGranularity: DeviceSize,
    sparseAddressSpaceSize: DeviceSize,
    maxBoundDescriptorSets: u32,
    maxPerStageDescriptorSamplers: u32,
    maxPerStageDescriptorUniformBuffers: u32,
    maxPerStageDescriptorStorageBuffers: u32,
    maxPerStageDescriptorSampledImages: u32,
    maxPerStageDescriptorStorageImages: u32,
    maxPerStageDescriptorInputAttachments: u32,
    maxPerStageResources: u32,
    maxDescriptorSetSamplers: u32,
    maxDescriptorSetUniformBuffers: u32,
    maxDescriptorSetUniformBuffersDynamic: u32,
    maxDescriptorSetStorageBuffers: u32,
    maxDescriptorSetStorageBuffersDynamic: u32,
    maxDescriptorSetSampledImages: u32,
    maxDescriptorSetStorageImages: u32,
    maxDescriptorSetInputAttachments: u32,
    maxVertexInputAttributes: u32,
    maxVertexInputBindings: u32,
    maxVertexInputAttributeOffset: u32,
    maxVertexInputBindingStride: u32,
    maxVertexOutputComponents: u32,
    maxTessellationGenerationLevel: u32,
    maxTessellationPatchSize: u32,
    maxTessellationControlPerVertexInputComponents: u32,
    maxTessellationControlPerVertexOutputComponents: u32,
    maxTessellationControlPerPatchOutputComponents: u32,
    maxTessellationControlTotalOutputComponents: u32,
    maxTessellationEvaluationInputComponents: u32,
    maxTessellationEvaluationOutputComponents: u32,
    maxGeometryShaderInvocations: u32,
    maxGeometryInputComponents: u32,
    maxGeometryOutputComponents: u32,
    maxGeometryOutputVertices: u32,
    maxGeometryTotalOutputComponents: u32,
    maxFragmentInputComponents: u32,
    maxFragmentOutputAttachments: u32,
    maxFragmentDualSrcAttachments: u32,
    maxFragmentCombinedOutputResources: u32,
    maxComputeSharedMemorySize: u32,
    maxComputeWorkGroupCount: [3]u32,
    maxComputeWorkGroupInvocations: u32,
    maxComputeWorkGroupSize: [3]u32,
    subPixelPrecisionBits: u32,
    subTexelPrecisionBits: u32,
    mipmapPrecisionBits: u32,
    maxDrawIndexedIndexValue: u32,
    maxDrawIndirectCount: u32,
    maxSamplerLodBias: f32,
    maxSamplerAnisotropy: f32,
    maxViewports: u32,
    maxViewportDimensions: [2]u32,
    viewportBoundsRange: [2]f32,
    viewportSubPixelBits: u32,
    minMemoryMapAlignment: usize,
    minTexelBufferOffsetAlignment: DeviceSize,
    minUniformBufferOffsetAlignment: DeviceSize,
    minStorageBufferOffsetAlignment: DeviceSize,
    minTexelOffset: i32,
    maxTexelOffset: u32,
    minTexelGatherOffset: i32,
    maxTexelGatherOffset: u32,
    minInterpolationOffset: f32,
    maxInterpolationOffset: f32,
    subPixelInterpolationOffsetBits: u32,
    maxFramebufferWidth: u32,
    maxFramebufferHeight: u32,
    maxFramebufferLayers: u32,
    framebufferColorSampleCounts: SampleCountFlags,
    framebufferDepthSampleCounts: SampleCountFlags,
    framebufferStencilSampleCounts: SampleCountFlags,
    framebufferNoAttachmentsSampleCounts: SampleCountFlags,
    maxColorAttachments: u32,
    sampledImageColorSampleCounts: SampleCountFlags,
    sampledImageIntegerSampleCounts: SampleCountFlags,
    sampledImageDepthSampleCounts: SampleCountFlags,
    sampledImageStencilSampleCounts: SampleCountFlags,
    storageImageSampleCounts: SampleCountFlags,
    maxSampleMaskWords: u32,
    timestampComputeAndGraphics: Bool32,
    timestampPeriod: f32,
    maxClipDistances: u32,
    maxCullDistances: u32,
    maxCombinedClipAndCullDistances: u32,
    discreteQueuePriorities: u32,
    pointSizeRange: [2]f32,
    lineWidthRange: [2]f32,
    pointSizeGranularity: f32,
    lineWidthGranularity: f32,
    strictLines: Bool32,
    standardSampleLocations: Bool32,
    optimalBufferCopyOffsetAlignment: DeviceSize,
    optimalBufferCopyRowPitchAlignment: DeviceSize,
    nonCoherentAtomSize: DeviceSize,
};
pub const PhysicalDeviceSparseProperties = extern struct {
    residencyStandard2DBlockShape: Bool32,
    residencyStandard2DMultisampleBlockShape: Bool32,
    residencyStandard3DBlockShape: Bool32,
    residencyAlignedMipSize: Bool32,
    residencyNonResidentStrict: Bool32,
};
pub const MemoryType = extern struct {
    propertyFlags: MemoryPropertyFlags,
    heapIndex: u32,
};
pub const MemoryHeap = extern struct {
    size: DeviceSize,
    flags: MemoryHeapFlags,
};
pub const AllocationCallbacks = opaque {};
pub const LayerProperties = extern struct {
    layerName: [256]u8,
    specVersion: u32,
    implementationVersion: u32,
    description: [256]u8,
};
pub const MappedMemoryRange = extern struct {
    sType: StructureType,
    pNext: ?*const anyopaque,
    memory: DeviceMemory,
    offset: DeviceSize,
    size: DeviceSize,
};
pub const MemoryBarrier = extern struct {
    sType: StructureType,
    pNext: ?*const anyopaque,
    srcAccessMask: AccessFlags,
    dstAccessMask: AccessFlags,
};
pub const BufferMemoryBarrier = extern struct {
    sType: StructureType,
    pNext: ?*const anyopaque,
    srcAccessMask: AccessFlags,
    dstAccessMask: AccessFlags,
    srcQueueFamilyIndex: u32,
    dstQueueFamilyIndex: u32,
    buffer: Buffer,
    offset: DeviceSize,
    size: DeviceSize,
};
pub const CopyDescriptorSet = extern struct {
    sType: StructureType,
    pNext: ?*const anyopaque,
    srcSet: DescriptorSet,
    srcBinding: u32,
    srcArrayElement: u32,
    dstSet: DescriptorSet,
    dstBinding: u32,
    dstArrayElement: u32,
    descriptorCount: u32,
};

// =============================================================================
// Vulkan Functions - Instance
// =============================================================================

pub extern fn vkCreateInstance(
    pCreateInfo: *const InstanceCreateInfo,
    pAllocator: ?*const AllocationCallbacks,
    pInstance: *Instance,
) callconv(.c) Result;
pub extern fn vkDestroyInstance(
    instance: Instance,
    pAllocator: ?*const AllocationCallbacks,
) callconv(.c) void;
pub extern fn vkEnumeratePhysicalDevices(
    instance: Instance,
    pPhysicalDeviceCount: *u32,
    pPhysicalDevices: ?[*]PhysicalDevice,
) callconv(.c) Result;
pub extern fn vkGetPhysicalDeviceProperties(
    physicalDevice: PhysicalDevice,
    pProperties: *PhysicalDeviceProperties,
) callconv(.c) void;
pub extern fn vkGetPhysicalDeviceFeatures(
    physicalDevice: PhysicalDevice,
    pFeatures: *PhysicalDeviceFeatures,
) callconv(.c) void;
pub extern fn vkGetPhysicalDeviceMemoryProperties(
    physicalDevice: PhysicalDevice,
    pMemoryProperties: *PhysicalDeviceMemoryProperties,
) callconv(.c) void;
pub extern fn vkGetPhysicalDeviceQueueFamilyProperties(
    physicalDevice: PhysicalDevice,
    pQueueFamilyPropertyCount: *u32,
    pQueueFamilyProperties: ?[*]QueueFamilyProperties,
) callconv(.c) void;
pub extern fn vkEnumerateInstanceLayerProperties(
    pPropertyCount: *u32,
    pProperties: ?[*]LayerProperties,
) callconv(.c) Result;
pub extern fn vkGetInstanceProcAddr(
    instance: Instance,
    pName: [*:0]const u8,
) callconv(.c) PFN_vkVoidFunction;

// Debug utils functions are not exported by the Vulkan loader. Load them with
// `vkGetInstanceProcAddr` and cast to these types.
pub const PFN_vkCreateDebugUtilsMessengerEXT = *const fn (
    instance: Instance,
    pCreateInfo: *const DebugUtilsMessengerCreateInfoEXT,
    pAllocator: ?*const AllocationCallbacks,
    pMessenger: *DebugUtilsMessengerEXT,
) callconv(.c) Result;
pub const PFN_vkDestroyDebugUtilsMessengerEXT = *const fn (
    instance: Instance,
    messenger: DebugUtilsMessengerEXT,
    pAllocator: ?*const AllocationCallbacks,
) callconv(.c) void;

// =============================================================================
// Vulkan Functions - Device
// =============================================================================

pub extern fn vkCreateDevice(
    physicalDevice: PhysicalDevice,
    pCreateInfo: *const DeviceCreateInfo,
    pAllocator: ?*const AllocationCallbacks,
    pDevice: *Device,
) callconv(.c) Result;
pub extern fn vkDestroyDevice(
    device: Device,
    pAllocator: ?*const AllocationCallbacks,
) callconv(.c) void;
pub extern fn vkGetDeviceQueue(
    device: Device,
    queueFamilyIndex: u32,
    queueIndex: u32,
    pQueue: *Queue,
) callconv(.c) void;
pub extern fn vkDeviceWaitIdle(device: Device) callconv(.c) Result;

// =============================================================================
// Vulkan Functions - Surface/Swapchain (KHR extensions)
// =============================================================================

pub extern fn vkCreateWaylandSurfaceKHR(
    instance: Instance,
    pCreateInfo: *const WaylandSurfaceCreateInfoKHR,
    pAllocator: ?*const AllocationCallbacks,
    pSurface: *Surface,
) callconv(.c) Result;
pub extern fn vkDestroySurfaceKHR(
    instance: Instance,
    surface: Surface,
    pAllocator: ?*const AllocationCallbacks,
) callconv(.c) void;
pub extern fn vkGetPhysicalDeviceSurfaceSupportKHR(
    physicalDevice: PhysicalDevice,
    queueFamilyIndex: u32,
    surface: Surface,
    pSupported: *Bool32,
) callconv(.c) Result;
pub extern fn vkGetPhysicalDeviceSurfaceCapabilitiesKHR(
    physicalDevice: PhysicalDevice,
    surface: Surface,
    pSurfaceCapabilities: *SurfaceCapabilitiesKHR,
) callconv(.c) Result;
pub extern fn vkGetPhysicalDeviceSurfaceFormatsKHR(
    physicalDevice: PhysicalDevice,
    surface: Surface,
    pSurfaceFormatCount: *u32,
    pSurfaceFormats: ?[*]SurfaceFormatKHR,
) callconv(.c) Result;
pub extern fn vkGetPhysicalDeviceSurfacePresentModesKHR(
    physicalDevice: PhysicalDevice,
    surface: Surface,
    pPresentModeCount: *u32,
    pPresentModes: ?[*]PresentModeKHR,
) callconv(.c) Result;

pub extern fn vkCreateSwapchainKHR(
    device: Device,
    pCreateInfo: *const SwapchainCreateInfoKHR,
    pAllocator: ?*const AllocationCallbacks,
    pSwapchain: *Swapchain,
) callconv(.c) Result;
pub extern fn vkDestroySwapchainKHR(
    device: Device,
    swapchain: Swapchain,
    pAllocator: ?*const AllocationCallbacks,
) callconv(.c) void;
pub extern fn vkGetSwapchainImagesKHR(
    device: Device,
    swapchain: Swapchain,
    pSwapchainImageCount: *u32,
    pSwapchainImages: ?[*]Image,
) callconv(.c) Result;
pub extern fn vkAcquireNextImageKHR(
    device: Device,
    swapchain: Swapchain,
    timeout: u64,
    semaphore: Semaphore,
    fence: Fence,
    pImageIndex: *u32,
) callconv(.c) Result;
pub extern fn vkQueuePresentKHR(
    queue: Queue,
    pPresentInfo: *const PresentInfoKHR,
) callconv(.c) Result;

// =============================================================================
// Vulkan Functions - Image/Buffer
// =============================================================================

pub extern fn vkCreateImage(
    device: Device,
    pCreateInfo: *const ImageCreateInfo,
    pAllocator: ?*const AllocationCallbacks,
    pImage: *Image,
) callconv(.c) Result;
pub extern fn vkDestroyImage(
    device: Device,
    image: Image,
    pAllocator: ?*const AllocationCallbacks,
) callconv(.c) void;
pub extern fn vkCreateImageView(
    device: Device,
    pCreateInfo: *const ImageViewCreateInfo,
    pAllocator: ?*const AllocationCallbacks,
    pView: *ImageView,
) callconv(.c) Result;
pub extern fn vkDestroyImageView(
    device: Device,
    imageView: ImageView,
    pAllocator: ?*const AllocationCallbacks,
) callconv(.c) void;
pub extern fn vkGetImageMemoryRequirements(
    device: Device,
    image: Image,
    pMemoryRequirements: *MemoryRequirements,
) callconv(.c) void;
pub extern fn vkBindImageMemory(
    device: Device,
    image: Image,
    memory: DeviceMemory,
    memoryOffset: DeviceSize,
) callconv(.c) Result;

pub extern fn vkCreateBuffer(
    device: Device,
    pCreateInfo: *const BufferCreateInfo,
    pAllocator: ?*const AllocationCallbacks,
    pBuffer: *Buffer,
) callconv(.c) Result;
pub extern fn vkDestroyBuffer(
    device: Device,
    buffer: Buffer,
    pAllocator: ?*const AllocationCallbacks,
) callconv(.c) void;
pub extern fn vkGetBufferMemoryRequirements(
    device: Device,
    buffer: Buffer,
    pMemoryRequirements: *MemoryRequirements,
) callconv(.c) void;
pub extern fn vkBindBufferMemory(
    device: Device,
    buffer: Buffer,
    memory: DeviceMemory,
    memoryOffset: DeviceSize,
) callconv(.c) Result;

// =============================================================================
// Vulkan Functions - Memory
// =============================================================================

pub extern fn vkAllocateMemory(
    device: Device,
    pAllocateInfo: *const MemoryAllocateInfo,
    pAllocator: ?*const AllocationCallbacks,
    pMemory: *DeviceMemory,
) callconv(.c) Result;
pub extern fn vkFreeMemory(
    device: Device,
    memory: DeviceMemory,
    pAllocator: ?*const AllocationCallbacks,
) callconv(.c) void;
pub extern fn vkMapMemory(
    device: Device,
    memory: DeviceMemory,
    offset: DeviceSize,
    size: DeviceSize,
    flags: MemoryMapFlags,
    ppData: *?*anyopaque,
) callconv(.c) Result;
pub extern fn vkUnmapMemory(device: Device, memory: DeviceMemory) callconv(.c) void;
pub extern fn vkFlushMappedMemoryRanges(
    device: Device,
    memoryRangeCount: u32,
    pMemoryRanges: ?[*]const MappedMemoryRange,
) callconv(.c) Result;

// =============================================================================
// Vulkan Functions - Pipeline
// =============================================================================

pub extern fn vkCreateShaderModule(
    device: Device,
    pCreateInfo: *const ShaderModuleCreateInfo,
    pAllocator: ?*const AllocationCallbacks,
    pShaderModule: *ShaderModule,
) callconv(.c) Result;
pub extern fn vkDestroyShaderModule(
    device: Device,
    shaderModule: ShaderModule,
    pAllocator: ?*const AllocationCallbacks,
) callconv(.c) void;
pub extern fn vkCreatePipelineLayout(
    device: Device,
    pCreateInfo: *const PipelineLayoutCreateInfo,
    pAllocator: ?*const AllocationCallbacks,
    pPipelineLayout: *PipelineLayout,
) callconv(.c) Result;
pub extern fn vkDestroyPipelineLayout(
    device: Device,
    pipelineLayout: PipelineLayout,
    pAllocator: ?*const AllocationCallbacks,
) callconv(.c) void;
pub extern fn vkCreateRenderPass(
    device: Device,
    pCreateInfo: *const RenderPassCreateInfo,
    pAllocator: ?*const AllocationCallbacks,
    pRenderPass: *RenderPass,
) callconv(.c) Result;
pub extern fn vkDestroyRenderPass(
    device: Device,
    renderPass: RenderPass,
    pAllocator: ?*const AllocationCallbacks,
) callconv(.c) void;
pub extern fn vkCreateGraphicsPipelines(
    device: Device,
    pipelineCache: PipelineCache,
    createInfoCount: u32,
    pCreateInfos: ?[*]const GraphicsPipelineCreateInfo,
    pAllocator: ?*const AllocationCallbacks,
    pPipelines: ?[*]Pipeline,
) callconv(.c) Result;
pub extern fn vkDestroyPipeline(
    device: Device,
    pipeline: Pipeline,
    pAllocator: ?*const AllocationCallbacks,
) callconv(.c) void;
pub extern fn vkCreatePipelineCache(
    device: Device,
    pCreateInfo: *const PipelineCacheCreateInfo,
    pAllocator: ?*const AllocationCallbacks,
    pPipelineCache: *PipelineCache,
) callconv(.c) Result;
pub extern fn vkDestroyPipelineCache(
    device: Device,
    pipelineCache: PipelineCache,
    pAllocator: ?*const AllocationCallbacks,
) callconv(.c) void;
pub extern fn vkGetPipelineCacheData(
    device: Device,
    pipelineCache: PipelineCache,
    pDataSize: *usize,
    pData: ?*anyopaque,
) callconv(.c) Result;

// =============================================================================
// Vulkan Functions - Framebuffer
// =============================================================================

pub extern fn vkCreateFramebuffer(
    device: Device,
    pCreateInfo: *const FramebufferCreateInfo,
    pAllocator: ?*const AllocationCallbacks,
    pFramebuffer: *Framebuffer,
) callconv(.c) Result;
pub extern fn vkDestroyFramebuffer(
    device: Device,
    framebuffer: Framebuffer,
    pAllocator: ?*const AllocationCallbacks,
) callconv(.c) void;

// =============================================================================
// Vulkan Functions - Command Buffer
// =============================================================================

pub extern fn vkCreateCommandPool(
    device: Device,
    pCreateInfo: *const CommandPoolCreateInfo,
    pAllocator: ?*const AllocationCallbacks,
    pCommandPool: *CommandPool,
) callconv(.c) Result;
pub extern fn vkDestroyCommandPool(
    device: Device,
    commandPool: CommandPool,
    pAllocator: ?*const AllocationCallbacks,
) callconv(.c) void;
pub extern fn vkAllocateCommandBuffers(
    device: Device,
    pAllocateInfo: *const CommandBufferAllocateInfo,
    pCommandBuffers: ?[*]CommandBuffer,
) callconv(.c) Result;
pub extern fn vkFreeCommandBuffers(
    device: Device,
    commandPool: CommandPool,
    commandBufferCount: u32,
    pCommandBuffers: ?[*]const CommandBuffer,
) callconv(.c) void;
pub extern fn vkResetCommandBuffer(
    commandBuffer: CommandBuffer,
    flags: CommandBufferResetFlags,
) callconv(.c) Result;

pub extern fn vkBeginCommandBuffer(
    commandBuffer: CommandBuffer,
    pBeginInfo: *const CommandBufferBeginInfo,
) callconv(.c) Result;
pub extern fn vkEndCommandBuffer(commandBuffer: CommandBuffer) callconv(.c) Result;
pub extern fn vkCmdBeginRenderPass(
    commandBuffer: CommandBuffer,
    pRenderPassBegin: *const RenderPassBeginInfo,
    contents: SubpassContents,
) callconv(.c) void;
pub extern fn vkCmdEndRenderPass(commandBuffer: CommandBuffer) callconv(.c) void;
pub extern fn vkCmdBindPipeline(
    commandBuffer: CommandBuffer,
    pipelineBindPoint: PipelineBindPoint,
    pipeline: Pipeline,
) callconv(.c) void;
pub extern fn vkCmdSetViewport(
    commandBuffer: CommandBuffer,
    firstViewport: u32,
    viewportCount: u32,
    pViewports: ?[*]const Viewport,
) callconv(.c) void;
pub extern fn vkCmdSetScissor(
    commandBuffer: CommandBuffer,
    firstScissor: u32,
    scissorCount: u32,
    pScissors: ?[*]const Rect2D,
) callconv(.c) void;
pub extern fn vkCmdDraw(
    commandBuffer: CommandBuffer,
    vertexCount: u32,
    instanceCount: u32,
    firstVertex: u32,
    firstInstance: u32,
) callconv(.c) void;
pub extern fn vkCmdDrawIndexed(
    commandBuffer: CommandBuffer,
    indexCount: u32,
    instanceCount: u32,
    firstIndex: u32,
    vertexOffset: i32,
    firstInstance: u32,
) callconv(.c) void;
pub extern fn vkCmdBindVertexBuffers(
    commandBuffer: CommandBuffer,
    firstBinding: u32,
    bindingCount: u32,
    pBuffers: ?[*]const Buffer,
    pOffsets: ?[*]const DeviceSize,
) callconv(.c) void;
pub extern fn vkCmdBindIndexBuffer(
    commandBuffer: CommandBuffer,
    buffer: Buffer,
    offset: DeviceSize,
    indexType: IndexType,
) callconv(.c) void;
pub extern fn vkCmdBindDescriptorSets(
    commandBuffer: CommandBuffer,
    pipelineBindPoint: PipelineBindPoint,
    layout: PipelineLayout,
    firstSet: u32,
    descriptorSetCount: u32,
    pDescriptorSets: ?[*]const DescriptorSet,
    dynamicOffsetCount: u32,
    pDynamicOffsets: ?[*]const u32,
) callconv(.c) void;
pub extern fn vkCmdCopyBufferToImage(
    commandBuffer: CommandBuffer,
    srcBuffer: Buffer,
    dstImage: Image,
    dstImageLayout: ImageLayout,
    regionCount: u32,
    pRegions: ?[*]const BufferImageCopy,
) callconv(.c) void;
pub extern fn vkCmdPipelineBarrier(
    commandBuffer: CommandBuffer,
    srcStageMask: PipelineStageFlags,
    dstStageMask: PipelineStageFlags,
    dependencyFlags: DependencyFlags,
    memoryBarrierCount: u32,
    pMemoryBarriers: ?[*]const MemoryBarrier,
    bufferMemoryBarrierCount: u32,
    pBufferMemoryBarriers: ?[*]const BufferMemoryBarrier,
    imageMemoryBarrierCount: u32,
    pImageMemoryBarriers: ?[*]const ImageMemoryBarrier,
) callconv(.c) void;

// =============================================================================
// Vulkan Functions - Synchronization
// =============================================================================

pub extern fn vkCreateSemaphore(
    device: Device,
    pCreateInfo: *const SemaphoreCreateInfo,
    pAllocator: ?*const AllocationCallbacks,
    pSemaphore: *Semaphore,
) callconv(.c) Result;
pub extern fn vkDestroySemaphore(
    device: Device,
    semaphore: Semaphore,
    pAllocator: ?*const AllocationCallbacks,
) callconv(.c) void;
pub extern fn vkCreateFence(
    device: Device,
    pCreateInfo: *const FenceCreateInfo,
    pAllocator: ?*const AllocationCallbacks,
    pFence: *Fence,
) callconv(.c) Result;
pub extern fn vkDestroyFence(
    device: Device,
    fence: Fence,
    pAllocator: ?*const AllocationCallbacks,
) callconv(.c) void;
pub extern fn vkWaitForFences(
    device: Device,
    fenceCount: u32,
    pFences: ?[*]const Fence,
    waitAll: Bool32,
    timeout: u64,
) callconv(.c) Result;
pub extern fn vkResetFences(
    device: Device,
    fenceCount: u32,
    pFences: ?[*]const Fence,
) callconv(.c) Result;
pub extern fn vkQueueSubmit(
    queue: Queue,
    submitCount: u32,
    pSubmits: ?[*]const SubmitInfo,
    fence: Fence,
) callconv(.c) Result;
pub extern fn vkQueueWaitIdle(queue: Queue) callconv(.c) Result;

// =============================================================================
// Vulkan Functions - Descriptor
// =============================================================================

pub extern fn vkCreateDescriptorSetLayout(
    device: Device,
    pCreateInfo: *const DescriptorSetLayoutCreateInfo,
    pAllocator: ?*const AllocationCallbacks,
    pSetLayout: *DescriptorSetLayout,
) callconv(.c) Result;
pub extern fn vkDestroyDescriptorSetLayout(
    device: Device,
    descriptorSetLayout: DescriptorSetLayout,
    pAllocator: ?*const AllocationCallbacks,
) callconv(.c) void;
pub extern fn vkCreateDescriptorPool(
    device: Device,
    pCreateInfo: *const DescriptorPoolCreateInfo,
    pAllocator: ?*const AllocationCallbacks,
    pDescriptorPool: *DescriptorPool,
) callconv(.c) Result;
pub extern fn vkDestroyDescriptorPool(
    device: Device,
    descriptorPool: DescriptorPool,
    pAllocator: ?*const AllocationCallbacks,
) callconv(.c) void;
pub extern fn vkAllocateDescriptorSets(
    device: Device,
    pAllocateInfo: *const DescriptorSetAllocateInfo,
    pDescriptorSets: ?[*]DescriptorSet,
) callconv(.c) Result;
pub extern fn vkUpdateDescriptorSets(
    device: Device,
    descriptorWriteCount: u32,
    pDescriptorWrites: ?[*]const WriteDescriptorSet,
    descriptorCopyCount: u32,
    pDescriptorCopies: ?[*]const CopyDescriptorSet,
) callconv(.c) void;

// =============================================================================
// Vulkan Functions - Sampler
// =============================================================================

pub extern fn vkCreateSampler(
    device: Device,
    pCreateInfo: *const SamplerCreateInfo,
    pAllocator: ?*const AllocationCallbacks,
    pSampler: *Sampler,
) callconv(.c) Result;
pub extern fn vkDestroySampler(
    device: Device,
    sampler: Sampler,
    pAllocator: ?*const AllocationCallbacks,
) callconv(.c) void;

// =============================================================================
// Validation Layer Support
// =============================================================================

/// Validation layer name for Khronos validation
pub const VALIDATION_LAYER_NAME: [*:0]const u8 = "VK_LAYER_KHRONOS_validation";

/// Check if the Khronos validation layer is available
pub fn isValidationLayerAvailable() bool {
    var layer_count: u32 = 0;
    _ = vkEnumerateInstanceLayerProperties(&layer_count, null);
    if (layer_count == 0) return false;

    // Use stack-allocated array with reasonable limit
    var layers: [64]LayerProperties = undefined;
    var count: u32 = @min(layer_count, 64);
    _ = vkEnumerateInstanceLayerProperties(&count, &layers);

    for (layers[0..count]) |layer| {
        const name: [*:0]const u8 = @ptrCast(&layer.layerName);
        if (std.mem.eql(u8, std.mem.sliceTo(name, 0), "VK_LAYER_KHRONOS_validation")) {
            return true;
        }
    }
    return false;
}

// =============================================================================
// Helper Functions
// =============================================================================

/// Find a memory type index that satisfies the requirements
pub fn findMemoryType(
    mem_properties: *const PhysicalDeviceMemoryProperties,
    type_filter: u32,
    required_properties: u32,
) ?u32 {
    var i: u32 = 0;
    while (i < mem_properties.memoryTypeCount) : (i += 1) {
        const type_matches = (type_filter & (@as(u32, 1) << @intCast(i))) != 0;
        const property_flags = mem_properties.memoryTypes[i].propertyFlags;
        const props_match = (property_flags & required_properties) == required_properties;
        if (type_matches and props_match) {
            return i;
        }
    }
    return null;
}

/// Create a simple clear color value
pub fn clearColor(r: f32, g: f32, b: f32, a: f32) ClearValue {
    return .{ .color = .{ .float32 = .{ r, g, b, a } } };
}

/// Make a simple viewport with Y-flip to match OpenGL/Metal coordinate system.
/// Vulkan's default clip space has Y going from -1 (top) to +1 (bottom),
/// which is opposite of OpenGL/Metal. Using negative height flips this.
/// This requires VK_KHR_maintenance1 (core in Vulkan 1.1+).
pub fn makeViewport(width: f32, height: f32) Viewport {
    return .{
        .x = 0,
        .y = height, // Start from bottom
        .width = width,
        .height = -height, // Negative height flips Y axis
        .minDepth = 0,
        .maxDepth = 1,
    };
}

/// Make a simple scissor rect
pub fn makeScissor(width: u32, height: u32) Rect2D {
    return .{
        .offset = .{ .x = 0, .y = 0 },
        .extent = .{ .width = width, .height = height },
    };
}

// =============================================================================
// Layout Pins
// =============================================================================

// Sizes and offsets below were measured once against translate-c output of
// `vulkan.h` (Vulkan headers 1.3.239) on x86_64-linux and aarch64-linux, where
// every struct also matched field by field. Khronos freezes released layouts,
// so these are permanent facts: a failure here means this file was edited
// incorrectly, never that Vulkan changed.

// Every struct and union: catches a missing, extra, or resized field.
comptime {
    assert(@sizeOf(ApplicationInfo) == 48);
    assert(@sizeOf(InstanceCreateInfo) == 64);
    assert(@sizeOf(DeviceQueueCreateInfo) == 40);
    assert(@sizeOf(DeviceCreateInfo) == 72);
    assert(@sizeOf(WaylandSurfaceCreateInfoKHR) == 40);
    assert(@sizeOf(SwapchainCreateInfoKHR) == 104);
    assert(@sizeOf(ImageViewCreateInfo) == 80);
    assert(@sizeOf(ImageCreateInfo) == 88);
    assert(@sizeOf(BufferCreateInfo) == 56);
    assert(@sizeOf(MemoryAllocateInfo) == 32);
    assert(@sizeOf(ShaderModuleCreateInfo) == 40);
    assert(@sizeOf(PipelineShaderStageCreateInfo) == 48);
    assert(@sizeOf(PipelineVertexInputStateCreateInfo) == 48);
    assert(@sizeOf(PipelineInputAssemblyStateCreateInfo) == 32);
    assert(@sizeOf(PipelineViewportStateCreateInfo) == 48);
    assert(@sizeOf(PipelineRasterizationStateCreateInfo) == 64);
    assert(@sizeOf(PipelineMultisampleStateCreateInfo) == 48);
    assert(@sizeOf(PipelineColorBlendAttachmentState) == 32);
    assert(@sizeOf(PipelineColorBlendStateCreateInfo) == 56);
    assert(@sizeOf(PipelineDynamicStateCreateInfo) == 32);
    assert(@sizeOf(PipelineLayoutCreateInfo) == 48);
    assert(@sizeOf(AttachmentDescription) == 36);
    assert(@sizeOf(AttachmentReference) == 8);
    assert(@sizeOf(SubpassDescription) == 72);
    assert(@sizeOf(SubpassDependency) == 28);
    assert(@sizeOf(RenderPassCreateInfo) == 64);
    assert(@sizeOf(GraphicsPipelineCreateInfo) == 144);
    assert(@sizeOf(FramebufferCreateInfo) == 64);
    assert(@sizeOf(CommandPoolCreateInfo) == 24);
    assert(@sizeOf(CommandBufferAllocateInfo) == 32);
    assert(@sizeOf(CommandBufferBeginInfo) == 32);
    assert(@sizeOf(RenderPassBeginInfo) == 64);
    assert(@sizeOf(SemaphoreCreateInfo) == 24);
    assert(@sizeOf(FenceCreateInfo) == 24);
    assert(@sizeOf(SubmitInfo) == 72);
    assert(@sizeOf(PresentInfoKHR) == 64);
    assert(@sizeOf(DescriptorSetLayoutBinding) == 24);
    assert(@sizeOf(DescriptorSetLayoutCreateInfo) == 32);
    assert(@sizeOf(DescriptorPoolSize) == 8);
    assert(@sizeOf(DescriptorPoolCreateInfo) == 40);
}
comptime {
    assert(@sizeOf(DescriptorSetAllocateInfo) == 40);
    assert(@sizeOf(DescriptorBufferInfo) == 24);
    assert(@sizeOf(DescriptorImageInfo) == 24);
    assert(@sizeOf(WriteDescriptorSet) == 64);
    assert(@sizeOf(SamplerCreateInfo) == 80);
    assert(@sizeOf(ImageMemoryBarrier) == 72);
    assert(@sizeOf(BufferImageCopy) == 56);
    assert(@sizeOf(PipelineCacheCreateInfo) == 40);
    assert(@sizeOf(DebugUtilsMessengerCreateInfoEXT) == 48);
    assert(@sizeOf(DebugUtilsMessengerCallbackDataEXT) == 96);
    assert(@sizeOf(Extent2D) == 8);
    assert(@sizeOf(Extent3D) == 12);
    assert(@sizeOf(Offset2D) == 8);
    assert(@sizeOf(Offset3D) == 12);
    assert(@sizeOf(Rect2D) == 16);
    assert(@sizeOf(Viewport) == 24);
    assert(@sizeOf(ClearValue) == 16);
    assert(@sizeOf(ClearColorValue) == 16);
    assert(@sizeOf(ComponentMapping) == 16);
    assert(@sizeOf(ImageSubresourceRange) == 20);
    assert(@sizeOf(ImageSubresourceLayers) == 16);
    assert(@sizeOf(MemoryRequirements) == 24);
    assert(@sizeOf(QueueFamilyProperties) == 24);
    assert(@sizeOf(SurfaceCapabilitiesKHR) == 52);
    assert(@sizeOf(SurfaceFormatKHR) == 8);
    assert(@sizeOf(PhysicalDeviceProperties) == 824);
    assert(@sizeOf(PhysicalDeviceMemoryProperties) == 520);
    assert(@sizeOf(PhysicalDeviceFeatures) == 220);
    assert(@sizeOf(VertexInputBindingDescription) == 12);
    assert(@sizeOf(VertexInputAttributeDescription) == 16);
    assert(@sizeOf(SpecializationInfo) == 32);
    assert(@sizeOf(SpecializationMapEntry) == 16);
    assert(@sizeOf(PushConstantRange) == 12);
    assert(@sizeOf(PipelineTessellationStateCreateInfo) == 24);
    assert(@sizeOf(PipelineDepthStencilStateCreateInfo) == 104);
    assert(@sizeOf(StencilOpState) == 28);
    assert(@sizeOf(CommandBufferInheritanceInfo) == 56);
    assert(@sizeOf(ClearDepthStencilValue) == 8);
    assert(@sizeOf(DebugUtilsLabelEXT) == 40);
    assert(@sizeOf(DebugUtilsObjectNameInfoEXT) == 40);
}
comptime {
    assert(@sizeOf(PhysicalDeviceLimits) == 504);
    assert(@sizeOf(PhysicalDeviceSparseProperties) == 20);
    assert(@sizeOf(MemoryType) == 8);
    assert(@sizeOf(MemoryHeap) == 16);
    assert(@sizeOf(LayerProperties) == 520);
    assert(@sizeOf(MappedMemoryRange) == 40);
    assert(@sizeOf(MemoryBarrier) == 24);
    assert(@sizeOf(BufferMemoryBarrier) == 56);
    assert(@sizeOf(CopyDescriptorSet) == 56);
}

// Driver-written structs: the renderer reads these fields directly, so a
// same-size transposition would silently read the wrong value. Pin every
// field offset.
comptime {
    assert(@offsetOf(MemoryRequirements, "size") == 0);
    assert(@offsetOf(MemoryRequirements, "alignment") == 8);
    assert(@offsetOf(MemoryRequirements, "memoryTypeBits") == 16);
}
comptime {
    assert(@offsetOf(QueueFamilyProperties, "queueFlags") == 0);
    assert(@offsetOf(QueueFamilyProperties, "queueCount") == 4);
    assert(@offsetOf(QueueFamilyProperties, "timestampValidBits") == 8);
    assert(@offsetOf(QueueFamilyProperties, "minImageTransferGranularity") == 12);
}
comptime {
    assert(@offsetOf(SurfaceCapabilitiesKHR, "minImageCount") == 0);
    assert(@offsetOf(SurfaceCapabilitiesKHR, "maxImageCount") == 4);
    assert(@offsetOf(SurfaceCapabilitiesKHR, "currentExtent") == 8);
    assert(@offsetOf(SurfaceCapabilitiesKHR, "minImageExtent") == 16);
    assert(@offsetOf(SurfaceCapabilitiesKHR, "maxImageExtent") == 24);
    assert(@offsetOf(SurfaceCapabilitiesKHR, "maxImageArrayLayers") == 32);
    assert(@offsetOf(SurfaceCapabilitiesKHR, "supportedTransforms") == 36);
    assert(@offsetOf(SurfaceCapabilitiesKHR, "currentTransform") == 40);
    assert(@offsetOf(SurfaceCapabilitiesKHR, "supportedCompositeAlpha") == 44);
    assert(@offsetOf(SurfaceCapabilitiesKHR, "supportedUsageFlags") == 48);
}
comptime {
    assert(@offsetOf(SurfaceFormatKHR, "format") == 0);
    assert(@offsetOf(SurfaceFormatKHR, "colorSpace") == 4);
}
comptime {
    assert(@offsetOf(PhysicalDeviceProperties, "apiVersion") == 0);
    assert(@offsetOf(PhysicalDeviceProperties, "driverVersion") == 4);
    assert(@offsetOf(PhysicalDeviceProperties, "vendorID") == 8);
    assert(@offsetOf(PhysicalDeviceProperties, "deviceID") == 12);
    assert(@offsetOf(PhysicalDeviceProperties, "deviceType") == 16);
    assert(@offsetOf(PhysicalDeviceProperties, "deviceName") == 20);
    assert(@offsetOf(PhysicalDeviceProperties, "pipelineCacheUUID") == 276);
    assert(@offsetOf(PhysicalDeviceProperties, "limits") == 296);
    assert(@offsetOf(PhysicalDeviceProperties, "sparseProperties") == 800);
}
comptime {
    assert(@offsetOf(PhysicalDeviceMemoryProperties, "memoryTypeCount") == 0);
    assert(@offsetOf(PhysicalDeviceMemoryProperties, "memoryTypes") == 4);
    assert(@offsetOf(PhysicalDeviceMemoryProperties, "memoryHeapCount") == 260);
    assert(@offsetOf(PhysicalDeviceMemoryProperties, "memoryHeaps") == 264);
}
comptime {
    assert(@offsetOf(PhysicalDeviceLimits, "maxImageDimension1D") == 0);
    assert(@offsetOf(PhysicalDeviceLimits, "maxImageDimension2D") == 4);
    assert(@offsetOf(PhysicalDeviceLimits, "maxImageDimension3D") == 8);
    assert(@offsetOf(PhysicalDeviceLimits, "maxImageDimensionCube") == 12);
    assert(@offsetOf(PhysicalDeviceLimits, "maxImageArrayLayers") == 16);
    assert(@offsetOf(PhysicalDeviceLimits, "maxTexelBufferElements") == 20);
    assert(@offsetOf(PhysicalDeviceLimits, "maxUniformBufferRange") == 24);
    assert(@offsetOf(PhysicalDeviceLimits, "maxStorageBufferRange") == 28);
    assert(@offsetOf(PhysicalDeviceLimits, "maxPushConstantsSize") == 32);
    assert(@offsetOf(PhysicalDeviceLimits, "maxMemoryAllocationCount") == 36);
    assert(@offsetOf(PhysicalDeviceLimits, "maxSamplerAllocationCount") == 40);
    assert(@offsetOf(PhysicalDeviceLimits, "bufferImageGranularity") == 48);
    assert(@offsetOf(PhysicalDeviceLimits, "sparseAddressSpaceSize") == 56);
    assert(@offsetOf(PhysicalDeviceLimits, "maxBoundDescriptorSets") == 64);
    assert(@offsetOf(PhysicalDeviceLimits, "maxPerStageDescriptorSamplers") == 68);
    assert(@offsetOf(PhysicalDeviceLimits, "maxPerStageDescriptorUniformBuffers") == 72);
    assert(@offsetOf(PhysicalDeviceLimits, "maxPerStageDescriptorStorageBuffers") == 76);
    assert(@offsetOf(PhysicalDeviceLimits, "maxPerStageDescriptorSampledImages") == 80);
    assert(@offsetOf(PhysicalDeviceLimits, "maxPerStageDescriptorStorageImages") == 84);
    assert(@offsetOf(PhysicalDeviceLimits, "maxPerStageDescriptorInputAttachments") == 88);
    assert(@offsetOf(PhysicalDeviceLimits, "maxPerStageResources") == 92);
    assert(@offsetOf(PhysicalDeviceLimits, "maxDescriptorSetSamplers") == 96);
    assert(@offsetOf(PhysicalDeviceLimits, "maxDescriptorSetUniformBuffers") == 100);
    assert(@offsetOf(PhysicalDeviceLimits, "maxDescriptorSetUniformBuffersDynamic") == 104);
    assert(@offsetOf(PhysicalDeviceLimits, "maxDescriptorSetStorageBuffers") == 108);
    assert(@offsetOf(PhysicalDeviceLimits, "maxDescriptorSetStorageBuffersDynamic") == 112);
    assert(@offsetOf(PhysicalDeviceLimits, "maxDescriptorSetSampledImages") == 116);
    assert(@offsetOf(PhysicalDeviceLimits, "maxDescriptorSetStorageImages") == 120);
    assert(@offsetOf(PhysicalDeviceLimits, "maxDescriptorSetInputAttachments") == 124);
    assert(@offsetOf(PhysicalDeviceLimits, "maxVertexInputAttributes") == 128);
    assert(@offsetOf(PhysicalDeviceLimits, "maxVertexInputBindings") == 132);
    assert(@offsetOf(PhysicalDeviceLimits, "maxVertexInputAttributeOffset") == 136);
    assert(@offsetOf(PhysicalDeviceLimits, "maxVertexInputBindingStride") == 140);
    assert(@offsetOf(PhysicalDeviceLimits, "maxVertexOutputComponents") == 144);
    assert(@offsetOf(PhysicalDeviceLimits, "maxTessellationGenerationLevel") == 148);
    assert(@offsetOf(PhysicalDeviceLimits, "maxTessellationPatchSize") == 152);
    assert(@offsetOf(PhysicalDeviceLimits, "maxTessellationControlPerVertexInputComponents") ==
        156);
    assert(@offsetOf(PhysicalDeviceLimits, "maxTessellationControlPerVertexOutputComponents") ==
        160);
    assert(@offsetOf(PhysicalDeviceLimits, "maxTessellationControlPerPatchOutputComponents") ==
        164);
    assert(@offsetOf(PhysicalDeviceLimits, "maxTessellationControlTotalOutputComponents") == 168);
    assert(@offsetOf(PhysicalDeviceLimits, "maxTessellationEvaluationInputComponents") == 172);
    assert(@offsetOf(PhysicalDeviceLimits, "maxTessellationEvaluationOutputComponents") == 176);
    assert(@offsetOf(PhysicalDeviceLimits, "maxGeometryShaderInvocations") == 180);
    assert(@offsetOf(PhysicalDeviceLimits, "maxGeometryInputComponents") == 184);
    assert(@offsetOf(PhysicalDeviceLimits, "maxGeometryOutputComponents") == 188);
    assert(@offsetOf(PhysicalDeviceLimits, "maxGeometryOutputVertices") == 192);
    assert(@offsetOf(PhysicalDeviceLimits, "maxGeometryTotalOutputComponents") == 196);
    assert(@offsetOf(PhysicalDeviceLimits, "maxFragmentInputComponents") == 200);
    assert(@offsetOf(PhysicalDeviceLimits, "maxFragmentOutputAttachments") == 204);
    assert(@offsetOf(PhysicalDeviceLimits, "maxFragmentDualSrcAttachments") == 208);
    assert(@offsetOf(PhysicalDeviceLimits, "maxFragmentCombinedOutputResources") == 212);
    assert(@offsetOf(PhysicalDeviceLimits, "maxComputeSharedMemorySize") == 216);
    assert(@offsetOf(PhysicalDeviceLimits, "maxComputeWorkGroupCount") == 220);
    assert(@offsetOf(PhysicalDeviceLimits, "maxComputeWorkGroupInvocations") == 232);
    assert(@offsetOf(PhysicalDeviceLimits, "maxComputeWorkGroupSize") == 236);
    assert(@offsetOf(PhysicalDeviceLimits, "subPixelPrecisionBits") == 248);
    assert(@offsetOf(PhysicalDeviceLimits, "subTexelPrecisionBits") == 252);
    assert(@offsetOf(PhysicalDeviceLimits, "mipmapPrecisionBits") == 256);
    assert(@offsetOf(PhysicalDeviceLimits, "maxDrawIndexedIndexValue") == 260);
    assert(@offsetOf(PhysicalDeviceLimits, "maxDrawIndirectCount") == 264);
}
comptime {
    assert(@offsetOf(PhysicalDeviceLimits, "maxSamplerLodBias") == 268);
    assert(@offsetOf(PhysicalDeviceLimits, "maxSamplerAnisotropy") == 272);
    assert(@offsetOf(PhysicalDeviceLimits, "maxViewports") == 276);
    assert(@offsetOf(PhysicalDeviceLimits, "maxViewportDimensions") == 280);
    assert(@offsetOf(PhysicalDeviceLimits, "viewportBoundsRange") == 288);
    assert(@offsetOf(PhysicalDeviceLimits, "viewportSubPixelBits") == 296);
    assert(@offsetOf(PhysicalDeviceLimits, "minMemoryMapAlignment") == 304);
    assert(@offsetOf(PhysicalDeviceLimits, "minTexelBufferOffsetAlignment") == 312);
    assert(@offsetOf(PhysicalDeviceLimits, "minUniformBufferOffsetAlignment") == 320);
    assert(@offsetOf(PhysicalDeviceLimits, "minStorageBufferOffsetAlignment") == 328);
    assert(@offsetOf(PhysicalDeviceLimits, "minTexelOffset") == 336);
    assert(@offsetOf(PhysicalDeviceLimits, "maxTexelOffset") == 340);
    assert(@offsetOf(PhysicalDeviceLimits, "minTexelGatherOffset") == 344);
    assert(@offsetOf(PhysicalDeviceLimits, "maxTexelGatherOffset") == 348);
    assert(@offsetOf(PhysicalDeviceLimits, "minInterpolationOffset") == 352);
    assert(@offsetOf(PhysicalDeviceLimits, "maxInterpolationOffset") == 356);
    assert(@offsetOf(PhysicalDeviceLimits, "subPixelInterpolationOffsetBits") == 360);
    assert(@offsetOf(PhysicalDeviceLimits, "maxFramebufferWidth") == 364);
    assert(@offsetOf(PhysicalDeviceLimits, "maxFramebufferHeight") == 368);
    assert(@offsetOf(PhysicalDeviceLimits, "maxFramebufferLayers") == 372);
    assert(@offsetOf(PhysicalDeviceLimits, "framebufferColorSampleCounts") == 376);
    assert(@offsetOf(PhysicalDeviceLimits, "framebufferDepthSampleCounts") == 380);
    assert(@offsetOf(PhysicalDeviceLimits, "framebufferStencilSampleCounts") == 384);
    assert(@offsetOf(PhysicalDeviceLimits, "framebufferNoAttachmentsSampleCounts") == 388);
    assert(@offsetOf(PhysicalDeviceLimits, "maxColorAttachments") == 392);
    assert(@offsetOf(PhysicalDeviceLimits, "sampledImageColorSampleCounts") == 396);
    assert(@offsetOf(PhysicalDeviceLimits, "sampledImageIntegerSampleCounts") == 400);
    assert(@offsetOf(PhysicalDeviceLimits, "sampledImageDepthSampleCounts") == 404);
    assert(@offsetOf(PhysicalDeviceLimits, "sampledImageStencilSampleCounts") == 408);
    assert(@offsetOf(PhysicalDeviceLimits, "storageImageSampleCounts") == 412);
    assert(@offsetOf(PhysicalDeviceLimits, "maxSampleMaskWords") == 416);
    assert(@offsetOf(PhysicalDeviceLimits, "timestampComputeAndGraphics") == 420);
    assert(@offsetOf(PhysicalDeviceLimits, "timestampPeriod") == 424);
    assert(@offsetOf(PhysicalDeviceLimits, "maxClipDistances") == 428);
    assert(@offsetOf(PhysicalDeviceLimits, "maxCullDistances") == 432);
    assert(@offsetOf(PhysicalDeviceLimits, "maxCombinedClipAndCullDistances") == 436);
    assert(@offsetOf(PhysicalDeviceLimits, "discreteQueuePriorities") == 440);
    assert(@offsetOf(PhysicalDeviceLimits, "pointSizeRange") == 444);
    assert(@offsetOf(PhysicalDeviceLimits, "lineWidthRange") == 452);
    assert(@offsetOf(PhysicalDeviceLimits, "pointSizeGranularity") == 460);
    assert(@offsetOf(PhysicalDeviceLimits, "lineWidthGranularity") == 464);
    assert(@offsetOf(PhysicalDeviceLimits, "strictLines") == 468);
    assert(@offsetOf(PhysicalDeviceLimits, "standardSampleLocations") == 472);
    assert(@offsetOf(PhysicalDeviceLimits, "optimalBufferCopyOffsetAlignment") == 480);
    assert(@offsetOf(PhysicalDeviceLimits, "optimalBufferCopyRowPitchAlignment") == 488);
    assert(@offsetOf(PhysicalDeviceLimits, "nonCoherentAtomSize") == 496);
}
comptime {
    assert(@offsetOf(PhysicalDeviceSparseProperties, "residencyStandard2DBlockShape") == 0);
    assert(@offsetOf(PhysicalDeviceSparseProperties, "residencyStandard2DMultisampleBlockShape") ==
        4);
    assert(@offsetOf(PhysicalDeviceSparseProperties, "residencyStandard3DBlockShape") == 8);
    assert(@offsetOf(PhysicalDeviceSparseProperties, "residencyAlignedMipSize") == 12);
    assert(@offsetOf(PhysicalDeviceSparseProperties, "residencyNonResidentStrict") == 16);
}
comptime {
    assert(@offsetOf(MemoryType, "propertyFlags") == 0);
    assert(@offsetOf(MemoryType, "heapIndex") == 4);
}
comptime {
    assert(@offsetOf(MemoryHeap, "size") == 0);
    assert(@offsetOf(MemoryHeap, "flags") == 8);
}
comptime {
    assert(@offsetOf(LayerProperties, "layerName") == 0);
    assert(@offsetOf(LayerProperties, "specVersion") == 256);
    assert(@offsetOf(LayerProperties, "implementationVersion") == 260);
    assert(@offsetOf(LayerProperties, "description") == 264);
}
comptime {
    assert(@offsetOf(DebugUtilsMessengerCallbackDataEXT, "sType") == 0);
    assert(@offsetOf(DebugUtilsMessengerCallbackDataEXT, "pNext") == 8);
    assert(@offsetOf(DebugUtilsMessengerCallbackDataEXT, "flags") == 16);
    assert(@offsetOf(DebugUtilsMessengerCallbackDataEXT, "pMessageIdName") == 24);
    assert(@offsetOf(DebugUtilsMessengerCallbackDataEXT, "messageIdNumber") == 32);
    assert(@offsetOf(DebugUtilsMessengerCallbackDataEXT, "pMessage") == 40);
    assert(@offsetOf(DebugUtilsMessengerCallbackDataEXT, "queueLabelCount") == 48);
    assert(@offsetOf(DebugUtilsMessengerCallbackDataEXT, "pQueueLabels") == 56);
    assert(@offsetOf(DebugUtilsMessengerCallbackDataEXT, "cmdBufLabelCount") == 64);
    assert(@offsetOf(DebugUtilsMessengerCallbackDataEXT, "pCmdBufLabels") == 72);
    assert(@offsetOf(DebugUtilsMessengerCallbackDataEXT, "objectCount") == 80);
    assert(@offsetOf(DebugUtilsMessengerCallbackDataEXT, "pObjects") == 88);
}
