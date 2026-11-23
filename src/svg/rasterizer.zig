const builtin = @import("builtin");
const interface_verify = @import("../core/interface_verify.zig");

const is_wasm = builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64;

const backend = if (is_wasm)
    @import("backends/canvas.zig")
else switch (builtin.os.tag) {
    .macos => @import("backends/coregraphics.zig"),
    .linux, .windows => @import("backends/cairo.zig"),
    else => @import("backends/null.zig"),
};

comptime {
    interface_verify.verifySvgRasterizerModule(backend);
}

pub const RasterizedSvg = backend.RasterizedSvg;
pub const RasterizeError = backend.RasterizeError;
pub const StrokeOptions = backend.StrokeOptions;
pub const RasterBudget = backend.RasterBudget;

pub const rasterize = backend.rasterize;
pub const rasterizeWithOptions = backend.rasterizeWithOptions;
pub const scratchBytes = backend.scratchBytes;
