const std = @import("std");
const vk = @import("vulkan.zig");

pub const BlendMode = enum {
    standard,
    premultiplied,
};

pub const PipelineConfig = struct {
    vert_spv: []align(4) const u8,
    frag_spv: []align(4) const u8,
    pipeline_layout: vk.PipelineLayout,
    blend_mode: BlendMode = .standard,
};

pub const PipelineError = error{
    ShaderModuleCreationFailed,
    PipelineLayoutCreationFailed,
    PipelineCacheCreationFailed,
    PipelineCreationFailed,
};

pub fn createPipelineLayout(device: vk.Device, descriptor_layout: vk.DescriptorSetLayout) PipelineError!vk.PipelineLayout {
    std.debug.assert(device != null);
    std.debug.assert(descriptor_layout != null);

    const layouts = [_]vk.DescriptorSetLayout{descriptor_layout};
    const push_constants = vk.PushConstantRange{
        .stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT,
        .offset = 0,
        .size = @sizeOf(@import("vk_types.zig").PushConstants),
    };
    const layout_info = vk.PipelineLayoutCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .setLayoutCount = 1,
        .pSetLayouts = &layouts,
        .pushConstantRangeCount = 1,
        .pPushConstantRanges = (&push_constants)[0..1],
    };

    var layout: vk.PipelineLayout = null;
    const result = vk.vkCreatePipelineLayout(device, &layout_info, null, &layout);
    if (!vk.succeeded(result)) return PipelineError.PipelineLayoutCreationFailed;

    std.debug.assert(layout != null);
    return layout;
}

pub fn createPipelineCache(
    device: vk.Device,
    initial_data: ?[]const u8,
) PipelineError!vk.PipelineCache {
    std.debug.assert(device != null);

    const create_info = vk.PipelineCacheCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_CACHE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .initialDataSize = if (initial_data) |d| d.len else 0,
        .pInitialData = if (initial_data) |d| d.ptr else null,
    };

    var cache: vk.PipelineCache = null;
    const result = vk.vkCreatePipelineCache(device, &create_info, null, &cache);
    if (!vk.succeeded(result)) return PipelineError.PipelineCacheCreationFailed;

    std.debug.assert(cache != null);
    return cache;
}

pub fn createGraphicsPipeline(
    device: vk.Device,
    render_pass: vk.RenderPass,
    config: PipelineConfig,
    pipeline_cache: vk.PipelineCache,
) PipelineError!vk.Pipeline {
    std.debug.assert(device != null);
    std.debug.assert(render_pass != null);
    std.debug.assert(config.pipeline_layout != null);
    std.debug.assert(config.vert_spv.len > 0);
    std.debug.assert(config.frag_spv.len > 0);

    const vert_module = try createShaderModule(device, config.vert_spv);
    defer vk.vkDestroyShaderModule(device, vert_module, null);
    const frag_module = try createShaderModule(device, config.frag_spv);
    defer vk.vkDestroyShaderModule(device, frag_module, null);

    const stages = shaderStages(vert_module, frag_module);
    const vertex_input = vertexInputState();
    const input_assembly = inputAssemblyState();
    const viewport = viewportState();
    const rasterizer = rasterizationState();
    const multisampling = multisampleState();
    const blend_attachment = blendAttachment(config.blend_mode);
    const color_blending = colorBlendState(&blend_attachment);
    const dynamic_states = [_]vk.DynamicState{
        vk.VK_DYNAMIC_STATE_VIEWPORT,
        vk.VK_DYNAMIC_STATE_SCISSOR,
    };
    const dynamic_state = dynamicState(&dynamic_states);

    const pipeline = try createPipeline(
        device,
        render_pass,
        config.pipeline_layout,
        pipeline_cache,
        &stages,
        &vertex_input,
        &input_assembly,
        &viewport,
        &rasterizer,
        &multisampling,
        &color_blending,
        &dynamic_state,
    );

    return pipeline;
}

pub fn destroyPipeline(device: vk.Device, pipeline: vk.Pipeline) void {
    std.debug.assert(device != null);
    if (pipeline) |p| vk.vkDestroyPipeline(device, p, null);
}

fn createShaderModule(device: vk.Device, code: []align(4) const u8) PipelineError!vk.ShaderModule {
    std.debug.assert(device != null);
    std.debug.assert(code.len >= 4);

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

fn createPipeline(
    device: vk.Device,
    render_pass: vk.RenderPass,
    layout: vk.PipelineLayout,
    pipeline_cache: vk.PipelineCache,
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
    const result = vk.vkCreateGraphicsPipelines(
        device,
        pipeline_cache,
        1,
        (&pipeline_info)[0..1],
        null,
        (&pipeline)[0..1],
    );
    if (!vk.succeeded(result)) return PipelineError.PipelineCreationFailed;

    std.debug.assert(pipeline != null);
    return pipeline;
}

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

fn multisampleState() vk.PipelineMultisampleStateCreateInfo {
    return .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .rasterizationSamples = vk.VK_SAMPLE_COUNT_1_BIT,
        .sampleShadingEnable = vk.FALSE,
        .minSampleShading = 1.0,
        .pSampleMask = null,
        .alphaToCoverageEnable = vk.FALSE,
        .alphaToOneEnable = vk.FALSE,
    };
}

fn blendAttachment(mode: BlendMode) vk.PipelineColorBlendAttachmentState {
    const src_color_factor: vk.BlendFactor = switch (mode) {
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
        .pAttachments = attachment[0..1],
        .blendConstants = .{ 0, 0, 0, 0 },
    };
}

fn dynamicState(states: *const [2]vk.DynamicState) vk.PipelineDynamicStateCreateInfo {
    return .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .dynamicStateCount = states.len,
        .pDynamicStates = states,
    };
}
