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
    var bound: ?Bound = null;
    for (frame.drawList()) |*draw| {
        assert(draw.clip < frame.clip_count);
        assert(frame.clips[draw.clip][2] > 0);
        assert(frame.clips[draw.clip][3] > 0);
        const wanted = Bound{ .pipeline = draw.pipeline, .shader = draw.shader };
        if (bound == null or !std.meta.eql(bound.?, wanted)) {
            encoder.msgSend(void, "setRenderPipelineState:", .{
                pipelines.state(draw.pipeline, draw.shader).value,
            });
            bound = wanted;
        }
        setBytes(encoder, "setFragmentBytes:length:atIndex:", .{
            .bytes = std.mem.asBytes(&frame.clips[draw.clip]),
            .index = shaders.fragment_buffer_clip,
        });
        switch (draw.pipeline.kind()) {
            .quad, .sprite, .custom => drawInstances(encoder, draw),
            .mesh => for (frame.drawRange(draw, .mesh)) |*mesh| {
                drawMesh(encoder, draw.pipeline, mesh);
            },
        }
    }
}

const Bound = struct { pipeline: Pipeline, shader: u8 };

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
            .triangles => .{
                @as(u64, mesh.edge_first) * shaders.triangle_draw_vertex_count,
                @as(u64, @divExact(mesh.count, 3)) * shaders.triangle_draw_vertex_count,
                1,
            },
            .strip_expanded => .{ 0, shaders.instance_vertex_count, mesh.count - 1 },
            .point_instanced => .{ 0, shaders.instance_vertex_count, mesh.count },
            .quad, .glyph, .svg, .image, .custom => unreachable,
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
    assert(options.bytes.len > 0);
    assert(options.bytes.len <= 4096);
    encoder.msgSend(void, selector, .{
        @as(*const anyopaque, @ptrCast(options.bytes.ptr)),
        @as(c_ulong, options.bytes.len),
        @as(c_ulong, options.index),
    });
}

pub fn bindFrame(encoder: objc.Object, bindings: struct {
    quads: objc.Object,
    sprites: objc.Object,
    points: objc.Object,
    edge_modes: objc.Object,
    customs: objc.Object,
    params: objc.Object,
    shade_frame: shaders.ShadeFrame,
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
        .{ bindings.customs, shaders.buffer_customs },
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
    // Custom fills read params by instance from one buffer; fragment bindings persist
    // across pipeline changes, so the frame binds them once.
    encoder.msgSend(void, "setFragmentBuffer:offset:atIndex:", .{
        bindings.params.value,
        @as(c_ulong, 0),
        @as(c_ulong, shaders.fragment_buffer_params),
    });
    setBytes(encoder, "setFragmentBytes:length:atIndex:", .{
        .bytes = std.mem.asBytes(&bindings.shade_frame),
        .index = shaders.fragment_buffer_shade_frame,
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
