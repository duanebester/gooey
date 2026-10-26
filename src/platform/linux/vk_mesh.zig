//! Three topology pipelines, four independently budgeted Scene pools.
//!
//! Resource sketch: each pool reserves aggregate geometry bytes plus bounded
//! header/alignment space per draw. At .standard this is 5,570,560 B/frame,
//! 16,760,832 B/window for three frames including host-pool alignment slack.
//! Worst-case upload is bounded by that reservation; normal uploads pack only
//! live data contiguously. Descriptors expose only initialized bytes. No network,
//! disk, texture uploads, tessellation, queues, or runtime allocations are needed.
//! CPU work is O(path indices + input points + draws); GPU expansion emits three
//! vertices/triangle, six/segment, six/point. Draws <= sum of the four scene limits.
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
    frames: [types.FRAME_COUNT]Frame = @splat(.{}),

    pub fn init(
        self: *Renderer,
        allocator: std.mem.Allocator,
        device: vk.Device,
        memory_properties: *const vk.PhysicalDeviceMemoryProperties,
        limits: *const scene_mod.SceneLimits,
        options: *const struct {
            render_pass: vk.RenderPass,
            sample_count: vk.SampleCountFlagBits,
            cache: vk.PipelineCache,
        },
    ) !void {
        assert(device != null);
        assert(self.device == null);
        self.device = device;
        self.allocator = allocator;
        self.capacity = Capacity.from_scene_limits(limits);
        errdefer self.deinit();

        const bytes = types.FRAME_COUNT * (self.capacity.frame_bytes() +
            4 * types.host_pool_alignment_slack_bytes);
        self.memory = try buffers.MemoryPool.init(
            device,
            memory_properties,
            bytes,
            vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        );

        self.descriptor_layout = try create_layout(device);
        self.pipeline_layout = try pipelines.createPipelineLayout(device, self.descriptor_layout);
        self.descriptor_pool = try create_descriptor_pool(device, &self.capacity);
        for (&self.frames) |*frame| try self.init_frame(frame);
        const names = .{ "triangles", "strip_expanded", "point_instanced" };
        inline for (names, 0..) |name, index| {
            self.topology_pipelines[index] = try pipelines.createGraphicsPipeline(
                device,
                options.render_pass,
                options.sample_count,
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
        self.* = .{};
    }
};

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
        for (instances, gradients) |*path, *gradient| {
            const mesh = self.scene.getMeshPool().getMesh(path.getMeshRef());
            const indices = mesh.indices.constSlice();
            if (indices.len == 0) continue;
            assert(indices.len % 3 == 0);
            self.frame.geometry.claim(&self.renderer.capacity.geometry, .{
                .pool = .path_vertices,
                .requested = @intCast(mesh.vertices.len),
                .frame = self.scene.frame_count_finished,
            });
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
            const target = self.prepare(.triangles, &header, indices.len * 16);
            const vertices: [*]scene_mod.PathVertex = @ptrCast(@alignCast(target));
            copy_triangles(vertices[0..indices.len], mesh.vertices.constSlice(), indices);
            self.submit(.triangles, .{ .vertices = @intCast(indices.len), .instances = 1 });
            draws += 1;
        }
        return draws;
    }

    pub fn strips(self: *const Draw, instances: []const scene_mod.Polyline) u32 {
        assert(instances.len <= self.scene.limits.polyline_count_frame_max);
        assert(self.command != null);
        for (instances) |*line| {
            line.validate();
            const header = Header{
                .color = line.color,
                .clip = .{ line.clip_x, line.clip_y, line.clip_width, line.clip_height },
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
    assert(@sizeOf(ColoredPoint) == 24);
    assert(@sizeOf(scene_mod.Point) == 8);
    assert(@sizeOf(scene_mod.PathVertex) == 16);
}

fn copy_triangles(
    target: []scene_mod.PathVertex,
    vertices: []const scene_mod.PathVertex,
    indices: []const u32,
) void {
    assert(target.len == indices.len);
    assert(indices.len <= @import("../../scene/path_mesh.zig").MAX_MESH_INDICES);
    for (indices, target) |index, *vertex| {
        assert(index < vertices.len);
        vertex.* = vertices[index];
    }
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

fn create_descriptor_pool(device: vk.Device, capacity: *const Capacity) !vk.DescriptorPool {
    assert(device != null);
    var count: u32 = 0;
    for (capacity.counts) |draws| count += draws * types.FRAME_COUNT;
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
