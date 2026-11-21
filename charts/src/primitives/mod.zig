pub const scale = @import("scale.zig");
pub const axis = @import("axis.zig");
pub const grid = @import("grid.zig");
pub const legend = @import("legend.zig");

pub const LinearScale = scale.LinearScale;
pub const BandScale = scale.BandScale;
pub const Scale = scale.Scale;

pub const Axis = axis.Axis;
pub const Grid = grid.Grid;
pub const Legend = legend.Legend;

pub const Color = axis.Color;
pub const Painter = axis.Painter;

test {
    @import("std").testing.refAllDecls(@This());
}
