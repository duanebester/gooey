//! Scene Renderer - Handles drawing shadows, quads, and text in correct order
//!
//! This module contains the core batched rendering logic for scenes,
//! supporting both async and synchronous (live resize) rendering paths.

const std = @import("std");
const objc = @import("objc");
const mtl = @import("api.zig");
const render_pass = @import("render_pass.zig");
const scene_mod = @import("../../../core/scene.zig");
const text_pipeline = @import("text.zig");
const render_stats = @import("../../../core/render_stats.zig");

/// Draw shadows and quads interleaved by order, batched for performance
pub fn drawScenePrimitives(
    encoder: objc.Object,
    scene: *const scene_mod.Scene,
    unit_vertex_buffer: objc.Object,
    viewport_size: [2]f32,
    shadow_pipeline: ?objc.Object,
    quad_pipeline: ?objc.Object,
) void {
    drawScenePrimitivesWithStats(
        encoder,
        scene,
        unit_vertex_buffer,
        viewport_size,
        shadow_pipeline,
        quad_pipeline,
        null,
    );
}

/// Draw with optional stats recording
pub fn drawScenePrimitivesWithStats(
    encoder: objc.Object,
    scene: *const scene_mod.Scene,
    unit_vertex_buffer: objc.Object,
    viewport_size: [2]f32,
    shadow_pipeline: ?objc.Object,
    quad_pipeline: ?objc.Object,
    stats: ?*render_stats.RenderStats,
) void {
    const shadows = scene.getShadows();
    const quads = scene.getQuads();

    var shadow_idx: usize = 0;
    var quad_idx: usize = 0;
    var last_was_shadow: ?bool = null;

    while (shadow_idx < shadows.len or quad_idx < quads.len) {
        const draw_shadow = if (shadow_idx < shadows.len) blk: {
            if (quad_idx >= quads.len) break :blk true;
            break :blk shadows[shadow_idx].order < quads[quad_idx].order;
        } else false;

        if (draw_shadow) {
            const batch_end = findShadowBatchEnd(shadows, quads, shadow_idx, quad_idx);
            const batch_count = batch_end - shadow_idx;

            if (shadow_pipeline) |pipeline| {
                // Record pipeline switch if we switched from quads
                if (stats) |s| {
                    if (last_was_shadow != null and last_was_shadow.? == false) {
                        s.recordPipelineSwitch();
                    }
                }
                drawShadowBatch(encoder, pipeline, unit_vertex_buffer, shadows, shadow_idx, batch_count, viewport_size);
                if (stats) |s| {
                    s.recordDrawCall();
                    s.recordShadows(@intCast(batch_count));
                }
            }
            shadow_idx = batch_end;
            last_was_shadow = true;
        } else {
            const batch_end = findQuadBatchEnd(shadows, quads, shadow_idx, quad_idx);
            const batch_count = batch_end - quad_idx;

            if (quad_pipeline) |pipeline| {
                // Record pipeline switch if we switched from shadows
                if (stats) |s| {
                    if (last_was_shadow != null and last_was_shadow.? == true) {
                        s.recordPipelineSwitch();
                    }
                }
                drawQuadBatch(encoder, pipeline, unit_vertex_buffer, quads, quad_idx, batch_count, viewport_size);
                if (stats) |s| {
                    s.recordDrawCall();
                    s.recordQuads(@intCast(batch_count));
                }
            }
            quad_idx = batch_end;
            last_was_shadow = false;
        }
    }
}

fn findShadowBatchEnd(
    shadows: []const scene_mod.Shadow,
    quads: []const scene_mod.Quad,
    shadow_idx: usize,
    quad_idx: usize,
) usize {
    var batch_end = shadow_idx + 1;
    while (batch_end < shadows.len) : (batch_end += 1) {
        if (quad_idx < quads.len and quads[quad_idx].order < shadows[batch_end].order) {
            break;
        }
    }
    return batch_end;
}

fn findQuadBatchEnd(
    shadows: []const scene_mod.Shadow,
    quads: []const scene_mod.Quad,
    shadow_idx: usize,
    quad_idx: usize,
) usize {
    var batch_end = quad_idx + 1;
    while (batch_end < quads.len) : (batch_end += 1) {
        if (shadow_idx < shadows.len and shadows[shadow_idx].order < quads[batch_end].order) {
            break;
        }
    }
    return batch_end;
}

fn drawShadowBatch(
    encoder: objc.Object,
    pipeline: objc.Object,
    unit_vertex_buffer: objc.Object,
    shadows: []const scene_mod.Shadow,
    start_idx: usize,
    count: usize,
    viewport_size: [2]f32,
) void {
    encoder.msgSend(void, "setRenderPipelineState:", .{pipeline.value});

    encoder.msgSend(void, "setVertexBuffer:offset:atIndex:", .{
        unit_vertex_buffer.value,
        @as(c_ulong, 0),
        @as(c_ulong, 0),
    });

    encoder.msgSend(void, "setVertexBytes:length:atIndex:", .{
        @as(*const anyopaque, @ptrCast(&shadows[start_idx])),
        @as(c_ulong, count * @sizeOf(scene_mod.Shadow)),
        @as(c_ulong, 1),
    });

    encoder.msgSend(void, "setVertexBytes:length:atIndex:", .{
        @as(*const anyopaque, @ptrCast(&viewport_size)),
        @as(c_ulong, @sizeOf([2]f32)),
        @as(c_ulong, 2),
    });

    encoder.msgSend(void, "drawPrimitives:vertexStart:vertexCount:instanceCount:", .{
        @intFromEnum(mtl.MTLPrimitiveType.triangle),
        @as(c_ulong, 0),
        @as(c_ulong, 6),
        @as(c_ulong, count),
    });
}

fn drawQuadBatch(
    encoder: objc.Object,
    pipeline: objc.Object,
    unit_vertex_buffer: objc.Object,
    quads: []const scene_mod.Quad,
    start_idx: usize,
    count: usize,
    viewport_size: [2]f32,
) void {
    encoder.msgSend(void, "setRenderPipelineState:", .{pipeline.value});

    encoder.msgSend(void, "setVertexBuffer:offset:atIndex:", .{
        unit_vertex_buffer.value,
        @as(c_ulong, 0),
        @as(c_ulong, 0),
    });

    encoder.msgSend(void, "setVertexBytes:length:atIndex:", .{
        @as(*const anyopaque, @ptrCast(&quads[start_idx])),
        @as(c_ulong, count * @sizeOf(scene_mod.Quad)),
        @as(c_ulong, 1),
    });

    encoder.msgSend(void, "setVertexBytes:length:atIndex:", .{
        @as(*const anyopaque, @ptrCast(&viewport_size)),
        @as(c_ulong, @sizeOf([2]f32)),
        @as(c_ulong, 2),
    });

    encoder.msgSend(void, "drawPrimitives:vertexStart:vertexCount:instanceCount:", .{
        @intFromEnum(mtl.MTLPrimitiveType.triangle),
        @as(c_ulong, 0),
        @as(c_ulong, 6),
        @as(c_ulong, count),
    });
}

/// Draw text glyphs using the text pipeline
pub fn drawText(
    tp: *text_pipeline.TextPipeline,
    encoder: objc.Object,
    scene: *const scene_mod.Scene,
    viewport_size: [2]f32,
) void {
    const glyphs = scene.getGlyphs();
    if (glyphs.len > 0) {
        tp.render(encoder, glyphs, viewport_size) catch {};
    }
}
