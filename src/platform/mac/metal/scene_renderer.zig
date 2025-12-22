//! Scene Renderer - Unified pipeline for quads, shadows, and text
//!
//! Uses a single draw call for all quads and shadows by merging them
//! into unified primitives sorted by draw order.

const std = @import("std");
const objc = @import("objc");
const mtl = @import("api.zig");
const scene_mod = @import("../../../core/scene.zig");
const svg_mesh = @import("../../../core/svg_mesh.zig");
const text_pipeline = @import("text.zig");
const render_stats = @import("../../../core/render_stats.zig");
const unified = @import("unified.zig");
const svg_pipeline = @import("svg_pipeline.zig");

/// Draw all scene primitives using the unified pipeline (single draw call)
pub fn drawScenePrimitives(
    encoder: objc.Object,
    scene: *const scene_mod.Scene,
    unit_vertex_buffer: objc.Object,
    viewport_size: [2]f32,
    unified_pipeline: ?objc.Object,
) void {
    drawScenePrimitivesWithStats(encoder, scene, unit_vertex_buffer, viewport_size, unified_pipeline, null);
}

/// Draw with optional stats recording
pub fn drawScenePrimitivesWithStats(
    encoder: objc.Object,
    scene: *const scene_mod.Scene,
    unit_vertex_buffer: objc.Object,
    viewport_size: [2]f32,
    unified_pipeline: ?objc.Object,
    stats: ?*render_stats.RenderStats,
) void {
    const pipeline = unified_pipeline orelse return;

    const shadows = scene.getShadows();
    const quads = scene.getQuads();
    const total_count = shadows.len + quads.len;

    if (total_count == 0) return;

    // Stack buffer for typical scenes, heap for large ones
    var stack_buffer: [1024]unified.Primitive = undefined;
    var primitives: []unified.Primitive = undefined;
    var heap_buffer: ?[]unified.Primitive = null;

    if (total_count <= stack_buffer.len) {
        primitives = stack_buffer[0..total_count];
    } else {
        heap_buffer = std.heap.page_allocator.alloc(unified.Primitive, total_count) catch return;
        primitives = heap_buffer.?;
    }
    defer if (heap_buffer) |buf| std.heap.page_allocator.free(buf);

    // Merge sorted arrays using two-pointer technique
    var shadow_idx: usize = 0;
    var quad_idx: usize = 0;
    var out_idx: usize = 0;

    while (shadow_idx < shadows.len and quad_idx < quads.len) {
        if (shadows[shadow_idx].order <= quads[quad_idx].order) {
            primitives[out_idx] = unified.Primitive.fromShadow(shadows[shadow_idx]);
            shadow_idx += 1;
        } else {
            primitives[out_idx] = unified.Primitive.fromQuad(quads[quad_idx]);
            quad_idx += 1;
        }
        out_idx += 1;
    }
    while (shadow_idx < shadows.len) : (shadow_idx += 1) {
        primitives[out_idx] = unified.Primitive.fromShadow(shadows[shadow_idx]);
        out_idx += 1;
    }
    while (quad_idx < quads.len) : (quad_idx += 1) {
        primitives[out_idx] = unified.Primitive.fromQuad(quads[quad_idx]);
        out_idx += 1;
    }

    // Single draw call for all primitives
    encoder.msgSend(void, "setRenderPipelineState:", .{pipeline.value});
    encoder.msgSend(void, "setVertexBuffer:offset:atIndex:", .{
        unit_vertex_buffer.value,
        @as(c_ulong, 0),
        @as(c_ulong, 0),
    });
    encoder.msgSend(void, "setVertexBytes:length:atIndex:", .{
        @as(*const anyopaque, @ptrCast(primitives.ptr)),
        @as(c_ulong, total_count * @sizeOf(unified.Primitive)),
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
        @as(c_ulong, total_count),
    });

    if (stats) |s| {
        s.recordDrawCall();
        s.recordQuads(@intCast(quads.len));
        s.recordShadows(@intCast(shadows.len));
    }
}

/// Draw text glyphs
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

/// Draw SVG instances
pub fn drawSvgInstances(
    sp: *svg_pipeline.SvgPipeline,
    encoder: objc.Object,
    scene: *const scene_mod.Scene,
    viewport_size: [2]f32,
) void {
    const svg_instances = scene.getSvgInstances();
    if (svg_instances.len > 0) {
        sp.render(encoder, svg_instances, viewport_size);
    }
}
