//! Testing utilities for Gooey
//!
//! Provides mock implementations and test helpers.
//! Only compiled when running tests.
//!
//! ## Available Mocks
//!
//! - `MockSvgRasterizer` - Simulates SVG rasterization
//! - `MockFontFace` - Configurable font face for text testing
//!
//! The core draws tests through `NullRenderer`.

const std = @import("std");

// =============================================================================
// Mock Implementations
// =============================================================================

pub const MockFontFace = @import("mock_font_face.zig").MockFontFace;

/// Mock SVG rasterizer module
pub const mock_svg_rasterizer = @import("mock_svg_rasterizer.zig");
pub const MockSvgRasterizer = mock_svg_rasterizer.MockSvgRasterizer;

/// Text dumps of packed frames, hit records, and accessibility trees.
pub const record_dump = @import("record_dump.zig");

/// The headless renderer the core draws with in tests.
pub const test_backend = @import("test_backend.zig");
pub const NullRenderer = test_backend.NullRenderer;

// =============================================================================
// Re-exports
// =============================================================================

/// Re-export std testing allocator for convenience
pub const allocator = std.testing.allocator;

// =============================================================================
// Test Helpers
// =============================================================================

const geometry = @import("../geometry/mod.zig");

/// Assert two colors are equal (with tolerance for floating point)
pub fn expectColorEqual(expected: geometry.Color, actual: geometry.Color) !void {
    const tolerance: f32 = 0.001;
    try std.testing.expectApproxEqAbs(expected.r, actual.r, tolerance);
    try std.testing.expectApproxEqAbs(expected.g, actual.g, tolerance);
    try std.testing.expectApproxEqAbs(expected.b, actual.b, tolerance);
    try std.testing.expectApproxEqAbs(expected.a, actual.a, tolerance);
}

/// Assert two bounds are equal (with tolerance)
pub fn expectBoundsEqual(expected: geometry.BoundsF, actual: geometry.BoundsF) !void {
    const tolerance: f32 = 0.001;
    try std.testing.expectApproxEqAbs(expected.origin.x, actual.origin.x, tolerance);
    try std.testing.expectApproxEqAbs(expected.origin.y, actual.origin.y, tolerance);
    try std.testing.expectApproxEqAbs(expected.size.width, actual.size.width, tolerance);
    try std.testing.expectApproxEqAbs(expected.size.height, actual.size.height, tolerance);
}

/// Assert two points are equal (with tolerance)
pub fn expectPointEqual(expected: geometry.PointF, actual: geometry.PointF) !void {
    const tolerance: f32 = 0.001;
    try std.testing.expectApproxEqAbs(expected.x, actual.x, tolerance);
    try std.testing.expectApproxEqAbs(expected.y, actual.y, tolerance);
}

/// Assert two sizes are equal (with tolerance)
pub fn expectSizeEqual(expected: geometry.SizeF, actual: geometry.SizeF) !void {
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
    const c1 = geometry.Color.rgb(1.0, 0.5, 0.0);
    const c2 = geometry.Color.rgb(1.0, 0.5, 0.0);
    try expectColorEqual(c1, c2);
}

test "expectPointEqual passes for equal points" {
    const p1 = geometry.PointF{ .x = 10.0, .y = 20.0 };
    const p2 = geometry.PointF{ .x = 10.0, .y = 20.0 };
    try expectPointEqual(p1, p2);
}

test "expectBoundsEqual passes for equal bounds" {
    const b1 = geometry.BoundsF.init(10.0, 20.0, 100.0, 200.0);
    const b2 = geometry.BoundsF.init(10.0, 20.0, 100.0, 200.0);
    try expectBoundsEqual(b1, b2);
}

test "expectSizeEqual passes for equal sizes" {
    const s1 = geometry.SizeF{ .width = 100.0, .height = 200.0 };
    const s2 = geometry.SizeF{ .width = 100.0, .height = 200.0 };
    try expectSizeEqual(s1, s2);
}
