//! Core primitives for Gooey
//!
//! This module contains foundational types with NO internal dependencies.
//! Higher-level modules (scene, input, context) build on these.
//!
//! For backward compatibility, many types are re-exported from root.zig.

const std = @import("std");

// =============================================================================
// Geometry (platform-agnostic primitives)
// =============================================================================

pub const geometry = @import("geometry.zig");

// Generic types
pub const Point = geometry.Point;
pub const Size = geometry.Size;
pub const Rect = geometry.Rect;
pub const Bounds = geometry.Bounds;
pub const Edges = geometry.Edges;
pub const Corners = geometry.Corners;
pub const Color = geometry.Color;

// Concrete type aliases
pub const PointF = geometry.PointF;
pub const PointI = geometry.PointI;
pub const SizeF = geometry.SizeF;
pub const SizeI = geometry.SizeI;
pub const RectF = geometry.RectF;
pub const RectI = geometry.RectI;
pub const BoundsF = geometry.BoundsF;
pub const BoundsI = geometry.BoundsI;
pub const EdgesF = geometry.EdgesF;
pub const CornersF = geometry.CornersF;

// GPU-aligned types
pub const GpuPoint = geometry.GpuPoint;
pub const GpuSize = geometry.GpuSize;
pub const GpuBounds = geometry.GpuBounds;
pub const GpuCorners = geometry.GpuCorners;
pub const GpuEdges = geometry.GpuEdges;

// Unit aliases
pub const Pixels = geometry.Pixels;

// =============================================================================
// Element Types
// =============================================================================

pub const element_types = @import("element_types.zig");
pub const ElementId = element_types.ElementId;

// =============================================================================
// Limits (static allocation bounds)
// =============================================================================

pub const limits = @import("limits.zig");

// =============================================================================
// Triangulator
// =============================================================================

pub const triangulator = @import("triangulator.zig");
pub const Triangulator = triangulator.Triangulator;
pub const Vec2 = triangulator.Vec2;
pub const IndexSlice = triangulator.IndexSlice;

// =============================================================================
// Stroke API
// =============================================================================

pub const stroke = @import("stroke.zig");
pub const LineCap = stroke.LineCap;
pub const LineJoin = stroke.LineJoin;
pub const StrokeStyle = stroke.StrokeStyle;
pub const StrokeError = stroke.StrokeError;

// =============================================================================
// Custom Shaders
// =============================================================================

pub const shader = @import("shader.zig");
pub const CustomShader = shader.CustomShader;

// =============================================================================
// Interface Verification (compile-time checks)
// =============================================================================

pub const interface_verify = @import("interface_verify.zig");
pub const verifyRendererInterface = interface_verify.verifyRendererInterface;
pub const verifyClipboardInterface = interface_verify.verifyClipboardInterface;
pub const verifySvgRasterizerModule = interface_verify.verifySvgRasterizerModule;
pub const verifyPlatformInterface = interface_verify.verifyPlatformInterface;
pub const verifyWindowInterface = interface_verify.verifyWindowInterface;

// =============================================================================
// Tests
// =============================================================================

test {
    std.testing.refAllDecls(@This());
}
