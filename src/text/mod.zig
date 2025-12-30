//! Text rendering system for gooey
//!
//! Provides high-level text rendering with:
//! - Font loading and metrics
//! - Text shaping (ligatures, kerning)
//! - Glyph caching and atlas management
//! - GPU-ready glyph data
//!
//! ## Architecture
//!
//! The text system is designed with platform abstraction in mind:
//! - `types.zig` - Platform-agnostic data types
//! - `font_face.zig` - FontFace interface (trait)
//! - `shaper.zig` - Shaper interface + generic simple shaper
//! - `atlas.zig` - Platform-agnostic texture atlas
//! - `cache.zig` - Glyph cache using FontFace interface
//! - `text_system.zig` - High-level unified API
//! - `backends/` - Platform-specific implementations
//!
//! ## Usage
//!
//! ```zig
//! var text = try TextSystem.init(allocator);
//! defer text.deinit();
//!
//! try text.loadSystemFont(.monospace, 14.0);
//! const width = try text.measureText("Hello, World!");
//! ```

const std = @import("std");

// Core types (platform-agnostic)
pub const types = @import("types.zig");
pub const Metrics = types.Metrics;
pub const GlyphMetrics = types.GlyphMetrics;
pub const ShapedGlyph = types.ShapedGlyph;
pub const ShapedRun = types.ShapedRun;
pub const TextMeasurement = types.TextMeasurement;
pub const SystemFont = types.SystemFont;
pub const TextDecoration = types.TextDecoration;
pub const RasterizedGlyph = types.RasterizedGlyph;

// Interfaces
pub const font_face = @import("font_face.zig");
pub const FontFace = font_face.FontFace;

pub const shaper = @import("shaper.zig");
pub const Shaper = shaper.Shaper;
pub const shapeSimple = shaper.shapeSimple;
pub const measureSimple = shaper.measureSimple;

// Infrastructure
pub const Atlas = @import("atlas.zig").Atlas;
pub const Region = @import("atlas.zig").Region;
pub const cache = @import("cache.zig");

// Text rendering utility
pub const render = @import("render.zig");
pub const renderText = render.renderText;
pub const RenderTextOptions = render.RenderTextOptions;

pub const GlyphCache = cache.GlyphCache;
pub const CachedGlyph = cache.CachedGlyph;

// High-level API
pub const TextSystem = @import("text_system.zig").TextSystem;

// Debug utilities (for diagnosing native vs web differences)
pub const text_debug = @import("text_debug.zig");

// Platform backends
const platform = @import("../platform/mod.zig");
const is_wasm = platform.is_wasm;

const is_linux = platform.is_linux;

pub const backends = if (is_wasm)
    struct {
        pub const web = @import("backends/web/mod.zig");
    }
else if (is_linux)
    struct {
        pub const freetype = @import("backends/freetype/mod.zig");
    }
else
    struct {
        pub const coretext = @import("backends/coretext/mod.zig");
    };

test {
    std.testing.refAllDecls(@This());
}
