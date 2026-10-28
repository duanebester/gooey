//! Atlas upload journal and frame clock, shared by the glyph, SVG, and image atlases.
//!
//! GPU backends keep no CPU copy of atlas pixels (memory-budget decision 8).
//! When an atlas places a rasterized item, it writes the item's pixels, with a
//! zeroed 1 px border, into this journal. Every renderer that draws from the
//! atlases is a registered consumer: each frame it copies the records it has not
//! yet seen into its own staging and uploads them before it draws. A record is
//! retired once every consumer has consumed it.
//!
//! The journal also owns the atlas frame clock. A consumer's frame is open from
//! `beginFrame` until its `consumeEnd`, while its scene still references atlas
//! regions the GPU has not received. Atlases never evict a shelf used at or
//! after the oldest open frame, nor one whose records a consumer still has to
//! upload, so no region is overwritten while a pending scene or upload needs it.
//!
//! Resource sketch (CLAUDE.md §7), `.standard`: `bytes` is
//! `upload_bytes_frame_max` (1 MiB) and `records` 16,384 × 16 B (256 KiB). Both
//! are reserved at init and touched only up to the peak per-frame upload. A
//! frame that would stage more defers the remaining items to the next frame.
//! The CPU renderer's atlases are their own textures, so it reserves neither.
//!
//! Locking: an atlas holds its cache's mutex and then this journal's mutex.
//! Consumers and `beginFrame` take only this mutex, so the order is acyclic.

const std = @import("std");
const assert = std.debug.assert;

/// Which atlas a record targets. Also the atlas name in fail-fast messages.
pub const AtlasKind = enum(u8) {
    text,
    svg,
    image,

    pub fn bytesPerPixel(self: AtlasKind) u32 {
        return switch (self) {
            .text => 1,
            .svg, .image => 4,
        };
    }
};

/// Where atlas pixels live.
pub const AtlasStorage = enum {
    /// The atlas pixels are the texture, in CPU memory (CPU renderer).
    cpu_texture,
    /// A GPU texture holds the only full copy; pixels travel through the journal.
    gpu_upload,
};

/// One staged rectangle: tightly packed rows of `width × bytesPerPixel(kind)`
/// bytes starting at `offset` in `Pending.bytes`.
pub const Upload = struct {
    offset: u32,
    x: u16,
    y: u16,
    width: u16,
    height: u16,
    kind: AtlasKind,

    pub fn byteCount(self: Upload) u32 {
        return @as(u32, self.width) * self.height * self.kind.bytesPerPixel();
    }
};

/// The records a consumer has not yet uploaded. Valid until `consumeEnd`.
pub const Pending = struct {
    records: []const Upload,
    bytes: []const u8,
};

/// Bound on registered consumers: one per window (multi-window registry bound).
pub const consumer_count_max: u32 = 32;

/// Record offsets are 4-byte aligned: Vulkan buffer-to-image copies and Metal
/// blits require offsets aligned to the 4-byte RGBA texel.
pub const record_alignment: u32 = 4;

/// wasm32 has no 64-bit atomics, and the web build runs on one thread, so the
/// frame clock is read and written plainly there.
const frame_atomic = @sizeOf(usize) >= 8;

/// Smallest staged item a record budget is sized for: a 6×6 R8 glyph with its
/// border. Smaller items share the budget with larger ones, so the bound holds.
const record_bytes_min: u32 = 64;

pub const AtlasUploads = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex,
    storage: AtlasStorage,

    /// Staged pixels; empty for `.cpu_texture`.
    bytes: []u8,
    /// Staged records; empty for `.cpu_texture`.
    records: []Upload,
    byte_count: u32,
    record_count: u32,
    /// Journal sequence of `records[0]`. Sequences count records ever staged.
    sequence_base: u64,

    consumers: [consumer_count_max]Consumer,
    consumer_count: u32,

    /// Atlas frame clock. Advanced by every consumer's `beginFrame`; read by
    /// atlases without the mutex, so it is accessed atomically.
    frame: u64,
    /// Latest frame in which a stage request was refused for lack of space.
    frame_deferred: u64,

    const Self = @This();

    const Consumer = struct {
        /// Renderer identity; 0 marks a free slot.
        key: usize,
        /// Journal sequence of the next record this consumer uploads.
        sequence_next: u64,
        /// Frame opened by `beginFrame`, or 0 when its scene has been uploaded.
        frame_open: u64,
    };

    pub const Options = struct {
        storage: AtlasStorage,
        /// `AtlasLimits.upload_bytes_frame_max`.
        upload_bytes_frame_max: u32,
    };

    /// Reserve the journal. Pages are not written here, so they become resident
    /// only as uploads touch them.
    pub fn init(self: *Self, allocator: std.mem.Allocator, io: std.Io, options: Options) !void {
        assert(options.upload_bytes_frame_max >= record_bytes_min);
        const staged = options.storage == .gpu_upload;
        const byte_capacity: u32 = if (staged) options.upload_bytes_frame_max else 0;
        const record_capacity: u32 = byte_capacity / record_bytes_min;

        self.bytes = try allocator.alloc(u8, byte_capacity);
        errdefer allocator.free(self.bytes);
        self.records = try allocator.alloc(Upload, record_capacity);

        self.allocator = allocator;
        self.io = io;
        self.mutex = .init;
        self.storage = options.storage;
        self.byte_count = 0;
        self.record_count = 0;
        self.sequence_base = 0;
        self.consumers = @splat(.{ .key = 0, .sequence_next = 0, .frame_open = 0 });
        self.consumer_count = 0;
        self.frame = 1;
        self.frame_deferred = 0;
        assert(self.bytes.len == byte_capacity);
        assert(self.records.len == record_capacity);
    }

    /// A journal no renderer consumes, for headless text systems (tests and
    /// benchmarks): atlases place items and validate caches, and nothing is
    /// staged because no consumer exists to receive it.
    pub fn initHeadless(self: *Self, allocator: std.mem.Allocator, io: std.Io) !void {
        try self.init(
            allocator,
            io,
            .{ .storage = .gpu_upload, .upload_bytes_frame_max = record_bytes_min },
        );
        assert(self.consumer_count == 0);
    }

    pub fn deinit(self: *Self) void {
        assert(self.consumer_count == 0);
        self.allocator.free(self.records);
        self.allocator.free(self.bytes);
        self.* = undefined;
    }

    // =========================================================================
    // Consumers (renderers)
    // =========================================================================

    /// Register a renderer. Its texture starts empty, so the caller must
    /// condemn every live atlas item afterwards (`AppResources` does).
    pub fn registerConsumer(self: *Self, key: usize) void {
        assert(key != 0);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        assert(self.findConsumer(key) == null);
        if (self.consumer_count == consumer_count_max) {
            std.debug.panic("AtlasUploads pool 'consumers' exhausted: capacity {d}, " ++
                "{d} in use, 1 requested.", .{ consumer_count_max, self.consumer_count });
        }
        for (&self.consumers) |*consumer| {
            if (consumer.key != 0) continue;
            // Records staged before registration describe items the caller
            // condemns; this consumer starts after them.
            consumer.* = .{
                .key = key,
                .sequence_next = self.sequenceEnd(),
                .frame_open = 0,
            };
            self.consumer_count += 1;
            return;
        }
        unreachable;
    }

    pub fn unregisterConsumer(self: *Self, key: usize) void {
        assert(key != 0);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const consumer = self.findConsumer(key) orelse unreachable;
        consumer.* = .{ .key = 0, .sequence_next = 0, .frame_open = 0 };
        assert(self.consumer_count > 0);
        self.consumer_count -= 1;
        self.retire();
    }

    /// Advance the frame clock and open `key`'s frame. Returns the new frame,
    /// which the caller passes to `deferredSince` when the frame ends.
    pub fn beginFrame(self: *Self, key: usize) u64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const frame = self.frame + 1;
        if (frame_atomic) {
            @atomicStore(u64, &self.frame, frame, .release);
        } else {
            self.frame = frame;
        }
        if (self.findConsumer(key)) |consumer| consumer.frame_open = frame;
        assert(frame > self.frame_deferred);
        return frame;
    }

    /// True when a stage request was refused in or after `frame`: some item
    /// was not drawn and the caller should render again.
    pub fn deferredSince(self: *Self, frame: u64) bool {
        assert(frame > 0);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.frame_deferred >= frame;
    }

    /// True when `key` has records it has not uploaded.
    pub fn hasPending(self: *Self, key: usize) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const consumer = self.findConsumer(key) orelse return false;
        return consumer.sequence_next < self.sequenceEnd();
    }

    /// Lock the journal and return the records `key` has not uploaded. The
    /// caller copies them into its staging and must call `consumeEnd`.
    pub fn consumeBegin(self: *Self, key: usize) Pending {
        self.mutex.lockUncancelable(self.io);
        const consumer = self.findConsumer(key) orelse {
            return .{ .records = &.{}, .bytes = &.{} };
        };
        assert(consumer.sequence_next >= self.sequence_base);
        const first: u32 = @intCast(consumer.sequence_next - self.sequence_base);
        assert(first <= self.record_count);
        const records = self.records[first..self.record_count];
        const bytes_start: u32 = if (records.len > 0) records[0].offset else self.byte_count;
        assert(bytes_start <= self.byte_count);
        return .{ .records = records, .bytes = self.bytes[0..self.byte_count] };
    }

    /// Mark everything `consumeBegin` returned as uploaded, close `key`'s
    /// frame, retire records every consumer has uploaded, and unlock.
    pub fn consumeEnd(self: *Self, key: usize) void {
        defer self.mutex.unlock(self.io);
        const consumer = self.findConsumer(key) orelse return;
        consumer.sequence_next = self.sequenceEnd();
        consumer.frame_open = 0;
        self.retire();
        assert(consumer.sequence_next >= self.sequence_base);
    }

    // =========================================================================
    // Atlas side (caller holds the mutex via `lock`)
    // =========================================================================

    pub fn lock(self: *Self) void {
        self.mutex.lockUncancelable(self.io);
    }

    pub fn unlock(self: *Self) void {
        self.mutex.unlock(self.io);
    }

    /// Current frame. Safe without the mutex.
    ///
    /// Monotonic, not acquire: the clock publishes no other data, and every
    /// structure it is compared against is guarded by this mutex or the text
    /// system's. Coherence alone gives what callers rely on: a thread never
    /// reads a frame older than one it opened itself. This runs on every glyph
    /// cache hit, and on aarch64 an acquire load (`ldapr`) holds back every
    /// later load, which serialized consecutive glyph lookups.
    pub inline fn frameCurrent(self: *const Self) u64 {
        if (frame_atomic) return @atomicLoad(u64, &self.frame, .monotonic);
        return self.frame;
    }

    /// Oldest frame whose items are still protected: the oldest open consumer
    /// frame, or the current frame when none is open.
    pub fn frameProtectedLocked(self: *const Self) u64 {
        var frame_min = self.frame;
        for (&self.consumers) |*consumer| {
            if (consumer.key == 0) continue;
            if (consumer.frame_open == 0) continue;
            frame_min = @min(frame_min, consumer.frame_open);
        }
        assert(frame_min > 0);
        return frame_min;
    }

    /// Records before this sequence have reached every consumer's texture.
    pub fn sequenceRetiredLocked(self: *const Self) u64 {
        var sequence_min = self.sequenceEnd();
        for (&self.consumers) |*consumer| {
            if (consumer.key == 0) continue;
            sequence_min = @min(sequence_min, consumer.sequence_next);
        }
        assert(sequence_min >= self.sequence_base);
        return sequence_min;
    }

    /// Journal sequence after the newest staged record.
    pub fn sequenceEnd(self: *const Self) u64 {
        assert(self.record_count <= self.records.len);
        return self.sequence_base + self.record_count;
    }

    /// Whether a `width × height` rectangle of `kind` can be staged now. A
    /// refusal records the frame so the frame that asked renders again.
    pub fn reserveLocked(self: *Self, kind: AtlasKind, width: u32, height: u32) bool {
        assert(self.storage == .gpu_upload);
        assert(width > 0);
        assert(height > 0);
        if (self.consumer_count == 0) return true;
        const byte_count = width * height * kind.bytesPerPixel();
        if (byte_count > self.bytes.len) {
            std.debug.panic("AtlasUploads pool 'staging' cannot hold one {t} atlas item: " ++
                "capacity {d} B, requested {d} B ({d}x{d} px with border), frame {d}.", .{
                kind, self.bytes.len, byte_count, width, height, self.frame,
            });
        }
        const offset = std.mem.alignForward(u32, self.byte_count, record_alignment);
        if (offset <= self.bytes.len and byte_count <= self.bytes.len - offset) {
            if (self.record_count < self.records.len) return true;
        }
        self.frame_deferred = self.frame;
        return false;
    }

    /// Append a record after a successful `reserveLocked` and return the bytes
    /// to fill, or null when no consumer exists to receive them.
    pub fn stageLocked(self: *Self, record: Upload) ?[]u8 {
        assert(self.storage == .gpu_upload);
        if (self.consumer_count == 0) return null;
        const byte_count = record.byteCount();
        const offset = std.mem.alignForward(u32, self.byte_count, record_alignment);
        assert(byte_count <= self.bytes.len - offset);
        assert(self.record_count < self.records.len);
        // Padding between records is never read; it carries no other owner's data.
        @memset(self.bytes[self.byte_count..offset], 0);
        var staged = record;
        staged.offset = offset;
        self.records[self.record_count] = staged;
        self.record_count += 1;
        self.byte_count = offset + byte_count;
        return self.bytes[staged.offset..][0..byte_count];
    }

    // =========================================================================
    // Internals
    // =========================================================================

    fn findConsumer(self: *Self, key: usize) ?*Consumer {
        assert(key != 0);
        for (&self.consumers) |*consumer| {
            if (consumer.key == key) return consumer;
        }
        return null;
    }

    /// Drop records every consumer has uploaded. Bounded by the journal size:
    /// a full retire resets the counters; a partial one (several windows at
    /// different points) moves the unretired tail to the front.
    fn retire(self: *Self) void {
        const sequence_retired = self.sequenceRetiredLocked();
        const retired: u32 = @intCast(sequence_retired - self.sequence_base);
        assert(retired <= self.record_count);
        if (retired == 0) return;
        if (retired == self.record_count) {
            self.record_count = 0;
            self.byte_count = 0;
            self.sequence_base = sequence_retired;
            return;
        }
        const byte_shift = self.records[retired].offset;
        const byte_kept = self.byte_count - byte_shift;
        std.mem.copyForwards(u8, self.bytes[0..byte_kept], self.bytes[byte_shift..self.byte_count]);
        const record_kept = self.record_count - retired;
        std.mem.copyForwards(
            Upload,
            self.records[0..record_kept],
            self.records[retired..self.record_count],
        );
        for (self.records[0..record_kept]) |*record| record.offset -= byte_shift;
        self.record_count = record_kept;
        self.byte_count = byte_kept;
        self.sequence_base = sequence_retired;
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

fn testUploads(storage: AtlasStorage, upload_bytes: u32) !*AtlasUploads {
    const uploads = try testing.allocator.create(AtlasUploads);
    errdefer testing.allocator.destroy(uploads);
    try uploads.init(testing.allocator, testing.io, .{
        .storage = storage,
        .upload_bytes_frame_max = upload_bytes,
    });
    return uploads;
}

test "journal retires a record only after every consumer uploaded it" {
    // Two consumers at different points: the record survives the first
    // consume, moves to the front when the second catches up partially, and
    // the journal empties once both have uploaded everything.
    const uploads = try testUploads(.gpu_upload, 4096);
    defer testing.allocator.destroy(uploads);
    defer uploads.deinit();
    uploads.registerConsumer(1);
    uploads.registerConsumer(2);
    defer uploads.unregisterConsumer(2);
    defer uploads.unregisterConsumer(1);

    uploads.lock();
    try testing.expect(uploads.reserveLocked(.text, 4, 4));
    @memset(
        uploads.stageLocked(.{
            .offset = 0,
            .x = 0,
            .y = 0,
            .width = 4,
            .height = 4,
            .kind = .text,
        }).?,
        7,
    );
    uploads.unlock();

    const first = uploads.consumeBegin(1);
    try testing.expectEqual(@as(usize, 1), first.records.len);
    uploads.consumeEnd(1);
    try testing.expectEqual(@as(u32, 1), uploads.record_count);

    uploads.lock();
    try testing.expect(uploads.reserveLocked(.svg, 2, 2));
    @memset(
        uploads.stageLocked(.{
            .offset = 0,
            .x = 8,
            .y = 0,
            .width = 2,
            .height = 2,
            .kind = .svg,
        }).?,
        9,
    );
    uploads.unlock();

    // Consumer 1 sees only the new record; consumer 2 sees both.
    const one = uploads.consumeBegin(1);
    try testing.expectEqual(@as(usize, 1), one.records.len);
    try testing.expectEqual(AtlasKind.svg, one.records[0].kind);
    uploads.consumeEnd(1);
    // Consumer 2 is now the only holder of both records; the text record
    // cannot retire yet, so the journal still starts with it.
    try testing.expectEqual(@as(u32, 2), uploads.record_count);

    const two = uploads.consumeBegin(2);
    try testing.expectEqual(@as(usize, 2), two.records.len);
    try testing.expectEqual(@as(u8, 7), two.bytes[two.records[0].offset]);
    try testing.expectEqual(@as(u8, 9), two.bytes[two.records[1].offset]);
    uploads.consumeEnd(2);
    try testing.expectEqual(@as(u32, 0), uploads.record_count);
    try testing.expectEqual(@as(u32, 0), uploads.byte_count);
}

test "journal refuses a stage past its byte budget and records the frame" {
    // 256 bytes hold one 16x16 R8 item exactly; one more byte is refused,
    // which marks the frame deferred, and a consume frees the space again.
    const uploads = try testUploads(.gpu_upload, 256);
    defer testing.allocator.destroy(uploads);
    defer uploads.deinit();
    uploads.registerConsumer(1);
    defer uploads.unregisterConsumer(1);

    const frame = uploads.beginFrame(1);
    try testing.expect(!uploads.deferredSince(frame));
    uploads.lock();
    try testing.expect(uploads.reserveLocked(.text, 16, 16));
    _ = uploads.stageLocked(
        .{ .offset = 0, .x = 0, .y = 0, .width = 16, .height = 16, .kind = .text },
    );
    try testing.expect(!uploads.reserveLocked(.text, 1, 1));
    uploads.unlock();
    try testing.expect(uploads.deferredSince(frame));

    _ = uploads.consumeBegin(1);
    uploads.consumeEnd(1);
    uploads.lock();
    try testing.expect(uploads.reserveLocked(.text, 1, 1));
    uploads.unlock();
}

test "frame protection follows the oldest open consumer frame" {
    // Consumer 1 opens frame 2 and consumer 2 opens frame 3: frame 2 stays
    // protected until consumer 1 uploads its scene.
    const uploads = try testUploads(.gpu_upload, 1024);
    defer testing.allocator.destroy(uploads);
    defer uploads.deinit();
    uploads.registerConsumer(1);
    uploads.registerConsumer(2);
    defer uploads.unregisterConsumer(2);
    defer uploads.unregisterConsumer(1);

    const frame_one = uploads.beginFrame(1);
    const frame_two = uploads.beginFrame(2);
    try testing.expect(frame_two > frame_one);
    uploads.lock();
    try testing.expectEqual(frame_one, uploads.frameProtectedLocked());
    uploads.unlock();
    _ = uploads.consumeBegin(1);
    uploads.consumeEnd(1);
    uploads.lock();
    try testing.expectEqual(frame_two, uploads.frameProtectedLocked());
    uploads.unlock();
}
