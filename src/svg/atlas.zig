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
const AtlasUploads = @import("../text/atlas.zig").AtlasUploads;
const rasterizer = @import("rasterizer.zig");
const limits = @import("../core/limits.zig");

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
    /// Side of the atlas the region lies in; fixed for the atlas's lifetime.
    atlas_size: u32,
    /// Atlas shelf holding the pixels; the entry is stale once it is evicted.
    shelf: u16,
    generation: u32,

    /// UV coordinates of the region.
    pub fn uv(self: CachedSvg) UVCoords {
        return self.region.uv(self.atlas_size);
    }
};

/// SVG texture atlas with caching
pub const SvgAtlas = struct {
    allocator: std.mem.Allocator,
    /// RGBA texture atlas, fixed at `AtlasLimits.svg_size`.
    atlas: Atlas,
    /// Cache map. Capacity is reserved at init and never grows: a full map
    /// reclaims entries whose shelves were evicted (CLAUDE.md §2).
    cache: std.AutoHashMap(SvgKey, CachedSvg),
    /// Reusable rasterization buffer, `svg_icon_size_max²` RGBA pixels.
    render_buffer: []u8,
    render_buffer_size: u32,
    /// Arena for the rasterizer's parsed path, flattened polygons, edge
    /// tables, and stroke buffer. Reserved at init and reset before every
    /// rasterization, so a cache miss never reaches the heap (CLAUDE.md §2).
    raster_scratch: []u8,
    /// `AtlasLimits.svg_path_bytes_max` and `svg_path_vertex_count_max`,
    /// which size `raster_scratch`; an icon past either fails fast.
    raster_budget: rasterizer.RasterBudget,
    /// Current scale factor
    scale_factor: f64,
    /// IO instance for mutex operations. Stored on the struct because lock
    /// sites run on CVDisplayLink threads that have no access to `*Cx` and
    /// therefore cannot reach `cx.io()`. Io is a pair of pointers into the
    /// process-lifetime vtable — safe to copy across threads.
    io: std.Io,
    /// Mutex for thread-safe access in multi-window scenarios.
    /// Multiple DisplayLink threads may access the atlas concurrently.
    /// Uses `lockUncancelable` everywhere — none of the atlas call sites
    /// propagate `std.Io.Cancelable`, and the critical sections are short
    /// enough that cancelation points would add noise without value.
    mutex: std.Io.Mutex,

    // =========================================================================
    // Per-frame rasterization budget
    // =========================================================================

    /// Number of software rasterizations performed this frame.
    rasterizations_this_frame: u32 = 0,

    /// Set when a cache miss was skipped due to budget exhaustion.
    /// Caller should check this via `hasDeferredWork()` and request a redraw.
    deferred_this_frame: bool = false,

    const Self = @This();

    /// Cached icons. lucide-demo, the largest measured user, draws 400.
    pub const entry_count_max: u32 = 4096;

    /// Maximum software rasterizations allowed per frame.
    ///
    /// Each rasterization costs ~0.5–2ms (parse SVG path, flatten curves,
    /// per-pixel stroke rendering at 48×48 device pixels). At 4 per frame
    /// that's ~2–8ms, leaving headroom for layout, GPU upload, and draw.
    ///
    /// A row of 16 icons progressively loads over 4 frames (~67ms) instead
    /// of stalling a single frame for 8–32ms of pure rasterization.
    const MAX_RASTERIZATIONS_PER_FRAME: u32 = 4;

    /// Scratch bytes reserved for icons of at most `icon_size_max` pixels
    /// within `budget`: exactly what the rasterizer reserves for one icon, so
    /// an icon within the budget never exhausts it. The software rasterizer
    /// (Linux, Windows) needs the parsed path, the flattened vertices, edge
    /// tables, and a stroke buffer; CoreGraphics needs only the parsed path
    /// and the stroke buffer; Canvas2D needs none.
    pub fn rasterScratchBytes(budget: rasterizer.RasterBudget, icon_size_max: u32) u32 {
        std.debug.assert(icon_size_max > 0);
        std.debug.assert(icon_size_max <= limits.MAX_SVG_ICON_SIZE);
        std.debug.assert(budget.path_bytes_max <= limits.MAX_SVG_PATH_BYTES);
        std.debug.assert(budget.vertex_count_max <= limits.MAX_SVG_PATH_VERTEX_COUNT);
        return rasterizer.scratchBytes(budget, icon_size_max);
    }

    comptime {
        // The ceiling's scratch must stay small next to the atlas textures:
        // 2.2 MiB against 144 MiB of ceiling textures.
        const ceiling = limits.AtlasLimits.ceiling;
        const budget = rasterizer.RasterBudget{
            .path_bytes_max = ceiling.svg_path_bytes_max,
            .vertex_count_max = ceiling.svg_path_vertex_count_max,
        };
        std.debug.assert(rasterScratchBytes(budget, ceiling.svg_icon_size_max) <= 4 * 1024 * 1024);
    }

    pub const Options = struct {
        /// `AtlasLimits.svg_size`.
        size: u32,
        /// `AtlasLimits.svg_icon_size_max`.
        icon_size_max: u32,
        /// `AtlasLimits.svg_path_bytes_max` and `svg_path_vertex_count_max`.
        raster_budget: rasterizer.RasterBudget,
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
        std.debug.assert(options.icon_size_max > 0);
        std.debug.assert(options.icon_size_max + 2 <= options.size);
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
        try self.cache.ensureTotalCapacity(entry_count_max);

        self.allocator = allocator;
        self.render_buffer_size = options.icon_size_max;
        self.raster_budget = options.raster_budget;
        self.scale_factor = scale_factor;
        self.io = io;
        self.mutex = .init;
        self.rasterizations_this_frame = 0;
        self.deferred_this_frame = false;
        std.debug.assert(self.cache.capacity() >= entry_count_max);
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
    /// If the per-frame rasterization budget or the upload staging is
    /// exhausted, returns `error.RasterizationDeferred` — the icon won't render
    /// this frame but will be picked up on the next frame.
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

        // Cache miss — check per-frame budget before doing expensive work.
        // This prevents a single frame from stalling on dozens of software
        // rasterizations when many uncached icons scroll into view at once.
        if (self.rasterizations_this_frame >= MAX_RASTERIZATIONS_PER_FRAME) {
            self.deferred_this_frame = true;
            return error.RasterizationDeferred;
        }

        // Rasterize at most `svg_icon_size_max` device pixels.
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
        /// Side in device pixels, at most `render_buffer_size`.
        device_size: u16,
        has_fill: bool,
        /// Logical stroke width; null or non-positive disables the stroke.
        stroke_width: ?f32,
    };

    /// Rasterize one icon into `render_buffer`, drawing every rasterizer
    /// allocation from `raster_scratch`. An icon that flattens to more than
    /// `svg_path_vertex_count_max` vertices is a capacity-planning error and
    /// fails fast naming the limit. Exhausting the scratch itself is a
    /// programmer error: it holds exactly what the rasterizer reserves.
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

    /// Fail fast on an icon path longer than `svg_path_bytes_max`.
    fn failPathBytes(self: *const Self, path_bytes: usize) noreturn {
        std.debug.assert(path_bytes > self.raster_budget.path_bytes_max);
        std.debug.panic(
            "SvgAtlas: an icon path of {d} B exceeds ResourceLimits.atlas.svg_path_bytes_max " ++
                "= {d}; raise it in the app's ResourceLimits (frame {d}).",
            .{ path_bytes, self.raster_budget.path_bytes_max, self.atlas.uploads.frameCurrent() },
        );
    }

    /// Fail fast on an icon that flattens past `svg_path_vertex_count_max`.
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

    /// Ensure `key` can be stored without growing the map: drop entries whose
    /// shelves were evicted, evicting the least recently used shelf if none
    /// were. A map full of icons used this frame fails fast.
    fn makeRoom(self: *Self, key: SvgKey) void {
        if (self.cache.contains(key)) return;
        if (self.cache.count() < entry_count_max) return;
        var attempt: usize = 0;
        while (attempt <= self.atlas.shelves.len) : (attempt += 1) {
            if (self.reclaimStale() > 0) return;
            if (!self.atlas.evictOne()) break;
        }
        std.debug.panic("SvgAtlas pool 'cache' exhausted: capacity {d}, {d} in use, " ++
            "1 requested, every icon used since frame {d}.", .{
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
};

/// Bump allocator over `SvgAtlas.raster_scratch` for one rasterization.
///
/// `FixedBufferAllocator.end_index` falls again whenever the newest allocation
/// is freed or shrunk, so after a rasterization it no longer shows how much
/// scratch was needed. This wrapper records the high-water mark after every
/// growth, and the size of the last request it refused so that exhaustion can
/// report it (CLAUDE.md §2). It adds two integers and never allocates.
const RasterScratch = struct {
    fixed: std.heap.FixedBufferAllocator,
    /// Highest `fixed.end_index` reached since `init`, alignment padding included.
    used_bytes_max: u32,
    /// Bytes asked for by the most recent refused alloc, resize, or remap; 0 if none.
    refused_bytes: u64,

    const FixedBufferAllocator = std.heap.FixedBufferAllocator;
    const Alignment = std.mem.Alignment;

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    /// `buffer` may be empty: Canvas2D rasterizes in the browser and
    /// reserves no scratch.
    fn init(buffer: []u8) RasterScratch {
        std.debug.assert(buffer.len <= std.math.maxInt(u32));
        if (buffer.len > 0) std.debug.assert(@intFromPtr(buffer.ptr) != 0);
        return .{ .fixed = .init(buffer), .used_bytes_max = 0, .refused_bytes = 0 };
    }

    /// The returned allocator points at `self`, which must not move while it is in use.
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

/// Whether `rasterizer.zig` selected the pure-Zig software rasterizer. The
/// struct type is unique to its declaring file, so this is an identity check
/// on the backend rather than a copy of its platform switch.
const raster_backend_software =
    rasterizer.RasterizedSvg == @import("backends/cairo.zig").RasterizedSvg;

test "RasterScratch keeps its peak across frees and reports the refused request" {
    // Fill a 64 B buffer in two steps, free the newest allocation so
    // `end_index` falls, then fill it exactly and ask for one byte more.
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

/// `loader_pinwheel`, the Lucide icon that flattens to the most vertices.
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
    // Filling and stroking `loader_pinwheel` at `MAX_SVG_ICON_SIZE` within
    // the standard profile's budget must fit the scratch that budget sizes,
    // and must produce coverage in both channels. Only the software
    // rasterizer flattens from the scratch.
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
    // `loader_pinwheel` flattens to 8,530 vertices at 256 px. With a budget
    // of 2,048 the software rasterizer must report PathTooComplex, the error
    // `SvgAtlas` turns into a panic naming `svg_path_vertex_count_max`, and
    // must not have been refused any scratch on the way.
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
    // A 64² atlas holds four 30 px icons, two per 32-row shelf. Frames 2-5
    // rasterize a, b (top shelf) and c, d (bottom shelf); frame 6 touches a
    // and adds e, which evicts the bottom shelf and lands where c was. Asking
    // for c again must re-rasterize c's own pixels, not return e's region.
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

    const svg_atlas = try testing.allocator.create(SvgAtlas);
    defer testing.allocator.destroy(svg_atlas);
    try svg_atlas.initInPlace(testing.allocator, 1.0, testing.io, .{
        .size = 64,
        .icon_size_max = 32,
        .raster_budget = testRasterBudget(limits.AtlasLimits.nano),
        .uploads = &uploads,
    });
    defer svg_atlas.deinit();

    // Distinct shapes with the same bounding box, so equal sizes but different pixels.
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
    // The top shelf was in use when e arrived, so a kept its pixels.
    const a = try Harness.icon(svg_atlas, paths[0]);
    const original_a = saved[0][0 .. @as(usize, placed[0].region.width) *
        placed[0].region.height * 4];
    try testing.expectEqualSlices(
        u8,
        original_a,
        Harness.copy(&svg_atlas.atlas, a.region, &current),
    );
}
