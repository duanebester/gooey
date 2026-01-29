# Gooey Testing Guide

Testing utilities and patterns for Gooey applications.

## Overview

The `testing` module provides mock implementations and helpers for testing Gooey code
without platform dependencies. This enables fast, isolated unit tests that don't require
a display, GPU, clipboard access, or file dialogs.

```zig
const gooey = @import("gooey");
const testing = gooey.testing;
```

> **Note:** The testing module is only available when `@import("builtin").is_test` is true.

---

## Available Mocks

| Mock                | Purpose                         | Platform Dependency Replaced       |
| ------------------- | ------------------------------- | ---------------------------------- |
| `MockRenderer`      | Track render calls              | Metal, Vulkan, WebGPU              |
| `MockClipboard`     | In-memory clipboard             | NSPasteboard, Wayland, Browser     |
| `MockSvgRasterizer` | Simulate SVG rasterization      | CoreGraphics, Cairo, Canvas        |
| `MockFontFace`      | Configurable font metrics       | CoreText, FreeType, Browser fonts  |
| `MockFileDialog`    | Simulate file open/save dialogs | NSOpenPanel, GTK, Browser file API |

---

## MockRenderer

Tracks rendering method calls without any GPU operations.

### Basic Usage

```zig
test "render pipeline" {
    var renderer = try testing.MockRenderer.init(testing.allocator);
    defer renderer.deinit();

    // Simulate a frame
    try renderer.beginFrame(800, 600, 2.0);
    renderer.renderScene(&my_scene);
    renderer.endFrame();

    // Verify
    try std.testing.expectEqual(@as(u32, 1), renderer.begin_frame_count);
    try std.testing.expectEqual(@as(u32, 1), renderer.render_scene_count);
    try std.testing.expect(renderer.isFrameBalanced());
}
```

### Simulating Failures

```zig
test "handle render failure" {
    var renderer = try testing.MockRenderer.init(testing.allocator);
    defer renderer.deinit();

    renderer.should_fail_begin_frame = true;

    const result = renderer.beginFrame(800, 600, 1.0);
    try std.testing.expectError(MockRenderer.Error.MockFailure, result);
}
```

### Tracked State

| Field                       | Description                            |
| --------------------------- | -------------------------------------- |
| `begin_frame_count`         | Number of `beginFrame` calls           |
| `end_frame_count`           | Number of `endFrame` calls             |
| `render_scene_count`        | Number of `renderScene`/`render` calls |
| `resize_count`              | Number of `resize` calls               |
| `last_width`, `last_height` | Last dimensions passed                 |
| `last_scale`                | Last scale factor passed               |

---

## MockClipboard

In-memory clipboard for testing copy/paste operations.

### Basic Usage

```zig
test "copy paste" {
    var clipboard = testing.MockClipboard.init(testing.allocator);
    defer clipboard.deinit();

    // Copy
    try std.testing.expect(clipboard.setText("Hello, World!"));

    // Paste
    const text = clipboard.getText(testing.allocator);
    defer if (text) |t| testing.allocator.free(t);

    try std.testing.expectEqualStrings("Hello, World!", text.?);
}
```

### Direct Access (Test Setup)

Use direct methods to set up test state without affecting call counters:

```zig
test "preset clipboard content" {
    var clipboard = testing.MockClipboard.init(testing.allocator);
    defer clipboard.deinit();

    // Set up (doesn't increment set_count)
    try clipboard.setContentDirect("preset");

    // Now test your code
    my_paste_handler(&clipboard);

    // Verify only your code's calls
    try std.testing.expectEqual(@as(u32, 1), clipboard.get_count);
}
```

### Simulating Failures

```zig
test "handle clipboard unavailable" {
    var clipboard = testing.MockClipboard.init(testing.allocator);
    defer clipboard.deinit();

    clipboard.should_fail_get = true;

    // Your code should handle null gracefully
    const text = clipboard.getText(testing.allocator);
    try std.testing.expect(text == null);
}
```

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

## MockFileDialog

Simulates file open/save dialogs for testing file selection workflows.

### Basic Usage

```zig
test "open file" {
    var dialog = testing.MockFileDialog.init(testing.allocator);
    defer dialog.deinit();

    // Configure what the "user" will select
    try dialog.setOpenResponse(&.{"/path/to/file.txt"});

    // Call the mock dialog
    const result = dialog.promptForPaths(testing.allocator, .{});
    defer if (result) |r| r.deinit();

    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("/path/to/file.txt", result.?.paths[0]);
    try std.testing.expectEqual(@as(u32, 1), dialog.open_count);
}
```

### Save Dialog

```zig
test "save file" {
    var dialog = testing.MockFileDialog.init(testing.allocator);
    defer dialog.deinit();

    try dialog.setSaveResponse("/documents/report.pdf");

    const result = dialog.promptForNewPath(testing.allocator, .{
        .suggested_name = "report.pdf",
        .directory = "/documents",
    });
    defer if (result) |r| testing.allocator.free(r);

    try std.testing.expectEqualStrings("/documents/report.pdf", result.?);
}
```

### Multiple File Selection

```zig
test "select multiple files" {
    var dialog = testing.MockFileDialog.init(testing.allocator);
    defer dialog.deinit();

    try dialog.setOpenResponse(&.{
        "/photos/img1.jpg",
        "/photos/img2.jpg",
        "/photos/img3.jpg",
    });

    const result = dialog.promptForPaths(testing.allocator, .{
        .multiple = true,
        .allowed_extensions = &.{ "jpg", "png" },
    });
    defer if (result) |r| r.deinit();

    try std.testing.expectEqual(@as(usize, 3), result.?.paths.len);
}
```

### Simulating User Cancellation

```zig
test "user cancels dialog" {
    var dialog = testing.MockFileDialog.init(testing.allocator);
    defer dialog.deinit();

    dialog.setCancelOpen();

    const result = dialog.promptForPaths(testing.allocator, .{});
    try std.testing.expect(result == null);
    try std.testing.expectEqual(@as(u32, 1), dialog.open_count);
}

test "user cancels save" {
    var dialog = testing.MockFileDialog.init(testing.allocator);
    defer dialog.deinit();

    dialog.setCancelSave();

    const result = dialog.promptForNewPath(testing.allocator, .{});
    try std.testing.expect(result == null);
}
```

### Verifying Dialog Options

```zig
test "directory picker configured correctly" {
    var dialog = testing.MockFileDialog.init(testing.allocator);
    defer dialog.deinit();

    _ = dialog.promptForPaths(testing.allocator, .{
        .directories = true,
        .files = false,
        .prompt = "Select Folder",
    });

    try std.testing.expect(dialog.lastOpenAllowedDirectories());
    try std.testing.expectEqualStrings("Select Folder", dialog.last_open_options.?.prompt.?);
}
```

### Tracked State

| Field               | Description                        |
| ------------------- | ---------------------------------- |
| `open_count`        | Number of `promptForPaths` calls   |
| `save_count`        | Number of `promptForNewPath` calls |
| `last_open_options` | Options from last open dialog      |
| `last_save_options` | Options from last save dialog      |

---

## Test Helpers

### Geometry Assertions

Floating-point comparisons with tolerance (0.001):

```zig
const core = gooey.core;

test "color calculation" {
    const actual = compute_color();
    const expected = core.Color.rgb(1.0, 0.5, 0.0);

    try testing.expectColorEqual(expected, actual);
}

test "layout bounds" {
    const actual = element.getBounds();
    const expected = core.BoundsF.init(10.0, 20.0, 100.0, 200.0);

    try testing.expectBoundsEqual(expected, actual);
}

test "position" {
    const actual = widget.getPosition();
    const expected = core.PointF{ .x = 50.0, .y = 75.0 };

    try testing.expectPointEqual(expected, actual);
}

test "size" {
    const actual = widget.getSize();
    const expected = core.SizeF{ .width = 100.0, .height = 50.0 };

    try testing.expectSizeEqual(expected, actual);
}
```

---

## Patterns

### Test Isolation with Reset

Use `reset()` to clear state between test cases in parameterized tests:

```zig
test "multiple scenarios" {
    var renderer = try testing.MockRenderer.init(testing.allocator);
    defer renderer.deinit();

    // Scenario 1
    try renderer.beginFrame(800, 600, 1.0);
    renderer.endFrame();
    try std.testing.expectEqual(@as(u32, 1), renderer.begin_frame_count);

    renderer.reset();

    // Scenario 2 (counters back to 0)
    try renderer.beginFrame(1920, 1080, 2.0);
    renderer.endFrame();
    try std.testing.expectEqual(@as(u32, 1), renderer.begin_frame_count);
}
```

### Verifying Call Sequences

```zig
test "proper frame lifecycle" {
    var renderer = try testing.MockRenderer.init(testing.allocator);
    defer renderer.deinit();

    run_app_frame(&renderer);

    // Verify balanced begin/end
    try std.testing.expect(renderer.isFrameBalanced());

    // Verify render was called
    try std.testing.expect(renderer.totalRenderCalls() > 0);
}
```

### Testing Error Paths

```zig
test "graceful degradation" {
    var clipboard = testing.MockClipboard.init(testing.allocator);
    defer clipboard.deinit();

    // Simulate system clipboard unavailable
    clipboard.should_fail_get = true;
    clipboard.should_fail_set = true;

    // Your code should not crash
    const result = my_paste_function(&clipboard);
    try std.testing.expect(result == .no_content);
}
```

---

## Interface Verification

All mocks include compile-time interface verification to ensure they match
the real implementation signatures:

```zig
// In mock_renderer.zig
comptime {
    interface_verify.verifyRendererInterface(@This());
}

// In mock_clipboard.zig
comptime {
    interface_verify.verifyClipboardInterface(@This());
}

// In mock_svg_rasterizer.zig
comptime {
    interface_verify.verifySvgRasterizerInterface(@This());
    interface_verify.verifySvgRasterizerModule(@This());
}

// In mock_file_dialog.zig
comptime {
    interface_verify.verifyFileDialogInterface(@This());
}
```

If the real interface changes, the mocks will fail to compile, ensuring
test code stays in sync.

---

## Running Tests

```bash
# Run all tests
zig build test

# Run with summary
zig build test --summary all

# Run specific test file
zig test src/testing/mock_renderer.zig
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
