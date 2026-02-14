//! SVG Atlas - Texture cache for rasterized SVG icons
//!
//! Caches rasterized SVGs in a texture atlas, keyed by path hash and size.
//! Thread-safe for multi-window scenarios where multiple DisplayLink threads
//! may access the atlas concurrently.
//!
//! **Per-frame rasterization budget**: Software SVG rasterization is expensive
//! (~0.5–2ms per icon). When many uncached icons appear at once (e.g. scrolling
//! a grid of 1600+ icons), rasterizing them all in one frame blows the 16.67ms
//! budget. Instead, we cap rasterizations per frame and progressively load the
//! rest over subsequent frames. The caller should check `hasDeferredWork()` after
//! rendering and request a redraw if true.

const std = @import("std");
const Atlas = @import("../text/atlas.zig").Atlas;
const Region = @import("../text/atlas.zig").Region;
const UVCoords = @import("../text/atlas.zig").UVCoords;
const rasterizer = @import("rasterizer.zig");

/// Cache key for SVG lookup
pub const SvgKey = struct {
    /// Hash of SVG path data
    path_hash: u64,
    /// Device pixel size (width = height for square icons)
    device_size: u16,
    /// Whether fill is enabled
    has_fill: bool,
    /// Whether stroke is enabled
    has_stroke: bool,
    /// Stroke width (quantized to 0.25 increments)
    stroke_width_q: u8,

    pub fn init(path_data: []const u8, logical_size: f32, scale_factor: f64, has_fill: bool, stroke_width: ?f32) SvgKey {
        const has_stroke = stroke_width != null and stroke_width.? > 0;
        return .{
            .path_hash = std.hash.Wyhash.hash(0, path_data),
            .device_size = @intFromFloat(@ceil(logical_size * scale_factor)),
            .has_fill = has_fill,
            .has_stroke = has_stroke,
            // Quantize stroke width to reduce cache variations
            .stroke_width_q = if (has_stroke) @intFromFloat(@min(255, (stroke_width.? * 4))) else 0,
        };
    }
};

/// Cached SVG entry
pub const CachedSvg = struct {
    /// Region in atlas texture
    region: Region,
    /// Offset from logical position (device pixels)
    offset_x: i16,
    offset_y: i16,
    /// Atlas size when this SVG was cached (for thread-safe UV calculation)
    /// In multi-window scenarios, the atlas may grow between caching and
    /// UV calculation; storing the size ensures correct UVs.
    atlas_size: u32,

    /// Calculate UV coordinates using the cached atlas size
    pub fn uv(self: CachedSvg) UVCoords {
        return self.region.uv(self.atlas_size);
    }
};

/// SVG texture atlas with caching
pub const SvgAtlas = struct {
    allocator: std.mem.Allocator,
    /// RGBA texture atlas
    atlas: Atlas,
    /// Cache map
    cache: std.AutoHashMap(SvgKey, CachedSvg),
    /// Reusable rasterization buffer
    render_buffer: []u8,
    render_buffer_size: u32,
    /// Current scale factor
    scale_factor: f64,
    /// Mutex for thread-safe access in multi-window scenarios.
    /// Multiple DisplayLink threads may access the atlas concurrently.
    mutex: std.Thread.Mutex,

    // =========================================================================
    // Per-frame rasterization budget
    // =========================================================================

    /// Number of software rasterizations performed this frame.
    rasterizations_this_frame: u32 = 0,

    /// Set when a cache miss was skipped due to budget exhaustion.
    /// Caller should check this via `hasDeferredWork()` and request a redraw.
    deferred_this_frame: bool = false,

    const Self = @This();
    const MAX_ICON_SIZE: u32 = 256;

    /// Maximum software rasterizations allowed per frame.
    ///
    /// Each rasterization costs ~0.5–2ms (parse SVG path, flatten curves,
    /// per-pixel stroke rendering at 48×48 device pixels). At 4 per frame
    /// that's ~2–8ms, leaving headroom for layout, GPU upload, and draw.
    ///
    /// A row of 16 icons progressively loads over 4 frames (~67ms) instead
    /// of stalling a single frame for 8–32ms of pure rasterization.
    const MAX_RASTERIZATIONS_PER_FRAME: u32 = 4;

    pub fn init(allocator: std.mem.Allocator, scale_factor: f64) !Self {
        // Buffer for largest possible icon (256x256 RGBA)
        const buffer_size = MAX_ICON_SIZE * MAX_ICON_SIZE * 4;
        const render_buffer = try allocator.alloc(u8, buffer_size);

        return .{
            .allocator = allocator,
            .atlas = try Atlas.initWithSize(allocator, .rgba, 512),
            .cache = std.AutoHashMap(SvgKey, CachedSvg).init(allocator),
            .render_buffer = render_buffer,
            .render_buffer_size = MAX_ICON_SIZE,
            .scale_factor = scale_factor,
            .mutex = .{},
            .rasterizations_this_frame = 0,
            .deferred_this_frame = false,
        };
    }

    pub fn deinit(self: *Self) void {
        self.cache.deinit();
        self.atlas.deinit();
        self.allocator.free(self.render_buffer);
    }

    pub fn setScaleFactor(self: *Self, scale: f32) void {
        if (self.scale_factor != scale) {
            self.scale_factor = scale;
            self.clear();
        }
    }

    // =========================================================================
    // Frame budget API
    // =========================================================================

    /// Reset the per-frame rasterization counter. Call at the start of each
    /// frame before any `getOrRasterize` calls.
    pub fn resetFrameBudget(self: *Self) void {
        self.rasterizations_this_frame = 0;
        self.deferred_this_frame = false;
    }

    /// Returns true if any SVGs were skipped this frame due to budget limits.
    /// When true, the caller should request another render so the remaining
    /// icons can be progressively rasterized.
    pub fn hasDeferredWork(self: *const Self) bool {
        return self.deferred_this_frame;
    }

    // =========================================================================
    // Core API
    // =========================================================================

    /// Get cached SVG or rasterize and cache it.
    ///
    /// Thread-safe: protected by mutex for multi-window scenarios.
    ///
    /// If the per-frame rasterization budget is exhausted, returns
    /// `error.RasterizationDeferred` — the icon won't render this frame
    /// but will be picked up on the next frame.
    pub fn getOrRasterize(
        self: *Self,
        path_data: []const u8,
        viewbox: f32,
        logical_size: f32,
        has_fill: bool,
        stroke_width: ?f32,
    ) !CachedSvg {
        self.mutex.lock();
        defer self.mutex.unlock();

        const key = SvgKey.init(path_data, logical_size, self.scale_factor, has_fill, stroke_width);

        if (self.cache.get(key)) |cached| {
            return cached;
        }

        // Cache miss — check per-frame budget before doing expensive work.
        // This prevents a single frame from stalling on dozens of software
        // rasterizations when many uncached icons scroll into view at once.
        if (self.rasterizations_this_frame >= MAX_RASTERIZATIONS_PER_FRAME) {
            self.deferred_this_frame = true;
            return error.RasterizationDeferred;
        }

        // Rasterize
        const device_size = key.device_size;
        if (device_size > self.render_buffer_size) {
            return error.IconTooLarge;
        }

        @memset(self.render_buffer, 0);

        // Scale stroke width to device pixels
        const device_stroke_width: f32 = if (stroke_width) |sw|
            sw * @as(f32, @floatCast(self.scale_factor))
        else
            0;

        const rasterized = try rasterizer.rasterizeWithOptions(
            self.allocator,
            path_data,
            viewbox,
            device_size,
            self.render_buffer,
            has_fill,
            .{
                .enabled = stroke_width != null and stroke_width.? > 0,
                .width = device_stroke_width,
            },
        );

        self.rasterizations_this_frame += 1;

        // Reserve atlas space
        const region = try self.reserveWithEviction(rasterized.width, rasterized.height);

        // Copy to atlas
        const pixel_count = rasterized.width * rasterized.height * 4;
        self.atlas.set(region, self.render_buffer[0..pixel_count]);

        // Capture atlas size AFTER reservation (may have grown)
        const current_atlas_size = self.atlas.size;

        const cached = CachedSvg{
            .region = region,
            .offset_x = rasterized.offset_x,
            .offset_y = rasterized.offset_y,
            .atlas_size = current_atlas_size,
        };

        try self.cache.put(key, cached);
        return cached;
    }

    fn reserveWithEviction(self: *Self, width: u32, height: u32) !Region {
        if (try self.atlas.reserve(width, height)) |region| {
            return region;
        }

        // Try growing
        self.atlas.grow() catch |err| {
            if (err == error.AtlasFull) {
                self.clear();
                if (try self.atlas.reserve(width, height)) |region| {
                    return region;
                }
                return error.IconTooLarge;
            }
            return err;
        };

        // Growth succeeded - update atlas_size in all cached entries
        // This is critical: cached SVGs store atlas_size for UV calculation.
        // When atlas grows, pixel positions stay the same but UVs change.
        self.updateAtlasSizeInCache();

        return try self.atlas.reserve(width, height) orelse error.IconTooLarge;
    }

    /// Update atlas_size in all cached entries after atlas growth.
    /// When the atlas grows, pixel positions are preserved but UV coordinates
    /// change (e.g., x=100 in 512px atlas is UV=0.195, but in 1024px is UV=0.098).
    fn updateAtlasSizeInCache(self: *Self) void {
        const new_size = self.atlas.size;

        var it = self.cache.valueIterator();
        while (it.next()) |cached| {
            cached.atlas_size = new_size;
        }
    }

    pub fn clear(self: *Self) void {
        self.cache.clearRetainingCapacity();
        self.atlas.clear();
    }

    /// Get the underlying atlas for GPU upload.
    /// WARNING: Not thread-safe! Use withAtlasLocked for multi-window scenarios.
    pub fn getAtlas(self: *const Self) *const Atlas {
        return &self.atlas;
    }

    pub fn getGeneration(self: *const Self) u32 {
        return self.atlas.generation;
    }

    /// Thread-safe atlas access for GPU upload.
    /// Holds the mutex while calling the callback, ensuring no other
    /// thread can modify the atlas during the upload.
    pub fn withAtlasLocked(
        self: *Self,
        comptime Ctx: type,
        ctx: Ctx,
        comptime callback: fn (Ctx, *const Atlas) anyerror!void,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        return callback(ctx, &self.atlas);
    }
};
