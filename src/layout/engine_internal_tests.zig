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

test "BoundedList fills its storage exactly and reports one more" {
    var buffer: [3]u32 = undefined;
    var list: BoundedList(u32) = .{ .buffer = &buffer };
    try std.testing.expectEqual(@as(?u32, null), list.pop());
    try std.testing.expectEqual(@as(?u32, null), list.last());
    try list.append(10);
    try list.append(20);
    try list.append(30);
    try std.testing.expectEqualSlices(u32, &.{ 10, 20, 30 }, list.slice());
    try std.testing.expectError(error.Overflow, list.append(40));
    try std.testing.expectEqual(@as(u32, 3), list.len);
    try std.testing.expectEqual(@as(?u32, 30), list.last());
    try std.testing.expectEqual(@as(?u32, 30), list.pop());
    try list.append(31);
    try std.testing.expectEqualSlices(u32, &.{ 10, 20, 31 }, list.slice());
    list.clear();
    try std.testing.expectEqual(@as(u32, 0), list.len);
}

test "LayoutCapacity follows each profile's budget" {
    // Values are written out rather than recomputed with the same
    // expressions as `fromLimits`, so a budget change moves the test.
    const nano = LayoutCapacity.fromLimits(&ResourceLimits.nano);
    try std.testing.expectEqual(@as(u32, 513), nano.element_count_max);
    try std.testing.expectEqual(@as(u32, 64), nano.box_depth_max);
    try std.testing.expectEqual(@as(u32, 8), nano.floating_count_max);
    try std.testing.expectEqual(@as(u32, 1024), nano.word_count_text_max);
    try std.testing.expectEqual(@as(u32, 1024), nano.wrapped_line_count_frame_max);
    try std.testing.expectEqual(@as(u32, 32 * 1024 + 1024 * 12), nano.arena_bytes);
    const large = LayoutCapacity.fromLimits(&ResourceLimits.large);
    try std.testing.expectEqual(@as(u32, 16_384), large.element_count_max);
    try std.testing.expectEqual(@as(u32, 64), large.floating_count_max);
    const ceiling = LayoutCapacity.fromLimits(&ResourceLimits.ceiling);
    try std.testing.expectEqual(@as(u32, 65_536), ceiling.element_count_max);
    try std.testing.expectEqual(@as(u32, 128), ceiling.box_depth_max);
    try std.testing.expectEqual(@as(u32, 255), ceiling.floating_count_max);
}

test "nano engine holds exactly its elements, depth and floating roots" {
    // Fills each `nano` pool exactly. One more of any of them panics naming
    // its budget field, which a test cannot catch; the core fails first at
    // the same budgets (`core-box-depth`, `core-layer-count`,
    // `core-layout-elements` in `testing/fail_fast_check.zig`).
    const nano = LayoutCapacity.fromLimits(&ResourceLimits.nano);
    var engine = try LayoutEngine.init(&nano);
    defer engine.deinit();
    for (0..2) |_| {
        engine.beginFrame(800, 600);
        for (0..nano.box_depth_max) |_| try engine.openElement(.{});
        try std.testing.expectEqual(nano.box_depth_max, engine.open_element_stack.len);
        engine.closeElement(); // Room for one floating container at a time.
        for (0..nano.floating_count_max) |_| {
            try engine.openElement(.{ .floating = .{} });
            engine.closeElement();
        }
        try std.testing.expectEqual(nano.floating_count_max, engine.floating_roots.len);
        while (engine.elements.len() < nano.element_count_max) try engine.text("m", .{});
        try std.testing.expectEqual(nano.element_count_max, engine.elements.len());
        while (engine.open_element_stack.len > 0) engine.closeElement();
        try engine.endFrame();
        try std.testing.expectEqual(nano.element_count_max, engine.elements.len());
    }
}

test "open_element_stack uses fixed capacity" {
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();

    engine.beginFrame(800, 600);

    for (0..10) |_| {
        try engine.openElement(.{
            .layout = .{ .sizing = Sizing.fixed(100, 100) },
        });
    }

    try std.testing.expectEqual(@as(usize, 10), engine.open_element_stack.len);

    for (0..10) |_| {
        engine.closeElement();
    }

    try std.testing.expectEqual(@as(usize, 0), engine.open_element_stack.len);
}

test "floating_roots uses fixed capacity" {
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();

    engine.beginFrame(800, 600);

    try engine.openElement(.{
        .layout = .{ .sizing = Sizing.fixed(400, 300) },
    });

    try engine.openElement(.{
        .layout = .{ .sizing = Sizing.fixed(50, 50) },
        .floating = .{},
    });
    engine.closeElement();

    try engine.openElement(.{
        .layout = .{ .sizing = Sizing.fixed(50, 50) },
        .floating = .{},
    });
    engine.closeElement();

    try engine.openElement(.{
        .layout = .{ .sizing = Sizing.fixed(50, 50) },
        .floating = .{},
    });
    engine.closeElement();

    try engine.openElement(.{
        .layout = .{ .sizing = Sizing.fixed(50, 50) },
        .floating = .{},
    });
    engine.closeElement();

    try engine.openElement(.{
        .layout = .{ .sizing = Sizing.fixed(50, 50) },
        .floating = .{},
    });
    engine.closeElement();

    engine.closeElement();

    try std.testing.expectEqual(@as(usize, 5), engine.floating_roots.len);
}

test "UTF-8 text wrapping handles multi-byte characters" {
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
            var codepoint_count: usize = 0;
            const view = std.unicode.Utf8View.initUnchecked(text);
            var iter = view.iterator();
            while (iter.nextCodepointSlice()) |_| {
                codepoint_count += 1;
            }
            return .{
                .width = @as(f32, @floatFromInt(codepoint_count)) * 10.0,
                .height = @floatFromInt(font_size),
            };
        }
    }.measure;

    engine.setMeasureTextFn(mockMeasure, null);
    engine.beginFrame(800, 600);

    try engine.openElement(.{
        .layout = .{ .sizing = Sizing.fixed(100, 200) },
    });

    try engine.text("Hello 世界", .{
        .font_size = 16,
        .wrap_mode = .words,
    });

    engine.closeElement();

    try engine.endFrame();

    const text_elem = engine.elements.getConst(1);
    try std.testing.expect(text_elem.text_data != null);
}

test "UTF-8 text wrapping with emoji" {
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
            var codepoint_count: usize = 0;
            const view = std.unicode.Utf8View.initUnchecked(text);
            var iter = view.iterator();
            while (iter.nextCodepointSlice()) |_| {
                codepoint_count += 1;
            }
            return .{
                .width = @as(f32, @floatFromInt(codepoint_count)) * 10.0,
                .height = @floatFromInt(font_size),
            };
        }
    }.measure;

    engine.setMeasureTextFn(mockMeasure, null);
    engine.beginFrame(800, 600);

    try engine.openElement(.{
        .layout = .{ .sizing = Sizing.fixed(50, 200) },
    });

    try engine.text("🎉🎊🎁", .{
        .font_size = 16,
        .wrap_mode = .words,
    });

    engine.closeElement();

    try engine.endFrame();

    const text_elem = engine.elements.getConst(1);
    try std.testing.expect(text_elem.text_data != null);
}

test "beginFrame clears fixed capacity arrays" {
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();

    engine.beginFrame(800, 600);
    try engine.openElement(.{
        .layout = .{ .sizing = Sizing.fill() },
        .floating = .{},
    });
    engine.closeElement();
    try engine.endFrame();

    try std.testing.expect(engine.floating_roots.len > 0 or engine.open_element_stack.len == 0);

    engine.beginFrame(800, 600);
    try std.testing.expectEqual(@as(usize, 0), engine.open_element_stack.len);
    try std.testing.expectEqual(@as(usize, 0), engine.floating_roots.len);
}

test "word-level measurement measures words not characters" {
    var word_buffer: [16]WordInfo = undefined;
    var words: BoundedList(WordInfo) = .{ .buffer = &word_buffer };

    const measure = struct {
        fn measure(text: []const u8, _: u16, _: u16, _: ?f32, _: ?*anyopaque) TextMeasurement {
            return .{ .width = @floatFromInt(text.len * 10), .height = 20 };
        }
    }.measure;

    const config = TextConfig{ .font_size = 16 };
    const text = "hello world test";

    const word_count = sizing_pass.findWordBoundaries(text, measure, config, null, &words);

    try std.testing.expectEqual(@as(u32, 3), word_count);
    try std.testing.expectEqual(@as(usize, 3), words.len);

    try std.testing.expectEqual(@as(u32, 0), words.buffer[0].start);
    try std.testing.expectEqual(@as(u32, 5), words.buffer[0].end);
    try std.testing.expectEqual(@as(f32, 50), words.buffer[0].width);
    try std.testing.expect(!words.buffer[0].has_newline);

    try std.testing.expectEqual(@as(u32, 6), words.buffer[1].start);
    try std.testing.expectEqual(@as(u32, 11), words.buffer[1].end);
    try std.testing.expectEqual(@as(f32, 50), words.buffer[1].width);

    try std.testing.expectEqual(@as(u32, 12), words.buffer[2].start);
    try std.testing.expectEqual(@as(u32, 16), words.buffer[2].end);
    try std.testing.expectEqual(@as(f32, 40), words.buffer[2].width);
}

test "word-level measurement handles newlines" {
    var word_buffer: [16]WordInfo = undefined;
    var words: BoundedList(WordInfo) = .{ .buffer = &word_buffer };

    const measure = struct {
        fn measure(text: []const u8, _: u16, _: u16, _: ?f32, _: ?*anyopaque) TextMeasurement {
            return .{ .width = @floatFromInt(text.len * 10), .height = 20 };
        }
    }.measure;

    const config = TextConfig{ .font_size = 16 };
    const text = "hello\nworld";

    const word_count = sizing_pass.findWordBoundaries(text, measure, config, null, &words);

    try std.testing.expectEqual(@as(u32, 2), word_count);
    try std.testing.expect(words.buffer[0].has_newline);
    try std.testing.expect(!words.buffer[1].has_newline);
}

/// The y of a 100 px wide, `float_height` tall element floating below a
/// 40 px parent at `parent_y` in a 600 px viewport, attached as a dropdown
/// menu is: at the parent's top left, offset by the parent's height.
fn dropdownY(parent_y: u16, float_height: f32) !f32 {
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();
    engine.beginFrame(800, 600);
    try engine.openElement(.{
        .layout = .{
            .sizing = Sizing.fixed(800, 600),
            .padding = .{ .top = parent_y },
            .layout_direction = .top_to_bottom,
        },
    });
    try engine.openElement(.{
        .layout = .{ .sizing = Sizing.fixed(100, 40) },
    });
    try engine.openElement(.{
        .layout = .{ .sizing = Sizing.fixed(100, float_height) },
        .floating = .{ .attach_to_parent = true, .offset = .{ .y = 40 } },
    });
    engine.closeElement();
    engine.closeElement();
    engine.closeElement();
    try engine.endFrame();
    const trigger = boundingBox(&engine, 1);
    try std.testing.expectEqual(@as(f32, @floatFromInt(parent_y)), trigger.y);
    return boundingBox(&engine, 2).y;
}

test "a parent-attached float opens above its parent when only that side fits" {
    // Expected values sit one pixel either side of each flip boundary: a
    // 150 px menu flips once it no longer fits below, a 450 px menu once it
    // no longer fits above, and on neither side the clamp keeps it on screen.
    try std.testing.expectEqual(@as(f32, 440), try dropdownY(400, 150));
    try std.testing.expectEqual(@as(f32, 450), try dropdownY(410, 150));
    try std.testing.expectEqual(@as(f32, 261), try dropdownY(411, 150));
    try std.testing.expectEqual(@as(f32, 350), try dropdownY(500, 150));
    try std.testing.expectEqual(@as(f32, 0), try dropdownY(450, 450));
    try std.testing.expectEqual(@as(f32, 600 - 450), try dropdownY(449, 450));
}

test "floating expand.width makes element match parent width" {
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();

    engine.beginFrame(800, 600);

    try engine.openElement(.{
        .layout = .{ .sizing = Sizing.fixed(300, 200) },
        .background_color = Color.white,
    });

    try engine.openElement(.{
        .layout = .{ .sizing = Sizing.fitContent() },
        .floating = .{
            .attach_to_parent = true,
            .expand = .{ .width = true, .height = false },
        },
        .background_color = Color.blue,
    });
    engine.closeElement();

    engine.closeElement();

    try engine.endFrame();

    const float_bbox = boundingBox(&engine, 1);
    try std.testing.expectEqual(@as(f32, 300), float_bbox.width);
}

test "floating expand.height makes element match parent height" {
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();

    engine.beginFrame(800, 600);

    try engine.openElement(.{
        .layout = .{ .sizing = Sizing.fixed(300, 250) },
        .background_color = Color.white,
    });

    try engine.openElement(.{
        .layout = .{ .sizing = Sizing.fitContent() },
        .floating = .{
            .attach_to_parent = true,
            .expand = .{ .width = false, .height = true },
        },
        .background_color = Color.green,
    });
    engine.closeElement();

    engine.closeElement();

    try engine.endFrame();

    const float_bbox = boundingBox(&engine, 1);
    try std.testing.expectEqual(@as(f32, 250), float_bbox.height);
}

test "floating expand both dimensions" {
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();

    engine.beginFrame(800, 600);

    try engine.openElement(.{
        .layout = .{ .sizing = Sizing.fixed(400, 300) },
        .background_color = Color.white,
    });

    try engine.openElement(.{
        .layout = .{ .sizing = Sizing.fitContent() },
        .floating = .{
            .attach_to_parent = true,
            .expand = .{ .width = true, .height = true },
        },
        .background_color = Color.red,
    });
    engine.closeElement();

    engine.closeElement();

    try engine.endFrame();

    const modal_bbox = boundingBox(&engine, 1);
    try std.testing.expectEqual(@as(f32, 400), modal_bbox.width);
    try std.testing.expectEqual(@as(f32, 300), modal_bbox.height);
}

test "Offset2D shared type works in FloatingConfig" {
    const float_config = types.FloatingConfig{
        .offset = types.Offset2D.init(10, 20),
    };

    try std.testing.expectEqual(@as(f32, 10), float_config.offset.x);
    try std.testing.expectEqual(@as(f32, 20), float_config.offset.y);
}

test "Offset2D shared type works in ScrollConfig" {
    const scroll_config = types.ScrollConfig{
        .horizontal = true,
        .vertical = true,
        .scroll_offset = types.Offset2D.init(100, 200),
    };

    try std.testing.expectEqual(@as(f32, 100), scroll_config.scroll_offset.x);
    try std.testing.expectEqual(@as(f32, 200), scroll_config.scroll_offset.y);
}

test "Offset2D zero constructor" {
    const offset = types.Offset2D.zero();
    try std.testing.expectEqual(@as(f32, 0), offset.x);
    try std.testing.expectEqual(@as(f32, 0), offset.y);
}

test "WordInfo struct has expected fields" {
    const word = WordInfo{
        .start = 0,
        .end = 5,
        .space_end = 6,
        .width = 50.0,
        .space_width = 8.0,
        .has_newline = false,
    };

    try std.testing.expectEqual(@as(u32, 0), word.start);
    try std.testing.expectEqual(@as(u32, 5), word.end);
    try std.testing.expectEqual(@as(u32, 6), word.space_end);
    try std.testing.expectEqual(@as(f32, 50.0), word.width);
    try std.testing.expectEqual(@as(f32, 8.0), word.space_width);
    try std.testing.expect(!word.has_newline);
}

test "grow distribution gives equal space to grow elements" {
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();

    engine.beginFrame(300, 100);

    try engine.openElement(.{
        .layout = .{ .sizing = Sizing.fill(), .layout_direction = .left_to_right },
    });
    {
        try engine.openElement(.{
            .layout = .{ .sizing = .{ .width = SizingAxis.grow(), .height = SizingAxis.fixed(50) } },
            .background_color = Color.red,
        });
        engine.closeElement();

        try engine.openElement(.{
            .layout = .{ .sizing = .{ .width = SizingAxis.grow(), .height = SizingAxis.fixed(50) } },
            .background_color = Color.green,
        });
        engine.closeElement();

        try engine.openElement(.{
            .layout = .{ .sizing = .{ .width = SizingAxis.grow(), .height = SizingAxis.fixed(50) } },
            .background_color = Color.blue,
        });
        engine.closeElement();
    }
    engine.closeElement();

    try engine.endFrame();

    const grow1 = boundingBox(&engine, 1);
    const grow2 = boundingBox(&engine, 2);
    const grow3 = boundingBox(&engine, 3);

    try std.testing.expectEqual(@as(f32, 100), grow1.width);
    try std.testing.expectEqual(@as(f32, 100), grow2.width);
    try std.testing.expectEqual(@as(f32, 100), grow3.width);
}

test "shrink distribution respects minimum constraints" {
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();

    engine.beginFrame(100, 100);

    try engine.openElement(.{
        .layout = .{ .sizing = Sizing.fill(), .layout_direction = .left_to_right },
    });
    {
        try engine.openElement(.{
            .layout = .{
                .sizing = .{
                    .width = SizingAxis.fitMinMax(60, 200),
                    .height = SizingAxis.fixed(50),
                },
            },
            .background_color = Color.red,
        });
        engine.closeElement();

        try engine.openElement(.{
            .layout = .{
                .sizing = .{
                    .width = SizingAxis.fitMax(200),
                    .height = SizingAxis.fixed(50),
                },
            },
            .background_color = Color.blue,
        });
        engine.closeElement();
    }
    engine.closeElement();

    try engine.endFrame();

    const minchild = boundingBox(&engine, 1);

    try std.testing.expect(minchild.width >= 60);
}

test "fast path: single grow child gets full available space" {
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();

    engine.beginFrame(400, 300);

    try engine.openElement(.{
        .layout = .{ .sizing = Sizing.fixed(400, 300), .layout_direction = .left_to_right },
    });
    {
        try engine.openElement(.{
            .layout = .{ .sizing = Sizing.fill() },
            .background_color = Color.red,
        });
        engine.closeElement();
    }
    engine.closeElement();

    try engine.endFrame();

    const child = boundingBox(&engine, 1);

    try std.testing.expectEqual(@as(f32, 400), child.width);
    try std.testing.expectEqual(@as(f32, 300), child.height);
}

test "fast path: all floating children falls back to slow path" {
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();

    engine.beginFrame(400, 300);

    try engine.openElement(.{
        .layout = .{
            .sizing = Sizing.fixed(400, 300),
            .layout_direction = .left_to_right,
        },
    });
    {
        try engine.openElement(.{
            .layout = .{ .sizing = Sizing.fixed(100, 100) },
            .floating = types.FloatingConfig.dropdown(),
            .background_color = Color.red,
        });
        engine.closeElement();

        try engine.openElement(.{
            .layout = .{ .sizing = Sizing.fixed(100, 100) },
            .floating = types.FloatingConfig.dropdown(),
            .background_color = Color.blue,
        });
        engine.closeElement();
    }
    engine.closeElement();

    try engine.endFrame();

    const f1 = boundingBox(&engine, 1);
    const f2 = boundingBox(&engine, 2);

    try std.testing.expectEqual(@as(f32, 100), f1.width);
    try std.testing.expectEqual(@as(f32, 100), f2.width);
}

test "fast path: mixed sizing children falls back to slow path" {
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();

    engine.beginFrame(400, 100);

    try engine.openElement(.{
        .layout = .{ .sizing = Sizing.fixed(400, 100), .layout_direction = .left_to_right },
    });
    {
        try engine.openElement(.{
            .layout = .{ .sizing = Sizing.fixed(100, 50) },
            .background_color = Color.red,
        });
        engine.closeElement();

        try engine.openElement(.{
            .layout = .{ .sizing = Sizing.fill() },
            .background_color = Color.green,
        });
        engine.closeElement();

        try engine.openElement(.{
            .layout = .{ .sizing = Sizing.fitContent() },
            .background_color = Color.blue,
        });
        {
            try engine.openElement(.{
                .layout = .{ .sizing = Sizing.fixed(50, 30) },
            });
            engine.closeElement();
        }
        engine.closeElement();
    }
    engine.closeElement();

    try engine.endFrame();

    const fixed = boundingBox(&engine, 1);
    const grow = boundingBox(&engine, 2);
    const fit = boundingBox(&engine, 3);

    try std.testing.expectEqual(@as(f32, 100), fixed.width);

    try std.testing.expectEqual(@as(f32, 50), fit.width);

    try std.testing.expectEqual(@as(f32, 250), grow.width);
}

test "fast path: grow with min constraint falls back to slow path" {
    var engine = try LayoutEngine.init(&test_capacity);
    defer engine.deinit();

    engine.beginFrame(300, 100);

    try engine.openElement(.{
        .layout = .{ .sizing = Sizing.fixed(300, 100), .layout_direction = .left_to_right },
    });
    {
        try engine.openElement(.{
            .layout = .{
                .sizing = .{
                    .width = SizingAxis.growMinMax(80, std.math.floatMax(f32)),
                    .height = SizingAxis.grow(),
                },
            },
            .background_color = Color.red,
        });
        engine.closeElement();

        try engine.openElement(.{
            .layout = .{ .sizing = Sizing.fill() },
            .background_color = Color.green,
        });
        engine.closeElement();
    }
    engine.closeElement();

    try engine.endFrame();

    const constrained = boundingBox(&engine, 1);
    const normal = boundingBox(&engine, 2);

    // The slow path shares equally, which satisfies the min constraint of 80.
    try std.testing.expectEqual(@as(f32, 150), constrained.width);
    try std.testing.expectEqual(@as(f32, 150), normal.width);
}
