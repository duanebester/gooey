//! Image Atlas - Texture cache for loaded images
//!
//! Caches decoded images in a texture atlas, keyed by source hash and size.
//! Supports PNG, JPEG, and raw pixel data sources.
//! Thread-safe for multi-window scenarios where multiple DisplayLink threads
//! may access the atlas concurrently.

const std = @import("std");
const Atlas = @import("../text/atlas.zig").Atlas;
const Region = @import("../text/atlas.zig").Region;
const UVCoords = @import("../text/atlas.zig").UVCoords;

/// How the image should fit within its container
pub const ObjectFit = enum {
    /// Scale to fit, maintaining aspect ratio (may letterbox)
    contain,
    /// Scale to fill, maintaining aspect ratio (may crop)
    cover,
    /// Stretch to fill exactly (may distort)
    fill,
    /// No scaling, center the image
    none,
    /// Scale down only if larger than container
    scale_down,
};

/// Source of image data
pub const ImageSource = union(enum) {
    /// Embedded asset (compile-time path)
    embedded: []const u8,
    /// File system path
    path: []const u8,
    /// URL for network loading (future)
    url: []const u8,
    /// Pre-decoded pixel data
    data: ImageData,
};

/// Raw pixel data for direct upload
pub const ImageData = struct {
    width: u32,
    height: u32,
    pixels: []const u8,
    format: PixelFormat = .rgba,

    pub const PixelFormat = enum {
        rgba,
        bgra,
        rgb,
        grayscale,

        pub fn bytesPerPixel(self: PixelFormat) u8 {
            return switch (self) {
                .rgba, .bgra => 4,
                .rgb => 3,
                .grayscale => 1,
            };
        }
    };

    /// Convert to RGBA format (the atlas format)
    pub fn toRgba(self: ImageData, allocator: std.mem.Allocator) ![]u8 {
        const pixel_count = self.width * self.height;
        const output = try allocator.alloc(u8, pixel_count * 4);
        errdefer allocator.free(output);

        switch (self.format) {
            .rgba => {
                @memcpy(output, self.pixels[0 .. pixel_count * 4]);
            },
            .bgra => {
                var i: usize = 0;
                while (i < pixel_count) : (i += 1) {
                    const src_offset = i * 4;
                    const dst_offset = i * 4;
                    output[dst_offset + 0] = self.pixels[src_offset + 2]; // R <- B
                    output[dst_offset + 1] = self.pixels[src_offset + 1]; // G <- G
                    output[dst_offset + 2] = self.pixels[src_offset + 0]; // B <- R
                    output[dst_offset + 3] = self.pixels[src_offset + 3]; // A <- A
                }
            },
            .rgb => {
                var i: usize = 0;
                while (i < pixel_count) : (i += 1) {
                    const src_offset = i * 3;
                    const dst_offset = i * 4;
                    output[dst_offset + 0] = self.pixels[src_offset + 0];
                    output[dst_offset + 1] = self.pixels[src_offset + 1];
                    output[dst_offset + 2] = self.pixels[src_offset + 2];
                    output[dst_offset + 3] = 255; // Full opacity
                }
            },
            .grayscale => {
                var i: usize = 0;
                while (i < pixel_count) : (i += 1) {
                    const gray = self.pixels[i];
                    const dst_offset = i * 4;
                    output[dst_offset + 0] = gray;
                    output[dst_offset + 1] = gray;
                    output[dst_offset + 2] = gray;
                    output[dst_offset + 3] = 255;
                }
            },
        }

        return output;
    }
};

/// Cache key for image lookup
pub const ImageKey = struct {
    /// Hash of image source (path, URL, or data pointer)
    source_hash: u64,
    /// Target width in device pixels (0 = intrinsic)
    target_width: u16,
    /// Target height in device pixels (0 = intrinsic)
    target_height: u16,

    pub fn init(source: ImageSource, logical_width: ?f32, logical_height: ?f32, scale_factor: f64) ImageKey {
        const source_hash = switch (source) {
            .embedded => |path| std.hash.Wyhash.hash(0, path),
            .path => |path| std.hash.Wyhash.hash(1, path),
            .url => |url| std.hash.Wyhash.hash(2, url),
            .data => |data| std.hash.Wyhash.hash(3, std.mem.asBytes(&@intFromPtr(data.pixels.ptr))),
        };

        const w: u16 = if (logical_width) |lw| @intFromFloat(@ceil(lw * scale_factor)) else 0;
        const h: u16 = if (logical_height) |lh| @intFromFloat(@ceil(lh * scale_factor)) else 0;

        return .{
            .source_hash = source_hash,
            .target_width = w,
            .target_height = h,
        };
    }

    pub fn initFromPath(path: []const u8, logical_width: ?f32, logical_height: ?f32, scale_factor: f64) ImageKey {
        return init(.{ .path = path }, logical_width, logical_height, scale_factor);
    }
};

/// Cached image entry
pub const CachedImage = struct {
    /// Region in atlas texture
    region: Region,
    /// Original image dimensions (device pixels)
    source_width: u16,
    source_height: u16,
    /// Rendered dimensions in atlas (device pixels)
    rendered_width: u16,
    rendered_height: u16,
    /// Last accessed frame number (for LRU eviction)
    last_accessed: u64 = 0,
    /// Atlas size when this image was cached (for thread-safe UV calculation)
    /// In multi-window scenarios, the atlas may grow between caching and
    /// UV calculation; storing the size ensures correct UVs.
    atlas_size: u32 = 0,

    /// Calculate UV coordinates using the cached atlas size
    pub fn uv(self: CachedImage) UVCoords {
        return self.region.uv(self.atlas_size);
    }
};

/// Image texture atlas with caching
pub const ImageAtlas = struct {
    allocator: std.mem.Allocator,
    /// RGBA texture atlas
    atlas: Atlas,
    /// Cache map
    cache: std.AutoHashMap(ImageKey, CachedImage),
    /// Current scale factor
    scale_factor: f64,
    /// Current frame number (for LRU tracking)
    current_frame: u64 = 0,
    /// Mutex for thread-safe access in multi-window scenarios.
    /// Multiple DisplayLink threads may access the atlas concurrently.
    mutex: std.Thread.Mutex = .{},

    const Self = @This();

    /// Maximum dimension for atlased images (larger images get standalone textures)
    pub const MAX_ATLAS_DIMENSION: u32 = 2048;

    /// Initial atlas size
    const INITIAL_ATLAS_SIZE: u32 = 1024;

    pub fn init(allocator: std.mem.Allocator, scale_factor: f64) !Self {
        return .{
            .allocator = allocator,
            .atlas = try Atlas.initWithSize(allocator, .rgba, INITIAL_ATLAS_SIZE),
            .cache = std.AutoHashMap(ImageKey, CachedImage).init(allocator),
            .scale_factor = scale_factor,
        };
    }

    pub fn deinit(self: *Self) void {
        self.cache.deinit();
        self.atlas.deinit();
    }

    pub fn setScaleFactor(self: *Self, scale: f64) void {
        if (self.scale_factor != scale) {
            self.scale_factor = scale;
            self.clear();
        }
    }

    /// Increment frame counter (call once per frame)
    pub fn beginFrame(self: *Self) void {
        self.current_frame += 1;
    }

    /// Check if an image is cached
    pub fn contains(self: *const Self, key: ImageKey) bool {
        return self.cache.contains(key);
    }

    /// Get cached image if it exists (updates last_accessed for LRU)
    /// Thread-safe: protected by mutex for multi-window scenarios.
    pub fn get(self: *Self, key: ImageKey) ?CachedImage {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.cache.getPtr(key)) |entry| {
            entry.last_accessed = self.current_frame;
            return entry.*;
        }
        return null;
    }

    /// Cache decoded image data
    /// Thread-safe: protected by mutex for multi-window scenarios.
    pub fn cacheImage(
        self: *Self,
        key: ImageKey,
        data: ImageData,
    ) !CachedImage {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Check if already cached
        if (self.cache.get(key)) |cached| {
            return cached;
        }

        // Convert to RGBA if needed
        const rgba_data = if (data.format == .rgba)
            null // Use source directly
        else
            try data.toRgba(self.allocator);
        defer if (rgba_data) |d| self.allocator.free(d);

        const pixels = rgba_data orelse data.pixels;

        // Calculate target dimensions
        const target_w: u32 = if (key.target_width > 0) key.target_width else data.width;
        const target_h: u32 = if (key.target_height > 0) key.target_height else data.height;

        // For now, we use source dimensions (scaling would require resampling)
        // TODO: Add image resampling for different target sizes
        const render_w = @min(data.width, MAX_ATLAS_DIMENSION);
        const render_h = @min(data.height, MAX_ATLAS_DIMENSION);

        // Reserve atlas space
        const region = try self.reserveWithEviction(render_w, render_h);

        // Copy to atlas (may need to clip if image is larger than max)
        if (data.width <= MAX_ATLAS_DIMENSION and data.height <= MAX_ATLAS_DIMENSION) {
            // Image fits entirely
            const pixel_count = data.width * data.height * 4;
            self.atlas.set(region, pixels[0..pixel_count]);
        } else {
            // Clip to max dimensions
            try self.copyClipped(region, pixels, data.width, data.height, render_w, render_h);
        }

        // Capture atlas size AFTER reservation (may have grown)
        const current_atlas_size = self.atlas.size;

        const cached = CachedImage{
            .region = region,
            .source_width = @intCast(data.width),
            .source_height = @intCast(data.height),
            .rendered_width = @intCast(render_w),
            .rendered_height = @intCast(render_h),
            .last_accessed = self.current_frame,
            .atlas_size = current_atlas_size,
        };

        try self.cache.put(key, cached);

        _ = target_w;
        _ = target_h;

        return cached;
    }

    /// Cache image from raw RGBA data (convenience method)
    pub fn cacheRgba(
        self: *Self,
        key: ImageKey,
        width: u32,
        height: u32,
        pixels: []const u8,
    ) !CachedImage {
        return self.cacheImage(key, .{
            .width = width,
            .height = height,
            .pixels = pixels,
            .format = .rgba,
        });
    }

    fn copyClipped(
        self: *Self,
        region: Region,
        src_pixels: []const u8,
        src_width: u32,
        src_height: u32,
        dest_width: u32,
        dest_height: u32,
    ) !void {
        const dest_stride = dest_width * 4;
        const src_stride = src_width * 4;

        const rows_to_copy = @min(src_height, dest_height);
        const cols_to_copy = @min(src_width, dest_width);
        const bytes_per_row = cols_to_copy * 4;

        // Allocate on heap - stack would be MAX_ATLAS_DIMENSION^2 * 4 = 1MB!
        const clipped_data = try self.allocator.alloc(u8, dest_width * dest_height * 4);
        defer self.allocator.free(clipped_data);

        for (0..rows_to_copy) |row| {
            const src_offset = row * src_stride;
            const dest_offset = row * dest_stride;

            @memcpy(clipped_data[dest_offset..][0..bytes_per_row], src_pixels[src_offset..][0..bytes_per_row]);
        }

        self.atlas.set(region, clipped_data);
    }

    fn reserveWithEviction(self: *Self, width: u32, height: u32) !Region {
        if (try self.atlas.reserve(width, height)) |region| {
            return region;
        }

        // Try growing the atlas first
        self.atlas.grow() catch |err| {
            if (err == error.AtlasFull) {
                // Atlas at max size, try LRU eviction
                self.evictLRU();
                if (try self.atlas.reserve(width, height)) |region| {
                    return region;
                }
                // Still no space - clear everything as last resort
                self.clear();
                if (try self.atlas.reserve(width, height)) |region| {
                    return region;
                }
                return error.ImageTooLarge;
            }
            return err;
        };

        // Growth succeeded - update atlas_size in all cached entries
        // This is critical: cached images store atlas_size for UV calculation.
        // When atlas grows, pixel positions stay the same but UVs change.
        self.updateAtlasSizeInCache();

        return try self.atlas.reserve(width, height) orelse error.ImageTooLarge;
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

    /// Evict images to make room for new ones.
    ///
    /// Current implementation (v1): Clear everything - images reload on demand.
    /// The `last_accessed` field is tracked for potential future LRU eviction
    /// that could selectively evict old entries while keeping frequently-used ones.
    ///
    /// Future enhancement (v2): Use last_accessed timestamps to evict only the
    /// oldest entries, keeping hot images cached. This would require either:
    /// - A region allocator that can reuse freed atlas space, or
    /// - Storing pixel data to re-upload retained images after atlas compaction
    fn evictLRU(self: *Self) void {
        // For v1, just clear everything - simple and correct
        self.clear();
    }

    /// Clear all cached images
    pub fn clear(self: *Self) void {
        self.cache.clearRetainingCapacity();
        self.atlas.clear();
    }

    /// Get the underlying atlas for GPU upload.
    /// WARNING: Not thread-safe! Use withAtlasLocked for multi-window scenarios.
    pub fn getAtlas(self: *const Self) *const Atlas {
        return &self.atlas;
    }

    /// Get the current generation (for GPU sync)
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

    /// Check if dimensions are suitable for atlasing
    pub fn shouldAtlas(width: u32, height: u32) bool {
        return width <= MAX_ATLAS_DIMENSION and height <= MAX_ATLAS_DIMENSION;
    }

    /// Result of fit calculation including UV adjustments for cropping modes
    pub const FitResult = struct {
        /// Output quad width (clamped to container for cover/none)
        width: f32,
        /// Output quad height (clamped to container for cover/none)
        height: f32,
        /// X offset within container
        offset_x: f32,
        /// Y offset within container
        offset_y: f32,
        /// UV coordinate adjustments (0-1 range within the texture region)
        uv_left: f32 = 0,
        uv_top: f32 = 0,
        uv_right: f32 = 1,
        uv_bottom: f32 = 1,
    };

    /// Calculate fit dimensions and UV adjustments based on ObjectFit mode
    /// Returns output quad size (clamped to container) and UV coords for texture sampling
    pub fn calculateFitResult(
        src_width: f32,
        src_height: f32,
        container_width: f32,
        container_height: f32,
        fit: ObjectFit,
    ) FitResult {
        const src_aspect = src_width / src_height;
        const container_aspect = container_width / container_height;

        return switch (fit) {
            .contain => {
                if (src_aspect > container_aspect) {
                    // Image is wider - fit to width
                    const h = container_width / src_aspect;
                    return .{
                        .width = container_width,
                        .height = h,
                        .offset_x = 0,
                        .offset_y = (container_height - h) / 2,
                    };
                } else {
                    // Image is taller - fit to height
                    const w = container_height * src_aspect;
                    return .{
                        .width = w,
                        .height = container_height,
                        .offset_x = (container_width - w) / 2,
                        .offset_y = 0,
                    };
                }
            },
            .cover => {
                // For cover: fill container, crop the excess by adjusting UVs
                if (src_aspect > container_aspect) {
                    // Image is wider - fit to height, crop width via UVs
                    const visible_width_ratio = container_aspect / src_aspect;
                    const uv_inset = (1.0 - visible_width_ratio) / 2.0;
                    return .{
                        .width = container_width,
                        .height = container_height,
                        .offset_x = 0,
                        .offset_y = 0,
                        .uv_left = uv_inset,
                        .uv_top = 0,
                        .uv_right = 1.0 - uv_inset,
                        .uv_bottom = 1,
                    };
                } else {
                    // Image is taller - fit to width, crop height via UVs
                    const visible_height_ratio = src_aspect / container_aspect;
                    const uv_inset = (1.0 - visible_height_ratio) / 2.0;
                    return .{
                        .width = container_width,
                        .height = container_height,
                        .offset_x = 0,
                        .offset_y = 0,
                        .uv_left = 0,
                        .uv_top = uv_inset,
                        .uv_right = 1,
                        .uv_bottom = 1.0 - uv_inset,
                    };
                }
            },
            .fill => .{
                .width = container_width,
                .height = container_height,
                .offset_x = 0,
                .offset_y = 0,
            },
            .none => {
                // No scaling - show at original size, crop if larger than container
                if (src_width <= container_width and src_height <= container_height) {
                    // Image fits entirely - center it
                    return .{
                        .width = src_width,
                        .height = src_height,
                        .offset_x = (container_width - src_width) / 2,
                        .offset_y = (container_height - src_height) / 2,
                    };
                } else {
                    // Image is larger - clamp quad to container and adjust UVs
                    const out_w = @min(src_width, container_width);
                    const out_h = @min(src_height, container_height);
                    const uv_w = out_w / src_width;
                    const uv_h = out_h / src_height;
                    const uv_inset_x = (1.0 - uv_w) / 2.0;
                    const uv_inset_y = (1.0 - uv_h) / 2.0;
                    return .{
                        .width = out_w,
                        .height = out_h,
                        .offset_x = (container_width - out_w) / 2,
                        .offset_y = (container_height - out_h) / 2,
                        .uv_left = uv_inset_x,
                        .uv_top = uv_inset_y,
                        .uv_right = 1.0 - uv_inset_x,
                        .uv_bottom = 1.0 - uv_inset_y,
                    };
                }
            },
            .scale_down => {
                if (src_width <= container_width and src_height <= container_height) {
                    // Image fits - no scaling
                    return .{
                        .width = src_width,
                        .height = src_height,
                        .offset_x = (container_width - src_width) / 2,
                        .offset_y = (container_height - src_height) / 2,
                    };
                }
                // Image too large - use contain
                return calculateFitResult(src_width, src_height, container_width, container_height, .contain);
            },
        };
    }
};

test "ImageKey hash consistency" {
    const key1 = ImageKey.initFromPath("test.png", 100, 100, 2.0);
    const key2 = ImageKey.initFromPath("test.png", 100, 100, 2.0);
    const key3 = ImageKey.initFromPath("other.png", 100, 100, 2.0);

    try std.testing.expectEqual(key1.source_hash, key2.source_hash);
    try std.testing.expect(key1.source_hash != key3.source_hash);
}

test "ObjectFit calculations" {
    // Test contain - wide image in square container
    const contain_wide = ImageAtlas.calculateFitResult(200, 100, 100, 100, .contain);
    try std.testing.expectEqual(@as(f32, 100), contain_wide.width);
    try std.testing.expectEqual(@as(f32, 50), contain_wide.height);

    // Test fill
    const fill = ImageAtlas.calculateFitResult(200, 100, 100, 100, .fill);
    try std.testing.expectEqual(@as(f32, 100), fill.width);
    try std.testing.expectEqual(@as(f32, 100), fill.height);
}
