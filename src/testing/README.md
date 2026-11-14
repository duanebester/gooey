# Gooey Testing Guide

Testing utilities and patterns for Gooey applications.

## Overview

The `testing` module holds the headless backend the core runs on in tests, record dumps for
goldens, two leaf mocks, and assertion helpers. It needs no display, GPU, clipboard, or file
dialogs.

```zig
const gooey = @import("gooey");
const testing = gooey.testing;
```

> **Note:** The testing module is only available when `@import("builtin").is_test` is true,
> or in the goldens' synthetic-text build.

- `NullRenderer` and `test_backend`: the core's `Renderer` for tests, which records packed
  frames instead of drawing.
- `record_dump`: text dumps of packed frames, hit records, and accessibility trees.
- `MockSvgRasterizer`: simulates SVG rasterization (CoreGraphics, Cairo, Canvas).
- `MockFontFace`: configurable font metrics (CoreText, FreeType, browser fonts).

---

## Testing an app headless

`App.initHeadless` reserves an app without a platform window, on `TestBackend`. A test
pushes input into the window's queue exactly as a platform does, runs one tick per frame,
and reads the rendered frame:

```zig
test "Add appends a todo" {
    const app = try std.testing.allocator.create(App);
    defer std.testing.allocator.destroy(app);
    try app.initHeadless(std.testing.allocator, std.testing.io, .{ .scale_factor = 1 });
    defer app.deinitHeadless();

    app.tick(16_666_667);
    // The rendered frame holds the hit records and the accessibility tree, with
    // each node's bounds; a test finds what to click there.
    const rendered = app.window.rendered();
    try std.testing.expect(rendered.a11y_count > 0);

    const press: gooey.input.MouseEvent = .{
        .position = .{ .x = 276, .y = 106 }, // the Add button's centre
        .button = .left,
        .click_count = 1,
        .modifiers = .{},
    };
    app.window.queue.push(.{ .input = .{ .mouse_down = press } });
    app.window.queue.push(.{ .input = .{ .mouse_up = press } });
    app.tick(33_333_334);
    try std.testing.expectEqual(@as(u32, 1), app.state.count);
}
```

Every tick after init runs under the lifecycle guard, so an allocation through Gooey's
allocator panics. To also check what was drawn, set `app.window.presenter` to a
`NullRenderer`; `src/testing/goldens/core.zig` does this and dumps each frame with
`record_dump`.

## Goldens

`src/testing/goldens/` replays scripted input traces (`traces.zig`) against counter, todo,
and actions on the core and compares each frame's packed records, hit records, and
accessibility tree with `core_*.txt`. They run in `zig build test`; `zig build goldens`
rewrites the files after an intended change. `legacy_*.txt` are the 0.3.1 captures, which
`compare.zig` checks the core's output against through its normalisation rules.

---

## MockSvgRasterizer

Simulates SVG path rasterization without graphics library dependencies.

### Basic Usage

```zig
test "rasterize icon" {
    var rasterizer = testing.MockSvgRasterizer.init();

    var buffer: [48 * 48 * 4]u8 = undefined;
    const result = try rasterizer.rasterize(
        testing.allocator,
        "M0 0 L10 10 Z",  // SVG path data
        24.0,             // viewbox
        48,               // device size
        &buffer,
    );

    try std.testing.expectEqual(@as(u32, 48), result.width);
    try std.testing.expectEqual(@as(u32, 1), rasterizer.rasterize_count);
}
```

### Custom Return Values

```zig
test "icon with offset" {
    var rasterizer = testing.MockSvgRasterizer.init();
    rasterizer.setResultDimensions(32, 24);
    rasterizer.setResultOffsets(-5, 10);

    var buffer: [48 * 48 * 4]u8 = undefined;
    const result = try rasterizer.rasterize(...);

    try std.testing.expectEqual(@as(u32, 32), result.width);
    try std.testing.expectEqual(@as(i16, -5), result.offset_x);
}
```

### Module-Level Testing

For code that uses module-level `rasterize()` functions:

```zig
test "svg component" {
    var rasterizer = testing.MockSvgRasterizer.init();
    testing.mock_svg_rasterizer.setGlobalMock(&rasterizer);
    defer testing.mock_svg_rasterizer.clearGlobalMock();

    // Code that calls svg.rasterize() will use the mock
    render_my_icon();

    try std.testing.expectEqual(@as(u32, 1), rasterizer.rasterize_count);
}
```

---

## MockFontFace

Provides a configurable `FontFace` implementation for testing text layout,
shaping, and rendering without loading real fonts.

### Basic Usage

```zig
test "text measurement" {
    var mock = testing.MockFontFace.init(testing.allocator);
    defer mock.deinit();

    // Configure glyph mappings
    try mock.setGlyphMapping('A', 65);
    try mock.setGlyphMapping('B', 66);
    try mock.setGlyphAdvance(65, 12.0);

    // Get FontFace interface (VTable-based)
    var face = mock.fontFace();

    try std.testing.expectEqual(@as(u16, 65), face.glyphIndex('A'));
    try std.testing.expectEqual(@as(f32, 12.0), face.glyphAdvance(65));
}
```

### Pre-configured Fonts

```zig
test "ascii text layout" {
    var mock = testing.MockFontFace.init(testing.allocator);
    defer mock.deinit();

    // Quick setup: A-Z, a-z, 0-9, space mapped to sequential IDs
    try mock.configureAsAsciiFont();

    // All ASCII letters now have valid glyph IDs
    try std.testing.expect(mock.glyphIndex('A') != 0);
    try std.testing.expect(mock.glyphIndex('z') != 0);
    try std.testing.expect(mock.glyphIndex('5') != 0);
}

test "monospace editor" {
    var mock = testing.MockFontFace.init(testing.allocator);
    defer mock.deinit();

    mock.configureAsMonospace(8.0);

    // All glyphs now have 8.0 advance width
    try std.testing.expectEqual(@as(f32, 8.0), mock.default_advance);
    try std.testing.expect(mock.metrics.is_monospace);
}
```

### Custom Glyph Metrics

```zig
test "glyph bounds" {
    var mock = testing.MockFontFace.init(testing.allocator);
    defer mock.deinit();

    try mock.setGlyphMetrics(42, .{
        .glyph_id = 42,
        .advance_x = 20.0,
        .advance_y = 0,
        .bearing_x = 2.0,
        .bearing_y = 15.0,
        .width = 16.0,
        .height = 18.0,
    });

    const m = mock.glyphMetrics(42);
    try std.testing.expectEqual(@as(f32, 16.0), m.width);
}
```

### Glyph Rendering

```zig
test "glyph rasterization" {
    var mock = testing.MockFontFace.init(testing.allocator);
    defer mock.deinit();

    var buffer: [1024]u8 = undefined;

    const result = try mock.renderGlyphSubpixel(
        42,    // glyph_id
        16.0,  // font_size
        2.0,   // scale
        0.25,  // subpixel_x
        0.0,   // subpixel_y
        &buffer,
        1024,
    );

    try std.testing.expectEqual(@as(u32, 1), mock.render_glyph_count);
    try std.testing.expectEqual(@as(f32, 16.0), mock.last_font_size.?);
}
```

### Simulating Failures

```zig
test "handle missing glyph" {
    var mock = testing.MockFontFace.init(testing.allocator);
    defer mock.deinit();

    mock.should_fail_render = true;
    mock.render_error = error.OutOfMemory;

    var buffer: [1024]u8 = undefined;
    const result = mock.renderGlyphSubpixel(1, 12.0, 1.0, 0, 0, &buffer, 1024);

    try std.testing.expectError(error.OutOfMemory, result);
}
```

### Tracked State

| Field                          | Description                           |
| ------------------------------ | ------------------------------------- |
| `glyph_index_count`            | Number of `glyphIndex` calls          |
| `glyph_advance_count`          | Number of `glyphAdvance` calls        |
| `glyph_metrics_count`          | Number of `glyphMetrics` calls        |
| `render_glyph_count`           | Number of `renderGlyphSubpixel` calls |
| `last_codepoint`               | Last codepoint looked up              |
| `last_glyph_id`                | Last glyph ID queried                 |
| `last_font_size`, `last_scale` | Last render parameters                |

---

## Test Helpers

### Geometry Assertions

Floating-point comparisons with tolerance (0.001), over the geometry types in
`gooey.internals.geometry`:

```zig
const geometry = gooey.internals.geometry;

test "layout bounds" {
    const actual = computeBounds();
    const expected = geometry.BoundsF.init(10.0, 20.0, 100.0, 200.0);

    try testing.expectBoundsEqual(expected, actual);
}
```

`expectColorEqual`, `expectPointEqual`, and `expectSizeEqual` work the same way on
`gooey.Color`, `geometry.PointF`, and `geometry.SizeF`.

---

## Interface Verification

The SVG mock verifies its signatures against the real rasterizer at compile time, so it
fails to compile when the interface changes:

```zig
// In mock_svg_rasterizer.zig
comptime {
    interface_verify.verifySvgRasterizerInterface(@This());
    interface_verify.verifySvgRasterizerModule(@This());
}
```

Renderers, `NullRenderer` included, are checked the same way by `backend.verifyRenderer`
(`src/core/backend.zig`, contract §9).

---

## Running Tests

```bash
# Run all tests
zig build test

# Run with summary
zig build test --summary all

# Rewrite the goldens after an intended change
zig build goldens
```

---

## Adding New Mocks

When adding a new mock:

1. **Create the mock file** in `src/testing/`
2. **Follow the existing pattern:**
   - Call tracking fields (`*_count`)
   - Last value fields (`last_*`)
   - Controllable behavior (`should_fail_*`)
   - `init()`, `deinit()`, `reset()` methods
   - Comptime interface verification
3. **Add comprehensive tests** in the same file
4. **Export from `mod.zig`**
5. **Update this README**

Template:

```zig
const interface_verify = @import("../core/interface_verify.zig");

pub const MockFoo = struct {
    // Call tracking
    call_count: u32 = 0,

    // Last values
    last_arg: ?SomeType = null,

    // Controllable behavior
    should_fail: bool = false,

    const Self = @This();

    pub fn init() Self {
        return Self{};
    }

    pub fn theMethod(self: *Self, arg: SomeType) !Result {
        self.call_count += 1;
        self.last_arg = arg;

        if (self.should_fail) return error.MockFailure;
        return .{};
    }

    pub fn reset(self: *Self) void {
        self.* = Self{};
    }

    comptime {
        interface_verify.verifyFooInterface(@This());
    }
};
```
