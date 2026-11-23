const builtin = @import("builtin");

pub const path = @import("path.zig");

pub const Vec2 = path.Vec2;
pub const IndexSlice = path.IndexSlice;
pub const PathCommand = path.PathCommand;
pub const CubicBez = path.CubicBez;
pub const QuadraticBez = path.QuadraticBez;
pub const SvgPath = path.SvgPath;
pub const PathParser = path.PathParser;
pub const SvgElementParser = path.SvgElementParser;
pub const flattenArc = path.flattenArc;
pub const flattenPath = path.flattenPath;

pub const SvgAtlas = @import("atlas.zig").SvgAtlas;
pub const SvgKey = @import("atlas.zig").SvgKey;
pub const CachedSvg = @import("atlas.zig").CachedSvg;

pub const rasterizer = @import("rasterizer.zig");
pub const rasterize = rasterizer.rasterize;
pub const rasterizeWithOptions = rasterizer.rasterizeWithOptions;
pub const RasterizedSvg = rasterizer.RasterizedSvg;
pub const RasterizeError = rasterizer.RasterizeError;
pub const StrokeOptions = rasterizer.StrokeOptions;
pub const RasterBudget = rasterizer.RasterBudget;

const is_wasm = builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64;

pub const backends = struct {
    pub const coregraphics = if (!is_wasm and builtin.os.tag == .macos)
        @import("backends/coregraphics.zig")
    else
        struct {};

    pub const cairo = if (!is_wasm and builtin.os.tag == .linux)
        @import("backends/cairo.zig")
    else
        struct {};

    pub const canvas = if (is_wasm)
        @import("backends/canvas.zig")
    else
        struct {};

    pub const null_backend = @import("backends/null.zig");
};
