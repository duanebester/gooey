const std = @import("std");
const assert = std.debug.assert;

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

pub const AtlasStorage = enum {
    cpu_texture,
    gpu_upload,
};

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

pub const Pending = struct {
    records: []const Upload,
    bytes: []const u8,
};

pub const record_alignment: u32 = 4;

const frame_atomic = @sizeOf(usize) >= 8;

const record_bytes_min: u32 = 64;

pub const AtlasUploads = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex,
    storage: AtlasStorage,

    bytes: []u8,
    records: []Upload,
    byte_count: u32,
    record_count: u32,
    sequence_base: u64,

    consumers: []Consumer,
    consumer_count: u32,

    frame: u64,
    frame_deferred: u64,

    const Self = @This();

    const Consumer = struct {
        key: usize,
        sequence_next: u64,
        frame_open: u64,
        frame_shown: u64,
        shown_protected: bool,
    };

    const consumer_free: Consumer = .{
        .key = 0,
        .sequence_next = 0,
        .frame_open = 0,
        .frame_shown = 0,
        .shown_protected = false,
    };

    pub const Options = struct {
        storage: AtlasStorage,
        upload_bytes_frame_max: u32,
        consumer_count_max: u32,
    };

    pub fn init(self: *Self, allocator: std.mem.Allocator, io: std.Io, options: Options) !void {
        assert(options.upload_bytes_frame_max >= record_bytes_min);
        assert(options.consumer_count_max > 0);
        const staged = options.storage == .gpu_upload;
        const byte_capacity: u32 = if (staged) options.upload_bytes_frame_max else 0;
        const record_capacity: u32 = byte_capacity / record_bytes_min;

        self.bytes = try allocator.alloc(u8, byte_capacity);
        errdefer allocator.free(self.bytes);
        self.records = try allocator.alloc(Upload, record_capacity);
        errdefer allocator.free(self.records);
        self.consumers = try allocator.alloc(Consumer, options.consumer_count_max);

        self.allocator = allocator;
        self.io = io;
        self.mutex = .init;
        self.storage = options.storage;
        self.byte_count = 0;
        self.record_count = 0;
        self.sequence_base = 0;
        @memset(self.consumers, consumer_free);
        self.consumer_count = 0;
        self.frame = 1;
        self.frame_deferred = 0;
        assert(self.bytes.len == byte_capacity);
        assert(self.records.len == record_capacity);
    }

    pub fn initHeadless(self: *Self, allocator: std.mem.Allocator, io: std.Io) !void {
        try self.init(
            allocator,
            io,
            .{
                .storage = .gpu_upload,
                .upload_bytes_frame_max = record_bytes_min,
                .consumer_count_max = 1,
            },
        );
        assert(self.consumer_count == 0);
    }

    pub fn deinit(self: *Self) void {
        assert(self.consumer_count == 0);
        self.allocator.free(self.consumers);
        self.allocator.free(self.records);
        self.allocator.free(self.bytes);
        self.* = undefined;
    }

    pub fn registerConsumer(self: *Self, key: usize) void {
        assert(key != 0);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        assert(self.findConsumer(key) == null);
        if (self.consumer_count == self.consumers.len) {
            std.debug.panic("AtlasUploads pool 'consumers' exhausted: capacity {d}, " ++
                "{d} in use, 1 requested. One renderer registers per window " ++
                "(limits.window_count_max).", .{ self.consumers.len, self.consumer_count });
        }
        for (self.consumers) |*consumer| {
            if (consumer.key != 0) continue;
            consumer.* = .{
                .key = key,
                .sequence_next = self.sequenceEnd(),
                .frame_open = 0,
                .frame_shown = 0,
                .shown_protected = false,
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
        consumer.* = consumer_free;
        assert(self.consumer_count > 0);
        self.consumer_count -= 1;
        self.retire();
    }

    pub fn protectShownFrame(self: *Self, key: usize) void {
        assert(key != 0);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const consumer = self.findConsumer(key) orelse unreachable;
        assert(!consumer.shown_protected);
        consumer.shown_protected = true;
    }

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

    pub fn deferredSince(self: *Self, frame: u64) bool {
        assert(frame > 0);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.frame_deferred >= frame;
    }

    pub fn hasPending(self: *Self, key: usize) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const consumer = self.findConsumer(key) orelse return false;
        return consumer.sequence_next < self.sequenceEnd();
    }

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

    pub fn consumeEnd(self: *Self, key: usize) void {
        defer self.mutex.unlock(self.io);
        const consumer = self.findConsumer(key) orelse return;
        consumer.sequence_next = self.sequenceEnd();
        if (consumer.shown_protected and consumer.frame_open != 0) {
            assert(consumer.frame_open > consumer.frame_shown);
            consumer.frame_shown = consumer.frame_open;
        }
        consumer.frame_open = 0;
        self.retire();
        assert(consumer.sequence_next >= self.sequence_base);
    }

    pub fn lock(self: *Self) void {
        self.mutex.lockUncancelable(self.io);
    }

    pub fn unlock(self: *Self) void {
        self.mutex.unlock(self.io);
    }

    pub inline fn frameCurrent(self: *const Self) u64 {
        if (frame_atomic) return @atomicLoad(u64, &self.frame, .monotonic);
        return self.frame;
    }

    pub fn frameProtectedLocked(self: *const Self) u64 {
        var frame_min = self.frame;
        for (self.consumers) |*consumer| {
            if (consumer.key == 0) continue;
            if (consumer.frame_open != 0) frame_min = @min(frame_min, consumer.frame_open);
            if (consumer.frame_shown != 0) frame_min = @min(frame_min, consumer.frame_shown);
        }
        assert(frame_min > 0);
        return frame_min;
    }

    pub fn sequenceRetiredLocked(self: *const Self) u64 {
        var sequence_min = self.sequenceEnd();
        for (self.consumers) |*consumer| {
            if (consumer.key == 0) continue;
            sequence_min = @min(sequence_min, consumer.sequence_next);
        }
        assert(sequence_min >= self.sequence_base);
        return sequence_min;
    }

    pub fn sequenceEnd(self: *const Self) u64 {
        assert(self.record_count <= self.records.len);
        return self.sequence_base + self.record_count;
    }

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

    pub fn stageLocked(self: *Self, record: Upload) ?[]u8 {
        assert(self.storage == .gpu_upload);
        if (self.consumer_count == 0) return null;
        const byte_count = record.byteCount();
        const offset = std.mem.alignForward(u32, self.byte_count, record_alignment);
        assert(byte_count <= self.bytes.len - offset);
        assert(self.record_count < self.records.len);
        @memset(self.bytes[self.byte_count..offset], 0);
        var staged = record;
        staged.offset = offset;
        self.records[self.record_count] = staged;
        self.record_count += 1;
        self.byte_count = offset + byte_count;
        return self.bytes[staged.offset..][0..byte_count];
    }

    fn findConsumer(self: *Self, key: usize) ?*Consumer {
        assert(key != 0);
        for (self.consumers) |*consumer| {
            if (consumer.key == key) return consumer;
        }
        return null;
    }

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

const testing = std.testing;

fn testUploads(storage: AtlasStorage, upload_bytes: u32) !*AtlasUploads {
    const uploads = try testing.allocator.create(AtlasUploads);
    errdefer testing.allocator.destroy(uploads);
    try uploads.init(testing.allocator, testing.io, .{
        .storage = storage,
        .upload_bytes_frame_max = upload_bytes,
        .consumer_count_max = 2,
    });
    return uploads;
}

test "journal retires a record only after every consumer uploaded it" {
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

    const one = uploads.consumeBegin(1);
    try testing.expectEqual(@as(usize, 1), one.records.len);
    try testing.expectEqual(AtlasKind.svg, one.records[0].kind);
    uploads.consumeEnd(1);
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
