//! Post-Process Rendering - Custom shader post-processing support

const std = @import("std");
const objc = @import("objc");
const mtl = @import("api.zig");
const render_pass = @import("render_pass.zig");
const scene_renderer = @import("scene_renderer.zig");
const scene_mod = @import("../../../core/scene.zig");
const geometry = @import("../../../core/geometry.zig");
const custom_shader = @import("custom_shader.zig");
const text_pipeline = @import("text.zig");

/// Render scene to an off-screen texture for post-processing
pub fn renderSceneToTexture(
    command_queue: objc.Object,
    scene: *const scene_mod.Scene,
    clear_color: geometry.Color,
    target_texture: objc.Object,
    msaa_texture: objc.Object,
    unit_vertex_buffer: objc.Object,
    unified_pipeline: ?objc.Object,
    tp: ?*text_pipeline.TextPipeline,
    size: geometry.Size(f64),
    scale_factor: f64,
) !void {
    const rp = render_pass.createRenderPass(.{
        .msaa_texture = msaa_texture,
        .resolve_texture = target_texture,
        .clear_color = clear_color,
    }) orelse return;

    const command_buffer = command_queue.msgSend(objc.Object, "commandBuffer", .{});
    const encoder = render_pass.createEncoder(command_buffer, rp) orelse return;

    render_pass.setViewport(encoder, size.width, size.height, scale_factor);

    const viewport_size: [2]f32 = .{
        @floatCast(size.width),
        @floatCast(size.height),
    };

    scene_renderer.drawScenePrimitives(
        encoder,
        scene,
        unit_vertex_buffer,
        viewport_size,
        unified_pipeline,
    );

    if (tp) |text_pipe| {
        scene_renderer.drawText(text_pipe, encoder, scene, viewport_size);
    }

    render_pass.finishAndWait(encoder, command_buffer);
}

/// Run a single post-process shader pass
pub fn runPostProcessPass(
    command_queue: objc.Object,
    pipeline: custom_shader.CustomShaderPipeline,
    input_texture: objc.Object,
    output_texture: objc.Object,
    uniform_buffer: objc.Object,
    sampler_state: objc.Object,
    size: geometry.Size(f64),
    scale_factor: f64,
) !void {
    const rp = render_pass.createSimpleRenderPass(.{
        .texture = output_texture,
    }) orelse return;

    const command_buffer = command_queue.msgSend(objc.Object, "commandBuffer", .{});
    const encoder = render_pass.createEncoder(command_buffer, rp) orelse return;

    render_pass.setViewport(encoder, size.width, size.height, scale_factor);

    encoder.msgSend(void, "setRenderPipelineState:", .{pipeline.pipeline_state.value});
    encoder.msgSend(void, "setFragmentBuffer:offset:atIndex:", .{
        uniform_buffer.value,
        @as(c_ulong, 0),
        @as(c_ulong, 0),
    });
    encoder.msgSend(void, "setFragmentTexture:atIndex:", .{
        input_texture.value,
        @as(c_ulong, 0),
    });
    encoder.msgSend(void, "setFragmentSamplerState:atIndex:", .{
        sampler_state.value,
        @as(c_ulong, 0),
    });

    encoder.msgSend(void, "drawPrimitives:vertexStart:vertexCount:", .{
        @intFromEnum(mtl.MTLPrimitiveType.triangle),
        @as(c_ulong, 0),
        @as(c_ulong, 3),
    });

    render_pass.finishAndWait(encoder, command_buffer);
}

/// Blit texture to screen drawable
pub fn blitToScreen(
    command_queue: objc.Object,
    layer: objc.Object,
    source_texture: objc.Object,
    size: geometry.Size(f64),
    scale_factor: f64,
) !void {
    const drawable_info = render_pass.getNextDrawable(layer) orelse return;
    const command_buffer = command_queue.msgSend(objc.Object, "commandBuffer", .{});
    const blit_encoder_ptr = command_buffer.msgSend(?*anyopaque, "blitCommandEncoder", .{});
    if (blit_encoder_ptr == null) return;
    const blit_encoder = objc.Object.fromId(blit_encoder_ptr);

    const width: u32 = @intFromFloat(size.width * scale_factor);
    const height: u32 = @intFromFloat(size.height * scale_factor);

    blit_encoder.msgSend(void, "copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:", .{
        source_texture.value,
        @as(c_ulong, 0),
        @as(c_ulong, 0),
        mtl.MTLOrigin{ .x = 0, .y = 0, .z = 0 },
        mtl.MTLSize{ .width = width, .height = height, .depth = 1 },
        drawable_info.texture.value,
        @as(c_ulong, 0),
        @as(c_ulong, 0),
        mtl.MTLOrigin{ .x = 0, .y = 0, .z = 0 },
    });

    blit_encoder.msgSend(void, "endEncoding", .{});
    command_buffer.msgSend(void, "presentDrawable:", .{drawable_info.drawable.value});
    command_buffer.msgSend(void, "commit", .{});
}
