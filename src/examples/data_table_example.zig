const std = @import("std");
const gooey = @import("gooey");
const components = @import("gooey-components");

const ui = gooey.ui;
const Cx = gooey.Cx;
const Effects = gooey.Effects;
const Color = ui.Color;
const List = components.List;

const assert = std.debug.assert;

pub const row_count: u32 = 10_000;
const row_height: f32 = 32;
const header_height: f32 = 36;

pub const Column = enum(u8) { id, name, status, size, modified };
const column_count = 5;
comptime {
    assert(@backingInt(Column.modified) + 1 == column_count);
}
const column_names = [column_count][]const u8{ "ID", "Name", "Status", "Size", "Modified" };
const column_widths = [column_count]f32{ 80, 200, 100, 120, 150 };
const column_grow: Column = .name;
const table_width: f32 = blk: {
    var total: f32 = 0;
    for (column_widths) |width| total += width;
    break :blk total;
};

const names = [_][]const u8{
    "document.pdf", "image.png", "data.json",  "script.zig",  "config.toml",
    "readme.md",    "notes.txt", "backup.zip", "report.xlsx", "video.mp4",
};
const statuses = [_][]const u8{ "Active", "Pending", "Archived" };

pub const RowData = struct {
    id: u32,
    name_index: u8,
    status_index: u8,
    size_bytes: u64,
    modified_days_ago: u16,
};

pub const SortDirection = enum {
    none,
    ascending,
    descending,

    fn next(self: SortDirection) SortDirection {
        return switch (self) {
            .none => .ascending,
            .ascending => .descending,
            .descending => .none,
        };
    }
};

pub const State = struct {
    rows: [row_count]RowData = undefined,
    order: [row_count]u32 = undefined,
    sort_column: ?Column = null,
    sort_direction: SortDirection = .none,

    fn init(self: *State, _: gooey.Init, _: *Effects) void {
        var seed: u64 = 12345;
        for (&self.rows, &self.order, 0..) |*row, *order, index| {
            const first = nextRandom(&seed);
            const second = nextRandom(&seed);
            const third = nextRandom(&seed);
            row.* = .{
                .id = @intCast(index + 1),
                .name_index = @intCast(first % names.len),
                .status_index = @intCast(second % statuses.len),
                .size_bytes = first % 10_000_000_000 + 100,
                .modified_days_ago = @intCast(third % 365),
            };
            order.* = @intCast(index);
        }
        assert(self.rows[row_count - 1].id == row_count);
    }

    pub fn sortBy(self: *State, column: u32) void {
        assert(column < column_count);
        const picked: Column = @fromBackingInt(@intCast(column));
        const direction: SortDirection = if (self.sort_column == picked)
            self.sort_direction.next()
        else
            .ascending;
        self.sort_direction = direction;
        self.sort_column = if (direction == .none) null else picked;
        if (direction == .none) {
            for (&self.order, 0..) |*order, index| order.* = @intCast(index);
        } else {
            heapSort(&self.order, &self.rows, picked, direction == .ascending);
        }
        if (self.sort_column == null) assert(self.order[0] == 0);
    }
};

fn nextRandom(seed: *u64) u64 {
    seed.* = seed.* *% 6364136223846793005 +% 1442695040888963407;
    return seed.* >> 33;
}

fn heapSort(
    order: *[row_count]u32,
    rows: *const [row_count]RowData,
    column: Column,
    up: bool,
) void {
    var index: u32 = row_count / 2;
    while (index > 0) {
        index -= 1;
        siftDown(order, rows, .{ .start = index, .end = row_count, .column = column, .up = up });
    }
    var end: u32 = row_count;
    while (end > 1) {
        end -= 1;
        std.mem.swap(u32, &order[0], &order[end]);
        siftDown(order, rows, .{ .start = 0, .end = end, .column = column, .up = up });
    }
}

const Sift = struct { start: u32, end: u32, column: Column, up: bool };

fn siftDown(order: *[row_count]u32, rows: *const [row_count]RowData, sift: Sift) void {
    assert(sift.start < sift.end);
    assert(sift.end <= row_count);
    var root = sift.start;
    var depth: u32 = 0;
    while (depth < 32) : (depth += 1) {
        const left = 2 * root + 1;
        if (left >= sift.end) return;
        var swap = root;
        if (before(rows, sift, order[swap], order[left])) swap = left;
        const right = left + 1;
        if (right < sift.end and before(rows, sift, order[swap], order[right])) swap = right;
        if (swap == root) return;
        std.mem.swap(u32, &order[root], &order[swap]);
        root = swap;
    }
    unreachable;
}

fn before(rows: *const [row_count]RowData, sift: Sift, parent: u32, child: u32) bool {
    const order = compare(&rows[child], &rows[parent], sift.column);
    return if (sift.up) order == .gt else order == .lt;
}

fn compare(a: *const RowData, b: *const RowData, column: Column) std.math.Order {
    return switch (column) {
        .id => std.math.order(a.id, b.id),
        .name => std.mem.order(u8, names[a.name_index], names[b.name_index]),
        .status => std.math.order(a.status_index, b.status_index),
        .size => std.math.order(a.size_bytes, b.size_bytes),
        .modified => std.math.order(a.modified_days_ago, b.modified_days_ago),
    };
}

pub const App = gooey.App(State, render, .{
    .title = "DataTable Example - 10,000 Rows",
    .width = 900,
    .height = 600,
    .limits = .standard,
    .on_init = State.init,
});

pub const main = App.main;

pub fn render(cx: *Cx) void {
    cx.render(ui.box(.{ .style = .{
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .background = .bg,
        .padding = .all(16),
        .gap = 12,
    } }, .{
        ui.box(.{ .style = .{ .direction = .row, .width = .{ .grow = 1 }, .gap = 8 } }, .{
            ui.text("DataTable Demo", .{ .size = 18, .weight = .bold, .color = .text }),
            ui.box(.{ .style = .{ .width = .{ .grow = 1 } } }, .{}),
            ui.text("10,000 rows × 5 columns - click headers to sort!", .{
                .size = 12,
                .color = .muted,
            }),
        }),
        SortStatus{},
        ui.box(.{ .style = .{
            .width = .{ .grow = 1 },
            .height = .{ .grow = 1 },
            .background = .surface,
            .corner_radius = .all(8),
        } }, .{
            Header{},
            List(TableRow){ .key = "main-table", .count = row_count },
        }),
    }));
}

const SortStatus = struct {
    pub fn render(_: SortStatus, cx: *Cx) void {
        const s = cx.state(State);
        var buffer: [64]u8 = undefined;
        if (s.sort_column) |column| {
            assert(std.fmt.count("Sort: {s} {s}", .{
                column_names[@backingInt(column)],
                "↑",
            }) <= buffer.len);
        }
        const text = if (s.sort_column) |column|
            std.fmt.bufPrint(&buffer, "Sort: {s} {s}", .{
                column_names[@backingInt(column)],
                if (s.sort_direction == .ascending) "↑" else "↓",
            }) catch unreachable
        else
            "Sort: none";
        cx.render(ui.box(.{ .style = .{
            .width = .{ .grow = 1 },
            .padding = .symmetric(12, 8),
            .background = .surface,
            .corner_radius = .all(4),
        } }, .{ui.text(text, .{
            .size = 12,
            .color = if (s.sort_column != null) .primary else .muted,
        })}));
    }
};

const Header = struct {
    pub fn render(_: Header, cx: *Cx) void {
        const s = cx.state(State);
        cx.render(ui.box(.{ .style = .{
            .direction = .row,
            .width = .{ .grow = 1 },
            .width_min = table_width,
            .height = .{ .fixed = header_height },
            .background = .{ .rgba = Color.rgba(0, 0, 0, 0.05) },
        } }, .{HeaderCells{ .sort_column = s.sort_column, .direction = s.sort_direction }}));
    }
};

const HeaderCells = struct {
    sort_column: ?Column,
    direction: SortDirection,

    pub fn render(self: HeaderCells, cx: *Cx) void {
        inline for (column_names, 0..) |name, index| {
            const sorted = self.sort_column == @as(Column, @fromBackingInt(@intCast(index)));
            const label = if (!sorted)
                name
            else if (self.direction == .ascending) name ++ " ▲" else name ++ " ▼";
            cx.render(ui.box(.{
                .key = .{ .name = name },
                .on_click = cx.on(State.sortBy, .{ .arg = @as(u32, index) }),
                .a11y = .{ .role = .button, .label = label },
                .style = cell_style(index, header_height),
            }, .{ui.text(label, .{ .size = 13, .weight = .semibold, .color = .text })}));
        }
    }
};

fn cell_style(column: u32, height: f32) ui.Style {
    assert(column < column_count);
    assert(height > 0);
    const width = column_widths[column];
    const grows = column == @backingInt(column_grow);
    return .{
        .width = if (grows) .{ .grow = 1 } else .{ .fixed = width },
        .width_min = if (grows) width else null,
        .height = .{ .fixed = height },
        .padding = .symmetric(8, 0),
        .alignment = .{ .main = .center },
    };
}

const TableRow = struct {
    index: u32,

    pub const row_height: f32 = 32;

    pub fn render(self: TableRow, cx: *Cx) void {
        const s = cx.state(State);
        assert(self.index < row_count);
        const row = &s.rows[s.order[self.index]];
        const background: ?ui.ColorToken = if (self.index % 2 == 1)
            .{ .rgba = Color.rgba(0, 0, 0, 0.02) }
        else
            null;
        var id_buffer: [16]u8 = undefined;
        var size_buffer: [32]u8 = undefined;
        var modified_buffer: [32]u8 = undefined;
        comptime assert(std.fmt.count("{d}", .{std.math.maxInt(u32)}) <= id_buffer.len);
        const cells = [column_count][]const u8{
            std.fmt.bufPrint(&id_buffer, "{d}", .{row.id}) catch unreachable,
            names[row.name_index],
            statuses[row.status_index],
            formatSize(&size_buffer, row.size_bytes),
            formatModified(&modified_buffer, row.modified_days_ago),
        };
        cx.render(ui.box(.{ .style = .{
            .direction = .row,
            .width = .{ .grow = 1 },
            .width_min = table_width,
            .height = .{ .grow = 1 },
            .background = background,
        } }, .{RowCells{ .cells = &cells }}));
    }
};

const RowCells = struct {
    cells: *const [column_count][]const u8,

    pub fn render(self: RowCells, cx: *Cx) void {
        inline for (self.cells.*, 0..) |cell, index| {
            cx.render(ui.box(.{ .style = cell_style(index, row_height) }, .{
                ui.text(cell, .{ .size = 13, .color = .text }),
            }));
        }
    }
};

fn formatSize(buffer: *[32]u8, bytes: u64) []const u8 {
    const value: f64 = @floatFromInt(bytes);
    comptime assert(std.fmt.count("{d:.2} GB", .{
        @as(f64, @floatFromInt(std.math.maxInt(u64))) / (1024.0 * 1024.0 * 1024.0),
    }) <= buffer.len);
    if (bytes < 1024) return std.fmt.bufPrint(buffer, "{d} B", .{bytes}) catch unreachable;
    if (bytes < 1024 * 1024) {
        return std.fmt.bufPrint(buffer, "{d:.1} KB", .{value / 1024.0}) catch unreachable;
    }
    if (bytes < 1024 * 1024 * 1024) {
        return std.fmt.bufPrint(buffer, "{d:.1} MB", .{value / (1024.0 * 1024.0)}) catch
            unreachable;
    }
    const gigabytes = value / (1024.0 * 1024.0 * 1024.0);
    return std.fmt.bufPrint(buffer, "{d:.2} GB", .{gigabytes}) catch unreachable;
}

fn formatModified(buffer: *[32]u8, days_ago: u16) []const u8 {
    comptime assert(std.fmt.count("{d} months ago", .{std.math.maxInt(u16)}) <= buffer.len);
    if (days_ago == 0) return "Today";
    if (days_ago == 1) return "Yesterday";
    if (days_ago < 7) {
        return std.fmt.bufPrint(buffer, "{d} days ago", .{days_ago}) catch unreachable;
    }
    const weeks = days_ago / 7;
    const months = days_ago / 30;
    const count = if (days_ago < 30) weeks else months;
    const unit = if (days_ago < 30) "week" else "month";
    const plural = if (count > 1) "s" else "";
    return std.fmt.bufPrint(buffer, "{d} {s}{s} ago", .{ count, unit, plural }) catch unreachable;
}
