# Gooey

A GPU-accelerated UI framework for Zig, targeting macOS with Metal rendering and Browser via WASM.

> ⚠️ **Early Development**: macOS-only (wasm half-baked). API is evolving.

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

WASM support imminent

<img src="https://github.com/duanebester/gooey/blob/main/assets/screenshots/gooey-wasm.png" height="300px" />

## Features

- **Metal Rendering** - Hardware-accelerated with MSAA anti-aliasing
- **Declarative UI** - Component-based layout with flexbox-style system
- **Unified Context** - Single `Cx` type for state, layout, handlers, and focus
- **Pure State Pattern** - Testable state methods with automatic re-rendering
- **Retained Widgets** - TextInput, TextArea, Checkbox, Scroll containers
- **Text Rendering** - CoreText shaping with subpixel positioning
- **Custom Shaders** - Drop in your own Metal shaders
- **Theming** - Built-in light/dark mode support

## Quick Start

**Requirements:** Zig 0.15.2+, macOS 12.0+

```bash
zig build run              # Showcase demo
zig build run-counter      # Counter example
zig build run-pomodoro     # Pomodoro timer
zig build run-shader       # Custom shaders
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

pub fn main() !void {
    var state = AppState{};
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

- **Button** - Primary, secondary, danger variants with sizes
- **Checkbox** - Toggle with customizable colors
- **TextInput** - Single-line text entry with placeholder
- **TextArea** - Multi-line text with scrolling

## More Examples

| Example   | Command                   | Description                        |
| --------- | ------------------------- | ---------------------------------- |
| Showcase  | `zig build run`           | Full feature demo with navigation  |
| Counter   | `zig build run-counter`   | Simple state management            |
| Pomodoro  | `zig build run-pomodoro`  | Timer with tasks and custom shader |
| Dynamic   | `zig build run-dynamic`   | Entity creation and deletion       |
| Layout    | `zig build run-layout`    | Flexbox, shrink, text wrapping     |
| Shader    | `zig build run-shader`    | Custom Metal shaders               |
| Spaceship | `zig build run-spaceship` | Space dashboard                    |

## WASM

:warning: Currently supports subset of the API. :warning:

To build the browser version of the counter/dynamic counters examples:

```bash
zig build wasm # showcase
zig build wasm-counter
zig build wasm-dynamic-counters
zig build wasm-pomodoro
```

To then run the example(s):

```bash
python3 -m http.server 8080 -d zig-out/web # showcase
python3 -m http.server 8080 -d zig-out/web/counter
python3 -m http.server 8080 -d zig-out/web/dynamic
python3 -m http.server 8080 -d zig-out/web/pomodoro
```

## Hot reloading - macOS

It's a simple, brute-force hot reload, but works well enough for now.

### Run showcase (default) with hot reload

zig build hot

### Run a specific example with hot reload

zig build hot -- run-counter
zig build hot -- run-pomodoro
zig build hot -- run-glass

## Inspiration

- [GPUI](https://github.com/zed-industries/zed/tree/main/crates/gpui) - Zed's GPU UI framework
- [Clay](https://github.com/nicbarker/clay) - Immediate mode layout
- [Ghostty](https://github.com/ghostty-org/ghostty) - Zig + Metal terminal
