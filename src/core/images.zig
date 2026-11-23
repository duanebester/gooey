const std = @import("std");
const builtin = @import("builtin");
const events = @import("events.zig");
const limits_mod = @import("limits.zig");
const reservation = @import("reservation.zig");
const image_mod = @import("../image/mod.zig");

const assert = std.debug.assert;

const ImageAtlas = image_mod.ImageAtlas;
const ImageKey = image_mod.ImageKey;

pub const supported = !builtin.single_threaded and !builtin.cpu.arch.isWasm();

const worker_stack_bytes: usize = 8 * 1024 * 1024;

pub const WakeService = struct {
    context: *anyopaque,
    wake: *const fn (context: *anyopaque) void,
};

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
    path: []u8,

    const State = enum(u8) { free, pending, failed };

    fn pathSlice(self: *const Entry) []const u8 {
        assert(self.state != .free);
        assert(self.path_len <= self.path.len);
        return self.path[0..self.path_len];
    }
};

pub const Land = enum { none, landed, deferred };

pub const Mode = enum { worker, stepped };

pub const Loader = struct {
    io: std.Io,
    mode: Mode,
    stepped_staging_held: bool,
    entries: []Entry,
    path_bytes: []u8,
    requests: []u32,
    request_head: std.atomic.Value(u32),
    request_tail: std.atomic.Value(u32),
    request_ready: std.Io.Semaphore,
    staging_free: std.Io.Semaphore,
    staging: []u8,
    staging_used_max: usize,
    completions: *events.CompletionRing,
    landed: ?events.ImageDecoded,
    wake_mutex: std.Io.Mutex,
    wake: ?WakeService,
    stopping: std.atomic.Value(bool),
    thread: if (supported) std.Thread else void,
    landed_count: u32,

    pub fn initInPlace(
        self: *Loader,
        gpa: std.mem.Allocator,
        io: std.Io,
        completions: *events.CompletionRing,
        limits: *const limits_mod.AtlasLimits,
        mode: Mode,
    ) !void {
        assert(limits.image_request_count_max > 0);
        assert(limits.image_decode_bytes_max > 0);
        assert(limits.image_path_bytes_max > 0);
        if (mode == .stepped) assert(supported);
        self.io = io;
        self.mode = mode;
        self.stepped_staging_held = false;
        self.entries = try gpa.alloc(Entry, limits.image_request_count_max);
        errdefer gpa.free(self.entries);
        const path_total = @as(usize, limits.image_request_count_max) * limits.image_path_bytes_max;
        self.path_bytes = try gpa.alloc(u8, path_total);
        errdefer gpa.free(self.path_bytes);
        const path_bytes_max = limits.image_path_bytes_max;
        for (self.entries, 0..) |*entry, index| {
            entry.state = .free;
            entry.path = self.path_bytes[index * path_bytes_max ..][0..path_bytes_max];
        }
        const ring_count = std.math.ceilPowerOfTwoAssert(u32, limits.image_request_count_max);
        self.requests = try gpa.alloc(u32, ring_count);
        errdefer gpa.free(self.requests);
        self.request_head = .init(0);
        self.request_tail = .init(0);
        self.request_ready = .{ .permits = 0 };
        self.staging_free = .{ .permits = 1 };
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
        if (supported and mode == .worker) {
            self.thread = try std.Thread.spawn(.{
                .stack_size = worker_stack_bytes,
                .allocator = null,
            }, workerMain, .{self});
        }
        assert(self.requests.len >= self.entries.len);
    }

    pub fn deinit(self: *Loader, gpa: std.mem.Allocator) void {
        self.stopping.store(true, .release);
        if (supported and self.mode == .worker) {
            const thread = self.thread;
            self.request_ready.post(self.io);
            self.staging_free.post(self.io);
            thread.join();
        }
        if (supported) reservation.release(u8, self.staging, self.staging_used_max);
        gpa.free(self.requests);
        gpa.free(self.path_bytes);
        gpa.free(self.entries);
        self.* = undefined;
    }

    pub fn bindWake(self: *Loader, service: ?WakeService) void {
        self.wake_mutex.lockUncancelable(self.io);
        defer self.wake_mutex.unlock(self.io);
        if (service != null) assert(self.wake == null);
        self.wake = service;
    }

    pub fn request(self: *Loader, path: []const u8, key: ImageKey, frame_number: u64) void {
        assert(path.len > 0);
        assert(self.requests.len >= self.entries.len);
        if (!supported) std.debug.panic("Painter.image(\"{s}\") needs the native decode " ++
            "worker; the web keeps the browser's image path", .{path});
        const path_bytes_max = self.entries[0].path.len;
        if (path.len > path_bytes_max) std.debug.panic("Painter.image path of {d} bytes " ++
            "exceeds ResourceLimits.atlas.image_path_bytes_max {d}, frame {d}: \"{s}\"", .{
            path.len,
            path_bytes_max,
            frame_number,
            path,
        });
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
        if (self.mode == .worker) self.request_ready.post(self.io);
    }

    pub fn takeStepped(self: *Loader) ?u32 {
        assert(self.mode == .stepped);
        assert(self.requests.len >= self.entries.len);
        if (self.stepped_staging_held) return null;
        const tail = self.request_tail.load(.monotonic);
        if (tail == self.request_head.load(.monotonic)) return null;
        self.stepped_staging_held = true;
        const index = self.takeRequest();
        assert(self.entries[index].state == .pending);
        return index;
    }

    pub fn stagingStepped(self: *Loader, pixel_bytes: u32) []u8 {
        assert(self.mode == .stepped);
        assert(self.stepped_staging_held);
        assert(pixel_bytes > 0);
        assert(pixel_bytes <= self.staging.len);
        self.staging_used_max = @max(self.staging_used_max, pixel_bytes);
        return self.staging[0..pixel_bytes];
    }

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
        const side_max = atlas.atlas.size - 2;
        if (decoded.width > side_max or decoded.height > side_max) {
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
        };
        entry.state = .free;
        self.release();
        self.landed_count += 1;
        return .landed;
    }

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

    fn release(self: *Loader) void {
        assert(self.landed != null);
        self.landed = null;
        switch (self.mode) {
            .worker => self.staging_free.post(self.io),
            .stepped => {
                assert(self.stepped_staging_held);
                self.stepped_staging_held = false;
            },
        }
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
        while (true) {
            self.request_ready.waitUncancelable(self.io);
            if (self.stopping.load(.acquire)) return;
            self.staging_free.waitUncancelable(self.io);
            if (self.stopping.load(.acquire)) return;
            const index = self.takeRequest();
            const decoded = self.decode(index);
            self.completions.pushImage(decoded);
            self.wakeHost();
        }
    }

    fn takeRequest(self: *Loader) u32 {
        const tail = self.request_tail.load(.monotonic);
        assert(tail != self.request_head.load(.acquire));
        const index = self.requests[tail & (@as(u32, @intCast(self.requests.len)) - 1)];
        self.request_tail.store(tail +% 1, .release);
        assert(index < self.entries.len);
        return index;
    }

    fn wakeHost(self: *Loader) void {
        self.wake_mutex.lockUncancelable(self.io);
        defer self.wake_mutex.unlock(self.io);
        if (self.wake) |service| service.wake(service.context);
    }

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

const PeakAllocator = struct {
    fixed: std.heap.FixedBufferAllocator,
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
        atlas_size - 2,
        atlas_size,
    });
}
