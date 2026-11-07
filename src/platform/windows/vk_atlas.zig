//! Shared with the Linux backend; see `../linux/vk_atlas.zig`.
//! Thin re-export so relative imports inside the shared files
//! resolve against their own directory rather than this one.
const linux = @import("../linux/vk_atlas.zig");

pub const AtlasError = linux.AtlasError;
pub const AtlasFormat = linux.AtlasFormat;
pub const AtlasResources = linux.AtlasResources;
pub const DirtyRegion = linux.DirtyRegion;
pub const MAX_ATLAS_DIMENSION = linux.MAX_ATLAS_DIMENSION;
pub const MAX_STAGING_BYTES = linux.MAX_STAGING_BYTES;
pub const RGBA_STAGING_BYTES = linux.RGBA_STAGING_BYTES;
pub const STAGING_LANE_SIZE = linux.STAGING_LANE_SIZE;
pub const TEXT_STAGING_BYTES = linux.TEXT_STAGING_BYTES;
pub const ensureAtlasImage = linux.ensureAtlasImage;
pub const recordPartialAtlasTransfer = linux.recordPartialAtlasTransfer;
pub const stageDirtyRegion = linux.stageDirtyRegion;
pub const updateAtlasDescriptorSet = linux.updateAtlasDescriptorSet;
