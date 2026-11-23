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

pub const Lucide = @import("lucide.zig").Lucide;

pub const Button = struct {
    label: []const u8,
    key: ?[]const u8 = null,
    variant: Variant = .primary,
    size: Size = .medium,
    disabled: bool = false,
    on_click: ?Handler = null,
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

pub const Checkbox = struct {
    checked: bool,
    on_click: ?Handler = null,
    key: ?Key = null,
    size: f32 = 18,
    label: ?[]const u8 = null,
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
            painter.svg(self.path, painter.bounds, .{ .fill = painter.theme().on_primary });
        }
    };

    const checkmark = Checkmark{ .path = "M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z" };
};

pub const Select = struct {
    key: []const u8,
    options: []const []const u8,
    on_select: []const Handler,
    selected: ?usize = null,
    placeholder: []const u8 = "Select...",
    disabled: bool = false,
    width: f32 = 200,
    padding: f32 = 10,
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
        const handle = cx.retain(SelectState, id, .frame, SelectState.init);
        const state = cx.get(SelectState, handle);
        state.root = id;
        const open = state.open and !self.disabled;
        const trigger_height = @as(f32, @floatFromInt(theme.font_size_base)) +
            self.padding * 2 + 4;
        cx.render(ui.box(.{
            .key = key,
            .style = .{
                .width = .{ .fixed = self.width },
                .corner_radius = .all(theme.radius_md),
            },
            .focusable = !self.disabled,
            .on_key = if (self.disabled) null else cx.on(SelectState.onKey, .{
                .entity = handle,
                .arg = self.keyArg(SelectState.on_combobox, open),
            }),
            .on_click = if (open) cx.on(SelectState.close, .{ .entity = handle }) else null,
            .on_click_outside = if (open) cx.on(SelectState.close, .{ .entity = handle }) else null,
            .a11y = .{
                .role = .combobox,
                .label = self.accessible_name orelse self.placeholder,
                .description = self.accessible_description,
                .value = self.displayText(),
                .expanded = open,
                .has_popup = true,
                .disabled = self.disabled,
            },
        }, .{
            SelectTrigger{
                .select = &self,
                .open = open,
                .height = trigger_height,
                .keys = handle,
            },
            if (open) SelectMenu{
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

    fn keyArg(self: *const Select, focused: u16, open: bool) SelectState.Arg {
        assert(self.options.len <= select_option_count_max);
        const start = self.selected orelse 0;
        return .{
            .focused = focused,
            .count = @intCast(self.options.len),
            .start = @intCast(start),
            .open = open,
        };
    }
};

pub const select_option_count_max: u32 = 1024;

const SelectState = struct {
    root: ElementId,
    open: bool,

    const on_combobox: u16 = std.math.maxInt(u16);

    const Arg = packed struct(u64) {
        focused: u16,
        count: u16,
        start: u16,
        open: bool,
        padding: u15 = 0,
    };

    comptime {
        assert(select_option_count_max < on_combobox);
    }

    fn init(self: *SelectState) void {
        self.* = .{ .root = .root, .open = false };
    }

    fn openMenu(self: *SelectState, effects: *Effects) void {
        assert(self.root.isKeyed());
        self.open = true;
        effects.requestRender();
    }

    fn close(self: *SelectState, effects: *Effects) void {
        self.open = false;
        effects.requestRender();
    }

    fn trigger(self: *const SelectState) ElementId {
        assert(self.root.isKeyed());
        return self.root.child(.{ .name = "trigger" });
    }

    fn option(self: *const SelectState, index: u16) ElementId {
        assert(self.root.isKeyed());
        assert(index < select_option_count_max);
        return self.root.child(.{ .name = "menu" }).child(.{ .index = index });
    }

    fn onKey(self: *SelectState, arg: Arg, effects: *Effects) void {
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

    fn comboboxKey(self: *SelectState, arg: Arg, key: KeyCode, effects: *Effects) void {
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
            .tab => if (arg.open) {
                effects.click(self.trigger());
                effects.focus(self.root);
            },
            else => {},
        }
    }

    fn optionKey(self: *SelectState, arg: Arg, key: KeyCode, effects: *Effects) void {
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
                self.close(effects);
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
    open: bool,
    height: f32,
    keys: gooey.Handle(SelectState),

    pub fn render(self: SelectTrigger, cx: *Cx) void {
        const select = self.select;
        assert(self.height > 0);
        const theme = cx.theme();
        const key = Key{ .name = "trigger" };
        const hovered = !select.disabled and cx.hovered(cx.id(key));
        const opacity: f32 = if (select.disabled) 0.6 else 1;
        const background = if (hovered) theme.overlay else theme.surface;
        const text_color = if (select.selected == null) theme.muted else theme.text;
        const chevron = &chevrons[@intFromBool(self.open)][@intFromBool(select.disabled)];
        var on_click: ?Handler = null;
        if (!select.disabled) {
            on_click = if (self.open)
                cx.on(SelectState.close, .{ .entity = self.keys })
            else
                cx.on(SelectState.openMenu, .{ .entity = self.keys });
        }
        cx.render(ui.box(.{
            .key = key,
            .style = .{
                .width = .{ .grow = 1 },
                .height = .{ .fixed = self.height },
                .padding = .symmetric(select.padding, select.padding / 2),
                .background = .{ .rgba = background.withAlpha(opacity) },
                .border = .{ .width = 1, .color = if (self.open) .border_focus else .border },
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
    keys: gooey.Handle(SelectState),

    pub fn render(self: SelectMenu, cx: *Cx) void {
        const select = self.select;
        assert(!select.disabled);
        const theme = cx.theme();
        cx.render(ui.box(.{
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
    keys: gooey.Handle(SelectState),

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
                .focusable = true,
                .tab_stop = false,
                .on_click = handler,
                .on_key = cx.on(SelectState.onKey, .{
                    .entity = self.keys,
                    .arg = select.keyArg(position, true),
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

pub const RadioGroup = struct {
    key: []const u8,
    options: []const []const u8,
    on_select: []const Handler,
    selected: ?usize = null,
    label: ?[]const u8 = null,
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
                .key = .{ .name = "options" },
                .style = .{ .gap = 8 },
            }, .{RadioOptions{ .group = &self, .keys = handle }}),
        }));
    }
};

pub const radio_option_count_max: u32 = 256;

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

pub const Switch = struct {
    checked: bool,
    on_click: ?Handler = null,
    key: ?Key = null,
    label: ?[]const u8 = null,
    disabled: bool = false,
    accessible_name: ?[]const u8 = null,
    accessible_description: ?[]const u8 = null,

    const track_width: f32 = 40;
    const track_height: f32 = 22;
    const thumb_inset: f32 = 2;
    const thumb_size: f32 = track_height - thumb_inset * 2;

    comptime {
        assert(thumb_size > 0);
        assert(track_width > thumb_size * 2);
    }

    pub fn render(self: Switch, cx: *Cx) void {
        assert(self.accessible_name != null or self.label != null);
        if (self.label) |label| assert(label.len > 0);
        const theme = cx.theme();
        const interactive = !self.disabled and self.on_click != null;
        const hovered = if (self.key) |key| interactive and cx.hovered(cx.id(key)) else false;
        const off_color = theme.muted.withAlpha(0.5);
        const track_color = if (self.checked) theme.primary else off_color;
        const track_fill = if (hovered) track_color.withAlpha(0.85) else track_color;
        cx.render(ui.box(.{
            .key = self.key,
            .style = .{
                .direction = .row,
                .gap = 10,
                .alignment = .center_cross,
                .corner_radius = .all(track_height / 2),
                .cursor = if (interactive) .pointer else null,
                .opacity = if (self.disabled) 0.5 else 1,
            },
            .focusable = interactive,
            .on_click = if (interactive) self.on_click else null,
            .a11y = .{
                .role = .switch_,
                .label = self.accessible_name orelse self.label,
                .description = self.accessible_description,
                .checked = self.checked,
                .disabled = self.disabled,
            },
        }, .{
            ui.box(.{ .style = .{
                .width = .{ .fixed = track_width },
                .height = .{ .fixed = track_height },
                .padding = .all(thumb_inset),
                .background = .{ .rgba = track_fill },
                .corner_radius = .all(track_height / 2),
                .direction = .row,
                .alignment = .{ .main = if (self.checked) .end else .start, .cross = .center },
            } }, .{
                ui.box(.{ .style = .{
                    .width = .{ .fixed = thumb_size },
                    .height = .{ .fixed = thumb_size },
                    .background = .{ .rgba = theme.on_primary },
                    .corner_radius = .all(thumb_size / 2),
                    .shadow = .{ .blur = 3, .offset_y = 1 },
                } }, .{}),
            }),
            if (self.label) |label| ui.text(label, .{
                .size = theme.font_size_base,
                .color = .text,
            }) else null,
        }));
    }
};

pub const Slider = struct {
    key: []const u8,
    bind: *f32,
    min: f32 = 0,
    max: f32 = 100,
    step: ?f32 = null,
    disabled: bool = false,
    width: f32 = 200,
    accessible_name: ?[]const u8 = null,
    accessible_description: ?[]const u8 = null,

    pub fn render(self: Slider, cx: *Cx) void {
        self.check();
        const key = Key{ .name = self.key };
        const id = cx.id(key);
        const handle = cx.retain(SliderState, id, .frame, SliderState.init);
        const state = cx.get(SliderState, handle);
        state.sync(id, &self);
        const value = self.bind.*;
        const lit = !self.disabled and (state.dragging or cx.hovered(id));
        var text: [slider_value_bytes_max]u8 = undefined;
        const decimals = sliderDecimals(self.step, self.max - self.min);
        cx.render(ui.box(.{
            .key = key,
            .style = .{
                .width = .{ .fixed = self.width },
                .height = .{ .fixed = slider_thumb_size },
                .direction = .row,
                .alignment = .center_cross,
                .corner_radius = .all(slider_thumb_size / 2),
                .cursor = if (self.disabled) null else .pointer,
                .opacity = if (self.disabled) 0.5 else 1,
            },
            .focusable = !self.disabled,
            .on_key = if (self.disabled) null else cx.on(SliderState.onKey, .{ .entity = handle }),
            .on_pointer_drag = if (self.disabled)
                null
            else
                cx.on(SliderState.onDrag, .{ .entity = handle }),
            .a11y = .{
                .role = .slider,
                .label = self.accessible_name,
                .description = self.accessible_description,
                .value = sliderValueText(&text, value, decimals),
                .range = .{
                    .min = self.min,
                    .max = self.max,
                    .now = value,
                    .orientation = .horizontal,
                },
                .disabled = self.disabled,
            },
        }, .{SliderTrack{
            .before = (self.width - slider_thumb_size) * sliderFraction(value, self.min, self.max),
            .travel = self.width - slider_thumb_size,
            .lit = lit,
        }}));
    }

    fn check(self: *const Slider) void {
        assert(self.key.len > 0);
        assert(self.accessible_name != null);
        assert(std.math.isFinite(self.min));
        assert(std.math.isFinite(self.max));
        assert(self.min < self.max);
        assert(self.width > slider_thumb_size);
        if (self.step) |step| {
            assert(step > 0);
            assert(step <= self.max - self.min);
        }
        const value = self.bind.*;
        assert(value >= self.min);
        assert(value <= self.max);
    }
};

const slider_thumb_size: f32 = 20;
const slider_track_height: f32 = 6;
const slider_value_bytes_max: u32 = 48;
const slider_decimals_max: u8 = 3;

comptime {
    assert(slider_track_height < slider_thumb_size);
    assert(39 + 2 + slider_decimals_max <= slider_value_bytes_max);
}

const SliderState = struct {
    root: ElementId,
    bind: ?*f32,
    scale: SliderScale,
    drag_start: f32,
    dragging: bool,
    disabled: bool,

    comptime {
        assert(@sizeOf(SliderState) <= 64);
    }

    fn init(self: *SliderState) void {
        self.* = .{
            .root = .root,
            .bind = null,
            .scale = .{ .min = 0, .max = 1, .step = 0 },
            .drag_start = 0,
            .dragging = false,
            .disabled = false,
        };
    }

    fn sync(self: *SliderState, id: ElementId, slider: *const Slider) void {
        assert(id.isKeyed());
        assert(slider.min < slider.max);
        self.root = id;
        self.bind = slider.bind;
        self.scale = .{ .min = slider.min, .max = slider.max, .step = slider.step orelse 0 };
        self.disabled = slider.disabled;
        if (slider.disabled) self.dragging = false;
        assert(self.scale.step >= 0);
    }

    fn onKey(self: *SliderState, effects: *Effects) void {
        assert(self.root.isKeyed());
        assert(self.scale.min < self.scale.max);
        if (self.disabled) return;
        const event = effects.inputEvent() orelse return;
        if (event.* != .key_down) return;
        const key = event.key_down;
        if (key.modifiers.cmd or key.modifiers.ctrl or key.modifiers.alt) return;
        const bind = self.bind.?;
        const page = self.scale.pageStops();
        bind.* = switch (key.key) {
            .right, .up => self.scale.move(bind.*, 1),
            .left, .down => self.scale.move(bind.*, -1),
            .page_up => self.scale.move(bind.*, page),
            .page_down => self.scale.move(bind.*, -page),
            .home => self.scale.min,
            .end => self.scale.snap(self.scale.max),
            else => return,
        };
        assert(bind.* >= self.scale.min);
        assert(bind.* <= self.scale.max);
        effects.stopPropagation();
    }

    fn onDrag(self: *SliderState, effects: *Effects) void {
        assert(self.root.isKeyed());
        const drag = effects.pointerDrag() orelse return;
        if (drag.button != .left) return;
        if (self.disabled) return;
        const bind = self.bind.?;
        switch (drag.phase) {
            .begin => {
                self.drag_start = bind.*;
                self.dragging = true;
                bind.* = self.valueAt(effects, drag.x) orelse bind.*;
            },
            .move, .end => {
                if (!self.dragging) return;
                bind.* = self.valueAt(effects, drag.x) orelse bind.*;
                self.dragging = drag.phase == .move;
            },
            .cancel => {
                if (self.dragging) bind.* = self.drag_start;
                self.dragging = false;
            },
        }
        assert(bind.* >= self.scale.min);
        assert(bind.* <= self.scale.max);
    }

    fn valueAt(self: *const SliderState, effects: *const Effects, x: f32) ?f32 {
        assert(std.math.isFinite(x));
        const bounds = effects.bounds(self.root) orelse return null;
        const travel = bounds.width - slider_thumb_size;
        if (travel <= 0) return null;
        const offset = x - bounds.x - slider_thumb_size / 2;
        const fraction = std.math.clamp(offset / travel, 0, 1);
        return self.scale.snap(self.scale.min + fraction * (self.scale.max - self.scale.min));
    }
};

const SliderScale = struct {
    min: f32,
    max: f32,
    step: f32,

    const stop_tolerance: f32 = 1e-3;
    const continuous_stop_count: f32 = 100;

    fn unit(self: SliderScale) f32 {
        assert(self.min < self.max);
        assert(self.step >= 0);
        if (self.step > 0) return self.step;
        return (self.max - self.min) / continuous_stop_count;
    }

    fn last(self: SliderScale) f32 {
        const stops = @floor((self.max - self.min) / self.unit() + stop_tolerance);
        assert(stops >= 1);
        return stops;
    }

    fn pageStops(self: SliderScale) f32 {
        const stops = @max(1, @round(self.last() / 10));
        assert(stops <= self.last());
        return stops;
    }

    fn snap(self: SliderScale, value: f32) f32 {
        assert(std.math.isFinite(value));
        const clamped = std.math.clamp(value, self.min, self.max);
        if (self.step == 0) return clamped;
        const index = std.math.clamp(@round((clamped - self.min) / self.step), 0, self.last());
        return self.stop(index);
    }

    fn move(self: SliderScale, value: f32, count: f32) f32 {
        assert(std.math.isFinite(value));
        assert(count != 0);
        if (self.step == 0) {
            return std.math.clamp(value + count * self.unit(), self.min, self.max);
        }
        var position = (value - self.min) / self.step;
        if (@abs(position - @round(position)) < stop_tolerance) position = @round(position);
        const from = if (count > 0) @floor(position) else @ceil(position);
        return self.stop(std.math.clamp(from + count, 0, self.last()));
    }

    fn stop(self: SliderScale, index: f32) f32 {
        assert(self.step > 0);
        assert(index >= 0);
        assert(index <= self.last());
        const value = @min(self.min + index * self.step, self.max);
        assert(value >= self.min);
        return value;
    }
};

fn sliderFraction(value: f32, min: f32, max: f32) f32 {
    assert(min < max);
    assert(value >= min);
    assert(value <= max);
    const fraction = (value - min) / (max - min);
    assert(fraction >= 0);
    assert(fraction <= 1);
    return fraction;
}

fn sliderDecimals(step: ?f32, range: f32) u8 {
    assert(range > 0);
    const size = step orelse {
        if (range >= 100) return 0;
        return if (range >= 10) 1 else 2;
    };
    assert(size > 0);
    var scaled = size;
    var decimals: u8 = 0;
    while (decimals < slider_decimals_max) : (decimals += 1) {
        if (@abs(scaled - @round(scaled)) < 1e-3) break;
        scaled *= 10;
    }
    assert(decimals <= slider_decimals_max);
    return decimals;
}

fn sliderValueText(buffer: *[slider_value_bytes_max]u8, value: f32, decimals: u8) []const u8 {
    assert(std.math.isFinite(value));
    assert(decimals <= slider_decimals_max);
    comptime assert(std.fmt.count("{d:.[1]}", .{
        -std.math.floatMax(f32),
        slider_decimals_max,
    }) <= slider_value_bytes_max);
    const text = std.fmt.bufPrint(buffer, "{d:.[1]}", .{ value, decimals }) catch unreachable;
    assert(text.len > 0);
    return text;
}

const SliderTrack = struct {
    before: f32,
    travel: f32,
    lit: bool,

    pub fn render(self: SliderTrack, cx: *Cx) void {
        assert(self.travel > 0);
        assert(self.before >= 0);
        assert(self.before <= self.travel);
        const theme = cx.theme();
        const glow = theme.primary.withAlpha(0.45);
        cx.render(ui.box(.{ .style = .{
            .width = .{ .fixed = self.before },
            .height = .{ .fixed = slider_track_height },
            .background = .primary,
            .corner_radius = .all(slider_track_height / 2),
        } }, .{}));
        cx.render(ui.box(.{ .style = .{
            .width = .{ .fixed = slider_thumb_size },
            .height = .{ .fixed = slider_thumb_size },
            .background = .{ .rgba = theme.on_primary },
            .border = .{ .width = 2, .color = .primary },
            .corner_radius = .all(slider_thumb_size / 2),
            .shadow = if (self.lit)
                .{ .blur = 8, .color = .{ .rgba = glow } }
            else
                .{ .blur = 3, .offset_y = 1 },
        } }, .{}));
        cx.render(ui.box(.{ .style = .{
            .width = .{ .fixed = self.travel - self.before },
            .height = .{ .fixed = slider_track_height },
            .background = .{ .rgba = theme.muted.withAlpha(0.35) },
            .corner_radius = .all(slider_track_height / 2),
        } }, .{}));
    }
};

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

pub const tooltip_delay_ms_default: u32 = 500;
const tooltip_gap: f32 = 4;

const TooltipState = struct {
    hover_since_ns: ?u64,
    wait_ms: ?u32,
    shown: bool,
    dismissed: bool,

    const Inputs = struct { hovered: bool, focused: bool, now_ns: u64, delay_ns: u64 };

    fn init(self: *TooltipState) void {
        self.* = .{ .hover_since_ns = null, .wait_ms = null, .shown = false, .dismissed = false };
    }

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
                const wait_ms = @divFloor(wait_ns - 1, std.time.ns_per_ms) + 1;
                assert(wait_ms <= std.math.maxInt(u32));
                self.wait_ms = @intCast(wait_ms);
            }
        }
        self.shown = !self.dismissed and (inputs.focused or rested);
        if (self.shown or self.dismissed) self.wait_ms = null;
        if (self.shown) assert(!self.dismissed);
        return self.shown;
    }

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

pub const MenuItem = struct {
    label: []const u8 = "",
    on_select: ?Handler = null,
    shortcut: ?[]const u8 = null,
    disabled: bool = false,
    danger: bool = false,
    separator: bool = false,

    fn enabled(self: *const MenuItem) bool {
        return !self.separator and !self.disabled and self.on_select != null;
    }
};

pub fn ContextMenu(comptime Child: type) type {
    return struct {
        key: []const u8,
        items: []const MenuItem,
        child: Child,
        width_min: f32 = 180,
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

pub const menu_item_count_max: u32 = 64;

fn enabledMask(items: []const MenuItem) u64 {
    assert(items.len <= menu_item_count_max);
    var mask: u64 = 0;
    for (items, 0..) |*item, index| {
        if (item.enabled()) mask |= @as(u64, 1) << @intCast(index);
    }
    return mask;
}

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

    fn pick(self: *const MenuState, index: u32) ElementId {
        return self.row(index).child(.{ .name = "pick" });
    }

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

    fn dismiss(self: *MenuState, effects: *Effects) void {
        self.shown = false;
        effects.requestRender();
    }

    fn close(self: *MenuState, effects: *Effects) void {
        self.shown = false;
        if (self.restore == .root) effects.blur() else effects.focus(self.restore);
        effects.requestRender();
    }

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
        content_background: ?Color = null,
        content_corner_radius: ?f32 = null,
        content_shadow: ?ui.Shadow = .{
            .blur = 24,
            .offset_y = 8,
            .color = .{ .rgba = Color.rgba(0, 0, 0, 0.25) },
        },
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
        const sum_count_max: u32 = if (uniform) list_count_max else Row.count_max;

        pub fn render(self: Self, cx: *Cx) void {
            assert(self.key.len > 0);
            assert(self.gap >= 0);
            self.checkStyle();
            if (!(uniform and self.multiplies())) self.checkCount();
            const key = Key{ .name = self.key };
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

        fn checkStyle(self: Self) void {
            assert(self.style.width == .fit);
            assert(self.style.height == .fit);
            assert(self.style.scroll == null);
            assert(self.style.gap == 0);
            assert(self.style.direction == .column);
        }

        fn checkRowsVisible(self: Self, cx: *Cx, rows_visible: u32) void {
            const element_count_max = cx.limits().build.element_count_frame_max;
            if (rows_visible <= element_count_max) return;
            std.debug.panic("List \"{s}\": {d} rows in view, more than " ++
                "build.element_count_frame_max {d}. Raise it or show fewer rows.", .{
                self.key, rows_visible, element_count_max,
            });
        }

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

        fn visibleRows(
            self: Self,
            cx: *Cx,
            state: *const Cx.ScrollPosition,
            width: f32,
        ) ListRange {
            const padding = self.style.padding;
            const rows_height = self.contentHeight(cx, width);
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

        fn contentHeight(self: Self, cx: *Cx, width: f32) f32 {
            if (self.count == 0) return 0;
            const last = self.count - 1;
            if (uniform and self.multiplies()) {
                return pitch(self.gap) * @as(f32, @floatFromInt(last)) + Row.row_height;
            }
            return self.rowTop(cx, last, width) + self.rowBox(cx, last, width);
        }

        fn rowBox(self: Self, cx: *Cx, index: u32, width: f32) f32 {
            assert(index < self.count);
            const gap: f32 = if (index + 1 < self.count) self.gap else 0;
            return listRowHeight(Row, cx, index, width) + gap;
        }

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
            return pitch_steps * last + height_steps < 1 << 24;
        }

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

fn viewHeight(style: ui.Style, state: *const Cx.ScrollPosition) f32 {
    assert(state.viewport.height >= 0);
    const padding = style.padding;
    return @max(0, state.viewport.height - (padding.top + padding.bottom));
}

fn belowSpacer(end_top: f32, rows_height: f32) f32 {
    assert(end_top >= 0);
    assert(end_top <= rows_height);
    const exact = @as(f64, rows_height) - @as(f64, end_top);
    var below: f32 = @floatCast(exact);
    if (below < exact) below = std.math.nextAfter(f32, below, std.math.inf(f32));
    assert(below >= exact);
    assert(end_top + below >= rows_height);
    return below;
}

fn gridExponent(value: f32) i32 {
    assert(std.math.isNormal(value));
    assert(value > 0);
    const bits: u32 = @bitCast(value);
    const mantissa: u32 = (bits & 0x7f_ffff) | 0x80_0000;
    const exponent: i32 = @as(i32, @intCast(bits >> 23)) - 127 - 23;
    return exponent + @as(i32, @ctz(mantissa));
}

const ListView = struct { top: f32, height: f32, width: f32 };

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

fn ListRows(comptime Row: type) type {
    return struct {
        start: u32,
        end: u32,
        count: u32,
        gap: f32,
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

pub const TextInput = struct {
    key: []const u8,
    bind: *[]const u8,
    placeholder: []const u8 = "",
    width: ?f32 = 200,
    padding: f32 = 8,
    border_width: f32 = 1,
    border_color: ?Color = null,
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
        const engine_actions = EngineActions.of(cx, InputEngine, handle, engine.hasSelection());
        const focused = cx.focused(id);
        setView(&engine.view, theme, id, self.placeholder);
        engine.blink(cx, focused);
        const inset = self.padding + self.border_width;
        const metrics = cx.fontMetrics();
        cx.render(ui.box(.{
            .key = key,
            .focusable = true,
            .on_key = cx.on(InputEngine.onKey, .{ .entity = handle }),
            .key_context = gooey.keymaps.context_input,
            .actions = engine_actions.slice(),
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

const EngineActions = struct {
    items: [engine_action_count_max]ui.ActionBinding,
    len: u32,

    const engine_action_count_max: u32 = 7;

    fn of(cx: *Cx, comptime E: type, handle: anytype, has_selection: bool) EngineActions {
        const handler = cx.on(E.onAction, .{ .entity = handle });
        var result: EngineActions = .{ .items = undefined, .len = 0 };
        const always = [_]u64{
            ui.action(gooey.actions.TextCommand),
            ui.action(gooey.actions.Undo),
            ui.action(gooey.actions.Redo),
            ui.action(gooey.actions.SelectAll),
            ui.action(gooey.actions.Paste),
        };
        for (always) |id| result.push(id, handler);
        if (has_selection) {
            result.push(ui.action(gooey.actions.Copy), handler);
            result.push(ui.action(gooey.actions.Cut), handler);
        }
        assert(result.len >= always.len);
        assert(result.len <= engine_action_count_max);
        return result;
    }

    fn push(self: *EngineActions, id: u64, handler: Handler) void {
        assert(self.len < engine_action_count_max);
        self.items[self.len] = .{ .action = id, .handler = handler };
        self.len += 1;
    }

    fn slice(self: *const EngineActions) []const ui.ActionBinding {
        assert(self.len <= engine_action_count_max);
        return self.items[0..self.len];
    }
};

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

pub const TextArea = struct {
    key: []const u8,
    bind: *[]const u8,
    placeholder: []const u8 = "",
    width: ?f32 = 300,
    rows: u16 = 4,
    padding: f32 = 8,
    border_width: f32 = 1,

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
        const engine_actions = EngineActions.of(cx, AreaEngine, handle, engine.hasSelection());
        engine.follow(line_height, viewport_height);
        engine.blink(cx, focused);
        cx.render(ui.box(.{
            .key = key,
            .focusable = true,
            .on_key = cx.on(AreaEngine.onKey, .{ .entity = handle }),
            .key_context = gooey.keymaps.context_area,
            .actions = engine_actions.slice(),
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

    fn paintArea(engine: *const AreaEngine, painter: *ui.Painter) void {
        paintText(engine, painter);
    }

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

pub const CodeEditor = struct {
    key: []const u8,
    bind: *[]const u8,
    placeholder: []const u8 = "",
    width: ?f32 = 500,
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
        const separator: f32 = if (gutter > 0) 1 else 0;
        engine.resolveClick(cx, .{
            .text_x = self.border_width + gutter + separator + self.padding,
            .text_y = self.border_width + self.padding,
            .gutter_end = self.border_width + gutter,
        });
        const engine_actions = EngineActions.of(cx, EditorEngine, handle, engine.hasSelection());
        engine.follow(line_height, viewport_height);
        engine.blink(cx, focused);
        cx.render(ui.box(.{
            .key = key,
            .focusable = true,
            .on_key = cx.on(EditorEngine.onKey, .{ .entity = handle }),
            .key_context = gooey.keymaps.context_editor,
            .actions = engine_actions.slice(),
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

    fn filledViewportHeight(
        self: *const CodeEditor,
        cx: *Cx,
        id: gooey.ElementId,
        line_height: f32,
    ) f32 {
        assert(self.rows == null);
        assert(line_height > 0);
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

    fn separatorBox(direction: enum { vertical, horizontal }) ui.Box.Element(@TypeOf(.{})) {
        const thickness = ui.Sizing{ .fixed = 1 };
        const span = ui.Sizing{ .grow = 1 };
        return ui.box(.{ .style = .{
            .width = if (direction == .vertical) thickness else span,
            .height = if (direction == .vertical) span else thickness,
            .background = .border,
        } }, .{});
    }

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
            comptime assert(std.fmt.count("{d}", .{std.math.maxInt(u32)}) <= buffer.len);
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

    const StatusBar = struct {
        editor: *const CodeEditor,
        engine: *const EditorEngine,

        pub fn render(self: StatusBar, cx: *Cx) void {
            const engine = self.engine;
            const line = engine.lineOf(engine.cursor) + 1;
            const column = engine.cursor - engine.lineStart(engine.cursor) + 1;
            var position_buffer: [32]u8 = undefined;
            var indent_buffer: [16]u8 = undefined;
            comptime assert(std.fmt.count("Ln {d}, Col {d}", .{
                std.math.maxInt(u32),
                std.math.maxInt(u32),
            }) <= position_buffer.len);
            const position = std.fmt.bufPrint(&position_buffer, "Ln {d}, Col {d}", .{
                line,
                column,
            }) catch unreachable;
            const indent_name = if (self.editor.use_hard_tabs) "Tab" else "Spaces";
            comptime assert(std.fmt.count("Spaces: {d}", .{
                std.math.maxInt(u8),
            }) <= indent_buffer.len);
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
        _ = Switch;
        _ = Slider;
        _ = Tooltip(Button);
        _ = ContextMenu(Button);
        _ = TextInput;
        _ = TextArea;
        _ = CodeEditor;
    }
}
