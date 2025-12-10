//! TextInput - editable single-line text field
//!
//! Handles:
//! - Text rendering with cursor
//! - IME composition (preedit) display with underline
//! - Basic editing (insert, delete, cursor movement)
//! - Selection (shift+arrow, shift+click)
//! - Focus management
//!
//! Example usage:
//! ```
//! var input = TextInput.init(allocator, .{ .x = 100, .y = 100, .width = 200, .height = 32 });
//! defer input.deinit();
//!
//! // In input handler:
//! if (input.handleInput(event)) |_| {
//!     // Input consumed the event
//! }
//!
//! // In render loop:
//! try input.render(&scene, text_system, window.scale_factor);
//! ```

const std = @import("std");

// Direct imports from core modules (not through root.zig to avoid cycles)
// Use prefixed names to avoid shadowing function parameters
const scene_mod = @import("../core/scene.zig");
const input_mod = @import("../core/input.zig");
const text_mod = @import("../text/mod.zig");

const element_types = @import("../core/element_types.zig");
const event = @import("../core/event.zig");
const geometry = @import("../core/geometry.zig");

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

/// Rectangle bounds for positioning
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

/// Visual style for the text input
pub const Style = struct {
    /// Background color
    background: Hsla = Hsla.white,
    /// Border color when unfocused
    border_color: Hsla = Hsla.init(0, 0, 0.8, 1),
    /// Border color when focused
    border_color_focused: Hsla = Hsla.init(0.6, 0.8, 0.5, 1), // Blue
    /// Border width
    border_width: f32 = 1,
    /// Corner radius
    corner_radius: f32 = 4,
    /// Text color
    text_color: Hsla = Hsla.black,
    /// Placeholder text color
    placeholder_color: Hsla = Hsla.init(0, 0, 0.6, 1),
    /// Selection highlight color
    selection_color: Hsla = Hsla.init(0.6, 0.8, 0.7, 0.4),
    /// Cursor color
    cursor_color: Hsla = Hsla.black,
    /// IME preedit underline color
    preedit_underline_color: Hsla = Hsla.init(0, 0, 0.3, 1),
    /// Padding inside the input
    padding: f32 = 8,
};

/// TextInput - editable single-line text field
pub const TextInput = struct {
    allocator: std.mem.Allocator,

    id: ElementId,

    // Geometry
    bounds: Bounds,
    style: Style,

    // Text state (UTF-8 encoded)
    buffer: std.ArrayList(u8),

    /// Cursor position as byte offset into buffer
    /// Always at a valid UTF-8 boundary
    cursor_byte: usize = 0,

    /// Selection anchor (byte offset), null if no selection
    /// Selection is from min(anchor, cursor) to max(anchor, cursor)
    selection_anchor: ?usize = null,

    // IME composition state
    /// Composing text (preedit) - stored copy
    preedit_buffer: std.ArrayList(u8),
    /// Cursor position within preedit (byte offset)
    preedit_cursor: usize = 0,

    // Visual state
    focused: bool = false,
    /// Cursor visible (for blinking)
    cursor_visible: bool = true,
    /// Time of last cursor blink toggle (for animation)
    last_blink_time: i64 = 0,

    // Scroll state (for text longer than visible area)
    scroll_offset: f32 = 0,

    // Placeholder text
    placeholder: []const u8 = "",

    // Callbacks
    on_change: ?*const fn (*TextInput) void = null,
    on_submit: ?*const fn (*TextInput) void = null,
    on_cursor_rect_changed: ?*const fn (x: f32, y: f32, width: f32, height: f32) void = null, // NEW

    const Self = @This();

    /// Cursor blink interval in milliseconds
    const BLINK_INTERVAL_MS: i64 = 530;

    pub fn init(allocator: std.mem.Allocator, bounds: Bounds) Self {
        // Generate a unique integer ID for this instance
        const unique_id = struct {
            var next: u64 = 1;
            fn get() u64 {
                const id = next;
                next += 1;
                return id;
            }
        }.get();
        return .{
            .allocator = allocator,
            .bounds = bounds,
            .style = .{},
            .buffer = .{},
            .preedit_buffer = .{},
            .id = ElementId.int(unique_id),
        };
    }

    /// Initialize with a string-based ID (for WidgetStore usage)
    pub fn initWithId(allocator: std.mem.Allocator, bounds: Bounds, id: []const u8) Self {
        return .{
            .allocator = allocator,
            .bounds = bounds,
            .style = .{},
            .buffer = .{},
            .preedit_buffer = .{},
            .id = ElementId.named(id),
        };
    }

    pub fn deinit(self: *Self) void {
        self.buffer.deinit(self.allocator);
        self.preedit_buffer.deinit(self.allocator);
    }

    /// Get the current text content
    pub fn getText(self: *const Self) []const u8 {
        return self.buffer.items;
    }

    /// Set the text content
    /// Safety: Handles the case where `text` might alias with the internal buffer
    pub fn setText(self: *Self, text: []const u8) !void {
        // Check if input slice aliases with our buffer (would cause @memcpy panic)
        const buf_start = @intFromPtr(self.buffer.items.ptr);
        const buf_end = buf_start + self.buffer.items.len;
        const text_start = @intFromPtr(text.ptr);
        const text_end = text_start + text.len;

        const aliases = text_start < buf_end and text_end > buf_start;

        if (aliases) {
            // Text overlaps with buffer - need to copy to temp first
            const temp = try self.allocator.dupe(u8, text);
            defer self.allocator.free(temp);
            self.buffer.clearRetainingCapacity();
            try self.buffer.appendSlice(self.allocator, temp);
        } else {
            // Safe - no overlap
            self.buffer.clearRetainingCapacity();
            try self.buffer.appendSlice(self.allocator, text);
        }

        self.cursor_byte = self.buffer.items.len;
        self.selection_anchor = null;
        self.notifyChange();
    }

    /// Clear all text
    pub fn clear(self: *Self) void {
        self.buffer.clearRetainingCapacity();
        self.cursor_byte = 0;
        self.selection_anchor = null;
        self.notifyChange();
    }

    /// Set placeholder text
    pub fn setPlaceholder(self: *Self, text: []const u8) void {
        self.placeholder = text;
    }

    // =========================================================================
    // Focus Management
    // =========================================================================

    pub fn focus(self: *Self) void {
        self.focused = true;
        self.cursor_visible = true;
        self.last_blink_time = std.time.milliTimestamp();
    }

    pub fn blur(self: *Self) void {
        self.focused = false;
        self.selection_anchor = null;
        // Clear any pending IME composition
        self.preedit_buffer.clearRetainingCapacity();
    }

    pub fn isFocused(self: *const Self) bool {
        return self.focused;
    }

    // =========================================================================
    // Input Handling
    // =========================================================================

    pub fn handleEvent(self: *Self, ev: *Event) EventResult {
        // Only handle events in target or bubble phase
        if (ev.phase == .capture) return .ignored;

        switch (ev.inner) {
            .mouse_down => |m| {
                const px: f32 = @floatCast(m.position.x);
                const py: f32 = @floatCast(m.position.y);
                if (self.bounds.contains(px, py)) {
                    // Request focus through event system
                    ev.stopPropagation();
                    return .stop;
                }
            },
            .key_down => |k| {
                if (self.focused) {
                    self.handleKey(k) catch {};
                    ev.stopPropagation();
                    return .stop;
                }
            },
            .text_input => |t| {
                if (self.focused) {
                    self.insertText(t.text) catch {};
                    ev.stopPropagation();
                    return .stop;
                }
            },
            .composition => |c| {
                if (self.focused) {
                    self.setComposition(c.text) catch {};
                    ev.stopPropagation();
                    return .stop;
                }
            },
            else => {},
        }
        return .ignored;
    }

    /// Element interface: get bounds
    pub fn getBounds(self: *Self) element_types.Bounds {
        return geometry.BoundsF.init(
            self.bounds.x,
            self.bounds.y,
            self.bounds.width,
            self.bounds.height,
        );
    }

    /// Element interface: get ID
    pub fn getId(self: *const Self) ElementId {
        return self.id;
    }

    /// Element interface: can this element receive focus?
    pub fn canFocus(_: *Self) bool {
        return true;
    }

    /// Element interface: called when gaining focus
    pub fn onFocus(self: *Self) void {
        self.focus();
    }

    /// Element interface: called when losing focus
    pub fn onBlur(self: *Self) void {
        self.blur();
    }

    /// Handle text_input event (committed text from IME)
    pub fn insertText(self: *Self, text: []const u8) !void {
        // Delete any existing selection first
        self.deleteSelection();

        // Insert at cursor position
        try self.buffer.insertSlice(self.allocator, self.cursor_byte, text);
        self.cursor_byte += text.len;

        // Clear preedit
        self.preedit_buffer.clearRetainingCapacity();

        self.resetCursorBlink();
        self.notifyChange();
    }

    /// Handle composition event (preedit text from IME)
    pub fn setComposition(self: *Self, text: []const u8) !void {
        self.preedit_buffer.clearRetainingCapacity();
        try self.preedit_buffer.appendSlice(self.allocator, text);
        self.preedit_cursor = text.len;
        self.resetCursorBlink();
    }

    /// Handle key_down for cursor movement, delete, etc.
    pub fn handleKey(self: *Self, key: input_mod.KeyEvent) !void {
        const code = key.key;
        const mods = key.modifiers;

        switch (code) {
            .delete => {
                // Backspace
                if (self.hasSelection()) {
                    self.deleteSelection();
                } else if (self.cursor_byte > 0) {
                    const prev = self.prevCharBoundary(self.cursor_byte);
                    _ = self.buffer.orderedRemove(prev);
                    // Remove remaining bytes of the character
                    const char_len = self.cursor_byte - prev;
                    for (1..char_len) |_| {
                        _ = self.buffer.orderedRemove(prev);
                    }
                    self.cursor_byte = prev;
                    self.notifyChange();
                }
            },
            .forward_delete => {
                if (self.hasSelection()) {
                    self.deleteSelection();
                } else if (self.cursor_byte < self.buffer.items.len) {
                    const next = self.nextCharBoundary(self.cursor_byte);
                    const char_len = next - self.cursor_byte;
                    for (0..char_len) |_| {
                        _ = self.buffer.orderedRemove(self.cursor_byte);
                    }
                    self.notifyChange();
                }
            },
            .left => {
                if (mods.shift) {
                    // Extend selection
                    if (self.selection_anchor == null) {
                        self.selection_anchor = self.cursor_byte;
                    }
                } else {
                    // Clear selection and move
                    if (self.hasSelection()) {
                        self.cursor_byte = self.selectionStart();
                        self.selection_anchor = null;
                        return;
                    }
                    self.selection_anchor = null;
                }
                if (mods.cmd) {
                    // Move to start of line
                    self.cursor_byte = 0;
                } else if (mods.alt) {
                    // Move by word
                    self.cursor_byte = self.prevWordBoundary(self.cursor_byte);
                } else {
                    // Move by character
                    if (self.cursor_byte > 0) {
                        self.cursor_byte = self.prevCharBoundary(self.cursor_byte);
                    }
                }
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
                        return;
                    }
                    self.selection_anchor = null;
                }
                if (mods.cmd) {
                    // Move to end of line
                    self.cursor_byte = self.buffer.items.len;
                } else if (mods.alt) {
                    // Move by word
                    self.cursor_byte = self.nextWordBoundary(self.cursor_byte);
                } else {
                    // Move by character
                    if (self.cursor_byte < self.buffer.items.len) {
                        self.cursor_byte = self.nextCharBoundary(self.cursor_byte);
                    }
                }
            },
            .a => {
                if (mods.cmd) {
                    // Select all
                    self.selection_anchor = 0;
                    self.cursor_byte = self.buffer.items.len;
                }
            },
            .@"return" => {
                if (self.on_submit) |callback| {
                    callback(self);
                }
            },
            else => {},
        }
        self.resetCursorBlink();
    }

    // =========================================================================
    // Selection Helpers
    // =========================================================================

    pub fn hasSelection(self: *const Self) bool {
        // Debug: catch invalid state early
        std.debug.assert(self.cursor_byte <= self.buffer.items.len);
        if (self.selection_anchor) |a| std.debug.assert(a <= self.buffer.items.len);

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

    fn deleteSelection(self: *Self) void {
        if (!self.hasSelection()) return;

        const start = self.selectionStart();
        const end = self.selectionEnd();
        const len = end - start;

        // Remove bytes from end to start
        for (0..len) |_| {
            _ = self.buffer.orderedRemove(start);
        }

        self.cursor_byte = start;
        self.selection_anchor = null;
        self.notifyChange();
    }

    // =========================================================================
    // UTF-8 Navigation Helpers
    // =========================================================================

    /// Check if a byte position is on a valid UTF-8 character boundary.
    /// A position is valid if it's at the start/end or doesn't point to a continuation byte.
    fn isCharBoundary(self: *const Self, pos: usize) bool {
        if (pos == 0) return true;
        if (pos >= self.buffer.items.len) return true;
        // Continuation bytes have the pattern 10xxxxxx (0x80-0xBF)
        return (self.buffer.items[pos] & 0xC0) != 0x80;
    }

    /// Snap a byte position to a valid UTF-8 character boundary.
    /// If already valid, returns the same position. Otherwise moves backward
    /// to the start of the current character.
    fn snapToCharBoundary(self: *const Self, pos: usize) usize {
        if (pos == 0) return 0;
        if (pos >= self.buffer.items.len) return self.buffer.items.len;
        // If already on a boundary, return as-is
        if ((self.buffer.items[pos] & 0xC0) != 0x80) return pos;
        // Otherwise, find the start of this character
        return self.prevCharBoundary(pos);
    }

    /// Snap a byte position to a valid UTF-8 character boundary for a given slice.
    /// Static version that doesn't rely on self.buffer (for thread safety).
    fn snapToCharBoundaryFor(_: *const Self, text: []const u8, pos: usize) usize {
        if (pos == 0) return 0;
        if (pos >= text.len) return text.len;
        // If already on a boundary, return as-is
        if ((text[pos] & 0xC0) != 0x80) return pos;
        // Otherwise, find the start of this character
        var i = pos - 1;
        while (i > 0 and (text[i] & 0xC0) == 0x80) {
            i -= 1;
        }
        return i;
    }

    /// Find the previous character boundary
    fn prevCharBoundary(self: *const Self, pos: usize) usize {
        if (pos == 0) return 0;
        var i = pos - 1;
        // Skip continuation bytes (10xxxxxx)
        while (i > 0 and (self.buffer.items[i] & 0xC0) == 0x80) {
            i -= 1;
        }
        return i;
    }

    /// Find the next character boundary
    fn nextCharBoundary(self: *const Self, pos: usize) usize {
        if (pos >= self.buffer.items.len) return self.buffer.items.len;
        var i = pos + 1;
        // Skip continuation bytes
        while (i < self.buffer.items.len and (self.buffer.items[i] & 0xC0) == 0x80) {
            i += 1;
        }
        return i;
    }

    /// Find the previous word boundary
    fn prevWordBoundary(self: *const Self, pos: usize) usize {
        if (pos == 0) return 0;
        var i = self.prevCharBoundary(pos);
        // Skip whitespace
        while (i > 0 and self.isWhitespaceAt(i)) {
            i = self.prevCharBoundary(i);
        }
        // Skip word characters
        while (i > 0 and !self.isWhitespaceAt(self.prevCharBoundary(i))) {
            i = self.prevCharBoundary(i);
        }
        return i;
    }

    /// Find the next word boundary
    fn nextWordBoundary(self: *const Self, pos: usize) usize {
        const len = self.buffer.items.len;
        if (pos >= len) return len;
        var i = pos;
        // Skip current word characters
        while (i < len and !self.isWhitespaceAt(i)) {
            i = self.nextCharBoundary(i);
        }
        // Skip whitespace
        while (i < len and self.isWhitespaceAt(i)) {
            i = self.nextCharBoundary(i);
        }
        return i;
    }

    fn isWhitespaceAt(self: *const Self, pos: usize) bool {
        if (pos >= self.buffer.items.len) return true;
        const c = self.buffer.items[pos];
        return c == ' ' or c == '\t' or c == '\n' or c == '\r';
    }

    // =========================================================================
    // Visual State
    // =========================================================================

    fn resetCursorBlink(self: *Self) void {
        self.cursor_visible = true;
        self.last_blink_time = std.time.milliTimestamp();
    }

    /// Update cursor blink state (call once per frame)
    pub fn updateBlink(self: *Self) void {
        if (!self.focused) return;

        const now = std.time.milliTimestamp();
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

    /// Render the text input to the scene
    pub fn render(self: *Self, scene: *Scene, text_system: *TextSystem, scale_factor: f32) !void {
        // Update cursor blink
        self.updateBlink();

        // Build display text: text before cursor + preedit + text after cursor
        const text = self.buffer.items;
        const preedit = self.preedit_buffer.items;

        // Safety: capture cursor position and ensure it's within valid range
        // AND on a valid UTF-8 boundary. We use a local copy because another
        // thread could modify self.cursor_byte during rendering.
        var cursor_byte = self.cursor_byte;
        if (cursor_byte > text.len) {
            cursor_byte = text.len;
        } else if (text.len > 0 and cursor_byte > 0) {
            // Ensure cursor is on a valid UTF-8 character boundary
            cursor_byte = self.snapToCharBoundaryFor(text, cursor_byte);
        }

        // Calculate text area dimensions early (needed for scroll calculation)
        const text_x = self.bounds.x + self.style.padding;
        const text_y = self.bounds.y + self.style.padding;
        const text_width = self.bounds.width - (self.style.padding * 2);
        const text_height = self.bounds.height - (self.style.padding * 2);

        // Ensure cursor is visible BEFORE rendering (fixes first-frame overflow)
        if (self.focused and preedit.len == 0) {
            self.ensureCursorVisible(text_system, text_width);
        }

        // Background (rendered OUTSIDE the clip region)
        const border_color = if (self.focused) self.style.border_color_focused else self.style.border_color;
        const bg = Quad.rounded(
            self.bounds.x,
            self.bounds.y,
            self.bounds.width,
            self.bounds.height,
            self.style.background,
            self.style.corner_radius,
        ).withBorder(border_color, self.style.border_width);
        try scene.insertQuad(bg);

        // Get font metrics for baseline positioning
        const metrics = text_system.getMetrics() orelse return;
        const line_height = metrics.ascender + metrics.descender;
        const baseline_y = self.bounds.y + (self.bounds.height + line_height) / 2 - metrics.descender;

        // Push clip for text content area - all glyphs will be clipped to this region
        try scene.pushClip(.{
            .x = text_x,
            .y = text_y,
            .width = text_width,
            .height = text_height,
        });
        defer scene.popClip();

        // Determine what to display
        const has_content = text.len > 0 or preedit.len > 0;

        if (!has_content and self.placeholder.len > 0) {
            // Render placeholder
            _ = try text_mod.renderText(scene, text_system, self.placeholder, text_x, baseline_y, scale_factor, self.style.placeholder_color, .{});
        } else if (has_content) {
            // Render selection background first (if any)
            if (self.hasSelection()) {
                try self.renderSelection(scene, text_system, text_x, text_y, self.bounds.height - self.style.padding * 2, scale_factor);
            }

            // Render text before cursor
            var pen_x = text_x - self.scroll_offset;
            if (cursor_byte > 0) {
                const before = text[0..cursor_byte];
                const width = try text_mod.renderText(scene, text_system, before, pen_x, baseline_y, scale_factor, self.style.text_color, .{});
                pen_x += width;
            }

            // Render preedit with underline
            const preedit_start_x = pen_x;
            if (preedit.len > 0) {
                const preedit_width = try text_mod.renderText(scene, text_system, preedit, pen_x, baseline_y, scale_factor, self.style.text_color, .{});

                // Draw underline under preedit
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
            }

            // Render text after cursor
            if (cursor_byte < text.len) {
                const after = text[cursor_byte..];
                _ = try text_mod.renderText(scene, text_system, after, pen_x, baseline_y, scale_factor, self.style.text_color, .{});
            }
        }

        // Render cursor (still inside clip region, which is fine)
        if (self.focused and self.cursor_visible and preedit.len == 0) {
            // Calculate cursor x position (scroll already adjusted above)
            var cursor_x = text_x - self.scroll_offset;
            if (cursor_byte > 0 and text.len > 0) {
                cursor_x += try self.measureText(text_system, text[0..cursor_byte]);
            }

            const cursor_height = metrics.line_height;
            const cursor_y = text_y + (self.bounds.height - self.style.padding * 2 - cursor_height) / 2;

            const cursor = Quad.filled(
                cursor_x,
                cursor_y,
                1.5, // cursor width
                cursor_height,
                self.style.cursor_color,
            );
            try scene.insertQuad(cursor);

            // Notify about cursor rect for IME positioning
            if (self.on_cursor_rect_changed) |callback| {
                callback(cursor_x, cursor_y, 1.5, cursor_height);
            }
        }
    }

    /// Measure text width without rendering
    fn measureText(self: *Self, text_system: *TextSystem, text: []const u8) !f32 {
        _ = self;
        if (text.len == 0) return 0;
        var shaped = try text_system.shapeText(text);
        defer shaped.deinit(text_system.allocator);
        return shaped.width;
    }

    /// Render selection highlight
    fn renderSelection(
        self: *Self,
        scene: *Scene,
        text_system: *TextSystem,
        text_x: f32,
        text_y: f32,
        text_height: f32,
        scale_factor: f32,
    ) !void {
        _ = scale_factor;
        const text = self.buffer.items;

        // Ensure selection bounds are on valid UTF-8 boundaries
        if (self.selection_anchor) |anchor| {
            if (anchor > text.len or !self.isCharBoundary(anchor)) {
                self.selection_anchor = self.snapToCharBoundary(@min(anchor, text.len));
            }
        }

        const start = self.selectionStart();
        const end = self.selectionEnd();

        // Calculate x positions
        var start_x = text_x - self.scroll_offset;
        if (start > 0) {
            start_x += try self.measureText(text_system, text[0..start]);
        }

        var end_x = text_x - self.scroll_offset;
        if (end > 0) {
            end_x += try self.measureText(text_system, text[0..end]);
        }

        const selection_quad = Quad.filled(
            start_x,
            text_y,
            end_x - start_x,
            text_height,
            self.style.selection_color,
        );
        try scene.insertQuad(selection_quad);
    }

    /// Ensure cursor is visible by adjusting scroll offset.
    /// Call this BEFORE rendering to ensure first frame is correct.
    fn ensureCursorVisible(self: *Self, text_system: *TextSystem, text_width: f32) void {
        const text = self.buffer.items;

        // Calculate cursor position in text space (no scroll applied)
        const cursor_text_x: f32 = if (self.cursor_byte > 0 and text.len > 0)
            self.measureText(text_system, text[0..self.cursor_byte]) catch 0
        else
            0;

        const margin: f32 = 10; // Pixels of breathing room

        // If cursor is left of visible area, scroll left
        if (cursor_text_x < self.scroll_offset + margin) {
            self.scroll_offset = @max(0, cursor_text_x - margin);
        }

        // If cursor is right of visible area, scroll right
        if (cursor_text_x > self.scroll_offset + text_width - margin) {
            self.scroll_offset = cursor_text_x - text_width + margin;
        }

        // Clamp scroll to non-negative
        self.scroll_offset = @max(0, self.scroll_offset);
    }
};

test "TextInput basic operations" {
    const allocator = std.testing.allocator;

    var input = TextInput.init(allocator, .{ .x = 0, .y = 0, .width = 200, .height = 32 });
    defer input.deinit();

    // Test setText
    try input.setText("Hello");
    try std.testing.expectEqualStrings("Hello", input.getText());
    try std.testing.expectEqual(@as(usize, 5), input.cursor_byte);

    // Test clear
    input.clear();
    try std.testing.expectEqualStrings("", input.getText());
    try std.testing.expectEqual(@as(usize, 0), input.cursor_byte);
}

test "TextInput UTF-8 navigation" {
    const allocator = std.testing.allocator;

    var input = TextInput.init(allocator, .{ .x = 0, .y = 0, .width = 200, .height = 32 });
    defer input.deinit();

    // Test with emoji (4 bytes in UTF-8)
    try input.setText("a🎉b");
    try std.testing.expectEqual(@as(usize, 6), input.cursor_byte); // 1 + 4 + 1

    // Move left should skip the whole emoji
    const prev = input.prevCharBoundary(input.cursor_byte);
    try std.testing.expectEqual(@as(usize, 5), prev); // position of 'b'

    const prev2 = input.prevCharBoundary(prev);
    try std.testing.expectEqual(@as(usize, 1), prev2); // position after 'a', before emoji
}

test "TextInput selection" {
    const allocator = std.testing.allocator;

    var input = TextInput.init(allocator, .{ .x = 0, .y = 0, .width = 200, .height = 32 });
    defer input.deinit();

    try input.setText("Hello World");
    input.cursor_byte = 5; // After "Hello"
    input.selection_anchor = 0;

    try std.testing.expect(input.hasSelection());
    try std.testing.expectEqual(@as(usize, 0), input.selectionStart());
    try std.testing.expectEqual(@as(usize, 5), input.selectionEnd());
}
