//! Text engines and their dedicated pools (contract §3, approved decision 6).
//!
//! Milestone 1 implements the single-line input engine: a fixed byte buffer,
//! a caret, and an IME preedit, edited by key, text, and composition events.
//! Each pool slot reserves `bytes_max` text bytes at init and never grows; a
//! full buffer drops further input and keeps what fits (an operating limit
//! the app declared, not a programmer error). Selection, undo, and the area
//! and editor engines arrive with the phase 4 text-engine port; their pools
//! reserve nothing while their counts are 0.
//!
//! An engine pool is registered with the store as an entity pool, so a
//! component targets its engine with `cx.on(InputEngine.onKey, .{ .entity =
//! handle })` and the router invokes it like any other handler.

const std = @import("std");
const id_mod = @import("id.zig");
const handler_mod = @import("handler.zig");
const retained = @import("retained.zig");
const input = @import("../input/mod.zig");
const Color = @import("../geometry/geometry.zig").Color;

const assert = std.debug.assert;

pub const ElementId = id_mod.ElementId;

/// Preedit bytes one engine holds. IME candidates are short phrases.
pub const preedit_bytes_max: u32 = 256;

pub const InputEngine = struct {
    bytes: []u8,
    len: u32,
    cursor: u32,
    preedit: [preedit_bytes_max]u8,
    preedit_len: u32,
    /// The app field this engine mirrors, captured each build (`TextInput`).
    bind: ?*[]const u8,
    /// What the input's paint function draws this tick, set each build.
    /// `placeholder` is read during this tick's emit only (contract rule 6).
    view: View,

    pub const View = struct {
        id: ElementId,
        focused: bool,
        placeholder: []const u8,
        text_color: Color,
        placeholder_color: Color,
        caret_color: Color,
        preedit_underline_color: Color,
    };

    /// Called by the pool after it binds `bytes`.
    pub fn reset(self: *InputEngine) void {
        assert(self.bytes.len > 0);
        self.len = 0;
        self.cursor = 0;
        self.preedit_len = 0;
        self.bind = null;
        self.view = .{
            .id = .root,
            .focused = false,
            .placeholder = "",
            .text_color = Color.black,
            .placeholder_color = Color.black,
            .caret_color = Color.black,
            .preedit_underline_color = Color.black,
        };
    }

    pub fn text(self: *const InputEngine) []const u8 {
        assert(self.len <= self.bytes.len);
        return self.bytes[0..self.len];
    }

    pub fn preeditText(self: *const InputEngine) []const u8 {
        assert(self.preedit_len <= preedit_bytes_max);
        return self.preedit[0..self.preedit_len];
    }

    /// Replace the text, keeping what fits, and move the caret to its end.
    pub fn setText(self: *InputEngine, value: []const u8) void {
        assert(value.len == 0 or @intFromPtr(value.ptr) != @intFromPtr(self.bytes.ptr));
        const kept = prefixFitting(value, self.bytes.len);
        @memcpy(self.bytes[0..kept], value[0..kept]);
        self.len = @intCast(kept);
        self.cursor = self.len;
        self.preedit_len = 0;
        assert(self.cursor <= self.len);
    }

    /// Adopt the bound value when the app changed it since the last edit.
    pub fn syncBound(self: *InputEngine, binding: *[]const u8) void {
        self.bind = binding;
        const value = binding.*;
        const mirrors = value.ptr == self.bytes.ptr and value.len == self.len;
        if (mirrors) return;
        if (value.len > 0 and value.ptr == self.bytes.ptr and value.len < self.len) {
            // The app shortened the engine's own text in place.
            self.len = @intCast(value.len);
            self.cursor = @min(self.cursor, self.len);
            self.preedit_len = 0;
            return;
        }
        if (value.len == self.len and std.mem.eql(u8, value, self.text())) return;
        self.setText(value);
        binding.* = self.text();
    }

    /// Insert committed text at the caret. Committing ends any composition,
    /// so the preedit is discarded first.
    pub fn insert(self: *InputEngine, value: []const u8) void {
        assert(self.cursor <= self.len);
        self.preedit_len = 0;
        const room = self.bytes.len - self.len;
        const kept = prefixFitting(value, room);
        const tail = self.bytes[self.cursor..self.len];
        std.mem.copyBackwards(u8, self.bytes[self.cursor + kept ..][0..tail.len], tail);
        @memcpy(self.bytes[self.cursor..][0..kept], value[0..kept]);
        self.len += @intCast(kept);
        self.cursor += @intCast(kept);
        assert(self.len <= self.bytes.len);
    }

    pub fn setPreedit(self: *InputEngine, value: []const u8) void {
        const kept = prefixFitting(value, preedit_bytes_max);
        @memcpy(self.preedit[0..kept], value[0..kept]);
        self.preedit_len = @intCast(kept);
        assert(self.preedit_len <= preedit_bytes_max);
    }

    /// Delete the codepoint before the caret.
    pub fn backspace(self: *InputEngine) void {
        if (self.cursor == 0) return;
        const start = previousBoundary(self.text(), self.cursor);
        self.removeRange(start, self.cursor);
        self.cursor = start;
    }

    /// Delete the codepoint after the caret.
    pub fn deleteForward(self: *InputEngine) void {
        if (self.cursor == self.len) return;
        self.removeRange(self.cursor, nextBoundary(self.text(), self.cursor));
    }

    pub fn moveLeft(self: *InputEngine) void {
        if (self.cursor > 0) self.cursor = previousBoundary(self.text(), self.cursor);
    }

    pub fn moveRight(self: *InputEngine) void {
        if (self.cursor < self.len) self.cursor = nextBoundary(self.text(), self.cursor);
    }

    fn removeRange(self: *InputEngine, start: u32, end: u32) void {
        assert(start < end);
        assert(end <= self.len);
        const tail_len = self.len - end;
        std.mem.copyForwards(u8, self.bytes[start..][0..tail_len], self.bytes[end..self.len]);
        self.len -= end - start;
    }

    /// Apply one input event. Returns whether the engine changed.
    pub fn apply(self: *InputEngine, event: *const input.InputEvent) bool {
        switch (event.*) {
            .text_input => |typed| self.insert(typed.text),
            .composition => |composing| self.setPreedit(composing.text),
            .key_down => |key| return self.applyKey(key.key),
            else => return false,
        }
        return true;
    }

    fn applyKey(self: *InputEngine, key: input.KeyCode) bool {
        // Keys go to the IME while it composes.
        if (self.preedit_len > 0) return false;
        switch (key) {
            .delete => self.backspace(),
            .forward_delete => self.deleteForward(),
            .left => self.moveLeft(),
            .right => self.moveRight(),
            .home => self.cursor = 0,
            .end => self.cursor = self.len,
            else => return false,
        }
        return true;
    }

    /// Handler for the input's key, text, and composition events.
    pub fn onKey(self: *InputEngine, effects: *handler_mod.Effects) void {
        const event = effects.inputEvent() orelse return;
        if (!self.apply(event)) return;
        if (self.bind) |binding| binding.* = self.text();
        effects.stopPropagation();
    }
};

/// The longest prefix of `value` that fits `room` bytes without splitting a
/// UTF-8 sequence.
fn prefixFitting(value: []const u8, room: usize) usize {
    if (value.len <= room) return value.len;
    var end = room;
    while (end > 0 and isContinuation(value[end])) end -= 1;
    assert(end <= room);
    return end;
}

fn isContinuation(byte: u8) bool {
    return byte & 0xC0 == 0x80;
}

fn previousBoundary(bytes: []const u8, index: u32) u32 {
    assert(index > 0);
    var position = index - 1;
    while (position > 0 and isContinuation(bytes[position])) position -= 1;
    return position;
}

fn nextBoundary(bytes: []const u8, index: u32) u32 {
    assert(index < bytes.len);
    var position = index + 1;
    while (position < bytes.len and isContinuation(bytes[position])) position += 1;
    return position;
}

pub const Kind = enum { input, area, editor };

/// The pool of one engine kind. Milestone 1 builds the `input` pool only.
pub const InputPool = struct {
    slab: retained.Slab,
    text_bytes: []u8,
    bytes_max: u32,

    const stride: u32 = std.mem.alignForward(u32, @sizeOf(InputEngine), retained.slab_alignment);

    pub fn initInPlace(self: *InputPool, gpa: std.mem.Allocator, count: u32, bytes_max: u32) !void {
        assert(count > 0);
        assert(bytes_max > 0);
        try self.slab.initInPlace(gpa, "text pool 'input'", stride, count);
        errdefer self.slab.deinit(gpa);
        self.text_bytes = try gpa.alloc(u8, @as(usize, count) * bytes_max);
        self.bytes_max = bytes_max;
    }

    pub fn deinit(self: *InputPool, gpa: std.mem.Allocator) void {
        assert(self.bytes_max > 0);
        gpa.free(self.text_bytes);
        self.slab.deinit(gpa);
    }

    /// The store entry that makes engines handler targets.
    pub fn entityPool(self: *const InputPool) handler_mod.EntityPool {
        return .{
            .type_id = handler_mod.typeId(InputEngine),
            .name = self.slab.name,
            .base = self.slab.bytes.ptr,
            .stride = self.slab.stride,
            .generations = self.slab.generations,
        };
    }

    /// Find or claim the engine for `id`. A claimed engine is reset, then
    /// `init` runs once.
    pub fn retain(
        self: *InputPool,
        id: ElementId,
        lifetime: retained.Lifetime,
        frame: u64,
        comptime init: fn (engine: *InputEngine) void,
    ) retained.Handle(InputEngine) {
        assert(id.isKeyed());
        const type_id = handler_mod.typeId(InputEngine);
        if (self.slab.find(id, type_id)) |slot| {
            self.slab.touch(slot, lifetime, frame);
            return .{ .slot = slot, .generation = self.slab.generations[slot] };
        }
        const slot = self.slab.claim(id, type_id, lifetime, frame);
        const engine: *InputEngine = @ptrCast(self.slab.slotBytes(slot).ptr);
        engine.bytes = self.text_bytes[@as(usize, slot) * self.bytes_max ..][0..self.bytes_max];
        engine.reset();
        init(engine);
        return .{ .slot = slot, .generation = self.slab.generations[slot] };
    }

    pub fn get(self: *InputPool, handle: retained.Handle(InputEngine)) *InputEngine {
        assert(handle.slot < self.slab.slotCount());
        assert(self.slab.meta[handle.slot].in_use);
        assert(self.slab.generations[handle.slot] == handle.generation);
        return @ptrCast(self.slab.slotBytes(handle.slot).ptr);
    }
};

test "input engine edits by codepoint and commits over a preedit" {
    // Goal: the edits counter and todo need, including the sequence that
    // asserts in 0.3.1 (a commit straight over a preedit). Method: drive one
    // engine over an 8-byte buffer and read its text after each step.
    var storage: [8]u8 = undefined;
    var engine: InputEngine = undefined;
    engine.bytes = &storage;
    engine.reset();
    engine.insert("caf");
    engine.setPreedit("e\u{301}");
    engine.insert("\u{e9}");
    try std.testing.expectEqualStrings("caf\u{e9}", engine.text());
    try std.testing.expectEqual(@as(u32, 0), engine.preedit_len);
    engine.backspace();
    try std.testing.expectEqualStrings("caf", engine.text());
    engine.moveLeft();
    engine.insert("X");
    try std.testing.expectEqualStrings("caXf", engine.text());
    // Full buffer: keep what fits without splitting a codepoint.
    engine.insert("\u{e9}\u{e9}\u{e9}");
    try std.testing.expectEqualStrings("caX\u{e9}\u{e9}f", engine.text());
    try std.testing.expectEqual(@as(u32, 8), engine.len);
    engine.deleteForward();
    try std.testing.expectEqualStrings("caX\u{e9}\u{e9}", engine.text());
}
