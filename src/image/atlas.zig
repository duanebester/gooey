//! Image Atlas - Texture cache for loaded images
//!
//! Caches decoded images in a texture atlas, keyed by source hash and size.
//! Supports PNG, JPEG, and raw pixel data sources.
//! Thread-safe for multi-window scenarios where multiple DisplayLink threads
//! may access the atlas concurrently.

const std = @import("std");
const atlas_mod = @import("../text/atlas.zig");
const Atlas = atlas_mod.Atlas;
const Region = atlas_mod.Region;
const UVCoords = atlas_mod.UVCoords;
const AtlasUploads = atlas_mod.AtlasUploads;

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
    /// Side of the atlas the region lies in; fixed for the atlas's lifetime.
    atlas_size: u32 = 0,
    /// Atlas shelf holding the pixels; the entry is stale once it is evicted.
    shelf: u16 = atlas_mod.shelf_none,
    generation: u32 = 0,

    /// UV coordinates of the region.
    pub fn uv(self: CachedImage) UVCoords {
        return self.region.uv(self.atlas_size);
    }
};

/// Image texture atlas with caching
pub const ImageAtlas = struct {
    allocator: std.mem.Allocator,
    /// IO instance for mutex operations. Stored on the struct because lock
    /// sites run on CVDisplayLink threads that have no access to `*Cx` and
    /// therefore cannot reach `cx.io()`. Io is a pair of pointers into the
    /// process-lifetime vtable — safe to copy across threads.
    io: std.Io,
    /// RGBA texture atlas, fixed at `AtlasLimits.image_size`.
    atlas: Atlas,
    /// Cache map. Capacity is reserved at init and never grows: a full map
    /// reclaims entries whose shelves were evicted (CLAUDE.md §2).
    cache: std.AutoHashMap(ImageKey, CachedImage),
    /// Current scale factor
    scale_factor: f64,
    /// Mutex for thread-safe access in multi-window scenarios.
    /// Multiple DisplayLink threads may access the atlas concurrently.
    /// Uses `lockUncancelable` everywhere — none of the atlas call sites
    /// propagate `std.Io.Cancelable`, and the critical sections are short
    /// enough that cancelation points would add noise without value.
    mutex: std.Io.Mutex = .init,

    const Self = @This();

    /// Maximum dimension for atlased images (larger images are clipped)
    pub const MAX_ATLAS_DIMENSION: u32 = 2048;

    /// Cached images. The images example, the largest measured user, holds 18.
    pub const entry_count_max: u32 = 1024;

    pub const Options = struct {
        /// `AtlasLimits.image_size`.
        size: u32,
        uploads: *AtlasUploads,
    };

    /// Initialize in place: `Atlas` is reserved at its final address.
    pub fn initInPlace(
        self: *Self,
        allocator: std.mem.Allocator,
        scale_factor: f64,
        io: std.Io,
        options: Options,
    ) !void {
        std.debug.assert(scale_factor > 0);
        std.debug.assert(options.size > 0);
        try self.atlas.init(
            allocator,
            .{ .kind = .image, .size = options.size, .uploads = options.uploads },
        );
        errdefer self.atlas.deinit();
        self.cache = std.AutoHashMap(ImageKey, CachedImage).init(allocator);
        errdefer self.cache.deinit();
        try self.cache.ensureTotalCapacity(entry_count_max);

        self.allocator = allocator;
        self.io = io;
        self.scale_factor = scale_factor;
        self.mutex = .init;
        std.debug.assert(self.cache.capacity() >= entry_count_max);
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

    /// Check if an image is cached with live pixels
    pub fn contains(self: *Self, key: ImageKey) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const cached = self.cache.get(key) orelse return false;
        return self.atlas.isLive(cached.shelf, cached.generation);
    }

    /// Get cached image if its pixels are live, marking it used this frame.
    /// Thread-safe: protected by mutex for multi-window scenarios.
    pub fn get(self: *Self, key: ImageKey) ?CachedImage {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const cached = self.cache.get(key) orelse return null;
        if (!self.atlas.isLive(cached.shelf, cached.generation)) return null;
        self.atlas.touch(cached.shelf, self.atlas.uploads.frameCurrent());
        return cached;
    }

    /// Cache decoded image data. Returns `error.UploadDeferred` when this
    /// frame's upload staging is full; the frame renders again.
    /// Thread-safe: protected by mutex for multi-window scenarios.
    pub fn cacheImage(
        self: *Self,
        key: ImageKey,
        data: ImageData,
    ) !CachedImage {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        // Check if already cached
        if (self.cache.get(key)) |cached| {
            if (self.atlas.isLive(cached.shelf, cached.generation)) {
                self.atlas.touch(cached.shelf, self.atlas.uploads.frameCurrent());
                return cached;
            }
        }

        // Convert to RGBA if needed
        const rgba_data = if (data.format == .rgba)
            null // Use source directly
        else
            try data.toRgba(self.allocator);
        defer if (rgba_data) |d| self.allocator.free(d);

        const pixels = rgba_data orelse data.pixels;

        // Source dimensions, clipped to the atlased maximum (no resampling).
        const render_w = @min(data.width, MAX_ATLAS_DIMENSION);
        const render_h = @min(data.height, MAX_ATLAS_DIMENSION);

        const fits = data.width <= MAX_ATLAS_DIMENSION and data.height <= MAX_ATLAS_DIMENSION;
        const placement = if (fits)
            self.atlas.insert(render_w, render_h, pixels[0 .. data.width * data.height * 4])
        else
            try self.insertClipped(pixels, data.width, render_w, render_h);

        const region_placement = placement orelse return error.UploadDeferred;

        const cached = CachedImage{
            .region = region_placement.region,
            .source_width = @intCast(data.width),
            .source_height = @intCast(data.height),
            .rendered_width = @intCast(render_w),
            .rendered_height = @intCast(render_h),
            .atlas_size = self.atlas.size,
            .shelf = region_placement.shelf,
            .generation = region_placement.generation,
        };

        self.makeRoom(key);
        self.cache.putAssumeCapacity(key, cached);
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

    /// Insert the top-left `dest_width × dest_height` pixels of a larger image.
    fn insertClipped(
        self: *Self,
        src_pixels: []const u8,
        src_width: u32,
        dest_width: u32,
        dest_height: u32,
    ) !?atlas_mod.Placement {
        std.debug.assert(dest_width <= src_width);
        std.debug.assert(dest_width <= MAX_ATLAS_DIMENSION);
        const dest_stride = dest_width * 4;
        const src_stride = src_width * 4;

        // Allocate on heap - stack would be MAX_ATLAS_DIMENSION^2 * 4 = 16MB!
        const clipped_data = try self.allocator.alloc(u8, dest_width * dest_height * 4);
        defer self.allocator.free(clipped_data);

        for (0..dest_height) |row| {
            const src_offset = row * src_stride;
            const dest_offset = row * dest_stride;

            @memcpy(
                clipped_data[dest_offset..][0..dest_stride],
                src_pixels[src_offset..][0..dest_stride],
            );
        }

        return self.atlas.insert(dest_width, dest_height, clipped_data);
    }

    /// Ensure `key` can be stored without growing the map: drop entries whose
    /// shelves were evicted, evicting the least recently used shelf if none
    /// were. A map full of images used this frame fails fast.
    fn makeRoom(self: *Self, key: ImageKey) void {
        if (self.cache.contains(key)) return;
        if (self.cache.count() < entry_count_max) return;
        var attempt: usize = 0;
        while (attempt <= self.atlas.shelves.len) : (attempt += 1) {
            if (self.reclaimStale() > 0) return;
            if (!self.atlas.evictOne()) break;
        }
        std.debug.panic("ImageAtlas pool 'cache' exhausted: capacity {d}, {d} in use, " ++
            "1 requested, every image used since frame {d}.", .{
            entry_count_max,
            self.cache.count(),
            self.atlas.uploads.frameCurrent(),
        });
    }

    /// Remove entries whose atlas pixels were evicted. Bounded by the map size.
    fn reclaimStale(self: *Self) u32 {
        var freed: u32 = 0;
        var it = self.cache.iterator();
        while (it.next()) |entry| {
            const cached = entry.value_ptr.*;
            if (self.atlas.isLive(cached.shelf, cached.generation)) continue;
            self.cache.removeByPtr(entry.key_ptr);
            freed += 1;
        }
        return freed;
    }

    /// Clear all cached images; the atlas condemns their pixels.
    pub fn clear(self: *Self) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.cache.clearRetainingCapacity();
        self.atlas.clear();
    }

    /// The atlas the renderers sample. Its pixels reach GPU textures through
    /// `AtlasUploads`, so renderers read only its fixed size and format here.
    pub fn getAtlas(self: *const Self) *const Atlas {
        return &self.atlas;
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

test "ImageAtlas never returns an image whose pixels were evicted" {
    // A 64² atlas holds four 62×14 images, one per shelf. Frames 2-5 cache
    // a..d; frame 6 touches a and caches e, which evicts b. `get(b)` must miss
    // rather than return the region e now owns, and re-caching b must place
    // b's own pixels while a and e keep theirs.
    const testing = std.testing;
    var uploads: AtlasUploads = undefined;
    try uploads.init(
        testing.allocator,
        testing.io,
        .{ .storage = .cpu_texture, .upload_bytes_frame_max = 64 },
    );
    defer uploads.deinit();
    const consumer: usize = 1;
    uploads.registerConsumer(consumer);
    defer uploads.unregisterConsumer(consumer);

    const image_atlas = try testing.allocator.create(ImageAtlas);
    defer testing.allocator.destroy(image_atlas);
    try image_atlas.initInPlace(
        testing.allocator,
        1.0,
        testing.io,
        .{ .size = 64, .uploads = &uploads },
    );
    defer image_atlas.deinit();

    const names = [_][]const u8{ "a", "b", "c", "d", "e" };
    var pixels: [names.len][62 * 14 * 4]u8 = undefined;
    for (&pixels, 0..) |*image, index| @memset(image, @intCast(40 + index));
    const Frame = struct {
        fn next(journal: *AtlasUploads) void {
            _ = journal.beginFrame(consumer);
            _ = journal.consumeBegin(consumer);
            journal.consumeEnd(consumer);
        }
    };
    const key = struct {
        fn of(name: []const u8) ImageKey {
            return ImageKey.initFromPath(name, null, null, 1.0);
        }
    }.of;
    const firstPixel = struct {
        fn of(atlas: *const Atlas, cached: CachedImage) u8 {
            const data = atlas.getData();
            return data[(@as(usize, cached.region.y) * atlas.size + cached.region.x) * 4];
        }
    }.of;

    for (names[0..4], 0..) |name, index| {
        Frame.next(&uploads);
        _ = try image_atlas.cacheRgba(key(name), 62, 14, &pixels[index]);
    }
    Frame.next(&uploads);
    try testing.expect(image_atlas.get(key("a")) != null);
    const e = try image_atlas.cacheRgba(key("e"), 62, 14, &pixels[4]);

    try testing.expect(image_atlas.get(key("b")) == null);
    try testing.expect(!image_atlas.contains(key("b")));
    try testing.expectEqual(@as(u8, 44), firstPixel(&image_atlas.atlas, e));

    Frame.next(&uploads);
    const b = try image_atlas.cacheRgba(key("b"), 62, 14, &pixels[1]);
    try testing.expectEqual(@as(u8, 41), firstPixel(&image_atlas.atlas, b));
    const a = image_atlas.get(key("a")).?;
    try testing.expectEqual(@as(u8, 40), firstPixel(&image_atlas.atlas, a));
    try testing.expectEqual(
        @as(u8, 44),
        firstPixel(&image_atlas.atlas, image_atlas.get(key("e")).?),
    );
}
