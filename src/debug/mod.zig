//! Debug Tools
//!
//! - `RenderStats` - Per-frame render statistics (draw calls, primitives, culling)
//!
//! The UI inspector and profiler (Cmd/Ctrl+Shift+I) live in the core:
//! `src/core/debugger.zig`.

const std = @import("std");

pub const render_stats = @import("render_stats.zig");

pub const RenderStats = render_stats.RenderStats;
pub const frame_stats = &render_stats.frame_stats;
pub const beginFrame = render_stats.beginFrame;
pub const getStats = render_stats.getStats;

test {
    std.testing.refAllDecls(@This());
}
