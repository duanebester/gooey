//! Tests for the layout engine, kept separate from `engine.zig`.
//!
//! These exercise the engine via its public API plus a few private fields
//! (`open_element_stack`, `floating_roots`, `elements`).
//! Word-boundary unit tests reach into `sizing_pass.findWordBoundaries`
//! directly; everything else routes through `LayoutEngine`'s methods.

const std = @import("std");

const assert = std.debug.assert;

const engine_mod = @import("engine.zig");
const sizing_pass = @import("sizing_pass.zig");
const types = @import("types.zig");

const LayoutEngine = engine_mod.LayoutEngine;
const ElementDeclaration = engine_mod.ElementDeclaration;
const FixedCapacityArray = engine_mod.FixedCapacityArray;
const WordInfo = engine_mod.WordInfo;
const TextMeasurement = engine_mod.TextMeasurement;
const MAX_ELEMENTS_PER_FRAME = engine_mod.MAX_ELEMENTS_PER_FRAME;
const MAX_OPEN_DEPTH = engine_mod.MAX_OPEN_DEPTH;
const MAX_FLOATING_ROOTS = engine_mod.MAX_FLOATING_ROOTS;
const MAX_WORDS_PER_TEXT = engine_mod.MAX_WORDS_PER_TEXT;
const MAX_LINES_PER_TEXT = engine_mod.MAX_LINES_PER_TEXT;

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

// ============================================================================
// Tests
// ============================================================================

test "basic layout" {
    var engine = try LayoutEngine.init(std.testing.allocator);
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
    // Goal: a fill-window root must use fresh viewport dimensions every frame.
    // Methodology: lay out the same root before and after a viewport resize.
    var engine = try LayoutEngine.init(std.testing.allocator);
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
    var engine = try LayoutEngine.init(std.testing.allocator);
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
    var engine = try LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame(200, 100); // Small viewport

    try engine.openElement(.{
        .layout = .{ .sizing = Sizing.fill(), .layout_direction = .left_to_right },
    });
    {
        // Two children that WANT 150px but CAN shrink (min=0)
        // Use fitMax(150) which means "fit content up to 150px, min is 0"
        try engine.openElement(.{
            .layout = .{
                .sizing = .{
                    .width = SizingAxis.fitMax(150), // min=0, max=150
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

    // Children should have shrunk to fit
    const child1 = engine.elements.getConst(1);
    const child2 = engine.elements.getConst(2);
    try std.testing.expect(child1.computed.sized_width <= 100); // 200/2
    try std.testing.expect(child2.computed.sized_width <= 100);
}

test "a grow scroll container's children overflow it instead of shrinking" {
    // Goal: a scroll container sized by the uniform-grow fast path (the only
    // grow-both-axes child of its parent) lets its children keep their size
    // along the scroll axis, as every other sizing path does. Methodology: a
    // 100 px tall viewport holds a vertical scroll container whose box child
    // fits two 80 px children; the box must keep its 160 px.
    var engine = try LayoutEngine.init(std.testing.allocator);
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
    var engine = try LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame(800, 600);

    try engine.openElement(.{
        .layout = .{
            .sizing = .{ .width = SizingAxis.fixed(160), .height = SizingAxis.fit() },
            .aspect_ratio = 16.0 / 9.0, // 16:9 ratio
        },
        .background_color = Color.white,
    });
    engine.closeElement();

    try engine.endFrame();

    const elem = engine.elements.getConst(0);
    // Width 160, aspect 16:9, so height should be 90
    try std.testing.expectApproxEqAbs(@as(f32, 90), elem.computed.sized_height, 0.1);
}

test "percent with min/max" {
    var engine = try LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame(800, 600);

    try engine.openElement(.{
        .layout = .{
            .sizing = .{
                .width = SizingAxis.percentMinMax(0.5, 100, 300), // 50% clamped to 100-300
                .height = SizingAxis.fixed(50),
            },
        },
        .background_color = Color.white,
    });
    engine.closeElement();

    try engine.endFrame();

    const elem = engine.elements.getConst(0);
    // 50% of 800 = 400, but max is 300
    try std.testing.expectEqual(@as(f32, 300), elem.computed.sized_width);
}

test "floating positioning" {
    var engine = try LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame(800, 600);

    // Parent element
    try engine.openElement(.{
        .layout = .{ .sizing = Sizing.fixed(200, 100) },
        .background_color = Color.white,
    });
    {
        // Floating child (dropdown style)
        try engine.openElement(.{
            .layout = .{ .sizing = Sizing.fixed(150, 80) },
            .floating = types.FloatingConfig.dropdown(),
            .background_color = Color.blue,
        });
        engine.closeElement();
    }
    engine.closeElement();

    try engine.endFrame();

    // Floating element should be positioned below parent
    const parent = engine.elements.getConst(0);
    const floating = engine.elements.getConst(1);

    try std.testing.expectEqual(parent.computed.bounding_box.x, floating.computed.bounding_box.x);
    try std.testing.expectEqual(parent.computed.bounding_box.y + parent.computed.bounding_box.height, floating.computed.bounding_box.y);
}

test "floating elements don't affect parent sizing or sibling layout" {
    var engine = try LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame(800, 600);

    // Parent with fit-content sizing
    try engine.openElement(.{
        .layout = .{
            .sizing = Sizing.fitContent(),
            .layout_direction = .top_to_bottom,
            .child_gap = 10,
        },
        .background_color = Color.white,
    });
    {
        // Regular child - should determine parent size
        try engine.openElement(.{
            .layout = .{ .sizing = Sizing.fixed(100, 50) },
            .background_color = Color.red,
        });
        engine.closeElement();

        // Floating child - should NOT affect parent size
        try engine.openElement(.{
            .layout = .{ .sizing = Sizing.fixed(200, 300) }, // Much larger than regular child
            .floating = types.FloatingConfig.dropdown(),
            .background_color = Color.blue,
        });
        engine.closeElement();

        // Another regular child - should be positioned ignoring floating sibling
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

    // Parent should only be sized by regular children (100x50 + gap + 100x50 = 100x110)
    // NOT affected by floating child's 200x300
    try std.testing.expectEqual(@as(f32, 100), parent.computed.sized_width);
    try std.testing.expectEqual(@as(f32, 110), parent.computed.sized_height); // 50 + 10 gap + 50

    // Second child should be positioned right after first child (ignoring floating)
    // First child at y=0, height=50, gap=10, so second child at y=60
    try std.testing.expectEqual(regular_child.computed.bounding_box.y + 50 + 10, second_child.computed.bounding_box.y);
}

test "text wrapping creates multiple lines" {
    var engine = try LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    // Mock text measurement: each character is 10px wide, height is font_size
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

    // Container with 100px content width (120 - 20 padding)
    try engine.openElement(.{
        .layout = .{
            .sizing = Sizing.fixed(120, 200),
            .padding = Padding.all(10),
            .layout_direction = .top_to_bottom,
        },
    });
    {
        // Text that needs to wrap: "hello world" = 11 chars = 110px, but container is 100px
        try engine.text("hello world", .{
            .wrap_mode = .words,
            .font_size = 14,
        });
    }
    engine.closeElement();

    try engine.endFrame();

    // Check that text element has wrapped lines
    const text_elem = engine.elements.getConst(1);
    try std.testing.expect(text_elem.text_data != null);

    const td = text_elem.text_data.?;
    try std.testing.expect(td.wrapped_lines != null);

    const lines = td.wrapped_lines.?;
    try std.testing.expect(lines.len >= 2); // Should have wrapped into at least 2 lines
}

test "text wrapping with newlines" {
    var engine = try LayoutEngine.init(std.testing.allocator);
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
    try std.testing.expectEqual(@as(usize, 3), lines.len); // 3 lines from newlines
}

test "propagateHeightChange updates fit-content parent" {
    var engine = try LayoutEngine.init(std.testing.allocator);
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

    // Parent with fit-content height
    try engine.openElement(.{
        .layout = .{
            .sizing = .{
                .width = SizingAxis.fixed(100), // 100px wide content area
                .height = SizingAxis.fit(), // Fit to content height
            },
            .layout_direction = .top_to_bottom,
        },
    });
    {
        // Long text that will wrap into multiple lines
        // "abcdefghij abcdefghij" = 21 chars = 210px wide, needs to wrap at 100px
        try engine.text("abcdefghij abcdefghij", .{
            .wrap_mode = .words,
            .font_size = 20,
            .line_height = 100, // 100% = 20px per line
        });
    }
    engine.closeElement();

    try engine.endFrame();

    // Parent should have grown to fit wrapped text
    const parent = engine.elements.getConst(0);
    const text_elem = engine.elements.getConst(1);

    // Text wraps to 2+ lines, each 20px tall
    try std.testing.expect(text_elem.computed.sized_height >= 40.0);

    // Parent height should match or exceed text height
    try std.testing.expect(parent.computed.sized_height >= text_elem.computed.sized_height);
}

test "propagateHeightChange stops at fixed-height parent" {
    var engine = try LayoutEngine.init(std.testing.allocator);
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

    // Outer container with FIXED height - should NOT grow
    try engine.openElement(.{
        .layout = .{
            .sizing = Sizing.fixed(100, 50), // Fixed 50px height
            .layout_direction = .top_to_bottom,
        },
    });
    {
        // Inner container with fit height
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
            // Text that wraps to multiple lines
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

    // Outer should stay at fixed height
    try std.testing.expectEqual(@as(f32, 50.0), outer.computed.sized_height);

    // Inner (fit-content) should have grown
    try std.testing.expect(inner.computed.sized_height >= 40.0);
}

test "wrapped text grows its floating panel but not the panel's host" {
    // Goal: wrapped lines inside a floating panel must grow the panel, as they
    // grow any fit-content parent, while the panel must not grow its host.
    // Methodology: both texts wrap "abcdefghij abcdefghij" (210 px at 10 px a
    // character) to two 20 px lines in 100 px. Without the fix the panel stays
    // one line tall (40 px) and the host counts the panel in its height (80 px).
    var engine = try LayoutEngine.init(std.testing.allocator);
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
    try std.testing.expectEqual(@as(f32, 60), panel.height);
    try std.testing.expectEqual(@as(f32, 40), host.height);
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
    var engine = try LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame(800, 600);

    // Container: 300px wide, horizontal layout with space_between
    // 3 children: 50px each = 150px total
    // Remaining space: 300 - 150 = 150px
    // space_between: gap = 150 / (3-1) = 75px between children
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

    // Get child positions
    const child1 = engine.elements.getConst(1);
    const child2 = engine.elements.getConst(2);
    const child3 = engine.elements.getConst(3);

    // Child 1: starts at x=0
    try std.testing.expectEqual(@as(f32, 0.0), child1.computed.bounding_box.x);
    // Child 2: starts at x=0 + 50 + 75 = 125
    try std.testing.expectEqual(@as(f32, 125.0), child2.computed.bounding_box.x);
    // Child 3: starts at x=125 + 50 + 75 = 250
    try std.testing.expectEqual(@as(f32, 250.0), child3.computed.bounding_box.x);
}

test "space_around distributes space around children" {
    var engine = try LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame(800, 600);

    // Container: 300px wide, horizontal layout with space_around
    // 3 children: 50px each = 150px total
    // Remaining space: 300 - 150 = 150px
    // space_around: space_per_child = 150 / 3 = 50px
    // start_offset = 50 / 2 = 25px, gap = 50px
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

    // Child 1: starts at x=25 (start_offset)
    try std.testing.expectEqual(@as(f32, 25.0), child1.computed.bounding_box.x);
    // Child 2: starts at x=25 + 50 + 50 = 125
    try std.testing.expectEqual(@as(f32, 125.0), child2.computed.bounding_box.x);
    // Child 3: starts at x=125 + 50 + 50 = 225
    try std.testing.expectEqual(@as(f32, 225.0), child3.computed.bounding_box.x);
}

test "space_evenly distributes space evenly" {
    var engine = try LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame(800, 600);

    // Container: 300px wide, horizontal layout with space_evenly
    // 3 children: 50px each = 150px total
    // Remaining space: 300 - 150 = 150px
    // space_evenly: gap = 150 / (3+1) = 37.5px
    // start_offset = gap = 37.5px
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

    // Child 1: starts at x=37.5
    try std.testing.expectEqual(@as(f32, 37.5), child1.computed.bounding_box.x);
    // Child 2: starts at x=37.5 + 50 + 37.5 = 125
    try std.testing.expectEqual(@as(f32, 125.0), child2.computed.bounding_box.x);
    // Child 3: starts at x=125 + 50 + 37.5 = 212.5
    try std.testing.expectEqual(@as(f32, 212.5), child3.computed.bounding_box.x);
}

test "space_between with vertical layout" {
    var engine = try LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame(800, 600);

    // Container: 200px tall, vertical layout with space_between
    // 2 children: 40px each = 80px total
    // Remaining space: 200 - 80 = 120px
    // space_between with 2 children: gap = 120 / 1 = 120px
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

    // Child 1: starts at y=0
    try std.testing.expectEqual(@as(f32, 0.0), child1.computed.bounding_box.y);
    // Child 2: starts at y=0 + 40 + 120 = 160
    try std.testing.expectEqual(@as(f32, 160.0), child2.computed.bounding_box.y);
}

test "space_between with single child stays at start" {
    var engine = try LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame(800, 600);

    // With a single child, space_between should position it at the start
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

    // Single child should be at start (x=0)
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

    var engine = try LayoutEngine.init(std.testing.allocator);
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

    var engine = try LayoutEngine.init(std.testing.allocator);
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

    // No wrapping ran, so the measured width survives to the computed size.
    const text_elem = engine.elements.getConst(1);
    const text_data = text_elem.text_data.?;
    const expected_width = @as(f32, @floatFromInt(message.len)) * 10.0;
    try std.testing.expectEqual(expected_width, text_data.measured_width);
    try std.testing.expect(text_data.wrapped_lines == null);
}
