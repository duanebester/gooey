//! Fixed-size texture atlas with shelf packing and LRU shelf eviction.
//!
//! An atlas is a square texture of a side fixed by `AtlasLimits` and reserved at
//! initialization (CLAUDE.md §2). It never grows. Items are packed left to right
//! into full-width horizontal shelves whose heights are multiples of
//! `shelf_height_quantum`. When no shelf has room and no free space remains, the
//! atlas evicts whole shelves, least recently used first, until the item fits.
//!
//! Eviction policy, deterministic and bounded by the shelf count:
//! 1. Only active shelves are candidates. A shelf is protected while an item
//!    in it was used at or after `AtlasUploads.frameProtectedLocked` (the
//!    current frame, or an older frame a window has not uploaded yet), or while
//!    a renderer has not yet uploaded a record written into it.
//! 2. Dead shelves (condemned by `clear`) go first, then the smallest
//!    `frame_used`, then the lowest `y`.
//! 3. An evicted shelf becomes free space and merges with free neighbours.
//!
//! Placement prefers a shelf of the item's own height, then a shelf already
//! protected this frame (at most twice as tall), then new free space, then a
//! protected shelf grown into the free rows below it, and only then evicts.
//! A small item is never parked in an old, taller shelf while
//! eviction can still make room, because that would protect the whole shelf.
//!
//! Each shelf carries a generation that increases whenever the shelf stops
//! being active or is condemned. Caches store `(shelf, generation)` with every
//! entry and treat an entry whose shelf generation changed as a miss, so a
//! cached glyph, icon, or image never points at evicted pixels.
//!
//! An item larger than the atlas, or a frame whose protected items leave no
//! room, panics with the atlas name, capacity, request, and frame.
//!
//! Every item is written with a zeroed 1 px border on all four sides, inside
//! its own reservation. Bilinear sampling one texel past an item therefore
//! always reads zero, without zeroing the texture at init or after eviction.
//!
//! Pixels: `.cpu_texture` atlases own `data`, the CPU renderer's texture.
//! `.gpu_upload` atlases own no pixels; each item is staged in `AtlasUploads`.
//!
//! Resource sketch (CLAUDE.md §7): shelf slots are `size / 4` × 32 B (32 KiB at
//! 4096). A placement scans at most every slot once per eviction, and evicts
//! at most every shelf, so worst-case work is O(slots²) = 1M steps at 4096,
//! paid only when an atlas is full. Typical placements append to a matching
//! shelf after one O(slots) scan.

const std = @import("std");
const assert = std.debug.assert;

const reservation = @import("../core/reservation.zig");
const uploads_mod = @import("atlas_uploads.zig");
pub const AtlasUploads = uploads_mod.AtlasUploads;
pub const AtlasKind = uploads_mod.AtlasKind;
pub const AtlasStorage = uploads_mod.AtlasStorage;

/// UV coordinates for texture sampling
pub const UVCoords = struct {
    u0: f32,
    v0: f32,
    u1: f32,
    v1: f32,
};

/// A region within the atlas
pub const Region = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,

    pub fn uv(self: Region, atlas_size: u32) UVCoords {
        const size_f: f32 = @floatFromInt(atlas_size);
        return .{
            .u0 = @as(f32, @floatFromInt(self.x)) / size_f,
            .v0 = @as(f32, @floatFromInt(self.y)) / size_f,
            .u1 = @as(f32, @floatFromInt(self.x + self.width)) / size_f,
            .v1 = @as(f32, @floatFromInt(self.y + self.height)) / size_f,
        };
    }
};

/// Texture atlas format
pub const Format = enum {
    /// Single channel (grayscale text)
    grayscale,
    /// RGBA (color emoji, subpixel rendering)
    rgba,

    pub fn bytesPerPixel(self: Format) u8 {
        return switch (self) {
            .grayscale => 1,
            .rgba => 4,
        };
    }
};

/// Where an item landed. Caches keep `shelf` and `generation` to validate it.
pub const Placement = struct {
    region: Region,
    shelf: u16,
    generation: u32,
};

/// Shelf index for items that occupy no atlas space (spaces, empty glyphs).
pub const shelf_none: u16 = std.math.maxInt(u16);

/// Shelf heights are rounded up to this many rows so similar items share shelves.
pub const shelf_height_quantum: u32 = 4;

/// Zero border written around every item, in pixels per side.
pub const item_border: u32 = 1;

pub const Atlas = struct {
    allocator: std.mem.Allocator,
    kind: AtlasKind,
    format: Format,
    /// Side in pixels; fixed for the atlas's lifetime.
    size: u32,
    storage: AtlasStorage,
    /// `size × size × bpp` pixels for `.cpu_texture`, from `reservation`; empty
    /// for `.gpu_upload`. Fresh pages read zero and stay non-resident until an
    /// item is written; only item rectangles and their borders are read.
    data: []u8,
    /// One past the lowest pixel row ever written to `data`: the reservation's
    /// high-water mark, zeroed on release (CLAUDE.md §21).
    data_rows_written_end: u32,
    /// Shelf slots; a slot index is a stable shelf identity.
    shelves: []Shelf,
    uploads: *AtlasUploads,
    /// Rows covered by active shelves, and their peak (occupancy reporting).
    rows_active: u32,
    rows_active_peak: u32,

    const Self = @This();

    const Shelf = struct {
        /// Frame in which an item in this shelf was last placed or used.
        frame_used: u64,
        /// Journal sequence after this shelf's newest staged record.
        sequence_end: u64,
        /// Increases whenever the shelf stops being active or is condemned.
        generation: u32,
        y: u16,
        height: u16,
        /// Next free column of an active shelf.
        x_cursor: u16,
        state: State,
        /// Condemned by `clear`: no live items remain, so evict it first.
        dead: bool,

        const State = enum(u8) { unused, free, active };
    };

    pub const Options = struct {
        kind: AtlasKind,
        /// Side in pixels, from `AtlasLimits`.
        size: u32,
        uploads: *AtlasUploads,
    };

    /// Reserve the shelf table and, for the CPU renderer, the pixel store.
    pub fn init(self: *Self, allocator: std.mem.Allocator, options: Options) !void {
        assert(options.size >= 64);
        assert(options.size <= std.math.maxInt(u16));
        assert(options.size % shelf_height_quantum == 0);
        const format: Format = if (options.kind == .text) .grayscale else .rgba;
        const storage = options.uploads.storage;
        self.data = if (storage == .cpu_texture)
            try reservation.reserve(u8, options.size * options.size * format.bytesPerPixel())
        else
            &.{};
        errdefer if (storage == .cpu_texture) reservation.release(u8, self.data, 0);
        self.data_rows_written_end = 0;
        self.shelves = try allocator.alloc(Shelf, options.size / shelf_height_quantum);

        self.allocator = allocator;
        self.kind = options.kind;
        self.format = format;
        self.size = options.size;
        self.storage = storage;
        self.uploads = options.uploads;
        self.rows_active = 0;
        self.rows_active_peak = 0;
        self.resetShelves();
        assert(self.shelves[0].state == .free);
        assert(self.shelves[0].height == self.size);
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.shelves);
        if (self.storage == .cpu_texture) {
            assert(self.data_rows_written_end <= self.size);
            const row_bytes = @as(usize, self.size) * self.format.bytesPerPixel();
            reservation.release(u8, self.data, self.data_rows_written_end * row_bytes);
        }
        self.* = undefined;
    }

    /// One free shelf spanning the atlas; every other slot unused.
    fn resetShelves(self: *Self) void {
        for (self.shelves) |*shelf| {
            shelf.* = .{
                .frame_used = 0,
                .sequence_end = 0,
                .generation = 0,
                .y = 0,
                .height = 0,
                .x_cursor = 0,
                .state = .unused,
                .dead = false,
            };
        }
        self.shelves[0].state = .free;
        self.shelves[0].height = @intCast(self.size);
        self.rows_active = 0;
    }

    /// Whether a placement still refers to live pixels. Inline: it runs on
    /// every glyph cache hit, so it compares the generation alone. That is
    /// exact because a placement's generation is read while its shelf is
    /// active and alive, and every way out of that state (`evict`, `clear`)
    /// bumps the generation before the slot can be merged, reused, or
    /// reactivated. The state checks below are that proof, asserted.
    pub inline fn isLive(self: *const Self, shelf: u16, generation: u32) bool {
        if (shelf == shelf_none) return true;
        assert(shelf < self.shelves.len);
        const entry = &self.shelves[shelf];
        if (entry.generation != generation) return false;
        assert(entry.state == .active);
        assert(!entry.dead);
        return true;
    }

    /// Mark a live placement's shelf as used in `frame`, which the caller read
    /// from `uploads.frameCurrent()`. A batch reads it once rather than per
    /// item; any frame at or after the caller's own open frame keeps the shelf
    /// protected for that frame. Most hits land on a shelf already stamped
    /// this frame, so the store is skipped. No assertion re-reads the clock:
    /// an atomic load survives ReleaseFast even when only an assert uses it.
    pub inline fn touch(self: *Self, shelf: u16, frame: u64) void {
        if (shelf == shelf_none) return;
        assert(shelf < self.shelves.len);
        assert(frame > 0);
        const entry = &self.shelves[shelf];
        assert(entry.state == .active);
        if (entry.frame_used < frame) entry.frame_used = frame;
    }

    /// Place a `width × height` item and write its pixels with a zero border.
    /// Returns null when this frame's upload staging is full; the caller skips
    /// the item and the frame renders again. Panics when the item cannot fit.
    pub fn insert(self: *Self, width: u32, height: u32, pixels: []const u8) ?Placement {
        assert(width > 0);
        assert(height > 0);
        assert(pixels.len >= @as(usize, width) * height * self.format.bytesPerPixel());
        const outer_width = width + 2 * item_border;
        const outer_height = height + 2 * item_border;
        if (outer_width > self.size or outer_height > self.size) {
            self.panicItemTooLarge(outer_width, outer_height);
        }

        self.uploads.lock();
        defer self.uploads.unlock();
        if (self.storage == .gpu_upload) {
            if (!self.uploads.reserveLocked(self.kind, outer_width, outer_height)) return null;
        }
        const placement = self.place(width, height);
        self.writeItem(placement, pixels);
        assert(self.isLive(placement.shelf, placement.generation));
        return placement;
    }

    /// Evict the least recently used unprotected shelf, for caches whose entry
    /// table is full. Returns false when every shelf is protected.
    pub fn evictOne(self: *Self) bool {
        self.uploads.lock();
        defer self.uploads.unlock();
        const victim = self.evictionCandidate() orelse return false;
        self.evict(victim);
        return true;
    }

    /// Condemn every item: placements stop validating at once, and the space
    /// is reclaimed by eviction once no open frame or pending upload needs it.
    pub fn clear(self: *Self) void {
        for (self.shelves) |*shelf| {
            if (shelf.state != .active) continue;
            shelf.generation +%= 1;
            shelf.dead = true;
            shelf.x_cursor = @intCast(self.size);
        }
    }

    /// Pixel store of a `.cpu_texture` atlas.
    pub fn getData(self: *const Self) []const u8 {
        assert(self.storage == .cpu_texture);
        assert(self.data.len == @as(usize, self.size) * self.size * self.format.bytesPerPixel());
        return self.data;
    }

    // =========================================================================
    // Placement
    // =========================================================================

    /// Find room for a `width × height` item and its border, evicting as
    /// needed. Caller holds the uploads mutex.
    fn place(self: *Self, width: u32, height: u32) Placement {
        const outer_width = width + 2 * item_border;
        const outer_height = height + 2 * item_border;
        const shelf_height = roundUpQuantum(outer_height);
        var attempt: usize = 0;
        while (attempt <= self.shelves.len) : (attempt += 1) {
            if (self.findShelf(outer_width, outer_height, shelf_height)) |slot| {
                return self.append(slot, width, height);
            }
            const victim = self.evictionCandidate() orelse break;
            self.evict(victim);
        }
        // Every unprotected shelf is gone, so any remaining shelf is protected
        // already: a taller one, or one grown into free rows, pins nothing new.
        const taller: ShelfQuery = .{ .height_min = outer_height, .height_max = self.size };
        const slot = self.findActiveShelf(outer_width, taller) orelse
            self.growShelf(outer_width, shelf_height, 0) orelse
            self.panicLiveSetDoesNotFit(outer_width, outer_height);
        return self.append(slot, width, height);
    }

    /// A shelf with room, in order: an active shelf of exactly `shelf_height`;
    /// a protected shelf at most twice as tall, which pins nothing new; a new
    /// shelf cut from free space; a protected shelf grown into the free space
    /// below it. Placing an item in an older, taller shelf would protect that
    /// whole shelf for one small item, so it waits until eviction has nothing
    /// else to offer.
    fn findShelf(self: *Self, outer_width: u32, outer_height: u32, shelf_height: u32) ?u16 {
        assert(shelf_height >= outer_height);
        assert(shelf_height <= self.size);
        const exact: ShelfQuery = .{ .height_min = shelf_height, .height_max = shelf_height };
        if (self.findActiveShelf(outer_width, exact)) |slot| return slot;
        const frame_protected = self.uploads.frameProtectedLocked();
        const pinned: ShelfQuery = .{
            .height_min = outer_height,
            .height_max = @min(self.size, 2 * shelf_height),
            .frame_used_min = frame_protected,
        };
        if (self.findActiveShelf(outer_width, pinned)) |slot| return slot;
        if (self.openShelf(shelf_height)) |slot| return slot;
        return self.growShelf(outer_width, shelf_height, frame_protected);
    }

    /// Grow the active shelf with `outer_width` columns left that needs the
    /// fewest extra rows to reach `shelf_height`, taking them from the free
    /// shelf directly below. Items keep their rows, so their regions stay valid.
    /// Only shelves used at or after `frame_used_min` qualify.
    fn growShelf(self: *Self, outer_width: u32, shelf_height: u32, frame_used_min: u64) ?u16 {
        assert(shelf_height <= self.size);
        var best: ?u16 = null;
        var best_below: u16 = 0;
        for (self.shelves, 0..) |*shelf, index| {
            if (shelf.state != .active) continue;
            if (shelf.height >= shelf_height) continue;
            if (shelf.frame_used < frame_used_min) continue;
            if (self.size - shelf.x_cursor < outer_width) continue;
            const below = self.freeNeighbour(shelf.y + shelf.height, .below) orelse continue;
            if (self.shelves[below].height < shelf_height - shelf.height) continue;
            if (best) |b| {
                if (shelf.height <= self.shelves[b].height) continue;
            }
            best = @intCast(index);
            best_below = below;
        }
        const slot = best orelse return null;
        const shelf = &self.shelves[slot];
        const free = &self.shelves[best_below];
        const rows: u16 = @intCast(shelf_height - shelf.height);
        assert(free.y == shelf.y + shelf.height);
        shelf.height += rows;
        free.y += rows;
        free.height -= rows;
        if (free.height == 0) free.state = .unused;
        self.rows_active += rows;
        self.rows_active_peak = @max(self.rows_active_peak, self.rows_active);
        assert(self.rows_active <= self.size);
        return slot;
    }

    const ShelfQuery = struct {
        height_min: u32,
        height_max: u32,
        /// Only shelves last used at or after this frame qualify.
        frame_used_min: u64 = 0,
    };

    /// Shortest active shelf matching `query` with `outer_width` columns left;
    /// ties go to the lowest `y`.
    fn findActiveShelf(self: *const Self, outer_width: u32, query: ShelfQuery) ?u16 {
        assert(query.height_min <= query.height_max);
        var best: ?u16 = null;
        for (self.shelves, 0..) |*shelf, index| {
            if (shelf.state != .active) continue;
            if (shelf.height < query.height_min) continue;
            if (shelf.height > query.height_max) continue;
            if (shelf.frame_used < query.frame_used_min) continue;
            if (self.size - shelf.x_cursor < outer_width) continue;
            if (best) |b| {
                const current = &self.shelves[b];
                if (shelf.height > current.height) continue;
                if (shelf.height == current.height and shelf.y > current.y) continue;
            }
            best = @intCast(index);
        }
        return best;
    }

    /// Cut a `shelf_height` active shelf from the top of the shortest free
    /// shelf that holds it (lowest `y` on ties).
    fn openShelf(self: *Self, shelf_height: u32) ?u16 {
        var best: ?u16 = null;
        for (self.shelves, 0..) |*shelf, index| {
            if (shelf.state != .free) continue;
            if (shelf.height < shelf_height) continue;
            if (best) |b| {
                const current = &self.shelves[b];
                if (shelf.height > current.height) continue;
                if (shelf.height == current.height and shelf.y > current.y) continue;
            }
            best = @intCast(index);
        }
        const slot = best orelse return null;
        const free = &self.shelves[slot];
        if (free.height > shelf_height) {
            const rest = self.unusedSlot();
            self.shelves[rest].state = .free;
            self.shelves[rest].y = free.y + @as(u16, @intCast(shelf_height));
            self.shelves[rest].height = free.height - @as(u16, @intCast(shelf_height));
        }
        free.height = @intCast(shelf_height);
        free.state = .active;
        free.dead = false;
        free.x_cursor = 0;
        free.frame_used = 0;
        free.sequence_end = 0;
        self.rows_active += shelf_height;
        self.rows_active_peak = @max(self.rows_active_peak, self.rows_active);
        assert(self.rows_active <= self.size);
        return slot;
    }

    /// Claim the next `width + 2` columns of `slot`. The returned region is the
    /// item itself, inset by the border.
    fn append(self: *Self, slot: u16, width: u32, height: u32) Placement {
        const shelf = &self.shelves[slot];
        const outer_width = width + 2 * item_border;
        assert(shelf.state == .active);
        assert(self.size - shelf.x_cursor >= outer_width);
        assert(height + 2 * item_border <= shelf.height);
        const x = shelf.x_cursor + item_border;
        shelf.x_cursor += @intCast(outer_width);
        shelf.frame_used = self.uploads.frameCurrent();
        return .{
            .region = .{
                .x = @intCast(x),
                .y = @intCast(shelf.y + item_border),
                .width = @intCast(width),
                .height = @intCast(height),
            },
            .shelf = slot,
            .generation = shelf.generation,
        };
    }

    /// The shelf to evict next, or null when every active shelf is protected.
    fn evictionCandidate(self: *const Self) ?u16 {
        const frame_protected = self.uploads.frameProtectedLocked();
        const sequence_retired = self.uploads.sequenceRetiredLocked();
        var best: ?u16 = null;
        for (self.shelves, 0..) |*shelf, index| {
            if (shelf.state != .active) continue;
            if (shelf.frame_used >= frame_protected) continue;
            if (shelf.sequence_end > sequence_retired) continue;
            if (best) |b| {
                if (!evictsBefore(shelf, &self.shelves[b])) continue;
            }
            best = @intCast(index);
        }
        return best;
    }

    /// Dead shelves first, then least recently used, then lowest `y`.
    fn evictsBefore(a: *const Shelf, b: *const Shelf) bool {
        assert(a.state == .active);
        assert(b.state == .active);
        if (a.dead != b.dead) return a.dead;
        if (a.frame_used != b.frame_used) return a.frame_used < b.frame_used;
        return a.y < b.y;
    }

    /// Free an active shelf and merge it with free neighbours.
    fn evict(self: *Self, slot: u16) void {
        const shelf = &self.shelves[slot];
        assert(shelf.state == .active);
        assert(self.rows_active >= shelf.height);
        self.rows_active -= shelf.height;
        shelf.generation +%= 1;
        shelf.state = .free;
        shelf.dead = false;
        shelf.x_cursor = 0;
        var merged = slot;
        if (self.freeNeighbour(self.shelves[merged].y, .above)) |above| {
            self.shelves[above].height += self.shelves[merged].height;
            self.shelves[merged].state = .unused;
            merged = above;
        }
        const end = self.shelves[merged].y + self.shelves[merged].height;
        if (self.freeNeighbour(end, .below)) |below| {
            self.shelves[merged].height += self.shelves[below].height;
            self.shelves[below].state = .unused;
        }
        assert(self.shelves[merged].state == .free);
    }

    /// The free shelf ending at `edge` (`.above`) or starting at it (`.below`).
    fn freeNeighbour(self: *const Self, edge: u32, side: enum { above, below }) ?u16 {
        assert(edge <= self.size);
        for (self.shelves, 0..) |*shelf, index| {
            if (shelf.state != .free) continue;
            const matches = switch (side) {
                .above => shelf.y + shelf.height == edge,
                .below => shelf.y == edge,
            };
            if (matches) return @intCast(index);
        }
        return null;
    }

    fn unusedSlot(self: *const Self) u16 {
        for (self.shelves, 0..) |*shelf, index| {
            if (shelf.state == .unused) return @intCast(index);
        }
        // Shelves partition the atlas in multiples of the quantum, so at most
        // `size / quantum` slots are ever in use; a split needs one more only
        // when a used slot is at least two quanta tall.
        unreachable;
    }

    // =========================================================================
    // Pixels
    // =========================================================================

    /// Write the item and its zero border into the pixel store or the journal.
    fn writeItem(self: *Self, placement: Placement, pixels: []const u8) void {
        const region = placement.region;
        assert(region.x >= item_border);
        assert(region.y >= item_border);
        const item: Item = .{
            .width = region.width,
            .height = region.height,
            .bpp = self.format.bytesPerPixel(),
        };
        const outer_x = region.x - item_border;
        const outer_y = region.y - item_border;
        switch (self.storage) {
            .cpu_texture => {
                const stride = @as(usize, self.size) * item.bpp;
                const origin = (@as(usize, outer_y) * self.size + outer_x) * item.bpp;
                writeBordered(self.data[origin..], stride, pixels, item);
                const rows_end = outer_y + region.height + 2 * item_border;
                assert(rows_end <= self.size);
                self.data_rows_written_end = @max(self.data_rows_written_end, rows_end);
            },
            .gpu_upload => {
                const outer_width = region.width + 2 * item_border;
                const staged = self.uploads.stageLocked(.{
                    .offset = 0,
                    .x = @intCast(outer_x),
                    .y = @intCast(outer_y),
                    .width = @intCast(outer_width),
                    .height = @intCast(region.height + 2 * item_border),
                    .kind = self.kind,
                }) orelse return;
                writeBordered(staged, @as(usize, outer_width) * item.bpp, pixels, item);
                self.shelves[placement.shelf].sequence_end = self.uploads.sequenceEnd();
            },
        }
    }

    const Item = struct { width: u32, height: u32, bpp: u32 };

    /// Fill a `(width + 2) × (height + 2)` rectangle of `target` with rows of
    /// `stride` bytes: zero border, item pixels inside.
    fn writeBordered(target: []u8, stride: usize, pixels: []const u8, item: Item) void {
        const outer_row = (@as(usize, item.width) + 2) * item.bpp;
        const inner_row = @as(usize, item.width) * item.bpp;
        const border = item.bpp;
        assert(stride >= outer_row);
        assert(target.len >= stride * (item.height + 1) + outer_row);
        @memset(target[0..outer_row], 0);
        var row: usize = 0;
        while (row < item.height) : (row += 1) {
            const line = target[(row + 1) * stride ..][0..outer_row];
            @memset(line[0..border], 0);
            @memcpy(line[border..][0..inner_row], pixels[row * inner_row ..][0..inner_row]);
            @memset(line[border + inner_row ..], 0);
        }
        @memset(target[(item.height + 1) * stride ..][0..outer_row], 0);
    }

    // =========================================================================
    // Fail fast
    // =========================================================================

    fn panicItemTooLarge(self: *const Self, outer_width: u32, outer_height: u32) noreturn {
        std.debug.panic("Atlas pool '{t}' cannot hold one item: capacity {d}x{d} px, " ++
            "requested {d}x{d} px (1 px border included), frame {d}.", .{
            self.kind,                   self.size, self.size, outer_width, outer_height,
            self.uploads.frameCurrent(),
        });
    }

    fn panicLiveSetDoesNotFit(self: *const Self, outer_width: u32, outer_height: u32) noreturn {
        std.debug.panic("Atlas pool '{t}' exhausted: capacity {d}x{d} px, {d} rows held " ++
            "by items in use since frame {d}, requested {d}x{d} px (1 px border included), " ++
            "frame {d}.", .{
            self.kind,
            self.size,
            self.size,
            self.rows_active,
            self.uploads.frameProtectedLocked(),
            outer_width,
            outer_height,
            self.uploads.frameCurrent(),
        });
    }
};

fn roundUpQuantum(value: u32) u32 {
    assert(value > 0);
    return std.mem.alignForward(u32, value, shelf_height_quantum);
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

/// A 64×64 atlas whose 62×14 test items each fill one 16-row shelf, so the
/// atlas holds exactly four. Consumer 1 stands in for a renderer.
const TestAtlas = struct {
    uploads: AtlasUploads,
    atlas: Atlas,

    const item_width: u32 = 62;
    const item_height: u32 = 14;
    const consumer: usize = 1;

    fn init(self: *TestAtlas, kind: AtlasKind, storage: AtlasStorage) !void {
        try self.uploads.init(testing.allocator, testing.io, .{
            .storage = storage,
            .upload_bytes_frame_max = 64 * 64 * 4,
        });
        errdefer self.uploads.deinit();
        self.uploads.registerConsumer(consumer);
        errdefer self.uploads.unregisterConsumer(consumer);
        try self.atlas.init(
            testing.allocator,
            .{ .kind = kind, .size = 64, .uploads = &self.uploads },
        );
        assert(self.atlas.shelves[0].height == 64);
    }

    fn deinit(self: *TestAtlas) void {
        self.atlas.deinit();
        self.uploads.unregisterConsumer(consumer);
        self.uploads.deinit();
    }

    /// Begin a frame and upload it at once, so only the new frame is protected.
    fn frame(self: *TestAtlas) void {
        _ = self.uploads.beginFrame(consumer);
        _ = self.uploads.consumeBegin(consumer);
        self.uploads.consumeEnd(consumer);
    }

    /// Insert one test item filled with `value`.
    fn item(self: *TestAtlas, value: u8) Placement {
        var pixels: [item_width * item_height * 4]u8 = undefined;
        @memset(&pixels, value);
        return self.atlas.insert(item_width, item_height, &pixels).?;
    }

    fn live(self: *const TestAtlas, placement: Placement) bool {
        return self.atlas.isLive(placement.shelf, placement.generation);
    }

    /// Pixel at `(x, y)` of a `.cpu_texture` grayscale atlas.
    fn pixel(self: *const TestAtlas, x: u32, y: u32) u8 {
        return self.atlas.getData()[y * self.atlas.size + x];
    }
};

test "atlas evicts the least recently used shelf, lowest y on ties" {
    // Four shelves filled in frames 2-5 hold a, b, c, d. Touching a in frame 6
    // makes b the oldest, then c, then d. Once a and e share frame 6, the tie
    // goes to a, the lower shelf. A FIFO or lowest-y policy fails at e or f.
    var t: TestAtlas = undefined;
    try t.init(.text, .cpu_texture);
    defer t.deinit();

    var placements: [4]Placement = undefined;
    for (&placements, 0..) |*placement, index| {
        t.frame();
        placement.* = t.item(@intCast(10 + index));
    }
    const a, const b, const c, const d = placements;
    try testing.expectEqual(@as(u32, 64), t.atlas.rows_active);

    t.frame();
    t.atlas.touch(a.shelf, t.atlas.uploads.frameCurrent());
    const e = t.item(20);
    try testing.expectEqual(b.region.y, e.region.y);
    try testing.expect(!t.live(b));
    try testing.expect(t.live(a) and t.live(c) and t.live(d));

    t.frame();
    const f = t.item(21);
    try testing.expectEqual(c.region.y, f.region.y);
    t.frame();
    const g = t.item(22);
    try testing.expectEqual(d.region.y, g.region.y);

    // a and e were both last used in frame 6; a has the lower y.
    t.frame();
    const h = t.item(23);
    try testing.expectEqual(a.region.y, h.region.y);
    try testing.expect(t.live(e) and t.live(f) and t.live(g) and t.live(h));
    try testing.expect(!t.live(a));

    // The new item's pixels replaced a's, and its border reads zero.
    try testing.expectEqual(@as(u8, 23), t.pixel(h.region.x, h.region.y));
    try testing.expectEqual(@as(u8, 0), t.pixel(h.region.x - 1, h.region.y));
    try testing.expectEqual(@as(u8, 0), t.pixel(h.region.x, h.region.y - 1));
    try testing.expectEqual(@as(u8, 0), t.pixel(h.region.x, h.region.y + h.region.height));
}

test "atlas never evicts an item used this frame or awaiting upload" {
    // Items placed in frame 2 and touched in frame 3 are all protected in
    // frame 3; in frame 4 they are not. In a GPU atlas, items whose records no
    // renderer has uploaded stay protected however many frames pass.
    var t: TestAtlas = undefined;
    try t.init(.text, .cpu_texture);
    defer t.deinit();
    t.frame();
    var placements: [4]Placement = undefined;
    for (&placements, 0..) |*placement, index| placement.* = t.item(@intCast(index + 1));
    t.frame();
    const frame = t.atlas.uploads.frameCurrent();
    for (placements) |placement| t.atlas.touch(placement.shelf, frame);
    try testing.expect(!t.atlas.evictOne());
    t.frame();
    try testing.expect(t.atlas.evictOne());
    try testing.expect(!t.live(placements[0]));
    try testing.expect(t.live(placements[1]));

    var g: TestAtlas = undefined;
    try g.init(.text, .gpu_upload);
    defer g.deinit();
    g.frame();
    for (&placements, 0..) |*placement, index| placement.* = g.item(@intCast(index + 1));
    // The renderer begins frames but never uploads: nothing may be evicted.
    var frame_index: u32 = 0;
    while (frame_index < 3) : (frame_index += 1) _ = g.uploads.beginFrame(TestAtlas.consumer);
    try testing.expect(!g.atlas.evictOne());
    const pending = g.uploads.consumeBegin(TestAtlas.consumer);
    try testing.expectEqual(@as(usize, 4), pending.records.len);
    try testing.expectEqual(@as(u16, 64), pending.records[0].width);
    try testing.expectEqual(@as(u16, 16), pending.records[0].height);
    g.uploads.consumeEnd(TestAtlas.consumer);
    g.frame();
    try testing.expect(g.atlas.evictOne());
}

test "atlas clear condemns every item and reuses its space" {
    // After `clear`, no placement validates, yet four more items still fit:
    // the condemned shelves are evicted to make room instead of panicking.
    var t: TestAtlas = undefined;
    try t.init(.text, .cpu_texture);
    defer t.deinit();
    t.frame();
    var placements: [4]Placement = undefined;
    for (&placements, 0..) |*placement, index| placement.* = t.item(@intCast(index + 1));
    t.atlas.clear();
    for (placements) |placement| try testing.expect(!t.live(placement));
    t.frame();
    for (&placements, 0..) |*placement, index| placement.* = t.item(@intCast(index + 5));
    for (placements) |placement| try testing.expect(t.live(placement));
    try testing.expectEqual(@as(u32, 64), t.atlas.rows_active);
}

test "atlas grows a shelf into the free rows below it" {
    // Three full 16-row shelves and a 12-row shelf leave 4 free rows at the
    // bottom. A 14-row item fits no shelf and no free region, but the 12-row
    // shelf can take the 4 rows below it, so the item lands beside the first.
    var t: TestAtlas = undefined;
    try t.init(.text, .cpu_texture);
    defer t.deinit();
    t.frame();
    var index: u8 = 0;
    while (index < 3) : (index += 1) _ = t.item(index + 1);
    var pixels: [30 * 12]u8 = @splat(9);
    const short = t.atlas.insert(30, 10, &pixels).?;
    try testing.expectEqual(@as(u32, 60), t.atlas.rows_active);
    const tall = t.atlas.insert(30, 12, &pixels).?;
    try testing.expectEqual(short.shelf, tall.shelf);
    try testing.expectEqual(short.region.y, tall.region.y);
    try testing.expectEqual(short.region.x + 32, tall.region.x);
    try testing.expectEqual(@as(u32, 64), t.atlas.rows_active);
    try testing.expect(t.live(short) and t.live(tall));
}
