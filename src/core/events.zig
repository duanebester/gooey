//! The bounded event queue and the completion ring.
//!
//! `tick` drains the whole queue once per tick, so a push never waits on a
//! handler and a handler never runs inside a platform callback. Event text
//! is copied into the queue's own bytes at push and stays valid until the
//! drain that delivers it ends.
//!
//! Overflow policy: consecutive pointer moves (with or without the same held
//! button) and scroll deltas coalesce. Any other overflow panics with the
//! queue's name and capacity.

const std = @import("std");
const input = @import("../input/mod.zig");
const clipboard = @import("clipboard.zig");

const assert = std.debug.assert;

pub const InputEvent = input.InputEvent;

pub const WindowEvent = union(enum) {
    resized: struct { width: f32, height: f32, scale_factor: f32 },
    /// The window controls the content must stay clear of changed
    /// (`Config.title_bar = .transparent`, macOS only).
    title_bar: TitleBar.Inset,
    close_requested,
};

/// How the window's title bar meets the content (`Config.title_bar`).
///
/// macOS only; every other platform ignores it and draws its usual frame.
pub const TitleBar = enum {
    standard,
    transparent,

    /// The window-control area a transparent title bar draws over the
    /// content, in logical pixels. `top` is the height of the title strip;
    /// `left` or `right` is how far the traffic lights reach in from that
    /// edge, with the margin AppKit leaves on their outer side mirrored on
    /// the inner one (they sit on the right in right-to-left languages).
    /// All zero for `.standard`, off macOS, and in full screen, where the
    /// title bar slides in over the content only on demand.
    pub const Inset = struct {
        top: f32 = 0,
        left: f32 = 0,
        right: f32 = 0,
    };
};

/// The result of an operation that finished outside the handler that asked
/// for it.
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
/// unambiguous, and one path is kept without a copy.
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

    pub fn iterator(self: Paths) std.mem.SplitIterator(u8, .scalar) {
        assert(self.count > 0);
        assert(self.bytes.len >= 2 * self.count - 1);
        return std.mem.splitScalar(u8, self.bytes, separator);
    }

    pub fn first(self: Paths) []const u8 {
        var paths = self.iterator();
        const path = paths.first();
        assert(path.len > 0);
        return path;
    }

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

/// One delivery from a background job (`jobs.zig`): a result it posted, or
/// its end.
pub const JobEntry = struct {
    slot: u32,
    generation: u32,
    kind: Kind,
    /// The result slot holding the posted bytes, for `.result`.
    result_index: u32,
    /// How `run` ended, for `.done`.
    outcome: Outcome,
    /// The error `run` returned, for `outcome == .failed`.
    failure: anyerror,

    pub const Kind = enum(u8) { result, done };
    pub const Outcome = enum(u8) { finished, cancelled, failed };

    pub const result_index_none: u32 = std.math.maxInt(u32);
};

/// The job deliveries one drain took from the completion ring, in ring
/// order. Its capacity is the ring's, so a drain can never overfill it, and
/// job deliveries never take event-queue slots that input needs.
pub const JobInbox = struct {
    entries: []JobEntry,
    count: u32,

    pub fn pending(self: *const JobInbox) []const JobEntry {
        assert(self.count <= self.entries.len);
        return self.entries[0..self.count];
    }

    fn add(self: *JobInbox, entry: JobEntry) void {
        assert(self.count < self.entries.len);
        if (entry.kind == .result) assert(entry.result_index != JobEntry.result_index_none);
        self.entries[self.count] = entry;
        self.count += 1;
    }
};

pub const QueueCapacity = struct {
    event_count_max: u32,
    text_bytes_max: u32,
    /// `events.dialog_count_max`: request ids, so path slots.
    dialog_count_max: u32,
    dialog_path_bytes_max: u32,
};

pub const EventQueue = struct {
    events: []Event,
    count: u32,
    text_bytes: []u8,
    text_len: u32,
    /// A queued completion's paths, in its request id's slot of
    /// `dialog_path_bytes_max` bytes. Text a platform pushes (typed text is
    /// cut to the room left, never refused) can fill `text_bytes` at any
    /// time, so paths there could find no room; each request id has at
    /// most one completion queued, since its slot frees only when routed.
    dialog_paths: []u8,
    dialog_path_bytes_max: u32,
    /// Events coalesced since init, for tests and diagnostics.
    coalesced_count: u64,

    pub fn initInPlace(self: *EventQueue, gpa: std.mem.Allocator, capacity: QueueCapacity) !void {
        assert(capacity.event_count_max > 0);
        assert(capacity.text_bytes_max > 0);
        assert(capacity.dialog_count_max > 0);
        assert(capacity.dialog_path_bytes_max > 0);
        self.events = try gpa.alloc(Event, capacity.event_count_max);
        errdefer gpa.free(self.events);

        self.text_bytes = try gpa.alloc(u8, capacity.text_bytes_max);
        errdefer gpa.free(self.text_bytes);

        const paths_bytes = @as(usize, capacity.dialog_count_max) * capacity.dialog_path_bytes_max;
        self.dialog_paths = try gpa.alloc(u8, paths_bytes);
        self.dialog_path_bytes_max = capacity.dialog_path_bytes_max;
        self.count = 0;
        self.text_len = 0;
        self.coalesced_count = 0;
    }

    pub fn deinit(self: *EventQueue, gpa: std.mem.Allocator) void {
        assert(self.count <= self.events.len);
        assert(self.dialog_paths.len % self.dialog_path_bytes_max == 0);
        gpa.free(self.dialog_paths);
        gpa.free(self.text_bytes);
        gpa.free(self.events);
        self.* = undefined;
    }

    /// Free event slots. A native host reads more input only while this
    /// holds its largest burst (`EventLimits.checkInputRoom`).
    pub fn room(self: *const EventQueue) u32 {
        assert(self.count <= self.events.len);
        const free: u32 = @intCast(self.events.len - self.count);
        assert(free <= self.events.len);
        return free;
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

    /// Fold a pointer move into a queued move, a held-button move into a
    /// queued one with the same button, or a scroll into a queued scroll,
    /// when it directly follows one. Without the held-button rule a drag
    /// at a 1 kHz mouse fills a 64-event queue in 64 ms of stalled ticks.
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
            .mouse_dragged => |dragged| {
                if (last.input != .mouse_dragged) return false;
                if (last.input.mouse_dragged.button != dragged.button) return false;
                last.input.mouse_dragged = dragged;
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
                    paths.bytes = self.copyPaths(completion.request_id, paths.bytes);
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
        const text_room = self.text_bytes.len - self.text_len;
        const kept = clipboard.prefixFitting(bytes, text_room);
        if (kept < bytes.len) {
            std.log.warn("event queue: {s} of {d} bytes cut to {d}; {d} of {d} text bytes " ++
                "were free. Raise ResourceLimits.events.text_bytes_max.", .{
                kind,
                bytes.len,
                kept,
                text_room,
                self.text_bytes.len,
            });
        }
        assert(kept <= text_room);
        return self.copyBytes(bytes[0..kept]);
    }

    /// Copy a completion's paths into its request id's slot, which no other
    /// queued completion holds. Paths past the slot are a backend's error:
    /// `tick.checkSelection` bounds every selection first.
    fn copyPaths(self: *EventQueue, request_id: u32, bytes: []const u8) []const u8 {
        const slot_count = self.dialog_paths.len / self.dialog_path_bytes_max;
        assert(request_id < slot_count);
        for (self.events[0..self.count]) |*queued| {
            if (queued.* == .completion) assert(queued.completion.request_id != request_id);
        }
        if (bytes.len > self.dialog_path_bytes_max) {
            std.debug.panic("event queue pool 'dialog paths' exhausted: capacity {d} bytes, " ++
                "{d} requested. Raise ResourceLimits.events.dialog_path_bytes_max.", .{
                self.dialog_path_bytes_max,
                bytes.len,
            });
        }
        const start = @as(usize, request_id) * self.dialog_path_bytes_max;
        const target = self.dialog_paths[start..][0..bytes.len];
        @memcpy(target, bytes);
        assert(target.len <= self.dialog_path_bytes_max);
        return target;
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

/// A decode the image worker finished (`images.zig`). Core-internal: the
/// drain hands it to the image loader, never to an app's handler, so it is
/// not a `Completion.Outcome` and apps' switches over outcomes stay exact.
pub const ImageDecoded = struct {
    /// The loader's request entry the decode answers.
    entry: u32,
    width: u32,
    height: u32,
    /// Offset of the RGBA pixels, `width * height * 4` bytes, in staging.
    pixel_offset: u32,
    /// Null when the pixels are ready.
    failure: ?anyerror,
};

/// A bounded multi-producer, single-consumer ring for completions produced
/// on worker threads: the image worker's decodes and background jobs'
/// results and ends. Producers serialize on `producer_mutex`; the consumer,
/// `tick` on the main thread, takes no lock. A dialog's paths
/// are copied into the path slot of its request id, so the worker's buffer
/// can be reused: a request id is reused only after the router delivers its
/// completion, which the drain has copied into the queue by then.
pub const CompletionRing = struct {
    slots: []Slot,
    /// `dialog_count_max` path slots of `path_bytes_max` bytes each.
    paths: []u8,
    path_bytes_max: u32,
    /// Written by the producer, read by the consumer.
    head: std.atomic.Value(u32),
    /// Written by the consumer, read by the producer.
    tail: std.atomic.Value(u32),
    /// Held by a producer from claiming a slot to publishing it.
    producer_mutex: std.Io.Mutex,
    io: std.Io,

    const Slot = struct {
        kind: enum(u8) { completion, image, job },
        request_id: u32,
        tag: std.meta.Tag(Completion.Outcome),
        failure: anyerror,
        path_count: u32,
        path_len: u32,
        image: ImageDecoded,
        job: JobEntry,
    };

    pub const Options = struct {
        /// Ring slots, a power of two at or above `events.completion_count_max`.
        count_max: u32,
        /// `events.dialog_count_max`: request ids, so path slots.
        dialog_count_max: u32,
        /// `events.dialog_path_bytes_max`: one selection's joined paths.
        dialog_path_bytes_max: u32,
        /// For the producers' mutex.
        io: std.Io,
    };

    pub fn initInPlace(self: *CompletionRing, gpa: std.mem.Allocator, options: Options) !void {
        assert(options.count_max > 0);
        assert(std.math.isPowerOfTwo(options.count_max));
        assert(options.dialog_count_max < options.count_max);
        assert(options.dialog_path_bytes_max > 0);
        self.slots = try gpa.alloc(Slot, options.count_max);
        errdefer gpa.free(self.slots);
        const paths_bytes = @as(usize, options.dialog_count_max) * options.dialog_path_bytes_max;
        self.paths = try gpa.alloc(u8, paths_bytes);
        self.path_bytes_max = options.dialog_path_bytes_max;
        self.head = .init(0);
        self.tail = .init(0);
        self.producer_mutex = .init;
        self.io = options.io;
    }

    pub fn deinit(self: *CompletionRing, gpa: std.mem.Allocator) void {
        assert(self.slots.len > 0);
        assert(self.paths.len % self.path_bytes_max == 0);
        gpa.free(self.paths);
        gpa.free(self.slots);
        self.* = undefined;
    }

    /// Producer side. A full ring, or paths past the request's slot, is a
    /// capacity-planning error.
    pub fn push(self: *CompletionRing, completion: Completion) void {
        assert(completion.request_id < self.paths.len / self.path_bytes_max);
        self.producer_mutex.lockUncancelable(self.io);
        defer self.producer_mutex.unlock(self.io);
        const head = self.head.load(.monotonic);
        const slot = self.claim(head);
        slot.kind = .completion;
        slot.request_id = completion.request_id;
        slot.tag = completion.outcome;
        slot.path_count = 0;
        slot.path_len = 0;
        slot.failure = error.Unexpected;
        switch (completion.outcome) {
            .file_selected => |paths| {
                assert(paths.consistent());
                if (paths.bytes.len > self.path_bytes_max) {
                    std.debug.panic("completion ring pool 'dialog paths' exhausted: " ++
                        "capacity {d} bytes, {d} requested. Raise " ++
                        "ResourceLimits.events.dialog_path_bytes_max.", .{
                        self.path_bytes_max,
                        paths.bytes.len,
                    });
                }
                @memcpy(self.pathSlot(completion.request_id)[0..paths.bytes.len], paths.bytes);
                slot.path_count = paths.count;
                slot.path_len = @intCast(paths.bytes.len);
            },
            .cancelled => {},
            .failed => |failure| slot.failure = failure,
        }
        self.head.store(head +% 1, .release);
    }

    fn pathSlot(self: *const CompletionRing, request_id: u32) []u8 {
        const start = @as(usize, request_id) * self.path_bytes_max;
        assert(start < self.paths.len);
        assert(self.path_bytes_max <= self.paths.len - start);
        return self.paths[start..][0..self.path_bytes_max];
    }

    /// Producer side, for the image worker. Same capacity rule as `push`.
    pub fn pushImage(self: *CompletionRing, decoded: ImageDecoded) void {
        if (decoded.failure == null) {
            assert(decoded.width > 0);
            assert(decoded.height > 0);
        }
        self.producer_mutex.lockUncancelable(self.io);
        defer self.producer_mutex.unlock(self.io);
        const head = self.head.load(.monotonic);
        const slot = self.claim(head);
        slot.kind = .image;
        slot.image = decoded;
        self.head.store(head +% 1, .release);
    }

    /// Producer side, for a background job's result or end. The job pool
    /// holds back results past its result slots and each job ends once, so
    /// `ResourceLimits.check` proves the ring cannot fill from jobs.
    pub fn pushJob(self: *CompletionRing, entry: JobEntry) void {
        if (entry.kind == .result) assert(entry.result_index != JobEntry.result_index_none);
        if (entry.kind == .done) assert(entry.result_index == JobEntry.result_index_none);
        self.producer_mutex.lockUncancelable(self.io);
        defer self.producer_mutex.unlock(self.io);
        const head = self.head.load(.monotonic);
        const slot = self.claim(head);
        slot.kind = .job;
        slot.job = entry;
        self.head.store(head +% 1, .release);
    }

    fn claim(self: *CompletionRing, head: u32) *Slot {
        const tail = self.tail.load(.acquire);
        assert(head -% tail <= self.slots.len);
        if (head -% tail == self.slots.len) {
            std.debug.panic("completion ring exhausted: capacity {d}, {d} in use, 1 " ++
                "requested. Raise ResourceLimits.events.completion_count_max.", .{
                self.slots.len,
                self.slots.len,
            });
        }
        return &self.slots[head & (@as(u32, @intCast(self.slots.len)) - 1)];
    }

    /// Consumer side: move every completion into `queue`, the image decode,
    /// of which the worker has at most one outstanding, into `image`, and
    /// every job delivery into `jobs`, which must be empty.
    pub fn drainInto(
        self: *CompletionRing,
        queue: *EventQueue,
        image: *?ImageDecoded,
        jobs: *JobInbox,
    ) void {
        assert(jobs.count == 0);
        assert(jobs.entries.len >= self.slots.len);
        const head = self.head.load(.acquire);
        var tail = self.tail.load(.monotonic);
        assert(head -% tail <= self.slots.len);
        while (tail != head) : (tail +%= 1) {
            const slot = &self.slots[tail & (@as(u32, @intCast(self.slots.len)) - 1)];
            switch (slot.kind) {
                .image => {
                    assert(image.* == null);
                    image.* = slot.image;
                },
                .completion => queue.push(.{ .completion = .{
                    .request_id = slot.request_id,
                    .outcome = self.slotOutcome(slot),
                } }),
                .job => jobs.add(slot.job),
            }
        }
        self.tail.store(tail, .release);
    }

    fn slotOutcome(self: *const CompletionRing, slot: *const Slot) Completion.Outcome {
        assert(slot.kind == .completion);
        assert(slot.path_len <= self.path_bytes_max);
        return switch (slot.tag) {
            .file_selected => .{ .file_selected = .{
                .bytes = self.pathSlot(slot.request_id)[0..slot.path_len],
                .count = slot.path_count,
            } },
            .cancelled => .cancelled,
            .failed => .{ .failed = slot.failure },
        };
    }
};

test "queue coalesces moves and scrolls and copies text" {
    var queue: EventQueue = undefined;
    try queue.initInPlace(std.testing.allocator, .{
        .event_count_max = 4,
        .text_bytes_max = 16,
        .dialog_count_max = 1,
        .dialog_path_bytes_max = 8,
    });
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

    queue.push(.{ .input = .{ .mouse_dragged = move } });
    queue.push(.{ .input = .{ .mouse_dragged = moved } });
    var right = moved;
    right.button = .right;
    queue.push(.{ .input = .{ .mouse_dragged = right } });
    queue.push(.{ .input = .{ .mouse_moved = move } });
    const drags = queue.pending();
    try std.testing.expectEqual(@as(usize, 3), drags.len);
    try std.testing.expectEqual(@as(f64, 9), drags[0].input.mouse_dragged.position.x);
    try std.testing.expectEqual(input.MouseButton.right, drags[1].input.mouse_dragged.button);
    try std.testing.expect(drags[2].input == .mouse_moved);
    try std.testing.expectEqual(@as(u64, 3), queue.coalesced_count);
}

test "platform text past the free text bytes is cut on a codepoint boundary" {
    // Long dictation or an IME commit must never split a UTF-8 sequence or
    // panic. A composition that no longer fits at all arrives empty, which
    // clears the preedit until the next update.
    var long: [255 + "東京".len]u8 = undefined;
    @memset(long[0..255], 'a');
    @memcpy(long[255..], "東京");
    var queue: EventQueue = undefined;
    try queue.initInPlace(std.testing.allocator, .{
        .event_count_max = 4,
        .text_bytes_max = 256,
        .dialog_count_max = 1,
        .dialog_path_bytes_max = 8,
    });
    defer queue.deinit(std.testing.allocator);
    queue.push(.{ .input = .{ .text_input = .{ .text = &long } } });
    const kept = queue.pending()[0].input.text_input.text;
    try std.testing.expectEqual(@as(usize, 255), kept.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(kept));
    queue.push(.{ .input = .{ .composition = .{ .text = "東" } } });
    try std.testing.expectEqualStrings("", queue.pending()[1].input.composition.text);

    var roomy: EventQueue = undefined;
    try roomy.initInPlace(std.testing.allocator, .{
        .event_count_max = 1,
        .text_bytes_max = 512,
        .dialog_count_max = 1,
        .dialog_path_bytes_max = 8,
    });
    defer roomy.deinit(std.testing.allocator);
    roomy.push(.{ .input = .{ .text_input = .{ .text = &long } } });
    try std.testing.expectEqualStrings(&long, roomy.pending()[0].input.text_input.text);
}

test "completion ring delivers distinct outcomes in order" {
    var queue: EventQueue = undefined;
    try queue.initInPlace(std.testing.allocator, .{
        .event_count_max = 4,
        .text_bytes_max = 64,
        .dialog_count_max = 4,
        .dialog_path_bytes_max = 32,
    });
    defer queue.deinit(std.testing.allocator);
    var ring: CompletionRing = undefined;
    try ring.initInPlace(std.testing.allocator, .{
        .count_max = 8,
        .dialog_count_max = 4,
        .dialog_path_bytes_max = 32,
        .io = std.testing.io,
    });
    defer ring.deinit(std.testing.allocator);
    var scratch: [64]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&scratch);
    const two = try Paths.join(fixed.allocator(), &.{ "/tmp/a.txt", "/tmp/b" });
    ring.push(.{ .request_id = 1, .outcome = .{ .file_selected = two } });
    ring.push(.{ .request_id = 2, .outcome = .cancelled });
    ring.pushImage(.{ .entry = 7, .width = 2, .height = 3, .pixel_offset = 5, .failure = null });
    ring.push(.{ .request_id = 3, .outcome = .{ .failed = error.AccessDenied } });
    var image: ?ImageDecoded = null;
    var job_entries: [8]JobEntry = undefined;
    var jobs: JobInbox = .{ .entries = &job_entries, .count = 0 };
    ring.drainInto(&queue, &image, &jobs);
    try std.testing.expectEqual(@as(u32, 0), jobs.count);
    const events = queue.pending();
    try std.testing.expectEqual(@as(usize, 3), events.len);
    try std.testing.expectEqual(@as(u32, 7), image.?.entry);
    try std.testing.expectEqual(@as(u32, 3), image.?.height);
    var paths = events[0].completion.outcome.file_selected.iterator();
    try std.testing.expectEqualStrings("/tmp/a.txt", paths.next().?);
    try std.testing.expectEqualStrings("/tmp/b", paths.next().?);
    try std.testing.expect(paths.next() == null);
    try std.testing.expect(events[1].completion.outcome == .cancelled);
    try std.testing.expectEqual(error.AccessDenied, events[2].completion.outcome.failed);
}

test "completion ring holds a selection of exactly the dialog path budget per request" {
    // The ring once held 1 KiB per slot: a selection between that and the
    // budget panicked. Each pending dialog owns a path slot of
    // `dialog_path_bytes_max` bytes.
    const path_bytes_max: u32 = 8;
    var queue: EventQueue = undefined;
    try queue.initInPlace(std.testing.allocator, .{
        .event_count_max = 4,
        .text_bytes_max = 16,
        .dialog_count_max = 2,
        .dialog_path_bytes_max = path_bytes_max,
    });
    defer queue.deinit(std.testing.allocator);
    var ring: CompletionRing = undefined;
    try ring.initInPlace(std.testing.allocator, .{
        .count_max = 4,
        .dialog_count_max = 2,
        .dialog_path_bytes_max = path_bytes_max,
        .io = std.testing.io,
    });
    defer ring.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2 * path_bytes_max), ring.paths.len);
    var scratch: [path_bytes_max]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&scratch);
    const first = try Paths.join(fixed.allocator(), &.{ "/a/bc", "/d" });
    try std.testing.expectEqual(@as(usize, path_bytes_max), first.bytes.len);
    ring.push(.{ .request_id = 1, .outcome = .{ .file_selected = first } });
    ring.push(.{ .request_id = 0, .outcome = .{ .file_selected = .{
        .bytes = "/abcdefg",
        .count = 1,
    } } });
    @memset(&scratch, 'X');
    var image: ?ImageDecoded = null;
    var job_entries: [8]JobEntry = undefined;
    var jobs: JobInbox = .{ .entries = &job_entries, .count = 0 };
    ring.drainInto(&queue, &image, &jobs);
    try std.testing.expectEqual(@as(u32, 0), jobs.count);
    const events = queue.pending();
    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expect(image == null);
    try std.testing.expectEqual(@as(u32, 1), events[0].completion.request_id);
    const selected = events[0].completion.outcome.file_selected;
    try std.testing.expectEqualStrings("/a/bc\x00/d", selected.bytes);
    try std.testing.expectEqual(@as(u32, 2), selected.count);
    const whole = events[1].completion.outcome.file_selected;
    try std.testing.expectEqualStrings("/abcdefg", whole.bytes);
}

test "a completion's paths fit in a queue whose text bytes typed text filled" {
    // Paths once shared the text bytes, which typed text may fill (it is
    // cut, never refused): a dialog's outcome queued after it, as the Linux
    // host's `pollDialog` queues one, panicked with "text bytes exhausted".
    // Each request id now has its own path slot, used to the last byte.
    var queue: EventQueue = undefined;
    try queue.initInPlace(std.testing.allocator, .{
        .event_count_max = 4,
        .text_bytes_max = 8,
        .dialog_count_max = 2,
        .dialog_path_bytes_max = 8,
    });
    defer queue.deinit(std.testing.allocator);
    queue.push(.{ .input = .{ .text_input = .{ .text = "typed text" } } });
    try std.testing.expectEqual(@as(u32, 8), queue.text_len);
    queue.push(.{ .completion = .{ .request_id = 1, .outcome = .{ .file_selected = .{
        .bytes = "/a\x00/bcde",
        .count = 2,
    } } } });
    queue.push(.{ .completion = .{ .request_id = 0, .outcome = .{ .file_selected = .{
        .bytes = "/1234567",
        .count = 1,
    } } } });
    try std.testing.expectEqual(@as(u32, 8), queue.text_len);
    const events = queue.pending();
    try std.testing.expectEqualStrings("typed te", events[0].input.text_input.text);
    const second = events[1].completion.outcome.file_selected;
    try std.testing.expectEqualStrings("/a\x00/bcde", second.bytes);
    const third = events[2].completion.outcome.file_selected;
    try std.testing.expectEqualStrings("/1234567", third.bytes);
}

test "paths join without copying one path and refuse platform errors" {
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
