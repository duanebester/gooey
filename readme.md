# Gooey

A GPU-accelerated UI framework for Zig, targeting macOS (Metal), Linux (Vulkan/Wayland), and Browser (WASM/WebGPU).

Join the [Gooey discord](https://discord.gg/bmzAZnZJyw)

<img src="https://github.com/duanebester/gooey/blob/main/assets/gooey-logo-final.png" height="100px" />

> **Early Development**: API is evolving.

[![CI](https://github.com/duanebester/gooey/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/duanebester/gooey/actions/workflows/ci.yml)

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

- **GPU Rendering** - Metal (macOS), Vulkan (Linux), WebGPU (WASM) with MSAA anti-aliasing
- **Declarative UI** - Component-based layout with `ui.*` primitives and flexbox-style system
- **Cx/UI Separation** - `Cx` for state, handlers, and focus; `ui.*` for layout primitives
- **Pure State Pattern** - Testable state methods with automatic re-rendering
- **Animation System** - Built-in animations with easing, `animateOn` triggers
- **Entity System** - Dynamic entity creation/deletion with auto-cleanup
- **Retained Widgets** - TextInput, TextArea, Checkbox, Scroll containers
- **Text Rendering** - CoreText (macOS), FreeType/HarfBuzz (Linux), Canvas (WASM)
- **Custom Shaders** - Drop in your own Metal/GLSL shaders
- **Drag & Drop** - Type-safe drag sources and drop targets with `pointer_events` control
- **Liquid Glass** - macOS 26.0+ Tahoe transparent window effects
- **Actions & Keybindings** - Contextual action system with keymap
- **Theming** - Built-in light/dark mode support
- **Images & SVG** - Load images and render SVG icons with styling
- **File Dialogs** - Native file open/save dialogs (macOS, Linux, WASM)
- **Clipboard** - Native clipboard support on all platforms
- **IME Support** - Input method editor for international text input
- **Accessibility** - Built-in screen reader support (VoiceOver, Orca, ARIA) with semantic roles and live regions

## Quick Start

**Requirements:** Zig 0.15.2+

**macOS:** macOS 12.0+

**Linux:** Wayland compositor, Vulkan drivers, FreeType, HarfBuzz, Fontconfig, libpng, D-Bus

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
zig build run-uniform-list # Virtualized list (10k items)
zig build run-virtual-list # Variable-height list
zig build run-data-table   # Virtualized table (10k rows)
zig build run-code-editor  # Code editor with syntax highlighting
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

    cx.render(ui.box(.{
        .width = size.width,
        .height = size.height,
        .alignment = .{ .main = .center, .cross = .center },
        .gap = 16,
        .direction = .column,
    }, .{
        ui.textFmt("{d}", .{s.count}, .{ .size = 48 }),
        ui.hstack(.{ .gap = 12 }, .{
            // Pure handlers - framework auto-renders after mutation!
            Button{ .label = "-", .on_click_handler = cx.update(AppState, AppState.decrement) },
            Button{ .label = "+", .on_click_handler = cx.update(AppState, AppState.increment) },
        }),
        Button{ .label = "Reset", .variant = .secondary, .on_click_handler = cx.update(AppState, AppState.reset) },
    }));
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

## API Pattern

Gooey separates concerns between `Cx` (context) and `ui` (layout primitives):

| Module | Purpose                            | Examples                                                           |
| ------ | ---------------------------------- | ------------------------------------------------------------------ |
| `cx.*` | State, handlers, animations, focus | `cx.state()`, `cx.update()`, `cx.animate()`, `cx.render()`         |
| `ui.*` | Layout containers and primitives   | `ui.box()`, `ui.hstack()`, `ui.vstack()`, `ui.text()`, `ui.when()` |

```/dev/null/example.zig#L1-19
fn render(cx: *Cx) void {
    const s = cx.state(AppState);

    cx.render(ui.box(.{ .width = 100 }, .{
        ui.text("Hello", .{}),

        // Conditional rendering
        ui.when(s.show_extra, .{
            ui.text("Extra content", .{}),
        }),

        // Iterate over items
        ui.each(&s.items, struct {
            fn render(item: Item, _: usize) @TypeOf(ui.text("", .{})) {
                return ui.text(item.name, .{});
            }
        }.render),
    }));
}
```

**Key primitives:**

- `ui.box()` - Container with flexbox layout
- `ui.hstack()` / `ui.vstack()` - Horizontal/vertical stacks
- `ui.text()` / `ui.textFmt()` - Text rendering
- `ui.when(cond, children)` - Conditional rendering
- `ui.maybe(optional, fn)` - Render if optional has value
- `ui.each(items, fn)` - Render for each item
- `ui.scroll(id, style, children)` - Scrollable container
- `ui.spacer()` - Flexible space

## Handler Types

| Method             | Signature                      | Use Case                           |
| ------------------ | ------------------------------ | ---------------------------------- |
| `cx.update()`      | `fn(*State) void`              | Pure state mutations               |
| `cx.updateWith()`  | `fn(*State, Arg) void`         | Mutations with argument            |
| `cx.command()`     | `fn(*State, *Gooey) void`      | Framework access (focus, entities) |
| `cx.commandWith()` | `fn(*State, *Gooey, Arg) void` | Framework access with argument     |
| `cx.defer()`       | `fn(*State, *Gooey) void`      | Run after current event completes  |
| `cx.deferWith()`   | `fn(*State, *Gooey, Arg) void` | Deferred with argument             |

> **Note:** The state type is passed explicitly: `cx.update(AppState, AppState.increment)`

### Handlers with Arguments

The `*With` variants (`updateWith`, `commandWith`, `deferWith`) let you pass data to your handler. The argument is captured at handler creation time and passed when invoked:

```zig
// In a list render callback - capture the index
.on_click_handler = cx.updateWith(State, index, State.selectItem),

// The handler receives the captured value
pub fn selectItem(self: *State, index: u32) void {
    self.selected = index;
}
```

**The 8-byte limit:** Arguments are packed into a `u64` for zero-allocation storage. This means your argument must be ≤8 bytes. If it exceeds this, you'll get a compile error:

```
error: updateWith: argument type 'MyLargeStruct' exceeds 8 bytes. Use a pointer or index instead.
```

**What fits in 8 bytes:**

| Type                                | Size     | ✓/✗ |
| ----------------------------------- | -------- | --- |
| `u8`, `i8`, `bool`                  | 1 byte   | ✓   |
| `u16`, `i16`                        | 2 bytes  | ✓   |
| `u32`, `i32`, `f32`                 | 4 bytes  | ✓   |
| `u64`, `i64`, `f64`                 | 8 bytes  | ✓   |
| `usize` (64-bit)                    | 8 bytes  | ✓   |
| `*T` (any pointer)                  | 8 bytes  | ✓   |
| `struct { x: u32, y: u32 }`         | 8 bytes  | ✓   |
| `[2]u32`                            | 8 bytes  | ✓   |
| `struct { a: u32, b: u32, c: u32 }` | 12 bytes | ✗   |

**Workarounds for larger data:**

```zig
// Option 1: Use an index into your data
.on_click_handler = cx.updateWith(State, row_index, State.selectRow),

// Option 2: Use a pointer (if the data outlives the handler)
.on_click_handler = cx.updateWith(State, &self.items[i], State.editItem),

// Option 3: Store data in state, pass an ID
pub fn openFile(self: *State, file_id: u32) void {
    const file = self.files.get(file_id) orelse return;
    // ... use file.path, file.name, etc.
}
```

### Deferred Commands

Use `defer` when you need to run code **after** the current event handler completes. This is essential for:

- **Modal dialogs** - They run their own event loop, which would deadlock if called during event handling
- **File pickers** - Same reason as modals
- **Heavy operations** - Defer work to avoid blocking the current frame

```zig
// In a command handler, use g.deferCommand():
pub fn openFolder(self: *State, g: *Gooey) void {
    _ = self;
    g.deferCommand(State, State.openFolderDeferred);
}

fn openFolderDeferred(self: *State, g: *Gooey) void {
    _ = g;
    // Safe to open modal dialog here - we're outside event handling
    if (file_dialog.chooseFolder(.{})) |path| {
        self.loadDirectory(path);
    }
}

// With an argument (same 8-byte limit applies):
pub fn deleteItem(self: *State, g: *Gooey, index: u32) void {
    _ = self;
    g.deferCommandWith(State, u32, index, State.confirmDelete);
}

fn confirmDelete(self: *State, g: *Gooey, index: u32) void {
    _ = g;
    if (dialog.confirm("Delete item?")) {
        self.items.remove(index);
    }
}
```

The deferred command queue holds up to 32 commands and is flushed after each event cycle.

## Fonts

By default, Gooey uses the platform's system sans-serif font (e.g., DejaVu Sans on Linux, SF Pro on macOS, system-ui on web). You can set a custom font at app init or switch fonts at runtime.

### App-Level Font

Set `.font` in your app config to use any font installed on the system:

```zig
const App = gooey.App(AppState, &state, render, .{
    .title = "My App",
    .font = "Inter",
    .font_size = 16.0,   // optional, defaults to 16.0
});
```

Omitting `.font` uses the platform default. On Linux, any font discoverable by Fontconfig works — install fonts via your package manager (e.g., `sudo apt install fonts-inter`) or drop `.ttf`/`.otf` files into `~/.local/share/fonts/`.

### Runtime Font Switching

Change the font on the fly from any event handler:

```zig
fn onSettingsChanged(cx: *Cx) void {
    const s = cx.state(AppState);
    cx.setFont(s.font_name, s.font_size) catch {};
}
```

This clears the glyph and shape caches and triggers a re-render automatically. All text in the UI updates immediately.

### Platform Details

| Platform | Font Discovery | System Sans-Serif |
| -------- | -------------- | ----------------- |
| Linux    | Fontconfig     | `sans-serif` (typically DejaVu Sans or Noto Sans) |
| macOS    | CoreText       | SF Pro |
| Web      | CSS font stack | `system-ui, -apple-system, sans-serif` |

> **Note:** Gooey currently uses a single global font. Per-component font families (e.g., mixing a serif body font with a monospace code font) are not yet supported — components expose `font_size` but not `font_family`.

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
cx.render(ui.hstack(.{ .gap = 4 }, .{
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
}))
```

### UniformList

Virtualized list for efficiently rendering large datasets with uniform item heights. Only visible items are rendered, regardless of total count. The render callback receives `*Cx` for full access to state and handlers.

```zig
const State = struct {
    list_state: UniformListState = UniformListState.init(10_000, 32.0), // count, item height
    selected: ?u32 = null,

    pub fn scrollToTop(self: *State) void {
        self.list_state.scrollToTop();
    }

    pub fn scrollToMiddle(self: *State) void {
        self.list_state.scrollToItem(5000, .center);
    }

    pub fn selectItem(self: *State, index: u32) void {
        self.selected = index;
    }
};

// In render function:
fn render(cx: *Cx) void {
    const s = cx.state(State);
    cx.uniformList("my-list", &s.list_state, .{
        .fill_width = true,
        .grow_height = true,
    }, renderItem);
}

fn renderItem(index: u32, cx: *Cx) void {
    const s = cx.stateConst(State);
    const theme = cx.builder().theme();
    const is_selected = if (s.selected) |sel| sel == index else false;

    // Color is available via: const Color = gooey.Color;
    const text_color = if (is_selected) Color.white else theme.text;

    cx.render(ui.box(.{
        .fill_width = true,
        .height = 32,
        .background = if (is_selected) theme.primary else null,
        .hover_background = theme.overlay,
        .on_click_handler = cx.updateWith(State, index, State.selectItem),
    }, .{
        ui.text("Item", .{ .color = text_color }),
    }));
}
```

### VirtualList

Virtualized list supporting variable item heights. Heights are cached after rendering for efficient scroll calculations. Ideal for chat messages or expandable rows. The callback must return the rendered height.

```zig
const State = struct {
    list_state: VirtualListState = VirtualListState.init(1000, 48.0), // count, default height
};

// In render function - callback returns item height:
fn render(cx: *Cx) void {
    const s = cx.state(State);
    cx.virtualList("chat-list", &s.list_state, .{ .grow_height = true }, renderMessage);
}

fn renderMessage(index: u32, cx: *Cx) f32 {
    const s = cx.stateConst(State);
    const msg = s.messages[index];
    const height: f32 = if (msg.has_image) 120.0 else 48.0;

    cx.render(ui.box(.{
        .fill_width = true,
        .height = height,
        .on_click_handler = cx.updateWith(State, index, State.selectMessage),
    }, .{
        ui.text(msg.text, .{}),
    }));

    return height; // Return actual rendered height for caching
}
```

### DataTable

Virtualized 2D table with both vertical and horizontal virtualization. Supports column resizing, sorting, and selection. Uses a callbacks struct for header and cell rendering.

```zig
const State = struct {
    table_state: DataTableState = blk: {
        var t = DataTableState.init(10_000, 32.0); // row count, row height
        t.addColumn(.{ .width_px = 80, .sortable = true }) catch unreachable;   // ID
        t.addColumn(.{ .width_px = 200, .sortable = true }) catch unreachable;  // Name
        t.addColumn(.{ .width_px = 100 }) catch unreachable;                     // Status
        break :blk t;
    },

    pub fn onHeaderClick(self: *State, col: u32) void {
        _ = self.table_state.toggleSort(col);
        // Re-sort your data based on table_state.sort_column and direction
    }

    pub fn onRowClick(self: *State, row: u32) void {
        self.table_state.selection.row = row;
    }
};

// In render function:
fn render(cx: *Cx) void {
    const s = cx.state(State);
    const theme = cx.builder().theme();
    cx.dataTable("my-table", &s.table_state, .{
        .fill_width = true,
        .grow_height = true,
        .row_hover_background = theme.overlay,
        .row_selected_background = theme.primary,
    }, .{
        .render_header = renderHeader,
        .render_cell = renderCell,
    });
}

fn renderHeader(col: u32, cx: *Cx) void {
    const s = cx.stateConst(State);
    const theme = cx.builder().theme();

    // Add sort indicator if this column is sorted
    const name = COLUMN_NAMES[col];
    const label = if (s.table_state.sort_column == col)
        if (s.table_state.sort_direction == .ascending) name ++ " ▲" else name ++ " ▼"
    else
        name;

    cx.render(ui.box(.{
        .fill_width = true,
        .fill_height = true,
        .on_click_handler = cx.updateWith(State, col, State.onHeaderClick),
    }, .{
        ui.text(label, .{ .weight = .semibold, .color = theme.text }),
    }));
}

fn renderCell(row: u32, col: u32, cx: *Cx) void {
    const theme = cx.builder().theme();

    cx.render(ui.box(.{
        .fill_width = true,
        .fill_height = true,
        .padding = .{ .symmetric = .{ .x = 8, .y = 0 } },
    }, .{
        switch (col) {
            0 => ui.textFmt("{d}", .{row}, .{ .color = theme.text }),
            1 => ui.text(data[row].name, .{ .color = theme.text }),
            2 => ui.text(data[row].status, .{ .color = theme.text }),
            else => ui.text("—", .{}),
        },
    }));
}
```

## Form Validation

Gooey provides utilities for form validation with touched-state tracking:

### Validation Utilities

```zig
const validation = gooey.validation;

// Single validators
const err = validation.required(value);           // Non-empty check
const err = validation.email(value);              // Email format
const err = validation.minLength(value, 8);       // Minimum length
const err = validation.maxLength(value, 100);     // Maximum length
const err = validation.numeric(value);            // Digits only
const err = validation.alphanumeric(value);       // Letters and numbers
const err = validation.matches(value, other);     // Values must match

// Password strength
const err = validation.hasUppercase(value);       // At least one uppercase
const err = validation.hasLowercase(value);       // At least one lowercase
const err = validation.hasDigit(value);           // At least one number
const err = validation.hasSpecialChar(value);     // At least one special char

// Chain multiple validators - returns first error or null
const err = validation.all(password, .{
    validation.required,
    validation.minLengthValidator(8),
    validation.hasUppercase,
    validation.hasDigit,
});
```

### Custom Messages (i18n)

Create validators with custom messages for internationalization:

```zig
// Define a locale struct with custom validators
const french = struct {
    pub const required = validation.requiredMsg("Ce champ est requis");
    pub const email = validation.emailMsg("Adresse e-mail invalide");
    pub const minLength8 = validation.minLengthMsg(8, "Au moins 8 caractères");
    pub const hasUppercase = validation.hasUppercaseMsg("Au moins une majuscule");
};

// Use in validation - works with all() combinator
const err = validation.all(value, .{
    french.required,
    french.email,
});

// Available message factories:
// validation.requiredMsg(msg)
// validation.emailMsg(msg)
// validation.minLengthMsg(min, msg)
// validation.maxLengthMsg(max, msg)
// validation.numericMsg(msg)
// validation.alphanumericMsg(msg)
// validation.hasUppercaseMsg(msg)
// validation.hasLowercaseMsg(msg)
// validation.hasDigitMsg(msg)
// validation.hasSpecialCharMsg(msg)
// validation.matchesMsg(msg)
```

### Error Codes (Programmatic Handling)

Use error codes when you need to programmatically handle errors (e.g., focus first invalid field):

```zig
// Returns ?ErrorCode instead of ?[]const u8
const code = validation.requiredCode(value);
if (code == .required) {
    cx.setFocus("username");  // Focus first invalid field
}

// Available error codes:
// .required, .min_length, .max_length, .invalid_email,
// .not_numeric, .not_alphanumeric, .mismatch,
// .no_uppercase, .no_lowercase, .no_digit, .no_special_char

// Find first invalid field - call individual *Code functions in sequence
// (there's no allCode() combinator; this pattern keeps the API simple)
pub fn getFirstInvalidField(s: *const State) ?[]const u8 {
    if (validation.requiredCode(s.username) != null) return "username";
    if (validation.emailCode(s.email) != null) return "email";
    if (validation.minLengthCode(s.password, 8) != null) return "password";
    return null;
}
```

> **Note:** Unlike `all()` for error messages, there's no `allCode()` combinator.
> For multi-field validation with error codes, call individual `*Code` functions
> in sequence as shown above. This keeps the API simple while covering the
> common "focus first invalid field" use case.

### Structured Results (Full Accessibility Control)

When you need different messages for visual display vs screen readers:

```zig
// Structured result with separate messages
const result = validation.requiredResult(value, .{
    .message = "Required",  // Terse for visual display
    .accessible_message = "The email field is required. Please enter your email address.",
});

if (result) |r| {
    r.code              // ErrorCode for programmatic handling
    r.displayMessage()  // Message for visual display
    r.screenReaderMessage()  // Message for screen readers (falls back to display)
}

// Use with ValidatedTextInput for full a11y control
gooey.ValidatedTextInput{
    .id = "email",
    .error_result = validation.requiredResult(s.email, .{
        .message = "Required",
        .accessible_message = "The email address field is required",
    }),
    .show_error = s.touched_email,
}
```

### ValidatedTextInput Component

All-in-one form field with label, input, error display, and help text:

```zig
const State = struct {
    email: []const u8 = "",
    touched_email: bool = false,

    pub fn validateEmail(self: *const State) ?[]const u8 {
        return gooey.validation.all(self.email, .{
            gooey.validation.required,
            gooey.validation.email,
        });
    }

    pub fn onEmailBlur(self: *State) void {
        self.touched_email = true;
    }
};

// In render:
gooey.ValidatedTextInput{
    .id = "email",
    .label = "Email Address",
    .required_indicator = true,        // Shows "*" after label
    .placeholder = "you@example.com",
    .bind = &s.email,
    .error_message = s.validateEmail(),  // Simple string error
    .show_error = s.touched_email,       // Only show after interaction
    .help_text = "We'll never share your email",
    .on_blur_handler = cx.update(State, State.onEmailBlur),
    .width = 300,
}

// Or with structured result for different a11y messages:
gooey.ValidatedTextInput{
    .id = "email",
    .label = "Email Address",
    .error_result = validation.emailResult(s.email, .{
        .message = "Invalid email",
        .accessible_message = "Please enter a valid email address in the format name@example.com",
    }),
    .show_error = s.touched_email,
}
```

### Form-Level Helpers

```zig
// Track errors for multiple fields
var errors = validation.FormErrors(4).init();
errors.set(0, validation.required(s.username));
errors.set(1, validation.email(s.email));
errors.set(2, validation.minLength(s.password, 8));
errors.set(3, validation.matches(s.confirm, s.password));

if (errors.isValid()) {
    // Submit form
} else {
    // errors.firstErrorIndex() returns index of first invalid field
}

// Track touched state
var touched = validation.TouchedFields(4).init();
touched.touch(0);  // Mark field 0 as touched
if (touched.isTouched(0)) { ... }
touched.touchAll();  // Mark all on submit
touched.reset();     // Clear on form reset
```

Run `zig build run-form-validation` for a complete example.

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
cx.render(ui.box(.{
    .background = Color.white.withAlpha(fade.progress),
    .width = gooey.lerp(100.0, 150.0, pulse.progress),
}, .{...}));
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
cx.render(ui.box(.{
    .direction = .row,           // or .column
    .gap = 16,
    .padding = .{ .all = 24 },   // or .symmetric, .each
    .alignment = .{ .main = .space_between, .cross = .center },
    .fill_width = true,
    .grow = true,
}, .{...}));

// Shrink behavior - elements shrink when container is too small
cx.render(ui.box(.{ .width = 150, .min_width = 60 }, .{...}));

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
    cx.render(ui.box(.{}, .{
        ui.onAction(Undo, doUndo),  // Handle action

        // Scoped context
        ui.keyContext("Editor"),
        ui.onAction(Save, doSave),
    }));
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
| A11y Demo        | `zig build run-a11y-demo`        | VoiceOver accessibility demo          |
| Accessible Form  | `zig build run-accessible-form`  | Complete accessible form example      |
| Drag & Drop      | `zig build run-drag-drop`        | Draggable items and drop targets      |
| Uniform List     | `zig build run-uniform-list`     | Virtualized list with 10,000 items    |
| Virtual List     | `zig build run-virtual-list`     | Variable-height virtualized list      |
| Data Table       | `zig build run-data-table`       | Virtualized table with 10,000 rows    |
| Code Editor      | `zig build run-code-editor`      | Code editor with syntax highlighting  |

See [docs/accessibility.md](docs/accessibility.md) for comprehensive accessibility documentation.

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
python3 -m http.server 8080 -d zig-out/web
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

```architecture.txt
src/
├── app.zig          # App entry points (runCx, App, WebApp)
├── cx.zig           # Unified context (Cx)
├── root.zig         # Public API exports
│
├── core/            # Foundational types (geometry, events, shaders)
├── input/           # Input handling (events, actions, keymaps)
├── scene/           # GPU primitives (scene graph, batching)
├── context/         # App context (focus, entity, dispatch, widget store)
├── animation/       # Animation system and easing
├── debug/           # Debugging tools and render stats
│
├── ui/              # Declarative builder (box, vstack, hstack, primitives)
├── components/      # UI components (Button, TextInput, Modal, Tooltip, etc.)
├── widgets/         # Stateful widget implementations (text input/area state)
├── layout/          # Flexbox-style layout engine
│
├── text/            # Text rendering (CoreText, FreeType/HarfBuzz, Canvas)
├── image/           # Image loading and atlas management
├── svg/             # SVG rasterization (CoreGraphics, Linux, Canvas)
├── platform/        # macOS/Metal, Linux/Vulkan/Wayland, WASM/WebGPU
├── runtime/         # Frame rendering and input handling
└── examples/        # Demo applications
```

## Linux Platform

Gooey has full Linux support using Wayland and Vulkan. The showcase and all demos run on Linux.

### Architecture

```linux-architecture.txt
Linux Platform Stack:
┌─────────────────────────────────────┐
│         gooey Application           │
├─────────────────────────────────────┤
│  LinuxPlatform  │  Window           │
│  (event loop)   │  (XDG shell)      │
├─────────────────────────────────────┤
│  VulkanRenderer │  SceneRenderer    │
│  (direct Vulkan, GLSL shaders)      │
├─────────────────────────────────────┤
│  Wayland Client  │  Vulkan Driver   │
└─────────────────────────────────────┘
```

### What's Implemented ✓

| Feature                | Implementation                                                                  |
| ---------------------- | ------------------------------------------------------------------------------- |
| **Windowing**          | Wayland via XDG shell (xdg-toplevel, xdg-decoration)                            |
| **GPU Rendering**      | Direct Vulkan with GLSL shaders (unified, text, svg, image pipelines)           |
| **Text Rendering**     | FreeType for rasterization, HarfBuzz for shaping, Fontconfig for font discovery |
| **Input Handling**     | Full keyboard (evdev keycodes), mouse, scroll with modifier support             |
| **Clipboard**          | Wayland data-device protocol (copy/paste text)                                  |
| **File Dialogs**       | XDG Desktop Portal via D-Bus (open, save, directory selection)                  |
| **IME Support**        | zwp_text_input_v3 protocol for international text input                         |
| **HiDPI**              | wp_viewporter protocol with scale factor support                                |
| **Server Decorations** | zxdg-decoration-manager-v1 protocol                                             |

### Key Design Decisions

1. **Wayland-only** - No X11 fallback (modern approach like Ghostty)
2. **Direct Vulkan** - No wgpu-native dependency, full control over rendering
3. **Native text stack** - FreeType/HarfBuzz/Fontconfig (same as most Linux apps)
4. **XDG Portal integration** - Native file dialogs that respect user's desktop environment

### Dependencies Required

```deps.sh
# System packages (Debian/Ubuntu)
sudo apt install \
    libwayland-dev \
    libvulkan-dev \
    libfreetype-dev \
    libharfbuzz-dev \
    libfontconfig-dev \
    libpng-dev \
    libdbus-1-dev

# Fedora/RHEL
sudo dnf install \
    wayland-devel \
    vulkan-loader-devel \
    freetype-devel \
    harfbuzz-devel \
    fontconfig-devel \
    libpng-devel \
    dbus-devel

# Arch Linux
sudo pacman -S \
    wayland \
    vulkan-icd-loader \
    vulkan-headers \
    freetype2 \
    harfbuzz \
    fontconfig \
    libpng \
    dbus
```

### Building & Running

```build.sh
# Build and run the showcase
zig build run

# Run specific demos
zig build run-basic        # Simple Wayland + Vulkan test
zig build run-text         # Text rendering demo
zig build run-file-dialog  # XDG portal file dialogs

# Compile shaders (only needed if you modify GLSL sources)
zig build compile-shaders
```

### What's Left / Known Limitations

1. **Custom cursors** - Cursor theming via wl_cursor not yet implemented
2. **Hot reloading** - macOS-only currently (uses FSEvents)
3. **Glass effects** - macOS-specific (compositor-dependent on Linux)
4. **Multi-window** - Supported in platform but not fully tested

## Testing & CI

### Running Tests

```bash
# Run all tests
zig build test

# Run tests under valgrind (Linux only - detects memory leaks)
zig build test-valgrind

# Check code formatting
zig fmt --check src/ charts/
```

### Continuous Integration

The project uses GitHub Actions for CI. Every push and pull request runs:

| Job           | Platform | Description                                                                   |
| ------------- | -------- | ----------------------------------------------------------------------------- |
| `test-linux`  | Ubuntu   | Unit tests on Linux                                                           |
| `test-macos`  | macOS    | Unit tests on macOS                                                           |
| `build-linux` | Ubuntu   | Build all optimization levels (Debug, ReleaseSafe, ReleaseFast, ReleaseSmall) |
| `build-macos` | macOS    | Build all optimization levels                                                 |
| `build-wasm`  | Ubuntu   | WebAssembly targets                                                           |
| `valgrind`    | Ubuntu   | Memory leak detection via valgrind                                            |
| `zig-fmt`     | Ubuntu   | Code formatting check                                                         |

### Memory Leak Detection

Valgrind integration helps catch memory issues early:

```bash
# Run tests with full leak checking
zig build test-valgrind
```

The `valgrind.supp` file contains suppressions for known false positives from system libraries (Vulkan, Wayland, FreeType, HarfBuzz, etc.).

## Inspiration

- [GPUI](https://github.com/zed-industries/zed/tree/main/crates/gpui) - Zed's GPU UI framework
- [Clay](https://github.com/nicbarker/clay) - Immediate mode layout
- [Ghostty](https://github.com/ghostty-org/ghostty) - Zig + Metal terminal
