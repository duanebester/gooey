//! Vulkan graphics pipeline creation.
//!
//! Replaces four copy-pasted pipeline creation functions (createUnifiedPipeline,
//! createTextPipeline, createSvgPipeline, createImagePipeline) with a single
//! generic helper parameterized by shader SPV, descriptor layout, and blend mode.
//!
//! Axes of variation across the four original functions:
//!   1. Shader SPIR-V bytecode (vert + frag)
//!   2. Descriptor set layout
//!   3. Blend mode — only SVG uses premultiplied; the rest use standard SRC_ALPHA
//!
//! Everything else (vertex input, topology, rasterizer, dynamic state) is identical.

const std = @import("std");
const vk = @import("vulkan.zig");

// =============================================================================
// Public Types
// =============================================================================

pub const BlendMode = enum {
    /// srcAlpha / oneMinusSrcAlpha — used by unified, text, and image pipelines.
    standard,
    /// one / oneMinusSrcAlpha — used by SVG pipeline (shader outputs pre-multiplied RGB).
    premultiplied,
};

pub const PipelineConfig = struct {
    vert_spv: []align(4) const u8,
    frag_spv: []align(4) const u8,
    descriptor_layout: vk.DescriptorSetLayout,
    blend_mode: BlendMode = .standard,
};

pub const PipelineResult = struct {
    pipeline: vk.Pipeline,
    layout: vk.PipelineLayout,
};

pub const PipelineError = error{
    ShaderModuleCreationFailed,
    PipelineLayoutCreationFailed,
    PipelineCreationFailed,
};

// =============================================================================
// Public API
// =============================================================================

/// Create a complete graphics pipeline and its layout from a config.
///
/// One call replaces what was previously four 160-line copy-pasted functions.
/// Caller owns both returned handles and must destroy them (via `destroyPipeline`
/// or individually) when no longer needed.
pub fn createGraphicsPipeline(
    device: vk.Device,
    render_pass: vk.RenderPass,
    sample_count: c_uint,
    config: PipelineConfig,
) PipelineError!PipelineResult {
    std.debug.assert(device != null);
    std.debug.assert(render_pass != null);
    std.debug.assert(config.vert_spv.len > 0);
    std.debug.assert(config.frag_spv.len > 0);

    // Create transient shader modules — destroyed after pipeline creation
    const vert_module = try createShaderModule(device, config.vert_spv);
    defer vk.vkDestroyShaderModule(device, vert_module, null);
    const frag_module = try createShaderModule(device, config.frag_spv);
    defer vk.vkDestroyShaderModule(device, frag_module, null);

    // Assemble fixed-function state
    const stages = shaderStages(vert_module, frag_module);
    const vertex_input = vertexInputState();
    const input_assembly = inputAssemblyState();
    const viewport = viewportState();
    const rasterizer = rasterizationState();
    const multisampling = multisampleState(sample_count);
    const blend_attachment = blendAttachment(config.blend_mode);
    const color_blending = colorBlendState(&blend_attachment);
    const dynamic_states = [_]c_uint{ vk.VK_DYNAMIC_STATE_VIEWPORT, vk.VK_DYNAMIC_STATE_SCISSOR };
    const dynamic_state = dynamicState(&dynamic_states);

    // Create pipeline layout (owns the handle on success)
    const layout = try createPipelineLayout(device, config.descriptor_layout);
    errdefer vk.vkDestroyPipelineLayout(device, layout, null);

    // Create the pipeline itself
    const pipeline = try createPipeline(
        device,
        render_pass,
        layout,
        &stages,
        &vertex_input,
        &input_assembly,
        &viewport,
        &rasterizer,
        &multisampling,
        &color_blending,
        &dynamic_state,
    );

    return .{ .pipeline = pipeline, .layout = layout };
}

/// Destroy a pipeline and its associated layout. Safe to call with null handles.
pub fn destroyPipeline(device: vk.Device, pipeline: vk.Pipeline, layout: vk.PipelineLayout) void {
    std.debug.assert(device != null);
    if (pipeline) |p| vk.vkDestroyPipeline(device, p, null);
    if (layout) |l| vk.vkDestroyPipelineLayout(device, l, null);
}

// =============================================================================
// Internal Helpers — Vulkan object creation
// =============================================================================

fn createShaderModule(device: vk.Device, code: []align(4) const u8) PipelineError!vk.ShaderModule {
    std.debug.assert(device != null);
    std.debug.assert(code.len >= 4); // SPIR-V minimum: magic number is 4 bytes

    const create_info = vk.ShaderModuleCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .codeSize = code.len,
        .pCode = @ptrCast(code.ptr),
    };

    var module: vk.ShaderModule = null;
    const result = vk.vkCreateShaderModule(device, &create_info, null, &module);
    if (!vk.succeeded(result)) return PipelineError.ShaderModuleCreationFailed;

    std.debug.assert(module != null);
    return module;
}

fn createPipelineLayout(device: vk.Device, descriptor_layout: vk.DescriptorSetLayout) PipelineError!vk.PipelineLayout {
    std.debug.assert(device != null);
    std.debug.assert(descriptor_layout != null);

    const layouts = [_]vk.DescriptorSetLayout{descriptor_layout};
    const layout_info = vk.PipelineLayoutCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .setLayoutCount = 1,
        .pSetLayouts = &layouts,
        .pushConstantRangeCount = 0,
        .pPushConstantRanges = null,
    };

    var layout: vk.PipelineLayout = null;
    const result = vk.vkCreatePipelineLayout(device, &layout_info, null, &layout);
    if (!vk.succeeded(result)) return PipelineError.PipelineLayoutCreationFailed;

    std.debug.assert(layout != null);
    return layout;
}

fn createPipeline(
    device: vk.Device,
    render_pass: vk.RenderPass,
    layout: vk.PipelineLayout,
    stages: *const [2]vk.PipelineShaderStageCreateInfo,
    vertex_input: *const vk.PipelineVertexInputStateCreateInfo,
    input_assembly: *const vk.PipelineInputAssemblyStateCreateInfo,
    viewport: *const vk.PipelineViewportStateCreateInfo,
    rasterizer: *const vk.PipelineRasterizationStateCreateInfo,
    multisampling: *const vk.PipelineMultisampleStateCreateInfo,
    color_blending: *const vk.PipelineColorBlendStateCreateInfo,
    dynamic_state: *const vk.PipelineDynamicStateCreateInfo,
) PipelineError!vk.Pipeline {
    std.debug.assert(device != null);
    std.debug.assert(layout != null);

    const pipeline_info = vk.GraphicsPipelineCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .stageCount = stages.len,
        .pStages = stages,
        .pVertexInputState = vertex_input,
        .pInputAssemblyState = input_assembly,
        .pTessellationState = null,
        .pViewportState = viewport,
        .pRasterizationState = rasterizer,
        .pMultisampleState = multisampling,
        .pDepthStencilState = null,
        .pColorBlendState = color_blending,
        .pDynamicState = dynamic_state,
        .layout = layout,
        .renderPass = render_pass,
        .subpass = 0,
        .basePipelineHandle = null,
        .basePipelineIndex = -1,
    };

    var pipeline: vk.Pipeline = null;
    const result = vk.vkCreateGraphicsPipelines(device, null, 1, &pipeline_info, null, &pipeline);
    if (!vk.succeeded(result)) return PipelineError.PipelineCreationFailed;

    std.debug.assert(pipeline != null);
    return pipeline;
}

// =============================================================================
// Internal Helpers — Fixed-function state builders
// =============================================================================

fn shaderStages(
    vert_module: vk.ShaderModule,
    frag_module: vk.ShaderModule,
) [2]vk.PipelineShaderStageCreateInfo {
    std.debug.assert(vert_module != null);
    std.debug.assert(frag_module != null);

    return .{
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
}

fn vertexInputState() vk.PipelineVertexInputStateCreateInfo {
    // No vertex input — all geometry is generated in the vertex shader
    return .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .vertexBindingDescriptionCount = 0,
        .pVertexBindingDescriptions = null,
        .vertexAttributeDescriptionCount = 0,
        .pVertexAttributeDescriptions = null,
    };
}

fn inputAssemblyState() vk.PipelineInputAssemblyStateCreateInfo {
    return .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .topology = vk.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
        .primitiveRestartEnable = vk.FALSE,
    };
}

fn viewportState() vk.PipelineViewportStateCreateInfo {
    // Viewport and scissor are dynamic state — no static values needed
    return .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .viewportCount = 1,
        .pViewports = null,
        .scissorCount = 1,
        .pScissors = null,
    };
}

fn rasterizationState() vk.PipelineRasterizationStateCreateInfo {
    return .{
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
}

fn multisampleState(sample_count: c_uint) vk.PipelineMultisampleStateCreateInfo {
    return .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .rasterizationSamples = sample_count,
        .sampleShadingEnable = vk.FALSE,
        .minSampleShading = 1.0,
        .pSampleMask = null,
        .alphaToCoverageEnable = vk.FALSE,
        .alphaToOneEnable = vk.FALSE,
    };
}

/// Returns the blend attachment state for the given mode.
///
/// The only difference between modes is srcColorBlendFactor:
///   standard:      SRC_ALPHA (straight alpha from shader)
///   premultiplied: ONE       (shader pre-multiplies RGB by alpha)
///
/// All other blend factors, ops, and write mask are identical.
fn blendAttachment(mode: BlendMode) vk.PipelineColorBlendAttachmentState {
    const src_color_factor: c_uint = switch (mode) {
        .standard => vk.VK_BLEND_FACTOR_SRC_ALPHA,
        .premultiplied => vk.VK_BLEND_FACTOR_ONE,
    };

    return .{
        .blendEnable = vk.TRUE,
        .srcColorBlendFactor = src_color_factor,
        .dstColorBlendFactor = vk.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
        .colorBlendOp = vk.VK_BLEND_OP_ADD,
        .srcAlphaBlendFactor = vk.VK_BLEND_FACTOR_ONE,
        .dstAlphaBlendFactor = vk.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
        .alphaBlendOp = vk.VK_BLEND_OP_ADD,
        .colorWriteMask = vk.VK_COLOR_COMPONENT_ALL,
    };
}

/// Wraps a blend attachment pointer into the color blend state create info.
/// The caller must ensure `attachment` outlives the returned struct.
fn colorBlendState(
    attachment: *const vk.PipelineColorBlendAttachmentState,
) vk.PipelineColorBlendStateCreateInfo {
    return .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .logicOpEnable = vk.FALSE,
        .logicOp = 0,
        .attachmentCount = 1,
        .pAttachments = attachment,
        .blendConstants = .{ 0, 0, 0, 0 },
    };
}

/// Wraps a dynamic state array pointer into the dynamic state create info.
/// The caller must ensure `states` outlives the returned struct.
fn dynamicState(states: *const [2]c_uint) vk.PipelineDynamicStateCreateInfo {
    return .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .dynamicStateCount = states.len,
        .pDynamicStates = states,
    };
}
