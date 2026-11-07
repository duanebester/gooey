//! Shared with the Linux backend; see `../linux/scene_renderer.zig`.
//! Thin re-export so relative imports inside the shared files
//! resolve against their own directory rather than this one.
const linux = @import("../linux/scene_renderer.zig");

pub const BatchCounts = linux.BatchCounts;
pub const BatchIterator = linux.BatchIterator;
pub const Pipelines = linux.Pipelines;
pub const PrimitiveBatch = linux.PrimitiveBatch;
pub const drawScene = linux.drawScene;
