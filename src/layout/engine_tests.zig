//! Tests for the layout engine (PR 10 split — kept separate from
//! `engine.zig` so that file stays under the 1,500-line ceiling).
//!
//! These exercise the engine via its public API and a small number of
//! private fields (`open_element_stack`, `floating_roots`, `id_to_index`,
//! `elements`) — those reads are allowed because Zig struct fields are
//! accessible across files when the struct's containing module is `pub`.
//!
//! Word-boundary unit tests reach into `sizing_pass.findWordBoundaries`
//! directly; everything else routes through `LayoutEngine`'s methods.

const std = @import("std");

const engine_mod = @import("engine.zig");
const sizing_pass = @import("sizing_pass.zig");
const types = @import("types.zig");
const layout_id = @import("layout_id.zig");

const LayoutEngine = engine_mod.LayoutEngine;
const ElementDeclaration = engine_mod.ElementDeclaration;
const FixedCapacityArray = engine_mod.FixedCapacityArray;
const WordInfo = engine_mod.WordInfo;
const SourceLoc = engine_mod.SourceLoc;
const TextMeasurement = engine_mod.TextMeasurement;
const MAX_ELEMENTS_PER_FRAME = engine_mod.MAX_ELEMENTS_PER_FRAME;
const MAX_OPEN_DEPTH = engine_mod.MAX_OPEN_DEPTH;
const MAX_FLOATING_ROOTS = engine_mod.MAX_FLOATING_ROOTS;
const MAX_TRACKED_IDS = engine_mod.MAX_TRACKED_IDS;
const MAX_WORDS_PER_TEXT = engine_mod.MAX_WORDS_PER_TEXT;
const MAX_LINES_PER_TEXT = engine_mod.MAX_LINES_PER_TEXT;

const LayoutId = layout_id.LayoutId;
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

// ============================================================================
// Tests
// ============================================================================

test "basic layout" {
    var engine = LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame(800, 600);

    try engine.openElement(.{
        .id = LayoutId.init("root"),
        .layout = .{ .sizing = Sizing.fill() },
        .background_color = Color.white,
    });
    engine.closeElement();

    const commands = try engine.endFrame();
    try std.testing.expect(commands.len > 0);
}

test "nested layout" {
    var engine = LayoutEngine.init(std.testing.allocator);
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

    _ = try engine.endFrame();
}

test "shrink behavior" {
    var engine = LayoutEngine.init(std.testing.allocator);
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

    _ = try engine.endFrame();

    // Children should have shrunk to fit
    const child1 = engine.elements.getConst(1);
    const child2 = engine.elements.getConst(2);
    try std.testing.expect(child1.computed.sized_width <= 100); // 200/2
    try std.testing.expect(child2.computed.sized_width <= 100);
}

test "aspect ratio" {
    var engine = LayoutEngine.init(std.testing.allocator);
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

    _ = try engine.endFrame();

    const elem = engine.elements.getConst(0);
    // Width 160, aspect 16:9, so height should be 90
    try std.testing.expectApproxEqAbs(@as(f32, 90), elem.computed.sized_height, 0.1);
}

test "percent with min/max" {
    var engine = LayoutEngine.init(std.testing.allocator);
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

    _ = try engine.endFrame();

    const elem = engine.elements.getConst(0);
    // 50% of 800 = 400, but max is 300
    try std.testing.expectEqual(@as(f32, 300), elem.computed.sized_width);
}

test "floating positioning" {
    var engine = LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame(800, 600);

    // Parent element
    try engine.openElement(.{
        .id = LayoutId.init("parent"),
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

    _ = try engine.endFrame();

    // Floating element should be positioned below parent
    const parent = engine.elements.getConst(0);
    const floating = engine.elements.getConst(1);

    try std.testing.expectEqual(parent.computed.bounding_box.x, floating.computed.bounding_box.x);
    try std.testing.expectEqual(parent.computed.bounding_box.y + parent.computed.bounding_box.height, floating.computed.bounding_box.y);
}

test "floating elements don't affect parent sizing or sibling layout" {
    var engine = LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame(800, 600);

    // Parent with fit-content sizing
    try engine.openElement(.{
        .id = LayoutId.init("parent"),
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
            .id = LayoutId.init("regular-child"),
            .layout = .{ .sizing = Sizing.fixed(100, 50) },
            .background_color = Color.red,
        });
        engine.closeElement();

        // Floating child - should NOT affect parent size
        try engine.openElement(.{
            .id = LayoutId.init("floating-child"),
            .layout = .{ .sizing = Sizing.fixed(200, 300) }, // Much larger than regular child
            .floating = types.FloatingConfig.dropdown(),
            .background_color = Color.blue,
        });
        engine.closeElement();

        // Another regular child - should be positioned ignoring floating sibling
        try engine.openElement(.{
            .id = LayoutId.init("second-child"),
            .layout = .{ .sizing = Sizing.fixed(100, 50) },
            .background_color = Color.green,
        });
        engine.closeElement();
    }
    engine.closeElement();

    _ = try engine.endFrame();

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
    var engine = LayoutEngine.init(std.testing.allocator);
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

    _ = try engine.endFrame();

    // Check that text element has wrapped lines
    const text_elem = engine.elements.getConst(1);
    try std.testing.expect(text_elem.text_data != null);

    const td = text_elem.text_data.?;
    try std.testing.expect(td.wrapped_lines != null);

    const lines = td.wrapped_lines.?;
    try std.testing.expect(lines.len >= 2); // Should have wrapped into at least 2 lines
}

test "text wrapping with newlines" {
    var engine = LayoutEngine.init(std.testing.allocator);
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

    _ = try engine.endFrame();

    const text_elem = engine.elements.getConst(1);
    const td = text_elem.text_data.?;
    try std.testing.expect(td.wrapped_lines != null);

    const lines = td.wrapped_lines.?;
    try std.testing.expectEqual(@as(usize, 3), lines.len); // 3 lines from newlines
}

test "propagateHeightChange updates fit-content parent" {
    var engine = LayoutEngine.init(std.testing.allocator);
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

    _ = try engine.endFrame();

    // Parent should have grown to fit wrapped text
    const parent = engine.elements.getConst(0);
    const text_elem = engine.elements.getConst(1);

    // Text wraps to 2+ lines, each 20px tall
    try std.testing.expect(text_elem.computed.sized_height >= 40.0);

    // Parent height should match or exceed text height
    try std.testing.expect(parent.computed.sized_height >= text_elem.computed.sized_height);
}

test "propagateHeightChange stops at fixed-height parent" {
    var engine = LayoutEngine.init(std.testing.allocator);
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

    _ = try engine.endFrame();

    const outer = engine.elements.getConst(0);
    const inner = engine.elements.getConst(1);

    // Outer should stay at fixed height
    try std.testing.expectEqual(@as(f32, 50.0), outer.computed.sized_height);

    // Inner (fit-content) should have grown
    try std.testing.expect(inner.computed.sized_height >= 40.0);
}

test "z-index propagates to render commands" {
    var engine = LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame(800, 600);

    // Parent element (z_index = 0)
    try engine.openElement(.{
        .id = LayoutId.init("parent"),
        .layout = .{ .sizing = Sizing.fixed(200, 100) },
        .background_color = Color.white,
    });
    {
        // Floating child with z_index = 100
        try engine.openElement(.{
            .id = LayoutId.init("dropdown"),
            .layout = .{ .sizing = Sizing.fixed(150, 80) },
            .floating = .{ .z_index = 100, .element_attach = .left_top, .parent_attach = .left_bottom },
            .background_color = Color.blue,
        });
        {
            // Nested child inside floating - should inherit z_index
            try engine.openElement(.{
                .id = LayoutId.init("dropdown-item"),
                .layout = .{ .sizing = Sizing.fixed(140, 30) },
                .background_color = Color.red,
            });
            engine.closeElement();
        }
        engine.closeElement();
    }
    engine.closeElement();

    const commands = try engine.endFrame();

    // Find commands by element ID
    var parent_z: ?i16 = null;
    var dropdown_z: ?i16 = null;
    var dropdown_item_z: ?i16 = null;

    for (commands) |cmd| {
        if (cmd.id == LayoutId.init("parent").id) parent_z = cmd.z_index;
        if (cmd.id == LayoutId.init("dropdown").id) dropdown_z = cmd.z_index;
        if (cmd.id == LayoutId.init("dropdown-item").id) dropdown_item_z = cmd.z_index;
    }

    // Parent should have z_index = 0
    try std.testing.expectEqual(@as(i16, 0), parent_z.?);
    // Floating dropdown should have z_index = 100
    try std.testing.expectEqual(@as(i16, 100), dropdown_z.?);
    // Nested item inside dropdown should inherit z_index = 100
    try std.testing.expectEqual(@as(i16, 100), dropdown_item_z.?);
}

test "getZIndex returns inherited z-index" {
    var engine = LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame(800, 600);

    try engine.openElement(.{
        .id = LayoutId.init("root"),
        .layout = .{ .sizing = Sizing.fixed(400, 300) },
    });
    {
        try engine.openElement(.{
            .id = LayoutId.init("floating"),
            .layout = .{ .sizing = Sizing.fixed(100, 100) },
            .floating = .{ .z_index = 50 },
        });
        {
            try engine.openElement(.{
                .id = LayoutId.init("nested"),
                .layout = .{ .sizing = Sizing.fixed(50, 50) },
            });
            engine.closeElement();
        }
        engine.closeElement();
    }
    engine.closeElement();

    _ = try engine.endFrame();

    // Root has no floating ancestor
    try std.testing.expectEqual(@as(i16, 0), engine.getZIndex(LayoutId.init("root").id));
    // Floating element itself
    try std.testing.expectEqual(@as(i16, 50), engine.getZIndex(LayoutId.init("floating").id));
    // Nested element inherits from floating ancestor
    try std.testing.expectEqual(@as(i16, 50), engine.getZIndex(LayoutId.init("nested").id));
}

test "text alignment positions wrapped lines correctly" {
    var engine = LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    // Mock: each char is 10px wide
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

    // Container is 200px wide, text lines are shorter
    try engine.openElement(.{
        .layout = .{ .sizing = Sizing.fixed(200, 100) },
    });
    {
        // "AA\nBBBB" - line 1 is 20px, line 2 is 40px
        try engine.text("AA\nBBBB", .{
            .wrap_mode = .newlines,
            .alignment = .center,
            .font_size = 20,
            .line_height = 100, // 100% = 20px per line
        });
    }
    engine.closeElement();

    const commands = try engine.endFrame();

    // Find text commands
    var text_commands: [2]?types.BoundingBox = .{ null, null };
    var text_cmd_idx: usize = 0;
    for (commands) |cmd| {
        if (cmd.command_type == .text and text_cmd_idx < 2) {
            text_commands[text_cmd_idx] = cmd.bounding_box;
            text_cmd_idx += 1;
        }
    }

    // Both lines should exist
    try std.testing.expect(text_commands[0] != null);
    try std.testing.expect(text_commands[1] != null);

    const line1 = text_commands[0].?;
    const line2 = text_commands[1].?;

    // Line 1 "AA" = 20px wide, centered in 200px container
    // Expected x = (200 - 20) / 2 = 90
    try std.testing.expectEqual(@as(f32, 90.0), line1.x);
    try std.testing.expectEqual(@as(f32, 20.0), line1.width);

    // Line 2 "BBBB" = 40px wide, centered in 200px container
    // Expected x = (200 - 40) / 2 = 80
    try std.testing.expectEqual(@as(f32, 80.0), line2.x);
    try std.testing.expectEqual(@as(f32, 40.0), line2.width);
}

test "text alignment right aligns text" {
    var engine = LayoutEngine.init(std.testing.allocator);
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
        .layout = .{ .sizing = Sizing.fixed(200, 50) },
    });
    {
        // Single line "test" = 40px, right aligned in 200px
        try engine.text("test", .{
            .alignment = .right,
            .font_size = 20,
        });
    }
    engine.closeElement();

    const commands = try engine.endFrame();

    // Find the text command
    var text_box: ?types.BoundingBox = null;
    for (commands) |cmd| {
        if (cmd.command_type == .text) {
            text_box = cmd.bounding_box;
            break;
        }
    }

    try std.testing.expect(text_box != null);
    const bbox = text_box.?;

    // "test" = 40px wide, right aligned in 200px container
    // Expected x = 200 - 40 = 160
    try std.testing.expectEqual(@as(f32, 160.0), bbox.x);
    try std.testing.expectEqual(@as(f32, 40.0), bbox.width);
}

test "space_between distributes children evenly" {
    var engine = LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame(800, 600);

    // Container: 300px wide, horizontal layout with space_between
    // 3 children: 50px each = 150px total
    // Remaining space: 300 - 150 = 150px
    // space_between: gap = 150 / (3-1) = 75px between children
    try engine.openElement(.{
        .id = LayoutId.init("container"),
        .layout = .{
            .sizing = Sizing.fixed(300, 100),
            .layout_direction = .left_to_right,
            .main_axis_distribution = .space_between,
        },
    });
    {
        try engine.openElement(.{
            .id = LayoutId.init("child1"),
            .layout = .{ .sizing = Sizing.fixed(50, 50) },
        });
        engine.closeElement();

        try engine.openElement(.{
            .id = LayoutId.init("child2"),
            .layout = .{ .sizing = Sizing.fixed(50, 50) },
        });
        engine.closeElement();

        try engine.openElement(.{
            .id = LayoutId.init("child3"),
            .layout = .{ .sizing = Sizing.fixed(50, 50) },
        });
        engine.closeElement();
    }
    engine.closeElement();

    _ = try engine.endFrame();

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
    var engine = LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame(800, 600);

    // Container: 300px wide, horizontal layout with space_around
    // 3 children: 50px each = 150px total
    // Remaining space: 300 - 150 = 150px
    // space_around: space_per_child = 150 / 3 = 50px
    // start_offset = 50 / 2 = 25px, gap = 50px
    try engine.openElement(.{
        .id = LayoutId.init("container"),
        .layout = .{
            .sizing = Sizing.fixed(300, 100),
            .layout_direction = .left_to_right,
            .main_axis_distribution = .space_around,
        },
    });
    {
        try engine.openElement(.{
            .id = LayoutId.init("child1"),
            .layout = .{ .sizing = Sizing.fixed(50, 50) },
        });
        engine.closeElement();

        try engine.openElement(.{
            .id = LayoutId.init("child2"),
            .layout = .{ .sizing = Sizing.fixed(50, 50) },
        });
        engine.closeElement();

        try engine.openElement(.{
            .id = LayoutId.init("child3"),
            .layout = .{ .sizing = Sizing.fixed(50, 50) },
        });
        engine.closeElement();
    }
    engine.closeElement();

    _ = try engine.endFrame();

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
    var engine = LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame(800, 600);

    // Container: 300px wide, horizontal layout with space_evenly
    // 3 children: 50px each = 150px total
    // Remaining space: 300 - 150 = 150px
    // space_evenly: gap = 150 / (3+1) = 37.5px
    // start_offset = gap = 37.5px
    try engine.openElement(.{
        .id = LayoutId.init("container"),
        .layout = .{
            .sizing = Sizing.fixed(300, 100),
            .layout_direction = .left_to_right,
            .main_axis_distribution = .space_evenly,
        },
    });
    {
        try engine.openElement(.{
            .id = LayoutId.init("child1"),
            .layout = .{ .sizing = Sizing.fixed(50, 50) },
        });
        engine.closeElement();

        try engine.openElement(.{
            .id = LayoutId.init("child2"),
            .layout = .{ .sizing = Sizing.fixed(50, 50) },
        });
        engine.closeElement();

        try engine.openElement(.{
            .id = LayoutId.init("child3"),
            .layout = .{ .sizing = Sizing.fixed(50, 50) },
        });
        engine.closeElement();
    }
    engine.closeElement();

    _ = try engine.endFrame();

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
    var engine = LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame(800, 600);

    // Container: 200px tall, vertical layout with space_between
    // 2 children: 40px each = 80px total
    // Remaining space: 200 - 80 = 120px
    // space_between with 2 children: gap = 120 / 1 = 120px
    try engine.openElement(.{
        .id = LayoutId.init("container"),
        .layout = .{
            .sizing = Sizing.fixed(100, 200),
            .layout_direction = .top_to_bottom,
            .main_axis_distribution = .space_between,
        },
    });
    {
        try engine.openElement(.{
            .id = LayoutId.init("child1"),
            .layout = .{ .sizing = Sizing.fixed(50, 40) },
        });
        engine.closeElement();

        try engine.openElement(.{
            .id = LayoutId.init("child2"),
            .layout = .{ .sizing = Sizing.fixed(50, 40) },
        });
        engine.closeElement();
    }
    engine.closeElement();

    _ = try engine.endFrame();

    const child1 = engine.elements.getConst(1);
    const child2 = engine.elements.getConst(2);

    // Child 1: starts at y=0
    try std.testing.expectEqual(@as(f32, 0.0), child1.computed.bounding_box.y);
    // Child 2: starts at y=0 + 40 + 120 = 160
    try std.testing.expectEqual(@as(f32, 160.0), child2.computed.bounding_box.y);
}

test "space_between with single child stays at start" {
    var engine = LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame(800, 600);

    // With a single child, space_between should position it at the start
    try engine.openElement(.{
        .id = LayoutId.init("container"),
        .layout = .{
            .sizing = Sizing.fixed(300, 100),
            .layout_direction = .left_to_right,
            .main_axis_distribution = .space_between,
        },
    });
    {
        try engine.openElement(.{
            .id = LayoutId.init("child"),
            .layout = .{ .sizing = Sizing.fixed(50, 50) },
        });
        engine.closeElement();
    }
    engine.closeElement();

    _ = try engine.endFrame();

    const child = engine.elements.getConst(1);

    // Single child should be at start (x=0)
    try std.testing.expectEqual(@as(f32, 0.0), child.computed.bounding_box.x);
}

