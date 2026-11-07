//! Shared with the Linux backend; see `../linux/vk_types.zig`.
//! Thin re-export so relative imports inside the shared files
//! resolve against their own directory rather than this one.
const linux = @import("../linux/vk_types.zig");

pub const FRAME_COUNT = linux.FRAME_COUNT;
pub const GpuGlyph = linux.GpuGlyph;
pub const GpuImage = linux.GpuImage;
pub const GpuSvg = linux.GpuSvg;
pub const InstanceCapacity = linux.InstanceCapacity;
pub const InstancePool = linux.InstancePool;
pub const MAX_PRESENT_MODES = linux.MAX_PRESENT_MODES;
pub const MAX_SURFACE_FORMATS = linux.MAX_SURFACE_FORMATS;
pub const Uniforms = linux.Uniforms;
pub const host_pool_alignment_slack_bytes = linux.host_pool_alignment_slack_bytes;
pub const host_pool_allocation_count = linux.host_pool_allocation_count;
pub const storage_buffer_range_guaranteed_bytes = linux.storage_buffer_range_guaranteed_bytes;
