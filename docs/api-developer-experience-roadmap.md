# Gooey API Developer Experience Roadmap

## Purpose

This document records recommended changes from a review of Gooey's top-level API, application lifecycle, standard components, examples, documentation, and testing facilities.

Gooey's central programming model is sound and should be preserved:

- `gooey.App` and `gooey.Cx` provide a concise application boundary.
- The `ui`, `components`, and `widgets` namespaces have clear responsibilities.
- State-oriented handlers encourage testable application logic.
- The curated root namespace makes the public API predictable.
- Standard components include accessibility semantics by default.

The main weakness is silent degradation. Some APIs turn configuration mistakes, unsupported operations, capacity exhaustion, or operational errors into defaults, `null`, empty results, no-ops, or disabled controls. The highest-priority work is therefore to make failure behavior explicit and actionable without redesigning the successful core API.

## Design principles

Changes made from this roadmap should follow these principles:

1. Preserve the current declarative application model.
2. Make invalid configuration fail at compile time.
3. Reserve optional values for normal absence, not operational failure.
4. Make unsupported platform operations discoverable before or during the call.
5. Make every fixed-capacity limit observable and actionable.
6. Make invalid component states unrepresentable where practical.
7. Keep native and web behavior equivalent where possible and explicitly document differences where it is not.
8. Prefer focused additions over a broad API redesign.

# P0: Correctness and diagnosability

## Reject unknown `App` configuration fields

### Current issue

`gooey.App` accepts an anonymous `anytype` configuration and copies fields recognized by `CxConfig`. Extra fields are not rejected, so a typo such as `.widht = 800` may compile and silently use the default width.

Relevant code:

- `src/app.zig`
- `src/runtime/runner.zig`

### Recommended change

Keep the existing literal-friendly call site, but add compile-time validation that every supplied field exists in `CxConfig(State)` or is an explicitly supported compatibility alias.

```zig
const App = gooey.App(State, &state, render, .{
    .title = "Example",
    .width = 800,
});
```

Unknown fields must produce a compile error naming the invalid field and, if practical, suggesting the nearest valid field.

The `init` compatibility alias should prefer canonical `on_init`, emit a deprecation diagnostic if feasible, and be removed on a published schedule.

### Acceptance criteria

- Every valid `CxConfig` field is accepted by `App`.
- An unknown field fails compilation.
- Native and WASM validate the same option set.
- Tests cover misspellings and compatibility aliases.

## Distinguish cancellation, absence, and errors

### Current issue

Several APIs collapse operational failures into normal absence:

- File dialogs use `null` for cancellation, unsupported platforms, and backend errors.
- Queue draining can return an empty slice after an error.
- Retained widget lookup can return `null` after allocation or capacity failure.

This makes normal application state indistinguishable from a framework or platform failure.

### Recommended change

Use a consistent contract:

- `?T` means normal absence.
- `!?T` means an operation can fail or produce no value.
- `!T` means the operation must produce a value or an error.
- Fixed-capacity exhaustion must fail fast or emit a structured diagnostic.

For file dialogs:

```zig
pub fn promptForPath(options: PathPromptOptions) !?PathPromptResult
```

Interpretation:

- `null`: the user cancelled.
- `error.Unsupported`: no supported dialog backend is available.
- Other errors: allocation, IPC, portal, browser, or operating-system failure.

Queue draining should return an error union unless a specific benign error is intentionally handled and documented.

Widget accessors should distinguish "not mounted" from state insertion failure. Lookup-only APIs may remain optional; create-on-touch APIs should return errors.

### Acceptance criteria

- Cancellation is distinguishable from failure.
- Queue failure cannot appear as an empty queue.
- Capacity exhaustion cannot appear as an unmounted or disabled widget.
- Examples demonstrate explicit error handling.

## Add structured capacity diagnostics

### Current issue

Gooey appropriately uses fixed-capacity pools and buffers, but applications lack a unified way to understand when a limit is reached. Silent fallback makes exported limits difficult to act on.

### Recommended change

Introduce a framework diagnostic hook or fixed-capacity failure record containing:

- Capacity or pool name.
- Configured maximum.
- Current usage.
- Attempted usage.
- Window identifier.
- Element or component identifier when available.
- Suggested remediation.

Cover at least:

- Element-state capacity.
- Render-command capacity.
- Glyph and image atlas capacity.
- Handler capacity.
- Focus and hover path capacity.
- Accessibility-tree capacity.
- Async queue capacity.
- Virtual-list and table limits.

Development and test builds should fail loudly. Production behavior should remain deterministic and must not silently render a misleading UI state.

### Acceptance criteria

- Every public fixed-capacity failure has an actionable message.
- Diagnostics identify the exhausted resource and configured maximum.
- Tests can intentionally trigger each important capacity limit.

## Make platform support explicit

### Current issue

Some cross-platform methods exist everywhere but silently do nothing on unsupported targets. Examples include window close and native glass effects on web.

### Recommended change

Use one of these explicit patterns for each platform-sensitive operation:

1. A capability query before calling.
2. An `error.Unsupported` result.
3. A compile-time error for inherently platform-specific APIs.

```zig
if (gooey.platform.getCapabilities().glass) {
    try cx.setGlassStyle(.sidebar, .{
        .opacity = 0.8,
        .corner_radius = 12,
    });
}
```

No-op behavior should be reserved for operations whose absence is genuinely harmless and semantically equivalent.

### Acceptance criteria

- Unsupported meaningful operations are detectable.
- Capability names map directly to public operations.
- Native, Linux, and WASM behavior is covered by tests or compile checks.
- The support matrix described later in this document is published.

## Harden multi-window lifecycle correctness

### Current issue

Static review identified several areas that require targeted verification:

- Per-window teardown may not invoke full `WindowContext` cleanup.
- App-scoped frame observation may be reset once per window rather than once per application tick.
- Recoverable frame errors may leave frame-phase state inconsistent.
- Shared rendering resources may retain the first window's scale factor.
- Native and WASM lifecycle callbacks do not appear fully equivalent.

Relevant code:

- `src/runtime/multi_window_app.zig`
- `src/runtime/window_context.zig`
- `src/runtime/frame.zig`
- `src/context/window.zig`
- `src/context/app.zig`
- `src/app.zig`

### Recommended change

Add focused lifecycle tests before changing behavior:

1. Open and close windows repeatedly while checking resource cleanup.
2. Observe one entity from two windows and verify both observations survive the tick.
3. Inject a recoverable frame error and verify the following frame starts cleanly.
4. Render windows at different scale factors and verify per-window raster resources.
5. Compare native and WASM callback invocation for initialization, resize, close, and custom I/O.

Then fix each confirmed issue at the lifecycle boundary rather than adding call-site workarounds.

### Acceptance criteria

- Closing a window deinitializes all per-window resources exactly once.
- App-level frame state advances once per application tick.
- A failed frame restores a valid lifecycle state.
- Windows on mixed-DPI displays render at their own scale factors.
- Native and web lifecycle differences are intentional and documented.

# P1: Public API consistency

## Type `setGlassStyle` explicitly

Replace the `anytype` style parameter with a public `GlassStyle` type. Use an options struct for values that can be mixed up.

```zig
pub fn setGlassStyle(
    self: *Cx,
    style: GlassStyle,
    options: GlassOptions,
) !void
```

Backend enum conversion should remain internal. Unsupported targets should return `error.Unsupported` or be guarded by a capability query.

## Normalize retained widget accessor names

Current accessor names mix control terminology and implementation terminology. Normalize them around the fact that they return retained state:

```zig
cx.textInputState(id)
cx.textAreaState(id)
cx.codeEditorState(id)
cx.scrollState(id)
```

Suggested migration:

1. Add the consistent names.
2. Mark old names deprecated.
3. Update examples and internal call sites.
4. Remove aliases in the next breaking release.

## Remove old `Gooey` terminology

Replace `cx.getGooey()` with terminology based on the current `Window` type.

Suggested API:

```zig
cx.window()          // Asserts that a window is bound.
cx.windowOptional()  // Returns ?*Window.
```

Keep `getGooey` only as a temporary compatibility alias.

## Standardize callback and handler terminology

Document and enforce one callback taxonomy:

- Update: pure state mutation followed by rendering.
- Command: state mutation with framework/window access.
- Selection handler: handler that receives a selected value or index.
- Deferred command: work run after event dispatch.
- Direct callback: stateless callback, if retained.

Avoid parallel fields that permit conflicting configuration such as both `on_click` and `on_click_handler`.

Prefer a tagged union when multiple action types remain necessary:

```zig
action: union(enum) {
    none,
    callback: *const fn () void,
    handler: HandlerRef,
}
```

Invalid callback combinations must be impossible in optimized builds, not merely guarded by debug assertions.

## Clarify component identity rules

Document when IDs are:

- Optional because a component is presentational.
- Required because state is retained across frames.
- Required for accessibility relationships.
- Required for focus, testing, or programmatic lookup.

Where practical, use distinct constructors or compile-time checks to prevent accidentally creating a retained component without stable identity.

## Consider a narrower command context

Commands currently receive broad framework/window access. This is practical but makes command methods harder to unit-test than pure updates.

Evaluate a narrower command context containing only stable application services:

- Render invalidation.
- Window operations.
- Clipboard.
- Notifications.
- Async task submission.
- Focus requests.

Do not add this abstraction unless it meaningfully improves testability and reduces coupling without hiding control flow.

# P2: Documentation and onboarding

## Publish a consumer-focused API reference

Create a stable API guide with these chapters:

1. Creating an application.
2. Application state and rendering.
3. Updates, commands, and event handlers.
4. Layout and styling.
5. Standard components.
6. Retained widget state.
7. Focus and keyboard input.
8. Animation.
9. Images, SVG, and fonts.
10. Async work and queues.
11. Accessibility.
12. Platform capabilities.
13. Capacity limits and failure behavior.
14. Testing.
15. Multi-window applications.

The guide should focus on public contracts rather than implementation history.

## Surface the namespace stability policy in the README

The two-tier policy documented in `src/root.zig` is one of Gooey's strongest design decisions. Add it to the README so users understand:

- Which flat names are intentionally stable.
- Which namespace owns each API.
- Why duplicate flat aliases are avoided.

## Reorganize examples as a learning progression

Recommended progression:

1. Hello World.
2. Counter and state updates.
3. Todo and controlled input.
4. Forms and validation.
5. Async loading and cancellation.
6. Virtualized data.
7. Custom component authoring.
8. Accessibility.
9. Multi-window applications.

Rename examples and comments that describe migration phases or implementation history. Each example should state what an application author will learn and which public contracts it demonstrates.

## Compile-test documentation snippets

Add documentation snippets to build checks so API changes cannot silently invalidate the README or guides.

At minimum, compile-test:

- Hello World.
- `App` configuration.
- `update` and `command` handlers.
- Controlled text input.
- File-dialog error handling.
- Platform capability checks.
- Custom component rendering.

## Rewrite the multi-window guide for consumers

Keep implementation plans and architecture history in a separate design note. The primary multi-window guide should cover:

- Creating and closing windows.
- Window handles and ownership.
- Shared versus per-window state.
- Rendering and observation behavior.
- Mixed-DPI behavior.
- Error handling.
- Platform restrictions.
- Shutdown and cleanup.

## Publish ownership and lifetime conventions

Document consistent rules for:

- Values borrowed only during the current render.
- Strings and slices retained across frames.
- Bound pointers.
- Widget-state pointers.
- Handler captures.
- Image and SVG source data.
- Async callback payloads.
- The application state pointer supplied to `App`.
- File-dialog and loader result ownership.

Each API that retains a pointer or slice should say so in its declaration documentation.

## Publish a platform capability matrix

Cover macOS, Linux, and WASM support for:

- Multi-window operation.
- Close and quit.
- Resize callbacks.
- Glass and transparency.
- Clipboard.
- File dialogs.
- Drag and drop.
- Image loading.
- Custom shaders.
- Accessibility.
- System fonts.
- IME and text composition.
- Cursor control.
- Notifications.

For every unsupported feature, document whether the call fails, compiles out, or has an intentional no-op.

# P3: Application testing

## Add a headless application harness

The current `gooey.testing` namespace provides useful subsystem mocks, but application authors need a semantic render-and-input harness.

Suggested shape:

```zig
var app = try gooey.testing.AppHarness.init(State, &state, render, .{});
defer app.deinit();

try app.render();
try app.expectText("Submit");
try app.clickById("submit");
try app.expectText("Saved");
try app.pressKey(.enter);
try app.expectFocused("email");
try app.expectAccessibleRole("submit", .button);
```

Required capabilities:

- Deterministic frame execution.
- Query by stable ID, text, role, or accessible name.
- Mouse, keyboard, text, and focus event injection.
- Layout and bounds assertions.
- Accessibility-tree inspection.
- Controlled animation time.
- Async queue draining.
- Capacity-failure injection.
- Semantic tree snapshots.

Prefer semantic snapshots over pixel snapshots for ordinary component tests. Pixel tests remain useful for renderer and visual-regression coverage.

# P4: Missing standard components

The existing component catalog covers a useful foundation. The next additions should prioritize common application needs and declarative wrappers around engines Gooey already has.

## Basic controls and layout

- `Label`, including explicit accessible association with a control.
- `Divider` or `Separator`.
- `Surface` or `Card`.
- `IconButton`.
- `Link`, including external URL behavior.
- `Spinner` or indeterminate progress.
- `Switch`.
- `Slider`.
- `NumberInput` or stepper.

## Overlays and feedback

- `Popover`.
- Toast or notification manager.
- Alert or banner.
- Confirmation dialog.
- Dropdown-menu abstraction.
- Command palette.
- Loading and skeleton placeholders.

Build these on a shared overlay engine that centralizes:

- Escape dismissal.
- Outside-click handling.
- Focus trapping and restoration.
- Screen-edge collision.
- Z ordering.
- Accessibility modality.

## Forms

- Field label, description, and error composition.
- Form-level validation.
- Dirty and touched state.
- Submission state.
- Error summary.
- Focus-first-invalid-field behavior.
- Group-level radio and checkbox validation.
- Consistent disabled and read-only semantics.

Keep form facilities composable and statically bounded; avoid a dynamic form framework unless a concrete application requirement justifies it.

## Application shell

- Toolbar.
- Status bar.
- Split pane.
- Resizable panels.
- Sidebar or navigation list.
- Breadcrumbs.
- Declarative tree component over `TreeList`.
- Declarative table component over the data-table engine.
- Closable and reorderable tabs.

Wrapping existing retained engines is likely higher value than introducing parallel state systems.

# Suggested implementation order

## Milestone 1: Fail loudly

1. Validate `App` options at compile time.
2. Separate cancellation from errors in file dialogs.
3. Propagate queue failures.
4. Expose retained-state insertion failures.
5. Add structured capacity diagnostics.
6. Replace meaningful platform no-ops with capability checks or errors.

## Milestone 2: Stabilize lifecycle

1. Add multi-window cleanup tests.
2. Add per-tick observation tests.
3. Make frame failure cleanup atomic.
4. Verify mixed-DPI windows.
5. Define native and WASM lifecycle parity.

## Milestone 3: Normalize the API

1. Type `setGlassStyle`.
2. Normalize retained-state accessor names.
3. Deprecate `getGooey`.
4. Standardize handler terminology.
5. Replace invalid callback combinations with tagged unions.
6. Document component identity requirements.

## Milestone 4: Improve adoption

1. Publish the API guide.
2. Publish the platform matrix.
3. Publish ownership and lifetime rules.
4. Reorganize and compile-test examples.
5. Rewrite the multi-window consumer guide.

## Milestone 5: Improve application confidence

1. Build the headless application harness.
2. Add semantic queries and input injection.
3. Add accessibility assertions.
4. Add deterministic animation and async control.
5. Use the harness for standard component conformance tests.

## Milestone 6: Fill component gaps

1. Add basic controls and layout utilities.
2. Centralize overlay behavior.
3. Add form composition utilities.
4. Wrap existing tree, table, and scroll engines.
5. Add desktop application-shell components based on real example needs.

# Definition of done

The roadmap is complete when:

- Configuration typos fail compilation.
- Cancellation, absence, unsupported operations, and failures have distinct representations.
- Every fixed-capacity failure is observable and actionable.
- Multi-window teardown and frame lifecycle are covered by deterministic tests.
- Public terminology is consistent and free of migration-era names.
- Native and WASM differences are documented in a capability matrix.
- Ownership and retained-data lifetimes are documented.
- Documentation snippets compile in CI.
- Application authors can render, inspect, and interact with a UI in headless tests.
- Common application controls are available without bypassing the component layer.

The intended outcome is not a larger API for its own sake. It is an API that remains concise on the happy path while becoming predictable, explicit, and easy to diagnose when an application reaches an invalid or unsupported state.
