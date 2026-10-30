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
        engine.view = .{
            .id = id,
            .focused = focused,
            .placeholder = self.placeholder,
            .text_color = theme.text,
            .placeholder_color = theme.muted,
            .caret_color = theme.text,
            .preedit_underline_color = Color.rgb(0.3, 0.3, 0.3),
        };
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

    /// Placeholder, or text with the preedit at the caret; then the caret.
    fn paintInput(engine: *const InputEngine, painter: *ui.Painter) void {
        const view = &engine.view;
        const bounds = painter.bounds;
        const metrics = painter.fontMetrics();
        const size: u16 = @intFromFloat(metrics.point_size);
        const baseline = metrics.calcBaseline(bounds.y, bounds.height);
        painter.pushClip(bounds);
        defer painter.popClip();
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
        if (preedit.len == 0) painter.fill(caret, view.caret_color);
        var ime_rect = caret;
        ime_rect.x += preedit_width;
        painter.imeCursor(.{
            .owner = view.id,
            .cursor_rect = ime_rect,
            .selected_start = engine.cursor,
            .selected_end = engine.cursor,
        });
    }
};

test "core components compile against the core surface" {
    comptime {
        _ = Button;
        _ = Checkbox;
        _ = TextInput;
    }
}
