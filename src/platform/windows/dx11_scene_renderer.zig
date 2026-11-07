//! Scene Renderer (DX11) — batch-based rendering with draw order interleaving.
//!
//! Structural mirror of `../linux/scene_renderer.zig`: same BatchIterator
//! walk, same scene→GPU-struct conversions (shared `unified.Primitive`,
//! `vk_types.GpuGlyph/GpuSvg/GpuImage`), same per-type instance offsets and
//! capacity checks, same stub behavior for path/polyline/point-cloud batches.
//!
//! The walk is split in two passes so the D3D11 resource states stay legal:
//!
//!   `fillScene`   — walks the batches and writes instance rows into the
//!                   currently MAPPED dynamic buffers, recording a draw list.
//!   `submitScene` — with the buffers UNMAPPED, binds per-kind pipeline state
//!                   and replays the draw list. (D3D11 silently drops a draw
//!                   whose SRV views a mapped resource, so draws must not run
//!                   interleaved with the map/write phase.)
//!
//! The per-batch Vulkan pipeline+descriptor binds become D3D11 state binds
//! (shaders, constant buffer, SRV, sampler, blend state).

const std = @import("std");
const builtin = @import("builtin");

const DEBUG_BATCHES = builtin.mode == .debug and false;

const d3d11 = @import("win32/graphics/direct3d11.zig");
const unified = @import("../unified.zig");
const scene_mod = @import("../../scene/mod.zig");
const batch_iter = @import("../../scene/batch_iterator.zig");
const SvgInstance = @import("../../scene/svg_instance.zig").SvgInstance;
const ImageInstance = @import("../../scene/image_instance.zig").ImageInstance;

// Re-export for convenience
pub const BatchIterator = batch_iter.BatchIterator;
pub const PrimitiveBatch = batch_iter.PrimitiveBatch;

/// GPU types from vk_types (canonical source — shared with the Vulkan backend)
const vk_types = @import("vk_types.zig");
const GpuGlyph = vk_types.GpuGlyph;
const GpuSvg = vk_types.GpuSvg;
const GpuImage = vk_types.GpuImage;
const InstanceCapacity = vk_types.InstanceCapacity;

/// One recorded draw: pipeline kind, instance range, vertex offsets.
const RecordedDraw = struct {
    kind: PipelineKind,
    count: u32,
    start_vertex: u32,
};

/// What `fillScene` hands to `submitScene`.
pub const DrawList = struct {
    draws: [max_draws]RecordedDraw = undefined,
    count: u32 = 0,
    // Per-kind instance ranges actually written this frame.
    primitive_count: u32 = 0,
    glyph_count: u32 = 0,
    svg_count: u32 = 0,
    image_count: u32 = 0,

    /// Per-kind instance-buffer element budget; a walk that would overflow
    /// one of these is a programmer error (the renderer asserts capacity up
    /// front), recorded here so submitScene can clamp instead of reading
    /// rows fillScene never wrote.
    primitive_capacity: u32 = 0,
    glyph_capacity: u32 = 0,
    svg_capacity: u32 = 0,
    image_capacity: u32 = 0,

    const max_draws = 4096;
};

/// Mapped instance buffers + budget for `fillScene`.
pub const FillResources = struct {
    primitive_mapped: ?*anyopaque,
    glyph_mapped: ?*anyopaque,
    svg_mapped: ?*anyopaque,
    image_mapped: ?*anyopaque,
    capacity: InstanceCapacity,
    /// The scene's finished-frame count, reported if a buffer is exhausted.
    frame: u64,
};

/// D3D11 state references for batch rendering. Parallel of scene_renderer's
/// `Pipelines`: one shader pair + blend state per primitive kind, one shared
/// constant buffer slot, instance-buffer SRVs, atlas SRVs.
pub const Pipelines = struct {
    // Shader objects (VS+PS per primitive kind)
    unified_vs: ?*d3d11.ID3D11VertexShader,
    unified_ps: ?*d3d11.ID3D11PixelShader,
    text_vs: ?*d3d11.ID3D11VertexShader,
    text_ps: ?*d3d11.ID3D11PixelShader,
    svg_vs: ?*d3d11.ID3D11VertexShader,
    svg_ps: ?*d3d11.ID3D11PixelShader,
    image_vs: ?*d3d11.ID3D11VertexShader,
    image_ps: ?*d3d11.ID3D11PixelShader,

    // Input layouts (per VS; SV_VertexID still requires a valid layout)
    unified_layout: ?*d3d11.ID3D11InputLayout,
    text_layout: ?*d3d11.ID3D11InputLayout,
    svg_layout: ?*d3d11.ID3D11InputLayout,
    image_layout: ?*d3d11.ID3D11InputLayout,

    // Blend states (standard alpha for unified/text/image; premultiplied for svg)
    standard_blend: ?*d3d11.ID3D11BlendState,
    premultiplied_blend: ?*d3d11.ID3D11BlendState,

    // Viewport constant buffer (b0), shared by all shaders
    uniform_buffer: ?*d3d11.ID3D11Buffer,

    // Draw-base constant buffer (b1): the batch's first instance row.
    // SV_VertexID does not include the draw's StartVertexLocation on all
    // drivers, so submitScene passes the row range explicitly per draw.
    base_buffer: ?*d3d11.ID3D11Buffer,

    // Instance-buffer SRVs (t0) over the slot fillScene just wrote
    primitive_srv: ?*d3d11.ID3D11ShaderResourceView,
    glyph_srv: ?*d3d11.ID3D11ShaderResourceView,
    svg_srv: ?*d3d11.ID3D11ShaderResourceView,
    image_srv: ?*d3d11.ID3D11ShaderResourceView,

    // Atlas SRVs (null if not uploaded yet — mirrors vk_atlas `.view`)
    atlas_view: ?*d3d11.ID3D11ShaderResourceView,
    svg_atlas_view: ?*d3d11.ID3D11ShaderResourceView,
    image_atlas_view: ?*d3d11.ID3D11ShaderResourceView,
    atlas_sampler: ?*d3d11.ID3D11SamplerState,
};

/// Batch counts output from scene rendering (same fields as the Vulkan one)
pub const BatchCounts = struct {
    primitives: u32 = 0,
    glyphs: u32 = 0,
    svgs: u32 = 0,
    images: u32 = 0,
    draw_calls: u32 = 0,
};

/// Walk the scene and write instance rows into the mapped buffers, recording
/// a draw list. No GPU state is touched: the buffers are mapped for the whole
/// call. `submitScene` replays the list after the caller unmaps.
pub fn fillScene(scene: *const scene_mod.Scene, resources: FillResources) DrawList {
    var iter = BatchIterator.init(scene);
    var list = DrawList{};
    list.primitive_capacity = resources.capacity.primitive_count_max;
    list.glyph_capacity = resources.capacity.glyph_count_max;
    list.svg_capacity = resources.capacity.svg_count_max;
    list.image_capacity = resources.capacity.image_count_max;

    if (DEBUG_BATCHES) {
        std.debug.print("\n=== BATCH FILL START (dx11) ===\n", .{});
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
        switch (batch) {
            .shadow => |shadows| {
                const drawn = fillShadowBatch(shadows, resources, &list);
                if (drawn > 0) record(&list, .unified, drawn, batch_num);
            },
            .quad => |quads| {
                const drawn = fillQuadBatch(quads, resources, &list);
                if (drawn > 0) record(&list, .unified, drawn, batch_num);
            },
            .glyph => |glyphs| {
                const drawn = fillGlyphBatch(glyphs, resources, &list);
                if (drawn > 0) record(&list, .text, drawn, batch_num);
            },
            .svg => |svgs| {
                const drawn = fillSvgBatch(svgs, resources, &list);
                if (drawn > 0) record(&list, .svg, drawn, batch_num);
            },
            .image => |images| {
                const drawn = fillImageBatch(images, resources, &list);
                if (drawn > 0) record(&list, .image, drawn, batch_num);
            },
            .path => |paths| {
                // TODO: Implement path rendering (stubbed to match Vulkan)
                if (DEBUG_BATCHES) std.debug.print("PATH x{d} (stub - not rendered)\n", .{paths.len});
            },
            .polyline => |polylines| {
                // TODO: Phase 4-5 — stub to match the Vulkan backend
                if (DEBUG_BATCHES) std.debug.print("POLYLINE x{d} (stub - not rendered)\n", .{polylines.len});
            },
            .point_cloud => |point_clouds| {
                if (DEBUG_BATCHES) std.debug.print("POINT_CLOUD x{d} (stub - not rendered)\n", .{point_clouds.len});
            },
            .colored_point_cloud => |colored_point_clouds| {
                if (DEBUG_BATCHES) std.debug.print("COLORED_POINT_CLOUD x{d} (stub - not rendered)\n", .{colored_point_clouds.len});
            },
        }
        batch_num += 1;
    }

    if (DEBUG_BATCHES) {
        std.debug.print("=== BATCH FILL END ({d} batches, {d} draws) ===\n\n", .{
            batch_num,
            list.count,
        });
    }

    return list;
}

/// Replay the draw list with the buffers unmapped. Binds pipeline state per
/// kind (deduplicated across consecutive draws of the same kind).
pub fn submitScene(
    context: *d3d11.ID3D11DeviceContext,
    list: DrawList,
    pipelines: Pipelines,
) BatchCounts {
    var counts = BatchCounts{};
    var current_pipeline: ?PipelineKind = null;

    var i: u32 = 0;
    while (i < list.count) : (i += 1) {
        const draw = list.draws[i];
        switch (draw.kind) {
            .unified => {
                bindPipeline(context, .unified, pipelines, &current_pipeline);
                counts.primitives += draw.count;
            },
            .text => {
                bindPipeline(context, .text, pipelines, &current_pipeline);
                bindAtlas(context, pipelines.atlas_view, pipelines.atlas_sampler);
                counts.glyphs += draw.count;
            },
            .svg => {
                bindPipeline(context, .svg, pipelines, &current_pipeline);
                bindAtlas(context, pipelines.svg_atlas_view, pipelines.atlas_sampler);
                counts.svgs += draw.count;
            },
            .image => {
                bindPipeline(context, .image, pipelines, &current_pipeline);
                bindAtlas(context, pipelines.image_atlas_view, pipelines.atlas_sampler);
                counts.images += draw.count;
            },
        }
        // Draw: 6 vertices per instance (two triangles), SV_VertexID quads.
        // The batch's first row goes through b1 (DrawBase.base_iid) because
        // SV_VertexID does not include StartVertexLocation on all drivers —
        // always draw from vertex 0 and offset in the shader instead.
        if (pipelines.base_buffer) |base_buf| {
            var bm: d3d11.D3D11_MAPPED_SUBRESOURCE = undefined;
            if (context.Map(@ptrCast(base_buf), 0, .WRITE_DISCARD, 0, &bm) >= 0) {
                const base: *u32 = @ptrCast(@alignCast(bm.pData.?));
                base.* = draw.start_vertex;
                context.Unmap(@ptrCast(base_buf), 0);
            }
        }
        context.Draw(6 * draw.count, 0);
        counts.draw_calls += 1;
    }

    return counts;
}

fn record(list: *DrawList, kind: PipelineKind, count: u32, batch_index: u32) void {
    // The draw list is sized for the batch shapes gooey produces; a scene
    // with more batches than slots is a budget bug, not a runtime condition.
    std.debug.assert(list.count < DrawList.max_draws);
    if (list.count >= DrawList.max_draws) return;
    // start_vertex is the instance's row in its kind's buffer; the per-kind
    // running counts on DrawList double as the write cursor fillScene used.
    const start_vertex: u32 = switch (kind) {
        .unified => blk: {
            const s = list.primitive_count - count;
            break :blk s;
        },
        .text => list.glyph_count - count,
        .svg => list.svg_count - count,
        .image => list.image_count - count,
    };
    _ = batch_index;
    list.draws[list.count] = .{ .kind = kind, .count = count, .start_vertex = start_vertex };
    list.count += 1;
}

/// Pipeline kinds for tracking current bound state
const PipelineKind = enum {
    unified,
    text,
    svg,
    image,
};

// Distinct fill fns so shadow/quad keep their own conversions while sharing
// the unified pipeline.

fn fillShadowBatch(
    shadows: []const scene_mod.Shadow,
    resources: FillResources,
    list: *DrawList,
) u32 {
    if (shadows.len == 0) return 0;
    if (resources.primitive_mapped == null) return 0;

    const count: u32 = @intCast(shadows.len);
    resources.capacity.reserve(.primitives, list.primitive_count, count, resources.frame);
    std.debug.assert(list.primitive_count + count <= list.primitive_capacity);

    const dest: [*]unified.Primitive = @ptrCast(@alignCast(resources.primitive_mapped.?));
    for (shadows[0..count], 0..) |shadow, i| {
        dest[list.primitive_count + i] = unified.Primitive.fromShadow(shadow);
    }
    list.primitive_count += count;
    return count;
}

fn fillQuadBatch(
    quads: []const scene_mod.Quad,
    resources: FillResources,
    list: *DrawList,
) u32 {
    if (quads.len == 0) return 0;
    if (resources.primitive_mapped == null) return 0;

    const count: u32 = @intCast(quads.len);
    resources.capacity.reserve(.primitives, list.primitive_count, count, resources.frame);
    std.debug.assert(list.primitive_count + count <= list.primitive_capacity);

    const dest: [*]unified.Primitive = @ptrCast(@alignCast(resources.primitive_mapped.?));
    for (quads[0..count], 0..) |quad, i| {
        dest[list.primitive_count + i] = unified.Primitive.fromQuad(quad);
    }
    list.primitive_count += count;
    return count;
}

// =============================================================================
// Fill pass — CPU writes into mapped buffers only
// =============================================================================

fn fillGlyphBatch(
    glyphs: []const scene_mod.GlyphInstance,
    resources: FillResources,
    list: *DrawList,
) u32 {
    if (glyphs.len == 0) return 0;
    if (resources.glyph_mapped == null) return 0;

    const count: u32 = @intCast(glyphs.len);
    resources.capacity.reserve(.glyphs, list.glyph_count, count, resources.frame);
    std.debug.assert(list.glyph_count + count <= list.glyph_capacity);

    const dest: [*]GpuGlyph = @ptrCast(@alignCast(resources.glyph_mapped.?));
    for (glyphs[0..count], 0..) |glyph, i| {
        dest[list.glyph_count + i] = GpuGlyph.fromScene(glyph);
    }
    list.glyph_count += count;
    return count;
}

fn fillSvgBatch(
    svgs: []const SvgInstance,
    resources: FillResources,
    list: *DrawList,
) u32 {
    if (svgs.len == 0) return 0;
    if (resources.svg_mapped == null) return 0;

    const count: u32 = @intCast(svgs.len);
    resources.capacity.reserve(.svgs, list.svg_count, count, resources.frame);
    std.debug.assert(list.svg_count + count <= list.svg_capacity);

    const dest: [*]GpuSvg = @ptrCast(@alignCast(resources.svg_mapped.?));
    for (svgs[0..count], 0..) |svg, i| {
        dest[list.svg_count + i] = GpuSvg.fromScene(svg);
    }
    list.svg_count += count;
    return count;
}

fn fillImageBatch(
    images: []const ImageInstance,
    resources: FillResources,
    list: *DrawList,
) u32 {
    if (images.len == 0) return 0;
    if (resources.image_mapped == null) return 0;

    const count: u32 = @intCast(images.len);
    resources.capacity.reserve(.images, list.image_count, count, resources.frame);
    std.debug.assert(list.image_count + count <= list.image_capacity);

    const dest: [*]GpuImage = @ptrCast(@alignCast(resources.image_mapped.?));
    for (images[0..count], 0..) |img, i| {
        dest[list.image_count + i] = GpuImage.fromScene(img);
    }
    list.image_count += count;
    return count;
}

// =============================================================================
// Submit pass — GPU binds + draws
// =============================================================================

/// Bind the full state bundle for one pipeline kind: shaders, input layout,
/// blend state, constant buffer. SRV/sampler are bound separately by the
/// textured submit path because the unified pipeline has none.
fn bindPipeline(
    context: *d3d11.ID3D11DeviceContext,
    kind: PipelineKind,
    pipelines: Pipelines,
    current_pipeline: *?PipelineKind,
) void {
    if (current_pipeline.* == kind) return;

    const vs: ?*d3d11.ID3D11VertexShader = switch (kind) {
        .unified => pipelines.unified_vs,
        .text => pipelines.text_vs,
        .svg => pipelines.svg_vs,
        .image => pipelines.image_vs,
    };
    const ps: ?*d3d11.ID3D11PixelShader = switch (kind) {
        .unified => pipelines.unified_ps,
        .text => pipelines.text_ps,
        .svg => pipelines.svg_ps,
        .image => pipelines.image_ps,
    };
    const layout: ?*d3d11.ID3D11InputLayout = switch (kind) {
        .unified => pipelines.unified_layout,
        .text => pipelines.text_layout,
        .svg => pipelines.svg_layout,
        .image => pipelines.image_layout,
    };
    const blend: ?*d3d11.ID3D11BlendState = switch (kind) {
        // SVG shader outputs pre-multiplied RGB (mirrors vk_pipelines' `.premultiplied`)
        .svg => pipelines.premultiplied_blend,
        else => pipelines.standard_blend,
    };

    context.VSSetShader(vs.?, null, 0);
    context.PSSetShader(ps.?, null, 0);
    context.IASetInputLayout(layout.?);
    const blend_factor = [4]f32{ 1.0, 1.0, 1.0, 1.0 };
    context.OMSetBlendState(blend.?, @ptrCast(&blend_factor), 0xffffffff);

    // b0: viewport uniforms, shared by every pipeline
    const cb = pipelines.uniform_buffer orelse unreachable;
    var cbs = [_]?*d3d11.ID3D11Buffer{cb};
    context.VSSetConstantBuffers(0, 1, &cbs);
    context.PSSetConstantBuffers(0, 1, &cbs);

    // b1: per-draw base instance row (submitScene rewrites it before each Draw)
    if (pipelines.base_buffer) |base_buf| {
        var base_cbs = [_]?*d3d11.ID3D11Buffer{base_buf};
        context.VSSetConstantBuffers(1, 1, &base_cbs);
    }

    // t0: the instance structured buffer for this pipeline kind
    const srv: ?*d3d11.ID3D11ShaderResourceView = switch (kind) {
        .unified => pipelines.primitive_srv,
        .text => pipelines.glyph_srv,
        .svg => pipelines.svg_srv,
        .image => pipelines.image_srv,
    };
    if (srv) |s| {
        var srvs = [_]?*d3d11.ID3D11ShaderResourceView{s};
        context.VSSetShaderResources(0, 1, &srvs);
    }

    current_pipeline.* = kind;
}

/// Bind the atlas SRV (t1) and sampler (s0) for a textured pipeline.
fn bindAtlas(
    context: *d3d11.ID3D11DeviceContext,
    view: ?*d3d11.ID3D11ShaderResourceView,
    sampler: ?*d3d11.ID3D11SamplerState,
) void {
    const srv = view orelse return;
    const samp = sampler orelse return;
    {
        var srvs = [_]?*d3d11.ID3D11ShaderResourceView{srv};
        context.PSSetShaderResources(1, 1, @ptrCast(&srvs));
    }
    {
        var samps = [_]?*d3d11.ID3D11SamplerState{samp};
        context.PSSetSamplers(0, 1, @ptrCast(&samps));
    }
}

// ===========================================================================
// Tests — pure fill/record logic, no D3D11 device. The fill layer writes
// instance rows through plain pointers handed to it in FillResources, so
// mapped GPU buffers are simulated with local arrays. Run with
// `zig build test -Dgpu-backend=dx11`.
// ===========================================================================

const testing = std.testing;

fn testCapacity(comptime per_pool: u32) InstanceCapacity {
    return .{
        .primitive_count_max = per_pool,
        .glyph_count_max = per_pool,
        .svg_count_max = per_pool,
        .image_count_max = per_pool,
    };
}

test "fill batches append rows and record per-kind start vertices" {
    var prim_buf: [8]unified.Primitive align(16) = undefined;
    var glyph_buf: [8]vk_types.GpuGlyph align(16) = undefined;
    const capacity = testCapacity(8);
    var list = DrawList{};
    list.primitive_capacity = 8;
    list.glyph_capacity = 8;
    const resources = FillResources{
        .primitive_mapped = @ptrCast(&prim_buf),
        .glyph_mapped = @ptrCast(&glyph_buf),
        .svg_mapped = null,
        .image_mapped = null,
        .capacity = capacity,
        .frame = 7,
    };

    // Two quad batches, then a shadow batch (also unified), interleaved with
    // a glyph batch — mirrors the mixed draw order fillScene produces.
    const quads_a = [_]scene_mod.Quad{
        scene_mod.Quad.filled(10, 20, 30, 40, scene_mod.Hsla.init(0, 0, 1, 1)),
        scene_mod.Quad.filled(1, 2, 3, 4, scene_mod.Hsla.init(0, 0, 1, 1)),
    };
    const glyphs = [_]scene_mod.GlyphInstance{
        .{ .pos_x = 0, .pos_y = 0 },
        .{ .pos_x = 8, .pos_y = 0 },
        .{ .pos_x = 16, .pos_y = 0 },
    };
    const shadows = [_]scene_mod.Shadow{scene_mod.Shadow.drop(5, 5, 20, 10, 4)};
    const quads_b = [_]scene_mod.Quad{
        scene_mod.Quad.filled(50, 60, 70, 80, scene_mod.Hsla.init(0, 0, 1, 1)),
    };

    try testing.expectEqual(@as(u32, 2), fillQuadBatch(&quads_a, resources, &list));
    record(&list, .unified, 2, 0);
    try testing.expectEqual(@as(u32, 3), fillGlyphBatch(&glyphs, resources, &list));
    record(&list, .text, 3, 1);
    try testing.expectEqual(@as(u32, 1), fillShadowBatch(&shadows, resources, &list));
    record(&list, .unified, 1, 2);
    try testing.expectEqual(@as(u32, 1), fillQuadBatch(&quads_b, resources, &list));
    record(&list, .unified, 1, 3);

    try testing.expectEqual(@as(u32, 4), list.primitive_count);
    try testing.expectEqual(@as(u32, 3), list.glyph_count);

    // Rows land in fill order, converted exactly like the shared converter.
    try testing.expectEqual(unified.Primitive.fromQuad(quads_a[0]), prim_buf[0]);
    try testing.expectEqual(unified.Primitive.fromQuad(quads_a[1]), prim_buf[1]);
    try testing.expectEqual(vk_types.GpuGlyph.fromScene(glyphs[0]), glyph_buf[0]);
    try testing.expectEqual(vk_types.GpuGlyph.fromScene(glyphs[1]), glyph_buf[1]);
    try testing.expectEqual(unified.Primitive.fromShadow(shadows[0]), prim_buf[2]);
    try testing.expectEqual(unified.Primitive.fromQuad(quads_b[0]), prim_buf[3]);

    // record() derives each draw's start_vertex from the per-kind running
    // count at the moment of the call — the invariant the SV_VertexID
    // batching depends on — so it must follow each fill immediately,
    // exactly like fillScene does.
    try testing.expectEqual(RecordedDraw{ .kind = .unified, .count = 2, .start_vertex = 0 }, list.draws[0]);
    try testing.expectEqual(RecordedDraw{ .kind = .text, .count = 3, .start_vertex = 0 }, list.draws[1]);
    try testing.expectEqual(RecordedDraw{ .kind = .unified, .count = 1, .start_vertex = 2 }, list.draws[2]);
    try testing.expectEqual(RecordedDraw{ .kind = .unified, .count = 1, .start_vertex = 3 }, list.draws[3]);
    try testing.expectEqual(@as(u32, 4), list.count);
}

test "fill with an unmapped pool is a no-op for that kind" {
    const capacity = testCapacity(8);
    var list = DrawList{};
    list.primitive_capacity = 8;
    const resources = FillResources{
        .primitive_mapped = null,
        .glyph_mapped = null,
        .svg_mapped = null,
        .image_mapped = null,
        .capacity = capacity,
        .frame = 0,
    };
    const quads = [_]scene_mod.Quad{scene_mod.Quad.filled(0, 0, 1, 1, scene_mod.Hsla.init(0, 0, 1, 1))};
    try testing.expectEqual(@as(u32, 0), fillQuadBatch(quads[0..], resources, &list));
    try testing.expectEqual(@as(u32, 0), list.primitive_count);
    try testing.expectEqual(@as(u32, 0), list.count);
}
