//! Text engines and their dedicated pools (contract §3, approved decision 6).
//!
//! The single-line input engine: a fixed byte buffer, a caret and selection
//! anchor, an IME preedit, and an undo history, edited by key, text, and
//! composition events with 0.3.1's bindings (edit commands use the platform's
//! command modifier). Each pool slot reserves `bytes_max` text bytes,
//! `bytes_max` history bytes, and `undo_depth_max` edits at init and never
//! grows; a full buffer keeps what fits of further input (an operating limit
//! the app declared, not a programmer error). Copy, cut, and paste go through
//! the window's clipboard (`clipboard.zig`), which has no public API.
//!
//! An engine pool is registered with the store as an entity pool, so a
//! component targets its engine with `cx.on(InputEngine.onKey, .{ .entity =
//! handle })` and the router invokes it like any other handler.
//!
//! The caret is shown for `blink_interval_ms` after each edit or move, then
//! blinks: `prepare` computes the phase at build and asks for a render at the
//! next toggle through the window's one render deadline (decision 10).

const std = @import("std");
const builtin = @import("builtin");
const id_mod = @import("id.zig");
const handler_mod = @import("handler.zig");
const retained = @import("retained.zig");
const history_mod = @import("text_history.zig");
const clipboard_mod = @import("clipboard.zig");
const input = @import("../input/mod.zig");
const Cx = @import("cx.zig").Cx;
const Color = @import("../geometry/geometry.zig").Color;

const assert = std.debug.assert;

pub const ElementId = id_mod.ElementId;
pub const History = history_mod.History;
pub const Clipboard = clipboard_mod.Clipboard;

/// Preedit bytes one engine holds. IME candidates are short phrases.
pub const preedit_bytes_max: u32 = 256;

/// The caret's on and off phases, as in 0.3.1.
pub const blink_interval_ms: u32 = 530;

pub const InputEngine = struct {
    bytes: []u8,
    len: u32,
    cursor: u32,
    /// The other end of the selection; equal to `cursor` when none.
    anchor: u32,
    preedit: [preedit_bytes_max]u8,
    preedit_len: u32,
    history: History,
    /// Window clock of the last edit or caret move, set by `prepare`.
    caret_moved_ns: u64,
    /// An edit or move since the last build restarts the blink.
    caret_moved: bool,
    /// The app field this engine mirrors, captured each build (`TextInput`).
    bind: ?*[]const u8,
    /// What the input's paint function draws this tick, set each build.
    /// `placeholder` is read during this tick's emit only (contract rule 6).
    view: View,

    pub const View = struct {
        id: ElementId,
        focused: bool,
        caret_visible: bool,
        placeholder: []const u8,
        text_color: Color,
        placeholder_color: Color,
        selection_color: Color,
        caret_color: Color,
        preedit_underline_color: Color,
    };

    /// Called by the pool after it binds `bytes` and the history storage.
    pub fn reset(self: *InputEngine) void {
        assert(self.bytes.len > 0);
        self.len = 0;
        self.cursor = 0;
        self.anchor = 0;
        self.preedit_len = 0;
        self.history.clear();
        self.caret_moved_ns = 0;
        self.caret_moved = true;
        self.bind = null;
        self.view = .{
            .id = .root,
            .focused = false,
            .caret_visible = false,
            .placeholder = "",
            .text_color = Color.black,
            .placeholder_color = Color.black,
            .selection_color = Color.black,
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

    pub fn hasSelection(self: *const InputEngine) bool {
        assert(self.anchor <= self.len);
        return self.anchor != self.cursor;
    }

    pub fn selectionStart(self: *const InputEngine) u32 {
        return @min(self.anchor, self.cursor);
    }

    pub fn selectionEnd(self: *const InputEngine) u32 {
        return @max(self.anchor, self.cursor);
    }

    /// Replace the text, keeping what fits, and move the caret to its end.
    /// The history starts over: the old edits no longer describe the text.
    pub fn setText(self: *InputEngine, value: []const u8) void {
        assert(value.len == 0 or @intFromPtr(value.ptr) != @intFromPtr(self.bytes.ptr));
        const kept = clipboard_mod.prefixFitting(value, self.bytes.len);
        @memcpy(self.bytes[0..kept], value[0..kept]);
        self.len = @intCast(kept);
        self.cursor = self.len;
        self.anchor = self.len;
        self.preedit_len = 0;
        self.history.clear();
        self.caret_moved = true;
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
            self.anchor = @min(self.anchor, self.len);
            self.preedit_len = 0;
            self.history.clear();
            return;
        }
        if (value.len == self.len and std.mem.eql(u8, value, self.text())) return;
        self.setText(value);
        binding.* = self.text();
    }

    /// Restart the blink after an edit, then show the caret for the phase
    /// `now_ns` falls in and return the delay to the next toggle (null while
    /// unfocused, when the caret does not blink). Called once per build.
    pub fn prepare(self: *InputEngine, focused: bool, now_ns: u64) ?u32 {
        if (self.caret_moved or !focused) {
            self.caret_moved = false;
            self.caret_moved_ns = now_ns;
        }
        assert(now_ns >= self.caret_moved_ns);
        self.view.focused = focused;
        self.view.caret_visible = false;
        if (!focused) return null;
        const interval_ns: u64 = @as(u64, blink_interval_ms) * std.time.ns_per_ms;
        const elapsed_ns = now_ns - self.caret_moved_ns;
        self.view.caret_visible = (elapsed_ns / interval_ns) % 2 == 0;
        const remaining_ns = interval_ns - elapsed_ns % interval_ns;
        const delay_ms = std.math.divCeil(u64, remaining_ns, std.time.ns_per_ms) catch
            unreachable; // The divisor is a nonzero constant.
        assert(delay_ms > 0);
        assert(delay_ms <= blink_interval_ms);
        return @intCast(delay_ms);
    }

    /// `prepare` on the window clock, asking the window to render at the
    /// caret's next toggle. Components call it once per build.
    pub fn blink(self: *InputEngine, cx: *Cx, focused: bool) void {
        assert(cx.window.phase == .build);
        const delay_ms = self.prepare(focused, cx.window.now_ns) orelse return;
        cx.requestRenderAfter(delay_ms);
    }

    /// Replace `start..end` with `value`, keeping what fits, and put the
    /// caret after it. Every edit goes through here, so each is recorded.
    fn replace(self: *InputEngine, start: u32, end: u32, value: []const u8) void {
        assert(start <= end);
        assert(end <= self.len);
        const room = self.bytes.len - (self.len - (end - start));
        const kept: u32 = @intCast(clipboard_mod.prefixFitting(value, room));
        if (end == start and kept == 0) return;
        self.history.record(.{
            .offset = start,
            .deleted_len = end - start,
            .inserted_len = kept,
            .bytes_start = 0,
            .cursor_before = self.cursor,
            .anchor_before = self.anchor,
        }, self.bytes[start..end], value[0..kept]);
        self.splice(start, end, value[0..kept]);
        self.cursor = start + kept;
        self.anchor = self.cursor;
    }

    /// Replace `start..end` with `value`, which must fit.
    fn splice(self: *InputEngine, start: u32, end: u32, value: []const u8) void {
        assert(start <= end);
        assert(self.len - (end - start) + value.len <= self.bytes.len);
        const tail_len = self.len - end;
        const target = start + @as(u32, @intCast(value.len));
        if (target > end) {
            std.mem.copyBackwards(u8, self.bytes[target..][0..tail_len], self.bytes[end..self.len]);
        } else {
            std.mem.copyForwards(u8, self.bytes[target..][0..tail_len], self.bytes[end..self.len]);
        }
        @memcpy(self.bytes[start..target], value);
        self.len = target + tail_len;
        self.caret_moved = true;
        assert(self.len <= self.bytes.len);
    }

    /// Insert committed text over the selection. Committing ends any
    /// composition, so the preedit is discarded first. Only a typed
    /// codepoint joins the typing run; a longer commit (an IME phrase) is
    /// an undo step of its own.
    pub fn insert(self: *InputEngine, value: []const u8) void {
        assert(self.cursor <= self.len);
        self.preedit_len = 0;
        if (oneCodepoint(value)) {
            return self.replace(self.selectionStart(), self.selectionEnd(), value);
        }
        self.replaceAsStep(self.selectionStart(), self.selectionEnd(), value);
    }

    /// `replace` as its own undo step, never merged with typing around it.
    fn replaceAsStep(self: *InputEngine, start: u32, end: u32, value: []const u8) void {
        self.history.seal();
        self.replace(start, end, value);
        self.history.seal();
    }

    pub fn setPreedit(self: *InputEngine, value: []const u8) void {
        const kept = clipboard_mod.prefixFitting(value, preedit_bytes_max);
        @memcpy(self.preedit[0..kept], value[0..kept]);
        self.preedit_len = @intCast(kept);
        assert(self.preedit_len <= preedit_bytes_max);
    }

    fn deleteSelection(self: *InputEngine) void {
        assert(self.hasSelection());
        self.replace(self.selectionStart(), self.selectionEnd(), "");
    }

    /// Delete the selection, or the codepoint before the caret.
    pub fn backspace(self: *InputEngine) void {
        if (self.hasSelection()) return self.deleteSelection();
        if (self.cursor == 0) return;
        self.replace(previousBoundary(self.text(), self.cursor), self.cursor, "");
    }

    /// Delete the selection, or the codepoint after the caret.
    pub fn deleteForward(self: *InputEngine) void {
        if (self.hasSelection()) return self.deleteSelection();
        if (self.cursor == self.len) return;
        self.replace(self.cursor, nextBoundary(self.text(), self.cursor), "");
    }

    /// Move the caret to `target`; `extend` keeps the anchor (shift).
    fn moveTo(self: *InputEngine, target: u32, extend: bool) void {
        assert(target <= self.len);
        self.cursor = target;
        if (!extend) self.anchor = target;
        self.history.seal();
        self.caret_moved = true;
    }

    /// Left or right with 0.3.1's modifiers: shift extends, the command
    /// modifier goes to the line's end, alt moves by word, and an unshifted
    /// move with a selection collapses it to that side.
    fn moveHorizontal(self: *InputEngine, forward: bool, mods: input.Modifiers) void {
        if (!mods.shift and self.hasSelection()) {
            const edge = if (forward) self.selectionEnd() else self.selectionStart();
            return self.moveTo(edge, false);
        }
        const text_now = self.text();
        const target = if (editCommand(mods))
            (if (forward) self.len else 0)
        else if (mods.alt)
            (if (forward) nextWord(text_now, self.cursor) else previousWord(text_now, self.cursor))
        else if (forward)
            (if (self.cursor < self.len) nextBoundary(self.text(), self.cursor) else self.len)
        else
            (if (self.cursor > 0) previousBoundary(self.text(), self.cursor) else 0);
        self.moveTo(target, mods.shift);
    }

    /// Reverse the newest applied edit, restoring the caret it moved.
    pub fn undo(self: *InputEngine) void {
        const edit = self.history.undo() orelse return;
        const end = edit.offset + edit.inserted_len;
        self.splice(edit.offset, end, self.history.deletedText(edit));
        self.cursor = edit.cursor_before;
        self.anchor = edit.anchor_before;
        assert(self.cursor <= self.len);
    }

    /// Apply the next undone edit again.
    pub fn redo(self: *InputEngine) void {
        const edit = self.history.redo() orelse return;
        const end = edit.offset + edit.deleted_len;
        self.splice(edit.offset, end, self.history.insertedText(edit));
        self.cursor = edit.offset + edit.inserted_len;
        self.anchor = self.cursor;
        assert(self.cursor <= self.len);
    }

    /// Apply one input event. Returns whether the engine consumed it.
    pub fn apply(self: *InputEngine, event: *const input.InputEvent, clipboard: *Clipboard) bool {
        switch (event.*) {
            .text_input => |typed| self.insert(typed.text),
            .composition => |composing| self.setPreedit(composing.text),
            .key_down => |key| return self.applyKey(key, clipboard),
            else => return false,
        }
        return true;
    }

    fn applyKey(self: *InputEngine, key: input.KeyEvent, clipboard: *Clipboard) bool {
        // Keys go to the IME while it composes.
        if (self.preedit_len > 0) return false;
        if (editCommand(key.modifiers)) {
            if (self.applyCommand(key, clipboard)) return true;
        }
        const extend = key.modifiers.shift;
        switch (key.key) {
            .delete => self.backspace(),
            .forward_delete => self.deleteForward(),
            .left => self.moveHorizontal(false, key.modifiers),
            .right => self.moveHorizontal(true, key.modifiers),
            .home => self.moveTo(0, extend),
            .end => self.moveTo(self.len, extend),
            else => return false,
        }
        return true;
    }

    /// Select all, copy, cut, paste, undo, and redo. Returns false for any
    /// other command key, which bubbles to the app.
    fn applyCommand(self: *InputEngine, key: input.KeyEvent, clipboard: *Clipboard) bool {
        const start = self.selectionStart();
        const end = self.selectionEnd();
        switch (key.key) {
            .a => {
                self.anchor = 0;
                self.moveTo(self.len, true);
            },
            .c => if (end > start) clipboard.write(self.bytes[start..end]),
            .x => if (end > start) {
                clipboard.write(self.bytes[start..end]);
                self.replace(start, end, "");
            },
            .v => {
                const pasted = clipboard.read();
                if (pasted.len > 0) self.replaceAsStep(start, end, pasted);
            },
            .z => if (key.modifiers.shift) self.redo() else self.undo(),
            else => return false,
        }
        return true;
    }

    /// Handler for the input's key, text, and composition events.
    pub fn onKey(self: *InputEngine, effects: *handler_mod.Effects) void {
        const event = effects.inputEvent() orelse return;
        if (!self.apply(event, effects.clipboard.?)) return;
        if (self.bind) |binding| binding.* = self.text();
        effects.requestRender();
        effects.stopPropagation();
    }
};

/// Edit commands use Cmd on Apple platforms and Ctrl elsewhere, ignored with
/// Alt held. Linux uses Ctrl, not 0.3.1's Super: GNOME's shell takes Super+A
/// and Super+V, and an IME such as ibus-mozc turns Super+letters into preedit
/// text (approved 2026-10-31 after SER9's check).
pub fn editCommand(mods: input.Modifiers) bool {
    if (uses_cmd) return mods.cmd;
    return mods.ctrl and !mods.alt;
}

/// Whether edit commands use Cmd. Native targets know their OS at build time.
/// One wasm build runs in browsers on every OS, so the web host sets this
/// once during init from the browser's platform, before the first frame, and
/// nothing writes it afterwards (0.3.1 used Cmd in every browser).
pub var uses_cmd: bool = builtin.os.tag == .macos;

fn oneCodepoint(value: []const u8) bool {
    if (value.len == 0) return false;
    const length = std.unicode.utf8ByteSequenceLength(value[0]) catch return false;
    return value.len == length;
}

fn isContinuation(byte: u8) bool {
    return byte & 0xC0 == 0x80;
}

fn isSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r';
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

/// The start of the word before `index`, skipping spaces first (0.3.1).
fn previousWord(bytes: []const u8, index: u32) u32 {
    assert(index <= bytes.len);
    var position = index;
    while (position > 0 and isSpace(bytes[position - 1])) position -= 1;
    while (position > 0 and !isSpace(bytes[position - 1])) position -= 1;
    return position;
}

/// The start of the word after `index`: past this word, then its spaces.
fn nextWord(bytes: []const u8, index: u32) u32 {
    assert(index <= bytes.len);
    var position = index;
    while (position < bytes.len and !isSpace(bytes[position])) position += 1;
    while (position < bytes.len and isSpace(bytes[position])) position += 1;
    return @intCast(position);
}

pub const Kind = enum { input, area, editor };

/// The pool of one engine kind.
pub const InputPool = struct {
    slab: retained.Slab,
    text_bytes: []u8,
    history_bytes: []u8,
    edits: []history_mod.Edit,
    bytes_max: u32,
    undo_depth_max: u32,

    const stride: u32 = std.mem.alignForward(u32, @sizeOf(InputEngine), retained.slab_alignment);

    pub const Capacity = struct { count: u32, bytes_max: u32, undo_depth_max: u32 };

    pub fn initInPlace(self: *InputPool, gpa: std.mem.Allocator, capacity: Capacity) !void {
        assert(capacity.count > 0);
        assert(capacity.bytes_max > 0);
        assert(capacity.undo_depth_max > 0);
        const bytes_total = @as(usize, capacity.count) * capacity.bytes_max;
        try self.slab.initInPlace(gpa, "text pool 'input'", stride, capacity.count);
        errdefer self.slab.deinit(gpa);
        self.text_bytes = try gpa.alloc(u8, bytes_total);
        errdefer gpa.free(self.text_bytes);
        self.history_bytes = try gpa.alloc(u8, bytes_total);
        errdefer gpa.free(self.history_bytes);
        const edit_count = @as(usize, capacity.count) * capacity.undo_depth_max;
        self.edits = try gpa.alloc(history_mod.Edit, edit_count);
        self.bytes_max = capacity.bytes_max;
        self.undo_depth_max = capacity.undo_depth_max;
    }

    pub fn deinit(self: *InputPool, gpa: std.mem.Allocator) void {
        assert(self.bytes_max > 0);
        gpa.free(self.edits);
        gpa.free(self.history_bytes);
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
        const bytes_start = @as(usize, slot) * self.bytes_max;
        const edits_start = @as(usize, slot) * self.undo_depth_max;
        engine.bytes = self.text_bytes[bytes_start..][0..self.bytes_max];
        engine.history = History.init(
            self.edits[edits_start..][0..self.undo_depth_max],
            self.history_bytes[bytes_start..][0..self.bytes_max],
        );
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

/// An engine over caller storage, for the tests below.
const TestEngine = struct {
    engine: InputEngine,
    bytes: [16]u8,
    edits: [4]history_mod.Edit,
    history_bytes: [16]u8,
    clipboard_bytes: [16]u8,
    clipboard: Clipboard,

    fn init(self: *TestEngine) void {
        self.engine.bytes = &self.bytes;
        self.engine.history = History.init(&self.edits, &self.history_bytes);
        self.engine.reset();
        self.clipboard = Clipboard.init(&self.clipboard_bytes);
    }

    fn key(self: *TestEngine, code: input.KeyCode, mods: input.Modifiers) bool {
        const event = input.InputEvent{ .key_down = .{
            .key = code,
            .modifiers = mods,
            .characters = null,
            .characters_ignoring_modifiers = null,
            .is_repeat = false,
        } };
        return self.engine.apply(&event, &self.clipboard);
    }

    fn command() input.Modifiers {
        return if (uses_cmd) .{ .cmd = true } else .{ .ctrl = true };
    }
};

test "input engine edits by codepoint and commits over a preedit" {
    // Goal: the edits counter and todo need, including the sequence that
    // asserts in 0.3.1 (a commit straight over a preedit). Method: drive one
    // engine over a 16-byte buffer and read its text after each step.
    var t: TestEngine = undefined;
    t.init();
    const engine = &t.engine;
    engine.insert("caf");
    engine.setPreedit("e\u{301}");
    engine.insert("\u{e9}");
    try std.testing.expectEqualStrings("caf\u{e9}", engine.text());
    try std.testing.expectEqual(@as(u32, 0), engine.preedit_len);
    engine.backspace();
    try std.testing.expectEqualStrings("caf", engine.text());
    try std.testing.expect(t.key(.left, .{}));
    engine.insert("X");
    try std.testing.expectEqualStrings("caXf", engine.text());
    // Full buffer: keep what fits without splitting a codepoint.
    engine.insert("\u{e9}\u{e9}\u{e9}\u{e9}\u{e9}\u{e9}");
    try std.testing.expectEqualStrings("caX\u{e9}\u{e9}\u{e9}\u{e9}\u{e9}\u{e9}f", engine.text());
    engine.insert("\u{e9}");
    try std.testing.expectEqual(@as(u32, 16), engine.len);
    engine.deleteForward();
    try std.testing.expectEqualStrings("caX\u{e9}\u{e9}\u{e9}\u{e9}\u{e9}\u{e9}", engine.text());
}

test "shift moves select, typing replaces the selection, and words and lines move" {
    // Goal: 0.3.1's key bindings. Method: asymmetric text so a wrong word
    // boundary or a selection collapsed to the wrong side changes the text.
    var t: TestEngine = undefined;
    t.init();
    const engine = &t.engine;
    engine.insert("one two  three");
    try std.testing.expect(t.key(.left, .{ .alt = true }));
    try std.testing.expectEqual(@as(u32, 9), engine.cursor);
    try std.testing.expect(t.key(.left, .{ .alt = true, .shift = true }));
    try std.testing.expectEqual(@as(u32, 4), engine.selectionStart());
    try std.testing.expectEqual(@as(u32, 9), engine.selectionEnd());
    engine.insert("2 ");
    try std.testing.expectEqualStrings("one 2 three", engine.text());
    try std.testing.expect(t.key(.right, .{ .shift = true }));
    try std.testing.expect(t.key(.right, .{ .shift = true }));
    // An unshifted move collapses to the side it moves towards.
    try std.testing.expect(t.key(.left, .{}));
    try std.testing.expectEqual(@as(u32, 6), engine.cursor);
    try std.testing.expect(!engine.hasSelection());
    try std.testing.expect(t.key(.right, TestEngine.command()));
    try std.testing.expectEqual(engine.len, engine.cursor);
    try std.testing.expect(t.key(.home, .{ .shift = true }));
    try std.testing.expectEqual(engine.len, engine.selectionEnd());
    engine.backspace();
    try std.testing.expectEqualStrings("", engine.text());
}

test "undo and redo restore text and caret; a new edit drops redo" {
    var t: TestEngine = undefined;
    t.init();
    const engine = &t.engine;
    for ("ab cd") |byte| engine.insert(&.{byte});
    try std.testing.expect(t.key(.z, TestEngine.command()));
    try std.testing.expectEqualStrings("ab", engine.text());
    try std.testing.expectEqual(@as(u32, 2), engine.cursor);
    try std.testing.expect(t.key(.z, TestEngine.command()));
    try std.testing.expectEqualStrings("", engine.text());
    var redo = TestEngine.command();
    redo.shift = true;
    try std.testing.expect(t.key(.z, redo));
    try std.testing.expectEqualStrings("ab", engine.text());
    // Undo a deletion of a selection: the selection comes back.
    try std.testing.expect(t.key(.a, TestEngine.command()));
    engine.backspace();
    try std.testing.expect(t.key(.z, TestEngine.command()));
    try std.testing.expectEqualStrings("ab", engine.text());
    try std.testing.expectEqual(@as(u32, 0), engine.selectionStart());
    try std.testing.expectEqual(@as(u32, 2), engine.selectionEnd());
    engine.insert("x");
    try std.testing.expect(!engine.history.canRedo());
}

test "a paste and an IME phrase are undo steps of their own" {
    // Goal: typing next to a paste or a commit does not join its step (the
    // Mac runner's TextEdit comparison). Method: paste "abc", type "Q",
    // commit "日本", type "z"; each undo removes exactly one of the four.
    var t: TestEngine = undefined;
    t.init();
    const engine = &t.engine;
    t.clipboard.write("abc");
    try std.testing.expect(t.key(.v, TestEngine.command()));
    engine.insert("Q");
    engine.insert("\u{65e5}\u{672c}");
    engine.insert("z");
    try std.testing.expectEqualStrings("abcQ\u{65e5}\u{672c}z", engine.text());
    const steps = [_][]const u8{ "abcQ\u{65e5}\u{672c}", "abcQ", "abc", "" };
    for (steps) |expected| {
        try std.testing.expect(t.key(.z, TestEngine.command()));
        try std.testing.expectEqualStrings(expected, engine.text());
    }
}

test "copy, cut, and paste go through the clipboard; other commands bubble" {
    var t: TestEngine = undefined;
    t.init();
    const engine = &t.engine;
    engine.insert("hello world");
    try std.testing.expect(t.key(.left, .{ .alt = true, .shift = true }));
    try std.testing.expect(t.key(.c, TestEngine.command()));
    try std.testing.expectEqualStrings("world", t.clipboard.read());
    try std.testing.expect(t.key(.x, TestEngine.command()));
    try std.testing.expectEqualStrings("hello ", engine.text());
    try std.testing.expect(t.key(.home, .{}));
    try std.testing.expect(t.key(.v, TestEngine.command()));
    try std.testing.expectEqualStrings("worldhello ", engine.text());
    try std.testing.expectEqual(@as(u32, 5), engine.cursor);
    // Copy with no selection writes nothing; cmd-s is the app's.
    t.clipboard.flush();
    try std.testing.expect(t.key(.c, TestEngine.command()));
    try std.testing.expect(t.clipboard.pending_len == null);
    try std.testing.expect(!t.key(.s, TestEngine.command()));
    try std.testing.expect(!t.key(.@"return", .{}));
}

test "edit commands use Cmd on macOS and Ctrl elsewhere, not with Alt" {
    // Goal: the approved Linux change keeps Super out and Ctrl+Alt (AltGr
    // on Windows layouts) from acting as a command.
    try std.testing.expectEqual(uses_cmd, editCommand(.{ .cmd = true }));
    try std.testing.expectEqual(!uses_cmd, editCommand(.{ .ctrl = true }));
    try std.testing.expect(!editCommand(.{ .ctrl = true, .alt = true }));
    try std.testing.expect(!editCommand(.{ .alt = true }));
}

test "the caret shows after a move, then blinks at 530 ms" {
    // Goal: blink phases and the delay to the next toggle. Method: prepare at
    // instants on both sides of each 530 ms boundary.
    var t: TestEngine = undefined;
    t.init();
    const engine = &t.engine;
    const ms = std.time.ns_per_ms;
    try std.testing.expectEqual(@as(?u32, 530), engine.prepare(true, 1000 * ms));
    try std.testing.expect(engine.view.caret_visible);
    try std.testing.expectEqual(@as(?u32, 1), engine.prepare(true, 1529 * ms));
    try std.testing.expect(engine.view.caret_visible);
    try std.testing.expectEqual(@as(?u32, 530), engine.prepare(true, 1530 * ms));
    try std.testing.expect(!engine.view.caret_visible);
    try std.testing.expect(engine.prepare(true, 2060 * ms) != null);
    try std.testing.expect(engine.view.caret_visible);
    // An edit restarts the on phase; an unfocused input asks for nothing.
    engine.insert("a");
    _ = engine.prepare(true, 2400 * ms);
    try std.testing.expect(engine.view.caret_visible);
    try std.testing.expectEqual(@as(?u32, null), engine.prepare(false, 2500 * ms));
    try std.testing.expect(!engine.view.caret_visible);
}
