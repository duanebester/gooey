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

/// Every engine here holds the `standard` profile's capacities, as an app on
/// that profile would; there is no unbudgeted engine.
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

/// The computed bounds of the element at `index`, in creation order: the
/// engine appends elements as `openElement` and `text` create them.
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
    // Goal: a scroll container sized by the uniform-grow fast path (the only
    // grow-both-axes child of its parent) lets its children keep their size
    // along the scroll axis, as every other sizing path does. Methodology: a
    // 100 px tall viewport holds a vertical scroll container whose box child
    // fits two 80 px children; the box must keep its 160 px.
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

// A percent child takes its fraction once, of its parent's content less the
// gaps between flow children (decision 25). The fractions 0.5 and 0.25 beside
// a grow child tell the readings apart: of the content less gaps, 190 and 95
// leave the grow child 95; of the whole content, 200 and 100 leave it 80; and
// a fraction taken twice, as the grow rule once did, gives 100 and 25.
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

test "propagateHeightChange updates fit-content parent" {
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

test "propagateHeightChange stops at fixed-height parent" {
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
    // Goal: wrapped lines inside a floating panel must grow the panel, as they
    // grow any fit-content parent, while the panel must not grow its host.
    // Methodology: both texts wrap "abcdefghij abcdefghij" (210 px at 10 px a
    // character) to three 20 px lines in 100 px: the first word fills its
    // line, its space overflows and breaks there, and the second word does
    // not fit after that space, so the space is a line of its own. Without
    // the fix the panel stays one line tall (40 px) and the host counts the
    // panel in its height (100 px).
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

test "a text of more words than one wrap batch wraps as one batch would" {
    // Goal: the word scratch bounds a batch, not a text. A long text wraps in
    // batches whose line in progress carries into the next, so its lines are
    // the ones one pass would make. Method: 3,000 "ab" words (20 px, spaces
    // 10 px) in 95 px fit three to a line ("ab ab ab ", 90 px with the space
    // that counts toward fitting), so there must be 1,000 lines of 90 px, the
    // last 80 px with no space, each starting 9 bytes after the last. The
    // batches hold 1,024 words, 3 × 341 + 1, so each batch boundary falls
    // inside a line, where a lost carry would start a short line.
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
        // A wrapped line keeps its trailing space; the last line has none.
        const length: u32 = if (index + 1 == lines.len) 8 else 9;
        try std.testing.expectEqual(length, line.length);
        const width: f32 = if (index + 1 == lines.len) 80 else 90;
        try std.testing.expectEqual(width, line.width);
    }
    try std.testing.expectEqual(@as(f32, 10 * word_count / 3), boundingBox(&engine, 0).height);
}

test "a word before a line break wraps and counts its space like any other" {
    // Goal: the last word of a paragraph packs as every other word does
    // (it ran past the column in long chat replies). Method: letters are
    // 10 px and spaces 10 px, in 75 px. "aa bb" is 50 px with its space, not
    // the 40 px of its words alone; "cc dd ee" is 80 px, so "ee" wraps to its
    // own line before the break instead of overflowing, leaving "cc dd " 60 px
    // with the space that counts toward fitting; "ff" ends the text.
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
        try std.testing.expectEqual(want[1], line.length);
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

/// Records what the layout engine asks the text-measurement callback to
/// measure, so tests can assert *how much* measuring a frame does rather than
/// only what it computes.  Widths mirror the 10px-per-character mock used by
/// the wrapping tests above.
const MeasureRecorder = struct {
    /// Byte length of the message under test.  `text()` measures the whole
    /// string in a single call, while `wrapText` only ever measures individual
    /// words, so a call of exactly this length is unambiguously the former.
    whole_string_len: u32,
    call_count: u32 = 0,
    whole_string_calls: u32 = 0,
    /// Longest call that was not the whole string — the longest word wrapping
    /// measured.
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

/// Shape cache insert limit from `text.ShapedRunCache.MAX_GLYPHS_PER_ENTRY`,
/// duplicated as a plain constant so the layout tests stay free of any
/// dependency on the platform text backend.
const SHAPE_CACHE_INSERT_LIMIT: u32 = 128;

test "wrapped text re-measures the whole string on every frame" {
    // Goal: pin the measurement pattern of `LayoutEngine.text()`.  It measures
    // the entire string unconditionally, but for wrap-enabled text
    // `computeTextWrapping` recomputes width and height from per-word
    // measurements later in the same frame and overwrites both.
    //
    // That whole-string call is the only one long enough to exceed the shape
    // cache's 128-glyph insert limit, so `ShapedRunCache.put` refuses it.
    // `TextSystem.MeasureCache` absorbs it by caching width without glyphs,
    // so the call is a hash lookup rather than a full platform shape every
    // frame.  The count below is therefore expected to equal the frame count
    // -- the text layer removes the cost, not the call.
    //
    // Methodology: lay out one long wrapped paragraph across several frames
    // with a recording measure callback, then assert the whole-string call
    // happens once per frame and that every other call is a short word.
    const message = "The quick brown fox jumps over the lazy dog while the " ++
        "cat watches from a sunny windowsill and the world turns slowly " ++
        "onward through another long and uneventful afternoon";

    // The message sits in the band that the shaped-run cache cannot store: past
    // its insert limit but under the lookup gate.  This is exactly the range
    // `MeasureCache` exists to cover.
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

    // One whole-string measurement per frame, whose result is superseded by
    // wrapping before the frame ends.  Deliberately NOT driven to 0: the value
    // feeds Phase 1 min-sizing (`content_width = @max(content_width,
    // td.measured_width)` in sizing_pass.zig), so skipping it would change the
    // min content width of any fit-content ancestor -- a behaviour change, not
    // an optimisation.  The cost is removed in the text layer instead.
    try std.testing.expectEqual(frame_count, recorder.whole_string_calls);

    // Wrapping itself is cache-friendly: every other measurement is a
    // single word, comfortably inside the shaped-run cache's insert limit.
    try std.testing.expect(recorder.longest_word_len > 0);
    try std.testing.expect(recorder.longest_word_len < SHAPE_CACHE_INSERT_LIMIT);
}

test "unwrapped text depends on the whole-string measurement" {
    // Goal: guard the obvious over-correction.  With `wrap_mode == .none`,
    // `computeTextWrapping` returns early and never overwrites the measurement,
    // so `text()`'s whole-string call is the *only* source of the element's
    // size.  Any fix that skips measuring must keep this path exact, which is
    // why the redundancy cannot simply be deleted for all text.
    //
    // Methodology: lay out one unwrapped string and assert the sized width
    // still matches what the measure callback reported.
    const message = "Sized entirely by the whole-string measurement";

    var recorder = MeasureRecorder{ .whole_string_len = @intCast(message.len) };

    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();

    engine.setMeasureTextFn(MeasureRecorder.measure, &recorder);
    engine.beginFrame(800, 600);

    try engine.openElement(.{
        .layout = .{
            .sizing = Sizing.fixed(400, 600),
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
    // Goal: when only the gaps overflow a box (its children desire nothing),
    // the grow children size to 0 and the row overflows, as in CSS flexbox
    // and clay, without tripping an assertion (layout fuzz crash at
    // sizing_pass.zig:421). Methodology: a 20 px wide row with 16 px gaps
    // holds four empty grow children and an empty 0 px fixed one, which
    // keeps the uniform-grow fast path out; the four gaps need 64 px. Every
    // child must be 0 px wide, start 16 px after the one before, and stay
    // finite, so the last starts at 64, past the row's 20 px.
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

/// A childless box of a fixed size, for the wrapping tests.
fn fixedLeaf(engine: *LayoutEngine, width: f32, height: f32) !void {
    assert(width >= 0);
    assert(height >= 0);
    try engine.openElement(.{ .layout = .{ .sizing = Sizing.fixed(width, height) } });
    engine.closeElement();
}

test "a wrapping row breaks before the child that overflows, and fits its lines" {
    // Five 100 px children with gaps of 10 in a 290 px content width: two
    // fit (210), a third would not (320). Lines are as tall as their
    // tallest child, so line tops come from heights 40 and 30, not 20.
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

    // Lines of 40, 30, and 25, two gaps, and the padding.
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
    // Three 100 px children and two 10 px gaps fill 320 px exactly; at
    // 319 px the third wraps, below the first line and a 10 px gap.
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
    // Line 1 is a 90 px box and grow boxes of weight 1 and 2: they share
    // 300 - 90 = 210 as 70 and 140. The 250 px box would overflow line 1, so
    // it starts line 2. The fit box around a 500 px box is wider than the
    // row, so it takes line 3 alone, cut to the row's width; a fixed width
    // would be its minimum, and would overflow instead.
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
    // Main-axis centre places each line by its own width: line 1 (100, 100,
    // and 80 px) starts at 10 in 300, line 2 (150 px) at 75. Cross-axis
    // centre uses line 1's height (40), not the row's, so the 20 px child
    // sits 10 down, and the cross-axis grow child stretches to the line.
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
    // A fit column holds a grow-width wrapping row of four 100x20 boxes in
    // 300 px (two lines, 40 tall), a grow-width 2:1 box (150 tall), and a
    // 10 px box. Their minimums say 20 and 0, so the column must learn the
    // derived heights after sizing to place the box at 190 and be 200 tall.
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

test "a wrapping scroll row scrolls to the end of its lines" {
    // Six 100x40 boxes in 300 px make two lines, 80 tall, in a 50 px view:
    // the end is 30 down. Measuring one line's height would give 0.
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
