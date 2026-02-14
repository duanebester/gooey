//! Vulkan buffer, command pool, command buffer, and sync object creation.
//!
//! Free functions with targeted parameters — each takes only what it needs,
//! not the entire VulkanRenderer. These are the per-frame resource primitives
//! that higher-level code composes into application-specific buffer sets.

const std = @import("std");
const vk = @import("vulkan.zig");
const vk_types = @import("vk_types.zig");

// =============================================================================
// Limits (CLAUDE.md Rule #4 — put a limit on everything)
// =============================================================================

pub const FRAME_COUNT: u32 = vk_types.FRAME_COUNT;

// =============================================================================
// Result Types
// =============================================================================

pub const BufferResult = struct {
    buffer: vk.Buffer,
    memory: vk.DeviceMemory,
};

pub const MappedBufferResult = struct {
    buffer: vk.Buffer,
    memory: vk.DeviceMemory,
    mapped: *anyopaque,
};

/// Result of a sub-allocation from a MemoryPool.
/// The memory handle belongs to the pool — caller must NOT free it individually.
pub const SubAllocation = struct {
    memory: vk.DeviceMemory,
    offset: vk.DeviceSize,
    mapped: ?*anyopaque,
};

pub const SyncObjects = struct {
    image_available_semaphores: [FRAME_COUNT]vk.Semaphore,
    render_finished_semaphores: [FRAME_COUNT]vk.Semaphore,
    in_flight_fences: [FRAME_COUNT]vk.Fence,

    /// Destroy all sync objects. Safe to call with null entries.
    pub fn destroy(self: *SyncObjects, device: vk.Device) void {
        std.debug.assert(device != null);
        for (0..FRAME_COUNT) |i| {
            if (self.image_available_semaphores[i]) |sem| vk.vkDestroySemaphore(device, sem, null);
            self.image_available_semaphores[i] = null;
            if (self.render_finished_semaphores[i]) |sem| vk.vkDestroySemaphore(device, sem, null);
            self.render_finished_semaphores[i] = null;
            if (self.in_flight_fences[i]) |fence| vk.vkDestroyFence(device, fence, null);
            self.in_flight_fences[i] = null;
        }
    }
};

pub const CommandBuffers = struct {
    render: [FRAME_COUNT]vk.CommandBuffer,
};

// =============================================================================
// Error Types
// =============================================================================

pub const BufferError = error{
    BufferCreationFailed,
    NoSuitableMemoryType,
    MemoryAllocationFailed,
    MemoryMapFailed,
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
};

// =============================================================================
// MemoryPool — sub-allocate from a single large VkDeviceMemory block
// =============================================================================

/// Bump-allocator over a single VkDeviceMemory allocation.
///
/// Reduces N individual `vkAllocateMemory` calls to 1. Two pools cover all
/// cases: host-visible (mapped buffers) and device-local (images).
/// Uses a probe buffer at init to discover valid memory type bits, then
/// asserts compatibility on every sub-allocation (CLAUDE.md Rule #11).
pub const MemoryPool = struct {
    memory: vk.DeviceMemory = null,
    mapped: ?[*]u8 = null,
    size: vk.DeviceSize = 0,
    offset: vk.DeviceSize = 0,
    memory_type_index: u32 = 0,

    /// Hard cap on sub-allocations per pool (CLAUDE.md Rule #4).
    const MAX_POOL_ALLOCATIONS: u32 = 64;

    /// Create a memory pool backed by a single large allocation.
    ///
    /// Uses a probe buffer to discover valid memoryTypeBits for storage/uniform
    /// usage, then finds a memory type matching `required_properties`.
    /// If the pool is host-visible, the entire block is mapped at creation.
    pub fn init(
        device: vk.Device,
        mem_properties: *const vk.PhysicalDeviceMemoryProperties,
        size: vk.DeviceSize,
        required_properties: u32,
    ) PoolError!MemoryPool {
        std.debug.assert(device != null);
        std.debug.assert(size > 0);

        // Probe buffer discovers valid memoryTypeBits for buffer allocations.
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

        const alloc_info = vk.MemoryAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = null,
            .allocationSize = size,
            .memoryTypeIndex = type_index,
        };

        var memory: vk.DeviceMemory = null;
        if (!vk.succeeded(vk.vkAllocateMemory(device, &alloc_info, null, &memory))) {
            return PoolError.PoolAllocationFailed;
        }
        std.debug.assert(memory != null);

        // Map entire block if host-visible
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

    /// Sub-allocate a region satisfying `requirements` from this pool.
    ///
    /// Returns the pool's memory handle + aligned offset + mapped pointer.
    /// Asserts (fails fast) if the pool is exhausted or memory type is
    /// incompatible — both indicate a sizing bug, not a runtime condition.
    pub fn allocate(self: *MemoryPool, requirements: vk.MemoryRequirements) SubAllocation {
        // Assert pool's memory type is compatible with buffer requirements
        const type_bit = @as(u32, 1) << @as(u5, @intCast(self.memory_type_index));
        std.debug.assert((requirements.memoryTypeBits & type_bit) != 0);

        // Align offset to buffer's required alignment
        const align_mask: vk.DeviceSize = requirements.alignment - 1;
        const aligned: vk.DeviceSize = (self.offset + align_mask) & ~align_mask;

        // Fail fast if pool is exhausted (CLAUDE.md Rule #4)
        std.debug.assert(aligned + requirements.size <= self.size);

        self.offset = aligned + requirements.size;

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

    /// Reset the bump offset to zero, allowing the pool to be reused.
    /// Does NOT free or unmap the backing memory.
    pub fn reset(self: *MemoryPool) void {
        std.debug.assert(self.memory != null);
        self.offset = 0;
    }

    /// Destroy the pool's backing memory. Safe to call with null memory.
    pub fn destroy(self: *MemoryPool, device: vk.Device) void {
        std.debug.assert(device != null);
        if (self.mapped != null and self.memory != null) {
            vk.vkUnmapMemory(device, self.memory);
        }
        if (self.memory) |mem| vk.vkFreeMemory(device, mem, null);
        self.* = .{};
    }
};

// =============================================================================
// Public API — Buffers
// =============================================================================

/// Create a Vulkan buffer with dedicated memory allocation.
///
/// Caller owns both returned handles and must destroy them via `destroyBuffer`
/// or individually when no longer needed.
pub fn createBuffer(
    device: vk.Device,
    mem_properties: *const vk.PhysicalDeviceMemoryProperties,
    size: vk.DeviceSize,
    usage: u32,
    properties: u32,
) BufferError!BufferResult {
    std.debug.assert(device != null);
    std.debug.assert(size > 0);

    const buffer = try createBufferHandle(device, size, usage);
    errdefer vk.vkDestroyBuffer(device, buffer, null);

    const memory = try allocateBufferMemory(device, mem_properties, buffer, properties);

    return .{ .buffer = buffer, .memory = memory };
}

/// Create a buffer, allocate memory, bind it, and map the memory.
///
/// Convenience wrapper for host-visible buffers that will be written from the CPU.
/// The returned mapped pointer is valid until the buffer is destroyed.
pub fn createMappedBuffer(
    device: vk.Device,
    mem_properties: *const vk.PhysicalDeviceMemoryProperties,
    size: vk.DeviceSize,
    usage: u32,
) BufferError!MappedBufferResult {
    std.debug.assert(device != null);
    std.debug.assert(size > 0);

    const host_props = vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    const result = try createBuffer(device, mem_properties, size, usage, host_props);
    errdefer destroyBuffer(device, result.buffer, result.memory);

    var mapped: ?*anyopaque = null;
    const map_result = vk.vkMapMemory(device, result.memory, 0, size, 0, &mapped);
    if (!vk.succeeded(map_result) or mapped == null) return BufferError.MemoryMapFailed;

    return .{
        .buffer = result.buffer,
        .memory = result.memory,
        .mapped = mapped.?,
    };
}

/// Destroy a buffer and free its memory. Safe to call with null handles.
pub fn destroyBuffer(device: vk.Device, buffer: vk.Buffer, memory: vk.DeviceMemory) void {
    std.debug.assert(device != null);
    if (buffer) |buf| vk.vkDestroyBuffer(device, buf, null);
    if (memory) |mem| vk.vkFreeMemory(device, mem, null);
}

/// Destroy only the buffer handle. Memory is NOT freed — use this for
/// pool-allocated buffers where the pool owns the backing memory.
pub fn destroyBufferOnly(device: vk.Device, buffer: vk.Buffer) void {
    std.debug.assert(device != null);
    if (buffer) |buf| vk.vkDestroyBuffer(device, buf, null);
}

// =============================================================================
// Public API — Pool-Based Buffer Creation
// =============================================================================

/// Create a buffer backed by a sub-allocation from a MemoryPool.
///
/// The buffer handle is owned by the caller (destroy via `destroyBufferOnly`),
/// but the memory is owned by the pool. Do NOT call `vkFreeMemory` on it.
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

/// Create a buffer from a MemoryPool and return the mapped pointer.
///
/// The pool must be host-visible (mapped != null). The mapped pointer points
/// into the pool's mapped range at the sub-allocated offset.
pub fn createMappedBufferFromPool(
    device: vk.Device,
    pool: *MemoryPool,
    size: vk.DeviceSize,
    usage: u32,
) BufferError!MappedBufferResult {
    std.debug.assert(device != null);
    std.debug.assert(size > 0);
    std.debug.assert(pool.mapped != null); // Pool must be host-visible

    const buffer = try createBufferHandle(device, size, usage);
    errdefer vk.vkDestroyBuffer(device, buffer, null);

    var reqs: vk.MemoryRequirements = undefined;
    vk.vkGetBufferMemoryRequirements(device, buffer, &reqs);

    const sub = pool.allocate(reqs);
    const bind_result = vk.vkBindBufferMemory(device, buffer, sub.memory, sub.offset);
    std.debug.assert(vk.succeeded(bind_result));

    return .{
        .buffer = buffer,
        .memory = null, // Pool owns memory — do NOT free individually
        .mapped = sub.mapped orelse unreachable,
    };
}

// =============================================================================
// Public API — Command Pool & Buffers
// =============================================================================

/// Create a command pool for the given queue family.
///
/// Created with RESET_COMMAND_BUFFER_BIT so individual command buffers can be
/// reset and re-recorded each frame.
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

/// Allocate render command buffers (one per frame in flight).
/// Atlas transfers are recorded directly into per-frame render command buffers,
/// so no dedicated transfer buffer is needed.
pub fn allocateCommandBuffers(
    device: vk.Device,
    command_pool: vk.CommandPool,
) CommandBufferError!CommandBuffers {
    std.debug.assert(device != null);
    std.debug.assert(command_pool != null);

    var result: CommandBuffers = .{
        .render = [_]vk.CommandBuffer{null} ** FRAME_COUNT,
    };

    // Allocate render command buffers (one per frame in flight)
    const render_alloc = vk.CommandBufferAllocateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .pNext = null,
        .commandPool = command_pool,
        .level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = FRAME_COUNT,
    };

    const render_res = vk.vkAllocateCommandBuffers(device, &render_alloc, &result.render);
    if (!vk.succeeded(render_res)) return CommandBufferError.CommandBufferAllocationFailed;

    return result;
}

// =============================================================================
// Public API — Synchronization
// =============================================================================

/// Create all synchronization objects: per-frame semaphores and fences,
/// plus a dedicated transfer fence.
///
/// All fences are created in the signaled state so the first vkWaitForFences
/// call succeeds immediately.
pub fn createSyncObjects(device: vk.Device) SyncError!SyncObjects {
    std.debug.assert(device != null);

    var result: SyncObjects = .{
        .image_available_semaphores = [_]vk.Semaphore{null} ** FRAME_COUNT,
        .render_finished_semaphores = [_]vk.Semaphore{null} ** FRAME_COUNT,
        .in_flight_fences = [_]vk.Fence{null} ** FRAME_COUNT,
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

    for (0..FRAME_COUNT) |i| {
        var res = vk.vkCreateSemaphore(device, &semaphore_info, null, &result.image_available_semaphores[i]);
        if (!vk.succeeded(res)) return SyncError.SyncObjectCreationFailed;

        res = vk.vkCreateSemaphore(device, &semaphore_info, null, &result.render_finished_semaphores[i]);
        if (!vk.succeeded(res)) return SyncError.SyncObjectCreationFailed;

        res = vk.vkCreateFence(device, &fence_info, null, &result.in_flight_fences[i]);
        if (!vk.succeeded(res)) return SyncError.SyncObjectCreationFailed;
    }

    return result;
}

// =============================================================================
// Internal Helpers
// =============================================================================

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

fn allocateBufferMemory(
    device: vk.Device,
    mem_properties: *const vk.PhysicalDeviceMemoryProperties,
    buffer: vk.Buffer,
    properties: u32,
) BufferError!vk.DeviceMemory {
    std.debug.assert(buffer != null);

    var mem_requirements: vk.MemoryRequirements = undefined;
    vk.vkGetBufferMemoryRequirements(device, buffer, &mem_requirements);

    const mem_type_index = vk.findMemoryType(
        mem_properties,
        mem_requirements.memoryTypeBits,
        properties,
    ) orelse return BufferError.NoSuitableMemoryType;

    const alloc_info = vk.MemoryAllocateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .pNext = null,
        .allocationSize = mem_requirements.size,
        .memoryTypeIndex = mem_type_index,
    };

    var memory: vk.DeviceMemory = null;
    const result = vk.vkAllocateMemory(device, &alloc_info, null, &memory);
    if (!vk.succeeded(result)) return BufferError.MemoryAllocationFailed;

    std.debug.assert(memory != null);

    _ = vk.vkBindBufferMemory(device, buffer, memory, 0);
    return memory;
}
