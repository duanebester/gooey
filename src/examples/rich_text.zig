const std = @import("std");
const gooey = @import("gooey");

const ui = gooey.ui;
const Cx = gooey.Cx;
const Color = ui.Color;

pub const State = struct {
    opened: u32 = 0,

    pub fn open(self: *State) void {
        self.opened += 1;
    }
};

pub const App = gooey.App(State, render, .{
    .title = "Rich text",
    .width = 640,
    .height = 520,
    .limits = limits,
    .fonts = .{ .mono = .{ .system = .monospace } },
});

// Inline code and the log line use `.mono`, so the app loads a monospace family with the
// two weights its spans ask for.
const limits = blk: {
    var value = gooey.ResourceLimits.standard;
    value.text.fonts.mono_variants = &.{ .regular, .bold };
    break :blk value;
};

pub const main = App.main;

const page: Color = .hex(0xF1F5F9);
const card: Color = .hex(0xFFFFFF);
const line: Color = .hex(0xE2E8F0);
const ink: Color = .hex(0x0F172A);
const muted: Color = .hex(0x64748B);
const mention: Color = .hex(0x2563EB);
const code_fill: Color = .hex(0xE2E8F0);
const danger: Color = .hex(0xDC2626);
const success: Color = .hex(0x16A34A);

const ink_token: ui.ColorToken = .{ .rgba = ink };

pub fn render(cx: *Cx) void {
    cx.render(ui.box(.{ .style = .{
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .background = .{ .rgba = page },
        .padding = .all(16),
        .gap = 12,
    } }, .{
        Panel{ .heading = "Chat message", .body = &chat },
        Panel{ .heading = "Markdown paragraph", .body = &markdown },
        Panel{ .heading = "Log line", .body = &log },
        Panel{ .heading = "Links", .body = &links(cx) },
        Panel{ .heading = "Truncated cell", .body = &cell, .width = 260 },
    }));
}

const chat = [_]ui.Span{
    .{ .text = "dana", .weight = .bold },
    .{ .text = "  " },
    .{ .text = "@sam", .color = .{ .rgba = mention }, .weight = .semibold },
    .{ .text = " the build on " },
    .{ .text = "main", .family = .mono, .background = .{ .rgba = code_fill } },
    .{ .text = " is green again, " },
    .{ .text = "nice work", .italic = true },
    .{ .text = "." },
};

const markdown = [_]ui.Span{
    .{ .text = "Spans are byte ranges over one string, so " },
    .{ .text = "a bold phrase wraps across lines like any other words", .weight = .bold },
    .{ .text = ", inline " },
    .{ .text = "code()", .family = .mono, .background = .{ .rgba = code_fill } },
    .{ .text = " keeps its background on every line, and " },
    .{ .text = "underlines", .decoration = .underlined, .color = .{ .rgba = mention } },
    .{ .text = " and " },
    .{ .text = "strikethrough", .decoration = .struckthrough, .color = .{ .rgba = muted } },
    .{ .text = " follow their span." },
};

const log = [_]ui.Span{
    .{ .text = "12:04:11 ", .family = .mono, .color = .{ .rgba = muted } },
    .{ .text = "ERROR", .family = .mono, .weight = .bold, .color = .{ .rgba = danger } },
    .{ .text = " upload failed, retrying  " },
    .{ .text = "12:04:13 ", .family = .mono, .color = .{ .rgba = muted } },
    .{ .text = "OK", .family = .mono, .weight = .bold, .color = .{ .rgba = success } },
};

// Links take the theme's link color and an underline unless the span sets its own; Tab
// reaches each one, and Return or a click runs its handler.
fn links(cx: *Cx) [5]ui.Span {
    const open = cx.on(State.open, .{});
    return .{
        .{ .text = "See " },
        .{
            .text = "the rich text design",
            .link = .{ .on_click = open, .href = "docs/rich-text.md" },
        },
        .{ .text = " or run " },
        .{
            .text = "zig build run-rich_text",
            .family = .mono,
            .background = .{ .rgba = code_fill },
            .link = .{ .on_click = open, .key = .{ .name = "run" } },
        },
        .{ .text = "; a link that wraps stays one Tab stop." },
    };
}

const cell = [_]ui.Span{
    .{ .text = "invoice-2026-11.pdf", .weight = .semibold },
    .{ .text = " shared by " },
    .{ .text = "@finance-team", .color = .{ .rgba = mention } },
};

const Panel = struct {
    heading: []const u8,
    body: []const ui.Span,
    width: ?f32 = null,

    pub fn render(self: Panel, cx: *Cx) void {
        std.debug.assert(self.heading.len > 0);
        std.debug.assert(self.body.len > 0);
        const cut = self.width != null;
        cx.render(ui.box(.{ .style = .{
            .width = if (self.width) |width| .{ .fixed = width } else .{ .grow = 1 },
            .padding = .all(12),
            .gap = 6,
            .background = .{ .rgba = card },
            .border = .{ .width = 1, .color = .{ .rgba = line } },
            .corner_radius = .all(8),
        } }, .{
            ui.text(self.heading, .{ .size = 11, .weight = .bold, .color = .{ .rgba = muted } }),
            ui.rich(self.body, .{
                .size = 15,
                .color = ink_token,
                .wrap = if (cut) .none else .words,
                .overflow = if (cut) .ellipsis else .clip,
            }),
        }));
    }
};
