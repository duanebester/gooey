//! Post-Process Rendering - Custom shader post-processing support
//!
//! PERFORMANCE: Uses a single command buffer for the entire pipeline.
//! Metal automatically handles synchronization between render passes
//! within the same command buffer - no CPU waits needed.

const std = @import("std");
const objc = @import("objc");
const mtl = @import("api.zig");
const render_pass = @import("render_pass.zig");
const scene_renderer = @import("scene_renderer.zig");
const scene_mod = @import("../../../core/scene.zig");
const geometry = @import("../../../core/geometry.zig");
const custom_shader = @import("custom_shader.zig");
const text_pipeline = @import("text.zig");
const svg_pipeline = @import("svg_pipeline.zig");

/// Render the complete post-process pipeline in a single command buffer.
/// This is the main entry point - replaces the old multi-buffer approach.
pub fn renderFullPipeline(
    command_queue: objc.Object,
    layer: objc.Object,
    scene: *const scene_mod.Scene,
    clear_color: geometry.Color,
    msaa_texture: objc.Object,
    unit_vertex_buffer: objc.Object,
    unified_pipeline: ?objc.Object,
    tp: ?*text_pipeline.TextPipeline,
    sp: ?*svg_pipeline.SvgPipeline,
    pp: *custom_shader.PostProcessState,
    size: geometry.Size(f64),
    scale_factor: f64,
) !void {
    // Get drawable FIRST - this is the presentation target
    const drawable_info = render_pass.getNextDrawable(layer) orelse return;

    // Single command buffer for entire pipeline
    const command_buffer = command_queue.msgSend(objc.Object, "commandBuffer", .{});

    // === Pass 1: Render scene to front_texture (with MSAA resolve) ===
    {
        const rp = render_pass.createRenderPass(.{
            .msaa_texture = msaa_texture,
            .resolve_texture = pp.front_texture.?,
            .clear_color = clear_color,
        }) orelse return;

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

        if (sp) |svg_pipe| {
            const svg_instances = scene.getSvgInstances();
            if (svg_instances.len > 0) {
                svg_pipe.render(encoder, svg_instances, viewport_size);
            }
        }

        if (tp) |text_pipe| {
            scene_renderer.drawText(text_pipe, encoder, scene, viewport_size);
        }

        encoder.msgSend(void, "endEncoding", .{});
        // Don't commit yet - continue with same command buffer
    }

    // === Pass 2+: Post-process shader passes ===
    for (pp.pipelines.items) |shader_pipeline| {
        const rp = render_pass.createSimpleRenderPass(.{
            .texture = pp.back_texture.?,
        }) orelse continue;

        const encoder = render_pass.createEncoder(command_buffer, rp) orelse continue;
        render_pass.setViewport(encoder, size.width, size.height, scale_factor);

        encoder.msgSend(void, "setRenderPipelineState:", .{shader_pipeline.pipeline_state.value});
        encoder.msgSend(void, "setFragmentBuffer:offset:atIndex:", .{
            pp.uniform_buffer.?.value,
            @as(c_ulong, 0),
            @as(c_ulong, 0),
        });
        encoder.msgSend(void, "setFragmentTexture:atIndex:", .{
            pp.front_texture.?.value,
            @as(c_ulong, 0),
        });
        encoder.msgSend(void, "setFragmentSamplerState:atIndex:", .{
            pp.sampler.?.value,
            @as(c_ulong, 0),
        });

        encoder.msgSend(void, "drawPrimitives:vertexStart:vertexCount:", .{
            @intFromEnum(mtl.MTLPrimitiveType.triangle),
            @as(c_ulong, 0),
            @as(c_ulong, 3),
        });

        encoder.msgSend(void, "endEncoding", .{});

        // Swap textures for next pass
        pp.swapTextures();
    }

    // === Final Pass: Blit to screen ===
    {
        const blit_encoder_ptr = command_buffer.msgSend(?*anyopaque, "blitCommandEncoder", .{});
        if (blit_encoder_ptr) |ptr| {
            const blit_encoder = objc.Object.fromId(ptr);

            const width: u32 = @intFromFloat(size.width * scale_factor);
            const height: u32 = @intFromFloat(size.height * scale_factor);

            blit_encoder.msgSend(void, "copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:", .{
                pp.front_texture.?.value,
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
        }
    }

    // === Present and commit (NO WAIT!) ===
    command_buffer.msgSend(void, "presentDrawable:", .{drawable_info.drawable.value});
    command_buffer.msgSend(void, "commit", .{});
}
