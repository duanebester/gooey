const std = @import("std");

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
pub const TextLimits = @import("../core/limits.zig").TextLimits;
pub const TextDecoration = types.TextDecoration;
pub const RasterizedGlyph = types.RasterizedGlyph;

pub const font_face = @import("font_face.zig");
pub const font_match = @import("font_match.zig");
pub const FontFace = font_face.FontFace;

pub const Atlas = @import("atlas.zig").Atlas;
pub const Region = @import("atlas.zig").Region;
pub const AtlasUploads = @import("atlas_uploads.zig").AtlasUploads;
pub const AtlasKind = @import("atlas_uploads.zig").AtlasKind;
pub const AtlasStorage = @import("atlas_uploads.zig").AtlasStorage;
pub const AtlasUpload = @import("atlas_uploads.zig").Upload;
pub const AtlasOptions = @import("cache.zig").AtlasOptions;
pub const cache = @import("cache.zig");

pub const render = @import("render.zig");

pub const GlyphCache = cache.GlyphCache;
pub const CachedGlyph = cache.CachedGlyph;

const text_system = @import("text_system.zig");
pub const TextSystem = text_system.TextSystem;
pub const TextSizeKey = text_system.TextSizeKey;
/// True in builds that select the deterministic synthetic text backend.
pub const is_synthetic = text_system.is_synthetic;
pub const ShapedRunCache = text_system.ShapedRunCache;
pub const run_codepoint_count_max = text_system.run_codepoint_count_max;
pub const codepointCount = text_system.codepointCount;
pub const SUBPIXEL_VARIANTS_X = text_system.SUBPIXEL_VARIANTS_X;

const platform = @import("../platform/mod.zig");
const is_wasm = platform.is_wasm;

const is_linux = platform.is_linux;
const is_windows = platform.is_windows;

/// Always compiled so its tests run on every host; `text_backend =
/// .synthetic` makes `TextSystem` use it.
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
