# Gooey

A GPU-accelerated UI framework for Zig, targeting macOS with Metal rendering and Browser via WASM.

Join the [Gooey discord](https://discord.gg/bmzAZnZJyw)

<img src="https://github.com/duanebester/gooey/blob/main/assets/gooey.png" height="200px" />

> ⚠️ **Early Development**: API is evolving.

<table>
  <tr>
    <td><img src="https://github.com/duanebester/gooey/blob/main/assets/screenshots/gooey-light.png" height="300px" /></td>
    <td><img src="https://github.com/duanebester/gooey/blob/main/assets/screenshots/gooey-dark.png" height="300px" /></td>
  </tr>
  <tr>
    <td><img src="https://github.com/duanebester/gooey/blob/main/assets/screenshots/gooey-shader.png" height="300px" /></td>
    <td><img src="https://github.com/duanebester/gooey/blob/main/assets/screenshots/gooey-shader2.png" height="300px" /></td>
  </tr>
</table>

WASM support!

<img src="https://github.com/duanebester/gooey/blob/main/assets/screenshots/gooey-wasm.png" height="300px" />

## Features

- **Metal Rendering** - Hardware-accelerated with MSAA anti-aliasing
- **Declarative UI** - Component-based layout with flexbox-style system
- **Unified Cx Context** - Single `Cx` type for state, layout, handlers, and focus
- **Pure State Pattern** - Testable state methods with automatic re-rendering
- **Animation System** - Built-in animations with easing, `animateOn` triggers
- **Entity System** - Dynamic entity creation/deletion with auto-cleanup
- **Retained Widgets** - TextInput, TextArea, Checkbox, Scroll containers
- **Text Rendering** - CoreText shaping with subpixel positioning
- **Custom Shaders** - Drop in your own Metal shaders
- **Liquid Glass** - macOS 26.0+ Tahoe transparent window effects
- **Actions & Keybindings** - Contextual action system with keymap
- **Theming** - Built-in light/dark mode support
- **Images & SVG** - Load images and render SVG icons with styling
- **File Dialogs** - Native file open/save dialogs (macOS & WASM)

## Quick Start

**Requirements:** Zig 0.15.2+, macOS 12.0+

```bash
zig build run              # Showcase demo
zig build run-counter      # Counter example
zig build run-animation    # Animation demo
zig build run-pomodoro     # Pomodoro timer
zig build run-glass        # Liquid glass effect
zig build run-spaceship    # Space dashboard with shader
zig build run-dynamic-counters  # Entity system demo
zig build run-layout       # Flexbox, shrink, text wrapping
zig build run-actions      # Keybindings demo
zig build run-select       # Dropdown select component
zig build run-tooltip      # Tooltip component
zig build run-modal        # Modal dialogs
zig build run-images       # Image loading and styling
zig build run-file-dialog  # Native file dialogs
zig build test             # Run tests
```

## Example

```zig
const std = @import("std");
const gooey = @import("gooey");
const ui = gooey.ui;
const Cx = gooey.Cx;
const Button = gooey.Button;

// State is pure - no UI knowledge, fully testable!
const AppState = struct {
    count: i32 = 0,

    pub fn increment(self: *AppState) void {
        self.count += 1;
    }

    pub fn decrement(self: *AppState) void {
        self.count -= 1;
    }

    pub fn reset(self: *AppState) void {
        self.count = 0;
    }
};

var state = AppState{};

pub fn main() !void {
    try gooey.runCx(AppState, &state, render, .{
        .title = "Counter",
        .width = 400,
        .height = 300,
    });
}

fn render(cx: *Cx) void {
    const s = cx.state(AppState);
    const size = cx.windowSize();

    cx.box(.{
        .width = size.width,
        .height = size.height,
        .alignment = .{ .main = .center, .cross = .center },
        .gap = 16,
        .direction = .column,
    }, .{
        ui.textFmt("{d}", .{s.count}, .{ .size = 48 }),
        cx.hstack(.{ .gap = 12 }, .{
            // Pure handlers - framework auto-renders after mutation!
            Button{ .label = "-", .on_click_handler = cx.update(AppState, AppState.decrement) },
            Button{ .label = "+", .on_click_handler = cx.update(AppState, AppState.increment) },
        }),
        Button{ .label = "Reset", .variant = .secondary, .on_click_handler = cx.update(AppState, AppState.reset) },
    });
}

// State is testable without UI!
test "counter logic" {
    var s = AppState{};
    s.increment();
    s.increment();
    try std.testing.expectEqual(2, s.count);
    s.reset();
    try std.testing.expectEqual(0, s.count);
}
```

## Handler Types

| Method             | Signature                      | Use Case                           |
| ------------------ | ------------------------------ | ---------------------------------- |
| `cx.update()`      | `fn(*State) void`              | Pure state mutations               |
| `cx.updateWith()`  | `fn(*State, Arg) void`         | Mutations with arguments           |
| `cx.command()`     | `fn(*State, *Gooey) void`      | Framework access (focus, entities) |
| `cx.commandWith()` | `fn(*State, *Gooey, Arg) void` | Framework access with arguments    |

> **Note:** The state type is passed explicitly: `cx.update(AppState, AppState.increment)`

## Components

Gooey includes ready-to-use components:

### Button

```zig
// Button variants
Button{ .label = "Save", .variant = .primary, .on_click_handler = cx.update(State, State.save) }
Button{ .label = "Cancel", .variant = .secondary, .size = .small, .on_click_handler = ... }
Button{ .label = "Delete", .variant = .danger, .on_click_handler = ... }
```

### TextInput & TextArea

```zig
// Single-line text input with binding
TextInput{
    .id = "email",
    .placeholder = "Enter email...",
    .bind = &s.email,
    .width = 250,
}

// Multi-line text area
TextArea{
    .id = "notes",
    .placeholder = "Enter notes...",
    .bind = &s.notes,
    .width = 400,
    .height = 200,
}
```

### Checkbox

```zig
Checkbox{
    .id = "terms",
    .checked = s.agreed_to_terms,
    .on_click_handler = cx.update(State, State.toggleTerms),
}
```

### RadioButton & RadioGroup

```zig
// RadioButton - individual buttons for custom layouts
RadioButton{
    .label = "Email",
    .is_selected = s.contact_method == 0,
    .on_click_handler = cx.updateWith(State, @as(u8, 0), State.setContactMethod),
}

// RadioGroup - grouped buttons with handlers array
RadioGroup{
    .id = "priority",
    .options = &.{ "Low", "Medium", "High" },
    .selected = s.priority,
    .handlers = &.{
        cx.updateWith(State, @as(u8, 0), State.setPriority),
        cx.updateWith(State, @as(u8, 1), State.setPriority),
        cx.updateWith(State, @as(u8, 2), State.setPriority),
    },
    .direction = .row,  // or .column
    .gap = 16,
}
```

### Select (Dropdown)

```zig
const State = struct {
    selected_option: ?usize = null,
    select_open: bool = false,

    pub fn toggleSelect(self: *State) void {
        self.select_open = !self.select_open;
    }

    pub fn closeSelect(self: *State) void {
        self.select_open = false;
    }

    pub fn selectOption(self: *State, index: usize) void {
        self.selected_option = index;
        self.select_open = false;
    }
};

// In render:
Select{
    .id = "fruit-select",
    .options = &.{ "Apple", "Banana", "Cherry", "Date" },
    .selected = s.selected_option,
    .is_open = s.select_open,
    .placeholder = "Choose a fruit...",
    .on_toggle_handler = cx.update(State, State.toggleSelect),
    .on_close_handler = cx.update(State, State.closeSelect),
    .handlers = &.{
        cx.updateWith(State, @as(usize, 0), State.selectOption),
        cx.updateWith(State, @as(usize, 1), State.selectOption),
        cx.updateWith(State, @as(usize, 2), State.selectOption),
        cx.updateWith(State, @as(usize, 3), State.selectOption),
    },
    .width = 200,
}
```

### Modal

```zig
const State = struct {
    show_confirm: bool = false,

    pub fn openConfirm(self: *State) void {
        self.show_confirm = true;
    }

    pub fn closeConfirm(self: *State) void {
        self.show_confirm = false;
    }
};

// Trigger button
Button{ .label = "Delete Item", .variant = .danger, .on_click_handler = cx.update(State, State.openConfirm) }

// Modal with custom content
Modal(ConfirmContent){
    .id = "confirm-dialog",
    .is_open = s.show_confirm,
    .on_close = cx.update(State, State.closeConfirm),
    .child = ConfirmContent{
        .message = "Are you sure you want to delete?",
        .on_confirm = cx.update(State, State.doDelete),
        .on_cancel = cx.update(State, State.closeConfirm),
    },
    .animate = true,
    .close_on_backdrop = true,
}
```

### Tooltip

```zig
// Wrap any component with a tooltip
Tooltip(Button){
    .text = "Click to save your changes",
    .child = Button{ .label = "Save", .on_click_handler = ... },
    .position = .top,  // .top, .bottom, .left, .right
}

// With custom styling
Tooltip(IconButton){
    .text = "This field is required",
    .child = HelpIcon{},
    .position = .right,
    .max_width = 200,
    .background = Color.rgb(0.2, 0.2, 0.25),
}
```

### Image

```zig
// Simple image from path
gooey.Image{ .src = "assets/logo.png" }

// With explicit sizing
gooey.Image{ .src = "photo.jpg", .width = 200, .height = 150 }

// Rounded avatar
gooey.Image{ .src = "avatar.png", .size = 48, .rounded = true }

// Cover image (fills container, may crop)
gooey.Image{ .src = "banner.jpg", .width = 800, .height = 200, .fit = .cover }

// With effects
gooey.Image{
    .src = "icon.png",
    .size = 64,
    .grayscale = 1.0,           // 0.0 = color, 1.0 = grayscale
    .tint = gooey.Color.blue,   // Color overlay
    .opacity = 0.8,
    .corner_radius = 8,
}
```

### SVG Icons

```zig
const gooey = @import("gooey");
const Svg = gooey.Svg;
const Icons = gooey.Icons;

// Using built-in icon paths
Svg{ .path = Icons.star, .size = 24, .color = Color.gold }
Svg{ .path = Icons.check, .size = 20, .color = Color.green }
Svg{ .path = Icons.close, .size = 16, .color = Color.red }

// Stroked icon (outline only)
Svg{ .path = Icons.star_outline, .size = 24, .stroke_color = Color.white, .stroke_width = 2 }

// Both fill and stroke
Svg{ .path = Icons.favorite, .size = 24, .color = Color.red, .stroke_color = Color.black, .stroke_width = 1 }

// Available icons: arrow_back, arrow_forward, menu, close, more_vert,
// check, add, remove, edit, delete, search, star, star_outline, favorite,
// info, warning, error_icon, play, pause, skip_next, skip_prev, volume_up,
// visibility, visibility_off, folder, file, download, upload
```

### ProgressBar

```zig
ProgressBar{
    .progress = s.completion,  // 0.0 to 1.0
    .width = 200,
    .height = 8,
    .corner_radius = 4,
}
```

### Tabs

```zig
// Individual tabs for custom navigation
cx.hstack(.{ .gap = 4 }, .{
    Tab{
        .label = "Home",
        .is_active = s.tab == 0,
        .on_click_handler = cx.updateWith(State, @as(u8, 0), State.setTab),
    },
    Tab{
        .label = "Settings",
        .is_active = s.tab == 1,
        .on_click_handler = cx.updateWith(State, @as(u8, 1), State.setTab),
        .style = .underline,  // .pills (default), .underline, .segmented
    },
})
```

## Animation System

Built-in animation support with easing functions:

```zig
// Simple animation (runs once on mount)
const fade = cx.animate("fade-in", .{ .duration_ms = 500 });
// fade.progress goes 0.0 -> 1.0

// Animation that restarts when a value changes
const pulse = cx.animateOn("counter-pulse", s.count, .{
    .duration_ms = 200,
    .easing = Easing.easeOutBack,
});

// Continuous animation
const spin = cx.animate("spinner", .{
    .duration_ms = 1000,
    .mode = .ping_pong,  // or .loop
});

// Use animation values
cx.box(.{
    .background = Color.white.withAlpha(fade.progress),
    .width = gooey.lerp(100.0, 150.0, pulse.progress),
}, .{...});
```

**Available Easings:** `linear`, `easeIn`, `easeOut`, `easeInOut`, `easeOutBack`, `easeOutCubic`, `easeInOutCubic`

## Entity System

Dynamic creation and deletion with automatic cleanup:

```zig
const Counter = struct {
    count: i32 = 0,
    pub fn increment(self: *Counter) void { self.count += 1; }
};

const AppState = struct {
    counters: [10]gooey.Entity(Counter) = ...,

    // Command method - needs Gooey access for entity operations
    pub fn addCounter(self: *AppState, g: *gooey.Gooey) void {
        const entity = g.createEntity(Counter, .{ .count = 0 }) catch return;
        self.counters[self.counter_count] = entity;
        self.counter_count += 1;
    }
};

// In render - use entityCx for entity-scoped handlers
var entity_cx = cx.entityCx(Counter, counter_entity) orelse return;
Button{ .label = "+", .on_click_handler = entity_cx.update(Counter.increment) }

// Read entity data
if (cx.gooey().readEntity(Counter, entity)) |data| {
    ui.textFmt("{d}", .{data.count}, .{});
}
```

## Layout System

Flexbox-inspired layout with shrink behavior and text wrapping:

```zig
cx.box(.{
    .direction = .row,           // or .column
    .gap = 16,
    .padding = .{ .all = 24 },   // or .symmetric, .each
    .alignment = .{ .main = .space_between, .cross = .center },
    .fill_width = true,
    .grow = true,
}, .{...});

// Shrink behavior - elements shrink when container is too small
cx.box(.{ .width = 150, .min_width = 60 }, .{...});

// Text wrapping
ui.text("Long text...", .{ .wrap = .words });  // .none, .words, .newlines
```

## Custom Shaders

Add custom post-processing shaders for visual effects. Shaders are cross-platform with MSL for macOS and WGSL for web:

```zig
// MSL shader (macOS)
pub const plasma_msl =
    \\void mainImage(thread float4& fragColor, float2 fragCoord,
    \\               constant ShaderUniforms& uniforms,
    \\               texture2d<float> iChannel0,
    \\               sampler iChannel0Sampler) {
    \\    float2 uv = fragCoord / uniforms.iResolution.xy;
    \\    float time = uniforms.iTime;
    \\    // ... shader code
    \\    fragColor = float4(color, 1.0);
    \\}
;

// WGSL shader (Web)
pub const plasma_wgsl =
    \\fn mainImage(
    \\    fragCoord: vec2<f32>,
    \\    u: ShaderUniforms,
    \\    tex: texture_2d<f32>,
    \\    samp: sampler
    \\) -> vec4<f32> {
    \\    let uv = fragCoord / u.iResolution.xy;
    \\    let time = u.iTime;
    \\    // ... shader code
    \\    return vec4<f32>(color, 1.0);
    \\}
;

try gooey.runCx(AppState, &state, render, .{
    .custom_shaders = &.{.{ .msl = plasma_msl, .wgsl = plasma_wgsl }},
});
```

You can also provide only one platform's shader:

```zig
// macOS only
.custom_shaders = &.{.{ .msl = plasma_msl }},

// Web only
.custom_shaders = &.{.{ .wgsl = plasma_wgsl }},
```

## Glass Effect (macOS 26.0+)

Transparent window with liquid glass effect:

```zig
try gooey.runCx(AppState, &state, render, .{
    .title = "Glass Demo",
    .background_color = gooey.Color.init(0.1, 0.1, 0.15, 1.0),
    .background_opacity = 0.2,
    .glass_style = .glass_regular,  // .glass_clear, .blur, .none
    .glass_corner_radius = 10.0,
    .titlebar_transparent = true,
});

// Change glass style at runtime
pub fn cycleStyle(self: *AppState, g: *gooey.Gooey) void {
    g.window.setGlassStyle(.glass_clear, 0.7, 10.0);
}
```

## Actions & Keybindings

Contextual action system with keyboard shortcuts:

```zig
const Undo = struct {};
const Save = struct {};

fn setupKeymap(cx: *Cx) void {
    const g = cx.gooey();
    g.keymap.bind(Undo, "cmd-z", null);        // Global
    g.keymap.bind(Save, "cmd-s", "Editor");    // Context-specific
}

fn render(cx: *Cx) void {
    cx.box(.{}, .{
        ui.onAction(Undo, doUndo),  // Handle action

        // Scoped context
        ui.keyContext("Editor"),
        ui.onAction(Save, doSave),
    });
}
```

## More Examples

| Example          | Command                          | Description                           |
| ---------------- | -------------------------------- | ------------------------------------- |
| Showcase         | `zig build run`                  | Full feature demo with navigation     |
| Counter          | `zig build run-counter`          | Simple state management               |
| Animation        | `zig build run-animation`        | Animation system with animateOn       |
| Pomodoro         | `zig build run-pomodoro`         | Timer with tasks and custom shader    |
| Dynamic Counters | `zig build run-dynamic-counters` | Entity creation and deletion          |
| Layout           | `zig build run-layout`           | Flexbox, shrink, text wrapping        |
| Glass            | `zig build run-glass`            | Liquid glass transparency effect      |
| Spaceship        | `zig build run-spaceship`        | Sci-fi dashboard with hologram shader |
| Actions          | `zig build run-actions`          | Keybindings and action system         |
| Select           | `zig build run-select`           | Dropdown select component             |
| Tooltip          | `zig build run-tooltip`          | Tooltip positioning and styling       |
| Modal            | `zig build run-modal`            | Modal dialogs with animation          |
| Images           | `zig build run-images`           | Image loading and effects             |
| File Dialog      | `zig build run-file-dialog`      | Native file open/save dialogs         |

## WASM

```bash
# Build WASM examples
zig build wasm                 # showcase
zig build wasm-counter
zig build wasm-dynamic-counters
zig build wasm-pomodoro
zig build wasm-spaceship
zig build wasm-layout
zig build wasm-select
zig build wasm-tooltip
zig build wasm-modal
zig build wasm-images
zig build wasm-file-dialog

# Run with a local server
python3 -m http.server 8080 -d zig-out/web            # showcase
python3 -m http.server 8080 -d zig-out/web/counter
python3 -m http.server 8080 -d zig-out/web/dynamic
python3 -m http.server 8080 -d zig-out/web/pomodoro
python3 -m http.server 8080 -d zig-out/web/select
python3 -m http.server 8080 -d zig-out/web/tooltip
python3 -m http.server 8080 -d zig-out/web/modal
```

## Hot Reloading (macOS)

Simple brute-force hot reload for development:

```bash
zig build hot                    # Showcase (default)
zig build hot -- run-counter     # Specific example
zig build hot -- run-pomodoro
zig build hot -- run-glass
```

## Architecture

```
src/
├── app.zig          # App entry points (runCx, App, WebApp)
├── cx.zig           # Unified context (Cx)
├── root.zig         # Public API exports
├── core/            # Geometry, input, scene, entities, animations
├── layout/          # Flexbox-style layout engine
├── text/            # CoreText text rendering
├── ui/              # Declarative builder (box, vstack, hstack, etc.)
├── components/      # Button, Checkbox, TextInput, TextArea, Modal, Tooltip, Select, Image, Svg
├── widgets/         # Lower-level retained widgets
├── platform/        # macOS/Metal, WASM/WebGPU
└── examples/        # Demo applications
```

## Inspiration

- [GPUI](https://github.com/zed-industries/zed/tree/main/crates/gpui) - Zed's GPU UI framework
- [Clay](https://github.com/nicbarker/clay) - Immediate mode layout
- [Ghostty](https://github.com/ghostty-org/ghostty) - Zig + Metal terminal
