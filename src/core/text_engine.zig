const std = @import("std");
const id_mod = @import("id.zig");
const handler_mod = @import("handler.zig");
const retained = @import("retained.zig");
const history_mod = @import("text_history.zig");
const clipboard_mod = @import("clipboard.zig");
const input = @import("../input/mod.zig");
const cx_mod = @import("cx.zig");
const Cx = cx_mod.Cx;
const Color = @import("../geometry/geometry.zig").Color;
const Rect = @import("records.zig").Rect;
const Point = @import("router.zig").Point;
const wheelOffset = @import("window.zig").wheelOffset;
const text_mod = @import("../text/mod.zig");
const actions_mod = @import("actions.zig");

const assert = std.debug.assert;

pub const ElementId = id_mod.ElementId;
pub const History = history_mod.History;
pub const Clipboard = clipboard_mod.Clipboard;
pub const TextCommand = actions_mod.TextCommand;
const Motion = actions_mod.Motion;

pub const line_codepoint_count_max: u32 = text_mod.run_codepoint_count_max;

pub const blink_interval_ms: u32 = 530;
pub const autoscroll_interval_ms: u32 = 16;
const autoscroll_dt_ms_max: u64 = 100;
const autoscroll_speed_min_px_per_sec: f32 = 60;
const autoscroll_speed_gain: f32 = 4;
const autoscroll_speed_max_px_per_sec: f32 = 900;

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
    scrollbar_track_color: Color,
    scrollbar_thumb_color: Color,
};

pub const Kind = enum { input, area, editor };

pub const Indent = struct {
    size: u8,
    hard_tabs: bool,

    pub const size_max: u8 = 16;
};

pub const PointerOrigin = struct {
    text_x: f32,
    text_y: f32,
    viewport_height: f32,
    gutter_end: f32,
};

pub const SelectionMode = enum(u8) { char, word, line };

const Range = struct { start: u32, end: u32 };

const ColumnHit = struct { caret: u32, char_at: u32 };

const PointerHit = struct {
    caret: u32,
    char_at: u32,
    line_start: u32,
    line_end: u32,
    in_gutter: bool,
};

const PendingPress = struct {
    point: Point,
    click_count: u32,
    shift: bool,
};

const PointerState = struct {
    active: bool,
    has_origin: bool,
    mode: SelectionMode,
    origin_start: u32,
    origin_end: u32,
    pointer: Point,
    autoscroll_ns: u64,
    pending_press: ?PendingPress,
    pending_move: ?Point,

    const idle: PointerState = .{
        .active = false,
        .has_origin = false,
        .mode = .char,
        .origin_start = 0,
        .origin_end = 0,
        .pointer = .{ .x = 0, .y = 0 },
        .autoscroll_ns = 0,
        .pending_press = null,
        .pending_move = null,
    };
};

pub fn Engine(comptime kind: Kind) type {
    return struct {
        const Self = @This();

        bytes: []u8,
        len: u32,
        cursor: u32,
        anchor: u32,
        preedit: []u8,
        preedit_len: u32,
        history: History,
        caret_moved_ns: u64,
        caret_moved: bool,
        bind: ?*[]const u8,
        preferred_column: ?u32,
        scroll_y: f32,
        pointer: PointerState,
        indent: Indent,
        view: View,

        pub const View = EngineView;

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
            self.pointer = .idle;
            self.indent = .{ .size = 4, .hard_tabs = false };
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
            assert(self.preedit_len <= self.preedit.len);
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
            self.invalidatePointer();
            assert(self.cursor <= self.len);
        }

        fn invalidatePointer(self: *Self) void {
            self.pointer.has_origin = false;
            self.pointer.origin_start = 0;
            self.pointer.origin_end = 0;
            if (self.pointer.pending_press == null) {
                self.pointer.active = false;
                self.pointer.autoscroll_ns = 0;
                self.pointer.pending_move = null;
            }
            assert(!self.pointer.has_origin);
        }

        pub fn syncBound(self: *Self, binding: *[]const u8) void {
            self.bind = binding;
            const value = binding.*;
            const mirrors = value.ptr == self.bytes.ptr and value.len == self.len;
            if (mirrors) return;
            if (value.len > 0 and value.ptr == self.bytes.ptr and value.len < self.len) {
                self.len = @intCast(value.len);
                self.cursor = @min(self.cursor, self.len);
                self.anchor = @min(self.anchor, self.len);
                self.preedit_len = 0;
                self.history.clear();
                self.invalidatePointer();
                return;
            }
            if (value.len == self.len and std.mem.eql(u8, value, self.text())) return;
            const cursor = self.cursor;
            const anchor = self.anchor;
            self.setText(value);
            self.cursor = boundaryAtOrBefore(self.text(), @min(cursor, self.len));
            self.anchor = boundaryAtOrBefore(self.text(), @min(anchor, self.len));
            assert(self.cursor <= self.len);
            assert(self.anchor <= self.len);
            binding.* = self.text();
        }

        pub fn prepare(self: *Self, focused: bool, now_ns: u64) ?u32 {
            if (!focused) assert(self.preedit_len == 0);
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
                unreachable;
            assert(delay_ms > 0);
            assert(delay_ms <= blink_interval_ms);
            return @intCast(delay_ms);
        }

        pub fn blink(self: *Self, cx: *Cx, focused: bool) void {
            assert(cx_mod.windowOf(cx).phase == .build);
            if (!focused) {
                self.pointer.active = false;
                self.pointer.autoscroll_ns = 0;
            }
            if (!focused and self.preedit_len > 0) {
                self.commitPreedit();
                cx.requestRenderAfter(0);
            }
            const delay_ms = self.prepare(focused, cx.now()) orelse return;
            cx.requestRenderAfter(delay_ms);
        }

        fn replace(self: *Self, start: u32, end: u32, value: []const u8) void {
            assert(start <= end);
            assert(end <= self.len);
            const room = self.bytes.len - (self.len - (end - start));
            const fits: u32 = @intCast(clipboard_mod.prefixFitting(value, room));
            const line_max = line_codepoint_count_max;
            const kept = lineFitting(self.text(), start, end, value[0..fits], line_max) orelse
                return;
            assert(kept <= fits);
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

        pub fn insert(self: *Self, value: []const u8) void {
            assert(self.cursor <= self.len);
            self.preedit_len = 0;
            if (oneCodepoint(value)) {
                return self.replace(self.selectionStart(), self.selectionEnd(), value);
            }
            self.replaceAsStep(self.selectionStart(), self.selectionEnd(), value);
        }

        pub fn commitPreedit(self: *Self) void {
            assert(self.preedit_len > 0);
            assert(self.preedit_len <= self.preedit.len);
            self.insert(self.preedit[0..self.preedit_len]);
            assert(self.preedit_len == 0);
            if (self.bind) |binding| binding.* = self.text();
        }

        fn replaceAsStep(self: *Self, start: u32, end: u32, value: []const u8) void {
            self.history.seal();
            self.replace(start, end, value);
            self.history.seal();
        }

        pub fn setPreedit(self: *Self, value: []const u8) void {
            assert(self.preedit.len > 0);
            const kept = clipboard_mod.prefixFitting(value, self.preedit.len);
            if (kept < value.len) {
                std.log.warn("IME composition of {d} bytes cut to {d}. Raise " ++
                    "ResourceLimits.text.preedit_bytes_max ({d}).", .{
                    value.len,
                    kept,
                    self.preedit.len,
                });
            }
            @memcpy(self.preedit[0..kept], value[0..kept]);
            self.preedit_len = @intCast(kept);
            assert(self.preedit_len <= self.preedit.len);
        }

        fn deleteSelection(self: *Self) void {
            assert(self.hasSelection());
            self.replace(self.selectionStart(), self.selectionEnd(), "");
        }

        pub fn backspace(self: *Self) void {
            if (self.hasSelection()) return self.deleteSelection();
            if (self.cursor == 0) return;
            self.replace(previousBoundary(self.text(), self.cursor), self.cursor, "");
        }

        pub fn deleteForward(self: *Self) void {
            if (self.hasSelection()) return self.deleteSelection();
            if (self.cursor == self.len) return;
            self.replace(self.cursor, nextBoundary(self.text(), self.cursor), "");
        }

        fn moveTo(self: *Self, target: u32, extend: bool) void {
            assert(target <= self.len);
            self.cursor = target;
            if (!extend) self.anchor = target;
            self.history.seal();
            self.caret_moved = true;
            self.preferred_column = null;
        }

        pub fn perform(self: *Self, command: TextCommand) bool {
            assert(self.cursor <= self.len);
            assert(self.preedit_len == 0);
            if (actions_mod.moveOf(command)) |move| return self.moveBy(move.motion, move.extend);
            if (actions_mod.deleteOf(command)) |motion| {
                self.deleteBy(motion);
                return true;
            }
            switch (command) {
                .newline => {
                    if (kind == .input) return false;
                    self.insert("\n");
                },
                .indent => {
                    if (kind != .editor) return false;
                    self.insertIndent();
                },
                else => unreachable,
            }
            return true;
        }

        fn moveBy(self: *Self, motion: Motion, extend: bool) bool {
            if (!extend and self.hasSelection()) {
                switch (motion) {
                    .backward => return self.moveCollapsed(self.selectionStart()),
                    .forward => return self.moveCollapsed(self.selectionEnd()),
                    else => {},
                }
            }
            switch (motion) {
                .up, .down => {
                    if (kind == .input) return false;
                    self.moveLine(motion == .down, extend);
                },
                else => self.moveTo(self.motionTarget(motion), extend),
            }
            assert(self.cursor <= self.len);
            return true;
        }

        fn moveCollapsed(self: *Self, edge: u32) bool {
            assert(edge <= self.len);
            self.moveTo(edge, false);
            return true;
        }

        fn motionTarget(self: *const Self, motion: Motion) u32 {
            const bytes = self.text();
            const at = self.cursor;
            const result = switch (motion) {
                .backward => if (at > 0) previousBoundary(bytes, at) else 0,
                .forward => if (at < self.len) nextBoundary(bytes, at) else self.len,
                .word_backward => previousWord(bytes, at),
                .word_forward => nextWord(bytes, at),
                .line_start => self.lineStart(at),
                .line_end => self.lineEnd(at),
                .text_start => 0,
                .text_end => self.len,
                .up, .down => unreachable,
            };
            assert(result <= self.len);
            return result;
        }

        fn deleteBy(self: *Self, motion: Motion) void {
            assert(motion != .up);
            assert(motion != .down);
            if (self.hasSelection()) return self.deleteSelection();
            var reach = self.motionTarget(motion);
            if (reach == self.cursor) {
                const forward = motion == .forward or motion == .word_forward or
                    motion == .line_end or motion == .text_end;
                reach = self.motionTarget(if (forward) .forward else .backward);
            }
            if (reach == self.cursor) return;
            self.replace(@min(reach, self.cursor), @max(reach, self.cursor), "");
        }

        fn insertIndent(self: *Self) void {
            comptime assert(kind == .editor);
            assert(self.indent.size > 0);
            assert(self.indent.size <= Indent.size_max);
            if (self.indent.hard_tabs) return self.insert("\t");
            const spaces: [Indent.size_max]u8 = @splat(' ');
            self.insert(spaces[0..self.indent.size]);
        }

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

        pub fn lineStart(self: *const Self, index: u32) u32 {
            assert(index <= self.len);
            if (kind == .input) return 0;
            const before = self.bytes[0..index];
            const newline = std.mem.lastIndexOfScalar(u8, before, '\n') orelse return 0;
            return @intCast(newline + 1);
        }

        pub fn lineEnd(self: *const Self, index: u32) u32 {
            assert(index <= self.len);
            if (kind == .input) return self.len;
            const after = self.bytes[index..self.len];
            const newline = std.mem.indexOfScalar(u8, after, '\n') orelse return self.len;
            return index + @as(u32, @intCast(newline));
        }

        pub fn lineOf(self: *const Self, index: u32) u32 {
            assert(index <= self.len);
            return @intCast(std.mem.count(u8, self.bytes[0..index], "\n"));
        }

        fn scrollMax(self: *const Self, line_height: f32, viewport_height: f32) f32 {
            comptime assert(kind != .input);
            assert(line_height > 0);
            assert(viewport_height > 0);
            const lines: f32 = @floatFromInt(std.mem.count(u8, self.text(), "\n") + 1);
            return @max(0, lines * line_height - viewport_height);
        }

        pub fn follow(self: *Self, line_height: f32, viewport_height: f32) void {
            comptime assert(kind != .input);
            assert(line_height > 0);
            assert(viewport_height > 0);
            const scroll_max = self.scrollMax(line_height, viewport_height);
            const autoscrolling = self.pointer.active and self.pointer.autoscroll_ns != 0;
            if (self.caret_moved and !autoscrolling) {
                const top = @as(f32, @floatFromInt(self.lineOf(self.cursor))) * line_height;
                if (top < self.scroll_y) self.scroll_y = top;
                if (top + line_height > self.scroll_y + viewport_height) {
                    self.scroll_y = top + line_height - viewport_height;
                }
            }
            self.scroll_y = std.math.clamp(self.scroll_y, 0, scroll_max);
        }

        pub fn onPointerDrag(self: *Self, effects: *handler_mod.Effects) void {
            const drag = effects.pointerDrag() orelse return;
            assert(std.math.isFinite(drag.x));
            assert(std.math.isFinite(drag.y));
            if (drag.button != .left) return;
            const point = Point{ .x = drag.x, .y = drag.y };
            switch (drag.phase) {
                .begin => {
                    self.pointer.active = true;
                    self.pointer.pointer = point;
                    self.pointer.autoscroll_ns = 0;
                    self.pointer.pending_press = .{
                        .point = point,
                        .click_count = drag.click_count,
                        .shift = drag.modifiers.shift,
                    };
                    self.pointer.pending_move = null;
                    effects.requestRender();
                },
                .move => {
                    if (!self.pointer.active) return;
                    self.pointer.pointer = point;
                    self.pointer.pending_move = point;
                    effects.requestRender();
                },
                .end => {
                    if (!self.pointer.active) return;
                    const moved = point.x != self.pointer.pointer.x or
                        point.y != self.pointer.pointer.y;
                    self.pointer.active = false;
                    self.pointer.autoscroll_ns = 0;
                    self.pointer.pointer = point;
                    if (moved) {
                        self.pointer.pending_move = point;
                        effects.requestRender();
                    }
                },
                .cancel => {
                    self.pointer.active = false;
                    self.pointer.autoscroll_ns = 0;
                    self.pointer.pending_press = null;
                    self.pointer.pending_move = null;
                },
            }
        }

        pub fn resolvePointer(self: *Self, cx: *Cx, origin: PointerOrigin) void {
            assert(origin.text_x >= origin.gutter_end);
            assert(origin.text_y >= 0);
            assert(origin.viewport_height > 0);
            const has_work = self.pointer.pending_press != null or
                self.pointer.pending_move != null or self.pointer.active;
            if (!has_work) return;
            const frame = cx_mod.windowOf(cx).rendered();
            const bounds = for (frame.hits[0..frame.hit_count]) |*hit| {
                if (hit.id == self.view.id) break hit.bounds;
            } else {
                self.pointer.active = false;
                self.pointer.autoscroll_ns = 0;
                self.pointer.pending_press = null;
                self.pointer.pending_move = null;
                return;
            };
            const line_height = cx.fontMetrics().line_height;
            assert(line_height > 0);
            if (comptime kind != .input) {
                const scroll_max = self.scrollMax(line_height, origin.viewport_height);
                self.scroll_y = std.math.clamp(self.scroll_y, 0, scroll_max);
            }
            const text_system = cx_mod.windowOf(cx).resources.text_system;
            if (self.pointer.pending_press) |press| {
                self.pointer.pending_press = null;
                self.applyPress(text_system, line_height, bounds, origin, press);
            }
            if (comptime kind != .input) {
                const dragging = self.pointer.pending_move != null or
                    self.pointer.autoscroll_ns != 0;
                if (self.pointer.active and dragging and cx.focused(self.view.id)) {
                    if (self.stepAutoscroll(cx, bounds, origin, line_height)) {
                        self.pointer.pending_move = self.pointer.pointer;
                    }
                }
            }
            if (self.pointer.pending_move) |point| {
                self.pointer.pending_move = null;
                self.applyDragMove(text_system, line_height, bounds, origin, point);
            }
        }

        fn applyPress(
            self: *Self,
            text_system: anytype,
            line_height: f32,
            bounds: Rect,
            origin: PointerOrigin,
            press: PendingPress,
        ) void {
            const hit = self.hitAt(text_system, line_height, bounds, origin, press.point, false);
            const mode = modeOf(press.click_count, hit.in_gutter);
            const hit_range = self.selectionRangeFor(mode, hit);
            const base = if (press.shift) self.shiftOrigin(hit.caret, mode) else hit_range;
            self.pointer.mode = mode;
            self.pointer.has_origin = true;
            self.pointer.origin_start = base.start;
            self.pointer.origin_end = base.end;
            self.applyRange(base, hit_range, hit.caret, mode);
            assert(self.cursor <= self.len);
            assert(self.anchor <= self.len);
        }

        fn applyDragMove(
            self: *Self,
            text_system: anytype,
            line_height: f32,
            bounds: Rect,
            origin: PointerOrigin,
            point: Point,
        ) void {
            if (!self.pointer.has_origin) return;
            assert(self.pointer.origin_start <= self.pointer.origin_end);
            assert(self.pointer.origin_end <= self.len);
            const hit = self.hitAt(text_system, line_height, bounds, origin, point, true);
            const mode = self.pointer.mode;
            const hit_range = self.selectionRangeFor(mode, hit);
            const base = Range{
                .start = self.pointer.origin_start,
                .end = self.pointer.origin_end,
            };
            self.applyRange(base, hit_range, hit.caret, mode);
            assert(self.cursor <= self.len);
            assert(self.anchor <= self.len);
        }

        fn shiftOrigin(self: *const Self, caret: u32, mode: SelectionMode) Range {
            assert(caret <= self.len);
            assert(self.anchor <= self.len);
            const keep = self.pointer.has_origin and
                self.pointer.origin_start <= self.pointer.origin_end and
                self.pointer.origin_end <= self.len and
                self.pointer.origin_start >= self.selectionStart() and
                self.pointer.origin_end <= self.selectionEnd();
            if (!keep) return .{ .start = self.anchor, .end = self.anchor };
            const inside = caret > self.pointer.origin_start and caret < self.pointer.origin_end;
            if (mode == .char and inside) return .{ .start = self.anchor, .end = self.anchor };
            return .{ .start = self.pointer.origin_start, .end = self.pointer.origin_end };
        }

        fn stepAutoscroll(
            self: *Self,
            cx: *Cx,
            bounds: Rect,
            origin: PointerOrigin,
            line_height: f32,
        ) bool {
            comptime assert(kind != .input);
            assert(self.pointer.active);
            assert(line_height > 0);
            const text_top = bounds.y + origin.text_y;
            const text_bottom = text_top + origin.viewport_height;
            const scroll_max = self.scrollMax(line_height, origin.viewport_height);
            const y = self.pointer.pointer.y;
            const above = y < text_top and self.scroll_y > 0;
            const below = y >= text_bottom and self.scroll_y < scroll_max;
            if (!above and !below) {
                self.pointer.autoscroll_ns = 0;
                return false;
            }
            const now = cx.now();
            const overshoot = if (above) text_top - y else y - text_bottom + 1;
            assert(overshoot > 0);
            if (self.pointer.autoscroll_ns == 0) {
                self.pointer.autoscroll_ns = now;
                cx.requestRenderAfter(autoscroll_interval_ms);
                return false;
            }
            assert(now >= self.pointer.autoscroll_ns);
            const dt_max = autoscroll_dt_ms_max * std.time.ns_per_ms;
            const dt_ns = @min(now - self.pointer.autoscroll_ns, dt_max);
            self.pointer.autoscroll_ns = now;
            if (dt_ns == 0) {
                cx.requestRenderAfter(autoscroll_interval_ms);
                return false;
            }
            const speed = @min(
                autoscroll_speed_max_px_per_sec,
                autoscroll_speed_min_px_per_sec + overshoot * autoscroll_speed_gain,
            );
            const delta = speed * (@as(f32, @floatFromInt(dt_ns)) / @as(f32, std.time.ns_per_s));
            const before = self.scroll_y;
            const next = if (above) before - delta else before + delta;
            self.scroll_y = std.math.clamp(next, 0, scroll_max);
            const room = (above and self.scroll_y > 0) or (below and self.scroll_y < scroll_max);
            if (room) cx.requestRenderAfter(autoscroll_interval_ms);
            return self.scroll_y != before;
        }

        fn hitAt(
            self: *const Self,
            text_system: anytype,
            line_height: f32,
            bounds: Rect,
            origin: PointerOrigin,
            point: Point,
            clamp_edges: bool,
        ) PointerHit {
            assert(line_height > 0);
            assert(origin.viewport_height > 0);
            if (comptime kind == .input) {
                const x = point.x - bounds.x - origin.text_x;
                const column = hitColumn(text_system, self.text(), x);
                return .{
                    .caret = column.caret,
                    .char_at = column.char_at,
                    .line_start = 0,
                    .line_end = self.len,
                    .in_gutter = false,
                };
            }
            const text_top = bounds.y + origin.text_y;
            const text_bottom = text_top + origin.viewport_height;
            const scroll_max = self.scrollMax(line_height, origin.viewport_height);
            if (clamp_edges and point.y < text_top and self.scroll_y <= 0) {
                return .{
                    .caret = 0,
                    .char_at = 0,
                    .line_start = 0,
                    .line_end = self.lineEnd(0),
                    .in_gutter = false,
                };
            }
            if (clamp_edges and point.y >= text_bottom and self.scroll_y >= scroll_max) {
                const start = self.lineStart(self.len);
                const char_at = if (start < self.len)
                    previousBoundary(self.text(), self.len)
                else
                    self.len;
                return .{
                    .caret = self.len,
                    .char_at = char_at,
                    .line_start = start,
                    .line_end = self.len,
                    .in_gutter = false,
                };
            }
            const row = self.rowAt(
                point.y,
                text_top,
                text_bottom,
                line_height,
                origin,
                clamp_edges,
            );
            const start = self.lineAtRow(row);
            const end = self.lineEnd(start);
            const in_gutter = kind == .editor and point.x - bounds.x < origin.gutter_end;
            const x = point.x - bounds.x - origin.text_x;
            const column = hitColumn(text_system, self.bytes[start..end], x);
            return .{
                .caret = start + column.caret,
                .char_at = start + column.char_at,
                .line_start = start,
                .line_end = end,
                .in_gutter = in_gutter,
            };
        }

        fn rowAt(
            self: *const Self,
            point_y: f32,
            text_top: f32,
            text_bottom: f32,
            line_height: f32,
            origin: PointerOrigin,
            clamp_edges: bool,
        ) u32 {
            comptime assert(kind != .input);
            assert(line_height > 0);
            assert(origin.viewport_height > 0);
            if (clamp_edges and point_y < text_top) {
                if (origin.viewport_height >= 2 * line_height) {
                    return @intFromFloat(@ceil(self.scroll_y / line_height));
                }
                return @intFromFloat(@floor(self.scroll_y / line_height));
            }
            if (clamp_edges and point_y >= text_bottom) {
                const inset_y = if (origin.viewport_height >= 2 * line_height)
                    line_height
                else
                    1;
                const bottom = @max(0, self.scroll_y + origin.viewport_height - inset_y);
                return @intFromFloat(@floor(bottom / line_height));
            }
            const y = point_y - text_top + self.scroll_y;
            return if (y > 0) @intFromFloat(y / line_height) else 0;
        }

        fn lineAtRow(self: *const Self, row: u32) u32 {
            comptime assert(kind != .input);
            var start: u32 = 0;
            var line: u32 = 0;
            while (line < row) : (line += 1) {
                const end = self.lineEnd(start);
                if (end == self.len) break;
                start = end + 1;
            }
            assert(start <= self.len);
            assert(start == self.lineStart(start));
            return start;
        }

        fn selectionRangeFor(self: *const Self, mode: SelectionMode, hit: PointerHit) Range {
            assert(hit.line_start <= hit.line_end);
            assert(hit.line_end <= self.len);
            return switch (mode) {
                .char => .{ .start = hit.caret, .end = hit.caret },
                .word => wordRange(self.text(), hit.line_start, hit.line_end, hit.char_at),
                .line => self.lineRange(hit.line_start),
            };
        }

        fn lineRange(self: *const Self, start: u32) Range {
            assert(start <= self.len);
            assert(start == self.lineStart(start));
            const end = self.lineEnd(start);
            return .{ .start = start, .end = if (end < self.len) end + 1 else end };
        }

        fn applyRange(
            self: *Self,
            origin: Range,
            hit: Range,
            caret: u32,
            mode: SelectionMode,
        ) void {
            assert(origin.start <= origin.end);
            assert(origin.end <= self.len);
            assert(hit.start <= hit.end);
            assert(hit.end <= self.len);
            if (hit.start < origin.start and hit.end > origin.end) {
                if (caret < origin.start) {
                    self.anchor = origin.end;
                    self.moveTo(hit.start, true);
                } else {
                    self.anchor = origin.start;
                    self.moveTo(hit.end, true);
                }
            } else if (hit.end > origin.end) {
                self.anchor = origin.start;
                self.moveTo(hit.end, true);
            } else if (hit.start < origin.start) {
                self.anchor = origin.end;
                self.moveTo(hit.start, true);
            } else if (mode == .line) {
                self.moveTo(origin.start, false);
                self.anchor = origin.end;
            } else {
                self.anchor = origin.start;
                self.moveTo(origin.end, true);
            }
            assert(self.cursor <= self.len);
            assert(self.anchor <= self.len);
        }

        pub fn undo(self: *Self) void {
            const edit = self.history.undo() orelse return;
            const end = edit.offset + edit.inserted_len;
            self.splice(edit.offset, end, self.history.deletedText(edit));
            self.cursor = edit.cursor_before;
            self.anchor = edit.anchor_before;
            assert(self.cursor <= self.len);
        }

        pub fn redo(self: *Self) void {
            const edit = self.history.redo() orelse return;
            const end = edit.offset + edit.deleted_len;
            self.splice(edit.offset, end, self.history.insertedText(edit));
            self.cursor = edit.offset + edit.inserted_len;
            self.anchor = self.cursor;
            assert(self.cursor <= self.len);
        }

        pub fn apply(self: *Self, event: *const input.InputEvent) bool {
            switch (event.*) {
                .text_input => |typed| self.insert(typed.text),
                .composition => |composing| self.setPreedit(composing.text),
                .scroll => |scroll| {
                    if (kind == .input) return false;
                    assert(std.math.isFinite(scroll.delta.y));
                    self.scroll_y += wheelOffset(@floatCast(scroll.delta.y));
                },
                else => return false,
            }
            return true;
        }

        pub fn selectAll(self: *Self) void {
            self.anchor = 0;
            self.moveTo(self.len, true);
            assert(self.selectionEnd() == self.len);
        }

        pub fn copy(self: *Self, clipboard: *Clipboard) void {
            const start = self.selectionStart();
            const end = self.selectionEnd();
            if (end > start) clipboard.write(self.bytes[start..end]);
        }

        pub fn cut(self: *Self, clipboard: *Clipboard) void {
            const start = self.selectionStart();
            const end = self.selectionEnd();
            if (end == start) return;
            const line_max = line_codepoint_count_max;
            if (lineFitting(self.text(), start, end, "", line_max) == null) return;
            clipboard.write(self.bytes[start..end]);
            self.replace(start, end, "");
            assert(self.cursor == start);
        }

        pub fn paste(self: *Self, clipboard: *Clipboard) void {
            const pasted = clipboard.read();
            if (pasted.len > 0) {
                self.replaceAsStep(self.selectionStart(), self.selectionEnd(), pasted);
            }
        }

        fn performAction(self: *Self, action: u64, arg: u64, clipboard: *Clipboard) bool {
            assert(action != 0);
            if (action == actions_mod.text_command) {
                assert(arg < TextCommand.count);
                return self.perform(@fromBackingInt(@intCast(arg)));
            }
            assert(arg == 0);
            if (action == actions_mod.undo) {
                self.undo();
            } else if (action == actions_mod.redo) {
                self.redo();
            } else if (action == actions_mod.select_all) {
                self.selectAll();
            } else if (action == actions_mod.copy) {
                self.copy(clipboard);
            } else if (action == actions_mod.cut) {
                self.cut(clipboard);
            } else {
                assert(action == actions_mod.paste);
                self.paste(clipboard);
            }
            return true;
        }

        pub fn onAction(self: *Self, effects: *handler_mod.Effects) void {
            assert(effects.action != 0);
            if (self.bind) |binding| self.syncBound(binding);
            assert(self.preedit_len == 0);
            if (!self.performAction(effects.action, effects.action_arg, effects.clipboard.?)) {
                return;
            }
            if (effects.action != actions_mod.copy) self.pointer = .idle;
            if (self.bind) |binding| binding.* = self.text();
            effects.requestRender();
            effects.stopPropagation();
        }

        pub fn onKey(self: *Self, effects: *handler_mod.Effects) void {
            const event = effects.inputEvent() orelse return;
            if (self.bind) |binding| self.syncBound(binding);
            if (!self.apply(event)) return;
            self.pointer = .idle;
            if (self.bind) |binding| binding.* = self.text();
            effects.requestRender();
            effects.stopPropagation();
        }
    };
}

pub const InputEngine = Engine(.input);
pub const AreaEngine = Engine(.area);
pub const EditorEngine = Engine(.editor);

fn modeOf(click_count: u32, in_gutter: bool) SelectionMode {
    if (in_gutter or click_count >= 3) return .line;
    if (click_count == 2) return .word;
    return .char;
}

fn isLineSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r';
}

fn wordRange(bytes: []const u8, line_start: u32, line_end: u32, char_at: u32) Range {
    assert(line_start <= line_end);
    assert(line_end <= bytes.len);
    if (line_start == line_end) return .{ .start = line_start, .end = line_start };
    assert(char_at >= line_start);
    assert(char_at < line_end);
    const space = isLineSpace(bytes[char_at]);
    var start = char_at;
    while (start > line_start and isLineSpace(bytes[start - 1]) == space) start -= 1;
    var end = char_at + 1;
    while (end < line_end and isLineSpace(bytes[end]) == space) end += 1;
    assert(start >= line_start);
    assert(end <= line_end);
    assert(start < end);
    assert(start == line_start or !isContinuation(bytes[start]));
    assert(end == line_end or !isContinuation(bytes[end]));
    return .{ .start = start, .end = end };
}

fn hitColumn(text_system: anytype, line: []const u8, x: f32) ColumnHit {
    assert(line.len <= std.math.maxInt(u32));
    assert(std.math.isFinite(x));
    if (line.len == 0 or x <= 0) return .{ .caret = 0, .char_at = 0 };
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
    if (low == line.len) {
        return .{ .caret = low, .char_at = previousBoundary(line, low) };
    }
    const next = nextBoundary(line, low);
    const left = measureWidth(text_system, line[0..low]);
    const right = measureWidth(text_system, line[0..next]);
    const caret = if (x - left > right - x) next else low;
    assert(caret <= line.len);
    assert(low < line.len);
    return .{ .caret = caret, .char_at = low };
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

fn lineFitting(text: []const u8, start: u32, end: u32, value: []const u8, line_max: u32) ?u32 {
    assert(start <= end);
    assert(end <= text.len);
    const before = text[0..start];
    const line_start = if (std.mem.lastIndexOfScalar(u8, before, '\n')) |index| index + 1 else 0;
    const line_end = std.mem.indexOfScalarPos(u8, text, end, '\n') orelse text.len;
    const tail = text_mod.codepointCount(text[end..line_end]);
    var base = text_mod.codepointCount(text[line_start..start]);
    var added: u32 = 0;
    var kept: u32 = 0;
    while (kept < value.len) {
        if (value[kept] == '\n') {
            base = 0;
            added = 0;
        } else {
            if (base + added >= line_max) break;
            added += 1;
        }
        kept = nextBoundary(value, kept);
    }
    while (added > 0 and base + added + tail > line_max) {
        kept = previousBoundary(value, kept);
        added -= 1;
    }
    assert(kept <= value.len);
    const joined = base + added + tail;
    if (joined > line_max) {
        assert(added == 0);
        if (joined > longestLineSpanned(text, start, end)) return null;
    }
    return kept;
}

fn longestLineSpanned(text: []const u8, start: u32, end: u32) u32 {
    assert(start <= end);
    assert(end <= text.len);
    const first_start = if (std.mem.lastIndexOfScalar(u8, text[0..start], '\n')) |index|
        index + 1
    else
        0;
    const first_end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
    const last_start = if (std.mem.lastIndexOfScalar(u8, text[0..end], '\n')) |index|
        index + 1
    else
        0;
    const last_end = std.mem.indexOfScalarPos(u8, text, end, '\n') orelse text.len;
    const first = text_mod.codepointCount(text[first_start..first_end]);
    const last = text_mod.codepointCount(text[last_start..last_end]);
    return @max(first, last);
}

fn boundaryAtOrBefore(bytes: []const u8, index: u32) u32 {
    assert(index <= bytes.len);
    var position = index;
    while (position > 0 and position < bytes.len and isContinuation(bytes[position])) {
        position -= 1;
    }
    assert(position <= index);
    return position;
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

fn previousWord(bytes: []const u8, index: u32) u32 {
    assert(index <= bytes.len);
    var position = index;
    while (position > 0 and isSpace(bytes[position - 1])) position -= 1;
    while (position > 0 and !isSpace(bytes[position - 1])) position -= 1;
    assert(position <= index);
    return position;
}

fn nextWord(bytes: []const u8, index: u32) u32 {
    assert(bytes.len <= std.math.maxInt(u32));
    assert(index <= bytes.len);
    var position = index;
    while (position < bytes.len and isSpace(bytes[position])) position += 1;
    while (position < bytes.len and !isSpace(bytes[position])) position += 1;
    assert(position >= index);
    assert(position <= bytes.len);
    return position;
}

pub fn Pool(comptime kind: Kind) type {
    return struct {
        const Self = @This();
        const E = Engine(kind);

        slab: retained.Slab,
        text_bytes: []u8,
        history_bytes: []u8,
        preedit_bytes: []u8,
        edits: []history_mod.Edit,
        bytes_max: u32,
        undo_depth_max: u32,
        preedit_bytes_max: u32,

        const stride: u32 = std.mem.alignForward(u32, @sizeOf(E), retained.slab_alignment);

        pub const Capacity = struct {
            count: u32,
            bytes_max: u32,
            undo_depth_max: u32,
            preedit_bytes_max: u32,
        };

        pub fn initInPlace(self: *Self, gpa: std.mem.Allocator, capacity: Capacity) !void {
            assert(capacity.count > 0);
            assert(capacity.bytes_max > 0);
            assert(capacity.undo_depth_max > 0);
            assert(capacity.preedit_bytes_max > 0);
            const bytes_total = @as(usize, capacity.count) * capacity.bytes_max;
            const name = "text pool '" ++ @tagName(kind) ++ "'";
            try self.slab.initInPlace(gpa, name, stride, capacity.count);
            errdefer self.slab.deinit(gpa);
            self.text_bytes = try gpa.alloc(u8, bytes_total);
            errdefer gpa.free(self.text_bytes);
            self.history_bytes = try gpa.alloc(u8, bytes_total);
            errdefer gpa.free(self.history_bytes);
            const preedit_total = @as(usize, capacity.count) * capacity.preedit_bytes_max;
            self.preedit_bytes = try gpa.alloc(u8, preedit_total);
            errdefer gpa.free(self.preedit_bytes);
            const edit_count = @as(usize, capacity.count) * capacity.undo_depth_max;
            self.edits = try gpa.alloc(history_mod.Edit, edit_count);
            self.bytes_max = capacity.bytes_max;
            self.undo_depth_max = capacity.undo_depth_max;
            self.preedit_bytes_max = capacity.preedit_bytes_max;
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            assert(self.bytes_max > 0);
            gpa.free(self.edits);
            gpa.free(self.preedit_bytes);
            gpa.free(self.history_bytes);
            gpa.free(self.text_bytes);
            self.slab.deinit(gpa);
        }

        pub fn entityPool(self: *const Self) handler_mod.EntityPool {
            return .{
                .type_id = handler_mod.typeId(E),
                .name = self.slab.name,
                .base = self.slab.bytes.ptr,
                .stride = self.slab.stride,
                .generations = self.slab.generations,
            };
        }

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
            const preedit_start = @as(usize, slot) * self.preedit_bytes_max;
            engine.preedit = self.preedit_bytes[preedit_start..][0..self.preedit_bytes_max];
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
pub const EditorPool = Pool(.editor);

fn TestOf(comptime kind: Kind) type {
    const size = if (kind == .input) 16 else 32;
    return struct {
        engine: Engine(kind),
        bytes: [size]u8,
        edits: [4]history_mod.Edit,
        history_bytes: [size]u8,
        clipboard_bytes: [size]u8,
        clipboard: Clipboard,
        preedit: [16]u8,

        fn init(self: *@This()) void {
            self.engine.bytes = &self.bytes;
            self.engine.preedit = &self.preedit;
            self.engine.history = History.init(&self.edits, &self.history_bytes);
            self.engine.reset();
            self.clipboard = Clipboard.init(&self.clipboard_bytes);
        }

        fn run(self: *@This(), command: TextCommand) bool {
            return self.engine.perform(command);
        }
    };
}

const TestEngine = TestOf(.input);

test "an edit keeps the prefix that leaves every line within the bound" {
    const fit = lineFitting;
    try std.testing.expectEqual(@as(?u32, 0), fit("abcd", 4, 4, "e", 4));
    try std.testing.expectEqual(@as(?u32, 1), fit("abcd", 4, 4, "\n", 4));
    try std.testing.expectEqual(@as(?u32, 3), fit("abc", 3, 3, "\u{6771}\u{4eac}", 4));
    try std.testing.expectEqual(@as(?u32, 6), fit("ab", 2, 2, "c\nwxyz!", 4));
    try std.testing.expectEqual(@as(?u32, 1), fit("abc", 2, 2, "XY", 4));
    try std.testing.expectEqual(@as(?u32, 3), fit("12345\nabcd\n1", 7, 10, "XYZ", 4));
    try std.testing.expectEqual(@as(?u32, 0), fit("abcdef", 3, 3, "x", 4));
    try std.testing.expectEqual(@as(?u32, 1), fit("abcdef", 3, 3, "\n", 4));
    try std.testing.expectEqual(@as(?u32, 0), fit("abcdef", 2, 3, "", 4));
    try std.testing.expectEqual(@as(?u32, null), fit("abc\nde", 3, 4, "", 4));
    try std.testing.expectEqual(@as(?u32, null), fit("abcd\nef", 4, 5, "q", 4));
    try std.testing.expectEqual(@as(?u32, 0), fit("ab\ncd", 2, 3, "", 4));
    try std.testing.expectEqual(@as(?u32, 1), fit("ab\ncd", 1, 4, "X", 4));
    try std.testing.expectEqual(@as(?u32, 0), fit("abcdefg\nxy", 5, 9, "", 4));
    try std.testing.expectEqual(@as(?u32, null), fit("abcdef\nxy", 6, 7, "", 4));
}

test "a preedit fills its budget exactly and cuts one more byte at a code point" {
    var t: TestEngine = undefined;
    t.init();
    const engine = &t.engine;
    try std.testing.expectEqual(@as(usize, 16), engine.preedit.len);
    engine.setPreedit("0123456789abcdef");
    try std.testing.expectEqualStrings("0123456789abcdef", engine.preeditText());
    engine.setPreedit("0123456789abcd\u{6771}");
    try std.testing.expectEqualStrings("0123456789abcd", engine.preeditText());
}

test "input engine edits by codepoint and commits over a preedit" {
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
    try std.testing.expect(t.run(.move_backward));
    engine.insert("X");
    try std.testing.expectEqualStrings("caXf", engine.text());
    engine.insert("\u{e9}\u{e9}\u{e9}\u{e9}\u{e9}\u{e9}");
    try std.testing.expectEqualStrings("caX\u{e9}\u{e9}\u{e9}\u{e9}\u{e9}\u{e9}f", engine.text());
    engine.insert("\u{e9}");
    try std.testing.expectEqual(@as(u32, 16), engine.len);
    engine.deleteForward();
    try std.testing.expectEqualStrings("caX\u{e9}\u{e9}\u{e9}\u{e9}\u{e9}\u{e9}", engine.text());
}

test "a value the app binds keeps the caret's offset, as 0.3.1's did" {
    var t: TestOf(.area) = undefined;
    t.init();
    const engine = &t.engine;
    var bound: []const u8 = "line one\nline two";
    engine.syncBound(&bound);
    try std.testing.expectEqual(@as(u32, 0), engine.cursor);
    engine.cursor = 3;
    engine.anchor = 3;
    bound = "ab\u{e9}cd\nefgh";
    engine.syncBound(&bound);
    try std.testing.expectEqualStrings("ab\u{e9}cd\nefgh", engine.text());
    try std.testing.expectEqual(@as(u32, 2), engine.cursor);
    try std.testing.expectEqual(@as(u32, 2), engine.anchor);
    engine.cursor = 9;
    engine.anchor = 1;
    bound = "short";
    engine.syncBound(&bound);
    try std.testing.expectEqual(@as(u32, 5), engine.cursor);
    try std.testing.expectEqual(@as(u32, 1), engine.anchor);
}

test "shift moves select, typing replaces the selection, and words and lines move" {
    var t: TestEngine = undefined;
    t.init();
    const engine = &t.engine;
    engine.insert("one two  three");
    try std.testing.expect(t.run(.move_word_backward));
    try std.testing.expectEqual(@as(u32, 9), engine.cursor);
    try std.testing.expect(t.run(.select_word_backward));
    try std.testing.expectEqual(@as(u32, 4), engine.selectionStart());
    try std.testing.expectEqual(@as(u32, 9), engine.selectionEnd());
    engine.insert("2 ");
    try std.testing.expectEqualStrings("one 2 three", engine.text());
    try std.testing.expect(t.run(.select_forward));
    try std.testing.expect(t.run(.select_forward));
    try std.testing.expect(t.run(.move_backward));
    try std.testing.expectEqual(@as(u32, 6), engine.cursor);
    try std.testing.expect(!engine.hasSelection());
    try std.testing.expect(t.run(.move_line_end));
    try std.testing.expectEqual(engine.len, engine.cursor);
    try std.testing.expect(t.run(.select_line_start));
    try std.testing.expectEqual(engine.len, engine.selectionEnd());
    engine.backspace();
    try std.testing.expectEqualStrings("", engine.text());
}

test "undo and redo restore text and caret; a new edit drops redo" {
    var t: TestEngine = undefined;
    t.init();
    const engine = &t.engine;
    for ("ab cd") |byte| engine.insert(&.{byte});
    engine.undo();
    try std.testing.expectEqualStrings("ab", engine.text());
    try std.testing.expectEqual(@as(u32, 2), engine.cursor);
    engine.undo();
    try std.testing.expectEqualStrings("", engine.text());
    engine.redo();
    try std.testing.expectEqualStrings("ab", engine.text());
    engine.selectAll();
    engine.backspace();
    engine.undo();
    try std.testing.expectEqualStrings("ab", engine.text());
    try std.testing.expectEqual(@as(u32, 0), engine.selectionStart());
    try std.testing.expectEqual(@as(u32, 2), engine.selectionEnd());
    engine.insert("x");
    try std.testing.expect(!engine.history.canRedo());
}

test "a paste and an IME phrase are undo steps of their own" {
    var t: TestEngine = undefined;
    t.init();
    const engine = &t.engine;
    t.clipboard.write("abc");
    engine.paste(&t.clipboard);
    engine.insert("Q");
    engine.insert("\u{65e5}\u{672c}");
    engine.insert("z");
    try std.testing.expectEqualStrings("abcQ\u{65e5}\u{672c}z", engine.text());
    const steps = [_][]const u8{ "abcQ\u{65e5}\u{672c}", "abcQ", "abc", "" };
    for (steps) |expected| {
        engine.undo();
        try std.testing.expectEqualStrings(expected, engine.text());
    }
}

test "copy, cut, and paste go through the clipboard; line commands miss an input" {
    var t: TestEngine = undefined;
    t.init();
    const engine = &t.engine;
    engine.insert("hello world");
    try std.testing.expect(t.run(.select_word_backward));
    engine.copy(&t.clipboard);
    try std.testing.expectEqualStrings("world", t.clipboard.read());
    engine.cut(&t.clipboard);
    try std.testing.expectEqualStrings("hello ", engine.text());
    try std.testing.expect(t.run(.move_line_start));
    engine.paste(&t.clipboard);
    try std.testing.expectEqualStrings("worldhello ", engine.text());
    try std.testing.expectEqual(@as(u32, 5), engine.cursor);
    t.clipboard.flush();
    engine.copy(&t.clipboard);
    try std.testing.expect(t.clipboard.pending_len == null);
    try std.testing.expect(!t.run(.newline));
    try std.testing.expect(!t.run(.move_up));
    try std.testing.expect(!t.run(.indent));
}

test "delete commands remove a word or a line's part, or the newline at its edge" {
    var t: TestOf(.area) = undefined;
    t.init();
    const engine = &t.engine;
    engine.insert("one two  three\nfour");
    try std.testing.expect(t.run(.move_up));
    try std.testing.expectEqual(@as(u32, 4), engine.cursor);
    try std.testing.expect(t.run(.delete_word_backward));
    try std.testing.expectEqualStrings("two  three\nfour", engine.text());
    try std.testing.expect(t.run(.delete_word_forward));
    try std.testing.expectEqualStrings("  three\nfour", engine.text());
    try std.testing.expect(t.run(.delete_line_end));
    try std.testing.expectEqualStrings("\nfour", engine.text());
    try std.testing.expect(t.run(.delete_line_end));
    try std.testing.expectEqualStrings("four", engine.text());
    try std.testing.expect(t.run(.move_line_end));
    try std.testing.expect(t.run(.delete_line_start));
    try std.testing.expectEqualStrings("", engine.text());
    engine.undo();
    try std.testing.expectEqualStrings("four", engine.text());
    try std.testing.expect(t.run(.move_text_start));
    try std.testing.expect(t.run(.delete_line_start));
    try std.testing.expectEqualStrings("four", engine.text());
    try std.testing.expect(t.run(.select_word_forward));
    try std.testing.expect(t.run(.delete_word_backward));
    try std.testing.expectEqualStrings("", engine.text());
    engine.undo();
    try std.testing.expectEqualStrings("four", engine.text());
}

test "only a character move collapses a selection to its edge" {
    var t: TestEngine = undefined;
    t.init();
    const engine = &t.engine;
    engine.insert("ab cd ef");
    engine.anchor = 3;
    engine.cursor = 5;
    try std.testing.expect(t.run(.move_backward));
    try std.testing.expectEqual(@as(u32, 3), engine.cursor);
    try std.testing.expect(!engine.hasSelection());
    engine.anchor = 3;
    engine.cursor = 5;
    try std.testing.expect(t.run(.move_word_forward));
    try std.testing.expectEqual(@as(u32, 8), engine.cursor);
    try std.testing.expect(!engine.hasSelection());
    try std.testing.expect(t.run(.select_text_start));
    try std.testing.expectEqual(@as(u32, 0), engine.selectionStart());
    try std.testing.expectEqual(@as(u32, 8), engine.selectionEnd());
}

test "word forward stops at word ends across spaces, newlines, and UTF-8" {
    const sample = "one two  three";
    const expected = [_][2]u32{
        .{ 0, 3 },
        .{ 1, 3 },
        .{ 3, 7 },
        .{ 4, 7 },
        .{ 7, 14 },
        .{ 8, 14 },
        .{ 9, 14 },
        .{ 14, 14 },
    };
    for (expected) |pair| {
        try std.testing.expectEqual(pair[1], nextWord(sample, pair[0]));
    }
    try std.testing.expectEqual(@as(u32, 0), nextWord("", 0));
    try std.testing.expectEqual(@as(u32, 3), nextWord("   ", 0));
    try std.testing.expectEqual(@as(u32, 5), nextWord("  one", 0));
    try std.testing.expectEqual(@as(u32, 3), nextWord("one   ", 0));
    try std.testing.expectEqual(@as(u32, 6), nextWord("one   ", 3));
    const lines = "one\ntwo\n\nthree";
    try std.testing.expectEqual(@as(u32, 3), nextWord(lines, 0));
    try std.testing.expectEqual(@as(u32, 7), nextWord(lines, 3));
    try std.testing.expectEqual(@as(u32, 14), nextWord(lines, 7));
    const utf8 = "caf\u{e9} \u{6771}\u{4eac}";
    try std.testing.expectEqual(@as(u32, 5), nextWord(utf8, 0));
    try std.testing.expectEqual(@as(u32, 12), nextWord(utf8, 5));
    try std.testing.expectEqual(@as(u32, 6), previousWord(utf8, 12));
    try std.testing.expectEqual(@as(u32, 0), previousWord(utf8, 6));
}

test "select and delete word forward follow word ends without eating trailing spaces" {
    var t: TestOf(.area) = undefined;
    t.init();
    const engine = &t.engine;
    engine.insert("one two  three   ");
    try std.testing.expect(t.run(.move_text_start));
    try std.testing.expect(t.run(.select_word_forward));
    try std.testing.expectEqual(@as(u32, 0), engine.selectionStart());
    try std.testing.expectEqual(@as(u32, 3), engine.selectionEnd());
    try std.testing.expect(t.run(.select_word_forward));
    try std.testing.expectEqual(@as(u32, 7), engine.selectionEnd());
    try std.testing.expect(t.run(.select_word_backward));
    try std.testing.expectEqual(@as(u32, 4), engine.selectionEnd());
    try std.testing.expect(t.run(.move_text_start));
    try std.testing.expect(t.run(.delete_word_forward));
    try std.testing.expectEqualStrings(" two  three   ", engine.text());
    try std.testing.expect(t.run(.delete_word_forward));
    try std.testing.expectEqualStrings("  three   ", engine.text());
    try std.testing.expect(t.run(.delete_word_forward));
    try std.testing.expectEqualStrings("   ", engine.text());
    try std.testing.expect(t.run(.delete_word_forward));
    try std.testing.expectEqualStrings("", engine.text());
    try std.testing.expect(t.run(.delete_word_forward));
    try std.testing.expectEqualStrings("", engine.text());
}

test "the caret shows after a move, then blinks at 530 ms" {
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
    engine.insert("a");
    _ = engine.prepare(true, 2400 * ms);
    try std.testing.expect(engine.view.caret_visible);
    try std.testing.expectEqual(@as(?u32, null), engine.prepare(false, 2500 * ms));
    try std.testing.expect(!engine.view.caret_visible);
}

test "an area moves between lines at the preferred column" {
    var t: TestOf(.area) = undefined;
    t.init();
    const engine = &t.engine;
    engine.insert("abcdef\nxy\nlonger line");
    try std.testing.expectEqual(@as(u32, 21), engine.cursor);
    try std.testing.expect(t.run(.move_up));
    try std.testing.expectEqual(@as(u32, 9), engine.cursor);
    try std.testing.expect(t.run(.move_up));
    try std.testing.expectEqual(@as(u32, 6), engine.cursor);
    try std.testing.expect(t.run(.move_down));
    try std.testing.expect(t.run(.move_down));
    try std.testing.expectEqual(@as(u32, 21), engine.cursor);
    try std.testing.expect(t.run(.move_down));
    try std.testing.expectEqual(@as(u32, 21), engine.cursor);
    try std.testing.expect(t.run(.move_text_start));
    try std.testing.expectEqual(@as(u32, 0), engine.cursor);
    try std.testing.expect(t.run(.select_down));
    try std.testing.expectEqual(@as(u32, 0), engine.selectionStart());
    try std.testing.expectEqual(@as(u32, 7), engine.selectionEnd());
    try std.testing.expect(t.run(.move_text_end));
    try std.testing.expectEqual(@as(u32, 21), engine.cursor);
    try std.testing.expect(t.run(.move_text_start));
    try std.testing.expectEqual(@as(u32, 0), engine.cursor);
    try std.testing.expect(t.run(.select_text_end));
    try std.testing.expectEqual(@as(u32, 0), engine.selectionStart());
    try std.testing.expectEqual(@as(u32, 21), engine.selectionEnd());
    try std.testing.expect(t.run(.move_text_start));
    try std.testing.expect(t.run(.select_down));
    try std.testing.expect(t.run(.move_forward));
    try std.testing.expect(t.run(.move_forward));
    try std.testing.expectEqual(@as(u32, 8), engine.cursor);
    try std.testing.expect(t.run(.move_line_end));
    try std.testing.expectEqual(@as(u32, 9), engine.cursor);
    try std.testing.expect(t.run(.move_line_start));
    try std.testing.expectEqual(@as(u32, 7), engine.cursor);
    try std.testing.expect(t.run(.newline));
    try std.testing.expectEqualStrings("abcdef\n\nxy\nlonger line", engine.text());
}

test "a vertical move never lands inside a codepoint" {
    var t: TestOf(.area) = undefined;
    t.init();
    const engine = &t.engine;
    engine.insert("ab\n\u{e9}z");
    try std.testing.expect(t.run(.move_text_start));
    try std.testing.expect(t.run(.move_forward));
    try std.testing.expect(t.run(.move_down));
    try std.testing.expectEqual(@as(u32, 3), engine.cursor);
    var input_test: TestEngine = undefined;
    input_test.init();
    try std.testing.expect(!input_test.run(.move_up));
    try std.testing.expect(!input_test.run(.newline));
}

test "an area scrolls to keep the caret's line in view" {
    var t: TestOf(.area) = undefined;
    t.init();
    const engine = &t.engine;
    engine.insert("0\n1\n2\n3\n4\n5\n6\n7\n8\n9");
    engine.follow(10, 30);
    try std.testing.expectEqual(@as(f32, 70), engine.scroll_y);
    _ = engine.prepare(true, 0);
    engine.scroll_y = 20;
    engine.follow(10, 30);
    try std.testing.expectEqual(@as(f32, 20), engine.scroll_y);
    try std.testing.expect(t.run(.move_up));
    try std.testing.expect(t.run(.move_up));
    try std.testing.expect(t.run(.move_up));
    try std.testing.expect(t.run(.move_up));
    try std.testing.expect(t.run(.move_up));
    try std.testing.expect(t.run(.move_up));
    engine.follow(10, 30);
    try std.testing.expectEqual(@as(f32, 20), engine.scroll_y);
    try std.testing.expect(t.run(.move_up));
    engine.follow(10, 30);
    try std.testing.expectEqual(@as(f32, 20), engine.scroll_y);
    try std.testing.expect(t.run(.move_up));
    engine.follow(10, 30);
    try std.testing.expectEqual(@as(f32, 10), engine.scroll_y);
    engine.selectAll();
    engine.backspace();
    engine.follow(10, 30);
    try std.testing.expectEqual(@as(f32, 0), engine.scroll_y);
}

test "the wheel scrolls an area the way it scrolls a scroll box" {
    var t: TestOf(.area) = undefined;
    t.init();
    const engine = &t.engine;
    engine.scroll_y = 100;
    const event = input.InputEvent{ .scroll = .{
        .position = .{ .x = 0, .y = 0 },
        .delta = .{ .x = 0, .y = 15 },
        .modifiers = .{},
    } };
    try std.testing.expect(engine.apply(&event));
    const expected: f32 = if (@import("window.zig").wheel_delta_inverted) 85 else 115;
    try std.testing.expectEqual(expected, engine.scroll_y);
    var line: TestOf(.input) = undefined;
    line.init();
    try std.testing.expect(!line.engine.apply(&event));
}

test "a click finds the nearest codepoint boundary and containing codepoint" {
    const Fake = struct {
        fn measureText(_: @This(), _: anytype, value: []const u8, _: anytype) !f32 {
            const count = std.unicode.utf8CountCodepoints(value) catch unreachable;
            return @floatFromInt(count * 10);
        }
    };
    const fake = Fake{};
    const sample = "a\u{e9}b";
    try std.testing.expectEqual(ColumnHit{ .caret = 0, .char_at = 0 }, hitColumn(fake, sample, -5));
    try std.testing.expectEqual(ColumnHit{ .caret = 1, .char_at = 1 }, hitColumn(fake, sample, 14));
    try std.testing.expectEqual(ColumnHit{ .caret = 3, .char_at = 1 }, hitColumn(fake, sample, 16));
    try std.testing.expectEqual(ColumnHit{ .caret = 3, .char_at = 3 }, hitColumn(fake, sample, 24));
    try std.testing.expectEqual(
        ColumnHit{ .caret = 4, .char_at = 3 },
        hitColumn(fake, sample, 1000),
    );
    try std.testing.expectEqual(ColumnHit{ .caret = 0, .char_at = 0 }, hitColumn(fake, "", 12));
}

test "word ranges isolate words and space runs within a line across UTF-8" {
    const sample = "one two  caf\u{e9}\nnext";
    try std.testing.expectEqual(Range{ .start = 0, .end = 3 }, wordRange(sample, 0, 14, 0));
    try std.testing.expectEqual(Range{ .start = 0, .end = 3 }, wordRange(sample, 0, 14, 2));
    try std.testing.expectEqual(Range{ .start = 3, .end = 4 }, wordRange(sample, 0, 14, 3));
    try std.testing.expectEqual(Range{ .start = 4, .end = 7 }, wordRange(sample, 0, 14, 5));
    try std.testing.expectEqual(Range{ .start = 7, .end = 9 }, wordRange(sample, 0, 14, 7));
    try std.testing.expectEqual(Range{ .start = 7, .end = 9 }, wordRange(sample, 0, 14, 8));
    try std.testing.expectEqual(Range{ .start = 9, .end = 14 }, wordRange(sample, 0, 14, 12));
    try std.testing.expectEqual(Range{ .start = 15, .end = 19 }, wordRange(sample, 15, 19, 15));
    try std.testing.expectEqual(Range{ .start = 4, .end = 4 }, wordRange("abc\n\ndef", 4, 4, 4));
    try std.testing.expectEqual(SelectionMode.char, modeOf(0, false));
    try std.testing.expectEqual(SelectionMode.char, modeOf(1, false));
    try std.testing.expectEqual(SelectionMode.word, modeOf(2, false));
    try std.testing.expectEqual(SelectionMode.line, modeOf(3, false));
    try std.testing.expectEqual(SelectionMode.line, modeOf(4, false));
    try std.testing.expectEqual(SelectionMode.line, modeOf(1, true));
}

test "an editor's Tab indents as one step, and a line selection takes its newline" {
    var t: TestOf(.editor) = undefined;
    t.init();
    const engine = &t.engine;
    engine.insert("a");
    engine.insert("b");
    try std.testing.expect(t.run(.indent));
    try std.testing.expectEqualStrings("ab    ", engine.text());
    engine.undo();
    try std.testing.expectEqualStrings("ab", engine.text());
    engine.indent = .{ .size = 2, .hard_tabs = true };
    try std.testing.expect(t.run(.indent));
    try std.testing.expectEqualStrings("ab\t", engine.text());
    engine.insert("\nxy\nz");
    const middle = engine.lineRange(4);
    engine.applyRange(middle, middle, middle.start, .line);
    try std.testing.expectEqual(@as(u32, 4), engine.cursor);
    try std.testing.expectEqual(@as(u32, 7), engine.anchor);
    const last = engine.lineRange(7);
    engine.applyRange(last, last, last.start, .line);
    try std.testing.expectEqual(@as(u32, 8), engine.anchor);
    engine.applyRange(middle, last, last.end, .line);
    try std.testing.expectEqual(@as(u32, 4), engine.anchor);
    try std.testing.expectEqual(@as(u32, 8), engine.cursor);
    const first = engine.lineRange(0);
    engine.applyRange(middle, first, first.start, .line);
    try std.testing.expectEqual(@as(u32, 7), engine.anchor);
    try std.testing.expectEqual(@as(u32, 0), engine.cursor);
}
