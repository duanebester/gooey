//! Chart Primitives Module
//!
//! Low-level building blocks for chart rendering:
//! - Scale: Maps data values to pixel coordinates
//! - Axis: Renders axis lines, ticks, and labels
//! - Grid: Renders background grid lines
//! - Legend: Renders series names and colors
//!
//! These primitives can be composed to build custom charts
//! or used by the higher-level chart components.

pub const scale = @import("scale.zig");
pub const axis = @import("axis.zig");
pub const grid = @import("grid.zig");
pub const legend = @import("legend.zig");

// Re-export main types for convenience
pub const LinearScale = scale.LinearScale;
pub const BandScale = scale.BandScale;
pub const Scale = scale.Scale;

pub const Axis = axis.Axis;
pub const Grid = grid.Grid;
pub const Legend = legend.Legend;

// Re-export Color and DrawContext from axis (which imports from gooey)
pub const Color = axis.Color;
pub const DrawContext = axis.DrawContext;

// =============================================================================
// Tests
// =============================================================================

test {
    @import("std").testing.refAllDecls(@This());
}
