# AI Module — API Reference

> `const ai = @import("gooey").ai;`

LLM-driven canvas drawing. An external process sends JSON commands on stdin,
Gooey parses them into a fixed-capacity command buffer, and a comptime paint
callback replays them into `DrawContext` each frame. Zero allocation after init.

Color fields accept **hex strings** (`"FF6B35"`) or **semantic theme tokens**
(`"primary"`, `"surface"`, `"text"`). Theme tokens resolve against the active
`Theme` at replay time — AI-generated drawings automatically adapt to
light/dark mode and custom themes without re-parsing commands.

**Design Doc:** [AI_NATIVE.md](../../docs/AI_NATIVE.md)
**Implementation Plan:** [AI_NATIVE_IMPL.md](../../docs/AI_NATIVE_IMPL.md)

---

## Quick Start

Pipe JSON-lines into the example app:

```sh
echo '{"tool":"set_background","color":"bg"}
{"tool":"fill_rect","x":200,"y":250,"w":200,"h":150,"color":"surface"}
{"tool":"fill_triangle","x1":180,"y1":250,"x2":300,"y2":120,"x3":420,"y3":250,"color":"danger"}
{"tool":"draw_text","text":"Home","x":260,"y":410,"color":"text","font_size":20}
' | zig-out/bin/ai-canvas
```

Hex colors still work — mix and match freely:

```sh
echo '{"tool":"set_background","color":"bg"}
{"tool":"fill_rect","x":200,"y":250,"w":200,"h":150,"color":"8B4513"}
{"tool":"fill_circle","cx":250,"cy":300,"radius":20,"color":"primary"}
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
| `ThemeColor`          | `union(enum)`   | `theme_color.zig`  | Literal hex color or semantic theme token        |
| `SemanticToken`       | `enum(u8)`      | `theme_color.zig`  | 14 semantic color slots mirroring `Theme` fields |
| `TextPool`            | `struct`        | `text_pool.zig`    | Fixed-capacity string arena for text commands    |
| `parseCommand`        | `fn`            | `json_parser.zig`  | JSON line → `DrawCommand`                        |
| `tool_schema`         | `[]const u8`    | `schema.zig`       | Comptime JSON tool schema string literal         |
| `semantic_token_list` | `[]const u8`    | `theme_color.zig`  | Comptime comma-separated list of token names     |
| `MAX_DRAW_COMMANDS`   | `usize` (4096)  | `draw_command.zig` | Hard cap on commands per batch                   |
| `MAX_TEXT_POOL_SIZE`  | `usize` (16384) | `text_pool.zig`    | Total byte capacity for pooled strings           |
| `MAX_TEXT_ENTRIES`    | `usize` (256)   | `text_pool.zig`    | Maximum distinct string entries                  |
| `MAX_TEXT_ENTRY_SIZE` | `usize` (512)   | `text_pool.zig`    | Maximum bytes per single string entry            |
| `MAX_JSON_LINE_SIZE`  | `usize` (4096)  | `json_parser.zig`  | Maximum bytes per JSON input line                |
| `TOOL_COUNT`          | `usize` (11)    | `schema.zig`       | Number of tools in the schema                    |

---

## ThemeColor

A color value that is either a concrete RGBA literal or a semantic reference
into the active theme. Replaces raw `Color` in `DrawCommand` variant structs.

At replay time, literals pass through unchanged. Tokens resolve against
whichever `Theme` is active — switch themes and the canvas redraws
automatically with coherent colors, no re-parsing needed.

### Construction

```
fn fromLiteral(color: Color) ThemeColor     // Wrap a concrete RGBA color
fn fromToken(token: SemanticToken) ThemeColor // Reference a theme slot
```

### Resolution

```
fn resolve(self: ThemeColor, theme: *const Theme) Color
```

Resolve to a concrete `Color`. Literals return as-is. Tokens look up the
corresponding field in the provided `Theme`.

### Query

```
fn isToken(self: ThemeColor) bool
fn isLiteral(self: ThemeColor) bool
fn getToken(self: ThemeColor) ?SemanticToken
fn getLiteral(self: ThemeColor) ?Color
```

---

## SemanticToken

Enum of 14 semantic color slots that mirror `Theme` struct fields 1:1.
The variant names match the exact strings the LLM sends in JSON.

### Variants

| Token          | Theme Field          | Category   | Description                          |
| -------------- | -------------------- | ---------- | ------------------------------------ |
| `bg`           | `theme.bg`           | Background | Page/app background — the base layer |
| `surface`      | `theme.surface`      | Background | Card/panel backgrounds               |
| `overlay`      | `theme.overlay`      | Background | Dropdowns, tooltips, modals          |
| `primary`      | `theme.primary`      | Accent     | Primary actions, links, focus        |
| `secondary`    | `theme.secondary`    | Accent     | Secondary actions, less emphasis     |
| `accent`       | `theme.accent`       | Accent     | Highlights, badges, decorative       |
| `success`      | `theme.success`      | Accent     | Positive feedback, success states    |
| `warning`      | `theme.warning`      | Accent     | Caution, warnings                    |
| `danger`       | `theme.danger`       | Accent     | Destructive actions, errors          |
| `text`         | `theme.text`         | Text       | Primary text — headings, body        |
| `subtext`      | `theme.subtext`      | Text       | Secondary text — subtitles           |
| `muted`        | `theme.muted`        | Text       | Disabled states, placeholders        |
| `border`       | `theme.border`       | Border     | Default borders — inputs, cards      |
| `border_focus` | `theme.border_focus` | Border     | Focused input borders                |

### Methods

```
fn fromString(str: []const u8) ?SemanticToken  // Parse "primary" → .primary
fn resolve(self: SemanticToken, theme: *const Theme) Color
fn name(self: SemanticToken) []const u8         // .primary → "primary"
```

### Single Source of Truth Chain

```
Theme struct (14 color fields)
  ↓ mirrors
SemanticToken enum (14 variants, same names)
  ↓ reflected at comptime
tool_schema JSON (color description lists all 14 token names)
  ↓ sent to
LLM (sees tokens in tool definitions)
  ↓ sends back
"color": "primary" → parser → ThemeColor{ .token = .primary }
  ↓ at replay time
ThemeColor.resolve(theme) → concrete Color from active theme
```

Add a field to `Theme` + a variant to `SemanticToken` → everything else
updates automatically. The schema, the parser (via `std.meta.stringToEnum`),
and the resolver (exhaustive switch) cannot drift.

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
fn replay(self: *const AiCanvas, ctx: *ui.DrawContext, theme: *const Theme) void
```

Replay all buffered commands into a `DrawContext`. Called once per frame
from the comptime paint callback. Fills background first, then replays
every command via exhaustive switch.

The `theme` parameter resolves `ThemeColor` tokens to concrete colors at
render time. Pass `&Theme.dark`, `&Theme.light`, or a custom `Theme`.
Changing the theme pointer automatically re-colors the entire canvas on
the next frame — no re-parsing needed.

### Fields

| Field              | Type                | Default            | Description                                      |
| ------------------ | ------------------- | ------------------ | ------------------------------------------------ |
| `commands`         | `[4096]DrawCommand` | `undefined`        | Command buffer (only `[0..command_count]` valid) |
| `command_count`    | `usize`             | `0`                | Number of valid commands                         |
| `texts`            | `TextPool`          | `.{}`              | String arena for text commands                   |
| `canvas_width`     | `f32`               | `800`              | Logical canvas width                             |
| `canvas_height`    | `f32`               | `600`              | Logical canvas height                            |
| `background_color` | `ThemeColor`        | literal `0x1a1a2e` | Default background (supports tokens too)         |

---

## DrawCommand

Tagged union with 11 variants mapping 1:1 to `DrawContext` methods.
Each variant is a struct with named fields. Fits in a single cache line (≤64 bytes).

All `color` fields are `ThemeColor` — they accept both literal hex colors
and semantic theme tokens. Resolution happens at replay time.

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

All coordinate fields are `f32`. All `color` fields are `ThemeColor`.
Text commands use `text_idx: u16` (index into `TextPool`), not string slices.

### Helper Methods

```
fn hasTextRef(self: DrawCommand) bool       // true for draw_text, draw_text_centered
fn textIdx(self: DrawCommand) ?u16          // text pool index, or null
fn getColor(self: DrawCommand) ThemeColor   // ThemeColor for any variant
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

**Color parsing:** The `"color"` field is tried as a semantic token first
(via `SemanticToken.fromString`). If it matches a token name like `"primary"`,
the command stores `ThemeColor{ .token = .primary }`. Otherwise, hex parsing
kicks in and stores `ThemeColor{ .literal = <Color> }`. There is no ambiguity —
token names are lowercase alpha + underscore; hex strings are alphanumeric
with an optional `#` prefix.

Returns `null` on: malformed JSON, unknown tool, missing fields, wrong types.

### JSON Format

One JSON object per line with a `"tool"` discriminator:

```json
{"tool":"fill_rect","x":10,"y":20,"w":100,"h":50,"color":"FF6B35"}
{"tool":"fill_rect","x":10,"y":20,"w":100,"h":50,"color":"primary"}
{"tool":"draw_text","text":"Hello","x":10,"y":20,"color":"text","font_size":16}
{"tool":"set_background","color":"bg"}
```

**Color format:** Either a **hex string** or a **semantic theme token**.

- **Hex:** With or without `#` prefix. Supports `RGB`, `RGBA`, `RRGGBB`,
  and `RRGGBBAA` formats. Examples: `"FF6B35"`, `"#FF6B35"`, `"FF6B35CC"`.

- **Theme token:** One of the 14 semantic names: `bg`, `surface`, `overlay`,
  `primary`, `secondary`, `accent`, `success`, `warning`, `danger`, `text`,
  `subtext`, `muted`, `border`, `border_focus`. These resolve against the
  active theme at replay time.

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

**Color descriptions** are generated at comptime from the `SemanticToken`
enum. Each color parameter's description reads:

> Hex color (e.g. 'FF6B35') or theme token: bg, surface, overlay, primary,
> secondary, accent, success, warning, danger, text, subtext, muted, border,
> border_focus

If a new token is added to `SemanticToken`, the description updates
automatically in every tool's color parameter.

---

## semantic_token_list

```
const tokens: []const u8 = ai.semantic_token_list;
// "bg, surface, overlay, primary, secondary, accent, success, warning, danger, text, subtext, muted, border, border_focus"
```

Comptime-generated comma-separated string of all semantic token names.
Derived from `SemanticToken` enum fields. Useful for building LLM prompts
or documentation that enumerates the valid theme color names.

---

## Tool Reference

All 11 tools with their JSON parameters:

### `set_background`

Fill the entire canvas with a background color. Use as the first command in
a batch to clear the slate and start a fresh scene.

| Parameter | Type     | Description              |
| --------- | -------- | ------------------------ |
| `color`   | `string` | Hex color or theme token |

### `fill_rect`

Fill a rectangle with a solid color.

| Parameter | Type     | Description              |
| --------- | -------- | ------------------------ |
| `x`       | `number` | X position (left edge)   |
| `y`       | `number` | Y position (top edge)    |
| `w`       | `number` | Width in pixels          |
| `h`       | `number` | Height in pixels         |
| `color`   | `string` | Hex color or theme token |

### `fill_rounded_rect`

Fill a rounded rectangle with a solid color.

| Parameter | Type     | Description              |
| --------- | -------- | ------------------------ |
| `x`       | `number` | X position (left edge)   |
| `y`       | `number` | Y position (top edge)    |
| `w`       | `number` | Width in pixels          |
| `h`       | `number` | Height in pixels         |
| `radius`  | `number` | Corner radius in pixels  |
| `color`   | `string` | Hex color or theme token |

### `fill_circle`

Fill a circle with a solid color.

| Parameter | Type     | Description              |
| --------- | -------- | ------------------------ |
| `cx`      | `number` | Center X                 |
| `cy`      | `number` | Center Y                 |
| `radius`  | `number` | Radius in pixels         |
| `color`   | `string` | Hex color or theme token |

### `fill_ellipse`

Fill an ellipse with a solid color.

| Parameter | Type     | Description              |
| --------- | -------- | ------------------------ |
| `cx`      | `number` | Center X                 |
| `cy`      | `number` | Center Y                 |
| `rx`      | `number` | Horizontal radius        |
| `ry`      | `number` | Vertical radius          |
| `color`   | `string` | Hex color or theme token |

### `fill_triangle`

Fill a triangle defined by three vertices.

| Parameter | Type     | Description              |
| --------- | -------- | ------------------------ |
| `x1`      | `number` | First point X            |
| `y1`      | `number` | First point Y            |
| `x2`      | `number` | Second point X           |
| `y2`      | `number` | Second point Y           |
| `x3`      | `number` | Third point X            |
| `y3`      | `number` | Third point Y            |
| `color`   | `string` | Hex color or theme token |

### `stroke_rect`

Stroke a rectangle outline.

| Parameter | Type     | Description              |
| --------- | -------- | ------------------------ |
| `x`       | `number` | X position (left edge)   |
| `y`       | `number` | Y position (top edge)    |
| `w`       | `number` | Width in pixels          |
| `h`       | `number` | Height in pixels         |
| `width`   | `number` | Stroke width in pixels   |
| `color`   | `string` | Hex color or theme token |

### `stroke_circle`

Stroke a circle outline.

| Parameter | Type     | Description              |
| --------- | -------- | ------------------------ |
| `cx`      | `number` | Center X                 |
| `cy`      | `number` | Center Y                 |
| `radius`  | `number` | Radius in pixels         |
| `width`   | `number` | Stroke width in pixels   |
| `color`   | `string` | Hex color or theme token |

### `line`

Draw a line between two points.

| Parameter | Type     | Description              |
| --------- | -------- | ------------------------ |
| `x1`      | `number` | Start X                  |
| `y1`      | `number` | Start Y                  |
| `x2`      | `number` | End X                    |
| `y2`      | `number` | End Y                    |
| `width`   | `number` | Line width in pixels     |
| `color`   | `string` | Hex color or theme token |

### `draw_text`

Render text at a position on the canvas.

| Parameter   | Type     | Description              |
| ----------- | -------- | ------------------------ |
| `text`      | `string` | Text content to render   |
| `x`         | `number` | X position               |
| `y`         | `number` | Y position (top of text) |
| `color`     | `string` | Hex color or theme token |
| `font_size` | `number` | Font size in pixels      |

### `draw_text_centered`

Render text vertically centered at a Y position.

| Parameter   | Type     | Description                        |
| ----------- | -------- | ---------------------------------- |
| `text`      | `string` | Text content to render             |
| `x`         | `number` | X position                         |
| `y_center`  | `number` | Y position to vertically center on |
| `color`     | `string` | Hex color or theme token           |
| `font_size` | `number` | Font size in pixels                |

---

## Memory Budget

| Struct          | Size   | Comptime Assert | Location                          |
| --------------- | ------ | --------------- | --------------------------------- |
| `DrawCommand`   | ≤64B   | `<= 64`         | Array in AiCanvas                 |
| `ThemeColor`    | ≤20B   | `<= 20`         | Field in each DrawCommand variant |
| `SemanticToken` | 1B     | `== 1`          | Inside ThemeColor `.token`        |
| `TextPool`      | ~17KB  | `< 20KB`        | Field in AiCanvas                 |
| `AiCanvas`      | ~280KB | `< 300KB`       | Global `var`                      |

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

## Theme Integration

### How the LLM Discovers Tokens

The comptime tool schema includes all 14 token names in every color
parameter's description. When you pass `tool_schema` as the `tools`
array to an LLM API, the model sees:

```
"color": {
  "type": "string",
  "description": "Hex color (e.g. 'FF6B35') or theme token: bg, surface, overlay, primary, secondary, accent, success, warning, danger, text, subtext, muted, border, border_focus"
}
```

The LLM can choose between raw hex for custom/artistic colors and semantic
tokens for theme-coherent UI elements. Both work in the same field.

### Light/Dark Mode Adaptation

Same commands, different themes:

```json
{"tool":"set_background","color":"bg"}
{"tool":"fill_rounded_rect","x":50,"y":50,"w":300,"h":200,"radius":16,"color":"surface"}
{"tool":"draw_text","text":"Hello","x":70,"y":80,"color":"text","font_size":18}
{"tool":"fill_rect","x":70,"y":160,"w":100,"h":40,"color":"primary"}
```

With `&Theme.dark`: dark background, elevated dark surface, light text, blue button.
With `&Theme.light`: light background, slightly darker surface, dark text, blue button.

No re-parsing — just pass a different `Theme` pointer to `replay()`.

### Mixing Hex and Tokens

The AI can freely mix literal and semantic colors in a single batch:

```json
{"tool":"set_background","color":"bg"}
{"tool":"fill_rect","x":100,"y":100,"w":200,"h":150,"color":"FF6B35"}
{"tool":"stroke_rect","x":100,"y":100,"w":200,"h":150,"width":2,"color":"border"}
{"tool":"draw_text","text":"Custom Orange","x":120,"y":130,"color":"text","font_size":14}
```

The orange rectangle uses a literal hex color; the border and text adapt
to the theme.

---

## File Map

```
src/ai/
├── ai.md               # This file — API reference
├── mod.zig             # Public exports
├── draw_command.zig    # DrawCommand tagged union (11 variants)
├── theme_color.zig     # ThemeColor union + SemanticToken enum
├── text_pool.zig       # TextPool fixed-capacity string arena
├── ai_canvas.zig       # AiCanvas replay engine
├── json_parser.zig     # JSON line → DrawCommand parser
└── schema.zig          # Comptime tool schema generation
```
