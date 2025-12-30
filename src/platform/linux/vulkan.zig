//! Minimal Vulkan bindings for Linux GPU rendering
//!
//! These bindings wrap the Vulkan C API to provide GPU functionality
//! on native Linux platforms with Wayland.
//!
//! Only the subset needed for Gooey's 2D UI rendering is included.
//! Reference: https://registry.khronos.org/vulkan/specs/1.3/html/

const std = @import("std");

// =============================================================================
// C Import - Vulkan headers
// =============================================================================

pub const c = @cImport({
    @cDefine("VK_USE_PLATFORM_WAYLAND_KHR", "1");
    @cInclude("vulkan/vulkan.h");
});

// =============================================================================
// Basic Types
// =============================================================================

pub const Bool32 = c.VkBool32;
pub const DeviceSize = c.VkDeviceSize;

pub const FALSE: Bool32 = c.VK_FALSE;
pub const TRUE: Bool32 = c.VK_TRUE;

pub const WHOLE_SIZE: DeviceSize = c.VK_WHOLE_SIZE;
pub const QUEUE_FAMILY_IGNORED: u32 = c.VK_QUEUE_FAMILY_IGNORED;
pub const SUBPASS_EXTERNAL: u32 = c.VK_SUBPASS_EXTERNAL;

// =============================================================================
// Handle Types (using C types directly for ABI compatibility)
// =============================================================================

pub const Instance = c.VkInstance;
pub const PhysicalDevice = c.VkPhysicalDevice;
pub const Device = c.VkDevice;
pub const Queue = c.VkQueue;
pub const Surface = c.VkSurfaceKHR;
pub const Swapchain = c.VkSwapchainKHR;
pub const Image = c.VkImage;
pub const ImageView = c.VkImageView;
pub const Buffer = c.VkBuffer;
pub const DeviceMemory = c.VkDeviceMemory;
pub const ShaderModule = c.VkShaderModule;
pub const PipelineLayout = c.VkPipelineLayout;
pub const RenderPass = c.VkRenderPass;
pub const Pipeline = c.VkPipeline;
pub const Framebuffer = c.VkFramebuffer;
pub const CommandPool = c.VkCommandPool;
pub const CommandBuffer = c.VkCommandBuffer;
pub const Semaphore = c.VkSemaphore;
pub const Fence = c.VkFence;
pub const DescriptorSetLayout = c.VkDescriptorSetLayout;
pub const DescriptorPool = c.VkDescriptorPool;
pub const DescriptorSet = c.VkDescriptorSet;
pub const Sampler = c.VkSampler;

// =============================================================================
// Result
// =============================================================================

pub const Result = c.VkResult;

pub const SUCCESS = c.VK_SUCCESS;
pub const NOT_READY = c.VK_NOT_READY;
pub const TIMEOUT = c.VK_TIMEOUT;
pub const SUBOPTIMAL_KHR = c.VK_SUBOPTIMAL_KHR;
pub const ERROR_OUT_OF_DATE_KHR = c.VK_ERROR_OUT_OF_DATE_KHR;

pub fn succeeded(result: Result) bool {
    return result >= 0;
}

// =============================================================================
// Constants
// =============================================================================

pub const VK_STRUCTURE_TYPE_APPLICATION_INFO = c.VK_STRUCTURE_TYPE_APPLICATION_INFO;
pub const VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_SUBMIT_INFO = c.VK_STRUCTURE_TYPE_SUBMIT_INFO;
pub const VK_STRUCTURE_TYPE_PRESENT_INFO_KHR = c.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR;
pub const VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR = c.VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR;
pub const VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR = c.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR;
pub const VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
pub const VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
pub const VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
pub const VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
pub const VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_FENCE_CREATE_INFO = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
pub const VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
pub const VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;

// Format constants
pub const VK_FORMAT_UNDEFINED = c.VK_FORMAT_UNDEFINED;
pub const VK_FORMAT_R8_UNORM = c.VK_FORMAT_R8_UNORM;
pub const VK_FORMAT_R8G8B8A8_UNORM = c.VK_FORMAT_R8G8B8A8_UNORM;
pub const VK_FORMAT_R8G8B8A8_SRGB = c.VK_FORMAT_R8G8B8A8_SRGB;
pub const VK_FORMAT_B8G8R8A8_UNORM = c.VK_FORMAT_B8G8R8A8_UNORM;
pub const VK_FORMAT_B8G8R8A8_SRGB = c.VK_FORMAT_B8G8R8A8_SRGB;
pub const VK_FORMAT_R32_SFLOAT = c.VK_FORMAT_R32_SFLOAT;
pub const VK_FORMAT_R32G32_SFLOAT = c.VK_FORMAT_R32G32_SFLOAT;
pub const VK_FORMAT_R32G32B32_SFLOAT = c.VK_FORMAT_R32G32B32_SFLOAT;
pub const VK_FORMAT_R32G32B32A32_SFLOAT = c.VK_FORMAT_R32G32B32A32_SFLOAT;

// Color space
pub const VK_COLOR_SPACE_SRGB_NONLINEAR_KHR = c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR;

// Present mode
pub const VK_PRESENT_MODE_IMMEDIATE_KHR = c.VK_PRESENT_MODE_IMMEDIATE_KHR;
pub const VK_PRESENT_MODE_MAILBOX_KHR = c.VK_PRESENT_MODE_MAILBOX_KHR;
pub const VK_PRESENT_MODE_FIFO_KHR = c.VK_PRESENT_MODE_FIFO_KHR;
pub const VK_PRESENT_MODE_FIFO_RELAXED_KHR = c.VK_PRESENT_MODE_FIFO_RELAXED_KHR;

// Image layout
pub const VK_IMAGE_LAYOUT_UNDEFINED = c.VK_IMAGE_LAYOUT_UNDEFINED;
pub const VK_IMAGE_LAYOUT_GENERAL = c.VK_IMAGE_LAYOUT_GENERAL;
pub const VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
pub const VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
pub const VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL = c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
pub const VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
pub const VK_IMAGE_LAYOUT_PRESENT_SRC_KHR = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;

// Attachment load/store ops
pub const VK_ATTACHMENT_LOAD_OP_LOAD = c.VK_ATTACHMENT_LOAD_OP_LOAD;
pub const VK_ATTACHMENT_LOAD_OP_CLEAR = c.VK_ATTACHMENT_LOAD_OP_CLEAR;
pub const VK_ATTACHMENT_LOAD_OP_DONT_CARE = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE;
pub const VK_ATTACHMENT_STORE_OP_STORE = c.VK_ATTACHMENT_STORE_OP_STORE;
pub const VK_ATTACHMENT_STORE_OP_DONT_CARE = c.VK_ATTACHMENT_STORE_OP_DONT_CARE;

// Image type/view type
pub const VK_IMAGE_TYPE_2D = c.VK_IMAGE_TYPE_2D;
pub const VK_IMAGE_VIEW_TYPE_2D = c.VK_IMAGE_VIEW_TYPE_2D;

// Image tiling
pub const VK_IMAGE_TILING_OPTIMAL = c.VK_IMAGE_TILING_OPTIMAL;
pub const VK_IMAGE_TILING_LINEAR = c.VK_IMAGE_TILING_LINEAR;

// Sharing mode
pub const VK_SHARING_MODE_EXCLUSIVE = c.VK_SHARING_MODE_EXCLUSIVE;

// Pipeline bind point
pub const VK_PIPELINE_BIND_POINT_GRAPHICS = c.VK_PIPELINE_BIND_POINT_GRAPHICS;

// Primitive topology
pub const VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
pub const VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP;

// Polygon mode
pub const VK_POLYGON_MODE_FILL = c.VK_POLYGON_MODE_FILL;

// Cull mode
pub const VK_CULL_MODE_NONE = c.VK_CULL_MODE_NONE;
pub const VK_CULL_MODE_BACK_BIT = c.VK_CULL_MODE_BACK_BIT;

// Front face
pub const VK_FRONT_FACE_COUNTER_CLOCKWISE = c.VK_FRONT_FACE_COUNTER_CLOCKWISE;
pub const VK_FRONT_FACE_CLOCKWISE = c.VK_FRONT_FACE_CLOCKWISE;

// Blend factor
pub const VK_BLEND_FACTOR_ZERO = c.VK_BLEND_FACTOR_ZERO;
pub const VK_BLEND_FACTOR_ONE = c.VK_BLEND_FACTOR_ONE;
pub const VK_BLEND_FACTOR_SRC_ALPHA = c.VK_BLEND_FACTOR_SRC_ALPHA;
pub const VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
pub const VK_BLEND_FACTOR_DST_ALPHA = c.VK_BLEND_FACTOR_DST_ALPHA;
pub const VK_BLEND_FACTOR_ONE_MINUS_DST_ALPHA = c.VK_BLEND_FACTOR_ONE_MINUS_DST_ALPHA;

// Blend op
pub const VK_BLEND_OP_ADD = c.VK_BLEND_OP_ADD;

// Dynamic state
pub const VK_DYNAMIC_STATE_VIEWPORT = c.VK_DYNAMIC_STATE_VIEWPORT;
pub const VK_DYNAMIC_STATE_SCISSOR = c.VK_DYNAMIC_STATE_SCISSOR;

// Shader stage
pub const VK_SHADER_STAGE_VERTEX_BIT = c.VK_SHADER_STAGE_VERTEX_BIT;
pub const VK_SHADER_STAGE_FRAGMENT_BIT = c.VK_SHADER_STAGE_FRAGMENT_BIT;
pub const VK_SHADER_STAGE_ALL_GRAPHICS = c.VK_SHADER_STAGE_ALL_GRAPHICS;

// Descriptor type
pub const VK_DESCRIPTOR_TYPE_SAMPLER = c.VK_DESCRIPTOR_TYPE_SAMPLER;
pub const VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
pub const VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE = c.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE;
pub const VK_DESCRIPTOR_TYPE_STORAGE_IMAGE = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE;
pub const VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
pub const VK_DESCRIPTOR_TYPE_STORAGE_BUFFER = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;

// Vertex input rate
pub const VK_VERTEX_INPUT_RATE_VERTEX = c.VK_VERTEX_INPUT_RATE_VERTEX;
pub const VK_VERTEX_INPUT_RATE_INSTANCE = c.VK_VERTEX_INPUT_RATE_INSTANCE;

// Filter
pub const VK_FILTER_NEAREST = c.VK_FILTER_NEAREST;
pub const VK_FILTER_LINEAR = c.VK_FILTER_LINEAR;

// Sampler mipmap mode
pub const VK_SAMPLER_MIPMAP_MODE_NEAREST = c.VK_SAMPLER_MIPMAP_MODE_NEAREST;
pub const VK_SAMPLER_MIPMAP_MODE_LINEAR = c.VK_SAMPLER_MIPMAP_MODE_LINEAR;

// Sampler address mode
pub const VK_SAMPLER_ADDRESS_MODE_REPEAT = c.VK_SAMPLER_ADDRESS_MODE_REPEAT;
pub const VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
pub const VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER;

// Border color
pub const VK_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK = c.VK_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK;
pub const VK_BORDER_COLOR_FLOAT_OPAQUE_BLACK = c.VK_BORDER_COLOR_FLOAT_OPAQUE_BLACK;
pub const VK_BORDER_COLOR_FLOAT_OPAQUE_WHITE = c.VK_BORDER_COLOR_FLOAT_OPAQUE_WHITE;

// Index type
pub const VK_INDEX_TYPE_UINT16 = c.VK_INDEX_TYPE_UINT16;
pub const VK_INDEX_TYPE_UINT32 = c.VK_INDEX_TYPE_UINT32;

// Command buffer level
pub const VK_COMMAND_BUFFER_LEVEL_PRIMARY = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
pub const VK_COMMAND_BUFFER_LEVEL_SECONDARY = c.VK_COMMAND_BUFFER_LEVEL_SECONDARY;

// Subpass contents
pub const VK_SUBPASS_CONTENTS_INLINE = c.VK_SUBPASS_CONTENTS_INLINE;

// Sample count
pub const VK_SAMPLE_COUNT_1_BIT = c.VK_SAMPLE_COUNT_1_BIT;
pub const VK_SAMPLE_COUNT_2_BIT = c.VK_SAMPLE_COUNT_2_BIT;
pub const VK_SAMPLE_COUNT_4_BIT = c.VK_SAMPLE_COUNT_4_BIT;
pub const VK_SAMPLE_COUNT_8_BIT = c.VK_SAMPLE_COUNT_8_BIT;

// Queue flags
pub const VK_QUEUE_GRAPHICS_BIT = c.VK_QUEUE_GRAPHICS_BIT;
pub const VK_QUEUE_COMPUTE_BIT = c.VK_QUEUE_COMPUTE_BIT;
pub const VK_QUEUE_TRANSFER_BIT = c.VK_QUEUE_TRANSFER_BIT;

// Buffer usage flags
pub const VK_BUFFER_USAGE_TRANSFER_SRC_BIT = c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT;
pub const VK_BUFFER_USAGE_TRANSFER_DST_BIT = c.VK_BUFFER_USAGE_TRANSFER_DST_BIT;
pub const VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT = c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT;
pub const VK_BUFFER_USAGE_STORAGE_BUFFER_BIT = c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT;
pub const VK_BUFFER_USAGE_INDEX_BUFFER_BIT = c.VK_BUFFER_USAGE_INDEX_BUFFER_BIT;
pub const VK_BUFFER_USAGE_VERTEX_BUFFER_BIT = c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT;

// Image usage flags
pub const VK_IMAGE_USAGE_TRANSFER_SRC_BIT = c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
pub const VK_IMAGE_USAGE_TRANSFER_DST_BIT = c.VK_IMAGE_USAGE_TRANSFER_DST_BIT;
pub const VK_IMAGE_USAGE_SAMPLED_BIT = c.VK_IMAGE_USAGE_SAMPLED_BIT;
pub const VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
pub const VK_IMAGE_USAGE_TRANSIENT_ATTACHMENT_BIT = c.VK_IMAGE_USAGE_TRANSIENT_ATTACHMENT_BIT;

// Memory property flags
pub const VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT = c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT;
pub const VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT = c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT;
pub const VK_MEMORY_PROPERTY_HOST_COHERENT_BIT = c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;

// Color component flags
pub const VK_COLOR_COMPONENT_R_BIT = c.VK_COLOR_COMPONENT_R_BIT;
pub const VK_COLOR_COMPONENT_G_BIT = c.VK_COLOR_COMPONENT_G_BIT;
pub const VK_COLOR_COMPONENT_B_BIT = c.VK_COLOR_COMPONENT_B_BIT;
pub const VK_COLOR_COMPONENT_A_BIT = c.VK_COLOR_COMPONENT_A_BIT;
pub const VK_COLOR_COMPONENT_ALL = VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT | VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT;

// Image aspect flags
pub const VK_IMAGE_ASPECT_COLOR_BIT = c.VK_IMAGE_ASPECT_COLOR_BIT;

// Pipeline stage flags
pub const VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT = c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT;
pub const VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT = c.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT;
pub const VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
pub const VK_PIPELINE_STAGE_TRANSFER_BIT = c.VK_PIPELINE_STAGE_TRANSFER_BIT;
pub const VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT = c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;

// Access flags
pub const VK_ACCESS_COLOR_ATTACHMENT_READ_BIT = c.VK_ACCESS_COLOR_ATTACHMENT_READ_BIT;
pub const VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
pub const VK_ACCESS_TRANSFER_READ_BIT = c.VK_ACCESS_TRANSFER_READ_BIT;
pub const VK_ACCESS_TRANSFER_WRITE_BIT = c.VK_ACCESS_TRANSFER_WRITE_BIT;
pub const VK_ACCESS_SHADER_READ_BIT = c.VK_ACCESS_SHADER_READ_BIT;
pub const VK_ACCESS_MEMORY_READ_BIT = c.VK_ACCESS_MEMORY_READ_BIT;

// Composite alpha
pub const VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR = c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;

// Command pool flags
pub const VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;

// Fence flags
pub const VK_FENCE_CREATE_SIGNALED_BIT = c.VK_FENCE_CREATE_SIGNALED_BIT;

// Dependency flags
pub const VK_DEPENDENCY_BY_REGION_BIT = c.VK_DEPENDENCY_BY_REGION_BIT;

// Component swizzle
pub const VK_COMPONENT_SWIZZLE_IDENTITY = c.VK_COMPONENT_SWIZZLE_IDENTITY;

// Compare op
pub const VK_COMPARE_OP_NEVER = c.VK_COMPARE_OP_NEVER;

// =============================================================================
// Struct Type Aliases (using C types for ABI compatibility)
// =============================================================================

pub const ApplicationInfo = c.VkApplicationInfo;
pub const InstanceCreateInfo = c.VkInstanceCreateInfo;
pub const DeviceQueueCreateInfo = c.VkDeviceQueueCreateInfo;
pub const DeviceCreateInfo = c.VkDeviceCreateInfo;
pub const WaylandSurfaceCreateInfoKHR = c.VkWaylandSurfaceCreateInfoKHR;
pub const SwapchainCreateInfoKHR = c.VkSwapchainCreateInfoKHR;
pub const ImageViewCreateInfo = c.VkImageViewCreateInfo;
pub const ImageCreateInfo = c.VkImageCreateInfo;
pub const BufferCreateInfo = c.VkBufferCreateInfo;
pub const MemoryAllocateInfo = c.VkMemoryAllocateInfo;
pub const ShaderModuleCreateInfo = c.VkShaderModuleCreateInfo;
pub const PipelineShaderStageCreateInfo = c.VkPipelineShaderStageCreateInfo;
pub const PipelineVertexInputStateCreateInfo = c.VkPipelineVertexInputStateCreateInfo;
pub const PipelineInputAssemblyStateCreateInfo = c.VkPipelineInputAssemblyStateCreateInfo;
pub const PipelineViewportStateCreateInfo = c.VkPipelineViewportStateCreateInfo;
pub const PipelineRasterizationStateCreateInfo = c.VkPipelineRasterizationStateCreateInfo;
pub const PipelineMultisampleStateCreateInfo = c.VkPipelineMultisampleStateCreateInfo;
pub const PipelineColorBlendAttachmentState = c.VkPipelineColorBlendAttachmentState;
pub const PipelineColorBlendStateCreateInfo = c.VkPipelineColorBlendStateCreateInfo;
pub const PipelineDynamicStateCreateInfo = c.VkPipelineDynamicStateCreateInfo;
pub const PipelineLayoutCreateInfo = c.VkPipelineLayoutCreateInfo;
pub const AttachmentDescription = c.VkAttachmentDescription;
pub const AttachmentReference = c.VkAttachmentReference;
pub const SubpassDescription = c.VkSubpassDescription;
pub const SubpassDependency = c.VkSubpassDependency;
pub const RenderPassCreateInfo = c.VkRenderPassCreateInfo;
pub const GraphicsPipelineCreateInfo = c.VkGraphicsPipelineCreateInfo;
pub const FramebufferCreateInfo = c.VkFramebufferCreateInfo;
pub const CommandPoolCreateInfo = c.VkCommandPoolCreateInfo;
pub const CommandBufferAllocateInfo = c.VkCommandBufferAllocateInfo;
pub const CommandBufferBeginInfo = c.VkCommandBufferBeginInfo;
pub const RenderPassBeginInfo = c.VkRenderPassBeginInfo;
pub const SemaphoreCreateInfo = c.VkSemaphoreCreateInfo;
pub const FenceCreateInfo = c.VkFenceCreateInfo;
pub const SubmitInfo = c.VkSubmitInfo;
pub const PresentInfoKHR = c.VkPresentInfoKHR;
pub const DescriptorSetLayoutBinding = c.VkDescriptorSetLayoutBinding;
pub const DescriptorSetLayoutCreateInfo = c.VkDescriptorSetLayoutCreateInfo;
pub const DescriptorPoolSize = c.VkDescriptorPoolSize;
pub const DescriptorPoolCreateInfo = c.VkDescriptorPoolCreateInfo;
pub const DescriptorSetAllocateInfo = c.VkDescriptorSetAllocateInfo;
pub const DescriptorBufferInfo = c.VkDescriptorBufferInfo;
pub const DescriptorImageInfo = c.VkDescriptorImageInfo;
pub const WriteDescriptorSet = c.VkWriteDescriptorSet;
pub const SamplerCreateInfo = c.VkSamplerCreateInfo;
pub const ImageMemoryBarrier = c.VkImageMemoryBarrier;
pub const BufferImageCopy = c.VkBufferImageCopy;

pub const Extent2D = c.VkExtent2D;
pub const Extent3D = c.VkExtent3D;
pub const Offset2D = c.VkOffset2D;
pub const Offset3D = c.VkOffset3D;
pub const Rect2D = c.VkRect2D;
pub const Viewport = c.VkViewport;
pub const ClearValue = c.VkClearValue;
pub const ClearColorValue = c.VkClearColorValue;
pub const ComponentMapping = c.VkComponentMapping;
pub const ImageSubresourceRange = c.VkImageSubresourceRange;
pub const ImageSubresourceLayers = c.VkImageSubresourceLayers;
pub const MemoryRequirements = c.VkMemoryRequirements;
pub const QueueFamilyProperties = c.VkQueueFamilyProperties;
pub const SurfaceCapabilitiesKHR = c.VkSurfaceCapabilitiesKHR;
pub const SurfaceFormatKHR = c.VkSurfaceFormatKHR;
pub const PhysicalDeviceProperties = c.VkPhysicalDeviceProperties;
pub const PhysicalDeviceMemoryProperties = c.VkPhysicalDeviceMemoryProperties;
pub const PhysicalDeviceFeatures = c.VkPhysicalDeviceFeatures;
pub const VertexInputBindingDescription = c.VkVertexInputBindingDescription;
pub const VertexInputAttributeDescription = c.VkVertexInputAttributeDescription;

// =============================================================================
// Vulkan Functions - Instance
// =============================================================================

pub const vkCreateInstance = c.vkCreateInstance;
pub const vkDestroyInstance = c.vkDestroyInstance;
pub const vkEnumeratePhysicalDevices = c.vkEnumeratePhysicalDevices;
pub const vkGetPhysicalDeviceProperties = c.vkGetPhysicalDeviceProperties;
pub const vkGetPhysicalDeviceFeatures = c.vkGetPhysicalDeviceFeatures;
pub const vkGetPhysicalDeviceMemoryProperties = c.vkGetPhysicalDeviceMemoryProperties;
pub const vkGetPhysicalDeviceQueueFamilyProperties = c.vkGetPhysicalDeviceQueueFamilyProperties;

// =============================================================================
// Vulkan Functions - Device
// =============================================================================

pub const vkCreateDevice = c.vkCreateDevice;
pub const vkDestroyDevice = c.vkDestroyDevice;
pub const vkGetDeviceQueue = c.vkGetDeviceQueue;
pub const vkDeviceWaitIdle = c.vkDeviceWaitIdle;

// =============================================================================
// Vulkan Functions - Surface/Swapchain (KHR extensions)
// =============================================================================

pub const vkCreateWaylandSurfaceKHR = c.vkCreateWaylandSurfaceKHR;
pub const vkDestroySurfaceKHR = c.vkDestroySurfaceKHR;
pub const vkGetPhysicalDeviceSurfaceSupportKHR = c.vkGetPhysicalDeviceSurfaceSupportKHR;
pub const vkGetPhysicalDeviceSurfaceCapabilitiesKHR = c.vkGetPhysicalDeviceSurfaceCapabilitiesKHR;
pub const vkGetPhysicalDeviceSurfaceFormatsKHR = c.vkGetPhysicalDeviceSurfaceFormatsKHR;
pub const vkGetPhysicalDeviceSurfacePresentModesKHR = c.vkGetPhysicalDeviceSurfacePresentModesKHR;

pub const vkCreateSwapchainKHR = c.vkCreateSwapchainKHR;
pub const vkDestroySwapchainKHR = c.vkDestroySwapchainKHR;
pub const vkGetSwapchainImagesKHR = c.vkGetSwapchainImagesKHR;
pub const vkAcquireNextImageKHR = c.vkAcquireNextImageKHR;
pub const vkQueuePresentKHR = c.vkQueuePresentKHR;

// =============================================================================
// Vulkan Functions - Image/Buffer
// =============================================================================

pub const vkCreateImage = c.vkCreateImage;
pub const vkDestroyImage = c.vkDestroyImage;
pub const vkCreateImageView = c.vkCreateImageView;
pub const vkDestroyImageView = c.vkDestroyImageView;
pub const vkGetImageMemoryRequirements = c.vkGetImageMemoryRequirements;
pub const vkBindImageMemory = c.vkBindImageMemory;

pub const vkCreateBuffer = c.vkCreateBuffer;
pub const vkDestroyBuffer = c.vkDestroyBuffer;
pub const vkGetBufferMemoryRequirements = c.vkGetBufferMemoryRequirements;
pub const vkBindBufferMemory = c.vkBindBufferMemory;

// =============================================================================
// Vulkan Functions - Memory
// =============================================================================

pub const vkAllocateMemory = c.vkAllocateMemory;
pub const vkFreeMemory = c.vkFreeMemory;
pub const vkMapMemory = c.vkMapMemory;
pub const vkUnmapMemory = c.vkUnmapMemory;
pub const vkFlushMappedMemoryRanges = c.vkFlushMappedMemoryRanges;

// =============================================================================
// Vulkan Functions - Pipeline
// =============================================================================

pub const vkCreateShaderModule = c.vkCreateShaderModule;
pub const vkDestroyShaderModule = c.vkDestroyShaderModule;
pub const vkCreatePipelineLayout = c.vkCreatePipelineLayout;
pub const vkDestroyPipelineLayout = c.vkDestroyPipelineLayout;
pub const vkCreateRenderPass = c.vkCreateRenderPass;
pub const vkDestroyRenderPass = c.vkDestroyRenderPass;
pub const vkCreateGraphicsPipelines = c.vkCreateGraphicsPipelines;
pub const vkDestroyPipeline = c.vkDestroyPipeline;

// =============================================================================
// Vulkan Functions - Framebuffer
// =============================================================================

pub const vkCreateFramebuffer = c.vkCreateFramebuffer;
pub const vkDestroyFramebuffer = c.vkDestroyFramebuffer;

// =============================================================================
// Vulkan Functions - Command Buffer
// =============================================================================

pub const vkCreateCommandPool = c.vkCreateCommandPool;
pub const vkDestroyCommandPool = c.vkDestroyCommandPool;
pub const vkAllocateCommandBuffers = c.vkAllocateCommandBuffers;
pub const vkFreeCommandBuffers = c.vkFreeCommandBuffers;
pub const vkResetCommandBuffer = c.vkResetCommandBuffer;

pub const vkBeginCommandBuffer = c.vkBeginCommandBuffer;
pub const vkEndCommandBuffer = c.vkEndCommandBuffer;
pub const vkCmdBeginRenderPass = c.vkCmdBeginRenderPass;
pub const vkCmdEndRenderPass = c.vkCmdEndRenderPass;
pub const vkCmdBindPipeline = c.vkCmdBindPipeline;
pub const vkCmdSetViewport = c.vkCmdSetViewport;
pub const vkCmdSetScissor = c.vkCmdSetScissor;
pub const vkCmdDraw = c.vkCmdDraw;
pub const vkCmdDrawIndexed = c.vkCmdDrawIndexed;
pub const vkCmdBindVertexBuffers = c.vkCmdBindVertexBuffers;
pub const vkCmdBindIndexBuffer = c.vkCmdBindIndexBuffer;
pub const vkCmdBindDescriptorSets = c.vkCmdBindDescriptorSets;
pub const vkCmdCopyBufferToImage = c.vkCmdCopyBufferToImage;
pub const vkCmdPipelineBarrier = c.vkCmdPipelineBarrier;

// =============================================================================
// Vulkan Functions - Synchronization
// =============================================================================

pub const vkCreateSemaphore = c.vkCreateSemaphore;
pub const vkDestroySemaphore = c.vkDestroySemaphore;
pub const vkCreateFence = c.vkCreateFence;
pub const vkDestroyFence = c.vkDestroyFence;
pub const vkWaitForFences = c.vkWaitForFences;
pub const vkResetFences = c.vkResetFences;
pub const vkQueueSubmit = c.vkQueueSubmit;
pub const vkQueueWaitIdle = c.vkQueueWaitIdle;

// =============================================================================
// Vulkan Functions - Descriptor
// =============================================================================

pub const vkCreateDescriptorSetLayout = c.vkCreateDescriptorSetLayout;
pub const vkDestroyDescriptorSetLayout = c.vkDestroyDescriptorSetLayout;
pub const vkCreateDescriptorPool = c.vkCreateDescriptorPool;
pub const vkDestroyDescriptorPool = c.vkDestroyDescriptorPool;
pub const vkAllocateDescriptorSets = c.vkAllocateDescriptorSets;
pub const vkUpdateDescriptorSets = c.vkUpdateDescriptorSets;

// =============================================================================
// Vulkan Functions - Sampler
// =============================================================================

pub const vkCreateSampler = c.vkCreateSampler;
pub const vkDestroySampler = c.vkDestroySampler;

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
        const props_match = (mem_properties.memoryTypes[i].propertyFlags & required_properties) == required_properties;
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
