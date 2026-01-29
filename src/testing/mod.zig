//! Testing utilities for Gooey
//!
//! Provides mock implementations and test helpers.
//! Only compiled when running tests.
//!
//! ## Available Mocks
//!
//! - `MockRenderer` - Tracks render calls without GPU operations
//! - `MockClipboard` - In-memory clipboard for copy/paste testing
//! - `MockSvgRasterizer` - Simulates SVG rasterization
//! - `MockFontFace` - Configurable font face for text testing
//! - `MockFileDialog` - Simulates file open/save dialogs
//!
//! ## Example
//!
//! ```zig
//! const gooey = @import("gooey");
//! const testing = gooey.testing;
//!
//! test "my feature" {
//!     var renderer = try testing.MockRenderer.init(testing.allocator);
//!     defer renderer.deinit();
//!
//!     try renderer.beginFrame(800, 600, 2.0);
//!     renderer.render();
//!     renderer.endFrame();
//!
//!     try std.testing.expectEqual(@as(u32, 1), renderer.begin_frame_count);
//! }
//! ```

const std = @import("std");

// =============================================================================
// Mock Implementations
// =============================================================================

pub const MockRenderer = @import("mock_renderer.zig").MockRenderer;
pub const MockClipboard = @import("mock_clipboard.zig").MockClipboard;
pub const MockFontFace = @import("mock_font_face.zig").MockFontFace;
pub const MockFileDialog = @import("mock_file_dialog.zig").MockFileDialog;

/// Mock SVG rasterizer module
pub const mock_svg_rasterizer = @import("mock_svg_rasterizer.zig");
pub const MockSvgRasterizer = mock_svg_rasterizer.MockSvgRasterizer;

// =============================================================================
// Re-exports
// =============================================================================

/// Re-export std testing allocator for convenience
pub const allocator = std.testing.allocator;

// =============================================================================
// Test Helpers
// =============================================================================

const core = @import("../core/mod.zig");

/// Assert two colors are equal (with tolerance for floating point)
pub fn expectColorEqual(expected: core.Color, actual: core.Color) !void {
    const tolerance: f32 = 0.001;
    try std.testing.expectApproxEqAbs(expected.r, actual.r, tolerance);
    try std.testing.expectApproxEqAbs(expected.g, actual.g, tolerance);
    try std.testing.expectApproxEqAbs(expected.b, actual.b, tolerance);
    try std.testing.expectApproxEqAbs(expected.a, actual.a, tolerance);
}

/// Assert two bounds are equal (with tolerance)
pub fn expectBoundsEqual(expected: core.BoundsF, actual: core.BoundsF) !void {
    const tolerance: f32 = 0.001;
    try std.testing.expectApproxEqAbs(expected.origin.x, actual.origin.x, tolerance);
    try std.testing.expectApproxEqAbs(expected.origin.y, actual.origin.y, tolerance);
    try std.testing.expectApproxEqAbs(expected.size.width, actual.size.width, tolerance);
    try std.testing.expectApproxEqAbs(expected.size.height, actual.size.height, tolerance);
}

/// Assert two points are equal (with tolerance)
pub fn expectPointEqual(expected: core.PointF, actual: core.PointF) !void {
    const tolerance: f32 = 0.001;
    try std.testing.expectApproxEqAbs(expected.x, actual.x, tolerance);
    try std.testing.expectApproxEqAbs(expected.y, actual.y, tolerance);
}

/// Assert two sizes are equal (with tolerance)
pub fn expectSizeEqual(expected: core.SizeF, actual: core.SizeF) !void {
    const tolerance: f32 = 0.001;
    try std.testing.expectApproxEqAbs(expected.width, actual.width, tolerance);
    try std.testing.expectApproxEqAbs(expected.height, actual.height, tolerance);
}

// =============================================================================
// Tests
// =============================================================================

test {
    std.testing.refAllDecls(@This());
}

test "expectColorEqual passes for equal colors" {
    const c1 = core.Color.rgb(1.0, 0.5, 0.0);
    const c2 = core.Color.rgb(1.0, 0.5, 0.0);
    try expectColorEqual(c1, c2);
}

test "expectPointEqual passes for equal points" {
    const p1 = core.PointF{ .x = 10.0, .y = 20.0 };
    const p2 = core.PointF{ .x = 10.0, .y = 20.0 };
    try expectPointEqual(p1, p2);
}

test "expectBoundsEqual passes for equal bounds" {
    const b1 = core.BoundsF.init(10.0, 20.0, 100.0, 200.0);
    const b2 = core.BoundsF.init(10.0, 20.0, 100.0, 200.0);
    try expectBoundsEqual(b1, b2);
}

test "expectSizeEqual passes for equal sizes" {
    const s1 = core.SizeF{ .width = 100.0, .height = 200.0 };
    const s2 = core.SizeF{ .width = 100.0, .height = 200.0 };
    try expectSizeEqual(s1, s2);
}
