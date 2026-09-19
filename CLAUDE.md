# Gooey Engineering Style

Gooey is designed for safety, performance, and developer experience, in that order.
Readability is necessary, but it is a means to those goals rather than the goal itself.

These are engineering rules, not suggestions. `MUST`, `MUST NOT`, `SHOULD`, and `MAY`
have their usual normative meanings. When a rule cannot be followed, document why at the
call site and obtain explicit agreement before merging the exception.

Simplicity is not the first attempt. It is the result of understanding the problem, sketching
alternatives, and finding one design that advances safety, performance, and usability at the
same time. Spend design effort before implementation, while change is still cheap.

## 1. Zero Technical Debt

Solve discovered problems correctly now. Do not defer known correctness risks, unbounded
work, allocation jitter, latency spikes, or accidental exponential complexity. A second pass
may never happen.

New code MUST leave its area more correct than it found it. Do not hide debt behind TODOs,
follow-up issues, comments, feature flags, or "temporary" abstractions. Missing features are
acceptable. Unsound foundations are not.

## 2. Static Memory Allocation

All Gooey-owned memory MUST be allocated during initialization. After initialization:

- No heap allocation is permitted.
- No capacity may grow.
- No object may be freed and replaced.
- No lazy initialization is permitted.
- No cache miss may allocate.
- No render, layout, input, accessibility, animation, asset, or callback path may allocate.
- Shutdown MAY free resources only after event and frame processing have stopped.

The initialization boundary is explicit:

- Native initialization ends immediately before entering the event loop.
- Web initialization ends immediately before the first frame can run.
- Application `on_init` work is part of initialization.
- Work completed after either boundary MUST consume storage reserved before the boundary.

This rule applies to application state, framework state, worker queues, decoded assets,
staging buffers, GPU resources, and bookkeeping. An OS or driver implementation may allocate
internally, but Gooey MUST NOT request avoidable dynamic storage from it after initialization.
Window resize, device recovery, asynchronous completion, and cache eviction are not implicit
exceptions; their storage and work MUST be bounded in the design.

Use fixed-capacity arrays, slot maps, object pools, arenas, slabs, and ring buffers. Allocate
or reserve their complete backing storage at startup. Runtime operations claim and release
slots; they do not allocate and free backing memory.

Pool exhaustion is a capacity-planning error. It MUST fail fast with the pool name, configured
capacity, requested count, and relevant frame or operation. It MUST NOT silently drop work,
grow, evict unrelated data, or fall back to a general-purpose allocator.

### Application resource budgets

Gooey applications MUST declare one complete resource budget at the canonical `gooey.App`
entry point. The intended public model is a comptime `ResourceLimits` value or named comptime
profile because `gooey.App` already accepts comptime configuration.

The resource budget MUST include every application-dependent capacity, including:

- Windows and maximum framebuffer dimensions.
- Widgets, elements, entities, and component-tree depth.
- Layout nodes, clips, render commands, vertices, indices, and draw batches.
- Glyphs, atlas pages, images, SVG data, and upload staging bytes.
- Input events, callbacks, timers, animations, and accessibility announcements.
- Async requests, completions, failures, and worker-queue entries.
- Per-frame work limits for every incremental subsystem.

Each subsystem MUST have an absolute framework ceiling. The application-selected limit MUST
be less than or equal to that ceiling. Relationships between limits MUST be checked at
comptime. Runtime-only platform constraints MUST be checked during initialization.

Capacity values MUST NOT be scattered through hidden subsystem defaults. A subsystem may use
a named default profile for examples, but production applications MUST select a profile or
provide explicit limits. The budget is part of the application's operational contract.

Where capacity changes a type's size, specialize the type at comptime. Where platform APIs
require runtime sizes, allocate the exact bounded storage during initialization. Pass the
validated budget downward; do not let leaf subsystems independently invent capacities.

Until the unified `ResourceLimits` API exists, new subsystem capacities MUST follow this model
locally and MUST be structured so they can be moved into the app budget without redesign.
Do not describe an unavailable API as implemented.

A debug allocation guard SHOULD mark the lifecycle as `initializing`, `running`, or
`deinitializing` and assert that Gooey allocator calls occur only in the permitted phases.

## 3. Assertions

Assertions detect programmer errors. Operating errors are expected and MUST be returned or
handled. Corrupt program state is unexpected and MUST stop execution.

The codebase MUST average at least two meaningful assertions per function. Non-trivial
functions SHOULD assert at least two independent properties. Do not add tautologies merely to
meet a count; strengthen the mental model instead.

Assert:

- Every function argument not already proven by its type.
- Preconditions before state is read or mutated.
- Invariants while state transitions occur.
- Postconditions and return values before returning.
- Counts before indexing and capacities before writing.
- Enum, tag, alignment, ownership, and lifecycle assumptions.
- Relationships between compile-time constants and important type sizes.

Pair assertions across boundaries. Assert data before writing it to a queue, file, GPU buffer,
or platform API, and assert it independently when reading or completing the operation.

Split compound assertions:

```zig
assert(offset <= length);
assert(size <= length - offset);
```

Do not write `assert(offset <= length and size <= length - offset)`. Separate assertions make
the failed property precise. Use a single-line implication when appropriate:

```zig
if (state == .running) assert(initialized);
```

A blatantly true assertion MAY replace a comment when it enforces a critical and surprising
relationship. Assertions are executable documentation, but they are not a substitute for
understanding or tests.

## 4. Put a Limit on Everything

Every loop, queue, stack, buffer, retry, callback list, state machine, and unit of work per
frame MUST have a hard upper bound. Use explicit names with units:

```zig
const glyph_count_frame_max: u32 = 65_536;
const clip_depth_max: u8 = 32;
const component_depth_max: u8 = 64;
```

Loops MUST make their bound visible in the loop condition or assert it in the body. An
intentional event loop that does not terminate MUST assert or structurally prove that each
iteration performs bounded work.

Do not convert a bounded queue into unbounded latency. Bound both storage and the number of
items processed per frame. Define overload behavior explicitly and fail fast when preserving
correctness is impossible.

## 5. Function Shape

Functions have a hard limit of 70 physical lines, including assertions and comments but
excluding the signature. Do not evade the limit with dense formatting.

When splitting functions:

- Keep control flow in the parent.
- Push `if` and `switch` upward.
- Push loops and pure computation downward.
- Keep state mutation centralized.
- Make leaf functions pure where possible.
- Prefer a few arguments and a simple return value.
- Move complex nested types to top-level declarations.

A helper split MUST represent a coherent responsibility. Do not create fragments named
`part1`, `continued`, or `helper` merely to satisfy the line count.

## 6. Explicit Control Flow

- Recursion is forbidden. Use a fixed-capacity explicit stack.
- Suspending functions and hidden coroutine control flow are forbidden.
- Functions MUST run to completion while their preconditions remain true.
- Abstractions MUST justify their safety and performance cost.
- Dynamic dispatch MUST be bounded and justified.
- Hidden callbacks and reentrancy MUST be avoided.

Split compound conditions into nested branches when separate facts are being decided. Write
complex `else if` chains as explicit `else { if (...) { ... } else { ... } }` trees. Consider
both the positive and negative space of every branch.

Add braces unless the complete `if` statement fits on one line. This is defense in depth
against edits that accidentally change control flow.

## 7. Performance Sketches

Before implementation, write a back-of-the-envelope sketch for network, disk, memory, CPU,
and GPU where applicable. Cover both bandwidth and latency. State:

- Maximum operations and bytes per frame.
- Maximum resident and transient memory.
- Maximum queue depth and completion rate.
- Expected cache behavior and data locality.
- Worst-case work, not only average work.
- The configured limit that enforces each estimate.

For Gooey, include vertices, indices, draw commands, texture uploads, glyph lookups, layout
nodes, event batches, accessibility updates, and asset completions as applicable.

Optimize network, disk, memory, and CPU in that order after accounting for frequency. A fast
operation repeated often can dominate a slower operation performed rarely.

## 8. Batching and Planes

Do not react directly to external events. Capture them into bounded queues and let Gooey run
at its own pace. Batch network, disk, memory, CPU, and GPU accesses.

Separate the control plane from the data plane. Assert heavily when constructing and
validating batches. Keep the hot data-plane loop compact, predictable, and free of allocation,
branching, pointer chasing, and redundant computation.

## 9. Naming

- Use `snake_case` for functions, variables, fields, and filenames.
- Use proper acronym capitalization in type names, such as `VSRState`, not `VsrState`.
- Do not abbreviate names except primitive integer parameters in sorting or matrix code.
- Put units and qualifiers last, ordered from most to least significant.
- Prefer `latency_ms_max` to `max_latency_ms`.
- Prefer `source` and `target` to `src` and `dest`.
- Choose related names of similar length when this improves visual symmetry.
- Infuse allocator names with ownership, such as `gpa`, `arena`, or `frame_arena`.
- Do not overload a domain term with a second meaning.
- Prefer nouns that compose outside code, such as `pipeline` rather than `preparing`.
- Use long-form script flags, such as `--force`, except for interactive convenience.

When one function owns a helper or callback, prefix the helper with the caller's name, such as
`read_sector` and `read_sector_callback`. Callbacks go last in parameter lists.

Use an `options: struct` when arguments can be confused. A function taking two values of the
same integer type MUST use named options. Nullable arguments MUST be named so `null` is clear
at the call site.

Thread singleton dependencies through constructors positionally from most general to most
specific when their distinct types make confusion impossible.

Order files top-down by importance. Put `main` first. In structs, place fields first, then
nested types, then methods. Move a nested type to top level when it is complex. When semantic
order is not stronger, use alphabetical or big-endian naming order.

Follow the Zig style guide for everything not overridden here.

## 10. Shrink Scope

Declare variables at the smallest possible scope. Calculate and validate values close to use
to prevent place-of-check-to-place-of-use bugs. Do not retain aliases or duplicate derived
state that can become inconsistent.

Prefer simpler signatures and return types. As a default ordering:

`void` > `bool` > `u64` > `?u64` > `!u64`

Complex return types add branches at every caller and spread through the call graph. Return
only information the caller must act upon.

## 11. Positive and Negative Space

State invariants positively:

```zig
if (index < count) {
    use(items[index]);
} else {
    unreachable;
}
```

Prefer `index < count` over negated or reversed forms such as `index >= count`. For every valid
state, identify and handle or assert the invalid states. Boundary transitions are where the
most valuable bugs are found.

## 12. Dependencies

Gooey has zero third-party package dependencies. The Zig toolchain, Zig standard library, and
required platform APIs such as CoreText, Metal, Wayland, Vulkan, and browser APIs are allowed.
Do not add a package when the functionality can be implemented and maintained locally.

Any proposed exception MUST document supply-chain risk, supported platforms, binary size,
initialization behavior, runtime allocation behavior, failure modes, and removal cost. An
exception requires explicit approval before code is written.

## 13. In-Place Initialization

Construct large or immovable values in place with an out pointer. In-place initialization is
viral: if one field requires a stable address, initialize its containing object in place too.

Pass an argument larger than 16 bytes as `*const` unless copying is intentional and documented.

For small structs, an in-place initializer MAY use `self.* = .{ ... }`. For large structs,
initialize field by field because a struct literal can create a stack temporary.

Initialization functions MUST establish and assert every field's state. Partially initialized
objects MUST NOT escape. Use `errdefer` to unwind every successfully acquired resource.

## 14. WASM Stack Budget

WASM has a 1 MiB stack beginning at address 1,048,576 and growing downward.

- Heap-allocate structs larger than 50 KiB during initialization.
- Initialize those structs in place.
- Mark their initializer `noinline` to prevent frame accumulation in `ReleaseSmall`.
- Do not use large struct literals or return large structs by value.
- Add compile-time size assertions for large foundational types.

Known approximate sizes include `TextSystem` at 1.7 MiB, `WebRenderer` at 1.15 MiB, `Gooey` at
400 KiB, and `Tree` at 350 KiB. Update these figures when layouts materially change.

```zig
const thing = try allocator.create(Thing);
errdefer allocator.destroy(thing);

thing.initInPlace(allocator);

pub noinline fn initInPlace(self: *Self, allocator: Allocator) void {
    self.field1 = 0;
    self.field2 = 0;
}
```

For stack diagnosis, use the existing `verbose_init_logging` switches in the relevant Gooey,
accessibility, or web bridge implementation.

## 15. Explicitly Sized Types

Use explicitly sized integers such as `u8`, `u16`, `u32`, and `u64`. Use `usize` only when
interfacing with Zig APIs, pointer arithmetic, or slice indexing that requires it. Convert to
and from explicitly sized domain types at the boundary, with checked casts and assertions.

Explicit sizes make overflow, memory layout, serialization, native behavior, and WASM behavior
predictable.

## 16. Explain Why and How

Code alone is not documentation. Comments MUST explain rationale, invariants, constraints, or
methodology rather than narrating syntax.

Comments are sentences: one space after `//`, an initial capital, and a final full stop. A
colon is appropriate when introducing code. End-of-line comments MAY be short phrases.

Tests MUST begin with a short explanation of their goal and methodology when the test body does
not make both immediately obvious. Performance-sensitive code MUST show its resource sketch or
link to the design that contains it.

## 17. Handle Every Error

Every error MUST be returned, transformed, logged and handled, or explicitly classified as an
impossible programmer error with a nearby proof. Do not silently discard errors. Do not use
`catch unreachable` without documenting and asserting why the error is impossible.

Test error paths. Incorrect handling of non-fatal errors causes catastrophic failures more
often than the original operation does.

## 18. Off-by-One Discipline

Treat indexes, counts, sizes, offsets, and capacities as distinct conceptual types.

- Index to count: add one.
- Count to byte size: multiply by the unit size.
- Offset plus size: prove the addition cannot overflow before comparing with capacity.
- Inclusive to exclusive bounds: perform and check the conversion explicitly.

Use `@divExact`, `@divFloor`, or an explicit ceiling-division helper. Do not use `/` where the
rounding contract matters. Names MUST include the relevant unit or qualifier.

## 19. Explicit Options

Pass library options explicitly at call sites. Do not rely on defaults when a choice affects
correctness, performance, compatibility, or generated code.

```zig
@prefetch(address, .{
    .cache = .data,
    .rw = .read,
    .locality = 3,
});
```

Named defaults are acceptable only when the default itself is the reviewed policy and its name
communicates that policy.

## 20. Hot Loops

Extract hot loops into standalone functions with primitive arguments and no `self`. Load
needed fields before the call so the compiler and reader do not need to prove repeated pointer
accesses are stable.

Hot loops MUST NOT allocate, perform virtual dispatch, grow buffers, acquire contended locks,
or hide bounds checks inside abstractions. Keep loop bounds and memory strides explicit.

## 21. Buffer Bleeds

A partially written buffer can leak stale or sensitive bytes and break deterministic output.
Zero every unused byte, including alignment padding, unused GPU ranges, serialization padding,
and pooled storage returned to a different logical owner.

Assert the used range when writing and again before submission or transmission.

## 22. Resource Grouping

Place a blank line before resource allocation and after its matching `defer` or `errdefer` so
ownership and cleanup are visually obvious:

```zig
const buffer = try allocator.alloc(u8, size);
defer allocator.free(buffer);

const texture = try gpu.createTexture(descriptor);
defer gpu.destroyTexture(texture);

use(buffer, texture);
```

Keep acquisition and cleanup together. Do not separate them with unrelated work.

## 23. Compiler Warnings

Enable the compiler's strictest practical diagnostics from the first day. Every warning is a
bug report. Fix the cause; do not suppress the warning.

## 24. Testing

Build a precise mental model before writing the implementation. Encode that model in types,
assertions, comments, and tests. Fuzzing and simulation find contradictions in the model; they
do not prove the absence of bugs.

Tests MUST cover:

- Minimum, maximum, empty, full, and one-past-the-boundary cases.
- Valid input becoming invalid at each boundary.
- Capacity exhaustion and overload behavior.
- Every error return and partial-initialization cleanup path.
- Integer overflow, truncation, and rounding boundaries.
- Repeated reuse of pooled slots and zeroed padding.
- Deterministic output where determinism is promised.

A capacity test MUST fill the resource exactly, verify the last valid operation, attempt one
additional operation, and verify the documented failure mode.

## 25. Formatting

- Run `zig fmt` on every changed Zig file.
- Use four spaces of indentation.
- Hard-limit every source and documentation line to 100 columns.
- Use the available width; do not create needlessly narrow code.
- Add trailing commas and let `zig fmt` wrap declarations, calls, and literals.
- Nothing important may be hidden behind a horizontal scrollbar.

Formatting rules are mechanical and MUST be enforced by tooling where possible.

## 26. Tooling

Prefer the standardized tool already used by the repository. Every additional tool adds
installation, portability, security, and maintenance cost.

Prefer Zig programs to shell scripts for repository automation. Zig scripts are cross-platform,
type-checked, and keep the team's toolbox small. A shell script is acceptable only when it is
trivial, portable, and demonstrably clearer.

Do not add a formatter, task runner, code generator, or package manager when the Zig toolchain
can perform the job adequately.

## 27. Review Checklist

Before considering work complete, verify:

1. Safety, performance, and developer experience were considered in that order.
2. Every resource and unit of work has a documented hard bound.
3. All Gooey-owned memory is reserved before the initialization boundary.
4. Runtime paths cannot allocate, grow capacity, or lazily initialize.
5. Arguments, invariants, boundaries, and postconditions are asserted.
6. Positive and negative spaces, capacity exhaustion, and errors are tested.
7. Functions and lines obey the 70-line and 100-column limits.
8. Names expose units, ownership, and domain meaning.
9. Errors and partial initialization are handled completely.
10. The performance sketch fits within the declared app resource budget.
11. `zig fmt`, focused tests, and relevant broader validation pass.
12. Comments and the change description explain why the design is correct.
