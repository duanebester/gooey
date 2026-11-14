# Gooey Layout System

A Clay-inspired declarative layout engine for building UI hierarchies with flexbox-style sizing and positioning.

This is internal machinery (`gooey.internals.layout`), not app API: apps lay out with
`ui.box` and `ui.Style` (`docs/v0.4.0-core-contract.md` §1). The core (`src/core/cx.zig`)
opens one element per node and reads each node's bounds from the engine's element list by
index (`src/core/emit.zig`). The snippets below compile against v0.5.3's engine
(`gooey.internals.layout`).

## Overview

The layout system uses an immediate-mode API where you declare your UI structure each frame:

1. **Begin frame** - Reset layout state and set viewport size
2. **Declare elements** - Open/close containers, add text
3. **End frame** - Compute every element's bounds; `core/emit.zig` paints from them

All layout data is allocated from a per-frame arena and automatically cleaned up.

## Quick Start

```zig
const gooey = @import("gooey");
const layout = gooey.internals.layout;
const LayoutEngine = layout.LayoutEngine;
const Sizing = layout.Sizing;
const SizingAxis = layout.SizingAxis;
const Padding = layout.Padding;
const ChildAlignment = layout.ChildAlignment;
const Color = layout.Color;
const CornerRadius = layout.CornerRadius;

// Initialize once. Every capacity comes from the app's budget.
const limits = gooey.ResourceLimits.small;
var engine = try LayoutEngine.init(&layout.LayoutCapacity.fromLimits(&limits));
defer engine.deinit();

// Each frame:
engine.beginFrame(window_width, window_height);

try engine.openElement(.{
    .layout = .{
        .sizing = Sizing.fill(),
        .child_alignment = ChildAlignment.center(),
    },
});
{
    try engine.openElement(.{
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

try engine.endFrame();
// Read each element's bounds from `engine.elements` to paint.
```

## Core Concepts

### Elements

The engine appends elements in the order `openElement` and `text` create
them; `engine.elements` holds them in that order, and each element's
`computed.bounding_box` holds its bounds after `endFrame`. The core keys its
own nodes by `ElementId` and opens one element per node, so node `n` is
element `n`.

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

// Weighted grow: siblings share free main-axis space by weight
SizingAxis.growWeighted(2, 0, std.math.floatMax(f32))  // twice a grow() sibling's share
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

### Main Axis Distribution

When children don't fill the container, `main_axis_distribution` controls how the
extra space along the layout direction is distributed:

| Value           | Description                                           |
| --------------- | ----------------------------------------------------- |
| `start`         | Children packed at the start (default)                |
| `center`        | Children packed in the center                         |
| `end`           | Children packed at the end                            |
| `space_between` | Equal space between children, no space at the edges   |
| `space_around`  | Equal space around children (half space at the edges) |
| `space_evenly`  | Equal space between and around children               |

```zig
.main_axis_distribution = .space_between
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
                .layout = .{ .sizing = Sizing.fitContent() },
            });
            try engine.text("Login", .{
                .color = Color.rgb(0.1, 0.1, 0.1),
                .font_size = 20,
            });
            engine.closeElement();

            // Username field placeholder
            try engine.openElement(.{
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

    try engine.endFrame();
}
```

## API Reference

### LayoutEngine

| Method                             | Description                                       |
| ---------------------------------- | ------------------------------------------------- |
| `init(&capacity)`                  | Reserve every table from a `LayoutCapacity`       |
| `deinit()`                         | Free resources                                    |
| `setMeasureTextFn(fn, user_data)`  | Set text measurement callback                     |
| `beginFrame(width, height)`        | Start a new frame                                 |
| `openElement(decl)`                | Open a container element                          |
| `closeElement()`                   | Close the current element                         |
| `text(content, config)`            | Add a text leaf element                           |
| `endFrame()`                       | Compute every element's bounds                    |

### ElementDeclaration

| Field              | Type              | Default | Description                                  |
| ------------------ | ----------------- | ------- | -------------------------------------------- |
| `layout`           | `LayoutConfig`    | `{}`    | Sizing and positioning                       |
| `background_color` | `?Color`          | `null`  | Fill color                                   |
| `corner_radius`    | `CornerRadius`    | `{}`    | Rounded corners                              |
| `border`           | `?BorderConfig`   | `null`  | Border styling                               |
| `shadow`           | `?ShadowConfig`   | `null`  | Box shadow                                   |
| `scroll`           | `?ScrollConfig`   | `null`  | Scrollable container                         |
| `floating`         | `?FloatingConfig` | `null`  | Floating positioning (see FloatingConfig)    |
| `user_data`        | `?*anyopaque`     | `null`  | Custom data pointer                          |
| `opacity`          | `f32`             | `1.0`   | Subtree opacity (0.0 transparent–1.0 opaque) |
| `is_canvas`        | `bool`            | `false` | Whether this is a canvas element             |

The layout passes read only `layout`, `scroll`, and `floating`. The paint fields
(`background_color`, `corner_radius`, `border`, `shadow`, `opacity`, `is_canvas`,
`user_data`) are stored on the element and read by nothing: the core paints from its own
nodes and applies `ui.Style.opacity` itself, so it leaves them at their defaults.

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
    .attach_to_parent = true,             // Direct parent; false = viewport
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

All fields use integer types for deterministic layout. `line_height` is a percentage
of `font_size` (e.g., 120 = 1.2×), not a float multiplier.

```zig
try engine.text("Hello, World!", .{
    .color = Color.black,
    .font_id = 0,              // u16, default 0
    .font_size = 16,           // u16 in pixels, default 16
    .line_height = 120,        // u16 percentage of font_size (120 = 1.2×), default 120
    .letter_spacing = 0,       // i16, default 0
    .wrap_mode = .words,       // .none (default), .words, .newlines
    .alignment = .left,        // .left (default), .center, .right
    .decoration = .{ .underline = false, .strikethrough = false },
});
```

### Offset2D

Shared type for 2D offsets (used in FloatingConfig and ScrollConfig), exported as
`layout.types.Offset2D`:

```zig
const offset = Offset2D.init(10, 20);
const zero = Offset2D.zero();
```

## Capacities

The layout engine reserves fixed-capacity tables at `init` and never allocates during a
frame. `LayoutCapacity.fromLimits(&limits)` derives every capacity from the app's
`ResourceLimits`:

| Field                          | From                                | Holds                     |
| ------------------------------ | ----------------------------------- | ------------------------- |
| `element_count_max`            | `build.element_count_frame_max` + 1 | Elements, with the root   |
| `box_depth_max`                | `build.box_depth_max` (64)          | Nesting depth             |
| `floating_count_max`           | `build.layer_count_frame_max`       | Floating elements         |
| `word_count_text_max`          | `run_codepoint_count_max`           | Words in one wrapped text |
| `wrapped_line_count_frame_max` | `paint.glyph_count_frame_max`       | Wrapped lines per frame   |
| `arena_bytes`                  | text and line budgets               | The per-frame arena       |

One text wraps into at most `word_count_text_max + 1` lines.

## Notes

- **Text strings** are copied into the per-frame arena, so they're safe to use with temporary buffers.
- **Text elements** must be inside a container (enforced by debug assertion).
- **Zero allocation during frame** - all collections use fixed capacity, panic on overflow.
- The layout algorithm runs in these phases:
  1. **Min sizes** (bottom-up) - compute minimum content sizes
  2. **Final sizes** (top-down) - distribute available space
     - **2b. Text wrapping** - wrap text now that container widths are known; propagate height changes back up to fit-content parents
  3. **Positions** (top-down) - compute final bounding boxes
     - **3b. Floating elements** - position floating elements relative to parents (includes text wrapping for floats)
- No phase recurses. Min sizes, final sizes and positions keep an explicit stack
  of open parents, one frame per level, bounded by `box_depth_max`; text
  wrapping and the floating passes walk a subtree's pre-order index range.
  Every depth the open stack admits lays out.
