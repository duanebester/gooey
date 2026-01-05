# Gooey Layout System

A Clay-inspired declarative layout engine for building UI hierarchies with flexbox-style sizing and positioning.

## Overview

The layout system uses an immediate-mode API where you declare your UI structure each frame:

1. **Begin frame** - Reset layout state and set viewport size
2. **Declare elements** - Open/close containers, add text
3. **End frame** - Compute layout and get render commands

All layout data is allocated from a per-frame arena and automatically cleaned up.

## Quick Start

```zig
const layout = @import("layout/layout.zig");
const LayoutEngine = layout.LayoutEngine;
const LayoutId = layout.LayoutId;
const Sizing = layout.Sizing;
const SizingAxis = layout.SizingAxis;
const Padding = layout.Padding;
const ChildAlignment = layout.ChildAlignment;
const Color = layout.Color;
const CornerRadius = layout.CornerRadius;

// Initialize once
var engine = LayoutEngine.init(allocator);
defer engine.deinit();

// Each frame:
engine.beginFrame(window_width, window_height);

try engine.openElement(.{
    .id = LayoutId.init("root"),
    .layout = .{
        .sizing = Sizing.fill(),
        .child_alignment = ChildAlignment.center(),
    },
});
{
    try engine.openElement(.{
        .id = LayoutId.init("card"),
        .layout = .{
            .sizing = Sizing.fixed(300, 200),
            .padding = Padding.all(16),
        },
        .background_color = Color.white,
        .corner_radius = CornerRadius.all(8),
    });

    try engine.text("Hello, World!", .{
        .color = Color.black,
        .font_size = 16,
    });

    engine.closeElement(); // card
}
engine.closeElement(); // root

const commands = try engine.endFrame();
// Use commands to render...
```

## Core Concepts

### Element IDs

Every element can have a unique ID for later lookup (e.g., hit testing):

```zig
// Compile-time string ID
.id = LayoutId.init("my_button")

// Indexed ID for lists
.id = LayoutId.indexed("list_item", index)

// Child ID relative to parent
.id = LayoutId.child(parent_id, "child_name")
```

### Sizing

Elements can size themselves in four ways:

| Type      | Description                    | Example                   |
| --------- | ------------------------------ | ------------------------- |
| `fit`     | Shrink to fit content          | `SizingAxis.fit()`        |
| `grow`    | Expand to fill available space | `SizingAxis.grow()`       |
| `fixed`   | Exact pixel size               | `SizingAxis.fixed(100)`   |
| `percent` | Percentage of parent           | `SizingAxis.percent(0.5)` |

**Convenience constructors:**

```zig
// Both dimensions
Sizing.fill()        // grow, grow
Sizing.fitContent()  // fit, fit
Sizing.fixed(w, h)   // fixed, fixed

// With min/max constraints
SizingAxis.fitMin(50)           // fit with minimum 50px
SizingAxis.growMax(300)         // grow up to 300px
SizingAxis.fitMinMax(50, 200)   // fit between 50-200px
```

### Layout Direction

Children are laid out in one direction:

```zig
.layout_direction = .left_to_right  // horizontal row (default)
.layout_direction = .top_to_bottom  // vertical column
```

Or use the shortcuts:

```zig
.layout = LayoutConfig.row(8)    // horizontal with 8px gap
.layout = LayoutConfig.column(8) // vertical with 8px gap
```

### Child Alignment

Position children within the container:

```zig
.child_alignment = ChildAlignment.center()      // center both axes
.child_alignment = ChildAlignment.topLeft()     // top-left corner
.child_alignment = .{ .x = .center, .y = .top } // custom
```

### Padding & Gaps

```zig
.padding = Padding.all(16)              // 16px all sides
.padding = Padding.symmetric(20, 10)    // 20px horizontal, 10px vertical
.padding = .{ .left = 8, .top = 4, .right = 8, .bottom = 4 }

.child_gap = 12  // 12px between children
```

### Visual Styling

```zig
.background_color = Color.white
.background_color = Color.rgb(0.2, 0.5, 1.0)    // 0-1 floats
.background_color = Color.rgb8(51, 128, 255)    // 0-255 integers
.background_color = Color.hex(0x3380FF)         // hex value

.corner_radius = CornerRadius.all(8)
.corner_radius = CornerRadius.top(8)  // only top corners

.border = BorderConfig.all(Color.black, 1)
```

## Complete Example: Login Card

```zig
fn buildLoginUI(engine: *LayoutEngine) !void {
    engine.beginFrame(800, 600);

    // Root - fills viewport, centers content
    try engine.openElement(.{
        .id = LayoutId.init("root"),
        .layout = .{
            .sizing = Sizing.fill(),
            .layout_direction = .top_to_bottom,
            .child_alignment = ChildAlignment.center(),
            .padding = Padding.all(20),
        },
    });
    {
        // Card container
        try engine.openElement(.{
            .id = LayoutId.init("card"),
            .layout = .{
                .sizing = .{
                    .width = SizingAxis.fixed(400),
                    .height = SizingAxis.fit(),
                },
                .layout_direction = .top_to_bottom,
                .padding = Padding.all(24),
                .child_gap = 16,
                .child_alignment = .{ .x = .center, .y = .top },
            },
            .background_color = Color.white,
            .corner_radius = CornerRadius.all(12),
        });
        {
            // Title
            try engine.openElement(.{
                .id = LayoutId.init("title"),
                .layout = .{ .sizing = Sizing.fitContent() },
            });
            try engine.text("Login", .{
                .color = Color.rgb(0.1, 0.1, 0.1),
                .font_size = 20,
            });
            engine.closeElement();

            // Username field placeholder
            try engine.openElement(.{
                .id = LayoutId.init("username_field"),
                .layout = .{
                    .sizing = .{
                        .width = SizingAxis.percent(1.0),
                        .height = SizingAxis.fixed(36),
                    },
                },
                .background_color = Color.rgb(0.95, 0.95, 0.95),
                .corner_radius = CornerRadius.all(4),
            });
            engine.closeElement();

            // Button row
            try engine.openElement(.{
                .id = LayoutId.init("button_row"),
                .layout = .{
                    .sizing = .{
                        .width = SizingAxis.percent(1.0),
                        .height = SizingAxis.fixed(44),
                    },
                    .layout_direction = .left_to_right,
                    .child_gap = 12,
                    .child_alignment = ChildAlignment.center(),
                },
            });
            {
                // Cancel - fixed width
                try engine.openElement(.{
                    .id = LayoutId.init("cancel_btn"),
                    .layout = .{
                        .sizing = Sizing.fixed(100, 36),
                        .child_alignment = ChildAlignment.center(),
                    },
                    .background_color = Color.rgb(0.9, 0.9, 0.9),
                    .corner_radius = CornerRadius.all(6),
                });
                try engine.text("Cancel", .{ .color = Color.rgb(0.3, 0.3, 0.3) });
                engine.closeElement();

                // Submit - grows to fill remaining space
                try engine.openElement(.{
                    .id = LayoutId.init("submit_btn"),
                    .layout = .{
                        .sizing = .{
                            .width = SizingAxis.grow(),
                            .height = SizingAxis.fixed(36),
                        },
                        .child_alignment = ChildAlignment.center(),
                    },
                    .background_color = Color.rgb(0.2, 0.5, 1.0),
                    .corner_radius = CornerRadius.all(6),
                });
                try engine.text("Sign In", .{ .color = Color.white });
                engine.closeElement();
            }
            engine.closeElement(); // button_row
        }
        engine.closeElement(); // card
    }
    engine.closeElement(); // root

    const commands = try engine.endFrame();

    // Query element positions for hit-testing
    if (engine.getBoundingBox(LayoutId.init("submit_btn").id)) |bbox| {
        // bbox.x, bbox.y, bbox.width, bbox.height
    }
}
```

## API Reference

### LayoutEngine

| Method                            | Description                            |
| --------------------------------- | -------------------------------------- |
| `init(allocator)`                 | Create a new layout engine             |
| `deinit()`                        | Free resources                         |
| `setMeasureTextFn(fn, user_data)` | Set text measurement callback          |
| `beginFrame(width, height)`       | Start a new frame                      |
| `openElement(decl)`               | Open a container element               |
| `closeElement()`                  | Close the current element              |
| `text(content, config)`           | Add a text leaf element                |
| `endFrame()`                      | Compute layout, return render commands |
| `getBoundingBox(id)`              | Get computed bounds for an element     |

### ElementDeclaration

| Field              | Type            | Default | Description               |
| ------------------ | --------------- | ------- | ------------------------- |
| `id`               | `LayoutId`      | `.none` | Unique element identifier |
| `layout`           | `LayoutConfig`  | `{}`    | Sizing and positioning    |
| `background_color` | `?Color`        | `null`  | Fill color                |
| `corner_radius`    | `CornerRadius`  | `{}`    | Rounded corners           |
| `border`           | `?BorderConfig` | `null`  | Border styling            |
| `scroll`           | `?ScrollConfig` | `null`  | Scrollable container      |
| `user_data`        | `?*anyopaque`   | `null`  | Custom data pointer       |

### LayoutConfig

| Field                    | Type                   | Default          | Description                     |
| ------------------------ | ---------------------- | ---------------- | ------------------------------- |
| `sizing`                 | `Sizing`               | fit/fit          | Width and height sizing         |
| `padding`                | `Padding`              | `{}`             | Inner spacing                   |
| `child_gap`              | `u16`                  | `0`              | Space between children          |
| `child_alignment`        | `ChildAlignment`       | top-left         | How to align children           |
| `layout_direction`       | `LayoutDirection`      | `.left_to_right` | Row or column                   |
| `main_axis_distribution` | `MainAxisDistribution` | `.start`         | How to distribute extra space   |
| `aspect_ratio`           | `?f32`                 | `null`           | Width/height ratio (e.g., 16/9) |

### FloatingConfig

Floating elements are positioned relative to a parent but don't affect sibling layout:

```zig
.floating = .{
    .offset = Offset2D.init(10, 20),     // Position offset
    .z_index = 100,                       // Render order
    .attach_to_parent = true,             // Use direct parent
    .parent_id = LayoutId.init("target").id,  // Or reference by ID
    .element_attach = .left_top,          // Anchor point on this element
    .parent_attach = .left_bottom,        // Anchor point on parent
    .expand = .{ .width = true, .height = false },  // Match parent size
}
```

**Preset configurations:**

```zig
FloatingConfig.dropdown()  // Positioned below parent
FloatingConfig.tooltip()   // Positioned above parent with offset
FloatingConfig.modal()     // Centered on viewport
```

### TextConfig

```zig
try engine.text("Hello, World!", .{
    .color = Color.black,
    .font_id = 0,
    .font_size = 16,
    .line_height = 1.2,           // Multiplier of font_size
    .letter_spacing = 0,
    .wrap_mode = .words,          // .none, .words, .newlines
    .alignment = .left,           // .left, .center, .right
    .decoration = .{ .underline = false, .strikethrough = false },
});
```

### Offset2D

Shared type for 2D offsets (used in FloatingConfig and ScrollConfig):

```zig
const offset = Offset2D.init(10, 20);
const zero = Offset2D.zero();
```

## Capacity Constants

The layout engine uses fixed-capacity collections (no allocation during frames):

| Constant                 | Value | Description                         |
| ------------------------ | ----- | ----------------------------------- |
| `MAX_ELEMENTS_PER_FRAME` | 8192  | Maximum elements in a single frame  |
| `MAX_OPEN_DEPTH`         | 64    | Maximum nesting depth               |
| `MAX_FLOATING_ROOTS`     | 256   | Maximum floating elements per frame |
| `MAX_TRACKED_IDS`        | 4096  | Maximum elements with IDs           |
| `MAX_LINES_PER_TEXT`     | 1024  | Maximum wrapped lines per text      |
| `MAX_WORDS_PER_TEXT`     | 2048  | Maximum words for text wrapping     |

## Notes

- **Text strings** are copied into the per-frame arena, so they're safe to use with temporary buffers.
- **ID collisions** are detected in debug builds and logged as warnings.
- **Text elements** must be inside a container (enforced by debug assertion).
- **Zero allocation during frame** - all collections use fixed capacity, panic on overflow.
- The layout algorithm runs in these phases:
  1. **Min sizes** (bottom-up) - compute minimum content sizes
  2. **Final sizes** (top-down) - distribute available space
  3. **Text wrapping** - wrap text using word-level measurement for performance
  4. **Positions** (top-down) - compute final bounding boxes
  5. **Floating elements** - position floating elements relative to parents
  6. **Render commands** - generate drawing instructions sorted by z-index
