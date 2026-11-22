//! Grid layout through the engine (`docs/layout-grid.md`). Each test states
//! the sizes it expects and how they follow from the spec, so a wrong
//! placement, sharing, or shrinking rule gives a different number.

const std = @import("std");

const engine_mod = @import("engine.zig");
const types = @import("types.zig");

const LayoutEngine = engine_mod.LayoutEngine;
const LayoutCapacity = engine_mod.LayoutCapacity;
const TextMeasurement = engine_mod.TextMeasurement;
const ResourceLimits = @import("../core/limits.zig").ResourceLimits;
const SizingAxis = types.SizingAxis;
const Sizing = types.Sizing;
const Track = types.Track;
const GridConfig = types.GridConfig;
const Cell = types.Cell;

const test_capacity = LayoutCapacity.fromLimits(&ResourceLimits.standard);
const expectEqual = std.testing.expectEqual;
const expectApprox = std.testing.expectApproxEqAbs;

fn measureTenPixelsPerCharacter(
    text: []const u8,
    _: u16,
    font_size: u16,
    _: ?f32,
    _: ?*anyopaque,
) TextMeasurement {
    std.debug.assert(font_size > 0);
    return .{ .width = @as(f32, @floatFromInt(text.len)) * 10, .height = @floatFromInt(font_size) };
}

const wrapped: types.TextConfig = .{ .wrap_mode = .words, .font_size = 10, .line_height = 100 };

fn fixedTrack(size: f32) Track {
    return .{ .axis = SizingAxis.fixed(size) };
}

fn growTrack(weight: f32) Track {
    return .{ .axis = SizingAxis.growWeighted(weight, 0, std.math.floatMax(f32)) };
}

const fit_track: Track = .{};

fn startEngine(engine: *LayoutEngine) void {
    engine.setMeasureTextFn(measureTenPixelsPerCharacter, null);
    engine.beginFrame(800, 600);
}

/// Open a grid box of `width` with `config`, `gap` between columns.
fn openGrid(
    engine: *LayoutEngine,
    width: SizingAxis,
    height: SizingAxis,
    gap: u16,
    config: *const GridConfig,
) !void {
    try engine.openElementWith(.{ .layout = .{
        .sizing = .{ .width = width, .height = height },
        .child_gap = gap,
        .grid = .grid,
    } }, .{ .grid = config });
}

/// A childless cell box of a fixed size.
fn leaf(engine: *LayoutEngine, width: f32, height: f32, cell: Cell) !void {
    const decl: engine_mod.ElementDeclaration = .{
        .layout = .{ .sizing = Sizing.fixed(width, height) },
    };
    try engine.openElementWith(decl, .{ .cell = cell });
    engine.closeElement();
}

fn box(engine: *const LayoutEngine, index: u32) types.BoundingBox {
    std.debug.assert(index < engine.elements.len());
    return engine.elements.getConst(index).computed.bounding_box;
}

test "cells place row-major: spans, explicit columns, and new rows" {
    // Three 100 px columns, gaps of 10, rows 5 apart, 20 px leaves. A spans
    // two; B fits after it. C spans three and starts row 1. D asks column 1,
    // before the cursor (3), so starts row 2 there; E asks column 0, before
    // the cursor (2), so starts row 3. Rows are 20 tall: tops 0, 25, 50, 75.
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();
    startEngine(&engine);
    const columns = [_]Track{ fixedTrack(100), fixedTrack(100), fixedTrack(100) };
    try openGrid(&engine, SizingAxis.fixed(320), SizingAxis.fit(), 10, &.{
        .columns = &columns,
        .row_gap = 5,
    });
    try leaf(&engine, 20, 20, .{ .column_span = 2 });
    try leaf(&engine, 20, 20, .{});
    try leaf(&engine, 20, 20, .{ .column_span = 3 });
    try leaf(&engine, 20, 20, .{ .column = 1 });
    try leaf(&engine, 20, 20, .{ .column = 0 });
    engine.closeElement();
    try engine.endFrame();

    const expected = [_][2]f32{ .{ 0, 0 }, .{ 220, 0 }, .{ 0, 25 }, .{ 110, 50 }, .{ 0, 75 } };
    for (expected, 1..) |position, index| {
        try expectEqual(position[0], box(&engine, @intCast(index)).x);
        try expectEqual(position[1], box(&engine, @intCast(index)).y);
    }
    try expectEqual(@as(f32, 95), box(&engine, 0).height); // Four 20 px rows, three gaps.
}

test "fit columns line up across rows of different content" {
    // Two fit columns, gap 10: column 0 is the widest of 30 and 70, so
    // column 1 starts at 80 in both rows, and the grid is 80 + 50 wide.
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();
    startEngine(&engine);
    const columns = [_]Track{ fit_track, fit_track };
    try openGrid(&engine, SizingAxis.fit(), SizingAxis.fit(), 10, &.{ .columns = &columns });
    try leaf(&engine, 30, 10, .{});
    try leaf(&engine, 50, 10, .{});
    try leaf(&engine, 70, 10, .{});
    try leaf(&engine, 20, 10, .{});
    engine.closeElement();
    try engine.endFrame();

    try expectEqual(@as(f32, 80), box(&engine, 2).x);
    try expectEqual(@as(f32, 80), box(&engine, 4).x);
    try expectEqual(@as(f32, 130), box(&engine, 0).width);
}

test "grow columns share by weight, and one held at its minimum gives way" {
    // 400 px, weights 1 and 3: shares 100 and 300. Column 1 holds a 350 px
    // cell, above its share, so it stays at 350 and column 0 takes the 50
    // left; sharing in proportion alone would give 100 and 300 and cut it.
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();
    startEngine(&engine);
    const columns = [_]Track{ growTrack(1), growTrack(3) };
    try openGrid(&engine, SizingAxis.fixed(400), SizingAxis.fit(), 0, &.{ .columns = &columns });
    try leaf(&engine, 10, 10, .{});
    try leaf(&engine, 350, 10, .{});
    engine.closeElement();
    try engine.endFrame();

    try expectApprox(@as(f32, 50), box(&engine, 2).x, 0.001);
    // Without the wide cell the shares are 100 and 300.
    startEngine(&engine);
    try openGrid(&engine, SizingAxis.fixed(400), SizingAxis.fit(), 0, &.{ .columns = &columns });
    try leaf(&engine, 10, 10, .{});
    try leaf(&engine, 10, 10, .{});
    engine.closeElement();
    try engine.endFrame();
    try expectApprox(@as(f32, 100), box(&engine, 2).x, 0.001);
}

test "equal grow columns stay equal under a long spanning text" {
    // Four grow(1) columns in 400 px: CSS `1fr`, so 100 each. The text
    // spanning columns 1 to 3 is 490 px unwrapped, but its widest word is
    // 40, so it wraps in its 300 px cell. Growing from the unwrapped width
    // instead would widen columns 1 to 3 and squeeze column 0.
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();
    startEngine(&engine);
    const columns = [_]Track{ growTrack(1), growTrack(1), growTrack(1), growTrack(1) };
    try openGrid(&engine, SizingAxis.fixed(400), SizingAxis.fit(), 0, &.{ .columns = &columns });
    try engine.text("aa", wrapped);
    try engine.openElementWith(.{ .layout = .{ .sizing = .{
        .width = SizingAxis.grow(),
        .height = SizingAxis.fit(),
    } } }, .{ .cell = .{ .column_span = 3 } });
    try engine.text("aaaa aaaa aaaa aaaa aaaa aaaa aaaa aaaa aaaa aaaa", wrapped);
    engine.closeElement();
    engine.closeElement();
    try engine.endFrame();

    try expectApprox(@as(f32, 100), box(&engine, 2).x, 0.001);
    try expectApprox(@as(f32, 300), box(&engine, 2).width, 0.001);
    try expectEqual(@as(f32, 20), box(&engine, 3).height); // Six words, then four.
}

test "overflowing columns shrink largest first, down to their floors" {
    // Fit columns of 300, 100, and 40 px texts in 320 px must lose 120. The
    // 300 px text's widest word is 100, so it can: largest first gives
    // 180, 100, 40. Shrinking in proportion would cut the 40 px word. At
    // 180 the first text wraps to 100, then 190 does not fit: three lines.
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();
    startEngine(&engine);
    const columns = [_]Track{ fit_track, fit_track, fit_track };
    try openGrid(&engine, SizingAxis.fixed(320), SizingAxis.fit(), 0, &.{ .columns = &columns });
    try engine.text("aaaaaaaaaa aaaaaaaaa aaaaaaaaa", wrapped);
    try engine.text("bbbbbbbbbb", wrapped);
    try engine.text("cccc", wrapped);
    engine.closeElement();
    try engine.endFrame();

    try expectApprox(@as(f32, 180), box(&engine, 2).x, 0.01);
    try expectApprox(@as(f32, 280), box(&engine, 3).x, 0.01);
    try expectEqual(@as(f32, 30), box(&engine, 1).height);
}

test "percent columns are fractions of the width less the gaps" {
    // Four 25 % columns with gaps of 10 in 430 px: 100 each, filling it.
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();
    startEngine(&engine);
    const quarter: Track = .{ .axis = SizingAxis.percent(0.25) };
    const columns = [_]Track{ quarter, quarter, quarter, quarter };
    try openGrid(&engine, SizingAxis.fixed(430), SizingAxis.fit(), 10, &.{ .columns = &columns });
    for (0..4) |_| {
        try engine.openElement(.{ .layout = .{ .sizing = .{
            .width = SizingAxis.grow(),
            .height = SizingAxis.fixed(10),
        } } });
        engine.closeElement();
    }
    engine.closeElement();
    try engine.endFrame();

    for (0..4) |column| {
        const cell = box(&engine, @intCast(column + 1));
        try expectEqual(@as(f32, 100), cell.width);
        try expectEqual(@as(f32, 110) * @as(f32, @floatFromInt(column)), cell.x);
    }
}

test "a spanning header widens its fit columns to keep its text whole" {
    // Two fit columns, gap 10, under a 250 px header spanning both. The
    // cells below need 50 and 70, 130 with the gap, so each column takes
    // half of the 120 the header lacks: 110 and 130.
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();
    startEngine(&engine);
    const columns = [_]Track{ fit_track, fit_track };
    try openGrid(&engine, SizingAxis.fit(), SizingAxis.fit(), 10, &.{ .columns = &columns });
    try leaf(&engine, 250, 10, .{ .column_span = 2 });
    try leaf(&engine, 50, 10, .{});
    try leaf(&engine, 70, 10, .{});
    engine.closeElement();
    try engine.endFrame();

    try expectEqual(@as(f32, 120), box(&engine, 3).x);
    try expectEqual(@as(f32, 250), box(&engine, 0).width);
}

test "grow rows share a fixed grid's height and fall back to fit in a fit grid" {
    // Rows fit and grow(1), 10 apart, two columns of 30 px cells, but one
    // cell of the second row has a grow height. In a 200 px grid the grow
    // row takes 200 - 30 - 10 = 160 and that cell fills it; in a fit-height
    // grid the row is 30, its tallest cell, and the cell fills that.
    const heights = [_]SizingAxis{ SizingAxis.fixed(200), SizingAxis.fit() };
    const expected = [_]f32{ 160, 30 };
    for (heights, expected) |height, row_height| {
        var engine = try LayoutEngine.init(&test_capacity);
        defer engine.deinit();
        startEngine(&engine);
        const columns = [_]Track{ fixedTrack(50), fixedTrack(50) };
        const rows = [_]Track{ fit_track, growTrack(1) };
        try openGrid(&engine, SizingAxis.fixed(100), height, 0, &.{
            .columns = &columns,
            .rows = &rows,
            .row_gap = 10,
        });
        try leaf(&engine, 50, 30, .{});
        try leaf(&engine, 50, 30, .{});
        try leaf(&engine, 50, 30, .{});
        try engine.openElementWith(.{ .layout = .{ .sizing = .{
            .width = SizingAxis.fixed(50),
            .height = SizingAxis.grow(),
        } } }, .{});
        engine.closeElement();
        engine.closeElement();
        try engine.endFrame();

        try expectEqual(@as(f32, 40), box(&engine, 4).y);
        try expectEqual(row_height, box(&engine, 4).height);
    }
}

test "a wrapped text cell raises its row, its stretched sibling, and its grid" {
    // A 50 px column wraps "aaaa bbbb cccc" to three 10 px lines; its row
    // and the fit-height grid become 30 tall, and the grow-height cell
    // beside it stretches to 30 rather than staying one line tall.
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();
    startEngine(&engine);
    const columns = [_]Track{ fixedTrack(50), fixedTrack(50) };
    try openGrid(&engine, SizingAxis.fit(), SizingAxis.fit(), 0, &.{ .columns = &columns });
    try engine.text("aaaa bbbb cccc", wrapped);
    try engine.openElementWith(.{ .layout = .{ .sizing = .{
        .width = SizingAxis.grow(),
        .height = SizingAxis.grow(),
    } } }, .{});
    engine.closeElement();
    engine.closeElement();
    try engine.endFrame();

    try expectEqual(@as(f32, 30), box(&engine, 1).height);
    try expectEqual(@as(f32, 30), box(&engine, 2).height);
    try expectEqual(@as(f32, 50), box(&engine, 2).x);
    try expectEqual(@as(f32, 30), box(&engine, 0).height);
}

test "row boxes share the grid's columns with its header cells" {
    // Two fit columns, gap 10. The header's cells are 40 and 30 wide; the
    // row box's are 90 and 10, so column 0 is 90 for both and column 1
    // starts at 100 in the header and in the row box. The row box is one
    // row, the grid's width, below the header.
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();
    startEngine(&engine);
    const columns = [_]Track{ fit_track, fit_track };
    try openGrid(&engine, SizingAxis.fit(), SizingAxis.fit(), 10, &.{
        .columns = &columns,
        .row_gap = 4,
    });
    try leaf(&engine, 40, 10, .{});
    try leaf(&engine, 30, 10, .{});
    try engine.openElementWith(.{ .layout = .{
        .sizing = .{ .width = SizingAxis.grow(), .height = SizingAxis.fit() },
        .padding = .{ .top = 3, .bottom = 3 },
        .grid = .row,
    } }, .{});
    try leaf(&engine, 90, 12, .{});
    try leaf(&engine, 10, 12, .{});
    engine.closeElement();
    engine.closeElement();
    try engine.endFrame();

    try expectEqual(@as(f32, 100), box(&engine, 2).x);
    try expectEqual(@as(f32, 100), box(&engine, 5).x);
    const row_box = box(&engine, 3);
    try expectEqual(@as(f32, 14), row_box.y);
    try expectEqual(@as(f32, 130), row_box.width);
    try expectEqual(@as(f32, 18), row_box.height); // 12 and its padding.
    try expectEqual(@as(f32, 17), box(&engine, 5).y);
}

test "a column's alignment places a narrower child at its end" {
    // A 96 px column aligned to its end holds a 20 px leaf at 96 - 20 = 76.
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();
    startEngine(&engine);
    const columns = [_]Track{.{ .axis = SizingAxis.fixed(96), .alignment = .end }};
    try openGrid(&engine, SizingAxis.fit(), SizingAxis.fit(), 0, &.{ .columns = &columns });
    try leaf(&engine, 20, 10, .{});
    engine.closeElement();
    try engine.endFrame();

    try expectEqual(@as(f32, 76), box(&engine, 1).x);
}

test "track min and max bound every kind of column" {
    // 400 px, gap 0: a fit column of min 50 holds a 10 px leaf, so 50; a
    // percent(0.5) column of max 100 is 100, not 200; two grow columns
    // share the 250 left, 125 each, but the first stops at its max of 60
    // and the second takes the rest, 190. Edges at 0, 50, 110, and 210.
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();
    startEngine(&engine);
    const columns = [_]Track{
        .{ .axis = SizingAxis.fitMin(50) },
        .{ .axis = SizingAxis.growMax(60) },
        .{ .axis = SizingAxis.percentMinMax(0.5, 0, 100) },
        growTrack(1),
    };
    try openGrid(&engine, SizingAxis.fixed(400), SizingAxis.fit(), 0, &.{ .columns = &columns });
    try leaf(&engine, 10, 10, .{});
    for (0..3) |_| {
        try engine.openElementWith(.{ .layout = .{ .sizing = .{
            .width = SizingAxis.grow(),
            .height = SizingAxis.fixed(10),
        } } }, .{});
        engine.closeElement();
    }
    engine.closeElement();
    try engine.endFrame();

    try expectApprox(@as(f32, 50), box(&engine, 2).x, 0.001);
    try expectApprox(@as(f32, 60), box(&engine, 2).width, 0.001);
    try expectApprox(@as(f32, 110), box(&engine, 3).x, 0.001);
    try expectApprox(@as(f32, 100), box(&engine, 3).width, 0.001);
    try expectApprox(@as(f32, 210), box(&engine, 4).x, 0.001);
    try expectApprox(@as(f32, 190), box(&engine, 4).width, 0.001);
}

test "an aspect child in a spanning cell takes its height from the span" {
    // Three fixed 50 px columns, gap 10. A grow-width child of aspect 2
    // spanning two columns is 50 + 10 + 50 = 110 wide, so 55 tall, and its
    // row and the fit-height grid are 55; one column wide it would be 25.
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();
    startEngine(&engine);
    const columns = [_]Track{ fixedTrack(50), fixedTrack(50), fixedTrack(50) };
    try openGrid(&engine, SizingAxis.fit(), SizingAxis.fit(), 10, &.{ .columns = &columns });
    try engine.openElementWith(.{ .layout = .{
        .sizing = .{ .width = SizingAxis.grow(), .height = SizingAxis.fit() },
        .aspect_ratio = 2,
    } }, .{ .cell = .{ .column_span = 2 } });
    engine.closeElement();
    try leaf(&engine, 20, 10, .{});
    engine.closeElement();
    try engine.endFrame();

    try expectApprox(@as(f32, 110), box(&engine, 1).width, 0.001);
    try expectApprox(@as(f32, 55), box(&engine, 1).height, 0.001);
    try expectEqual(@as(f32, 120), box(&engine, 2).x);
    try expectApprox(@as(f32, 55), box(&engine, 0).height, 0.001);
}

test "a nested grid sizes its columns in its parent's cell" {
    // An outer grid of two grow(1) columns in 200 px puts the inner grid
    // in a 100 px cell at x 100. The inner grid's fit column takes its
    // 30 px leaf and its grow column the 70 left, so its grow-width cell
    // starts at 130 and is 70 wide, not the outer grid's 170.
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();
    startEngine(&engine);
    const outer = [_]Track{ growTrack(1), growTrack(1) };
    const inner = [_]Track{ fit_track, growTrack(1) };
    try openGrid(&engine, SizingAxis.fixed(200), SizingAxis.fit(), 0, &.{ .columns = &outer });
    try leaf(&engine, 10, 10, .{});
    try openGrid(&engine, SizingAxis.grow(), SizingAxis.fit(), 0, &.{ .columns = &inner });
    try leaf(&engine, 30, 10, .{});
    try engine.openElementWith(.{ .layout = .{ .sizing = .{
        .width = SizingAxis.grow(),
        .height = SizingAxis.fixed(10),
    } } }, .{});
    engine.closeElement();
    engine.closeElement();
    engine.closeElement();
    try engine.endFrame();

    try expectEqual(@as(f32, 100), box(&engine, 2).x);
    try expectEqual(@as(f32, 100), box(&engine, 2).width);
    try expectEqual(@as(f32, 130), box(&engine, 4).x);
    try expectEqual(@as(f32, 70), box(&engine, 4).width);
}

test "floating children take no cell" {
    // A floating child between two cells does not move the second cell to
    // the next column; a grid with only a floating child has no rows.
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();
    startEngine(&engine);
    const columns = [_]Track{ fixedTrack(40), fixedTrack(40) };
    try openGrid(&engine, SizingAxis.fit(), SizingAxis.fit(), 0, &.{ .columns = &columns });
    try leaf(&engine, 10, 10, .{});
    try engine.openElement(.{
        .layout = .{ .sizing = Sizing.fixed(5, 5) },
        .floating = .{ .attach_to_parent = true },
    });
    engine.closeElement();
    try leaf(&engine, 10, 10, .{});
    try openGrid(&engine, SizingAxis.fit(), SizingAxis.fit(), 0, &.{ .columns = &columns });
    try engine.openElement(.{
        .layout = .{ .sizing = Sizing.fixed(5, 5) },
        .floating = .{ .attach_to_parent = true },
    });
    engine.closeElement();
    engine.closeElement();
    engine.closeElement();
    try engine.endFrame();

    try expectEqual(@as(f32, 40), box(&engine, 3).x);
    try expectEqual(@as(f32, 0), box(&engine, 4).height);
}

test "a grid holds exactly its budget of grid slots" {
    // Goal: the slot pool is reserved, not grown. Method: open
    // `grid_count_max` grids in one frame, then check the last one laid
    // out; one more panics, which the fail-fast check covers.
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();
    startEngine(&engine);
    const columns = [_]Track{fixedTrack(7)};
    try engine.openElement(.{ .layout = .{ .sizing = Sizing.fixed(800, 600) } });
    var index: u32 = 0;
    while (index < test_capacity.grid_count_max) : (index += 1) {
        try openGrid(&engine, SizingAxis.fit(), SizingAxis.fit(), 0, &.{ .columns = &columns });
        engine.closeElement();
    }
    engine.closeElement();
    try engine.endFrame();

    try expectEqual(test_capacity.grid_count_max, engine.grid_count);
    try expectEqual(@as(f32, 7), box(&engine, test_capacity.grid_count_max).width);
}
