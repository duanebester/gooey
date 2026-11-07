//! Shared with the Linux backend; see `../linux/vk_pipelines.zig`.
//! Thin re-export so relative imports inside the shared files
//! resolve against their own directory rather than this one.
const linux = @import("../linux/vk_pipelines.zig");

pub const BlendMode = linux.BlendMode;
pub const PipelineConfig = linux.PipelineConfig;
pub const PipelineError = linux.PipelineError;
pub const createGraphicsPipeline = linux.createGraphicsPipeline;
pub const createPipelineCache = linux.createPipelineCache;
pub const createPipelineLayout = linux.createPipelineLayout;
pub const destroyPipeline = linux.destroyPipeline;
