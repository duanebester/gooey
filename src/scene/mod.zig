//! Scene - GPU Primitives
//!
//! Low-level rendering primitives for GPU submission.
//!
//! - `Scene` - Collects and sorts primitives for a frame
//! - `Quad` - Filled/bordered rectangle
//! - `Shadow` - Drop shadow primitive
//! - `GlyphInstance` - Text glyph for GPU rendering
//! - `SvgInstance` - SVG icon instance
//! - `ImageInstance` - Raster image instance
//! - `BatchIterator` - Yields draw-order batches for efficient rendering

const std = @import("std");

// =============================================================================
// Scene
// =============================================================================

pub const scene = @import("scene.zig");

pub const Scene = scene.Scene;
pub const DrawOrder = scene.DrawOrder;

// Hard limits (static memory allocation policy)
pub const MAX_QUADS_PER_FRAME = scene.MAX_QUADS_PER_FRAME;
pub const MAX_GLYPHS_PER_FRAME = scene.MAX_GLYPHS_PER_FRAME;
pub const MAX_SHADOWS_PER_FRAME = scene.MAX_SHADOWS_PER_FRAME;
pub const MAX_SVGS_PER_FRAME = scene.MAX_SVGS_PER_FRAME;
pub const MAX_IMAGES_PER_FRAME = scene.MAX_IMAGES_PER_FRAME;
pub const MAX_CLIP_STACK_DEPTH = scene.MAX_CLIP_STACK_DEPTH;

// Geometry aliases (GPU-aligned)
pub const Point = scene.Point;
pub const Size = scene.Size;
pub const Bounds = scene.Bounds;
pub const Corners = scene.Corners;
pub const Edges = scene.Edges;

// Color
pub const Hsla = scene.Hsla;

// Content mask / clipping
pub const ContentMask = scene.ContentMask;

// =============================================================================
// Primitives
// =============================================================================

pub const Quad = scene.Quad;
pub const Shadow = scene.Shadow;
pub const GlyphInstance = scene.GlyphInstance;

// =============================================================================
// SVG Instance
// =============================================================================

pub const svg_instance = @import("svg_instance.zig");
pub const SvgInstance = svg_instance.SvgInstance;

// =============================================================================
// Image Instance
// =============================================================================

pub const image_instance = @import("image_instance.zig");
pub const ImageInstance = image_instance.ImageInstance;

// =============================================================================
// Batch Iterator
// =============================================================================

pub const batch_iterator = @import("batch_iterator.zig");

pub const BatchIterator = batch_iterator.BatchIterator;
pub const PrimitiveBatch = batch_iterator.PrimitiveBatch;
pub const PrimitiveKind = batch_iterator.PrimitiveKind;

// =============================================================================
// Tests
// =============================================================================

test {
    std.testing.refAllDecls(@This());
}
