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
//! - `atlas.zig` - Fixed-size texture atlas with LRU shelf eviction
//! - `atlas_uploads.zig` - Upload journal and frame clock shared by the atlases
//! - `cache.zig` - Glyph cache using FontFace interface
//! - `text_system.zig` - High-level unified API
//! - `backends/` - Platform-specific implementations
//!
//! ## Usage
//!
//! ```zig
//! const text = try allocator.create(TextSystem);
//! try text.initInPlace(allocator, 1.0, io, &FontLimits.standard, .{
//!     .size = AtlasLimits.standard.text_size,
//!     .uploads = uploads, // shared `AtlasUploads`
//! });
//! defer text.deinit();
//!
//! try text.loadSystemFont(.monospace, 14.0);
//! const width = try text.measureText(.app, "Hello, World!", .bold);
//! ```
//!
//! The `io` parameter is stored on the struct so lock sites on render
//! threads (which do not carry a `*Cx`) can still acquire the internal
//! mutexes via `std.Io.Mutex`.

const std = @import("std");

// Core types (platform-agnostic)
pub const types = @import("types.zig");
pub const Metrics = types.Metrics;
pub const GlyphMetrics = types.GlyphMetrics;
pub const ShapedGlyph = types.ShapedGlyph;
pub const ShapedRun = types.ShapedRun;
pub const TextMeasurement = types.TextMeasurement;
pub const MeasureTextOptions = types.MeasureTextOptions;
pub const SystemFont = types.SystemFont;
pub const FontWeight = types.FontWeight;
pub const FontVariant = types.FontVariant;
pub const FontFamily = types.FontFamily;
pub const FontLimits = @import("../core/limits.zig").FontLimits;
pub const TextDecoration = types.TextDecoration;
pub const RasterizedGlyph = types.RasterizedGlyph;

// Interfaces
pub const font_face = @import("font_face.zig");
pub const font_match = @import("font_match.zig");
pub const FontFace = font_face.FontFace;

// Infrastructure
pub const Atlas = @import("atlas.zig").Atlas;
pub const Region = @import("atlas.zig").Region;
pub const AtlasUploads = @import("atlas_uploads.zig").AtlasUploads;
pub const AtlasKind = @import("atlas_uploads.zig").AtlasKind;
pub const AtlasStorage = @import("atlas_uploads.zig").AtlasStorage;
pub const AtlasUpload = @import("atlas_uploads.zig").Upload;
pub const AtlasOptions = @import("cache.zig").AtlasOptions;
pub const cache = @import("cache.zig");

// Text rendering utility
pub const render = @import("render.zig");
pub const renderText = render.renderText;
pub const RenderTextOptions = render.RenderTextOptions;

pub const GlyphCache = cache.GlyphCache;
pub const CachedGlyph = cache.CachedGlyph;

// High-level API
const text_system = @import("text_system.zig");
pub const TextSystem = text_system.TextSystem;
/// True in builds that select the deterministic synthetic text backend.
pub const is_synthetic = text_system.is_synthetic;
pub const ShapedRunCache = text_system.ShapedRunCache;
pub const SUBPIXEL_VARIANTS_X = text_system.SUBPIXEL_VARIANTS_X;

// Platform backends
const platform = @import("../platform/mod.zig");
const is_wasm = platform.is_wasm;

const is_linux = platform.is_linux;
const is_windows = platform.is_windows;

/// Deterministic headless backend. Always compiled so its tests run on every
/// host; `text_backend = .synthetic` makes `TextSystem` use it.
pub const synthetic_backend = @import("backends/synthetic/mod.zig");

pub const backends = if (is_wasm)
    struct {
        pub const web = @import("backends/web/mod.zig");
    }
else if (is_linux)
    struct {
        pub const freetype = @import("backends/freetype/mod.zig");
    }
else if (is_windows)
    struct {
        pub const directwrite = @import("backends/directwrite/mod.zig");
    }
else
    struct {
        pub const coretext = @import("backends/coretext/mod.zig");
    };

test {
    std.testing.refAllDecls(@This());
}
