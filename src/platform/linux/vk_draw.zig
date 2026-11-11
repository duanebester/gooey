//! Recording a packed frame's draws into a command buffer (contract §9).
//!
//! The packed frame is already in draw order, one `Draw` per run of one
//! pipeline and one clip, so recording is one pass: set the scissor when the
//! clip changes, bind the pipeline when it changes, and issue the draw. The
//! frame's descriptor set holds every buffer and atlas, so it is bound once.
//!
//! Performance sketch (CLAUDE.md §7): `writeInstances` copies the used prefix
//! of each packed array into the frame's mapped buffers, at most the 1.9 MB
//! `FrameCapacity` holds at `.standard`; a todo frame copies about 11 KiB.
//! `recordDraws` records at most one scissor, one bind, and one draw per
//! quad or sprite draw, plus one push constant and one draw per mesh, so
//! commands are bounded by `records.paint_record_count_frame_max`.

const std = @import("std");
const vk = @import("vulkan.zig");
const vk_types = @import("vk_types.zig");
const packed_mod = @import("../../core/packed_frame.zig");
const mesh_edges = @import("../mesh_edges.zig");

const assert = std.debug.assert;

const PackedFrame = packed_mod.PackedFrame;
const Pipeline = packed_mod.Pipeline;
const FrameBuffer = vk_types.FrameBuffer;
const FrameCapacity = vk_types.FrameCapacity;

pub const pipeline_count: u32 = @typeInfo(Pipeline).@"enum".field_names.len;

/// Vertices per quad or sprite instance, and per strip segment or point.
const instance_vertex_count: u32 = 6;

comptime {
    // `shaders/triangles.vert` hard-codes the triangle's draw layout.
    assert(mesh_edges.triangle_draw_vertex_count == 21);
}

/// Where and how one frame's draws are recorded.
pub const Target = struct {
    command: vk.CommandBuffer,
    layout: vk.PipelineLayout,
    /// Indexed by `Pipeline`.
    pipelines: *const [pipeline_count]vk.Pipeline,
    descriptor_set: vk.DescriptorSet,
    extent: vk.Extent2D,
    /// Device pixels per logical pixel on each axis: the framebuffer extent
    /// over the viewport's logical size.
    scale_x: f32,
    scale_y: f32,
};

/// Copy each packed array's used prefix into the frame's mapped buffers,
/// indexed by `FrameBuffer`. A frame is packed at the budget the buffers were
/// sized from, so a count past capacity is a programmer error, stopped before
/// it can write past a buffer in any build mode.
pub fn writeInstances(
    frame: *const PackedFrame,
    mapped: *const [vk_types.frame_buffer_count][*]u8,
    capacity: *const FrameCapacity,
) void {
    const counts = FrameCapacity.usedCounts(frame);
    const sources = [vk_types.frame_buffer_count][]const u8{
        std.mem.sliceAsBytes(frame.quadList()),
        std.mem.sliceAsBytes(frame.spriteList()),
        std.mem.sliceAsBytes(frame.meshList()),
        std.mem.sliceAsBytes(frame.mesh_points),
        std.mem.sliceAsBytes(frame.edgeModeList()),
    };
    for (std.enums.values(FrameBuffer), counts, sources) |buffer, count, source| {
        const count_max = capacity.countMax(buffer);
        if (count > count_max) {
            std.debug.panic("Vulkan frame buffer '{t}' cannot hold frame {d}: capacity {d}, " ++
                "{d} requested. The packed frame and the renderer must share one budget.", .{
                buffer,
                frame.frame_number,
                count_max,
                count,
            });
        }
        assert(source.len == @as(u64, count) * FrameCapacity.elementBytes(buffer));
        @memcpy(mapped[@backingInt(buffer)][0..source.len], source);
    }
}

/// Record every draw of `frame` in order. Returns the draw calls recorded.
pub fn recordDraws(target: *const Target, frame: *const PackedFrame) u32 {
    assert(target.command != null);
    assert(target.scale_x > 0);
    assert(target.scale_y > 0);
    vk.vkCmdBindDescriptorSets(
        target.command,
        vk.VK_PIPELINE_BIND_POINT_GRAPHICS,
        target.layout,
        0,
        1,
        (&target.descriptor_set)[0..1],
        0,
        null,
    );
    var bound_pipeline: ?Pipeline = null;
    var bound_clip: ?u32 = null;
    var draw_calls: u32 = 0;
    // One iteration per draw; the draw list is bounded by the paint records.
    for (frame.drawList()) |*draw| {
        assert(draw.count > 0);
        assert(draw.clip < frame.clip_count);
        // Pack emits no draw under a zero-area clip (contract §9).
        assert(frame.clips[draw.clip][2] > 0);
        assert(frame.clips[draw.clip][3] > 0);
        // A clip that covers no pixel centre (off the framebuffer, or between
        // centres) draws nothing.
        const scissor = scissorRect(frame.clips[draw.clip], target) orelse continue;
        if (bound_clip != draw.clip) {
            vk.vkCmdSetScissor(target.command, 0, 1, (&scissor)[0..1]);
            bound_clip = draw.clip;
        }
        if (bound_pipeline != draw.pipeline) {
            const pipeline = target.pipelines[@backingInt(draw.pipeline)];
            assert(pipeline != null);
            vk.vkCmdBindPipeline(target.command, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
            bound_pipeline = draw.pipeline;
        }
        switch (draw.pipeline.kind()) {
            // Instance `i` is vertices 6i..6i+5 (`gl_VertexIndex / 6`).
            .quad, .sprite => {
                vk.vkCmdDraw(
                    target.command,
                    instance_vertex_count * draw.count,
                    1,
                    instance_vertex_count * draw.first,
                    0,
                );
                draw_calls += 1;
            },
            .mesh => draw_calls += recordMeshes(target, frame, draw),
        }
    }
    return draw_calls;
}

/// One draw per mesh, with its index pushed for the topology's vertex shader.
fn recordMeshes(
    target: *const Target,
    frame: *const PackedFrame,
    draw: *const packed_mod.Draw,
) u32 {
    const meshes = frame.drawRange(draw, .mesh);
    assert(meshes.len == draw.count);
    for (meshes, draw.first..) |*mesh, index| {
        assert(mesh.count > 0);
        assert(mesh.first + mesh.count <= frame.mesh_points.len);
        const push = vk_types.PushConstants{ .mesh = @intCast(index) };
        vk.vkCmdPushConstants(
            target.command,
            target.layout,
            vk.VK_SHADER_STAGE_VERTEX_BIT,
            0,
            @sizeOf(vk_types.PushConstants),
            &push,
        );
        switch (draw.pipeline) {
            .triangles => {
                assert(mesh.count % 3 == 0);
                assert(mesh.edge_first + @divExact(mesh.count, 3) <= frame.triangle_count);
                const vertex_count = mesh_edges.draw_vertex_count(mesh.count);
                vk.vkCmdDraw(target.command, vertex_count, 1, 0, 0);
            },
            .strip_expanded => {
                assert(mesh.count >= 2);
                vk.vkCmdDraw(target.command, instance_vertex_count, mesh.count - 1, 0, 0);
            },
            .point_instanced => {
                vk.vkCmdDraw(target.command, instance_vertex_count, mesh.count, 0, 0);
            },
            .quad, .glyph, .svg, .image => unreachable, // `drawRange` asserted a mesh draw.
        }
    }
    return draw.count;
}

/// The scissor that keeps exactly the pixels whose centres lie inside `clip`,
/// edges included, or null when there are none.
fn scissorRect(clip: packed_mod.Rect, target: *const Target) ?vk.Rect2D {
    const columns = centreSpan(clip[0], clip[2], target.scale_x, target.extent.width) orelse
        return null;
    const rows = centreSpan(clip[1], clip[3], target.scale_y, target.extent.height) orelse
        return null;
    return .{
        .offset = .{ .x = @intCast(columns.first), .y = @intCast(rows.first) },
        .extent = .{ .width = columns.count, .height = rows.count },
    };
}

const Span = struct { first: u32, count: u32 };

/// Device pixels `i` in `0..limit` whose centre `(i + 0.5) / scale` lies in
/// `[start, start + size]`: `i >= start * scale - 0.5` and
/// `i <= (start + size) * scale - 0.5`. Null when none does. Both ends clamp
/// to the framebuffer in float before converting, so the unbounded clip's
/// ±1e9 never reaches an integer at any scale.
fn centreSpan(start: f32, size: f32, scale: f32, limit: u32) ?Span {
    assert(!std.math.isNan(start));
    assert(size >= 0);
    assert(scale > 0);
    const limit_f: f32 = @floatFromInt(limit);
    const first = std.math.clamp(@ceil(start * scale - 0.5), 0, limit_f);
    const end = std.math.clamp(@floor((start + size) * scale - 0.5) + 1, 0, limit_f);
    if (end <= first) return null;
    const span = Span{ .first = @intFromFloat(first), .count = @intFromFloat(end - first) };
    assert(span.count > 0);
    assert(span.first + span.count <= limit);
    return span;
}

test "centreSpan keeps exactly the pixels whose centres lie in the clip" {
    // Goal: the scissor implements the contract's clip rule, inclusive edges and
    // all. Methodology: boundaries chosen so each side lands exactly on, just
    // inside, or just outside a pixel centre, at scale 1 and at 1.5.
    // [2, 5] holds centres 2.5, 3.5, 4.5: pixels 2..4.
    try std.testing.expectEqual(Span{ .first = 2, .count = 3 }, centreSpan(2, 3, 1, 100).?);
    // Edges on centres are inside: [2.5, 4.5] holds 2.5, 3.5, 4.5.
    try std.testing.expectEqual(Span{ .first = 2, .count = 3 }, centreSpan(2.5, 2, 1, 100).?);
    // Just past them they are not: [2.51, 4.49] holds only 3.5.
    try std.testing.expectEqual(Span{ .first = 3, .count = 1 }, centreSpan(2.51, 1.98, 1, 100).?);
    // An empty or centre-free clip draws nothing.
    try std.testing.expectEqual(null, centreSpan(2.6, 0.3, 1, 100));
    try std.testing.expectEqual(null, centreSpan(3, 0, 1, 100));
    // At scale 1.5, logical [1, 3] is device [1.5, 4.5]: centres 1.5 .. 4.5.
    try std.testing.expectEqual(Span{ .first = 1, .count = 4 }, centreSpan(1, 2, 1.5, 100).?);
    // The unbounded clip is the whole framebuffer; one outside it is nothing.
    const unbounded = packed_mod.clip_unbounded;
    try std.testing.expectEqual(
        Span{ .first = 0, .count = 640 },
        centreSpan(unbounded[0], unbounded[2], 2, 640).?,
    );
    try std.testing.expectEqual(null, centreSpan(700, 10, 1, 640));
    try std.testing.expectEqual(null, centreSpan(-20, 10, 1, 640));
}
