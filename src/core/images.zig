//! The image decode worker behind `Painter.image` (contract §9 `ImageDecoder`).
//!
//! A file read has no time bound and a PNG or JPEG decode takes milliseconds,
//! so neither runs on the main thread (CLAUDE.md §1, §8). One worker, started
//! at init, reads and decodes into staging reserved at init:
//!
//! 1. Emit misses the atlas and calls `request`: the path is copied into a
//!    free entry and the entry's index goes onto the bounded request ring.
//! 2. The worker takes the oldest request once the staging is free, reads
//!    the file into the staging's front and decodes the RGBA pixels behind
//!    it, then pushes an `ImageDecoded` onto the window's completion ring
//!    and wakes the host.
//! 3. The drain moves it into `landed` and requests a render; the next emit
//!    uploads it into the image atlas on the main thread (`land`), frees the
//!    entry, and hands the staging back to the worker. Until then the image
//!    paints nothing, so its box's own background shows.
//!
//! Capacity: `AtlasLimits.image_request_count_max` entries hold images that
//! wait for the worker and images whose decode failed, which stay failed for
//! the session so a missing file is not re-read every frame. One more fails
//! fast. `image_decode_bytes_max` bounds one image's file and pixels.
//!
//! Performance sketch at `.large`: 64 entries of ~1 KiB (64 KiB) and 24 MiB
//! of staging from fresh pages; a decode makes resident only its file and
//! pixels (the images example's 512² logo: ~1.1 MiB). The main thread's
//! work per tick is one hash and an entry scan (≤ 64) per missing image,
//! plus at most one upload per emit, which the atlas already bounds by
//! `upload_bytes_frame_max`. Images land at most one per frame.

const std = @import("std");
const builtin = @import("builtin");
const events = @import("events.zig");
const limits_mod = @import("limits.zig");
const reservation = @import("reservation.zig");
const image_mod = @import("../image/mod.zig");

const assert = std.debug.assert;

const ImageAtlas = image_mod.ImageAtlas;
const ImageKey = image_mod.ImageKey;

/// The web has no worker threads; it keeps the browser's image path.
pub const supported = !builtin.single_threaded and !builtin.cpu.arch.isWasm();

/// Longest path `Painter.image` accepts. A longer one fails fast.
pub const path_bytes_max: u32 = 1024;

/// The worker's stack. Decoders are opaque platform code (libpng,
/// ImageIO, WIC), so it matches a common main-thread default.
const worker_stack_bytes: usize = 8 * 1024 * 1024;

/// Wakes the host's main loop from the worker, so a landed decode is drawn
/// without waiting for input. Bound per backend beside `FileDialogService`.
pub const WakeService = struct {
    context: *anyopaque,
    wake: *const fn (context: *anyopaque) void,
};

/// The atlas key of the image file at `path`. Pixels are cached at their
/// decoded size and scaled when drawn, so the size is not part of the key.
pub fn keyFor(path: []const u8) ImageKey {
    assert(path.len > 0);
    const key = ImageKey.initFromPath(path, null, null, 1);
    assert(key.target_width == 0);
    return key;
}

const Entry = struct {
    state: State,
    source_hash: u64,
    path_len: u32,
    path: [path_bytes_max]u8,

    const State = enum(u8) { free, pending, failed };

    fn pathSlice(self: *const Entry) []const u8 {
        assert(self.state != .free);
        assert(self.path_len <= path_bytes_max);
        return self.path[0..self.path_len];
    }
};

/// What `land` did, so emit knows whether to render again.
pub const Land = enum { none, landed, deferred };

pub const Loader = struct {
    io: std.Io,
    /// Main thread only, except that the worker reads a pending entry's path.
    entries: []Entry,
    /// Indexes of entries waiting for the worker, a power-of-two ring at
    /// least as long as `entries`; every queued index holds a pending entry,
    /// so the ring cannot overflow. The main thread writes `request_head`,
    /// the worker `request_tail`.
    requests: []u32,
    request_head: std.atomic.Value(u32),
    request_tail: std.atomic.Value(u32),
    /// One permit per queued request, plus one at stop.
    request_ready: std.Io.Semaphore,
    /// One permit while the staging is free for the next decode.
    staging_free: std.Io.Semaphore,
    staging: []u8,
    /// The staging's high-water mark, zeroed on release (CLAUDE.md §21).
    /// Written by the worker; read after it is joined.
    staging_used_max: usize,
    completions: *events.CompletionRing,
    /// The decode the drain took from the completion ring, until `land`.
    landed: ?events.ImageDecoded,
    wake_mutex: std.Io.Mutex,
    wake: ?WakeService,
    stopping: std.atomic.Value(bool),
    /// The worker; `void` where there are no threads (the web).
    thread: if (supported) std.Thread else void,
    /// Decodes landed, for tests and the lifecycle guard's checks.
    landed_count: u32,

    /// Reserve every entry and the staging, then start the worker.
    pub fn initInPlace(
        self: *Loader,
        gpa: std.mem.Allocator,
        io: std.Io,
        completions: *events.CompletionRing,
        limits: *const limits_mod.AtlasLimits,
    ) !void {
        assert(limits.image_request_count_max > 0);
        assert(limits.image_decode_bytes_max > 0);
        self.io = io;
        self.entries = try gpa.alloc(Entry, limits.image_request_count_max);
        errdefer gpa.free(self.entries);
        for (self.entries) |*entry| entry.state = .free;
        const ring_count = std.math.ceilPowerOfTwoAssert(u32, limits.image_request_count_max);
        self.requests = try gpa.alloc(u32, ring_count);
        errdefer gpa.free(self.requests);
        self.request_head = .init(0);
        self.request_tail = .init(0);
        self.request_ready = .{ .permits = 0 };
        self.staging_free = .{ .permits = 1 };
        // The web never decodes here, so it reserves no staging.
        self.staging = if (supported)
            try reservation.reserve(u8, limits.image_decode_bytes_max)
        else
            &.{};
        errdefer if (supported) reservation.release(u8, self.staging, 0);
        self.staging_used_max = 0;
        self.completions = completions;
        self.landed = null;
        self.wake_mutex = .init;
        self.wake = null;
        self.stopping = .init(false);
        self.landed_count = 0;
        if (supported) {
            self.thread = try std.Thread.spawn(.{
                .stack_size = worker_stack_bytes,
                .allocator = null,
            }, workerMain, .{self});
        }
        assert(self.requests.len >= self.entries.len);
    }

    /// Stop the worker and wait for it, then free what init reserved. A
    /// decode in progress finishes first; queued requests are dropped.
    pub fn deinit(self: *Loader, gpa: std.mem.Allocator) void {
        self.stopping.store(true, .release);
        if (supported) {
            const thread = self.thread;
            self.request_ready.post(self.io);
            self.staging_free.post(self.io);
            thread.join();
        }
        if (supported) reservation.release(u8, self.staging, self.staging_used_max);
        gpa.free(self.requests);
        gpa.free(self.entries);
        self.* = undefined;
    }

    /// Bind or unbind the host's wake. The worker calls it under the same
    /// lock, so a host may unbind while a decode is in flight.
    pub fn bindWake(self: *Loader, service: ?WakeService) void {
        self.wake_mutex.lockUncancelable(self.io);
        defer self.wake_mutex.unlock(self.io);
        if (service != null) assert(self.wake == null);
        self.wake = service;
    }

    /// Queue a decode of `path` unless it is already queued or failed. Main
    /// thread, from emit. Fails fast when every entry is held.
    pub fn request(self: *Loader, path: []const u8, key: ImageKey, frame_number: u64) void {
        assert(path.len > 0);
        assert(self.requests.len >= self.entries.len);
        if (!supported) std.debug.panic("Painter.image(\"{s}\") needs the native decode " ++
            "worker; the web keeps the browser's image path", .{path});
        if (path.len > path_bytes_max) std.debug.panic("Painter.image path of {d} bytes " ++
            "exceeds images.path_bytes_max ({d}): \"{s}\"", .{ path.len, path_bytes_max, path });
        if (self.find(key.source_hash) != null) return;
        const index = self.freeEntry() orelse std.debug.panic("image loader pool 'requests' " ++
            "exhausted: capacity {d} images waiting or failed, 1 requested (\"{s}\") in " ++
            "frame {d}. Raise ResourceLimits.atlas.image_request_count_max.", .{
            self.entries.len,
            path,
            frame_number,
        });
        const entry = &self.entries[index];
        entry.state = .pending;
        entry.source_hash = key.source_hash;
        entry.path_len = @intCast(path.len);
        @memcpy(entry.path[0..path.len], path);
        const head = self.request_head.load(.monotonic);
        assert(head -% self.request_tail.load(.acquire) < self.entries.len);
        self.requests[head & (@as(u32, @intCast(self.requests.len)) - 1)] = index;
        self.request_head.store(head +% 1, .release);
        self.request_ready.post(self.io);
    }

    /// Upload the landed decode, if any, into `atlas` and free its entry and
    /// the staging. A decode this frame's upload staging cannot take stays
    /// landed for the next frame. Main thread, at the start of emit.
    pub fn land(self: *Loader, atlas: *ImageAtlas) Land {
        const decoded = self.landed orelse return .none;
        assert(decoded.entry < self.entries.len);
        const entry = &self.entries[decoded.entry];
        assert(entry.state == .pending);
        if (decoded.failure) |failure| {
            self.landFailure(entry, failure);
            return .none;
        }
        const pixel_bytes = @as(usize, decoded.width) * decoded.height * 4;
        assert(decoded.pixel_offset <= self.staging.len);
        assert(pixel_bytes <= self.staging.len - decoded.pixel_offset);
        if (decoded.width > ImageAtlas.MAX_ATLAS_DIMENSION or
            decoded.height > ImageAtlas.MAX_ATLAS_DIMENSION)
        {
            panicTooLarge(entry, decoded, atlas.atlas.size);
        }
        const pixels = self.staging[decoded.pixel_offset..][0..pixel_bytes];
        const key = ImageKey{
            .source_hash = entry.source_hash,
            .target_width = 0,
            .target_height = 0,
        };
        _ = atlas.cacheRgba(key, decoded.width, decoded.height, pixels) catch |err| switch (err) {
            error.UploadDeferred => return .deferred,
            else => std.debug.panic("image atlas rejected \"{s}\": {s}", .{
                entry.pathSlice(),
                @errorName(err),
            }),
        };
        entry.state = .free;
        self.release();
        self.landed_count += 1;
        return .landed;
    }

    /// A missing or undecodable file is an operating error: it is logged
    /// once and the entry stays failed. Staging too small for the file is a
    /// capacity-planning error.
    fn landFailure(self: *Loader, entry: *Entry, failure: anyerror) void {
        assert(entry.state == .pending);
        if (failure == error.StagingExhausted) {
            std.debug.panic("image \"{s}\" does not fit the decode staging: capacity {d} B. " ++
                "Raise ResourceLimits.atlas.image_decode_bytes_max.", .{
                entry.pathSlice(),
                self.staging.len,
            });
        }
        std.log.warn("Painter.image(\"{s}\") failed: {s}; it draws nothing", .{
            entry.pathSlice(),
            @errorName(failure),
        });
        entry.state = .failed;
        self.release();
    }

    /// Hand the staging back to the worker.
    fn release(self: *Loader) void {
        assert(self.landed != null);
        self.landed = null;
        self.staging_free.post(self.io);
    }

    fn find(self: *const Loader, source_hash: u64) ?u32 {
        for (self.entries, 0..) |*entry, index| {
            if (entry.state != .free and entry.source_hash == source_hash) {
                return @intCast(index);
            }
        }
        return null;
    }

    fn freeEntry(self: *const Loader) ?u32 {
        for (self.entries, 0..) |*entry, index| {
            if (entry.state == .free) return @intCast(index);
        }
        return null;
    }

    fn workerMain(self: *Loader) void {
        assert(supported);
        // Each turn decodes one request, so the loop ends at stop.
        while (true) {
            self.request_ready.waitUncancelable(self.io);
            if (self.stopping.load(.acquire)) return;
            self.staging_free.waitUncancelable(self.io);
            if (self.stopping.load(.acquire)) return;
            const tail = self.request_tail.load(.monotonic);
            assert(tail != self.request_head.load(.acquire));
            const index = self.requests[tail & (@as(u32, @intCast(self.requests.len)) - 1)];
            self.request_tail.store(tail +% 1, .release);
            assert(index < self.entries.len);
            const decoded = self.decode(index);
            self.completions.pushImage(decoded);
            self.wakeHost();
        }
    }

    fn wakeHost(self: *Loader) void {
        self.wake_mutex.lockUncancelable(self.io);
        defer self.wake_mutex.unlock(self.io);
        if (self.wake) |service| service.wake(service.context);
    }

    /// Worker side: read and decode the entry's file into the staging.
    fn decode(self: *Loader, index: u32) events.ImageDecoded {
        const entry = &self.entries[index];
        assert(entry.state == .pending);
        var peak = PeakAllocator{ .fixed = undefined, .peak = 0 };
        const image = decodeInto(self.io, entry.pathSlice(), self.staging, &peak);
        self.staging_used_max = @max(self.staging_used_max, peak.base + peak.peak);
        const decoded = image catch |err| return .{
            .entry = index,
            .width = 0,
            .height = 0,
            .pixel_offset = 0,
            .failure = err,
        };
        const offset = @intFromPtr(decoded.pixels.ptr) - @intFromPtr(self.staging.ptr);
        assert(offset + decoded.pixels.len <= self.staging.len);
        assert(decoded.pixels.len == @as(usize, decoded.width) * decoded.height * 4);
        return .{
            .entry = index,
            .width = decoded.width,
            .height = decoded.height,
            .pixel_offset = @intCast(offset),
            .failure = null,
        };
    }
};

const Decoded = struct { width: u32, height: u32, pixels: []const u8 };

/// Read `path` into the front of `staging` and decode its RGBA pixels into
/// the rest. Either part not fitting is `error.StagingExhausted`.
fn decodeInto(io: std.Io, path: []const u8, staging: []u8, peak: *PeakAllocator) !Decoded {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const file_bytes = try file.length(io);
    if (file_bytes >= staging.len) return error.StagingExhausted;
    const bytes = staging[0..@intCast(file_bytes)];
    peak.base = bytes.len;
    const read = try file.readPositionalAll(io, bytes, 0);
    if (read != bytes.len) return error.EndOfStream;
    peak.fixed = .init(staging[bytes.len..]);
    const image = image_mod.loader.loadFromMemory(peak.allocator(), bytes) catch |err| {
        return if (err == error.OutOfMemory) error.StagingExhausted else err;
    };
    assert(image.width > 0);
    assert(image.height > 0);
    return .{ .width = image.width, .height = image.height, .pixels = image.pixels };
}

/// A fixed buffer allocator that remembers its high-water mark: decoders
/// free scratch such as libpng's row table, and release must still zero it.
const PeakAllocator = struct {
    fixed: std.heap.FixedBufferAllocator,
    /// Staging bytes before the fixed buffer (the file).
    base: usize = 0,
    peak: usize,

    fn allocator(self: *PeakAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *PeakAllocator = @ptrCast(@alignCast(context));
        const result = self.fixed.allocator().rawAlloc(len, alignment, ra);
        self.peak = @max(self.peak, self.fixed.end_index);
        return result;
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        len: usize,
        ra: usize,
    ) bool {
        const self: *PeakAllocator = @ptrCast(@alignCast(context));
        const result = self.fixed.allocator().rawResize(memory, alignment, len, ra);
        self.peak = @max(self.peak, self.fixed.end_index);
        return result;
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        len: usize,
        ra: usize,
    ) ?[*]u8 {
        const self: *PeakAllocator = @ptrCast(@alignCast(context));
        const result = self.fixed.allocator().rawRemap(memory, alignment, len, ra);
        self.peak = @max(self.peak, self.fixed.end_index);
        return result;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *PeakAllocator = @ptrCast(@alignCast(context));
        self.fixed.allocator().rawFree(memory, alignment, ra);
    }
};

fn panicTooLarge(entry: *const Entry, decoded: events.ImageDecoded, atlas_size: u32) noreturn {
    std.debug.panic("image \"{s}\" is {d}x{d} px: the image atlas holds at most {d} px " ++
        "per side ({d} px atlas). Raise ResourceLimits.atlas.image_size or use a " ++
        "smaller image.", .{
        entry.pathSlice(),
        decoded.width,
        decoded.height,
        @min(atlas_size - 2, ImageAtlas.MAX_ATLAS_DIMENSION),
        atlas_size,
    });
}
