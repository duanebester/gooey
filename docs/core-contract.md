# Gooey Core Contract

## Status

Approved on 2026-10-30, at the end of the 0.4 migration's design phase, and implemented
on `main`: milestone 1 and phase 4 shipped in v0.4.0, the packed frame and `Renderer`
contract (phase 5, §9) in v0.4.3, and the last of phase 6 in v0.5.0 and v0.5.1. The 0.4
migration is closed (2026-11-14). A change to a signature or rule here needs the same
approval as the contract, recorded under "Approved decisions".

Three promises here were deferred to 0.6:

- **Build and draw overlap** (decision 7, "Changed in phase 5"). The core keeps one frame
  in flight, so the main thread does not build while the render thread draws. Shelved on
  2026-11-14 after measuring: no kept example needs it.
- **The complete budget** (`ResourceLimits` below). Done in 0.6; Wayland's input bound
  is hard on libwayland 1.25 or later and soft before it; charts take comptime capacities.
  `FontLimits` is now `ResourceLimits.text.fonts`, the three `PaintLimits` fields that
  bound nothing are gone (0.6 plan, PR 1), layout reserves every table from `build` (0.6
  plan, PR 3), the accessibility tree is sized from `a11y` (0.6 plan, PR 4), the text
  caches from `text` (0.6 plan, PR 5), the SVG and image caches from `atlas` (0.6 plan, PR
  6), and the pending file dialogs, the completion ring's dialog paths and the text
  scratch from `events` (0.6 plan, PR 7), and the platform intake and buffers from
  `events` and `text` (0.6 plan, PR 8).
- **Drag and drop** (decision 15). Pointer and keyboard drags and drop targets are back
  (decision 19). The `.tooltip` layer is implemented (decision 21).

The example snippets (§1 and "Acceptance: todo") compile against `main` and run headless on
`TestBackend` (checked 2026-11-14).

Signatures are written in Zig and are normative. Bodies, private fields, and helper types are
left to implementation unless they affect the contract.

## Shape

```text
core/
├── root.zig        # public surface: App, Cx, ui, Handler, ElementId, ResourceLimits
├── limits.zig      # ResourceLimits (grows from PR #77's SceneLimits, now PaintLimits)
├── id.zig          # ElementId
├── element.zig     # box, text, paint; child dispatch
├── cx.zig          # Cx: state, retain, on, hovered, focused, effects
├── retained.zig    # size-class slabs, handles, sweep
├── handler.zig     # Handler, Effects
├── events.zig      # Event, EventQueue, CompletionRing
├── router.zig      # hit test, capture/bubble, focus, keymap, drag
├── layers.zig      # fragments and their order
├── records.zig     # Quad, Sprite, Mesh, Clip paint records; HitRecord
├── tick.zig        # the per-window frame driver
├── pack.zig        # paint records → packed frame (§9)
├── packed_frame.zig # the renderer input (§9)
├── app.zig         # App store and the generated entry point
└── backend.zig     # Platform, Renderer, and service contracts (comptime-verified)
```

The block is named "core", not "kernel": in Gooey "kernel" already means the operating
system kernel (§21, fbdev, evdev) and, in GPU code, a compute shader (CLAUDE.md §9).
`src/core/` already holds `limits.zig`, `reservation.zig`, and `fixed_array.zig`, which
belong here; its geometry and path math (`geometry`, `vec2`, `triangulator`, `stroke`)
moves to `src/geometry/`.

```text
platform ──push──▶ EventQueue ──┐            ┌──▶ Query (read-only, synchronous)
                                ▼            │
tick(window): drain ─▶ build ─▶ layout ─▶ emit records ─▶ pack ─▶ Renderer.draw ─▶ swap
               │         │                    │
               ▼         ▼                    ▼
            router    Cx + ui.*        PaintRecords + HitRecords (per fragment)
```

## Rules for every block

1. **Two threads, one owner each.** Build, layout, emit, and every handler run on the main
   thread. Pack, draw, and present run on one render thread per app, paced by the display.
   They meet only at the two record buffers: the main thread fills `built`, the render
   thread draws `presented`, and a completed frame swaps them. Platforms may capture events
   on any thread but only push them through a bounded queue. On macOS the render thread
   runs a `CADisplayLink` on its own run loop (approved decision 5). This removes
   `render_mutex`. The web is the one exception (decision 9): the browser gives the app
   one thread, so both sides run in sequence in each animation frame.
2. **Lifecycle.** `Lifecycle = enum { initializing, running, deinitializing }`. A debug
   allocator guard asserts that Gooey allocator calls happen only outside `running`.
3. **Phases.** `Phase = enum { idle, drain, build, layout, emit, pack, draw }`. Every core
   function that is restricted to a phase asserts it on entry.
4. **Capacity.** Every pool is sized from `ResourceLimits` at init. Exhaustion panics with the
   pool name, configured capacity, requested count, and frame number. Nothing grows,
   evicts unrelated data, or falls back to another allocator.
5. **Errors.** Core API functions return `void` unless the caller must act on a result.
   Programmer errors assert. Operating errors (decode failure, file missing, dialog
   cancelled) arrive as events with explicit outcomes; absence, cancellation, and failure
   are distinct values.
6. **Strings are not stored.** Keys, key contexts, and labels are hashed or copied into
   reserved storage at the call. No slice passed during `build` is read after the tick.

## 1. Element

```zig
pub fn box(options: Box, children: anytype) Box.Element(@TypeOf(children));
pub fn text(content: []const u8, style: Text) Text.Element;
pub fn paint(
    comptime Data: type,
    data: *const Data,
    comptime paint_fn: fn (data: *const Data, painter: *Painter) void,
    style: Style,
) Paint(Data);

/// Per-instance identity and behaviour. These fields carry per-element arguments
/// (handler args, keys, accessibility text), so they are never shared constants.
pub const Box = struct {
    key: ?Key = null,
    style: Style = .{},
    layer: ?Layer = null,          // see block 6
    focusable: bool = false,
    tab_stop: bool = true,         // false: focusable, but Tab skips it (0.4.2)
    key_context: ?KeyContext = null,
    on_click: ?Handler = null,
    on_click_outside: ?Handler = null,
    on_context_menu: ?Handler = null, // right press, macOS Ctrl+press, Shift+F10 (decision 22)
    on_key: ?Handler = null,
    on_pointer_drag: ?Handler = null, // pointer capture, needs `key` (0.6, decision 19)
    draggable: ?DragSource = null,    // needs `key`; not with `on_pointer_drag` (decision 19)
    drop_target: ?DropTarget = null,  // needs `key` (decision 19)
    actions: []const ActionBinding = &.{},
    a11y: ?A11y = null,
};

/// Layout and appearance: plain data with no per-element arguments, so a `Style`
/// can be a shared constant, chosen per state, and compared or hashed.
pub const Style = struct {
    direction: Direction = .column,
    width: Sizing = .fit,
    height: Sizing = .fit,
    width_min: ?f32 = null,
    width_max: ?f32 = null,
    height_min: ?f32 = null,
    height_max: ?f32 = null,
    padding: Edges = .zero,
    gap: f32 = 0,
    alignment: Alignment = .start,
    wrap: bool = false,            // rows only: break into lines (decision 24)
    aspect_ratio: ?f32 = null,     // width / height; height follows width (decision 24)
    grid: ?Grid = null,            // lay children out on a grid (decision 28)
    cell: Cell = .{},              // where this box sits in its parent's grid (decision 28)
    background: ?ColorToken = null,
    border: ?Border = null,
    corner_radius: Corners = .zero,
    shadow: ?Shadow = null,
    opacity: f32 = 1,
    clip: ClipPolicy = .none,
    scroll: ?Scroll = null,        // offset retained by the box's key; anchor = .end follows
    cursor: ?CursorShape = null,
    pointer_events: PointerEvents = .auto,
    source: ?std.builtin.SourceLocation = null,  // decision 16
};

pub const Sizing = union(enum) { fit, grow: f32, fixed: f32, percent: f32 };
pub const Direction = enum { row, column };

pub const Grid = struct {
    columns: []const Track,        // 1 to `grid_track_count_max` (32)
    rows: []const Track = &.{},    // the first rows; every later row is `row_implicit`
    row_implicit: Track = .fit,
    row_gap: ?f32 = null,          // null: `Style.gap`
};
pub const Track = struct {         // `.fit`, `.fixed(px)`, `.grow(weight)`, `.percent(f)`
    sizing: Sizing = .fit,
    min: f32 = 0,
    max: f32 = std.math.floatMax(f32),
    cell_alignment: ?Alignment.Cross = null,  // null: the grid's `alignment`
};
pub const Cell = struct {
    column: ?u8 = null,            // null: the next free column
    column_span: u8 = 1,
    row: bool = false,             // a row box: one row of cells on the grid's columns
};
```

A shared card style, a hover variant, and per-element fields beside it:

```zig
const card: ui.Style = .{
    .padding = .all(16),
    .gap = 8,
    .background = .surface,
    .border = .{ .width = 1, .color = .border },
    .corner_radius = .all(8),
    .cursor = .pointer,
};

const card_hover: ui.Style = blk: {
    var style = card;
    style.background = .overlay;
    style.shadow = .{ .blur = 12, .offset_y = 2 }; // default colour: black at 15%
    break :blk style;
};

const ProjectCard = struct {
    index: u32,

    pub fn render(self: ProjectCard, cx: *gooey.Cx) void {
        const s = cx.state(State);
        const id = cx.id(.{ .index = self.index });
        cx.render(ui.box(.{
            .key = .{ .index = self.index },
            .style = if (cx.hovered(id)) card_hover else card,
            .on_click = cx.on(State.openProject, .{ .arg = self.index }),
            .a11y = .{ .role = .button, .label = s.projects[self.index].name() },
        }, .{
            ui.text(s.projects[self.index].name(), .{ .size = 16 }),
            ui.text(s.projects[self.index].summary(), .{ .color = .muted }),
        }));
    }
};
```

`card` and `card_hover` are comptime constants shared by every card. Only the key, the
handler argument, and the accessibility label differ per element.

Contract:

- **Children** are elements, components, tuples, optionals, and arrays or slices of
  components. Anything else is a compile error that names the type. A bare string is a
  compile error that suggests `ui.text`.
- **Components** are structs with `pub fn render(self, cx: *Cx) void`. They emit through
  `cx.render`. Rendering depth is bounded (see "Exceptions"). `Cx` is opaque, so a
  component reaches the window only through `Cx`'s methods, as an app does (decision 20).
- **Style and Box split by lifetime.** `Style` holds what can be shared: layout, paint, and
  per-state appearance such as `scroll`, `cursor`, and `pointer_events`. `Box` holds what
  is per element: the key, handlers, actions, focus, layer, and accessibility. Zig has no
  struct spread, so a flat struct would make every reuse a copy and mutate. Shared styles
  are constants (`const card: ui.Style = .{ ... }`), and a box sets per-element fields
  beside one: `ui.box(.{ .style = card, .on_click = h }, ...)`. `paint` takes the same
  `Style`; a painted area that needs a key, handlers, or accessibility sits inside a `box`
  that carries them.
- **Grow weights.** Siblings sized `.{ .grow = weight }` split their parent's free
  main-axis space by weight, each clamped between its content's floor and its
  `width_max` or `height_max`. The floor is the narrowest the content goes without
  cutting it: a wrapping text's widest word, a row's children's floors side by side
  (decision 26). On the cross axis a grow box fills its parent whatever its
  weight. A weight must be finite and greater than 0; any other weight panics.
- **Heights after widths.** Text wraps at its final width before any height is sized,
  so a height that follows a sibling's or the parent's, a stretched child in a row or a
  grow child in a column, counts every wrapped line (decision 27).
- **Grid.** A box with `grid` places its children in cells, row-major in declaration
  order, and sizes its columns once from all of them, so every row shares the same column
  lines; `docs/layout-grid.md` specifies placement, track sizing, row boxes, and the
  checks. A child without a `cell` takes the next free column. A row box
  (`cell.row = true`) spans one row and lays its own children on the grid's columns, so a
  keyed, hoverable table row keeps its cells under the header's (decision 28).
- **Percent.** `.{ .percent = fraction }` along the parent's direction is that fraction of
  the parent's content size less the gaps between its flow children, so fractions that
  add up to 1 fill the parent exactly; on the cross axis it is the fraction of the content
  size. In a wrapping row it is of the row's content width (decision 25).
- **Overflow.** When a row's or column's children do not fit, its `.fit` and `.grow`
  children shrink largest first, as Clay shrinks them, to a common size, and none
  shrinks below its floor; `.fixed` and `.percent` children keep their size, and what
  the floors cannot fit overflows. A wrapping text a row shrinks wraps at its new width
  (decision 26).
- **Opacity** multiplies the alpha of everything a box or paint element and its subtree
  draws, including the layers it opens; nested values multiply. Each record fades on its
  own, so overlapping children show through each other rather than fading as one group.
  Scrollbars fade with their scroll box; the keyboard focus ring stays at full strength.
  Hit testing and accessibility ignore opacity. A value outside 0–1, or NaN, panics in
  every build mode.
- **`pointer_events = .none`** applies to the one box: pointer hit tests skip it, so a
  press, release, hover, cursor, wheel, or `Query.hitTest` reaches whatever is below or
  around it. Its children still take the pointer and bubble through its handlers. Focus,
  Tab, keys, and actions are unchanged.
- **Hover styling** is not a style field. Components read `cx.hovered(id)` and choose a
  style: `.style = if (cx.hovered(id)) card_hover else card`. Hover changes request a
  render.
- **Text** colour defaults to the theme's `text` token. `ColorToken` is either a theme token
  or a literal colour.
- **Text editing** is not an element. `components.TextInput` composes `box`, `paint`,
  `focusable`, `on_key`, and a retained text engine (block 3).
- **Lists** are not statements. `components.List` composes a box with `style.scroll`,
  retained viewport state, and a row component, rendering only visible rows.
- **Lazy conditionals.** `ui.when(cond, fn)` takes a render function, not a built tuple.

Replaces: 17 `PrimitiveType` kinds, `StackStyle`, `CenterStyle`, the flat style-plus-handler
structs, `hstack`, `vstack`, `root`,
`rect`, the `ui.Button` and input primitives, `hover_*` fields, `cx.lists.*`.

## 2. ElementId

```zig
pub const ElementId = enum(u64) {
    root = 0,
    _,

    pub fn child(parent: ElementId, key: Key) ElementId;
    pub fn auto(parent: ElementId, sibling_index: u32) ElementId;
    pub fn isKeyed(self: ElementId) bool;
};

pub const Key = union(enum) { name: []const u8, index: u64 };
```

Contract:

- `child` mixes the parent id with the key hash. The top bit marks a keyed id; `auto` ids
  have it clear.
- Retained state, focus, scroll, animation, and accessibility identity require keyed ids;
  each asserts `isKeyed`.
- A duplicate key under one parent panics in Debug with both keys' source locations.
- Hit records and the accessibility tree use this id. The layout engine has no identity
  of its own: the core opens one layout element per node and reads its bounds by index
  (0.3.1's `LayoutId` was removed in #226).
- `cx.id(key)` returns the id a child box with that key gets under the element being
  built (`ElementId.child(current, key)`), so a component can ask `cx.hovered(id)`,
  `cx.focused(id)`, or `cx.focusVisibleWithin(id)` before it emits the box.

Replaces: about 11 identity schemes, three `typeId` copies, string-keyed blur handlers and
key contexts.

## 3. Retained store

```zig
pub const Lifetime = union(enum) {
    frame,              // swept after `retained.sweep_delay_frames` untouched frames
    scope: ElementId,   // alive while the scope id is rendered
    owned,              // released only by `release`
};

pub fn Handle(comptime T: type) type; // { slot: u32, generation: u32 }

pub fn retain(
    cx: *Cx,
    comptime T: type,
    id: ElementId,
    lifetime: Lifetime,
    comptime init: fn (value: *T) void,
) Handle(T);
pub fn get(cx: *Cx, comptime T: type, handle: Handle(T)) *T;
pub fn release(cx: *Cx, comptime T: type, handle: Handle(T)) void;
```

Contract:

- Slots come from size-class slabs (64 B, 256 B, 1 KiB, 4 KiB). `@sizeOf(T)` above the
  largest class is a compile error; larger state uses a dedicated pool (text engines).
- `get` asserts the generation and the current tick. Pointers do not survive the tick.
- A sweep releases a `.frame` entry once it has been untouched for the delay, so exit
  animations can finish. It releases a `.scope` entry once its scope is not rendered. It
  never releases `.owned` entries.
- There is no keep-alive. State that must survive its element being hidden, such as a hidden
  tab's scroll offset or text, is an entity field or an `.owned` handle the app keeps.
- `release` asserts `.owned`. Releasing twice is a generation mismatch and panics.
- Text engines use three dedicated pools, one per kind, sized by `limits.text`: single-line
  inputs, multi-line areas, and code editors. Each slot has a fixed byte buffer and a fixed
  undo depth, and never grows. A kind with a count of 0 reserves nothing. Exhaustion panics
  with the pool's name and count, for example "text pool 'area' exhausted (16 slots)".
- Animations, scroll offsets, list viewports, and change memos are ordinary `T`s.
  `core.animation` (`tween`, `tweenOn`, `motion`) is a library helper over `retain`
  (decision 14). There is no `cx.changed`; a change memo is a retained `T` the component
  compares itself.

Replaces: `element_states`, `AnimationStore`, `ChangeTracker`, `Builder.pending_*`, app-owned
list states, `Window.widgetState`, `cx.textField` and its siblings.

## 4. Handler

```zig
pub const Handler = struct {
    invoke: *const fn (app: *anyopaque, target: Target, arg: u64, effects: *Effects) void,
    target: Target,
    arg: u64,
};

pub fn on(cx: *Cx, comptime method: anytype, options: anytype) Handler;
```

Accepted method shapes, detected at comptime:

```zig
fn (state: *State) void
fn (state: *State, arg: Arg) void
fn (state: *State, effects: *Effects) void
fn (state: *State, arg: Arg, effects: *Effects) void
```

Contract:

- `options` accepts only `.arg` and `.entity`. Unknown fields are compile errors. `.arg` is
  coerced to the method's `Arg` type, so integer literals need no `@as`. `@sizeOf(Arg) > 8`
  is a compile error.
- `State` must be the app's root state, a registered entity type, or state retained with
  `cx.retain` (0.4.2), whose handle is passed as `.entity`, so a component can handle events
  on state of its own. In Debug and ReleaseSafe builds, `on` checks this when the handler is
  built, during `build`, so a mismatch panics on the first frame and names the handler's
  method and source location. ReleaseFast and ReleaseSmall compile the check out. See
  "Approved decisions".
- `Effects` is the narrow command context: focus and blur, request render, stop
  propagation, quit, file dialogs (`openFileDialog`), fonts (`setFont`), themes
  (`setTheme`), screen-reader announcements (`announce`), entities (`create`, `remove`),
  completion handlers (`handler`), the event being handled (`inputEvent`,
  `completionEvent`), clicking a keyed element in the frame on screen (`click`,
  0.4.2), which runs its `on_click` after the handler and cannot click again,
  background jobs (`spawn`, `cancelJob`, `jobResult`, `jobDone`, `jobId`; 0.6, see
  "Background jobs" below), and moving a scroll box (`scrollTo`, 0.6, §5). It has no
  window open or close (one window per app, decision 14) and no access to `Window`
  internals. Timed renders are requested from `render`
  (`cx.requestRenderAfter`); the clipboard belongs to the text engines (decision 10).
- Every handler is invoked by the router from the drain phase, on the main thread. The number
  of invocations per tick is bounded by the number of drained events.

### Announcements

`effects.announce(text, politeness)` adds one announcement to the window's pending set; the
next build copies the set into its frame, and the screen reader receives it when that frame
is flipped on. Drains keep running while a frame is in flight, so any number of
announcements can be made before a build. The pending set therefore behaves as a pair of
live regions, as the platforms' own queues do (ARIA assertive and polite regions, UI
Automation's `NotificationProcessing.ImportantMostRecent`, VoiceOver's priorities), and
replacement is defined behaviour, not loss:

- **Assertive:** at most one is pending. A newer assertive announcement replaces it.
- **Polite:** a FIFO of at most `a11y.announcement_polite_pending_max`. A newer polite
  announcement past that count replaces the oldest pending polite one.
- **Order:** the survivors reach the screen reader in the order they were announced. A
  replacement is a new announcement, so it follows every survivor.
- **Bytes:** each announcement's text is copied into a slot of
  `a11y.announcement_message_bytes_max` bytes. A longer text is a capacity-planning error
  and fails fast naming that field; nothing else about announcements can fail.

### Background jobs (0.6)

A job is a type in `Config.jobs` with `Input`, `Result`, `posts_max: u32` (the most
results one run posts, at most `events.job_result_count_max`, checked at comptime), and
`run(input: *const Input, job: *gooey.Job(Result)) !void`. The rules:

1. `effects.spawn(Job, &input, .{ .on_result, .on_done })` copies `input` into a free job
   slot and returns a `JobId`. With every slot busy (`events.job_count_max`), not counting
   a job whose `on_done` is running, it returns `error.JobBusy` and starts nothing: clicks
   decide how many spawns a drain asks for, so the caller handles the refusal. `Input`
   must not contain a pointer or slice (compile error): a job never reaches `State`.
2. Natively each slot has a runner, alone in its own `std.Io.Group`, and an interrupter in
   the pool's group, started at init with `io.concurrent` only when `Config.jobs` is
   non-empty. Without threads (the web, `-fsingle-threaded`) a job runs on the main thread
   after the drain that spawned it.
3. `job.post(&result)` copies the result into one of `events.job_result_count_max` slots,
   pushes it onto the completion ring, and calls the host's thread-safe wake
   (`Window.bindWake`). With every slot held it waits on its worker until a drain frees
   one. Without threads a post cannot wait, so a queued job starts only while its
   `posts_max` result slots are free: queued jobs run in spawn order, as many as fit in
   this drain, the rest after the next. A run that posts more than its `posts_max` panics
   there; with workers it waits like any post. It returns false once the job is cancelled
   or the app is stopping.
4. The drain routes job deliveries after the queued events, in ring order: `on_result` per
   result, in post order, then `on_done` once with `.finished`, `.cancelled`, or
   `.failed`. Both are root-state handlers. A result is valid until its handler returns.
   The job's slot is freed, under a new generation, just before `on_done` runs, so
   `on_done` can spawn a chained job or a retry into it. The id `on_done` receives is
   then stale: cancelling it does nothing, and it still equals the id the app stored.
5. `effects.cancelJob(id)` never waits: posts return false, `job.cancelled()` is true,
   undelivered results are dropped, and `on_done` reports `.cancelled`. A job not yet
   started never runs. Natively a running job is interrupted: its slot's interrupter
   cancels the runner's group, so the job's Io cancellation points return
   `error.Canceled`, then starts the slot's next runner (the one task the pool asks the io
   for after init) and delivers the end. A stale id does nothing.
6. `App.stop` sets `stopping`, cancels the pool's group, whose interrupters cancel their
   runners' groups (every Io cancellation point in a job, a blocked post, and an idle
   wait return `error.Canceled`), and awaits every task.
   Then `Config.on_deinit(state)` runs, then teardown. A job not started by then never runs,
   and no delivery is routed after `stop`.
7. The completion ring is multi-producer (a producer mutex) and holds
   `dialog_count_max + 1 + job_result_count_max + job_count_max` entries, which
   `ResourceLimits.check` enforces, so it cannot fill.

Replaces: `update`, `updateWith`, `command`, `commandWith`, `onSelect`, `OnSelectHandler`,
bare `fn () void` callbacks, `*_handler` field suffixes, the parallel listener lists.

## 5. Runtime

```zig
pub const Event = union(enum) {
    input: InputEvent,
    completion: Completion,
    window: WindowEvent,
};

pub const EventQueue = struct {
    pub fn push(self: *EventQueue, event: Event) void;
};

pub const Query = struct {
    pub fn hitTest(self: *const Query, point: Point) ?ElementId;
    pub fn imeCursorRect(self: *const Query) ?Rect;
    pub fn imeOwner(self: *const Query) ?ElementId; // a change ends the IME composition
    pub fn imeSelectedRange(self: *const Query) ?TextRange;
    pub fn keymapClaims(self: *const Query, key: KeyEvent) bool;
};

pub fn tick(app: *App, window: *Window, now_ns: u64) void;
```

Contract:

- `push` runs on the main thread. Worker-thread completions use a separate bounded
  single-consumer `CompletionRing` that `tick` drains.
- Overflow policy: consecutive pointer moves, consecutive held-button moves of the same
  button, and scroll deltas coalesce. Any other overflow panics with the queue name and
  capacity.
- `Query` reads only `rendered_frame`. It cannot mutate state, invoke handlers, or re-enter
  the core. It exists for platform calls that need an answer before they return
  (`firstRectForCharacterRange`, `performKeyEquivalent`).
- `tick` stages: drain (route events, invoke handlers), build, layout, emit, pack, draw, swap.
  It asserts each phase transition and skips build through draw when nothing requested a
  render.
- Routing is one algorithm for every event kind: hit test (or the focus path for keys),
  capture from root to target, then bubble. A handler can stop propagation through
  `Effects`.
- Focus is an `ElementId` per window. Tab order is tree order among `focusable` boxes that
  are tab stops (`tab_stop`, 0.4.2; a listbox's options are not). A focused id that was not
  rendered this tick, or no longer takes focus, passes focus to its nearest focusable
  ancestor, else the nearest Tab stop after it, else before it, in the frame it left
  (0.4.2), or else to none. A key no `on_key` handler stopped has a default (0.4.2): Tab and
  Shift+Tab move focus, and Enter or Space without Cmd, Ctrl, or Alt, and not a repeat, runs
  the focused element's `on_click`. Tab skips, and focus drops, records below the last modal
  fragment. Focus the keyboard moved draws a 2 px `border_focus` ring 2 px outside the box,
  and scrolls the innermost scroll box to it once, and again when a layout change moves the
  box within that scroll box's content; a press does neither.
- Keymap bindings live in the app store. Key contexts are comptime-hashed. The router matches
  bindings along the focus path, then bubbles `actions`. The focus path is the focused
  element and its ancestors, or the top-level elements when nothing is focused. The last
  matching binding wins, as in 0.3.1, and a handled action consumes the key, which then
  reaches neither `on_key` nor the IME. `keymapClaims` answers the same question for the
  platform before it hands a key to the IME.
- **Clicks.** `on_click` fires on a left release over a record the left press also landed
  in, bubbling from the record under the pointer; a left drag or capture that moved more
  than 2 px clicks nothing. Right and middle presses focus, run click-outside handlers, and
  start captures and drags, but their releases click nothing and leave a left press's
  path alone, as a browser's `click` versus `auxclick`. Enter and Space click as above.
- **Context menus.** A right press, or on macOS a left press with Ctrl, runs
  `on_context_menu` on the nearest record from the one under the pointer up that has one,
  after the press's click-outside handlers and focus move, as a browser's `contextmenu`
  follows `mousedown`. A macOS Ctrl+press clicks nothing and takes no scrollbar, capture, or
  drag. Shift+F10 that no `on_key` handler stopped runs it from the focused record up, as
  Enter and Space click. Only that one handler runs (decision 22).
- **Scrollbars.** A left press on a scroll box's bar drags its thumb or jumps along its
  track, and is consumed: no click, focus, or click-outside. The left release ends a thumb
  drag. Other buttons, and any press while a thumb drag is on, land as usual and leave the
  drag alone, as native scrollbars do.
- **Pointer capture** (0.6, decision 19). A press whose path holds a record with
  `Box.on_pointer_drag` (the innermost such record, after the scrollbar's claim) captures
  the pointer for that record. Its handler gets `begin` on the press, `move` for every
  coalesced pointer move, wherever the pointer goes, and `end` on the same button's
  release; Escape (consumed) or `InputEvent.pointer_cancelled` gives `cancel` instead.
  `effects.pointerDrag()` reads the phase, the pointer, and the press point. A move past
  2 px from the press means the release clicks nothing; one that stays within it clicks as
  usual. While captured, the cursor stays the one under the press. Each step finds the
  record by id in the frame on screen, so a box that stops rendering ends the capture
  with no call; a capturing box must be keyed. `effects.bounds(id)` reads a keyed
  element's hit bounds from the frame on screen.
- **Drag and drop** (0.6, decision 19).

  ```zig
  pub const DragSource = struct {
      pub fn of(comptime T: type, payload: T) DragSource; // @sizeOf(T) <= 8, no pointers
  };
  pub const DropTarget = struct {
      pub fn of(comptime T: type, on_drop: Handler) DropTarget;
  };
  pub fn Drag(comptime T: type) type; // { payload, over, x: f32, y: f32, keyboard: bool }
  pub fn drag(cx: *const Cx, comptime T: type) ?Drag(T);
  pub fn dropPayload(effects: *const Effects, comptime T: type) ?T; // inside on_drop
  pub fn startDrag(effects: *Effects, id: ElementId) bool; // keyboard pick-up; started?
  ```

  A press whose innermost gesture record is `Box.draggable` arms a drag of a copy of its
  payload, which starts once the pointer moves more than 2 px; a started drag clicks
  nothing. `over` is the innermost `drop_target` of the payload's type under the pointer
  that a hit test reaches, or `.root`, recomputed on each move and after each flip. A
  release of the pressing button over one calls its `on_drop`, where
  `effects.dropPayload(T)` reads the payload; a release anywhere else, Escape (consumed),
  or `pointer_cancelled` ends the drag with no call. `cx.drag(T)` reports a started drag
  whose payload is a `T`. A draggable or drop target must be keyed, and a box cannot be
  both draggable and capturing. Per move a drag costs no more than hover: the same hit
  test finds `over`.

  `effects.startDrag(id)`, from a handler of the app's choosing (the core adds no default
  key), starts a keyboard drag of keyed draggable `id`, active at once and `over` nothing;
  a gesture already on, or an `id` not on screen, starts none, and an `id` on screen with
  no `draggable` panics. It returns whether the drag starts, from facts the router sets on
  `Effects` before the handler (the gesture is idle, the frame on screen), and the router
  asserts that the drag it then starts, or does not, matches; an app announces a pick-up
  only on true. While it is on, the router takes every key before the keymap:
  Tab, Shift+Tab, and the arrows move `over`, with focus and its ring, to the next or
  previous drop target of the payload's type in tree order that the pointer could reach,
  wrapping, one scan of the hit records per key; Enter or Space drops on `over`; Escape
  cancels; any other key, `key_up`, text, and composition go nowhere. A drop leaves focus
  on a focusable target, where the screen reader stays to read the drop's announcement;
  otherwise, and on a cancel, focus returns to the source. A press or `pointer_cancelled`
  cancels. The pointer
  does not move it; `x` and `y` are the centre of `over`, or of the source over none,
  followed after each flip, and an `over` that stops rendering becomes `.root`. The
  target holds focus though it is not focusable, so the screen reader reads its label;
  the app announces the pick-up and the drop.
- **Programmatic scroll** (0.6).

  ```zig
  pub const Scroll = struct { x: bool = false, y: bool = true, anchor: ScrollAnchor = .start };
  pub const ScrollAnchor = enum { start, end };
  pub const ScrollTarget = union(enum) {
      start,
      end,
      offset: ScrollOffset,  // { x, y }, logical px from the content's start
      child: ScrollChild,    // { key: Key, alignment: ScrollAlignment = .nearest }
  };
  pub const ScrollAlignment = enum { start, center, end, nearest };
  pub fn scrollTo(effects: *Effects, id: ElementId, target: ScrollTarget) void;
  ```

  `effects.scrollTo` hands keyed scroll box `id` a target after the handler returns, at
  most one per handler; an `id` that is not a scroll box on screen moves nothing. The next
  build gives it to that box's layout, whose position pass resolves it against the content
  it laid out that frame, before placing the children, and clamps it to the content along
  the box's axes: `.end` therefore reaches content the same handler added, and the frame
  shows it. `.child` names a direct child by key; layout measures where that child starts
  along the main axis, and `.nearest` moves as little as shows it whole, or to its start
  when it is taller than the box. A child the next build does not render is dropped. Emit
  reads the offset layout applied back into the box's retained `ScrollState` and clears
  the target. A wheel or scrollbar press before that build wins over a pending target.
  `Scroll.anchor = .end` asks layout for the end on every build while the box rests at its
  end (`ScrollState.at_end`, within 0.5 px, recomputed by every move and measurement),
  so growing content scrolls into view in the frame it appears. The wheel, the scrollbar,
  focus reveal, or a `scrollTo` that leaves the end releases it; coming back pins it. A
  box starts pinned. `components.List` honours both: it reads the pending target and the
  pin when it picks its rows, and resolves them as layout will (`List.scrollTo(effects,
  list_id, index, alignment)` names row `index`, whose box is keyed by it), so the rows it
  lands on are built in that frame. Work: one walk over the box's children per resolved
  target; no storage beyond two fields of `ScrollState`.
- **Measured text** (0.6). `cx.measureText(text, style: ui.Text, max_width) Cx.TextSize`
  returns the `{ width, height }` that `ui.text(text, style)` takes in a parent whose
  content is `max_width` wide: layout's own word breaking at that width when `style.wrap`
  wraps (lines × the style's line pitch), one measured line otherwise. It adds no element
  and allocates nothing. Sizes are cached by the text's hash and length, its style and the
  width in `text.text_size_slot_count_max` slots, which evict the least recently used, so
  a miss costs one wrap of the text and a hit one hash of it. A `List` row with a height
  per row gets `height(cx, index, width)`, the row's width being the viewport's less the
  list's side padding (0 before the first emit), so it can size from content.
- Each window keeps one render deadline: the earliest `cx.requestRenderAfter` made by the
  last build, including caret blink. Reaching it requests a render; a build that makes no
  request clears it.

Replaces: native synchronous dispatch, `WebApp.frame`'s five drain closures,
`renderFrameImpl`'s special passes, special cases for text widgets in `runtime/input.zig`,
`deferCommand`, `notify` and `notifyAfter`.

## 6. Layers

```zig
pub const Layer = struct {
    kind: Kind,
    anchor: Anchor,
    clip: enum { escape, inherit },

    pub const Kind = enum { popover, tooltip, modal, drag };
};
```

Contract:

- Every box with a `layer` opens a fragment. Among the layers opened by the same fragment,
  fragments are ordered by kind, then by open order. A layer opened inside a layer's
  fragment comes after that fragment, so a popover inside a modal is above the modal, as
  in 0.3.1. Content is fragment zero.
- Paint records and hit records carry their fragment. Paint goes in fragment order; hit
  testing goes in reverse fragment order. Both use the same order, so what is on top
  receives input.
- A modal fragment blocks hit testing of earlier fragments.
- A layer stays in the window. One anchored to its parent that would run past the window's
  top or bottom opens on the parent's other side when it fits there (0.4.2), as a menu
  opens upward near the bottom; otherwise it is clamped into the window.
- No numeric z-index is exposed.
- Every kind is implemented. A `.drag` fragment, for a drag preview, ranks above modals;
  its hit records never take the pointer, so the target under a preview stays `over`, and
  its subtree adds no accessibility nodes, since a preview repeats its source. A
  `.tooltip` fragment ranks above popovers and below modals, and its hit records never
  take the pointer either, so a tooltip cannot end its trigger's hover or block a click
  under it (decision 21). Its subtree adds accessibility nodes in tree order, as a
  popover's does.

Replaces: additive `i16` z-index, global sort of individual commands, the canvas 256-order
reservation.

## 7. App store

```zig
pub fn App(
    comptime State: type,
    comptime render: fn (cx: *Cx) void,
    comptime config: Config,
) type;

pub fn Config(comptime State: type) type {  // generic for `on_init` (decision 7)
    return struct {
        title: []const u8,
        width: u32,
        height: u32,
        limits: ResourceLimits,
        theme: *const Theme = &Theme.light,
        keymap: []const Binding = &.{},
        entities: []const type = &.{},
        fonts: Fonts = .{},
        title_bar: TitleBar = .standard,  // macOS only: .transparent over full-size content
        min_width: u32 = 0,            // smallest content size; 0 sets no minimum
        min_height: u32 = 0,
        jobs: []const type = &.{},     // background job types (0.6)
        on_init: ?*const fn (state: *State, init: Init, effects: *Effects) void = null,
        on_deinit: ?*const fn (state: *State) void = null,  // after every job returned
    };
}

pub const Init = struct {          // 0.6: what on_init receives from the process
    io: std.Io,
    environ: *const std.process.Environ.Map,
};

pub const Fonts = struct {
    name: ?[]const u8 = null,      // family name; null loads the platform's sans-serif
    size: ?f32 = null,             // points; null takes the theme's font_size_base
    mono: ?FontSource = null,      // second family; its faces: limits.text.fonts.mono_variants
};

/// A keymap entry. Actions are types (`const Redo = struct {};`) named by
/// `ui.action(Redo)`; a key context is `KeyContext.named("Editor")`.
pub const Binding = struct {
    keys: []const u8,                 // "cmd-shift-z", parsed at compile time
    action: u64,                      // ui.action(Redo)
    key_context: ?KeyContext = null,  // null binds globally
};

pub const FontSource = union(enum) {
    name: []const u8,           // an installed family, such as "JetBrains Mono"
    system: SystemFont,         // .monospace loads the platform's monospace family
};
```

Contract:

- Unknown `Config` fields are compile errors. Only `title`, `width`, `height`, and `limits`
  are required (decision 10); each example uses the smallest profile that fits it (counter
  `.nano`, todo `.small`).
- `render` is the root render function, passed positionally as in 0.3.1's `gooey.App(State,
  &state, render, ...)`. Nothing is found by name in the root file. The app owns `State`
  (initialized in place), so the 0.3.1 `&state` argument is gone.
- The generated type provides `main` on native targets and the browser exports on WASM. It is
  the only entry point; the root file declares `pub const main = App.main;` because Zig
  looks for `main` there.
- Entities live in typed fixed pools, declared in `config.entities`. Entity handles are
  generation-checked. Observer and dirty tracking are removed in 0.4.0 and return with
  subtree caching (approved decision 4), which did not ship in 0.5 and has no target
  release yet.
- Theme, keymap, and atlases are typed fields shared by every window.

Replaces: `gooey.run`, `WebApp`, `MultiWindowApp` as separate entry points, `Globals`,
reflection-copied config, the `init` and `on_init` aliasing.

## 8. Paint records (the Scene)

```zig
pub const Record = union(enum) {
    quad: Quad,
    sprite: Sprite,
    mesh: Mesh,
    clip_push: Rect,
    clip_pop,
};

pub const Quad = struct {
    bounds: Rect,
    fill: Color,
    border: Border,
    corners: Corners,
    blur: f32,          // shadows are blurred quads
    offset_x: f32,      // a shadow's offset from bounds
    offset_y: f32,
};

pub const Sprite = struct {
    bounds: Rect,
    atlas: enum { glyph, glyph_color, svg, image },  // glyph_color: no pipeline yet
    uv: Rect,
    tint: Color,
    secondary: Color,   // SVG stroke colour
    corners: Corners,   // image rounding
    grayscale: f32,
    opacity: f32,
};

pub const Mesh = struct {
    range: MeshRange,
    topology: enum { triangles, strip_expanded, point_instanced },
    fill: Color,        // solid; no gradient fills in 0.4.0 (decision 10)
    width: f32,         // strip width or point size
};
```

Contract:

- `emit` writes records into one draw-ordered stream per fragment. There are no per-kind
  arrays to merge.
- `pack` turns records into renderer input, the packed frame (phase 5, below), which every
  renderer draws through the `Renderer` contract.
- Polylines and point clouds stay GPU-expanded through `strip_expanded` and
  `point_instanced`.
- Colour glyphs (`glyph_color`) have no packed pipeline yet: nothing emits them, and pack
  fails fast if a record names that atlas.
- **Culling.** `emit` writes no paint records for what lies wholly outside the clip around
  it (a `Style.clip` or scroll box, or a layer's inherited clip): a box's fill, a shadow
  whose extent (bounds moved by its offset, grown by twice its blur) misses the clip, a
  text line whose box grown by one line pitch on every side misses it, and a clip box
  whose own clip is empty, with everything inside it. Wrapped lines are evenly pitched, so
  emit takes the lines in view by division, in constant time per text. A culled `ui.paint`
  function still runs with a painter that writes nothing, so its text widths and IME answer
  hold; it queues no image decode. Hit records stay, clipped to nothing, so Tab order,
  focus reveal, `Effects.bounds` and drop targets reach content out of view, and so do
  accessibility nodes, with their laid-out bounds: a screen reader reads and walks a whole
  scroll box, as it does a web page or a native table, and moving keyboard focus into it
  scrolls the focused box into view. Paint records, glyphs and glyph shaping therefore scale
  with the viewport, not with a scroll box's content; text bytes, wrapped lines, elements,
  hit records and accessibility nodes still scale with the content.

Replaces: nine scene arrays, about 30 `insert*` variants, `RenderCommand`, `render_bridge`.

## 9. Backend

```zig
pub const Renderer = struct {
    pub fn initInPlace(self: *Renderer, surface: *const Surface, limits: *const RenderLimits) !void;
    pub fn uploadAtlas(self: *Renderer, atlas: AtlasKind, dirty: RectPx, pixels: []const u8) void;
    pub fn draw(self: *Renderer, frame: *const PackedFrame, viewport: Viewport, clear: Color) void;
    pub fn resize(self: *Renderer, size_px: SizePx) void;
    pub fn capabilities(self: *const Renderer) Capabilities;
    pub fn deinit(self: *Renderer) void;
};
```

Contract:

- Verified at comptime by `contract.verifyFn`, like the existing platform contract.
- `resize` asserts the size is within `limits.window.framebuffer_*_max` and reuses reserved
  storage.
- `PackedFrame` holds bounded instance buffers and a draw list of
  `{ pipeline, clip, first, count }`. Draws are already in fragment order, so they carry no
  fragment. There are no post-process passes (decision 14).
- `NullRenderer` implements the contract on `src/testing/test_backend.zig` and records packed
  frames for goldens.
- `PlatformWindow` loses its `on_input` and `on_render` callbacks. It receives an
  `*EventQueue` and a `*const Query`, and signals ticks. There is one window per app and no
  liquid glass (decision 14).
- Services, each one comptime choice per target: `TextBackend` (shape, rasterize, metrics),
  `ImageDecoder` (decode into reserved staging), `SvgRasterizer`.

Replaces: three private renderer APIs, silent feature gaps per backend, `@min` truncation.

### Phase 5: the packed frame (proposed 2026-11-11, shipped in v0.4.3)

Signatures are in `src/core/packed_frame.zig` and `src/core/backend.zig`; the `Renderer`
signatures above are unchanged. `PackedFrame` is renderer input only: `gooey.internals`,
not public API (decision 18).

```zig
pub const Quad = extern struct {       // 96 B; a shadow when blur > 0
    bounds: [4]f32, fill: [4]f32, border_color: [4]f32,
    corners: [4]f32,                   // tl, tr, br, bl
    border_widths: [4]f32,             // top, right, bottom, left
    offset: [2]f32,                    // byte 80: a vec2/float2 is 8-byte aligned
    blur: f32, _pad: f32,
};
pub const Sprite = extern struct {     // 96 B
    bounds: [4]f32, uv: [4]f32,        // uv: left, top, right, bottom in 0..1
    tint: [4]f32,                      // glyph colour, SVG fill, image tint
    secondary: [4]f32,                 // SVG stroke
    corners: [4]f32,                   // image radii
    grayscale: f32, opacity: f32, _pad: [2]f32,
};
pub const Mesh = extern struct {       // 32 B
    fill: [4]f32, first: u32, count: u32,  // mesh_points[first..][0..count]
    width: f32,                        // strip: full width; points: radius
    edge_first: u32,                   // triangles: edge_modes[edge_first..]
};
pub const Pipeline = enum(u8) {
    quad, glyph, svg, image, triangles, strip_expanded, point_instanced,
};
pub const Draw = extern struct {       // 16 B
    pipeline: Pipeline, _pad: [3]u8, clip: u32, first: u32, count: u32,
};
pub const PackedFrame = struct {
    quads, sprites, meshes, edge_modes,   // instance arrays, each with a count
    mesh_points: []const MeshPoint,       // the records frame's pool, borrowed
    clips: [][4]f32,                      // clips[0] is unbounded
    draws: []Draw,
    // plus per-pool counts, limits, frame_number, and pack's edge table
};
```

Rules a backend implements:

- Walk `draws` in order. A draw renders instances `first..first + count` of its pipeline's
  kind, compositing them in index order; a backend may merge adjacent draws only if it keeps
  that order. Clip push and pop are resolved by pack; there is no clip stack in a renderer.
- A draw writes only pixels whose centres lie in `clips[clip]`, edges included. A clip with
  zero width or height writes nothing: pack skips every instance record while its clip has
  zero area, so no draw carries one, and backends assert it. Clamp the unbounded clip
  (±1e9) to the framebuffer in float before converting to integer pixels (a scissor, for
  example); at a scale above 2.147 it overflows `i32`.
- Instances are `extern`, 16-byte multiples of 4-byte scalars, with every 8-byte vector
  8-byte aligned, so GLSL std430, MSL, and WGSL declare the same structs: copy each array
  to the GPU as is. Positions are logical pixels from the top left; NDC uses
  `viewport.size_px / viewport.scale_factor`.
- Colours are straight (not premultiplied) RGBA, sRGB-encoded, blended in gamma space into
  a UNORM framebuffer: Metal's `bgra8Unorm` layer and Vulkan's preferred
  `B8G8R8A8_UNORM` swapchain. Vulkan's fallback that accepts a `_SRGB` swapchain would blend
  in linear space; a port on the contract must pick a UNORM format.
- Quads keep the 0.3.1 SDF quad and shadow shaders; shadows are now clipped like every
  other draw. Sprites keep the glyph, two-colour SVG, and image shaders, one per pipeline.
  Triangles keep the analytic edge shader of `mesh_edges.zig`: triangle `t` of a mesh is
  points `first + 3t ..+3`, with modes `edge_modes[edge_first + t]` (2 bits per edge).
  Pack classifies every edge once per frame, so no backend classifies.
- `uploadAtlas` copies before returning. Hosts feed it with
  `backend.uploadPendingAtlases(renderer, journal, key)` on the render side, before `draw`.
  That closes the journal's frame, so the next build may evict a shelf an in-flight frame
  still samples. The region must therefore reach the texture on the GPU timeline after
  every earlier submitted draw (a copy in the frame's command buffer on the same queue,
  with hazards tracked), never as a CPU write into a texture an in-flight frame may sample.
- `draw` presents; a missing drawable skips the frame and logs once. `resize` comes first
  when `viewport.size_px` changes, and `draw` asserts `viewport.size_px` equals the last
  `resize` (or init). A zero-size viewport (a minimised window) draws and presents nothing;
  pending uploads still reach the GPU.
- Hosts call `backend.checkCapabilities(renderer.capabilities(), frame)` before every
  `draw`. A frame holding meshes for a renderer whose `Capabilities.meshes` is false fails
  fast with the frame number; nothing is silently dropped.

Pack culls a quad wholly outside its clip, as 0.3.1 did, and a shadow whose drawn extent
(its bounds moved by its offset and grown by twice its blur on every side) is wholly
outside, and nothing else. Shadows are clipped like every other draw, where 0.3.1 drew them
unclipped; `record_dump` prints a shadow's clip, a known difference from 0.3.1's dumps
(no golden holds a shadow today). Consecutive records of one pipeline and clip extend one
draw; draws and clips are bounded by the paint record budget, and pack fails fast naming
the pool past it. Each pool keeps the limit the app declared
(`ResourceLimits.paint`); past one, pack fails fast naming the pool, its limit, and the
frame.

Not in this proposal: `Draw.fragment` (paint records carry no fragment, and draw order already
is fragment order), gradient fills (no kept example uses them, decision 10), and a
`glyph_color` pipeline (nothing emits colour glyphs yet; pack fails fast on one).

#### Performance sketch (§7), `.standard`

| Packed storage | Count | Unit | Reserved |
| --- | ---: | ---: | ---: |
| Quads and shadows | 4,608 | 96 B | 432 KiB |
| Sprites (glyph, SVG, image) | 9,472 | 96 B | 888 KiB |
| Meshes | 1,536 | 32 B | 48 KiB |
| Triangle edge modes | 5,461 | 4 B | 21 KiB |
| Clips and draws (one per paint record, at most) | 28,672 each | 16 B | 896 KiB |
| Edge table (pack scratch, `mesh_edges.EdgeTable`) | 24,577 slots | 20 B | 480 KiB |
| Mesh points | borrowed from the records frame | | 0 |
| **Total, reserved from fresh pages** | | | **~2.7 MiB** |

Only written pages become resident: a todo frame (108 records) writes about 11 KiB, one page
of each array. The 0.3.1 scene this replaces reserves about 1.8 MiB plus its sort keys and
frame meshes.

- **Pack, worst case:** one pass over 28,672 records writing at most one instance, one draw,
  and one clip each (~2.4 MB of writes), plus 3 edge inserts and 3 lookups per triangle
  (5,461 triangles). At ~20 ns per record that is ~0.6 ms, the estimate above; milestone 1
  measured 14.5 µs for a whole todo tick.
- **GPU upload per frame:** the used prefix of each array, one copy each. Per frame in flight
  on Metal: 432 + 888 + 21 KiB of instances and 512 KiB of points (all three topologies'
  point budgets), 1.8 MiB, against 2.0 MiB for the 0.3.1 Metal buffers at `.standard`
  before its colored point cloud buffer, which the packed frame does not need. Meshes travel
  inline with their draw call (32 B each), so their array is not uploaded.
- **Draw calls:** one per quad or sprite draw, one per mesh. A draw breaks at a pipeline or
  clip change, so draws ≤ paint records.

#### Metal on the contract

`src/platform/macos/metal/` implements the contract and draws the packed frame directly; the
macOS host no longer fills a scene, and `Window.scene` is not reserved on macOS.

- One shader library (`shaders.zig`) declares the packed structs and one vertex and fragment
  function per pipeline, with the 0.3.1 coverage, SDF, edge, and falloff math unchanged. The
  clip rectangle is a 16 B fragment uniform per draw, tested by discard, so fractional clip
  edges rasterize as before; a scissor would round them.
- Every buffer, atlas texture, and the viewport are bound once per frame. Quads and sprites
  draw instanced with the draw's `first` as the base instance; a triangle mesh starts at
  vertex `edge_first × 21`, so the shader finds its edge modes without an offset.
- A frame is one command buffer, begun by the first `uploadAtlas` or `draw`. Each of the
  `in_flight_count` frame slots (instance copies plus atlas staging, 2.8 MiB at `.standard`)
  is reused only after the command buffer that last read it completes. Atlas textures are
  private and hazard-tracked; an upload is a blit in that command buffer, so it lands after
  every earlier frame's reads. With no drawable, or a zero-size viewport, the frame's uploads
  are still committed; a missing drawable is logged once.
- A window never grows past `ResourceLimits.window`'s framebuffer: its `contentMaxSize` is
  the framebuffer at the current backing scale, floored to whole points, and is recomputed
  when the scale changes, shrinking a window a denser display puts past it. A `min_size`
  past the cap yields to it, as on Windows. Should full screen size a window past the cap
  anyway, the frame draws at the largest scale that fits and the host logs it once.
- Verified against `main` on Apple silicon at scale 2, 90 ticks at a fixed clock: 14 of the
  15 examples are bit-identical, and todo differs by one level in two text colours, the
  known `#191926 → #1a1a26` and `#7f7f8c → #80808c` of the dropped HSLA round trip. No
  example puts a shadow under a clip, so shadow clipping changes no capture.

#### WebGPU on the contract

`src/platform/web/renderer.zig` implements the contract, the last renderer to move: the web
host no longer fills a scene, so no target reserves `Window.scene` and `pack_legacy.zig` is
gone.

- One shader module (`src/platform/wgpu/shaders/packed.wgsl`) holds the Metal library's
  math in WGSL, one vertex and fragment entry point per pipeline. A draw's clip is its
  scissor rectangle, from the rule Vulkan uses (`platform/scissor.zig`, now shared).
- One bind group holds every buffer, the viewport, the three atlases, and the sampler.
  Quads and sprites draw instanced from the draw's `first`; a mesh draw passes the mesh's
  index as its first instance, since WebGPU has no push constants.
- `draw` writes the used prefix of each packed array with `queue.writeBuffer` and submits
  one render pass. `uploadAtlas` is `queue.writeTexture`, which copies before it returns
  and runs on the queue after every earlier submit, so neither needs WASM-side staging.
- Rendering is single-sample, as on Metal and Vulkan: the 4× MSAA target, which was
  window-sized and recreated on resize, is gone. The host sizes the canvas's drawing
  buffer with `Viewport.fitLogical` (JavaScript no longer does), so a canvas past
  `ResourceLimits.window` renders at a lower scale and CSS scales it up.
- A device whose `maxTextureDimension2D` or `maxStorageBufferBindingSize` cannot hold the
  budget fails init.

## ResourceLimits

PR #77's `ResourceLimits` keeps its shape and profiles and gains fields next to its
`scene`, which #218 renamed `paint`:

```zig
pub const ResourceLimits = struct {
    paint: PaintLimits,         // per-kind instance and geometry counts per frame
    window: WindowLimits,       // framebuffer_width_max, framebuffer_height_max
    frame: FrameLimits,         // in_flight_count
    atlas: AtlasLimits,         // upload_bytes_frame_max, text/svg/image sizes, SVG bounds,
                                // image requests and decode bytes, svg_entry_count_max,
                                // svg_rasterization_count_frame_max,
                                // image_entry_count_max, image_path_bytes_max
    build: BuildLimits,         // element_count_frame_max, component_depth_max,
                                // key_count_frame_max, text_bytes_frame_max,
                                // layer_count_frame_max, box_depth_max,
                                // grid_count_frame_max
    records: RecordLimits,      // paint_record_count_frame_max, hit_record_count_frame_max,
                                // handler_count_frame_max
    retained: RetainedLimits,   // slots per size class, sweep_delay_frames
    events: EventLimits,        // queue_count_max, completion_count_max, text_bytes_max,
                                // dialog_path_count_max, dialog_path_bytes_max,
                                // dialog_count_max, job_count_max,
                                // job_input_bytes_max, job_result_count_max,
                                // job_result_bytes_max
    text: TextLimits,           // fonts (FontLimits: variants, mono_variants);
                                // glyph_cache_count_max, shaped_run_count_max,
                                // measure_slot_count_max, text_size_slot_count_max,
                                // preedit_bytes_max; per kind
                                // (input, area, editor): count_max, bytes_max, undo_depth_max
    entities: EntityLimits,     // count_per_type_max
    a11y: A11yLimits,           // element_count_max, announcement_polite_pending_max,
                                // announcement_message_bytes_max, value_bytes_max
};
```

There is no `window_count_max` field: an app has one window (decision 14). The platform
window registry and the atlas upload journal hold the constant `limits.window_count_max`
(1) in place.

The text system reserves its caches at init from `text`: `glyph_cache_count_max` rendered
glyphs (a frame that draws more distinct glyphs fails fast; otherwise glyphs whose atlas
shelf no open frame used are evicted), `shaped_run_count_max` shaped runs and
`measure_slot_count_max` width slots, and `text_size_slot_count_max` slots of wrapped
text sizes for `cx.measureText` (all three evict the least recently used). Each text engine
and the platform window keep `preedit_bytes_max` bytes of IME composition; a longer one
from the OS is cut at a code point boundary and logged.

The SVG and image caches hold `atlas.svg_entry_count_max` icons and
`image_entry_count_max` images; a full cache drops entries whose atlas shelf was evicted.
Items an open frame used are never evicted, so `check` holds each cache to at least
`atlas_open_frame_count_max` (1; build and draw overlap would make it 2) frames of
`paint.svg_count_frame_max` icons or `image_count_frame_max` images, and the image cache to
every `image_request_count_max` request. At most `svg_rasterization_count_frame_max` icons
rasterize per frame; the rest draw in later frames. `Painter.image` accepts paths of up to
`image_path_bytes_max` bytes and images of up to `image_size − 2` pixels per side.

`a11y.element_count_max` sizes both frames' accessibility node pools, the accessibility
tree and each platform bridge's element slots; the tree's depth is `build.box_depth_max`
and it holds the pending announcements (`announcement_polite_pending_max` plus one) plus one
live-region announcement per element. The pending sets that carry `Effects.announce` text
between builds are `announcement_polite_pending_max + 1` slots of
`announcement_message_bytes_max` bytes each (§4, "Announcements"). A node's
value keeps at most `value_bytes_max` bytes: the whole lines around `A11y.selection`.

Layout takes every capacity from `build` and `paint` (`LayoutCapacity.fromLimits`):
`element_count_frame_max + 1` elements (the window root), a `box_depth_max` open stack,
`layer_count_frame_max` floating roots (each layer box floats), `grid_count_frame_max` grid
slots (one per grid box, `docs/layout-grid.md`), a wrap batch of
`text.run_codepoint_count_max` words, and `paint.glyph_count_frame_max` wrapped lines per
frame, which one text may fill alone. A text of any length wraps in batches and is measured
and drawn in shaping runs of at most `text.run_codepoint_count_max` codepoints, split after a
space or line break (`text_system.runLength`), so the bound is the shapers' and never a
text's. Its arena is always the reserved buffer; there is no growing mode.

`validate` checks every field against its framework ceiling at comptime, plus relationships
such as `hit_record_count_frame_max <= element_count_frame_max`,
`layer_count_frame_max <= element_count_frame_max`,
`grid_count_frame_max <= element_count_frame_max`,
`box_depth_max <= element_count_frame_max`,
`a11y.element_count_max <= element_count_frame_max`,
`a11y.value_bytes_max <= build.text_bytes_frame_max`,
`text.preedit_bytes_max <= events.text_bytes_max`, and `text.measure_slot_count_max` and
`text.text_size_slot_count_max` powers of two above the 8-slot probe window. The element
ceiling is 65,535, the depth ceiling 128 (`Node.depth` is a `u8`) and the accessibility
element ceiling 16,384 (tree indexes are `u16`).

## Performance sketch (§7)

Per window at `.standard`, as estimated at approval (2026-10-30). Scene figures are PR #77's
measured profile; the rest are estimates. Milestone 1's measurements below and phase 5's
sketch (§9) replace them where they differ.

| Resource | Bound | Unit size | Resident |
| --- | ---: | ---: | ---: |
| Paint records: quads (8,192 + 512 shadow) | 8,704 | ~96 B | 0.8 MiB |
| Paint records: sprites (glyph, svg, image) | 17,664 | ~64 B | 1.1 MiB |
| Paint records: meshes | 1,792 | ~48 B | 0.1 MiB |
| Two record buffers (built, presented) | | | 4.0 MiB |
| Elements, layout nodes, hit records | 4,096 | ~300 B | 1.2 MiB |
| Handler arena | 4,096 | 24 B | 0.1 MiB |
| Retained slabs (2,048 / 1,024 / 256 / 64 slots) | | 64 B–4 KiB | 0.9 MiB |
| Text engines (64 inputs × 8 KiB, 16 areas × 128 KiB, 0 editors) | | | 2.5 MiB |
| Event queue and completion ring | 256 + 64 | 64 B | 0.02 MiB |
| **CPU total** | | | **~9 MiB** |

Work per tick, worst case:

- **Drain:** at most 256 events. Pointer moves coalesce to one, so hit tests per tick are
  bounded by non-move events plus one. One hit test walks at most 4,096 records (~20 µs).
- **Build and layout:** 65–83 ns per node measured in 0.3.1, so 4,096 nodes take ~0.35 ms.
- **Emit and pack:** one pass over at most ~28,000 records, ~20 ns each, ~0.6 ms. Since
  0.6 emit culls what its clips hide (§8), so a scroll box's records follow its viewport:
  a headless 800×900 transcript of 65 wrapped 800-byte messages, scrolled 40 px a frame,
  wrote 43,387 paint records a frame before culling and 1,510 after, and its whole tick
  fell from 90.6 to 5.5 ms (ReleaseFast, FreeType, x86-64).
- **Upload:** bounded by atlas staging per tick (`atlas` limits); deferred rasterization
  continues on later ticks.
- **GPU:** PR #77 measured 16.8 MB of Metal allocation per window at `.standard`.

### Milestone 1 measurements

Measured on the core under `src/core/` with counter and todo on `TestBackend` (x86_64 orb,
`src/testing/goldens/core_checks.zig`). The guard counts every core allocation during init;
both traces then run with zero allocations.

| Profile | Init bytes, one window, CPU only | Allocations |
| --- | ---: | ---: |
| `nano` (counter) | 3,842,572 (3.7 MiB) | 60 |
| `small` (todo) | 6,146,792 (5.9 MiB) | 60 |
| `standard` | 14,015,696 (13.4 MiB) | 60 |
| `large` | 34,249,680 (32.7 MiB) | 60 |

- `.standard` is 13.4 MiB against the ~9 MiB estimate above. The total also holds what the
  table above does not list: the text system and its shape cache, the layout engine (then
  its fixed 16,384-element reservation; budget-sized since 0.6), and CPU copies of the atlases, which test builds
  keep (`atlas_storage = .cpu_texture`). The per-subsystem split is not measured yet.
- One todo tick with a forced render (drain, build, layout, emit, pack, and a
  `NullRenderer` draw; 22 nodes, 108 paint records) takes 14.5 µs in ReleaseFast. That is
  too small a tree to check the 4,096-node estimates; phase 4's larger examples will.

## Acceptance: todo

The milestone 1 todo app, written against this contract:

```zig
const App = gooey.App(State, render, .{
    .title = "Todos",
    .width = 480,
    .height = 560,
    .limits = .small,
});

pub const main = App.main;

fn render(cx: *gooey.Cx) void {
    const s = cx.state(State);
    cx.render(ui.box(.{ .style = .{
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .padding = .all(24),
        .gap = 16,
    } }, .{
        ui.text("Todos", .{ .size = 28 }),
        ui.box(.{ .style = .{ .direction = .row, .gap = 8 } }, .{
            TextInput{ .key = "draft", .bind = &s.draft },
            Button{ .label = "Add", .on_click = cx.on(State.addTodo, .{}) },
        }),
        ui.when(s.count == 0, emptyHint),
        List(TodoRow){ .key = "todos", .count = s.count },
    }));
}

const row_style: ui.Style = .{ .direction = .row, .gap = 12, .padding = .all(10) };

const TodoRow = struct {
    index: u32,

    pub const row_height: f32 = 72; // List needs every row's height before it builds any

    pub fn render(self: TodoRow, cx: *gooey.Cx) void {
        const s = cx.state(State);
        cx.render(ui.box(.{ .style = row_style }, .{
            Checkbox{
                .checked = s.todos[self.index].done,
                .on_click = cx.on(State.toggle, .{ .arg = self.index }),
            },
            ui.text(s.todos[self.index].text(), .{}),
            Button{ .label = "Delete", .on_click = cx.on(State.remove, .{ .arg = self.index }) },
        }));
    }
};
```

Concept count for this app: `App`, `Cx`, `box`, `text`, `when`, `on`, `state`, plus three
library components. In 0.3.1 the same app uses `root`, `hstack`, `box`, `text`, `textFmt`,
`when`, `spacer`, `update`, `updateWith`, `on_click_handler`, string ids, and two component
wrappers for list iteration.

## Approved decisions

1. **§6 recursion: bounded, approved.** `component.render → cx.render → child.render`
   recurses. `cx.render` increments a depth counter, asserts it against
   `build.component_depth_max`, and decrements on return. Past the limit it panics with the
   limit, the depth, and the component type that crossed it. Converting component rendering
   to an explicit stack would require type-erasing every component, at the cost of comptime
   checking and inlining.
   - **Default:** 64 in `.standard` and `.large`. It is the value CLAUDE.md §4 uses as its
     example, and it leaves wide headroom over real trees; milestone 1 measures the deepest
     nesting across the kept examples and records it here.
   - **Ceiling:** 128. Milestone 1 also measures stack bytes per level and must show that
     ceiling × bytes per level fits within the 1 MiB WASM stack (§14) with the rest of a tick.
   - **Measured in milestone 1:** the deepest nesting is 4 levels in counter and 5 in todo
     (`window.component_depth_peak`; the depth counts every `cx.render` call). Stack bytes
     per level are the frame-address span between the outermost and deepest `cx.render`,
     divided by the levels between them:

     | Build | Counter | Todo | 128 × todo |
     | --- | ---: | ---: | ---: |
     | ReleaseSmall (the WASM build mode) | 592 B | 1,116 B | 140 KiB, 14% of 1 MiB |
     | Debug | 5,888 B | 10,712 B | 1.31 MiB, over 1 MiB |

     ReleaseSmall fits the ceiling with wide room for the rest of the tick, whose text
     shaping buffers are bounded at 16 KiB (`text/render.zig`) and run in emit, after the
     component recursion returns. A Debug WASM build fits the default 64 (686 KiB) but not
     the ceiling. Measured on x86_64; wasm32 frames are expected to be no larger.
2. **`Cx` stays untyped, with a safety-mode state check.** One `Cx` for every app, so library
   components are not generic over the app's state.
   - **Debug and ReleaseSafe:** `cx.on` checks the method's `State` against the root state
     and registered entity types while the tree is built, so every mismatch panics on the
     first frame and names the method and source location. `cx.state(T)` checks the same way.
     The check is gated on `std.debug.runtime_safety`, matching how Zig gates assertions.
   - **ReleaseFast and ReleaseSmall:** the check compiles out. A mismatch is a programmer
     error that any Debug or ReleaseSafe run catches on its first frame.
   - **Removed:** the 0.3.1 behaviour where a mismatched handler silently does nothing
     (`getRootState(State) orelse return`).

3. **No keep-alive, as in GPUI.** Element state lives only while its element renders in
   consecutive frames. Zed's `Pane` holds every tab's `Entity` and renders only the active
   one; editor text, selections, and scroll live in entity fields, and scroll and focus
   handles are app-owned. Gooey does the same: hidden state is an entity field or an
   `.owned` handle, so pool occupancy tracks what is visible, which is what profiles size.
4. **Observers and subtree caching move to 0.5, together.** GPUI's `notify` marks dependent
   views dirty, runs observer callbacks later as queued effects, and `Entity::cached` reuses
   a clean view by replaying the previous frame's paint and prepaint ranges. The 0.5 design:
   `notify` sets a bit in a fixed dirty set; one drain per tick marks dependent views dirty
   with no callbacks; read dependencies are recorded per view in a fixed arena; a clean
   cached view copies its previous record range. The 0.3.1 observer code appends to
   growable lists after init and drops errors, so 0.4.0 removes it rather than carrying it.
   Not shipped in 0.5 (2026-11-14); the target release is open.
5. **macOS pacing: `CADisplayLink` on a render thread; macOS 14 is the minimum.** Measured
   on an M2 Max against CVDisplayLink (`tick-driver/` and `tick-driver/ca-thread/` under
   the Mac's baselines). Both hold 120 fps on the 120 Hz panel and neither exceeds it. The
   render-thread link holds a steady 60 with 0 drops on a 60 Hz display where CVDisplayLink
   stays pinned at 120 and drops ~600 frames per 30 s, uses half the energy there, follows
   the window between displays, pauses while displays sleep, and starts while they sleep
   (CVDisplayLink exits with `DisplayLinkCreationFailed`). CVDisplayLink is deprecated in
   the macOS 15 SDK.
   - The main thread creates the link from the window's view, so NSView calls stay there;
     the render thread adds it to its own run loop (`NSRunLoop` is not thread-safe) and
     invalidates it before the window is freed. Amended by decision 7.
   - **Main-thread budget (reworded 2026-11-14).** At 120 Hz a frame's main-thread work
     (drain, build, flip) must fit about 7 ms, leaving the rest of the 8.33 ms refresh for
     the render thread to encode and present. Measured with `-Dframe-trace` (PR #231, 30 s
     runs, ReleaseFast): main p99 is at most 0.42 ms on the M2 Max (Metal), 1.5 ms in
     Chrome WebGPU, 0.69 ms on the SER9 (Vulkan), and 0.20 ms on the BT-L075 (DX11 and
     Vulkan).
   - The earlier claim that the link "holds 120 with a 12 ms main-thread handler" is
     withdrawn. `tick-driver/ca-thread` counted render-thread link callbacks that
     re-rendered the existing scene while a 12 ms spin occupied the main queue; no new
     frame was built at 120. With one frame in flight a 12 ms build holds 60 at most.
   - Known gap: the link misses 0–13 refreshes per 30 s with the next frame already
     built, and with display sync off (it adds a refresh of latency) 36–85 frames per
     30 s are replaced before they reach the glass. Holding the range at {120, 120, 120}
     changed nothing (85 misses before, 93 after, over 36 runs), so it stays adaptive.
     Tracked in the plan ("macOS pacing").
6. **Text engines: one pool per kind.** Inputs, areas, and code editors each get a pool with
   their own slot count, slot bytes, and undo depth in `TextLimits`. One shared pool would
   size every slot for the largest kind, so a search box would reserve an editor's buffer.
   Separate pools reserve only what each kind needs, let a profile set editors to 0, and
   name the kind that ran out. Apps override one kind the same way as any other limit.

7. **Milestone 1 rulings (2026-10-30).** Implementing milestone 1 needed these choices.
   - **Approved as built:** `Config(State)` is generic because `on_init` takes `*State`.
     `Effects.inputEvent()` and `completionEvent()` let a handler read what invoked it.
     `effects.openFileDialog(.{ .kind, .on_complete })` opens the dialog on the main thread
     after the drain and delivers `file_selected`, `cancelled`, or `failed` on the next
     drain. Text engines are retained values whose slab is an entity pool, so `cx.on` can
     target one. `ColorToken` names follow `Theme`, so `.text_muted` is `.muted`. Examples
     declare `pub const main = App.main;`. The macOS display link is created on the main
     thread (decision 5 amended).
   - **Changed in phase 4:** `render` is passed to `App` positionally, as in 0.3.1
     (`gooey.App(State, render, .{ ... })`), replacing the `@import("root")` lookup. A
     handler names a completion handler directly
     (`.on_complete = effects.handler(State.onPicked)`), so completion handlers are no
     longer built during render and kept in state. Clicks fire on release instead of
     press, as a deliberate golden change.
   - **Changed in phase 5:** milestone 1 keeps one frame in flight, so build never
     overlaps draw. Phase 5's atlas staging (§9 `uploadAtlas`) lets the main thread build
     the next frame while the render thread draws. v0.4.3 shipped the atlas staging, but
     the tick still keeps one frame in flight.
   - **Overlap shelved (2026-11-14).** Measured on every host before building it: main
     p99 is at most 0.42 ms (Metal, M2 Max), 1.5 ms (Chrome WebGPU), 0.69 ms (SER9
     Vulkan), and 0.20 ms (BT-L075 DX11 and Vulkan). Serialized main plus render fits one
     120 Hz refresh in 99.9–100% of frames on every GPU renderer; only the CPU renderer's
     dashboard falls to 97.4%, and its 6–8 ms draw is the cost there, not the build.
     Overlap would save at most the main time per frame, under 0.7 ms on every native
     host, for a second packed frame, a second staging ring, and a handshake on every
     host, and the web has no thread to overlap with. No measured miss came from build
     time: every macOS miss had its frame ready within 0.4 ms (decision 5, known gap).
     Revisit when an app's p99 draw exceeds 1 ms on a 120 Hz GPU host and its serialized
     main plus render misses the refresh. The shelved design builds frame N+1 into a
     second packed frame and records frame while the render thread draws frame N, and
     fences atlas uploads per frame.

8. **Fonts: restore 0.3.1, plus an optional second family (2026-10-30).**
   - **Restored:** 0.3.1 sets the app's font with `.font` and `.font_size` and swaps it
     with `cx.setFont`; milestone 1's core dropped all three and always loads the
     platform's sans-serif. `Config` regains `font` and `font_size`, and `Effects` gains
     `setFont(name, size)`, applied after the drain. The reload reuses the same face
     slots, as 0.3.1's `loadFont` does, so it claims no storage.
   - **Second family (C3 from the showcase design):** 0.3.1 already loads a monospace
     family as the app's only font; what it cannot do is draw two families in one frame.
     `Config.fonts.mono` adds an optional second family, and `Text` gains
     `family: enum { app, mono } = .app`. `FontLimits` gains the mono family's variants
     (`limits.text.fonts.mono_variants`), empty in every profile, so apps that leave
     `fonts.mono` null reserve nothing.
   - **Choosing faces:** the faces are part of the budget, `ResourceLimits.text.fonts`
     (moved there in 0.5.3; `Config.fonts.limits` is gone). An app that sets `fonts.mono`
     lists its mono variants there, for example
     `.{ .variants = FontLimits.small.variants, .mono_variants = &.{.regular} }`, which
     follows the "profile plus overrides" rule. Setting `fonts.mono` with no mono
     variants, or `.family = .mono` with `fonts.mono` null, is a compile error or a
     first-frame panic that names the field.

9. **Wrapped text and the web's single thread (2026-10-30, showcase C1 and C10).**
   - **Wrapped text:** `Text` gains `wrap: enum { none, words, newlines } = .none`,
     `line_height: ?u16` (percent of the font's line height; null keeps the font's), and
     `alignment: enum { left, center, right } = .left`. The layout engine already wraps
     (`TextConfig.wrap_mode`); the core stops passing `.none` and emit writes one glyph
     run per wrapped line. Wrapped lines count against the same glyph and record limits
     as any other text.
   - **The web runs on one thread:** the browser host runs drain, build, layout, emit,
     pack, and draw in sequence inside each `requestAnimationFrame` callback. The
     `built` and `presented` buffers still swap at the end of a frame, so the core code is
     the same on every platform; only the web host has no render thread. This is an
     exception to rule 1, not a change to it.

10. **Scope for 0.4.0: parity, not new surface (2026-10-31).** The rewrite exists to make the
    API smaller. Of the showcase's proposed additions, only those that carry 0.3.1 behaviour
    onto the core land in 0.4.0:
    - **C9, accessibility (kept):** `A11y` gains `heading_level`
      (`accessibility.HeadingLevel`), `live: enum { off, polite, assertive }`, and
      `href: ?[]const u8`; `Effects` gains `announce(text, politeness)`. 0.3.1 has heading
      levels, live regions, and `cx.announce`; accessible_form needs them.
    - **C11, theme switching (kept):** `Effects.setTheme(theme: *const Theme)`, applied at
      the next build, replacing 0.3.1's `cx.setTheme`.
    - **Landed (#121):** C9 and C11 as written. Each rendered frame's nodes and
      announcements reach the platform's screen-reader bridge (VoiceOver, AT-SPI2, ARIA)
      through the existing accessibility tree. Announcements were bounded at 16 and 1 KiB
      per frame and failed fast past that; since the VOPR found input alone overflowing
      them during a frame in flight, they follow live-region replacement rules instead
      (§4, "Announcements").
    - **Deferred past 0.4.0:** C2 (inline runs), C4 (`openUrl`), C5 (navigation), C6
      (app-bound scroll and `scrollTo`), C7 (state scopes), and C8 (viewport and capability
      queries). The showcase is built from what the core already has.
    - **Config defaults:** only `title`, `width`, `height`, and `limits` are required.
      `theme` defaults to `Theme.light`, `keymap` and `entities` to empty, `on_init` to
      null, and the four font fields fold into one `fonts: Fonts = .{}` whose defaults
      are the platform sans-serif at `Theme.font_size_base`, no mono family, and the
      profile's faces. Each default is the reviewed policy (CLAUDE.md §19). A counter is
      `gooey.App(State, render, .{ .title, .width, .height, .limits = .nano })`.
    - **Timers and clipboard (2026-10-31), parity for the text engines:**
      - `cx.requestRenderAfter(delay_ms: u32)` on the build `Cx` replaces 0.3.1's
        `cx.notifyAfter` with the same contract: render code that depends on the clock
        renews it every frame. It is on `Cx`, not `Effects`, so apps never route timer
        events. Caret blink uses the same per-window deadline. There is no timer table,
        `Event.timer`, or `timer_count_max`.
      - The clipboard has no public API, as in 0.3.1. The text engines copy and cut after
        the drain and paste into a buffer reserved at init and sized to the largest
        kind's `bytes_max`. `Effects.copyText` is not added; the showcase's copy button
        is dropped.

11. **File dialogs: GPUI's options, minus button text (2026-10-31).** 0.3.1's
    `PathPromptOptions` and `SavePromptOptions` shrink to the fields GPUI's
    `prompt_for_paths` and `prompt_for_new_path` have:
    - **Open:** `{ files: bool, directories: bool, multiple: bool }`. A selection
      completes with a bounded list of paths; the path count and total bytes are
      `ResourceLimits`, and a selection past them fails fast (CLAUDE.md §2).
    - **Save:** `{ directory: ?[]const u8, suggested_name: ?[]const u8 }`, completing with
      one path.
    - **Dropped:** `prompt`, `message`, `starting_directory`, `allowed_extensions`, and
      `can_create_directories`, with their platform code. Zed ships without extension
      filters; adding one field back later is cheap.
    - **Amended (2026-11-10):** a backend may keep the dialog open while its loop keeps
      turning and deliver the outcome on a later drain (`FileDialogService`). Linux does,
      so the compositor does not mark the window unresponsive. It opens one portal dialog
      at a time; a second request meanwhile fails with `error.FileDialogBusy`.
    - **Amended (2026-11-22):** `effects.openFileDialog` returns `error{DialogBusy}!void`.
      It refuses, and asks for nothing, when a request already waits for this tick's
      drain to open it, or when every dialog slot (`events.dialog_count_max`) holds a
      dialog awaiting its outcome. The router applies each handler's effects before the
      next runs, so a later handler in the same drain (another click, a completion, a
      job, or a bubbling handler) sees the earlier request. Two clicks on Open queued
      before one tick used to panic ("one opens per tick"); a full dialog table failed
      fast as a capacity error. Both are ordinary user actions, so they are refusals
      the caller handles at the call site. A refusal claims no storage and delivers no
      completion. Found by the VOPR's `file_dialog` workload.

12. **Linux screen readers: shelved past 0.4.0 (2026-10-31).** The Linux AT-SPI bridge has
    never joined the accessibility bus or answered D-Bus calls, in 0.3.1 or 0.4.0, so Orca
    cannot see a Gooey app (SER9, #121). 0.4.0 does not implement it. The non-working
    bridge is removed rather than kept as a stub, so Linux builds no accessibility tree and
    the gap is stated plainly; a later release starts from git history.

13. **Retiring the 0.3.1 text widgets (2026-10-31).** Every remaining user of the 0.3.1
    TextInput, TextArea, or code editor is ported or loses the widget, so the old widgets
    can be deleted:
    - `spaceship` drops its text input; its shaders stay on 0.3.1 until phase 5. Superseded
      by decision 14: spaceship is cut.
    - The 0.3.1 `showcase` drops its TextInput and TextArea cards; the 0.4.0 showcase
      tutorial replaces it.
    - `genui` stays on the 0.3.1 TextInput for now (out of scope); the old TextInput is
      deleted when genui moves.
    - `accessible_form` ports with a core `Select`, and `code_editor` ports with a core list
      but drops its file tree. Both are 0.3.1 parity; neither adds other API.
    - `accessible_form` drops its "Screen reader detected" indicator (2026-11-01). Showing
      it needs a screen-reader capability query, which is C8 and deferred.
    - `components.ValidatedTextInput` is deleted (no users); `validation.zig` stays.
    - The core `A11y` gains 0.3.1's `description`, `expanded`, `has_popup`, `pos_in_set`,
      and `set_size`, which accessible_form uses. Parity under decision 10, not new API.
    - Layers implement `.popover` only (for `Select`); tooltip, modal, and drag layers keep
      failing fast until something needs them.

14. **Cuts: multi-window, glass, custom shaders (2026-11-09).** These carry no 0.3.1
    behaviour onto the core; they leave 0.4.0 to lower the floor (plan "Open decisions").
    - **Multi-window:** one window per app. Native file dialogs cover the dialog case.
      `multi_window_app` and the `multi_window` example are deleted. Multi-window is
      deferred, not abandoned. `platform/window_registry.zig` stays as is: every platform
      registers its one window there, and it allocates only at init. A later release
      replaces it when multi-window returns. The likely upgrade is a fixed table of typed
      window slots sized by `limits.window.count_max`, with a generation-checked `WindowId`
      like `ElementId`, replacing today's growable `AutoHashMap` of `*anyopaque`.
    - **Liquid glass, custom shaders, and post-processing:** cut on every backend, with
      `Capabilities.post_process`, `CustomShader`, and the `glass` and `spaceship`
      examples. The CPU renderer never supported them. Custom shaders are deferred, not
      abandoned: a later release designs them as a core primitive, and nothing in 0.4.0
      depends on that design.
    - **Animation helpers are module functions:** `core.animation.tween(cx, key, ...)`,
      `tweenOn`, and `motion`, as the text engines use `engine.blink(cx, ...)`, so `Cx`
      does not grow a method per helper. This replaces §3's `cx.animate`.
    - Each cut deletes its 0.3.1 code now, as "delete as you port" requires, and reports
      the net line change.

15. **Examples cut and deferred before phase 6 (2026-11-09).** So that phase 6 can delete
    the 0.3.1 middle, the examples still on it either port or leave:
    - **Removed:** `genui` (the `genui/` tree and `genui_demo`), `ai_canvas`,
      `ai_canvas_spike`, and `src/ai`, together with anything only they use. Also removed:
      `disktree`, with `test-disktree` and its benchmark use. Any limit or profile that only
      disktree exercised gets its coverage from an existing test, or the PR says it lost it.
    - **Showcase is deferred:** the 0.3.1 `showcase` example is deleted now, and the
      showcase tutorial is built in a later release. Its roles
      move to core examples: `todo` becomes the default `zig build run`, and `zig build
      wasm`, Pages, and the preview skill use a core example.
    - **Drag and drop is deferred:** `drag_drop` is deleted, and the 0.3.1 drag machinery
      goes with the old middle in phase 6. The plan for its return is draft PR #148:
      `draggable: ?DragSource` and `DropTarget` on the element, `cx.drag(T)` and
      `effects.dropPayload(T)`, payloads of at most 8 bytes like handler arguments, the
      0.3.1 rules (2 px threshold, nearest draggable on the press path), and the core
      `.drag` layer, which fails fast until then. `drag_drop` returns as its example.
      Amended (2026-11-14, #227): the unimplemented `Box.draggable`, `Box.drop_target`,
      `DragSource`, and `DropTarget` are removed, a breaking change, and drag and drop,
      `.drag` layer included, is deferred to 0.6.

16. **Source locations on elements (2026-11-09).** `Style` gains `source:
    ?std.builtin.SourceLocation = null`, so `.source = @src()` fills the debugger
    inspector's Source row. Only Debug and ReleaseSafe builds store it per node (a pointer
    and a u32). ReleaseFast and ReleaseSmall accept the field and drop it at comptime, so
    nodes carry no storage for it and app code builds unchanged in every mode. This is the
    one addition beyond decision 10, replacing 0.3.1's unused `ui.boxTracked` family.
    The debugger itself (inspector, profiler, Cmd/Ctrl+Shift+I) follows the same rule: it
    exists only in Debug and ReleaseSafe. ReleaseFast and ReleaseSmall compile out its
    state, its frame timing, its overlay, and its key binding, so shipped apps reserve and
    spend nothing on it.

17. **Entities and the Linux CPU backends stay in 0.4.0 (2026-11-09).**
    - **Entities** are built as §7 describes: typed fixed pools declared in
      `config.entities`, sized by `EntityLimits`, with generation-checked handles and the
      `.entity` handler option. `dynamic_counters` ports onto them in the same PR.
      Approved surface (2026-11-09):

      ```zig
      pub fn create(effects: *Effects, comptime T: type, value: T) Entity(T);
      pub fn remove(effects: *Effects, comptime T: type, handle: Entity(T)) void;
      // Read: the existing `cx.get(T, handle) *T`; `Entity(T)` is the retained `Handle(T)`.
      ```

      - Pools are reserved at init, one per type, `limits.entities.count_per_type_max`
        slots each, with a u32 generation per slot. Listing a non-struct, a duplicate, the
        root `State`, or a text engine, or more than `entity_pool_count_max` (16) pools
        including the engine pools, is a compile error. The store's pool table holds
        exactly `config.entities.len` plus the three engine pools, sized at comptime.
      - `create` claims a slot at once, so a handler can store the handle. `on_init` may
        create. A full pool panics with its name, capacity, and the requested count.
      - Every `get` and `remove` checks the generation and panics on a stale handle in
        every build mode, naming the pool, the slot, and both generations.
      - `remove` marks the slot, and the tick frees it after the drain and before the build:
        it bumps the generation and zeroes the slot. Handlers later in the same drain still
        reach the value. Removing twice in one drain panics.
      - Removal releases nothing else. The app releases `.owned` handles stored in the
        entity first, and keys the entity's boxes with its slot and generation.
    - **`wayland_cpu` and `fbdev`** get the core host before phase 6 deletes the 0.3.1
      runtime, so both keep an app path; their app typecheck roots then move to a core
      example.
18. **The public root (2026-11-09).** The core's names are the `gooey` root, with one
    spelling each; `gooey.core` is private and `components.core.X` becomes `components.X`.
    - **Root:** App, Config, Cx, ui, Handler, Effects, Entity, ElementId, Key, Lifetime,
      Handle, Query, Theme, Painter, the file dialog option types and Paths, the three text
      engines, ResourceLimits, FontLimits, FontSource, and Color; the `animation`, `input`,
      `text`, and `accessibility` namespaces; and `log`, `std_options`, and `testing`.
      `api_check` pins exactly this list.
    - **`ui.Paint`** is public, because an app that writes a paint helper must name it.
    - **`gooey.internals`** holds what tests, goldens, and platform or renderer code reach:
      scene, layout, platform, geometry, image, svg, backend, limits, and the verifiers. It
      is not API, may change in any release, and nothing in it is pinned. (`scene` left
      with `src/scene` in #218.)
    - **Removed:** `validation` (no users) and the 0.3.1 `file_dialog` wrapper.
    - **Import ban:** `zig build import-ban`, run by `test`, fails on any file at, or
      `@import` of, a deleted 0.3.1 path.

19. **Drag and drop, 0.6 plan (approved 2026-11-14).** The plan is the thread artifact
    "0.6 plan: drag and drop". Duane approved its recommendations: one `on_pointer_drag`
    handler with phases (D1), keyboard pick-up through `effects.startDrag` (D2), drag
    fields inline on `HitRecord` (D3), only the `resize_left_right` and `resize_up_down`
    cursors (D4), a splitter example with no `components.Splitter` (D5), and hover-only
    pointer moves, OS drag and drop, edge auto-scroll, and touch out of 0.6 (D6). It lands
    in five PRs; the first adds pointer capture (§5), `effects.pointerDrag`,
    `effects.bounds`, `InputEvent.pointer_cancelled`, `A11y.range`, the two cursors, and
    the `splitter` example. The rest of decision 15's drag API follows in later PRs.
    The third adds `Box.draggable` and `Box.drop_target` with `ui.DragSource` and
    `ui.DropTarget`, `cx.drag(T)` and `Drag(T)` (a root name, decision 18's list grows by
    one), `effects.dropPayload(T)`, the `.drag`
    layer (§6), and the `drag_drop` example back, keeping #148's 0.3.1 rules. A drag
    holds no handler: `on_drop` is looked up in the frame on screen at the release.
    The fourth adds `effects.startDrag` and `Drag(T).keyboard` (§5); `drag_drop` binds
    Space on a focused card and announces the pick-up and the drop.
20. **A sealed public boundary (0.6, 2026-11-15).** Simplification 3 of the 0.5.5
    overview: library code can do only what an app can.
    - **`Cx` is opaque.** A `*Cx` is the window's address under an opaque type, so
      `cx.window` is gone. The core's own modules reach the window through
      `internals.cx.windowOf(cx)`. Four public reads replace what components used it
      for: `cx.now()` (the tick's clock, nanoseconds), `cx.bounds(id)` (a keyed element's
      bounds in the last laid-out frame; after a resize it asks for the one render that
      reads the new size), `cx.scroll(id)` (a keyed scroll box's offset and last viewport,
      `Cx.ScrollPosition`), and `cx.limits()` (the app's `ResourceLimits`).
    - **`Painter` carries only `bounds`.** Its window and clip depth live in the
      emit-private `PaintTarget` that holds it, found from the painter's address.
    - **`List`** reads its offset with `cx.scroll` and bounds the rows it builds by
      `build.element_count_frame_max`, which replaces its framebuffer-height constant;
      **`CodeEditor`** sizes its text with `cx.bounds`.
    - **Import ban:** `zig build import-ban` also fails on any `.internals` reference in
      code under `components/` or `charts/`.
    - **Namespaces.** `gooey.text` holds only `Metrics`, `FontWeight`, `FontFamily`,
      `FontVariant`, `codepointCount`, and `run_codepoint_count_max`; `gooey.accessibility`
      only `Role`, `State`, `Live`, `HeadingLevel`, and `Orientation`. The full modules
      move to `internals.text` and `internals.accessibility`, and `Query`, the platform
      host's view of the frame, to `internals.Query` (decision 18's root list loses it).
    - **`ui` names the types `Box` and `Style` fields use:** `Direction`, `Layer`,
      `Anchor`, `Scroll`, `ClipPolicy`, `CursorShape`, `PointerEvents`, `KeyContext`, and
      `ActionBinding`, so a helper can take or return one.
    - **`api_check.zig` is exact:** besides pinning each name, it lists every public name
      of the root, `ui`, `Cx`, `text`, `accessibility`, `input`, and `animation`, so an
      unpinned addition fails the build too.
21. **Tooltips (0.6, 2026-11-20).** The `.tooltip` layer stops failing fast, and
    `components.Tooltip(Child)` uses it.
    - **Pointer-transparent.** A tooltip fragment's hit records never take the pointer, as
      a drag preview's do, so moving onto a tooltip leaves hover and clicks to what is
      under it. Tooltips are not hoverable; they repeat a short text and hide when the
      pointer leaves their trigger, as native ones do.
    - **`cx.focusVisibleWithin(id)`.** Whether keyboard focus, drawn with its ring, is on
      `id` or a descendant in the frame on screen. The window recomputes the focus path
      (`Window.focus_path`, reserved at init like the hover path) before each build, one
      pass over the hit records while focus is visible. A tooltip shows for keyboard focus
      on its child without knowing the child's id, and not after a pointer press focuses
      it, so a click leaves none standing.
    - **The component** times the hover delay with `cx.now` and `cx.requestRenderAfter`
      in one retained 64 B slot, shows at once for visible focus, hides on Escape until
      hover and focus both leave, and opens below its child (above when it does not fit).
22. **Context menus (0.6, 2026-11-20).** 0.3.1's `ContextMenu` opened from an app-wide
    event hook the core does not have, and the core's right press clicked nothing.
    - **`Box.on_context_menu`.** One handler per box, run by a right press, a macOS
      Ctrl+press, or Shift+F10 (§5). Only the nearest record with one runs, so a menu over
      part of a larger menu's area opens alone. The handler reads the press's position
      from `effects.inputEvent()`.
    - **`effects.focusedElement()`.** The element holding keyboard focus when a handler
      runs, or null. A menu opened from the keyboard opens beside it (`effects.bounds`),
      and a component returns focus to it on close.
    - **`components.ContextMenu(Child)`** keeps its open state and position in one
      retained 64 B slot, so the app supplies only `MenuItem` rows with ordinary handlers.
      It opens on a `.popover` layer anchored to the window at the pointer, or below the
      focused element for Shift+F10, with its first action focused; the arrow keys, Home,
      and End move between actions, skipping disabled rows and separators and wrapping;
      Enter or Space chooses; Escape or Tab closes; a choice or a keyboard close returns
      focus where it was. At most 64 rows (`menu_item_count_max`). Every handler sits on
      a `menuitem` row or a box inside one, so each handled record belongs to an
      interactive accessibility node, as the VOPR's frame invariants require; the goldens
      check its frames against them.
23. **State ownership in components (0.6, 2026-11-20).** One rule, as GPUI, egui, Radix,
    and SwiftUI draw it: the app owns values (`selected`, `checked`, bound text) and what
    its own logic decides (whether a `Modal` shows); a component owns transient state that
    only the user's gestures drive, in a retained slot. `Tooltip` and `ContextMenu`
    followed it; `Select` loses `open`, `on_toggle`, and `on_close` and keeps whether its
    menu is open in the slot it already held for its keys. Programmatic control of
    component-owned state, as GPUI's `PopoverMenuHandle` gives, waits for a caller, and
    would follow `List.scrollTo`: a function on the component type that takes its id.
24. **Wrapping rows and aspect ratios (0.6, 2026-11-21).** `Style.wrap` breaks a `.row`
    into lines at its content width, as CSS `flex-wrap: wrap`. Children keep their
    widths; one wider than the row takes a line alone, cut to the row unless its width
    is fixed or its `width_min` is wider. Grow children share each line's free width by
    weight, as a row that does not wrap shares its own. `alignment.main` places each
    line, `alignment.cross` aligns children within their line, and cross-axis grow
    children fill it. Lines stack `gap` apart. The sizing pass breaks the lines once
    and marks each line's first child, so positions, fit-content heights, and scroll
    targets never break them differently. A wrapping row's minimum width is its widest
    child's, so a `.fit` width is that narrow. Columns do not wrap: their lines would
    need a width derived from heights, which no caller needs yet. `Style.aspect_ratio`
    exposes the engine's ratio. The height follows the width, so `height` must stay
    `.fit` with no bounds; with a fixed width the core fixes the height too. Both derive
    heights from widths after a fit-content parent was sized from minimums. Each
    derived height marks its fit-content ancestors, up to one already marked, and one
    backward walk grows every marked box to its children once, so a parent of N aspect
    children adds them up once, not N times, as wrapped text's per-text walk would.
    Work stays linear and needs no storage: three walks over a line's children while
    sizing, two while placing, and the marking and backward walk only on frames that
    derive a height. Layouts without either field run 0.5 to 2 % more instructions in
    the Cachegrind gate, from the branches the feature adds.
25. **Percent less gaps (0.6, 2026-11-21).** A `.percent` child along its parent's
    direction takes its fraction of the content size less the gaps between flow children,
    as Clay sizes percent children, so fractions that add up to 1 fill the parent without
    overflowing. It replaces a fraction of the whole content size, which a parent that did
    not overflow then took a second time when it sized the child, so two halves of a
    400 px row came out 100 px each; only `percent = 1` was unaffected. A wrapping row's
    lines hold different gap counts, so a percent child there stays a fraction of the row's
    content width, and the cross axis has no gaps to subtract.
26. **Content floors and largest-first shrink (0.6, 2026-11-22).** Each layout element
    has a floor, the narrowest it can be without cutting its content: a text wrapping at
    words floors at its widest word, other text at its one-line width, a row at its
    children's floors and gaps, a column at its widest child's, a horizontal scroll box
    at its padding. Heights floor at their minimum, since text has not wrapped yet. A
    grow child takes at least its floor, not its one-line content width, so a grow
    column of wrapping text beside a fixed sidebar takes the rest of the row and wraps
    there; before, it took the text's one-line width and ran off the row. When the
    children cannot fit, because the others overflow or a grow child's floor is above
    its share, the fit and grow children shrink largest first to a common level, as
    Clay does, never below their floors; fixed and percent children keep their size. It
    replaces one shrink ratio for every non-grow child, which cut labels below their
    text, and grow children that dropped to `width_min`. The level is found by exact
    leveling from an upper bound on the children's sizes taken while summing them, one
    walk per distinct size it passes, at most 16 walks and then 32 bisection steps, and
    only on a parent that overflows with a fit or grow child.
    Floors are summed only in frames with a text whose widest word is narrower than its
    line; other frames copy the minimum. The uniform-grow fast path declines a child
    whose floor is above its share. In the Cachegrind gate, layouts that fit run 1.4 to
    3.6 % more instructions; the two overflow benchmarks run 20 and 22 % more, for the
    walks that give them sizes that fit.
27. **Heights after widths (0.6, 2026-11-22).** Heights are sized after text wraps, as
    Clay orders its passes: the sizing pass settles every width, text wraps at those
    widths, and a heights pass sizes heights again from the wrapped text, aspect ratios,
    and wrapping rows' lines. A grow-height child in a row, wrapping or not, stretches to
    the row's wrapped height; a grow child in a column shares the height its wrapped
    siblings leave. Before, every height was sized from one-line text: a stretched child
    stayed one line tall beside a wrapped sibling, and a grow child in a fixed column took
    space its wrapped sibling then overflowed into. GPUI reaches the same sizes through
    Taffy, which measures a text at each width it needs and caches the answers; sizing
    heights after widths measures each text once, with no cache and no measure callback.
    The heights pass is incremental. Each height that follows a width marks its element,
    one backward walk recomputes those minimums and marks a parent whose child's minimum
    changed, and one forward walk sizes the children of each marked parent, marking a
    child whose height changed. Everything else keeps the sizing pass's heights, which no
    changed minimum affects. Floating subtrees run the same three steps once each,
    replacing a pass that sized every element of the subtree again from its own size,
    which took a percent child's fraction twice. The pass replaces the walks that grew
    fit-content parents after wrapping (`propagateHeightChange`, `growMarkedParents`).
    In the Cachegrind gate, layouts without derived heights run 1 % fewer to 0.45 %
    more instructions; the two aspect-ratio benchmarks, a column of 1,000 aspect
    children that overflow it, run 24 % more, for the walks that re-share the column.
28. **Grids (0.6, 2026-11-22).** `Style.grid` lays a box's children on shared column
    lines: up to 32 `.fit`, `.fixed`, `.grow`, or `.percent` columns with `min` and
    `max`, rows that are listed or implicit, a separate row gap, row-major placement in
    declaration order with spans and explicit columns, and row boxes (`cell.row`), one
    keyed box per table row whose cells sit on the grid's columns. `docs/layout-grid.md`
    is the specification. It takes Clay's sizing order and largest-first shrink, CSS
    grid's track kinds and placement, SwiftUI's `GridRow` for row boxes, and GPUI's
    separate row gap. Grow columns grow from their content's floor, as CSS `1fr` does,
    so equal weights give equal columns under long text; columns shrink to their
    floors, as decision 26 shrinks children. A grid measures each text once, in the
    passes every box uses: its minimum pass places the cells and takes the column
    minimums, the sizing pass resolves the columns and sizes each cell, and decision 27's
    heights pass sizes the rows from the wrapped text. Each grid claims a slot of
    `build.grid_count_frame_max`, reserved at init, which holds its tracks, its resolved
    columns, and the position pass's row state, so boxes that are not grids carry no
    grid state. The minimum walk is specialized at compile time for frames without a
    grid, as it is for floors. In the Cachegrind gate, the layout passes of layouts
    without a grid run 0.4 % to 0.9 % more instructions, for the grid branches in the
    sizing and position passes; `openElement` now inlines into its caller without
    copying the declaration, so building and laying out those layouts runs 12 % to 28 %
    fewer instructions, and `mixed_layout`, mostly text, the same. A table of 300 row
    boxes lays out at about 180 ns a node, like the other layouts, and a dashboard of
    100 nested four-cell grids at about 0.9 µs a grid.

## Open questions

None.
