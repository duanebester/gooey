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
- **Split compound assertions**: prefer `assert(a); assert(b);` over `assert(a and b);` — the former is simpler to read, and provides more precise information if the condition fails
- Use single-line `if` to assert an implication: `if (a) assert(b);`
- On occasion, use a blatantly true assertion instead of a comment as stronger documentation where the assertion condition is critical and surprising

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
- **Good function shape** is the inverse of an hourglass: a few parameters, a simple return type, and a lot of meaty logic between the braces
- **Centralize state manipulation**: let the parent function keep all relevant state in local variables, and use helpers to compute what needs to change, rather than applying the change directly. Keep leaf functions pure

### 6. **Explicit Control Flow**

- No recursion (important for component trees—use explicit stacks)
- Minimize abstractions ("abstractions are never zero cost")
- Avoid `async`/suspend patterns that hide control flow
- **Split compound conditions**: split complex `else if` chains into nested `else { if {} }` trees to make branches and cases explicit. Consider whether a single `if` also needs a matching `else` branch to ensure positive and negative spaces are handled or asserted
- **Functions must run to completion** without suspending, so that precondition assertions remain true throughout the lifetime of the function

### 7. **Back-of-Envelope Performance Sketches**

Before implementing, sketch resource usage:

- How many vertices per frame? (GPU bandwidth)
- How many texture uploads per frame? (memory bandwidth)
- How many glyph cache lookups? (CPU/cache locality)

Optimize for **network → disk → memory → CPU** (slowest first), adjusted for frequency. A memory cache miss may be as expensive as a disk fsync if it happens many times more often.

### 8. **Batching as Religion**

We're already doing this with GPU commands, but:

- Don't react to events directly—batch them
- Amortize costs across frames
- Let the CPU sprint on large chunks, not zig-zag on tiny tasks
- **Distinguish control plane from data plane**: a clear delineation through batching enables a high level of assertion safety without losing performance. Assert heavily on the control plane; batch tightly on the data plane

### 9. **Naming Discipline**

- Units/qualifiers last: `offset_pixels_x`, `latency_ms_max`
- Same-length related names for visual alignment: `source`/`target` not `src`/`dest`
- Callbacks go last in parameter lists
- **Do not abbreviate** variable names (unless the variable is a primitive integer in a sort function or matrix calculation)
- **Infuse names with meaning**: `gpa: Allocator` and `arena: Allocator` are better than `allocator: Allocator` — they inform the reader whether `deinit` should be called
- **Don't overload names** with multiple meanings that are context-dependent
- **Think of how names read outside the code** — in docs or conversation. Nouns compose better than adjectives or participles: `pipeline` over `preparing`
- **Named arguments via `options: struct`** pattern when arguments can be mixed up. A function taking two `u64`s must use an options struct
- **Struct field ordering**: fields first, then types, then methods. Important things near the top. `main` goes first in a file
- **Descriptive commit messages** that inform and delight the reader. PR descriptions are not stored in git history and are invisible in `git blame` — they are not a replacement for commit messages

### 10. **Shrink Scope Aggressively**

- Declare variables at smallest possible scope
- Calculate/check values close to use (avoid POCPOU bugs)
- Don't leave variables around after they're needed
- **Don't duplicate variables or take aliases** — this reduces the probability that state gets out of sync
- **Simpler return types reduce dimensionality**: `void` > `bool` > `u64` > `?u64` > `!u64`. Simpler signatures mean fewer branches at call sites, and this dimensionality is **viral** through call chains

### 11. **Handle the Negative Space**

For every valid state you handle, assert the invalid states too:

```example.zig
if (glyph_index < glyph_count) {
    // Valid - render the glyph
} else {
    unreachable; // Assert we never get here
}
```

**State invariants positively.** Negations are error-prone. This form is easy to get right:

```example.zig
if (index < length) {
    // The invariant holds.
} else {
    // The invariant doesn't hold.
}
```

This form is harder, and goes against the grain of how `index` is typically compared to `length`:

```example.zig
if (index >= length) {
    // It's not true that the invariant holds.
}
```

Prefer the positive form.

### 12. **Zero Dependencies (Spirit Of)**

We're using Zig and system APIs (CoreText, Metal)—that's fine. But avoid pulling in external Zig packages when you can implement cleanly yourself. Each dependency is a supply chain risk.

### 13. **In-Place Initialization**

For large structs (like render state), use out-pointers:

```example.zig
pub fn init(self: *RenderState) void {
    self.* = .{ ... };  // No stack copy
}
```

This avoids stack growth and copy-move allocations. In-place initializations are **viral** — if any field is initialized in-place, the entire container struct should be initialized in-place as well.

**Pass large args as `*const`**: if an argument type is more than 16 bytes and you don't intend for it to be copied, pass it as `*const`. This catches bugs where the caller makes an accidental copy on the stack before calling the function.

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

### 15. **Explicitly-Sized Types**

Use explicitly-sized types like `u32` for everything. Avoid architecture-specific `usize` unless interfacing with Zig's standard library or slice indexing that requires it. Explicit sizes make overflow behavior, memory layout, and cross-platform behavior (native ↔ WASM) predictable and consistent.

### 16. **Always Say Why**

Code alone is not documentation.

- **Never forget to say why.** If you explain the rationale for a decision, it increases the reader's understanding and shares criteria with which to evaluate the decision and its importance
- Comments are sentences: space after the slash, capital letter, full stop (or a colon if they relate to something that follows)
- Comments after the end of a line _can_ be phrases, with no punctuation
- When writing a test, describe the goal and methodology at the top — help the reader get up to speed or skip over sections without forcing them to dive in

### 17. **All Errors Must Be Handled**

92% of catastrophic failures in distributed data-intensive systems are the result of incorrect handling of non-fatal errors explicitly signaled in software ([OSDI'14](https://www.usenix.org/system/files/conference/osdi14/osdi14-paper-yuan.pdf)). Every error return must be handled — no silent discards, no blind `catch unreachable` without justification.

### 18. **Off-By-One Discipline**

The usual suspects for off-by-one errors are casual interactions between an `index`, a `count`, and a `size`. Treat them as distinct conceptual types with clear conversion rules:

- `index` → `count`: add one (indexes are 0-based, counts are 1-based)
- `count` → `size`: multiply by the unit

Show division intent explicitly: use `@divExact()`, `@divFloor()`, or `div_ceil()` to prove to the reader you've thought through rounding scenarios.

### 19. **Explicit Options at Call Sites**

Explicitly pass options to library functions at the call site instead of relying on defaults:

```example.zig
// Prefer:
@prefetch(a, .{ .cache = .data, .rw = .read, .locality = 3 });

// Over:
@prefetch(a, .{});
```

This improves readability and avoids latent, potentially catastrophic bugs if the library ever changes its defaults.

### 20. **Hot Loop Extraction**

Extract hot loops into standalone functions with primitive arguments — no `self`. This way the compiler doesn't need to prove it can cache struct fields in registers, and a human reader can spot redundant computations more easily.

```example.zig
// Instead of a method that accesses self.field in a tight loop:
fn renderGlyphBatch(positions: [*]const f32, uvs: [*]const f32, count: u32, atlas_width: f32) void {
    // Tight loop with only primitives — no pointer chasing through self
}
```

### 21. **Buffer Bleeds**

The inverse of a buffer overflow: a buffer underflow where a buffer is not fully utilized and padding is not zeroed correctly. This can leak sensitive information and break deterministic guarantees. When writing to GPU buffers, zero-fill any padding between used regions.

### 22. **Resource Allocation Grouping**

Use newlines to **group resource allocation and deallocation** — place a blank line before the allocation and after the corresponding `defer` statement. This makes leaks visually obvious:

```example.zig
const buffer = try allocator.alloc(u8, size);
defer allocator.free(buffer);

const texture = try gpu.createTexture(desc);
defer gpu.destroyTexture(texture);

// ... use buffer and texture ...
```

### 23. **Compiler Warnings**

Appreciate **all compiler warnings at the compiler's strictest setting** from day one. Warnings are free bug reports. Never suppress them — fix the underlying issue.
