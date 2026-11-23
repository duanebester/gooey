const std = @import("std");
const Atlas = @import("../text/atlas.zig").Atlas;
const Region = @import("../text/atlas.zig").Region;
const UVCoords = @import("../text/atlas.zig").UVCoords;
const AtlasUploads = @import("../text/atlas.zig").AtlasUploads;
const rasterizer = @import("rasterizer.zig");
const limits = @import("../core/limits.zig");

const assert = std.debug.assert;

pub const SvgKey = struct {
    path_hash: u64,
    device_size: u16,
    has_fill: bool,
    has_stroke: bool,
    stroke_width_q: u8,

    pub fn init(
        path_data: []const u8,
        logical_size: f32,
        scale_factor: f64,
        has_fill: bool,
        stroke_width: ?f32,
    ) SvgKey {
        const has_stroke = stroke_width != null and stroke_width.? > 0;
        return .{
            .path_hash = std.hash.Wyhash.hash(0, path_data),
            .device_size = @intFromFloat(@ceil(logical_size * scale_factor)),
            .has_fill = has_fill,
            .has_stroke = has_stroke,
            .stroke_width_q = if (has_stroke) @intFromFloat(@min(255, (stroke_width.? * 4))) else 0,
        };
    }
};

pub const CachedSvg = struct {
    region: Region,
    offset_x: i16,
    offset_y: i16,
    atlas_size: u32,
    shelf: u16,
    generation: u32,

    pub fn uv(self: CachedSvg) UVCoords {
        return self.region.uv(self.atlas_size);
    }
};

pub const SvgAtlas = struct {
    allocator: std.mem.Allocator,
    atlas: Atlas,
    cache: std.AutoHashMap(SvgKey, CachedSvg),
    entry_count_max: u32,
    rasterization_count_frame_max: u32,
    render_buffer: []u8,
    render_buffer_size: u32,
    raster_scratch: []u8,
    raster_budget: rasterizer.RasterBudget,
    scale_factor: f64,
    io: std.Io,
    mutex: std.Io.Mutex,

    rasterizations_this_frame: u32 = 0,

    deferred_this_frame: bool = false,

    const Self = @This();

    pub fn rasterScratchBytes(budget: rasterizer.RasterBudget, icon_size_max: u32) u32 {
        std.debug.assert(icon_size_max > 0);
        std.debug.assert(icon_size_max <= limits.MAX_SVG_ICON_SIZE);
        std.debug.assert(budget.path_bytes_max <= limits.MAX_SVG_PATH_BYTES);
        std.debug.assert(budget.vertex_count_max <= limits.MAX_SVG_PATH_VERTEX_COUNT);
        return rasterizer.scratchBytes(budget, icon_size_max);
    }

    comptime {
        const ceiling = limits.AtlasLimits.ceiling;
        const budget = rasterizer.RasterBudget{
            .path_bytes_max = ceiling.svg_path_bytes_max,
            .vertex_count_max = ceiling.svg_path_vertex_count_max,
        };
        std.debug.assert(rasterScratchBytes(budget, ceiling.svg_icon_size_max) <= 4 * 1024 * 1024);
    }

    pub const Options = struct {
        size: u32,
        icon_size_max: u32,
        raster_budget: rasterizer.RasterBudget,
        entry_count_max: u32,
        rasterization_count_frame_max: u32,
        uploads: *AtlasUploads,
    };

    pub fn initInPlace(
        self: *Self,
        allocator: std.mem.Allocator,
        scale_factor: f64,
        io: std.Io,
        options: Options,
    ) !void {
        std.debug.assert(options.icon_size_max > 0);
        std.debug.assert(options.icon_size_max + 2 <= options.size);
        std.debug.assert(options.entry_count_max > 0);
        std.debug.assert(options.entry_count_max <= limits.MAX_SVG_ENTRIES);
        std.debug.assert(options.rasterization_count_frame_max > 0);
        std.debug.assert(options.rasterization_count_frame_max <= options.entry_count_max);
        const buffer_size = options.icon_size_max * options.icon_size_max * 4;
        self.render_buffer = try allocator.alloc(u8, buffer_size);
        errdefer allocator.free(self.render_buffer);

        const scratch_bytes = rasterScratchBytes(options.raster_budget, options.icon_size_max);
        self.raster_scratch = try allocator.alloc(u8, scratch_bytes);
        errdefer allocator.free(self.raster_scratch);

        try self.atlas.init(
            allocator,
            .{ .kind = .svg, .size = options.size, .uploads = options.uploads },
        );
        errdefer self.atlas.deinit();

        self.cache = std.AutoHashMap(SvgKey, CachedSvg).init(allocator);
        errdefer self.cache.deinit();
        try self.cache.ensureTotalCapacity(options.entry_count_max);

        self.allocator = allocator;
        self.entry_count_max = options.entry_count_max;
        self.rasterization_count_frame_max = options.rasterization_count_frame_max;
        self.render_buffer_size = options.icon_size_max;
        self.raster_budget = options.raster_budget;
        self.scale_factor = scale_factor;
        self.io = io;
        self.mutex = .init;
        self.rasterizations_this_frame = 0;
        self.deferred_this_frame = false;
        std.debug.assert(self.cache.capacity() >= self.entry_count_max);
    }

    pub fn deinit(self: *Self) void {
        self.cache.deinit();
        self.atlas.deinit();
        self.allocator.free(self.raster_scratch);
        self.allocator.free(self.render_buffer);
    }

    pub fn setScaleFactor(self: *Self, scale: f32) void {
        if (self.scale_factor != scale) {
            self.scale_factor = scale;
            self.clear();
        }
    }

    pub fn resetFrameBudget(self: *Self) void {
        self.rasterizations_this_frame = 0;
        self.deferred_this_frame = false;
    }

    pub fn hasDeferredWork(self: *const Self) bool {
        return self.deferred_this_frame;
    }

    pub fn getOrRasterize(
        self: *Self,
        path_data: []const u8,
        viewbox: f32,
        logical_size: f32,
        has_fill: bool,
        stroke_width: ?f32,
    ) !CachedSvg {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const key = SvgKey.init(path_data, logical_size, self.scale_factor, has_fill, stroke_width);

        if (self.cache.get(key)) |cached| {
            if (self.atlas.isLive(cached.shelf, cached.generation)) {
                self.atlas.touch(cached.shelf, self.atlas.uploads.frameCurrent());
                return cached;
            }
        }

        assert(self.rasterizations_this_frame <= self.rasterization_count_frame_max);
        if (self.rasterizations_this_frame == self.rasterization_count_frame_max) {
            self.deferred_this_frame = true;
            return error.RasterizationDeferred;
        }

        if (key.device_size > self.render_buffer_size) return error.IconTooLarge;
        if (path_data.len > self.raster_budget.path_bytes_max) self.failPathBytes(path_data.len);

        const rasterized = try self.rasterizeIntoRenderBuffer(.{
            .path_data = path_data,
            .viewbox = viewbox,
            .device_size = key.device_size,
            .has_fill = has_fill,
            .stroke_width = stroke_width,
        });
        std.debug.assert(rasterized.width <= self.render_buffer_size);
        std.debug.assert(rasterized.height <= self.render_buffer_size);

        self.rasterizations_this_frame += 1;

        const pixel_count = rasterized.width * rasterized.height * 4;
        const placement = self.atlas.insert(
            rasterized.width,
            rasterized.height,
            self.render_buffer[0..pixel_count],
        ) orelse {
            self.deferred_this_frame = true;
            return error.RasterizationDeferred;
        };

        const cached = CachedSvg{
            .region = placement.region,
            .offset_x = rasterized.offset_x,
            .offset_y = rasterized.offset_y,
            .atlas_size = self.atlas.size,
            .shelf = placement.shelf,
            .generation = placement.generation,
        };

        self.makeRoom(key);
        self.cache.putAssumeCapacity(key, cached);
        return cached;
    }

    const RasterizeIntoRenderBufferOptions = struct {
        path_data: []const u8,
        viewbox: f32,
        device_size: u16,
        has_fill: bool,
        stroke_width: ?f32,
    };

    fn rasterizeIntoRenderBuffer(
        self: *Self,
        options: RasterizeIntoRenderBufferOptions,
    ) rasterizer.RasterizeError!rasterizer.RasterizedSvg {
        std.debug.assert(options.device_size > 0);
        std.debug.assert(options.device_size <= self.render_buffer_size);
        std.debug.assert(options.path_data.len <= self.raster_budget.path_bytes_max);
        if (!(options.viewbox > 0)) return error.EmptyPath;

        @memset(self.render_buffer, 0);
        const stroke_enabled = options.stroke_width != null and options.stroke_width.? > 0;
        const stroke_width_device: f32 = if (stroke_enabled)
            options.stroke_width.? * @as(f32, @floatCast(self.scale_factor))
        else
            0;

        var scratch = RasterScratch.init(self.raster_scratch);
        const rasterized = rasterizer.rasterizeWithOptions(
            scratch.allocator(),
            options.path_data,
            options.viewbox,
            options.device_size,
            self.render_buffer,
            options.has_fill,
            .{ .enabled = stroke_enabled, .width = stroke_width_device },
            self.raster_budget,
        ) catch |err| switch (err) {
            error.PathTooComplex => {
                self.failVertexCount(options.path_data.len, options.device_size);
            },
            error.OutOfMemory => std.debug.panic(
                "SvgAtlas pool 'raster_scratch' exhausted: capacity {d} B, peak {d} B, " ++
                    "requested {d} B, path {d} B at {d} px, frame {d}. The scratch is sized " ++
                    "to the rasterizer's reservations, so this is a sizing bug.",
                .{
                    self.raster_scratch.len,
                    scratch.used_bytes_max,
                    scratch.refused_bytes,
                    options.path_data.len,
                    options.device_size,
                    self.atlas.uploads.frameCurrent(),
                },
            ),
            else => |e| return e,
        };
        std.debug.assert(scratch.used_bytes_max <= self.raster_scratch.len);
        std.debug.assert(rasterized.width <= options.device_size);
        std.debug.assert(rasterized.height <= options.device_size);
        return rasterized;
    }

    fn failPathBytes(self: *const Self, path_bytes: usize) noreturn {
        std.debug.assert(path_bytes > self.raster_budget.path_bytes_max);
        std.debug.panic(
            "SvgAtlas: an icon path of {d} B exceeds ResourceLimits.atlas.svg_path_bytes_max " ++
                "= {d}; raise it in the app's ResourceLimits (frame {d}).",
            .{ path_bytes, self.raster_budget.path_bytes_max, self.atlas.uploads.frameCurrent() },
        );
    }

    fn failVertexCount(self: *const Self, path_bytes: usize, device_size: u16) noreturn {
        std.debug.assert(path_bytes <= self.raster_budget.path_bytes_max);
        std.debug.assert(device_size <= self.render_buffer_size);
        std.debug.panic(
            "SvgAtlas: an icon path of {d} B flattens to more than " ++
                "ResourceLimits.atlas.svg_path_vertex_count_max = {d} vertices at {d} px; " ++
                "raise it in the app's ResourceLimits (frame {d}).",
            .{
                path_bytes,
                self.raster_budget.vertex_count_max,
                device_size,
                self.atlas.uploads.frameCurrent(),
            },
        );
    }

    fn makeRoom(self: *Self, key: SvgKey) void {
        if (self.cache.contains(key)) return;
        assert(self.cache.count() <= self.entry_count_max);
        if (self.cache.count() < self.entry_count_max) return;
        var attempt: usize = 0;
        while (attempt <= self.atlas.shelves.len) : (attempt += 1) {
            if (self.reclaimStale() > 0) return;
            if (!self.atlas.evictOne()) break;
        }
        std.debug.panic("SvgAtlas pool 'cache' exhausted: capacity {d}, {d} in use, " ++
            "1 requested, every icon used since frame {d}. " ++
            "Raise ResourceLimits.atlas.svg_entry_count_max.", .{
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
};

const RasterScratch = struct {
    fixed: std.heap.FixedBufferAllocator,
    used_bytes_max: u32,
    refused_bytes: u64,

    const FixedBufferAllocator = std.heap.FixedBufferAllocator;
    const Alignment = std.mem.Alignment;

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn init(buffer: []u8) RasterScratch {
        std.debug.assert(buffer.len <= std.math.maxInt(u32));
        if (buffer.len > 0) std.debug.assert(@intFromPtr(buffer.ptr) != 0);
        return .{ .fixed = .init(buffer), .used_bytes_max = 0, .refused_bytes = 0 };
    }

    fn allocator(self: *RasterScratch) std.mem.Allocator {
        std.debug.assert(self.fixed.end_index <= self.fixed.buffer.len);
        std.debug.assert(self.fixed.end_index <= self.used_bytes_max);
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn alloc(context: *anyopaque, len: usize, alignment: Alignment, return_address: usize) ?[*]u8 {
        const self: *RasterScratch = @ptrCast(@alignCast(context));
        const result = FixedBufferAllocator.alloc(&self.fixed, len, alignment, return_address);
        if (result == null) self.refuse(len) else self.record();
        return result;
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        len_new: usize,
        return_address: usize,
    ) bool {
        const self: *RasterScratch = @ptrCast(@alignCast(context));
        const resized = FixedBufferAllocator.resize(
            &self.fixed,
            memory,
            alignment,
            len_new,
            return_address,
        );
        if (resized) self.record() else self.refuse(len_new);
        return resized;
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        len_new: usize,
        return_address: usize,
    ) ?[*]u8 {
        const resized = resize(context, memory, alignment, len_new, return_address);
        return if (resized) memory.ptr else null;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: Alignment, return_address: usize) void {
        const self: *RasterScratch = @ptrCast(@alignCast(context));
        FixedBufferAllocator.free(&self.fixed, memory, alignment, return_address);
        std.debug.assert(self.fixed.end_index <= self.used_bytes_max);
    }

    fn record(self: *RasterScratch) void {
        std.debug.assert(self.fixed.end_index <= self.fixed.buffer.len);
        const used_bytes: u32 = @intCast(self.fixed.end_index);
        self.used_bytes_max = @max(self.used_bytes_max, used_bytes);
        std.debug.assert(self.used_bytes_max <= self.fixed.buffer.len);
    }

    fn refuse(self: *RasterScratch, len: usize) void {
        std.debug.assert(len > 0);
        self.refused_bytes = len;
        std.debug.assert(self.fixed.end_index <= self.used_bytes_max);
    }
};

const raster_backend_software =
    rasterizer.RasterizedSvg == @import("backends/cairo.zig").RasterizedSvg;

test "RasterScratch keeps its peak across frees and reports the refused request" {
    const testing = std.testing;
    var buffer: [64]u8 = undefined;
    var scratch = RasterScratch.init(&buffer);
    const gpa = scratch.allocator();

    const first = try gpa.alloc(u8, 16);
    const second = try gpa.alloc(u8, 32);
    gpa.free(second);
    try testing.expectEqual(@as(usize, 16), scratch.fixed.end_index);
    try testing.expectEqual(@as(u32, 48), scratch.used_bytes_max);
    try testing.expectEqual(@as(u64, 0), scratch.refused_bytes);

    const last = try gpa.alloc(u8, 48);
    try testing.expectEqual(@as(u32, 64), scratch.used_bytes_max);
    try testing.expectError(error.OutOfMemory, gpa.alloc(u8, 1));
    try testing.expectEqual(@as(u64, 1), scratch.refused_bytes);
    try testing.expect(!gpa.resize(last, 49));
    try testing.expectEqual(@as(u64, 49), scratch.refused_bytes);

    gpa.free(last);
    gpa.free(first);
    try testing.expectEqual(@as(usize, 0), scratch.fixed.end_index);
    try testing.expectEqual(@as(u32, 64), scratch.used_bytes_max);
}

const test_loader_pinwheel = "<path d=\"M22 12a1 1 0 0 1-10 0 1 1 0 0 0-10 0\"/>" ++
    "<path d=\"M7 20.7a1 1 0 1 1 5-8.7 1 1 0 1 0 5-8.6\"/>" ++
    "<path d=\"M7 3.3a1 1 0 1 1 5 8.6 1 1 0 1 0 5 8.6\"/>" ++
    "<circle cx=\"12\" cy=\"12\" r=\"10\"/>";

fn testRasterBudget(atlas_limits: limits.AtlasLimits) rasterizer.RasterBudget {
    return .{
        .path_bytes_max = atlas_limits.svg_path_bytes_max,
        .vertex_count_max = atlas_limits.svg_path_vertex_count_max,
    };
}

test "SvgAtlas rasterizes the heaviest Lucide icon at the size ceiling within its scratch" {
    if (!raster_backend_software) return error.SkipZigTest;
    const testing = std.testing;
    const side = limits.MAX_SVG_ICON_SIZE;
    const budget = testRasterBudget(limits.AtlasLimits.standard);
    const scratch = try testing.allocator.alloc(u8, SvgAtlas.rasterScratchBytes(budget, side));
    defer testing.allocator.free(scratch);

    const pixels = try testing.allocator.alloc(u8, side * side * 4);
    defer testing.allocator.free(pixels);

    var arena = RasterScratch.init(scratch);
    const rasterized = try rasterizer.rasterizeWithOptions(
        arena.allocator(),
        test_loader_pinwheel,
        24,
        side,
        pixels,
        true,
        .{ .enabled = true, .width = @as(f32, @floatFromInt(side)) / 12.0 },
        budget,
    );
    try testing.expectEqual(side, rasterized.width);
    try testing.expect(arena.used_bytes_max <= scratch.len);
    try testing.expectEqual(@as(u64, 0), arena.refused_bytes);

    var fill_max: u8 = 0;
    var stroke_max: u8 = 0;
    var index: usize = 0;
    while (index < pixels.len) : (index += 4) {
        fill_max = @max(fill_max, pixels[index]);
        stroke_max = @max(stroke_max, pixels[index + 1]);
    }
    try testing.expectEqual(@as(u8, 255), fill_max);
    try testing.expectEqual(@as(u8, 255), stroke_max);
}

test "an icon past its vertex budget is refused before it exhausts the scratch" {
    if (!raster_backend_software) return error.SkipZigTest;
    const testing = std.testing;
    const side = limits.MAX_SVG_ICON_SIZE;
    const budget = rasterizer.RasterBudget{ .path_bytes_max = 1024, .vertex_count_max = 2048 };
    const scratch = try testing.allocator.alloc(u8, SvgAtlas.rasterScratchBytes(budget, side));
    defer testing.allocator.free(scratch);

    const pixels = try testing.allocator.alloc(u8, side * side * 4);
    defer testing.allocator.free(pixels);

    var arena = RasterScratch.init(scratch);
    try testing.expectError(error.PathTooComplex, rasterizer.rasterizeWithOptions(
        arena.allocator(),
        test_loader_pinwheel,
        24,
        side,
        pixels,
        true,
        .{ .enabled = true, .width = 2 },
        budget,
    ));
    try testing.expectEqual(@as(u64, 0), arena.refused_bytes);
    try testing.expect(arena.used_bytes_max <= scratch.len);
}

test "SvgAtlas re-rasterizes an icon whose atlas shelf was evicted" {
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

    const svg_atlas = try testing.allocator.create(SvgAtlas);
    defer testing.allocator.destroy(svg_atlas);
    try svg_atlas.initInPlace(testing.allocator, 1.0, testing.io, .{
        .size = 64,
        .icon_size_max = 32,
        .raster_budget = testRasterBudget(limits.AtlasLimits.nano),
        .entry_count_max = limits.AtlasLimits.nano.svg_entry_count_max,
        .rasterization_count_frame_max = 4,
        .uploads = &uploads,
    });
    defer svg_atlas.deinit();

    const paths = [_][]const u8{
        "M0 0L24 0L0 24Z",       "M0 0L24 0L24 24Z", "M0 0L24 24L0 24Z", "M24 0L24 24L0 24Z",
        "M0 0L24 0L24 24L0 24Z",
    };
    var saved: [paths.len][32 * 32 * 4]u8 = undefined;
    var placed: [paths.len]CachedSvg = undefined;
    const Harness = struct {
        fn frame(journal: *AtlasUploads, atlas: *SvgAtlas) void {
            _ = journal.beginFrame(consumer);
            _ = journal.consumeBegin(consumer);
            journal.consumeEnd(consumer);
            atlas.resetFrameBudget();
        }
        fn icon(atlas: *SvgAtlas, path: []const u8) !CachedSvg {
            return atlas.getOrRasterize(path, 24, 30, true, null);
        }
        fn copy(atlas: *const Atlas, region: Region, out: []u8) []const u8 {
            const row_bytes = @as(usize, region.width) * 4;
            var row: usize = 0;
            while (row < region.height) : (row += 1) {
                const source = ((@as(usize, region.y) + row) * atlas.size + region.x) * 4;
                @memcpy(
                    out[row * row_bytes ..][0..row_bytes],
                    atlas.getData()[source..][0..row_bytes],
                );
            }
            return out[0 .. row_bytes * region.height];
        }
    };

    for (paths[0..4], 0..) |path, index| {
        Harness.frame(&uploads, svg_atlas);
        placed[index] = try Harness.icon(svg_atlas, path);
        _ = Harness.copy(&svg_atlas.atlas, placed[index].region, &saved[index]);
    }
    try testing.expectEqual(placed[0].region.y, placed[1].region.y);
    try testing.expectEqual(placed[2].region.y, placed[3].region.y);
    try testing.expect(placed[0].region.y != placed[2].region.y);

    Harness.frame(&uploads, svg_atlas);
    _ = try Harness.icon(svg_atlas, paths[0]);
    placed[4] = try Harness.icon(svg_atlas, paths[4]);
    try testing.expectEqual(placed[2].region.x, placed[4].region.x);
    try testing.expectEqual(placed[2].region.y, placed[4].region.y);

    Harness.frame(&uploads, svg_atlas);
    const again = try Harness.icon(svg_atlas, paths[2]);
    var current: [32 * 32 * 4]u8 = undefined;
    const original = saved[2][0 .. @as(usize, placed[2].region.width) *
        placed[2].region.height * 4];
    try testing.expectEqualSlices(
        u8,
        original,
        Harness.copy(&svg_atlas.atlas, again.region, &current),
    );
    const a = try Harness.icon(svg_atlas, paths[0]);
    const original_a = saved[0][0 .. @as(usize, placed[0].region.width) *
        placed[0].region.height * 4];
    try testing.expectEqualSlices(
        u8,
        original_a,
        Harness.copy(&svg_atlas.atlas, a.region, &current),
    );
}

test "SvgAtlas holds exactly its entries and rasterizes exactly its frame budget" {
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

    const svg_atlas = try testing.allocator.create(SvgAtlas);
    defer testing.allocator.destroy(svg_atlas);
    try svg_atlas.initInPlace(testing.allocator, 1.0, testing.io, .{
        .size = 256,
        .icon_size_max = 32,
        .raster_budget = testRasterBudget(limits.AtlasLimits.nano),
        .entry_count_max = 8,
        .rasterization_count_frame_max = 3,
        .uploads = &uploads,
    });
    defer svg_atlas.deinit();

    const paths = [_][]const u8{
        "M0 0L24 0L0 24Z", "M1 0L24 0L0 24Z", "M2 0L24 0L0 24Z", "M3 0L24 0L0 24Z",
        "M4 0L24 0L0 24Z", "M5 0L24 0L0 24Z", "M6 0L24 0L0 24Z", "M7 0L24 0L0 24Z",
    };
    var regions: [paths.len]?Region = @splat(null);
    var frame_count: u32 = 0;
    while (frame_count < 3) : (frame_count += 1) {
        _ = uploads.beginFrame(consumer);
        svg_atlas.resetFrameBudget();
        var rasterized: u32 = 0;
        for (paths, &regions) |path, *region| {
            if (region.* != null) continue;
            const result = svg_atlas.getOrRasterize(path, 24, 16, true, null);
            if (result) |cached| {
                region.* = cached.region;
                rasterized += 1;
            } else |err| {
                try testing.expectEqual(error.RasterizationDeferred, err);
                try testing.expect(svg_atlas.hasDeferredWork());
            }
        }
        try testing.expect(rasterized <= 3);
        if (frame_count < 2) try testing.expectEqual(@as(u32, 3), rasterized);
    }
    try testing.expectEqual(@as(u32, 8), svg_atlas.cache.count());
    _ = uploads.beginFrame(consumer);
    svg_atlas.resetFrameBudget();
    for (paths, regions) |path, region| {
        const hit = try svg_atlas.getOrRasterize(path, 24, 16, true, null);
        try testing.expectEqual(region.?, hit.region);
    }
    try testing.expect(!svg_atlas.hasDeferredWork());
    try testing.expectEqual(@as(u32, 8), svg_atlas.cache.count());
}
