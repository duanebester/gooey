//! Metal Renderer - Main GPU rendering coordinator

const std = @import("std");
const assert = std.debug.assert;
const objc = @import("objc");

const interface_verify = @import("../../../core/interface_verify.zig");
const geometry = @import("../../../core/geometry.zig");
const scene_mod = @import("../../../scene/mod.zig");
const SceneLimits = @import("../../../core/limits.zig").SceneLimits;
const mtl = @import("api.zig");
const pipelines = @import("pipelines.zig");
const render_pass = @import("render_pass.zig");
const scene_renderer = @import("scene_renderer.zig");
const post_process = @import("post_process.zig");
const scissor = @import("scissor.zig");
const text_pipeline = @import("text.zig");
const custom_shader = @import("custom_shader.zig");
const svg_pipeline = @import("svg_pipeline.zig");
const image_pipeline = @import("image_pipeline.zig");
const path_pipeline = @import("path_pipeline.zig");
const polyline_pipeline = @import("polyline_pipeline.zig");
const point_cloud_pipeline = @import("point_cloud_pipeline.zig");
const colored_point_cloud_pipeline = @import("colored_point_cloud_pipeline.zig");
const DrawableReserve = @import("drawable_reserve.zig").DrawableReserve;
const Atlas = @import("../../../text/mod.zig").Atlas;

pub const Vertex = extern struct {
    position: [2]f32,
    color: [4]f32,
};

pub const ScissorRect = scissor.ScissorRect;

pub const Renderer = struct {
    // Compile-time interface verification
    comptime {
        interface_verify.verifyRendererInterface(@This());
    }

    device: objc.Object,
    command_queue: objc.Object,
    layer: objc.Object,
    /// Asynchronous frames take their drawable from here, so the main thread never waits
    /// in `nextDrawable`. Must not move after the first frame (see `DrawableReserve`).
    drawable_reserve: DrawableReserve,
    unified_memory: bool,

    // Single unified pipeline for quads + shadows
    unified_pipeline_state: ?objc.Object,
    unified_primitive_ring: scene_renderer.UnifiedPrimitiveRing,
    text_pipeline_state: ?text_pipeline.TextPipeline,
    svg_pipeline_state: ?svg_pipeline.SvgPipeline,
    image_pipeline_state: ?image_pipeline.ImagePipeline,
    path_pipeline_state: ?path_pipeline.PathPipeline,
    polyline_pipeline_state: ?polyline_pipeline.PolylinePipeline,
    point_cloud_pipeline_state: ?point_cloud_pipeline.PointCloudPipeline,
    colored_point_cloud_pipeline_state: ?colored_point_cloud_pipeline.ColoredPointCloudPipeline,

    quad_unit_vertex_buffer: ?objc.Object,
    msaa_texture: ?objc.Object,
    sample_count: u32,

    size: geometry.Size(f64),
    scale_factor: f64,

    post_process_state: ?custom_shader.PostProcessState,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// `scene_limits` is the window's validated budget; the quad/shadow instance ring
    /// is reserved from it instead of the framework ceilings.
    pub fn init(
        allocator: std.mem.Allocator,
        layer: objc.Object,
        size: geometry.Size(f64),
        scale_factor: f64,
        scene_limits: *const SceneLimits,
    ) !Self {
        const device_ptr = mtl.MTLCreateSystemDefaultDevice() orelse
            return error.MetalNotAvailable;
        const device = objc.Object.fromId(device_ptr);

        const unified_memory = device.msgSend(bool, "hasUnifiedMemory", .{});
        const command_queue = device.msgSend(objc.Object, "newCommandQueue", .{});

        layer.msgSend(void, "setDevice:", .{device.value});
        layer.msgSend(void, "setDrawableSize:", .{mtl.CGSize{
            .width = size.width * scale_factor,
            .height = size.height * scale_factor,
        }});

        const sample_count: u32 = 4;

        // The ring's in-flight safety proof relies on every frame holding one of at most
        // `frame_count` drawables (see `UnifiedPrimitiveRing`).
        const drawable_count_max = layer.msgSend(c_ulong, "maximumDrawableCount", .{});
        assert(drawable_count_max >= 2);
        assert(drawable_count_max <= scene_renderer.UnifiedPrimitiveRing.frame_count);

        var unified_primitive_ring =
            try scene_renderer.UnifiedPrimitiveRing.init(device, scene_limits);
        errdefer unified_primitive_ring.deinit();

        // No acquisition is requested before the first frame, so moving this value into
        // the returned renderer is safe.
        var drawable_reserve = try DrawableReserve.init(layer);
        errdefer drawable_reserve.deinit();

        var self = Self{
            .device = device,
            .command_queue = command_queue,
            .layer = layer,
            .drawable_reserve = drawable_reserve,
            .unified_memory = unified_memory,
            .unified_pipeline_state = null,
            .unified_primitive_ring = unified_primitive_ring,
            .text_pipeline_state = null,
            .svg_pipeline_state = null,
            .image_pipeline_state = null,
            .path_pipeline_state = null,
            .polyline_pipeline_state = null,
            .point_cloud_pipeline_state = null,
            .colored_point_cloud_pipeline_state = null,
            .quad_unit_vertex_buffer = null,
            .msaa_texture = null,
            .sample_count = sample_count,
            .size = size,
            .scale_factor = scale_factor,
            .post_process_state = null,
            .allocator = allocator,
        };

        self.msaa_texture = try pipelines.createMSAATexture(
            device,
            size.width,
            size.height,
            scale_factor,
            sample_count,
            unified_memory,
        );

        self.unified_pipeline_state = try pipelines.setupUnifiedPipeline(device, sample_count);
        self.quad_unit_vertex_buffer = try pipelines.createUnitVertexBuffer(device, unified_memory);

        self.initOptionalPipelines(sample_count);
        return self;
    }

    /// Create the optional pipelines. Each one that fails to build stays null and its
    /// primitives are skipped, as before this was split out of `init`.
    fn initOptionalPipelines(self: *Self, sample_count: u32) void {
        assert(sample_count > 0);
        assert(self.text_pipeline_state == null);
        const device = self.device;

        self.text_pipeline_state = text_pipeline.TextPipeline.init(
            device,
            mtl.MTLPixelFormat.bgra8unorm,
            sample_count,
        ) catch null;

        // Instanced pipelines for SVGs, images, paths, chart polylines, and scatter points.
        const allocator = self.allocator;
        const samples: u32 = sample_count;
        self.svg_pipeline_state = svg_pipeline.SvgPipeline.init(
            allocator,
            device,
            @intCast(samples),
        ) catch null;
        self.image_pipeline_state = image_pipeline.ImagePipeline.init(
            allocator,
            device,
            @intCast(samples),
        ) catch null;
        self.path_pipeline_state = path_pipeline.PathPipeline.init(
            allocator,
            device,
            @intCast(samples),
        ) catch null;
        self.polyline_pipeline_state = polyline_pipeline.PolylinePipeline.init(
            allocator,
            device,
            @intCast(samples),
        ) catch null;
        self.point_cloud_pipeline_state = point_cloud_pipeline.PointCloudPipeline.init(
            allocator,
            device,
            @intCast(samples),
        ) catch null;
        const ColoredPointCloudPipeline = colored_point_cloud_pipeline.ColoredPointCloudPipeline;
        self.colored_point_cloud_pipeline_state = ColoredPointCloudPipeline.init(
            allocator,
            device,
            @intCast(samples),
        ) catch null;
    }

    pub fn deinit(self: *Self) void {
        // First: waits out an in-flight acquisition that still uses the layer.
        self.drawable_reserve.deinit();
        if (self.msaa_texture) |tex| tex.release();
        if (self.unified_pipeline_state) |ps| ps.release();
        self.unified_primitive_ring.deinit();
        if (self.quad_unit_vertex_buffer) |vb| vb.release();
        if (self.text_pipeline_state) |*tp| tp.deinit();
        if (self.svg_pipeline_state) |*sp| sp.deinit();
        if (self.image_pipeline_state) |*ip| ip.deinit();
        if (self.path_pipeline_state) |*pp| pp.deinit();
        if (self.polyline_pipeline_state) |*plp| plp.deinit();
        if (self.point_cloud_pipeline_state) |*pcp| pcp.deinit();
        if (self.colored_point_cloud_pipeline_state) |*cpcp| cpcp.deinit();
        if (self.post_process_state) |*pp| pp.deinit();
        self.command_queue.release();
        self.device.release();
    }

    pub fn clear(self: *Self, color: geometry.Color) void {
        self.renderInternal(color, false);
    }

    pub fn clearSynchronous(self: *Self, color: geometry.Color) void {
        self.renderInternal(color, true);
    }

    pub fn render(self: *Self, clear_color: geometry.Color) void {
        self.renderInternal(clear_color, false);
    }

    pub fn renderScene(self: *Self, scene: *const scene_mod.Scene, clear_color: geometry.Color) !void {
        try self.renderSceneInternal(scene, clear_color, false);
    }

    pub fn renderSceneSynchronous(self: *Self, scene: *const scene_mod.Scene, clear_color: geometry.Color) !void {
        try self.renderSceneInternal(scene, clear_color, true);
    }

    pub fn renderSceneWithPostProcess(
        self: *Self,
        scene: *const scene_mod.Scene,
        clear_color: geometry.Color,
    ) !void {
        var pp = &(self.post_process_state orelse {
            try self.renderScene(scene, clear_color);
            return;
        });

        if (!pp.hasShaders()) {
            try self.renderScene(scene, clear_color);
            return;
        }

        // Before the rings advance: a skipped frame must not consume a ring slot.
        const drawable = self.acquireDrawable(false) orelse return;
        defer drawable.release();
        const drawable_texture = drawableTexture(drawable) orelse return;

        self.unified_primitive_ring.nextFrame();
        if (self.text_pipeline_state) |*tp| tp.nextFrame();

        const width: u32 = @intFromFloat(self.size.width * self.scale_factor);
        const height: u32 = @intFromFloat(self.size.height * self.scale_factor);
        try pp.ensureSize(width, height);

        pp.updateTiming();
        pp.uploadUniforms();

        // Use the new unified single-command-buffer pipeline
        try post_process.renderFullPipeline(
            self.command_queue,
            .{ .drawable = drawable, .texture = drawable_texture },
            scene,
            clear_color,
            self.msaa_texture.?,
            self.quad_unit_vertex_buffer.?,
            self.unified_pipeline_state,
            &self.unified_primitive_ring,
            if (self.text_pipeline_state) |*tp| tp else null,
            if (self.svg_pipeline_state) |*sp| sp else null,
            pp,
            self.size,
            self.scale_factor,
        );
    }

    pub fn initPostProcess(self: *Self) !void {
        if (self.post_process_state != null) return;
        self.post_process_state = custom_shader.PostProcessState.init(self.allocator, self.device);
    }

    pub fn addCustomShader(self: *Self, shader_source: []const u8, name: []const u8) !void {
        if (self.post_process_state == null) try self.initPostProcess();
        try self.post_process_state.?.addShader(shader_source, name, mtl.MTLPixelFormat.bgra8unorm, 1);
    }

    pub fn hasCustomShaders(self: *const Self) bool {
        if (self.post_process_state) |pp| return pp.hasShaders();
        return false;
    }

    pub fn getPostProcess(self: *Self) ?*custom_shader.PostProcessState {
        return if (self.post_process_state) |*pp| pp else null;
    }

    pub fn resize(self: *Self, size: geometry.Size(f64), scale_factor: f64) void {
        self.size = size;
        self.scale_factor = scale_factor;
        self.layer.msgSend(void, "setDrawableSize:", .{mtl.CGSize{
            .width = size.width * scale_factor,
            .height = size.height * scale_factor,
        }});

        if (self.msaa_texture) |tex| tex.release();
        self.msaa_texture = pipelines.createMSAATexture(
            self.device,
            size.width,
            size.height,
            scale_factor,
            self.sample_count,
            self.unified_memory,
        ) catch return;
    }

    pub fn updateTextAtlas(self: *Self, atlas: *const Atlas) !void {
        if (self.text_pipeline_state) |*tp| try tp.updateAtlas(atlas);
    }

    pub fn prepareSvgAtlas(self: *Self, atlas: *const Atlas) void {
        if (self.svg_pipeline_state) |*sp| {
            sp.prepareFrame(atlas);
        }
    }

    pub fn prepareImageAtlas(self: *Self, atlas: *const Atlas) void {
        if (self.image_pipeline_state) |*ip| {
            ip.prepareFrame(atlas);
        }
    }

    pub fn setScissor(encoder: objc.Object, rect: ScissorRect) void {
        scissor.setScissor(encoder, rect);
    }

    pub fn boundsToScissorRect(x: f32, y: f32, width: f32, height: f32, viewport_height: f32, scale: f64) ScissorRect {
        return scissor.boundsToScissorRect(x, y, width, height, viewport_height, scale);
    }

    pub fn resetScissor(self: *const Self, encoder: objc.Object) void {
        scissor.resetScissor(encoder, self.size.width, self.size.height, self.scale_factor);
    }

    pub fn setScissorFromBounds(self: *const Self, encoder: objc.Object, x: f32, y: f32, width: f32, height: f32) void {
        scissor.setScissorFromBounds(encoder, x, y, width, height, @floatCast(self.size.height), self.scale_factor);
    }

    /// Whether the next asynchronous frame has a drawable. False starts acquiring one off
    /// the main thread; the caller skips this frame and stays dirty. Never waits.
    pub fn drawableReady(self: *Self) bool {
        return self.drawable_reserve.ready();
    }

    /// The frame's drawable, retained +1 for the caller to release. Asynchronous frames take
    /// the reserve and never wait; null means none is ready, so the frame is skipped.
    /// Synchronous frames (live resize) acquire on the main thread and may wait.
    fn acquireDrawable(self: *Self, synchronous: bool) ?objc.Object {
        if (synchronous) return self.drawable_reserve.acquireWaiting();
        if (!self.drawable_reserve.ready()) return null;
        return self.drawable_reserve.take();
    }

    fn renderInternal(self: *Self, clear_color: geometry.Color, synchronous: bool) void {
        const drawable = self.acquireDrawable(synchronous) orelse return;
        defer drawable.release();

        // Declared after the drawable so the transaction commits before it is released.
        const ca_scope = if (synchronous) render_pass.CATransactionScope.begin() else null;
        defer if (ca_scope) |scope| scope.commit();

        self.encodeClear(drawable, clear_color, synchronous);
    }

    /// Clear `drawable` and present it.
    fn encodeClear(
        self: *Self,
        drawable: objc.Object,
        clear_color: geometry.Color,
        synchronous: bool,
    ) void {
        assert(drawable.value != null);
        const texture = drawableTexture(drawable) orelse return;
        const msaa_tex = self.msaa_texture orelse return;

        const rp = render_pass.createRenderPass(.{
            .msaa_texture = msaa_tex,
            .resolve_texture = texture,
            .clear_color = clear_color,
        }) orelse return;

        const command_buffer = self.command_queue.msgSend(objc.Object, "commandBuffer", .{});
        const encoder = render_pass.createEncoder(command_buffer, rp) orelse return;

        if (synchronous) {
            render_pass.finishAndPresentSync(encoder, command_buffer, drawable);
        } else {
            render_pass.finishAndPresent(encoder, command_buffer, drawable);
        }
    }

    fn renderSceneInternal(
        self: *Self,
        scene: *const scene_mod.Scene,
        clear_color: geometry.Color,
        synchronous: bool,
    ) !void {
        // Acquired before the rings advance: every ring slot advance belongs to a frame that
        // holds a drawable, which is what bounds the frames in flight per slot (see
        // `UnifiedPrimitiveRing`). A skipped frame advances nothing.
        const drawable = self.acquireDrawable(synchronous) orelse return;
        defer drawable.release();

        // Declared after the drawable so the transaction commits before it is released.
        const ca_scope = if (synchronous) render_pass.CATransactionScope.begin() else null;
        defer if (ca_scope) |scope| scope.commit();

        self.unified_primitive_ring.nextFrame();
        if (self.text_pipeline_state) |*tp| tp.nextFrame();
        if (self.polyline_pipeline_state) |*plp| plp.nextFrame();
        if (self.point_cloud_pipeline_state) |*pcp| pcp.nextFrame();
        if (self.colored_point_cloud_pipeline_state) |*cpcp| cpcp.nextFrame();

        if (scene.getShadows().len == 0 and scene.getQuads().len == 0 and
            scene.getGlyphs().len == 0 and scene.getSvgInstances().len == 0 and
            scene.getImages().len == 0)
        {
            self.encodeClear(drawable, clear_color, synchronous);
            return;
        }

        const texture = drawableTexture(drawable) orelse return;
        const msaa_tex = self.msaa_texture orelse return;
        const unit_verts = self.quad_unit_vertex_buffer orelse return;

        const rp = render_pass.createRenderPass(.{
            .msaa_texture = msaa_tex,
            .resolve_texture = texture,
            .clear_color = clear_color,
        }) orelse return;

        const command_buffer = self.command_queue.msgSend(objc.Object, "commandBuffer", .{});
        const encoder = render_pass.createEncoder(command_buffer, rp) orelse return;

        render_pass.setViewport(encoder, self.size.width, self.size.height, self.scale_factor);
        const viewport_size: [2]f32 = .{ @floatCast(self.size.width), @floatCast(self.size.height) };

        // Use batch-based rendering for correct z-ordering
        const scene_pipelines = self.scenePipelines(scene, unit_verts);
        scene_renderer.drawScene(encoder, scene, scene_pipelines, viewport_size);

        if (synchronous) {
            render_pass.finishAndPresentSync(encoder, command_buffer, drawable);
        } else {
            render_pass.finishAndPresent(encoder, command_buffer, drawable);
        }
    }

    fn scenePipelines(
        self: *Self,
        scene: *const scene_mod.Scene,
        unit_vertex_buffer: objc.Object,
    ) scene_renderer.Pipelines {
        return .{
            .unified = self.unified_pipeline_state,
            .unified_ring = &self.unified_primitive_ring,
            .text = if (self.text_pipeline_state) |*tp| tp else null,
            .svg = if (self.svg_pipeline_state) |*sp| sp else null,
            .image = if (self.image_pipeline_state) |*ip| ip else null,
            .path = if (self.path_pipeline_state) |*pp| pp else null,
            .polyline = if (self.polyline_pipeline_state) |*plp| plp else null,
            .point_cloud = if (self.point_cloud_pipeline_state) |*pcp| pcp else null,
            .colored_point_cloud = if (self.colored_point_cloud_pipeline_state) |*cpcp| cpcp else null,
            .mesh_pool = &scene.mesh_pool,
            .unit_vertex_buffer = unit_vertex_buffer,
        };
    }
};

fn drawableTexture(drawable: objc.Object) ?objc.Object {
    assert(drawable.value != null);
    const texture = drawable.msgSend(?*anyopaque, "texture", .{}) orelse return null;
    return objc.Object.fromId(texture);
}
