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
    assert(frame.params_stride == packed_frame.params_stride or frame.params_count == 0);
    packed_frame.params = frame.paramsUsed();
    packed_frame.shader_time_s = frame.shader_time_s;
    const triangle_points = frame.mesh_point_counts[@backingInt(records.Mesh.Topology.triangles)];
    packed_frame.edge_table.begin(triangle_points);
    var packer = Packer{ .target = packed_frame, .clip_stack = undefined, .clip_depth = 0 };
    const app_paint_count = debugger.appPaintCount(frame);
    packer.packRecords(frame.paint[0..app_paint_count]);
    debugger.checkAppPacked(packed_frame);
    packer.packRecords(frame.paint[app_paint_count..frame.paint_count]);
    writeEdgeModes(packed_frame);
    assert(packed_frame.triangle_count * 3 <= triangle_points);
}

const Packer = struct {
    target: *PackedFrame,
    clip_stack: [limits_mod.MAX_CLIP_STACK_DEPTH]u32,
    clip_depth: u32,

    fn packRecords(self: *Packer, paint: []const records.Record) void {
        assert(self.clip_depth <= self.clip_stack.len);
        const depth_start = self.clip_depth;
        for (paint) |*record| {
            switch (record.*) {
                .clip_push => |bounds| self.pushClip(bounds),
                .clip_pop => self.popClip(),
                .quad, .sprite, .mesh, .custom => if (!self.currentClipEmpty()) switch (record.*) {
                    .quad => |*quad| self.packQuad(quad),
                    .sprite => |*sprite| self.packSprite(sprite),
                    .mesh => |*mesh| self.packMesh(mesh),
                    .custom => |*custom| self.packCustom(custom),
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
                "(ResourceLimits.paint.clip_depth_max), {d} in use, 1 requested, frame {d}. " ++
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
        self.appendDraw(.quad, 0, target.quad_count);
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
        self.appendDraw(pipeline, 0, target.sprite_count);
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
        self.appendDraw(pipeline, 0, target.mesh_count);
        target.mesh_count += 1;
    }

    fn packCustom(self: *Packer, custom: *const records.Custom) void {
        const target = self.target;
        assert(custom.opacity >= 0);
        assert(custom.opacity <= 1);
        assert(custom.shader < target.limits.shader_count_max);
        assert((@as(u64, custom.params_slot) + 1) * target.params_stride <= target.params.len);
        if (outside(custom.bounds, target.clips[self.currentClip()])) return;
        if (custom.opacity == 0) return;
        claim(target, .customs);
        const bounds = custom.bounds;
        const radii = custom.corners;
        target.customs[target.custom_count] = .{
            .bounds = .{ bounds.x, bounds.y, bounds.width, bounds.height },
            .corners = .{ radii.top_left, radii.top_right, radii.bottom_right, radii.bottom_left },
            .opacity = custom.opacity,
            .params_index = custom.params_slot,
        };
        self.appendDraw(.custom, custom.shader, target.custom_count);
        target.custom_count += 1;
    }

    fn appendDraw(self: *Packer, pipeline: Pipeline, shader: u8, first: u32) void {
        const target = self.target;
        const clip = self.currentClip();
        assert(!self.currentClipEmpty());
        assert(target.draw_count <= target.draws.len);
        if (pipeline != .custom) assert(shader == 0);
        if (target.draw_count > 0) {
            const last = &target.draws[target.draw_count - 1];
            if (last.pipeline == pipeline and last.shader == shader and last.clip == clip) {
                assert(last.first + last.count == first);
                last.count += 1;
                return;
            }
        }
        if (target.draw_count == target.draws.len) failRecordPool(target, "draws", 0);
        target.draws[target.draw_count] = .{
            .pipeline = pipeline,
            .shader = shader,
            .clip = clip,
            .first = first,
            .count = 1,
        };
        target.draw_count += 1;
    }
};

fn claim(target: *PackedFrame, pool: Pool) void {
    assert(target.draw_count <= target.draws.len);
    const capacity = pool.capacity(&target.limits);
    const used = &target.counts[@backingInt(pool)];
    assert(used.* <= capacity);
    if (used.* == capacity) {
        @branchHint(.cold);
        std.debug.panic("Packed pool '{t}' exhausted: capacity {d} " ++
            "(ResourceLimits.paint.{s}), {d} in use, 1 requested, frame {d}. " ++
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

fn rgba(color: records.Color) packed_mod.Rgba {
    assert(color.a >= 0);
    assert(color.a <= 1);
    return .{ color.r, color.g, color.b, color.a };
}

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
    const testing = std.testing;
    var frame: records.Frame = undefined;
    try frame.initInPlace(testing.allocator, &.{
        .paint_record_count_max = 32,
        .hit_record_count_max = 1,
        .handler_count_max = 1,
        .a11y_node_count_max = 1,
        .announcements = .{ .polite_pending_max = 1, .message_bytes_max = 1 },
        .text_bytes_max = 1,
        .mesh_point_count_max = 9,
        .params_slot_count_max = 0,
        .params_stride = 0,
    });
    defer frame.deinit(testing.allocator);
    frame.reset(1, .{ .width = 200, .height = 200, .scale_factor = 1 });
    const red = records.Color{ .r = 1, .g = 0, .b = 0, .a = 1 };
    const blue = records.Color{ .r = 0, .g = 0, .b = 1, .a = 1 };
    frame.appendPaint(.{ .quad = testQuad(0, 0, 0) });
    frame.appendPaint(.{ .clip_push = .{ .x = 10, .y = 10, .width = 100, .height = 100 } });
    frame.appendPaint(.{ .quad = testQuad(20, 20, 0) });
    frame.appendPaint(.{ .quad = testQuad(150, 150, 0) });
    frame.appendPaint(.{ .quad = testQuad(120, 20, 6) });
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
        .paint = limits_mod.PaintLimits.nano,
        .paint_record_count_max = 32,
    });
    defer target.deinit();
    pack(&frame, &target);

    const draws = target.drawList();
    try testing.expectEqual(@as(usize, 5), draws.len);
    try testing.expectEqual(@as(u32, packed_mod.clip_none), draws[0].clip);
    try testing.expectEqual(@as(u32, 1), draws[1].clip);
    try testing.expectEqual(@as(u32, 2), draws[1].count);
    try testing.expectEqual(@as(f32, 6), target.quads[draws[1].first + 1].blur);
    try testing.expectEqual(@as(u32, 2), draws[2].clip);
    try testing.expectEqualSlices(f32, &.{ 50, 50, 60, 60 }, &target.clips[2]);
    try testing.expectEqual(@as(u32, 1), draws[3].clip);
    try testing.expectEqual(Pipeline.triangles, draws[4].pipeline);
    try testing.expectEqual(@as(u32, 3), draws[4].count);
    try testing.expectEqual(@as(u32, 4), target.counts[@backingInt(Pool.quads)]);
    try testing.expectEqual(@as(u32, 1), target.counts[@backingInt(Pool.shadows)]);

    const modes = target.edgeModeList();
    try testing.expectEqual(@as(usize, 3), modes.len);
    try testing.expectEqual(@as(u32, 1 | 0 << 2 | 1 << 4), modes[0]);
    try testing.expectEqual(@as(u32, 2 | 1 << 2 | 0 << 4), modes[1]);
    try testing.expectEqual(@as(u32, 1 | 1 << 2 | 1 << 4), modes[2]);
}

test "pack skips every instance under a clip with zero area" {
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
        .paint = limits_mod.PaintLimits.nano,
        .paint_record_count_max = 16,
    });
    defer target.deinit();
    pack(&frame, &target);

    try testing.expectEqual(@as(usize, 1), target.drawList().len);
    try testing.expectEqual(@as(u32, packed_mod.clip_none), target.draws[0].clip);
    try testing.expectEqualSlices(f32, &.{ 20, 20, 10, 10 }, &target.quads[0].bounds);
    try testing.expectEqual(@as(u32, 0), target.sprite_count);
    try testing.expectEqual(@as(u32, 0), target.triangle_count);
    try testing.expectEqual(@as(u32, 4), target.clip_count);
    try testing.expectEqual(@as(f32, 0), target.clips[2][2]);
}

test "pack starts a draw at every pipeline change within one clip" {
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
        .paint = limits_mod.PaintLimits.nano,
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
    const testing = std.testing;
    const record_count_max: u32 = 8;
    var frame: records.Frame = undefined;
    try frame.initInPlace(testing.allocator, &testFrameCapacity(2 * record_count_max, 0));
    defer frame.deinit(testing.allocator);
    var target: PackedFrame = undefined;
    try target.initInPlace(&.{
        .paint = limits_mod.PaintLimits.nano,
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

test "pack merges custom fills by shader and clip, culls, and keeps each params slot" {
    const testing = std.testing;
    var frame: records.Frame = undefined;
    var capacity = testFrameCapacity(16, 0);
    capacity.params_slot_count_max = 8;
    capacity.params_stride = 16;
    try frame.initInPlace(testing.allocator, &capacity);
    defer frame.deinit(testing.allocator);
    frame.reset(1, .{ .width = 200, .height = 200, .scale_factor = 1 });
    frame.shader_time_s = 2.5;
    var slots: [7]u32 = undefined;
    for (&slots, 0..) |*slot, index| slot.* = frame.claimParams(&.{@intCast(index + 1)});
    frame.appendPaint(.{ .custom = testCustom(0, 0, slots[6], 1) });
    frame.appendPaint(.{ .custom = testCustom(10, 0, slots[5], 1) });
    frame.appendPaint(.{ .custom = testCustom(20, 1, slots[4], 0.5) });
    frame.appendPaint(.{ .custom = testCustom(30, 0, slots[3], 1) });
    frame.appendPaint(.{ .custom = testCustom(40, 0, slots[2], 0) });
    frame.appendPaint(.{ .clip_push = .{ .x = 0, .y = 0, .width = 100, .height = 100 } });
    frame.appendPaint(.{ .custom = testCustom(50, 0, slots[1], 1) });
    frame.appendPaint(.{ .custom = testCustom(150, 0, slots[0], 1) });
    frame.appendPaint(.clip_pop);

    var target: PackedFrame = undefined;
    var paint = limits_mod.PaintLimits.nano;
    paint.shader_params_bytes_max = 16;
    try target.initInPlace(&.{ .paint = paint, .paint_record_count_max = 16 });
    defer target.deinit();
    pack(&frame, &target);

    const draws = target.drawList();
    const expected = [_]struct { shader: u8, clip: u32, first: u32, count: u32 }{
        .{ .shader = 0, .clip = 0, .first = 0, .count = 2 },
        .{ .shader = 1, .clip = 0, .first = 2, .count = 1 },
        .{ .shader = 0, .clip = 0, .first = 3, .count = 1 },
        .{ .shader = 0, .clip = 1, .first = 4, .count = 1 },
    };
    try testing.expectEqual(expected.len, draws.len);
    for (draws, expected) |draw, want| {
        try testing.expectEqual(Pipeline.custom, draw.pipeline);
        try testing.expectEqual(want.shader, draw.shader);
        try testing.expectEqual(want.clip, draw.clip);
        try testing.expectEqual(want.first, draw.first);
        try testing.expectEqual(want.count, draw.count);
    }
    const customs = target.customList();
    try testing.expectEqual(@as(usize, 5), customs.len);
    try testing.expectEqual(@as(f32, 0.5), customs[2].opacity);
    try testing.expectEqual(@as(f32, 50), customs[4].bounds[0]);
    const params_first = [_]u8{ 7, 6, 5, 4, 2 };
    for (customs, params_first) |*custom, first| {
        const params = target.customParams(custom);
        try testing.expectEqual(first, params[0]);
        for (params[1..]) |byte| try testing.expectEqual(@as(u8, 0), byte);
    }
    try testing.expectEqual(@as(f32, 2.5), target.shader_time_s);
    try testing.expectEqual(@as(u32, 5), target.counts[@backingInt(Pool.customs)]);
}

fn testCustom(x: f32, shader: u8, slot: u32, opacity: f32) records.Custom {
    return .{
        .bounds = .{ .x = x, .y = 10, .width = 8, .height = 8 },
        .corners = .all(2),
        .opacity = opacity,
        .shader = shader,
        .params_slot = slot,
    };
}

fn testFrameCapacity(paint_record_count_max: u32, mesh_point_count_max: u32) records.FrameCapacity {
    return .{
        .paint_record_count_max = paint_record_count_max,
        .hit_record_count_max = 1,
        .handler_count_max = 1,
        .a11y_node_count_max = 1,
        .announcements = .{ .polite_pending_max = 1, .message_bytes_max = 1 },
        .text_bytes_max = 1,
        .mesh_point_count_max = mesh_point_count_max,
        .params_slot_count_max = 0,
        .params_stride = 0,
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
