const std = @import("std");
const assert = std.debug.assert;
const vk = @import("vulkan.zig");
const vk_types = @import("vk_types.zig");

pub const frame_count_max: u32 = vk_types.frame_count_max;

pub const MappedBufferResult = struct {
    buffer: vk.Buffer,
    memory: vk.DeviceMemory,
    mapped: *anyopaque,
};

pub const SubAllocation = struct {
    memory: vk.DeviceMemory,
    offset: vk.DeviceSize,
    mapped: ?*anyopaque,
};

pub const SyncObjects = struct {
    image_available_semaphores: [frame_count_max]vk.Semaphore,
    in_flight_fences: [frame_count_max]vk.Fence,

    pub fn destroy(self: *SyncObjects, device: vk.Device) void {
        std.debug.assert(device != null);
        for (0..frame_count_max) |i| {
            if (self.image_available_semaphores[i]) |sem| vk.vkDestroySemaphore(device, sem, null);
            self.image_available_semaphores[i] = null;
            if (self.in_flight_fences[i]) |fence| vk.vkDestroyFence(device, fence, null);
            self.in_flight_fences[i] = null;
        }
    }
};

pub const CommandBuffers = struct {
    render: [frame_count_max]vk.CommandBuffer,
};

pub const BufferError = error{
    BufferCreationFailed,
};

pub const CommandPoolError = error{
    CommandPoolCreationFailed,
};

pub const CommandBufferError = error{
    CommandBufferAllocationFailed,
};

pub const SyncError = error{
    SyncObjectCreationFailed,
};

pub const PoolError = error{
    PoolAllocationFailed,
    PoolMapFailed,
    NoSuitableMemoryType,
    ProbeBufferFailed,
    VulkanReservationExceedsAllocationMax,
    VulkanReservationExceedsHeap,
};

pub fn queryAllocationBytesMax(physical_device: vk.PhysicalDevice) vk.DeviceSize {
    assert(physical_device != null);
    var properties: vk.PhysicalDeviceProperties = undefined;
    vk.vkGetPhysicalDeviceProperties(physical_device, &properties);
    if (properties.apiVersion < vk.API_VERSION_1_1) return std.math.maxInt(vk.DeviceSize);

    var maintenance3 = vk.PhysicalDeviceMaintenance3Properties{
        .sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MAINTENANCE_3_PROPERTIES,
        .pNext = null,
        .maxPerSetDescriptors = 0,
        .maxMemoryAllocationSize = 0,
    };
    var properties2 = vk.PhysicalDeviceProperties2{
        .sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2,
        .pNext = &maintenance3,
        .properties = undefined,
    };
    vk.vkGetPhysicalDeviceProperties2(physical_device, &properties2);
    assert(maintenance3.maxMemoryAllocationSize >= 1 << 30);
    return maintenance3.maxMemoryAllocationSize;
}

fn checkReservation(
    mem_properties: *const vk.PhysicalDeviceMemoryProperties,
    options: *const MemoryPool.Options,
    memory_type_index: u32,
) ?PoolError {
    assert(memory_type_index < mem_properties.memoryTypeCount);
    assert(options.allocation_bytes_max > 0);
    const heap_index = mem_properties.memoryTypes[memory_type_index].heapIndex;
    assert(heap_index < mem_properties.memoryHeapCount);
    const heap_bytes = mem_properties.memoryHeaps[heap_index].size;
    if (options.size > options.allocation_bytes_max) {
        return PoolError.VulkanReservationExceedsAllocationMax;
    }
    if (options.size > heap_bytes) return PoolError.VulkanReservationExceedsHeap;
    return null;
}

fn reportReservation(
    mem_properties: *const vk.PhysicalDeviceMemoryProperties,
    options: *const MemoryPool.Options,
    memory_type_index: u32,
    err: PoolError,
) void {
    const heap_index = mem_properties.memoryTypes[memory_type_index].heapIndex;
    const heap_bytes = mem_properties.memoryHeaps[heap_index].size;
    const limit_name = switch (err) {
        PoolError.VulkanReservationExceedsAllocationMax => "maxMemoryAllocationSize",
        PoolError.VulkanReservationExceedsHeap => "the heap size",
        else => unreachable,
    };
    std.log.err(
        "Vulkan reservation '{s}' of {d} B exceeds {s} (maxMemoryAllocationSize {d} B; " ++
            "memory type {d} in heap {d} of {d} B). Lower ResourceLimits.",
        .{
            options.name,      options.size, limit_name, options.allocation_bytes_max,
            memory_type_index, heap_index,   heap_bytes,
        },
    );
}

pub const MemoryPool = struct {
    memory: vk.DeviceMemory = null,
    mapped: ?[*]u8 = null,
    size: vk.DeviceSize = 0,
    offset: vk.DeviceSize = 0,
    memory_type_index: u32 = 0,

    pub const Options = struct {
        name: []const u8,
        size: vk.DeviceSize,
        allocation_bytes_max: vk.DeviceSize,
        required_properties: u32,
    };

    pub fn init(
        device: vk.Device,
        mem_properties: *const vk.PhysicalDeviceMemoryProperties,
        options: *const Options,
    ) PoolError!MemoryPool {
        std.debug.assert(device != null);
        std.debug.assert(options.size > 0);
        std.debug.assert(options.name.len > 0);
        const size = options.size;
        const required_properties = options.required_properties;

        const probe_usage = vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT |
            vk.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT |
            vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT;
        const probe = createBufferHandle(device, 256, probe_usage) catch
            return PoolError.ProbeBufferFailed;
        var reqs: vk.MemoryRequirements = undefined;
        vk.vkGetBufferMemoryRequirements(device, probe, &reqs);
        vk.vkDestroyBuffer(device, probe, null);

        const type_index = vk.findMemoryType(
            mem_properties,
            reqs.memoryTypeBits,
            required_properties,
        ) orelse return PoolError.NoSuitableMemoryType;
        if (checkReservation(mem_properties, options, type_index)) |err| {
            reportReservation(mem_properties, options, type_index, err);
            return err;
        }

        const alloc_info = vk.MemoryAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = null,
            .allocationSize = size,
            .memoryTypeIndex = type_index,
        };

        var memory: vk.DeviceMemory = null;
        const result = vk.vkAllocateMemory(device, &alloc_info, null, &memory);
        if (!vk.succeeded(result)) {
            std.log.err("Vulkan reservation '{s}' of {d} B: vkAllocateMemory failed ({d}) " ++
                "on memory type {d}.", .{ options.name, size, result, type_index });
            return PoolError.PoolAllocationFailed;
        }
        std.debug.assert(memory != null);

        var mapped: ?[*]u8 = null;
        const is_host_visible = (required_properties & vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT) != 0;
        if (is_host_visible) {
            var raw: ?*anyopaque = null;
            if (!vk.succeeded(vk.vkMapMemory(device, memory, 0, size, 0, &raw))) {
                vk.vkFreeMemory(device, memory, null);
                return PoolError.PoolMapFailed;
            }
            std.debug.assert(raw != null);
            mapped = @ptrCast(raw);
        }

        return .{
            .memory = memory,
            .mapped = mapped,
            .size = size,
            .offset = 0,
            .memory_type_index = type_index,
        };
    }

    pub fn allocate(self: *MemoryPool, requirements: vk.MemoryRequirements) SubAllocation {
        const type_bit = @as(u32, 1) << @as(u5, @intCast(self.memory_type_index));
        std.debug.assert((requirements.memoryTypeBits & type_bit) != 0);

        const align_mask: vk.DeviceSize = requirements.alignment - 1;
        const aligned: vk.DeviceSize = (self.offset + align_mask) & ~align_mask;

        assert(aligned >= self.offset);
        const end = aligned + requirements.size;
        if (end <= self.size) {
            self.offset = end;
        } else {
            std.debug.panic(
                "Vulkan host memory pool exhausted: capacity {d} B, {d} B in use, " ++
                    "{d} B requested at alignment {d}.",
                .{ self.size, self.offset, requirements.size, requirements.alignment },
            );
        }

        var mapped_ptr: ?*anyopaque = null;
        if (self.mapped) |base| {
            mapped_ptr = @ptrCast(base + @as(usize, @intCast(aligned)));
        }

        return .{
            .memory = self.memory,
            .offset = aligned,
            .mapped = mapped_ptr,
        };
    }

    pub fn reset(self: *MemoryPool) void {
        std.debug.assert(self.memory != null);
        self.offset = 0;
    }

    pub fn destroy(self: *MemoryPool, device: vk.Device) void {
        std.debug.assert(device != null);
        if (self.mapped != null and self.memory != null) {
            vk.vkUnmapMemory(device, self.memory);
        }
        if (self.memory) |mem| vk.vkFreeMemory(device, mem, null);
        self.* = .{};
    }
};

pub fn destroyBufferOnly(device: vk.Device, buffer: vk.Buffer) void {
    std.debug.assert(device != null);
    if (buffer) |buf| vk.vkDestroyBuffer(device, buf, null);
}

pub fn createBufferFromPool(
    device: vk.Device,
    pool: *MemoryPool,
    size: vk.DeviceSize,
    usage: u32,
) BufferError!vk.Buffer {
    std.debug.assert(device != null);
    std.debug.assert(size > 0);

    const buffer = try createBufferHandle(device, size, usage);
    errdefer vk.vkDestroyBuffer(device, buffer, null);

    var reqs: vk.MemoryRequirements = undefined;
    vk.vkGetBufferMemoryRequirements(device, buffer, &reqs);

    const sub = pool.allocate(reqs);
    const bind_result = vk.vkBindBufferMemory(device, buffer, sub.memory, sub.offset);
    std.debug.assert(vk.succeeded(bind_result));

    return buffer;
}

pub fn createMappedBufferFromPool(
    device: vk.Device,
    pool: *MemoryPool,
    size: vk.DeviceSize,
    usage: u32,
) BufferError!MappedBufferResult {
    std.debug.assert(device != null);
    std.debug.assert(size > 0);
    std.debug.assert(pool.mapped != null);

    const buffer = try createBufferHandle(device, size, usage);
    errdefer vk.vkDestroyBuffer(device, buffer, null);

    var reqs: vk.MemoryRequirements = undefined;
    vk.vkGetBufferMemoryRequirements(device, buffer, &reqs);

    const sub = pool.allocate(reqs);
    const bind_result = vk.vkBindBufferMemory(device, buffer, sub.memory, sub.offset);
    std.debug.assert(vk.succeeded(bind_result));

    return .{
        .buffer = buffer,
        .memory = null,
        .mapped = sub.mapped orelse unreachable,
    };
}

pub fn createCommandPool(
    device: vk.Device,
    graphics_family: u32,
) CommandPoolError!vk.CommandPool {
    std.debug.assert(device != null);

    const pool_info = vk.CommandPoolCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .pNext = null,
        .flags = vk.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
        .queueFamilyIndex = graphics_family,
    };

    var pool: vk.CommandPool = null;
    const result = vk.vkCreateCommandPool(device, &pool_info, null, &pool);
    if (!vk.succeeded(result)) return CommandPoolError.CommandPoolCreationFailed;

    std.debug.assert(pool != null);
    return pool;
}

pub fn allocateCommandBuffers(
    device: vk.Device,
    command_pool: vk.CommandPool,
    frame_count: u32,
) CommandBufferError!CommandBuffers {
    std.debug.assert(device != null);
    std.debug.assert(command_pool != null);
    std.debug.assert(frame_count >= 1);
    std.debug.assert(frame_count <= frame_count_max);

    var result: CommandBuffers = .{
        .render = @as([frame_count_max]vk.CommandBuffer, @splat(null)),
    };

    const render_alloc = vk.CommandBufferAllocateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .pNext = null,
        .commandPool = command_pool,
        .level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = frame_count,
    };

    const render_res = vk.vkAllocateCommandBuffers(device, &render_alloc, &result.render);
    if (!vk.succeeded(render_res)) return CommandBufferError.CommandBufferAllocationFailed;

    return result;
}

pub fn createSyncObjects(device: vk.Device, frame_count: u32) SyncError!SyncObjects {
    std.debug.assert(device != null);
    std.debug.assert(frame_count >= 1);
    std.debug.assert(frame_count <= frame_count_max);

    var result: SyncObjects = .{
        .image_available_semaphores = @as([frame_count_max]vk.Semaphore, @splat(null)),
        .in_flight_fences = @as([frame_count_max]vk.Fence, @splat(null)),
    };
    errdefer result.destroy(device);

    const semaphore_info = vk.SemaphoreCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
    };

    const fence_info = vk.FenceCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
        .pNext = null,
        .flags = vk.VK_FENCE_CREATE_SIGNALED_BIT,
    };

    for (0..frame_count) |i| {
        var res = vk.vkCreateSemaphore(device, &semaphore_info, null, &result.image_available_semaphores[i]);
        if (!vk.succeeded(res)) return SyncError.SyncObjectCreationFailed;

        res = vk.vkCreateFence(device, &fence_info, null, &result.in_flight_fences[i]);
        if (!vk.succeeded(res)) return SyncError.SyncObjectCreationFailed;
    }

    return result;
}

pub fn createSemaphores(device: vk.Device, out: []vk.Semaphore) SyncError!void {
    assert(device != null);
    assert(out.len > 0);
    errdefer destroySemaphores(device, out);
    const semaphore_info = vk.SemaphoreCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
    };
    for (out) |*semaphore| {
        assert(semaphore.* == null);
        const result = vk.vkCreateSemaphore(device, &semaphore_info, null, semaphore);
        if (!vk.succeeded(result)) {
            semaphore.* = null;
            return SyncError.SyncObjectCreationFailed;
        }
        assert(semaphore.* != null);
    }
}

pub fn destroySemaphores(device: vk.Device, semaphores: []vk.Semaphore) void {
    assert(device != null);
    for (semaphores) |*semaphore| {
        if (semaphore.*) |handle| vk.vkDestroySemaphore(device, handle, null);
        semaphore.* = null;
    }
}

fn createBufferHandle(
    device: vk.Device,
    size: vk.DeviceSize,
    usage: u32,
) BufferError!vk.Buffer {
    const buffer_info = vk.BufferCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .size = size,
        .usage = usage,
        .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
        .queueFamilyIndexCount = 0,
        .pQueueFamilyIndices = null,
    };

    var buffer: vk.Buffer = null;
    const result = vk.vkCreateBuffer(device, &buffer_info, null, &buffer);
    if (!vk.succeeded(result)) return BufferError.BufferCreationFailed;

    std.debug.assert(buffer != null);
    return buffer;
}

test "reservations fail by name at the allocation and heap limits" {
    var properties = std.mem.zeroes(vk.PhysicalDeviceMemoryProperties);
    properties.memoryTypeCount = 2;
    properties.memoryHeapCount = 2;
    properties.memoryTypes[0].heapIndex = 0;
    properties.memoryTypes[1].heapIndex = 1;
    properties.memoryHeaps[0].size = 1 << 32;
    properties.memoryHeaps[1].size = 256 << 20;
    const allocation_max: vk.DeviceSize = 1 << 30;
    var options = MemoryPool.Options{
        .name = "test",
        .size = allocation_max,
        .allocation_bytes_max = allocation_max,
        .required_properties = 0,
    };
    try std.testing.expectEqual(@as(?PoolError, null), checkReservation(&properties, &options, 0));
    options.size = allocation_max + 1;
    try std.testing.expectEqual(
        @as(?PoolError, PoolError.VulkanReservationExceedsAllocationMax),
        checkReservation(&properties, &options, 0),
    );
    options.size = 256 << 20;
    try std.testing.expectEqual(@as(?PoolError, null), checkReservation(&properties, &options, 1));
    options.size = (256 << 20) + 1;
    try std.testing.expectEqual(
        @as(?PoolError, PoolError.VulkanReservationExceedsHeap),
        checkReservation(&properties, &options, 1),
    );
    options.size = allocation_max + 1;
    try std.testing.expectEqual(
        @as(?PoolError, PoolError.VulkanReservationExceedsAllocationMax),
        checkReservation(&properties, &options, 1),
    );
}
