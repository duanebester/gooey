//! CodeEditorState - Stateful code editor widget
//!
//! Extends TextArea with:
//! - Line number gutter rendering
//! - Syntax highlight spans (pre-allocated fixed array)
//! - Code-specific settings (tab size, indentation)
//!
//! Memory: Uses static allocation for highlight spans per CLAUDE.md guidelines.
//! All spans are pre-allocated at init time - no dynamic allocation during rendering.

const std = @import("std");
const builtin = @import("builtin");

const text_area_mod = @import("text_area_state.zig");
const TextArea = text_area_mod.TextArea;
const TextAreaBounds = text_area_mod.Bounds;
const TextAreaStyle = text_area_mod.Style;

const scene_mod = @import("../scene/mod.zig");
const Scene = scene_mod.Scene;
const Quad = scene_mod.Quad;
const Hsla = scene_mod.Hsla;

const text_mod = @import("../text/mod.zig");
const TextSystem = text_mod.TextSystem;

const element_types = @import("../core/element_types.zig");
const ElementId = element_types.ElementId;

const event = @import("../core/event.zig");
const Event = event.Event;
const EventResult = event.EventResult;

const input_mod = @import("../input/events.zig");
const InputEvent = input_mod.InputEvent;
const KeyCode = input_mod.KeyCode;
const Modifiers = input_mod.Modifiers;

// =============================================================================
// Constants - Hard limits per CLAUDE.md
// =============================================================================

/// Maximum number of highlight spans per frame
pub const MAX_HIGHLIGHT_SPANS: usize = 4096;

/// Maximum gutter width in pixels
pub const MAX_GUTTER_WIDTH: f32 = 100;

/// Default gutter width
pub const DEFAULT_GUTTER_WIDTH: f32 = 50;

/// Default tab size in spaces
pub const DEFAULT_TAB_SIZE: u8 = 4;

// =============================================================================
// Types
// =============================================================================

/// A highlighted region of text with a specific color
pub const HighlightSpan = struct {
    /// Start byte offset (inclusive)
    start: usize,
    /// End byte offset (exclusive)
    end: usize,
    /// Color for this span
    color: Hsla,

    pub fn init(start: usize, end: usize, color: Hsla) HighlightSpan {
        std.debug.assert(start <= end);
        return .{ .start = start, .end = end, .color = color };
    }

    /// Check if this span overlaps with a byte range
    pub fn overlaps(self: HighlightSpan, range_start: usize, range_end: usize) bool {
        return self.start < range_end and self.end > range_start;
    }
};

/// Code editor styling (extends TextArea style)
pub const Style = struct {
    /// Base text area style
    text: TextAreaStyle = .{},

    /// Line number gutter background
    gutter_background: Hsla = Hsla.init(0, 0, 0.15, 1.0),

    /// Line number text color
    line_number_color: Hsla = Hsla.init(0, 0, 0.5, 1.0),

    /// Current line number highlight color
    current_line_number_color: Hsla = Hsla.init(0, 0, 0.9, 1.0),

    /// Gutter/content separator color
    gutter_separator_color: Hsla = Hsla.init(0, 0, 0.3, 1.0),

    /// Current line background highlight (subtle highlight behind cursor line)
    current_line_background: Hsla = Hsla.init(220, 0.3, 0.5, 0.08),

    /// Status bar background color
    status_bar_background: Hsla = Hsla.init(0, 0, 0.12, 1.0),

    /// Status bar text color
    status_bar_text_color: Hsla = Hsla.init(0, 0, 0.6, 1.0),

    /// Status bar separator color
    status_bar_separator_color: Hsla = Hsla.init(0, 0, 0.25, 1.0),
};

/// Bounds for code editor (includes gutter)
pub const Bounds = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,

    pub fn contains(self: Bounds, px: f32, py: f32) bool {
        return px >= self.x and px < self.x + self.width and
            py >= self.y and py < self.y + self.height;
    }
};

// =============================================================================
// CodeEditorState
// =============================================================================

pub const CodeEditorState = struct {
    allocator: std.mem.Allocator,

    /// Unique identifier
    id: ElementId,

    /// Embedded TextArea for text management
    text_area: TextArea,

    /// Full bounds (including gutter)
    bounds: Bounds,

    /// Code editor specific style
    style: Style = .{},

    // =========================================================================
    // Code editor settings
    // =========================================================================

    /// Show line numbers in gutter
    show_line_numbers: bool = true,

    /// Width of the line number gutter (pixels)
    gutter_width: f32 = DEFAULT_GUTTER_WIDTH,

    /// Tab size in spaces (for display and insertion)
    tab_size: u8 = DEFAULT_TAB_SIZE,

    /// Use hard tabs (true) or spaces (false)
    use_hard_tabs: bool = false,

    /// Show status bar at bottom
    show_status_bar: bool = true,

    /// Height of status bar in pixels
    status_bar_height: f32 = 22,

    /// Language mode for display (e.g., "Zig", "Plain Text")
    language_mode: []const u8 = "Plain Text",

    /// File encoding for display
    encoding: []const u8 = "UTF-8",

    // =========================================================================
    // Highlight spans (static allocation)
    // =========================================================================

    /// Pre-allocated highlight spans array
    highlight_spans: [MAX_HIGHLIGHT_SPANS]HighlightSpan = undefined,

    /// Number of active highlight spans
    highlight_count: usize = 0,

    const Self = @This();

    // =========================================================================
    // Initialization
    // =========================================================================

    pub fn init(allocator: std.mem.Allocator, bounds: Bounds) Self {
        std.debug.assert(bounds.width > 0);
        std.debug.assert(bounds.height > 0);

        const text_bounds = calcTextAreaBounds(bounds, DEFAULT_GUTTER_WIDTH, true);

        return .{
            .allocator = allocator,
            .id = ElementId.int(generateUniqueId()),
            .text_area = TextArea.init(allocator, text_bounds),
            .bounds = bounds,
        };
    }

    pub fn initWithId(allocator: std.mem.Allocator, bounds: Bounds, id: []const u8) Self {
        std.debug.assert(bounds.width > 0);
        std.debug.assert(id.len > 0);

        const text_bounds = calcTextAreaBounds(bounds, DEFAULT_GUTTER_WIDTH, true);

        return .{
            .allocator = allocator,
            .id = ElementId.named(id),
            .text_area = TextArea.initWithId(allocator, text_bounds, id),
            .bounds = bounds,
        };
    }

    pub fn deinit(self: *Self) void {
        std.debug.assert(self.highlight_count <= MAX_HIGHLIGHT_SPANS);
        std.debug.assert(self.gutter_width <= MAX_GUTTER_WIDTH);

        self.text_area.deinit();
        self.highlight_count = 0;
    }

    // =========================================================================
    // ID generation (thread-safe counter)
    // =========================================================================

    fn generateUniqueId() u64 {
        const Counter = struct {
            var next: u64 = 1;
            var mutex: std.Thread.Mutex = .{};
        };
        Counter.mutex.lock();
        defer Counter.mutex.unlock();
        const id = Counter.next;
        Counter.next += 1;
        return id;
    }

    // =========================================================================
    // Bounds calculation
    // =========================================================================

    fn calcTextAreaBounds(editor_bounds: Bounds, gutter_w: f32, show_gutter: bool) TextAreaBounds {
        const gutter = if (show_gutter) gutter_w else 0;
        return .{
            .x = editor_bounds.x + gutter,
            .y = editor_bounds.y,
            .width = @max(1, editor_bounds.width - gutter),
            .height = editor_bounds.height,
        };
    }

    /// Update bounds and recalculate text area bounds
    pub fn setBounds(self: *Self, bounds: Bounds) void {
        std.debug.assert(bounds.width > 0);
        std.debug.assert(bounds.height > 0);

        self.bounds = bounds;
        self.text_area.bounds = calcTextAreaBounds(bounds, self.gutter_width, self.show_line_numbers);
    }

    pub fn getBounds(self: *Self) Bounds {
        return self.bounds;
    }

    pub fn getId(self: *Self) ElementId {
        return self.id;
    }

    // =========================================================================
    // Text access (delegated to TextArea)
    // =========================================================================

    pub fn getText(self: *Self) []const u8 {
        return self.text_area.getText();
    }

    pub fn setText(self: *Self, text: []const u8) !void {
        try self.text_area.setText(text);
        // Clear highlights when text changes
        self.clearHighlights();
    }

    pub fn clear(self: *Self) void {
        self.text_area.clear();
        self.clearHighlights();
    }

    pub fn setPlaceholder(self: *Self, placeholder: []const u8) void {
        self.text_area.setPlaceholder(placeholder);
    }

    pub fn lineCount(self: *Self) usize {
        return self.text_area.lineCount();
    }

    pub fn lineContent(self: *Self, row: usize) []const u8 {
        return self.text_area.lineContent(row);
    }

    // =========================================================================
    // Cursor and selection (delegated to TextArea)
    // =========================================================================

    pub fn getCursorRow(self: *Self) usize {
        return self.text_area.cursor_row;
    }

    pub fn getCursorCol(self: *Self) usize {
        return self.text_area.cursor_col;
    }

    pub fn getCursorByte(self: *Self) usize {
        return self.text_area.cursor_byte;
    }

    pub fn hasSelection(self: *Self) bool {
        return self.text_area.hasSelection();
    }

    // =========================================================================
    // Focus management (delegated to TextArea)
    // =========================================================================

    pub fn focus(self: *Self) void {
        self.text_area.focus();
    }

    pub fn blur(self: *Self) void {
        self.text_area.blur();
    }

    pub fn isFocused(self: *Self) bool {
        return self.text_area.isFocused();
    }

    pub fn canFocus(self: *Self) bool {
        _ = self;
        return true;
    }

    pub fn onFocus(self: *Self) void {
        self.text_area.onFocus();
    }

    pub fn onBlur(self: *Self) void {
        self.text_area.onBlur();
    }

    // =========================================================================
    // Input handling
    // =========================================================================

    pub fn handleEvent(self: *Self, input_event: InputEvent) EventResult {
        // Check if click is in gutter (line number click -> select line)
        if (input_event == .mouse_down) {
            const press = input_event.mouse_down;
            const x: f32 = @floatCast(press.position.x);
            const y: f32 = @floatCast(press.position.y);

            // Check if click is within the widget's inner bounds (not in padding/border)
            const content_height = if (self.show_status_bar)
                self.bounds.height - self.status_bar_height
            else
                self.bounds.height;

            const in_gutter_x = self.show_line_numbers and
                x >= self.bounds.x and
                x < self.bounds.x + self.gutter_width;
            const in_content_y = y >= self.bounds.y and
                y < self.bounds.y + content_height;

            if (in_gutter_x and in_content_y) {
                const row = self.calcRowFromY(y);
                self.selectLine(row);
                self.text_area.focus();
                return .handled;
            }

            // Check if click is in content area (not gutter)
            const in_content_x = x >= self.bounds.x + (if (self.show_line_numbers) self.gutter_width else 0) and
                x < self.bounds.x + self.bounds.width;

            if (in_content_x and in_content_y) {
                // Convert click position to text area coordinates
                // The text area bounds start after the gutter
                self.text_area.pending_click = .{ .x = x, .y = y };
                self.text_area.selection_anchor = null;
                self.text_area.focus();
                return .handled;
            }
        }

        // Non-gutter clicks are handled by the caller (focus, etc.)
        return .ignored;
    }

    /// Calculate which row (0-based) corresponds to a Y coordinate
    fn calcRowFromY(self: *Self, y: f32) usize {
        std.debug.assert(std.math.isFinite(y));
        std.debug.assert(self.bounds.height >= 0);

        const line_height = self.text_area.line_height;
        if (line_height <= 0) return 0;

        const scroll_y = self.text_area.scroll_offset_y;
        const relative_y = y - self.bounds.y + scroll_y;

        if (relative_y < 0) return 0;

        const row: usize = @intFromFloat(@floor(relative_y / line_height));
        const max_row = self.lineCount();
        return if (max_row == 0) 0 else @min(row, max_row - 1);
    }

    /// Select an entire line by row number (0-based)
    pub fn selectLine(self: *Self, row: usize) void {
        const line_count = self.lineCount();
        std.debug.assert(line_count == 0 or row <= line_count - 1);
        self.text_area.selectLine(row);
    }

    pub fn insertText(self: *Self, text: []const u8) void {
        self.text_area.insertText(text) catch {};
    }

    pub fn setComposition(self: *Self, text: []const u8) void {
        self.text_area.setComposition(text) catch {};
    }

    pub fn handleKey(self: *Self, key: KeyCode, mods: Modifiers) bool {
        // Handle tab key specially for code editor
        if (key == .tab and !mods.shift and !mods.ctrl and !mods.alt) {
            if (self.use_hard_tabs) {
                self.insertText("\t");
            } else {
                // Insert spaces
                var spaces: [16]u8 = undefined;
                const count = @min(self.tab_size, 16);
                @memset(spaces[0..count], ' ');
                self.insertText(spaces[0..count]);
            }
            return true;
        }

        // Create KeyEvent for TextArea's handleKey
        const key_event = input_mod.KeyEvent{
            .key = key,
            .modifiers = mods,
            .characters = null,
            .characters_ignoring_modifiers = null,
            .is_repeat = false,
        };
        self.text_area.handleKey(key_event) catch {};
        return true;
    }

    // =========================================================================
    // Highlight span management
    // =========================================================================

    /// Clear all highlight spans
    pub fn clearHighlights(self: *Self) void {
        self.highlight_count = 0;
    }

    /// Add a highlight span. Returns false if at capacity.
    pub fn addHighlight(self: *Self, start: usize, end: usize, color: Hsla) bool {
        std.debug.assert(start <= end);

        if (self.highlight_count >= MAX_HIGHLIGHT_SPANS) {
            return false;
        }

        self.highlight_spans[self.highlight_count] = HighlightSpan.init(start, end, color);
        self.highlight_count += 1;
        return true;
    }

    /// Add multiple highlight spans from a slice
    pub fn addHighlights(self: *Self, spans: []const HighlightSpan) usize {
        var added: usize = 0;
        for (spans) |span| {
            if (!self.addHighlight(span.start, span.end, span.color)) {
                break;
            }
            added += 1;
        }
        return added;
    }

    /// Get active highlight spans
    pub fn getHighlights(self: *Self) []const HighlightSpan {
        return self.highlight_spans[0..self.highlight_count];
    }

    // =========================================================================
    // Gutter settings
    // =========================================================================

    pub fn setShowLineNumbers(self: *Self, show: bool) void {
        self.show_line_numbers = show;
        self.text_area.bounds = calcTextAreaBounds(self.bounds, self.gutter_width, show);
    }

    pub fn setGutterWidth(self: *Self, width: f32) void {
        std.debug.assert(width >= 0);
        std.debug.assert(width <= MAX_GUTTER_WIDTH);

        self.gutter_width = width;
        self.text_area.bounds = calcTextAreaBounds(self.bounds, width, self.show_line_numbers);
    }

    // =========================================================================
    // Rendering
    // =========================================================================

    pub fn render(self: *Self, scene: *Scene, text_system: *TextSystem, scale_factor: f32) !void {
        std.debug.assert(self.bounds.width > 0);
        std.debug.assert(self.bounds.height > 0);

        // Calculate content area (excluding status bar)
        const content_height = if (self.show_status_bar)
            self.bounds.height - self.status_bar_height
        else
            self.bounds.height;

        // 1. Render current line highlight (behind everything else)
        if (self.isFocused()) {
            try self.renderCurrentLineHighlight(scene, text_system, content_height);
        }

        // 2. Render gutter with line numbers
        if (self.show_line_numbers) {
            try self.renderGutter(scene, text_system, scale_factor, content_height);
        }

        // 3. Render text content (with highlights applied)
        try self.renderContent(scene, text_system, scale_factor);

        // 4. Render status bar at bottom
        if (self.show_status_bar) {
            try self.renderStatusBar(scene, text_system, scale_factor);
        }
    }

    /// Render subtle highlight behind the current line
    fn renderCurrentLineHighlight(self: *Self, scene: *Scene, text_system: *TextSystem, content_height: f32) !void {
        const metrics = text_system.getMetrics() orelse return;
        const line_height = metrics.line_height;
        const scroll_y = self.text_area.scroll_offset_y;
        const current_row = self.getCursorRow();

        // Calculate y position of current line
        const row_f: f32 = @floatFromInt(current_row);
        const line_y = self.bounds.y + (row_f * line_height) - scroll_y;

        // Check if line is visible
        if (line_y + line_height < self.bounds.y or line_y > self.bounds.y + content_height) {
            return;
        }

        // Clip to content area
        const visible_y = @max(line_y, self.bounds.y);
        const visible_height = @min(line_y + line_height, self.bounds.y + content_height) - visible_y;

        if (visible_height <= 0) return;

        // Render the highlight across the full width (including gutter for visual continuity)
        const highlight_quad = Quad.filled(
            self.bounds.x,
            visible_y,
            self.bounds.width,
            visible_height,
            self.style.current_line_background,
        );
        try scene.insertQuad(highlight_quad);
    }

    fn renderGutter(self: *Self, scene: *Scene, text_system: *TextSystem, scale_factor: f32, content_height: f32) !void {
        const metrics = text_system.getMetrics() orelse return;
        std.debug.assert(metrics.line_height > 0);
        std.debug.assert(self.gutter_width > 0 and self.gutter_width <= MAX_GUTTER_WIDTH);

        // Gutter background (only content area, not status bar)
        const gutter_quad = Quad.filled(
            self.bounds.x,
            self.bounds.y,
            self.gutter_width,
            content_height,
            self.style.gutter_background,
        );
        try scene.insertQuad(gutter_quad);

        // Gutter separator line
        const separator = Quad.filled(
            self.bounds.x + self.gutter_width - 1,
            self.bounds.y,
            1,
            content_height,
            self.style.gutter_separator_color,
        );
        try scene.insertQuad(separator);

        // Push clip for gutter
        try scene.pushClip(.{
            .x = self.bounds.x,
            .y = self.bounds.y,
            .width = self.gutter_width,
            .height = content_height,
        });
        defer scene.popClip();

        // Calculate visible line range
        const scroll_y = self.text_area.scroll_offset_y;
        const line_height = metrics.line_height;
        const first_visible = self.calcFirstVisibleLine(scroll_y, line_height);
        const last_visible = self.calcLastVisibleLine(scroll_y, line_height);

        // Render line numbers
        try self.renderLineNumbers(scene, text_system, scale_factor, first_visible, last_visible);
    }

    fn calcFirstVisibleLine(self: *Self, scroll_y: f32, line_height: f32) usize {
        _ = self;
        if (line_height <= 0) return 0;
        const first_f = @floor(scroll_y / line_height);
        return if (first_f < 0) 0 else @intFromFloat(first_f);
    }

    fn calcLastVisibleLine(self: *Self, scroll_y: f32, line_height: f32) usize {
        if (line_height <= 0) return 0;
        const visible_count_f = @ceil(self.bounds.height / line_height) + 1;
        const visible_count: usize = @intFromFloat(visible_count_f);
        const first = self.calcFirstVisibleLine(scroll_y, line_height);
        return @min(first + visible_count, self.lineCount());
    }

    fn renderLineNumbers(
        self: *Self,
        scene: *Scene,
        text_system: *TextSystem,
        scale_factor: f32,
        first_visible: usize,
        last_visible: usize,
    ) !void {
        const metrics = text_system.getMetrics() orelse return;
        const line_height = metrics.line_height;
        const scroll_y = self.text_area.scroll_offset_y;
        const cursor_row = self.text_area.cursor_row;

        var line_num_buf: [16]u8 = undefined;

        for (first_visible..last_visible) |row| {
            const line_y = self.bounds.y + @as(f32, @floatFromInt(row)) * line_height - scroll_y;
            const baseline_y = metrics.calcBaseline(line_y, line_height);

            // Format line number (1-based)
            const line_num = std.fmt.bufPrint(&line_num_buf, "{d}", .{row + 1}) catch continue;

            // Choose color based on current line
            const color = if (row == cursor_row)
                self.style.current_line_number_color
            else
                self.style.line_number_color;

            // Right-align line number in gutter
            const text_width = self.measureLineNumber(text_system, line_num) catch 0;
            const x = self.bounds.x + self.gutter_width - text_width - 8; // 8px right padding

            var opts = text_mod.RenderTextOptions{};
            _ = try text_mod.renderText(
                scene,
                text_system,
                line_num,
                x,
                baseline_y,
                scale_factor,
                color,
                metrics.point_size,
                &opts,
            );
        }
    }

    fn measureLineNumber(self: *Self, text_system: *TextSystem, text: []const u8) !f32 {
        _ = self;
        if (text.len == 0) return 0;
        var shaped = try text_system.shapeText(text, null);
        defer shaped.deinit(text_system.allocator);
        return shaped.width;
    }

    fn renderContent(self: *Self, scene: *Scene, text_system: *TextSystem, scale_factor: f32) !void {
        // Update text area style from code editor style
        self.text_area.style = self.style.text;

        // If we have highlight spans, render with per-span coloring
        if (self.highlight_count > 0) {
            try self.renderHighlightedContent(scene, text_system, scale_factor);
        } else {
            // No highlights - delegate to standard text area render
            try self.text_area.render(scene, text_system, scale_factor);
        }
    }

    fn renderHighlightedContent(self: *Self, scene: *Scene, text_system: *TextSystem, scale_factor: f32) !void {
        // For now, render normally and overlay highlight backgrounds
        // Future: per-character coloring with highlight spans
        try self.text_area.render(scene, text_system, scale_factor);

        // Render highlight span backgrounds (behind text)
        const metrics = text_system.getMetrics() orelse return;
        const line_height = metrics.line_height;
        const scroll_y = self.text_area.scroll_offset_y;
        const text = self.getText();

        for (self.highlight_spans[0..self.highlight_count]) |span| {
            if (span.start >= text.len) continue;
            const end = @min(span.end, text.len);
            if (span.start >= end) continue;

            // Find which lines this span covers
            const start_row = self.text_area.lineForOffset(span.start);
            const end_row = self.text_area.lineForOffset(end);

            for (start_row..end_row + 1) |row| {
                const line_start = self.text_area.lineStartOffset(row);
                const line_end = self.text_area.lineEndOffset(row);

                // Calculate span range within this line
                const span_line_start = if (row == start_row) span.start - line_start else 0;
                const span_line_end = if (row == end_row) end - line_start else line_end - line_start;

                if (span_line_start >= span_line_end) continue;

                const line_content = self.lineContent(row);
                const line_y = self.text_area.bounds.y + @as(f32, @floatFromInt(row)) * line_height - scroll_y;

                // Calculate x positions
                var start_x = self.text_area.bounds.x - self.text_area.scroll_offset_x;
                if (span_line_start > 0 and span_line_start <= line_content.len) {
                    start_x += self.measureLineNumber(text_system, line_content[0..span_line_start]) catch 0;
                }

                var end_x = self.text_area.bounds.x - self.text_area.scroll_offset_x;
                if (span_line_end > 0 and span_line_end <= line_content.len) {
                    end_x += self.measureLineNumber(text_system, line_content[0..span_line_end]) catch 0;
                }

                // Create highlight background quad with reduced opacity
                const highlight_color = Hsla.init(span.color.h, span.color.s, span.color.l, span.color.a * 0.3);
                const highlight_quad = Quad.filled(
                    start_x,
                    line_y,
                    @max(2, end_x - start_x),
                    line_height,
                    highlight_color,
                );
                try scene.insertQuadClipped(highlight_quad);
            }
        }
    }

    // =========================================================================
    // Scroll access
    // =========================================================================

    pub fn canScrollY(self: *Self) bool {
        return self.text_area.canScrollY();
    }

    pub fn getScrollOffsetY(self: *Self) f32 {
        return self.text_area.scroll_offset_y;
    }

    pub fn setScrollOffsetY(self: *Self, offset: f32) void {
        self.text_area.scroll_offset_y = offset;
    }

    /// Render the status bar at the bottom of the editor
    fn renderStatusBar(self: *Self, scene: *Scene, text_system: *TextSystem, scale_factor: f32) !void {
        const metrics = text_system.getMetrics() orelse return;
        const status_y = self.bounds.y + self.bounds.height - self.status_bar_height;

        // Status bar background
        const bg_quad = Quad.filled(
            self.bounds.x,
            status_y,
            self.bounds.width,
            self.status_bar_height,
            self.style.status_bar_background,
        );
        try scene.insertQuad(bg_quad);

        // Top separator line
        const separator = Quad.filled(
            self.bounds.x,
            status_y,
            self.bounds.width,
            1,
            self.style.status_bar_separator_color,
        );
        try scene.insertQuad(separator);

        // Push clip for status bar text
        try scene.pushClip(.{
            .x = self.bounds.x,
            .y = status_y,
            .width = self.bounds.width,
            .height = self.status_bar_height,
        });
        defer scene.popClip();

        const padding: f32 = 8;
        const font_size: f32 = 11; // Smaller font for status bar
        const baseline_y = metrics.calcBaseline(status_y, self.status_bar_height);
        var x_offset = self.bounds.x + padding;
        var opts = text_mod.RenderTextOptions{};

        // Cursor position: "Ln X, Col Y"
        var ln_buf: [32]u8 = undefined;
        const ln_text = std.fmt.bufPrint(&ln_buf, "Ln {d}, Col {d}", .{
            self.getCursorRow() + 1, // 1-indexed for display
            self.getCursorCol() + 1,
        }) catch "Ln ?, Col ?";

        const ln_width = try text_mod.renderText(
            scene,
            text_system,
            ln_text,
            x_offset,
            baseline_y,
            scale_factor,
            self.style.status_bar_text_color,
            font_size,
            &opts,
        );
        x_offset += ln_width + padding * 2;

        // Separator dot
        try self.renderStatusSeparator(scene, x_offset, status_y + self.status_bar_height / 2 - 1.5);
        x_offset += padding * 2;

        // Tab/Space indicator
        var tab_buf: [16]u8 = undefined;
        const tab_text = if (self.use_hard_tabs)
            std.fmt.bufPrint(&tab_buf, "Tab: {d}", .{self.tab_size}) catch "Tab"
        else
            std.fmt.bufPrint(&tab_buf, "Spaces: {d}", .{self.tab_size}) catch "Spaces";

        const tab_width = try text_mod.renderText(
            scene,
            text_system,
            tab_text,
            x_offset,
            baseline_y,
            scale_factor,
            self.style.status_bar_text_color,
            font_size,
            &opts,
        );
        x_offset += tab_width + padding * 2;

        // Separator dot
        try self.renderStatusSeparator(scene, x_offset, status_y + self.status_bar_height / 2 - 1.5);
        x_offset += padding * 2;

        // Encoding
        const enc_width = try text_mod.renderText(
            scene,
            text_system,
            self.encoding,
            x_offset,
            baseline_y,
            scale_factor,
            self.style.status_bar_text_color,
            font_size,
            &opts,
        );
        x_offset += enc_width + padding * 2;

        // Separator dot
        try self.renderStatusSeparator(scene, x_offset, status_y + self.status_bar_height / 2 - 1.5);
        x_offset += padding * 2;

        // Language mode
        _ = try text_mod.renderText(
            scene,
            text_system,
            self.language_mode,
            x_offset,
            baseline_y,
            scale_factor,
            self.style.status_bar_text_color,
            font_size,
            &opts,
        );
    }

    /// Render a small separator dot between status bar items
    fn renderStatusSeparator(self: *Self, scene: *Scene, x: f32, y: f32) !void {
        const dot = Quad.filled(
            x,
            y,
            3,
            3,
            self.style.status_bar_separator_color,
        );
        try scene.insertQuad(dot);
    }

    // =========================================================================
    // IME cursor position (for input method positioning)
    // =========================================================================

    pub fn getCursorRect(self: *Self) struct { x: f32, y: f32, width: f32, height: f32 } {
        const rect = self.text_area.cursor_rect;
        return .{
            .x = rect.x,
            .y = rect.y,
            .width = rect.width,
            .height = rect.height,
        };
    }
};

// =============================================================================
// Tests
// =============================================================================

test "CodeEditorState basic operations" {
    const allocator = std.testing.allocator;
    var editor = CodeEditorState.initWithId(allocator, .{ .x = 0, .y = 0, .width = 400, .height = 300 }, "test");
    defer editor.deinit();

    try std.testing.expect(editor.show_line_numbers);
    try std.testing.expectEqual(@as(f32, 50), editor.gutter_width);
    try std.testing.expectEqual(@as(usize, 0), editor.highlight_count);
}

test "CodeEditorState highlight spans" {
    const allocator = std.testing.allocator;
    var editor = CodeEditorState.initWithId(allocator, .{ .x = 0, .y = 0, .width = 400, .height = 300 }, "test");
    defer editor.deinit();

    const color = Hsla.init(0, 1, 0.5, 1);

    // Add highlights
    try std.testing.expect(editor.addHighlight(0, 10, color));
    try std.testing.expect(editor.addHighlight(15, 25, color));
    try std.testing.expectEqual(@as(usize, 2), editor.highlight_count);

    // Clear highlights
    editor.clearHighlights();
    try std.testing.expectEqual(@as(usize, 0), editor.highlight_count);
}

test "CodeEditorState bounds calculation" {
    const allocator = std.testing.allocator;
    var editor = CodeEditorState.initWithId(allocator, .{ .x = 0, .y = 0, .width = 400, .height = 300 }, "test");
    defer editor.deinit();

    // Text area should be offset by gutter width
    try std.testing.expectEqual(@as(f32, 50), editor.text_area.bounds.x);
    try std.testing.expectEqual(@as(f32, 350), editor.text_area.bounds.width);

    // Disable line numbers
    editor.setShowLineNumbers(false);
    try std.testing.expectEqual(@as(f32, 0), editor.text_area.bounds.x);
    try std.testing.expectEqual(@as(f32, 400), editor.text_area.bounds.width);
}

test "CodeEditorState tab insertion" {
    const allocator = std.testing.allocator;
    var editor = CodeEditorState.initWithId(allocator, .{ .x = 0, .y = 0, .width = 400, .height = 300 }, "test");
    defer editor.deinit();

    editor.focus();

    // Default: spaces
    editor.use_hard_tabs = false;
    editor.tab_size = 4;
    _ = editor.handleKey(.tab, .{});

    const text = editor.getText();
    try std.testing.expectEqual(@as(usize, 4), text.len);
    try std.testing.expectEqualStrings("    ", text);
}

test "HighlightSpan overlap detection" {
    const color = Hsla.init(0, 0, 0, 1);
    const span = HighlightSpan.init(10, 20, color);

    // Overlapping ranges
    try std.testing.expect(span.overlaps(5, 15));
    try std.testing.expect(span.overlaps(15, 25));
    try std.testing.expect(span.overlaps(12, 18));
    try std.testing.expect(span.overlaps(0, 100));

    // Non-overlapping ranges
    try std.testing.expect(!span.overlaps(0, 10));
    try std.testing.expect(!span.overlaps(20, 30));
    try std.testing.expect(!span.overlaps(0, 5));
}
