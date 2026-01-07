Engineering Notes

### 1. **Zero Technical Debt Policy**

_solve problems correctly the first time_. When you encounter a potential latency spike or algorithmic issue, fix it now—don't defer. The second pass may never come.

### 2. **Static Memory Allocation**

This is huge for a UI framework:

- **No dynamic allocation after initialization**
- Pre-allocate pools for glyphs, render commands, widgets at startup
- Use fixed-capacity arrays/pools instead of growing `ArrayList`s during rendering

For Gooey, this means: glyph caches, command buffers, and clip stacks should have fixed upper bounds allocated at init time. This eliminates allocation jitter during frame rendering.

### 3. **Assertion Density**

**minimum 2 assertions per function**. For Gooey:

- Assert glyph bounds before atlas insertion
- Assert clip rect validity before pushing to stack
- **Pair assertions**: assert data validity when writing to GPU buffer AND when reading back
- Assert compile-time constants (e.g., `comptime { assert(@sizeOf(Vertex) == 32); }`)

### 4. **Put a Limit on Everything**

Every loop, every queue, every buffer needs a hard cap:

```example.zig
const MAX_GLYPHS_PER_FRAME = 65536;
const MAX_CLIP_STACK_DEPTH = 32;
const MAX_NESTED_COMPONENTS = 64;
```

This prevents infinite loops and tail latency spikes. If you hit a limit, **fail fast**.

### 5. **70-Line Function Limit**

Hard limit. Split large render functions by:

- Keeping control flow (switches, ifs) in parent functions
- Moving pure computation to helpers
- "Push ifs up, fors down"

### 6. **Explicit Control Flow**

- No recursion (important for component trees—use explicit stacks)
- Minimize abstractions (you already mention "abstractions are never zero cost")
- Avoid `async`/suspend patterns that hide control flow

### 7. **Back-of-Envelope Performance Sketches**

Before implementing, sketch resource usage:

- How many vertices per frame? (GPU bandwidth)
- How many texture uploads per frame? (memory bandwidth)
- How many glyph cache lookups? (CPU/cache locality)

Optimize for **network → disk → memory → CPU** (slowest first), adjusted for frequency.

### 8. **Batching as Religion**

We're already doing this with GPU commands, but:

- Don't react to events directly—batch them
- Amortize costs across frames
- Let the CPU sprint on large chunks, not zig-zag on tiny tasks

### 9. **Naming Discipline**

- Units/qualifiers last: `offset_pixels_x`, `latency_ms_max`
- Same-length related names for visual alignment: `source`/`target` not `src`/`dest`
- Callbacks go last in parameter lists

### 10. **Shrink Scope Aggressively**

- Declare variables at smallest possible scope
- Calculate/check values close to use (avoid POCPOU bugs)
- Don't leave variables around after they're needed

### 11. **Handle the Negative Space**

For every valid state you handle, assert the invalid states too:

```example.zig
if (glyph_index < glyph_count) {
    // Valid - render the glyph
} else {
    unreachable; // Assert we never get here
}
```

### 12. **Zero Dependencies (Spirit Of)**

We're using Zig and system APIs (CoreText, Metal)—that's fine. But avoid pulling in external Zig packages when you can implement cleanly yourself. Each dependency is a supply chain risk.

### 13. **In-Place Initialization**

For large structs (like render state), use out-pointers:

```example.zig
pub fn init(self: *RenderState) void {
    self.* = .{ ... };  // No stack copy
}
```

This avoids stack growth and copy-move allocations.

### 14. **WASM Stack Budget**

WASM has a **1MB stack** starting at address 1,048,576, growing downward. Large structs returned by value or struct literals blow this budget fast. Hard rules:

- **Heap-allocate structs >50KB**: Use `allocator.create(T)` + `initInPlace()`
- **Mark init functions `noinline`**: Prevents ReleaseSmall from combining stack frames
- **Avoid struct literals for large types**: `self.* = .{ ... }` creates a stack temp; use field-by-field init instead
- **Know your struct sizes**: `TextSystem` ~1.7MB, `WebRenderer` ~1.15MB, `Gooey` ~400KB, `Tree` ~350KB

Pattern for large structs:

```example.zig
// Instead of: const thing = try Thing.init(allocator);
const thing = try allocator.create(Thing);
thing.initInPlace(allocator);

// initInPlace must be noinline to prevent stack accumulation
pub noinline fn initInPlace(self: *Self, allocator: Allocator) void {
    self.field1 = 0;  // Field-by-field, no struct literal
    self.field2 = 0;
}
```

Debug logging for stack issues: Set `verbose_init_logging = true` in `gooey.zig`, `accessibility.zig`, or `web_bridge.zig`.
