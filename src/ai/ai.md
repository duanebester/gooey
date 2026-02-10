# AI Module — API Reference

> `const ai = @import("gooey").ai;`

LLM-driven canvas drawing. An external process sends JSON commands on stdin,
Gooey parses them into a fixed-capacity command buffer, and a comptime paint
callback replays them into `DrawContext` each frame. Zero allocation after init.

**Design Doc:** [AI_NATIVE.md](../../docs/AI_NATIVE.md)
**Implementation Plan:** [AI_NATIVE_IMPL.md](../../docs/AI_NATIVE_IMPL.md)

---

## Quick Start

Pipe JSON-lines into the example app:

```sh
echo '{"tool":"set_background","color":"87CEEB"}
{"tool":"fill_rect","x":200,"y":250,"w":200,"h":150,"color":"8B4513"}
{"tool":"fill_triangle","x1":180,"y1":250,"x2":300,"y2":120,"x3":420,"y3":250,"color":"CC3333"}
{"tool":"draw_text","text":"Home","x":260,"y":410,"color":"FFFFFF","font_size":20}
' | zig-out/bin/ai-canvas
```

An empty line between groups commits the current batch. EOF commits the final batch.

---

## Public Exports

All public symbols are re-exported through `src/ai/mod.zig`:

| Symbol                | Type            | Source             | Description                                      |
| --------------------- | --------------- | ------------------ | ------------------------------------------------ |
| `AiCanvas`            | `struct`        | `ai_canvas.zig`    | Command buffer + text pool + replay engine       |
| `DrawCommand`         | `union(enum)`   | `draw_command.zig` | Tagged union — 11 variants, one per drawing tool |
| `TextPool`            | `struct`        | `text_pool.zig`    | Fixed-capacity string arena for text commands    |
| `parseCommand`        | `fn`            | `json_parser.zig`  | JSON line → `DrawCommand`                        |
| `tool_schema`         | `[]const u8`    | `schema.zig`       | Comptime JSON tool schema string literal         |
| `MAX_DRAW_COMMANDS`   | `usize` (4096)  | `draw_command.zig` | Hard cap on commands per batch                   |
| `MAX_TEXT_POOL_SIZE`  | `usize` (16384) | `text_pool.zig`    | Total byte capacity for pooled strings           |
| `MAX_TEXT_ENTRIES`    | `usize` (256)   | `text_pool.zig`    | Maximum distinct string entries                  |
| `MAX_TEXT_ENTRY_SIZE` | `usize` (512)   | `text_pool.zig`    | Maximum bytes per single string entry            |
| `MAX_JSON_LINE_SIZE`  | `usize` (4096)  | `json_parser.zig`  | Maximum bytes per JSON input line                |
| `TOOL_COUNT`          | `usize` (11)    | `schema.zig`       | Number of tools in the schema                    |

---

## AiCanvas

The core runtime state. Owns the command buffer and text pool. Provides three
API surfaces: **mutation** (for the parser/transport), **query** (for status
display), and **replay** (for the paint callback).

At ~280KB this struct **must** live in global `var` state — never on the stack.

### Mutation API

```
fn pushCommand(self: *AiCanvas, cmd: DrawCommand) bool
```

Push a command onto the buffer. Returns `true` on success, `false` if full.
Debug builds assert on overflow. Text commands must have valid `text_idx`
(push text first via `pushText`).

```
fn pushText(self: *AiCanvas, text: []const u8) ?u16
```

Push a string into the text pool. Returns the `u16` index, or `null` if
the pool is full (entry count or byte capacity exhausted). Use the returned
index as `text_idx` in `draw_text` / `draw_text_centered` commands.

```
fn clearAll(self: *AiCanvas) void
```

Reset all state for the next batch. O(1) — counters reset, buffer contents
become garbage. Call between batches.

### Query API

```
fn commandCount(self: *const AiCanvas) usize
fn commandsRemaining(self: *const AiCanvas) usize
fn isFull(self: *const AiCanvas) bool
```

### Replay API

```
fn replay(self: *const AiCanvas, ctx: *ui.DrawContext) void
```

Replay all buffered commands into a `DrawContext`. Called once per frame
from the comptime paint callback. Fills background first, then replays
every command via exhaustive switch. Handles `DrawContext` parameter order
inconsistencies internally.

### Fields

| Field              | Type                | Default     | Description                                      |
| ------------------ | ------------------- | ----------- | ------------------------------------------------ |
| `commands`         | `[4096]DrawCommand` | `undefined` | Command buffer (only `[0..command_count]` valid) |
| `command_count`    | `usize`             | `0`         | Number of valid commands                         |
| `texts`            | `TextPool`          | `.{}`       | String arena for text commands                   |
| `canvas_width`     | `f32`               | `800`       | Logical canvas width                             |
| `canvas_height`    | `f32`               | `600`       | Logical canvas height                            |
| `background_color` | `Color`             | `0x1a1a2e`  | Default background                               |

---

## DrawCommand

Tagged union with 11 variants mapping 1:1 to `DrawContext` methods.
Each variant is a struct with named fields. Fits in a single cache line (≤64 bytes).

### Variants

**Fills:**

| Variant             | Fields                                      |
| ------------------- | ------------------------------------------- |
| `fill_rect`         | `x`, `y`, `w`, `h`, `color`                 |
| `fill_rounded_rect` | `x`, `y`, `w`, `h`, `radius`, `color`       |
| `fill_circle`       | `cx`, `cy`, `radius`, `color`               |
| `fill_ellipse`      | `cx`, `cy`, `rx`, `ry`, `color`             |
| `fill_triangle`     | `x1`, `y1`, `x2`, `y2`, `x3`, `y3`, `color` |

**Strokes / Lines:**

| Variant         | Fields                                   |
| --------------- | ---------------------------------------- |
| `stroke_rect`   | `x`, `y`, `w`, `h`, `width`, `color`     |
| `stroke_circle` | `cx`, `cy`, `radius`, `width`, `color`   |
| `line`          | `x1`, `y1`, `x2`, `y2`, `width`, `color` |

**Text:**

| Variant              | Fields                                            |
| -------------------- | ------------------------------------------------- |
| `draw_text`          | `text_idx`, `x`, `y`, `color`, `font_size`        |
| `draw_text_centered` | `text_idx`, `x`, `y_center`, `color`, `font_size` |

**Control:**

| Variant          | Fields  |
| ---------------- | ------- |
| `set_background` | `color` |

All coordinate fields are `f32`. All `color` fields are `Color`.
Text commands use `text_idx: u16` (index into `TextPool`), not string slices.

### Helper Methods

```
fn hasTextRef(self: DrawCommand) bool       // true for draw_text, draw_text_centered
fn textIdx(self: DrawCommand) ?u16          // text pool index, or null
fn getColor(self: DrawCommand) Color        // color for any variant
```

---

## TextPool

Fixed-capacity string arena. Push strings in, get them back by `u16` index.
Cleared per batch — when the AI sends a new batch, old strings are released.

```
fn push(self: *TextPool, text: []const u8) ?u16     // returns index or null
fn get(self: *const TextPool, idx: u16) []const u8   // retrieve by index
fn clear(self: *TextPool) void                        // reset for next batch
fn entryCount(self: *const TextPool) u16
fn bytesUsed(self: *const TextPool) u16
fn bytesRemaining(self: *const TextPool) usize
fn entriesRemaining(self: *const TextPool) usize
```

---

## parseCommand

```
fn parseCommand(
    allocator: std.mem.Allocator,
    json_line: []const u8,
    texts: *TextPool,
) ?DrawCommand
```

Parse a single JSON line into a `DrawCommand`. The allocator is temporary —
used internally by `std.json.parseFromSlice`, freed before returning. No
allocation escapes this function.

For text commands, the `"text"` string is pushed into `texts` and the
resulting index stored as `text_idx` (schema aliasing).

Returns `null` on: malformed JSON, unknown tool, missing fields, wrong types.

### JSON Format

One JSON object per line with a `"tool"` discriminator:

```json
{"tool":"fill_rect","x":10,"y":20,"w":100,"h":50,"color":"FF6B35"}
{"tool":"draw_text","text":"Hello","x":10,"y":20,"color":"FFFFFF","font_size":16}
{"tool":"set_background","color":"1a1a2e"}
```

**Color format:** Hex string, with or without `#` prefix. Supports `RGB`,
`RGBA`, `RRGGBB`, and `RRGGBBAA` formats. Examples: `"FF6B35"`, `"#FF6B35"`,
`"FF6B35CC"` (with alpha).

**Numeric values:** Both integers (`"x": 10`) and floats (`"x": 10.0`) are
accepted — AI models emit either interchangeably.

---

## tool_schema

```
const tool_schema: []const u8 = ai.tool_schema;
```

Comptime-generated JSON string containing the tool schema array. Derived by
reflecting over `DrawCommand` at comptime — the schema and the command type
are the same source of truth and cannot drift. Zero runtime cost.

Use this to provide tool definitions to an LLM API (e.g. as the `tools`
parameter in a chat completion request).

The `text_idx` field is aliased to `"text": { "type": "string" }` in the
external schema. The parser handles the reverse mapping.

---

## Tool Reference

All 11 tools with their JSON parameters:

### `set_background`

Fill the entire canvas with a background color. Use as the first command in
a batch to clear the slate and start a fresh scene.

| Parameter | Type     | Description |
| --------- | -------- | ----------- |
| `color`   | `string` | Hex color   |

### `fill_rect`

Fill a rectangle with a solid color.

| Parameter | Type     | Description            |
| --------- | -------- | ---------------------- |
| `x`       | `number` | X position (left edge) |
| `y`       | `number` | Y position (top edge)  |
| `w`       | `number` | Width in pixels        |
| `h`       | `number` | Height in pixels       |
| `color`   | `string` | Hex color              |

### `fill_rounded_rect`

Fill a rounded rectangle with a solid color.

| Parameter | Type     | Description             |
| --------- | -------- | ----------------------- |
| `x`       | `number` | X position (left edge)  |
| `y`       | `number` | Y position (top edge)   |
| `w`       | `number` | Width in pixels         |
| `h`       | `number` | Height in pixels        |
| `radius`  | `number` | Corner radius in pixels |
| `color`   | `string` | Hex color               |

### `fill_circle`

Fill a circle with a solid color.

| Parameter | Type     | Description      |
| --------- | -------- | ---------------- |
| `cx`      | `number` | Center X         |
| `cy`      | `number` | Center Y         |
| `radius`  | `number` | Radius in pixels |
| `color`   | `string` | Hex color        |

### `fill_ellipse`

Fill an ellipse with a solid color.

| Parameter | Type     | Description       |
| --------- | -------- | ----------------- |
| `cx`      | `number` | Center X          |
| `cy`      | `number` | Center Y          |
| `rx`      | `number` | Horizontal radius |
| `ry`      | `number` | Vertical radius   |
| `color`   | `string` | Hex color         |

### `fill_triangle`

Fill a triangle defined by three vertices.

| Parameter | Type     | Description    |
| --------- | -------- | -------------- |
| `x1`      | `number` | First point X  |
| `y1`      | `number` | First point Y  |
| `x2`      | `number` | Second point X |
| `y2`      | `number` | Second point Y |
| `x3`      | `number` | Third point X  |
| `y3`      | `number` | Third point Y  |
| `color`   | `string` | Hex color      |

### `stroke_rect`

Stroke a rectangle outline.

| Parameter | Type     | Description            |
| --------- | -------- | ---------------------- |
| `x`       | `number` | X position (left edge) |
| `y`       | `number` | Y position (top edge)  |
| `w`       | `number` | Width in pixels        |
| `h`       | `number` | Height in pixels       |
| `width`   | `number` | Stroke width in pixels |
| `color`   | `string` | Hex color              |

### `stroke_circle`

Stroke a circle outline.

| Parameter | Type     | Description            |
| --------- | -------- | ---------------------- |
| `cx`      | `number` | Center X               |
| `cy`      | `number` | Center Y               |
| `radius`  | `number` | Radius in pixels       |
| `width`   | `number` | Stroke width in pixels |
| `color`   | `string` | Hex color              |

### `line`

Draw a line between two points.

| Parameter | Type     | Description          |
| --------- | -------- | -------------------- |
| `x1`      | `number` | Start X              |
| `y1`      | `number` | Start Y              |
| `x2`      | `number` | End X                |
| `y2`      | `number` | End Y                |
| `width`   | `number` | Line width in pixels |
| `color`   | `string` | Hex color            |

### `draw_text`

Render text at a position on the canvas.

| Parameter   | Type     | Description              |
| ----------- | -------- | ------------------------ |
| `text`      | `string` | Text content to render   |
| `x`         | `number` | X position               |
| `y`         | `number` | Y position (top of text) |
| `color`     | `string` | Hex color                |
| `font_size` | `number` | Font size in pixels      |

### `draw_text_centered`

Render text vertically centered at a Y position.

| Parameter   | Type     | Description                        |
| ----------- | -------- | ---------------------------------- |
| `text`      | `string` | Text content to render             |
| `x`         | `number` | X position                         |
| `y_center`  | `number` | Y position to vertically center on |
| `color`     | `string` | Hex color                          |
| `font_size` | `number` | Font size in pixels                |

---

## Memory Budget

| Struct        | Size   | Comptime Assert | Location          |
| ------------- | ------ | --------------- | ----------------- |
| `DrawCommand` | ≤64B   | `<= 64`         | Array in AiCanvas |
| `TextPool`    | ~17KB  | `< 20KB`        | Field in AiCanvas |
| `AiCanvas`    | ~280KB | `< 300KB`       | Global `var`      |

**Native:** ~840KB total (3 × `AiCanvas` for triple-buffering).
**WASM:** ~280KB total (single buffer, no threads).

---

## Coordinate System

- **Origin:** Top-left corner of the canvas
- **X:** Increases rightward
- **Y:** Increases downward
- **Units:** Pixels (f32)

Default canvas size: 800×600.

---

## Batching Protocol

Commands accumulate in the write buffer until a batch delimiter is received:

- **Empty line** on stdin → commit current batch, start a new one
- **EOF** → commit final batch

The renderer always displays the most recently committed batch. If no
batch has been committed, the canvas shows the default background.

Commands within a batch are replayed in order — later commands draw on
top of earlier ones. `set_background` should typically be the first
command in a batch (it fills the entire canvas).

---

## File Map

```
src/ai/
├── ai.md               # This file — API reference
├── mod.zig             # Public exports
├── draw_command.zig    # DrawCommand tagged union (11 variants)
├── text_pool.zig       # TextPool fixed-capacity string arena
├── ai_canvas.zig       # AiCanvas replay engine
├── json_parser.zig     # JSON line → DrawCommand parser
└── schema.zig          # Comptime tool schema generation
```
