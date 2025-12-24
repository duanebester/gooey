//! Scene Renderer - Batch-based rendering with draw order interleaving
//!
//! Renders primitives in correct z-order by iterating through batches
//! and switching pipelines as needed. This enables proper layering of
//! text over quads, dropdowns over content, etc.

const std = @import("std");
const builtin = @import("builtin");

const DEBUG_BATCHES = builtin.mode == .Debug and false; // Set second condition to true to enable batch debug output
const objc = @import("objc");
const mtl = @import("api.zig");
const scene_mod = @import("../../../core/scene.zig");
const batch_iter = @import("../../../core/batch_iterator.zig");
const text_pipeline = @import("text.zig");
const render_stats = @import("../../../core/render_stats.zig");
const unified = @import("unified.zig");
const svg_pipeline = @import("svg_pipeline.zig");
const image_pipeline = @import("image_pipeline.zig");

/// Pipeline references for batch rendering
pub const Pipelines = struct {
    unified: ?objc.Object,
    text: ?*text_pipeline.TextPipeline,
    svg: ?*svg_pipeline.SvgPipeline,
    image: ?*image_pipeline.ImagePipeline,
    unit_vertex_buffer: objc.Object,
};

/// Draw all scene primitives using batch iteration for correct z-ordering
pub fn drawScene(
    encoder: objc.Object,
    scene: *const scene_mod.Scene,
    pipelines: Pipelines,
    viewport_size: [2]f32,
) void {
    drawSceneWithStats(encoder, scene, pipelines, viewport_size, null);
}

/// Draw with optional stats recording
pub fn drawSceneWithStats(
    encoder: objc.Object,
    scene: *const scene_mod.Scene,
    pipelines: Pipelines,
    viewport_size: [2]f32,
    stats: ?*render_stats.RenderStats,
) void {
    var iter = batch_iter.BatchIterator.init(scene);

    if (DEBUG_BATCHES) {
        std.debug.print("\n=== BATCH RENDER START ===\n", .{});
        std.debug.print("  Total shadows: {d}, quads: {d}, glyphs: {d}, svgs: {d}, images: {d}\n", .{
            scene.getShadows().len,
            scene.getQuads().len,
            scene.getGlyphs().len,
            scene.getSvgInstances().len,
            scene.getImages().len,
        });
    }

    var batch_num: u32 = 0;
    while (iter.next()) |batch| {
        if (DEBUG_BATCHES) {
            std.debug.print("  Batch {d}: ", .{batch_num});
        }
        switch (batch) {
            .shadow => |shadows| {
                if (DEBUG_BATCHES) std.debug.print("SHADOW x{d}\n", .{shadows.len});
                drawShadowBatch(encoder, shadows, pipelines, viewport_size, stats);
            },
            .quad => |quads| {
                if (DEBUG_BATCHES) std.debug.print("QUAD x{d}\n", .{quads.len});
                drawQuadBatch(encoder, quads, pipelines, viewport_size, stats);
            },
            .glyph => |glyphs| {
                if (DEBUG_BATCHES) std.debug.print("GLYPH x{d}\n", .{glyphs.len});
                drawGlyphBatch(encoder, glyphs, pipelines, viewport_size, stats);
            },
            .svg => |svgs| {
                if (DEBUG_BATCHES) std.debug.print("SVG x{d}\n", .{svgs.len});
                drawSvgBatch(encoder, svgs, pipelines, viewport_size, stats);
            },
            .image => |images| {
                if (DEBUG_BATCHES) std.debug.print("IMAGE x{d}\n", .{images.len});
                drawImageBatch(encoder, images, pipelines, viewport_size, stats);
            },
        }
        batch_num += 1;
    }

    if (DEBUG_BATCHES) {
        std.debug.print("=== BATCH RENDER END ({d} batches) ===\n\n", .{batch_num});
    }
}

/// Draw a batch of shadows using the unified pipeline
fn drawShadowBatch(
    encoder: objc.Object,
    shadows: []const scene_mod.Shadow,
    pipelines: Pipelines,
    viewport_size: [2]f32,
    stats: ?*render_stats.RenderStats,
) void {
    if (shadows.len == 0) return;
    const pipeline = pipelines.unified orelse return;

    // Convert shadows to unified primitives
    var stack_buffer: [512]unified.Primitive = undefined;
    var primitives: []unified.Primitive = undefined;
    var heap_buffer: ?[]unified.Primitive = null;

    if (shadows.len <= stack_buffer.len) {
        primitives = stack_buffer[0..shadows.len];
    } else {
        heap_buffer = std.heap.page_allocator.alloc(unified.Primitive, shadows.len) catch return;
        primitives = heap_buffer.?;
    }
    defer if (heap_buffer) |buf| std.heap.page_allocator.free(buf);

    for (shadows, 0..) |shadow, i| {
        primitives[i] = unified.Primitive.fromShadow(shadow);
    }

    drawUnifiedPrimitives(encoder, primitives, pipeline, pipelines.unit_vertex_buffer, viewport_size);

    if (stats) |s| {
        s.recordDrawCall();
        s.recordShadows(@intCast(shadows.len));
    }
}

/// Draw a batch of quads using the unified pipeline
fn drawQuadBatch(
    encoder: objc.Object,
    quads: []const scene_mod.Quad,
    pipelines: Pipelines,
    viewport_size: [2]f32,
    stats: ?*render_stats.RenderStats,
) void {
    if (quads.len == 0) return;
    const pipeline = pipelines.unified orelse return;

    // Convert quads to unified primitives
    var stack_buffer: [512]unified.Primitive = undefined;
    var primitives: []unified.Primitive = undefined;
    var heap_buffer: ?[]unified.Primitive = null;

    if (quads.len <= stack_buffer.len) {
        primitives = stack_buffer[0..quads.len];
    } else {
        heap_buffer = std.heap.page_allocator.alloc(unified.Primitive, quads.len) catch return;
        primitives = heap_buffer.?;
    }
    defer if (heap_buffer) |buf| std.heap.page_allocator.free(buf);

    for (quads, 0..) |quad, i| {
        primitives[i] = unified.Primitive.fromQuad(quad);
    }

    drawUnifiedPrimitives(encoder, primitives, pipeline, pipelines.unit_vertex_buffer, viewport_size);

    if (stats) |s| {
        s.recordDrawCall();
        s.recordQuads(@intCast(quads.len));
    }
}

/// Draw a batch of glyphs using the text pipeline
fn drawGlyphBatch(
    encoder: objc.Object,
    glyphs: []const scene_mod.GlyphInstance,
    pipelines: Pipelines,
    viewport_size: [2]f32,
    stats: ?*render_stats.RenderStats,
) void {
    if (glyphs.len == 0) return;
    const tp = pipelines.text orelse return;

    // Use renderBatch which copies data inline via setVertexBytes,
    // safe for multiple calls per frame (unlike render which uses shared buffer)
    tp.renderBatch(encoder, glyphs, viewport_size) catch |err| {
        if (builtin.mode == .Debug) {
            std.debug.print("drawGlyphBatch failed: {}\n", .{err});
        }
    };

    if (stats) |s| {
        s.recordDrawCall();
        s.recordGlyphs(@intCast(glyphs.len));
    }
}

/// Draw a batch of SVG instances using the SVG pipeline
fn drawSvgBatch(
    encoder: objc.Object,
    svgs: []const @import("../../../core/svg_instance.zig").SvgInstance,
    pipelines: Pipelines,
    viewport_size: [2]f32,
    stats: ?*render_stats.RenderStats,
) void {
    if (svgs.len == 0) return;
    const sp = pipelines.svg orelse return;

    // Use renderBatch which copies data inline via setVertexBytes,
    // safe for multiple calls per frame (unlike render which uses shared buffer)
    sp.renderBatch(encoder, svgs, viewport_size) catch |err| {
        if (builtin.mode == .Debug) {
            std.debug.print("drawSvgBatch failed: {}\n", .{err});
        }
    };

    if (stats) |s| {
        s.recordDrawCall();
        s.recordSvgs(@intCast(svgs.len));
    }
}

/// Draw a batch of image instances using the image pipeline
fn drawImageBatch(
    encoder: objc.Object,
    images: []const @import("../../../core/image_instance.zig").ImageInstance,
    pipelines: Pipelines,
    viewport_size: [2]f32,
    stats: ?*render_stats.RenderStats,
) void {
    if (images.len == 0) return;
    const ip = pipelines.image orelse return;

    // Use renderBatch which copies data inline via setVertexBytes,
    // safe for multiple calls per frame (unlike render which uses shared buffer)
    ip.renderBatch(encoder, images, viewport_size) catch |err| {
        if (builtin.mode == .Debug) {
            std.debug.print("drawImageBatch failed: {}\n", .{err});
        }
    };

    if (stats) |s| {
        s.recordDrawCall();
        // TODO: Add recordImages to stats if needed
    }
}

/// Common rendering logic for unified primitives (quads and shadows)
fn drawUnifiedPrimitives(
    encoder: objc.Object,
    primitives: []const unified.Primitive,
    pipeline: objc.Object,
    unit_vertex_buffer: objc.Object,
    viewport_size: [2]f32,
) void {
    if (primitives.len == 0) return;

    encoder.msgSend(void, "setRenderPipelineState:", .{pipeline.value});
    encoder.msgSend(void, "setVertexBuffer:offset:atIndex:", .{
        unit_vertex_buffer.value,
        @as(c_ulong, 0),
        @as(c_ulong, 0),
    });
    encoder.msgSend(void, "setVertexBytes:length:atIndex:", .{
        @as(*const anyopaque, @ptrCast(primitives.ptr)),
        @as(c_ulong, primitives.len * @sizeOf(unified.Primitive)),
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
        @as(c_ulong, primitives.len),
    });
}

// =============================================================================
// Legacy API - for backwards compatibility during transition
// =============================================================================

/// Draw all scene primitives using the unified pipeline (single draw call)
/// DEPRECATED: Use drawScene() instead for correct z-ordering
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
/// DEPRECATED: Use drawSceneWithStats() instead for correct z-ordering
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
/// DEPRECATED: Handled automatically by drawScene()
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
/// DEPRECATED: Handled automatically by drawScene()
pub fn drawSvgInstances(
    sp: *svg_pipeline.SvgPipeline,
    encoder: objc.Object,
    scene: *const scene_mod.Scene,
    viewport_size: [2]f32,
) void {
    const svg_instances = scene.getSvgInstances();
    if (svg_instances.len > 0) {
        sp.render(encoder, svg_instances, viewport_size) catch {};
    }
}
