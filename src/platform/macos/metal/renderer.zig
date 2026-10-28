//! Metal Renderer - Main GPU rendering coordinator

const std = @import("std");
const assert = std.debug.assert;
const objc = @import("objc");

const interface_verify = @import("../../../core/interface_verify.zig");
const geometry = @import("../../../geometry/geometry.zig");
const scene_mod = @import("../../../scene/mod.zig");
const ResourceLimits = @import("../../../core/limits.zig").ResourceLimits;
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
const atlas_textures = @import("atlas_textures.zig");
const AtlasUploads = @import("../../../text/mod.zig").AtlasUploads;

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
    unified_memory: bool,

    // Single unified pipeline for quads + shadows
    unified_pipeline_state: ?objc.Object,
    unified_primitive_ring: scene_renderer.UnifiedPrimitiveRing,
    /// Fixed-size atlas textures and their upload staging, created at init.
    atlas_textures: atlas_textures.AtlasTextures,
    text_pipeline_state: ?text_pipeline.TextPipeline,
    svg_pipeline_state: ?svg_pipeline.SvgPipeline,
    image_pipeline_state: ?image_pipeline.ImagePipeline,
    path_pipeline_state: ?path_pipeline.PathPipeline,
    polyline_pipeline_state: ?polyline_pipeline.PolylinePipeline,
    point_cloud_pipeline_state: ?point_cloud_pipeline.PointCloudPipeline,
    colored_point_cloud_pipeline_state: ?colored_point_cloud_pipeline.ColoredPointCloudPipeline,

    quad_unit_vertex_buffer: ?objc.Object,

    size: geometry.Size(f64),
    scale_factor: f64,

    post_process_state: ?custom_shader.PostProcessState,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// `limits` is the window's validated budget; the quad/shadow instance ring
    /// and the mesh pipelines' per-frame geometry buffers are reserved from it
    /// instead of the framework ceilings, once per frame in flight, and the layer
    /// keeps exactly that many drawables.
    /// The atlas textures and their upload staging come from `limits.atlas`,
    /// created here once and never recreated.
    pub fn init(
        allocator: std.mem.Allocator,
        layer: objc.Object,
        size: geometry.Size(f64),
        scale_factor: f64,
        limits: *const ResourceLimits,
    ) !Self {
        assert(limits.check() == null);
        const device_ptr = mtl.MTLCreateSystemDefaultDevice() orelse
            return error.MetalNotAvailable;
        const device = objc.Object.fromId(device_ptr);

        const unified_memory = device.msgSend(bool, "hasUnifiedMemory", .{});
        const command_queue = device.msgSend(objc.Object, "newCommandQueue", .{});

        configureLayer(layer, device, size, scale_factor, limits.frame.in_flight_count);

        var unified_primitive_ring =
            try scene_renderer.UnifiedPrimitiveRing.init(device, limits);
        // Not an `errdefer`: once `self` exists, its `deinit` releases the ring.
        const textures = atlas_textures.AtlasTextures.init(device, limits) catch |err| {
            unified_primitive_ring.deinit();
            return err;
        };

        var self = Self{
            .device = device,
            .command_queue = command_queue,
            .layer = layer,
            .unified_memory = unified_memory,
            .unified_pipeline_state = null,
            .unified_primitive_ring = unified_primitive_ring,
            .atlas_textures = textures,
            .text_pipeline_state = null,
            .svg_pipeline_state = null,
            .image_pipeline_state = null,
            .path_pipeline_state = null,
            .polyline_pipeline_state = null,
            .point_cloud_pipeline_state = null,
            .colored_point_cloud_pipeline_state = null,
            .quad_unit_vertex_buffer = null,
            .size = size,
            .scale_factor = scale_factor,
            .post_process_state = null,
            .allocator = allocator,
        };
        // Releases the ring and every optional resource created below.
        errdefer self.deinit();

        // One sample per pixel (`pipelines.sample_count`): no MSAA target exists,
        // so the drawable is the only window-sized surface and resize recreates
        // nothing.
        self.unified_pipeline_state = try pipelines.setupUnifiedPipeline(device);
        self.quad_unit_vertex_buffer = try pipelines.createUnitVertexBuffer(device, unified_memory);

        try self.initInstancePipelines(limits);
        try self.initMeshPipelines(limits);
        return self;
    }

    /// Bind `layer` to `device`, size its drawables, and cap them at the budget's
    /// frames in flight.
    fn configureLayer(
        layer: objc.Object,
        device: objc.Object,
        size: geometry.Size(f64),
        scale_factor: f64,
        frame_count: u32,
    ) void {
        assert(scale_factor > 0.0);
        layer.msgSend(void, "setDevice:", .{device.value});
        layer.msgSend(void, "setDrawableSize:", .{mtl.CGSize{
            .width = size.width * scale_factor,
            .height = size.height * scale_factor,
        }});

        // The rings' in-flight safety proof relies on every frame holding one of at most
        // `frame_count` drawables (see `UnifiedPrimitiveRing`). CAMetalLayer accepts 2 or
        // 3, the same range `FrameLimits.check` enforces. Two drawables at `nano` and
        // `small` drop one window-sized surface; three is the layer's default, kept at
        // `standard` and above.
        layer.msgSend(void, "setMaximumDrawableCount:", .{@as(c_ulong, frame_count)});
        const drawable_count_max = layer.msgSend(c_ulong, "maximumDrawableCount", .{});
        assert(drawable_count_max >= 2);
        assert(drawable_count_max == frame_count);
    }

    /// Create the text, SVG and image pipelines with their per-frame instance
    /// buffers sized from `limits`. A failure here is fatal rather than
    /// skipped: a missing pipeline would silently drop primitives the scene
    /// accepted within its budget (CLAUDE.md §2).
    fn initInstancePipelines(self: *Self, limits: *const ResourceLimits) !void {
        assert(limits.check() == null);
        assert(self.text_pipeline_state == null);
        const device = self.device;
        self.text_pipeline_state = try text_pipeline.TextPipeline.init(
            device,
            mtl.MTLPixelFormat.bgra8unorm,
            limits,
            self.atlas_textures.text,
        );
        self.svg_pipeline_state = try svg_pipeline.SvgPipeline.init(
            device,
            limits,
            self.atlas_textures.svg,
        );
        self.image_pipeline_state = try image_pipeline.ImagePipeline.init(
            device,
            limits,
            self.atlas_textures.image,
        );
    }

    /// Create the path, polyline and point-cloud pipelines with their per-frame
    /// geometry buffers sized from `limits`. A failure here is fatal rather
    /// than skipped: a missing pipeline would silently drop geometry the scene
    /// accepted within its budget (CLAUDE.md §2).
    fn initMeshPipelines(self: *Self, limits: *const ResourceLimits) !void {
        assert(limits.check() == null);
        assert(self.path_pipeline_state == null);
        const device = self.device;
        try checkMeshReservation(device, limits);
        self.path_pipeline_state = try path_pipeline.PathPipeline.init(device, limits);
        self.polyline_pipeline_state = try polyline_pipeline.PolylinePipeline.init(
            device,
            limits,
        );
        self.point_cloud_pipeline_state = try point_cloud_pipeline.PointCloudPipeline.init(
            device,
            limits,
        );
        const ColoredPointCloudPipeline = colored_point_cloud_pipeline.ColoredPointCloudPipeline;
        self.colored_point_cloud_pipeline_state = try ColoredPointCloudPipeline.init(
            device,
            limits,
        );
    }

    /// Fail init when one window's mesh reservation exceeds the device's
    /// recommended working set. `createFrameBuffers` checks each buffer against
    /// `maxBufferLength` only, and on Apple silicon that is a large fraction of
    /// system memory: `.ceiling` reserves 26,750,976,000 B per window in buffers
    /// that each pass it, so the total must be checked separately.
    fn checkMeshReservation(device: objc.Object, limits: *const ResourceLimits) !void {
        assert(limits.check() == null);
        const reservation_bytes = meshReservationBytes(limits);
        const working_set_bytes_max: u64 = device.msgSend(u64, "recommendedMaxWorkingSetSize", .{});
        assert(reservation_bytes > 0);
        assert(working_set_bytes_max > 0);
        if (reservation_bytes <= working_set_bytes_max) return;

        std.log.err(
            "Metal mesh reservation of {d} B per window ({d} frames in flight, " ++
                "ResourceLimits.scene) exceeds the device's recommendedMaxWorkingSetSize " ++
                "of {d} B.",
            .{ reservation_bytes, limits.frame.in_flight_count, working_set_bytes_max },
        );
        return error.MeshReservationExceedsWorkingSet;
    }

    /// Bytes the mesh pipelines reserve for one window: every per-frame buffer of
    /// every frame in flight.
    fn meshReservationBytes(limits: *const ResourceLimits) u64 {
        const scene_limits = &limits.scene;
        const ColoredPointCloudPipeline = colored_point_cloud_pipeline.ColoredPointCloudPipeline;
        const frame_bytes = path_pipeline.PathPipeline.frameBytes(scene_limits) +
            polyline_pipeline.PolylinePipeline.frameBytes(scene_limits) +
            point_cloud_pipeline.PointCloudPipeline.frameBytes(scene_limits) +
            ColoredPointCloudPipeline.frameBytes(scene_limits);
        assert(frame_bytes > 0);
        return frame_bytes * limits.frame.in_flight_count;
    }

    pub fn deinit(self: *Self) void {
        if (self.unified_pipeline_state) |ps| ps.release();
        self.unified_primitive_ring.deinit();
        self.atlas_textures.deinit();
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

        self.nextFrame();

        const width: u32 = @intFromFloat(self.size.width * self.scale_factor);
        const height: u32 = @intFromFloat(self.size.height * self.scale_factor);
        try pp.ensureSize(width, height);

        pp.updateTiming();
        pp.uploadUniforms();

        // Use the new unified single-command-buffer pipeline
        try post_process.renderFullPipeline(
            self.command_queue,
            self.layer,
            scene,
            clear_color,
            self.quad_unit_vertex_buffer.?,
            self.unified_pipeline_state,
            &self.unified_primitive_ring,
            &self.atlas_textures,
            if (self.text_pipeline_state) |*tp| tp else null,
            if (self.svg_pipeline_state) |*sp| sp else null,
            pp,
            self.size,
            self.scale_factor,
        );
    }

    pub fn initPostProcess(self: *Self) !void {
        if (self.post_process_state != null) return;
        self.post_process_state = try custom_shader.PostProcessState.init(
            self.allocator,
            self.device,
        );
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
        assert(scale_factor > 0);
        assert(size.width >= 0);
        assert(size.height >= 0);
        self.size = size;
        self.scale_factor = scale_factor;
        self.layer.msgSend(void, "setDrawableSize:", .{mtl.CGSize{
            .width = size.width * scale_factor,
            .height = size.height * scale_factor,
        }});
    }

    /// Bind the atlas journal this renderer consumes, keyed by its platform
    /// window (the key `Window` registered). Call before the first render.
    pub fn bindAtlasUploads(self: *Self, uploads: *AtlasUploads, key: usize) void {
        self.atlas_textures.bind(uploads, key);
    }

    /// True when atlas records are waiting for this renderer's next frame.
    pub fn hasPendingAtlasUploads(self: *const Self) bool {
        return self.atlas_textures.hasPending();
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

    fn renderInternal(self: *Self, clear_color: geometry.Color, synchronous: bool) void {
        const ca_scope = if (synchronous) render_pass.CATransactionScope.begin() else null;
        defer if (ca_scope) |scope| scope.commit();

        const drawable_info = render_pass.getNextDrawable(self.layer) orelse return;
        const rp = render_pass.createSimpleRenderPass(.{
            .texture = drawable_info.texture,
            .clear_color = clear_color,
            .load_action = .clear,
            .store_action = .store,
        }) orelse return;

        const command_buffer = self.command_queue.msgSend(objc.Object, "commandBuffer", .{});
        const encoder = render_pass.createEncoder(command_buffer, rp) orelse return;

        if (synchronous) {
            render_pass.finishAndPresentSync(encoder, command_buffer, drawable_info.drawable);
        } else {
            render_pass.finishAndPresent(encoder, command_buffer, drawable_info.drawable);
        }
    }

    /// Advance every per-frame buffer ring to its next frame-in-flight slot and
    /// release the previous frame's claims. Both render paths call this once per
    /// frame, before any batch is drawn.
    fn nextFrame(self: *Self) void {
        assert(self.text_pipeline_state != null);
        assert(self.path_pipeline_state != null);
        self.unified_primitive_ring.nextFrame();
        self.atlas_textures.nextFrame();
        if (self.text_pipeline_state) |*tp| tp.nextFrame();
        if (self.svg_pipeline_state) |*sp| sp.nextFrame();
        if (self.image_pipeline_state) |*ip| ip.nextFrame();
        if (self.path_pipeline_state) |*pp| pp.nextFrame();
        if (self.polyline_pipeline_state) |*plp| plp.nextFrame();
        if (self.point_cloud_pipeline_state) |*pcp| pcp.nextFrame();
        if (self.colored_point_cloud_pipeline_state) |*cpcp| cpcp.nextFrame();
    }

    fn renderSceneInternal(self: *Self, scene: *const scene_mod.Scene, clear_color: geometry.Color, synchronous: bool) !void {
        self.nextFrame();

        // No empty-scene shortcut: `drawScene` draws exactly what the scene's
        // BatchIterator yields, so an empty scene already presents a plain
        // clear. A shortcut keyed on a list of primitive kinds blanks every
        // frame whose kinds the list omits, such as a paths-only frame.
        const ca_scope = if (synchronous) render_pass.CATransactionScope.begin() else null;
        defer if (ca_scope) |scope| scope.commit();

        const drawable_info = render_pass.getNextDrawable(self.layer) orelse return;
        const rp = render_pass.createSimpleRenderPass(.{
            .texture = drawable_info.texture,
            .clear_color = clear_color,
            .load_action = .clear,
            .store_action = .store,
        }) orelse return;

        const command_buffer = self.command_queue.msgSend(objc.Object, "commandBuffer", .{});
        // Atlas blits precede the render pass in the same command buffer.
        self.atlas_textures.encodeUploads(command_buffer);
        const encoder = render_pass.createEncoder(command_buffer, rp) orelse return;

        render_pass.setViewport(encoder, self.size.width, self.size.height, self.scale_factor);

        const viewport_size: [2]f32 = .{ @floatCast(self.size.width), @floatCast(self.size.height) };
        const unit_verts = self.quad_unit_vertex_buffer orelse {
            encoder.msgSend(void, "endEncoding", .{});
            return;
        };

        // Use batch-based rendering for correct z-ordering
        scene_renderer.drawScene(encoder, scene, .{
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
            .unit_vertex_buffer = unit_verts,
        }, viewport_size);

        if (synchronous) {
            render_pass.finishAndPresentSync(encoder, command_buffer, drawable_info.drawable);
        } else {
            render_pass.finishAndPresent(encoder, command_buffer, drawable_info.drawable);
        }
    }
};
