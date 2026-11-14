//! Encode a packed frame's draws into a render pass, in draw order.
//!
//! Every buffer, texture, and the viewport are bound once per frame
//! (`shaders.zig` lists the slots); a draw sets its pipeline when it changes
//! and its clip rectangle. Quads and sprites draw instanced with the draw's
//! first instance as the base instance; meshes draw one call each, with the
//! 32 B mesh inline, because each mesh is its own vertex range.
//!
//! Performance sketch (CLAUDE.md §7): per draw a 16 B `setFragmentBytes` and
//! at most one pipeline bind, plus one draw call per quad or sprite draw and
//! per mesh. Draws are bounded by the paint record budget, meshes by the
//! paint budget's mesh limits. Nothing allocates; no CPU work scales with instances.

const std = @import("std");
const assert = std.debug.assert;

const objc = @import("objc");
const mtl = @import("api.zig");
const shaders = @import("shaders.zig");
const pipelines_mod = @import("pipelines.zig");
const packed_frame = @import("../../../core/packed_frame.zig");

const PackedFrame = packed_frame.PackedFrame;
const Pipeline = packed_frame.Pipeline;

pub fn encodeDraws(
    encoder: objc.Object,
    frame: *const PackedFrame,
    pipelines: *const pipelines_mod.Pipelines,
) void {
    assert(frame.clip_count >= 1);
    assert(frame.draw_count <= frame.draws.len);
    var bound: ?Pipeline = null;
    for (frame.drawList()) |*draw| {
        assert(draw.clip < frame.clip_count);
        // Pack emits no draw under a zero-area clip (contract §9).
        assert(frame.clips[draw.clip][2] > 0);
        assert(frame.clips[draw.clip][3] > 0);
        if (bound != draw.pipeline) {
            encoder.msgSend(void, "setRenderPipelineState:", .{
                pipelines.state(draw.pipeline).value,
            });
            bound = draw.pipeline;
        }
        setBytes(encoder, "setFragmentBytes:length:atIndex:", .{
            .bytes = std.mem.asBytes(&frame.clips[draw.clip]),
            .index = shaders.fragment_buffer_clip,
        });
        switch (draw.pipeline.kind()) {
            .quad, .sprite => drawInstances(encoder, draw),
            .mesh => for (frame.drawRange(draw, .mesh)) |*mesh| {
                drawMesh(encoder, draw.pipeline, mesh);
            },
        }
    }
}

/// `count` instances from `first`, six vertices each. `instance_id` counts
/// from the base instance, so shaders index the frame's array directly.
fn drawInstances(encoder: objc.Object, draw: *const packed_frame.Draw) void {
    assert(draw.count > 0);
    assert(draw.pipeline.kind() != .mesh);
    encoder.msgSend(void, "drawPrimitives:vertexStart:vertexCount:instanceCount:baseInstance:", .{
        @backingInt(mtl.MTLPrimitiveType.triangle),
        @as(c_ulong, 0),
        @as(c_ulong, shaders.instance_vertex_count),
        @as(c_ulong, draw.count),
        @as(c_ulong, draw.first),
    });
}

fn drawMesh(encoder: objc.Object, pipeline: Pipeline, mesh: *const packed_frame.Mesh) void {
    assert(mesh.count > 0);
    setBytes(encoder, "setVertexBytes:length:atIndex:", .{
        .bytes = std.mem.asBytes(mesh),
        .index = shaders.buffer_mesh,
    });
    const vertex_start: u64, const vertex_count: u64, const instance_count: u64 =
        switch (pipeline) {
            // `vid / 21` is the triangle's index into the frame's edge modes.
            .triangles => .{
                @as(u64, mesh.edge_first) * shaders.triangle_draw_vertex_count,
                @as(u64, @divExact(mesh.count, 3)) * shaders.triangle_draw_vertex_count,
                1,
            },
            // One instance per segment; a line has at least two points.
            .strip_expanded => .{ 0, shaders.instance_vertex_count, mesh.count - 1 },
            .point_instanced => .{ 0, shaders.instance_vertex_count, mesh.count },
            .quad, .glyph, .svg, .image => unreachable,
        };
    assert(instance_count > 0);
    encoder.msgSend(void, "drawPrimitives:vertexStart:vertexCount:instanceCount:", .{
        @backingInt(mtl.MTLPrimitiveType.triangle),
        @as(c_ulong, vertex_start),
        @as(c_ulong, vertex_count),
        @as(c_ulong, instance_count),
    });
}

fn setBytes(
    encoder: objc.Object,
    comptime selector: [:0]const u8,
    options: struct { bytes: []const u8, index: u32 },
) void {
    // Metal's inline data limit is 4 KiB; these are 8 to 32 B.
    assert(options.bytes.len > 0);
    assert(options.bytes.len <= 4096);
    encoder.msgSend(void, selector, .{
        @as(*const anyopaque, @ptrCast(options.bytes.ptr)),
        @as(c_ulong, options.bytes.len),
        @as(c_ulong, options.index),
    });
}

/// Bind the frame's buffers, the atlas textures, and the viewport once.
pub fn bindFrame(encoder: objc.Object, bindings: struct {
    quads: objc.Object,
    sprites: objc.Object,
    points: objc.Object,
    edge_modes: objc.Object,
    textures: [3]objc.Object,
    viewport_logical: [2]f32,
}) void {
    assert(bindings.viewport_logical[0] > 0);
    assert(bindings.viewport_logical[1] > 0);
    const buffers = [_]struct { objc.Object, u32 }{
        .{ bindings.quads, shaders.buffer_quads },
        .{ bindings.sprites, shaders.buffer_sprites },
        .{ bindings.points, shaders.buffer_points },
        .{ bindings.edge_modes, shaders.buffer_edge_modes },
    };
    for (buffers) |entry| {
        encoder.msgSend(void, "setVertexBuffer:offset:atIndex:", .{
            entry[0].value,
            @as(c_ulong, 0),
            @as(c_ulong, entry[1]),
        });
    }
    setBytes(encoder, "setVertexBytes:length:atIndex:", .{
        .bytes = std.mem.asBytes(&bindings.viewport_logical),
        .index = shaders.buffer_viewport,
    });
    const texture_indices = [3]u32{
        shaders.texture_glyph,
        shaders.texture_svg,
        shaders.texture_image,
    };
    for (bindings.textures, texture_indices) |texture, index| {
        encoder.msgSend(void, "setFragmentTexture:atIndex:", .{
            texture.value,
            @as(c_ulong, index),
        });
    }
}
