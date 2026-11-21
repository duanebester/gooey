const std = @import("std");

pub const geometry = @import("geometry.zig");

pub const Point = geometry.Point;
pub const Size = geometry.Size;
pub const Rect = geometry.Rect;
pub const Bounds = geometry.Bounds;
pub const Edges = geometry.Edges;
pub const Corners = geometry.Corners;
pub const Color = geometry.Color;

pub const PointF = geometry.PointF;
pub const PointI = geometry.PointI;
pub const SizeF = geometry.SizeF;
pub const SizeI = geometry.SizeI;
pub const RectF = geometry.RectF;
pub const RectI = geometry.RectI;
pub const BoundsF = geometry.BoundsF;
pub const BoundsI = geometry.BoundsI;
pub const EdgesF = geometry.EdgesF;
pub const EdgesI = geometry.EdgesI;
pub const CornersF = geometry.CornersF;
pub const CornersI = geometry.CornersI;

pub const GpuPoint = geometry.GpuPoint;
pub const GpuSize = geometry.GpuSize;
pub const GpuBounds = geometry.GpuBounds;
pub const GpuCorners = geometry.GpuCorners;
pub const GpuEdges = geometry.GpuEdges;

pub const Pixels = geometry.Pixels;

pub const vec2 = @import("vec2.zig");
pub const Vec2 = vec2.Vec2;
pub const IndexSlice = vec2.IndexSlice;

pub const triangulator = @import("triangulator.zig");
pub const Triangulator = triangulator.Triangulator;

pub const stroke = @import("stroke.zig");
pub const LineCap = stroke.LineCap;
pub const LineJoin = stroke.LineJoin;
pub const StrokeStyle = stroke.StrokeStyle;
pub const StrokeError = stroke.StrokeError;

test {
    std.testing.refAllDecls(@This());
}
