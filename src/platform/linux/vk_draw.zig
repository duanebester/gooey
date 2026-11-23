const std = @import("std");
const vk = @import("vulkan.zig");
const vk_types = @import("vk_types.zig");
const packed_mod = @import("../../core/packed_frame.zig");
const mesh_edges = @import("../mesh_edges.zig");
const scissor_rule = @import("../scissor.zig");

const assert = std.debug.assert;

const PackedFrame = packed_mod.PackedFrame;
const Pipeline = packed_mod.Pipeline;
const FrameBuffer = vk_types.FrameBuffer;
const FrameCapacity = vk_types.FrameCapacity;

pub const pipeline_count: u32 = @typeInfo(Pipeline).@"enum".field_names.len;

const instance_vertex_count: u32 = 6;

comptime {
    assert(mesh_edges.triangle_draw_vertex_count == 21);
}

pub const Target = struct {
    command: vk.CommandBuffer,
    layout: vk.PipelineLayout,
    pipelines: *const [pipeline_count]vk.Pipeline,
    descriptor_set: vk.DescriptorSet,
    extent: vk.Extent2D,
    scale_x: f32,
    scale_y: f32,
};

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
    for (frame.drawList()) |*draw| {
        assert(draw.count > 0);
        assert(draw.clip < frame.clip_count);
        assert(frame.clips[draw.clip][2] > 0);
        assert(frame.clips[draw.clip][3] > 0);
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
            .quad, .glyph, .svg, .image => unreachable,
        }
    }
    return draw.count;
}

fn scissorRect(clip: packed_mod.Rect, target: *const Target) ?vk.Rect2D {
    const rect = scissor_rule.clipRect(clip, target.scale_x, target.scale_y, .{
        .width = target.extent.width,
        .height = target.extent.height,
    }) orelse return null;
    return .{
        .offset = .{ .x = @intCast(rect.x), .y = @intCast(rect.y) },
        .extent = .{ .width = rect.width, .height = rect.height },
    };
}
