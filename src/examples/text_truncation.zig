const std = @import("std");
const gooey = @import("gooey");

const ui = gooey.ui;
const Cx = gooey.Cx;
const Color = ui.Color;

pub const State = struct {};

pub const App = gooey.App(State, render, .{
    .title = "Text truncation",
    .width = 780,
    .height = 600,
    .limits = .standard,
});

pub const main = App.main;

const blue: Color = .hex(0x3B82F6);
const violet: Color = .hex(0x8B5CF6);
const teal: Color = .hex(0x14B8A6);
const page: Color = .hex(0xF1F5F9);
const card: Color = .hex(0xFFFFFF);
const line: Color = .hex(0xE2E8F0);
const ink: Color = .hex(0x0F172A);
const ink_token: ui.ColorToken = .{ .rgba = ink };
const muted: Color = .hex(0x64748B);

pub fn render(cx: *Cx) void {
    cx.render(ui.box(.{ .style = .{
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .direction = .row,
        .background = .{ .rgba = page },
        .padding = .all(16),
        .gap = 12,
    } }, .{
        Sidebar{},
        ui.box(.{ .style = .{ .width = .{ .grow = 1 }, .gap = 12 } }, .{
            FileTable{},
            Cards{},
        }),
    }));
}

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

const Sidebar = struct {
    const Channel = struct { name: []const u8, unread: []const u8 };
    const channels = [_]Channel{
        .{ .name = "general", .unread = "3" },
        .{ .name = "design-reviews-and-weekly-critique", .unread = "12" },
        .{ .name = "release-engineering-and-infrastructure", .unread = "128" },
        .{ .name = "random", .unread = "1" },
        .{ .name = "customer-escalations-emea-and-apac", .unread = "7" },
    };

    pub fn render(_: Sidebar, cx: *Cx) void {
        cx.render(ui.box(.{ .style = .{
            .width = .{ .fixed = 230 },
            .height = .{ .grow = 1 },
            .padding = .all(14),
            .gap = 6,
            .background = .{ .rgba = card },
            .border = .{ .width = 1, .color = .{ .rgba = line } },
            .corner_radius = .all(10),
        } }, .{
            title("Channels"),
            Rows{},
        }));
    }

    const Rows = struct {
        pub fn render(_: Rows, cx: *Cx) void {
            for (channels) |channel| cx.render(Row{ .channel = channel });
        }
    };

    const Row = struct {
        channel: Channel,

        pub fn render(self: Row, cx: *Cx) void {
            cx.render(ui.box(.{ .style = .{
                .width = .{ .grow = 1 },
                .direction = .row,
                .gap = 8,
                .alignment = .center_cross,
                .padding = .symmetric(6, 5),
            } }, .{
                ui.box(.{ .style = .{
                    .width = .{ .fixed = 8 },
                    .height = .{ .fixed = 8 },
                    .background = .{ .rgba = teal },
                    .corner_radius = .all(4),
                } }, .{}),
                ui.box(.{ .style = .{ .width = .{ .grow = 1 } } }, .{
                    ui.text(self.channel.name, .{
                        .size = 13,
                        .color = ink_token,
                        .overflow = .ellipsis,
                    }),
                }),
                ui.box(.{ .style = .{
                    .padding = .symmetric(7, 2),
                    .background = .{ .rgba = blue },
                    .corner_radius = .all(9),
                } }, .{ui.text(self.channel.unread, .{
                    .size = 11,
                    .weight = .bold,
                    .color = .{ .rgba = .hex(0xFFFFFF) },
                })}),
            }));
        }
    };
};

const FileTable = struct {
    const columns = [_]ui.Track{
        .grow(1),
        .fit,
        .fixed(110),
        .{ .sizing = .{ .fixed = 64 }, .cell_alignment = .end },
    };

    const File = struct { name: []const u8, owner: []const u8, note: []const u8, size: []const u8 };
    const files = [_]File{
        .{ .name = "readme.md", .owner = "Ada", .note = "draft", .size = "4 KB" },
        .{
            .name = "quarterly-revenue-by-region-and-product-line-final-v7-reviewed.xlsx",
            .owner = "Grace",
            .note = "waiting on the finance review",
            .size = "1.2 MB",
        },
        .{
            .name = "architecture overview for the new layout engine.pdf",
            .owner = "Edsger",
            .note = "shared",
            .size = "880 KB",
        },
        .{ .name = "logo.svg", .owner = "Barbara", .note = "final", .size = "12 KB" },
    };

    pub fn render(_: FileTable, cx: *Cx) void {
        cx.render(ui.box(.{ .style = panel }, .{
            title("Files"),
            ui.box(.{ .style = .{
                .width = .{ .grow = 1 },
                .grid = .{ .columns = &columns, .row_gap = 8 },
                .gap = 16,
            } }, .{
                header("Name"),
                header("Owner"),
                header("Note"),
                header("Size"),
                Rows{},
            }),
        }));
    }

    fn header(text: []const u8) ui.Text.Element {
        return ui.text(text, .{ .size = 12, .weight = .bold, .color = .{ .rgba = muted } });
    }

    const name_style: ui.Text = .{ .size = 13, .color = ink_token, .overflow = .ellipsis };

    const Rows = struct {
        pub fn render(_: Rows, cx: *Cx) void {
            for (files) |file| {
                cx.render(ui.text(file.name, name_style));
                cx.render(ui.text(file.owner, .{ .size = 13, .color = .{ .rgba = muted } }));
                cx.render(ui.text(file.note, .{ .size = 13, .color = .{ .rgba = muted } }));
                cx.render(ui.text(file.size, .{ .size = 13, .color = ink_token }));
            }
        }
    };
};

const Cards = struct {
    const Note = struct {
        heading: []const u8,
        body: []const u8,
        color: Color,
        line_count_max: u8,
        overflow: @FieldType(ui.Text, "overflow"),
    };
    const notes = [_]Note{
        .{
            .heading = "Release notes",
            .body = "Text can now be cut to a line count, with an ellipsis that fills the " ++
                "last line to its width. Layout keeps the clamped height, so every card " ++
                "on this row lines up whatever the length of its body.",
            .color = blue,
            .line_count_max = 3,
            .overflow = .ellipsis,
        },
        .{
            .heading = "Short",
            .body = "Fits in three lines, so no ellipsis.",
            .color = violet,
            .line_count_max = 3,
            .overflow = .ellipsis,
        },
        .{
            .heading = "Clipped",
            .body = "With .clip the lines past the limit are dropped and nothing marks " ++
                "the cut, which suits a preview whose full text is a click away.",
            .color = teal,
            .line_count_max = 2,
            .overflow = .clip,
        },
    };
    const columns: [3]ui.Track = @splat(.grow(1));

    pub fn render(_: Cards, cx: *Cx) void {
        cx.render(ui.box(.{ .style = panel }, .{
            title("Cards"),
            ui.box(.{ .style = .{
                .width = .{ .grow = 1 },
                .grid = .{ .columns = &columns },
                .gap = 12,
            } }, .{NoteCards{}}),
        }));
    }

    const NoteCards = struct {
        pub fn render(_: NoteCards, cx: *Cx) void {
            for (notes) |note| cx.render(NoteCard{ .note = note });
        }
    };

    const NoteCard = struct {
        note: Note,

        pub fn render(self: NoteCard, cx: *Cx) void {
            cx.render(ui.box(.{ .style = .{
                .width = .{ .grow = 1 },
                .height = .{ .grow = 1 },
                .padding = .all(12),
                .gap = 4,
                .background = .{ .rgba = page },
                .border = .{ .width = 2, .color = .{ .rgba = self.note.color } },
                .corner_radius = .all(8),
            } }, .{
                ui.text(self.note.heading, .{
                    .size = 12,
                    .weight = .bold,
                    .color = .{ .rgba = self.note.color },
                }),
                ui.text(self.note.body, .{
                    .size = 14,
                    .wrap = .words,
                    .color = ink_token,
                    .line_count_max = self.note.line_count_max,
                    .overflow = self.note.overflow,
                }),
            }));
        }
    };
};
