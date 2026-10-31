//! Library components on the 0.4.0 core: `Button`, `Checkbox`, and
//! `TextInput`, the three the milestone 1 todo needs (contract "Acceptance:
//! todo"). Each composes `ui.box`, `ui.text`, and `ui.paint`; none reaches
//! into the core beyond `Cx`.
//!
//! Their geometry and colours match the 0.3.1 components, so the core's
//! counter and todo goldens can be compared with the 0.3.1 goldens.

const std = @import("std");
const gooey = @import("gooey");

const assert = std.debug.assert;

const core = gooey.core;
const ui = core.ui;
const Cx = core.Cx;
const Handler = core.Handler;
const Key = core.Key;
const Color = ui.Color;
const InputEngine = core.InputEngine;
const AreaEngine = core.AreaEngine;
const EditorEngine = core.EditorEngine;

// =============================================================================
// Button
// =============================================================================

pub const Button = struct {
    label: []const u8,
    /// The button's key under its parent; defaults to the label, so sibling
    /// buttons need distinct labels or explicit keys.
    key: ?[]const u8 = null,
    variant: Variant = .primary,
    size: Size = .medium,
    disabled: bool = false,
    on_click: ?Handler = null,

    pub const Variant = enum { primary, secondary, danger };
    pub const Size = enum { small, medium, large };

    pub fn render(self: Button, cx: *Cx) void {
        assert(self.label.len > 0);
        const theme = cx.theme();
        const key = Key{ .name = self.key orelse self.label };
        const hovered = !self.disabled and cx.hovered(cx.id(key));
        const colors = variantColors(self.variant, theme);
        var background = if (hovered) colors.background.withAlpha(0.85) else colors.background;
        var foreground = colors.foreground;
        if (self.disabled) {
            background = background.withAlpha(0.5);
            foreground = foreground.withAlpha(0.7);
        }
        cx.render(ui.box(.{
            .key = key,
            .style = .{
                .padding = padding(self.size),
                .background = .{ .rgba = background },
                .corner_radius = .all(theme.radius_md),
                .alignment = .center,
                .cursor = .pointer,
            },
            .on_click = if (self.disabled) null else self.on_click,
            .a11y = .{ .role = .button, .label = self.label, .disabled = self.disabled },
        }, .{
            ui.text(self.label, .{
                .size = fontSize(self.size, theme.font_size_base),
                .color = .{ .rgba = foreground },
            }),
        }));
    }

    fn padding(size: Size) ui.Edges {
        return switch (size) {
            .small => .symmetric(12, 6),
            .medium => .symmetric(24, 10),
            .large => .symmetric(32, 14),
        };
    }

    fn fontSize(size: Size, base: u16) u16 {
        assert(base > 2);
        return switch (size) {
            .small => base - 2,
            .medium => base,
            .large => base + 2,
        };
    }

    const Colors = struct { background: Color, foreground: Color };

    fn variantColors(variant: Variant, theme: *const core.Theme) Colors {
        return switch (variant) {
            .primary => .{ .background = theme.primary, .foreground = Color.white },
            .secondary => .{ .background = theme.secondary, .foreground = theme.text },
            .danger => .{ .background = theme.danger, .foreground = Color.white },
        };
    }
};

// =============================================================================
// Checkbox
// =============================================================================

pub const Checkbox = struct {
    checked: bool,
    on_click: ?Handler = null,
    key: ?Key = null,
    size: f32 = 18,

    pub fn render(self: Checkbox, cx: *Cx) void {
        assert(self.size > 0);
        const theme = cx.theme();
        const mark_size = self.size * 0.7;
        cx.render(ui.box(.{
            .key = self.key,
            .style = .{ .direction = .row, .gap = 8, .alignment = .center_cross },
            .on_click = self.on_click,
            .a11y = .{ .role = .checkbox, .checked = self.checked },
        }, .{
            ui.box(.{ .style = .{
                .width = .{ .fixed = self.size },
                .height = .{ .fixed = self.size },
                .background = if (self.checked) .primary else .surface,
                .border = .{ .width = 1, .color = .border },
                .corner_radius = .all(theme.radius_sm),
                .alignment = .center,
            } }, .{
                if (self.checked) ui.paint(Checkmark, &checkmark, Checkmark.paint, .{
                    .width = .{ .fixed = mark_size },
                    .height = .{ .fixed = mark_size },
                }) else null,
            }),
        }));
    }

    const Checkmark = struct {
        path: []const u8,

        fn paint(self: *const Checkmark, painter: *ui.Painter) void {
            painter.svg(self.path, painter.bounds, .{ .fill = Color.white });
        }
    };

    /// The Material "check" icon, as the 0.3.1 checkbox draws it.
    const checkmark = Checkmark{ .path = "M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z" };
};

// =============================================================================
// TextInput
// =============================================================================

/// A single-line input bound to an app field. The engine is retained under
/// the input's key and lives while the input is rendered; `bind` points into
/// the engine's buffer after an edit, so the app reads the text there and
/// assigns `""` (or any other slice) to replace it.
pub const TextInput = struct {
    key: []const u8,
    bind: *[]const u8,
    placeholder: []const u8 = "",
    width: f32 = 200,
    padding: f32 = 8,
    border_width: f32 = 1,

    pub fn render(self: TextInput, cx: *Cx) void {
        assert(self.key.len > 0);
        const theme = cx.theme();
        const key = Key{ .name = self.key };
        const id = cx.id(key);
        const handle = cx.retain(InputEngine, id, .{ .scope = id }, initEngine);
        const engine = cx.get(InputEngine, handle);
        engine.syncBound(self.bind);
        const focused = cx.focused(id);
        setView(&engine.view, theme, id, self.placeholder);
        engine.blink(cx, focused);
        const inset = self.padding + self.border_width;
        const metrics = cx.fontMetrics();
        cx.render(ui.box(.{
            .key = key,
            .focusable = true,
            .on_key = cx.on(InputEngine.onKey, .{ .entity = handle }),
            .style = .{
                .width = .{ .fixed = self.width },
                .height = .{ .fixed = metrics.line_height + inset * 2 },
                .padding = .all(inset),
                .background = .surface,
                .border = .{
                    .width = self.border_width,
                    .color = if (focused) .border_focus else .border,
                },
                .corner_radius = .all(theme.radius_md),
                .cursor = .text,
            },
            .a11y = .{
                .role = .textbox,
                .label = self.placeholder,
                .value = if (engine.len > 0) engine.text() else null,
            },
        }, .{
            ui.paint(InputEngine, engine, paintInput, .{
                .width = .{ .grow = 1 },
                .height = .{ .grow = 1 },
            }),
        }));
    }

    fn initEngine(engine: *InputEngine) void {
        assert(engine.len == 0);
    }

    /// The selection, under the text, while focused.
    fn paintSelection(engine: *const InputEngine, painter: *ui.Painter, size: u16) void {
        assert(engine.view.focused);
        if (!engine.hasSelection()) return;
        const bounds = painter.bounds;
        const line_height = painter.fontMetrics().line_height;
        const style = ui.PaintText{ .size = size, .color = engine.view.text_color };
        const text = engine.text();
        const start = painter.measureText(text[0..engine.selectionStart()], style);
        const end = painter.measureText(text[0..engine.selectionEnd()], style);
        assert(end >= start);
        painter.fill(.{
            .x = bounds.x + start,
            .y = bounds.y + (bounds.height - line_height) / 2,
            .width = end - start,
            .height = line_height,
        }, engine.view.selection_color);
    }

    /// Placeholder, or the selection and text with the preedit at the caret;
    /// then the caret in its blink phase.
    fn paintInput(engine: *const InputEngine, painter: *ui.Painter) void {
        const view = &engine.view;
        const bounds = painter.bounds;
        const metrics = painter.fontMetrics();
        const size: u16 = @intFromFloat(metrics.point_size);
        const baseline = metrics.calcBaseline(bounds.y, bounds.height);
        painter.pushClip(bounds);
        defer painter.popClip();
        if (view.focused) paintSelection(engine, painter, size);
        const text = engine.text();
        const preedit = engine.preeditText();
        if (text.len == 0 and preedit.len == 0) {
            const style = ui.PaintText{ .size = size, .color = view.placeholder_color };
            _ = painter.textOnBaseline(view.placeholder, bounds.x, baseline, style);
        } else {
            const style = ui.PaintText{ .size = size, .color = view.text_color };
            const before = text[0..engine.cursor];
            var pen = bounds.x + painter.textOnBaseline(before, bounds.x, baseline, style);
            if (preedit.len > 0) {
                const width = painter.textOnBaseline(preedit, pen, baseline, style);
                const underline = ui.Rect{
                    .x = pen,
                    .y = baseline + 2,
                    .width = width,
                    .height = 1,
                };
                painter.fill(underline, view.preedit_underline_color);
                pen += width;
            }
            _ = painter.textOnBaseline(text[engine.cursor..], pen, baseline, style);
        }
        if (!view.focused) return;
        const caret_style = ui.PaintText{ .size = size, .color = view.caret_color };
        const caret_x = bounds.x + painter.measureText(text[0..engine.cursor], caret_style);
        const preedit_width = painter.measureText(preedit, caret_style);
        const caret = ui.Rect{
            .x = caret_x,
            .y = bounds.y + (bounds.height - metrics.line_height) / 2,
            .width = 1.5,
            .height = metrics.line_height,
        };
        if (preedit.len == 0 and view.caret_visible) painter.fill(caret, view.caret_color);
        var ime_rect = caret;
        ime_rect.x += preedit_width;
        painter.imeCursor(.{
            .owner = view.id,
            .cursor_rect = ime_rect,
            .selected_start = engine.selectionStart(),
            .selected_end = engine.selectionEnd(),
        });
    }
};

/// What both text components draw with, from the theme.
fn setView(
    view: *InputEngine.View,
    theme: *const core.Theme,
    id: core.ElementId,
    placeholder: []const u8,
) void {
    assert(id.isKeyed());
    view.id = id;
    view.placeholder = placeholder;
    view.text_color = theme.text;
    view.placeholder_color = theme.muted;
    view.selection_color = theme.primary.withAlpha(0.3);
    view.caret_color = theme.text;
    view.preedit_underline_color = Color.rgb(0.3, 0.3, 0.3);
    view.scrollbar_track_color = theme.muted.withAlpha(0.1);
    view.scrollbar_thumb_color = theme.muted.withAlpha(0.4);
    assert(view.placeholder.len == placeholder.len);
}

// =============================================================================
// TextArea
// =============================================================================

/// A multi-line input bound to an app field, `rows` lines tall. Lines split
/// on '\n' without soft wrap, and the lines scroll to keep the caret in view,
/// as in 0.3.1. The app reserves areas with `limits.text.area`.
pub const TextArea = struct {
    key: []const u8,
    bind: *[]const u8,
    placeholder: []const u8 = "",
    width: f32 = 300,
    rows: u16 = 4,
    padding: f32 = 8,
    border_width: f32 = 1,

    /// The scrollbar's width at the right edge, as in 0.3.1.
    const scrollbar_width: f32 = 8;

    pub fn render(self: TextArea, cx: *Cx) void {
        assert(self.key.len > 0);
        assert(self.rows > 0);
        const theme = cx.theme();
        const key = Key{ .name = self.key };
        const id = cx.id(key);
        const handle = cx.retain(AreaEngine, id, .{ .scope = id }, initEngine);
        const engine = cx.get(AreaEngine, handle);
        engine.syncBound(self.bind);
        const focused = cx.focused(id);
        setView(&engine.view, theme, id, self.placeholder);
        const inset = self.padding + self.border_width;
        const line_height = cx.fontMetrics().line_height;
        const viewport_height = line_height * @as(f32, @floatFromInt(self.rows));
        engine.resolveClick(cx, .{ .text_x = inset, .text_y = inset, .gutter_end = 0 });
        engine.follow(line_height, viewport_height);
        engine.blink(cx, focused);
        cx.render(ui.box(.{
            .key = key,
            .focusable = true,
            .on_key = cx.on(AreaEngine.onKey, .{ .entity = handle }),
            .on_click = cx.on(AreaEngine.onClick, .{ .entity = handle }),
            .style = .{
                .width = .{ .fixed = self.width },
                .height = .{ .fixed = viewport_height + inset * 2 },
                .padding = .all(inset),
                .background = .surface,
                .border = .{
                    .width = self.border_width,
                    .color = if (focused) .border_focus else .border,
                },
                .corner_radius = .all(theme.radius_md),
                .cursor = .text,
            },
            .a11y = .{
                .role = .textarea,
                .label = self.placeholder,
                .value = if (engine.len > 0) engine.text() else null,
            },
        }, .{
            ui.paint(AreaEngine, engine, paintArea, .{
                .width = .{ .grow = 1 },
                .height = .{ .grow = 1 },
            }),
        }));
    }

    fn initEngine(engine: *AreaEngine) void {
        assert(engine.len == 0);
    }

    /// The visible lines with the selection under them and the preedit at
    /// the caret, then the caret and the scrollbar. Lines above the viewport
    /// are skipped and drawing stops below it, so paint work is bounded by
    /// `rows` + 1 lines; finding them scans the text once.
    fn paintArea(engine: *const AreaEngine, painter: *ui.Painter) void {
        paintText(engine, painter);
    }

    /// `paintArea` for any multi-line engine; the editor draws its text so.
    fn paintText(engine: anytype, painter: *ui.Painter) void {
        const bounds = painter.bounds;
        const metrics = painter.fontMetrics();
        const size: u16 = @intFromFloat(metrics.point_size);
        painter.pushClip(bounds);
        defer painter.popClip();
        if (engine.len == 0 and engine.preedit_len == 0) {
            const style = ui.PaintText{ .size = size, .color = engine.view.placeholder_color };
            const baseline = metrics.calcBaseline(bounds.y, metrics.line_height);
            _ = painter.textOnBaseline(engine.view.placeholder, bounds.x, baseline, style);
        } else {
            paintLines(engine, painter, size);
        }
        if (engine.view.focused) paintCaret(engine, painter, size);
        paintScrollbar(engine, painter);
    }

    fn paintLines(engine: anytype, painter: *ui.Painter, size: u16) void {
        const bounds = painter.bounds;
        const line_height = painter.fontMetrics().line_height;
        var start: u32 = 0;
        var top = bounds.y - engine.scroll_y;
        var line_count: u32 = 0;
        while (line_count <= engine.len) : (line_count += 1) {
            const end = engine.lineEnd(start);
            if (top > bounds.y + bounds.height) break;
            if (top + line_height >= bounds.y) paintLine(engine, painter, size, start, end, top);
            if (end == engine.len) break;
            start = end + 1;
            top += line_height;
        }
        assert(line_count <= engine.len);
    }

    /// One line: its part of the selection, then its text, with the
    /// preedit underlined at the caret when the caret is on this line.
    fn paintLine(
        engine: anytype,
        painter: *ui.Painter,
        size: u16,
        start: u32,
        end: u32,
        top: f32,
    ) void {
        assert(start <= end);
        const metrics = painter.fontMetrics();
        const style = ui.PaintText{ .size = size, .color = engine.view.text_color };
        const line = engine.text()[start..end];
        const left = painter.bounds.x;
        if (engine.view.focused and engine.hasSelection()) {
            const from = @max(engine.selectionStart(), start);
            const to = @min(engine.selectionEnd(), end);
            if (from <= to and engine.selectionEnd() > start) {
                const x0 = painter.measureText(line[0 .. from - start], style);
                const x1 = painter.measureText(line[0 .. to - start], style);
                // A selected newline shows as a sliver past the line's end.
                const newline: f32 = if (engine.selectionEnd() > end) 4 else 0;
                painter.fill(.{
                    .x = left + x0,
                    .y = top,
                    .width = x1 - x0 + newline,
                    .height = metrics.line_height,
                }, engine.view.selection_color);
            }
        }
        const baseline = metrics.calcBaseline(top, metrics.line_height);
        const preedit = engine.preeditText();
        const caret_here = engine.cursor >= start and engine.cursor <= end;
        if (preedit.len == 0 or !caret_here) {
            _ = painter.textOnBaseline(line, left, baseline, style);
            return;
        }
        const split = engine.cursor - start;
        var pen = left + painter.textOnBaseline(line[0..split], left, baseline, style);
        const width = painter.textOnBaseline(preedit, pen, baseline, style);
        painter.fill(
            .{ .x = pen, .y = baseline + 2, .width = width, .height = 1 },
            engine.view.preedit_underline_color,
        );
        pen += width;
        _ = painter.textOnBaseline(line[split..], pen, baseline, style);
    }

    /// The caret in its blink phase, and the IME's answer at the caret.
    fn paintCaret(engine: anytype, painter: *ui.Painter, size: u16) void {
        assert(engine.view.focused);
        const line_height = painter.fontMetrics().line_height;
        const style = ui.PaintText{ .size = size, .color = engine.view.caret_color };
        const start = engine.lineStart(engine.cursor);
        const row: f32 = @floatFromInt(engine.lineOf(engine.cursor));
        const caret = ui.Rect{
            .x = painter.bounds.x + painter.measureText(engine.text()[start..engine.cursor], style),
            .y = painter.bounds.y + row * line_height - engine.scroll_y,
            .width = 1.5,
            .height = line_height,
        };
        const preedit = engine.preeditText();
        if (preedit.len == 0 and engine.view.caret_visible) {
            painter.fill(caret, engine.view.caret_color);
        }
        var ime_rect = caret;
        ime_rect.x += painter.measureText(preedit, style);
        painter.imeCursor(.{
            .owner = engine.view.id,
            .cursor_rect = ime_rect,
            .selected_start = engine.selectionStart(),
            .selected_end = engine.selectionEnd(),
        });
    }

    /// A track and thumb at the right edge while the lines overflow.
    fn paintScrollbar(engine: anytype, painter: *ui.Painter) void {
        const bounds = painter.bounds;
        const line_height = painter.fontMetrics().line_height;
        const lines: f32 = @floatFromInt(std.mem.count(u8, engine.text(), "\n") + 1);
        const content_height = lines * line_height;
        if (content_height <= bounds.height) return;
        const track = ui.Rect{
            .x = bounds.x + bounds.width - scrollbar_width,
            .y = bounds.y,
            .width = scrollbar_width,
            .height = bounds.height,
        };
        painter.fill(track, engine.view.scrollbar_track_color);
        const thumb_height = @max(20, bounds.height * bounds.height / content_height);
        const travel = bounds.height - thumb_height;
        const scroll_max = content_height - bounds.height;
        assert(scroll_max > 0);
        var thumb = track;
        thumb.y += travel * engine.scroll_y / scroll_max;
        thumb.height = thumb_height;
        painter.fill(thumb, engine.view.scrollbar_thumb_color);
    }
};

// =============================================================================
// CodeEditor
// =============================================================================

/// A TextArea with line numbers, a highlighted current line, Tab indenting,
/// and a status bar, as 0.3.1's CodeEditor. Clicking a line number selects
/// the line. The app reserves editors with `limits.text.editor`.
pub const CodeEditor = struct {
    key: []const u8,
    bind: *[]const u8,
    placeholder: []const u8 = "",
    width: f32 = 500,
    rows: u16 = 10,
    padding: f32 = 8,
    border_width: f32 = 1,
    show_line_numbers: bool = true,
    gutter_width: f32 = 50,
    show_status_bar: bool = true,
    status_bar_height: f32 = 22,
    language_mode: []const u8 = "Plain Text",
    encoding: []const u8 = "UTF-8",
    tab_size: u8 = 4,
    use_hard_tabs: bool = false,

    pub fn render(self: CodeEditor, cx: *Cx) void {
        assert(self.key.len > 0);
        assert(self.rows > 0);
        const theme = cx.theme();
        const key = Key{ .name = self.key };
        const id = cx.id(key);
        const handle = cx.retain(EditorEngine, id, .{ .scope = id }, initEngine);
        const engine = cx.get(EditorEngine, handle);
        engine.syncBound(self.bind);
        const focused = cx.focused(id);
        setView(&engine.view, theme, id, self.placeholder);
        engine.indent = .{ .size = self.tab_size, .hard_tabs = self.use_hard_tabs };
        const gutter = if (self.show_line_numbers) self.gutter_width else 0;
        const line_height = cx.fontMetrics().line_height;
        const viewport_height = line_height * @as(f32, @floatFromInt(self.rows));
        // The separator after the gutter is one pixel wide.
        const separator: f32 = if (gutter > 0) 1 else 0;
        engine.resolveClick(cx, .{
            .text_x = self.border_width + gutter + separator + self.padding,
            .text_y = self.border_width + self.padding,
            .gutter_end = self.border_width + gutter,
        });
        engine.follow(line_height, viewport_height);
        engine.blink(cx, focused);
        cx.render(ui.box(.{
            .key = key,
            .focusable = true,
            .on_key = cx.on(EditorEngine.onKey, .{ .entity = handle }),
            .on_click = cx.on(EditorEngine.onClick, .{ .entity = handle }),
            .style = .{
                .width = .{ .fixed = self.width },
                .padding = .all(self.border_width),
                .background = .surface,
                .border = .{
                    .width = self.border_width,
                    .color = if (focused) .border_focus else .border,
                },
                .corner_radius = .all(theme.radius_md),
                .cursor = .text,
            },
            .a11y = .{
                .role = .textarea,
                .label = if (self.placeholder.len > 0) self.placeholder else "Code editor",
                .value = if (engine.len > 0) engine.text() else null,
            },
        }, .{
            ui.box(.{ .style = .{
                .direction = .row,
                .width = .{ .grow = 1 },
                .height = .{ .fixed = viewport_height + self.padding * 2 },
            } }, .{
                if (gutter > 0) ui.box(.{ .style = .{
                    .width = .{ .fixed = gutter },
                    .height = .{ .grow = 1 },
                    .padding = .symmetric(0, self.padding),
                } }, .{
                    ui.paint(EditorEngine, engine, paintGutter, .{
                        .width = .{ .grow = 1 },
                        .height = .{ .grow = 1 },
                    }),
                }) else null,
                if (gutter > 0) separatorBox(.vertical) else null,
                ui.box(.{ .style = .{
                    .width = .{ .grow = 1 },
                    .height = .{ .grow = 1 },
                    .padding = .all(self.padding),
                } }, .{
                    ui.paint(EditorEngine, engine, paintEditorText, .{
                        .width = .{ .grow = 1 },
                        .height = .{ .grow = 1 },
                    }),
                }),
            }),
            if (self.show_status_bar) separatorBox(.horizontal) else null,
            if (self.show_status_bar) StatusBar{ .editor = &self, .engine = engine } else null,
        }));
    }

    fn initEngine(engine: *EditorEngine) void {
        assert(engine.len == 0);
    }

    /// The caret's line under the text while focused, then the text.
    fn paintEditorText(engine: *const EditorEngine, painter: *ui.Painter) void {
        if (engine.view.focused) {
            const line_height = painter.fontMetrics().line_height;
            const row: f32 = @floatFromInt(engine.lineOf(engine.cursor));
            painter.pushClip(painter.bounds);
            painter.fill(.{
                .x = painter.bounds.x,
                .y = painter.bounds.y + row * line_height - engine.scroll_y,
                .width = painter.bounds.width,
                .height = line_height,
            }, engine.view.selection_color.withAlpha(0.08));
            painter.popClip();
        }
        TextArea.paintText(engine, painter);
    }

    /// A one-pixel rule in the border colour.
    fn separatorBox(direction: enum { vertical, horizontal }) ui.Box.Element(@TypeOf(.{})) {
        const thickness = ui.Sizing{ .fixed = 1 };
        const span = ui.Sizing{ .grow = 1 };
        return ui.box(.{ .style = .{
            .width = if (direction == .vertical) thickness else span,
            .height = if (direction == .vertical) span else thickness,
            .background = .border,
        } }, .{});
    }

    /// Line numbers for the visible lines, right-aligned 8 px from the
    /// separator, the caret's line in the text colour. The gutter is inset
    /// like the text beside it, so a number's row is the text line's row.
    fn paintGutter(engine: *const EditorEngine, painter: *ui.Painter) void {
        const bounds = painter.bounds;
        const metrics = painter.fontMetrics();
        const line_height = metrics.line_height;
        const size: u16 = @intFromFloat(metrics.point_size);
        painter.pushClip(bounds);
        defer painter.popClip();
        const line_count: u32 = @intCast(std.mem.count(u8, engine.text(), "\n") + 1);
        const caret_line = engine.lineOf(engine.cursor);
        const first: u32 = @intFromFloat(engine.scroll_y / line_height);
        const visible: u32 = @intFromFloat(@ceil(bounds.height / line_height) + 1);
        var line = first;
        while (line < @min(line_count, first + visible)) : (line += 1) {
            var buffer: [10]u8 = undefined;
            // Ten digits hold any u32 line number.
            const label = std.fmt.bufPrint(&buffer, "{d}", .{line + 1}) catch unreachable;
            const view = &engine.view;
            const color = if (line == caret_line) view.text_color else view.placeholder_color;
            const style = ui.PaintText{ .size = size, .color = color };
            const x = bounds.x + bounds.width - 8 - painter.measureText(label, style);
            const row: f32 = @floatFromInt(line);
            const top = bounds.y + row * line_height - engine.scroll_y;
            _ = painter.textOnBaseline(label, x, metrics.calcBaseline(top, line_height), style);
        }
    }

    /// "Ln 3, Col 7" on the left; the indent, encoding, and language on the
    /// right, as 0.3.1's status bar.
    const StatusBar = struct {
        editor: *const CodeEditor,
        engine: *const EditorEngine,

        pub fn render(self: StatusBar, cx: *Cx) void {
            const engine = self.engine;
            const line = engine.lineOf(engine.cursor) + 1;
            const column = engine.cursor - engine.lineStart(engine.cursor) + 1;
            var position_buffer: [32]u8 = undefined;
            var indent_buffer: [16]u8 = undefined;
            // 32 bytes hold "Ln " and ", Col " with two u32s; 16 hold the indent.
            const position = std.fmt.bufPrint(&position_buffer, "Ln {d}, Col {d}", .{
                line,
                column,
            }) catch unreachable;
            const indent_name = if (self.editor.use_hard_tabs) "Tab" else "Spaces";
            const indent = std.fmt.bufPrint(&indent_buffer, "{s}: {d}", .{
                indent_name,
                self.editor.tab_size,
            }) catch unreachable;
            const style = ui.Text{ .size = 12, .color = .muted };
            cx.render(ui.box(.{ .style = .{
                .direction = .row,
                .width = .{ .grow = 1 },
                .height = .{ .fixed = self.editor.status_bar_height },
                .padding = .symmetric(10, 0),
                .gap = 16,
                .alignment = .center_cross,
            } }, .{
                ui.text(position, style),
                ui.box(.{ .style = .{ .width = .{ .grow = 1 } } }, .{}),
                ui.text(indent, style),
                ui.text(self.editor.encoding, style),
                ui.text(self.editor.language_mode, style),
            }));
        }
    };
};

test "core components compile against the core surface" {
    comptime {
        _ = Button;
        _ = Checkbox;
        _ = TextInput;
        _ = TextArea;
        _ = CodeEditor;
    }
}
