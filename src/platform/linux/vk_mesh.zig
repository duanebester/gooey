//! Three topology pipelines, four independently budgeted Scene pools.
//!
//! Anti-aliasing: the renderer draws one sample per pixel, so the mesh shaders
//! compute edge coverage analytically instead of relying on MSAA. Each
//! triangle vertex carries two bits per triangle edge (`mesh_edges`):
//! silhouette edges get a one-logical-pixel fringe quad outside them and fade
//! across their pixel-wide boundary, edges shared with a same-fill triangle are
//! left alone so tiled shapes have no seams, and fill boundaries blend like a
//! resolve. Polyline segments fade their sides and the line's two end caps;
//! the joints between segments stay hard so consecutive segments do not
//! double-fade where they meet. Points keep their circular falloff, widened
//! to at least one device pixel. Coverage is measured in device pixels from
//! screen-space derivatives of exact (affine) edge distances.
//!
//! Resource sketch: each pool reserves aggregate geometry bytes plus bounded
//! header/alignment space per draw, once per frame in flight. At .standard this
//! is 2,490,368 B/frame, 7,520,256 B/window for three frames including host-pool
//! alignment slack; .nano is 103,424 B/frame, 239,616 B/window for two frames
//! (20 B per path index: the 16 B source vertex plus 4 B of edge modes). The
//! edge table adds 30 B of host memory per path index budget: 491,540 B at
//! .standard, 61,460 B at .nano.
//! Worst-case upload is bounded by that reservation; normal uploads pack only
//! live data contiguously. Descriptors expose only initialized bytes. No network,
//! disk, texture uploads, tessellation, queues, or runtime allocations are needed.
//! CPU work is O(path indices + input points + draws); GPU expansion emits 21
//! vertices/triangle (the triangle and a fringe quad per edge, from its three
//! records; quads on interior edges collapse), six/segment, six/point. Draws
//! <= sum of the four scene limits.
//! Each frame reuses its resources only after the renderer's fence has completed.
const std = @import("std");
const assert = std.debug.assert;
const vk = @import("vulkan.zig");
const buffers = @import("vk_buffers.zig");
const descriptors = @import("vk_descriptors.zig");
const pipelines = @import("vk_pipelines.zig");
const types = @import("vk_types.zig");
const scene_mod = @import("../../scene/mod.zig");
const colored_cloud = @import("../../scene/colored_point_cloud.zig");
const edges_mod = @import("../mesh_edges.zig");
const Header = types.MeshHeader;
const Capacity = types.MeshCapacity;
const Pool = types.MeshPool;
const pool_kinds = [_]Pool{ .triangles, .strip_expanded, .points, .colored_points };

pub const Frame = struct {
    pools: [4]DrawPool = @splat(.{}),
    geometry: scene_mod.GeometryCounts = .{},

    pub fn reset(self: *Frame) void {
        self.geometry = .{};
        for (&self.pools) |*pool| {
            assert(pool.buffer != null);
            assert(pool.sets.len > 0);
            pool.draw_count = 0;
            pool.bytes_used = 0;
        }
    }
};

const DrawPool = struct {
    buffer: vk.Buffer = null,
    mapped: ?[*]u8 = null,
    sets: []vk.DescriptorSet = &.{},
    draw_count: u32 = 0,
    bytes_used: u64 = 0,
};

pub const Renderer = struct {
    device: vk.Device = null,
    allocator: std.mem.Allocator = undefined,
    capacity: Capacity = undefined,
    memory: buffers.MemoryPool = .{},
    descriptor_pool: vk.DescriptorPool = null,
    descriptor_layout: vk.DescriptorSetLayout = null,
    pipeline_layout: vk.PipelineLayout = null,
    topology_pipelines: [3]vk.Pipeline = @splat(null),
    /// Declared at the ceiling; only `frame_count` are created and rotated.
    frames: [types.frame_count_max]Frame = @splat(.{}),
    frame_count: u32 = 0,
    /// Path edge modes for the frame being recorded; see `classify_edges`.
    edges: edges_mod.EdgeTable = .{},

    pub fn init(
        self: *Renderer,
        allocator: std.mem.Allocator,
        device: vk.Device,
        memory_properties: *const vk.PhysicalDeviceMemoryProperties,
        limits: *const scene_mod.SceneLimits,
        options: *const struct {
            render_pass: vk.RenderPass,
            cache: vk.PipelineCache,
            /// The window budget's `ResourceLimits.frame.in_flight_count`.
            frame_count: u32,
            /// From `vk_buffers.queryAllocationBytesMax`.
            allocation_bytes_max: vk.DeviceSize,
        },
    ) !void {
        assert(device != null);
        assert(self.device == null);
        assert(options.frame_count >= 1);
        assert(options.frame_count <= types.frame_count_max);
        self.device = device;
        self.allocator = allocator;
        self.capacity = Capacity.from_scene_limits(limits);
        self.frame_count = options.frame_count;
        errdefer self.deinit();

        const bytes = @as(u64, self.frame_count) * (self.capacity.frame_bytes() +
            4 * types.host_pool_alignment_slack_bytes);
        self.memory = try buffers.MemoryPool.init(device, memory_properties, &.{
            .name = "mesh geometry",
            .size = bytes,
            .allocation_bytes_max = options.allocation_bytes_max,
            .required_properties = vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
                vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        });
        const index_count_max = self.capacity.geometry.counts[
            @backingInt(scene_mod.GeometryPool.path_indices)
        ];
        try self.edges.init(allocator, index_count_max);

        self.descriptor_layout = try create_layout(device);
        self.pipeline_layout = try pipelines.createPipelineLayout(device, self.descriptor_layout);
        self.descriptor_pool = try create_descriptor_pool(
            device,
            &self.capacity,
            self.frame_count,
        );
        for (self.frames[0..self.frame_count]) |*frame| try self.init_frame(frame);
        const names = .{ "triangles", "strip_expanded", "point_instanced" };
        inline for (names, 0..) |name, index| {
            self.topology_pipelines[index] = try pipelines.createGraphicsPipeline(
                device,
                options.render_pass,
                .{
                    .vert_spv = @alignCast(@embedFile("shaders/" ++ name ++ ".vert.spv")),
                    .frag_spv = @alignCast(@embedFile("shaders/mesh.frag.spv")),
                    .pipeline_layout = self.pipeline_layout,
                    .blend_mode = .premultiplied,
                },
                options.cache,
            );
        }
    }

    fn init_frame(self: *Renderer, frame: *Frame) !void {
        assert(self.memory.mapped != null);
        assert(self.descriptor_pool != null);
        for (pool_kinds, &frame.pools) |kind, *pool| {
            const result = try buffers.createMappedBufferFromPool(
                self.device,
                &self.memory,
                self.capacity.buffer_bytes(kind),
                vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
            );
            pool.buffer = result.buffer;
            pool.mapped = @ptrCast(result.mapped);

            pool.sets = try self.allocator.alloc(
                vk.DescriptorSet,
                self.capacity.counts[@backingInt(kind)],
            );
            @memset(pool.sets, null);
            for (pool.sets) |*set| {
                set.* = try descriptors.allocateDescriptorSet(
                    self.device,
                    self.descriptor_pool,
                    self.descriptor_layout,
                );
            }
        }
    }

    pub fn deinit(self: *Renderer) void {
        if (self.device == null) return;
        for (self.topology_pipelines) |pipeline| pipelines.destroyPipeline(self.device, pipeline);
        if (self.pipeline_layout) |layout| vk.vkDestroyPipelineLayout(self.device, layout, null);
        if (self.descriptor_pool) |pool| vk.vkDestroyDescriptorPool(self.device, pool, null);
        if (self.descriptor_layout) |layout| {
            vk.vkDestroyDescriptorSetLayout(self.device, layout, null);
        }
        for (&self.frames) |*frame| {
            for (&frame.pools) |*pool| {
                buffers.destroyBufferOnly(self.device, pool.buffer);
                self.allocator.free(pool.sets);
            }
        }
        self.memory.destroy(self.device);
        if (self.edges.entries.len > 0) self.edges.deinit(self.allocator);
        self.* = .{};
    }

    /// Classify every path triangle edge of the frame before any path is drawn
    /// (`mesh_edges.classify`, shared with Metal).
    pub fn classify_edges(self: *Renderer, scene: *const scene_mod.Scene) void {
        assert(self.edges.entries.len > 0);
        assert(self.edges.edge_count_max == self.capacity.geometry.counts[
            @backingInt(scene_mod.GeometryPool.path_indices)
        ]);
        edges_mod.classify(&self.edges, scene);
    }
};

/// The per-draw header for a path.
fn path_header(path: *const scene_mod.PathInstance, gradient: anytype) Header {
    var header = Header{
        .transform = .{ path.offset_x, path.offset_y, path.scale_x, path.scale_y },
        .color = path.fill_color,
        .clip = .{ path.clip_x, path.clip_y, path.clip_width, path.clip_height },
        .params = .{
            path.grad_param0,
            path.grad_param1,
            path.grad_param2,
            path.grad_param3,
        },
        .gradient_type = path.gradient_type,
        .stop_count = gradient.stop_count,
    };
    assert(header.gradient_type <= 2);
    if (header.gradient_type != 0) {
        assert(header.stop_count >= 2);
        assert(header.stop_count <= 16);
        const count = header.stop_count;
        @memcpy(header.stop_offsets[0..count], gradient.stop_offsets[0..count]);
        @memcpy(header.stop_h[0..count], gradient.stop_h[0..count]);
        @memcpy(header.stop_s[0..count], gradient.stop_s[0..count]);
        @memcpy(header.stop_l[0..count], gradient.stop_l[0..count]);
        @memcpy(header.stop_a[0..count], gradient.stop_a[0..count]);
    }
    return header;
}

/// One recording context is stack-owned by drawScene. It never survives a frame.
pub const Draw = struct {
    renderer: *Renderer,
    frame: *Frame,
    scene: *const scene_mod.Scene,
    command: vk.CommandBuffer,
    uniform: vk.Buffer,

    pub fn paths(self: *const Draw, instances: []const scene_mod.PathInstance) u32 {
        assert(instances.len <= self.scene.limits.path_count_frame_max);
        const all = self.scene.getPathInstances();
        const first = @divExact(
            @intFromPtr(instances.ptr) - @intFromPtr(all.ptr),
            @sizeOf(scene_mod.PathInstance),
        );
        assert(first + instances.len <= all.len);
        var draws: u32 = 0;
        const gradients = self.scene.getPathGradients()[first..][0..instances.len];
        for (instances, gradients, first..) |*path, *gradient, path_index| {
            const mesh = self.scene.getMeshPool().getMesh(path.getMeshRef());
            const indices = mesh.indices.constSlice();
            if (indices.len == 0) continue;
            assert(indices.len % 3 == 0);
            self.frame.geometry.claim(&self.renderer.capacity.geometry, .{
                .pool = .path_vertices,
                .requested = @intCast(mesh.vertices.len),
                .frame = self.scene.frame_count_finished,
            });
            const header = path_header(path, gradient);
            const bytes = indices.len * @sizeOf(types.TriangleVertex);
            const target = self.prepare(.triangles, &header, bytes);
            const records: [*]types.TriangleVertex = @ptrCast(@alignCast(target));
            edges_mod.write_triangles(records[0..indices.len], &.{
                .edges = &self.renderer.edges,
                .path = path,
                .path_index = @intCast(path_index),
                .vertices = mesh.vertices.constSlice(),
                .indices = indices,
            });
            const vertex_count = edges_mod.draw_vertex_count(@intCast(indices.len));
            self.submit(.triangles, .{ .vertices = vertex_count, .instances = 1 });
            draws += 1;
        }
        return draws;
    }

    pub fn strips(self: *const Draw, instances: []const scene_mod.Polyline) u32 {
        assert(instances.len <= self.scene.limits.polyline_count_frame_max);
        assert(self.command != null);
        for (instances) |*line| {
            line.validate();
            // Strips have no gradient: `params[0]` carries the segment count so
            // the shader can fade the line's two end caps and not its joints.
            const header = Header{
                .color = line.color,
                .clip = .{ line.clip_x, line.clip_y, line.clip_width, line.clip_height },
                .params = .{ @floatFromInt(line.point_count - 1), 0, 0, 0 },
                .radius = line.width * 0.5,
            };
            const positions = line.getPoints();
            const target = self.prepare(.strip_expanded, &header, positions.len * 8);
            @memcpy(target[0 .. positions.len * 8], std.mem.sliceAsBytes(positions));
            self.submit(.strip_expanded, .{ .vertices = 6, .instances = line.point_count - 1 });
        }
        return @intCast(instances.len);
    }

    pub fn points(self: *const Draw, comptime colored: bool, instances: anytype) u32 {
        const kind: Pool = if (colored) .colored_points else .points;
        const count_max = if (colored) count: {
            break :count self.scene.limits.colored_point_cloud_count_frame_max;
        } else self.scene.limits.point_cloud_count_frame_max;
        assert(instances.len <= count_max);
        assert(self.command != null);
        for (instances) |*cloud| {
            cloud.validate();
            const header = Header{
                .color = if (colored) scene_mod.Hsla.black else cloud.color,
                .clip = .{ cloud.clip_x, cloud.clip_y, cloud.clip_width, cloud.clip_height },
                .radius = cloud.radius,
                .colored = @intFromBool(colored),
            };
            const positions = cloud.getPositions();
            const stride: usize = if (colored) 24 else 8;
            const target = self.prepare(kind, &header, positions.len * stride);
            if (colored) {
                const output: [*]ColoredPoint = @ptrCast(@alignCast(target));
                copy_colored_points(output[0..positions.len], positions, cloud.getColors());
            } else {
                @memcpy(target[0 .. positions.len * 8], std.mem.sliceAsBytes(positions));
            }
            self.submit(kind, .{ .vertices = 6, .instances = cloud.count });
        }
        return @intCast(instances.len);
    }

    fn prepare(self: *const Draw, kind: Pool, header: *const Header, payload_bytes: usize) [*]u8 {
        const pool = &self.frame.pools[@backingInt(kind)];
        self.renderer.capacity.reserve(kind, pool.draw_count, self.scene.frame_count_finished);
        self.frame.geometry.claim(&self.renderer.capacity.geometry, .{
            .pool = Capacity.geometry_pool(kind),
            .requested = @intCast(@divExact(payload_bytes, Capacity.element_bytes(kind))),
            .frame = self.scene.frame_count_finished,
        });
        const bytes = @sizeOf(Header) + payload_bytes;
        assert(bytes <= Capacity.stride_bytes(kind));
        const offset = pool.bytes_used;
        const padded = std.mem.alignForward(u64, bytes, Capacity.alignment_bytes);
        assert(offset <= self.renderer.capacity.buffer_bytes(kind));
        assert(padded <= self.renderer.capacity.buffer_bytes(kind) - offset);
        const target = pool.mapped.? + @as(usize, @intCast(offset));
        // Every exposed byte is initialized; padding is zero even on slot reuse.
        @memcpy(target[0..@sizeOf(Header)], std.mem.asBytes(header));
        @memset(target[bytes..@intCast(padded)], 0);
        write_descriptor(self.renderer.device, pool.sets[pool.draw_count], &.{
            .buffer = pool.buffer,
            .offset = offset,
            .range = bytes,
        }, self.uniform);
        pool.bytes_used += padded;
        return target + @sizeOf(Header);
    }

    fn submit(self: *const Draw, kind: Pool, count: struct { vertices: u32, instances: u32 }) void {
        assert(count.vertices > 0);
        assert(count.instances > 0);
        const pool = &self.frame.pools[@backingInt(kind)];
        assert(pool.draw_count < pool.sets.len);
        const topology: usize = switch (kind) {
            .triangles => 0,
            .strip_expanded => 1,
            .points, .colored_points => 2,
        };
        vk.vkCmdBindPipeline(
            self.command,
            vk.VK_PIPELINE_BIND_POINT_GRAPHICS,
            self.renderer.topology_pipelines[topology],
        );
        vk.vkCmdBindDescriptorSets(
            self.command,
            vk.VK_PIPELINE_BIND_POINT_GRAPHICS,
            self.renderer.pipeline_layout,
            0,
            1,
            (&pool.sets[pool.draw_count])[0..1],
            0,
            null,
        );
        vk.vkCmdDraw(self.command, count.vertices, count.instances, 0, 0);
        pool.draw_count += 1;
    }
};

const ColoredPoint = colored_cloud.ColoredPoint;

comptime {
    // `shaders/triangles.vert` hard-codes the draw layout as
    // `triangle_draw_vertex_count`.
    assert(edges_mod.triangle_draw_vertex_count == 21);
    assert(@sizeOf(ColoredPoint) == 24);
    assert(@sizeOf(scene_mod.Point) == 8);
    assert(@sizeOf(scene_mod.PathVertex) == 16);
    assert(@sizeOf(types.TriangleVertex) == @sizeOf(scene_mod.PathVertex) + 4);
}

fn copy_colored_points(
    target: []ColoredPoint,
    positions: []const scene_mod.Point,
    colors: []const scene_mod.Hsla,
) void {
    assert(target.len == positions.len);
    assert(colors.len == positions.len);
    assert(positions.len <= colored_cloud.MAX_POINTS_PER_COLORED_CLOUD);
    for (target, positions, colors) |*point, position, color| {
        point.* = .{ .x = position.x, .y = position.y, .color = color };
    }
}

fn create_layout(device: vk.Device) !vk.DescriptorSetLayout {
    assert(device != null);
    const stages = vk.VK_SHADER_STAGE_VERTEX_BIT | vk.VK_SHADER_STAGE_FRAGMENT_BIT;
    const bindings = [_]vk.DescriptorSetLayoutBinding{
        .{
            .binding = 0,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .descriptorCount = 1,
            .stageFlags = stages,
            .pImmutableSamplers = null,
        },
        .{
            .binding = 1,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .descriptorCount = 1,
            .stageFlags = stages,
            .pImmutableSamplers = null,
        },
    };
    const info = vk.DescriptorSetLayoutCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .bindingCount = bindings.len,
        .pBindings = &bindings,
    };
    var layout: vk.DescriptorSetLayout = null;
    if (!vk.succeeded(vk.vkCreateDescriptorSetLayout(device, &info, null, &layout))) {
        return error.DescriptorSetLayoutCreationFailed;
    }
    assert(layout != null);
    return layout;
}

fn create_descriptor_pool(
    device: vk.Device,
    capacity: *const Capacity,
    frame_count: u32,
) !vk.DescriptorPool {
    assert(device != null);
    assert(frame_count <= types.frame_count_max);
    var count: u32 = 0;
    for (capacity.counts) |draws| count += draws * frame_count;
    assert(count > 0);
    const sizes = [_]vk.DescriptorPoolSize{
        .{ .type = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = count },
        .{ .type = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = count },
    };
    const info = vk.DescriptorPoolCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .maxSets = count,
        .poolSizeCount = sizes.len,
        .pPoolSizes = &sizes,
    };
    var pool: vk.DescriptorPool = null;
    if (!vk.succeeded(vk.vkCreateDescriptorPool(device, &info, null, &pool))) {
        return error.DescriptorPoolCreationFailed;
    }
    assert(pool != null);
    return pool;
}

fn write_descriptor(
    device: vk.Device,
    set: vk.DescriptorSet,
    storage: *const vk.DescriptorBufferInfo,
    uniform: vk.Buffer,
) void {
    assert(set != null);
    assert(storage.range <= types.storage_buffer_range_guaranteed_bytes);
    const viewport = vk.DescriptorBufferInfo{
        .buffer = uniform,
        .offset = 0,
        .range = @sizeOf(types.Uniforms),
    };
    const writes = [_]vk.WriteDescriptorSet{
        .{
            .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = set,
            .dstBinding = 0,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .pImageInfo = null,
            .pBufferInfo = storage[0..1],
            .pTexelBufferView = null,
        },
        .{
            .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = set,
            .dstBinding = 1,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .pImageInfo = null,
            .pBufferInfo = (&viewport)[0..1],
            .pTexelBufferView = null,
        },
    };
    vk.vkUpdateDescriptorSets(device, writes.len, &writes, 0, null);
}
