const std = @import("std");
const gooey = @import("gooey");

const ui = gooey.ui;
const Cx = gooey.Cx;
const Color = ui.Color;

pub const State = struct {};

pub const App = gooey.App(State, render, .{
    .title = "Layout gallery",
    .width = 1240,
    .height = 760,
    .limits = .standard,
});

pub const main = App.main;

const blue: Color = .hex(0x3B82F6);
const violet: Color = .hex(0x8B5CF6);
const teal: Color = .hex(0x14B8A6);
const amber: Color = .hex(0xF59E0B);
const rose: Color = .hex(0xF43F5E);
const slate: Color = .hex(0x64748B);
const page: Color = .hex(0xF1F5F9);
const card: Color = .hex(0xFFFFFF);
const line: Color = .hex(0xE2E8F0);
const ink: Color = .hex(0x0F172A);
const muted: Color = .hex(0x64748B);
const white: ui.ColorToken = .{ .rgba = .white };

pub fn render(cx: *Cx) void {
    cx.render(ui.box(.{ .style = .{
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .background = .{ .rgba = page },
        .padding = .all(16),
        .gap = 12,
        .direction = .row,
    } }, .{
        ui.box(.{ .style = column }, .{ RowsPanel{}, DistributionPanel{}, WrapPanel{} }),
        ui.box(.{ .style = column }, .{ AspectPanel{}, PercentPanel{}, ScrollPanel{} }),
        ui.box(.{ .style = column }, .{ TextPanel{}, OverflowPanel{} }),
    }));
}

const column: ui.Style = .{ .width = .{ .grow = 1 }, .height = .{ .grow = 1 }, .gap = 12 };

const panel: ui.Style = .{
    .width = .{ .grow = 1 },
    .padding = .all(14),
    .gap = 10,
    .background = .{ .rgba = card },
    .border = .{ .width = 1, .color = .{ .rgba = line } },
    .corner_radius = .all(10),
};

fn title(text: []const u8) ui.Text.Element {
    return ui.text(text, .{ .size = 15, .weight = .bold, .color = .{ .rgba = ink } });
}

fn caption(text: []const u8) ui.Text.Element {
    return ui.text(text, .{ .size = 12, .color = .{ .rgba = muted } });
}

const Block = struct {
    label: []const u8,
    color: Color,
    width: ui.Sizing = .fit,
    height: f32 = 36,

    pub fn render(self: Block, cx: *Cx) void {
        cx.render(ui.box(.{ .style = .{
            .width = self.width,
            .height = .{ .fixed = self.height },
            .padding = .symmetric(10, 0),
            .background = .{ .rgba = self.color },
            .corner_radius = .all(6),
            .alignment = .center,
        } }, .{ui.text(self.label, .{ .size = 12, .weight = .bold, .color = white })}));
    }
};

const RowsPanel = struct {
    pub fn render(_: RowsPanel, cx: *Cx) void {
        const row: ui.Style = .{ .width = .{ .grow = 1 }, .direction = .row, .gap = 8 };
        cx.render(ui.box(.{ .style = panel }, .{
            title("Rows, columns and grow weights"),
            caption("grow 1 : 2 : 1 share the free width"),
            ui.box(.{ .style = row }, .{
                Block{ .label = "grow 1", .color = blue, .width = .{ .grow = 1 } },
                Block{ .label = "grow 2", .color = violet, .width = .{ .grow = 2 } },
                Block{ .label = "grow 1", .color = blue, .width = .{ .grow = 1 } },
            }),
            caption("fixed sidebar, grow content, fixed rail"),
            ui.box(.{ .style = row }, .{
                Block{ .label = "fixed 90", .color = slate, .width = .{ .fixed = 90 } },
                Block{ .label = "grow", .color = teal, .width = .{ .grow = 1 } },
                Block{ .label = "60", .color = slate, .width = .{ .fixed = 60 } },
            }),
        }));
    }
};

const DistributionPanel = struct {
    pub fn render(_: DistributionPanel, cx: *Cx) void {
        cx.render(ui.box(.{ .style = panel }, .{
            title("Main-axis distribution"),
            Distributed{ .main = .start, .label = "start" },
            Distributed{ .main = .center, .label = "center" },
            Distributed{ .main = .space_between, .label = "space_between" },
            Distributed{ .main = .space_evenly, .label = "space_evenly" },
        }));
    }
};

const Distributed = struct {
    main: ui.Alignment.Main,
    label: []const u8,

    pub fn render(self: Distributed, cx: *Cx) void {
        cx.render(ui.box(.{ .style = .{
            .width = .{ .grow = 1 },
            .direction = .row,
            .gap = 6,
            .padding = .all(4),
            .background = .{ .rgba = page },
            .corner_radius = .all(6),
            .alignment = .{ .main = self.main, .cross = .center },
        } }, .{
            Block{ .label = self.label, .color = amber, .height = 26 },
            Block{ .label = "B", .color = amber, .height = 26 },
            Block{ .label = "C", .color = amber, .height = 26 },
        }));
    }
};

const WrapPanel = struct {
    const tags = [_][]const u8{
        "layout", "flexbox",    "wrap",    "aspect ratio",  "percent", "grow weights",
        "scroll", "layers",     "tooltip", "accessibility", "IME",     "drag and drop",
        "themes", "zero alloc", "vulkan",  "metal",
    };

    pub fn render(_: WrapPanel, cx: *Cx) void {
        var chips: [tags.len]Block = undefined;
        for (tags, 0..) |tag, index| {
            const color = if (index % 3 == 0) violet else blue;
            chips[index] = .{ .label = tag, .color = color, .height = 26 };
        }
        cx.render(ui.box(.{ .style = panel }, .{
            title("Wrapping rows (Style.wrap)"),
            caption("chips keep their widths and break onto lines"),
            ui.box(.{ .style = .{
                .width = .{ .grow = 1 },
                .direction = .row,
                .wrap = true,
                .gap = 6,
            } }, chips),
        }));
    }
};

const AspectPanel = struct {
    pub fn render(_: AspectPanel, cx: *Cx) void {
        cx.render(ui.box(.{ .style = panel }, .{
            title("Aspect ratio"),
            caption("height follows width: 16:9, 4:3 and 1:1"),
            ui.box(.{ .style = .{ .width = .{ .grow = 1 }, .direction = .row, .gap = 10 } }, .{
                Media{ .ratio = 16.0 / 9.0, .label = "16:9", .color = teal, .weight = 2 },
                Media{ .ratio = 4.0 / 3.0, .label = "4:3", .color = violet, .weight = 1.5 },
                Media{ .ratio = 1, .label = "1:1", .color = rose, .weight = 1 },
            }),
        }));
    }
};

const Media = struct {
    ratio: f32,
    label: []const u8,
    color: Color,
    weight: f32,

    pub fn render(self: Media, cx: *Cx) void {
        cx.render(ui.box(.{ .style = .{
            .width = .{ .grow = self.weight },
            .aspect_ratio = self.ratio,
            .background = .{ .rgba = self.color },
            .corner_radius = .all(8),
            .alignment = .center,
        } }, .{ui.text(self.label, .{ .size = 13, .weight = .bold, .color = white })}));
    }
};

const PercentPanel = struct {
    pub fn render(_: PercentPanel, cx: *Cx) void {
        const row: ui.Style = .{
            .width = .{ .grow = 1 },
            .direction = .row,
            .gap = 10,
            .padding = .all(4),
            .background = .{ .rgba = page },
            .corner_radius = .all(6),
        };
        cx.render(ui.box(.{ .style = panel }, .{
            title("Percent sizing"),
            caption("4 x 25% with 10 px gaps"),
            ui.box(.{ .style = row }, .{
                Block{ .label = "25%", .color = blue, .width = .{ .percent = 0.25 } },
                Block{ .label = "25%", .color = blue, .width = .{ .percent = 0.25 } },
                Block{ .label = "25%", .color = blue, .width = .{ .percent = 0.25 } },
                Block{ .label = "25%", .color = blue, .width = .{ .percent = 0.25 } },
            }),
            caption("50% and 25% beside a grow box"),
            ui.box(.{ .style = row }, .{
                Block{ .label = "50%", .color = violet, .width = .{ .percent = 0.5 } },
                Block{ .label = "25%", .color = blue, .width = .{ .percent = 0.25 } },
                Block{ .label = "grow", .color = teal, .width = .{ .grow = 1 } },
            }),
        }));
    }
};

const ScrollPanel = struct {
    pub fn render(_: ScrollPanel, cx: *Cx) void {
        var rows: [14]ScrollRow = undefined;
        for (&rows, 0..) |*row, index| row.* = .{ .index = @intCast(index) };
        cx.render(ui.box(.{ .style = panel }, .{
            title("Scrolling"),
            caption("a fixed-height box scrolls its column"),
            ui.box(.{ .key = .{ .name = "scroll" }, .style = .{
                .width = .{ .grow = 1 },
                .height = .{ .fixed = 130 },
                .gap = 4,
                .scroll = .{},
                .clip = .clip,
            } }, rows),
        }));
    }
};

const ScrollRow = struct {
    index: u32,

    pub fn render(self: ScrollRow, cx: *Cx) void {
        const names = [_][]const u8{
            "Inbox", "Drafts", "Sent", "Archive", "Spam", "Trash", "Notes",
        };
        cx.render(ui.box(.{ .style = .{
            .width = .{ .grow = 1 },
            .direction = .row,
            .padding = .symmetric(10, 6),
            .background = .{ .rgba = page },
            .corner_radius = .all(4),
            .alignment = .{ .main = .space_between, .cross = .center },
        } }, .{
            ui.text(names[self.index % names.len], .{ .size = 13, .color = .{ .rgba = ink } }),
            caption(if (self.index % 2 == 0) "12 new" else "read"),
        }));
    }
};

const lorem =
    "Gooey lays out boxes in one bottom-up pass for content sizes, one top-down pass " ++
    "for widths, then wraps text at those widths, sizes heights, and places everything.";

const beside_fixed = "A grow column beside a fixed box takes the rest of the row " ++
    "and wraps its text there.";

const TextPanel = struct {
    pub fn render(_: TextPanel, cx: *Cx) void {
        cx.render(ui.box(.{ .style = panel }, .{
            title("Wrapped text and cross alignment"),
            ui.box(.{ .style = .{ .width = .{ .grow = 1 }, .direction = .row, .gap = 10 } }, .{
                ui.box(.{ .style = .{
                    .width = .{ .fixed = 40 },
                    .height = .{ .fixed = 40 },
                    .background = .{ .rgba = violet },
                    .corner_radius = .all(20),
                } }, .{}),
                ui.box(.{ .style = .{ .width = .{ .grow = 1 }, .gap = 4 } }, .{
                    ui.text("Paragraph in a column", .{ .size = 13, .weight = .bold }),
                    ui.text(lorem, .{ .size = 13, .wrap = .words, .color = .{ .rgba = muted } }),
                }),
            }),
            ui.box(.{ .style = .{
                .width = .{ .grow = 1 },
                .direction = .row,
                .gap = 8,
                .padding = .all(6),
                .background = .{ .rgba = page },
                .corner_radius = .all(6),
                .alignment = .{ .main = .start, .cross = .center },
            } }, .{
                Block{ .label = "tall", .color = teal, .height = 56 },
                Block{ .label = "cross: center", .color = amber, .height = 26 },
                Block{ .label = "mid", .color = blue, .height = 40 },
            }),
        }));
    }
};

const OverflowPanel = struct {
    pub fn render(_: OverflowPanel, cx: *Cx) void {
        const outline: ui.Style = .{
            .width = .{ .fixed = 300 },
            .direction = .row,
            .gap = 6,
            .padding = .all(4),
            .border = .{ .width = 1, .color = .{ .rgba = rose } },
            .corner_radius = .all(6),
        };
        cx.render(ui.box(.{ .style = panel }, .{
            title("Overflow"),
            caption("300 px row: fixed 150 + two labels that need 200"),
            ui.box(.{ .style = outline }, .{
                Block{ .label = "fixed 150", .color = slate, .width = .{ .fixed = 150 } },
                Label{ .text = "Save changes" },
                Label{ .text = "Discard draft" },
            }),
            caption("300 px row: fixed 90 + grow column with a paragraph"),
            ui.box(.{ .style = outline }, .{
                Block{ .label = "fixed 90", .color = slate, .width = .{ .fixed = 90 } },
                ui.box(.{ .style = .{ .width = .{ .grow = 1 } } }, .{
                    ui.text(beside_fixed, .{ .size = 13, .wrap = .words }),
                }),
            }),
            caption("300 px row: grow-height notes stretch to the row"),
            ui.box(.{ .style = outline }, .{
                Note{ .text = "Long note: the wider child gives way first and wraps" },
                Note{ .text = "Short note" },
            }),
        }));
    }
};

const Label = struct {
    text: []const u8,

    pub fn render(self: Label, cx: *Cx) void {
        cx.render(ui.box(.{ .style = .{
            .padding = .symmetric(8, 6),
            .background = .{ .rgba = page },
            .border = .{ .width = 1, .color = .{ .rgba = slate } },
            .corner_radius = .all(4),
        } }, .{ui.text(self.text, .{ .size = 13, .color = .{ .rgba = ink } })}));
    }
};

const Note = struct {
    text: []const u8,

    pub fn render(self: Note, cx: *Cx) void {
        cx.render(ui.box(.{ .style = .{
            .height = .{ .grow = 1 },
            .padding = .symmetric(8, 6),
            .background = .{ .rgba = .hex(0xFEF3C7) },
            .corner_radius = .all(4),
        } }, .{ui.text(self.text, .{ .size = 13, .wrap = .words, .color = .{ .rgba = ink } })}));
    }
};
