//! Events, the bounded event queue, and the completion ring (contract §5).
//!
//! Platforms push events on the main thread; `tick` drains the whole queue
//! once per tick, so a push never waits on a handler and a handler never runs
//! inside a platform callback. Event text (typed text, IME preedit, key
//! characters, dialog paths) is copied into the queue's own bytes at push
//! (contract rule 6) and stays valid until the drain that delivers it ends.
//!
//! Overflow policy: consecutive pointer moves and scroll deltas coalesce.
//! Any other overflow panics with the queue's name and capacity.

const std = @import("std");
const input = @import("../input/mod.zig");
const clipboard = @import("clipboard.zig");

const assert = std.debug.assert;

pub const InputEvent = input.InputEvent;

pub const WindowEvent = union(enum) {
    resized: struct { width: f32, height: f32, scale_factor: f32 },
    close_requested,
};

/// The result of an operation that finished outside the handler that asked
/// for it. Selection, cancellation, and failure are distinct (rule 5).
pub const Completion = struct {
    request_id: u32,
    outcome: Outcome,

    pub const Outcome = union(enum) {
        /// One path for a save or a single selection; up to
        /// `ResourceLimits.events.dialog_path_count_max` for `multiple`.
        file_selected: Paths,
        cancelled,
        failed: anyerror,
    };
};

/// The paths a file dialog selected, in the platform's order, joined by NUL
/// bytes. No supported platform allows NUL in a path, so the join is
/// unambiguous, and one path is kept without a copy. The count and total
/// bytes are bounded by `ResourceLimits.events` (contract decision 11).
pub const Paths = struct {
    bytes: []const u8,
    count: u32,

    pub const separator: u8 = 0;

    /// Join `paths` into `allocator`, a host's dialog scratch. A path that
    /// is empty or holds a NUL is the platform's error, not the app's.
    pub fn join(allocator: std.mem.Allocator, paths: []const []const u8) !Paths {
        assert(paths.len > 0);
        assert(paths.len <= std.math.maxInt(u32));
        var size: usize = paths.len - 1;
        for (paths) |path| {
            if (path.len == 0) return error.InvalidPath;
            if (std.mem.indexOfScalar(u8, path, separator) != null) return error.InvalidPath;
            size += path.len;
        }
        if (paths.len == 1) return .{ .bytes = paths[0], .count = 1 };
        const bytes = try allocator.alloc(u8, size);
        var offset: usize = 0;
        for (paths, 0..) |path, index| {
            if (index > 0) {
                bytes[offset] = separator;
                offset += 1;
            }
            @memcpy(bytes[offset..][0..path.len], path);
            offset += path.len;
        }
        assert(offset == size);
        return .{ .bytes = bytes, .count = @intCast(paths.len) };
    }

    /// The paths in order; yields exactly `count` slices.
    pub fn iterator(self: Paths) std.mem.SplitIterator(u8, .scalar) {
        assert(self.count > 0);
        assert(self.bytes.len >= 2 * self.count - 1);
        return std.mem.splitScalar(u8, self.bytes, separator);
    }

    /// The first path: the only one for a save or a single selection.
    pub fn first(self: Paths) []const u8 {
        var paths = self.iterator();
        const path = paths.first();
        assert(path.len > 0);
        return path;
    }

    /// Whether `count` matches the separators, so `iterator` yields `count`.
    fn consistent(self: Paths) bool {
        if (self.count == 0) return false;
        return std.mem.count(u8, self.bytes, &.{separator}) == self.count - 1;
    }
};

pub const Event = union(enum) {
    input: InputEvent,
    completion: Completion,
    window: WindowEvent,
};

pub const QueueCapacity = struct {
    event_count_max: u32,
    text_bytes_max: u32,
};

pub const EventQueue = struct {
    events: []Event,
    count: u32,
    text_bytes: []u8,
    text_len: u32,
    /// Events coalesced since init, for tests and diagnostics.
    coalesced_count: u64,

    pub fn initInPlace(self: *EventQueue, gpa: std.mem.Allocator, capacity: QueueCapacity) !void {
        assert(capacity.event_count_max > 0);
        assert(capacity.text_bytes_max > 0);
        self.events = try gpa.alloc(Event, capacity.event_count_max);
        errdefer gpa.free(self.events);
        self.text_bytes = try gpa.alloc(u8, capacity.text_bytes_max);
        self.count = 0;
        self.text_len = 0;
        self.coalesced_count = 0;
    }

    pub fn deinit(self: *EventQueue, gpa: std.mem.Allocator) void {
        assert(self.count <= self.events.len);
        gpa.free(self.text_bytes);
        gpa.free(self.events);
        self.* = undefined;
    }

    /// Queue `event`, copying its text. Runs on the main thread.
    pub fn push(self: *EventQueue, event: Event) void {
        assert(self.count <= self.events.len);
        if (self.coalesce(event)) {
            self.coalesced_count += 1;
            return;
        }
        if (self.count == self.events.len) {
            std.debug.panic("event queue 'events' exhausted: capacity {d}, {d} in use, " ++
                "1 requested ({t}). Raise the app's ResourceLimits.events.", .{
                self.events.len,
                self.count,
                event,
            });
        }
        self.events[self.count] = self.copyText(event);
        self.count += 1;
    }

    /// The queued events, in push order. Valid until `clear`.
    pub fn pending(self: *const EventQueue) []const Event {
        assert(self.count <= self.events.len);
        return self.events[0..self.count];
    }

    /// Release every event and its text. Called by `tick` after the drain.
    pub fn clear(self: *EventQueue) void {
        assert(self.text_len <= self.text_bytes.len);
        self.count = 0;
        self.text_len = 0;
    }

    /// Fold a pointer move into a queued move, or a scroll into a queued
    /// scroll, when it directly follows one.
    fn coalesce(self: *EventQueue, event: Event) bool {
        if (self.count == 0) return false;
        const last = &self.events[self.count - 1];
        if (event != .input or last.* != .input) return false;
        switch (event.input) {
            .mouse_moved => |moved| {
                if (last.input != .mouse_moved) return false;
                last.input.mouse_moved = moved;
                return true;
            },
            .scroll => |scroll| {
                if (last.input != .scroll) return false;
                last.input.scroll.position = scroll.position;
                last.input.scroll.delta.x += scroll.delta.x;
                last.input.scroll.delta.y += scroll.delta.y;
                return true;
            },
            else => return false,
        }
    }

    fn copyText(self: *EventQueue, event: Event) Event {
        var copy = event;
        switch (copy) {
            .input => |*value| switch (value.*) {
                .text_input => |*text| text.text = self.copyPlatformText(text.text, "text"),
                .composition => |*text| {
                    text.text = self.copyPlatformText(text.text, "composition");
                },
                .key_down, .key_up => |*key| {
                    if (key.characters) |bytes| key.characters = self.copyBytes(bytes);
                    if (key.characters_ignoring_modifiers) |bytes| {
                        key.characters_ignoring_modifiers = self.copyBytes(bytes);
                    }
                },
                else => {},
            },
            .completion => |*completion| switch (completion.outcome) {
                .file_selected => |*paths| {
                    assert(paths.consistent());
                    paths.bytes = self.copyBytes(paths.bytes);
                },
                else => {},
            },
            else => {},
        }
        return copy;
    }

    /// Typed, dictated, or composed text is operating input whose length
    /// the app cannot plan: text past the queue's free text bytes
    /// (`ResourceLimits.events.text_bytes_max`) is cut at the last codepoint
    /// boundary that fits, and the cut logged, rather than split or refused.
    fn copyPlatformText(self: *EventQueue, bytes: []const u8, kind: []const u8) []const u8 {
        assert(self.text_len <= self.text_bytes.len);
        const room = self.text_bytes.len - self.text_len;
        const kept = clipboard.prefixFitting(bytes, room);
        if (kept < bytes.len) {
            std.log.warn("event queue: {s} of {d} bytes cut to {d}; {d} of {d} text bytes " ++
                "were free. Raise ResourceLimits.events.text_bytes_max.", .{
                kind,
                bytes.len,
                kept,
                room,
                self.text_bytes.len,
            });
        }
        assert(kept <= room);
        return self.copyBytes(bytes[0..kept]);
    }

    fn copyBytes(self: *EventQueue, bytes: []const u8) []const u8 {
        assert(self.text_len <= self.text_bytes.len);
        if (bytes.len > self.text_bytes.len - self.text_len) {
            std.debug.panic("event queue 'text bytes' exhausted: capacity {d} bytes, " ++
                "{d} in use, {d} requested. Raise ResourceLimits.events.text_bytes_max.", .{
                self.text_bytes.len,
                self.text_len,
                bytes.len,
            });
        }
        const target = self.text_bytes[self.text_len..][0..bytes.len];
        @memcpy(target, bytes);
        self.text_len += @intCast(bytes.len);
        return target;
    }
};

/// A bounded single-producer, single-consumer ring for completions produced
/// on worker threads. `tick` drains it on the main thread. Paths are copied
/// into each slot's fixed bytes so the worker's buffer can be reused; a
/// selection larger than one slot's bytes is a capacity-planning error.
pub const CompletionRing = struct {
    slots: []Slot,
    /// Written by the producer, read by the consumer.
    head: std.atomic.Value(u32),
    /// Written by the consumer, read by the producer.
    tail: std.atomic.Value(u32),

    pub const path_bytes_max: u32 = 1024;

    const Slot = struct {
        request_id: u32,
        tag: std.meta.Tag(Completion.Outcome),
        failure: anyerror,
        path_count: u32,
        path_len: u32,
        path: [path_bytes_max]u8,
    };

    pub fn initInPlace(self: *CompletionRing, gpa: std.mem.Allocator, count_max: u32) !void {
        assert(count_max > 0);
        assert(std.math.isPowerOfTwo(count_max));
        self.slots = try gpa.alloc(Slot, count_max);
        self.head = .init(0);
        self.tail = .init(0);
    }

    pub fn deinit(self: *CompletionRing, gpa: std.mem.Allocator) void {
        assert(self.slots.len > 0);
        gpa.free(self.slots);
        self.* = undefined;
    }

    /// Producer side. A full ring is a capacity-planning error.
    pub fn push(self: *CompletionRing, completion: Completion) void {
        const head = self.head.load(.monotonic);
        const tail = self.tail.load(.acquire);
        assert(head -% tail <= self.slots.len);
        if (head -% tail == self.slots.len) {
            std.debug.panic("completion ring exhausted: capacity {d}, {d} in use, 1 " ++
                "requested. Raise ResourceLimits.events.completion_count_max.", .{
                self.slots.len,
                self.slots.len,
            });
        }
        const slot = &self.slots[head & (@as(u32, @intCast(self.slots.len)) - 1)];
        slot.request_id = completion.request_id;
        slot.tag = completion.outcome;
        slot.path_count = 0;
        slot.path_len = 0;
        slot.failure = error.Unexpected;
        switch (completion.outcome) {
            .file_selected => |paths| {
                assert(paths.consistent());
                if (paths.bytes.len > path_bytes_max) {
                    std.debug.panic("completion ring slot path bytes exhausted: capacity " ++
                        "{d} bytes, {d} requested", .{ path_bytes_max, paths.bytes.len });
                }
                @memcpy(slot.path[0..paths.bytes.len], paths.bytes);
                slot.path_count = paths.count;
                slot.path_len = @intCast(paths.bytes.len);
            },
            .cancelled => {},
            .failed => |failure| slot.failure = failure,
        }
        self.head.store(head +% 1, .release);
    }

    /// Consumer side: move every completion into `queue`.
    pub fn drainInto(self: *CompletionRing, queue: *EventQueue) void {
        const head = self.head.load(.acquire);
        var tail = self.tail.load(.monotonic);
        assert(head -% tail <= self.slots.len);
        while (tail != head) : (tail +%= 1) {
            const slot = &self.slots[tail & (@as(u32, @intCast(self.slots.len)) - 1)];
            const outcome: Completion.Outcome = switch (slot.tag) {
                .file_selected => .{ .file_selected = .{
                    .bytes = slot.path[0..slot.path_len],
                    .count = slot.path_count,
                } },
                .cancelled => .cancelled,
                .failed => .{ .failed = slot.failure },
            };
            queue.push(.{ .completion = .{ .request_id = slot.request_id, .outcome = outcome } });
        }
        self.tail.store(tail, .release);
    }
};

test "queue coalesces moves and scrolls and copies text" {
    // Goal: the overflow policy and rule 6. Method: push two moves, two
    // scrolls, and text from a buffer that is then overwritten.
    var queue: EventQueue = undefined;
    try queue.initInPlace(std.testing.allocator, .{ .event_count_max = 4, .text_bytes_max = 16 });
    defer queue.deinit(std.testing.allocator);
    const move = input.MouseEvent{
        .position = .{ .x = 1, .y = 2 },
        .button = .left,
        .click_count = 0,
        .modifiers = .{},
    };
    queue.push(.{ .input = .{ .mouse_moved = move } });
    var moved = move;
    moved.position.x = 9;
    queue.push(.{ .input = .{ .mouse_moved = moved } });
    const scroll = input.ScrollEvent{
        .position = .{ .x = 0, .y = 0 },
        .delta = .{ .x = 1, .y = 2 },
        .modifiers = .{},
    };
    queue.push(.{ .input = .{ .scroll = scroll } });
    queue.push(.{ .input = .{ .scroll = scroll } });
    var text = "abc".*;
    queue.push(.{ .input = .{ .text_input = .{ .text = &text } } });
    text[0] = 'X';
    const events = queue.pending();
    try std.testing.expectEqual(@as(usize, 3), events.len);
    try std.testing.expectEqual(@as(f64, 9), events[0].input.mouse_moved.position.x);
    try std.testing.expectEqual(@as(f64, 4), events[1].input.scroll.delta.y);
    try std.testing.expectEqualStrings("abc", events[2].input.text_input.text);
    try std.testing.expectEqual(@as(u64, 2), queue.coalesced_count);
    queue.clear();
    try std.testing.expectEqual(@as(usize, 0), queue.pending().len);
}

test "platform text past the free text bytes is cut on a codepoint boundary" {
    // Goal: long dictation or an IME commit never splits a UTF-8 sequence
    // or panics (the 0.3.1 macOS host cut "a" x 255 + "東京" at byte 256).
    // Methodology: a 256-byte queue keeps the 255 'a' bytes and drops "東京"
    // whole; a composition that no longer fits at all arrives empty, which
    // clears the preedit until the next update. A 512-byte queue keeps the
    // string whole.
    var long: [255 + "東京".len]u8 = undefined;
    @memset(long[0..255], 'a');
    @memcpy(long[255..], "東京");
    var queue: EventQueue = undefined;
    try queue.initInPlace(std.testing.allocator, .{ .event_count_max = 4, .text_bytes_max = 256 });
    defer queue.deinit(std.testing.allocator);
    queue.push(.{ .input = .{ .text_input = .{ .text = &long } } });
    const kept = queue.pending()[0].input.text_input.text;
    try std.testing.expectEqual(@as(usize, 255), kept.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(kept));
    queue.push(.{ .input = .{ .composition = .{ .text = "東" } } });
    try std.testing.expectEqualStrings("", queue.pending()[1].input.composition.text);

    var roomy: EventQueue = undefined;
    try roomy.initInPlace(std.testing.allocator, .{ .event_count_max = 1, .text_bytes_max = 512 });
    defer roomy.deinit(std.testing.allocator);
    roomy.push(.{ .input = .{ .text_input = .{ .text = &long } } });
    try std.testing.expectEqualStrings(&long, roomy.pending()[0].input.text_input.text);
}

test "completion ring delivers distinct outcomes in order" {
    // Goal: selection, cancellation, and failure arrive as distinct values.
    var queue: EventQueue = undefined;
    try queue.initInPlace(std.testing.allocator, .{ .event_count_max = 4, .text_bytes_max = 64 });
    defer queue.deinit(std.testing.allocator);
    var ring: CompletionRing = undefined;
    try ring.initInPlace(std.testing.allocator, 4);
    defer ring.deinit(std.testing.allocator);
    var scratch: [64]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&scratch);
    const two = try Paths.join(fixed.allocator(), &.{ "/tmp/a.txt", "/tmp/b" });
    ring.push(.{ .request_id = 1, .outcome = .{ .file_selected = two } });
    ring.push(.{ .request_id = 2, .outcome = .cancelled });
    ring.push(.{ .request_id = 3, .outcome = .{ .failed = error.AccessDenied } });
    ring.drainInto(&queue);
    const events = queue.pending();
    try std.testing.expectEqual(@as(usize, 3), events.len);
    var paths = events[0].completion.outcome.file_selected.iterator();
    try std.testing.expectEqualStrings("/tmp/a.txt", paths.next().?);
    try std.testing.expectEqualStrings("/tmp/b", paths.next().?);
    try std.testing.expect(paths.next() == null);
    try std.testing.expect(events[1].completion.outcome == .cancelled);
    try std.testing.expectEqual(error.AccessDenied, events[2].completion.outcome.failed);
}

test "paths join without copying one path and refuse platform errors" {
    // Goal: the join is exact at its edges. Method: one path keeps its
    // memory; two paths fill a scratch of exactly their joined size, and one
    // byte less fails; an empty path or one with a NUL is refused.
    var scratch: [7]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&scratch);
    const path = "/a/b.txt";
    const one = try Paths.join(fixed.allocator(), &.{path});
    try std.testing.expectEqual(@as(u32, 1), one.count);
    try std.testing.expectEqual(path.ptr, one.bytes.ptr);
    try std.testing.expectEqualStrings(path, one.first());
    const two = try Paths.join(fixed.allocator(), &.{ "/abc", "/d" });
    try std.testing.expectEqualStrings("/abc\x00/d", two.bytes);
    try std.testing.expectEqualStrings("/abc", two.first());
    fixed.reset();
    try std.testing.expectError(error.OutOfMemory, Paths.join(fixed.allocator(), &.{
        "/abcd",
        "/d",
    }));
    try std.testing.expectError(error.InvalidPath, Paths.join(fixed.allocator(), &.{ "/a", "" }));
    try std.testing.expectError(error.InvalidPath, Paths.join(fixed.allocator(), &.{"/a\x00b"}));
}
