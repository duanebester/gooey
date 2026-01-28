//! Scene Renderer - Batch-based rendering with draw order interleaving
//!
//! Renders primitives in correct z-order by iterating through batches
//! and switching pipelines as needed. This enables proper layering of
//! text over quads, dropdowns over content, etc.

const std = @import("std");
const builtin = @import("builtin");

const DEBUG_BATCHES = builtin.mode == .Debug and false;

const vk = @import("vulkan.zig");
const unified = @import("../wgpu/unified.zig");
const scene_mod = @import("../../scene/mod.zig");
const batch_iter = @import("../../scene/batch_iterator.zig");
const SvgInstance = @import("../../scene/svg_instance.zig").SvgInstance;
const ImageInstance = @import("../../scene/image_instance.zig").ImageInstance;

// Re-export for convenience
pub const BatchIterator = batch_iter.BatchIterator;
pub const PrimitiveBatch = batch_iter.PrimitiveBatch;

/// GPU types from vk_renderer
const GpuGlyph = @import("vk_renderer.zig").GpuGlyph;
const GpuSvg = @import("vk_renderer.zig").GpuSvg;
const GpuImage = @import("vk_renderer.zig").GpuImage;

/// Maximum batch sizes (must match vk_renderer limits)
pub const MAX_PRIMITIVES_PER_BATCH = 4096;
pub const MAX_GLYPHS_PER_BATCH = 8192;
pub const MAX_SVGS_PER_BATCH = 2048;
pub const MAX_IMAGES_PER_BATCH = 1024;

/// Vulkan pipeline references for batch rendering
pub const Pipelines = struct {
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
    pipelines: Pipelines,
) BatchCounts {
    var iter = BatchIterator.init(scene);
    var counts = BatchCounts{};

    // Track current pipeline to avoid redundant binds
    var current_pipeline: ?PipelineKind = null;

    // Offsets into the mapped buffers for each type
    var primitive_offset: u32 = 0;
    var glyph_offset: u32 = 0;
    var svg_offset: u32 = 0;
    var image_offset: u32 = 0;

    if (DEBUG_BATCHES) {
        std.debug.print("\n=== BATCH RENDER START ===\n", .{});
        std.debug.print("  Total shadows: {d}, quads: {d}, glyphs: {d}, svgs: {d}, images: {d}\n", .{
            scene.getShadows().len,
            scene.getQuads().len,
            scene.getGlyphs().len,
            scene.getSvgInstances().len,
            scene.getImages().len,
        });
        std.debug.print("  Pipeline state: unified={}, text={}, svg={}, image={}\n", .{
            pipelines.unified_pipeline != null,
            pipelines.text_pipeline != null,
            pipelines.svg_pipeline != null,
            pipelines.image_pipeline != null,
        });
        std.debug.print("  Atlas views: text={}, svg={}, image={}\n", .{
            pipelines.atlas_view != null,
            pipelines.svg_atlas_view != null,
            pipelines.image_atlas_view != null,
        });
        std.debug.print("  Mapped buffers: prim={}, glyph={}, svg={}, image={}\n", .{
            pipelines.primitive_mapped != null,
            pipelines.glyph_mapped != null,
            pipelines.svg_mapped != null,
            pipelines.image_mapped != null,
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
                const drawn = drawShadowBatch(
                    cmd,
                    shadows,
                    pipelines,
                    primitive_offset,
                    &current_pipeline,
                );
                primitive_offset += drawn;
                counts.primitives += drawn;
                counts.draw_calls += 1;
            },
            .quad => |quads| {
                if (DEBUG_BATCHES) std.debug.print("QUAD x{d}\n", .{quads.len});
                const drawn = drawQuadBatch(
                    cmd,
                    quads,
                    pipelines,
                    primitive_offset,
                    &current_pipeline,
                );
                primitive_offset += drawn;
                counts.primitives += drawn;
                counts.draw_calls += 1;
            },
            .glyph => |glyphs| {
                if (DEBUG_BATCHES) std.debug.print("GLYPH x{d}\n", .{glyphs.len});
                const drawn = drawGlyphBatch(
                    cmd,
                    glyphs,
                    pipelines,
                    glyph_offset,
                    &current_pipeline,
                );
                glyph_offset += drawn;
                counts.glyphs += drawn;
                counts.draw_calls += 1;
            },
            .svg => |svgs| {
                if (DEBUG_BATCHES) std.debug.print("SVG x{d}\n", .{svgs.len});
                const drawn = drawSvgBatch(
                    cmd,
                    svgs,
                    pipelines,
                    svg_offset,
                    &current_pipeline,
                );
                svg_offset += drawn;
                counts.svgs += drawn;
                counts.draw_calls += 1;
            },
            .image => |images| {
                if (DEBUG_BATCHES) std.debug.print("IMAGE x{d}\n", .{images.len});
                const drawn = drawImageBatch(
                    cmd,
                    images,
                    pipelines,
                    image_offset,
                    &current_pipeline,
                );
                image_offset += drawn;
                counts.images += drawn;
                counts.draw_calls += 1;
            },
            .path => |paths| {
                // TODO: Implement path rendering for Linux
                if (DEBUG_BATCHES) {
                    std.debug.print("PATH x{d} (stub - not rendered)\n", .{paths.len});
                }
            },
            .polyline => |polylines| {
                // TODO: Phase 4-5 - Implement polyline GPU pipeline
                // For now, stub that skips rendering (API validation phase)
                if (DEBUG_BATCHES) {
                    std.debug.print("POLYLINE x{d} (stub - not rendered)\n", .{polylines.len});
                }
            },
            .point_cloud => |point_clouds| {
                // TODO: Phase 4-5 - Implement point cloud GPU pipeline
                // For now, stub that skips rendering (API validation phase)
                if (DEBUG_BATCHES) {
                    std.debug.print("POINT_CLOUD x{d} (stub - not rendered)\n", .{point_clouds.len});
                }
            },
            .colored_point_cloud => |colored_point_clouds| {
                // TODO: Phase 6 - Implement colored point cloud GPU pipeline
                // For now, stub that skips rendering (API validation phase)
                if (DEBUG_BATCHES) {
                    std.debug.print("COLORED_POINT_CLOUD x{d} (stub - not rendered)\n", .{colored_point_clouds.len});
                }
            },
        }
        batch_num += 1;
    }

    if (DEBUG_BATCHES) {
        std.debug.print("=== BATCH RENDER END ({d} batches, {d} draw calls) ===\n\n", .{
            batch_num,
            counts.draw_calls,
        });
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
    pipelines: Pipelines,
    buffer_offset: u32,
    current_pipeline: *?PipelineKind,
) u32 {
    // Assertions: validate inputs
    std.debug.assert(cmd != null);
    std.debug.assert(buffer_offset <= MAX_PRIMITIVES_PER_BATCH);

    if (shadows.len == 0) return 0;
    if (pipelines.unified_pipeline == null) return 0;
    if (pipelines.primitive_mapped == null) return 0;

    const count: u32 = @intCast(@min(shadows.len, MAX_PRIMITIVES_PER_BATCH - buffer_offset));
    if (count == 0) return 0;

    // Assert buffer bounds before GPU write
    std.debug.assert(buffer_offset + count <= MAX_PRIMITIVES_PER_BATCH);

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
            &pipelines.unified_descriptor_set,
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
    pipelines: Pipelines,
    buffer_offset: u32,
    current_pipeline: *?PipelineKind,
) u32 {
    // Assertions: validate inputs
    std.debug.assert(cmd != null);
    std.debug.assert(buffer_offset <= MAX_PRIMITIVES_PER_BATCH);

    if (quads.len == 0) return 0;
    if (pipelines.unified_pipeline == null) return 0;
    if (pipelines.primitive_mapped == null) return 0;

    const count: u32 = @intCast(@min(quads.len, MAX_PRIMITIVES_PER_BATCH - buffer_offset));
    if (count == 0) return 0;

    // Assert buffer bounds before GPU write
    std.debug.assert(buffer_offset + count <= MAX_PRIMITIVES_PER_BATCH);

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
            &pipelines.unified_descriptor_set,
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
    pipelines: Pipelines,
    buffer_offset: u32,
    current_pipeline: *?PipelineKind,
) u32 {
    // Assertions: validate inputs
    std.debug.assert(cmd != null);
    std.debug.assert(buffer_offset <= MAX_GLYPHS_PER_BATCH);

    if (glyphs.len == 0) return 0;
    if (pipelines.text_pipeline == null) return 0;
    if (pipelines.atlas_view == null) return 0;
    if (pipelines.glyph_mapped == null) return 0;

    const count: u32 = @intCast(@min(glyphs.len, MAX_GLYPHS_PER_BATCH - buffer_offset));
    if (count == 0) return 0;

    // Assert buffer bounds before GPU write
    std.debug.assert(buffer_offset + count <= MAX_GLYPHS_PER_BATCH);

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
            &pipelines.text_descriptor_set,
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
    pipelines: Pipelines,
    buffer_offset: u32,
    current_pipeline: *?PipelineKind,
) u32 {
    // Assertions: validate inputs
    std.debug.assert(cmd != null);
    std.debug.assert(buffer_offset <= MAX_SVGS_PER_BATCH);

    if (svgs.len == 0) return 0;
    if (pipelines.svg_pipeline == null) return 0;
    if (pipelines.svg_atlas_view == null) return 0;
    if (pipelines.svg_mapped == null) return 0;

    const count: u32 = @intCast(@min(svgs.len, MAX_SVGS_PER_BATCH - buffer_offset));
    if (count == 0) return 0;

    // Assert buffer bounds before GPU write
    std.debug.assert(buffer_offset + count <= MAX_SVGS_PER_BATCH);

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
            &pipelines.svg_descriptor_set,
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
    pipelines: Pipelines,
    buffer_offset: u32,
    current_pipeline: *?PipelineKind,
) u32 {
    // Assertions: validate inputs
    std.debug.assert(cmd != null);
    std.debug.assert(buffer_offset <= MAX_IMAGES_PER_BATCH);

    if (images.len == 0) return 0;
    if (pipelines.image_pipeline == null) return 0;
    if (pipelines.image_atlas_view == null) return 0;
    if (pipelines.image_mapped == null) return 0;

    const count: u32 = @intCast(@min(images.len, MAX_IMAGES_PER_BATCH - buffer_offset));
    if (count == 0) return 0;

    // Assert buffer bounds before GPU write
    std.debug.assert(buffer_offset + count <= MAX_IMAGES_PER_BATCH);

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
            &pipelines.image_descriptor_set,
            0,
            null,
        );
        current_pipeline.* = .image;
    }

    // Draw: 6 vertices per image, starting at the buffer offset
    vk.vkCmdDraw(cmd, 6 * count, 1, 6 * buffer_offset, 0);

    return count;
}
