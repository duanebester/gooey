# AI Native Canvas — Design Document

> Expose Gooey's drawing primitives as AI-callable "tools" so an LLM can draw on a canvas, render text, and build visual artifacts at runtime. Color fields accept hex strings or semantic theme tokens that resolve at render time.

**Status:** v1 Complete  
**Created:** 2025-07-14

---

## Table of Contents

1. [Motivation](#motivation)
2. [Key Insight: Comptime vs Runtime](#key-insight-comptime-vs-runtime)
3. [Architecture: Command Buffer Pattern](#architecture-command-buffer-pattern)
4. [DrawCommand Type](#drawcommand-type)
5. [Text Pool](#text-pool)
6. [AiCanvas: The Runtime State](#aicanvas-the-runtime-state)
7. [Paint Callback: Bridging Comptime and Runtime](#paint-callback-bridging-comptime-and-runtime)
8. [Tool Schema](#tool-schema)
9. [Comptime Schema Generation](#comptime-schema-generation)
10. [Transport Layer](#transport-layer)
11. [Where This Lives in the Codebase](#where-this-lives-in-the-codebase)
12. [DrawContext Coverage Map](#drawcontext-coverage-map)
13. [Constraints and Limits](#constraints-and-limits)
14. [WASM Compatibility](#wasm-compatibility)
15. [Future: Bidirectional](#future-bidirectional)
16. [Open Questions](#open-questions)
17. [References](#references)

---

## Motivation

Gooey already has a rich immediate-mode drawing API (`DrawContext`) and interactive primitives (`TextInput`, `Button`, `Canvas`). The canvas drawing example (`src/examples/canvas_drawing.zig`) demonstrates clicking to place dots, and text primitives render styled text anywhere in the UI tree.

The idea: expose these as **tools** in the API layer that an AI model can call. The AI gets a slate/canvas and can issue draw commands (`draw_rect`, `draw_circle`, `draw_text`, `draw_line`, etc.) to build visual output — an etch-a-sketch driven by an LLM.

### Goals

1. **AI as a first-class consumer** — An LLM can produce visual output through Gooey with the same fidelity as hand-written code
2. **Zero framework changes required** — The command buffer lives in user-land app state
3. **Serializable protocol** — Tools are JSON-describable, transport-agnostic
4. **No runtime allocation** — Fixed-capacity buffers, consistent with CLAUDE.md principles
5. **Cross-platform** — Works on macOS (Metal), Linux (Vulkan), and Web (WebGPU/WASM)

### Non-Goals

- Widget-level AI control (button creation, form building) — future work
- Bidirectional vision (AI seeing the canvas) — future work, noted below
- Streaming animation — batch-per-frame is sufficient for v1
- AI writing Zig code that gets compiled — that's a different (harder) problem

---

## Key Insight: Comptime vs Runtime

This is the central concern and the reason this document exists.

### The Comptime Surface

Gooey wires things up at comptime. The `App` function takes comptime type parameters:

```zig
// src/app.zig — comptime State type, comptime render function
pub fn App(
    comptime State: type,
    state: *State,
    comptime render: fn (*Cx) void,
    comptime config: anytype,
) type { ... }
```

Canvas paint callbacks are comptime function pointers:

```zig
// src/ui/canvas.zig — paint is a comptime fn pointer
pub fn canvas(w: f32, h: f32, paint: *const fn (*DrawContext) void) Canvas { ... }
```

Handler creation uses comptime method references:

```zig
// src/cx.zig — comptime method binding
pub fn update(self: *Self, comptime State: type, comptime method: fn (*State) void) HandlerRef { ... }
pub fn command(self: *Self, comptime State: type, comptime method: fn (*State, *Gooey) void) HandlerRef { ... }
```

An AI cannot inject new comptime functions at runtime. Full stop.

### The Runtime Surface

But here's the thing — **every `DrawContext` method is a normal runtime call**:

```zig
// src/ui/canvas.zig — these are all runtime
pub fn fillRect(self: *Self, x: f32, y: f32, w: f32, h: f32, color: Color) void { ... }
pub fn fillCircle(self: *Self, cx: f32, cy: f32, radius: f32, color: Color) void { ... }
pub fn drawText(self: *Self, text: []const u8, x: f32, y: f32, color: Color, font_size: f32) f32 { ... }
pub fn line(self: *Self, x1: f32, y1: f32, x2: f32, y2: f32, line_width: f32, color: Color) void { ... }
```

Once inside a paint callback, everything is runtime. The comptime boundary is just the **wiring** — which function gets invoked. What that function _does_ is entirely runtime.

### The Bridge

One comptime paint callback → reads a runtime command buffer → calls runtime `DrawContext` methods.

The AI mutates the command buffer. The paint callback replays it. Comptime and runtime never conflict.

---

## Architecture: Command Buffer Pattern

This is a classic **display list** (or retained-mode command buffer). The architecture has three layers:

```
┌─────────────────────────────────────────────────┐
│  AI / External Process                          │
│  (Python, Node, curl, any language)             │
│                                                 │
│  Sends JSON commands:                           │
│  {"tool":"draw_rect","x":10,"y":20,...}         │
└──────────────────┬──────────────────────────────┘
                   │ stdin / HTTP / WebSocket / file
                   ▼
┌─────────────────────────────────────────────────┐
│  Transport / Parser Layer                       │
│  (app-level, NOT in framework core)             │
│                                                 │
│  Parses JSON → DrawCommand union variants       │
│  Pushes onto AiCanvas.commands[]                │
└──────────────────┬──────────────────────────────┘
                   │ writes to AppState.ai_canvas
                   ▼
┌─────────────────────────────────────────────────┐
│  Gooey Render Loop                              │
│                                                 │
│  render(cx) called each frame                   │
│    └─ ui.canvas(W, H, AiCanvas.paint)           │
│         └─ paint reads command buffer            │
│              └─ calls ctx.fillRect, ctx.drawText │
│                 etc. for each command             │
└─────────────────────────────────────────────────┘
```

Key properties:

- **No framework modification** — `DrawCommand` and `AiCanvas` live in user-land `AppState`
- **No allocation after init** — fixed-capacity arrays for commands and text
- **Transport-agnostic** — the command buffer doesn't care where commands come from
- **Frame-consistent** — the entire buffer is replayed atomically each frame
- **Draw order = z-order** — commands replay sequentially; later commands draw on top of earlier ones. The AI must emit background elements first and foreground elements last

---

## DrawCommand Type

A tagged union mapping 1:1 to `DrawContext` methods:

```zig
const MAX_DRAW_COMMANDS: usize = 4096;

const DrawCommand = union(enum) {
    // === Fills ===
    fill_rect: struct { x: f32, y: f32, w: f32, h: f32, color: ThemeColor },
    fill_rounded_rect: struct { x: f32, y: f32, w: f32, h: f32, radius: f32, color: ThemeColor },
    fill_circle: struct { cx: f32, cy: f32, radius: f32, color: ThemeColor },
    fill_ellipse: struct { cx: f32, cy: f32, rx: f32, ry: f32, color: ThemeColor },
    fill_triangle: struct { x1: f32, y1: f32, x2: f32, y2: f32, x3: f32, y3: f32, color: ThemeColor },

    // === Strokes / Lines ===
    stroke_rect: struct { x: f32, y: f32, w: f32, h: f32, width: f32, color: ThemeColor },
    stroke_circle: struct { cx: f32, cy: f32, radius: f32, width: f32, color: ThemeColor },
    line: struct { x1: f32, y1: f32, x2: f32, y2: f32, width: f32, color: ThemeColor },

    // === Text ===
    draw_text: struct { text_idx: u16, x: f32, y: f32, color: ThemeColor, font_size: f32 },
    draw_text_centered: struct { text_idx: u16, x: f32, y_center: f32, color: ThemeColor, font_size: f32 },

    // === Control ===
    set_background: struct { color: ThemeColor },
};

// Compile-time size budget — keep the union compact for cache-friendly replay
comptime {
    std.debug.assert(@sizeOf(DrawCommand) <= 64); // Largest variant must stay under 64 bytes
}
```

**`ThemeColor`** is a tagged union: `literal: Color | token: SemanticToken`. Literal wraps a concrete RGBA color (from hex strings like `"FF6B35"`). Token holds a semantic reference (from strings like `"primary"`, `"surface"`, `"text"`) that resolves against the active `Theme` at replay time. Both fit in ≤20 bytes, keeping the union well under the 64-byte cache line cap.

### Why a tagged union?

- **Exhaustive switch** — the compiler forces the paint callback to handle every variant
- **Fixed size** — the largest variant determines the union size; no heap indirection
- **Reflectable** — `std.meta.fields(DrawCommand)` enables comptime schema generation
- **Serializable** — each variant maps directly to a JSON object with a `"tool"` discriminator

### Why one `line` instead of `line` + `stroke_line`?

The `DrawContext` has both `line()` (optimized, auto-detects axis-aligned) and `strokeLine()` (stroke expansion for diagonals). From the AI's perspective this distinction is irrelevant — the AI just wants to draw a line. The replay function calls `ctx.line()` which internally picks the optimal code path. Fewer tools = less confusion for the model.

### Why `text_idx` instead of `[]const u8`?

Slices contain pointers. Pointers are not serializable, not safely storable across frames in a fixed buffer, and break the "no allocation" rule. Instead, text is stored in a separate pool and referenced by index. See next section.

---

## Text Pool

A fixed-capacity string arena for draw command text:

```zig
const MAX_TEXT_POOL_SIZE: usize = 16384;   // 16KB of text per frame
const MAX_TEXT_ENTRIES: usize = 256;        // max distinct strings
const MAX_TEXT_ENTRY_SIZE: usize = 512;     // max bytes per single string

const TextPool = struct {
    buffer: [MAX_TEXT_POOL_SIZE]u8 = undefined,
    offsets: [MAX_TEXT_ENTRIES]u16 = undefined,
    lengths: [MAX_TEXT_ENTRIES]u16 = undefined,
    count: u16 = 0,
    used: u16 = 0,

    /// Push a string into the pool, return its index. Null if full.
    fn push(self: *TextPool, text: []const u8) ?u16 {
        std.debug.assert(text.len <= MAX_TEXT_ENTRY_SIZE);
        if (self.count >= MAX_TEXT_ENTRIES) return null;
        if (self.used + text.len > MAX_TEXT_POOL_SIZE) return null;

        const idx = self.count;
        const offset = self.used;
        @memcpy(self.buffer[offset .. offset + text.len], text);
        self.offsets[idx] = offset;
        self.lengths[idx] = @intCast(text.len);
        self.count += 1;
        self.used += @intCast(text.len);
        return idx;
    }

    /// Retrieve a string by index.
    fn get(self: *const TextPool, idx: u16) []const u8 {
        std.debug.assert(idx < self.count);
        const offset = self.offsets[idx];
        return self.buffer[offset .. offset + self.lengths[idx]];
    }

    /// Reset for next batch of commands.
    fn clear(self: *TextPool) void {
        self.count = 0;
        self.used = 0;
    }
};
```

Properties:

- **Zero allocation** — everything in stack/static arrays
- **O(1) push and get** — index-based, no searching
- **Cleared per batch** — when AI sends a new batch, old strings are released
- **16KB limit** — plenty for labels, annotations, paragraphs; fail-fast if exceeded

---

## AiCanvas: The Runtime State

This struct lives inside the user's `AppState`. It owns the command buffer and text pool:

```zig
const AiCanvas = struct {
    commands: [MAX_DRAW_COMMANDS]DrawCommand = undefined,
    command_count: usize = 0,
    texts: TextPool = .{},
    canvas_width: f32 = 800,
    canvas_height: f32 = 600,
    background_color: ThemeColor = ThemeColor.fromLiteral(Color.hex(0x1a1a2e)),

    const Self = @This();

    // --- Mutation API (called by transport/parser layer) ---

    /// Push a command onto the buffer. Returns false if full (handles the
    /// negative space per CLAUDE.md rule #11). Callers can log dropped commands.
    pub fn pushCommand(self: *Self, cmd: DrawCommand) bool {
        std.debug.assert(self.command_count < MAX_DRAW_COMMANDS);
        if (self.command_count >= MAX_DRAW_COMMANDS) return false;
        self.commands[self.command_count] = cmd;
        self.command_count += 1;
        return true;
    }

    pub fn pushText(self: *Self, text: []const u8) ?u16 {
        return self.texts.push(text);
    }

    pub fn clearAll(self: *Self) void {
        self.command_count = 0;
        self.texts.clear();
    }

    // --- Replay (called by the comptime paint callback) ---

    pub fn replay(self: *const Self, ctx: *ui.DrawContext, theme: *const Theme) void {
        const w = ctx.width();
        const h = ctx.height();

        // Background fill — resolve ThemeColor against active theme
        ctx.fillRect(0, 0, w, h, self.background_color.resolve(theme));

        // Replay every command, resolving ThemeColor tokens at render time
        for (self.commands[0..self.command_count]) |cmd| {
            switch (cmd) {
                .fill_rect => |c| ctx.fillRect(c.x, c.y, c.w, c.h, c.color.resolve(theme)),
                .fill_rounded_rect => |c| ctx.fillRoundedRect(c.x, c.y, c.w, c.h, c.radius, c.color.resolve(theme)),
                .fill_circle => |c| ctx.fillCircle(c.cx, c.cy, c.radius, c.color.resolve(theme)),
                .fill_ellipse => |c| ctx.fillEllipse(c.cx, c.cy, c.rx, c.ry, c.color.resolve(theme)),
                .fill_triangle => |c| ctx.fillTriangle(c.x1, c.y1, c.x2, c.y2, c.x3, c.y3, c.color.resolve(theme)),
                .stroke_rect => |c| ctx.strokeRect(c.x, c.y, c.w, c.h, c.color.resolve(theme), c.width),
                .stroke_circle => |c| ctx.strokeCircle(c.cx, c.cy, c.radius, c.width, c.color.resolve(theme)),
                .line => |c| ctx.line(c.x1, c.y1, c.x2, c.y2, c.width, c.color.resolve(theme)),
                .draw_text => |c| {
                    const text = self.texts.get(c.text_idx);
                    _ = ctx.drawText(text, c.x, c.y, c.color.resolve(theme), c.font_size);
                },
                .draw_text_centered => |c| {
                    const text = self.texts.get(c.text_idx);
                    _ = ctx.drawTextVCentered(text, c.x, c.y_center, c.color.resolve(theme), c.font_size);
                },
                .set_background => |c| ctx.fillRect(0, 0, w, h, c.color.resolve(theme)),
            }
        }
    }
};
```

### Usage in AppState

**Native (triple-buffered):** Three `AiCanvas` instances in global state. Writer, renderer, and mailbox each own one buffer — no two threads ever touch the same buffer:

```zig
const AppState = struct {
    // ... other app state ...
};

var state = AppState{};

// Native: three buffers for lock-free triple-buffering (~840KB in global state)
var buffers: [3]AiCanvas = .{ .{}, .{}, .{} };
var write_idx: u8 = 0;       // Writer thread owns this — not shared
var ready_idx: u8 = 1;       // Mailbox — accessed via @atomicRmw only
var display_idx: u8 = 2;     // Render thread owns this — not shared
```

**WASM (single-buffered):** No threads, no contention — one buffer is sufficient:

```zig
var state = AppState{};
var ai_canvas: AiCanvas = .{};  // ~280KB in global state
```

---

## Paint Callback: Bridging Comptime and Runtime

The paint function is comptime (it's a function pointer known at compile time). But it delegates entirely to runtime state:

```zig
// Module-level theme pointer — set by render(), read by paint callback
var active_theme: *const Theme = &Theme.dark;

// Native: paint from the display buffer (renderer owns it exclusively)
fn paintAiCanvas(ctx: *ui.DrawContext) void {
    buffers[display_idx].replay(ctx, active_theme);
}

// WASM: paint from the single buffer (single-threaded, no contention)
// fn paintAiCanvas(ctx: *ui.DrawContext) void {
//     ai_canvas.replay(ctx);
// }

fn render(cx: *Cx) void {
    // Acquire latest committed batch from mailbox (native only)
    const old_ready = @atomicRmw(u8, &ready_idx, .Xchg, display_idx, .acq_rel);
    display_idx = old_ready;

    const size = cx.windowSize();
    cx.render(ui.box(.{
        .width = size.width,
        .height = size.height,
    }, .{
        ui.canvas(buffers[display_idx].canvas_width, buffers[display_idx].canvas_height, paintAiCanvas),
    }));
}
```

This is the entire comptime surface. One function pointer, four lines. Everything interesting happens at runtime inside `AiCanvas.replay`.

---

## Tool Schema

From the AI's perspective, it receives a set of tools it can call. This is the **complete** v1 tool set — every `DrawCommand` variant has a corresponding tool, no more, no less:

```json
{
  "tools": [
    {
      "name": "fill_rect",
      "description": "Fill a rectangle with a solid color",
      "parameters": {
        "x": {
          "type": "number",
          "description": "X position (pixels from left)"
        },
        "y": {
          "type": "number",
          "description": "Y position (pixels from top)"
        },
        "w": { "type": "number", "description": "Width in pixels" },
        "h": { "type": "number", "description": "Height in pixels" },
        "color": {
          "type": "string",
          "description": "Hex color (e.g. 'FF6B35') or theme token: bg, surface, overlay, primary, secondary, accent, success, warning, danger, text, subtext, muted, border, border_focus"
        }
      }
    },
    {
      "name": "fill_rounded_rect",
      "description": "Fill a rounded rectangle with a solid color",
      "parameters": {
        "x": {
          "type": "number",
          "description": "X position (pixels from left)"
        },
        "y": {
          "type": "number",
          "description": "Y position (pixels from top)"
        },
        "w": { "type": "number", "description": "Width in pixels" },
        "h": { "type": "number", "description": "Height in pixels" },
        "radius": {
          "type": "number",
          "description": "Corner radius in pixels"
        },
        "color": {
          "type": "string",
          "description": "Hex color (e.g. 'FF6B35') or theme token: bg, surface, overlay, primary, ..."
        }
      }
    },
    {
      "name": "fill_circle",
      "description": "Fill a circle with a solid color",
      "parameters": {
        "cx": { "type": "number", "description": "Center X" },
        "cy": { "type": "number", "description": "Center Y" },
        "radius": { "type": "number", "description": "Radius in pixels" },
        "color": {
          "type": "string",
          "description": "Hex color (e.g. 'FF6B35') or theme token: bg, surface, overlay, primary, ..."
        }
      }
    },
    {
      "name": "fill_ellipse",
      "description": "Fill an ellipse with a solid color",
      "parameters": {
        "cx": { "type": "number", "description": "Center X" },
        "cy": { "type": "number", "description": "Center Y" },
        "rx": {
          "type": "number",
          "description": "Horizontal radius in pixels"
        },
        "ry": { "type": "number", "description": "Vertical radius in pixels" },
        "color": {
          "type": "string",
          "description": "Hex color (e.g. 'FF6B35') or theme token: bg, surface, overlay, primary, ..."
        }
      }
    },
    {
      "name": "fill_triangle",
      "description": "Fill a triangle defined by three vertices",
      "parameters": {
        "x1": { "type": "number", "description": "Vertex 1 X" },
        "y1": { "type": "number", "description": "Vertex 1 Y" },
        "x2": { "type": "number", "description": "Vertex 2 X" },
        "y2": { "type": "number", "description": "Vertex 2 Y" },
        "x3": { "type": "number", "description": "Vertex 3 X" },
        "y3": { "type": "number", "description": "Vertex 3 Y" },
        "color": {
          "type": "string",
          "description": "Hex color (e.g. 'FF6B35') or theme token: bg, surface, overlay, primary, ..."
        }
      }
    },
    {
      "name": "stroke_rect",
      "description": "Stroke a rectangle outline",
      "parameters": {
        "x": {
          "type": "number",
          "description": "X position (pixels from left)"
        },
        "y": {
          "type": "number",
          "description": "Y position (pixels from top)"
        },
        "w": { "type": "number", "description": "Width in pixels" },
        "h": { "type": "number", "description": "Height in pixels" },
        "width": { "type": "number", "description": "Stroke width in pixels" },
        "color": {
          "type": "string",
          "description": "Hex color (e.g. 'FF6B35') or theme token: bg, surface, overlay, primary, ..."
        }
      }
    },
    {
      "name": "stroke_circle",
      "description": "Stroke a circle outline",
      "parameters": {
        "cx": { "type": "number", "description": "Center X" },
        "cy": { "type": "number", "description": "Center Y" },
        "radius": { "type": "number", "description": "Radius in pixels" },
        "width": { "type": "number", "description": "Stroke width in pixels" },
        "color": {
          "type": "string",
          "description": "Hex color (e.g. 'FF6B35') or theme token: bg, surface, overlay, primary, ..."
        }
      }
    },
    {
      "name": "line",
      "description": "Draw a line between two points (auto-optimizes for axis-aligned lines)",
      "parameters": {
        "x1": { "type": "number", "description": "Start X" },
        "y1": { "type": "number", "description": "Start Y" },
        "x2": { "type": "number", "description": "End X" },
        "y2": { "type": "number", "description": "End Y" },
        "width": { "type": "number", "description": "Line width in pixels" },
        "color": {
          "type": "string",
          "description": "Hex color (e.g. 'FF6B35') or theme token: bg, surface, overlay, primary, ..."
        }
      }
    },
    {
      "name": "draw_text",
      "description": "Render text at a position on the canvas",
      "parameters": {
        "text": {
          "type": "string",
          "description": "The text content to render"
        },
        "x": { "type": "number", "description": "X position" },
        "y": { "type": "number", "description": "Y position (top of text)" },
        "color": {
          "type": "string",
          "description": "Hex color (e.g. 'FF6B35') or theme token: bg, surface, overlay, primary, ..."
        },
        "font_size": { "type": "number", "description": "Font size in pixels" }
      }
    },
    {
      "name": "draw_text_centered",
      "description": "Render text vertically centered at a Y position",
      "parameters": {
        "text": {
          "type": "string",
          "description": "The text content to render"
        },
        "x": { "type": "number", "description": "X position" },
        "y_center": {
          "type": "number",
          "description": "Y position to vertically center text on"
        },
        "color": {
          "type": "string",
          "description": "Hex color (e.g. 'FF6B35') or theme token: bg, surface, overlay, primary, ..."
        },
        "font_size": { "type": "number", "description": "Font size in pixels" }
      }
    },
    {
      "name": "set_background",
      "description": "Fill the entire canvas with a background color (typically the first command in a batch)",
      "parameters": {
        "color": {
          "type": "string",
          "description": "Hex color (e.g. 'FF6B35') or theme token: bg, surface, overlay, primary, ..."
        }
      }
    }
  ]
}
```

11 tools, mapping 1:1 to `DrawCommand` variants → 1:1 to `DrawContext` methods. Clean, auditable chain.

**Color format:** Every `color` parameter accepts two formats:

- **Hex strings** — `"FF6B35"`, `"#FF6B35"`, `"FF6B35CC"` (with alpha). Parsed into `ThemeColor{ .literal = <Color> }`.
- **Semantic theme tokens** — `"primary"`, `"surface"`, `"text"`, `"bg"`, etc. (14 total, mirroring the `Theme` struct fields). Parsed into `ThemeColor{ .token = .primary }` and resolved against the active theme at replay time.

Token names are derived from the `SemanticToken` enum at comptime and listed in every color parameter's description, so the LLM always sees what's available. Theme tokens automatically adapt to light/dark mode.

**Coordinate system:** Top-left origin, matching `DrawContext` and what web-trained models expect. X increases rightward, Y increases downward.

---

## Comptime Schema Generation

Zig's comptime reflection means the tool schema can be **derived from the `DrawCommand` type itself**. If a new variant is added to the union, the schema updates automatically. They cannot drift.

```zig
/// Generate a JSON tool schema string from a DrawCommand union at comptime.
/// The schema and executor are derived from the same type — they cannot go out of sync.
fn generateToolSchema(comptime Command: type) []const u8 {
    comptime {
        const fields = std.meta.fields(Command);
        var schema: []const u8 = "[\n";
        for (fields, 0..) |field, i| {
            schema = schema ++ "  {\"name\": \"" ++ field.name ++ "\"";
            // Reflect over payload struct fields for parameters...
            schema = schema ++ "}";
            if (i < fields.len - 1) schema = schema ++ ",";
            schema = schema ++ "\n";
        }
        schema = schema ++ "]";
        return schema;
    }
}

// This is a comptime string literal — zero runtime cost, zero allocation
const tool_schema: []const u8 = generateToolSchema(DrawCommand);
```

This is a sketch — the real implementation would emit proper JSON with parameter types and descriptions derived from the struct field types. The key point: **one source of truth**.

**Caveat: the `text` asymmetry.** In the `DrawCommand` struct, text is `text_idx: u16` (a pool index). In the JSON schema, it's `"text": { "type": "string" }`. The schema generator must handle this special case — the parser converts the string to a pool index transparently. This is the one place where the internal representation and external schema intentionally diverge.

---

## Transport Layer

The command buffer is just app state. How commands get into it is a separate, user-chosen concern. The framework provides the types; the app chooses the transport.

### Options

| Transport                | Best For                          | Complexity | Latency |
| ------------------------ | --------------------------------- | ---------- | ------- |
| **Stdin JSON-lines**     | CLI tools, piped from Python/Node | Low        | ~1ms    |
| **HTTP POST**            | Any AI SDK, curl, webhooks        | Medium     | ~5-50ms |
| **WebSocket**            | Real-time streaming on web        | Medium     | ~1-5ms  |
| **Unix socket**          | Local IPC, low overhead           | Medium     | <1ms    |
| **Shared memory / mmap** | Maximum throughput                | High       | ~0      |
| **File watching**        | Simplest possible POC             | Minimal    | ~100ms  |

### Recommended: Stdin JSON-Lines (v1)

For a first implementation, JSON-lines on stdin is the path of least resistance:

**AI side (Python):**

```python
import json, subprocess

proc = subprocess.Popen(["./gooey-ai-canvas"], stdin=subprocess.PIPE)

# Draw a house — theme tokens for coherent styling, hex for custom colors
commands = [
    {"tool": "set_background", "color": "bg"},
    {"tool": "fill_rect", "x": 200, "y": 250, "w": 200, "h": 150, "color": "surface"},
    {"tool": "fill_triangle", "x1": 180, "y1": 250, "x2": 300, "y2": 120, "x3": 420, "y3": 250, "color": "danger"},
    {"tool": "fill_rect", "x": 270, "y": 320, "w": 60, "h": 80, "color": "654321"},  # hex works too
    {"tool": "fill_circle", "cx": 250, "cy": 300, "radius": 20, "color": "primary"},
    {"tool": "draw_text", "text": "Home", "x": 260, "y": 410, "color": "text", "font_size": 20},
]

for cmd in commands:
    proc.stdin.write((json.dumps(cmd) + "\n").encode())
    proc.stdin.flush()
```

**Gooey side:** A background thread (native) or polling loop (WASM) reads stdin, parses JSON, and calls `ai_canvas.pushCommand(...)`.

### Why Not HTTP from the Start?

HTTP is the obvious "production" transport, but stdin has advantages for a POC:

- No port binding, no CORS, no firewall issues
- Works identically on macOS, Linux, and (with minor adaptation) WASM
- Natural fit for subprocess-based AI tool calling (Anthropic's MCP, OpenAI function calling, etc.)
- Easy to test: `echo '{"tool":"fill_rect","x":0,"y":0,"w":100,"h":50,"color":"primary"}' | ./gooey-ai-canvas`

---

## Where This Lives in the Codebase

Following CLAUDE.md rule #12 (zero dependencies) and the precedent set by `gooey-charts`:

```
src/
├── ai/                          # NEW — optional AI integration module
│   ├── mod.zig                  # Public exports
│   ├── draw_command.zig         # DrawCommand union type (uses ThemeColor)
│   ├── theme_color.zig          # ThemeColor union + SemanticToken enum
│   ├── text_pool.zig            # TextPool fixed-capacity string storage
│   ├── ai_canvas.zig            # AiCanvas state + replay logic (takes *const Theme)
│   ├── json_parser.zig          # JSON → DrawCommand parser (theme-aware colors)
│   └── schema.zig               # Comptime tool schema generation (token list from enum)
│
├── examples/
│   ├── ai_canvas.zig            # NEW — example app: AI-driven canvas
│   └── canvas_drawing.zig       # Existing — mouse-driven canvas (reference)
```

### What Goes Where

| Component               | Location                  | Rationale                                                    |
| ----------------------- | ------------------------- | ------------------------------------------------------------ |
| `DrawCommand`           | `src/ai/draw_command.zig` | Core type, depends on `ThemeColor`                           |
| `ThemeColor`            | `src/ai/theme_color.zig`  | Tagged union (`Color` or `SemanticToken`), mirrors `Theme`   |
| `TextPool`              | `src/ai/text_pool.zig`    | Self-contained, tested independently                         |
| `AiCanvas`              | `src/ai/ai_canvas.zig`    | Depends on `DrawCommand`, `TextPool`, `DrawContext`, `Theme` |
| `json_parser`           | `src/ai/json_parser.zig`  | JSON → `DrawCommand`, uses `std.json` + `SemanticToken`      |
| `schema`                | `src/ai/schema.zig`       | Comptime schema gen from `DrawCommand` + `SemanticToken`     |
| Transport (stdin, HTTP) | Example-level or separate | Keeps core transport-agnostic                                |

### What Does NOT Change

- `src/ui/canvas.zig` — no modifications needed
- `src/ui/primitives.zig` — no modifications needed
- `src/runtime/frame.zig` — no modifications needed
- `src/cx.zig` — no modifications needed

The entire AI integration is additive. The command buffer pattern works with the framework as-is.

---

## DrawContext Coverage Map

Every `DrawContext` public method and whether it's covered by a `DrawCommand` variant:

| DrawContext Method                      | DrawCommand | Notes                                               |
| --------------------------------------- | :---------: | --------------------------------------------------- |
| `fillRect`                              |     ✅      | `fill_rect`                                         |
| `fillRoundedRect`                       |     ✅      | `fill_rounded_rect`                                 |
| `strokeRect`                            |     ✅      | `stroke_rect`                                       |
| `fillCircle`                            |     ✅      | `fill_circle`                                       |
| `fillEllipse`                           |     ✅      | `fill_ellipse`                                      |
| `fillCircleAdaptive`                    |     ❌      | Low priority — adaptive tessellation detail         |
| `fillEllipseAdaptive`                   |     ❌      | Low priority                                        |
| `fillCircleWithSegments`                |     ❌      | Low priority — explicit segment control             |
| `fillTriangle`                          |     ✅      | `fill_triangle`                                     |
| `line` / `strokeLine`                   |     ✅      | `line` — single tool, internally picks optimal path |
| `strokeCircle`                          |     ✅      | `stroke_circle`                                     |
| `strokeEllipse`                         |     ❌      | v2                                                  |
| `drawText`                              |     ✅      | `draw_text` (text via TextPool index)               |
| `drawTextVCentered`                     |     ✅      | `draw_text_centered`                                |
| `measureText`                           |     ❌      | Read-only, not a draw command — future query API    |
| `polyline`                              |     ❌      | v2 — needs array-of-points in command, more complex |
| `polylineClipped`                       |     ❌      | v2                                                  |
| `pointCloud`                            |     ❌      | v2 — needs array-of-points                          |
| `pointCloudColored`                     |     ❌      | v2                                                  |
| `pointCloudColoredArrays`               |     ❌      | v2                                                  |
| `beginPath` / `fillPath` / `strokePath` |     ❌      | v2 — needs path builder commands                    |
| `cachePath` / `fillCached`              |     ❌      | Internal optimization, not user-facing              |
| `fillPathLinearGradient`                |     ❌      | v2                                                  |
| `fillPathRadialGradient`                |     ❌      | v2                                                  |
| `fillRectLinearGradient`                |     ❌      | v2                                                  |
| `fillRectRadialGradient`                |     ❌      | v2                                                  |
| `fillCircleRadialGradient`              |     ❌      | v2                                                  |

### v1 Coverage

11 tools covering 12 `DrawContext` methods (since the single `line` tool maps to both `line` and `strokeLine` internally). These cover the vast majority of what an AI would want to draw: rectangles, circles, ellipses, triangles, lines, and text. Gradients, paths, polylines, and point clouds are v2.

---

## Constraints and Limits

Per CLAUDE.md — put a limit on everything:

| Resource                       | Constant              | Limit        | Rationale                         |
| ------------------------------ | --------------------- | ------------ | --------------------------------- |
| Draw commands per batch        | `MAX_DRAW_COMMANDS`   | 4,096        | Enough for complex scenes         |
| Text pool size                 | `MAX_TEXT_POOL_SIZE`  | 16,384 bytes | ~250 labels at 64 chars each      |
| Text entries                   | `MAX_TEXT_ENTRIES`    | 256          | One string per draw_text command  |
| Max text length (single entry) | `MAX_TEXT_ENTRY_SIZE` | 512 bytes    | Fail-fast on absurd strings       |
| JSON line length               | —                     | 4,096 bytes  | Prevents stdin buffer overflow    |
| Commands per frame             | —                     | 4,096        | Same as batch — replay is bounded |

If any limit is hit, **fail fast** — drop the command, log the overflow, continue rendering what's already buffered.

### Compile-time Size Assertions

Per CLAUDE.md rule #3 (assertion density), verify struct sizes at compile time:

```zig
comptime {
    std.debug.assert(@sizeOf(DrawCommand) <= 64);       // Keep variants compact for cache-friendly replay
    std.debug.assert(@sizeOf(AiCanvas) < 300 * 1024);   // Budget: 300KB total (commands ~260KB + text ~17KB)
    std.debug.assert(@sizeOf(TextPool) < 20 * 1024);    // Budget: 20KB
}
```

---

## WASM Compatibility

The command buffer is pure static memory. Per CLAUDE.md rule #14 (WASM stack budget), `AiCanvas` lives in a global `var` — never on the stack:

```zig
const AiCanvas = struct {
    commands: [MAX_DRAW_COMMANDS]DrawCommand = undefined,  // ~260KB in global state
    command_count: usize = 0,
    texts: TextPool = .{},                                  // ~17KB
};

// WASM: single buffer (~280KB in global state, no triple-buffering needed)
var ai_canvas: AiCanvas = .{};

// Native: three buffers (~840KB in global state) for triple-buffering
// var buffers: [3]AiCanvas = .{ .{}, .{}, .{} };
```

- **No heap allocation** — everything in global variables
- **No pointers in commands** — text uses indices, not slices
- **Size verified at comptime** — `@sizeOf(AiCanvas) < 300KB` (see Constraints section)
- **Single-threaded on WASM** — no triple-buffer needed, no atomics, no thread spawning. Commands are pushed directly into the single buffer from the exported WASM function, and `replay` reads from the same buffer. No race conditions possible.
- **Transport on WASM** — instead of stdin, use `postMessage` from JavaScript:

```javascript
// JS side — send commands to WASM
const commands = [
  { tool: "set_background", color: "bg" },
  { tool: "fill_rect", x: 10, y: 20, w: 100, h: 50, color: "primary" },
  {
    tool: "draw_text",
    text: "Hello AI",
    x: 50,
    y: 100,
    color: "text",
    font_size: 24,
  },
];
// Call WASM-exported function with serialized JSON
wasmInstance.exports.pushAiCommands(JSON.stringify(commands));
```

The WASM export would parse the JSON string and push commands onto the buffer, then call `requestAnimationFrame` to trigger a re-render.

---

## Future: Bidirectional

v1 is write-only: AI sends commands, Gooey renders them. But the architecture naturally extends to read-back:

### Query API (v2)

The AI could also ask questions about the canvas:

```json
{"query": "measure_text", "text": "Hello World", "font_size": 24}
→ {"width": 168.5, "height": 24.0}

{"query": "canvas_size"}
→ {"width": 800, "height": 600}

{"query": "command_count"}
→ {"count": 47, "max": 4096}
```

These map to existing `DrawContext` read methods like `measureText`, `width()`, `height()`.

### Screenshot / Vision (v3)

Capture the rendered canvas as an image and send it back to the AI for vision-based feedback loops. The AI draws something, sees the result, and iterates. This requires:

- Framebuffer readback (Metal/Vulkan/WebGPU all support this)
- JPEG/PNG encoding
- Base64 encoding for API transport

This is a larger effort but the command buffer architecture doesn't need to change at all.

### Widget Control (v3+)

Beyond canvas drawing, AI could manipulate the UI tree:

- Create/remove buttons, text inputs, labels
- Set widget properties (text, color, enabled state)
- Respond to user interactions (button clicks, text input)

This would require a separate mechanism from the canvas command buffer — likely a widget command protocol layered on top of the `Cx` API.

---

## Design Decisions

These were open questions during the design phase, now resolved:

1. **Batching semantics** — Default to **`set_background` + full redraw** each batch. The AI sends a complete scene every time — stateless, easy to reason about. With 4,096 commands the replay cost is negligible. Incremental append is supported (just don't send `set_background`), but full redraw is the recommended default.

2. **Color format** — **Hex strings or semantic theme tokens.** Hex: both `"FF6B35"` and `"#FF6B35"` are accepted (leading `#` stripped on parse). Theme tokens: `"primary"`, `"surface"`, `"text"`, `"bg"`, etc. (14 total, mirroring `Theme` struct fields). Theme tokens resolve against the active `Theme` at replay time via `ThemeColor.resolve(theme)`, so the same commands automatically adapt to light/dark mode. Hex and tokens can be freely mixed in a single batch. Stored internally as `ThemeColor` (tagged union: `literal: Color | token: SemanticToken`).

3. **Coordinate system** — **Top-left origin**. X increases rightward, Y increases downward. Matches `DrawContext` and what web-trained models expect.

4. **Thread safety for stdin reader** — **Triple-buffering** on native. Three `AiCanvas` instances live in global state (~840KB total). Writer, renderer, and mailbox each own one buffer exclusively. Only the mailbox index (`ready_idx`) is shared, accessed via `@atomicRmw(.Xchg, ..., .acq_rel)`. No two threads ever touch the same buffer — no fences, no mutexes, no clear-race. On WASM this is a non-issue (single-threaded, single buffer).

```zig
// Global state — three buffers, atomic mailbox index
var buffers: [3]AiCanvas = .{ .{}, .{}, .{} };
var write_idx: u8 = 0;       // Writer thread owns this
var ready_idx: u8 = 1;       // Mailbox — @atomicRmw only
var display_idx: u8 = 2;     // Render thread owns this

// Writer: push commands, then commit batch on empty line
buffers[write_idx].pushCommand(cmd);
// ... on batch boundary (empty stdin line):
const old_ready = @atomicRmw(u8, &ready_idx, .Xchg, write_idx, .acq_rel);
write_idx = old_ready;              // Take ownership of old mailbox buffer
buffers[write_idx].clearAll();      // Safe — we own it, no race

// Renderer: acquire latest batch at frame start
const old_ready = @atomicRmw(u8, &ready_idx, .Xchg, display_idx, .acq_rel);
display_idx = old_ready;            // Take ownership of latest batch
buffers[display_idx].replay(ctx);   // Replay — we own it, no race
```

Why triple instead of double? Double-buffering has a subtle race: after the index flip, the render thread must `clearAll()` the new back buffer — but the writer thread may already be pushing into it. Triple-buffering gives each thread its own buffer at all times. The mailbox is touched only via atomic swap, never written to directly. If the renderer is faster than the writer, it re-displays the same batch (harmless). If the writer is faster, the renderer always picks up the most recent complete batch.

**Batch delimiter:** An empty line between batches signals "batch complete." This is natural for JSON-lines protocols and doesn't pollute the tool namespace.

5. **Tool count** — **Fewer tools is better.** `line` and `stroke_line` merged into single `line` (framework picks optimal path internally). `clear` replaced by `set_background` (clearer intent). 11 tools total for v1.

---

## Open Questions

1. **Error reporting** — When a command is malformed or a limit is hit, how does the AI learn? Options: stderr JSON, a status query endpoint, or just log and drop. For v1, log and drop is fine.

2. **Polyline/PointCloud encoding** — These take arrays of points. JSON encoding is straightforward (`"points": [[x1,y1], [x2,y2], ...]`) but the `DrawCommand` union can't hold variable-length data. Options: separate point pool (like TextPool), or split into individual line segments. Point pool is cleaner.

3. **Opacity / alpha** — AI models frequently want transparency for layering effects. Currently color alpha is embedded in the hex value (e.g., `"FF6B35CC"` for ~80% opacity). Should we add an explicit `"opacity"` field to tools instead? Hex-with-alpha is sufficient for v1, revisit if models struggle with the format.

---

## References

- `src/examples/canvas_drawing.zig` — Interactive mouse-driven canvas (existing pattern)
- `src/ui/canvas.zig` — `DrawContext` API, `Canvas` element, `executePendingCanvas`
- `src/ui/primitives.zig` — UI primitive types (`text`, `box`, `hstack`, etc.)
- `src/cx.zig` — `Cx` context, `update`/`command` handler creation
- `src/app.zig` — `App()` comptime entry point, native + WASM
- `src/runtime/frame.zig` — Frame render loop, canvas execution
- `docs/charts.md` — `gooey-charts` as precedent for optional sub-module pattern
- `CLAUDE.md` — Engineering principles (static alloc, limits, assertions, 70-line functions)
