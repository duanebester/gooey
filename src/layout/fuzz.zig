const std = @import("std");
const gooey = @import("gooey");

const layout = gooey.internals.layout;
const engine_mod = layout.engine;
const types = layout.types;

const LayoutEngine = engine_mod.LayoutEngine;

const fuzz_capacity = layout.LayoutCapacity.fromLimits(&gooey.ResourceLimits.standard);
const Sizing = types.Sizing;
const SizingAxis = types.SizingAxis;
const Padding = types.Padding;

const MAX_FUZZ_ELEMENTS: u32 = 256;
const MAX_FUZZ_DEPTH: u32 = 8;
const MAX_FUZZ_CHILDREN_PER_NODE: u32 = 8;
const MAX_FUZZ_TEXT_LEN: u32 = 64;

const FUZZ_VIEWPORT_MIN: u32 = 64;
const FUZZ_VIEWPORT_MAX: u32 = 4096;

pub fn fuzzLayoutTree(_: void, smith: *std.testing.Smith) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var engine = try LayoutEngine.init(&fuzz_capacity);
    defer engine.deinit();
    engine.setMeasureTextFn(fuzzMeasureText, null);

    const viewport_w: f32 = @floatFromInt(smith.valueRangeAtMost(u32, FUZZ_VIEWPORT_MIN, FUZZ_VIEWPORT_MAX));
    const viewport_h: f32 = @floatFromInt(smith.valueRangeAtMost(u32, FUZZ_VIEWPORT_MIN, FUZZ_VIEWPORT_MAX));
    engine.beginFrame(viewport_w, viewport_h);

    var state: TreeState = .{ .smith = smith, .arena = arena.allocator(), .elements_emitted = 0 };
    try emitContainer(&engine, &state, 0, .{});

    while (engine.open_element_stack.len > 0) engine.closeElement();

    try engine.endFrame();
    try assertBoundsFinite(&engine);
    try assertCellsOnColumns(&engine);
}

pub fn fuzzTextWrapping(_: void, smith: *std.testing.Smith) anyerror!void {
    var engine = try LayoutEngine.init(&fuzz_capacity);
    defer engine.deinit();
    engine.setMeasureTextFn(fuzzMeasureText, null);

    const viewport_w: f32 = @floatFromInt(smith.valueRangeAtMost(u32, FUZZ_VIEWPORT_MIN, FUZZ_VIEWPORT_MAX));
    engine.beginFrame(viewport_w, 1024);

    try engine.openElement(.{
        .layout = .{
            .sizing = Sizing.fixed(viewport_w, 1024),
            .padding = Padding.all(8),
            .layout_direction = .top_to_bottom,
        },
    });

    var text_buf: [MAX_FUZZ_TEXT_LEN]u8 = undefined;
    const written = smith.slice(&text_buf);
    const text = sanitizeText(text_buf[0..written]);
    const wrap_mode: types.TextConfig.WrapMode = switch (smith.valueRangeAtMost(u8, 0, 3)) {
        0 => .none,
        1 => .newlines,
        else => .words,
    };
    const line_count_max = if (wrap_mode == .none) 0 else smith.valueRangeAtMost(u8, 0, 4);
    const config: types.TextConfig = .{
        .wrap_mode = wrap_mode,
        .font_size = 14,
        .line_count_max = line_count_max,
        .overflow = if (smith.boolWeighted(1, 1)) .ellipsis else .clip,
    };
    try engine.text(text, config);
    engine.closeElement();

    try engine.endFrame();
    try assertTruncated(&engine, config, viewport_w - 16);
}

fn assertTruncated(engine: *const LayoutEngine, config: types.TextConfig, width: f32) !void {
    const text = engine.elements.getConst(1);
    const data = text.text_data.?;
    const lines = data.wrapped_lines orelse return;
    if (config.line_count_max > 0) try std.testing.expect(lines.len <= config.line_count_max);
    for (lines) |line| {
        if (line.extent.end == .whole) continue;
        try std.testing.expect(config.overflow == .ellipsis);
        try std.testing.expect(line.width <= @max(0, width));
    }
    if (config.wrap_mode != .none and lines.len > 0) {
        const count: f32 = @floatFromInt(lines.len);
        const height = count * config.lineHeightPx();
        try std.testing.expectApproxEqAbs(height, data.measured_height, 0.01);
    }
}

const TreeState = struct {
    smith: *std.testing.Smith,
    arena: std.mem.Allocator,
    elements_emitted: u32,
};

const Parent = struct {
    column_count: u8 = 0,
    row_cursor: ?*u8 = null,
};

const FUZZ_GRID_COLUMNS_MAX: u8 = 6;

fn emitContainer(
    engine: *LayoutEngine,
    state: *TreeState,
    depth: u32,
    parent: Parent,
) anyerror!void {
    if (state.elements_emitted >= MAX_FUZZ_ELEMENTS) return;
    if (depth >= MAX_FUZZ_DEPTH) return;
    std.debug.assert(parent.column_count <= FUZZ_GRID_COLUMNS_MAX);

    const smith = state.smith;
    if (parent.row_cursor) |cursor| {
        if (cursor.* >= parent.column_count) return;
    }
    const row_box = parent.column_count > 0 and parent.row_cursor == null and
        smith.boolWeighted(1, 3);
    const is_grid = !row_box and smith.boolWeighted(1, 4);
    const layout_direction: types.LayoutDirection =
        if (row_box or is_grid or smith.boolWeighted(1, 1)) .left_to_right else .top_to_bottom;
    const padding_amt: u16 = @intCast(smith.valueRangeAtMost(u16, 0, 16));
    const wrap = layout_direction == .left_to_right and !row_box and !is_grid and
        smith.boolWeighted(1, 3);
    const aspect_ratio: ?f32 = if (!row_box and smith.boolWeighted(1, 7))
        @as(f32, @floatFromInt(smith.valueRangeAtMost(u32, 1, 16))) / 4.0
    else
        null;
    var padding = Padding.all(padding_amt);
    if (row_box) {
        padding.left = 0;
        padding.right = 0;
    }
    var columns: [FUZZ_GRID_COLUMNS_MAX]types.Track = undefined;
    const column_count: u8 = if (is_grid) randomTracks(smith, &columns) else 0;
    const config: types.GridConfig = .{
        .columns = columns[0..column_count],
        .row_gap = @floatFromInt(smith.valueRangeAtMost(u16, 0, 16)),
    };

    try engine.openElementWith(.{ .layout = .{
        .sizing = if (row_box) Sizing.horizontalFill() else randomSizing(smith),
        .padding = padding,
        .child_gap = @intCast(smith.valueRangeAtMost(u16, 0, 16)),
        .layout_direction = layout_direction,
        .aspect_ratio = aspect_ratio,
        .wrap = wrap,
        .grid = if (row_box) .row else if (is_grid) .grid else .none,
    } }, .{
        .grid = if (is_grid) &config else null,
        .cell = if (parent.column_count > 0 and !row_box) randomCell(smith, parent) else .{},
    });
    state.elements_emitted += 1;

    var row_cursor: u8 = 0;
    const inner: Parent = if (is_grid)
        .{ .column_count = column_count }
    else if (row_box)
        .{ .column_count = parent.column_count, .row_cursor = &row_cursor }
    else
        .{};
    const child_count = smith.valueRangeAtMost(u32, 0, MAX_FUZZ_CHILDREN_PER_NODE);
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        if (state.elements_emitted >= MAX_FUZZ_ELEMENTS) break;
        try emitContainer(engine, state, depth + 1, inner);
    }

    engine.closeElement();
}

fn randomTracks(smith: *std.testing.Smith, columns: *[FUZZ_GRID_COLUMNS_MAX]types.Track) u8 {
    const count = smith.valueRangeAtMost(u8, 1, FUZZ_GRID_COLUMNS_MAX);
    for (columns[0..count]) |*track| {
        var axis = randomSizingAxis(smith);
        if (axis.value == .grow and smith.boolWeighted(1, 3)) {
            const min: f32 = @floatFromInt(smith.valueRangeAtMost(u32, 0, 64));
            const max: f32 = min + @as(f32, @floatFromInt(smith.valueRangeAtMost(u32, 0, 256)));
            axis = SizingAxis.growMinMax(min, max);
        }
        track.* = .{
            .axis = axis,
            .alignment = @fromBackingInt(@intCast(smith.valueRangeLessThan(u8, 0, 4))),
        };
    }
    std.debug.assert(count >= 1);
    return count;
}

fn randomCell(smith: *std.testing.Smith, parent: Parent) types.Cell {
    std.debug.assert(parent.column_count >= 1);
    const first: u8 = if (parent.row_cursor) |cursor| cursor.* else 0;
    std.debug.assert(first < parent.column_count);
    const span = smith.valueRangeAtMost(u8, 1, parent.column_count - first);
    const auto = smith.boolWeighted(1, 3);
    const last = parent.column_count - span;
    const column = if (auto) first else smith.valueRangeAtMost(u8, first, last);
    if (parent.row_cursor) |cursor| cursor.* = column + span;
    if (auto) return .{ .column_span = span };
    return .{ .column = column, .column_span = span };
}

fn randomSizing(smith: *std.testing.Smith) Sizing {
    return .{
        .width = randomSizingAxis(smith),
        .height = randomSizingAxis(smith),
    };
}

fn randomSizingAxis(smith: *std.testing.Smith) SizingAxis {
    const kind = smith.valueRangeLessThan(u8, 0, 4);
    return switch (kind) {
        0 => SizingAxis.fit(),
        1 => SizingAxis.grow(),
        2 => SizingAxis.fixed(@floatFromInt(smith.valueRangeAtMost(u32, 0, 256))),
        3 => SizingAxis.percent(@as(f32, @floatFromInt(smith.valueRangeAtMost(u32, 0, 100))) / 100.0),
        else => unreachable,
    };
}

fn fuzzMeasureText(
    text: []const u8,
    _: u16,
    font_size: u16,
    _: ?f32,
    _: ?*anyopaque,
) engine_mod.TextMeasurement {
    return .{
        .width = @as(f32, @floatFromInt(text.len)) * 10.0,
        .height = @floatFromInt(font_size),
    };
}

fn sanitizeText(buf: []u8) []const u8 {
    std.debug.assert(buf.len <= MAX_FUZZ_TEXT_LEN);
    for (buf) |*b| {
        if (b.* >= 0x80) b.* = ' ';
        if (b.* == 0) b.* = ' ';
    }
    return buf;
}

fn assertBoundsFinite(engine: *const LayoutEngine) !void {
    const elements = engine.elements.items();
    try std.testing.expect(elements.len > 0);
    for (elements) |element| {
        const b = element.computed.bounding_box;
        try std.testing.expect(std.math.isFinite(b.x));
        try std.testing.expect(std.math.isFinite(b.y));
        try std.testing.expect(std.math.isFinite(b.width));
        try std.testing.expect(std.math.isFinite(b.height));
        try std.testing.expect(b.width >= 0);
        try std.testing.expect(b.height >= 0);
    }
}

fn assertCellsOnColumns(engine: *const LayoutEngine) !void {
    const elements = engine.elements.items();
    for (elements) |*element| {
        if (element.config.layout.grid != .grid) continue;
        const slot = layout.grid.slotOf(engine, element);
        var column: u8 = 1;
        while (column < slot.column_count) : (column += 1) {
            const previous_end = slot.column_left[column - 1] + slot.column_width[column - 1];
            try std.testing.expect(slot.column_left[column] >= previous_end - 0.01);
        }
        const content_left = element.computed.bounding_box.x +
            @as(f32, @floatFromInt(element.config.layout.padding.left));
        var cursor = element.first_child_index;
        while (cursor) |index| {
            const child = engine.elements.getConst(index);
            cursor = child.next_sibling_index;
            if (child.config.layout.grid == .row) {
                var inner = child.first_child_index;
                while (inner) |cell_index| {
                    const cell = engine.elements.getConst(cell_index);
                    inner = cell.next_sibling_index;
                    try expectCellOnColumns(slot, content_left, cell);
                }
            } else {
                try expectCellOnColumns(slot, content_left, child);
            }
        }
    }
}

fn expectCellOnColumns(
    slot: *const layout.grid.GridSlot,
    content_left: f32,
    cell: *const layout.engine.LayoutElement,
) !void {
    if (cell.config.floating != null) return;
    if (cell.config.layout.sizing.width.value != .grow) return;
    std.debug.assert(cell.cell_column < slot.column_count);
    const box = cell.computed.bounding_box;
    const cell_width = slot.cellWidth(cell.cell_column, cell.cell_span);
    const tolerance: f32 = 0.01 * @max(1, cell_width);
    const left = content_left + slot.column_left[cell.cell_column];
    try std.testing.expectApproxEqAbs(left, box.x, tolerance);
    try std.testing.expect(box.width >= cell_width - tolerance);
    if (cell.computed.floor_width <= cell_width) {
        try std.testing.expectApproxEqAbs(cell_width, box.width, tolerance);
    }
}

test "fuzz: layout tree" {
    try std.testing.fuzz({}, fuzzLayoutTree, .{});
}

test "fuzz: text wrapping" {
    try std.testing.fuzz({}, fuzzTextWrapping, .{});
}
