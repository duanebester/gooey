//! Grid layout (`Style.grid`, decision 28): a form whose labels line up in a
//! fit column, a table whose keyed, hoverable rows keep their cells under the
//! header's, and a 12-column dashboard whose cards span 3, 4, 6, or 8 columns
//! and stretch to their row's height.

const std = @import("std");
const gooey = @import("gooey");

const ui = gooey.ui;
const Cx = gooey.Cx;
const Color = ui.Color;

pub const State = struct {};

pub const App = gooey.App(State, render, .{
    .title = "Grid layout",
    .width = 1240,
    .height = 760,
    .limits = .standard,
});

pub const main = App.main;

const blue: Color = .hex(0x3B82F6);
const violet: Color = .hex(0x8B5CF6);
const teal: Color = .hex(0x14B8A6);
const amber: Color = .hex(0xF59E0B);
const page: Color = .hex(0xF1F5F9);
const card: Color = .hex(0xFFFFFF);
const line: Color = .hex(0xE2E8F0);
const hover: Color = .hex(0xEFF6FF);
const ink: Color = .hex(0x0F172A);
const ink_token: ui.ColorToken = .{ .rgba = ink };
const muted: Color = .hex(0x64748B);

pub fn render(cx: *Cx) void {
    cx.render(ui.box(.{ .style = .{
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .background = .{ .rgba = page },
        .padding = .all(16),
        .gap = 12,
    } }, .{
        ui.box(.{ .style = .{ .width = .{ .grow = 1 }, .direction = .row, .gap = 12 } }, .{
            FormPanel{},
            TablePanel{},
        }),
        DashboardPanel{},
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

fn caption(text: []const u8) ui.Text.Element {
    return ui.text(text, .{ .size = 12, .color = .{ .rgba = muted } });
}

fn label(text: []const u8) ui.Text.Element {
    return ui.text(text, .{ .size = 13, .color = .{ .rgba = ink } });
}

/// Labels in a `.fit` column as wide as the widest, fields filling the rest.
const FormPanel = struct {
    const columns = [_]ui.Track{ .fit, .grow(1) };

    pub fn render(_: FormPanel, cx: *Cx) void {
        cx.render(ui.box(.{ .style = panel }, .{
            title("Form"),
            caption("columns .fit and .grow(1): every label lines up"),
            ui.box(.{ .style = .{
                .width = .{ .grow = 1 },
                .grid = .{ .columns = &columns, .row_gap = 8 },
                .gap = 12,
                .alignment = .center_cross,
            } }, .{
                label("Name"),
                Field{ .text = "Ada Lovelace" },
                label("Email address"),
                Field{ .text = "ada@example.com" },
                label("Role"),
                Field{ .text = "Analyst" },
                label("Notes"),
                Field{ .text = "Wrapped text makes its row taller, and the label stays " ++
                    "centred on it." },
            }),
        }));
    }
};

const Field = struct {
    text: []const u8,

    pub fn render(self: Field, cx: *Cx) void {
        cx.render(ui.box(.{ .style = .{
            .width = .{ .grow = 1 },
            .padding = .symmetric(10, 7),
            .background = .{ .rgba = page },
            .border = .{ .width = 1, .color = .{ .rgba = line } },
            .corner_radius = .all(6),
        } }, .{ui.text(self.text, .{ .size = 13, .wrap = .words, .color = .{ .rgba = muted } })}));
    }
};

/// A header of plain cells and keyed row boxes on one grid: the name column
/// grows twice as fast as the team column, and the amounts are right-aligned.
const TablePanel = struct {
    const columns = [_]ui.Track{
        .fit,
        .{ .sizing = .{ .grow = 2 }, .min = 140 },
        .grow(1),
        .{ .sizing = .{ .fixed = 112 }, .cell_alignment = .end },
    };

    const Person = struct {
        id: []const u8,
        name: []const u8,
        team: []const u8,
        amount: []const u8,
    };
    const people = [_]Person{
        .{ .id = "1", .name = "Ada Lovelace", .team = "Analysis", .amount = "$1,240.00" },
        .{ .id = "2", .name = "Grace Hopper", .team = "Compilers", .amount = "$980.50" },
        .{
            .id = "3",
            .name = "Edsger Wybe Dijkstra, whose name wraps",
            .team = "Algorithms",
            .amount = "$12.00",
        },
        .{ .id = "4", .name = "Barbara Liskov", .team = "Types", .amount = "$3,400.10" },
        .{ .id = "5", .name = "Ken Thompson", .team = "Systems", .amount = "$77.70" },
    };

    pub fn render(_: TablePanel, cx: *Cx) void {
        cx.render(ui.box(.{ .style = panel }, .{
            title("Table"),
            caption("row boxes keep their cells under the header; hover a row"),
            ui.box(.{ .style = .{
                .width = .{ .grow = 1 },
                .grid = .{ .columns = &columns, .row_gap = 0 },
                .gap = 12,
            } }, .{
                HeaderCell{ .text = "#" },
                HeaderCell{ .text = "Name" },
                HeaderCell{ .text = "Team" },
                HeaderCell{ .text = "Amount" },
                Rows{},
            }),
        }));
    }

    const Rows = struct {
        pub fn render(_: Rows, cx: *Cx) void {
            for (people, 0..) |person, index| {
                cx.render(Row{ .person = person, .index = @intCast(index) });
            }
        }
    };

    const Row = struct {
        person: Person,
        index: u32,

        pub fn render(self: Row, cx: *Cx) void {
            const key: gooey.Key = .{ .index = self.index };
            const hovered = cx.hovered(cx.id(key));
            cx.render(ui.box(.{ .key = key, .style = .{
                .cell = .{ .row = true },
                .padding = .{ .top = 7, .bottom = 7 },
                .alignment = .center_cross,
                .background = .{ .rgba = if (hovered) hover else card },
                .border = .{ .width = 1, .color = .{ .rgba = line } },
            } }, .{
                ui.text(self.person.id, .{ .size = 13, .color = .{ .rgba = muted } }),
                ui.text(self.person.name, .{ .size = 13, .wrap = .words, .color = ink_token }),
                ui.text(self.person.team, .{ .size = 13, .color = .{ .rgba = muted } }),
                ui.text(self.person.amount, .{ .size = 13, .weight = .bold, .color = ink_token }),
            }));
        }
    };
};

const HeaderCell = struct {
    text: []const u8,

    pub fn render(self: HeaderCell, cx: *Cx) void {
        cx.render(ui.box(.{ .style = .{ .padding = .{ .bottom = 6 } } }, .{
            ui.text(self.text, .{ .size = 12, .weight = .bold, .color = .{ .rgba = muted } }),
        }));
    }
};

const tickets = "37 open, 5 of them waiting on a reply for more than a day";
const span_eight = "A wide card on 8 of the 12 column lines.";
const span_four = "Its edges sit on the same lines as the cards above.";

/// Twelve equal columns; cards span 3, 4, 6, or 8 of them, and each row's
/// cards stretch to its tallest.
const DashboardPanel = struct {
    const twelve: [12]ui.Track = @splat(.grow(1));

    pub fn render(_: DashboardPanel, cx: *Cx) void {
        cx.render(ui.box(.{ .style = panel }, .{
            title("Dashboard"),
            caption("12 .grow(1) columns; cards span 3, 4, 6 or 8 and stretch to their row"),
            ui.box(.{ .style = .{
                .width = .{ .grow = 1 },
                .grid = .{ .columns = &twelve },
                .gap = 12,
            } }, .{
                Card{ .span = 3, .color = blue, .heading = "Revenue", .body = "$48,210" },
                Card{ .span = 3, .color = violet, .heading = "Customers", .body = "1,204" },
                Card{ .span = 3, .color = teal, .heading = "Churn", .body = "1.8%" },
                Card{ .span = 3, .color = amber, .heading = "Tickets", .body = tickets },
                Card{ .span = 8, .color = blue, .heading = "Span 8", .body = span_eight },
                Card{ .span = 4, .color = teal, .heading = "Span 4", .body = span_four },
                Card{ .span = 6, .color = violet, .heading = "Span 6", .body = "Half" },
                Card{ .span = 6, .color = amber, .heading = "Span 6", .body = "The other half" },
            }),
        }));
    }
};

const Card = struct {
    span: u8,
    color: Color,
    heading: []const u8,
    body: []const u8,

    pub fn render(self: Card, cx: *Cx) void {
        std.debug.assert(self.span >= 1);
        std.debug.assert(self.span <= 12);
        cx.render(ui.box(.{ .style = .{
            .cell = .{ .column_span = self.span },
            .width = .{ .grow = 1 },
            .height = .{ .grow = 1 },
            .padding = .all(12),
            .gap = 4,
            .background = .{ .rgba = page },
            .border = .{ .width = 2, .color = .{ .rgba = self.color } },
            .corner_radius = .all(8),
        } }, .{
            ui.text(self.heading, .{
                .size = 12,
                .weight = .bold,
                .color = .{ .rgba = self.color },
            }),
            ui.text(self.body, .{ .size = 15, .wrap = .words, .color = ink_token }),
        }));
    }
};
