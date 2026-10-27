//! Scene Renderer - Batch-based rendering with draw order interleaving
//!
//! Renders primitives in correct z-order by iterating through batches
//! and switching pipelines as needed. This enables proper layering of
//! text over quads, dropdowns over content, etc.

const std = @import("std");
const mesh_mod = @import("vk_mesh.zig");

const vk = @import("vulkan.zig");
const unified = @import("../unified.zig");
const scene_mod = @import("../../scene/mod.zig");
const batch_iter = @import("../../scene/batch_iterator.zig");
const SvgInstance = @import("../../scene/svg_instance.zig").SvgInstance;
const ImageInstance = @import("../../scene/image_instance.zig").ImageInstance;

// Re-export for convenience
pub const BatchIterator = batch_iter.BatchIterator;
pub const PrimitiveBatch = batch_iter.PrimitiveBatch;

/// GPU types from vk_types (canonical source)
const vk_types = @import("vk_types.zig");
const GpuGlyph = vk_types.GpuGlyph;
const GpuSvg = vk_types.GpuSvg;
const GpuImage = vk_types.GpuImage;
const InstanceCapacity = vk_types.InstanceCapacity;

/// Vulkan pipeline references for batch rendering
pub const Pipelines = struct {
    mesh: *mesh_mod.Renderer,
    mesh_frame: *mesh_mod.Frame,
    uniform_buffer: vk.Buffer,
    // Pipeline state objects
    unified_pipeline: vk.Pipeline,
    unified_pipeline_layout: vk.PipelineLayout,
    text_pipeline: vk.Pipeline,
    text_pipeline_layout: vk.PipelineLayout,
    svg_pipeline: vk.Pipeline,
    svg_pipeline_layout: vk.PipelineLayout,
    image_pipeline: vk.Pipeline,
    image_pipeline_layout: vk.PipelineLayout,

    // Descriptor sets
    unified_descriptor_set: vk.DescriptorSet,
    text_descriptor_set: vk.DescriptorSet,
    svg_descriptor_set: vk.DescriptorSet,
    image_descriptor_set: vk.DescriptorSet,

    // Buffer mappings for batched data upload
    primitive_mapped: ?*anyopaque,
    glyph_mapped: ?*anyopaque,
    svg_mapped: ?*anyopaque,
    image_mapped: ?*anyopaque,

    // Atlas views (null if not uploaded yet)
    atlas_view: ?vk.ImageView,
    svg_atlas_view: ?vk.ImageView,
    image_atlas_view: ?vk.ImageView,

    // Per-frame capacity of each mapped buffer above, from the window's budget.
    // Offsets accumulate across every batch of a frame, so these bound the frame.
    capacity: InstanceCapacity,
    // The scene's finished-frame count, reported if a buffer is exhausted.
    frame: u64,
};

/// Batch counts output from scene rendering
pub const BatchCounts = struct {
    primitives: u32 = 0,
    glyphs: u32 = 0,
    svgs: u32 = 0,
    images: u32 = 0,
    draw_calls: u32 = 0,
};

/// Draw all scene primitives using batch iteration for correct z-ordering.
/// This records draw commands into the command buffer, switching pipelines
/// as needed to maintain proper draw order.
pub fn drawScene(
    cmd: vk.CommandBuffer,
    scene: *const scene_mod.Scene,
    pipelines: *const Pipelines,
) BatchCounts {
    std.debug.assert(cmd != null);
    std.debug.assert(pipelines.uniform_buffer != null);
    var iter = BatchIterator.init(scene);
    var counts = BatchCounts{};
    var bound: ?PipelineKind = null;
    pipelines.mesh_frame.reset();
    // Path edges are classified over the whole frame before the first path draw.
    pipelines.mesh.classify_edges(scene);
    const mesh = mesh_mod.Draw{
        .renderer = pipelines.mesh,
        .frame = pipelines.mesh_frame,
        .scene = scene,
        .command = cmd,
        .uniform = pipelines.uniform_buffer,
    };
    // The iterator consumes at least one primitive per batch; Scene bounds each pool.
    while (iter.next()) |batch| {
        switch (batch) {
            .shadow => |shadows| {
                const drawn = drawShadowBatch(cmd, shadows, pipelines, counts.primitives, &bound);
                counts.primitives += drawn;
            },
            .quad => |quads| {
                const drawn = drawQuadBatch(cmd, quads, pipelines, counts.primitives, &bound);
                counts.primitives += drawn;
            },
            .glyph => |glyphs| {
                counts.glyphs += drawGlyphBatch(cmd, glyphs, pipelines, counts.glyphs, &bound);
            },
            .svg => |svgs| {
                counts.svgs += drawSvgBatch(cmd, svgs, pipelines, counts.svgs, &bound);
            },
            .image => |images| {
                counts.images += drawImageBatch(cmd, images, pipelines, counts.images, &bound);
            },
            else => {
                counts.draw_calls += switch (batch) {
                    .path => |items| mesh.paths(items),
                    .polyline => |items| mesh.strips(items),
                    .point_cloud => |items| mesh.points(false, items),
                    .colored_point_cloud => |items| mesh.points(true, items),
                    else => unreachable, // The five non-mesh kinds are handled above.
                };
                // Mesh binding invalidates the cached non-mesh pipeline and descriptor set.
                bound = null;
                continue;
            },
        }
        counts.draw_calls += 1;
    }
    return counts;
}

/// Pipeline kinds for tracking current bound pipeline
const PipelineKind = enum {
    unified,
    text,
    svg,
    image,
};

/// Draw a batch of shadows using the unified pipeline
fn drawShadowBatch(
    cmd: vk.CommandBuffer,
    shadows: []const scene_mod.Shadow,
    pipelines: *const Pipelines,
    buffer_offset: u32,
    current_pipeline: *?PipelineKind,
) u32 {
    // Assertions: validate inputs
    std.debug.assert(cmd != null);
    std.debug.assert(buffer_offset <= pipelines.capacity.primitive_count_max);

    if (shadows.len == 0) return 0;
    if (pipelines.unified_pipeline == null) return 0;
    if (pipelines.primitive_mapped == null) return 0;

    // A frame within the budget always fits; anything else fails fast instead
    // of drawing a truncated frame (CLAUDE.md §2).
    const count: u32 = @intCast(shadows.len);
    pipelines.capacity.reserve(.primitives, buffer_offset, count, pipelines.frame);
    std.debug.assert(buffer_offset + count <= pipelines.capacity.primitive_count_max);

    // Upload shadow data to GPU buffer
    const dest: [*]unified.Primitive = @ptrCast(@alignCast(pipelines.primitive_mapped));
    for (shadows[0..count], 0..) |shadow, i| {
        dest[buffer_offset + i] = unified.Primitive.fromShadow(shadow);
    }

    // Bind pipeline if not already bound
    if (current_pipeline.* != .unified) {
        vk.vkCmdBindPipeline(cmd, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, pipelines.unified_pipeline);
        vk.vkCmdBindDescriptorSets(
            cmd,
            vk.VK_PIPELINE_BIND_POINT_GRAPHICS,
            pipelines.unified_pipeline_layout,
            0,
            1,
            (&pipelines.unified_descriptor_set)[0..1],
            0,
            null,
        );
        current_pipeline.* = .unified;
    }

    // Draw: 6 vertices per primitive (two triangles), starting at the buffer offset
    vk.vkCmdDraw(cmd, 6 * count, 1, 6 * buffer_offset, 0);

    return count;
}

/// Draw a batch of quads using the unified pipeline
fn drawQuadBatch(
    cmd: vk.CommandBuffer,
    quads: []const scene_mod.Quad,
    pipelines: *const Pipelines,
    buffer_offset: u32,
    current_pipeline: *?PipelineKind,
) u32 {
    // Assertions: validate inputs
    std.debug.assert(cmd != null);
    std.debug.assert(buffer_offset <= pipelines.capacity.primitive_count_max);

    if (quads.len == 0) return 0;
    if (pipelines.unified_pipeline == null) return 0;
    if (pipelines.primitive_mapped == null) return 0;

    // A frame within the budget always fits; anything else fails fast instead
    // of drawing a truncated frame (CLAUDE.md §2).
    const count: u32 = @intCast(quads.len);
    pipelines.capacity.reserve(.primitives, buffer_offset, count, pipelines.frame);
    std.debug.assert(buffer_offset + count <= pipelines.capacity.primitive_count_max);

    // Upload quad data to GPU buffer
    const dest: [*]unified.Primitive = @ptrCast(@alignCast(pipelines.primitive_mapped));
    for (quads[0..count], 0..) |quad, i| {
        dest[buffer_offset + i] = unified.Primitive.fromQuad(quad);
    }

    // Bind pipeline if not already bound
    if (current_pipeline.* != .unified) {
        vk.vkCmdBindPipeline(cmd, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, pipelines.unified_pipeline);
        vk.vkCmdBindDescriptorSets(
            cmd,
            vk.VK_PIPELINE_BIND_POINT_GRAPHICS,
            pipelines.unified_pipeline_layout,
            0,
            1,
            (&pipelines.unified_descriptor_set)[0..1],
            0,
            null,
        );
        current_pipeline.* = .unified;
    }

    // Draw: 6 vertices per primitive (two triangles), starting at the buffer offset
    vk.vkCmdDraw(cmd, 6 * count, 1, 6 * buffer_offset, 0);

    return count;
}

/// Draw a batch of glyphs using the text pipeline
fn drawGlyphBatch(
    cmd: vk.CommandBuffer,
    glyphs: []const scene_mod.GlyphInstance,
    pipelines: *const Pipelines,
    buffer_offset: u32,
    current_pipeline: *?PipelineKind,
) u32 {
    // Assertions: validate inputs
    std.debug.assert(cmd != null);
    std.debug.assert(buffer_offset <= pipelines.capacity.glyph_count_max);

    if (glyphs.len == 0) return 0;
    if (pipelines.text_pipeline == null) return 0;
    if (pipelines.atlas_view == null) return 0;
    if (pipelines.glyph_mapped == null) return 0;

    // A frame within the budget always fits; anything else fails fast instead
    // of drawing a truncated frame (CLAUDE.md §2).
    const count: u32 = @intCast(glyphs.len);
    pipelines.capacity.reserve(.glyphs, buffer_offset, count, pipelines.frame);
    std.debug.assert(buffer_offset + count <= pipelines.capacity.glyph_count_max);

    // Upload glyph data to GPU buffer
    const dest: [*]GpuGlyph = @ptrCast(@alignCast(pipelines.glyph_mapped));
    for (glyphs[0..count], 0..) |glyph, i| {
        dest[buffer_offset + i] = GpuGlyph.fromScene(glyph);
    }

    // Bind pipeline if not already bound
    if (current_pipeline.* != .text) {
        vk.vkCmdBindPipeline(cmd, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, pipelines.text_pipeline);
        vk.vkCmdBindDescriptorSets(
            cmd,
            vk.VK_PIPELINE_BIND_POINT_GRAPHICS,
            pipelines.text_pipeline_layout,
            0,
            1,
            (&pipelines.text_descriptor_set)[0..1],
            0,
            null,
        );
        current_pipeline.* = .text;
    }

    // Draw: 6 vertices per glyph, starting at the buffer offset
    vk.vkCmdDraw(cmd, 6 * count, 1, 6 * buffer_offset, 0);

    return count;
}

/// Draw a batch of SVG instances using the SVG pipeline
fn drawSvgBatch(
    cmd: vk.CommandBuffer,
    svgs: []const SvgInstance,
    pipelines: *const Pipelines,
    buffer_offset: u32,
    current_pipeline: *?PipelineKind,
) u32 {
    // Assertions: validate inputs
    std.debug.assert(cmd != null);
    std.debug.assert(buffer_offset <= pipelines.capacity.svg_count_max);

    if (svgs.len == 0) return 0;
    if (pipelines.svg_pipeline == null) return 0;
    if (pipelines.svg_atlas_view == null) return 0;
    if (pipelines.svg_mapped == null) return 0;

    // A frame within the budget always fits; anything else fails fast instead
    // of drawing a truncated frame (CLAUDE.md §2).
    const count: u32 = @intCast(svgs.len);
    pipelines.capacity.reserve(.svgs, buffer_offset, count, pipelines.frame);
    std.debug.assert(buffer_offset + count <= pipelines.capacity.svg_count_max);

    // Upload SVG data to GPU buffer
    const dest: [*]GpuSvg = @ptrCast(@alignCast(pipelines.svg_mapped));
    for (svgs[0..count], 0..) |svg, i| {
        dest[buffer_offset + i] = GpuSvg.fromScene(svg);
    }

    // Bind pipeline if not already bound
    if (current_pipeline.* != .svg) {
        vk.vkCmdBindPipeline(cmd, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, pipelines.svg_pipeline);
        vk.vkCmdBindDescriptorSets(
            cmd,
            vk.VK_PIPELINE_BIND_POINT_GRAPHICS,
            pipelines.svg_pipeline_layout,
            0,
            1,
            (&pipelines.svg_descriptor_set)[0..1],
            0,
            null,
        );
        current_pipeline.* = .svg;
    }

    // Draw: 6 vertices per SVG, starting at the buffer offset
    vk.vkCmdDraw(cmd, 6 * count, 1, 6 * buffer_offset, 0);

    return count;
}

/// Draw a batch of image instances using the image pipeline
fn drawImageBatch(
    cmd: vk.CommandBuffer,
    images: []const ImageInstance,
    pipelines: *const Pipelines,
    buffer_offset: u32,
    current_pipeline: *?PipelineKind,
) u32 {
    // Assertions: validate inputs
    std.debug.assert(cmd != null);
    std.debug.assert(buffer_offset <= pipelines.capacity.image_count_max);

    if (images.len == 0) return 0;
    if (pipelines.image_pipeline == null) return 0;
    if (pipelines.image_atlas_view == null) return 0;
    if (pipelines.image_mapped == null) return 0;

    // A frame within the budget always fits; anything else fails fast instead
    // of drawing a truncated frame (CLAUDE.md §2).
    const count: u32 = @intCast(images.len);
    pipelines.capacity.reserve(.images, buffer_offset, count, pipelines.frame);
    std.debug.assert(buffer_offset + count <= pipelines.capacity.image_count_max);

    // Upload image data to GPU buffer
    const dest: [*]GpuImage = @ptrCast(@alignCast(pipelines.image_mapped));
    for (images[0..count], 0..) |img, i| {
        dest[buffer_offset + i] = GpuImage.fromScene(img);
    }

    // Bind pipeline if not already bound
    if (current_pipeline.* != .image) {
        vk.vkCmdBindPipeline(cmd, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, pipelines.image_pipeline);
        vk.vkCmdBindDescriptorSets(
            cmd,
            vk.VK_PIPELINE_BIND_POINT_GRAPHICS,
            pipelines.image_pipeline_layout,
            0,
            1,
            (&pipelines.image_descriptor_set)[0..1],
            0,
            null,
        );
        current_pipeline.* = .image;
    }

    // Draw: 6 vertices per image, starting at the buffer offset
    vk.vkCmdDraw(cmd, 6 * count, 1, 6 * buffer_offset, 0);

    return count;
}
