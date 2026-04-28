# Gooey Architectural Cleanup Plan

> A deep-dive review of Gooey's module structure, public API surface, and
> dependency hygiene — with a concrete cleanup roadmap informed by what Zed's
> GPUI does well.

## TL;DR

Gooey is in better shape than most ~140 KLOC Zig codebases — every directory
has a `mod.zig`, namespaces are layered, and `core/interface_verify.zig`
provides compile-time platform-backend checks. But the architecture has
drifted in a few specific ways:

| Issue | Symptom |
|---|---|
| **`Gooey` is a god object** | 1,984 lines, ~50 public methods, depends on widgets/a11y/svg/image/debug/text/scene/layout |
| **`Cx` largely re-exports `Gooey`** | 1,971 lines, 60+ methods, mostly thin wrappers + widget-specific list APIs |
| **Layering is muddy** | `context/` imports from `widgets/`, `ui/builder.zig` reaches into `widgets/uniform_list.zig`, `runtime/` directly imports widget state |
| **Two parallel scene/svg modules** | `scene/svg.zig` (path parsing) vs `svg/mod.zig` (rasterizer + atlas) — namespaces collide |
| **`root.zig` has 100+ flat re-exports** | Hard to see what's API surface vs. convenience alias |
| **Owned/shared resources tracked by `_owned: bool` flags** | Six ownership flags on `Gooey` — error-prone |

None of this is "broken" — it works. But each issue makes future contributors
slower and increases the blast radius of changes.

---

## 1. Current module dependency graph (what we observed)

```
core ──────────────────┐
   ▲                   │
   │                   ▼
input              geometry, shader, stroke, limits
   ▲
   │
scene ────► svg (path parsing in scene, rasterizer in svg/)
   ▲
   │
text, image, svg, layout (siblings, mostly independent)
   ▲
   │
context ───► widgets  ◄── BACKWARD EDGE (context imports widget state)
   ▲              ▲
   │              │
ui/builder ───────┘  ◄── BACKWARD EDGE (ui knows about specific widgets)
   ▲
   │
components
   ▲
   │
runtime ──► cx ──► Gooey  (cx is mostly a wrapper around Gooey)
   ▲
   │
app
```

The two backward edges (`context → widgets`, `ui → widgets`) are the
structural smells. They exist because `Gooey` and `Builder` host the storage
for retained widget state.

---

## 2. The `Gooey` god object

`src/context/gooey.zig` has accumulated everything frame-related:

- Layout engine (`layout`, owned flag)
- Scene (`scene`, owned flag)
- Text system (`text_system`, owned flag)
- SVG atlas (`svg_atlas`, owned flag)
- Image atlas (`image_atlas`, owned flag)
- Widget store (`widgets`)
- Focus manager (`focus`)
- Dispatch tree (`dispatch`)
- Entity map (`entities`)
- Keymap (`keymap`)
- Drag/drop state
- Hover state + ancestor cache
- Accessibility tree + bridge
- Async image loading queue
- Cancel groups
- Blur handlers (fixed array of 64)
- Deferred command queue
- Debugger
- Window pointer + cached dimensions
- Per-window root state pointer (type-erased)

It has `initOwned`, `initOwnedPtr`, `initWithSharedResources`,
`initWithSharedResourcesPtr` — four init paths to keep in sync, with
field-by-field WASM stack-budget initialization duplicated three times.

```zig
pub const Gooey = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    // Layout (immediate mode - rebuilt each frame)
    layout: *LayoutEngine,
    layout_owned: bool = false,

    // ...

    // SVG and Image atlases (pointers for resource sharing)
    svg_atlas: *svg_mod.SvgAtlas,
    svg_atlas_owned: bool = false,
    image_atlas: *image_mod.ImageAtlas,
    image_atlas_owned: bool = false,
    // ...
};
```

### Cleanup direction

**Split `Gooey` into composable subsystems with explicit ownership.**

Introduce a `Resources` struct that holds the *shared, expensive* things
(text, svg atlas, image atlas) and a `FrameContext` struct for *per-window*
things (layout, scene, dispatch, hover, drag, deferred queue). `Gooey`
becomes a thin orchestrator:

```zig
pub const Resources = struct {       // Lifetime: app, shared across windows
    text_system: *TextSystem,
    svg_atlas: *SvgAtlas,
    image_atlas: *ImageAtlas,
    image_loader: ImageLoader,       // owns Io.Group + Queue + pending/failed sets
    pub fn init(...) !Resources { ... }
    pub fn deinit(self: *Resources) void { ... }
};

pub const FrameContext = struct {    // Lifetime: per-window, per-frame builder
    layout: LayoutEngine,            // value, not pointer — owns it
    scene: Scene,
    dispatch: DispatchTree,
    hover: HoverState,               // extracted struct
    drag: DragState,
    deferred: DeferredQueue,
};

pub const Gooey = struct {
    resources: *Resources,           // borrowed
    frame: FrameContext,             // owned
    widgets: WidgetStore,
    focus: FocusManager,
    entities: EntityMap,
    a11y: A11ySystem,                // tree + bridge + enabled flag together
    window: ?*Window,
};
```

This eliminates all six `_owned: bool` flags — ownership is encoded in the
type system. The `initOwned` vs `initWithSharedResources` distinction
collapses to "do you create your own `Resources` or borrow one?".

It also makes the WASM stack-budget hack (`initOwnedPtr` /
`initWithSharedResourcesPtr`) less awful: each subsystem becomes a
`noinline initInPlace` and `Gooey` just calls through.

---

## 3. `Cx` is a thin wrapper that grew widget-specific APIs

`src/cx.zig` is 1,971 lines but ~80% of it is delegation. The exceptions
are the **list rendering APIs** (`uniformList`, `treeList`, `virtualList`,
`dataTable`) which are coordination logic between `Builder`, widget state,
and the render callback. These belong in `ui/builder.zig` or a dedicated
`ui/lists.zig`, not on `Cx`.

```zig
pub fn uniformList(
    self: *Self,
    id: []const u8,
    list_state: *UniformListState,
    style: UniformListStyle,
    comptime render_item: fn (index: u32, cx: *Self) void,
) void {
    const b = self._builder;

    // Sync gap and scroll state
    list_state.gap_px = style.gap;
    b.syncUniformListScroll(id, list_state);
    // ...
}
```

`Cx` should expose:

1. **State access** (`state`, `stateConst`)
2. **Handler creation** (`update`, `updateWith`, `command`, `commandWith`,
   `defer`, `deferWith`)
3. **Frame primitives** (`render`, `windowSize`, `scaleFactor`, `theme`,
   `setTheme`)
4. **Resource accessors that return narrow handles** — `cx.focus()`,
   `cx.entities()`, `cx.a11y()`, `cx.io()`, `cx.allocator()`

…and **delegate widget-specific concerns to typed sub-namespaces**:

```zig
// Instead of cx.uniformList(...), cx.dataTable(...), cx.treeList(...):
cx.lists.uniform(...)
cx.lists.virtual(...)
cx.lists.tree(...)
cx.tables.data(...)

// Instead of cx.animateOnComptime, cx.springComptime, cx.staggerComptime:
cx.animate.tween(...)
cx.animate.spring(...)
cx.animate.stagger(...)
```

Sub-namespaces are zero-cost in Zig (they're just `*Cx` wrappers returned
by inline accessors).

---

## 4. Backward dependencies: `context → widgets`, `ui → widgets`

```zig
// In src/context/gooey.zig:
const TextInput = @import("../widgets/text_input_state.zig").TextInput;
const TextArea = @import("../widgets/text_area_state.zig").TextArea;
const CodeEditorState = @import("../widgets/code_editor_state.zig").CodeEditorState;

// In src/ui/builder.zig:
const uniform_list = @import("../widgets/uniform_list.zig");
```

These edges exist for two reasons:

- `Gooey.focusTextInput` etc. need to know the concrete widget types to
  call `.focus()` on them.
- `Builder` needs widget state types to compute virtualized list layout.

### Cleanup direction

**Introduce a `Focusable` trait/vtable in `context/widget_store.zig`.** All
focusable widgets register a tiny vtable:

```zig
pub const Focusable = struct {
    ptr: *anyopaque,
    vtable: *const struct {
        focus: *const fn (*anyopaque) void,
        blur: *const fn (*anyopaque) void,
        is_focused: *const fn (*const anyopaque) bool,
    },
};
```

Then `Gooey.focusWidgetById(comptime T, id)` becomes
`Gooey.focus.focusWidget(id)` — no widget-type switch in `context/`.
Adding a new focusable widget type touches only `widgets/`.

For `ui/builder.zig`'s list reach-through: invert the dependency. Move the
`computeUniformListLayout` / `openUniformListElements` /
`registerUniformListScroll` helpers **into `widgets/uniform_list.zig`**
(or a new `widgets/list_render.zig`) and have `Builder` accept a small
interface. The list widget knows its own layout math; the builder just
opens elements.

---

## 5. Two SVG modules

```
src/scene/svg.zig         — 1,768 lines — SVG path parsing + Vec2 + PathCommand
src/scene/svg_instance.zig — GPU instance struct
src/svg/mod.zig           — Atlas + rasterizer dispatch
src/svg/atlas.zig
src/svg/rasterizer.zig
src/svg/backends/{coregraphics, cairo, canvas, null}.zig
```

`scene.svg` is path parsing (input → command list), `svg/` is
rasterizer+atlas (command list → pixels → GPU). They serve different layers
but share a name and there's a `Vec2` defined in `scene/svg.zig` that
duplicates `core/vec2.zig`.

### Cleanup direction

Consolidate into one `svg/` module with submodules:

```
src/svg/
├── mod.zig         — re-exports
├── path.zig        — was scene/svg.zig (parsing → PathCommand list)
├── atlas.zig       — atlas-side caching
├── rasterizer.zig  — backend dispatch
├── instance.zig    — was scene/svg_instance.zig (GPU side)
└── backends/...
```

Have `path.zig` use `core.vec2.Vec2` instead of defining its own. The
`scene/` module then only owns purely-GPU primitives.

---

## 6. `root.zig` has 100+ flat re-exports

```zig
pub const Color = core.Color;
pub const Point = core.Point;
pub const Size = core.Size;
pub const Rect = core.Rect;
// ... 100+ more lines like this
```

Some are necessary for ergonomics (`gooey.Color`, `gooey.Button`). Many
aren't — `gooey.MotionPhase`, `gooey.RowRange`, `gooey.spring_mod` (a whole
module re-exported as a struct alias!).

### Cleanup direction

Promote a **two-tier API**:

- **Tier 1 — top-level**: `gooey.run`, `gooey.App`, `gooey.Cx`, the 12-15
  components, `gooey.Color`, `gooey.run`. About 25 names, hand-curated.
- **Tier 2 — namespaces**: everything else under `gooey.core`,
  `gooey.layout`, `gooey.scene`, etc. Users opt in to verbosity when they
  need it.

Delete the convenience aliases like `gooey.spring_mod`, `gooey.stagger_mod`,
`gooey.motion_mod`. Users that want them already write
`const animation = gooey.animation;` and `animation.SpringConfig`.

This is mechanical: every removal is replaced by a slightly longer access
path, but `git grep` will find them all.

---

## 7. Specific structural improvements

### 7a. Extract async image loading from `Gooey`

```zig
// In src/context/gooey.zig:
const MAX_IMAGE_LOAD_RESULTS: u32 = 32;
const MAX_PENDING_IMAGE_LOADS: u32 = 64;
const MAX_FAILED_IMAGE_LOADS: u32 = 128;
// ... three big fixed arrays + 6 methods bolted onto Gooey
```

`isImageLoadPending`, `addPendingImageLoad`, `isImageLoadFailed`,
`addFailedImageLoad`, `drainImageLoadQueue`, `fixupImageLoadQueue` and
three big fixed arrays are bolted onto `Gooey`. This belongs in
`image/loader.zig` as an `ImageLoader` struct that `Gooey` (or rather
`Resources`) holds. ~150 lines of cleanup with no behavior change.

### 7b. Extract a `HoverState` struct

```zig
hovered_layout_id: ?u32 = null,
last_mouse_x: f32 = 0,
last_mouse_y: f32 = 0,
hovered_ancestors: [32]u32 = [_]u32{0} ** 32,
hovered_ancestor_count: u8 = 0,
hover_changed: bool = false,
```

Plus `updateHover`, `refreshHover`, `isHovered`, `isLayoutIdHovered`,
`isHoveredOrDescendant`, `clearHover`. That's 6 fields and 6 methods — a
textbook subsystem extraction.

### 7c. Extract an `A11ySystem`

```zig
a11y_tree: a11y.Tree,
a11y_platform_bridge: a11y.PlatformBridge,
a11y_bridge: a11y.Bridge,
a11y_enabled: bool = false,
a11y_check_counter: u32 = 0,
```

Plus `isA11yEnabled`/`enableA11y`/`disableA11y`/`getA11yTree`/`announce`.
The init-in-place dance for `a11y_tree` (350KB) is non-trivial;
encapsulating it in `accessibility/system.zig` localizes the WASM stack
tricks.

### 7d. Extract `BlurHandlerRegistry`

```zig
blur_handlers: [MAX_BLUR_HANDLERS]?BlurHandlerEntry = ...
blur_handler_count: usize = 0,
blur_handlers_invoked_this_transition: bool = false,
```

Plus `registerBlurHandler`, `clearBlurHandlers`, `getBlurHandler`,
`invokeBlurHandlersForFocusedWidgets`. This is a self-contained 100-line
module that's currently tangled into `Gooey`.

### 7e. The `cancel_groups` registry

Same story — fixed-capacity `[64]*Io.Group` plus four methods. Extract to
`context/cancel_registry.zig`.

---

## 8. Public-API verification

We already have `core/interface_verify.zig` for platform backends
(renderer, clipboard, svg rasterizer, image loader). Excellent — use the
same approach to **lock down module public APIs**:

```zig
// In src/api_check.zig (compiled into tests only)
comptime {
    const gooey = @import("root.zig");
    // Tier 1 surface — these names must exist forever
    _ = @TypeOf(gooey.run);
    _ = @TypeOf(gooey.App);
    _ = gooey.Color;
    _ = gooey.Button;
    // …
}
```

This catches accidental Tier-1 deletions in PR review.

---

## 9. File-size red flags

| File | Lines | Notes |
|---|---|---|
| `layout/engine.zig` | 4,009 | Too large; consider splitting per-pass (sizing pass, position pass, scroll pass) |
| `ui/builder.zig` | 2,405 | Hosts virtualized-list helpers that belong in `widgets/` |
| `text/benchmarks.zig` | 2,220 | OK if benchmark-only |
| `cx.zig` | 1,971 | Mostly delegation; lists/animations should sub-namespace |
| `context/gooey.zig` | 1,984 | Split per §2 |
| `examples/showcase.zig` | 1,876 | Just an example, fine |
| `scene/path.zig` | 1,867 | Watch closely |
| `components/svg.zig` | 1,846 | Surprisingly large for a component — likely contains baked-in icon data |
| `widgets/text_area_state.zig` | 1,613 | Probably fine, but `text_input_state` (1,157) + `code_editor_state` (1,025) — opportunity for shared core in `text_common.zig` |
| `context/dispatch.zig` | 1,595 | Self-contained, OK |
| `ui/canvas.zig` | 1,594 | Self-contained |

70-line function limit per `CLAUDE.md` is going to be hard to enforce in a
4,000-line file — `layout/engine.zig` is overdue for a split.

---

# Lessons from Zed's GPUI

Gooey was originally inspired by Zed's GPUI framework. Reading through
`crates/gpui/src/{gpui.rs, app.rs, app/context.rs, window.rs, element.rs,
subscription.rs, asset_cache.rs, global.rs, prelude.rs}` and the
architecture intent doc at `_ownership_and_data_flow.rs` surfaces several
patterns Gooey should adopt.

---

## 10. The `App` ↔ `Window` ↔ `Context<T>` split

GPUI splits state across three structs with very clear lifetimes:

| Struct | Owns | Lifetime |
|---|---|---|
| `App` | entities, globals, focus map, platform, action listeners, asset cache, keymap | application |
| `Window` | `rendered_frame`/`next_frame`, `platform_window`, `sprite_atlas`, `layout_engine`, mouse position, focus listeners, tab stops | per-window |
| `Context<'a, T>` | `&'a mut App` + `WeakEntity<T>` (just a typed wrapper) | per-callback |

`Context<T>` literally `Deref`s to `App`. So when a method takes
`&mut Context<T>`, you can call any `App` method on it transparently — but
it also carries the entity-specific subscribe/notify methods.

This is exactly the cleanup §2 wants, but with a much sharper formulation
than the "Resources/FrameContext" sketch:

```rust
struct Context<'a, T> { app: &'a mut App, entity_state: WeakEntity<T> }
struct App      { entities, focus_handles, platform, keymap, globals, asset_cache, ... }
struct Window   { rendered_frame: Frame, next_frame: Frame, platform_window, layout_engine, ... }
```

For Gooey this maps to:

```zig
// App-scope (shared, expensive — what we called "Resources")
const App = struct {
    text_system: TextSystem,
    svg_atlas: SvgAtlas,
    image_atlas: ImageAtlas,
    image_loader: ImageLoader,
    keymap: Keymap,
    focus_handles: FocusMap,
    globals: GlobalMap,
    entities: EntityMap,
    asset_cache: AssetCache,
    platform: Platform,
};

// Window-scope (per-window, per-frame)
const Window = struct {
    rendered_frame: Frame,                // see §11
    next_frame: Frame,
    layout_engine: LayoutEngine,
    platform_window: PlatformWindow,
    mouse_position: PointF,
    hover_state: HoverState,
    drag_state: DragState,
};

// User-facing render context
const Cx = struct {
    app: *App,
    window: *Window,
    state: *anyopaque,
    state_type_id: usize,
};
```

This is materially better than the "Resources/FrameContext" sketch because
**`Context` doesn't introduce a third type** — it's a `*App` plus tiny
extra info. In Zig we get the same ergonomics with method-style dispatch.

---

## 11. Frame double-buffering with `mem::swap`

The single biggest "we're doing this worse than Zed" thing:

```rust
pub(crate) struct Frame {
    pub(crate) focus: Option<FocusId>,
    pub(crate) element_states: FxHashMap<(GlobalElementId, TypeId), ElementStateBox>,
    pub(crate) mouse_listeners: Vec<Option<AnyMouseListener>>,
    pub(crate) dispatch_tree: DispatchTree,
    pub(crate) scene: Scene,
    pub(crate) hitboxes: Vec<Hitbox>,
    pub(crate) deferred_draws: Vec<DeferredDraw>,
    pub(crate) input_handlers: Vec<Option<PlatformInputHandler>>,
    pub(crate) tooltip_requests: Vec<Option<TooltipRequest>>,
    pub(crate) cursor_styles: Vec<CursorStyleRequest>,
    pub(crate) tab_stops: TabStopMap,
    // ...
}

// In Window::draw():
mem::swap(&mut self.rendered_frame, &mut self.next_frame);
self.next_frame.clear();
```

Why this matters for Gooey:

- **Hit-testing happens against `rendered_frame`** while events are
  dispatched, but `next_frame` is being built simultaneously. Today our
  `DispatchTree` is rebuilt every frame and we need that ancestor-cache
  hack in `updateHover` because the tree is reset before the next mouse
  move arrives. With double-buffering this hack disappears — the previous
  frame's tree is still alive for hit testing.
- **Element state survives across frames automatically.** GPUI's
  `with_element_state(global_id, |state| ...)` looks up
  `(GlobalElementId, TypeId)` in `next_frame.element_states`, falling back
  to `rendered_frame.element_states`. This collapses our entire
  `WidgetStore` (separate per-type maps for `text_inputs`, `text_areas`,
  `code_editors`, `scroll_containers`, `uniform_lists`, `data_tables`,
  `tree_lists`) into a single map keyed by `(id, TypeId)`. Adding a new
  stateful widget is then a no-op in framework code.

Cost: roughly two `Frame` structs per window instead of "live state in
`Gooey`". That's still bounded static memory.

---

## 12. `DrawPhase` enum + per-method phase assertions

Throughout `Window`, every method asserts which phase it can be called in:

```rust
pub(crate) enum DrawPhase { None, Prepaint, Paint, Focus }

pub fn paint_quad(&mut self, quad: PaintQuad) {
    self.invalidator.debug_assert_paint();  // ← method-level guard
    // ...
}

pub fn insert_hitbox(&mut self, ...) -> Hitbox {
    self.invalidator.debug_assert_prepaint();
    // ...
}

pub fn request_autoscroll(&mut self, bounds: Bounds<Pixels>) {
    self.invalidator.debug_assert_prepaint();
    self.requested_autoscroll = Some(bounds);
}
```

This is exactly the "pair assertions" / "split compound assertions"
`CLAUDE.md` mentions, but applied as a **temporal contract**. It catches
bugs like "called `insert_hitbox` from outside a draw" at the method
boundary.

For Gooey, the equivalent is putting
`std.debug.assert(self.frame_phase == .building)` in every
`Builder.openElement`-style method. We're already at 1+ assertion per
function, and this is essentially free in release builds.

---

## 13. `SubscriberSet<EmitterKey, Callback>` and RAII `Subscription`

GPUI has *one* generic subscriber storage type used for everything
event-like:

```rust
pub(crate) struct SubscriberSet<EmitterKey, Callback>(...);

// Used uniformly for:
//   focus_listeners, focus_lost_listeners, bounds_observers,
//   appearance_observers, activation_observers, pending_input_observers,
//   global_observers, release_listeners, keystroke_observers, ...
```

And every `subscribe`/`observe` returns a `Subscription` whose `Drop`
removes the callback. `detach()` keeps it alive for the lifetime of the
observed entity.

Compare to what `Gooey` carries today:

| Gooey field | Zed equivalent |
|---|---|
| `blur_handlers: [?BlurHandlerEntry; 64]` + count | `SubscriberSet<FocusId, BlurCallback>` |
| `cancel_groups: [*Group; 64]` + count | `SubscriberSet<(), CancelGroup>` |
| `pending_image_hashes: [u64; 64]` + count | folded into `AssetCache` (see §14) |
| `failed_image_hashes: [u64; 128]` + count | folded into `AssetCache` |
| `deferred_commands: [DeferredCommand; 32]` + count | `App.pending_effects: VecDeque<Effect>` |

Five different fixed-capacity ad-hoc registries become one parameterized
type. Each instance is still bounded for static-allocation purposes (cap it
at `MAX_LISTENERS` in the `SubscriberSet` itself), but the API surface and
the maintenance cost collapses.

The Zig version:

```zig
pub fn SubscriberSet(comptime Key: type, comptime Callback: type, comptime cap: usize) type {
    return struct {
        entries: [cap]?Entry = [_]?Entry{null} ** cap,
        next_id: u32 = 0,
        // insert(key, callback) -> Subscription
        // remove(subscription)
        // retain(key, fn(*Callback) bool)  // for invocation + cleanup
    };
}
```

---

## 14. `Asset` trait + `AssetCache`

GPUI has a generic asset pipeline:

```rust
pub trait Asset: 'static {
    type Source: Clone + Hash + Send;
    type Output: Clone + Send;
    fn load(source: Self::Source, cx: &mut App) -> impl Future<Output = Self::Output>;
}

// Usage:
window.use_asset::<MyImageAsset>(&url, cx)  // returns Option<Output>, redraws when ready
```

The cache automatically dedupes concurrent loads of the same source (the
"is_first" pattern), and the view auto-redraws when load completes. We have
*exactly this pattern* hand-rolled in `Gooey` for images — the
`pending_image_hashes`/`failed_image_hashes`/`drainImageLoadQueue` sets are
reinventing this. SVG rasterization has the same shape too.

For Gooey, a generic `AssetCache(comptime AssetType)` would handle:

- async image URL fetch (current `image_load_*`)
- SVG rasterization (today: `SvgAtlas.cacheSvg`)
- font loading (today: blocking)
- future: any user-supplied `Asset` type

---

## 15. The `prelude.rs` philosophy — tiny curated re-export

GPUI's entire prelude:

```rust
pub use crate::{
    AppContext as _, BorrowAppContext, Context, Element, InteractiveElement, IntoElement,
    ParentElement, Refineable, Render, RenderOnce, StatefulInteractiveElement, Styled,
    StyledImage, VisualContext, util::FluentBuilder,
};
```

That's it. **13 names.** Most are traits, not concrete types. Concrete
types are accessed via `use gpui::TextStyle;` etc. — there's no flattened
`gpui::*` mega-import.

Compare to our `root.zig` which has 100+ flat aliases (`gooey.spring_mod`,
`gooey.MotionPhase`, `gooey.RowRange`, …). The "two-tier API" recommendation
in §6 was on the right track, but **GPUI's prelude is even tighter** — they
don't even surface concrete types in the prelude.

Concrete equivalent for Gooey:

```zig
// gooey/src/prelude.zig
pub usingnamespace struct {
    pub const run = @import("app.zig").runCx;
    pub const App = @import("app.zig").App;
    pub const Cx = @import("cx.zig").Cx;
    // That's about all the literally-everyone-needs-it items.
};
```

Everything else lives at `gooey.core.Color`, `gooey.ui.text`,
`gooey.components.Button`. Cleaner discovery, no aliasing.

---

## 16. Type-keyed `Global<G>` storage

GPUI has a `Global` marker trait + `App::set_global<G>`/`App::read_global<G>`/
`App::update_global<G>`:

```rust
pub trait Global: 'static {}

// User code:
struct Theme { colors: ColorPalette }
impl Global for Theme {}
cx.set_global(Theme { ... });
let theme = Theme::global(cx);  // type-keyed lookup
```

This replaces our patchwork of "the framework knows about themes, debugger,
render_stats, custom_shaders…". Anything not core to `App`/`Window` becomes
a user-defined `Global`. Adding a new framework-level concern doesn't add a
field to `Gooey`.

For Gooey:

```zig
pub fn Global(comptime T: type) type {
    return struct {
        pub fn set(app: *App, value: T) void { ... }   // keyed by typeId(T)
        pub fn get(app: *App) ?*T { ... }
        pub fn update(app: *App, comptime fn_(*T) void) void { ... }
    };
}
```

Implementation: a single `std.AutoHashMap(usize, *anyopaque)` keyed by
`typeId(T)`. Frees `Gooey` from carrying `debugger`, `render_stats`,
`custom_shaders`, `theme`-defaults, `keymap`, etc. directly.

---

## 17. No ownership flags — `Option<T>` and `Box<dyn>` instead

There is no equivalent of our `layout_owned: bool`, `scene_owned: bool`,
etc. in GPUI. They use:

- `layout_engine: Option<TaffyLayoutEngine>` — `take()` to use, put back to
  return ownership during method calls
- `Box<dyn PlatformWindow>` — always owned by `Window`
- `Arc<dyn PlatformAtlas>` for the sprite atlas — shared via Arc, no flag
  needed

This confirms §2's recommendation but with a cleaner approach: in Zig the
equivalent is `*LayoutEngine` (always owned) plus `?*TextSystem` for shared
resources. The owner is implied by who allocates. If multi-window needs
sharing, model it as `*Resources` (borrowed) on `Window` rather than
booleans.

---

## 18. `Element` lifecycle as an explicit three-phase trait

```rust
pub trait Element: 'static + IntoElement {
    type RequestLayoutState: 'static;
    type PrepaintState: 'static;

    fn id(&self) -> Option<ElementId>;
    fn source_location(&self) -> Option<&'static panic::Location<'static>>;
    fn request_layout(&mut self, ..., window, cx) -> (LayoutId, Self::RequestLayoutState);
    fn prepaint(&mut self, ..., bounds, &mut request_layout, window, cx) -> Self::PrepaintState;
    fn paint(&mut self, ..., bounds, &mut request_layout, &mut prepaint, window, cx);
}
```

The associated state types **flow** between phases — `RequestLayoutState`
is created in `request_layout`, passed `&mut` to `prepaint`, and again to
`paint`. This means an element's per-frame computation state has a
strongly-typed lifetime tied to the draw phases.

Today our `Builder` does layout + scene-emission in one pass via
`processChildren`. We can't easily defer painting (e.g., for tooltips that
need to know everyone's bounds first). GPUI's `defer_draw` works precisely
because of this three-phase design. If we want to do **floating popups,
drag previews, autoscroll, deferred tooltips correctly**, this is the
architecture that gets us there.

Defer this one — it's structurally bigger than the rest. But it should be
in the architectural backlog.

---

## 19. `with_element_state(global_id, fn(state) -> (R, state))`

```rust
pub fn with_element_state<S: 'static, R>(
    &mut self,
    global_id: &GlobalElementId,
    f: impl FnOnce(Option<S>, &mut Self) -> (R, S),
) -> R
```

Stored in `next_frame.element_states: FxHashMap<(GlobalElementId,
TypeId), Box<S>>`. **Any** element can attach **any** state type without
framework changes.

This is the right answer to "where does TextInput state live?" — not in a
`WidgetStore.text_inputs` map, but in the generic `element_states` map
keyed by `(id, TypeId(TextInput))`. Adding a new stateful widget type
requires zero framework changes.

For us: replace `WidgetStore`'s 6 per-type maps with one
`std.AutoHashMap(struct { id_hash: u64, type_id: u64 }, *anyopaque)`. The
free-list-on-frame-N-not-accessed-on-N+1 logic moves with it.

---

# Synthesis: the cleanup plan

Combining all the above:

| # | Task | Maps to GPUI pattern | Risk | Payoff |
|---|---|---|---|---|
| 1 | Extract `ImageLoader`, `HoverState`, `BlurHandlerRegistry`, `CancelRegistry`, `A11ySystem` from `Gooey` | n/a (just hygiene) | Low (mechanical) | Drops `Gooey` from 1,984 to ~900 lines |
| 2 | Introduce `Focusable` vtable; remove widget imports from `context/gooey.zig` | `Focusable` trait | Low | Breaks the `context → widgets` backward edge |
| 3 | Move `computeUniformListLayout`/etc. into `widgets/`; `Builder` takes a thin interface | n/a | Medium | Breaks the `ui → widgets` backward edge |
| 4 | Sub-namespace `Cx`: `cx.lists.*`, `cx.animate.*`, `cx.entities.*`, `cx.focus.*` | n/a | Low (additive; deprecate old names later) | Cuts `Cx` to ~600 lines |
| 5 | Split `Gooey` → `App` + `Window` (renamed, refocused) | `App`/`Window`/`Context` split | Medium-high (touches all callers) | Eliminates god object; clean ownership |
| 6 | Introduce `Frame` struct with `rendered_frame`/`next_frame` double buffer | `Frame` + `mem::swap` | Medium-high | Hit-test correctness; deferred draw becomes possible |
| 7 | Add `DrawPhase` enum + per-method phase asserts | `WindowInvalidator::debug_assert_*` | Low | Catches misuse at method boundary |
| 8 | Generic `SubscriberSet(K, Cb, cap)` + RAII `Subscription` | Same | Low | Collapses 5+ ad-hoc registries |
| 9 | Generic `Asset(T)` cache for image/svg/font loaders | `Asset` trait + `AssetCache` | Low | Removes 200+ lines of bespoke async tracking |
| 10 | `Global(G)` type-keyed singletons; move debugger/keymap/theme out of `Gooey` | `Global` trait | Low | `Gooey` shrinks; user extensibility |
| 11 | Single `element_states: HashMap((id, TypeId), *anyopaque)` replaces per-type widget maps | `with_element_state` | Medium | Adding widgets = zero framework work |
| 12 | Consolidate `scene/svg.zig` + `svg/` into one `svg/` module | n/a | Low | Removes name collision; one less Vec2 |
| 13 | Tiny `prelude.zig` (5–10 names); demote rest to namespaces in `root.zig` | `prelude.rs` | Medium (breaking) | API surface becomes legible |
| 14 | Encode ownership in types — drop all `_owned: bool` flags | `Option<T>` / `Box<dyn>` patterns | Medium | Memory safety improves |
| 15 | Split `layout/engine.zig` per pass | n/a | Medium | Frees the engine from 4,000-line gravity |
| 16 | Add `api_check.zig` compile-time pinning of Tier-1 surface | n/a | Low | Prevents future regressions |
| 17 | Three-phase Element lifecycle (request_layout / prepaint / paint) | `Element` trait | Large | Tooltips, drag previews, autoscroll done correctly |

## Recommended ordering

1. **#1 — Extract subsystems out of `Gooey`** (no API break). Lowest risk,
   highest leverage starting point.
2. **#8 + #9 — `SubscriberSet` + `AssetCache`** (no API break). Kills
   ~300 lines of `Gooey` and lays the foundation for #11.
3. **#2 + #3 — Break the backward edges** (no API break).
4. **#4 — Sub-namespace `Cx`** (additive; deprecate old names).
5. **#7 + #10 — `DrawPhase` + `Global<G>`** (low risk).
6. **#5 + #6 — `App`/`Window` split + `Frame` double buffer** (medium-high
   risk, big PR — the architectural earthquake).
7. **#11 + #12 — Unified `element_states` + SVG consolidation**.
8. **#13 + #14 — Trim `prelude.zig`, drop ownership flags** (breaking).
9. **#15 + #16 — Engine split, API check**.
10. **#17 — Three-phase Element lifecycle** (largest, most transformative).

Items #1–4 are independently shippable, low-risk, and each one removes a
meaningful chunk of `gooey.zig`/`cx.zig`. Items #5, #6 and #11 are the
*most architecturally transformative* — they're the difference between
"Gooey is a hand-rolled retained UI thing" and "Gooey has GPUI's data
model".

---

## What we're already doing better than GPUI

Worth calling out explicitly so we don't lose it during refactoring:

- **Static memory allocation policy.** GPUI uses `Vec` and `FxHashMap`
  everywhere — they accept allocator pressure as a tradeoff for
  flexibility. `CLAUDE.md`'s hard caps + fixed-capacity arrays are
  stricter. Don't lose this when adopting #8 and #11 — `SubscriberSet` and
  `element_states` should be fixed-capacity slot maps.
- **WASM stack budget discipline.** GPUI has no equivalent. Our
  `initInPlace`/`noinline` discipline is unique and important. Migrating to
  App/Window split needs to preserve this.
- **Zig 0.16 `std.Io` integration.** GPUI's executor is a hand-rolled
  scheduler. Ours rides the standard library. Better forward-compat.
- **Compile-time interface verification** (`core/interface_verify.zig`).
  GPUI has only runtime trait dispatch through `Box<dyn Trait>`. Our
  compile-time checks are stronger.
- **Action handler `cx.update(method)`** is more ergonomic than GPUI's
  `cx.listener_for(view, |view, e, win, cx| ...)` boilerplate.

---

## What we should explicitly skip

- The `platform/interface.zig` vtable + compile-time `Platform` type-alias
  dual API is fine. It's documented, motivated, and the duplication is
  worth it.
- The `widgets/` vs `components/` split is good (state vs. declarative
  wrapper). Keep it.
- `core/`, `input/`, `animation/`, `text/`, `image/` are well-structured
  already.
- The `CLAUDE.md` engineering doctrine (static allocation, hard limits,
  assertion density) is being followed reasonably well — don't loosen it
  during refactoring.

---

## Suggested first PR

The highest-leverage single PR that would unlock everything else is
**#8 (`SubscriberSet`) + #9 (`AssetCache`)**: low risk, no public API break,
kills ~300 lines of `Gooey`, and lays the foundation for #11.

After that, **#5 + #6 together** is the architectural earthquake — it's a
big PR but it's where Gooey starts looking like GPUI's data model rather
than a one-off retained-mode thing.
