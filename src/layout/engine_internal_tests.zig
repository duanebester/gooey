//! Tests for engine internal data structures and low-level helpers.
//!
//! Covers:
//!   - `SourceLoc` source-location capture
//!   - `FixedCapacityArray` fixed-capacity collection
//!   - `open_element_stack` / `floating_roots` fixed-capacity invariants
//!   - UTF-8 text wrapping
//!   - Pre-allocation of `id_to_index`, `seen_ids`
//!   - `beginFrame` reset behavior
//!   - Word-boundary helper (`sizing_pass.findWordBoundaries`)
//!   - Floating `expand` behavior
//!   - `Offset2D` / `WordInfo` shared types
//!   - `distributeGrow` / `distributeShrink` / fast-path coverage
//!
//! All tests route through public `LayoutEngine` methods unless noted.

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
const Padding = types.Padding;
const ChildAlignment = types.ChildAlignment;
const Color = types.Color;
const CornerRadius = types.CornerRadius;
const TextConfig = types.TextConfig;
const Offset2D = types.Offset2D;

// =============================================================================
// SourceLoc Tests (Phase 5)
// =============================================================================

test "SourceLoc.none is invalid" {
    const loc = SourceLoc.none;
    try std.testing.expect(!loc.isValid());
    try std.testing.expectEqual(@as(?[*:0]const u8, null), loc.file);
    try std.testing.expectEqual(@as(u32, 0), loc.line);
}

test "SourceLoc.from captures builtin source location" {
    const src = @src();
    const loc = SourceLoc.from(src);

    try std.testing.expect(loc.isValid());
    try std.testing.expect(loc.line > 0);
    try std.testing.expect(loc.file != null);
}

test "SourceLoc.getFile returns file name" {
    const src = @src();
    const loc = SourceLoc.from(src);

    const file = loc.getFile();
    try std.testing.expect(file != null);
    try std.testing.expect(file.?.len > 0);
}

test "SourceLoc.getBasename extracts filename" {
    const src = @src();
    const loc = SourceLoc.from(src);

    const basename = loc.getBasename();
    try std.testing.expect(basename != null);
    // The basename should be this test file itself.
    try std.testing.expectEqualStrings("engine_internal_tests.zig", basename.?);
}

test "SourceLoc stored in ElementDeclaration" {
    const src = @src();
    const loc = SourceLoc.from(src);

    const decl = ElementDeclaration{
        .source_location = loc,
    };

    try std.testing.expect(decl.source_location.isValid());
    try std.testing.expectEqual(loc.line, decl.source_location.line);
}

test "SourceLoc propagates through createElement" {
    var engine = LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame(800, 600);

    const src = @src();
    const loc = SourceLoc.from(src);

    try engine.openElement(.{
        .id = LayoutId.init("test-element"),
        .layout = .{ .sizing = Sizing.fixed(100, 100) },
        .source_location = loc,
    });
    engine.closeElement();

    _ = try engine.endFrame();

    // Verify the element stored the source location
    const elem = engine.elements.getConst(0);
    try std.testing.expect(elem.config.source_location.isValid());
    try std.testing.expectEqual(loc.line, elem.config.source_location.line);
}

// =============================================================================
// Phase 1 Tests: Fixed Capacity Arrays, UTF-8, Capacity Limits
// =============================================================================

test "FixedCapacityArray basic operations" {
    var arr: FixedCapacityArray(u32, 4) = .{};

    // Test append
    try arr.append(10);
    try arr.append(20);
    try arr.append(30);
    try std.testing.expectEqual(@as(usize, 3), arr.len);

    // Test slice
    const slice = arr.slice();
    try std.testing.expectEqual(@as(usize, 3), slice.len);
    try std.testing.expectEqual(@as(u32, 10), slice[0]);
    try std.testing.expectEqual(@as(u32, 20), slice[1]);
    try std.testing.expectEqual(@as(u32, 30), slice[2]);

    // Test pop
    const popped = arr.pop();
    try std.testing.expectEqual(@as(?u32, 30), popped);
    try std.testing.expectEqual(@as(usize, 2), arr.len);

    // Test clear
    arr.clear();
    try std.testing.expectEqual(@as(usize, 0), arr.len);
}

test "FixedCapacityArray overflow returns error" {
    var arr: FixedCapacityArray(u32, 2) = .{};

    try arr.append(1);
    try arr.append(2);

    // Third append should fail
    const result = arr.append(3);
    try std.testing.expectError(error.Overflow, result);
    try std.testing.expectEqual(@as(usize, 2), arr.len);
}

test "FixedCapacityArray pop on empty returns null" {
    var arr: FixedCapacityArray(u32, 4) = .{};
    const result = arr.pop();
    try std.testing.expectEqual(@as(?u32, null), result);
}

test "open_element_stack uses fixed capacity" {
    var engine = LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame(800, 600);

    // Open several nested elements
    for (0..10) |_| {
        try engine.openElement(.{
            .layout = .{ .sizing = Sizing.fixed(100, 100) },
        });
    }

    // Verify stack has correct depth
    try std.testing.expectEqual(@as(usize, 10), engine.open_element_stack.len);

    // Close all
    for (0..10) |_| {
        engine.closeElement();
    }

    try std.testing.expectEqual(@as(usize, 0), engine.open_element_stack.len);
}

test "floating_roots uses fixed capacity" {
    var engine = LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame(800, 600);

    // Create a parent element
    try engine.openElement(.{
        .id = LayoutId.init("parent"),
        .layout = .{ .sizing = Sizing.fixed(400, 300) },
    });

    // Add several floating elements (no IDs needed for this test)
    try engine.openElement(.{
        .layout = .{ .sizing = Sizing.fixed(50, 50) },
        .floating = .{ .z_index = 0 },
    });
    engine.closeElement();

    try engine.openElement(.{
        .layout = .{ .sizing = Sizing.fixed(50, 50) },
        .floating = .{ .z_index = 1 },
    });
    engine.closeElement();

    try engine.openElement(.{
        .layout = .{ .sizing = Sizing.fixed(50, 50) },
        .floating = .{ .z_index = 2 },
    });
    engine.closeElement();

    try engine.openElement(.{
        .layout = .{ .sizing = Sizing.fixed(50, 50) },
        .floating = .{ .z_index = 3 },
    });
    engine.closeElement();

    try engine.openElement(.{
        .layout = .{ .sizing = Sizing.fixed(50, 50) },
        .floating = .{ .z_index = 4 },
    });
    engine.closeElement();

    engine.closeElement();

    // Verify floating roots tracked
    try std.testing.expectEqual(@as(usize, 5), engine.floating_roots.len);
}

test "UTF-8 text wrapping handles multi-byte characters" {
    var engine = LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    // Mock text measurement: each codepoint is 10px wide
    const mockMeasure = struct {
        fn measure(
            text: []const u8,
            _: u16,
            font_size: u16,
            _: ?f32,
            _: ?*anyopaque,
        ) TextMeasurement {
            // Count UTF-8 codepoints, not bytes
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

    // Container that forces wrapping
    try engine.openElement(.{
        .layout = .{ .sizing = Sizing.fixed(100, 200) }, // 100px wide = 10 codepoints max
    });

    // Text with UTF-8 characters (each emoji is multi-byte but should be 1 codepoint = 10px)
    // "Hello 世界" = 8 codepoints (H,e,l,l,o, ,世,界) = 80px, fits in 100px
    try engine.text("Hello 世界", .{
        .font_size = 16,
        .wrap_mode = .words,
    });

    engine.closeElement();

    _ = try engine.endFrame();

    // Should render without crashing - UTF-8 handling works
    const text_elem = engine.elements.getConst(1);
    try std.testing.expect(text_elem.text_data != null);
}

test "UTF-8 text wrapping with emoji" {
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
        .layout = .{ .sizing = Sizing.fixed(50, 200) }, // Very narrow - 5 codepoints
    });

    // Emoji characters (4 bytes each in UTF-8, but 1 codepoint each)
    try engine.text("🎉🎊🎁", .{
        .font_size = 16,
        .wrap_mode = .words,
    });

    engine.closeElement();

    _ = try engine.endFrame();

    // Should complete without panic
    const text_elem = engine.elements.getConst(1);
    try std.testing.expect(text_elem.text_data != null);
}

test "capacity constants are reasonable" {
    // Verify our limits are sensible
    try std.testing.expect(MAX_ELEMENTS_PER_FRAME >= 1000);
    try std.testing.expect(MAX_OPEN_DEPTH >= 32);
    try std.testing.expect(MAX_FLOATING_ROOTS >= 64);
    try std.testing.expect(MAX_TRACKED_IDS >= 1000);
    try std.testing.expect(MAX_LINES_PER_TEXT >= 100);
}

test "id_to_index is pre-allocated" {
    var engine = LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    // After init, hashmaps should have capacity (pre-allocated)
    // We can't directly check capacity, but we can verify lookups work
    engine.beginFrame(800, 600);

    try engine.openElement(.{
        .id = LayoutId.init("root"),
        .layout = .{ .sizing = Sizing.fill() },
    });

    // Create several elements with comptime IDs
    try engine.openElement(.{
        .id = LayoutId.init("elem-a"),
        .layout = .{ .sizing = Sizing.fixed(10, 10) },
    });
    engine.closeElement();

    try engine.openElement(.{
        .id = LayoutId.init("elem-b"),
        .layout = .{ .sizing = Sizing.fixed(10, 10) },
    });
    engine.closeElement();

    try engine.openElement(.{
        .id = LayoutId.init("elem-c"),
        .layout = .{ .sizing = Sizing.fixed(10, 10) },
    });
    engine.closeElement();

    engine.closeElement();
    _ = try engine.endFrame();

    // All IDs should be trackable via getBoundingBox
    const root_bbox = engine.getBoundingBox(LayoutId.init("root").id);
    try std.testing.expect(root_bbox != null);

    const elem_a_bbox = engine.getBoundingBox(LayoutId.init("elem-a").id);
    try std.testing.expect(elem_a_bbox != null);

    const elem_b_bbox = engine.getBoundingBox(LayoutId.init("elem-b").id);
    try std.testing.expect(elem_b_bbox != null);

    const elem_c_bbox = engine.getBoundingBox(LayoutId.init("elem-c").id);
    try std.testing.expect(elem_c_bbox != null);
}

test "beginFrame clears fixed capacity arrays" {
    var engine = LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    // First frame
    engine.beginFrame(800, 600);
    try engine.openElement(.{
        .layout = .{ .sizing = Sizing.fill() },
        .floating = .{},
    });
    engine.closeElement();
    _ = try engine.endFrame();

    // Verify state after first frame
    try std.testing.expect(engine.floating_roots.len > 0 or engine.open_element_stack.len == 0);

    // Second frame should start clean
    engine.beginFrame(800, 600);
    try std.testing.expectEqual(@as(usize, 0), engine.open_element_stack.len);
    try std.testing.expectEqual(@as(usize, 0), engine.floating_roots.len);
}

// ============================================================================
// Phase 2 Tests: Performance Improvements
// ============================================================================

test "word-level measurement measures words not characters" {
    // This test verifies that findWordBoundaries correctly identifies word boundaries
    var words: FixedCapacityArray(WordInfo, MAX_WORDS_PER_TEXT) = .{};

    // Mock measure function that returns width = length * 10
    const measure = struct {
        fn measure(text: []const u8, _: u16, _: u16, _: ?f32, _: ?*anyopaque) TextMeasurement {
            return .{ .width = @floatFromInt(text.len * 10), .height = 20 };
        }
    }.measure;

    const config = TextConfig{ .font_size = 16 };
    const text = "hello world test";

    const word_count = sizing_pass.findWordBoundaries(text, measure, config, null, &words);

    // Should find 3 words: "hello", "world", "test"
    try std.testing.expectEqual(@as(u32, 3), word_count);
    try std.testing.expectEqual(@as(usize, 3), words.len);

    // First word: "hello" (5 chars * 10 = 50)
    try std.testing.expectEqual(@as(u32, 0), words.buffer[0].start);
    try std.testing.expectEqual(@as(u32, 5), words.buffer[0].end);
    try std.testing.expectEqual(@as(f32, 50), words.buffer[0].width);
    try std.testing.expect(!words.buffer[0].has_newline);

    // Second word: "world" (5 chars * 10 = 50)
    try std.testing.expectEqual(@as(u32, 6), words.buffer[1].start);
    try std.testing.expectEqual(@as(u32, 11), words.buffer[1].end);
    try std.testing.expectEqual(@as(f32, 50), words.buffer[1].width);

    // Third word: "test" (4 chars * 10 = 40)
    try std.testing.expectEqual(@as(u32, 12), words.buffer[2].start);
    try std.testing.expectEqual(@as(u32, 16), words.buffer[2].end);
    try std.testing.expectEqual(@as(f32, 40), words.buffer[2].width);
}

test "word-level measurement handles newlines" {
    var words: FixedCapacityArray(WordInfo, MAX_WORDS_PER_TEXT) = .{};

    const measure = struct {
        fn measure(text: []const u8, _: u16, _: u16, _: ?f32, _: ?*anyopaque) TextMeasurement {
            return .{ .width = @floatFromInt(text.len * 10), .height = 20 };
        }
    }.measure;

    const config = TextConfig{ .font_size = 16 };
    const text = "hello\nworld";

    const word_count = sizing_pass.findWordBoundaries(text, measure, config, null, &words);

    // Should find 2 words with newline marker on first
    try std.testing.expectEqual(@as(u32, 2), word_count);
    try std.testing.expect(words.buffer[0].has_newline);
    try std.testing.expect(!words.buffer[1].has_newline);
}

test "floating element resolved_floating_parent is cached at creation" {
    var engine = LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame(800, 600);

    // Create parent with ID
    try engine.openElement(.{
        .id = LayoutId.init("parent"),
        .layout = .{ .sizing = Sizing.fixed(200, 200) },
        .background_color = Color.white,
    });

    // Create floating child that references parent by ID
    try engine.openElement(.{
        .id = LayoutId.init("float"),
        .layout = .{ .sizing = Sizing.fixed(50, 50) },
        .floating = .{
            .attach_to_parent = false,
            .parent_id = LayoutId.init("parent").id,
        },
        .background_color = Color.red,
    });
    engine.closeElement();

    engine.closeElement();

    // Before endFrame, check that resolved_floating_parent was set
    const float_idx = engine.id_to_index.get(LayoutId.init("float").id).?;
    const float_elem = engine.elements.getConst(float_idx);

    // The resolved parent should be cached
    try std.testing.expect(float_elem.computed.resolved_floating_parent != null);

    const parent_idx = engine.id_to_index.get(LayoutId.init("parent").id).?;
    try std.testing.expectEqual(parent_idx, float_elem.computed.resolved_floating_parent.?);

    _ = try engine.endFrame();
}

test "floating expand.width makes element match parent width" {
    var engine = LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame(800, 600);

    // Create parent container
    try engine.openElement(.{
        .id = LayoutId.init("parent"),
        .layout = .{ .sizing = Sizing.fixed(300, 200) },
        .background_color = Color.white,
    });

    // Create floating child with expand.width = true
    try engine.openElement(.{
        .id = LayoutId.init("expand-float"),
        .layout = .{ .sizing = Sizing.fitContent() }, // Would normally fit content
        .floating = .{
            .attach_to_parent = true,
            .expand = .{ .width = true, .height = false },
        },
        .background_color = Color.blue,
    });
    engine.closeElement();

    engine.closeElement();

    _ = try engine.endFrame();

    // The floating element should have expanded to parent width
    const float_bbox = engine.getBoundingBox(LayoutId.init("expand-float").id).?;
    try std.testing.expectEqual(@as(f32, 300), float_bbox.width);
}

test "floating expand.height makes element match parent height" {
    var engine = LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame(800, 600);

    // Create parent container
    try engine.openElement(.{
        .id = LayoutId.init("parent"),
        .layout = .{ .sizing = Sizing.fixed(300, 250) },
        .background_color = Color.white,
    });

    // Create floating child with expand.height = true
    try engine.openElement(.{
        .id = LayoutId.init("expand-float"),
        .layout = .{ .sizing = Sizing.fitContent() },
        .floating = .{
            .attach_to_parent = true,
            .expand = .{ .width = false, .height = true },
        },
        .background_color = Color.green,
    });
    engine.closeElement();

    engine.closeElement();

    _ = try engine.endFrame();

    // The floating element should have expanded to parent height
    const float_bbox = engine.getBoundingBox(LayoutId.init("expand-float").id).?;
    try std.testing.expectEqual(@as(f32, 250), float_bbox.height);
}

test "floating expand both dimensions" {
    var engine = LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame(800, 600);

    // Create parent container
    try engine.openElement(.{
        .id = LayoutId.init("parent"),
        .layout = .{ .sizing = Sizing.fixed(400, 300) },
        .background_color = Color.white,
    });

    // Create floating child with both expand flags
    try engine.openElement(.{
        .id = LayoutId.init("modal"),
        .layout = .{ .sizing = Sizing.fitContent() },
        .floating = .{
            .attach_to_parent = true,
            .expand = .{ .width = true, .height = true },
        },
        .background_color = Color.red,
    });
    engine.closeElement();

    engine.closeElement();

    _ = try engine.endFrame();

    // The floating element should match parent in both dimensions
    const modal_bbox = engine.getBoundingBox(LayoutId.init("modal").id).?;
    try std.testing.expectEqual(@as(f32, 400), modal_bbox.width);
    try std.testing.expectEqual(@as(f32, 300), modal_bbox.height);
}

// ============================================================================
// Phase 3 Tests: Code Quality
// ============================================================================

test "Offset2D shared type works in FloatingConfig" {
    const float_config = types.FloatingConfig{
        .offset = types.Offset2D.init(10, 20),
        .z_index = 5,
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
        .width = 50.0,
        .trailing_space_width = 8.0,
        .has_newline = false,
    };

    try std.testing.expectEqual(@as(u32, 0), word.start);
    try std.testing.expectEqual(@as(u32, 5), word.end);
    try std.testing.expectEqual(@as(f32, 50.0), word.width);
    try std.testing.expectEqual(@as(f32, 8.0), word.trailing_space_width);
    try std.testing.expect(!word.has_newline);
}

test "MAX_WORDS_PER_TEXT constant is reasonable" {
    // Ensure we have enough capacity for typical text content
    try std.testing.expect(MAX_WORDS_PER_TEXT >= 1000);
    try std.testing.expect(MAX_WORDS_PER_TEXT <= 10000); // But not excessive
}

test "distributeGrow gives equal space to grow elements" {
    var engine = LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame(300, 100);

    try engine.openElement(.{
        .layout = .{ .sizing = Sizing.fill(), .layout_direction = .left_to_right },
    });
    {
        // Three grow elements should each get 100px (300/3)
        try engine.openElement(.{
            .id = LayoutId.init("grow1"),
            .layout = .{ .sizing = .{ .width = SizingAxis.grow(), .height = SizingAxis.fixed(50) } },
            .background_color = Color.red,
        });
        engine.closeElement();

        try engine.openElement(.{
            .id = LayoutId.init("grow2"),
            .layout = .{ .sizing = .{ .width = SizingAxis.grow(), .height = SizingAxis.fixed(50) } },
            .background_color = Color.green,
        });
        engine.closeElement();

        try engine.openElement(.{
            .id = LayoutId.init("grow3"),
            .layout = .{ .sizing = .{ .width = SizingAxis.grow(), .height = SizingAxis.fixed(50) } },
            .background_color = Color.blue,
        });
        engine.closeElement();
    }
    engine.closeElement();

    _ = try engine.endFrame();

    const grow1 = engine.getBoundingBox(LayoutId.init("grow1").id).?;
    const grow2 = engine.getBoundingBox(LayoutId.init("grow2").id).?;
    const grow3 = engine.getBoundingBox(LayoutId.init("grow3").id).?;

    try std.testing.expectEqual(@as(f32, 100), grow1.width);
    try std.testing.expectEqual(@as(f32, 100), grow2.width);
    try std.testing.expectEqual(@as(f32, 100), grow3.width);
}

test "distributeShrink respects minimum constraints" {
    var engine = LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame(100, 100); // Very small viewport

    try engine.openElement(.{
        .layout = .{ .sizing = Sizing.fill(), .layout_direction = .left_to_right },
    });
    {
        // Child with min constraint of 60 should not shrink below that
        try engine.openElement(.{
            .id = LayoutId.init("minchild"),
            .layout = .{
                .sizing = .{
                    .width = SizingAxis.fitMinMax(60, 200), // min=60, max=200
                    .height = SizingAxis.fixed(50),
                },
            },
            .background_color = Color.red,
        });
        engine.closeElement();

        try engine.openElement(.{
            .id = LayoutId.init("shrinkable"),
            .layout = .{
                .sizing = .{
                    .width = SizingAxis.fitMax(200), // min=0, can shrink fully
                    .height = SizingAxis.fixed(50),
                },
            },
            .background_color = Color.blue,
        });
        engine.closeElement();
    }
    engine.closeElement();

    _ = try engine.endFrame();

    const minchild = engine.getBoundingBox(LayoutId.init("minchild").id).?;

    // minchild should not shrink below its minimum of 60
    try std.testing.expect(minchild.width >= 60);
}

// =============================================================================
// Fast Path Edge Case Tests (tryUniformGrowFastPath)
// =============================================================================

test "fast path: single grow child gets full available space" {
    var engine = LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame(400, 300);

    try engine.openElement(.{
        .id = LayoutId.init("container"),
        .layout = .{ .sizing = Sizing.fixed(400, 300), .layout_direction = .left_to_right },
    });
    {
        // Single grow child should get full width (fast path with total_children == 1)
        try engine.openElement(.{
            .id = LayoutId.init("only-child"),
            .layout = .{ .sizing = Sizing.fill() },
            .background_color = Color.red,
        });
        engine.closeElement();
    }
    engine.closeElement();

    _ = try engine.endFrame();

    const child = engine.getBoundingBox(LayoutId.init("only-child").id).?;

    // Single grow child should fill entire container
    try std.testing.expectEqual(@as(f32, 400), child.width);
    try std.testing.expectEqual(@as(f32, 300), child.height);
}

test "fast path: all floating children falls back to slow path" {
    var engine = LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame(400, 300);

    try engine.openElement(.{
        .id = LayoutId.init("container"),
        .layout = .{
            .sizing = Sizing.fixed(400, 300),
            .layout_direction = .left_to_right,
        },
    });
    {
        // All children are floating - fast path should return false (actual_children == 0)
        try engine.openElement(.{
            .id = LayoutId.init("floating1"),
            .layout = .{ .sizing = Sizing.fixed(100, 100) },
            .floating = types.FloatingConfig.dropdown(),
            .background_color = Color.red,
        });
        engine.closeElement();

        try engine.openElement(.{
            .id = LayoutId.init("floating2"),
            .layout = .{ .sizing = Sizing.fixed(100, 100) },
            .floating = types.FloatingConfig.dropdown(),
            .background_color = Color.blue,
        });
        engine.closeElement();
    }
    engine.closeElement();

    _ = try engine.endFrame();

    // Both floating elements should be positioned (not crash)
    const f1 = engine.getBoundingBox(LayoutId.init("floating1").id).?;
    const f2 = engine.getBoundingBox(LayoutId.init("floating2").id).?;

    try std.testing.expectEqual(@as(f32, 100), f1.width);
    try std.testing.expectEqual(@as(f32, 100), f2.width);
}

test "fast path: mixed sizing children falls back to slow path" {
    var engine = LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame(400, 100);

    try engine.openElement(.{
        .id = LayoutId.init("container"),
        .layout = .{ .sizing = Sizing.fixed(400, 100), .layout_direction = .left_to_right },
    });
    {
        // Mixed sizing: fixed + grow + fit - should use slow path
        try engine.openElement(.{
            .id = LayoutId.init("fixed-child"),
            .layout = .{ .sizing = Sizing.fixed(100, 50) },
            .background_color = Color.red,
        });
        engine.closeElement();

        try engine.openElement(.{
            .id = LayoutId.init("grow-child"),
            .layout = .{ .sizing = Sizing.fill() },
            .background_color = Color.green,
        });
        engine.closeElement();

        try engine.openElement(.{
            .id = LayoutId.init("fit-child"),
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

    _ = try engine.endFrame();

    const fixed = engine.getBoundingBox(LayoutId.init("fixed-child").id).?;
    const grow = engine.getBoundingBox(LayoutId.init("grow-child").id).?;
    const fit = engine.getBoundingBox(LayoutId.init("fit-child").id).?;

    // Fixed child keeps its size
    try std.testing.expectEqual(@as(f32, 100), fixed.width);

    // Fit child wraps its content
    try std.testing.expectEqual(@as(f32, 50), fit.width);

    // Grow child gets remaining space: 400 - 100 - 50 = 250
    try std.testing.expectEqual(@as(f32, 250), grow.width);
}

test "fast path: grow with min constraint falls back to slow path" {
    var engine = LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame(300, 100);

    try engine.openElement(.{
        .id = LayoutId.init("container"),
        .layout = .{ .sizing = Sizing.fixed(300, 100), .layout_direction = .left_to_right },
    });
    {
        // Grow with min constraint - fast path should bail (mm.min != 0)
        try engine.openElement(.{
            .id = LayoutId.init("constrained-grow"),
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
            .id = LayoutId.init("normal-grow"),
            .layout = .{ .sizing = Sizing.fill() },
            .background_color = Color.green,
        });
        engine.closeElement();
    }
    engine.closeElement();

    _ = try engine.endFrame();

    const constrained = engine.getBoundingBox(LayoutId.init("constrained-grow").id).?;
    const normal = engine.getBoundingBox(LayoutId.init("normal-grow").id).?;

    // Both should share space equally (150 each) since slow path handles this
    // The min constraint of 80 is satisfied by the equal split
    try std.testing.expectEqual(@as(f32, 150), constrained.width);
    try std.testing.expectEqual(@as(f32, 150), normal.width);
}
