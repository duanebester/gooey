//! Gooey Components: library controls (`Button`, `Checkbox`, `Select`,
//! `RadioGroup`, `Tooltip`, `ContextMenu`, `Modal`, `List`, `TextInput`,
//! `TextArea`, `CodeEditor`) and the Lucide icon set. Each control composes
//! `ui.box`, `ui.text`, and `ui.paint` through the public API alone: `zig
//! build import-ban` fails on any `gooey.internals` reference here, so a
//! control can do only what an app can.
//!
//! Keyboard: `Button`, `Checkbox`, `Select`, and `RadioGroup` are focusable,
//! so Tab reaches them, and the core turns Enter and Space into a click on
//! the focused element. `Select`, `RadioGroup`, and `ContextMenu` add their
//! own keys (see `SelectKeys`, `RadioKeys`, and `MenuState.onKey`).

const std = @import("std");
const gooey = @import("gooey");

const assert = std.debug.assert;

const ui = gooey.ui;
const Cx = gooey.Cx;
const Handler = gooey.Handler;
const Effects = gooey.Effects;
const ElementId = gooey.ElementId;
const Key = gooey.Key;
const KeyCode = gooey.input.KeyCode;
const Color = ui.Color;
const InputEngine = gooey.InputEngine;
const AreaEngine = gooey.AreaEngine;
const EditorEngine = gooey.EditorEngine;

/// Lucide icon data for `Painter.svg`.
pub const Lucide = @import("lucide.zig").Lucide;

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
    /// The screen-reader name; defaults to the label.
    accessible_name: ?[]const u8 = null,

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
            .focusable = !self.disabled,
            .on_click = if (self.disabled) null else self.on_click,
            .a11y = .{
                .role = .button,
                .label = self.accessible_name orelse self.label,
                .disabled = self.disabled,
            },
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

    fn variantColors(variant: Variant, theme: *const gooey.Theme) Colors {
        return switch (variant) {
            .primary => .{ .background = theme.primary, .foreground = theme.on_primary },
            .secondary => .{ .background = theme.secondary, .foreground = theme.text },
            .danger => .{ .background = theme.danger, .foreground = theme.on_danger },
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
    /// Text beside the box, which clicks it too.
    label: ?[]const u8 = null,
    /// The screen-reader name; defaults to the label.
    accessible_name: ?[]const u8 = null,
    accessible_description: ?[]const u8 = null,

    pub fn render(self: Checkbox, cx: *Cx) void {
        assert(self.size > 0);
        const theme = cx.theme();
        const mark_size = self.size * 0.7;
        cx.render(ui.box(.{
            .key = self.key,
            .style = .{ .direction = .row, .gap = 8, .alignment = .center_cross },
            .focusable = self.on_click != null,
            .on_click = self.on_click,
            .a11y = .{
                .role = .checkbox,
                .label = self.accessible_name orelse self.label,
                .description = self.accessible_description,
                .checked = self.checked,
            },
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
            if (self.label) |label| ui.text(label, .{
                .size = theme.font_size_base,
                .color = .text,
            }) else null,
        }));
    }

    const Checkmark = struct {
        path: []const u8,

        fn paint(self: *const Checkmark, painter: *ui.Painter) void {
            // The box behind the mark is `primary` while checked.
            painter.svg(self.path, painter.bounds, .{ .fill = painter.theme().on_primary });
        }
    };

    /// The Material "check" icon, as the 0.3.1 checkbox draws it.
    const checkmark = Checkmark{ .path = "M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z" };
};

// =============================================================================
// Select
// =============================================================================

/// A dropdown of options, as the 0.3.1 `Select` draws it, with its menu on a
/// `.popover` layer. The app owns `selected` and `open`: the trigger calls
/// `on_toggle` to open the menu and `on_close` to close it, a click outside
/// calls `on_close`, and option `i` calls `on_select[i]`, typically
/// `cx.on(State.choose, .{ .arg = i })`.
///
/// The combobox takes keyboard focus, and the focused option is the
/// highlighted one, so a screen reader follows it. Enter, Space, Down, and
/// Up open the menu on the selected option (or the first); Down, Up, Home,
/// and End move between options; Enter and Space choose; Esc closes, back
/// on the combobox; and Tab or Shift+Tab closes and moves on, since the
/// options are not tab stops. Each opens or closes through the trigger and
/// chooses through `on_select`, pressed with `effects.click`. A Select
/// retains one 64 B slot for its keys, and adds a key handler per option.
pub const Select = struct {
    key: []const u8,
    options: []const []const u8,
    /// One handler per option.
    on_select: []const Handler,
    on_toggle: Handler,
    on_close: Handler,
    selected: ?usize = null,
    open: bool = false,
    placeholder: []const u8 = "Select...",
    disabled: bool = false,
    width: f32 = 200,
    padding: f32 = 10,
    /// The combobox's screen-reader name; defaults to the placeholder.
    accessible_name: ?[]const u8 = null,
    accessible_description: ?[]const u8 = null,

    pub fn render(self: Select, cx: *Cx) void {
        assert(self.key.len > 0);
        assert(self.on_select.len == self.options.len);
        if (self.selected) |index| assert(index < self.options.len);
        if (self.options.len > select_option_count_max) std.debug.panic(
            "Select \"{s}\" of {d} options: capacity {d}",
            .{ self.key, self.options.len, select_option_count_max },
        );
        const theme = cx.theme();
        const key = Key{ .name = self.key };
        const id = cx.id(key);
        const handle = cx.retain(SelectKeys, id, .frame, SelectKeys.init);
        cx.get(SelectKeys, handle).root = id;
        const trigger_height = @as(f32, @floatFromInt(theme.font_size_base)) +
            self.padding * 2 + 4;
        cx.render(ui.box(.{
            .key = key,
            // The trigger's corners, for the focus ring; the box paints none.
            .style = .{
                .width = .{ .fixed = self.width },
                .corner_radius = .all(theme.radius_md),
            },
            .focusable = !self.disabled,
            .on_key = if (self.disabled) null else cx.on(SelectKeys.onKey, .{
                .entity = handle,
                .arg = self.keyArg(SelectKeys.on_combobox),
            }),
            .on_click_outside = if (self.open) self.on_close else null,
            .a11y = .{
                .role = .combobox,
                .label = self.accessible_name orelse self.placeholder,
                .description = self.accessible_description,
                .value = self.displayText(),
                .expanded = self.open,
                .has_popup = true,
                .disabled = self.disabled,
            },
        }, .{
            SelectTrigger{ .select = &self, .height = trigger_height },
            if (self.open) SelectMenu{
                .select = &self,
                .offset_y = trigger_height,
                .keys = handle,
            } else null,
        }));
    }

    fn displayText(self: *const Select) []const u8 {
        const index = self.selected orelse return self.placeholder;
        return self.options[index];
    }

    /// What a key handler on the combobox or option `focused` acts on.
    fn keyArg(self: *const Select, focused: u16) SelectKeys.Arg {
        assert(self.options.len <= select_option_count_max);
        const start = self.selected orelse 0;
        return .{
            .focused = focused,
            .count = @intCast(self.options.len),
            .start = @intCast(start),
            .open = self.open,
        };
    }
};

/// The most options one `Select` lists: the key handlers pack indexes into
/// 16 bits, and a menu past a thousand rows is not a dropdown.
pub const select_option_count_max: u32 = 1024;

/// A `Select`'s keyboard handling, retained under its key so its handlers
/// have state to run on. The arguments come from the frame on screen; only
/// the combobox's id, which never changes, is kept.
const SelectKeys = struct {
    root: ElementId,

    /// `Arg.focused` for the combobox itself.
    const on_combobox: u16 = std.math.maxInt(u16);

    const Arg = packed struct(u64) {
        /// The focused option, or `on_combobox`.
        focused: u16,
        count: u16,
        /// The option the menu opens on: the selected one, or the first.
        start: u16,
        open: bool,
        padding: u15 = 0,
    };

    comptime {
        assert(select_option_count_max < on_combobox);
    }

    fn init(self: *SelectKeys) void {
        self.root = .root;
    }

    fn trigger(self: *const SelectKeys) ElementId {
        assert(self.root.isKeyed());
        return self.root.child(.{ .name = "trigger" });
    }

    fn option(self: *const SelectKeys, index: u16) ElementId {
        assert(self.root.isKeyed());
        assert(index < select_option_count_max);
        return self.root.child(.{ .name = "menu" }).child(.{ .index = index });
    }

    /// Keys without Cmd, Ctrl, or Alt. A key an option leaves alone bubbles
    /// to the combobox's handler, which closes the menu on Esc and Tab.
    /// Shift+Tab takes the Tab arm too: `KeyCode` has no back-tab.
    fn onKey(self: *SelectKeys, arg: Arg, effects: *Effects) void {
        assert(self.root.isKeyed());
        assert(arg.start < @max(arg.count, 1));
        const event = effects.inputEvent() orelse return;
        if (event.* != .key_down) return;
        const key = event.key_down;
        if (key.modifiers.cmd or key.modifiers.ctrl or key.modifiers.alt) return;
        if (arg.focused == on_combobox) {
            self.comboboxKey(arg, key.key, effects);
        } else {
            assert(arg.open);
            assert(arg.focused < arg.count);
            self.optionKey(arg, key.key, effects);
        }
    }

    /// Opening focuses the start option, which the next frame renders.
    fn comboboxKey(self: *SelectKeys, arg: Arg, key: KeyCode, effects: *Effects) void {
        assert(arg.focused == on_combobox);
        assert(arg.start < @max(arg.count, 1));
        switch (key) {
            .@"return", .keypad_enter, .space, .down, .up => {
                const choosing = key != .down and key != .up;
                if (arg.open and choosing) {
                    effects.click(self.trigger());
                } else {
                    if (!arg.open) effects.click(self.trigger());
                    if (arg.count > 0) effects.focus(self.option(arg.start));
                }
                effects.stopPropagation();
            },
            .escape => if (arg.open) {
                effects.click(self.trigger());
                effects.focus(self.root);
                effects.stopPropagation();
            },
            // Tab closes the menu and goes on: from the combobox, the core's
            // Tab moves to the next tab stop, which the closing menu's
            // options, still in the frame on screen, are not.
            .tab => if (arg.open) {
                effects.click(self.trigger());
                effects.focus(self.root);
            },
            else => {},
        }
    }

    /// Movement stops at the first and last option, as a listbox's does.
    fn optionKey(self: *SelectKeys, arg: Arg, key: KeyCode, effects: *Effects) void {
        assert(arg.count > 0);
        assert(arg.focused < arg.count);
        const last = arg.count - 1;
        const target: u16 = switch (key) {
            .down => @min(arg.focused + 1, last),
            .up => arg.focused -| 1,
            .home => 0,
            .end => last,
            .@"return", .keypad_enter, .space => {
                effects.click(self.option(arg.focused));
                effects.focus(self.root);
                effects.stopPropagation();
                return;
            },
            else => return,
        };
        assert(target <= last);
        effects.focus(self.option(target));
        effects.stopPropagation();
    }
};

const SelectTrigger = struct {
    select: *const Select,
    height: f32,

    pub fn render(self: SelectTrigger, cx: *Cx) void {
        const select = self.select;
        assert(self.height > 0);
        const theme = cx.theme();
        const key = Key{ .name = "trigger" };
        const hovered = !select.disabled and cx.hovered(cx.id(key));
        const opacity: f32 = if (select.disabled) 0.6 else 1;
        const background = if (hovered) theme.overlay else theme.surface;
        const text_color = if (select.selected == null) theme.muted else theme.text;
        const chevron = &chevrons[@intFromBool(select.open)][@intFromBool(select.disabled)];
        // An open menu's trigger closes through `on_close`, not `on_toggle`.
        // Every key a drain delivers after the one that chose an option
        // routes against this frame, where the menu is still open, so a Tab
        // or Esc that presses the trigger here must not reopen the menu the
        // choice closed; closing a closed menu changes nothing.
        var on_click: ?Handler = null;
        if (!select.disabled) {
            on_click = if (select.open) select.on_close else select.on_toggle;
        }
        cx.render(ui.box(.{
            .key = key,
            .style = .{
                .width = .{ .grow = 1 },
                .height = .{ .fixed = self.height },
                .padding = .symmetric(select.padding, select.padding / 2),
                .background = .{ .rgba = background.withAlpha(opacity) },
                .border = .{ .width = 1, .color = if (select.open) .border_focus else .border },
                .corner_radius = .all(theme.radius_md),
                .direction = .row,
                .alignment = .{ .main = .space_between, .cross = .center },
                .cursor = .pointer,
            },
            .on_click = on_click,
        }, .{
            ui.text(select.displayText(), .{
                .size = theme.font_size_base,
                .color = .{ .rgba = text_color.withAlpha(opacity) },
            }),
            ui.paint(SelectIcon, chevron, SelectIcon.paint, .{
                .width = .{ .fixed = 10 },
                .height = .{ .fixed = 10 },
            }),
        }));
    }
};

const SelectMenu = struct {
    select: *const Select,
    offset_y: f32,
    keys: gooey.Handle(SelectKeys),

    pub fn render(self: SelectMenu, cx: *Cx) void {
        const select = self.select;
        assert(select.open);
        const theme = cx.theme();
        cx.render(ui.box(.{
            // `SelectKeys.option` derives the options' ids from this key.
            .key = .{ .name = "menu" },
            .layer = .{
                .kind = .popover,
                .anchor = .{ .parent = .{ .y = self.offset_y } },
                .clip = .escape,
            },
            .style = .{
                .width_min = select.width,
                .padding = .all(4),
                .background = .surface,
                .border = .{ .width = 1, .color = .border },
                .corner_radius = .all(theme.radius_md),
                .gap = 2,
                .shadow = .{ .blur = 12, .offset_y = 4 },
            },
            .a11y = .{
                .role = .listbox,
                .label = select.accessible_name orelse select.placeholder,
            },
        }, .{SelectOptions{ .select = select, .keys = self.keys }}));
    }
};

const SelectOptions = struct {
    select: *const Select,
    keys: gooey.Handle(SelectKeys),

    pub fn render(self: SelectOptions, cx: *Cx) void {
        const select = self.select;
        const theme = cx.theme();
        assert(select.options.len == select.on_select.len);
        assert(select.options.len <= select_option_count_max);
        const set_size: u16 = @intCast(select.options.len);
        for (select.options, select.on_select, 0..) |label, handler, index| {
            const key = Key{ .index = index };
            const position: u16 = @intCast(index);
            const chosen = select.selected == index;
            // The focused option is the highlighted one, drawn as hovered.
            const lit = cx.hovered(cx.id(key)) or cx.focused(cx.id(key));
            const background: ?Color = if (lit)
                theme.overlay
            else if (chosen) theme.primary.withAlpha(0.15) else null;
            cx.render(ui.box(.{
                .key = key,
                .style = .{
                    .width = .{ .grow = 1 },
                    .padding = .symmetric(select.padding, select.padding * 0.7),
                    .background = if (background) |color| .{ .rgba = color } else null,
                    .corner_radius = .all(theme.radius_md - 2),
                    .direction = .row,
                    .gap = 8,
                    .alignment = .{ .main = .space_between, .cross = .center },
                    .cursor = .pointer,
                },
                // Arrow keys reach the options; Tab leaves the menu.
                .focusable = true,
                .tab_stop = false,
                .on_click = handler,
                .on_key = cx.on(SelectKeys.onKey, .{
                    .entity = self.keys,
                    .arg = select.keyArg(position),
                }),
                .a11y = .{
                    .role = .option,
                    .label = label,
                    .selected = chosen,
                    .pos_in_set = position + 1,
                    .set_size = set_size,
                },
            }, .{
                ui.text(label, .{ .size = theme.font_size_base, .color = .text }),
                ui.box(.{ .style = .{
                    .width = .{ .fixed = 16 },
                    .height = .{ .fixed = 16 },
                    .alignment = .center,
                } }, .{
                    if (chosen) ui.paint(SelectIcon, &select_check, SelectIcon.paint, .{
                        .width = .{ .fixed = 14 },
                        .height = .{ .fixed = 14 },
                    }) else null,
                }),
            }));
        }
    }
};

/// A Material icon tinted by a theme colour at paint time, so one constant
/// serves every theme.
const SelectIcon = struct {
    path: []const u8,
    color: enum { text, primary },
    opacity: f32,

    fn paint(self: *const SelectIcon, painter: *ui.Painter) void {
        const theme = painter.theme();
        const color = switch (self.color) {
            .text => theme.text,
            .primary => theme.primary,
        };
        painter.svg(self.path, painter.bounds, .{ .fill = color.withAlpha(self.opacity) });
    }
};

const chevron_down = "M7.41 8.59L12 13.17l4.59-4.58L18 10l-6 6-6-6z";
const chevron_up = "M7.41 15.41L12 10.83l4.59 4.58L18 14l-6-6-6 6z";

/// Indexed by `open`, then `disabled`.
const chevrons = [2][2]SelectIcon{
    .{
        .{ .path = chevron_down, .color = .text, .opacity = 1 },
        .{ .path = chevron_down, .color = .text, .opacity = 0.6 },
    },
    .{
        .{ .path = chevron_up, .color = .text, .opacity = 1 },
        .{ .path = chevron_up, .color = .text, .opacity = 0.6 },
    },
};

const select_check = SelectIcon{ .path = Checkbox.checkmark.path, .color = .primary, .opacity = 1 };

// =============================================================================
// RadioGroup
// =============================================================================

/// A column of mutually exclusive options that behaves as a native radio
/// group. The app owns `selected`: option `i` calls `on_select[i]`, typically
/// `cx.on(State.choose, .{ .arg = i })`.
///
/// Tab enters the group at the selected option, or the first when none is,
/// and leaves it in one press, because only that option is a tab stop. Down
/// and Right select the next option, Up and Left the previous, wrapping at
/// the ends, with focus following; Enter and Space select the focused one.
/// Each selection goes through `on_select`, pressed with `effects.click`. A
/// RadioGroup retains one 64 B slot for its keys, and adds a key handler per
/// option.
pub const RadioGroup = struct {
    key: []const u8,
    options: []const []const u8,
    /// One handler per option.
    on_select: []const Handler,
    selected: ?usize = null,
    /// Text above the options; also the group's screen-reader name.
    label: ?[]const u8 = null,
    /// The group's screen-reader name; defaults to the label.
    accessible_name: ?[]const u8 = null,
    accessible_description: ?[]const u8 = null,

    pub fn render(self: RadioGroup, cx: *Cx) void {
        assert(self.key.len > 0);
        assert(self.options.len > 0);
        assert(self.on_select.len == self.options.len);
        assert(self.accessible_name != null or self.label != null);
        if (self.selected) |index| assert(index < self.options.len);
        if (self.options.len > radio_option_count_max) std.debug.panic(
            "RadioGroup \"{s}\" of {d} options: capacity {d}",
            .{ self.key, self.options.len, radio_option_count_max },
        );
        const theme = cx.theme();
        const key = Key{ .name = self.key };
        const id = cx.id(key);
        const handle = cx.retain(RadioKeys, id, .frame, RadioKeys.init);
        cx.get(RadioKeys, handle).root = id;
        cx.render(ui.box(.{
            .key = key,
            .style = .{ .gap = 8 },
            .a11y = .{
                .role = .group,
                .label = self.accessible_name orelse self.label,
                .description = self.accessible_description,
            },
        }, .{
            if (self.label) |label| ui.text(label, .{
                .size = theme.font_size_base,
                .weight = .medium,
                .color = .text,
            }) else null,
            ui.box(.{
                // `RadioKeys.option` derives the options' ids from this key.
                .key = .{ .name = "options" },
                .style = .{ .gap = 8 },
            }, .{RadioOptions{ .group = &self, .keys = handle }}),
        }));
    }
};

/// The most options one `RadioGroup` lists: the key handlers pack indexes
/// into 16 bits, and a group past a few dozen options wants a `Select`.
pub const radio_option_count_max: u32 = 256;

/// A `RadioGroup`'s arrow keys, retained under its key so the options' key
/// handlers have state to run on; only the group's id, which never changes,
/// is kept.
const RadioKeys = struct {
    root: ElementId,

    const Arg = packed struct(u32) {
        index: u16,
        count: u16,
    };

    comptime {
        assert(radio_option_count_max <= std.math.maxInt(u16));
    }

    fn init(self: *RadioKeys) void {
        self.root = .root;
    }

    fn option(self: *const RadioKeys, index: u16) ElementId {
        assert(self.root.isKeyed());
        assert(index < radio_option_count_max);
        return self.root.child(.{ .name = "options" }).child(.{ .index = index });
    }

    /// Keys without Cmd, Ctrl, or Alt select the next or previous option by
    /// clicking it, and focus follows.
    fn onKey(self: *RadioKeys, arg: Arg, effects: *Effects) void {
        assert(arg.count > 0);
        assert(arg.index < arg.count);
        const event = effects.inputEvent() orelse return;
        if (event.* != .key_down) return;
        const modifiers = event.key_down.modifiers;
        if (modifiers.cmd or modifiers.ctrl or modifiers.alt) return;
        const target: u16 = switch (event.key_down.key) {
            .down, .right => (arg.index + 1) % arg.count,
            .up, .left => (arg.index + arg.count - 1) % arg.count,
            else => return,
        };
        assert(target < arg.count);
        effects.click(self.option(target));
        effects.focus(self.option(target));
        effects.stopPropagation();
    }
};

const RadioOptions = struct {
    group: *const RadioGroup,
    keys: gooey.Handle(RadioKeys),

    pub fn render(self: RadioOptions, cx: *Cx) void {
        const group = self.group;
        assert(group.options.len == group.on_select.len);
        assert(group.options.len <= radio_option_count_max);
        const count: u16 = @intCast(group.options.len);
        // With nothing selected, the first option is the group's tab stop.
        const tab_stop = group.selected orelse 0;
        for (group.options, group.on_select, 0..) |label, handler, index| {
            const position: u16 = @intCast(index);
            cx.render(RadioOption{
                .label = label,
                .position = position,
                .count = count,
                .selected = group.selected == index,
                .tab_stop = tab_stop == index,
                .on_select = handler,
                .on_key = cx.on(RadioKeys.onKey, .{
                    .entity = self.keys,
                    .arg = RadioKeys.Arg{ .index = position, .count = count },
                }),
            });
        }
    }
};

const RadioOption = struct {
    label: []const u8,
    position: u16,
    count: u16,
    selected: bool,
    tab_stop: bool,
    on_select: Handler,
    on_key: Handler,

    const ring_size: f32 = 18;
    const dot_size: f32 = 10;

    pub fn render(self: RadioOption, cx: *Cx) void {
        assert(self.position < self.count);
        if (self.selected) assert(self.tab_stop);
        const theme = cx.theme();
        cx.render(ui.box(.{
            .key = .{ .index = self.position },
            .style = .{
                .direction = .row,
                .gap = 8,
                .alignment = .center_cross,
                .cursor = .pointer,
            },
            .focusable = true,
            .tab_stop = self.tab_stop,
            .on_click = self.on_select,
            .on_key = self.on_key,
            .a11y = .{
                .role = .radio,
                .label = self.label,
                .checked = self.selected,
                .pos_in_set = self.position + 1,
                .set_size = self.count,
            },
        }, .{
            ui.box(.{ .style = .{
                .width = .{ .fixed = ring_size },
                .height = .{ .fixed = ring_size },
                .corner_radius = .all(ring_size / 2),
                .border = .{ .width = 2, .color = if (self.selected) .primary else .border },
                .background = .surface,
                .alignment = .center,
            } }, .{
                if (self.selected) ui.box(.{ .style = .{
                    .width = .{ .fixed = dot_size },
                    .height = .{ .fixed = dot_size },
                    .corner_radius = .all(dot_size / 2),
                    .background = .primary,
                } }, .{}) else null,
            }),
            ui.text(self.label, .{ .size = theme.font_size_base, .color = .text }),
        }));
    }
};

// =============================================================================
// Tooltip
// =============================================================================

/// A short text shown beside `child` on a `.tooltip` layer: after the
/// pointer rests on it for `delay_ms`, or at once while keyboard focus with
/// its ring is on it or inside it (`cx.focusVisibleWithin`). It hides when
/// both leave, and Escape hides it until they do. It opens below the child,
/// or above when it does not fit there, and never takes the pointer, so it
/// cannot end the child's hover or block a click on what is under it.
///
/// The text is a `tooltip` node after the child's for the screen reader
/// while it shows. A Tooltip retains one 64 B slot for its timing, so each
/// one on screen counts against the app's retained budget.
pub fn Tooltip(comptime Child: type) type {
    return struct {
        key: []const u8,
        text: []const u8,
        child: Child,
        delay_ms: u32 = tooltip_delay_ms_default,
        width_max: f32 = 320,

        const Self = @This();

        pub fn render(self: Self, cx: *Cx) void {
            assert(self.key.len > 0);
            assert(self.text.len > 0);
            assert(self.width_max > 0);
            const key = Key{ .name = self.key };
            const id = cx.id(key);
            const handle = cx.retain(TooltipState, id, .frame, TooltipState.init);
            const state = cx.get(TooltipState, handle);
            const shown = state.update(.{
                .hovered = cx.hovered(id),
                .focused = cx.focusVisibleWithin(id),
                .now_ns = cx.now(),
                .delay_ns = @as(u64, self.delay_ms) * std.time.ns_per_ms,
            });
            if (state.wait_ms) |wait_ms| cx.requestRenderAfter(wait_ms);
            // The child's height from the last frame: a tooltip shows only
            // after a frame has laid its child out.
            const height = if (cx.bounds(id)) |rect| rect.height else 0;
            cx.render(ui.box(.{
                .key = key,
                .on_key = cx.on(TooltipState.onKey, .{ .entity = handle }),
            }, .{
                self.child,
                if (shown) TooltipBubble{
                    .text = self.text,
                    .offset_y = height + tooltip_gap,
                    .width_max = self.width_max,
                } else null,
            }));
        }
    };
}

/// The rest before a hovered tooltip shows, as macOS and Windows wait.
pub const tooltip_delay_ms_default: u32 = 500;
/// The space between a tooltip and its child.
const tooltip_gap: f32 = 4;

/// A `Tooltip`'s timing, retained under its key: when the pointer came to
/// rest on the child, and whether Escape dismissed it.
const TooltipState = struct {
    /// When the current hover began, or null while the pointer is away.
    hover_since_ns: ?u64,
    /// How long until the hover reaches the delay, for `requestRenderAfter`;
    /// null when no render is waiting.
    wait_ms: ?u32,
    /// Shown in the last build, so Escape claims the key only then.
    shown: bool,
    /// Escape hid it; cleared once hover and focus both leave.
    dismissed: bool,

    const Inputs = struct { hovered: bool, focused: bool, now_ns: u64, delay_ns: u64 };

    fn init(self: *TooltipState) void {
        self.* = .{ .hover_since_ns = null, .wait_ms = null, .shown = false, .dismissed = false };
    }

    /// Whether the tooltip shows this build, from the child's hover and
    /// focus and the tick's clock.
    fn update(self: *TooltipState, inputs: Inputs) bool {
        self.wait_ms = null;
        if (!inputs.hovered and !inputs.focused) {
            self.hover_since_ns = null;
            self.dismissed = false;
            self.shown = false;
            return false;
        }
        if (!inputs.hovered) {
            self.hover_since_ns = null;
        } else {
            if (self.hover_since_ns == null) self.hover_since_ns = inputs.now_ns;
        }
        var rested = false;
        if (self.hover_since_ns) |since_ns| {
            assert(since_ns <= inputs.now_ns);
            const elapsed_ns = inputs.now_ns - since_ns;
            rested = elapsed_ns >= inputs.delay_ns;
            if (!rested) {
                const wait_ns = inputs.delay_ns - elapsed_ns;
                assert(wait_ns > 0);
                // Rounded up, so the render it asks for lands at or past the delay.
                const wait_ms = @divFloor(wait_ns - 1, std.time.ns_per_ms) + 1;
                assert(wait_ms <= std.math.maxInt(u32));
                self.wait_ms = @intCast(wait_ms);
            }
        }
        self.shown = !self.dismissed and (inputs.focused or rested);
        // Shown or dismissed, no render waits on the delay.
        if (self.shown or self.dismissed) self.wait_ms = null;
        if (self.shown) assert(!self.dismissed);
        return self.shown;
    }

    /// Escape hides a shown tooltip; other keys, and Escape while it is
    /// hidden, go on to the child's ancestors, such as a modal that closes.
    fn onKey(self: *TooltipState, effects: *Effects) void {
        const event = effects.inputEvent() orelse return;
        if (event.* != .key_down) return;
        if (event.key_down.key != .escape) return;
        if (!self.shown) return;
        self.dismissed = true;
        self.shown = false;
        effects.requestRender();
        effects.stopPropagation();
    }
};

const TooltipBubble = struct {
    text: []const u8,
    offset_y: f32,
    width_max: f32,

    pub fn render(self: TooltipBubble, cx: *Cx) void {
        assert(self.offset_y >= tooltip_gap);
        assert(self.width_max > 0);
        const theme = cx.theme();
        cx.render(ui.box(.{
            .layer = .{
                .kind = .tooltip,
                .anchor = .{ .parent = .{ .y = self.offset_y } },
                .clip = .escape,
            },
            .style = .{
                .width_max = self.width_max,
                .padding = .symmetric(8, 4),
                .background = .overlay,
                .border = .{ .width = 1, .color = .border },
                .corner_radius = .all(theme.radius_sm),
                .shadow = .{ .blur = 8, .offset_y = 2 },
            },
            .a11y = .{ .role = .tooltip, .label = self.text },
        }, .{
            ui.text(self.text, .{
                .size = theme.font_size_base -| 2,
                .color = .text,
                .wrap = .words,
            }),
        }));
    }
};

// =============================================================================
// ContextMenu
// =============================================================================

/// One row of a `ContextMenu`: an action, or with `separator` a divider that
/// ignores every other field. An action without `on_select`, or `disabled`,
/// is drawn dimmed and skipped by the arrow keys.
pub const MenuItem = struct {
    label: []const u8 = "",
    /// Runs when the row is chosen; the menu then closes. It must not stop
    /// propagation, since the menu closes on the click it bubbles.
    on_select: ?Handler = null,
    /// A shortcut hint drawn at the row's end, such as "Ctrl+C"; binding it
    /// is the app's keymap's job.
    shortcut: ?[]const u8 = null,
    disabled: bool = false,
    /// Draws the label in the theme's `danger`, for a destructive action.
    danger: bool = false,
    separator: bool = false,

    fn enabled(self: *const MenuItem) bool {
        return !self.separator and !self.disabled and self.on_select != null;
    }
};

/// A right-click menu over `child`, on a `.popover` layer at the pointer.
/// A right press on the child (a Ctrl+press on macOS) opens it there, and
/// Shift+F10 while focus is in the child opens it below the focused element;
/// either focuses its first action, drawn only for the key. Down, Up, Home,
/// and End move between actions, wrapping; Enter or Space chooses; Escape or
/// Tab closes, and a choice or a close from the keyboard returns focus where
/// it was. A press outside closes it, and a right press elsewhere in the
/// child moves it.
///
/// The menu owns whether it is open and where, in one retained 64 B slot,
/// so the app supplies only the rows. Each row's `on_select` is an ordinary
/// handler, such as `cx.on(State.copy, .{ .arg = row })`.
pub fn ContextMenu(comptime Child: type) type {
    return struct {
        key: []const u8,
        items: []const MenuItem,
        child: Child,
        width_min: f32 = 180,
        /// The menu's screen-reader name.
        accessible_name: []const u8 = "Context menu",

        const Self = @This();

        pub fn render(self: Self, cx: *Cx) void {
            assert(self.key.len > 0);
            assert(self.items.len > 0);
            if (self.items.len > menu_item_count_max) std.debug.panic(
                "ContextMenu \"{s}\" of {d} items: capacity {d}",
                .{ self.key, self.items.len, menu_item_count_max },
            );
            const key = Key{ .name = self.key };
            const id = cx.id(key);
            const handle = cx.retain(MenuState, id, .frame, MenuState.init);
            const state = cx.get(MenuState, handle);
            state.root = id;
            const enabled = enabledMask(self.items);
            cx.render(ui.box(.{
                .key = key,
                .on_context_menu = cx.on(MenuState.open, .{ .entity = handle, .arg = enabled }),
            }, .{
                self.child,
                if (state.shown) MenuPanel{
                    .items = self.items,
                    .width_min = self.width_min,
                    .accessible_name = self.accessible_name,
                    .x = state.x,
                    .y = state.y,
                    .keys = handle,
                    .enabled = enabled,
                } else null,
            }));
        }
    };
}

/// The most rows one `ContextMenu` holds: its key handler carries which rows
/// are actions as a 64-bit mask, and a longer menu wants another design.
pub const menu_item_count_max: u32 = 64;

/// Bit `i` set when row `i` is an action the keys reach.
fn enabledMask(items: []const MenuItem) u64 {
    assert(items.len <= menu_item_count_max);
    var mask: u64 = 0;
    for (items, 0..) |*item, index| {
        if (item.enabled()) mask |= @as(u64, 1) << @intCast(index);
    }
    return mask;
}

/// A `ContextMenu`'s state, retained under its key: whether it is open,
/// where, and the element focus returns to.
///
/// Every handler sits on a `menuitem` row, so each handled record belongs to
/// an interactive accessibility node: the row's own handler closes the menu
/// and takes the keys, and the app's `on_select` sits on a box inside it that
/// fills it, so a click runs `on_select` and then bubbles to the close.
const MenuState = struct {
    root: ElementId,
    shown: bool,
    x: f32,
    y: f32,
    restore: ElementId,

    fn init(self: *MenuState) void {
        self.* = .{ .root = .root, .shown = false, .x = 0, .y = 0, .restore = .root };
    }

    fn row(self: *const MenuState, index: u32) ElementId {
        assert(self.root.isKeyed());
        assert(index < menu_item_count_max);
        return self.root.child(.{ .name = "menu" }).child(.{ .index = index });
    }

    /// The box inside row `index` that holds its `on_select`.
    fn pick(self: *const MenuState, index: u32) ElementId {
        return self.row(index).child(.{ .name = "pick" });
    }

    /// `Box.on_context_menu`: at the press, or below the focused element
    /// for Shift+F10. Either focuses the first action, so the keys work at
    /// once; only the key's focus draws a ring and lights the row.
    fn open(self: *MenuState, enabled: u64, effects: *Effects) void {
        assert(self.root.isKeyed());
        const event = effects.inputEvent() orelse return;
        const focused = effects.focusedElement();
        switch (event.*) {
            .mouse_down => |mouse| {
                self.x = @floatCast(mouse.position.x);
                self.y = @floatCast(mouse.position.y);
            },
            .key_down => {
                const bounds = effects.bounds(focused orelse return) orelse return;
                self.x = bounds.x;
                self.y = bounds.y + bounds.height;
            },
            else => return,
        }
        assert(std.math.isFinite(self.x));
        assert(std.math.isFinite(self.y));
        if (menuStep(enabled, null, .first)) |index| effects.focus(self.row(index));
        self.shown = true;
        self.restore = focused orelse .root;
        effects.requestRender();
    }

    /// A press outside: the press itself moves focus.
    fn dismiss(self: *MenuState, effects: *Effects) void {
        self.shown = false;
        effects.requestRender();
    }

    /// A row's click, after its `on_select` ran, and the keys that close.
    fn close(self: *MenuState, effects: *Effects) void {
        self.shown = false;
        if (self.restore == .root) effects.blur() else effects.focus(self.restore);
        effects.requestRender();
    }

    /// A row's keys; the focused row is the one they act on.
    fn onKey(self: *MenuState, enabled: u64, effects: *Effects) void {
        assert(self.shown);
        const event = effects.inputEvent() orelse return;
        if (event.* != .key_down) return;
        const key = event.key_down;
        if (key.modifiers.cmd or key.modifiers.ctrl or key.modifiers.alt) return;
        const current = self.focusedRow(effects.focusedElement());
        const step: MenuStep = switch (key.key) {
            .down => .next,
            .up => .previous,
            .home => .first,
            .end => .last,
            .@"return", .keypad_enter, .space => {
                const index = current orelse return;
                // `effects.click` runs the box's own handler only.
                effects.click(self.pick(index));
                self.close(effects);
                effects.stopPropagation();
                return;
            },
            .escape, .tab => {
                self.close(effects);
                effects.stopPropagation();
                return;
            },
            else => return,
        };
        if (menuStep(enabled, current, step)) |index| effects.focus(self.row(index));
        effects.stopPropagation();
    }

    fn focusedRow(self: *const MenuState, focused: ?ElementId) ?u32 {
        const id = focused orelse return null;
        var index: u32 = 0;
        while (index < menu_item_count_max) : (index += 1) {
            if (self.row(index) == id) return index;
        }
        return null;
    }
};

const MenuStep = enum { next, previous, first, last };

/// The action row a key moves to among `enabled`'s set bits, wrapping, or
/// null when there is none. From no row, `next` takes the first and
/// `previous` the last.
fn menuStep(enabled: u64, current: ?u32, step: MenuStep) ?u32 {
    if (enabled == 0) return null;
    const first: u32 = @ctz(enabled);
    const last: u32 = 63 - @as(u32, @clz(enabled));
    assert(first <= last);
    const from = current orelse return switch (step) {
        .next, .first => first,
        .previous, .last => last,
    };
    assert(from < menu_item_count_max);
    return switch (step) {
        .first => first,
        .last => last,
        .next => blk: {
            const after = if (from == 63) 0 else enabled >> @intCast(from + 1);
            break :blk if (after == 0) first else from + 1 + @as(u32, @ctz(after));
        },
        .previous => blk: {
            const below = enabled & ((@as(u64, 1) << @intCast(from)) - 1);
            break :blk if (below == 0) last else 63 - @as(u32, @clz(below));
        },
    };
}

/// The open menu, on a `.popover` layer anchored to the window, which keeps
/// it inside the window near an edge. Its rows sit directly under it, keyed
/// by index (`MenuState.row`).
const MenuPanel = struct {
    items: []const MenuItem,
    width_min: f32,
    accessible_name: []const u8,
    x: f32,
    y: f32,
    keys: gooey.Handle(MenuState),
    enabled: u64,

    pub fn render(self: MenuPanel, cx: *Cx) void {
        assert(self.items.len <= menu_item_count_max);
        assert(self.width_min >= 0);
        const theme = cx.theme();
        cx.render(ui.box(.{
            .key = .{ .name = "menu" },
            .layer = .{
                .kind = .popover,
                .anchor = .{ .window = .{ .x = self.x, .y = self.y } },
                .clip = .escape,
            },
            .style = .{
                .width_min = self.width_min,
                .padding = .all(4),
                .gap = 2,
                .background = .surface,
                .border = .{ .width = 1, .color = .border },
                .corner_radius = .all(theme.radius_md),
                .shadow = .{ .blur = 12, .offset_y = 4 },
            },
            .on_click_outside = cx.on(MenuState.dismiss, .{ .entity = self.keys }),
            .a11y = .{ .role = .menu, .label = self.accessible_name },
        }, .{MenuRows{ .items = self.items, .keys = self.keys, .enabled = self.enabled }}));
    }
};

const MenuRows = struct {
    items: []const MenuItem,
    keys: gooey.Handle(MenuState),
    enabled: u64,

    pub fn render(self: MenuRows, cx: *Cx) void {
        assert(self.items.len <= menu_item_count_max);
        const close = cx.on(MenuState.close, .{ .entity = self.keys });
        const on_key = cx.on(MenuState.onKey, .{ .entity = self.keys, .arg = self.enabled });
        for (self.items, 0..) |*item, index| {
            const key = Key{ .index = index };
            if (item.separator) {
                cx.render(ui.box(.{
                    .key = key,
                    .style = .{ .width = .{ .grow = 1 }, .padding = .symmetric(0, 4) },
                }, .{ui.box(.{ .style = .{
                    .width = .{ .grow = 1 },
                    .height = .{ .fixed = 1 },
                    .background = .border,
                } }, .{})}));
            } else {
                cx.render(MenuRow{ .item = item, .key = key, .close = close, .on_key = on_key });
            }
        }
    }
};

const MenuRow = struct {
    item: *const MenuItem,
    key: Key,
    close: Handler,
    on_key: Handler,

    pub fn render(self: MenuRow, cx: *Cx) void {
        const item = self.item;
        assert(!item.separator);
        assert(item.label.len > 0);
        const theme = cx.theme();
        const enabled = item.enabled();
        const id = cx.id(self.key);
        // The keyboard's row is lit only while focus shows, so a menu opened
        // with the pointer lights only what the pointer is over.
        const lit = enabled and (cx.hovered(id) or cx.focusVisibleWithin(id));
        const label_color: ui.ColorToken = if (!enabled)
            .muted
        else if (item.danger) .danger else .text;
        cx.render(ui.box(.{
            .key = self.key,
            .style = .{
                .width = .{ .grow = 1 },
                .background = if (lit) .overlay else null,
                .corner_radius = .all(theme.radius_sm),
                .cursor = if (enabled) .pointer else null,
            },
            .focusable = enabled,
            .tab_stop = false,
            .on_click = if (enabled) self.close else null,
            .on_key = if (enabled) self.on_key else null,
            .a11y = .{ .role = .menuitem, .label = item.label, .disabled = !enabled },
        }, .{ui.box(.{
            // Fills the row, so every click on it lands here first.
            .key = .{ .name = "pick" },
            .style = .{
                .direction = .row,
                .width = .{ .grow = 1 },
                .padding = .symmetric(10, 6),
                .gap = 24,
                .alignment = .{ .main = .space_between, .cross = .center },
            },
            .on_click = if (enabled) item.on_select else null,
        }, .{
            ui.text(item.label, .{ .size = theme.font_size_base, .color = label_color }),
            if (item.shortcut) |shortcut| ui.text(shortcut, .{
                .size = theme.font_size_base -| 2,
                .color = .muted,
            }) else null,
        })}));
    }
};

// =============================================================================
// Modal
// =============================================================================

/// A dialog over a dimmed backdrop, as 0.3.1's `Modal`, on a `.modal` layer:
/// nothing opened before it receives the pointer (contract §6), and layers
/// its child opens, such as a `Select`'s menu, sit above it. The app owns
/// `open`; with `close_on_backdrop`, a press outside the panel calls
/// `on_close`. 0.3.1's fade and scale wait for the animation cluster.
pub fn Modal(comptime Child: type) type {
    return struct {
        key: []const u8,
        open: bool,
        child: Child,
        on_close: ?Handler = null,
        close_on_backdrop: bool = true,
        backdrop: Color = Color.rgba(0, 0, 0, 0.5),
        content_max_width: ?f32 = 500,
        content_padding: f32 = 24,
        /// Defaults to the theme's surface.
        content_background: ?Color = null,
        /// Defaults to the theme's `radius_lg`.
        content_corner_radius: ?f32 = null,
        content_shadow: ?ui.Shadow = .{
            .blur = 24,
            .offset_y = 8,
            .color = .{ .rgba = Color.rgba(0, 0, 0, 0.25) },
        },
        /// The dialog's screen-reader name; defaults to the key.
        accessible_name: ?[]const u8 = null,
        accessible_description: ?[]const u8 = null,

        const Self = @This();

        pub fn render(self: Self, cx: *Cx) void {
            assert(self.key.len > 0);
            if (self.close_on_backdrop) assert(self.on_close != null);
            if (!self.open) return;
            const theme = cx.theme();
            const background = self.content_background orelse theme.surface;
            cx.render(ui.box(.{
                .key = .{ .name = self.key },
                .layer = .{ .kind = .modal, .anchor = .{ .window = .{} }, .clip = .escape },
                .style = .{
                    .width = .{ .grow = 1 },
                    .height = .{ .grow = 1 },
                    .background = .{ .rgba = self.backdrop },
                    .alignment = .center,
                },
                .a11y = .{
                    .role = .dialog,
                    .label = self.accessible_name orelse self.key,
                    .description = self.accessible_description,
                },
            }, .{ui.box(.{
                .key = .{ .name = "panel" },
                .style = .{
                    .width_max = self.content_max_width,
                    .padding = .all(self.content_padding),
                    .background = .{ .rgba = background },
                    .corner_radius = .all(self.content_corner_radius orelse theme.radius_lg),
                    .shadow = self.content_shadow,
                },
                .on_click_outside = if (self.close_on_backdrop) self.on_close else null,
            }, .{self.child})}));
        }
    };
}

// =============================================================================
// List
// =============================================================================

/// A vertical list of `count` rows that builds only the rows in view
/// (contract §1): a keyed scroll box whose retained offset and last measured
/// viewport pick the rows, with spacers above and below standing in for the
/// rest so the wheel and scrollbar see every row. `Row` has an `index: u32`
/// field and a `render`, and declares its heights one of two ways:
///
/// - `row_height: f32`, one height for every row, as 0.3.1's uniform list.
///   The rows in view follow from the offset in constant time.
/// - `fn height(cx: *Cx, index: u32, width: f32) f32` and `count_max: u32`,
///   a height per row, as 0.3.1's virtual list. `width` is the row's width,
///   the viewport's less the list's padding (0 before the first emit), so a
///   row can size from its content with `cx.measureText`. Each render sums
///   every row's height, so `count_max` bounds that work; a longer list
///   fails fast.
///
/// Each row sits in a box keyed by its index, so state a row keys survives
/// scrolling. `gap` separates rows, and `style` dresses the scroll box
/// (background, border, corners, padding). The list grows to fill its
/// parent: a viewport sized by its rows would add one row per frame.
/// `anchor = .end` keeps it at its last row while it is there, as
/// `Scroll.anchor` does, and `scrollTo` brings a row into view from a
/// handler; either builds the rows it lands on in the same frame.
pub fn List(comptime Row: type) type {
    comptime {
        assert(@FieldType(Row, "index") == u32);
        assert(@hasDecl(Row, "row_height") != @hasDecl(Row, "height"));
        if (@hasDecl(Row, "row_height")) assert(Row.row_height >= 1);
        if (@hasDecl(Row, "height")) assert(Row.count_max <= list_count_max);
    }
    return struct {
        key: []const u8,
        count: u32,
        gap: f32 = 0,
        style: ui.Style = .{},
        anchor: ui.ScrollAnchor = .start,

        const Self = @This();

        /// Bring row `index` of the list with id `list` into view, after
        /// the handler returns: `list` is `cx.id(.{ .name = key })` taken in
        /// the render that builds the list, under the same parent. An index
        /// past the last row moves nothing.
        pub fn scrollTo(
            effects: *gooey.Effects,
            list: gooey.ElementId,
            index: u32,
            alignment: ui.ScrollAlignment,
        ) void {
            assert(list.isKeyed());
            effects.scrollTo(list, .{ .child = .{
                .key = .{ .index = index },
                .alignment = alignment,
            } });
        }
        const uniform = @hasDecl(Row, "row_height");
        /// The most rows a list that sums row by row may hold.
        const sum_count_max: u32 = if (uniform) list_count_max else Row.count_max;

        pub fn render(self: Self, cx: *Cx) void {
            assert(self.key.len > 0);
            assert(self.gap >= 0);
            self.checkStyle();
            if (!(uniform and self.multiplies())) self.checkCount();
            const key = Key{ .name = self.key };
            // The offset and viewport the wheel, scrollbar, and last emit
            // left; none before the box first renders.
            const position = cx.scroll(cx.id(key)) orelse Cx.ScrollPosition{
                .offset_x = 0,
                .offset_y = 0,
                .viewport = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
                .target = null,
                .at_end = true,
            };
            const width = self.rowWidth(&position);
            const range = self.visibleRows(cx, &position, width);
            assert(range.start <= range.end);
            assert(range.end <= self.count);
            self.checkRowsVisible(cx, range.end - range.start);
            var style = self.style;
            style.width = .{ .grow = 1 };
            style.height = .{ .grow = 1 };
            style.scroll = .{ .anchor = self.anchor };
            cx.render(ui.box(.{ .key = key, .style = style }, .{
                spacer(range.above),
                ListRows(Row){
                    .start = range.start,
                    .end = range.end,
                    .count = self.count,
                    .gap = self.gap,
                    .width = width,
                },
                spacer(range.below),
            }));
        }

        /// The list owns the scroll box's size, scrolling, and row spacing.
        fn checkStyle(self: Self) void {
            assert(self.style.width == .fit);
            assert(self.style.height == .fit);
            assert(self.style.scroll == null);
            assert(self.style.gap == 0);
            assert(self.style.direction == .column);
        }

        /// Each row in view is at least one element (its keyed box), so
        /// the frame's element budget bounds the rows one build may emit.
        /// A viewport that shows more fails here, naming the list.
        fn checkRowsVisible(self: Self, cx: *Cx, rows_visible: u32) void {
            const element_count_max = cx.limits().build.element_count_frame_max;
            if (rows_visible <= element_count_max) return;
            std.debug.panic("List \"{s}\": {d} rows in view, more than " ++
                "build.element_count_frame_max {d}. Raise it or show fewer rows.", .{
                self.key, rows_visible, element_count_max,
            });
        }

        /// A list that sums row by row (`multiplies` is false) does so on
        /// every render, so its rows are bounded: `Row.count_max`, or
        /// `list_count_max` for uniform rows whose sums are inexact.
        fn checkCount(self: Self) void {
            if (self.count <= sum_count_max) return;
            if (uniform) {
                std.debug.panic("List \"{s}\" of {d} rows: rows {d} px with gap {d} do " ++
                    "not sum exactly in f32, which caps the list at {d} rows. Use a row " ++
                    "height and gap on a coarser grid, such as whole pixels.", .{
                    self.key, self.count, Row.row_height, self.gap, sum_count_max,
                });
            }
            std.debug.panic("List \"{s}\" of {d} rows: capacity {d}. Raise {s}.count_max.", .{
                self.key, self.count, sum_count_max, @typeName(Row),
            });
        }

        /// The rows from the first one the offset reaches through the last
        /// one the viewport shows, partial rows included, and the heights
        /// above and below them. An unmeasured viewport shows one row; the
        /// emit that measures it requests the render that fills it.
        fn visibleRows(
            self: Self,
            cx: *Cx,
            state: *const Cx.ScrollPosition,
            width: f32,
        ) ListRange {
            const padding = self.style.padding;
            const rows_height = self.contentHeight(cx, width);
            // `position_pass.resolveScrollTarget`'s `max_y`, operation for
            // operation, from the rows' exact height; layout's own end may
            // sit an ulp further (`belowSpacer`).
            const offset_max = @max(0, rows_height - viewHeight(self.style, state));
            const offset = self.offsetFor(cx, state, .{ .offset_max = offset_max, .width = width });
            const view_top = std.math.clamp(offset, 0, offset_max) - padding.top;
            const range = if (uniform and self.multiplies())
                uniformRows(view_top, state.viewport.height, self.count, self.gap)
            else
                self.variableRows(cx, .{
                    .top = view_top,
                    .height = state.viewport.height,
                    .width = width,
                });
            const end_top = if (uniform and self.multiplies())
                pitch(self.gap) * @as(f32, @floatFromInt(range.end))
            else
                range.below;
            const below = if (range.end == self.count) 0 else belowSpacer(end_top, rows_height);
            assert(range.above >= 0);
            assert(below >= 0);
            var result = range;
            result.below = below;
            return result;
        }

        /// Where the core's layout will put the offset this frame, so the
        /// rows it shows are the ones built: a pending `scrollTo` resolved
        /// as layout resolves it (`position_pass.resolveScrollTarget`), the
        /// end while an `.end` anchor is pinned, else the retained offset.
        fn offsetFor(
            self: Self,
            cx: *Cx,
            state: *const Cx.ScrollPosition,
            options: struct { offset_max: f32, width: f32 },
        ) f32 {
            const offset_max = options.offset_max;
            assert(offset_max >= 0);
            if (state.target) |target| switch (target) {
                .start => return 0,
                .end => return offset_max,
                .offset => |offset| return offset.y,
                .child => |child| {
                    const index = child.index orelse return state.offset_y;
                    if (index >= self.count) return state.offset_y;
                    const view = viewHeight(self.style, state);
                    const top = self.rowTop(cx, @intCast(index), options.width);
                    const height = self.rowBox(cx, @intCast(index), options.width);
                    return alignRow(child.alignment, top, height, view, state.offset_y);
                },
            };
            if (self.anchor == .end and state.at_end) return offset_max;
            return state.offset_y;
        }

        // Row tops and the rows' height are the sums layout makes: the
        // spacer above the window, then each row box in turn
        // (`position_pass.childSpan`, `sumChildrenAlongMainAxis`). f32
        // addition rounds, so a sum taken any other way, such as heights
        // and gaps added separately, can differ by an ulp; an `.end` or
        // `.child` target predicted from it then builds a window one row off
        // the one the resolved offset shows, and the next render moves the
        // rows. So the list adds row boxes one by one from the first row,
        // as layout does, unless `multiplies` proves the product exact.

        /// Row `index`'s top within the rows: the boxes above it, summed.
        fn rowTop(self: Self, cx: *Cx, index: u32, width: f32) f32 {
            assert(index < self.count);
            if (uniform and self.multiplies()) {
                return pitch(self.gap) * @as(f32, @floatFromInt(index));
            }
            var top: f32 = 0;
            var row: u32 = 0;
            while (row < index) : (row += 1) top += self.rowBox(cx, row, width);
            return top;
        }

        /// Every row box, summed.
        fn contentHeight(self: Self, cx: *Cx, width: f32) f32 {
            if (self.count == 0) return 0;
            const last = self.count - 1;
            if (uniform and self.multiplies()) {
                return pitch(self.gap) * @as(f32, @floatFromInt(last)) + Row.row_height;
            }
            return self.rowTop(cx, last, width) + self.rowBox(cx, last, width);
        }

        /// Row `index`'s box: the row and the gap below it, but for the
        /// last row, as `ListRows` sizes it.
        fn rowBox(self: Self, cx: *Cx, index: u32, width: f32) f32 {
            assert(index < self.count);
            const gap: f32 = if (index + 1 < self.count) self.gap else 0;
            return listRowHeight(Row, cx, index, width) + gap;
        }

        /// Whether a uniform list may multiply instead of summing: every
        /// sum of its boxes, `pitch` each and `row_height` for the last, is
        /// a whole number of steps of the finer of the two values' binary
        /// grids, under 2^24 steps, so f32 holds each exactly and the
        /// product has the bits layout's box-by-box sum has. Whole-pixel or
        /// half-pixel rows qualify up to millions of pixels.
        /// Callers test `uniform and` first, so a list of measured rows
        /// never compiles the product.
        fn multiplies(self: Self) bool {
            if (comptime !uniform) return false;
            if (self.count == 0) return true;
            const row_pitch = pitch(self.gap);
            const row_height: f32 = Row.row_height;
            if (row_pitch >= 1 << 24) return false;
            const grid = @min(gridExponent(row_pitch), gridExponent(row_height));
            const pitch_steps = std.math.ldexp(@as(f64, row_pitch), -grid);
            const height_steps = std.math.ldexp(@as(f64, row_height), -grid);
            const last: f64 = @floatFromInt(self.count - 1);
            // f64 holds the sum exactly near 2^24; a larger one may round
            // but stays far above the bound.
            return pitch_steps * last + height_steps < 1 << 24;
        }

        /// A row's width: the viewport's less the list's side padding.
        fn rowWidth(self: Self, state: *const Cx.ScrollPosition) f32 {
            const padding = self.style.padding;
            assert(state.viewport.width >= 0);
            const width = @max(0, state.viewport.width - padding.left - padding.right);
            assert(width <= state.viewport.width);
            return width;
        }

        fn pitch(gap: f32) f32 {
            return Row.row_height + gap;
        }

        /// The first row the view's top reaches through the last its height
        /// covers, plus one for a partial row. `below` is unset.
        fn uniformRows(view_top: f32, view_height: f32, count: u32, gap: f32) ListRange {
            const row_pitch = pitch(gap);
            const first: u32 = @intFromFloat(@floor(@max(0, view_top) / row_pitch));
            assert(view_height >= 0);
            const shown: u32 = @intFromFloat(@ceil(view_height / row_pitch));
            const start = @min(first, count);
            const end = @min(count, start + shown + 1);
            const above = row_pitch * @as(f32, @floatFromInt(start));
            return .{ .start = start, .end = end, .above = above, .below = 0 };
        }

        /// One scan from the first row: rows whose bottoms stay above the
        /// view are skipped, then rows are taken until one starts at or past
        /// the view's bottom, and always one. `below` carries the end row's
        /// top for `visibleRows` to subtract.
        fn variableRows(self: Self, cx: *Cx, view: ListView) ListRange {
            const count = self.count;
            assert(count <= sum_count_max);
            assert(view.height >= 0);
            var top: f32 = 0;
            var index: u32 = 0;
            while (index < count) : (index += 1) {
                const height = listRowHeight(Row, cx, index, view.width);
                if (top + height > view.top) break;
                top += self.rowBox(cx, index, view.width);
            }
            const start = index;
            const above = top;
            const view_bottom = view.top + view.height;
            while (index < count) : (index += 1) {
                if (index > start and top >= view_bottom) break;
                top += self.rowBox(cx, index, view.width);
            }
            return .{ .start = start, .end = index, .above = above, .below = top };
        }

        fn spacer(height: f32) ui.Box.Element(@TypeOf(.{})) {
            assert(height >= 0);
            return ui.box(.{ .style = .{ .height = .{ .fixed = height } } }, .{});
        }
    };
}

const ListRange = struct { start: u32, end: u32, above: f32, below: f32 };

/// The view a scroll target aligns in: the box's height less its vertical
/// padding, as layout's `content_box.height`, operation for operation.
fn viewHeight(style: ui.Style, state: *const Cx.ScrollPosition) f32 {
    assert(state.viewport.height >= 0);
    const padding = style.padding;
    return @max(0, state.viewport.height - (padding.top + padding.bottom));
}

/// The spacer below the window. Layout adds it to the boxes above it,
/// `end_top`, to find the rows' end and its `max_y`. f32 cannot always
/// land that sum on `rows_height`: when `end_top` carries half an ulp of
/// the sum, every spacer rounds to a neighbour. So the spacer is the
/// difference rounded up, which puts the end at `rows_height` or one ulp
/// past it, never short. The list's `offset_max`, from `rows_height`, is
/// then at most layout's `max_y`, and an offset layout clamps to its
/// `max_y` clamps to the same `offset_max` here: the target frame and
/// every rebuild after it choose the same rows.
fn belowSpacer(end_top: f32, rows_height: f32) f32 {
    assert(end_top >= 0);
    assert(end_top <= rows_height);
    // f64 holds the difference of two f32 values exactly unless their
    // exponents differ by more than 29, far past any list's rows.
    const exact = @as(f64, rows_height) - @as(f64, end_top);
    var below: f32 = @floatCast(exact);
    if (below < exact) below = std.math.nextAfter(f32, below, std.math.inf(f32));
    assert(below >= exact);
    assert(end_top + below >= rows_height);
    return below;
}

/// The exponent of `value`'s lowest set mantissa bit: `value` is a whole
/// number of steps of 2^exponent.
fn gridExponent(value: f32) i32 {
    assert(std.math.isNormal(value));
    assert(value > 0);
    const bits: u32 = @bitCast(value);
    const mantissa: u32 = (bits & 0x7f_ffff) | 0x80_0000;
    const exponent: i32 = @as(i32, @intCast(bits >> 23)) - 127 - 23;
    return exponent + @as(i32, @ctz(mantissa));
}

/// The list's view in row coordinates: its top past the first row, its
/// height, and the rows' width.
const ListView = struct { top: f32, height: f32, width: f32 };

/// The offset that shows a row box at `top`, `height` tall, in a view of
/// `view` px, as the core's layout aligns a scroll target's child.
fn alignRow(alignment: ui.ScrollAlignment, top: f32, height: f32, view: f32, current: f32) f32 {
    assert(height >= 0);
    assert(view >= 0);
    return switch (alignment) {
        .start => top,
        .center => top + height / 2 - view / 2,
        .end => top + height - view,
        .nearest => blk: {
            if (top < current or height > view) break :blk top;
            const overshoot = top + height - (current + view);
            break :blk if (overshoot > 0) current + overshoot else current;
        },
    };
}

/// The longest list of per-row heights: each render sums them all, and
/// 65,536 calls stay well inside a frame.
pub const list_count_max: u32 = 65_536;

fn listRowHeight(comptime Row: type, cx: *Cx, index: u32, width: f32) f32 {
    assert(width >= 0);
    const height: f32 = if (@hasDecl(Row, "row_height"))
        Row.row_height
    else
        Row.height(cx, index, width);
    assert(height >= 0);
    return height;
}

/// The rows in view, each in a box keyed by its index and as tall as the
/// row plus the gap below it; the last row has no gap below.
fn ListRows(comptime Row: type) type {
    return struct {
        start: u32,
        end: u32,
        count: u32,
        gap: f32,
        /// The rows' width, which `Row.height` measures against.
        width: f32,

        pub fn render(self: @This(), cx: *Cx) void {
            assert(self.start <= self.end);
            assert(self.end <= self.count);
            assert(self.end - self.start <= cx.limits().build.element_count_frame_max);
            var index = self.start;
            while (index < self.end) : (index += 1) {
                const gap: f32 = if (index + 1 < self.count) self.gap else 0;
                const height = listRowHeight(Row, cx, index, self.width);
                cx.render(ui.box(.{ .key = .{ .index = index }, .style = .{
                    .width = .{ .grow = 1 },
                    .height = .{ .fixed = height + gap },
                    .padding = .{ .bottom = gap },
                } }, .{Row{ .index = index }}));
            }
        }
    };
}

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
    /// Null fills the parent's free width, as `CodeEditor.width` does.
    width: ?f32 = 200,
    padding: f32 = 8,
    border_width: f32 = 1,
    /// The unfocused border, such as an error colour; defaults to the theme's.
    border_color: ?Color = null,
    /// The screen-reader name; defaults to the placeholder.
    accessible_name: ?[]const u8 = null,
    accessible_description: ?[]const u8 = null,

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
                .width = if (self.width) |width| .{ .fixed = width } else .{ .grow = 1 },
                .height = .{ .fixed = metrics.line_height + inset * 2 },
                .padding = .all(inset),
                .background = .surface,
                .border = .{
                    .width = self.border_width,
                    .color = if (focused)
                        .border_focus
                    else if (self.border_color) |color| .{ .rgba = color } else .border,
                },
                .corner_radius = .all(theme.radius_md),
                .cursor = .text,
            },
            .a11y = .{
                .role = .textbox,
                .label = self.accessible_name orelse self.placeholder,
                .description = self.accessible_description,
                .value = if (engine.len > 0) engine.text() else null,
                .selection = .{ .start = engine.selectionStart(), .end = engine.selectionEnd() },
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
    theme: *const gooey.Theme,
    id: gooey.ElementId,
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
    /// Null fills the parent's free width, as `TextInput.width` does. The
    /// text paints into the width laid out this frame, and nothing the
    /// build computes (scroll, caret row, accessibility value) depends on
    /// it, so a resize draws at the new width with no frame of lag.
    width: ?f32 = 300,
    rows: u16 = 4,
    padding: f32 = 8,
    border_width: f32 = 1,

    /// The scrollbar's width at the right edge, as in 0.3.1.
    const scrollbar_width: f32 = 8;

    pub fn render(self: TextArea, cx: *Cx) void {
        assert(self.key.len > 0);
        assert(self.rows > 0);
        if (self.width) |width| assert(width > 0);
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
                .width = if (self.width) |width| .{ .fixed = width } else .{ .grow = 1 },
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
                .selection = .{ .start = engine.selectionStart(), .end = engine.selectionEnd() },
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
    /// Null fills the parent's width, as 0.3.1's editor did.
    width: ?f32 = 500,
    /// Null fills the parent's height: the rows are what fit in the height
    /// the editor was laid out at last frame, so a resized window reflows on
    /// the next frame. Its first frame, before any layout, shows one row.
    rows: ?u16 = 10,
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
        if (self.rows) |rows| assert(rows > 0);
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
        const viewport_height = if (self.rows) |rows|
            line_height * @as(f32, @floatFromInt(rows))
        else
            self.filledViewportHeight(cx, id, line_height);
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
                .width = if (self.width) |width| .{ .fixed = width } else .{ .grow = 1 },
                .height = if (self.rows == null) .{ .grow = 1 } else .fit,
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
                .selection = .{ .start = engine.selectionStart(), .end = engine.selectionEnd() },
            },
        }, .{
            ui.box(.{ .style = .{
                .direction = .row,
                .width = .{ .grow = 1 },
                .height = if (self.rows == null)
                    .{ .grow = 1 }
                else
                    .{ .fixed = viewport_height + self.padding * 2 },
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

    /// The text's height when filling: the editor's laid-out height last
    /// frame less its border, padding, and status bar, in whole lines so no
    /// row draws past the border. One line before the first layout.
    ///
    /// The box's own size never depends on its rows (it grows), so this
    /// cannot oscillate. A build after a resize, or before any layout, reads
    /// a stale height, so it asks for exactly one more render: the next
    /// build reads the frame laid out at the new size and asks for none.
    fn filledViewportHeight(
        self: *const CodeEditor,
        cx: *Cx,
        id: gooey.ElementId,
        line_height: f32,
    ) f32 {
        assert(self.rows == null);
        assert(line_height > 0);
        // After a resize `bounds` asks for the render that reads the new size.
        const bounds = cx.bounds(id) orelse {
            cx.requestRenderAfter(0);
            return line_height;
        };
        var chrome = self.border_width * 2 + self.padding * 2;
        if (self.show_status_bar) chrome += self.status_bar_height + 1;
        const lines = @floor(@max(0, bounds.height - chrome) / line_height);
        return @max(1, lines) * line_height;
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

test {
    std.testing.refAllDecls(@This());
}

test "components compile against the gooey surface" {
    comptime {
        _ = Button;
        _ = Checkbox;
        _ = RadioGroup;
        _ = Tooltip(Button);
        _ = ContextMenu(Button);
        _ = TextInput;
        _ = TextArea;
        _ = CodeEditor;
    }
}
