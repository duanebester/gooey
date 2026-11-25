const std = @import("std");
const gooey = @import("gooey");
const Button = @import("gooey-components").Button;

const assert = std.debug.assert;
const ui = gooey.ui;
const Cx = gooey.Cx;
const Color = gooey.Color;
const animation = gooey.animation;

const Gloss = gooey.Shader(.{
    .name = "button_gloss",
    .Params = extern struct {
        hover: f32,
        _pad: [3]u32 = .{ 0, 0, 0 },
    },
    .source = .{ .msl = @embedFile("shaders/button_gloss.metal") },
});

const State = struct {
    hovered: bool = false,
    hover_from: f32 = 0,
    hover_amount: f32 = 0,
    activated: bool = false,

    fn activate(self: *State, _: *gooey.Effects) void {
        self.activated = !self.activated;
    }

    fn reset(self: *State, _: *gooey.Effects) void {
        self.activated = false;
    }
};

pub const App = gooey.App(State, render, .{
    .title = "Shader Button Hover",
    .width = 620,
    .height = 344,
    .limits = .nano,
    .theme = &gooey.Theme.catppuccin_macchiato,
    .shaders = &.{Gloss},
});

pub const main = App.main;

fn render(cx: *Cx) void {
    const state = cx.state(State);
    const silent = Color.rgb(0.61, 0.69, 0.77);
    cx.render(ui.box(.{ .style = .{
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .padding = .all(32),
        .gap = 20,
        .background = .{ .rgba = Color.rgb(0.045, 0.06, 0.09) },
    } }, .{
        ui.text("METAL   /   SHADER STUDY 01", .{
            .size = 13,
            .color = .{ .rgba = Color.rgb(0.43, 0.8, 0.86) },
        }),
        ui.text("Specular button", .{ .size = 32, .color = .{ .rgba = Color.white } }),
        ui.text("Move from Reset to Engage to sweep the light across the button.", .{
            .size = 15,
            .color = .{ .rgba = silent },
        }),
        ui.box(.{ .style = .{
            .direction = .row,
            .alignment = .center_cross,
            .gap = 18,
            .padding = .all(24),
            .background = .{ .rgba = Color.rgb(0.075, 0.10, 0.15) },
            .corner_radius = .all(18),
        } }, .{
            Button{ .label = "Reset", .variant = .secondary, .on_click = cx.on(State.reset, .{}) },
            GlossButton{},
        }),
        ui.text(if (state.activated) "Engaged" else "Ready   /   Tab to focus, Space to activate", .{
            .size = 14,
            .color = .{ .rgba = silent },
        }),
    }));
}

const GlossButton = struct {
    pub fn render(_: GlossButton, cx: *Cx) void {
        const key: gooey.Key = .{ .name = "engage" };
        const state = cx.state(State);
        const hovered = cx.hovered(cx.id(key));
        if (state.hovered != hovered) {
            state.hover_from = state.hover_amount;
            state.hovered = hovered;
        }
        const progress = animation.tweenOn(cx, .{ .name = "gloss" }, @intFromBool(hovered), .{
            .duration_ms = if (hovered) 460 else 360,
            .easing = animation.Easing.easeOutCubic,
        });
        const target: f32 = if (hovered) 1 else 0;
        state.hover_amount = state.hover_from + (target - state.hover_from) * progress;
        assert(state.hover_amount >= 0);
        assert(state.hover_amount <= 1);

        cx.render(ui.box(.{
            .key = key,
            .style = .{
                .width = .{ .fixed = 206 },
                .height = .{ .fixed = 60 },
                .alignment = .center,
                .fill = Gloss.fill(.{ .hover = state.hover_amount }),
                .corner_radius = .all(14),
                .border = .{ .width = 1, .color = .{ .rgba = Color.rgb(0.29, 0.54, 0.64) } },
                .cursor = .pointer,
            },
            .focusable = true,
            .on_click = cx.on(State.activate, .{}),
            .a11y = .{ .role = .button, .label = "Engage" },
        }, .{ui.text("Engage", .{ .size = 20, .color = .{ .rgba = Color.white } })}));
    }
};
