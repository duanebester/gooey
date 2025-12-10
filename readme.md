# Gooey

A minimal GPU-accelerated UI framework for Zig, targeting macOS with Metal rendering.

> ⚠️ **Early Development**: macOS-only. API is evolving.

<img src="https://github.com/duanebester/gooey/blob/main/assets/screenshots/gooey.png" height="400px" />

## Features

- **Metal Rendering** - Hardware-accelerated with MSAA anti-aliasing
- **CVDisplayLink VSync** - Smooth 60Hz - 240Hz frame-paced rendering
- **Declarative UI** - Component-based with simple `render()` methods
- **Retained Widgets** - TextInput with full IME/composition support
- **Text Rendering** - CoreText font loading and shaping, glyph atlas caching
- **Simple API** - Plain structs, simple callbacks, no complex reactive system (yet?).

## Quick Start

### Prerequisites

- Zig 0.15.2+
- macOS 12.0+ (Metal required)
- Xcode Command Line Tools

### Build & Run

`bash
zig build run          # Run the showcase demo
zig build run-simple   # Run the simple counter example
zig build run-login    # Run the login form example
zig build test         # Run tests
`

## Examples

### Simple Counter

The simplest way to get started - just a render function and plain struct state:

```zig
const std = @import("std");
const gooey = @import("gooey");
const ui = gooey.ui;

// Plain struct state - no wrappers needed!
var state = struct {
count: i32 = 0,
}{};

pub fn main() !void {
try gooey.run(.{
.title = "Simple Counter",
.width = 400,
.height = 300,
.render = render,
});
}

fn render(g: \*gooey.UI) void {
const size = g.windowSize();

    g.box(.{
        .width = size.width,
        .height = size.height,
        .alignment = .{ .main = .center, .cross = .center },
    }, .{
        Card{},
    });

}

// Components are just structs with render()
const Card = struct {
pub fn render(\_: @This(), b: \*ui.Builder) void {
b.box(.{
.padding = .{ .all = 32 },
.gap = 20,
.background = ui.Color.white,
.corner_radius = 12,
.direction = .column,
}, .{
Counter{},
ui.button("+ Increment", increment),
});
}
};

const Counter = struct {
var buf: [32]u8 = undefined;

    pub fn render(_: @This(), b: *ui.Builder) void {
        const text = std.fmt.bufPrint(&buf, "{d}", .{state.count}) catch "?";
        b.vstack(.{ .gap = 8, .alignment = .center }, .{
            ui.text("Count:", .{ .size = 16 }),
            ui.text(text, .{ .size = 48 }),
        });
    }

};

fn increment() void {
state.count += 1;
}
```

### Login Form with Input Binding

Text inputs with two-way data binding:

```zig
const gooey = @import("gooey");
const ui = gooey.ui;

var state = struct {
username: []const u8 = "",
password: []const u8 = "",
}{};

pub fn main() !void {
try gooey.run(.{
.title = "Login",
.render = render,
});
}

fn render(g: \*gooey.UI) void {
g.center(.{}, .{
LoginCard{},
});
}

const LoginCard = struct {
pub fn render(\_: @This(), b: \*ui.Builder) void {
b.box(.{
.padding = .{ .all = 32 },
.gap = 16,
.background = ui.Color.white,
.corner_radius = 12,
.direction = .column,
}, .{
ui.text("Login", .{ .size = 24 }),

            ui.input("username", .{
                .placeholder = "Username",
                .width = 250,
                .bind = &state.username,
            }),
            ui.input("password", .{
                .placeholder = "Password",
                .secure = true,
                .width = 250,
                .bind = &state.password,
            }),

            ui.button("Sign In", submit),
        });
    }

};
```

## API Reference

### `gooey.run()` - Entry Point

`zig
try gooey.run(.{
    .title = "My App",
    .width = 800,
    .height = 600,
    .render = myRenderFn,        // fn(*gooey.UI) void
    .on_event = myEventFn,       // Optional: fn(*gooey.UI, InputEvent) bool
});
`

### Layout Containers

`zig
fn render(g: *gooey.UI) void {
    g.box(style, children);      // Flexible container
    g.vstack(style, children);   // Vertical stack
    g.hstack(style, children);   // Horizontal stack
    g.center(style, children);   // Centered container
}
`

### Primitives

`zig
ui.text("Hello", .{ .size = 16, .color = ui.Color.black })
ui.textFmt("Count: {d}", .{42}, .{})
ui.button("Click", onClick)
ui.input("id", .{ .placeholder = "...", .bind = &state.field })
ui.spacer()
`

### Styles

```zig
// BoxStyle
.{
.width = 200, .height = 100,
.padding = .{ .all = 16 },
.gap = 8,
.background = ui.Color.white,
.corner_radius = 8,
.shadow = ui.ShadowConfig.drop(6),
.direction = .column,
.alignment = .{ .main = .center, .cross = .center },
}

// Colors
ui.Color.white
ui.Color.rgb(0.2, 0.5, 1.0)
ui.Color.rgba(0.2, 0.5, 1.0, 0.8)
```

## Project Structure

```
src/
├── app.zig              # gooey.run() API
├── root.zig             # Public exports
├── core/                # Core types
├── ui/                  # Builder & components
├── elements/            # Widgets (TextInput)
├── font/                # Text system
├── layout/              # Layout engine
├── platform/mac/        # macOS/Metal
└── examples/
    ├── simple.zig
    ├── login.zig
    └── showcase.zig
```

## Inspiration

- [GPUI](https://github.com/zed-industries/zed/tree/main/crates/gpui) - Zed's GPU UI framework
- [Clay](https://github.com/nicbarker/clay) - Immediate mode layout library
- [Ghostty](https://github.com/ghostty-org/ghostty) - Zig + Metal terminal
