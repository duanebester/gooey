//! Shared with the Linux backend; see `../linux/vk_buffers.zig`.
//! Thin re-export so relative imports inside the shared files
//! resolve against their own directory rather than this one.
const linux = @import("../linux/vk_buffers.zig");

pub const BufferError = linux.BufferError;
pub const BufferResult = linux.BufferResult;
pub const CommandBufferError = linux.CommandBufferError;
pub const CommandBuffers = linux.CommandBuffers;
pub const CommandPoolError = linux.CommandPoolError;
pub const FRAME_COUNT = linux.FRAME_COUNT;
pub const MappedBufferResult = linux.MappedBufferResult;
pub const MemoryPool = linux.MemoryPool;
pub const PoolError = linux.PoolError;
pub const SubAllocation = linux.SubAllocation;
pub const SyncError = linux.SyncError;
pub const SyncObjects = linux.SyncObjects;
pub const allocateCommandBuffers = linux.allocateCommandBuffers;
pub const createBuffer = linux.createBuffer;
pub const createBufferFromPool = linux.createBufferFromPool;
pub const createCommandPool = linux.createCommandPool;
pub const createMappedBuffer = linux.createMappedBuffer;
pub const createMappedBufferFromPool = linux.createMappedBufferFromPool;
pub const createSemaphores = linux.createSemaphores;
pub const createSyncObjects = linux.createSyncObjects;
pub const destroyBuffer = linux.destroyBuffer;
pub const destroyBufferOnly = linux.destroyBufferOnly;
pub const destroySemaphores = linux.destroySemaphores;
