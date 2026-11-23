const std = @import("std");

const assert = std.debug.assert;

const engine_mod = @import("engine.zig");
const sizing_pass = @import("sizing_pass.zig");
const types = @import("types.zig");

const LayoutEngine = engine_mod.LayoutEngine;
const ElementDeclaration = engine_mod.ElementDeclaration;
const BoundedList = engine_mod.BoundedList;
const WordInfo = engine_mod.WordInfo;
const TextMeasurement = engine_mod.TextMeasurement;
const LayoutCapacity = engine_mod.LayoutCapacity;
const ResourceLimits = @import("../core/limits.zig").ResourceLimits;

const test_capacity = LayoutCapacity.fromLimits(&ResourceLimits.standard);

const Sizing = types.Sizing;
const SizingAxis = types.SizingAxis;
const LayoutConfig = types.LayoutConfig;
const LayoutDirection = types.LayoutDirection;
const Padding = types.Padding;
const ChildAlignment = types.ChildAlignment;
const Color = types.Color;
const CornerRadius = types.CornerRadius;
const TextConfig = types.TextConfig;
const Offset2D = types.Offset2D;

fn boundingBox(engine: *const LayoutEngine, index: u32) types.BoundingBox {
    assert(index < engine.elements.len());
    const bounds = engine.elements.getConst(index).computed.bounding_box;
    assert(bounds.width >= 0);
    return bounds;
}

test "basic layout" {
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();

    engine.beginFrame(800, 600);

    try engine.openElement(.{
        .layout = .{ .sizing = Sizing.fill() },
        .background_color = Color.white,
    });
    engine.closeElement();

    try engine.endFrame();
    const root = boundingBox(&engine, 0);
    try std.testing.expectEqual(@as(f32, 800), root.width);
    try std.testing.expectEqual(@as(f32, 600), root.height);
}

test "root fill follows viewport resize" {
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();

    engine.beginFrame(320, 240);
    try engine.openElement(.{
        .layout = .{ .sizing = .{
            .width = SizingAxis.percent(1.0),
            .height = SizingAxis.percent(1.0),
        } },
    });
    engine.closeElement();
    try engine.endFrame();

    const initial = boundingBox(&engine, 0);
    try std.testing.expectEqual(@as(f32, 320), initial.width);
    try std.testing.expectEqual(@as(f32, 240), initial.height);

    engine.beginFrame(1024, 576);
    try engine.openElement(.{
        .layout = .{ .sizing = .{
            .width = SizingAxis.percent(1.0),
            .height = SizingAxis.percent(1.0),
        } },
    });
    engine.closeElement();
    try engine.endFrame();

    const resized = boundingBox(&engine, 0);
    try std.testing.expectEqual(@as(f32, 1024), resized.width);
    try std.testing.expectEqual(@as(f32, 576), resized.height);
}

test "nested layout" {
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();

    engine.beginFrame(800, 600);

    try engine.openElement(.{
        .layout = .{ .sizing = Sizing.fill(), .layout_direction = .top_to_bottom },
    });
    {
        try engine.openElement(.{
            .layout = .{ .sizing = .{ .width = SizingAxis.grow(), .height = SizingAxis.fixed(100) } },
            .background_color = Color.red,
        });
        engine.closeElement();

        try engine.openElement(.{
            .layout = .{ .sizing = Sizing.fill() },
            .background_color = Color.blue,
        });
        engine.closeElement();
    }
    engine.closeElement();

    try engine.endFrame();
}

test "shrink behavior" {
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();

    engine.beginFrame(200, 100);

    try engine.openElement(.{
        .layout = .{ .sizing = Sizing.fill(), .layout_direction = .left_to_right },
    });
    {
        try engine.openElement(.{
            .layout = .{
                .sizing = .{
                    .width = SizingAxis.fitMax(150),
                    .height = SizingAxis.fixed(50),
                },
            },
            .background_color = Color.red,
        });
        engine.closeElement();

        try engine.openElement(.{
            .layout = .{ .sizing = .{ .width = SizingAxis.fitMax(150), .height = SizingAxis.fixed(50) } },
            .background_color = Color.blue,
        });
        engine.closeElement();
    }
    engine.closeElement();

    try engine.endFrame();

    const child1 = engine.elements.getConst(1);
    const child2 = engine.elements.getConst(2);
    try std.testing.expect(child1.computed.sized_width <= 100);
    try std.testing.expect(child2.computed.sized_width <= 100);
}

test "a grow scroll container's children overflow it instead of shrinking" {
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();

    engine.beginFrame(200, 100);
    try engine.openElement(.{ .layout = .{ .sizing = Sizing.fill(), .layout_direction = .top_to_bottom } });
    try engine.openElement(.{
        .layout = .{ .sizing = Sizing.fill(), .layout_direction = .top_to_bottom },
        .scroll = .{ .vertical = true },
    });
    try engine.openElement(.{ .layout = .{ .layout_direction = .top_to_bottom } });
    for (0..2) |_| {
        try engine.openElement(.{ .layout = .{ .sizing = .{
            .width = SizingAxis.fixed(50),
            .height = SizingAxis.fixed(80),
        } } });
        engine.closeElement();
    }
    engine.closeElement();
    engine.closeElement();
    engine.closeElement();
    try engine.endFrame();

    try std.testing.expectEqual(@as(f32, 100), engine.elements.getConst(1).computed.sized_height);
    try std.testing.expectEqual(@as(f32, 160), engine.elements.getConst(2).computed.sized_height);
}

test "aspect ratio" {
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();

    engine.beginFrame(800, 600);

    try engine.openElement(.{
        .layout = .{
            .sizing = .{ .width = SizingAxis.fixed(160), .height = SizingAxis.fit() },
            .aspect_ratio = 16.0 / 9.0,
        },
        .background_color = Color.white,
    });
    engine.closeElement();

    try engine.endFrame();

    const elem = engine.elements.getConst(0);
    try std.testing.expectApproxEqAbs(@as(f32, 90), elem.computed.sized_height, 0.1);
}

test "percent with min/max" {
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();

    engine.beginFrame(800, 600);

    try engine.openElement(.{
        .layout = .{
            .sizing = .{
                .width = SizingAxis.percentMinMax(0.5, 100, 300),
                .height = SizingAxis.fixed(50),
            },
        },
        .background_color = Color.white,
    });
    engine.closeElement();

    try engine.endFrame();

    const elem = engine.elements.getConst(0);
    try std.testing.expectEqual(@as(f32, 300), elem.computed.sized_width);
}

test "percent children take their fraction once, less the gaps" {
    const directions = [_]LayoutDirection{ .left_to_right, .top_to_bottom };
    for (directions) |direction| {
        var engine = try LayoutEngine.init(&test_capacity);
        defer engine.deinit();
        engine.beginFrame(800, 600);

        const is_row = direction == .left_to_right;
        try engine.openElement(.{ .layout = .{
            .sizing = Sizing.fixed(400, 400),
            .layout_direction = direction,
            .child_gap = 10,
        } });
        const mains = [_]SizingAxis{
            SizingAxis.percent(0.5),
            SizingAxis.percent(0.25),
            SizingAxis.grow(),
        };
        for (mains) |main| {
            const sizing: Sizing = if (is_row)
                .{ .width = main, .height = SizingAxis.fixed(10) }
            else
                .{ .width = SizingAxis.fixed(10), .height = main };
            try engine.openElement(.{ .layout = .{ .sizing = sizing } });
            engine.closeElement();
        }
        engine.closeElement();
        try engine.endFrame();

        const expected = [_]f32{ 190, 95, 95 };
        for (expected, 1..) |size, index| {
            const bounds = boundingBox(&engine, @intCast(index));
            const main_size = if (is_row) bounds.width else bounds.height;
            try std.testing.expectApproxEqAbs(size, main_size, 0.01);
        }
    }
}

test "floating positioning" {
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();

    engine.beginFrame(800, 600);

    try engine.openElement(.{
        .layout = .{ .sizing = Sizing.fixed(200, 100) },
        .background_color = Color.white,
    });
    {
        try engine.openElement(.{
            .layout = .{ .sizing = Sizing.fixed(150, 80) },
            .floating = types.FloatingConfig.dropdown(),
            .background_color = Color.blue,
        });
        engine.closeElement();
    }
    engine.closeElement();

    try engine.endFrame();

    const parent = engine.elements.getConst(0);
    const floating = engine.elements.getConst(1);

    try std.testing.expectEqual(parent.computed.bounding_box.x, floating.computed.bounding_box.x);
    try std.testing.expectEqual(parent.computed.bounding_box.y + parent.computed.bounding_box.height, floating.computed.bounding_box.y);
}

test "floating elements don't affect parent sizing or sibling layout" {
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();

    engine.beginFrame(800, 600);

    try engine.openElement(.{
        .layout = .{
            .sizing = Sizing.fitContent(),
            .layout_direction = .top_to_bottom,
            .child_gap = 10,
        },
        .background_color = Color.white,
    });
    {
        try engine.openElement(.{
            .layout = .{ .sizing = Sizing.fixed(100, 50) },
            .background_color = Color.red,
        });
        engine.closeElement();

        try engine.openElement(.{
            .layout = .{ .sizing = Sizing.fixed(200, 300) },
            .floating = types.FloatingConfig.dropdown(),
            .background_color = Color.blue,
        });
        engine.closeElement();

        try engine.openElement(.{
            .layout = .{ .sizing = Sizing.fixed(100, 50) },
            .background_color = Color.green,
        });
        engine.closeElement();
    }
    engine.closeElement();

    try engine.endFrame();

    const parent = engine.elements.getConst(0);
    const regular_child = engine.elements.getConst(1);
    const second_child = engine.elements.getConst(3);

    try std.testing.expectEqual(@as(f32, 100), parent.computed.sized_width);
    try std.testing.expectEqual(@as(f32, 110), parent.computed.sized_height);

    try std.testing.expectEqual(regular_child.computed.bounding_box.y + 50 + 10, second_child.computed.bounding_box.y);
}

test "text wrapping creates multiple lines" {
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();

    const mockMeasure = struct {
        fn measure(
            text: []const u8,
            _: u16,
            font_size: u16,
            _: ?f32,
            _: ?*anyopaque,
        ) TextMeasurement {
            return .{
                .width = @as(f32, @floatFromInt(text.len)) * 10.0,
                .height = @floatFromInt(font_size),
            };
        }
    }.measure;

    engine.setMeasureTextFn(mockMeasure, null);
    engine.beginFrame(800, 600);

    try engine.openElement(.{
        .layout = .{
            .sizing = Sizing.fixed(120, 200),
            .padding = Padding.all(10),
            .layout_direction = .top_to_bottom,
        },
    });
    {
        try engine.text("hello world", .{
            .wrap_mode = .words,
            .font_size = 14,
        });
    }
    engine.closeElement();

    try engine.endFrame();

    const text_elem = engine.elements.getConst(1);
    try std.testing.expect(text_elem.text_data != null);

    const td = text_elem.text_data.?;
    try std.testing.expect(td.wrapped_lines != null);

    const lines = td.wrapped_lines.?;
    try std.testing.expect(lines.len >= 2);
}

test "text wrapping with newlines" {
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();

    const mockMeasure = struct {
        fn measure(
            text: []const u8,
            _: u16,
            font_size: u16,
            _: ?f32,
            _: ?*anyopaque,
        ) TextMeasurement {
            return .{
                .width = @as(f32, @floatFromInt(text.len)) * 10.0,
                .height = @floatFromInt(font_size),
            };
        }
    }.measure;

    engine.setMeasureTextFn(mockMeasure, null);
    engine.beginFrame(800, 600);

    try engine.openElement(.{
        .layout = .{ .sizing = Sizing.fixed(400, 200) },
    });
    {
        try engine.text("line one\nline two\nline three", .{
            .wrap_mode = .newlines,
            .font_size = 14,
        });
    }
    engine.closeElement();

    try engine.endFrame();

    const text_elem = engine.elements.getConst(1);
    const td = text_elem.text_data.?;
    try std.testing.expect(td.wrapped_lines != null);

    const lines = td.wrapped_lines.?;
    try std.testing.expectEqual(@as(usize, 3), lines.len);
}

test "wrapped text grows its fit-content parent" {
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();

    const mockMeasure = struct {
        fn measure(
            text: []const u8,
            _: u16,
            font_size: u16,
            _: ?f32,
            _: ?*anyopaque,
        ) TextMeasurement {
            return .{
                .width = @as(f32, @floatFromInt(text.len)) * 10.0,
                .height = @floatFromInt(font_size),
            };
        }
    }.measure;

    engine.setMeasureTextFn(mockMeasure, null);
    engine.beginFrame(800, 600);

    try engine.openElement(.{
        .layout = .{
            .sizing = .{
                .width = SizingAxis.fixed(100),
                .height = SizingAxis.fit(),
            },
            .layout_direction = .top_to_bottom,
        },
    });
    {
        try engine.text("abcdefghij abcdefghij", .{
            .wrap_mode = .words,
            .font_size = 20,
            .line_height = 100,
        });
    }
    engine.closeElement();

    try engine.endFrame();

    const parent = engine.elements.getConst(0);
    const text_elem = engine.elements.getConst(1);

    try std.testing.expect(text_elem.computed.sized_height >= 40.0);

    try std.testing.expect(parent.computed.sized_height >= text_elem.computed.sized_height);
}

test "wrapped text does not grow a fixed-height ancestor" {
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();

    const mockMeasure = struct {
        fn measure(
            text: []const u8,
            _: u16,
            font_size: u16,
            _: ?f32,
            _: ?*anyopaque,
        ) TextMeasurement {
            return .{
                .width = @as(f32, @floatFromInt(text.len)) * 10.0,
                .height = @floatFromInt(font_size),
            };
        }
    }.measure;

    engine.setMeasureTextFn(mockMeasure, null);
    engine.beginFrame(800, 600);

    try engine.openElement(.{
        .layout = .{
            .sizing = Sizing.fixed(100, 50),
            .layout_direction = .top_to_bottom,
        },
    });
    {
        try engine.openElement(.{
            .layout = .{
                .sizing = .{
                    .width = SizingAxis.fixed(100),
                    .height = SizingAxis.fit(),
                },
                .layout_direction = .top_to_bottom,
            },
        });
        {
            try engine.text("abcdefghij abcdefghij", .{
                .wrap_mode = .words,
                .font_size = 20,
                .line_height = 100,
            });
        }
        engine.closeElement();
    }
    engine.closeElement();

    try engine.endFrame();

    const outer = engine.elements.getConst(0);
    const inner = engine.elements.getConst(1);

    try std.testing.expectEqual(@as(f32, 50.0), outer.computed.sized_height);

    try std.testing.expect(inner.computed.sized_height >= 40.0);
}

test "wrapped text grows its floating panel but not the panel's host" {
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();
    engine.setMeasureTextFn(measureTenPixelsPerCharacter, null);
    engine.beginFrame(800, 600);

    const wrapped: TextConfig = .{ .wrap_mode = .words, .font_size = 20, .line_height = 100 };
    const fit_column: Sizing = .{ .width = SizingAxis.fixed(100), .height = SizingAxis.fit() };
    try engine.openElement(.{
        .layout = .{ .sizing = fit_column, .layout_direction = .top_to_bottom },
    });
    try engine.openElement(.{
        .layout = .{ .sizing = Sizing.fitContent(), .padding = Padding.all(10) },
        .floating = .{},
    });
    try engine.openElement(.{
        .layout = .{ .sizing = fit_column, .layout_direction = .top_to_bottom },
    });
    try engine.text("abcdefghij abcdefghij", wrapped);
    engine.closeElement();
    engine.closeElement();
    try engine.text("abcdefghij abcdefghij", wrapped);
    engine.closeElement();
    try engine.endFrame();

    const panel = boundingBox(&engine, 1);
    const host = boundingBox(&engine, 0);
    try std.testing.expectEqual(@as(f32, 80), panel.height);
    try std.testing.expectEqual(@as(f32, 60), host.height);
}

test "a floating panel sizes its children once, as the main pass does" {
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();
    engine.beginFrame(800, 600);
    try engine.openElement(.{ .layout = .{ .sizing = Sizing.fixed(400, 400) } });
    try engine.openElement(.{
        .layout = .{ .sizing = Sizing.fixed(200, 100) },
        .floating = .{ .attach_to_parent = true },
    });
    try engine.openElement(.{ .layout = .{
        .sizing = .{ .width = SizingAxis.percent(0.5), .height = SizingAxis.fixed(10) },
    } });
    engine.closeElement();
    engine.closeElement();
    engine.closeElement();
    try engine.endFrame();

    try std.testing.expectEqual(@as(f32, 100), boundingBox(&engine, 2).width);
}

test "an overflowing row shrinks its widest children first, down to their floors" {
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();
    engine.setMeasureTextFn(measureTenPixelsPerCharacter, null);
    engine.beginFrame(800, 600);

    const wrapped: TextConfig = .{ .wrap_mode = .words, .font_size = 20, .line_height = 100 };
    try engine.openElement(.{ .layout = .{ .sizing = Sizing.fixed(300, 200) } });
    try engine.text("aaa bbb ccc ddd eee fff ggg hh", wrapped);
    try engine.text("aaa bbb cc", wrapped);
    try engine.text("dddd", wrapped);
    engine.closeElement();
    try engine.endFrame();

    const first = boundingBox(&engine, 1);
    const second = boundingBox(&engine, 2);
    const third = boundingBox(&engine, 3);
    try std.testing.expectApproxEqAbs(@as(f32, 160), second.x - first.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 100), third.x - second.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 40), third.width, 0.01);
    try std.testing.expect(first.width <= 160);
    try std.testing.expectEqual(@as(f32, 40), first.height);
}

test "a column whose shrink lands on a breakpoint by rounding keeps that level" {
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();
    engine.beginFrame(64, 64);
    const fit_column: ElementDeclaration = .{ .layout = .{ .layout_direction = .top_to_bottom } };
    try engine.openElement(fit_column);
    try engine.openElement(fit_column);
    try engine.openElement(fit_column);
    try engine.openElement(.{ .layout = .{
        .sizing = .{ .width = SizingAxis.fit(), .height = SizingAxis.grow() },
        .padding = Padding.all(3),
        .layout_direction = .top_to_bottom,
    } });
    engine.closeElement();
    try engine.openElement(.{ .layout = .{
        .sizing = .{ .width = SizingAxis.fit(), .height = SizingAxis.grow() },
        .layout_direction = .top_to_bottom,
    } });
    try engine.openElement(.{ .layout = .{
        .sizing = .{ .width = SizingAxis.percent(0.01), .height = SizingAxis.fit() },
        .padding = Padding.all(2),
        .aspect_ratio = 0.25,
    } });
    engine.closeElement();
    engine.closeElement();
    engine.closeElement();
    engine.closeElement();
    engine.closeElement();
    try engine.endFrame();

    const percent_row = boundingBox(&engine, 5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.16), percent_row.height, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 6.16), boundingBox(&engine, 2).height, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 6), boundingBox(&engine, 3).height, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 6), boundingBox(&engine, 4).y, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.16), boundingBox(&engine, 4).height, 0.0001);
}

test "a grow box beside a fixed one takes its share and its text wraps there" {
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();
    engine.setMeasureTextFn(measureTenPixelsPerCharacter, null);
    engine.beginFrame(800, 600);

    const wrapped: TextConfig = .{ .wrap_mode = .words, .font_size = 20, .line_height = 100 };
    try engine.openElement(.{ .layout = .{ .sizing = Sizing.fixed(400, 300) } });
    try engine.openElement(.{ .layout = .{ .sizing = Sizing.fixed(100, 10) } });
    engine.closeElement();
    try engine.openElement(.{ .layout = .{
        .sizing = .{ .width = SizingAxis.grow(), .height = SizingAxis.fit() },
        .layout_direction = .top_to_bottom,
    } });
    try engine.text("aaaa bbbb cccc dddd eeee ffff gggg hhhh iiii jjjj kkkk llll mmmm nnnn oooo", wrapped);
    engine.closeElement();
    engine.closeElement();
    try engine.endFrame();

    const column = boundingBox(&engine, 2);
    const text = boundingBox(&engine, 3);
    try std.testing.expectEqual(@as(f32, 300), column.width);
    try std.testing.expect(text.width <= 300);
    try std.testing.expectEqual(@as(f32, 60), column.height);
}

test "a grow child held at its floor takes space from its grow sibling" {
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();
    engine.setMeasureTextFn(measureTenPixelsPerCharacter, null);
    engine.beginFrame(800, 600);

    const grow_row: Sizing = .{ .width = SizingAxis.grow(), .height = SizingAxis.fixed(20) };
    try engine.openElement(.{ .layout = .{ .sizing = Sizing.fixed(300, 20) } });
    try engine.openElement(.{ .layout = .{ .sizing = grow_row } });
    try engine.text("twenty characters!!!", .{ .font_size = 20 });
    engine.closeElement();
    try engine.openElement(.{ .layout = .{ .sizing = grow_row } });
    engine.closeElement();
    engine.closeElement();
    try engine.endFrame();

    try std.testing.expectEqual(@as(f32, 200), boundingBox(&engine, 1).width);
    try std.testing.expectApproxEqAbs(@as(f32, 100), boundingBox(&engine, 3).width, 0.01);
}

test "a text of more words than one wrap batch wraps as one batch would" {
    const word_count = 3_000;
    comptime assert(word_count > 2 * test_capacity.word_count_text_max);
    const text = comptime blk: {
        @setEvalBranchQuota(100_000);
        var bytes: [word_count * 3 - 1]u8 = undefined;
        for (0..word_count) |index| {
            bytes[index * 3] = 'a';
            bytes[index * 3 + 1] = 'b';
            if (index + 1 < word_count) bytes[index * 3 + 2] = ' ';
        }
        break :blk bytes;
    };
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();
    engine.setMeasureTextFn(measureTenPixelsPerCharacter, null);
    engine.beginFrame(800, 600);
    try engine.openElement(.{ .layout = .{
        .sizing = .{ .width = SizingAxis.fixed(95), .height = SizingAxis.fit() },
    } });
    try engine.text(&text, .{ .wrap_mode = .words, .font_size = 10, .line_height = 100 });
    engine.closeElement();
    try engine.endFrame();

    const lines = engine.elements.getConst(1).text_data.?.wrapped_lines.?;
    try std.testing.expectEqual(@as(usize, word_count / 3), lines.len);
    for (lines, 0..) |line, index| {
        try std.testing.expectEqual(@as(u32, @intCast(index * 9)), line.start_offset);
        const length: u32 = if (index + 1 == lines.len) 8 else 9;
        try std.testing.expectEqual(length, @as(u32, line.extent.length));
        const width: f32 = if (index + 1 == lines.len) 80 else 90;
        try std.testing.expectEqual(width, line.width);
    }
    try std.testing.expectEqual(@as(f32, 10 * word_count / 3), boundingBox(&engine, 0).height);
}

test "a word before a line break wraps and counts its space like any other" {
    const text = "aa bb\ncc dd ee\nff";
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();
    engine.setMeasureTextFn(measureTenPixelsPerCharacter, null);
    engine.beginFrame(800, 600);
    try engine.openElement(.{ .layout = .{
        .sizing = .{ .width = SizingAxis.fixed(75), .height = SizingAxis.fit() },
    } });
    try engine.text(text, .{ .wrap_mode = .words, .font_size = 10, .line_height = 100 });
    engine.closeElement();
    try engine.endFrame();

    const lines = engine.elements.getConst(1).text_data.?.wrapped_lines.?;
    const expected = [_][3]u32{ .{ 0, 5, 50 }, .{ 6, 6, 60 }, .{ 12, 2, 20 }, .{ 15, 2, 20 } };
    try std.testing.expectEqual(expected.len, lines.len);
    for (lines, expected) |line, want| {
        try std.testing.expectEqual(want[0], line.start_offset);
        try std.testing.expectEqual(want[1], @as(u32, line.extent.length));
        try std.testing.expectEqual(@as(f32, @floatFromInt(want[2])), line.width);
        try std.testing.expect(line.width <= 75);
    }
}

fn measureTenPixelsPerCharacter(
    text: []const u8,
    _: u16,
    font_size: u16,
    _: ?f32,
    _: ?*anyopaque,
) TextMeasurement {
    std.debug.assert(font_size > 0);
    return .{
        .width = @as(f32, @floatFromInt(text.len)) * 10.0,
        .height = @floatFromInt(font_size),
    };
}

test "space_between distributes children evenly" {
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();

    engine.beginFrame(800, 600);

    try engine.openElement(.{
        .layout = .{
            .sizing = Sizing.fixed(300, 100),
            .layout_direction = .left_to_right,
            .main_axis_distribution = .space_between,
        },
    });
    {
        try engine.openElement(.{
            .layout = .{ .sizing = Sizing.fixed(50, 50) },
        });
        engine.closeElement();

        try engine.openElement(.{
            .layout = .{ .sizing = Sizing.fixed(50, 50) },
        });
        engine.closeElement();

        try engine.openElement(.{
            .layout = .{ .sizing = Sizing.fixed(50, 50) },
        });
        engine.closeElement();
    }
    engine.closeElement();

    try engine.endFrame();

    const child1 = engine.elements.getConst(1);
    const child2 = engine.elements.getConst(2);
    const child3 = engine.elements.getConst(3);

    try std.testing.expectEqual(@as(f32, 0.0), child1.computed.bounding_box.x);
    try std.testing.expectEqual(@as(f32, 125.0), child2.computed.bounding_box.x);
    try std.testing.expectEqual(@as(f32, 250.0), child3.computed.bounding_box.x);
}

test "space_around distributes space around children" {
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();

    engine.beginFrame(800, 600);

    try engine.openElement(.{
        .layout = .{
            .sizing = Sizing.fixed(300, 100),
            .layout_direction = .left_to_right,
            .main_axis_distribution = .space_around,
        },
    });
    {
        try engine.openElement(.{
            .layout = .{ .sizing = Sizing.fixed(50, 50) },
        });
        engine.closeElement();

        try engine.openElement(.{
            .layout = .{ .sizing = Sizing.fixed(50, 50) },
        });
        engine.closeElement();

        try engine.openElement(.{
            .layout = .{ .sizing = Sizing.fixed(50, 50) },
        });
        engine.closeElement();
    }
    engine.closeElement();

    try engine.endFrame();

    const child1 = engine.elements.getConst(1);
    const child2 = engine.elements.getConst(2);
    const child3 = engine.elements.getConst(3);

    try std.testing.expectEqual(@as(f32, 25.0), child1.computed.bounding_box.x);
    try std.testing.expectEqual(@as(f32, 125.0), child2.computed.bounding_box.x);
    try std.testing.expectEqual(@as(f32, 225.0), child3.computed.bounding_box.x);
}

test "space_evenly distributes space evenly" {
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();

    engine.beginFrame(800, 600);

    try engine.openElement(.{
        .layout = .{
            .sizing = Sizing.fixed(300, 100),
            .layout_direction = .left_to_right,
            .main_axis_distribution = .space_evenly,
        },
    });
    {
        try engine.openElement(.{
            .layout = .{ .sizing = Sizing.fixed(50, 50) },
        });
        engine.closeElement();

        try engine.openElement(.{
            .layout = .{ .sizing = Sizing.fixed(50, 50) },
        });
        engine.closeElement();

        try engine.openElement(.{
            .layout = .{ .sizing = Sizing.fixed(50, 50) },
        });
        engine.closeElement();
    }
    engine.closeElement();

    try engine.endFrame();

    const child1 = engine.elements.getConst(1);
    const child2 = engine.elements.getConst(2);
    const child3 = engine.elements.getConst(3);

    try std.testing.expectEqual(@as(f32, 37.5), child1.computed.bounding_box.x);
    try std.testing.expectEqual(@as(f32, 125.0), child2.computed.bounding_box.x);
    try std.testing.expectEqual(@as(f32, 212.5), child3.computed.bounding_box.x);
}

test "space_between with vertical layout" {
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();

    engine.beginFrame(800, 600);

    try engine.openElement(.{
        .layout = .{
            .sizing = Sizing.fixed(100, 200),
            .layout_direction = .top_to_bottom,
            .main_axis_distribution = .space_between,
        },
    });
    {
        try engine.openElement(.{
            .layout = .{ .sizing = Sizing.fixed(50, 40) },
        });
        engine.closeElement();

        try engine.openElement(.{
            .layout = .{ .sizing = Sizing.fixed(50, 40) },
        });
        engine.closeElement();
    }
    engine.closeElement();

    try engine.endFrame();

    const child1 = engine.elements.getConst(1);
    const child2 = engine.elements.getConst(2);

    try std.testing.expectEqual(@as(f32, 0.0), child1.computed.bounding_box.y);
    try std.testing.expectEqual(@as(f32, 160.0), child2.computed.bounding_box.y);
}

test "space_between with single child stays at start" {
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();

    engine.beginFrame(800, 600);

    try engine.openElement(.{
        .layout = .{
            .sizing = Sizing.fixed(300, 100),
            .layout_direction = .left_to_right,
            .main_axis_distribution = .space_between,
        },
    });
    {
        try engine.openElement(.{
            .layout = .{ .sizing = Sizing.fixed(50, 50) },
        });
        engine.closeElement();
    }
    engine.closeElement();

    try engine.endFrame();

    const child = engine.elements.getConst(1);

    try std.testing.expectEqual(@as(f32, 0.0), child.computed.bounding_box.x);
}

const MeasureRecorder = struct {
    whole_string_len: u32,
    call_count: u32 = 0,
    whole_string_calls: u32 = 0,
    longest_word_len: u32 = 0,

    fn measure(
        content: []const u8,
        _: u16,
        font_size: u16,
        _: ?f32,
        user_data: ?*anyopaque,
    ) TextMeasurement {
        const self: *MeasureRecorder = @ptrCast(@alignCast(user_data.?));
        const content_len: u32 = @intCast(content.len);

        self.call_count += 1;
        if (content_len == self.whole_string_len) {
            self.whole_string_calls += 1;
        } else {
            self.longest_word_len = @max(self.longest_word_len, content_len);
        }

        return .{
            .width = @as(f32, @floatFromInt(content_len)) * 10.0,
            .height = @floatFromInt(font_size),
        };
    }
};

const SHAPE_CACHE_INSERT_LIMIT: u32 = 128;

test "wrapped text re-measures the whole string on every frame" {
    const message = "The quick brown fox jumps over the lazy dog while the " ++
        "cat watches from a sunny windowsill and the world turns slowly " ++
        "onward through another long and uneventful afternoon";

    try std.testing.expect(message.len > SHAPE_CACHE_INSERT_LIMIT);
    try std.testing.expect(message.len < 512);

    var recorder = MeasureRecorder{ .whole_string_len = @intCast(message.len) };

    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();

    engine.setMeasureTextFn(MeasureRecorder.measure, &recorder);

    const frame_count: u32 = 5;
    var frame: u32 = 0;
    while (frame < frame_count) : (frame += 1) {
        engine.beginFrame(800, 600);
        try engine.openElement(.{
            .layout = .{
                .sizing = Sizing.fixed(400, 600),
                .layout_direction = .top_to_bottom,
            },
        });
        {
            try engine.text(message, .{ .wrap_mode = .words, .font_size = 14 });
        }
        engine.closeElement();
        try engine.endFrame();
    }

    try std.testing.expectEqual(frame_count, recorder.whole_string_calls);

    try std.testing.expect(recorder.longest_word_len > 0);
    try std.testing.expect(recorder.longest_word_len < SHAPE_CACHE_INSERT_LIMIT);
}

test "unwrapped text depends on the whole-string measurement" {
    const message = "Sized entirely by the whole-string measurement";

    var recorder = MeasureRecorder{ .whole_string_len = @intCast(message.len) };

    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();

    engine.setMeasureTextFn(MeasureRecorder.measure, &recorder);
    engine.beginFrame(800, 600);

    try engine.openElement(.{
        .layout = .{
            .sizing = Sizing.fixed(500, 600),
            .layout_direction = .top_to_bottom,
        },
    });
    {
        try engine.text(message, .{ .wrap_mode = .none, .font_size = 14 });
    }
    engine.closeElement();

    try engine.endFrame();

    try std.testing.expectEqual(@as(u32, 1), recorder.whole_string_calls);

    const text_elem = engine.elements.getConst(1);
    const text_data = text_elem.text_data.?;
    const expected_width = @as(f32, @floatFromInt(message.len)) * 10.0;
    try std.testing.expectEqual(expected_width, text_data.measured_width);
    try std.testing.expect(text_data.wrapped_lines == null);
}

test "gaps wider than their box overflow it, and its grow children get none" {
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();

    engine.beginFrame(400, 200);
    try engine.openElement(.{ .layout = .{
        .sizing = .{ .width = SizingAxis.fixed(20), .height = SizingAxis.fixed(10) },
        .child_gap = 16,
        .layout_direction = .left_to_right,
    } });
    const grow_child_count: u32 = 4;
    for (0..grow_child_count) |_| {
        try engine.openElement(.{ .layout = .{ .sizing = .{
            .width = SizingAxis.grow(),
            .height = SizingAxis.fixed(10),
        } } });
        engine.closeElement();
    }
    try engine.openElement(.{ .layout = .{ .sizing = .{
        .width = SizingAxis.fixed(0),
        .height = SizingAxis.fixed(10),
    } } });
    engine.closeElement();
    engine.closeElement();
    try engine.endFrame();

    const elements = engine.elements.items();
    try std.testing.expectEqual(@as(usize, grow_child_count + 2), elements.len);
    try std.testing.expectEqual(@as(f32, 20), elements[0].computed.bounding_box.width);
    const row_x = elements[0].computed.bounding_box.x;
    for (elements[1..], 0..) |element, index| {
        const box = element.computed.bounding_box;
        try std.testing.expect(std.math.isFinite(box.x));
        try std.testing.expect(std.math.isFinite(box.width));
        try std.testing.expectEqual(@as(f32, 0), box.width);
        const x_expected = row_x + 16 * @as(f32, @floatFromInt(index));
        try std.testing.expectApproxEqAbs(x_expected, box.x, 0.001);
    }
    const last = elements[elements.len - 1].computed.bounding_box;
    try std.testing.expect(last.x > row_x + 20);
}

fn fixedLeaf(engine: *LayoutEngine, width: f32, height: f32) !void {
    assert(width >= 0);
    assert(height >= 0);
    try engine.openElement(.{ .layout = .{ .sizing = Sizing.fixed(width, height) } });
    engine.closeElement();
}

test "a wrapping row breaks before the child that overflows, and fits its lines" {
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();
    engine.beginFrame(800, 600);
    try engine.openElement(.{ .layout = .{
        .sizing = .{ .width = SizingAxis.fixed(300), .height = SizingAxis.fit() },
        .padding = Padding.all(5),
        .child_gap = 10,
        .wrap = true,
    } });
    try fixedLeaf(&engine, 100, 20);
    try fixedLeaf(&engine, 100, 40);
    try fixedLeaf(&engine, 100, 30);
    try fixedLeaf(&engine, 100, 10);
    try fixedLeaf(&engine, 100, 25);
    engine.closeElement();
    try engine.endFrame();

    const height_expected: f32 = 40 + 10 + 30 + 10 + 25 + 10;
    try std.testing.expectEqual(height_expected, boundingBox(&engine, 0).height);
    const expected = [_][2]f32{ .{ 5, 5 }, .{ 115, 5 }, .{ 5, 55 }, .{ 115, 55 }, .{ 5, 95 } };
    for (expected, 1..) |position, index| {
        const bounds = boundingBox(&engine, @intCast(index));
        try std.testing.expectEqual(position[0], bounds.x);
        try std.testing.expectEqual(position[1], bounds.y);
    }
}

test "a wrapping row keeps a child that fits exactly on its line" {
    const widths = [_]f32{ 320, 319 };
    const third_y = [_]f32{ 0, 30 };
    for (widths, third_y) |width, y| {
        var engine = try LayoutEngine.init(&test_capacity);
        defer engine.deinit();
        engine.beginFrame(800, 600);
        try engine.openElement(.{ .layout = .{
            .sizing = .{ .width = SizingAxis.fixed(width), .height = SizingAxis.fit() },
            .child_gap = 10,
            .wrap = true,
        } });
        try fixedLeaf(&engine, 100, 20);
        try fixedLeaf(&engine, 100, 20);
        try fixedLeaf(&engine, 100, 20);
        engine.closeElement();
        try engine.endFrame();
        try std.testing.expectEqual(y, boundingBox(&engine, 3).y);
    }
}

test "grow children share their own line's free width, and a long child is cut to the row" {
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();
    engine.beginFrame(800, 600);
    try engine.openElement(.{ .layout = .{
        .sizing = .{ .width = SizingAxis.fixed(300), .height = SizingAxis.fit() },
        .wrap = true,
    } });
    try fixedLeaf(&engine, 90, 10);
    try engine.openElement(.{ .layout = .{ .sizing = .{
        .width = SizingAxis.growWeighted(1, 0, std.math.floatMax(f32)),
        .height = SizingAxis.fixed(10),
    } } });
    engine.closeElement();
    try engine.openElement(.{ .layout = .{ .sizing = .{
        .width = SizingAxis.growWeighted(2, 0, std.math.floatMax(f32)),
        .height = SizingAxis.fixed(10),
    } } });
    engine.closeElement();
    try fixedLeaf(&engine, 250, 10);
    try engine.openElement(.{ .layout = .{} });
    try fixedLeaf(&engine, 500, 10);
    engine.closeElement();
    engine.closeElement();
    try engine.endFrame();

    try std.testing.expectApproxEqAbs(@as(f32, 70), boundingBox(&engine, 2).width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 140), boundingBox(&engine, 3).width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 160), boundingBox(&engine, 3).x, 0.01);
    try std.testing.expectEqual(@as(f32, 250), boundingBox(&engine, 4).width);
    try std.testing.expectEqual(@as(f32, 10), boundingBox(&engine, 4).y);
    try std.testing.expectEqual(@as(f32, 300), boundingBox(&engine, 5).width);
    try std.testing.expectEqual(@as(f32, 20), boundingBox(&engine, 5).y);
}

test "a wrapping row aligns each line on its own, and children within their line" {
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();
    engine.beginFrame(800, 600);
    try engine.openElement(.{ .layout = .{
        .sizing = .{ .width = SizingAxis.fixed(300), .height = SizingAxis.fixed(200) },
        .child_alignment = ChildAlignment.center(),
        .main_axis_distribution = .center,
        .wrap = true,
    } });
    try fixedLeaf(&engine, 100, 20);
    try fixedLeaf(&engine, 100, 40);
    try engine.openElement(.{ .layout = .{ .sizing = .{
        .width = SizingAxis.fixed(80),
        .height = SizingAxis.grow(),
    } } });
    engine.closeElement();
    try fixedLeaf(&engine, 150, 10);
    engine.closeElement();
    try engine.endFrame();

    try std.testing.expectEqual(@as(f32, 10), boundingBox(&engine, 1).x);
    try std.testing.expectEqual(@as(f32, 10), boundingBox(&engine, 1).y);
    try std.testing.expectEqual(@as(f32, 0), boundingBox(&engine, 2).y);
    try std.testing.expectEqual(@as(f32, 40), boundingBox(&engine, 3).height);
    try std.testing.expectEqual(@as(f32, 75), boundingBox(&engine, 4).x);
    try std.testing.expectEqual(@as(f32, 40), boundingBox(&engine, 4).y);
    try std.testing.expectEqual(@as(f32, 200), boundingBox(&engine, 0).height);
}

test "fit-content parents grow to heights that wrapping and aspect ratios derive from widths" {
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();
    engine.beginFrame(800, 600);
    try engine.openElement(.{ .layout = .{
        .sizing = .{ .width = SizingAxis.fixed(300), .height = SizingAxis.fit() },
        .layout_direction = .top_to_bottom,
    } });
    try engine.openElement(.{ .layout = .{
        .sizing = .{ .width = SizingAxis.grow(), .height = SizingAxis.fit() },
        .wrap = true,
    } });
    for (0..4) |_| try fixedLeaf(&engine, 100, 20);
    engine.closeElement();
    try engine.openElement(.{ .layout = .{
        .sizing = .{ .width = SizingAxis.grow(), .height = SizingAxis.fit() },
        .aspect_ratio = 2,
    } });
    engine.closeElement();
    try fixedLeaf(&engine, 300, 10);
    engine.closeElement();
    try engine.endFrame();

    try std.testing.expectEqual(@as(f32, 40), boundingBox(&engine, 1).height);
    try std.testing.expectEqual(@as(f32, 150), boundingBox(&engine, 6).height);
    try std.testing.expectEqual(@as(f32, 190), boundingBox(&engine, 7).y);
    try std.testing.expectEqual(@as(f32, 200), boundingBox(&engine, 0).height);
}

test "heights that follow a sibling's or a parent's are sized after text wraps" {
    const Case = struct {
        wrap: bool,
        direction: LayoutDirection,
        height: SizingAxis,
        sibling_y: f32,
        sibling_height: f32,
    };
    const row: LayoutDirection = .left_to_right;
    const fit = SizingAxis.fit();
    const cases = [_]Case{
        .{ .wrap = true, .direction = row, .height = fit, .sibling_y = 0, .sibling_height = 30 },
        .{ .wrap = false, .direction = row, .height = fit, .sibling_y = 0, .sibling_height = 30 },
        .{
            .wrap = false,
            .direction = .top_to_bottom,
            .height = SizingAxis.fixed(100),
            .sibling_y = 30,
            .sibling_height = 70,
        },
    };
    for (cases) |case| {
        var engine = try LayoutEngine.init(&test_capacity);
        defer engine.deinit();
        engine.setMeasureTextFn(measureTenPixelsPerCharacter, null);
        engine.beginFrame(800, 600);
        try engine.openElement(.{ .layout = .{
            .sizing = .{ .width = SizingAxis.fixed(200), .height = case.height },
            .layout_direction = case.direction,
            .wrap = case.wrap,
        } });
        try engine.openElement(.{ .layout = .{
            .sizing = .{ .width = SizingAxis.fixed(50), .height = SizingAxis.fit() },
        } });
        const wrapped: TextConfig = .{ .wrap_mode = .words, .font_size = 10, .line_height = 100 };
        try engine.text("aaaa bbbb cccc", wrapped);
        engine.closeElement();
        const grow_height: Sizing = .{ .width = SizingAxis.fixed(50), .height = SizingAxis.grow() };
        try engine.openElement(.{ .layout = .{ .sizing = grow_height } });
        try engine.openElement(.{ .layout = .{ .sizing = grow_height } });
        engine.closeElement();
        engine.closeElement();
        engine.closeElement();
        try engine.endFrame();

        try std.testing.expectEqual(@as(f32, 30), boundingBox(&engine, 1).height);
        const sibling = boundingBox(&engine, 3);
        try std.testing.expectEqual(case.sibling_y, sibling.y);
        try std.testing.expectEqual(case.sibling_height, sibling.height);
        try std.testing.expectEqual(case.sibling_height, boundingBox(&engine, 4).height);
    }
}

test "a wrapping scroll row scrolls to the end of its lines" {
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();
    engine.beginFrame(800, 600);
    try engine.openElement(.{
        .layout = .{ .sizing = Sizing.fixed(300, 50), .wrap = true },
        .scroll = .{ .vertical = true, .target = .end },
    });
    for (0..6) |_| try fixedLeaf(&engine, 100, 40);
    engine.closeElement();
    try engine.endFrame();

    const scroll = engine.elements.getConst(0).config.scroll.?;
    try std.testing.expectEqual(@as(f32, 30), scroll.scroll_offset.y);
    try std.testing.expectEqual(@as(f32, 40 - 30), boundingBox(&engine, 4).y);
}

const truncated: TextConfig = .{ .font_size = 10, .line_height = 100, .overflow = .ellipsis };

inline fn repeated(comptime text: []const u8, comptime count: usize) *const [text.len * count]u8 {
    comptime {
        var bytes: [text.len * count]u8 = undefined;
        for (0..count) |index| @memcpy(bytes[index * text.len ..][0..text.len], text);
        const result = bytes;
        return &result;
    }
}

fn truncationColumn(
    engine: *LayoutEngine,
    width: f32,
    content: []const u8,
    config: TextConfig,
) !*const engine_mod.LayoutElement {
    assert(width >= 0);
    engine.setMeasureTextFn(measureTenPixelsPerCharacter, null);
    engine.beginFrame(800, 600);
    try engine.openElement(.{ .layout = .{
        .sizing = .{ .width = SizingAxis.fixed(width), .height = SizingAxis.fit() },
        .layout_direction = .top_to_bottom,
    } });
    try engine.text(content, config);
    engine.closeElement();
    try engine.endFrame();
    return engine.elements.getConst(1);
}

test "an ellipsis text that does not wrap is cut at its column's width, one line tall" {
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();

    const fits = try truncationColumn(&engine, 100, "abcdefghij", truncated);
    try std.testing.expect(fits.text_data.?.wrapped_lines == null);
    try std.testing.expectEqual(@as(f32, 100), fits.computed.bounding_box.width);

    for ([_][]const u8{ "abcdefghijk", repeated("a", 40) }) |content| {
        const cut = try truncationColumn(&engine, 100, content, truncated);
        const lines = cut.text_data.?.wrapped_lines.?;
        try std.testing.expectEqual(@as(usize, 1), lines.len);
        try std.testing.expectEqual(types.LineEnd.cut_if_wide, lines[0].extent.end);
        try std.testing.expectEqual(@as(u32, @intCast(content.len)), lines[0].extent.length);
        try std.testing.expectEqual(@as(f32, 100), lines[0].width);
        try std.testing.expectEqual(@as(f32, 100), cut.computed.bounding_box.width);
        try std.testing.expectEqual(@as(f32, 10), cut.computed.bounding_box.height);
    }

    const clipped = try truncationColumn(&engine, 100, repeated("a", 40), .{ .font_size = 10 });
    const clip_lines = clipped.text_data.?.wrapped_lines.?;
    try std.testing.expectEqual(@as(usize, 1), clip_lines.len);
    try std.testing.expectEqual(types.LineEnd.cut_if_wide, clip_lines[0].extent.end);
    try std.testing.expectEqual(@as(f32, 100), clipped.computed.bounding_box.width);
    try std.testing.expectEqual(@as(f32, 0), clipped.text_data.?.ellipsis_width);
    try std.testing.expectEqual(@as(f32, 400), clipped.computed.floor_width);

    engine.beginFrame(800, 600);
    try engine.openElement(.{
        .layout = .{ .sizing = .{ .width = SizingAxis.fixed(100), .height = SizingAxis.fit() } },
        .scroll = .{ .horizontal = true },
    });
    try engine.text(repeated("a", 40), truncated);
    engine.closeElement();
    try engine.endFrame();
    try std.testing.expect(engine.elements.getConst(1).text_data.?.wrapped_lines == null);
}

test "a clamp keeps line_count_max lines and cuts the last only when text follows" {
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();
    const content = "aaaa bbbb cccc dddd eeee ffff gggg hhhh iiii jjjj";
    var clamped = truncated;
    clamped.wrap_mode = .words;

    clamped.line_count_max = 5;
    const exact = try truncationColumn(&engine, 100, content, clamped);
    try std.testing.expectEqual(@as(usize, 5), exact.text_data.?.wrapped_lines.?.len);
    for (exact.text_data.?.wrapped_lines.?) |line| {
        try std.testing.expectEqual(types.LineEnd.whole, line.extent.end);
    }
    try std.testing.expectEqual(@as(f32, 50), exact.computed.bounding_box.height);

    inline for (.{ 4, 2, 1 }) |count| {
        clamped.line_count_max = count;
        const text = try truncationColumn(&engine, 100, content, clamped);
        const lines = text.text_data.?.wrapped_lines.?;
        try std.testing.expectEqual(@as(usize, count), lines.len);
        try std.testing.expectEqual(@as(u32, count), engine.wrapped_line_count);
        const last = lines[count - 1];
        try std.testing.expectEqual(types.LineEnd.cut, last.extent.end);
        try std.testing.expectEqual(@as(u32, @intCast(content.len)), last.start_offset +
            @as(u32, last.extent.length));
        try std.testing.expectEqual(@as(f32, 100), last.width);
        try std.testing.expectEqual(@as(f32, 10 * count), text.computed.bounding_box.height);
        for (lines[0 .. count - 1]) |line| {
            try std.testing.expectEqual(types.LineEnd.whole, line.extent.end);
        }
    }

    clamped.overflow = .clip;
    clamped.line_count_max = 2;
    const clipped = try truncationColumn(&engine, 100, content, clamped);
    const clip_lines = clipped.text_data.?.wrapped_lines.?;
    try std.testing.expectEqual(@as(usize, 2), clip_lines.len);
    try std.testing.expectEqual(types.LineEnd.whole, clip_lines[1].extent.end);
    try std.testing.expectEqual(@as(u32, 10), clip_lines[1].start_offset);
    try std.testing.expectEqual(@as(u32, 10), @as(u32, clip_lines[1].extent.length));
    try std.testing.expectEqual(@as(f32, 20), clipped.computed.bounding_box.height);
}

test "a clamped line that ends at a newline keeps its bytes; blank lines after it are no text" {
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();
    var clamped = truncated;
    clamped.wrap_mode = .newlines;
    clamped.line_count_max = 2;

    const paragraphs = try truncationColumn(&engine, 100, "aaaa\nbbbb\ncccc", clamped);
    const lines = paragraphs.text_data.?.wrapped_lines.?;
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqual(types.LineEnd.cut, lines[1].extent.end);
    try std.testing.expectEqual(@as(u32, 4), @as(u32, lines[1].extent.length));

    clamped.line_count_max = 1;
    const blank = try truncationColumn(&engine, 100, "aaaa\n\n \n", clamped);
    const blank_lines = blank.text_data.?.wrapped_lines.?;
    try std.testing.expectEqual(@as(usize, 1), blank_lines.len);
    try std.testing.expectEqual(types.LineEnd.whole, blank_lines[0].extent.end);
}

test "a word wider than a wrapping ellipsis text's line is cut on a line of its own" {
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();
    var words = truncated;
    words.wrap_mode = .words;
    const text = try truncationColumn(&engine, 100, "aa " ++ repeated("w", 30) ++ " bb", words);
    const lines = text.text_data.?.wrapped_lines.?;
    try std.testing.expectEqual(@as(usize, 3), lines.len);
    const ends = [_]types.LineEnd{ .whole, .cut_if_wide, .whole };
    for (lines, ends) |line, end| try std.testing.expectEqual(end, line.extent.end);
    try std.testing.expectEqual(@as(f32, 100), lines[1].width);
    try std.testing.expectEqual(@as(f32, 100), text.computed.bounding_box.width);
}

test "an overflowing row cuts an ellipsis text first, down to the ellipsis" {
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();
    engine.setMeasureTextFn(measureTenPixelsPerCharacter, null);
    const cases = [_]struct { row: f32, overflow: TextConfig.Overflow, text: f32 }{
        .{ .row = 500, .overflow = .ellipsis, .text = 200 },
        .{ .row = 330, .overflow = .ellipsis, .text = 30 },
        .{ .row = 310, .overflow = .ellipsis, .text = 30 },
        .{ .row = 500, .overflow = .clip, .text = 400 },
    };
    for (cases) |case| {
        engine.beginFrame(800, 600);
        try engine.openElement(.{ .layout = .{ .sizing = .{
            .width = SizingAxis.fixed(case.row),
            .height = SizingAxis.fit(),
        } } });
        var config = truncated;
        config.overflow = case.overflow;
        try engine.text(repeated("a", 40), config);
        try fixedLeaf(&engine, 300, 10);
        engine.closeElement();
        try engine.endFrame();
        try std.testing.expectEqual(case.text, boundingBox(&engine, 1).width);
        try std.testing.expectEqual(@as(f32, 300), boundingBox(&engine, 2).width);
        const lines = engine.elements.getConst(1).text_data.?.wrapped_lines;
        if (case.overflow == .ellipsis) {
            try std.testing.expectEqual(case.text, lines.?[0].width);
        } else {
            try std.testing.expect(lines == null);
        }
    }
}

test "a fit box around an ellipsis text floors at the ellipsis and its padding" {
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();
    engine.setMeasureTextFn(measureTenPixelsPerCharacter, null);
    engine.beginFrame(800, 600);
    try engine.openElement(.{ .layout = .{ .sizing = .{
        .width = SizingAxis.fixed(340),
        .height = SizingAxis.fit(),
    } } });
    try engine.openElement(.{ .layout = .{ .padding = Padding.all(5) } });
    try engine.text(repeated("a", 40), truncated);
    engine.closeElement();
    try fixedLeaf(&engine, 300, 10);
    engine.closeElement();
    try engine.endFrame();
    try std.testing.expectEqual(@as(f32, 40), boundingBox(&engine, 1).width);
    try std.testing.expectEqual(@as(f32, 30), boundingBox(&engine, 2).width);
}

test "a clamped text's parent takes the clamped height, and measureText agrees" {
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();
    const body = repeated("word ", 200);
    var clamped = truncated;
    clamped.wrap_mode = .words;
    clamped.line_count_max = 3;
    engine.setMeasureTextFn(measureTenPixelsPerCharacter, null);
    engine.beginFrame(800, 600);
    try engine.openElement(.{ .layout = .{
        .sizing = .{ .width = SizingAxis.fixed(120), .height = SizingAxis.fit() },
        .layout_direction = .top_to_bottom,
        .padding = Padding.all(4),
    } });
    try engine.text("Title", .{ .font_size = 10, .line_height = 100 });
    try engine.text(body, clamped);
    engine.closeElement();
    try engine.endFrame();
    try std.testing.expectEqual(@as(f32, 30), boundingBox(&engine, 2).height);
    try std.testing.expectEqual(@as(f32, 4 + 10 + 30 + 4), boundingBox(&engine, 0).height);
    try std.testing.expectEqual(@as(u32, 3), engine.wrapped_line_count);

    const measured = engine.measureText(body, clamped, 112);
    try std.testing.expectEqual(boundingBox(&engine, 2).height, measured.height);
    try std.testing.expectEqual(boundingBox(&engine, 2).width, measured.width);
    const one_line = engine.measureText(repeated("a", 40), truncated, 112);
    try std.testing.expectEqual(@as(f32, 112), one_line.width);
}
