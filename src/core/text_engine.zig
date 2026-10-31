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
const Point = @import("router.zig").Point;

const assert = std.debug.assert;

pub const ElementId = id_mod.ElementId;
pub const History = history_mod.History;
pub const Clipboard = clipboard_mod.Clipboard;

/// Preedit bytes one engine holds. IME candidates are short phrases.
pub const preedit_bytes_max: u32 = 256;

/// Pixels an area scrolls per wheel unit, as in 0.3.1.
pub const wheel_step: f32 = 20;

/// The caret's on and off phases, as in 0.3.1.
pub const blink_interval_ms: u32 = 530;

/// What an engine's paint function draws this tick, set each build. One
/// type for every kind, so a component can fill it from the theme once.
pub const EngineView = struct {
    id: ElementId,
    focused: bool,
    caret_visible: bool,
    placeholder: []const u8,
    text_color: Color,
    placeholder_color: Color,
    selection_color: Color,
    caret_color: Color,
    preedit_underline_color: Color,
    /// The area's scrollbar; unused by an input.
    scrollbar_track_color: Color,
    scrollbar_thumb_color: Color,
};

pub const Kind = enum { input, area, editor };

/// The engine of one kind. An input is one line; an area adds lines split
/// on '\n' (no soft wrap, as in 0.3.1), vertical moves, Return inserting a
/// newline, a scroll offset that follows the caret, and click positioning.
pub fn Engine(comptime kind: Kind) type {
    comptime assert(kind != .editor);
    return struct {
        const Self = @This();

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
        /// The byte column vertical moves aim for (area); null after any
        /// other move or edit, so the next vertical move starts from the caret.
        preferred_column: ?u32,
        /// How far the area's lines are scrolled up, in pixels; kept so the
        /// caret's line is visible (`follow`).
        scroll_y: f32,
        /// A click to resolve into a caret position at the next build, in
        /// window coordinates (area). Resolving needs the frame's bounds and
        /// text measurement, which a handler does not have.
        pending_click: ?Point,
        /// What the input's paint function draws this tick, set each build.
        /// `placeholder` is read during this tick's emit only (contract rule 6).
        view: View,

        pub const View = EngineView;

        /// Called by the pool after it binds `bytes` and the history storage.
        pub fn reset(self: *Self) void {
            assert(self.bytes.len > 0);
            self.len = 0;
            self.cursor = 0;
            self.anchor = 0;
            self.preedit_len = 0;
            self.history.clear();
            self.caret_moved_ns = 0;
            self.caret_moved = true;
            self.bind = null;
            self.preferred_column = null;
            self.scroll_y = 0;
            self.pending_click = null;
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
                .scrollbar_track_color = Color.black,
                .scrollbar_thumb_color = Color.black,
            };
        }

        pub fn text(self: *const Self) []const u8 {
            assert(self.len <= self.bytes.len);
            return self.bytes[0..self.len];
        }

        pub fn preeditText(self: *const Self) []const u8 {
            assert(self.preedit_len <= preedit_bytes_max);
            return self.preedit[0..self.preedit_len];
        }

        pub fn hasSelection(self: *const Self) bool {
            assert(self.anchor <= self.len);
            return self.anchor != self.cursor;
        }

        pub fn selectionStart(self: *const Self) u32 {
            return @min(self.anchor, self.cursor);
        }

        pub fn selectionEnd(self: *const Self) u32 {
            return @max(self.anchor, self.cursor);
        }

        /// Replace the text, keeping what fits, and move the caret to its end.
        /// The history starts over: the old edits no longer describe the text.
        pub fn setText(self: *Self, value: []const u8) void {
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
        pub fn syncBound(self: *Self, binding: *[]const u8) void {
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
        pub fn prepare(self: *Self, focused: bool, now_ns: u64) ?u32 {
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
        pub fn blink(self: *Self, cx: *Cx, focused: bool) void {
            assert(cx.window.phase == .build);
            const delay_ms = self.prepare(focused, cx.window.now_ns) orelse return;
            cx.requestRenderAfter(delay_ms);
        }

        /// Replace `start..end` with `value`, keeping what fits, and put the
        /// caret after it. Every edit goes through here, so each is recorded.
        fn replace(self: *Self, start: u32, end: u32, value: []const u8) void {
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
        fn splice(self: *Self, start: u32, end: u32, value: []const u8) void {
            assert(start <= end);
            assert(self.len - (end - start) + value.len <= self.bytes.len);
            const tail_len = self.len - end;
            const target = start + @as(u32, @intCast(value.len));
            const tail_target = self.bytes[target..][0..tail_len];
            const tail_source = self.bytes[end..][0..tail_len];
            if (target > end) {
                std.mem.copyBackwards(u8, tail_target, tail_source);
            } else {
                std.mem.copyForwards(u8, tail_target, tail_source);
            }
            @memcpy(self.bytes[start..target], value);
            self.len = target + tail_len;
            self.caret_moved = true;
            self.preferred_column = null;
            assert(self.len <= self.bytes.len);
        }

        /// Insert committed text over the selection. Committing ends any
        /// composition, so the preedit is discarded first. Only a typed
        /// codepoint joins the typing run; a longer commit (an IME phrase) is
        /// an undo step of its own.
        pub fn insert(self: *Self, value: []const u8) void {
            assert(self.cursor <= self.len);
            self.preedit_len = 0;
            if (oneCodepoint(value)) {
                return self.replace(self.selectionStart(), self.selectionEnd(), value);
            }
            self.replaceAsStep(self.selectionStart(), self.selectionEnd(), value);
        }

        /// `replace` as its own undo step, never merged with typing around it.
        fn replaceAsStep(self: *Self, start: u32, end: u32, value: []const u8) void {
            self.history.seal();
            self.replace(start, end, value);
            self.history.seal();
        }

        pub fn setPreedit(self: *Self, value: []const u8) void {
            const kept = clipboard_mod.prefixFitting(value, preedit_bytes_max);
            @memcpy(self.preedit[0..kept], value[0..kept]);
            self.preedit_len = @intCast(kept);
            assert(self.preedit_len <= preedit_bytes_max);
        }

        fn deleteSelection(self: *Self) void {
            assert(self.hasSelection());
            self.replace(self.selectionStart(), self.selectionEnd(), "");
        }

        /// Delete the selection, or the codepoint before the caret.
        pub fn backspace(self: *Self) void {
            if (self.hasSelection()) return self.deleteSelection();
            if (self.cursor == 0) return;
            self.replace(previousBoundary(self.text(), self.cursor), self.cursor, "");
        }

        /// Delete the selection, or the codepoint after the caret.
        pub fn deleteForward(self: *Self) void {
            if (self.hasSelection()) return self.deleteSelection();
            if (self.cursor == self.len) return;
            self.replace(self.cursor, nextBoundary(self.text(), self.cursor), "");
        }

        /// Move the caret to `target`; `extend` keeps the anchor (shift).
        fn moveTo(self: *Self, target: u32, extend: bool) void {
            assert(target <= self.len);
            self.cursor = target;
            if (!extend) self.anchor = target;
            self.history.seal();
            self.caret_moved = true;
            self.preferred_column = null;
        }

        /// Left or right with 0.3.1's modifiers: shift extends, the command
        /// modifier goes to the line's end, alt moves by word, and an unshifted
        /// move with a selection collapses it to that side.
        fn moveHorizontal(self: *Self, forward: bool, mods: input.Modifiers) void {
            if (!mods.shift and self.hasSelection()) {
                const edge = if (forward) self.selectionEnd() else self.selectionStart();
                return self.moveTo(edge, false);
            }
            const bytes = self.text();
            const at = self.cursor;
            const target = if (editCommand(mods))
                (if (forward) self.lineEnd(at) else self.lineStart(at))
            else if (mods.alt)
                (if (forward) nextWord(bytes, at) else previousWord(bytes, at))
            else if (forward)
                (if (at < self.len) nextBoundary(bytes, at) else self.len)
            else
                (if (at > 0) previousBoundary(bytes, at) else 0);
            self.moveTo(target, mods.shift);
        }

        /// Return, Up, and Down, which only an area takes: an input leaves
        /// Return to the app (submit) and has no lines to move between. The
        /// command modifier moves to the text's first or last byte.
        fn applyAreaKey(self: *Self, key: input.KeyEvent) bool {
            comptime assert(kind == .area);
            const mods = key.modifiers;
            switch (key.key) {
                .@"return", .keypad_enter => self.insert("\n"),
                .up => if (editCommand(mods)) {
                    self.moveTo(0, mods.shift);
                } else {
                    self.moveLine(false, mods.shift);
                },
                .down => if (editCommand(mods)) {
                    self.moveTo(self.len, mods.shift);
                } else {
                    self.moveLine(true, mods.shift);
                },
                else => return false,
            }
            return true;
        }

        /// Move to the line above or below at the preferred byte column,
        /// clamped to that line and snapped back to a codepoint start (0.3.1
        /// counts columns in bytes). On the first or last line it stays.
        fn moveLine(self: *Self, down: bool, extend: bool) void {
            const start = self.lineStart(self.cursor);
            const column = self.preferred_column orelse self.cursor - start;
            const target_start = if (down) blk: {
                const end = self.lineEnd(self.cursor);
                if (end == self.len) return;
                break :blk end + 1;
            } else blk: {
                if (start == 0) return;
                break :blk self.lineStart(start - 1);
            };
            const target_end = self.lineEnd(target_start);
            var target = target_start + @min(column, target_end - target_start);
            while (target > target_start and target < self.len and
                isContinuation(self.bytes[target])) target -= 1;
            self.moveTo(target, extend);
            self.preferred_column = column;
            assert(target <= self.len);
        }

        /// The first byte of the line holding `index`.
        pub fn lineStart(self: *const Self, index: u32) u32 {
            assert(index <= self.len);
            if (kind == .input) return 0;
            const before = self.bytes[0..index];
            const newline = std.mem.lastIndexOfScalar(u8, before, '\n') orelse return 0;
            return @intCast(newline + 1);
        }

        /// The end of the line holding `index`: its '\n', or the text's end.
        pub fn lineEnd(self: *const Self, index: u32) u32 {
            assert(index <= self.len);
            if (kind == .input) return self.len;
            const after = self.bytes[index..self.len];
            const newline = std.mem.indexOfScalar(u8, after, '\n') orelse return self.len;
            return index + @as(u32, @intCast(newline));
        }

        /// The 0-based line holding `index`.
        pub fn lineOf(self: *const Self, index: u32) u32 {
            assert(index <= self.len);
            return @intCast(std.mem.count(u8, self.bytes[0..index], "\n"));
        }

        /// Scroll so the caret's line is inside `viewport_height`, after an
        /// edit or move; otherwise keep the offset. Call before `blink`,
        /// which consumes the move.
        pub fn follow(self: *Self, line_height: f32, viewport_height: f32) void {
            comptime assert(kind == .area);
            assert(line_height > 0);
            assert(viewport_height > 0);
            const lines: f32 = @floatFromInt(std.mem.count(u8, self.text(), "\n") + 1);
            const scroll_max = @max(0, lines * line_height - viewport_height);
            if (self.caret_moved) {
                const top = @as(f32, @floatFromInt(self.lineOf(self.cursor))) * line_height;
                if (top < self.scroll_y) self.scroll_y = top;
                if (top + line_height > self.scroll_y + viewport_height) {
                    self.scroll_y = top + line_height - viewport_height;
                }
            }
            self.scroll_y = std.math.clamp(self.scroll_y, 0, scroll_max);
        }

        /// Handler for a click in the area: the caret moves there at the next
        /// build (`resolveClick`). The press already focused the area.
        pub fn onClick(self: *Self, effects: *handler_mod.Effects) void {
            comptime assert(kind == .area);
            const event = effects.inputEvent() orelse return;
            const mouse = switch (event.*) {
                .mouse_down, .mouse_up => |mouse| mouse,
                else => return,
            };
            self.pending_click = .{
                .x = @floatCast(mouse.position.x),
                .y = @floatCast(mouse.position.y),
            };
            effects.requestRender();
        }

        /// Move the caret to the pending click, measured against the area's
        /// bounds in the frame on screen, `inset` inside its edge. Columns
        /// are found by binary search over prefix widths, which grow with
        /// the prefix, so a line of n bytes costs O(log n) measurements.
        pub fn resolveClick(self: *Self, cx: *Cx, inset: f32) void {
            comptime assert(kind == .area);
            assert(inset >= 0);
            const click = self.pending_click orelse return;
            self.pending_click = null;
            const frame = cx.window.rendered();
            const bounds = for (frame.hits[0..frame.hit_count]) |*hit| {
                if (hit.id == self.view.id) break hit.bounds;
            } else return;
            const line_height = cx.fontMetrics().line_height;
            const y = click.y - bounds.y - inset + self.scroll_y;
            const row: u32 = if (y > 0) @intFromFloat(y / line_height) else 0;
            var start: u32 = 0;
            var line: u32 = 0;
            while (line < row) : (line += 1) {
                const end = self.lineEnd(start);
                if (end == self.len) break;
                start = end + 1;
            }
            const x = click.x - bounds.x - inset;
            const text_system = cx.window.resources.text_system;
            const column = columnAt(text_system, self.bytes[start..self.lineEnd(start)], x);
            self.moveTo(start + column, false);
        }

        /// Reverse the newest applied edit, restoring the caret it moved.
        pub fn undo(self: *Self) void {
            const edit = self.history.undo() orelse return;
            const end = edit.offset + edit.inserted_len;
            self.splice(edit.offset, end, self.history.deletedText(edit));
            self.cursor = edit.cursor_before;
            self.anchor = edit.anchor_before;
            assert(self.cursor <= self.len);
        }

        /// Apply the next undone edit again.
        pub fn redo(self: *Self) void {
            const edit = self.history.redo() orelse return;
            const end = edit.offset + edit.deleted_len;
            self.splice(edit.offset, end, self.history.insertedText(edit));
            self.cursor = edit.offset + edit.inserted_len;
            self.anchor = self.cursor;
            assert(self.cursor <= self.len);
        }

        /// Apply one input event. Returns whether the engine consumed it.
        pub fn apply(self: *Self, event: *const input.InputEvent, clipboard: *Clipboard) bool {
            switch (event.*) {
                .text_input => |typed| self.insert(typed.text),
                .composition => |composing| self.setPreedit(composing.text),
                .key_down => |key| return self.applyKey(key, clipboard),
                .scroll => |scroll| {
                    if (kind == .input) return false;
                    assert(std.math.isFinite(scroll.delta.y));
                    // 0.3.1's 20 px per wheel unit; `follow` clamps at build.
                    self.scroll_y -= @as(f32, @floatCast(scroll.delta.y)) * wheel_step;
                },
                else => return false,
            }
            return true;
        }

        fn applyKey(self: *Self, key: input.KeyEvent, clipboard: *Clipboard) bool {
            // Keys go to the IME while it composes.
            if (self.preedit_len > 0) return false;
            if (editCommand(key.modifiers)) {
                if (self.applyCommand(key, clipboard)) return true;
            }
            if (kind == .area) {
                if (self.applyAreaKey(key)) return true;
            }
            const extend = key.modifiers.shift;
            switch (key.key) {
                .delete => self.backspace(),
                .forward_delete => self.deleteForward(),
                .left => self.moveHorizontal(false, key.modifiers),
                .right => self.moveHorizontal(true, key.modifiers),
                .home => self.moveTo(self.lineStart(self.cursor), extend),
                .end => self.moveTo(self.lineEnd(self.cursor), extend),
                else => return false,
            }
            return true;
        }

        /// Select all, copy, cut, paste, undo, and redo. Returns false for any
        /// other command key, which bubbles to the app.
        fn applyCommand(self: *Self, key: input.KeyEvent, clipboard: *Clipboard) bool {
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
        pub fn onKey(self: *Self, effects: *handler_mod.Effects) void {
            const event = effects.inputEvent() orelse return;
            if (!self.apply(event, effects.clipboard.?)) return;
            // A key after a click in the same tick supersedes it.
            self.pending_click = null;
            if (self.bind) |binding| binding.* = self.text();
            effects.requestRender();
            effects.stopPropagation();
        }
    };
}

pub const InputEngine = Engine(.input);
pub const AreaEngine = Engine(.area);

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

/// The codepoint boundary in `line` nearest to `x` pixels from its start.
fn columnAt(text_system: anytype, line: []const u8, x: f32) u32 {
    assert(line.len <= std.math.maxInt(u32));
    // Invariant: `low` is a boundary at or left of x (or 0), and no boundary
    // after `high` is.
    var low: u32 = 0;
    var high: u32 = @intCast(line.len);
    while (low < high) {
        var middle = low + (high - low + 1) / 2;
        while (middle > low and middle < line.len and isContinuation(line[middle])) middle -= 1;
        if (middle == low) middle = nextBoundary(line, low);
        if (middle > high) break;
        if (measureWidth(text_system, line[0..middle]) <= x) {
            low = middle;
        } else {
            high = middle - 1;
        }
    }
    assert(low == line.len or !isContinuation(line[low]));
    if (low == line.len) return low;
    // The click may be nearer the next boundary than this one.
    const next = nextBoundary(line, low);
    const left = measureWidth(text_system, line[0..low]);
    const right = measureWidth(text_system, line[0..next]);
    return if (x - left > right - x) next else low;
}

fn measureWidth(text_system: anytype, value: []const u8) f32 {
    if (value.len == 0) return 0;
    return text_system.measureText(.app, value, .regular) catch |err| {
        std.debug.panic("text measurement failed: {s}", .{@errorName(err)});
    };
}

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

/// The pool of one engine kind.
pub fn Pool(comptime kind: Kind) type {
    return struct {
        const Self = @This();
        const E = Engine(kind);

        slab: retained.Slab,
        text_bytes: []u8,
        history_bytes: []u8,
        edits: []history_mod.Edit,
        bytes_max: u32,
        undo_depth_max: u32,

        const stride: u32 = std.mem.alignForward(u32, @sizeOf(E), retained.slab_alignment);

        pub const Capacity = struct { count: u32, bytes_max: u32, undo_depth_max: u32 };

        pub fn initInPlace(self: *Self, gpa: std.mem.Allocator, capacity: Capacity) !void {
            assert(capacity.count > 0);
            assert(capacity.bytes_max > 0);
            assert(capacity.undo_depth_max > 0);
            const bytes_total = @as(usize, capacity.count) * capacity.bytes_max;
            const name = "text pool '" ++ @tagName(kind) ++ "'";
            try self.slab.initInPlace(gpa, name, stride, capacity.count);
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

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            assert(self.bytes_max > 0);
            gpa.free(self.edits);
            gpa.free(self.history_bytes);
            gpa.free(self.text_bytes);
            self.slab.deinit(gpa);
        }

        /// The store entry that makes engines handler targets.
        pub fn entityPool(self: *const Self) handler_mod.EntityPool {
            return .{
                .type_id = handler_mod.typeId(E),
                .name = self.slab.name,
                .base = self.slab.bytes.ptr,
                .stride = self.slab.stride,
                .generations = self.slab.generations,
            };
        }

        /// Find or claim the engine for `id`. A claimed engine is reset, then
        /// `init` runs once.
        pub fn retain(
            self: *Self,
            id: ElementId,
            lifetime: retained.Lifetime,
            frame: u64,
            comptime init: fn (engine: *E) void,
        ) retained.Handle(E) {
            assert(id.isKeyed());
            const type_id = handler_mod.typeId(E);
            if (self.slab.find(id, type_id)) |slot| {
                self.slab.touch(slot, lifetime, frame);
                return .{ .slot = slot, .generation = self.slab.generations[slot] };
            }
            const slot = self.slab.claim(id, type_id, lifetime, frame);
            const engine: *E = @ptrCast(self.slab.slotBytes(slot).ptr);
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

        pub fn get(self: *Self, handle: retained.Handle(E)) *E {
            assert(handle.slot < self.slab.slotCount());
            assert(self.slab.meta[handle.slot].in_use);
            assert(self.slab.generations[handle.slot] == handle.generation);
            return @ptrCast(self.slab.slotBytes(handle.slot).ptr);
        }
    };
}

pub const InputPool = Pool(.input);
pub const AreaPool = Pool(.area);

/// An engine over caller storage, for the tests below.
fn TestOf(comptime kind: Kind) type {
    // The input tests fill 16 bytes; the area tests need a few lines.
    const size = if (kind == .input) 16 else 32;
    return struct {
        engine: Engine(kind),
        bytes: [size]u8,
        edits: [4]history_mod.Edit,
        history_bytes: [size]u8,
        clipboard_bytes: [size]u8,
        clipboard: Clipboard,

        fn init(self: *@This()) void {
            self.engine.bytes = &self.bytes;
            self.engine.history = History.init(&self.edits, &self.history_bytes);
            self.engine.reset();
            self.clipboard = Clipboard.init(&self.clipboard_bytes);
        }

        fn key(self: *@This(), code: input.KeyCode, mods: input.Modifiers) bool {
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
}

const TestEngine = TestOf(.input);

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

test "an area moves between lines at the preferred column" {
    // Goal: 0.3.1's vertical moves keep the column a short line clamps.
    // Method: a long, a short, and a long line; a wrong implementation that
    // forgets the column lands at the short line's length on the way back.
    var t: TestOf(.area) = undefined;
    t.init();
    const engine = &t.engine;
    engine.insert("abcdef\nxy\nlonger line");
    try std.testing.expectEqual(@as(u32, 21), engine.cursor);
    try std.testing.expect(t.key(.up, .{}));
    try std.testing.expectEqual(@as(u32, 9), engine.cursor); // "xy|"
    try std.testing.expect(t.key(.up, .{}));
    try std.testing.expectEqual(@as(u32, 6), engine.cursor); // "abcdef|"
    try std.testing.expect(t.key(.down, .{}));
    try std.testing.expect(t.key(.down, .{}));
    try std.testing.expectEqual(@as(u32, 21), engine.cursor); // Column 11 again.
    try std.testing.expect(t.key(.down, .{}));
    try std.testing.expectEqual(@as(u32, 21), engine.cursor);
    try std.testing.expect(t.key(.up, TestOf(.area).command()));
    try std.testing.expectEqual(@as(u32, 0), engine.cursor);
    try std.testing.expect(t.key(.down, .{ .shift = true }));
    try std.testing.expectEqual(@as(u32, 0), engine.selectionStart());
    try std.testing.expectEqual(@as(u32, 7), engine.selectionEnd());
    // Home and End, and the command modifier, stay on the caret's line.
    try std.testing.expect(t.key(.right, .{}));
    try std.testing.expect(t.key(.right, .{}));
    try std.testing.expectEqual(@as(u32, 8), engine.cursor);
    try std.testing.expect(t.key(.end, .{}));
    try std.testing.expectEqual(@as(u32, 9), engine.cursor);
    try std.testing.expect(t.key(.left, TestOf(.area).command()));
    try std.testing.expectEqual(@as(u32, 7), engine.cursor);
    try std.testing.expect(t.key(.@"return", .{}));
    try std.testing.expectEqualStrings("abcdef\n\nxy\nlonger line", engine.text());
}

test "a vertical move never lands inside a codepoint" {
    // Goal: byte columns snap back to a codepoint start. Method: column 1
    // below is the middle of the two-byte é.
    var t: TestOf(.area) = undefined;
    t.init();
    const engine = &t.engine;
    engine.insert("ab\n\u{e9}z");
    try std.testing.expect(t.key(.up, TestOf(.area).command()));
    try std.testing.expect(t.key(.right, .{}));
    try std.testing.expect(t.key(.down, .{}));
    try std.testing.expectEqual(@as(u32, 3), engine.cursor);
    // An input has no lines: Up, Down, and Return are the app's.
    var input_test: TestEngine = undefined;
    input_test.init();
    try std.testing.expect(!input_test.key(.up, .{}));
    try std.testing.expect(!input_test.key(.@"return", .{}));
}

test "an area scrolls to keep the caret's line in view" {
    // Goal: `follow` scrolls only as far as the caret needs, only after a
    // move, and never past the last line. Method: ten lines 10 px tall in a
    // 30 px viewport.
    var t: TestOf(.area) = undefined;
    t.init();
    const engine = &t.engine;
    engine.insert("0\n1\n2\n3\n4\n5\n6\n7\n8\n9");
    engine.follow(10, 30);
    try std.testing.expectEqual(@as(f32, 70), engine.scroll_y);
    _ = engine.prepare(true, 0); // A build consumes the move.
    engine.scroll_y = 20;
    engine.follow(10, 30);
    try std.testing.expectEqual(@as(f32, 20), engine.scroll_y);
    try std.testing.expect(t.key(.up, .{}));
    try std.testing.expect(t.key(.up, .{}));
    try std.testing.expect(t.key(.up, .{}));
    try std.testing.expect(t.key(.up, .{}));
    try std.testing.expect(t.key(.up, .{}));
    try std.testing.expect(t.key(.up, .{}));
    engine.follow(10, 30); // The caret on line 3 sits inside 20..50.
    try std.testing.expectEqual(@as(f32, 20), engine.scroll_y);
    try std.testing.expect(t.key(.up, .{}));
    engine.follow(10, 30);
    try std.testing.expectEqual(@as(f32, 20), engine.scroll_y);
    try std.testing.expect(t.key(.up, .{}));
    engine.follow(10, 30);
    try std.testing.expectEqual(@as(f32, 10), engine.scroll_y);
    // Deleting lines clamps the offset to the shorter text.
    try std.testing.expect(t.key(.a, TestOf(.area).command()));
    engine.backspace();
    engine.follow(10, 30);
    try std.testing.expectEqual(@as(f32, 0), engine.scroll_y);
}

test "a click finds the nearest codepoint boundary" {
    // Goal: `columnAt` rounds to the nearer boundary and never returns the
    // middle of a codepoint. Method: a fake measure at 10 px per codepoint,
    // so "aéb" has boundaries 0, 1, 3, 4 at 0, 10, 20, 30 px.
    const Fake = struct {
        fn measureText(_: @This(), _: anytype, value: []const u8, _: anytype) !f32 {
            // The test's literals are valid UTF-8.
            const count = std.unicode.utf8CountCodepoints(value) catch unreachable;
            return @floatFromInt(count * 10);
        }
    };
    const fake = Fake{};
    try std.testing.expectEqual(@as(u32, 0), columnAt(fake, "a\u{e9}b", -5));
    try std.testing.expectEqual(@as(u32, 1), columnAt(fake, "a\u{e9}b", 14));
    try std.testing.expectEqual(@as(u32, 3), columnAt(fake, "a\u{e9}b", 16));
    try std.testing.expectEqual(@as(u32, 3), columnAt(fake, "a\u{e9}b", 24));
    try std.testing.expectEqual(@as(u32, 4), columnAt(fake, "a\u{e9}b", 1000));
    try std.testing.expectEqual(@as(u32, 0), columnAt(fake, "", 12));
}
