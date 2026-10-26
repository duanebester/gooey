//! Scene Renderer - Batch-based rendering with draw order interleaving
//!
//! Renders primitives in correct z-order by iterating through batches
//! and switching pipelines as needed. This enables proper layering of
//! text over quads, dropdowns over content, etc.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

const DEBUG_BATCHES = builtin.mode == .debug and false; // Set second condition to true to enable batch debug output
const objc = @import("objc");
const mtl = @import("api.zig");
const scene_mod = @import("../../../scene/mod.zig");
const batch_iter = @import("../../../scene/batch_iterator.zig");
const text_pipeline = @import("text.zig");
const render_stats = @import("../../../debug/render_stats.zig");
const unified = @import("../../unified.zig");
const limits = @import("../../../core/limits.zig");
const svg_pipeline = @import("svg_pipeline.zig");
const image_pipeline = @import("image_pipeline.zig");
const path_pipeline = @import("path_pipeline.zig");
const polyline_pipeline = @import("polyline_pipeline.zig");
const point_cloud_pipeline = @import("point_cloud_pipeline.zig");
const colored_point_cloud_pipeline = @import("colored_point_cloud_pipeline.zig");
const mesh_pool_mod = @import("../../../scene/mesh_pool.zig");
const Polyline = @import("../../../scene/polyline.zig").Polyline;
const PointCloud = @import("../../../scene/point_cloud.zig").PointCloud;
const ColoredPointCloud = @import("../../../scene/colored_point_cloud.zig").ColoredPointCloud;

/// Pipeline references for batch rendering
pub const Pipelines = struct {
    unified: ?objc.Object,
    /// Per-frame instance storage for quads and shadows. The caller advances it with
    /// `nextFrame` once per rendered frame, before any batch is drawn.
    unified_ring: *UnifiedPrimitiveRing,
    text: ?*text_pipeline.TextPipeline,
    svg: ?*svg_pipeline.SvgPipeline,
    image: ?*image_pipeline.ImagePipeline,
    path: ?*path_pipeline.PathPipeline,
    polyline: ?*polyline_pipeline.PolylinePipeline,
    point_cloud: ?*point_cloud_pipeline.PointCloudPipeline,
    colored_point_cloud: ?*colored_point_cloud_pipeline.ColoredPointCloudPipeline,
    mesh_pool: ?*const mesh_pool_mod.MeshPool,
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

/// Draw with optional stats recording.
///
/// Quad and shadow batches share the unified pipeline and the same per-frame ring slot, so
/// consecutive quad/shadow batches are appended back to back and drawn as one instanced
/// call when a different pipeline's batch (or the end of the scene) interrupts the run.
/// Instances rasterize in instance order, so merging preserves draw order.
pub fn drawSceneWithStats(
    encoder: objc.Object,
    scene: *const scene_mod.Scene,
    pipelines: Pipelines,
    viewport_size: [2]f32,
    stats: ?*render_stats.RenderStats,
) void {
    const ring = pipelines.unified_ring;
    // Every earlier drawScene call in this frame flushed its tail.
    assert(ring.primitive_count_drawn == ring.primitive_count);

    if (DEBUG_BATCHES) {
        std.debug.print("\n=== BATCH RENDER START ===\n", .{});
        std.debug.print("  Total shadows: {d}, quads: {d}, glyphs: {d}, svgs: {d}, images: {d}, paths: {d}\n", .{
            scene.getShadows().len,
            scene.getQuads().len,
            scene.getGlyphs().len,
            scene.getSvgInstances().len,
            scene.getImages().len,
            scene.getPathInstances().len,
        });
    }

    var iter = batch_iter.BatchIterator.init(scene);
    var batch_num: u32 = 0;
    while (iter.next()) |batch| : (batch_num += 1) {
        if (DEBUG_BATCHES) {
            const name = @tagName(batch);
            std.debug.print("  Batch {d}: {s} x{d}\n", .{ batch_num, name, batch.len() });
        }
        switch (batch) {
            .shadow => |shadows| appendShadowBatch(ring, shadows, &pipelines, stats),
            .quad => |quads| appendQuadBatch(ring, quads, &pipelines, stats),
            else => {
                drawUnifiedPending(encoder, ring, &pipelines, viewport_size, stats);
                drawPipelineBatch(encoder, batch, scene, &pipelines, viewport_size, stats);
            },
        }
    }
    drawUnifiedPending(encoder, ring, &pipelines, viewport_size, stats);
    assert(ring.primitive_count_drawn == ring.primitive_count);

    if (DEBUG_BATCHES) {
        std.debug.print("=== BATCH RENDER END ({d} batches) ===\n\n", .{batch_num});
    }
}

/// Dispatch a batch that does not use the unified quad/shadow pipeline.
fn drawPipelineBatch(
    encoder: objc.Object,
    batch: batch_iter.PrimitiveBatch,
    scene: *const scene_mod.Scene,
    pipelines: *const Pipelines,
    viewport_size: [2]f32,
    stats: ?*render_stats.RenderStats,
) void {
    switch (batch) {
        .shadow, .quad => unreachable, // Appended to the unified ring by the caller.
        .glyph => |glyphs| drawGlyphBatch(encoder, glyphs, pipelines.*, viewport_size, stats),
        .svg => |svgs| drawSvgBatch(encoder, svgs, pipelines.*, viewport_size, stats),
        .image => |images| drawImageBatch(encoder, images, pipelines.*, viewport_size, stats),
        .path => |paths| drawPathBatch(encoder, paths, scene, pipelines.*, viewport_size, stats),
        .polyline => |polylines| {
            drawPolylineBatch(encoder, polylines, pipelines.*, viewport_size, stats);
        },
        .point_cloud => |point_clouds| {
            drawPointCloudBatch(encoder, point_clouds, pipelines.*, viewport_size, stats);
        },
        .colored_point_cloud => |clouds| {
            drawColoredPointCloudBatch(encoder, clouds, pipelines.*, viewport_size, stats);
        },
    }
}

/// Convert a shadow batch into the ring; drawn later by `drawUnifiedPending`.
fn appendShadowBatch(
    ring: *UnifiedPrimitiveRing,
    shadows: []const scene_mod.Shadow,
    pipelines: *const Pipelines,
    stats: ?*render_stats.RenderStats,
) void {
    assert(shadows.len > 0); // The batch iterator never yields empty batches.
    if (pipelines.unified == null) return;

    const target = ring.claim(shadows.len, "shadow");
    convertShadows(shadows, target);

    if (stats) |s| s.recordShadows(@intCast(shadows.len));
}

/// Convert a quad batch into the ring; drawn later by `drawUnifiedPending`.
fn appendQuadBatch(
    ring: *UnifiedPrimitiveRing,
    quads: []const scene_mod.Quad,
    pipelines: *const Pipelines,
    stats: ?*render_stats.RenderStats,
) void {
    assert(quads.len > 0); // The batch iterator never yields empty batches.
    if (pipelines.unified == null) return;

    const target = ring.claim(quads.len, "quad");
    convertQuads(quads, target);

    if (stats) |s| s.recordQuads(@intCast(quads.len));
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
        if (builtin.mode == .debug) {
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
    svgs: []const @import("../../../scene/svg_instance.zig").SvgInstance,
    pipelines: Pipelines,
    viewport_size: [2]f32,
    stats: ?*render_stats.RenderStats,
) void {
    if (svgs.len == 0) return;
    const sp = pipelines.svg orelse return;

    // Use renderBatch which copies data inline via setVertexBytes,
    // safe for multiple calls per frame (unlike render which uses shared buffer)
    sp.renderBatch(encoder, svgs, viewport_size) catch |err| {
        if (builtin.mode == .debug) {
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
    images: []const @import("../../../scene/image_instance.zig").ImageInstance,
    pipelines: Pipelines,
    viewport_size: [2]f32,
    stats: ?*render_stats.RenderStats,
) void {
    if (images.len == 0) return;
    const ip = pipelines.image orelse return;

    // Use renderBatch which copies data inline via setVertexBytes,
    // safe for multiple calls per frame (unlike render which uses shared buffer)
    ip.renderBatch(encoder, images, viewport_size) catch |err| {
        if (builtin.mode == .debug) {
            std.debug.print("drawImageBatch failed: {}\n", .{err});
        }
    };

    if (stats) |s| {
        s.recordDrawCall();
        // TODO: Add recordImages to stats if needed
    }
}

/// Draw a batch of path instances using the path pipeline
fn drawPathBatch(
    encoder: objc.Object,
    paths: []const @import("../../../scene/path_instance.zig").PathInstance,
    scene: *const scene_mod.Scene,
    pipelines: Pipelines,
    viewport_size: [2]f32,
    stats: ?*render_stats.RenderStats,
) void {
    if (paths.len == 0) return;
    const pp = pipelines.path orelse return;
    const pool = pipelines.mesh_pool orelse return;

    // Calculate offset of this batch within the full paths array
    // (paths is a slice that may start at any index in the full array)
    const all_paths = scene.getPathInstances();
    const all_gradients = scene.getPathGradients();

    // Use pointer arithmetic to find the batch offset
    const PathInstance = @import("../../../scene/path_instance.zig").PathInstance;

    // Safety assertions for pointer arithmetic (per CLAUDE.md: minimum 2 assertions per function)
    std.debug.assert(@intFromPtr(paths.ptr) >= @intFromPtr(all_paths.ptr));
    const batch_offset = (@intFromPtr(paths.ptr) - @intFromPtr(all_paths.ptr)) / @sizeOf(PathInstance);
    std.debug.assert(batch_offset + paths.len <= all_gradients.len);

    // Slice gradients to match the path batch (parallel arrays must stay aligned)
    const gradients = all_gradients[batch_offset..][0..paths.len];

    pp.renderBatchWithGradients(encoder, paths, gradients, pool, viewport_size) catch |err| {
        if (builtin.mode == .debug) {
            std.debug.print("drawPathBatch failed: {}\n", .{err});
        }
    };

    if (stats) |s| {
        s.recordDrawCall();
        s.recordPaths(@intCast(paths.len));
    }
}

/// Draw a batch of polylines using the polyline pipeline
fn drawPolylineBatch(
    encoder: objc.Object,
    polylines: []const Polyline,
    pipelines: Pipelines,
    viewport_size: [2]f32,
    stats: ?*render_stats.RenderStats,
) void {
    if (polylines.len == 0) return;
    const plp = pipelines.polyline orelse return;

    plp.renderBatch(encoder, polylines, viewport_size) catch |err| {
        if (builtin.mode == .debug) {
            std.debug.print("drawPolylineBatch failed: {}\n", .{err});
        }
    };

    if (stats) |s| {
        s.recordDrawCall();
        // TODO: Add recordPolylines to stats if needed
    }
}

/// Draw a batch of point clouds using the point cloud pipeline
fn drawPointCloudBatch(
    encoder: objc.Object,
    point_clouds: []const PointCloud,
    pipelines: Pipelines,
    viewport_size: [2]f32,
    stats: ?*render_stats.RenderStats,
) void {
    if (point_clouds.len == 0) return;
    const pcp = pipelines.point_cloud orelse return;

    pcp.renderBatch(encoder, point_clouds, viewport_size) catch |err| {
        if (builtin.mode == .debug) {
            std.debug.print("drawPointCloudBatch failed: {}\n", .{err});
        }
    };

    if (stats) |s| {
        s.recordDrawCall();
        // TODO: Add recordPointClouds to stats if needed
    }
}

fn drawColoredPointCloudBatch(
    encoder: objc.Object,
    colored_point_clouds: []const ColoredPointCloud,
    pipelines: Pipelines,
    viewport_size: [2]f32,
    stats: ?*render_stats.RenderStats,
) void {
    if (colored_point_clouds.len == 0) return;
    const cpcp = pipelines.colored_point_cloud orelse return;

    cpcp.renderBatch(encoder, colored_point_clouds, viewport_size) catch |err| {
        if (builtin.mode == .debug) {
            std.debug.print("drawColoredPointCloudBatch failed: {}\n", .{err});
        }
    };

    if (stats) |s| {
        s.recordDrawCall();
        // TODO: Add recordColoredPointClouds to stats if needed
    }
}

/// Issue one instanced draw for the ring's written-but-undrawn tail, if any.
///
/// The slot is bound at `buffer(1)`, where `unified_vertex` reads `constant Primitive *`, at
/// the tail's byte offset. Offsets are multiples of 128 B, which satisfies the minimum
/// constant-buffer offset alignment of every Metal GPU family (4 B Apple, 32 B Mac2).
fn drawUnifiedPending(
    encoder: objc.Object,
    ring: *UnifiedPrimitiveRing,
    pipelines: *const Pipelines,
    viewport_size: [2]f32,
    stats: ?*render_stats.RenderStats,
) void {
    assert(ring.primitive_count_drawn <= ring.primitive_count);
    const pending = ring.primitive_count - ring.primitive_count_drawn;
    if (pending == 0) return;
    // Primitives are only appended when the unified pipeline exists.
    const pipeline = pipelines.unified.?;
    assert(viewport_size[0] > 0);
    assert(viewport_size[1] > 0);

    encoder.msgSend(void, "setRenderPipelineState:", .{pipeline.value});
    encoder.msgSend(void, "setVertexBuffer:offset:atIndex:", .{
        pipelines.unit_vertex_buffer.value,
        @as(c_ulong, 0),
        @as(c_ulong, 0),
    });
    const offset_bytes = @as(usize, ring.primitive_count_drawn) * @sizeOf(unified.Primitive);
    assert(offset_bytes % 128 == 0);
    encoder.msgSend(void, "setVertexBuffer:offset:atIndex:", .{
        ring.buffers[ring.frame_index].value,
        @as(c_ulong, offset_bytes),
        @as(c_ulong, 1),
    });
    encoder.msgSend(void, "setVertexBytes:length:atIndex:", .{
        @as(*const anyopaque, @ptrCast(&viewport_size)),
        @as(c_ulong, @sizeOf([2]f32)),
        @as(c_ulong, 2),
    });
    encoder.msgSend(void, "drawPrimitives:vertexStart:vertexCount:instanceCount:", .{
        @backingInt(mtl.MTLPrimitiveType.triangle),
        @as(c_ulong, 0),
        @as(c_ulong, 6),
        @as(c_ulong, pending),
    });

    ring.primitive_count_drawn = ring.primitive_count;
    if (stats) |s| s.recordDrawCall();
}

/// Hot loop: scene quads to GPU primitives, written straight into the ring slot.
fn convertQuads(source: []const scene_mod.Quad, target: []unified.Primitive) void {
    assert(source.len == target.len);
    assert(source.len <= UnifiedPrimitiveRing.primitive_count_ceiling);
    for (source, target) |quad, *primitive| primitive.* = unified.Primitive.fromQuad(quad);
}

/// Hot loop: scene shadows to GPU primitives, written straight into the ring slot.
fn convertShadows(source: []const scene_mod.Shadow, target: []unified.Primitive) void {
    assert(source.len == target.len);
    assert(source.len <= UnifiedPrimitiveRing.primitive_count_ceiling);
    for (source, target) |shadow, *primitive| primitive.* = unified.Primitive.fromShadow(shadow);
}

/// Per-frame ring of shared `MTLBuffer`s holding unified primitives (quads and shadows),
/// following the same pattern as `TextPipeline` but with storage fixed at init.
///
/// Resource sketch (CLAUDE.md §7):
/// - Slot capacity: the app budget's `quad_count_frame_max + shadow_count_frame_max`
///   (`SceneLimits.unifiedPrimitiveCountMax`) primitives of 128 B, three slots, allocated
///   once in `init` and never grown. `ResourceLimits.standard` gives 8,704 primitives:
///   1.06 MiB per slot, 3.19 MiB total; the framework ceiling gives 25.5 MiB. The scene
///   is reserved from the same budget, so a frame's quads and shadows always fit.
/// - Per quad/shadow batch: one sequential n × 128 B conversion write into the slot. No
///   staging copy, no heap allocation, no `setVertexBytes` payload.
/// - Per run of consecutive quad/shadow batches: one pipeline bind, two buffer binds, one
///   8 B `setVertexBytes` and one instanced draw (`drawUnifiedPending`).
///
/// In-flight safety: slot `frame_index` is rewritten `frame_count` frames after it was last
/// used. Every frame that writes the ring first holds a drawable from the layer, and the
/// renderer asserts `maximumDrawableCount <= frame_count` at init. If the frame that last
/// used this slot were still executing, so would every later frame on the same in-order
/// command queue: `frame_count` frames each holding a drawable, leaving none for this frame.
pub const UnifiedPrimitiveRing = struct {
    buffers: [frame_count]objc.Object,
    /// CPU-visible `contents` of each buffer; stable for the buffer's lifetime.
    slots: [frame_count][*]unified.Primitive,
    frame_index: u32,
    /// Slot capacity in primitives, from the window's `ResourceLimits.scene`.
    primitive_count_max: u32,
    /// Primitives written into the current slot this frame.
    primitive_count: u32,
    /// Prefix of `primitive_count` already submitted by a draw call.
    primitive_count_drawn: u32,

    pub const frame_count: u32 = 3;
    /// Largest slot any valid budget can request.
    pub const primitive_count_ceiling: u32 =
        limits.MAX_QUADS_PER_FRAME + limits.MAX_SHADOWS_PER_FRAME;
    /// The CPU only ever writes whole primitives sequentially and never reads the slots
    /// back, which is the access pattern write-combined memory is for. Measured on an
    /// Apple Silicon Mac it cut conversion time about 13% versus the default cache mode.
    const buffer_options: mtl.MTLResourceOptions = .{
        .cpu_cache_mode = .write_combined,
        .storage_mode = .shared,
        .hazard_tracking_mode = .default,
    };

    const Self = @This();

    comptime {
        assert(@sizeOf(unified.Primitive) == 128);
        assert(primitive_count_ceiling >= limits.MAX_QUADS_PER_FRAME);
        assert(primitive_count_ceiling >= limits.MAX_SHADOWS_PER_FRAME);
        // Byte offsets into a slot stay well inside `c_ulong` and `u32` math.
        assert(@as(u64, primitive_count_ceiling) * @sizeOf(unified.Primitive) < 1 << 32);
    }

    /// Reserve three slots of `scene_limits.unifiedPrimitiveCountMax()` primitives.
    pub fn init(device: objc.Object, scene_limits: *const limits.SceneLimits) !Self {
        assert(scene_limits.check() == null);
        const primitive_count_max = scene_limits.unifiedPrimitiveCountMax();
        assert(primitive_count_max > 0);
        assert(primitive_count_max <= primitive_count_ceiling);
        const slot_size_bytes: usize =
            @as(usize, primitive_count_max) * @sizeOf(unified.Primitive);

        var self: Self = .{
            .buffers = undefined,
            .slots = undefined,
            .frame_index = 0,
            .primitive_count_max = primitive_count_max,
            .primitive_count = 0,
            .primitive_count_drawn = 0,
        };
        var created: u32 = 0;
        errdefer for (self.buffers[0..created]) |buffer| buffer.release();

        while (created < frame_count) : (created += 1) {
            // Fresh shared buffers are zero-filled, so unused ranges never hold stale bytes
            // from another owner; within a frame the GPU reads only the written prefix.
            const buffer_ptr = device.msgSend(?*anyopaque, "newBufferWithLength:options:", .{
                @as(c_ulong, slot_size_bytes),
                @as(c_ulong, @bitCast(buffer_options)),
            }) orelse return error.BufferCreationFailed;
            const buffer = objc.Object.fromId(buffer_ptr);
            assert(buffer.msgSend(c_ulong, "length", .{}) == slot_size_bytes);

            const contents = buffer.msgSend(*anyopaque, "contents", .{});
            assert(@intFromPtr(contents) % @alignOf(unified.Primitive) == 0);
            self.buffers[created] = buffer;
            self.slots[created] = @ptrCast(@alignCast(contents));
        }
        assert(created == frame_count);
        return self;
    }

    pub fn deinit(self: *Self) void {
        for (self.buffers) |buffer| buffer.release();
        self.* = undefined;
    }

    /// Advance to the next slot. Call once per rendered frame, before any batch is drawn.
    pub fn nextFrame(self: *Self) void {
        assert(self.frame_index < frame_count);
        // The previous frame drew everything it wrote.
        assert(self.primitive_count_drawn == self.primitive_count);
        self.frame_index = (self.frame_index + 1) % frame_count;
        self.primitive_count = 0;
        self.primitive_count_drawn = 0;
    }

    /// Reserve `count` primitives after the current slot's used range.
    /// Exhaustion means the scene's budget and this ring's disagree (both come from
    /// the same `ResourceLimits`): a programmer error.
    fn claim(self: *Self, count: usize, operation: []const u8) []unified.Primitive {
        assert(count > 0);
        assert(self.primitive_count <= self.primitive_count_max);
        const available: usize = self.primitive_count_max - self.primitive_count;
        if (available < count) {
            std.debug.panic(
                "UnifiedPrimitiveRing exhausted: capacity {d} primitives per frame " ++
                    "(ResourceLimits.scene quads + shadows), " ++
                    "{d} used, {d} requested by {s} batch, frame slot {d}",
                .{
                    self.primitive_count_max,
                    self.primitive_count,
                    count,
                    operation,
                    self.frame_index,
                },
            );
        }
        const first = self.primitive_count;
        self.primitive_count += @intCast(count);
        assert(self.primitive_count <= self.primitive_count_max);
        return self.slots[self.frame_index][first..self.primitive_count];
    }
};
