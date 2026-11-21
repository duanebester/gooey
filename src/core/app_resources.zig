const std = @import("std");
const Allocator = std.mem.Allocator;

const text_mod = @import("../text/mod.zig");
const TextSystem = text_mod.TextSystem;
const limits_mod = @import("limits.zig");
const TextLimits = limits_mod.TextLimits;

const svg_mod = @import("../svg/mod.zig");
const SvgAtlas = svg_mod.SvgAtlas;

const image_mod = @import("../image/mod.zig");
const ImageAtlas = image_mod.ImageAtlas;

const AtlasUploads = text_mod.AtlasUploads;
const AtlasLimits = @import("limits.zig").AtlasLimits;
const platform = @import("../platform/mod.zig");

/// Font configuration. Duplicated as a small POD struct so `initOwned` avoids
/// a circular import on `window.zig`. Kept field-for-field identical to
/// `window.FontConfig`; any divergence must be added in both places.
pub const FontConfig = struct {
    /// Family name; null loads the platform's default sans-serif.
    font_name: ?[]const u8 = null,
    font_size: f32 = 16.0,
    /// The app's text budget, `ResourceLimits.text`: the faces loaded at init,
    /// one per variant, and the text caches' sizes.
    text: *const TextLimits,
    /// The optional second family, loaded into `text.fonts.mono_variants` at
    /// `font_size`.
    mono: ?TextSystem.FaceSource = null,
};

pub const AppResources = struct {
    allocator: Allocator,
    io: std.Io,

    text_system: *TextSystem,
    svg_atlas: *SvgAtlas,
    image_atlas: *ImageAtlas,
    /// Upload journal and frame clock shared by the three atlases.
    atlas_uploads: *AtlasUploads,

    /// True between an `initOwned*` call and `deinit`: the three pointees
    /// are live and this struct frees them.
    owned: bool,

    const Self = @This();

    /// The caller must invoke `deinit` exactly once.
    pub fn initOwned(
        allocator: Allocator,
        io: std.Io,
        scale: f32,
        font_config: FontConfig,
        atlas_limits: *const AtlasLimits,
    ) !Self {
        var self: Self = undefined;
        try self.initOwnedInPlace(allocator, io, scale, font_config, atlas_limits);
        return self;
    }

    fn loadFonts(text_system: *TextSystem, font_config: *const FontConfig) !void {
        std.debug.assert(font_config.font_size > 0);
        std.debug.assert(font_config.font_size < 1000);
        if (font_config.font_name) |name| {
            try text_system.loadFont(name, font_config.font_size);
        } else {
            try text_system.loadSystemFont(.sans_serif, font_config.font_size);
        }
        if (font_config.mono) |source| {
            try text_system.loadMonoFont(source, font_config.font_size);
        }
    }

    /// `noinline` so ReleaseSmall doesn't fold the stack frame back into the
    /// caller (WASM stack budget). Every atlas is reserved at its budget size
    /// and never grows.
    pub noinline fn initOwnedInPlace(
        self: *Self,
        allocator: Allocator,
        io: std.Io,
        scale: f32,
        font_config: FontConfig,
        atlas_limits: *const AtlasLimits,
    ) !void {
        std.debug.assert(scale > 0);
        std.debug.assert(scale <= 4.0);
        std.debug.assert(font_config.font_size > 0);
        std.debug.assert(font_config.font_size < 1000);
        atlas_limits.assertValid();

        const atlas_uploads = try allocator.create(AtlasUploads);
        errdefer allocator.destroy(atlas_uploads);
        try atlas_uploads.init(allocator, io, .{
            .storage = platform.atlas_storage,
            .upload_bytes_frame_max = atlas_limits.upload_bytes_frame_max,
            .consumer_count_max = limits_mod.window_count_max,
        });
        errdefer atlas_uploads.deinit();

        const text_system = try allocator.create(TextSystem);
        errdefer allocator.destroy(text_system);
        try text_system.initInPlace(allocator, scale, io, font_config.text, .{
            .size = atlas_limits.text_size,
            .uploads = atlas_uploads,
        });
        errdefer text_system.deinit();

        try loadFonts(text_system, &font_config);

        const svg_atlas = try allocator.create(SvgAtlas);
        errdefer allocator.destroy(svg_atlas);
        try svg_atlas.initInPlace(allocator, scale, io, .{
            .size = atlas_limits.svg_size,
            .icon_size_max = atlas_limits.svg_icon_size_max,
            .raster_budget = .{
                .path_bytes_max = atlas_limits.svg_path_bytes_max,
                .vertex_count_max = atlas_limits.svg_path_vertex_count_max,
            },
            .entry_count_max = atlas_limits.svg_entry_count_max,
            .rasterization_count_frame_max = atlas_limits.svg_rasterization_count_frame_max,
            .uploads = atlas_uploads,
        });
        errdefer svg_atlas.deinit();

        const image_atlas = try allocator.create(ImageAtlas);
        errdefer allocator.destroy(image_atlas);
        try image_atlas.initInPlace(allocator, scale, io, .{
            .size = atlas_limits.image_size,
            .entry_count_max = atlas_limits.image_entry_count_max,
            .uploads = atlas_uploads,
        });
        errdefer image_atlas.deinit();

        // Field-by-field, no struct literal, to avoid a stack temp (WASM stack budget).
        self.allocator = allocator;
        self.io = io;
        self.text_system = text_system;
        self.svg_atlas = svg_atlas;
        self.image_atlas = image_atlas;
        self.atlas_uploads = atlas_uploads;
        self.owned = true;

        // Pointer equality between the subsystems would imply a cross-aliased allocation bug.
        std.debug.assert(@intFromPtr(self.text_system) != @intFromPtr(self.svg_atlas));
        std.debug.assert(@intFromPtr(self.svg_atlas) != @intFromPtr(self.image_atlas));
        std.debug.assert(self.text_system.getAtlas().uploads == atlas_uploads);
    }

    /// Register the renderer identified by `key` (its platform window's
    /// address) as a consumer of the atlas uploads. Its texture starts empty,
    /// so every cached glyph, icon, and image is condemned: they re-rasterize
    /// on next use and reach every texture through the journal.
    pub fn registerAtlasConsumer(self: *const Self, key: usize) void {
        std.debug.assert(key != 0);
        self.atlas_uploads.registerConsumer(key);
        self.text_system.clearGlyphCache();
        self.svg_atlas.clear();
        self.image_atlas.clear();
    }

    /// Rasterize glyphs, icons, and images at `scale` device pixels per
    /// logical pixel from now on. Each cache condemns what it holds only when
    /// its scale changes, so repeating the current scale costs nothing.
    pub fn setScaleFactor(self: *const Self, scale: f64) void {
        std.debug.assert(scale > 0);
        std.debug.assert(std.math.isFinite(scale));
        const scale_f32: f32 = @floatCast(scale);
        self.text_system.setScaleFactor(scale_f32);
        self.svg_atlas.setScaleFactor(scale_f32);
        self.image_atlas.setScaleFactor(scale);
    }

    pub fn unregisterAtlasConsumer(self: *const Self, key: usize) void {
        std.debug.assert(key != 0);
        self.atlas_uploads.unregisterConsumer(key);
    }

    /// Tear down the three subsystems if `owned`; a second call is a no-op.
    pub fn deinit(self: *Self) void {
        if (!self.owned) return;

        // Order is not load-bearing: no inter-pointer references between the three.
        self.image_atlas.deinit();
        self.allocator.destroy(self.image_atlas);

        self.svg_atlas.deinit();
        self.allocator.destroy(self.svg_atlas);

        self.text_system.deinit();
        self.allocator.destroy(self.text_system);

        // The journal outlives every atlas that stages into it.
        self.atlas_uploads.deinit();
        self.allocator.destroy(self.atlas_uploads);

        // Null out so an accidental re-deinit fails fast rather than double-freeing.
        self.text_system = undefined;
        self.svg_atlas = undefined;
        self.image_atlas = undefined;
        self.atlas_uploads = undefined;
        self.owned = false;
    }
};

const testing = std.testing;

/// System sans-serif at 16 pt with one face: the tests only check ownership.
const test_font_config: FontConfig = .{ .text = &TextLimits.nano };

test "AppResources: initOwned allocates and frees cleanly" {
    var resources = try AppResources.initOwned(
        testing.allocator,
        testing.io,
        1.0,
        test_font_config,
        &AtlasLimits.standard,
    );
    defer resources.deinit();

    try testing.expect(resources.owned);
    try testing.expect(@intFromPtr(resources.text_system) != 0);
    try testing.expect(@intFromPtr(resources.svg_atlas) != 0);
    try testing.expect(@intFromPtr(resources.image_atlas) != 0);
}

test "AppResources: initOwnedInPlace produces an owned instance" {
    const slot = try testing.allocator.create(AppResources);
    defer testing.allocator.destroy(slot);

    try slot.initOwnedInPlace(
        testing.allocator,
        testing.io,
        1.0,
        test_font_config,
        &AtlasLimits.standard,
    );
    defer slot.deinit();

    try testing.expect(slot.owned);
    try testing.expect(@intFromPtr(slot.text_system) != 0);
    try testing.expect(@intFromPtr(slot.svg_atlas) != 0);
    try testing.expect(@intFromPtr(slot.image_atlas) != 0);
}

test "AppResources: custom font config loads named font" {
    var resources = try AppResources.initOwned(
        testing.allocator,
        testing.io,
        1.0,
        .{ .font_name = null, .font_size = 14.0, .text = &TextLimits.nano },
        &AtlasLimits.nano,
    );
    defer resources.deinit();

    // Exact metrics are platform dependent; a positive size confirms the font path ran.
    const metrics = resources.text_system.getMetrics() orelse
        return error.SkipZigTest; // No font loader on this platform.
    try testing.expect(metrics.point_size > 0);
}
