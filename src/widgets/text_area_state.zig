//! TextArea Widget - Multi-line text input with vertical scrolling
//!
//! Key differences from TextInput:
//! - Handles newlines (\n) in text
//! - Vertical scrolling (renders only visible lines)
//! - Line index cache for O(log n) line lookup
//! - Up/down cursor navigation with preferred column
//! - Multi-line selection rendering

const std = @import("std");
const builtin = @import("builtin");
const platform = @import("../platform/mod.zig");

// Clipboard support (platform-specific)
const clipboard = if (builtin.os.tag == .macos)
    @import("../platform/mac/clipboard.zig")
else if (builtin.os.tag == .freestanding and builtin.cpu.arch == .wasm32)
    @import("../platform/web/clipboard.zig")
else
    struct {
        pub fn getText(_: std.mem.Allocator) ?[]const u8 {
            return null;
        }
        pub fn setText(_: []const u8) bool {
            return false;
        }
    };

const scene_mod = @import("../scene/mod.zig");
const input_mod = @import("../input/events.zig");
const text_mod = @import("../text/mod.zig");
const element_types = @import("../core/element_types.zig");
const event = @import("../input/event.zig");
const common = @import("text_common.zig");
const history_mod = @import("edit_history.zig");
const EditHistory = history_mod.EditHistory;
const Edit = history_mod.Edit;

const ElementId = element_types.ElementId;
const Event = event.Event;
const EventResult = event.EventResult;
const Scene = scene_mod.Scene;
const Quad = scene_mod.Quad;
const Hsla = scene_mod.Hsla;
const GlyphInstance = scene_mod.GlyphInstance;
const TextSystem = text_mod.TextSystem;
const KeyCode = input_mod.KeyCode;
const InputEvent = input_mod.InputEvent;
const Modifiers = input_mod.Modifiers;

// Re-export shared utilities
pub const isCharBoundary = common.isCharBoundary;
pub const Selection = common.Selection;
pub const Position = common.Position;

pub const Bounds = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,

    pub fn contains(self: Bounds, px: f32, py: f32) bool {
        return px >= self.x and px <= self.x + self.width and
            py >= self.y and py <= self.y + self.height;
    }
};

pub const Style = struct {
    /// Text color (dark gray, near black)
    text_color: Hsla = Hsla.init(0, 0, 0.1, 1),
    /// Placeholder text color (medium gray)
    placeholder_color: Hsla = Hsla.init(0, 0, 0.5, 1),
    /// Selection highlight color (blue tint, semi-transparent)
    selection_color: Hsla = Hsla.init(0.6, 0.8, 0.5, 0.35),
    /// Cursor color (dark gray)
    cursor_color: Hsla = Hsla.init(0, 0, 0.1, 1),
    /// Preedit underline color (for IME)
    preedit_underline_color: Hsla = Hsla.init(0, 0, 0.3, 1),
};

pub const ScrollbarStyle = struct {
    /// Show vertical scrollbar when content exceeds viewport
    show_vertical: bool = true,
    /// Scrollbar width
    scrollbar_size: f32 = 8,
    /// Padding around scrollbar
    scrollbar_padding: f32 = 2,
    /// Minimum thumb size
    min_thumb_size: f32 = 30,
    /// Track color (subtle, semi-transparent)
    track_color: Hsla = Hsla.init(0, 0, 0, 0.05),
    /// Thumb color
    thumb_color: Hsla = Hsla.init(0, 0, 0, 0.3),
    /// Thumb corner radius
    thumb_radius: f32 = 4,
};

pub const TextArea = struct {
    allocator: std.mem.Allocator,

    id: ElementId,

    // Geometry
    bounds: Bounds,
    style: Style,
    scrollbar_style: ScrollbarStyle = .{},

    // Text state (UTF-8 encoded)
    buffer: std.ArrayList(u8),

    // Line index: byte offset of each line start (always has at least one element: 0)
    line_starts: std.ArrayList(usize),

    /// Cursor position as byte offset into buffer
    cursor_byte: usize = 0,

    /// Cached cursor row (line number, 0-based)
    cursor_row: usize = 0,

    /// Cached cursor column (byte offset within line)
    cursor_col: usize = 0,

    /// Selection anchor (byte offset), null if no selection
    selection_anchor: ?usize = null,

    /// Preferred column for up/down navigation (preserves horizontal position)
    /// Stored as byte offset within line
    preferred_column: ?usize = null,

    // IME composition state
    preedit_buffer: std.ArrayList(u8),
    preedit_cursor: usize = 0,

    // Visual state
    focused: bool = false,
    cursor_visible: bool = true,
    last_blink_time: i64 = 0,

    // Scroll state
    scroll_offset_x: f32 = 0,
    scroll_offset_y: f32 = 0,

    // Layout info (set during render)
    line_height: f32 = 0,
    viewport_height: f32 = 0,

    // Placeholder text
    placeholder: []const u8 = "",

    // Callbacks
    on_change: ?*const fn (*TextArea) void = null,

    /// Cursor rect for IME candidate window positioning (set during render)
    cursor_rect: struct { x: f32 = 0, y: f32 = 0, width: f32 = 1.5, height: f32 = 20 } = .{},

    /// Pending click position for cursor placement (processed during render when text_system is available)
    pending_click: ?struct { x: f32, y: f32 } = null,

    /// Edit history for undo/redo (heap-allocated, ~512KB)
    edit_history: ?*EditHistory = null,

    const Self = @This();

    const BLINK_INTERVAL_MS: i64 = 530;

    /// Initialize TextArea
    /// Marked noinline to prevent stack accumulation
    pub noinline fn init(allocator: std.mem.Allocator, bounds: Bounds) Self {
        const unique_id = struct {
            var next: u64 = 1;
            fn get() u64 {
                const id = next;
                next += 1;
                return id;
            }
        }.get();

        var line_starts = std.ArrayList(usize){};
        line_starts.append(allocator, 0) catch {};

        return .{
            .allocator = allocator,
            .bounds = bounds,
            .style = .{},
            .buffer = .{},
            .line_starts = line_starts,
            .preedit_buffer = .{},
            .id = ElementId.int(unique_id),
            .edit_history = EditHistory.create(allocator),
        };
    }

    /// Initialize TextArea with a string ID
    /// Marked noinline to prevent stack accumulation
    pub noinline fn initWithId(allocator: std.mem.Allocator, bounds: Bounds, id: []const u8) Self {
        var line_starts = std.ArrayList(usize){};
        line_starts.append(allocator, 0) catch {};

        return .{
            .allocator = allocator,
            .bounds = bounds,
            .style = .{},
            .buffer = .{},
            .line_starts = line_starts,
            .preedit_buffer = .{},
            .id = ElementId.named(id),
            .edit_history = EditHistory.create(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.buffer.deinit(self.allocator);
        self.line_starts.deinit(self.allocator);
        self.preedit_buffer.deinit(self.allocator);
        if (self.edit_history) |h| h.destroy(self.allocator);
    }

    // =========================================================================
    // Text Content
    // =========================================================================

    pub fn getText(self: *const Self) []const u8 {
        return self.buffer.items;
    }

    pub fn setText(self: *Self, text: []const u8) !void {
        // Handle aliasing (same as TextInput)
        const buf_start = @intFromPtr(self.buffer.items.ptr);
        const buf_end = buf_start + self.buffer.items.len;
        const text_start = @intFromPtr(text.ptr);
        const text_end = text_start + text.len;
        const aliases = text_start < buf_end and text_end > buf_start;

        if (aliases) {
            var temp = std.ArrayList(u8){};
            try temp.appendSlice(self.allocator, text);
            self.buffer.clearRetainingCapacity();
            try self.buffer.appendSlice(self.allocator, temp.items);
            temp.deinit(self.allocator);
        } else {
            self.buffer.clearRetainingCapacity();
            try self.buffer.appendSlice(self.allocator, text);
        }

        self.rebuildLineIndex();
        self.cursor_byte = @min(self.cursor_byte, self.buffer.items.len);
        self.updateCursorPosition();
        self.selection_anchor = null;
    }

    pub fn clear(self: *Self) void {
        self.buffer.clearRetainingCapacity();
        self.line_starts.clearRetainingCapacity();
        self.line_starts.append(self.allocator, 0) catch {};
        self.cursor_byte = 0;
        self.cursor_row = 0;
        self.cursor_col = 0;
        self.selection_anchor = null;
        self.notifyChange();
    }

    pub fn setPlaceholder(self: *Self, placeholder: []const u8) void {
        self.placeholder = placeholder;
    }

    // =========================================================================
    // Line Index Management
    // =========================================================================

    /// Rebuild the entire line index from scratch
    fn rebuildLineIndex(self: *Self) void {
        self.line_starts.clearRetainingCapacity();
        self.line_starts.append(self.allocator, 0) catch return;

        for (self.buffer.items, 0..) |c, i| {
            if (c == '\n') {
                self.line_starts.append(self.allocator, i + 1) catch return;
            }
        }
    }

    /// Get the number of lines
    pub fn lineCount(self: *const Self) usize {
        return self.line_starts.items.len;
    }

    /// Find which line a byte offset is on (binary search)
    pub fn lineForOffset(self: *const Self, offset: usize) usize {
        const starts = self.line_starts.items;
        if (starts.len == 0) return 0;

        var low: usize = 0;
        var high: usize = starts.len;

        while (low < high) {
            const mid = low + (high - low) / 2;
            if (starts[mid] <= offset) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }
        return if (low > 0) low - 1 else 0;
    }

    /// Get the byte offset for the start of a line
    pub fn lineStartOffset(self: *const Self, row: usize) usize {
        if (row >= self.line_starts.items.len) {
            return self.buffer.items.len;
        }
        return self.line_starts.items[row];
    }

    /// Get the byte offset for the end of a line (before \n or end of buffer)
    pub fn lineEndOffset(self: *const Self, row: usize) usize {
        if (row + 1 < self.line_starts.items.len) {
            // End is one before the next line start (the \n)
            return self.line_starts.items[row + 1] - 1;
        }
        return self.buffer.items.len;
    }

    /// Get the text content of a specific line (without trailing \n)
    pub fn lineContent(self: *const Self, row: usize) []const u8 {
        const start = self.lineStartOffset(row);
        const end = self.lineEndOffset(row);
        return self.buffer.items[start..end];
    }

    /// Update cursor row/col from cursor_byte
    fn updateCursorPosition(self: *Self) void {
        self.cursor_row = self.lineForOffset(self.cursor_byte);
        const line_start = self.lineStartOffset(self.cursor_row);
        self.cursor_col = self.cursor_byte - line_start;
    }

    /// Update line index incrementally after inserting text at position
    fn updateLineIndexAfterInsert(self: *Self, insert_pos: usize, inserted_text: []const u8) void {
        // Count newlines in inserted text and their positions
        var new_line_offsets = std.ArrayList(usize){};
        defer new_line_offsets.deinit(self.allocator);

        for (inserted_text, 0..) |c, i| {
            if (c == '\n') {
                new_line_offsets.append(self.allocator, insert_pos + i + 1) catch return;
            }
        }

        if (new_line_offsets.items.len == 0 and inserted_text.len > 0) {
            // No newlines inserted, just shift subsequent line starts
            for (self.line_starts.items) |*start| {
                if (start.* > insert_pos) {
                    start.* += inserted_text.len;
                }
            }
            return;
        }

        // Rebuild is simpler for now - optimize later if needed
        self.rebuildLineIndex();
    }

    /// Update line index after deleting a range
    fn updateLineIndexAfterDelete(self: *Self, _: usize, _: usize) void {
        // For simplicity, rebuild. Could be optimized for incremental updates.
        self.rebuildLineIndex();
    }

    // =========================================================================
    // Focus
    // =========================================================================

    pub fn focus(self: *Self) void {
        self.focused = true;
        self.cursor_visible = true;
        self.last_blink_time = getTimestamp();
    }

    pub fn blur(self: *Self) void {
        self.focused = false;
        self.preedit_buffer.clearRetainingCapacity();
    }

    pub fn isFocused(self: *const Self) bool {
        return self.focused;
    }

    // =========================================================================
    // Event Handling
    // =========================================================================

    pub fn handleEvent(self: *Self, evt: Event) EventResult {
        switch (evt) {
            .mouse_down => |e| {
                if (self.bounds.contains(e.x, e.y)) {
                    self.focus();
                    // Store click position for processing during render (when text_system is available)
                    self.pending_click = .{ .x = e.x, .y = e.y };
                    self.selection_anchor = null; // Clear selection on click
                    return .consumed;
                }
            },
            .key_down => |key_event| {
                if (self.focused) {
                    self.handleKey(key_event) catch {};
                    return .consumed;
                }
            },
            .text_input => |txt| {
                if (self.focused) {
                    self.insertText(txt) catch {};
                    return .consumed;
                }
            },
            .composition => |comp| {
                if (self.focused) {
                    self.setComposition(comp.text) catch {};
                    return .consumed;
                }
            },
            .scroll => |scroll| {
                if (self.bounds.contains(scroll.x, scroll.y)) {
                    self.handleScroll(scroll.delta_y);
                    return .consumed;
                }
            },
            else => {},
        }
        return .ignored;
    }

    fn handleScroll(self: *Self, delta_y: f32) void {
        const max_scroll = self.maxScrollY();
        self.scroll_offset_y = std.math.clamp(
            self.scroll_offset_y - delta_y * 20, // 20px per scroll unit
            0,
            max_scroll,
        );
    }

    fn maxScrollY(self: *const Self) f32 {
        const content_height = @as(f32, @floatFromInt(self.lineCount())) * self.line_height;
        return @max(0, content_height - self.viewport_height);
    }

    pub fn getBounds(self: *const Self) struct { x: f32, y: f32, width: f32, height: f32 } {
        return .{
            .x = self.bounds.x,
            .y = self.bounds.y,
            .width = self.bounds.width,
            .height = self.bounds.height,
        };
    }

    pub fn getId(self: *const Self) ElementId {
        return self.id;
    }

    pub fn canFocus(self: *const Self) bool {
        _ = self;
        return true;
    }

    pub fn onFocus(self: *Self) void {
        self.focus();
    }

    pub fn onBlur(self: *Self) void {
        self.blur();
    }

    // =========================================================================
    // Text Editing
    // =========================================================================

    pub fn insertText(self: *Self, text: []const u8) !void {
        // Skip empty inserts
        if (text.len == 0) return;

        // Save state for history before any modifications
        const cursor_before: u32 = @intCast(self.cursor_byte);
        const anchor_before: ?u32 = if (self.selection_anchor) |a| @intCast(a) else null;
        const insert_offset: u32 = @intCast(self.selectionStart());

        // Handle selection replacement as a single compound edit
        const had_selection = self.hasSelection();
        var deleted_text_buf: [history_mod.MAX_EDIT_BYTES]u8 = undefined;
        var deleted_len: usize = 0;

        if (had_selection) {
            // Save deleted text for compound edit before deleting
            const start = self.selectionStart();
            const end = self.selectionEnd();
            deleted_len = end - start;
            if (deleted_len <= history_mod.MAX_EDIT_BYTES) {
                @memcpy(deleted_text_buf[0..deleted_len], self.buffer.items[start..end]);
            }
            // Delete without recording history (we'll record a compound replace instead)
            self.deleteSelection();
        }

        try self.buffer.insertSlice(self.allocator, self.cursor_byte, text);
        self.updateLineIndexAfterInsert(self.cursor_byte, text);

        // Record in history
        if (self.edit_history) |h| {
            if (had_selection and deleted_len > 0 and deleted_len <= history_mod.MAX_EDIT_BYTES) {
                // Compound replace edit (single undo step for delete + insert)
                if (Edit.makeReplace(
                    insert_offset,
                    deleted_text_buf[0..deleted_len],
                    text,
                    cursor_before,
                    anchor_before,
                    getTimestamp(),
                )) |edit| {
                    h.push(edit);
                }
            } else if (!had_selection and text.len <= history_mod.MAX_EDIT_BYTES) {
                // Simple insert
                h.push(Edit.makeInsert(
                    insert_offset,
                    text,
                    cursor_before,
                    anchor_before,
                    getTimestamp(),
                ));
            }
        }

        self.cursor_byte += text.len;
        self.updateCursorPosition();
        self.ensureCursorVisible();
        self.preferred_column = null;

        self.preedit_buffer.clearRetainingCapacity();
        self.resetCursorBlink();
        self.notifyChange();
    }

    pub fn setComposition(self: *Self, text: []const u8) !void {
        self.preedit_buffer.clearRetainingCapacity();
        try self.preedit_buffer.appendSlice(self.allocator, text);
        self.preedit_cursor = text.len;
        self.resetCursorBlink();
    }

    pub fn handleKey(self: *Self, key: input_mod.KeyEvent) !void {
        const code = key.key;
        const mods = key.modifiers;

        switch (code) {
            .delete => {
                // Backspace
                if (self.hasSelection()) {
                    self.deleteSelectionWithHistory();
                } else if (self.cursor_byte > 0) {
                    const prev = common.prevCharBoundary(self.buffer.items, self.cursor_byte);
                    const char_len = self.cursor_byte - prev;

                    // Record in history before deleting
                    const deleted_text = self.buffer.items[prev..self.cursor_byte];
                    if (self.edit_history) |h| {
                        if (deleted_text.len <= history_mod.MAX_EDIT_BYTES) {
                            h.push(Edit.makeDelete(
                                @intCast(prev),
                                deleted_text,
                                @intCast(self.cursor_byte),
                                null,
                                getTimestamp(),
                            ));
                        }
                    }

                    for (0..char_len) |_| {
                        _ = self.buffer.orderedRemove(prev);
                    }
                    self.updateLineIndexAfterDelete(prev, self.cursor_byte);
                    self.cursor_byte = prev;
                    self.updateCursorPosition();
                    self.preferred_column = null;
                    self.notifyChange();
                }
            },
            .forward_delete => {
                if (self.hasSelection()) {
                    self.deleteSelectionWithHistory();
                } else if (self.cursor_byte < self.buffer.items.len) {
                    const next = common.nextCharBoundary(self.buffer.items, self.cursor_byte);
                    const char_len = next - self.cursor_byte;

                    // Record in history before deleting
                    const deleted_text = self.buffer.items[self.cursor_byte..next];
                    if (self.edit_history) |h| {
                        if (deleted_text.len <= history_mod.MAX_EDIT_BYTES) {
                            h.push(Edit.makeDelete(
                                @intCast(self.cursor_byte),
                                deleted_text,
                                @intCast(self.cursor_byte),
                                null,
                                getTimestamp(),
                            ));
                        }
                    }

                    for (0..char_len) |_| {
                        _ = self.buffer.orderedRemove(self.cursor_byte);
                    }
                    self.updateLineIndexAfterDelete(self.cursor_byte, next);
                    self.updateCursorPosition();
                    self.notifyChange();
                }
            },
            .left => {
                if (mods.shift) {
                    if (self.selection_anchor == null) {
                        self.selection_anchor = self.cursor_byte;
                    }
                } else {
                    if (self.hasSelection()) {
                        self.cursor_byte = self.selectionStart();
                        self.selection_anchor = null;
                        self.updateCursorPosition();
                        self.preferred_column = null;
                        return;
                    }
                    self.selection_anchor = null;
                }
                if (mods.cmd) {
                    // Move to start of line
                    self.cursor_byte = self.lineStartOffset(self.cursor_row);
                } else if (mods.alt) {
                    self.cursor_byte = common.prevWordBoundary(self.buffer.items, self.cursor_byte);
                } else {
                    if (self.cursor_byte > 0) {
                        self.cursor_byte = common.prevCharBoundary(self.buffer.items, self.cursor_byte);
                    }
                }
                self.updateCursorPosition();
                self.preferred_column = null;
            },
            .right => {
                if (mods.shift) {
                    if (self.selection_anchor == null) {
                        self.selection_anchor = self.cursor_byte;
                    }
                } else {
                    if (self.hasSelection()) {
                        self.cursor_byte = self.selectionEnd();
                        self.selection_anchor = null;
                        self.updateCursorPosition();
                        self.preferred_column = null;
                        return;
                    }
                    self.selection_anchor = null;
                }
                if (mods.cmd) {
                    // Move to end of line
                    self.cursor_byte = self.lineEndOffset(self.cursor_row);
                } else if (mods.alt) {
                    self.cursor_byte = common.nextWordBoundary(self.buffer.items, self.cursor_byte);
                } else {
                    if (self.cursor_byte < self.buffer.items.len) {
                        self.cursor_byte = common.nextCharBoundary(self.buffer.items, self.cursor_byte);
                    }
                }
                self.updateCursorPosition();
                self.preferred_column = null;
            },
            .up => {
                if (mods.shift) {
                    if (self.selection_anchor == null) {
                        self.selection_anchor = self.cursor_byte;
                    }
                } else {
                    self.selection_anchor = null;
                }

                if (mods.cmd) {
                    // Move to start of document
                    self.cursor_byte = 0;
                    self.cursor_row = 0;
                    self.cursor_col = 0;
                    self.preferred_column = null;
                } else {
                    self.moveUp();
                }
            },
            .down => {
                if (mods.shift) {
                    if (self.selection_anchor == null) {
                        self.selection_anchor = self.cursor_byte;
                    }
                } else {
                    self.selection_anchor = null;
                }

                if (mods.cmd) {
                    // Move to end of document
                    self.cursor_byte = self.buffer.items.len;
                    self.updateCursorPosition();
                    self.preferred_column = null;
                } else {
                    self.moveDown();
                }
            },
            .a => {
                if (mods.cmd) {
                    // Select all
                    self.selection_anchor = 0;
                    self.cursor_byte = self.buffer.items.len;
                    self.updateCursorPosition();
                }
            },
            .c => {
                if (mods.cmd and self.hasSelection()) {
                    // Copy selection to clipboard
                    const start = self.selectionStart();
                    const end = self.selectionEnd();
                    const selected_text = self.buffer.items[start..end];
                    _ = clipboard.setText(selected_text);
                }
            },
            .v => {
                if (mods.cmd) {
                    // Paste from clipboard
                    if (clipboard.getText(self.allocator)) |text| {
                        defer self.allocator.free(text);
                        if (self.hasSelection()) {
                            self.deleteSelection();
                        }
                        self.insertText(text) catch {};
                    }
                }
            },
            .x => {
                if (mods.cmd and self.hasSelection()) {
                    // Cut = Copy + Delete
                    const start = self.selectionStart();
                    const end = self.selectionEnd();
                    const selected_text = self.buffer.items[start..end];
                    _ = clipboard.setText(selected_text);
                    self.deleteSelectionWithHistory();
                }
            },
            .z => {
                if (mods.cmd and !mods.shift) {
                    // Undo
                    self.applyUndo();
                } else if (mods.cmd and mods.shift) {
                    // Redo
                    self.applyRedo();
                }
            },
            .@"return" => {
                // Insert newline (multi-line support!)
                try self.insertText("\n");
            },
            else => {},
        }
        self.ensureCursorVisible();
        self.resetCursorBlink();
    }

    /// Move cursor up one line, preserving preferred column
    fn moveUp(self: *Self) void {
        if (self.cursor_row == 0) return;

        // Initialize preferred column if not set
        if (self.preferred_column == null) {
            self.preferred_column = self.cursor_col;
        }

        self.cursor_row -= 1;
        self.cursor_byte = self.clampColumnToLine(self.cursor_row, self.preferred_column.?);
        self.cursor_col = self.cursor_byte - self.lineStartOffset(self.cursor_row);
    }

    /// Move cursor down one line, preserving preferred column
    fn moveDown(self: *Self) void {
        if (self.cursor_row >= self.lineCount() - 1) return;

        if (self.preferred_column == null) {
            self.preferred_column = self.cursor_col;
        }

        self.cursor_row += 1;
        self.cursor_byte = self.clampColumnToLine(self.cursor_row, self.preferred_column.?);
        self.cursor_col = self.cursor_byte - self.lineStartOffset(self.cursor_row);
    }

    /// Convert a column offset to a valid byte position within a line
    fn clampColumnToLine(self: *const Self, row: usize, target_col: usize) usize {
        const line_start = self.lineStartOffset(row);
        const line_end = self.lineEndOffset(row);
        const line_len = line_end - line_start;

        const actual_col = @min(target_col, line_len);
        const byte_pos = line_start + actual_col;

        // Snap to char boundary
        return common.snapToCharBoundary(self.buffer.items, byte_pos);
    }

    // =========================================================================
    // Selection Helpers
    // =========================================================================

    pub fn hasSelection(self: *const Self) bool {
        return self.selection_anchor != null and self.selection_anchor.? != self.cursor_byte;
    }

    fn selectionStart(self: *const Self) usize {
        if (self.selection_anchor) |anchor| {
            return @min(anchor, self.cursor_byte);
        }
        return self.cursor_byte;
    }

    fn selectionEnd(self: *const Self) usize {
        if (self.selection_anchor) |anchor| {
            return @max(anchor, self.cursor_byte);
        }
        return self.cursor_byte;
    }

    /// Delete selection without recording history (used internally)
    fn deleteSelection(self: *Self) void {
        if (!self.hasSelection()) return;

        const start = self.selectionStart();
        const end = self.selectionEnd();
        const len = end - start;

        for (0..len) |_| {
            _ = self.buffer.orderedRemove(start);
        }

        self.updateLineIndexAfterDelete(start, end);
        self.cursor_byte = start;
        self.updateCursorPosition();
        self.selection_anchor = null;
        self.preferred_column = null;
        self.notifyChange();
    }

    /// Delete selection and record in history (used for standalone delete operations)
    fn deleteSelectionWithHistory(self: *Self) void {
        if (!self.hasSelection()) return;

        const start = self.selectionStart();
        const end = self.selectionEnd();
        const len = end - start;

        // Save deleted text for history before removing
        const deleted_text = self.buffer.items[start..end];
        if (self.edit_history) |h| {
            if (deleted_text.len <= history_mod.MAX_EDIT_BYTES) {
                h.push(Edit.makeDelete(
                    @intCast(start),
                    deleted_text,
                    @intCast(self.cursor_byte),
                    if (self.selection_anchor) |a| @intCast(a) else null,
                    getTimestamp(),
                ));
            }
        }

        for (0..len) |_| {
            _ = self.buffer.orderedRemove(start);
        }

        self.updateLineIndexAfterDelete(start, end);
        self.cursor_byte = start;
        self.updateCursorPosition();
        self.selection_anchor = null;
        self.preferred_column = null;
        self.notifyChange();
    }

    /// Select an entire line by row number (0-based)
    /// Sets selection from line start to line end (including newline if present)
    pub fn selectLine(self: *Self, row: usize) void {
        const line_count = self.lineCount();
        if (line_count == 0) return;

        const clamped_row = @min(row, line_count - 1);
        const start = self.lineStartOffset(clamped_row);

        // Selection end includes the newline character if this isn't the last line
        const end = if (clamped_row + 1 < line_count)
            self.lineStartOffset(clamped_row + 1)
        else
            self.buffer.items.len;

        // Assert offsets are valid within buffer bounds
        std.debug.assert(start <= self.buffer.items.len);
        std.debug.assert(end <= self.buffer.items.len);
        std.debug.assert(start <= end);

        // For line selection: anchor at end (including newline), cursor at start
        // This way selection spans the full line but cursor stays on selected line
        self.selection_anchor = end;
        self.cursor_byte = start;
        self.cursor_row = clamped_row;
        self.cursor_col = 0;
        self.preferred_column = null;
        self.ensureCursorVisible();
    }

    // =========================================================================
    // Undo/Redo
    // =========================================================================

    /// Apply an undo operation
    fn applyUndo(self: *Self) void {
        const h = self.edit_history orelse return;
        const edit = h.undo() orelse return;

        // Assertions: validate edit is applicable to current buffer state
        std.debug.assert(edit.op == .insert or edit.op == .delete or edit.op == .replace);
        std.debug.assert(edit.cursor_before <= self.buffer.items.len + edit.len); // cursor_before was valid

        h.beginApply();
        defer h.endApply();

        switch (edit.op) {
            .insert => {
                // Undo insert = delete the inserted text
                const start = edit.offset;
                const len = edit.len;
                const end = start + len;

                // Assert buffer has the content we're about to delete
                std.debug.assert(start + len <= self.buffer.items.len);

                for (0..len) |_| {
                    _ = self.buffer.orderedRemove(start);
                }
                self.updateLineIndexAfterDelete(start, end);
            },
            .delete => {
                // Undo delete = reinsert the deleted text
                const text = edit.getText();

                // Assert offset is valid for insertion
                std.debug.assert(edit.offset <= self.buffer.items.len);

                self.buffer.insertSlice(self.allocator, edit.offset, text) catch {
                    // Restore history state on allocation failure
                    h.undoUndo();
                    return;
                };
                self.updateLineIndexAfterInsert(edit.offset, text);
            },
            .replace => {
                // Undo replace = delete inserted text, reinsert deleted text
                const inserted_len = edit.len2;
                const deleted_text = edit.getDeletedText();

                // Assert buffer has the inserted content we're about to delete
                std.debug.assert(edit.offset + inserted_len <= self.buffer.items.len);

                // First, remove the inserted text
                for (0..inserted_len) |_| {
                    _ = self.buffer.orderedRemove(edit.offset);
                }
                self.updateLineIndexAfterDelete(edit.offset, edit.offset + inserted_len);

                // Then, reinsert the deleted text
                self.buffer.insertSlice(self.allocator, edit.offset, deleted_text) catch {
                    // Partial failure: we deleted but couldn't reinsert
                    // Restore history state - user can retry
                    h.undoUndo();
                    return;
                };
                self.updateLineIndexAfterInsert(edit.offset, deleted_text);
            },
        }

        // Restore cursor and selection state
        self.cursor_byte = edit.cursor_before;
        self.selection_anchor = if (edit.getAnchor()) |a| @as(usize, a) else null;
        self.updateCursorPosition();
        self.preferred_column = null;
        self.ensureCursorVisible();
        self.resetCursorBlink();
        self.notifyChange();
    }

    /// Apply a redo operation
    fn applyRedo(self: *Self) void {
        const h = self.edit_history orelse return;
        const edit = h.redo() orelse return;

        // Assertions: validate edit is applicable to current buffer state
        std.debug.assert(edit.op == .insert or edit.op == .delete or edit.op == .replace);
        std.debug.assert(edit.offset <= self.buffer.items.len);

        h.beginApply();
        defer h.endApply();

        switch (edit.op) {
            .insert => {
                // Redo insert = reinsert the text
                const text = edit.getText();

                // Assert offset is valid for insertion
                std.debug.assert(edit.offset <= self.buffer.items.len);

                self.buffer.insertSlice(self.allocator, edit.offset, text) catch {
                    // Restore history state on allocation failure
                    h.undoRedo();
                    return;
                };
                self.updateLineIndexAfterInsert(edit.offset, text);
                self.cursor_byte = edit.offset + edit.len;
            },
            .delete => {
                // Redo delete = delete the text again
                const start = edit.offset;
                const len = edit.len;
                const end = start + len;

                // Assert buffer has the content we're about to delete
                std.debug.assert(start + len <= self.buffer.items.len);

                for (0..len) |_| {
                    _ = self.buffer.orderedRemove(start);
                }
                self.updateLineIndexAfterDelete(start, end);
                self.cursor_byte = start;
            },
            .replace => {
                // Redo replace = delete the deleted text, insert the inserted text
                const deleted_len = edit.len;
                const inserted_text = edit.getInsertedText();

                // Assert buffer has the content we're about to delete
                std.debug.assert(edit.offset + deleted_len <= self.buffer.items.len);

                // First, remove the deleted text (which was restored by undo)
                for (0..deleted_len) |_| {
                    _ = self.buffer.orderedRemove(edit.offset);
                }
                self.updateLineIndexAfterDelete(edit.offset, edit.offset + deleted_len);

                // Then, reinsert the inserted text
                self.buffer.insertSlice(self.allocator, edit.offset, inserted_text) catch {
                    // Partial failure: we deleted but couldn't reinsert
                    // Restore history state - user can retry
                    h.undoRedo();
                    return;
                };
                self.updateLineIndexAfterInsert(edit.offset, inserted_text);
                self.cursor_byte = edit.offset + @as(usize, edit.len2);
            },
        }

        self.selection_anchor = null;
        self.updateCursorPosition();
        self.preferred_column = null;
        self.ensureCursorVisible();
        self.resetCursorBlink();
        self.notifyChange();
    }

    /// Check if undo is available
    pub fn canUndo(self: *const Self) bool {
        const h = self.edit_history orelse return false;
        return h.canUndo();
    }

    /// Check if redo is available
    pub fn canRedo(self: *const Self) bool {
        const h = self.edit_history orelse return false;
        return h.canRedo();
    }

    /// Clear edit history (e.g., after loading new content)
    pub fn clearHistory(self: *Self) void {
        if (self.edit_history) |h| h.clear();
    }

    // =========================================================================
    // Visual State
    // =========================================================================

    fn resetCursorBlink(self: *Self) void {
        self.cursor_visible = true;
        self.last_blink_time = getTimestamp();
    }

    pub fn updateBlink(self: *Self) void {
        if (!self.focused) return;

        const now = getTimestamp();
        if (now - self.last_blink_time >= BLINK_INTERVAL_MS) {
            self.cursor_visible = !self.cursor_visible;
            self.last_blink_time = now;
        }
    }

    fn notifyChange(self: *Self) void {
        if (self.on_change) |callback| {
            callback(self);
        }
    }

    // =========================================================================
    // Rendering
    // =========================================================================

    pub fn render(self: *Self, scene: *Scene, text_system: *TextSystem, scale_factor: f32) !void {
        self.updateBlink();

        const text = self.buffer.items;
        const preedit = self.preedit_buffer.items;

        // Get font metrics
        const metrics = text_system.getMetrics() orelse return;
        self.line_height = metrics.line_height;
        self.viewport_height = self.bounds.height;

        // Process pending click if any (needs text_system for measurement)
        if (self.pending_click) |click| {
            // Note: Error is intentionally ignored here - click positioning failure is recoverable
            // (user can click again). We can't use std.log on WASM (freestanding) targets.
            self.processPendingClick(click.x, click.y, text_system) catch {};
            self.pending_click = null;
        }

        // Calculate visible line range
        const first_visible_f = @floor(self.scroll_offset_y / self.line_height);
        const first_visible: usize = if (first_visible_f < 0) 0 else @intFromFloat(first_visible_f);

        const visible_count_f = @ceil(self.viewport_height / self.line_height) + 1;
        const visible_count: usize = @intFromFloat(visible_count_f);
        const last_visible = @min(first_visible + visible_count, self.lineCount());

        // Push clip for text content area
        try scene.pushClip(.{
            .x = self.bounds.x,
            .y = self.bounds.y,
            .width = self.bounds.width,
            .height = self.bounds.height,
        });
        defer scene.popClip();

        const has_content = text.len > 0 or preedit.len > 0;

        if (!has_content and self.placeholder.len > 0) {
            // Render placeholder (first line only)
            const baseline_y = metrics.calcBaseline(self.bounds.y, self.line_height);
            var opts = text_mod.RenderTextOptions{};
            _ = try text_mod.renderText(
                scene,
                text_system,
                self.placeholder,
                self.bounds.x,
                baseline_y,
                scale_factor,
                self.style.placeholder_color,
                metrics.point_size,
                &opts,
            );
        } else if (has_content) {
            // Render selection background first
            if (self.hasSelection()) {
                try self.renderSelection(scene, text_system, scale_factor);
            }

            // Render visible lines
            for (first_visible..last_visible) |row| {
                try self.renderLine(scene, text_system, row, scale_factor);
            }
        }

        // Render cursor
        if (self.focused and self.cursor_visible and preedit.len == 0) {
            try self.renderCursor(scene, text_system, scale_factor);
        }

        // Render scrollbar
        try self.renderScrollbar(scene);
    }

    fn renderLine(
        self: *Self,
        scene: *Scene,
        text_system: *TextSystem,
        row: usize,
        scale_factor: f32,
    ) !void {
        const metrics = text_system.getMetrics() orelse return;
        const line_y = self.bounds.y + @as(f32, @floatFromInt(row)) * self.line_height - self.scroll_offset_y;
        const baseline_y = metrics.calcBaseline(line_y, self.line_height);

        const line_content = self.lineContent(row);

        // Handle preedit if cursor is on this line
        if (row == self.cursor_row and self.preedit_buffer.items.len > 0) {
            const preedit = self.preedit_buffer.items;
            const line_start = self.lineStartOffset(row);
            const cursor_in_line = self.cursor_byte - line_start;

            var pen_x = self.bounds.x - self.scroll_offset_x;

            // Text before cursor
            if (cursor_in_line > 0) {
                const before = line_content[0..cursor_in_line];
                var opts = text_mod.RenderTextOptions{};
                const width = try text_mod.renderText(
                    scene,
                    text_system,
                    before,
                    pen_x,
                    baseline_y,
                    scale_factor,
                    self.style.text_color,
                    metrics.point_size,
                    &opts,
                );
                pen_x += width;
            }

            // Preedit with underline
            const preedit_start_x = pen_x;
            var preedit_opts = text_mod.RenderTextOptions{};
            const preedit_width = try text_mod.renderText(
                scene,
                text_system,
                preedit,
                pen_x,
                baseline_y,
                scale_factor,
                self.style.text_color,
                metrics.point_size,
                &preedit_opts,
            );

            // Draw underline
            const underline_y = baseline_y + 2;
            const underline = Quad.filled(
                preedit_start_x,
                underline_y,
                preedit_width,
                1,
                self.style.preedit_underline_color,
            );
            try scene.insertQuad(underline);
            pen_x += preedit_width;

            // Text after cursor
            if (cursor_in_line < line_content.len) {
                const after = line_content[cursor_in_line..];
                var after_opts = text_mod.RenderTextOptions{};
                _ = try text_mod.renderText(
                    scene,
                    text_system,
                    after,
                    pen_x,
                    baseline_y,
                    scale_factor,
                    self.style.text_color,
                    metrics.point_size,
                    &after_opts,
                );
            }
        } else {
            // Normal line rendering
            if (line_content.len > 0) {
                var line_opts = text_mod.RenderTextOptions{};
                _ = try text_mod.renderText(
                    scene,
                    text_system,
                    line_content,
                    self.bounds.x - self.scroll_offset_x,
                    baseline_y,
                    scale_factor,
                    self.style.text_color,
                    metrics.point_size,
                    &line_opts,
                );
            }
        }
    }

    fn renderCursor(
        self: *Self,
        scene: *Scene,
        text_system: *TextSystem,
        scale_factor: f32,
    ) !void {
        _ = scale_factor;
        const metrics = text_system.getMetrics() orelse return;

        const line_y = self.bounds.y + @as(f32, @floatFromInt(self.cursor_row)) * self.line_height - self.scroll_offset_y;

        // Calculate cursor x position
        var cursor_x = self.bounds.x - self.scroll_offset_x;
        if (self.cursor_col > 0) {
            const line_content = self.lineContent(self.cursor_row);
            if (self.cursor_col <= line_content.len) {
                cursor_x += try self.measureText(text_system, line_content[0..self.cursor_col]);
            }
        }

        const cursor_height = metrics.line_height;
        const cursor_y = line_y + (self.line_height - cursor_height) / 2;

        const cursor = Quad.filled(
            cursor_x,
            cursor_y,
            1.5,
            cursor_height,
            self.style.cursor_color,
        );
        try scene.insertQuadClipped(cursor);

        // Store cursor rect for IME positioning
        self.cursor_rect = .{ .x = cursor_x, .y = cursor_y, .width = 1.5, .height = cursor_height };
    }

    fn renderSelection(
        self: *Self,
        scene: *Scene,
        text_system: *TextSystem,
        scale_factor: f32,
    ) !void {
        _ = scale_factor;

        const sel_start = self.selectionStart();
        const sel_end = self.selectionEnd();

        const start_row = self.lineForOffset(sel_start);
        const end_row = self.lineForOffset(sel_end);

        // Render selection highlight for each line
        for (start_row..end_row + 1) |row| {
            const line_start = self.lineStartOffset(row);
            const line_end = self.lineEndOffset(row);

            // Calculate selection range within this line
            const sel_line_start = if (row == start_row) sel_start - line_start else 0;
            const sel_line_end = if (row == end_row) sel_end - line_start else line_end - line_start;

            // Skip if no actual selection content on this line
            if (sel_line_start >= sel_line_end) continue;

            const line_content = self.lineContent(row);
            const line_y = self.bounds.y + @as(f32, @floatFromInt(row)) * self.line_height - self.scroll_offset_y;

            // Calculate x positions
            var start_x = self.bounds.x - self.scroll_offset_x;
            if (sel_line_start > 0 and sel_line_start <= line_content.len) {
                start_x += try self.measureText(text_system, line_content[0..sel_line_start]);
            }

            var end_x = self.bounds.x - self.scroll_offset_x;
            if (sel_line_end > 0 and sel_line_end <= line_content.len) {
                end_x += try self.measureText(text_system, line_content[0..sel_line_end]);
            } else if (sel_line_end > line_content.len) {
                end_x += try self.measureText(text_system, line_content);
            }

            // Show newline extension for non-end rows (full line selected) or when selection extends past content
            if (row != end_row or sel_line_end > line_content.len) {
                end_x += 4; // Small extension to show selection includes newline
            }

            const selection_quad = Quad.filled(
                start_x,
                line_y,
                @max(2, end_x - start_x), // Min width of 2 for visibility
                self.line_height,
                self.style.selection_color,
            );
            try scene.insertQuadClipped(selection_quad);
        }
    }

    fn measureText(self: *Self, text_system: *TextSystem, text: []const u8) !f32 {
        _ = self;
        if (text.len == 0) return 0;
        var shaped = try text_system.shapeText(text, null);
        defer shaped.deinit(text_system.allocator);
        return shaped.width;
    }

    /// Process a pending click to position cursor at the clicked location
    fn processPendingClick(self: *Self, click_x: f32, click_y: f32, text_system: *TextSystem) !void {
        std.debug.assert(std.math.isFinite(click_x) and std.math.isFinite(click_y));
        std.debug.assert(text_system.getMetrics() != null);

        if (self.line_height <= 0) return;

        // Calculate which row was clicked
        const relative_y = click_y - self.bounds.y + self.scroll_offset_y;
        const row_f = @floor(relative_y / self.line_height);
        const row: usize = if (row_f < 0) 0 else @intFromFloat(row_f);
        const clamped_row = @min(row, if (self.lineCount() > 0) self.lineCount() - 1 else 0);

        // Calculate which column was clicked using text measurement
        const line_content = self.lineContent(clamped_row);
        const line_start_x = self.bounds.x - self.scroll_offset_x;
        const click_offset_x = click_x - line_start_x;

        // Binary search for the closest character position
        var best_col: usize = 0;
        var best_distance: f32 = click_offset_x; // Distance if cursor at position 0

        // Check each character position to find the closest one
        var col: usize = 0;
        while (col <= line_content.len) : (col += 1) {
            const text_width = if (col > 0) try self.measureText(text_system, line_content[0..col]) else 0;
            const distance = @abs(click_offset_x - text_width);

            if (distance < best_distance) {
                best_distance = distance;
                best_col = col;
            }

            // Early exit if we've passed the click point
            if (text_width > click_offset_x and col > 0) break;
        }

        // Set cursor position
        const line_start = self.lineStartOffset(clamped_row);
        self.cursor_byte = line_start + best_col;
        self.cursor_row = clamped_row;
        self.cursor_col = best_col;
        self.preferred_column = null;
        self.resetCursorBlink();

        // Assert cursor is within valid bounds
        std.debug.assert(self.cursor_byte <= self.buffer.items.len);
    }

    fn ensureCursorVisible(self: *Self) void {
        // Ensure cursor row is visible vertically
        const cursor_y = @as(f32, @floatFromInt(self.cursor_row)) * self.line_height;

        // Only scroll if cursor is completely outside visible area
        // If cursor is above visible area, scroll up
        if (cursor_y < self.scroll_offset_y) {
            self.scroll_offset_y = cursor_y;
        }

        // If cursor is below visible area, scroll down
        const cursor_bottom = cursor_y + self.line_height;
        if (cursor_bottom > self.scroll_offset_y + self.viewport_height) {
            self.scroll_offset_y = cursor_bottom - self.viewport_height;
        }

        // Clamp scroll
        self.scroll_offset_y = std.math.clamp(self.scroll_offset_y, 0, self.maxScrollY());
    }

    // =========================================================================
    // Scrollbar
    // =========================================================================

    /// Check if content can scroll (content taller than viewport)
    pub fn canScrollY(self: *const Self) bool {
        const content_height = @as(f32, @floatFromInt(self.lineCount())) * self.line_height;
        return content_height > self.viewport_height;
    }

    /// Get scroll percentage (0.0 - 1.0)
    fn scrollPercentY(self: *const Self) f32 {
        const max = self.maxScrollY();
        if (max <= 0) return 0;
        return self.scroll_offset_y / max;
    }

    /// Get the thumb height based on content/viewport ratio
    fn getThumbHeight(self: *const Self) f32 {
        const content_height = @as(f32, @floatFromInt(self.lineCount())) * self.line_height;
        if (content_height <= 0) return self.scrollbar_style.min_thumb_size;

        const track_height = self.bounds.height - self.scrollbar_style.scrollbar_padding * 2;
        const ratio = self.viewport_height / content_height;
        return @max(self.scrollbar_style.min_thumb_size, track_height * ratio);
    }

    /// Render vertical scrollbar
    fn renderScrollbar(self: *Self, scene: *Scene) !void {
        if (!self.scrollbar_style.show_vertical or !self.canScrollY()) return;

        const track_x = self.bounds.x + self.bounds.width - self.scrollbar_style.scrollbar_size - self.scrollbar_style.scrollbar_padding;
        const track_y = self.bounds.y + self.scrollbar_style.scrollbar_padding;
        const track_height = self.bounds.height - self.scrollbar_style.scrollbar_padding * 2;

        // Track background
        try scene.insertQuad(Quad{
            .bounds_origin_x = track_x,
            .bounds_origin_y = track_y,
            .bounds_size_width = self.scrollbar_style.scrollbar_size,
            .bounds_size_height = track_height,
            .background = self.scrollbar_style.track_color,
            .corner_radii = .{
                .top_left = self.scrollbar_style.thumb_radius,
                .top_right = self.scrollbar_style.thumb_radius,
                .bottom_left = self.scrollbar_style.thumb_radius,
                .bottom_right = self.scrollbar_style.thumb_radius,
            },
        });

        // Thumb
        const thumb_height = self.getThumbHeight();
        const scroll_range = track_height - thumb_height;
        const thumb_y = track_y + (scroll_range * self.scrollPercentY());

        try scene.insertQuad(Quad{
            .bounds_origin_x = track_x,
            .bounds_origin_y = thumb_y,
            .bounds_size_width = self.scrollbar_style.scrollbar_size,
            .bounds_size_height = thumb_height,
            .background = self.scrollbar_style.thumb_color,
            .corner_radii = .{
                .top_left = self.scrollbar_style.thumb_radius,
                .top_right = self.scrollbar_style.thumb_radius,
                .bottom_left = self.scrollbar_style.thumb_radius,
                .bottom_right = self.scrollbar_style.thumb_radius,
            },
        });
    }
};

fn getTimestamp() i64 {
    return platform.time.milliTimestamp();
}

// =============================================================================
// Tests
// =============================================================================

test "TextArea basic operations" {
    const allocator = std.testing.allocator;
    var ta = TextArea.init(allocator, .{ .x = 0, .y = 0, .width = 300, .height = 200 });
    defer ta.deinit();

    try ta.setText("Hello\nWorld");
    try std.testing.expectEqualStrings("Hello\nWorld", ta.getText());
    try std.testing.expectEqual(@as(usize, 2), ta.lineCount());
}

test "TextArea line index" {
    const allocator = std.testing.allocator;
    var ta = TextArea.init(allocator, .{ .x = 0, .y = 0, .width = 300, .height = 200 });
    defer ta.deinit();

    try ta.setText("Line 1\nLine 2\nLine 3");

    try std.testing.expectEqual(@as(usize, 3), ta.lineCount());
    try std.testing.expectEqual(@as(usize, 0), ta.lineStartOffset(0));
    try std.testing.expectEqual(@as(usize, 7), ta.lineStartOffset(1));
    try std.testing.expectEqual(@as(usize, 14), ta.lineStartOffset(2));

    try std.testing.expectEqual(@as(usize, 0), ta.lineForOffset(0));
    try std.testing.expectEqual(@as(usize, 0), ta.lineForOffset(5));
    try std.testing.expectEqual(@as(usize, 1), ta.lineForOffset(7));
    try std.testing.expectEqual(@as(usize, 2), ta.lineForOffset(14));
}

test "TextArea line content" {
    const allocator = std.testing.allocator;
    var ta = TextArea.init(allocator, .{ .x = 0, .y = 0, .width = 300, .height = 200 });
    defer ta.deinit();

    try ta.setText("First\nSecond\nThird");

    try std.testing.expectEqualStrings("First", ta.lineContent(0));
    try std.testing.expectEqualStrings("Second", ta.lineContent(1));
    try std.testing.expectEqualStrings("Third", ta.lineContent(2));
}

test "TextArea cursor navigation" {
    const allocator = std.testing.allocator;
    var ta = TextArea.init(allocator, .{ .x = 0, .y = 0, .width = 300, .height = 200 });
    defer ta.deinit();

    try ta.setText("AB\nCD\nEF");

    // Start at beginning
    ta.cursor_byte = 0;
    ta.updateCursorPosition();
    try std.testing.expectEqual(@as(usize, 0), ta.cursor_row);
    try std.testing.expectEqual(@as(usize, 0), ta.cursor_col);

    // Move down
    ta.moveDown();
    try std.testing.expectEqual(@as(usize, 1), ta.cursor_row);

    // Move down again
    ta.moveDown();
    try std.testing.expectEqual(@as(usize, 2), ta.cursor_row);

    // Move up
    ta.moveUp();
    try std.testing.expectEqual(@as(usize, 1), ta.cursor_row);
}
