const std = @import("std");

pub fn verifySvgRasterizerInterface(comptime T: type) void {
    comptime {
        if (!@hasDecl(T, "rasterize") and !@hasDecl(T, "rasterizeWithOptions")) {
            @compileError("SvgRasterizer must have rasterize or rasterizeWithOptions method");
        }
    }
}

pub fn verifySvgRasterizerModule(comptime M: type) void {
    comptime {
        if (!@hasDecl(M, "rasterize") and !@hasDecl(M, "rasterizeWithOptions")) {
            @compileError("SvgRasterizer module must export rasterize or rasterizeWithOptions function");
        }

        assertHasDecl(M, "RasterizedSvg", "SvgRasterizer module");
        assertHasDecl(M, "RasterizeError", "SvgRasterizer module");
        assertHasDecl(M, "StrokeOptions", "SvgRasterizer module");
        assertHasDecl(M, "RasterBudget", "SvgRasterizer module");
        assertHasDecl(M, "scratchBytes", "SvgRasterizer module");
    }
}

pub fn verifyImageLoaderModule(comptime M: type) void {
    comptime {
        if (!@hasDecl(M, "load") and !@hasDecl(M, "loadFromMemory")) {
            @compileError("ImageLoader module must export load or loadFromMemory function");
        }

        assertHasDecl(M, "DecodedImage", "ImageLoader module");
        assertHasDecl(M, "LoadError", "ImageLoader module");
    }
}

fn assertHasDecl(comptime T: type, comptime name: []const u8, comptime interface: []const u8) void {
    if (!@hasDecl(T, name)) {
        @compileError(std.fmt.comptimePrint(
            "{s} interface requires '{s}' method, but {s} does not have it",
            .{ interface, name, @typeName(T) },
        ));
    }
}

test "interface verification helpers compile" {
    _ = assertHasDecl;
}

test "verifySvgRasterizerModule with mock" {
    const MockSvgModule = struct {
        pub const RasterizedSvg = struct {
            width: u32,
            height: u32,
            offset_x: i16,
            offset_y: i16,
        };

        pub const RasterizeError = error{
            EmptyPath,
            GraphicsError,
        };

        pub const StrokeOptions = struct {
            enabled: bool = false,
            width: f32 = 1.0,
        };

        pub const RasterBudget = struct {
            path_bytes_max: u32,
            vertex_count_max: u32,
        };

        pub fn scratchBytes(_: RasterBudget, _: u32) u32 {
            return 0;
        }

        pub fn rasterize(
            _: std.mem.Allocator,
            _: []const u8,
            _: f32,
            _: u32,
            _: []u8,
        ) RasterizeError!RasterizedSvg {
            return error.EmptyPath;
        }

        pub fn rasterizeWithOptions(
            _: std.mem.Allocator,
            _: []const u8,
            _: f32,
            _: u32,
            _: []u8,
            _: bool,
            _: StrokeOptions,
            _: RasterBudget,
        ) RasterizeError!RasterizedSvg {
            return error.EmptyPath;
        }
    };

    comptime {
        verifySvgRasterizerModule(MockSvgModule);
    }
}

test "verifyImageLoaderModule with mock" {
    const MockImageLoaderModule = struct {
        pub const DecodedImage = struct {
            width: u32,
            height: u32,
            pixels: []u8,
        };

        pub const LoadError = error{
            InvalidFormat,
            OutOfMemory,
        };

        pub fn load(_: std.mem.Allocator, _: anytype) LoadError!DecodedImage {
            return LoadError.InvalidFormat;
        }

        pub fn loadFromMemory(_: std.mem.Allocator, _: []const u8) LoadError!DecodedImage {
            return LoadError.InvalidFormat;
        }
    };

    comptime {
        verifyImageLoaderModule(MockImageLoaderModule);
    }
}
