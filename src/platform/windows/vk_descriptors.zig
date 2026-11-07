//! Shared with the Linux backend; see `../linux/vk_descriptors.zig`.
//! Thin re-export so relative imports inside the shared files
//! resolve against their own directory rather than this one.
const linux = @import("../linux/vk_descriptors.zig");

pub const AllocError = linux.AllocError;
pub const LayoutError = linux.LayoutError;
pub const PoolError = linux.PoolError;
pub const SamplerError = linux.SamplerError;
pub const allocateDescriptorSet = linux.allocateDescriptorSet;
pub const createAtlasSampler = linux.createAtlasSampler;
pub const createDescriptorPool = linux.createDescriptorPool;
pub const createTexturedLayout = linux.createTexturedLayout;
pub const createUnifiedLayout = linux.createUnifiedLayout;
pub const updateUnifiedDescriptorSet = linux.updateUnifiedDescriptorSet;
