const std = @import("std");
const atlas_mod = @import("../text/atlas.zig");
const Atlas = atlas_mod.Atlas;
const Region = atlas_mod.Region;
const UVCoords = atlas_mod.UVCoords;
const AtlasUploads = atlas_mod.AtlasUploads;
const limits = @import("../core/limits.zig");

const assert = std.debug.assert;

pub const ObjectFit = enum {
    contain,
    cover,
    fill,
    none,
    scale_down,
};

pub const ImageSource = union(enum) {
    embedded: []const u8,
    path: []const u8,
    url: []const u8,
    data: ImageData,
};

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
                    output[dst_offset + 0] = self.pixels[src_offset + 2];
                    output[dst_offset + 1] = self.pixels[src_offset + 1];
                    output[dst_offset + 2] = self.pixels[src_offset + 0];
                    output[dst_offset + 3] = self.pixels[src_offset + 3];
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
                    output[dst_offset + 3] = 255;
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

pub const ImageKey = struct {
    source_hash: u64,
    target_width: u16,
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

pub const CachedImage = struct {
    region: Region,
    source_width: u16,
    source_height: u16,
    rendered_width: u16,
    rendered_height: u16,
    atlas_size: u32 = 0,
    shelf: u16 = atlas_mod.shelf_none,
    generation: u32 = 0,

    pub fn uv(self: CachedImage) UVCoords {
        return self.region.uv(self.atlas_size);
    }
};

pub const ImageAtlas = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    atlas: Atlas,
    cache: std.AutoHashMap(ImageKey, CachedImage),
    entry_count_max: u32,
    scale_factor: f64,
    mutex: std.Io.Mutex = .init,

    const Self = @This();

    pub const Options = struct {
        size: u32,
        entry_count_max: u32,
        uploads: *AtlasUploads,
    };

    pub fn initInPlace(
        self: *Self,
        allocator: std.mem.Allocator,
        scale_factor: f64,
        io: std.Io,
        options: Options,
    ) !void {
        assert(scale_factor > 0);
        assert(options.size > 0);
        assert(options.entry_count_max > 0);
        assert(options.entry_count_max <= limits.MAX_IMAGE_ENTRIES);
        try self.atlas.init(
            allocator,
            .{ .kind = .image, .size = options.size, .uploads = options.uploads },
        );
        errdefer self.atlas.deinit();
        self.cache = std.AutoHashMap(ImageKey, CachedImage).init(allocator);
        errdefer self.cache.deinit();
        try self.cache.ensureTotalCapacity(options.entry_count_max);

        self.allocator = allocator;
        self.entry_count_max = options.entry_count_max;
        self.io = io;
        self.scale_factor = scale_factor;
        self.mutex = .init;
        assert(self.cache.capacity() >= self.entry_count_max);
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

    pub fn contains(self: *Self, key: ImageKey) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const cached = self.cache.get(key) orelse return false;
        return self.atlas.isLive(cached.shelf, cached.generation);
    }

    pub fn get(self: *Self, key: ImageKey) ?CachedImage {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const cached = self.cache.get(key) orelse return null;
        if (!self.atlas.isLive(cached.shelf, cached.generation)) return null;
        self.atlas.touch(cached.shelf, self.atlas.uploads.frameCurrent());
        return cached;
    }

    pub fn cacheRgba(
        self: *Self,
        key: ImageKey,
        width: u32,
        height: u32,
        pixels: []const u8,
    ) error{UploadDeferred}!CachedImage {
        assert(width > 0);
        assert(height > 0);
        assert(width <= self.atlas.size - 2);
        assert(height <= self.atlas.size - 2);
        assert(pixels.len >= @as(usize, width) * height * 4);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.cache.get(key)) |cached| {
            if (self.atlas.isLive(cached.shelf, cached.generation)) {
                self.atlas.touch(cached.shelf, self.atlas.uploads.frameCurrent());
                return cached;
            }
        }

        const placement = self.atlas.insert(width, height, pixels) orelse {
            return error.UploadDeferred;
        };
        const cached = CachedImage{
            .region = placement.region,
            .source_width = @intCast(width),
            .source_height = @intCast(height),
            .rendered_width = @intCast(width),
            .rendered_height = @intCast(height),
            .atlas_size = self.atlas.size,
            .shelf = placement.shelf,
            .generation = placement.generation,
        };

        self.makeRoom(key);
        self.cache.putAssumeCapacity(key, cached);
        assert(self.cache.count() <= self.entry_count_max);
        return cached;
    }

    fn makeRoom(self: *Self, key: ImageKey) void {
        if (self.cache.contains(key)) return;
        assert(self.cache.count() <= self.entry_count_max);
        if (self.cache.count() < self.entry_count_max) return;
        var attempt: usize = 0;
        while (attempt <= self.atlas.shelves.len) : (attempt += 1) {
            if (self.reclaimStale() > 0) return;
            if (!self.atlas.evictOne()) break;
        }
        std.debug.panic("ImageAtlas pool 'cache' exhausted: capacity {d}, {d} in use, " ++
            "1 requested, every image used since frame {d}. " ++
            "Raise ResourceLimits.atlas.image_entry_count_max.", .{
            self.entry_count_max,
            self.cache.count(),
            self.atlas.uploads.frameCurrent(),
        });
    }

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

    pub fn clear(self: *Self) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.cache.clearRetainingCapacity();
        self.atlas.clear();
    }

    pub fn getAtlas(self: *const Self) *const Atlas {
        return &self.atlas;
    }

    pub const FitResult = struct {
        width: f32,
        height: f32,
        offset_x: f32,
        offset_y: f32,
        uv_left: f32 = 0,
        uv_top: f32 = 0,
        uv_right: f32 = 1,
        uv_bottom: f32 = 1,
    };

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
                    const h = container_width / src_aspect;
                    return .{
                        .width = container_width,
                        .height = h,
                        .offset_x = 0,
                        .offset_y = (container_height - h) / 2,
                    };
                } else {
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
                if (src_aspect > container_aspect) {
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
                if (src_width <= container_width and src_height <= container_height) {
                    return .{
                        .width = src_width,
                        .height = src_height,
                        .offset_x = (container_width - src_width) / 2,
                        .offset_y = (container_height - src_height) / 2,
                    };
                } else {
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
                    return .{
                        .width = src_width,
                        .height = src_height,
                        .offset_x = (container_width - src_width) / 2,
                        .offset_y = (container_height - src_height) / 2,
                    };
                }
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
    const contain_wide = ImageAtlas.calculateFitResult(200, 100, 100, 100, .contain);
    try std.testing.expectEqual(@as(f32, 100), contain_wide.width);
    try std.testing.expectEqual(@as(f32, 50), contain_wide.height);

    const fill = ImageAtlas.calculateFitResult(200, 100, 100, 100, .fill);
    try std.testing.expectEqual(@as(f32, 100), fill.width);
    try std.testing.expectEqual(@as(f32, 100), fill.height);
}

test "ImageAtlas never returns an image whose pixels were evicted" {
    const testing = std.testing;
    var uploads: AtlasUploads = undefined;
    try uploads.init(
        testing.allocator,
        testing.io,
        .{
            .storage = .cpu_texture,
            .upload_bytes_frame_max = 64,
            .consumer_count_max = 1,
        },
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
        .{ .size = 64, .entry_count_max = 8, .uploads = &uploads },
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

test "ImageAtlas holds exactly its entries, all live in one frame" {
    const testing = std.testing;
    var uploads: AtlasUploads = undefined;
    try uploads.init(
        testing.allocator,
        testing.io,
        .{
            .storage = .cpu_texture,
            .upload_bytes_frame_max = 64 * 1024,
            .consumer_count_max = 1,
        },
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
        .{ .size = 256, .entry_count_max = 8, .uploads = &uploads },
    );
    defer image_atlas.deinit();

    const names = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h" };
    const pixels: [8 * 8 * 4]u8 = @splat(255);
    var regions: [names.len]Region = undefined;
    _ = uploads.beginFrame(consumer);
    for (names, &regions) |name, *region| {
        const key = ImageKey.initFromPath(name, null, null, 1.0);
        region.* = (try image_atlas.cacheRgba(key, 8, 8, &pixels)).region;
    }
    try testing.expectEqual(@as(u32, 8), image_atlas.cache.count());
    for (names, regions) |name, region| {
        const hit = image_atlas.get(ImageKey.initFromPath(name, null, null, 1.0)).?;
        try testing.expectEqual(region, hit.region);
    }
}
