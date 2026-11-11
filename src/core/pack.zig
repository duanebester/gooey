//! Pack: paint records to the packed frame every renderer draws (contract
//! §8 and §9).
//!
//! One pass over the records in draw order. Each record appends one instance
//! to its kind's array and extends the last draw when the pipeline and clip
//! are unchanged, so consecutive records of one pipeline become one draw.
//! Clip pushes and pops resolve to one clip rectangle per draw: a push appends
//! its intersection with the current clip, a pop returns to the parent's.
//!
//! Three decisions are made here once for every backend:
//!
//! - Culling: a quad wholly outside its clip is dropped, as the 0.3.1 scene
//!   dropped it, and so is a shadow whose drawn extent (its bounds moved by
//!   its offset and grown by twice its blur on every side) is. Nothing else
//!   is culled.
//! - Empty clips: while the current clip has zero width or height, no
//!   instance is packed, so no draw carries an empty clip. Under the
//!   inclusive-edge rule a zero-size rectangle would still pass the pixel
//!   centres on its edge.
//! - Triangle edges: every triangle edge is classified over the whole frame
//!   (`mesh_edges.zig`) and its modes written to `edge_modes`, so backends
//!   anti-alias shared edges identically without a pass of their own.
//!
//! Performance sketch (CLAUDE.md §7): one sequential read of at most
//! `records.paint_record_count_frame_max` records and one sequential write of
//! one 96 B or 32 B instance each, plus at most one 16 B draw and one 16 B
//! clip. Triangle meshes add three hashed edge inserts per triangle during the
//! pass and three lookups per triangle after it. Nothing allocates; the
//! `.standard` worst case writes about 2.4 MB, typical frames a few KiB.

const std = @import("std");
const records = @import("records.zig");
const packed_mod = @import("packed_frame.zig");
const limits_mod = @import("limits.zig");
const debugger = @import("debugger.zig");
const mesh_edges = @import("../platform/mesh_edges.zig");

const assert = std.debug.assert;

const PackedFrame = packed_mod.PackedFrame;
const Pipeline = packed_mod.Pipeline;
const Pool = packed_mod.Pool;
const Rect = packed_mod.Rect;

pub fn pack(frame: *const records.Frame, packed_frame: *PackedFrame) void {
    assert(frame.paint_count <= frame.paint.len);
    assert(frame.mesh_point_count <= frame.mesh_points.len);
    packed_frame.reset(frame.frame_number, frame.mesh_points[0..frame.mesh_point_count]);
    const triangle_points = frame.mesh_point_counts[@backingInt(records.Mesh.Topology.triangles)];
    // One edge per triangle point: three edges per triangle.
    packed_frame.edge_table.begin(triangle_points);
    var packer = Packer{ .target = packed_frame, .clip_stack = undefined, .clip_depth = 0 };
    // A safe build reserves the debugger overlay's headroom; the app's own
    // records are checked against its declared limits first.
    const app_paint_count = debugger.appPaintCount(frame);
    packer.packRecords(frame.paint[0..app_paint_count]);
    debugger.checkAppPacked(packed_frame);
    packer.packRecords(frame.paint[app_paint_count..frame.paint_count]);
    writeEdgeModes(packed_frame);
    // Meshes under an empty clip are not packed, so not every point is used.
    assert(packed_frame.triangle_count * 3 <= triangle_points);
}

const Packer = struct {
    target: *PackedFrame,
    /// Indices into `target.clips` of the pushed clips, innermost last.
    clip_stack: [limits_mod.MAX_CLIP_STACK_DEPTH]u32,
    clip_depth: u32,

    /// Every fragment, and the overlay, pops each clip it pushes, so a run of
    /// records leaves the clip stack as it found it.
    fn packRecords(self: *Packer, paint: []const records.Record) void {
        assert(self.clip_depth <= self.clip_stack.len);
        const depth_start = self.clip_depth;
        for (paint) |*record| {
            switch (record.*) {
                .clip_push => |bounds| self.pushClip(bounds),
                .clip_pop => self.popClip(),
                .quad, .sprite, .mesh => if (!self.currentClipEmpty()) switch (record.*) {
                    .quad => |*quad| self.packQuad(quad),
                    .sprite => |*sprite| self.packSprite(sprite),
                    .mesh => |*mesh| self.packMesh(mesh),
                    .clip_push, .clip_pop => unreachable,
                },
            }
        }
        assert(self.clip_depth == depth_start);
    }

    fn currentClip(self: *const Packer) u32 {
        assert(self.clip_depth <= self.clip_stack.len);
        if (self.clip_depth == 0) return packed_mod.clip_none;
        const clip = self.clip_stack[self.clip_depth - 1];
        assert(clip < self.target.clip_count);
        return clip;
    }

    /// A clip with zero width or height writes nothing (contract §9).
    fn currentClipEmpty(self: *const Packer) bool {
        const clip = self.target.clips[self.currentClip()];
        assert(clip[2] >= 0);
        assert(clip[3] >= 0);
        return clip[2] == 0 or clip[3] == 0;
    }

    fn pushClip(self: *Packer, bounds: records.Rect) void {
        const target = self.target;
        assert(bounds.width >= 0);
        assert(bounds.height >= 0);
        assert(self.clip_depth <= target.limits.clip_depth_max);
        if (self.clip_depth == target.limits.clip_depth_max) {
            std.debug.panic("Packed clip stack exhausted: capacity {d} " ++
                "(ResourceLimits.scene.clip_depth_max), {d} in use, 1 requested, frame {d}. " ++
                "Raise the app's ResourceLimits.", .{
                target.limits.clip_depth_max,
                self.clip_depth,
                target.frame_number,
            });
        }
        if (target.clip_count == target.clips.len) failRecordPool(target, "clips", 1);
        const parent = target.clips[self.currentClip()];
        target.clips[target.clip_count] = intersect(parent, .{
            bounds.x,
            bounds.y,
            bounds.width,
            bounds.height,
        });
        self.clip_stack[self.clip_depth] = target.clip_count;
        self.clip_depth += 1;
        target.clip_count += 1;
    }

    fn popClip(self: *Packer) void {
        assert(self.clip_depth > 0);
        assert(self.clip_stack[self.clip_depth - 1] < self.target.clip_count);
        self.clip_depth -= 1;
    }

    fn packQuad(self: *Packer, quad: *const records.Quad) void {
        const target = self.target;
        assert(quad.blur >= 0);
        assert(quad.border.width >= 0);
        const bounds = quad.bounds;
        if (outside(drawnExtent(quad), target.clips[self.currentClip()])) return;
        claim(target, if (quad.blur > 0) .shadows else .quads);
        const width = quad.border.width;
        const radii = quad.corners;
        target.quads[target.quad_count] = .{
            .bounds = .{ bounds.x, bounds.y, bounds.width, bounds.height },
            .fill = rgba(quad.fill),
            .border_color = rgba(quad.border.color),
            .corners = .{ radii.top_left, radii.top_right, radii.bottom_right, radii.bottom_left },
            .border_widths = .{ width, width, width, width },
            .offset = .{ quad.offset_x, quad.offset_y },
            .blur = quad.blur,
        };
        self.appendDraw(.quad, target.quad_count);
        target.quad_count += 1;
    }

    fn packSprite(self: *Packer, sprite: *const records.Sprite) void {
        const target = self.target;
        const pipeline: Pipeline, const pool: Pool = switch (sprite.atlas) {
            .glyph => .{ .glyph, .glyphs },
            .svg => .{ .svg, .svgs },
            .image => .{ .image, .images },
            .glyph_color => std.debug.panic("{t} sprites are not emitted yet (frame {d})", .{
                sprite.atlas,
                target.frame_number,
            }),
        };
        claim(target, pool);
        const bounds = sprite.bounds;
        const uv = sprite.uv;
        const radii = sprite.corners;
        assert(uv.x >= 0);
        assert(uv.x + uv.width <= 1);
        assert(uv.y >= 0);
        assert(uv.y + uv.height <= 1);
        target.sprites[target.sprite_count] = .{
            .bounds = .{ bounds.x, bounds.y, bounds.width, bounds.height },
            .uv = .{ uv.x, uv.y, uv.x + uv.width, uv.y + uv.height },
            .tint = rgba(sprite.tint),
            .secondary = rgba(sprite.secondary),
            .corners = .{ radii.top_left, radii.top_right, radii.bottom_right, radii.bottom_left },
            .grayscale = sprite.grayscale,
            .opacity = sprite.opacity,
        };
        self.appendDraw(pipeline, target.sprite_count);
        target.sprite_count += 1;
    }

    fn packMesh(self: *Packer, mesh: *const records.Mesh) void {
        const target = self.target;
        assert(mesh.range.count > 0);
        assert(mesh.range.first + mesh.range.count <= target.mesh_points.len);
        const pipeline: Pipeline, const pool: Pool = switch (mesh.topology) {
            .triangles => .{ .triangles, .triangle_meshes },
            .strip_expanded => .{ .strip_expanded, .polylines },
            .point_instanced => .{ .point_instanced, .point_clouds },
        };
        claim(target, pool);
        var edge_first: u32 = 0;
        if (mesh.topology == .triangles) {
            assert(mesh.range.count % 3 == 0);
            edge_first = target.triangle_count;
            target.triangle_count += @divExact(mesh.range.count, 3);
            assert(target.triangle_count <= target.edge_modes.len);
            const path_index = target.counts[@backingInt(Pool.triangle_meshes)] - 1;
            const fill = fillHash(mesh.fill, target.clips[self.currentClip()]);
            insertEdges(target, mesh.range, @intCast(path_index), fill);
        }
        target.meshes[target.mesh_count] = .{
            .fill = rgba(mesh.fill),
            .first = mesh.range.first,
            .count = mesh.range.count,
            .width = mesh.width,
            .edge_first = edge_first,
        };
        self.appendDraw(pipeline, target.mesh_count);
        target.mesh_count += 1;
    }

    /// Extend the last draw with instance `first` when it has the same
    /// pipeline and clip, or start a draw. Instances of one kind append in
    /// order, so an extended draw stays contiguous.
    fn appendDraw(self: *Packer, pipeline: Pipeline, first: u32) void {
        const target = self.target;
        const clip = self.currentClip();
        assert(!self.currentClipEmpty());
        assert(target.draw_count <= target.draws.len);
        if (target.draw_count > 0) {
            const last = &target.draws[target.draw_count - 1];
            if (last.pipeline == pipeline and last.clip == clip) {
                assert(last.first + last.count == first);
                last.count += 1;
                return;
            }
        }
        if (target.draw_count == target.draws.len) failRecordPool(target, "draws", 0);
        target.draws[target.draw_count] = .{
            .pipeline = pipeline,
            .clip = clip,
            .first = first,
            .count = 1,
        };
        target.draw_count += 1;
    }
};

/// Count one instance of `pool` against the window's limit for it.
fn claim(target: *PackedFrame, pool: Pool) void {
    assert(target.draw_count <= target.draws.len);
    const capacity = pool.capacity(&target.limits);
    const used = &target.counts[@backingInt(pool)];
    assert(used.* <= capacity);
    if (used.* == capacity) {
        @branchHint(.cold);
        std.debug.panic("Packed pool '{t}' exhausted: capacity {d} " ++
            "(ResourceLimits.scene.{s}), {d} in use, 1 requested, frame {d}. " ++
            "Raise the app's ResourceLimits.", .{
            pool,
            capacity,
            pool.limitName(),
            capacity,
            target.frame_number,
        });
    }
    used.* += 1;
}

/// Draws and clips are bounded by the paint record budget the frame was
/// reserved for: each record starts at most one draw, and each push one clip
/// (plus the unbounded clip). A frame past it was packed into storage
/// reserved for a smaller budget than its records frame's.
fn failRecordPool(target: *const PackedFrame, pool: []const u8, reserved: u32) noreturn {
    @branchHint(.cold);
    assert(pool.len > 0);
    assert(reserved <= 1);
    const capacity = if (std.mem.eql(u8, pool, "draws")) target.draws.len else target.clips.len;
    std.debug.panic("Packed pool '{s}' exhausted: capacity {d} " ++
        "(ResourceLimits.records.paint_record_count_frame_max + {d}), {d} in use, " ++
        "1 requested, frame {d}. Pack the frame into storage reserved for its records.", .{
        pool,
        capacity,
        reserved,
        capacity,
        target.frame_number,
    });
}

/// Straight RGBA as the theme wrote it, each channel in 0..1.
fn rgba(color: records.Color) packed_mod.Rgba {
    assert(color.a >= 0);
    assert(color.a <= 1);
    return .{ color.r, color.g, color.b, color.a };
}

/// The overlap of two clips, empty (zero-sized) when they do not meet. The
/// 0.3.1 scene's rule, so clip rectangles and culling are unchanged.
fn intersect(a: Rect, b: Rect) Rect {
    assert(a[2] >= 0);
    assert(a[3] >= 0);
    assert(b[2] >= 0);
    assert(b[3] >= 0);
    const x = @max(a[0], b[0]);
    const y = @max(a[1], b[1]);
    const right = @min(a[0] + a[2], b[0] + b[2]);
    const bottom = @min(a[1] + a[3], b[1] + b[3]);
    return .{ x, y, @max(0, right - x), @max(0, bottom - y) };
}

/// What a quad draws into: its bounds, or for a shadow its bounds moved by
/// the offset and grown by twice the blur on every side, the extent the
/// shadow shaders rasterize.
fn drawnExtent(quad: *const records.Quad) records.Rect {
    assert(quad.blur >= 0);
    assert(quad.bounds.width >= 0);
    if (quad.blur == 0) return quad.bounds;
    const grow = 2 * quad.blur;
    return .{
        .x = quad.bounds.x + quad.offset_x - grow,
        .y = quad.bounds.y + quad.offset_y - grow,
        .width = quad.bounds.width + 2 * grow,
        .height = quad.bounds.height + 2 * grow,
    };
}

/// `bounds` wholly outside `clip`; bounds touching its edge are kept.
fn outside(bounds: records.Rect, clip: Rect) bool {
    assert(bounds.width >= 0);
    assert(bounds.height >= 0);
    assert(clip[2] >= 0);
    assert(clip[3] >= 0);
    if (bounds.x + bounds.width < clip[0]) return true;
    if (bounds.x > clip[0] + clip[2]) return true;
    if (bounds.y + bounds.height < clip[1]) return true;
    return bounds.y > clip[1] + clip[3];
}

/// Everything that decides a mesh's colour across a shared edge: its fill and
/// its clip. Two meshes with equal hashes blend identically there.
fn fillHash(fill: records.Color, clip: Rect) u32 {
    assert(clip[2] > 0);
    assert(clip[3] > 0);
    const key = [8]f32{ fill.r, fill.g, fill.b, fill.a, clip[0], clip[1], clip[2], clip[3] };
    return @truncate(std.hash.Wyhash.hash(0, std.mem.asBytes(&key)));
}

fn triangleCorners(points: []const packed_mod.MeshPoint) [3][2]f32 {
    assert(points.len == 3);
    assert(std.math.isFinite(points[0].x));
    return .{
        .{ points[0].x, points[0].y },
        .{ points[1].x, points[1].y },
        .{ points[2].x, points[2].y },
    };
}

/// Record a triangle mesh's edges, in draw order, before any mode is read.
fn insertEdges(
    target: *PackedFrame,
    range: records.MeshRange,
    path_index: mesh_edges.PathIndex,
    fill: u32,
) void {
    assert(range.first + range.count <= target.mesh_points.len);
    const points = target.mesh_points[range.first..][0..range.count];
    assert(points.len % 3 == 0);
    var triangle: usize = 0;
    while (triangle < points.len) : (triangle += 3) {
        const corners = triangleCorners(points[triangle..][0..3]);
        for (0..3) |edge| {
            const key = mesh_edges.edgeKey(corners[edge], corners[(edge + 1) % 3]);
            target.edge_table.insert(key, path_index, fill);
        }
    }
}

/// After every edge is inserted: each triangle's modes, in draw order.
fn writeEdgeModes(target: *PackedFrame) void {
    assert(target.triangle_count <= target.edge_modes.len);
    var path_index: u32 = 0;
    for (target.drawList()) |*draw| {
        if (draw.pipeline != .triangles) continue;
        for (target.drawRange(draw, .mesh)) |*mesh| {
            writeMeshEdgeModes(target, mesh, @intCast(path_index));
            path_index += 1;
        }
    }
    assert(path_index == target.counts[@backingInt(Pool.triangle_meshes)]);
}

fn writeMeshEdgeModes(
    target: *PackedFrame,
    mesh: *const packed_mod.Mesh,
    path_index: mesh_edges.PathIndex,
) void {
    const points = target.meshPoints(mesh);
    const triangle_count = @divExact(mesh.count, 3);
    assert(mesh.edge_first + triangle_count <= target.triangle_count);
    for (target.edge_modes[mesh.edge_first..][0..triangle_count], 0..) |*modes, triangle| {
        const corners = triangleCorners(points[triangle * 3 ..][0..3]);
        var value: u32 = 0;
        for (0..3) |edge| {
            const key = mesh_edges.edgeKey(corners[edge], corners[(edge + 1) % 3]);
            const mode = target.edge_table.mode(key, path_index);
            value |= @as(u32, @backingInt(mode)) << @intCast(2 * edge);
        }
        assert(value < 64);
        modes.* = value;
    }
}

test "pack resolves clips into draws, culls, and classifies shared triangle edges" {
    // Goal: the rules backends rely on. Method: pack a hand-built frame with
    // nested clips, a culled quad, two shadows whose bounds lie outside their
    // clip (one reaching into it by its offset and blur, one not), and three
    // triangle meshes, two of one fill sharing an edge and one of another fill
    // sharing an edge with the second, then read the draws, clips, and edge
    // modes back.
    const testing = std.testing;
    var frame: records.Frame = undefined;
    try frame.initInPlace(testing.allocator, &.{
        .paint_record_count_max = 32,
        .hit_record_count_max = 1,
        .handler_count_max = 1,
        .a11y_node_count_max = 1,
        .text_bytes_max = 1,
        .mesh_point_count_max = 9,
    });
    defer frame.deinit(testing.allocator);
    frame.reset(1, .{ .width = 200, .height = 200, .scale_factor = 1 });
    const red = records.Color{ .r = 1, .g = 0, .b = 0, .a = 1 };
    const blue = records.Color{ .r = 0, .g = 0, .b = 1, .a = 1 };
    frame.appendPaint(.{ .quad = testQuad(0, 0, 0) });
    frame.appendPaint(.{ .clip_push = .{ .x = 10, .y = 10, .width = 100, .height = 100 } });
    frame.appendPaint(.{ .quad = testQuad(20, 20, 0) });
    frame.appendPaint(.{ .quad = testQuad(150, 150, 0) }); // Wholly outside: culled.
    // Bounds start at x 120, past the clip's right edge at 110, but the blur
    // grows the drawn extent 12 px left, to 108: kept.
    frame.appendPaint(.{ .quad = testQuad(120, 20, 6) });
    // Drawn extent from 142: wholly outside, culled.
    frame.appendPaint(.{ .quad = testQuad(150, 150, 4) });
    frame.appendPaint(.{ .clip_push = .{ .x = 50, .y = 50, .width = 100, .height = 100 } });
    frame.appendPaint(.{ .quad = testQuad(60, 60, 0) });
    frame.appendPaint(.clip_pop);
    frame.appendPaint(.{ .quad = testQuad(30, 30, 0) });
    frame.appendPaint(.clip_pop);
    const square = [_][2]f32{
        .{ 0, 0 },  .{ 10, 0 },  .{ 0, 10 },
        .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 },
    };
    appendTriangles(&frame, square[0..3], red);
    appendTriangles(&frame, square[3..6], red);
    appendTriangles(&frame, &.{ .{ 10, 0 }, .{ 10, 10 }, .{ 20, 5 } }, blue);

    var target: PackedFrame = undefined;
    try target.initInPlace(&.{
        .scene = limits_mod.SceneLimits.nano,
        .paint_record_count_max = 32,
    });
    defer target.deinit();
    pack(&frame, &target);

    const draws = target.drawList();
    try testing.expectEqual(@as(usize, 5), draws.len);
    try testing.expectEqual(@as(u32, packed_mod.clip_none), draws[0].clip);
    // Inside the first clip: the kept quad and the shadow; one draw.
    try testing.expectEqual(@as(u32, 1), draws[1].clip);
    try testing.expectEqual(@as(u32, 2), draws[1].count);
    try testing.expectEqual(@as(f32, 6), target.quads[draws[1].first + 1].blur);
    // The nested clip is the intersection; popping returns to its parent.
    try testing.expectEqual(@as(u32, 2), draws[2].clip);
    try testing.expectEqualSlices(f32, &.{ 50, 50, 60, 60 }, &target.clips[2]);
    try testing.expectEqual(@as(u32, 1), draws[3].clip);
    try testing.expectEqual(Pipeline.triangles, draws[4].pipeline);
    try testing.expectEqual(@as(u32, 3), draws[4].count);
    try testing.expectEqual(@as(u32, 4), target.counts[@backingInt(Pool.quads)]);
    try testing.expectEqual(@as(u32, 1), target.counts[@backingInt(Pool.shadows)]);

    // Edges in order v0→v1, v1→v2, v2→v0, two bits each: 0 interior,
    // 1 fade, 2 underlap. The diagonal (10,0)-(0,10) joins two red
    // triangles: interior in both. The edge (10,0)-(10,10) is shared with the
    // later blue triangle: the earlier red one underlaps, the blue one fades.
    const modes = target.edgeModeList();
    try testing.expectEqual(@as(usize, 3), modes.len);
    try testing.expectEqual(@as(u32, 1 | 0 << 2 | 1 << 4), modes[0]);
    try testing.expectEqual(@as(u32, 2 | 1 << 2 | 0 << 4), modes[1]);
    try testing.expectEqual(@as(u32, 1 | 1 << 2 | 1 << 4), modes[2]);
}

test "pack skips every instance under a clip with zero area" {
    // Goal: a child scrolled out of its viewport draws nothing. Its clip
    // intersects to zero width, and under the inclusive-edge rule a draw with
    // that clip would still write the pixel centres on its edge. Method: a
    // quad touching the empty clip's edge (kept by `outside` alone), a glyph,
    // a nested push, and a triangle mesh all sit under the empty clip; only
    // the quad after the pops is packed.
    const testing = std.testing;
    var frame: records.Frame = undefined;
    try frame.initInPlace(testing.allocator, &testFrameCapacity(16, 3));
    defer frame.deinit(testing.allocator);
    frame.reset(1, .{ .width = 300, .height = 300, .scale_factor = 1 });
    frame.appendPaint(.{ .clip_push = .{ .x = 0, .y = 0, .width = 100, .height = 100 } });
    frame.appendPaint(.{ .clip_push = .{ .x = 200, .y = 0, .width = 50, .height = 50 } });
    frame.appendPaint(.{ .quad = testQuad(195, 10, 0) });
    frame.appendPaint(.{ .sprite = testGlyph(200, 10) });
    frame.appendPaint(.{ .clip_push = .{ .x = 200, .y = 0, .width = 10, .height = 10 } });
    appendTriangles(&frame, &.{ .{ 200, 0 }, .{ 210, 0 }, .{ 200, 10 } }, .{
        .r = 1,
        .g = 0,
        .b = 0,
        .a = 1,
    });
    frame.appendPaint(.clip_pop);
    frame.appendPaint(.clip_pop);
    frame.appendPaint(.clip_pop);
    frame.appendPaint(.{ .quad = testQuad(20, 20, 0) });

    var target: PackedFrame = undefined;
    try target.initInPlace(&.{
        .scene = limits_mod.SceneLimits.nano,
        .paint_record_count_max = 16,
    });
    defer target.deinit();
    pack(&frame, &target);

    try testing.expectEqual(@as(usize, 1), target.drawList().len);
    try testing.expectEqual(@as(u32, packed_mod.clip_none), target.draws[0].clip);
    try testing.expectEqualSlices(f32, &.{ 20, 20, 10, 10 }, &target.quads[0].bounds);
    try testing.expectEqual(@as(u32, 0), target.sprite_count);
    try testing.expectEqual(@as(u32, 0), target.triangle_count);
    // The pushes still resolve, so later clips keep their indices.
    try testing.expectEqual(@as(u32, 4), target.clip_count);
    try testing.expectEqual(@as(f32, 0), target.clips[2][2]);
}

test "pack starts a draw at every pipeline change within one clip" {
    // Goal: draw order is record order across pipelines. Method: quad,
    // glyph, quad under one clip must make three draws, not one quad draw of
    // two and a glyph draw, which would paint the second quad under the glyph.
    const testing = std.testing;
    var frame: records.Frame = undefined;
    try frame.initInPlace(testing.allocator, &testFrameCapacity(8, 0));
    defer frame.deinit(testing.allocator);
    frame.reset(1, .{ .width = 200, .height = 200, .scale_factor = 1 });
    frame.appendPaint(.{ .clip_push = .{ .x = 0, .y = 0, .width = 100, .height = 100 } });
    frame.appendPaint(.{ .quad = testQuad(10, 10, 0) });
    frame.appendPaint(.{ .sprite = testGlyph(12, 12) });
    frame.appendPaint(.{ .quad = testQuad(14, 14, 0) });
    frame.appendPaint(.clip_pop);

    var target: PackedFrame = undefined;
    try target.initInPlace(&.{
        .scene = limits_mod.SceneLimits.nano,
        .paint_record_count_max = 8,
    });
    defer target.deinit();
    pack(&frame, &target);

    const draws = target.drawList();
    try testing.expectEqual(@as(usize, 3), draws.len);
    const expected = [_]struct { Pipeline, u32 }{ .{ .quad, 0 }, .{ .glyph, 0 }, .{ .quad, 1 } };
    for (draws, expected) |draw, want| {
        try testing.expectEqual(want[0], draw.pipeline);
        try testing.expectEqual(want[1], draw.first);
        try testing.expectEqual(@as(u32, 1), draw.count);
        try testing.expectEqual(@as(u32, 1), draw.clip);
    }
}

test "pack fills its draws and clips exactly at the paint record budget" {
    // Goal: the boundary of the draw and clip pools (CLAUDE.md §24). Method:
    // at a budget of 8 records, 8 records alternating quad and glyph make 8
    // draws, and 8 push/pop pairs make 9 clips with the unbounded one; both
    // pools are then full and their last entry is the last record's. One
    // more record panics, naming the pool (`fail_fast_check`
    // `core-pack-draws` and `core-pack-clips`).
    const testing = std.testing;
    const record_count_max: u32 = 8;
    var frame: records.Frame = undefined;
    try frame.initInPlace(testing.allocator, &testFrameCapacity(2 * record_count_max, 0));
    defer frame.deinit(testing.allocator);
    var target: PackedFrame = undefined;
    try target.initInPlace(&.{
        .scene = limits_mod.SceneLimits.nano,
        .paint_record_count_max = record_count_max,
    });
    defer target.deinit();

    frame.reset(1, .{ .width = 200, .height = 200, .scale_factor = 1 });
    for (0..record_count_max) |index| {
        const offset: f32 = @floatFromInt(index);
        if (index % 2 == 0) {
            frame.appendPaint(.{ .quad = testQuad(offset, 0, 0) });
        } else {
            frame.appendPaint(.{ .sprite = testGlyph(offset, 0) });
        }
    }
    pack(&frame, &target);
    try testing.expectEqual(target.draws.len, target.drawList().len);
    try testing.expectEqual(Pipeline.glyph, target.draws[record_count_max - 1].pipeline);
    try testing.expectEqual(@as(u32, 3), target.draws[record_count_max - 1].first);

    frame.reset(2, .{ .width = 200, .height = 200, .scale_factor = 1 });
    for (0..record_count_max) |index| {
        const offset: f32 = @floatFromInt(index);
        frame.appendPaint(.{ .clip_push = .{ .x = offset, .y = 0, .width = 50, .height = 50 } });
        frame.appendPaint(.clip_pop);
    }
    pack(&frame, &target);
    try testing.expectEqual(target.clips.len, target.clipList().len);
    try testing.expectEqualSlices(f32, &.{ 7, 0, 50, 50 }, &target.clips[record_count_max]);
}

fn testFrameCapacity(paint_record_count_max: u32, mesh_point_count_max: u32) records.FrameCapacity {
    return .{
        .paint_record_count_max = paint_record_count_max,
        .hit_record_count_max = 1,
        .handler_count_max = 1,
        .a11y_node_count_max = 1,
        .text_bytes_max = 1,
        .mesh_point_count_max = mesh_point_count_max,
    };
}

fn testGlyph(x: f32, y: f32) records.Sprite {
    return .{
        .bounds = .{ .x = x, .y = y, .width = 8, .height = 8 },
        .atlas = .glyph,
        .uv = .{ .x = 0, .y = 0, .width = 0.5, .height = 0.5 },
        .tint = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
        .secondary = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .corners = .zero,
        .grayscale = 0,
        .opacity = 1,
    };
}

fn testQuad(x: f32, y: f32, blur: f32) records.Quad {
    return .{
        .bounds = .{ .x = x, .y = y, .width = 10, .height = 10 },
        .fill = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
        .border = .none,
        .corners = .zero,
        .blur = blur,
    };
}

fn appendTriangles(frame: *records.Frame, points: []const [2]f32, fill: records.Color) void {
    const range = frame.claimMeshPoints(@intCast(points.len));
    for (frame.meshPoints(range), points) |*point, source| {
        point.* = .{ .x = source[0], .y = source[1] };
    }
    frame.mesh_point_counts[@backingInt(records.Mesh.Topology.triangles)] += range.count;
    frame.appendPaint(.{ .mesh = .{
        .range = range,
        .topology = .triangles,
        .fill = fill,
        .width = 0,
    } });
}
