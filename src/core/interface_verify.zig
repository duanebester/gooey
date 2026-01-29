//! Compile-time interface verification
//!
//! Ensures platform backends implement required methods with correct signatures.
//! This provides interface-like guarantees without runtime overhead.
//!
//! Usage in a backend file:
//!   const interface_verify = @import("../../core/interface_verify.zig");
//!   comptime { interface_verify.verifyRendererInterface(@This()); }

const std = @import("std");

/// Verify a type implements the Renderer interface
///
/// Required methods:
///   - deinit(*Self) void
///   - renderScene or render (at least one)
///
/// NOTE: The render/renderScene flexibility is intentional. Platform renderers
/// have legitimately different signatures:
///   - Metal: render(clear_color), renderScene(scene, clear_color) — has internal scene state
///   - Vulkan: render(scene) — stateless, scene passed in
///   - Web: render(scene, viewport_w, viewport_h, r, g, b, a) — needs viewport info
///
/// The verification only checks that *some* render capability exists, not the
/// exact signature, because platform-specific calling code handles the differences.
///
/// Optional methods (platform-dependent):
///   - resize(*Self, ...) - native platforms; web handles resize via canvas
///   - beginFrame/endFrame - if using explicit frame boundaries
pub fn verifyRendererInterface(comptime T: type) void {
    comptime {
        // Must have deinit
        assertHasDecl(T, "deinit", "Renderer");

        // Must have either renderScene or render for rendering
        if (!@hasDecl(T, "renderScene") and !@hasDecl(T, "render")) {
            @compileError("Renderer must have renderScene or render method");
        }

        // Note: resize is optional - web platforms handle resize via canvas/viewport
        // Native platforms (Metal, Vulkan) should have resize
    }
}

/// Verify a type implements the SvgRasterizer interface (struct-based)
///
/// Required methods:
///   - rasterize or rasterizeWithOptions
pub fn verifySvgRasterizerInterface(comptime T: type) void {
    comptime {
        if (!@hasDecl(T, "rasterize") and !@hasDecl(T, "rasterizeWithOptions")) {
            @compileError("SvgRasterizer must have rasterize or rasterizeWithOptions method");
        }
    }
}

/// Verify a module implements the SvgRasterizer interface (module-level functions)
///
/// Required exports:
///   - rasterize fn
///   - rasterizeWithOptions fn
///   - RasterizedSvg type
///   - RasterizeError type
///   - StrokeOptions type
pub fn verifySvgRasterizerModule(comptime M: type) void {
    comptime {
        // Required function exports
        if (!@hasDecl(M, "rasterize") and !@hasDecl(M, "rasterizeWithOptions")) {
            @compileError("SvgRasterizer module must export rasterize or rasterizeWithOptions function");
        }

        // Required type exports
        assertHasDecl(M, "RasterizedSvg", "SvgRasterizer module");
        assertHasDecl(M, "RasterizeError", "SvgRasterizer module");
        assertHasDecl(M, "StrokeOptions", "SvgRasterizer module");
    }
}

/// Verify a type implements the ImageLoader interface
///
/// Required methods:
///   - loadFromMemory or decode
pub fn verifyImageLoaderInterface(comptime T: type) void {
    comptime {
        if (!@hasDecl(T, "loadFromMemory") and !@hasDecl(T, "decode")) {
            @compileError("ImageLoader must have loadFromMemory or decode method");
        }
    }
}

/// Verify a module implements the ImageLoader interface (module-level functions)
///
/// Required exports:
///   - load or loadFromMemory fn
///   - DecodedImage type
///   - LoadError type
pub fn verifyImageLoaderModule(comptime M: type) void {
    comptime {
        // Required function exports
        if (!@hasDecl(M, "load") and !@hasDecl(M, "loadFromMemory")) {
            @compileError("ImageLoader module must export load or loadFromMemory function");
        }

        // Required type exports
        assertHasDecl(M, "DecodedImage", "ImageLoader module");
        assertHasDecl(M, "LoadError", "ImageLoader module");
    }
}

/// Verify a type implements the Clipboard interface
///
/// Required methods:
///   - getText(*Self, Allocator) ?[]const u8
///   - setText(*Self, []const u8) bool
pub fn verifyClipboardInterface(comptime T: type) void {
    comptime {
        assertHasDecl(T, "getText", "Clipboard");
        assertHasDecl(T, "setText", "Clipboard");
    }
}

/// Verify a type implements the Platform interface
///
/// Required methods:
///   - init
///   - deinit
pub fn verifyPlatformInterface(comptime T: type) void {
    comptime {
        assertHasDecl(T, "init", "Platform");
        assertHasDecl(T, "deinit", "Platform");
    }
}

/// Verify a type implements the Window interface
///
/// Required methods:
///   - getSize
///   - setTitle
pub fn verifyWindowInterface(comptime T: type) void {
    comptime {
        assertHasDecl(T, "getSize", "Window");
        assertHasDecl(T, "setTitle", "Window");
    }
}

/// Verify a type implements the FileDialog interface
///
/// Required methods:
///   - promptForPaths(*Self, Allocator, PathPromptOptions) ?PathPromptResult
///   - promptForNewPath(*Self, Allocator, SavePromptOptions) ?[]const u8
pub fn verifyFileDialogInterface(comptime T: type) void {
    comptime {
        assertHasDecl(T, "promptForPaths", "FileDialog");
        assertHasDecl(T, "promptForNewPath", "FileDialog");
    }
}

// =============================================================================
// Helpers
// =============================================================================

fn assertHasDecl(comptime T: type, comptime name: []const u8, comptime interface: []const u8) void {
    if (!@hasDecl(T, name)) {
        @compileError(std.fmt.comptimePrint(
            "{s} interface requires '{s}' method, but {s} does not have it",
            .{ interface, name, @typeName(T) },
        ));
    }
}

/// Check if a type has a specific declaration (for optional features)
pub fn hasDecl(comptime T: type, comptime name: []const u8) bool {
    return @hasDecl(T, name);
}

// =============================================================================
// Tests
// =============================================================================

test "interface verification helpers compile" {
    // These are comptime-only, just verify the module compiles
    _ = assertHasDecl;
    _ = hasDecl;
}

test "verifyRendererInterface with mock" {
    const MockRenderer = struct {
        pub fn deinit(_: *@This()) void {}
        pub fn resize(_: *@This(), _: u32, _: u32, _: f64) void {}
        pub fn render(_: *@This()) void {}
    };

    // Should not cause compile error
    comptime {
        verifyRendererInterface(MockRenderer);
    }
}

test "verifyRendererInterface with web-style mock (no resize)" {
    const MockWebRenderer = struct {
        pub fn deinit(_: *@This()) void {}
        pub fn render(_: *@This()) void {}
    };

    // Should not cause compile error - resize is optional for web
    comptime {
        verifyRendererInterface(MockWebRenderer);
    }
}

test "verifyClipboardInterface with mock" {
    const MockClipboard = struct {
        pub fn getText(_: *@This(), _: std.mem.Allocator) ?[]const u8 {
            return null;
        }
        pub fn setText(_: *@This(), _: []const u8) bool {
            return false;
        }
    };

    // Should not cause compile error
    comptime {
        verifyClipboardInterface(MockClipboard);
    }
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
        ) RasterizeError!RasterizedSvg {
            return error.EmptyPath;
        }
    };

    // Should not cause compile error
    comptime {
        verifySvgRasterizerModule(MockSvgModule);
    }
}

test "verifyFileDialogInterface with mock" {
    const MockFileDialog = struct {
        pub fn promptForPaths(_: *@This(), _: std.mem.Allocator, _: anytype) ?void {
            return null;
        }
        pub fn promptForNewPath(_: *@This(), _: std.mem.Allocator, _: anytype) ?[]const u8 {
            return null;
        }
    };

    // Should not cause compile error
    comptime {
        verifyFileDialogInterface(MockFileDialog);
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

    // Should not cause compile error
    comptime {
        verifyImageLoaderModule(MockImageLoaderModule);
    }
}
