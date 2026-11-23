const std = @import("std");
const d3d11 = @import("d3d11.zig");
const win32 = @import("win32.zig");
const dx11_device = @import("dx11_device.zig");
const dx11_swapchain = @import("dx11_swapchain.zig");
const dx11_resources = @import("dx11_resources.zig");
const dx11_uploads = @import("dx11_uploads.zig");
const geometry = @import("../../geometry/geometry.zig");
const backend = @import("../../core/backend.zig");
const packed_mod = @import("../../core/packed_frame.zig");
const limits_mod = @import("../../core/limits.zig");

const assert = std.debug.assert;
const log = std.log.scoped(.dx11);
const hex = dx11_device.hex;

const PackedFrame = packed_mod.PackedFrame;
const Pipeline = packed_mod.Pipeline;
const Atlas = dx11_resources.Atlas;
const InstanceBuffer = dx11_resources.InstanceBuffer;

pub const frame_count_max: u32 = limits_mod.MAX_FRAMES_IN_FLIGHT;

const quad_vertex_count: u32 = 6;
const triangle_vertex_count: u32 = 21;

const Uniforms = extern struct {
    viewport_width: f32,
    viewport_height: f32,
    pad: [2]f32 = .{ 0, 0 },
};

pub const FrameBuffers = struct {
    uniforms: *d3d11.ID3D11Buffer,
    quads: InstanceBuffer,
    sprites: InstanceBuffer,
    meshes: InstanceBuffer,
    mesh_points: InstanceBuffer,
    edge_modes: InstanceBuffer,
};

const Atlases = struct {
    glyph: Atlas,
    svg: Atlas,
    image: Atlas,
};

const VertexStage = enum { quad, sprite, triangles, strip, points };
const PixelStage = enum { quad, glyph, svg, image, mesh };

const vertex_stage_count = @typeInfo(VertexStage).@"enum".field_names.len;
const pixel_stage_count = @typeInfo(PixelStage).@"enum".field_names.len;

const vertex_dxbc = [vertex_stage_count][]const u8{
    @embedFile("shaders/quad.vs_main.dxbc"),
    @embedFile("shaders/sprite.vs_main.dxbc"),
    @embedFile("shaders/mesh.vs_triangles.dxbc"),
    @embedFile("shaders/mesh.vs_strip.dxbc"),
    @embedFile("shaders/mesh.vs_points.dxbc"),
};
const pixel_dxbc = [pixel_stage_count][]const u8{
    @embedFile("shaders/quad.ps_main.dxbc"),
    @embedFile("shaders/sprite.ps_glyph.dxbc"),
    @embedFile("shaders/sprite.ps_svg.dxbc"),
    @embedFile("shaders/sprite.ps_image.dxbc"),
    @embedFile("shaders/mesh.ps_mesh.dxbc"),
};

pub const Shaders = struct {
    vertex: [vertex_stage_count]*d3d11.ID3D11VertexShader,
    layouts: [vertex_stage_count]*d3d11.ID3D11InputLayout,
    pixel: [pixel_stage_count]*d3d11.ID3D11PixelShader,
};

const PipelineState = struct {
    vertex: VertexStage,
    pixel: PixelStage,
    premultiplied: bool,
};

fn pipelineState(pipeline: Pipeline) PipelineState {
    return switch (pipeline) {
        .quad => .{ .vertex = .quad, .pixel = .quad, .premultiplied = false },
        .glyph => .{ .vertex = .sprite, .pixel = .glyph, .premultiplied = false },
        .svg => .{ .vertex = .sprite, .pixel = .svg, .premultiplied = true },
        .image => .{ .vertex = .sprite, .pixel = .image, .premultiplied = false },
        .triangles => .{ .vertex = .triangles, .pixel = .mesh, .premultiplied = true },
        .strip_expanded => .{ .vertex = .strip, .pixel = .mesh, .premultiplied = true },
        .point_instanced => .{ .vertex = .points, .pixel = .mesh, .premultiplied = true },
    };
}

pub const InitError = dx11_device.Device.CreateError ||
    dx11_swapchain.Swapchain.CreateError ||
    dx11_resources.ResourceError ||
    error{ Dx11BufferPastResourceLimit, WindowTooLarge };

pub const Dx11Renderer = struct {
    device: dx11_device.Device,
    swapchain: ?dx11_swapchain.Swapchain,
    states: dx11_resources.States,
    atlases: Atlases,
    shaders: Shaders,
    instance_indices: *d3d11.ID3D11Buffer,
    uploads: dx11_uploads.Uploads,
    size_px: backend.SizePx,
    frames: [frame_count_max]FrameBuffers,
    frame_count: u32,
    frame_index: u32,
    limits: backend.RenderLimits,
    device_lost: bool,
    drawable_missing_logged: bool,
    initialized: bool,

    const Self = @This();

    comptime {
        backend.verifyRenderer(Self);
        assert(@sizeOf(Self) <= 2 * 1024);
    }

    pub fn initInPlace(
        self: *Self,
        surface: *const backend.Surface,
        limits: *const backend.RenderLimits,
    ) InitError!void {
        return self.initInPlaceWithDriver(surface, limits, .hardware_then_warp);
    }

    pub fn initInPlaceWithDriver(
        self: *Self,
        surface: *const backend.Surface,
        limits: *const backend.RenderLimits,
        preference: dx11_device.DriverPreference,
    ) InitError!void {
        assert(surface.scale_factor > 0);
        assert(limits.paint.check() == null);
        const window = &limits.window;
        if (surface.size_px.width > window.framebuffer_width_max) return error.WindowTooLarge;
        if (surface.size_px.height > window.framebuffer_height_max) return error.WindowTooLarge;
        self.initialized = false;
        self.limits = limits.*;
        self.frame_count = limits.frame.in_flight_count;
        self.frame_index = 0;
        self.size_px = surface.size_px;
        self.device_lost = false;
        self.drawable_missing_logged = false;
        assert(self.frame_count >= dx11_swapchain.buffer_count_min);
        assert(self.frame_count <= frame_count_max);

        self.device = try dx11_device.Device.create(preference);
        errdefer self.device.release();
        self.device.logAdapter();

        self.swapchain = null;
        if (surface.native) |native| {
            const hwnd: win32.HWND = @ptrCast(native);
            self.swapchain = try dx11_swapchain.Swapchain.create(&self.device, hwnd, .{
                .width_px = @max(surface.size_px.width, 1),
                .height_px = @max(surface.size_px.height, 1),
                .buffer_count = self.frame_count,
            });
        }
        errdefer if (self.swapchain) |*swapchain| swapchain.release();

        try self.initResources();
        self.initialized = true;
        log.info("DirectX 11 renderer: {d}x{d} px at scale {d:.2}, {d} frames in flight", .{
            surface.size_px.width,
            surface.size_px.height,
            surface.scale_factor,
            self.frame_count,
        });
    }

    fn initResources(self: *Self) InitError!void {
        assert(self.frame_count > 0);
        if (bufferPastBound(&self.limits)) |buffer| {
            log.err("frame buffer '{t}' needs {d} B (ResourceLimits.{s}), past the {d} B " ++
                "every D3D11 device accepts", .{
                buffer,
                bufferBytes(&self.limits, buffer),
                buffer.budget(),
                dx11_resources.buffer_bytes_max,
            });
            return error.Dx11BufferPastResourceLimit;
        }
        self.states = try dx11_resources.States.create(&self.device);
        errdefer self.states.release();

        self.atlases = try createAtlases(&self.device, &self.limits.atlas);
        errdefer releaseAtlases(&self.atlases);

        self.shaders = try createShaders(&self.device);
        errdefer releaseShaders(&self.shaders);

        const paint = &self.limits.paint;
        self.instance_indices = try dx11_resources.createIndexSequence(
            &self.device,
            instanceIndexCount(&self.limits),
        );
        errdefer self.instance_indices.release();

        try self.uploads.init(&self.device, &self.limits.atlas, self.frame_count);
        errdefer self.uploads.deinit(self.device.context);

        var created: u32 = 0;
        errdefer for (self.frames[0..created]) |*frame| releaseFrame(frame);
        while (created < self.frame_count) : (created += 1) {
            self.frames[created] = try createFrame(&self.device, paint);
        }
        assert(created == self.frame_count);
    }

    pub fn deinit(self: *Self) void {
        assert(self.initialized);
        assert(self.frame_count <= frame_count_max);
        for (self.frames[0..self.frame_count]) |*frame| releaseFrame(frame);
        self.uploads.deinit(self.device.context);
        self.instance_indices.release();
        releaseShaders(&self.shaders);
        releaseAtlases(&self.atlases);
        self.states.release();
        if (self.swapchain) |*swapchain| swapchain.release();
        self.device.release();
        self.initialized = false;
    }

    pub fn capabilities(self: *const Self) backend.Capabilities {
        assert(self.initialized);
        return .{ .meshes = true };
    }

    pub fn swapchainUsable(self: *const Self) bool {
        assert(self.initialized);
        const swapchain = self.swapchain orelse return false;
        return swapchain.usable();
    }

    pub fn resize(self: *Self, size_px: backend.SizePx) void {
        assert(self.initialized);
        assert(size_px.width <= self.limits.window.framebuffer_width_max);
        assert(size_px.height <= self.limits.window.framebuffer_height_max);
        self.size_px = size_px;
        const swapchain = &(self.swapchain orelse return);
        if (size_px.width == 0) return;
        if (size_px.height == 0) return;
        const same_size = size_px.width == swapchain.width_px and
            size_px.height == swapchain.height_px;
        if (same_size and swapchain.usable()) return;
        _ = swapchain.resize(&self.device, size_px.width, size_px.height);
    }

    pub fn uploadAtlas(
        self: *Self,
        atlas: backend.AtlasKind,
        dirty: backend.RectPx,
        pixels: []const u8,
    ) void {
        assert(self.initialized);
        assert(dirty.width > 0);
        assert(dirty.height > 0);
        if (self.device_lost) return;
        const slot: dx11_uploads.Slot = switch (atlas) {
            .glyph => .glyph,
            .svg => .svg,
            .image => .image,
            .glyph_color => std.debug.panic("dx11: no glyph_color atlas is reserved", .{}),
        };
        const side_px = self.atlasTargets()[@backingInt(slot)].side_px;
        if (!self.uploads.stage(self.device.context, slot, side_px, dirty, pixels)) {
            self.loseDevice();
        }
    }

    pub fn draw(
        self: *Self,
        frame: *const PackedFrame,
        viewport: backend.Viewport,
        clear: geometry.Color,
    ) void {
        assert(self.initialized);
        assert(viewport.scale_factor > 0);
        assert(viewport.size_px.width == self.size_px.width);
        assert(viewport.size_px.height == self.size_px.height);
        if (self.device_lost) return;
        self.flushUploads();
        if (viewport.size_px.width == 0) return;
        if (viewport.size_px.height == 0) return;
        if (!self.drawableReady(frame.frame_number)) return;
        const swapchain = &self.swapchain.?;
        assert(viewport.size_px.width == swapchain.width_px);
        assert(viewport.size_px.height == swapchain.height_px);
        swapchain.waitForFrame();
        if (!self.encode(swapchain.target_view.?, frame, viewport, clear)) {
            self.loseDevice();
            return;
        }
        switch (swapchain.present()) {
            .presented, .occluded => {},
            .device_lost => self.loseDevice(),
        }
    }

    fn flushUploads(self: *Self) void {
        assert(self.initialized);
        assert(!self.device_lost);
        const targets = self.atlasTargets();
        const rasterizer = self.states.rasterizer;
        self.uploads.flush(self.device.context, &targets, self.instance_indices, rasterizer);
    }

    fn atlasTargets(self: *const Self) [dx11_uploads.atlas_count]dx11_uploads.Target {
        assert(self.atlases.glyph.format == .r8);
        assert(self.atlases.image.format == .rgba8);
        return .{
            .{ .view = self.atlases.glyph.target, .side_px = self.atlases.glyph.side_px },
            .{ .view = self.atlases.svg.target, .side_px = self.atlases.svg.side_px },
            .{ .view = self.atlases.image.target, .side_px = self.atlases.image.side_px },
        };
    }

    fn drawableReady(self: *Self, frame_number: u64) bool {
        if (self.swapchainUsable()) {
            self.drawable_missing_logged = false;
            return true;
        }
        if (!self.drawable_missing_logged) {
            log.err("frame {d} not drawn: no drawable (headless, or a failed resize)", .{
                frame_number,
            });
        }
        self.drawable_missing_logged = true;
        return false;
    }

    pub fn encode(
        self: *Self,
        target: *d3d11.ID3D11RenderTargetView,
        frame: *const PackedFrame,
        viewport: backend.Viewport,
        clear: geometry.Color,
    ) bool {
        assert(self.initialized);
        assert(viewport.size_px.width > 0);
        assert(viewport.size_px.height > 0);
        self.flushUploads();
        const buffers = &self.frames[self.frame_index];
        self.frame_index = (self.frame_index + 1) % self.frame_count;
        if (!writeFrame(self.device.context, buffers, frame, viewport)) return false;

        const context = self.device.context;
        bindTarget(context, &self.states, target, viewport.size_px);
        const clear_rgba = [4]f32{ clear.r, clear.g, clear.b, clear.a };
        context.vtable.ClearRenderTargetView(context, target, &clear_rgba);
        self.bindFrame(buffers);
        self.encodeDraws(buffers, frame, viewport);
        return true;
    }

    fn bindFrame(self: *const Self, buffers: *const FrameBuffers) void {
        const context = self.device.context;
        const streams = [_]?*d3d11.ID3D11Buffer{self.instance_indices};
        const strides = [_]u32{@sizeOf(u32)};
        const offsets = [_]u32{0};
        context.vtable.IASetVertexBuffers(context, 0, 1, &streams, &strides, &offsets);
        const constants = [_]?*d3d11.ID3D11Buffer{buffers.uniforms};
        context.vtable.VSSetConstantBuffers(context, 0, 1, &constants);
        const samplers = [_]?*d3d11.ID3D11SamplerState{self.states.sampler};
        context.vtable.PSSetSamplers(context, 0, 1, &samplers);
    }

    fn encodeDraws(
        self: *const Self,
        buffers: *const FrameBuffers,
        frame: *const PackedFrame,
        viewport: backend.Viewport,
    ) void {
        const context = self.device.context;
        const clips = frame.clipList();
        var pipeline_bound: ?Pipeline = null;
        var clip_bound: ?u32 = null;
        var clip_empty = false;
        for (frame.drawList()) |*packed_draw| {
            assert(packed_draw.count > 0);
            if (clip_bound != packed_draw.clip) {
                assert(packed_draw.clip < clips.len);
                const clip = clips[packed_draw.clip];
                assert(clip[2] > 0);
                assert(clip[3] > 0);
                const rect = scissorRect(clip, viewport);
                clip_empty = rect.right <= rect.left or rect.bottom <= rect.top;
                if (!clip_empty) context.vtable.RSSetScissorRects(context, 1, (&rect)[0..1]);
                clip_bound = packed_draw.clip;
            }
            if (clip_empty) continue;
            if (pipeline_bound != packed_draw.pipeline) {
                self.bindPipeline(buffers, packed_draw.pipeline);
                pipeline_bound = packed_draw.pipeline;
            }
            switch (packed_draw.pipeline.kind()) {
                .quad, .sprite => context.vtable.DrawInstanced(
                    context,
                    quad_vertex_count,
                    packed_draw.count,
                    0,
                    packed_draw.first,
                ),
                .mesh => drawMeshes(context, frame, packed_draw),
            }
        }
    }

    fn bindPipeline(self: *const Self, buffers: *const FrameBuffers, pipeline: Pipeline) void {
        const context = self.device.context;
        const state = pipelineState(pipeline);
        const vertex = @backingInt(state.vertex);
        context.vtable.IASetInputLayout(context, self.shaders.layouts[vertex]);
        context.vtable.IASetPrimitiveTopology(context, d3d11.D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        context.vtable.VSSetShader(context, self.shaders.vertex[vertex], null, 0);
        context.vtable.PSSetShader(context, self.shaders.pixel[@backingInt(state.pixel)], null, 0);
        const blend = if (state.premultiplied)
            self.states.blend_premultiplied
        else
            self.states.blend_straight;
        context.vtable.OMSetBlendState(context, blend, null, 0xFFFF_FFFF);
        const instances = switch (pipeline.kind()) {
            .quad => buffers.quads.view,
            .sprite => buffers.sprites.view,
            .mesh => buffers.meshes.view,
        };
        const views = [_]?*d3d11.ID3D11ShaderResourceView{
            instances,
            buffers.mesh_points.view,
            buffers.edge_modes.view,
        };
        context.vtable.VSSetShaderResources(context, 0, views.len, &views);
        const atlas: ?*d3d11.ID3D11ShaderResourceView = switch (pipeline) {
            .glyph => self.atlases.glyph.view,
            .svg => self.atlases.svg.view,
            .image => self.atlases.image.view,
            .quad, .triangles, .strip_expanded, .point_instanced => null,
        };
        if (atlas) |view| {
            const atlas_views = [_]?*d3d11.ID3D11ShaderResourceView{view};
            context.vtable.PSSetShaderResources(context, 3, 1, &atlas_views);
        }
    }

    fn loseDevice(self: *Self) void {
        assert(!self.device_lost);
        const reason = self.device.device.vtable.GetDeviceRemovedReason(self.device.device);
        log.err("Direct3D 11 device lost (reason 0x{X:0>8}); frames are no longer drawn", .{
            hex(reason),
        });
        self.device_lost = true;
    }
};

fn drawMeshes(
    context: *d3d11.ID3D11DeviceContext,
    frame: *const PackedFrame,
    packed_draw: *const packed_mod.Draw,
) void {
    assert(packed_draw.pipeline.kind() == .mesh);
    const meshes = frame.drawRange(packed_draw, .mesh);
    for (meshes, packed_draw.first..) |*mesh, mesh_index| {
        const vertex_count = meshVertexCount(packed_draw.pipeline, mesh.count);
        if (vertex_count == 0) continue;
        context.vtable.DrawInstanced(context, vertex_count, 1, 0, @intCast(mesh_index));
    }
}

pub fn meshVertexCount(pipeline: Pipeline, point_count: u32) u32 {
    assert(point_count > 0);
    return switch (pipeline) {
        .triangles => blk: {
            assert(point_count % 3 == 0);
            break :blk @divExact(point_count, 3) * triangle_vertex_count;
        },
        .strip_expanded => (point_count - 1) * quad_vertex_count,
        .point_instanced => point_count * quad_vertex_count,
        .quad, .glyph, .svg, .image => unreachable,
    };
}

pub fn scissorRect(clip: packed_mod.Rect, viewport: backend.Viewport) d3d11.D3D11_RECT {
    assert(clip[2] >= 0);
    assert(clip[3] >= 0);
    const scale = viewport.scale_factor;
    const width: f32 = @floatFromInt(viewport.size_px.width);
    const height: f32 = @floatFromInt(viewport.size_px.height);
    const left = std.math.clamp(@ceil(clip[0] * scale - 0.5), 0, width);
    const top = std.math.clamp(@ceil(clip[1] * scale - 0.5), 0, height);
    const right = std.math.clamp(@floor((clip[0] + clip[2]) * scale - 0.5) + 1, 0, width);
    const bottom = std.math.clamp(@floor((clip[1] + clip[3]) * scale - 0.5) + 1, 0, height);
    const rect = d3d11.D3D11_RECT{
        .left = @intFromFloat(left),
        .top = @intFromFloat(top),
        .right = @intFromFloat(@max(right, left)),
        .bottom = @intFromFloat(@max(bottom, top)),
    };
    assert(rect.right <= viewport.size_px.width);
    assert(rect.bottom <= viewport.size_px.height);
    return rect;
}

fn writeFrame(
    context: *d3d11.ID3D11DeviceContext,
    buffers: *const FrameBuffers,
    frame: *const PackedFrame,
    viewport: backend.Viewport,
) bool {
    const width: f32 = @floatFromInt(viewport.size_px.width);
    const height: f32 = @floatFromInt(viewport.size_px.height);
    const uniforms = Uniforms{
        .viewport_width = width / viewport.scale_factor,
        .viewport_height = height / viewport.scale_factor,
    };
    if (!dx11_resources.mapWrite(context, buffers.uniforms, std.mem.asBytes(&uniforms))) {
        return false;
    }
    const arrays = [_]struct { buffer: *const InstanceBuffer, bytes: []const u8 }{
        .{ .buffer = &buffers.quads, .bytes = std.mem.sliceAsBytes(frame.quadList()) },
        .{ .buffer = &buffers.sprites, .bytes = std.mem.sliceAsBytes(frame.spriteList()) },
        .{ .buffer = &buffers.meshes, .bytes = std.mem.sliceAsBytes(frame.meshList()) },
        .{ .buffer = &buffers.mesh_points, .bytes = std.mem.sliceAsBytes(frame.mesh_points) },
        .{ .buffer = &buffers.edge_modes, .bytes = std.mem.sliceAsBytes(frame.edgeModeList()) },
    };
    for (arrays) |array| {
        assert(array.bytes.len <= @as(usize, array.buffer.count_max) * array.buffer.stride_bytes);
        if (!array.buffer.write(context, array.bytes)) return false;
    }
    return true;
}

pub fn bindTarget(
    context: *d3d11.ID3D11DeviceContext,
    states: *const dx11_resources.States,
    view: *d3d11.ID3D11RenderTargetView,
    size_px: backend.SizePx,
) void {
    assert(size_px.width > 0);
    assert(size_px.height > 0);
    const views = [_]?*d3d11.ID3D11RenderTargetView{view};
    context.vtable.OMSetRenderTargets(context, 1, &views, null);
    const viewport = d3d11.D3D11_VIEWPORT{
        .TopLeftX = 0,
        .TopLeftY = 0,
        .Width = @floatFromInt(size_px.width),
        .Height = @floatFromInt(size_px.height),
        .MinDepth = 0,
        .MaxDepth = 1,
    };
    context.vtable.RSSetViewports(context, 1, (&viewport)[0..1]);
    const scissor = d3d11.D3D11_RECT{
        .left = 0,
        .top = 0,
        .right = @intCast(size_px.width),
        .bottom = @intCast(size_px.height),
    };
    context.vtable.RSSetScissorRects(context, 1, (&scissor)[0..1]);
    context.vtable.RSSetState(context, states.rasterizer);
}

pub const SizedBuffer = enum {
    quads,
    sprites,
    meshes,
    mesh_points,
    edge_modes,
    instance_indices,
    upload_words,

    pub fn budget(self: SizedBuffer) []const u8 {
        return switch (self) {
            .quads, .sprites, .meshes, .mesh_points, .edge_modes => "paint",
            .instance_indices => "paint and ResourceLimits.atlas",
            .upload_words => "atlas.upload_bytes_frame_max",
        };
    }
};

pub fn bufferBytes(limits: *const backend.RenderLimits, buffer: SizedBuffer) u64 {
    const paint = &limits.paint;
    const bytes: u64 = switch (buffer) {
        .quads => @as(u64, packed_mod.quadCapacity(paint)) * @sizeOf(packed_mod.Quad),
        .sprites => @as(u64, packed_mod.spriteCapacity(paint)) * @sizeOf(packed_mod.Sprite),
        .meshes => @as(u64, packed_mod.meshCapacity(paint)) * @sizeOf(packed_mod.Mesh),
        .mesh_points => @as(u64, @max(packed_mod.meshPointCapacity(paint), 1)) *
            @sizeOf(packed_mod.MeshPoint),
        .edge_modes => @as(u64, packed_mod.triangleCapacity(paint)) *
            @sizeOf(packed_mod.EdgeModes),
        .instance_indices => @as(u64, instanceIndexCount(limits)) * @sizeOf(u32),
        .upload_words => dx11_uploads.Uploads.wordsBytes(&limits.atlas),
    };
    assert(bytes > 0);
    return bytes;
}

pub fn bufferPastBound(limits: *const backend.RenderLimits) ?SizedBuffer {
    assert(limits.paint.check() == null);
    for (std.enums.values(SizedBuffer)) |buffer| {
        if (bufferBytes(limits, buffer) > dx11_resources.buffer_bytes_max) return buffer;
    }
    return null;
}

fn instanceIndexCount(limits: *const backend.RenderLimits) u32 {
    const paint = &limits.paint;
    const count = @max(
        packed_mod.quadCapacity(paint),
        packed_mod.spriteCapacity(paint),
        packed_mod.meshCapacity(paint),
        dx11_uploads.Uploads.recordCountMax(&limits.atlas),
    );
    assert(count > 0);
    return count;
}

fn createAtlases(
    device: *const dx11_device.Device,
    limits: *const limits_mod.AtlasLimits,
) dx11_resources.ResourceError!Atlases {
    assert(limits.text_size > 0);
    assert(limits.image_size > 0);
    var glyph = try Atlas.create(device, limits.text_size, .r8);
    errdefer glyph.release();
    var svg = try Atlas.create(device, limits.svg_size, .rgba8);
    errdefer svg.release();
    const image = try Atlas.create(device, limits.image_size, .rgba8);
    return .{ .glyph = glyph, .svg = svg, .image = image };
}

fn releaseAtlases(atlases: *Atlases) void {
    assert(atlases.glyph.format == .r8);
    atlases.image.release();
    atlases.svg.release();
    atlases.glyph.release();
}

pub fn createShaders(device: *const dx11_device.Device) dx11_resources.ResourceError!Shaders {
    var shaders: Shaders = undefined;
    var vertex_count: u32 = 0;
    errdefer for (shaders.vertex[0..vertex_count]) |shader| shader.release();
    var layout_count: u32 = 0;
    errdefer for (shaders.layouts[0..layout_count]) |layout| layout.release();
    var pixel_count: u32 = 0;
    errdefer for (shaders.pixel[0..pixel_count]) |shader| shader.release();

    for (vertex_dxbc) |bytecode| {
        shaders.vertex[vertex_count] = try dx11_resources.createVertexShader(device, bytecode);
        vertex_count += 1;
        shaders.layouts[layout_count] = try dx11_resources.createInstanceLayout(device, bytecode);
        layout_count += 1;
    }
    for (pixel_dxbc) |bytecode| {
        shaders.pixel[pixel_count] = try dx11_resources.createPixelShader(device, bytecode);
        pixel_count += 1;
    }
    assert(vertex_count == vertex_stage_count);
    assert(pixel_count == pixel_stage_count);
    return shaders;
}

pub fn releaseShaders(shaders: *Shaders) void {
    for (shaders.pixel) |shader| shader.release();
    for (shaders.layouts) |layout| layout.release();
    for (shaders.vertex) |shader| shader.release();
}

pub fn createFrame(
    device: *const dx11_device.Device,
    paint: *const limits_mod.PaintLimits,
) dx11_resources.ResourceError!FrameBuffers {
    assert(paint.check() == null);
    const uniforms = try dx11_resources.createConstantBuffer(device, @sizeOf(Uniforms));
    errdefer uniforms.release();
    var quads = try InstanceBuffer.create(device, .{
        .name = "quads",
        .count_max = packed_mod.quadCapacity(paint),
        .stride_bytes = @sizeOf(packed_mod.Quad),
    });
    errdefer quads.release();
    var sprites = try InstanceBuffer.create(device, .{
        .name = "sprites",
        .count_max = packed_mod.spriteCapacity(paint),
        .stride_bytes = @sizeOf(packed_mod.Sprite),
    });
    errdefer sprites.release();
    var meshes = try InstanceBuffer.create(device, .{
        .name = "meshes",
        .count_max = packed_mod.meshCapacity(paint),
        .stride_bytes = @sizeOf(packed_mod.Mesh),
    });
    errdefer meshes.release();
    var mesh_points = try InstanceBuffer.create(device, .{
        .name = "mesh points",
        .count_max = @max(packed_mod.meshPointCapacity(paint), 1),
        .stride_bytes = @sizeOf(packed_mod.MeshPoint),
    });
    errdefer mesh_points.release();
    const edge_modes = try InstanceBuffer.create(device, .{
        .name = "edge modes",
        .count_max = packed_mod.triangleCapacity(paint),
        .stride_bytes = @sizeOf(packed_mod.EdgeModes),
    });
    return .{
        .uniforms = uniforms,
        .quads = quads,
        .sprites = sprites,
        .meshes = meshes,
        .mesh_points = mesh_points,
        .edge_modes = edge_modes,
    };
}

pub fn releaseFrame(frame: *FrameBuffers) void {
    frame.edge_modes.release();
    frame.mesh_points.release();
    frame.meshes.release();
    frame.sprites.release();
    frame.quads.release();
    frame.uniforms.release();
}

comptime {
    assert(@sizeOf(Uniforms) == 16);
    for (vertex_dxbc ++ pixel_dxbc) |bytecode| assert(std.mem.eql(u8, bytecode[0..4], "DXBC"));
}
