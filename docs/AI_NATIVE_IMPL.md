# AI Native Canvas — Implementation Plan

> High-level implementation guide for exposing Gooey's drawing primitives as AI-callable tools.

**Status:** v1 Complete  
**Design Doc:** [AI_NATIVE.md](./AI_NATIVE.md)  
**Last Updated:** 2026-02-10

---

## Table of Contents

1. [Current State](#current-state)
2. [Existing Infrastructure](#existing-infrastructure)
3. [Implementation Phases](#implementation-phases)
4. [Phase 0: Spike](#phase-0-spike)
5. [Phase 1: Core Types](#phase-1-core-types)
6. [Phase 2: Replay Engine](#phase-2-replay-engine)
7. [Phase 3: JSON Parser](#phase-3-json-parser)
8. [Phase 4: Schema Generation](#phase-4-schema-generation)
9. [Phase 5: Example App + Stdin Transport](#phase-5-example-app--stdin-transport)
10. [File Map](#file-map)
11. [Struct Size Budget](#struct-size-budget)
12. [Testing Strategy](#testing-strategy)
13. [Risk Areas](#risk-areas)
14. [What We Do NOT Touch](#what-we-do-not-touch)

---

## Current State

**All phases (0–5) are complete.** The `src/ai/` module provides the full AI canvas pipeline: `DrawCommand` tagged union (11 variants), `TextPool` fixed-capacity string arena, `AiCanvas` replay engine, `parseCommand` JSON parser, and `tool_schema` comptime schema generation. The example app (`src/examples/ai_canvas.zig`) wires everything together with a triple-buffered stdin transport on native and a single-buffer fallback on WASM. 70 tests across 6 files. All comptime size assertions pass.

**What exists:**

- `src/ai/draw_command.zig` — `DrawCommand` tagged union, 11 variants mapping 1:1 to `DrawContext` methods
- `src/ai/text_pool.zig` — `TextPool` fixed-capacity string arena (16KB buffer, 256 entries)
- `src/ai/ai_canvas.zig` — `AiCanvas` replay engine: mutation API + replay API + query API
- `src/ai/json_parser.zig` — `parseCommand`: JSON line → `DrawCommand` via `std.json.parseFromSlice`
- `src/ai/schema.zig` — `tool_schema`: comptime-generated JSON tool schema from `DrawCommand` type
- `src/ai/mod.zig` — module entry point exporting all public types, constants, and functions
- `src/examples/ai_canvas.zig` — example app: triple-buffered stdin transport, status bar, paint callback
- `src/root.zig` — `pub const ai = @import("ai/mod.zig")` wired into Module Namespaces
- `build.zig` — `ai-canvas` example entry

---

## Existing Infrastructure

These are the pieces already in the codebase that the AI canvas builds on top of. None of them require modification.

### DrawContext (`src/ui/canvas.zig`)

The runtime drawing surface. Every method we need is already implemented:

| Method              | Signature                                   | Notes                                    |
| ------------------- | ------------------------------------------- | ---------------------------------------- |
| `fillRect`          | `(x, y, w, h, Color) void`                  | Optimized quad rendering                 |
| `fillRoundedRect`   | `(x, y, w, h, radius, Color) void`          | Corner radius support                    |
| `fillCircle`        | `(cx, cy, r, Color) void`                   | Cubic Bézier approximation               |
| `fillEllipse`       | `(cx, cy, rx, ry, Color) void`              | —                                        |
| `fillTriangle`      | `(x1, y1, x2, y2, x3, y3, Color) void`      | Direct triangle insertion, no Path alloc |
| `strokeRect`        | `(x, y, w, h, Color, stroke_width) void`    | Note: color before width                 |
| `strokeCircle`      | `(cx, cy, r, stroke_width, Color) void`     | Note: width before color                 |
| `line`              | `(x1, y1, x2, y2, line_width, Color) void`  | Auto-detects axis-aligned                |
| `drawText`          | `(text, x, y, Color, font_size) f32`        | Returns rendered width                   |
| `drawTextVCentered` | `(text, x, y_center, Color, font_size) f32` | Vertically centered                      |
| `measureText`       | `(text, font_size) f32`                     | Read-only, future query API              |

**Watch out:** Parameter order is inconsistent between methods (e.g., `strokeRect` takes `color, width` but `strokeCircle` takes `width, color`). The `AiCanvas.replay` function must map correctly. The design doc already accounts for this.

### Color (`src/core/geometry.zig`)

- `Color.hex(value: u32)` — accepts `0xRRGGBB` or `0xRRGGBBAA` integer literals
- `Color.fromHex(str: []const u8)` — parses string hex: `"#RGB"`, `"#RGBA"`, `"#RRGGBB"`, `"#RRGGBBAA"`, with or without `#` prefix

`Color.fromHex` is exactly what the JSON parser needs. No new color parsing code required.

### Canvas Element (`src/ui/canvas.zig`)

```
pub fn canvas(w: f32, h: f32, paint: *const fn (*DrawContext) void) Canvas
```

Takes a **comptime** function pointer. The AI integration uses exactly one of these — the `paintAiCanvas` function that calls `AiCanvas.replay`. This is the comptime/runtime bridge.

### Canvas Drawing Example (`src/examples/canvas_drawing.zig`)

Reference pattern for the example app. Shows:

- Global `var state = AppState{}`
- Comptime paint callback reading runtime state
- `cx.command()` for handlers that need `*Gooey` access
- Coordinate conversion from window space to canvas-local space

### Charts Sub-Module (`charts/`)

Precedent for an optional module that depends on `DrawContext` but lives outside the core framework. The AI module follows the same pattern but lives inside `src/ai/` since it's tightly coupled to core types.

### App Architecture (`src/app.zig`, `src/cx.zig`)

- `App(State, *state, render, config)` — comptime generic entry point
- `Cx` — unified rendering context, provides `windowSize()`, `state()`, `render()`, `update()`, `command()`
- Global `var state` pattern for WASM compatibility (avoids stack allocation of large structs)

---

## Implementation Phases

```
Phase 0: Spike               ✅ COMPLETE — bridge validated
  └── Minimal example with canvas + replay

Phase 1: Core Types          ✅ COMPLETE — DrawCommand (11 variants) + TextPool
  ├── DrawCommand
  └── TextPool

Phase 2: Replay Engine       ✅ COMPLETE — AiCanvas (mutation + replay API)
  └── AiCanvas

Phase 3: JSON Parser         ✅ COMPLETE — parseCommand (std.json → DrawCommand)
  └── json_parser

Phase 4: Schema Generation   ✅ COMPLETE — tool_schema (comptime JSON from DrawCommand)
  └── schema

Phase 5: Example App         ✅ COMPLETE — ai_canvas.zig + stdin triple-buffered transport
  ├── ai_canvas.zig example
  └── Stdin transport (native)
```

Phase 0 validates the comptime/runtime bridge before building infrastructure. Phases 1 through 4 are independently testable. Phase 5 is the integration.

---

## Phase 0: Spike ✅

**Status:** Complete  
**Artifact:** `src/examples/ai_canvas_spike.zig`

**Goal:** Validate that the comptime paint callback → runtime command buffer → `DrawContext` bridge actually works, end-to-end, before building any infrastructure.

**What was built:**

1. A minimal example app (`ai_canvas_spike.zig`) with a `canvas()` element and a comptime paint callback
2. A hardcoded dashboard scene: title bar, stat cards, memory bar, status indicators, a line chart with grid, data point dots, axis labels, and a stroke-rect border
3. Separate arrays for rects, circles, lines, and text commands, replayed through `DrawContext` in the paint callback
4. A flat `u8` text buffer with offset/length pairs — validates the text pooling pattern

**What this proved:**

- The `canvas(w, h, paintFn)` → `paintFn(ctx: *DrawContext)` → `ctx.fillRect(...)` chain works
- A global `var state` can hold data that the paint callback reads at runtime
- The pattern from `canvas_drawing.zig` generalizes to a command-buffer replay approach
- All required `DrawContext` methods work through the replay loop: `fillRect`, `fillRoundedRect`, `strokeRect`, `fillCircle`, `strokeCircle`, `line`, `drawText`
- Text pooling via flat buffer + offset/length is viable

**Decision:** Keep as scratch reference. Proceed to Phase 1.

---

## Phase 1: Core Types ✅

### `src/ai/draw_command.zig`

**Status:** Complete

`DrawCommand` tagged union with 11 variants mapping 1:1 to `DrawContext` methods.

**What was built:**

- Import `Color` via relative path `../core/geometry.zig` (same pattern as other internal modules)
- Each variant is a named pub struct with fields matching `DrawContext` method parameters
- Text commands use `text_idx: u16` (index into `TextPool`), not string slices
- Helper methods: `hasTextRef()`, `textIdx()`, `getColor()` — exhaustive switches over all variants
- `MAX_DRAW_COMMANDS = 4096`

**Comptime assertions (per CLAUDE.md):**

- `@sizeOf(DrawCommand) <= 64` — cache-friendly replay
- Variant count == 11 — catches accidental additions without schema update
- `@alignOf(DrawCommand) <= 8` — reasonable array packing

**Tests:** 7 tests covering size, variant count, roundtrip, text ref detection, getColor exhaustiveness

### `src/ai/text_pool.zig`

**Status:** Complete

Fixed-capacity string arena. Push strings in, get them back by `u16` index.

**What was built:**

- `MAX_TEXT_POOL_SIZE = 16_384` (16KB), `MAX_TEXT_ENTRIES = 256`, `MAX_TEXT_ENTRY_SIZE = 512`
- `push(text) ?u16` — returns null if full (fail-fast, don't crash)
- `get(idx) []const u8` — assert idx < count
- `clear()` — reset count and used to 0
- Capacity introspection: `entryCount()`, `bytesUsed()`, `bytesRemaining()`, `entriesRemaining()`

**Comptime assertions:**

- `@sizeOf(TextPool) < 20 * 1024`
- Pool/entry sizes fit in u16 offset/length fields

**Tests:** 8 tests covering roundtrip, entry capacity, byte capacity, clear/reuse, contiguous indices, capacity helpers, max entry size, binary content preservation

---

## Phase 2: Replay Engine ✅

### `src/ai/ai_canvas.zig`

Owns the command buffer and text pool. Provides mutation API (for the parser) and replay API (for the paint callback).

**Struct fields:**

- `commands: [MAX_DRAW_COMMANDS]DrawCommand` — undefined init (no zero-fill needed)
- `command_count: usize = 0`
- `texts: TextPool = .{}`
- `canvas_width: f32 = 800`
- `canvas_height: f32 = 600`
- `background_color: Color = Color.hex(0x1a1a2e)`

**Mutation API:**

- `pushCommand(cmd: DrawCommand) bool` — bounds check, returns `false` on overflow (handles the negative space per CLAUDE.md rule #11). In debug builds, also asserts. Callers can log dropped commands.
- `pushText(text: []const u8) ?u16` — delegates to `TextPool.push`
- `clearAll() void` — reset command_count, clear text pool

**Replay API:**

- `replay(ctx: *DrawContext) void` — the core function. Iterates `commands[0..command_count]`, switches on each variant, calls the corresponding `DrawContext` method.

**Replay parameter mapping (watch the inconsistencies):**

| DrawCommand variant   | DrawContext call                                             | Parameter order notes |
| --------------------- | ------------------------------------------------------------ | --------------------- |
| `.fill_rect`          | `ctx.fillRect(x, y, w, h, color)`                            | Straightforward       |
| `.fill_rounded_rect`  | `ctx.fillRoundedRect(x, y, w, h, radius, color)`             | Straightforward       |
| `.fill_circle`        | `ctx.fillCircle(cx, cy, radius, color)`                      | Straightforward       |
| `.fill_ellipse`       | `ctx.fillEllipse(cx, cy, rx, ry, color)`                     | Straightforward       |
| `.fill_triangle`      | `ctx.fillTriangle(x1, y1, x2, y2, x3, y3, color)`            | Straightforward       |
| `.stroke_rect`        | `ctx.strokeRect(x, y, w, h, color, width)`                   | **color then width**  |
| `.stroke_circle`      | `ctx.strokeCircle(cx, cy, radius, width, color)`             | **width then color**  |
| `.line`               | `ctx.line(x1, y1, x2, y2, width, color)`                     | Straightforward       |
| `.draw_text`          | `ctx.drawText(text, x, y, color, font_size)`                 | Lookup text from pool |
| `.draw_text_centered` | `ctx.drawTextVCentered(text, x, y_center, color, font_size)` | Lookup text from pool |
| `.set_background`     | `ctx.fillRect(0, 0, w, h, color)`                            | Full-canvas fill      |

**Assertions:**

- `replay`: assert `command_count <= MAX_DRAW_COMMANDS` at entry
- `replay`: assert text_idx validity before pool lookup
- Comptime: `@sizeOf(AiCanvas) < 300 * 1024` (budget ~280KB: commands ~260KB + text ~17KB)

**WASM note:** `AiCanvas` is ~280KB. Must live in global `var state`, never on the stack (CLAUDE.md rule #14: 50KB stack threshold). On WASM, only a single `AiCanvas` buffer is needed (single-threaded, no reader/writer contention). The triple-buffer pattern is native-only — see Phase 5.

---

## Phase 3: JSON Parser ✅

### `src/ai/json_parser.zig`

Parses a single JSON line into a `DrawCommand` (plus optional text pool mutation).

**Input format** (one JSON object per line):

```
{"tool":"fill_rect","x":10,"y":20,"w":100,"h":50,"color":"FF6B35"}
```

**Approach — `std.json.parseFromSlice` into `std.json.Value`, then manual field extraction:**

`std.json` is part of Zig's standard library — using it is no different from using `std.mem` or `std.debug`, and does not violate CLAUDE.md rule #12 (which targets _external_ packages, not `std`). Parse each JSON line into a `std.json.Value` (dynamic), then manually extract fields by tool name. This avoids needing the internal struct layout to match JSON field names exactly and handles the `text` → `text_idx` asymmetry cleanly.

**API:**

- `parseCommand(json_line: []const u8, texts: *TextPool) ?DrawCommand`
  - Returns null on malformed input (fail-fast, log, don't crash)
  - For `draw_text` / `draw_text_centered`: extracts `"text"` string field, pushes into `TextPool`, stores resulting `text_idx` in the command
  - For `"color"` fields: calls `Color.fromHex(color_str)`

**Constants:**

- `MAX_JSON_LINE_SIZE = 4096`

**Assertions:**

- Assert JSON line length <= `MAX_JSON_LINE_SIZE`
- Assert tool name matches a known variant (log unknown tools, return null)

**Color parsing flow:**

```
JSON "color": "FF6B35"  →  Color.fromHex("FF6B35")  →  Color{ .r=1.0, .g=0.42, .b=0.21, .a=1.0 }
JSON "color": "#FF6B35" →  Color.fromHex("#FF6B35")  →  same result (# stripped internally)
```

No new code needed — `Color.fromHex` already handles both formats, including `#RRGGBBAA` for alpha.

---

## Phase 4: Schema Generation ✅

### `src/ai/schema.zig`

Comptime function that generates the JSON tool schema string from the `DrawCommand` type.

**Approach:**

- `fn generateToolSchema(comptime Command: type) []const u8`
- Iterate `std.meta.fields(Command)` at comptime
- For each variant, reflect over the payload struct's fields
- Map Zig types to JSON schema types: `f32` → `"number"`, `u16` → `"number"`, `Color` → `"string"`
- Special case: `text_idx: u16` → emit as `"text": { "type": "string" }` in the schema

**Output:** A comptime `[]const u8` string literal containing the full JSON tool array. Zero runtime cost, zero allocation.

**The `text_idx` asymmetry (schema aliasing):** This is the one place where internal representation diverges from external schema. The schema generator must recognize fields named `text_idx` and emit them as `"text"` with type `"string"`. The JSON parser handles the reverse mapping. We call this pattern "schema aliasing" — the internal field name (`text_idx`) is aliased to an external name (`text`) with a different type (`string` vs `u16`). Both the schema generator and the JSON parser must agree on this alias.

**Assertions:**

- Comptime assert the generated schema is valid JSON (parse it back at comptime)
- Comptime assert tool count matches `std.meta.fields(DrawCommand).len`

---

## Phase 5: Example App + Stdin Transport ✅

### `src/examples/ai_canvas.zig`

The integration example. Minimal wiring:

**Structure:**

```
Global state:
  var state = AppState{}

  // Native: three buffers for lock-free triple-buffering
  var buffers: [3]AiCanvas = .{ .{}, .{}, .{} }
  var write_idx: u8 = 0     // writer thread owns this buffer
  var ready_idx: u8 = 1     // last committed batch (atomic — the mailbox)
  var display_idx: u8 = 2   // renderer owns this buffer

  // WASM: single buffer (single-threaded, no contention)
  var ai_canvas: AiCanvas = .{}

Comptime surface (4 lines):
  fn paintAiCanvas(ctx: *DrawContext) → buffers[display_idx].replay(ctx)

  fn render(cx: *Cx) → acquire latest ready batch, then cx.render(ui.canvas(..., paintAiCanvas))

Runtime surface:
  Background thread reads stdin line-by-line (native)
  Each line → json_parser.parseCommand → write buffer pushCommand
  Empty line → commit batch (atomic swap write_idx ↔ ready_idx)
```

**Batch delimiter:** An empty line between batches signals "batch complete." This is natural for JSON-lines protocols and keeps the tool namespace clean. The writer commits on empty line; the renderer acquires on each frame.

**Native stdin transport:**

- Spawn a thread (`std.Thread`) that reads stdin via `std.io.getStdIn().reader()`
- Read line-by-line into a fixed `[MAX_JSON_LINE_SIZE]u8` buffer
- Non-empty line: parse and push command onto write buffer
- Empty line: commit the batch (atomic swap `write_idx` ↔ `ready_idx`, then clear new write buffer)

**Triple-buffering for thread safety (native only):**

Three `AiCanvas` instances live in global state. Each buffer is owned by exactly one role at any time — writer, renderer, or mailbox ("ready"). Only the `ready_idx` is shared, accessed via atomic swap. Writer and renderer never touch the same buffer.

```
// Global state — three buffers, ~840KB total in static memory
var buffers: [3]AiCanvas = .{ .{}, .{}, .{} };
var write_idx: u8 = 0;       // Writer thread owns this — not shared
var ready_idx: u8 = 1;       // Mailbox — accessed via @atomicRmw only
var display_idx: u8 = 2;     // Render thread owns this — not shared

// === Writer thread ===
// Push commands into the write buffer:
buffers[write_idx].pushCommand(cmd);

// On batch boundary (empty line from stdin):
// Commit: swap write buffer into the mailbox, get old mailbox to reuse
const old_ready = @atomicRmw(u8, &ready_idx, .Xchg, write_idx, .acq_rel);
write_idx = old_ready;                  // Take ownership of old ready buffer
buffers[write_idx].clearAll();          // Safe — we own it now, no race

// === Render thread (in render(), before ui.canvas()) ===
// Acquire: grab latest committed batch from the mailbox
const old_ready = @atomicRmw(u8, &ready_idx, .Xchg, display_idx, .acq_rel);
display_idx = old_ready;                // Take ownership of latest batch

// Paint callback reads from display buffer:
buffers[display_idx].replay(ctx);
```

**Why triple-buffer instead of double-buffer?**

Double-buffering has a subtle race: after the index flip, the render thread calls `clearAll()` on the new back buffer — but the writer thread may already be pushing commands into it. The window between flip and clear is a data race.

Triple-buffering eliminates this entirely:

- Writer owns `write_idx` — pushes freely, clears only buffers it owns
- Renderer owns `display_idx` — replays freely, never clears
- `ready_idx` is the mailbox — touched only via atomic swap, never written to directly
- **No fences, no mutexes, no clear-race** — each thread operates on its own buffer

If the renderer is faster than the writer (no new batch ready), it swaps display ↔ ready and gets back the same batch it just displayed. Harmless — same frame re-renders.

If the writer is faster than the renderer (multiple batches between frames), the latest batch overwrites the mailbox. The renderer always picks up the most recent complete batch. Older intermediate batches are naturally discarded.

**Why not `std.mem.swap`?** `AiCanvas` is ~280KB. `std.mem.swap` does a three-way byte copy (~840KB of memory traffic per frame). An atomic `@atomicRmw` swaps a single `u8` index — zero copies. On WASM, atomics compile to plain loads/stores (single-threaded), so they're zero-cost there too.

**WASM transport (single-buffer, no threads):**

- No threads on WASM — no triple-buffer needed
- Use a single `AiCanvas` in global state
- Exported function called from JS: `export fn pushAiCommands(json_ptr: [*]const u8, len: usize) void`
- Parse and push commands directly into the single buffer, then trigger re-render
- No race conditions possible — JS and WASM execute on the same thread

---

## File Map

```
src/ai/
├── mod.zig              # Public exports: AiCanvas, DrawCommand, TextPool, parseCommand, tool_schema
├── draw_command.zig     # DrawCommand tagged union + MAX_DRAW_COMMANDS
├── text_pool.zig        # TextPool fixed-capacity string arena
├── ai_canvas.zig        # AiCanvas state struct + replay logic
├── json_parser.zig      # JSON line → DrawCommand parser (via std.json)
└── schema.zig           # Comptime tool schema generation

src/examples/
└── ai_canvas.zig        # Example app: AI-driven canvas with stdin transport

build.zig                # MODIFIED — add one addNativeExample() call for ai-canvas example
```

### `src/ai/mod.zig` exports:

```
pub const DrawCommand = draw_command.DrawCommand;
pub const TextPool = text_pool.TextPool;
pub const AiCanvas = ai_canvas.AiCanvas;
pub const parseCommand = json_parser.parseCommand;
pub const tool_schema = schema.tool_schema;
```

### Root integration (`src/root.zig`):

Add one line in the **"Module Namespaces"** section (after the existing `pub const debug = ...` block, around line 112):

```
/// AI integration: canvas command buffer for LLM-driven drawing
pub const ai = @import("ai/mod.zig");
```

This follows the same pattern as `pub const scene = @import("scene/mod.zig")` and the other module namespace exports.

### Build integration (`build.zig`):

Add one line alongside the other `addNativeExample` calls (around line 105):

```
addNativeExample(b, mod, objc_dep.module("objc"), target, optimize, "ai-canvas", "src/examples/ai_canvas.zig", false);
```

---

## Struct Size Budget

Per CLAUDE.md rules #2 (static allocation) and #14 (WASM stack budget):

| Struct        | Estimated Size                                                        | Comptime Assert | Lives In           |
| ------------- | --------------------------------------------------------------------- | --------------- | ------------------ |
| `DrawCommand` | ~48-64 bytes (largest variant: `fill_triangle` with 7 floats + color) | `<= 64`         | Array in AiCanvas  |
| `TextPool`    | ~17KB (16KB buffer + 1KB indices)                                     | `< 20 * 1024`   | Field in AiCanvas  |
| `AiCanvas`    | ~280KB (4096 × 64B commands + 17KB text)                              | `< 300 * 1024`  | Global `var state` |

**Total global memory footprint:**

- **Native:** ~840KB (three `AiCanvas` buffers for triple-buffering) + AppState overhead
- **WASM:** ~280KB (single `AiCanvas` buffer, no triple-buffering needed)

`AiCanvas` at ~280KB is well above the 50KB WASM stack threshold → **must be global, never on the stack**. The example uses file-scope globals for the buffer(s), which is correct for both native and WASM. ~840KB of static globals on native is well within reason — it's less than 1MB and eliminates all runtime allocation and synchronization.

---

## Testing Strategy

Each phase is independently testable without a running Gooey application.

### Phase 1 Tests (`draw_command.zig`, `text_pool.zig`)

- **TextPool push/get roundtrip:** push N strings, verify get returns exact bytes
- **TextPool capacity:** push until full, verify returns null (not crash)
- **TextPool clear:** push, clear, verify count is 0, can push again
- **TextPool max entry size:** assert push of 513-byte string is rejected
- **DrawCommand size:** comptime assert `@sizeOf(DrawCommand) <= 64`
- **DrawCommand variant count:** comptime assert `std.meta.fields(DrawCommand).len == 11`

### Phase 2 Tests (`ai_canvas.zig`)

- **pushCommand/replay roundtrip:** push commands, replay into a mock DrawContext (or just verify command_count)
- **clearAll:** push, clear, verify command_count is 0
- **Overflow behavior:** push MAX_DRAW_COMMANDS + 1, verify no crash (assert + return)
- **Text command roundtrip:** pushText, pushCommand with text_idx, verify text retrieval in replay

### Phase 3 Tests (`json_parser.zig`)

- **Parse each tool type:** one test per DrawCommand variant with valid JSON
- **Color parsing:** verify `"FF6B35"` and `"#FF6B35"` both produce correct Color
- **Color with alpha:** verify `"FF6B35CC"` produces correct alpha
- **Text handling:** verify `draw_text` extracts string, pushes to TextPool, stores correct idx
- **Malformed JSON:** verify returns null, no crash
- **Unknown tool:** verify returns null, no crash
- **Missing fields:** verify returns null, no crash
- **Oversized line:** verify returns null for lines > MAX_JSON_LINE_SIZE

### Phase 4 Tests (`schema.zig`)

- **Comptime generation:** verify `tool_schema` is a non-empty string
- **Tool count in schema:** count `"name":` occurrences, assert == 11
- **Roundtrip:** parse generated schema back as JSON at comptime (validates syntax)

### Phase 5 Tests (`ai_canvas.zig` example)

- **Integration test:** pipe JSON commands to stdin, verify app doesn't crash (manual/CI)
- **House example:** reproduce the Python "draw a house" example from the design doc

---

## Risk Areas

### 1. `std.json` API Surface

The codebase currently has **zero uses** of `std.json`. `std.json` is part of Zig's standard library (not an external dependency — CLAUDE.md rule #12 does not apply), but its API has shifted across Zig versions. Pin to the Zig 0.15.2 API: `std.json.parseFromSlice` for dynamic parsing into `std.json.Value`. If the API changes in a future Zig upgrade, the fix is localized to `json_parser.zig`. The input format is flat (string/number values only), so the `std.json.Value` usage is minimal — extract `"tool"` string, then pull fields by name per tool type.

### 2. DrawContext Parameter Order Inconsistency

`strokeRect` takes `(x, y, w, h, color, stroke_width)` but `strokeCircle` takes `(cx, cy, r, stroke_width, color)`. The replay function must get this right. **Mitigation:** explicit per-variant mapping in the switch (no generic dispatch), and integration test that renders each variant.

### 3. Thread Safety for Stdin Reader (Native)

Triple-buffering eliminates the class of race conditions that plague double-buffer designs. Each thread owns its buffer exclusively — the writer never touches the display buffer, the renderer never touches the write buffer. The only shared state is `ready_idx`, accessed exclusively via `@atomicRmw(.Xchg, ..., .acq_rel)`. The `.acq_rel` ordering ensures: (a) the writer's command pushes are visible before the batch appears in the mailbox, and (b) the renderer sees all commands after acquiring from the mailbox. **No fences, no mutexes, no clear-race.** On WASM this is a non-issue — single-threaded, single buffer, atomics compile to plain loads/stores.

### 4. WASM Transport

WASM has no threads and no stdin. The design doc suggests `postMessage` from JavaScript calling an exported WASM function. This is Phase 5+ and can be deferred — the core types (Phases 1-4) are WASM-compatible by construction (no pointers in commands, no dynamic allocation, fixed-size buffers).

### 5. Large Struct Initialization (CLAUDE.md Rule #14)

`AiCanvas` is ~280KB (~840KB total for native triple-buffer). **Do not** use struct literals (`self.* = .{ ... }`) for initialization — this creates a stack temporary. Use field-by-field init or `initInPlace` pattern with `noinline`. For the global `var buffers: [3]AiCanvas`, Zig initializes globals in the data segment — no stack involved — so default field values (`.{}`) are safe here.

---

## What We Do NOT Touch

The design doc explicitly states these files require no modification:

- `src/ui/canvas.zig` — DrawContext, Canvas element, `executePendingCanvas`
- `src/ui/primitives.zig` — UI primitive types
- `src/runtime/frame.zig` — Frame render loop
- `src/cx.zig` — Cx context
- `src/app.zig` — App entry point

The AI integration is **purely additive**. New files in `src/ai/` and `src/examples/`, plus minimal wiring:

- `src/root.zig` — one line: `pub const ai = @import("ai/mod.zig");` in the Module Namespaces section
- `build.zig` — one line: `addNativeExample(...)` call for the ai-canvas example

---

## Implementation Order (Suggested)

0. ~~**Phase 0 spike**~~ ✅ — validated comptime/runtime bridge. Artifact: `src/examples/ai_canvas_spike.zig`
1. ~~**Create `src/ai/` directory and `mod.zig`**~~ ✅ — module created, wired into `src/root.zig`
2. ~~**`text_pool.zig` + tests**~~ ✅ — 8 tests, comptime assertions, full API
3. ~~**`draw_command.zig` + comptime assertions**~~ ✅ — 11 variants, 7 tests, helper methods
4. ~~**`ai_canvas.zig` + tests**~~ ✅ — 13 tests, mutation API (`pushCommand`/`pushText`/`clearAll`), replay API, query API, comptime size assertions (<300KB)
5. ~~**`json_parser.zig` + tests**~~ ✅ — 27 tests, `std.json.parseFromSlice` → `std.json.Value`, all 11 tool types, color parsing (with/without `#`, with alpha), text→text_idx schema aliasing, fail-fast on malformed/unknown/missing
6. ~~**`schema.zig` + comptime tests**~~ ✅ — comptime `generateToolSchema` reflects over DrawCommand union, 11 tests, roundtrip JSON parse validation, `text_idx`→`text` schema aliasing, `@setEvalBranchQuota(100_000)` for deep comptime string ops
7. ~~**`src/examples/ai_canvas.zig`**~~ ✅ — triple-buffered native stdin transport via `@atomicRmw` index swaps, Zig 0.15 `File.Reader` streaming API with `takeDelimiter`, `StatusBar` component, `FixedBufferAllocator` for zero-alloc JSON parsing, WASM single-buffer fallback, 4 tests + comptime assertions
8. ~~**Wire into `src/root.zig`**~~ ✅ — `pub const ai = @import("ai/mod.zig");` in Module Namespaces section
9. ~~**Wire into `build.zig`**~~ ✅ — `addNativeExample(...)` call for ai-canvas example
10. **Manual integration test** — pipe the "draw a house" JSON from the design doc

Step 0 is throwaway. Steps 1–10 are each independently compilable and testable before moving to the next.
