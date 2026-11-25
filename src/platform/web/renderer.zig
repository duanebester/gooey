const std = @import("std");
const imports = @import("imports.zig");
const backend = @import("../../core/backend.zig");
const packed_mod = @import("../../core/packed_frame.zig");
const limits_mod = @import("../../core/limits.zig");
const mesh_edges = @import("../mesh_edges.zig");
const scissor = @import("../scissor.zig");

const assert = std.debug.assert;

const PackedFrame = packed_mod.PackedFrame;
const Pipeline = packed_mod.Pipeline;
const BuiltinPipeline = packed_mod.BuiltinPipeline;

const pipeline_count: u32 = packed_mod.builtin_pipeline_count;

const FrameBuffer = enum(u8) { quads, sprites, meshes, mesh_points, edge_modes, viewport };

const frame_buffer_count: u32 = @typeInfo(FrameBuffer).@"enum".field_names.len;

const Atlas = enum(u8) { glyph, svg, image };

const atlas_count: u32 = @typeInfo(Atlas).@"enum".field_names.len;

const instance_vertex_count: u32 = 6;

const usage_copy_dst: u32 = 0x0008;
const usage_uniform: u32 = 0x0040;
const usage_storage: u32 = 0x0080;

const Viewport = extern struct {
    width: f32,
    height: f32,
    _pad: [2]f32 = .{ 0, 0 },
};

const shader_source = @embedFile("packed_wgsl");

const EntryPoints = struct {
    vertex: []const u8,
    fragment: []const u8,
    premultiplied: bool,
};

const entry_points = std.EnumArray(BuiltinPipeline, EntryPoints).init(.{
    .quad = .{ .vertex = "quad_vertex", .fragment = "quad_fragment", .premultiplied = false },
    .glyph = .{ .vertex = "text_vertex", .fragment = "text_fragment", .premultiplied = false },
    .svg = .{ .vertex = "icon_vertex", .fragment = "svg_fragment", .premultiplied = true },
    .image = .{ .vertex = "icon_vertex", .fragment = "image_fragment", .premultiplied = false },
    .triangles = .{
        .vertex = "triangle_vertex",
        .fragment = "edge_fragment",
        .premultiplied = true,
    },
    .strip_expanded = .{
        .vertex = "polyline_vertex",
        .fragment = "edge_fragment",
        .premultiplied = true,
    },
    .point_instanced = .{
        .vertex = "point_vertex",
        .fragment = "point_fragment",
        .premultiplied = true,
    },
});

comptime {
    assert(@sizeOf(packed_mod.Quad) == 96);
    assert(@offsetOf(packed_mod.Quad, "offset") == 80);
    assert(@sizeOf(packed_mod.Sprite) == 96);
    assert(@offsetOf(packed_mod.Sprite, "grayscale") == 80);
    assert(@sizeOf(packed_mod.Mesh) == 32);
    assert(@offsetOf(packed_mod.Mesh, "edge_first") == 28);
    assert(@sizeOf(packed_mod.MeshPoint) == 8);
    assert(@sizeOf(Viewport) == 16);
    assert(mesh_edges.triangle_draw_vertex_count == 21);
}

pub const WebRenderer = struct {
    pipelines: [pipeline_count]u32,
    bind_group: u32,
    buffers: [frame_buffer_count]u32,
    capacity: [frame_buffer_count]u32,
    atlases: [atlas_count]u32,
    atlas_sizes: [atlas_count]u32,
    size_px: backend.SizePx,
    limits: backend.RenderLimits,
    frame_number: u64,
    frame_skip_logged: bool,

    const Self = @This();

    comptime {
        backend.verifyRenderer(Self);
    }

    pub noinline fn initInPlace(
        self: *Self,
        surface: *const backend.Surface,
        render_limits: *const backend.RenderLimits,
    ) !void {
        assert(surface.scale_factor > 0);
        assert(render_limits.paint.check() == null);
        assertFits(surface.size_px, &render_limits.window);
        self.capacity = frameCapacity(&render_limits.paint);
        self.atlas_sizes = .{
            render_limits.atlas.text_size,
            render_limits.atlas.svg_size,
            render_limits.atlas.image_size,
        };
        try checkDevice(&self.capacity, &self.atlas_sizes, &render_limits.window);
        const layout = imports.createPackedLayout();
        assert(layout != 0);
        self.initPipelines(layout);
        self.initBuffers();
        self.initAtlases();
        const sampler = imports.createSampler();
        assert(sampler != 0);
        self.bind_group = imports.createPackedBindGroup(
            layout,
            &self.buffers,
            frame_buffer_count,
            &self.atlases,
            atlas_count,
            sampler,
        );
        assert(self.bind_group != 0);
        self.limits = render_limits.*;
        self.frame_number = 0;
        self.frame_skip_logged = false;
        self.size_px = .{ .width = 0, .height = 0 };
        self.resize(surface.size_px);
        assert(std.meta.eql(self.size_px, surface.size_px));
    }

    fn initPipelines(self: *Self, layout: u32) void {
        assert(layout != 0);
        const module = imports.createShaderModule(shader_source.ptr, shader_source.len);
        assert(module != 0);
        for (std.enums.values(BuiltinPipeline)) |builtin_pipeline| {
            const entry = entry_points.get(builtin_pipeline);
            const pipeline: Pipeline = @fromBackingInt(@backingInt(builtin_pipeline));
            const handle = imports.createPackedPipeline(
                layout,
                module,
                entry.vertex.ptr,
                @intCast(entry.vertex.len),
                entry.fragment.ptr,
                @intCast(entry.fragment.len),
                entry.premultiplied,
            );
            assert(handle != 0);
            self.pipelines[@backingInt(pipeline)] = handle;
        }
    }

    fn initBuffers(self: *Self) void {
        assert(self.capacity[@backingInt(FrameBuffer.viewport)] == 1);
        for (std.enums.values(FrameBuffer)) |buffer| {
            const usage: u32 = switch (buffer) {
                .viewport => usage_uniform | usage_copy_dst,
                .quads, .sprites, .meshes, .mesh_points, .edge_modes => usage_storage |
                    usage_copy_dst,
            };
            const bytes = bufferBytes(&self.capacity, buffer);
            const handle = imports.createBuffer(@intCast(bytes), usage);
            assert(handle != 0);
            self.buffers[@backingInt(buffer)] = handle;
        }
    }

    fn initAtlases(self: *Self) void {
        for (std.enums.values(Atlas)) |atlas| {
            const size = self.atlas_sizes[@backingInt(atlas)];
            assert(size > 0);
            const handle = imports.createAtlasTexture(size, size, atlasBytesPerPixel(atlas));
            assert(handle != 0);
            self.atlases[@backingInt(atlas)] = handle;
        }
    }

    pub fn deinit(self: *Self) void {
        assert(self.bind_group != 0);
        assert(self.buffers[0] != 0);
        self.* = undefined;
    }

    pub fn capabilities(self: *const Self) backend.Capabilities {
        assert(self.bind_group != 0);
        assert(self.pipelines[@backingInt(Pipeline.triangles)] != 0);
        return .{ .meshes = true, .custom_shaders = false };
    }

    pub fn resize(self: *Self, size_px: backend.SizePx) void {
        assert(self.bind_group != 0);
        assertFits(size_px, &self.limits.window);
        if (size_px.width > 0 and size_px.height > 0) {
            if (!std.meta.eql(size_px, self.size_px)) {
                imports.setCanvasSize(size_px.width, size_px.height);
            }
        }
        self.size_px = size_px;
    }

    pub fn uploadAtlas(
        self: *Self,
        kind: backend.AtlasKind,
        dirty: backend.RectPx,
        pixels: []const u8,
    ) void {
        assert(dirty.width > 0);
        assert(dirty.height > 0);
        const atlas: Atlas = switch (kind) {
            .glyph => .glyph,
            .svg => .svg,
            .image => .image,
            .glyph_color => std.debug.panic("WebGPU: no glyph_color atlas; nothing emits " ++
                "colour glyphs yet (contract §9, phase 5)", .{}),
        };
        const size = self.atlas_sizes[@backingInt(atlas)];
        assert(dirty.x <= size);
        assert(dirty.width <= size - dirty.x);
        assert(dirty.y <= size);
        assert(dirty.height <= size - dirty.y);
        const bytes_per_pixel = atlasBytesPerPixel(atlas);
        assert(pixels.len == @as(u64, dirty.width) * dirty.height * bytes_per_pixel);
        imports.writeAtlasRegion(
            self.atlases[@backingInt(atlas)],
            dirty.x,
            dirty.y,
            dirty.width,
            dirty.height,
            bytes_per_pixel,
            pixels.ptr,
            @intCast(pixels.len),
        );
    }

    pub fn draw(
        self: *Self,
        frame: *const PackedFrame,
        viewport: backend.Viewport,
        clear: backend.Color,
    ) void {
        assert(viewport.scale_factor > 0);
        assert(std.meta.eql(viewport.size_px, self.size_px));
        assert(clear.a >= 0);
        assert(clear.a <= 1);
        self.frame_number = frame.frame_number;
        const size_px = viewport.size_px;
        if (size_px.width == 0 or size_px.height == 0) return;
        const logical = Viewport{
            .width = logicalSize(size_px.width, viewport.scale_factor),
            .height = logicalSize(size_px.height, viewport.scale_factor),
        };
        self.writeFrame(frame, &logical);
        if (!imports.beginFrame(clear.r, clear.g, clear.b, clear.a)) {
            if (!self.frame_skip_logged) {
                imports.err("WebGPU: the canvas has no current texture; skipping frame {d}", .{
                    frame.frame_number,
                });
                self.frame_skip_logged = true;
            }
            return;
        }
        imports.setBindGroup(0, self.bind_group);
        recordDraws(&self.pipelines, frame, .{
            .size_px = size_px,
            .scale_x = @as(f32, @floatFromInt(size_px.width)) / logical.width,
            .scale_y = @as(f32, @floatFromInt(size_px.height)) / logical.height,
        });
        imports.endFrame();
    }

    fn writeFrame(self: *const Self, frame: *const PackedFrame, logical: *const Viewport) void {
        assert(logical.width > 0);
        assert(logical.height > 0);
        assert(frame.mesh_points.len <= std.math.maxInt(u32));
        const sources = [frame_buffer_count][]const u8{
            std.mem.sliceAsBytes(frame.quadList()),
            std.mem.sliceAsBytes(frame.spriteList()),
            std.mem.sliceAsBytes(frame.meshList()),
            std.mem.sliceAsBytes(frame.mesh_points),
            std.mem.sliceAsBytes(frame.edgeModeList()),
            std.mem.asBytes(logical),
        };
        for (std.enums.values(FrameBuffer), sources) |buffer, source| {
            const count_max = self.capacity[@backingInt(buffer)];
            const count = @divExact(source.len, elementBytes(buffer));
            if (count > count_max) {
                std.debug.panic("WebGPU frame buffer '{t}' cannot hold frame {d}: capacity " ++
                    "{d}, {d} requested. The packed frame and the renderer must share one " ++
                    "budget.", .{ buffer, frame.frame_number, count_max, count });
            }
            if (source.len == 0) continue;
            const handle = self.buffers[@backingInt(buffer)];
            imports.writeBuffer(handle, 0, source.ptr, @intCast(source.len));
        }
    }
};

const Target = struct {
    size_px: backend.SizePx,
    scale_x: f32,
    scale_y: f32,
};

fn recordDraws(
    pipelines: *const [pipeline_count]u32,
    frame: *const PackedFrame,
    target: Target,
) void {
    assert(target.scale_x > 0);
    assert(target.scale_y > 0);
    var bound_pipeline: ?Pipeline = null;
    var bound_clip: ?u32 = null;
    for (frame.drawList()) |*packed_draw| {
        assert(packed_draw.count > 0);
        assert(packed_draw.clip < frame.clip_count);
        const clip = frame.clips[packed_draw.clip];
        assert(clip[2] > 0);
        assert(clip[3] > 0);
        const rect = scissor.clipRect(clip, target.scale_x, target.scale_y, target.size_px) orelse
            continue;
        if (bound_clip != packed_draw.clip) {
            imports.setScissorRect(rect.x, rect.y, rect.width, rect.height);
            bound_clip = packed_draw.clip;
        }
        if (bound_pipeline != packed_draw.pipeline) {
            imports.setPipeline(pipelines[@backingInt(packed_draw.pipeline)]);
            bound_pipeline = packed_draw.pipeline;
        }
        switch (packed_draw.pipeline.kind()) {
            .quad, .sprite => imports.draw(
                instance_vertex_count,
                packed_draw.count,
                0,
                packed_draw.first,
            ),
            .mesh => recordMeshes(frame, packed_draw),
            // checkCapabilities rejects custom fills: Capabilities.custom_shaders is false.
            .custom => unreachable,
        }
    }
}

fn recordMeshes(frame: *const PackedFrame, packed_draw: *const packed_mod.Draw) void {
    const meshes = frame.drawRange(packed_draw, .mesh);
    assert(meshes.len == packed_draw.count);
    for (meshes, packed_draw.first..) |*mesh, index| {
        assert(mesh.count > 0);
        assert(mesh.first + mesh.count <= frame.mesh_points.len);
        const vertex_count: u32 = switch (packed_draw.pipeline) {
            .triangles => count: {
                assert(mesh.edge_first + @divExact(mesh.count, 3) <= frame.triangle_count);
                break :count mesh_edges.draw_vertex_count(mesh.count);
            },
            .strip_expanded => count: {
                assert(mesh.count >= 2);
                break :count instance_vertex_count * (mesh.count - 1);
            },
            .point_instanced => instance_vertex_count * mesh.count,
            .quad, .glyph, .svg, .image, .custom => unreachable,
        };
        imports.draw(vertex_count, 1, 0, @intCast(index));
    }
}

fn frameCapacity(paint: *const limits_mod.PaintLimits) [frame_buffer_count]u32 {
    assert(paint.check() == null);
    const capacity = [frame_buffer_count]u32{
        packed_mod.quadCapacity(paint),
        packed_mod.spriteCapacity(paint),
        packed_mod.meshCapacity(paint),
        @max(packed_mod.meshPointCapacity(paint), 1),
        packed_mod.triangleCapacity(paint),
        1,
    };
    for (capacity) |count| assert(count > 0);
    return capacity;
}

fn elementBytes(buffer: FrameBuffer) u32 {
    return switch (buffer) {
        .quads => @sizeOf(packed_mod.Quad),
        .sprites => @sizeOf(packed_mod.Sprite),
        .meshes => @sizeOf(packed_mod.Mesh),
        .mesh_points => @sizeOf(packed_mod.MeshPoint),
        .edge_modes => @sizeOf(packed_mod.EdgeModes),
        .viewport => @sizeOf(Viewport),
    };
}

fn bufferBytes(capacity: *const [frame_buffer_count]u32, buffer: FrameBuffer) u64 {
    const bytes = @as(u64, capacity[@backingInt(buffer)]) * elementBytes(buffer);
    assert(bytes > 0);
    assert(bytes % 4 == 0);
    return bytes;
}

fn atlasBytesPerPixel(atlas: Atlas) u32 {
    return switch (atlas) {
        .glyph => 1,
        .svg, .image => 4,
    };
}

fn checkDevice(
    capacity: *const [frame_buffer_count]u32,
    atlas_sizes: *const [atlas_count]u32,
    window: *const limits_mod.WindowLimits,
) !void {
    const dimension_max = imports.deviceMaxTextureDimension2D();
    const binding_bytes_max = imports.deviceMaxStorageBufferBindingSize();
    assert(dimension_max > 0);
    assert(binding_bytes_max > 0);
    const framebuffer_side_max = @max(window.framebuffer_width_max, window.framebuffer_height_max);
    const side_max = @max(framebuffer_side_max, std.mem.max(u32, atlas_sizes));
    if (side_max > dimension_max) {
        imports.err("WebGPU: a {d} px texture side (ResourceLimits.window or .atlas) is past " ++
            "the device's maxTextureDimension2D of {d}", .{ side_max, dimension_max });
        return error.DeviceLimitExceeded;
    }
    for (std.enums.values(FrameBuffer)) |buffer| {
        const bytes = bufferBytes(capacity, buffer);
        if (bytes > binding_bytes_max) {
            imports.err("WebGPU: frame buffer '{t}' needs {d} B (ResourceLimits.paint), past " ++
                "the device's maxStorageBufferBindingSize of {d} B", .{
                buffer,
                bytes,
                binding_bytes_max,
            });
            return error.DeviceLimitExceeded;
        }
    }
}

fn assertFits(size_px: backend.SizePx, window: *const limits_mod.WindowLimits) void {
    assert(window.framebuffer_width_max > 0);
    assert(size_px.width <= window.framebuffer_width_max);
    assert(size_px.height <= window.framebuffer_height_max);
}

fn logicalSize(size_px: u32, scale_factor: f32) f32 {
    assert(size_px > 0);
    assert(scale_factor > 0);
    return @as(f32, @floatFromInt(size_px)) / scale_factor;
}
