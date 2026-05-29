# Changelog

All notable user-facing changes to Gooey land here. Cleanup-PR specifics
live in `docs/cleanup-implementation-plan.md`; this file is the
migration index callers reach for when upgrading across a breaking
change.

## 0.2.0 — 2026-05-29 (architectural cleanup: `App`/`Window`/`Cx` split, `root.zig` slim)

First release cutting the GPUI-inspired architectural cleanup (cleanup
PRs 1–11a). The `Gooey` god object is split into `App` / `Window` /
`Cx`; per-type widget maps are unified onto an `element_states` pool;
the layout engine is split per-pass; and `api_check.zig` pins the
Tier-1 public surface at comptime. The headline user-facing break is
the `root.zig` slim described below.

**Breaking.** Top-level `gooey.X` flat aliases shrunk from ~120 names
down to seven curated-core re-exports. Every other symbol moved under
its namespace. The `cx.*` deprecated forwarders added by PR 5 are
deleted; callers must reach for `cx.lists.*`, `cx.animations.*`,
`cx.focus.*`, `cx.entities.*` directly.

### Curated core (no change)

These seven names stay flat at `gooey.X`:

| Name                | Resolves to                              |
| ------------------- | ---------------------------------------- |
| `gooey.run`         | `app.runCx` (renamed from `gooey.runCx`) |
| `gooey.App`         | `app.App`                                |
| `gooey.Cx`          | `app.Cx`                                 |
| `gooey.Window`      | `context.Window`                         |
| `gooey.Color`       | `core.Color`                             |
| `gooey.log`         | `log.zig`                                |
| `gooey.std_options` | root `std.Options` constant              |

### Migration table \u2014 flat aliases demoted

The full list mirrors PR 9 Task 2 in
[`cleanup-implementation-plan.md`](./cleanup-implementation-plan.md). The
high-volume migrations (\u2265 5 example uses) are called out at the top.

| Before            | After                        |
| ----------------- | ---------------------------- |
| `gooey.runCx`     | `gooey.run`                  |
| `gooey.Button`    | `gooey.components.Button`    |
| `gooey.Image`     | `gooey.components.Image`     |
| `gooey.Entity`    | `gooey.context.Entity`       |
| `gooey.lerp`      | `gooey.animation.lerp`       |
| `gooey.TextInput` | `gooey.components.TextInput` |
| `gooey.Svg`       | `gooey.components.Svg`       |
| `gooey.Checkbox`  | `gooey.components.Checkbox`  |

Lower-volume \u2014 mechanical:

- **Components**: `Checkbox`, `TextInput`, `TextArea`, `CodeEditor`,
  `ProgressBar`, `RadioGroup`, `RadioButton`, `Tab`, `TabBar`, `Svg`,
  `Icons`, `Lucide`, `Select`, `Image`, `AspectRatio`, `Tooltip`,
  `Modal`, `ValidatedTextInput` \u2192 `gooey.components.*`.
- **Geometry** (`Color` stays in curated core): `Point`, `Size`, `Rect`,
  `Bounds`, `PointF`, `SizeF`, `BoundsF`, `Edges`, `Corners`, `Pixels`,
  `ElementId`, `CustomShader` \u2192 `gooey.core.*`.
- **Input**: `InputEvent`, `KeyEvent`, `KeyCode`, `MouseEvent`,
  `MouseButton`, `Modifiers`, `Event`, `EventPhase`, `EventResult` \u2192
  `gooey.input.*`.
- **Scene**: `Scene`, `Quad`, `Shadow`, `Hsla`, `GlyphInstance`,
  `render_bridge` \u2192 `gooey.scene.*`.
- **Image**: `ImageAtlas`, `ImageSource`, `ImageData`, `ObjectFit` \u2192
  `gooey.image.*`. The WASM async loader moves:
  `gooey.wasm_image_loader` \u2192 `gooey.platform.web.image_loader`.
- **Animation**: `Animation`, `AnimationHandle`, `AnimationStore`,
  `Easing`, `Duration`, `lerpInt`, `lerpColor`, `SpringConfig`,
  `SpringHandle`, `StaggerConfig`, `StaggerDirection`, `MotionConfig`,
  `MotionHandle`, `MotionPhase`, `SpringMotionConfig` \u2192
  `gooey.animation.*`. The sub-module aliases collapse:
  `gooey.spring_mod` \u2192 `gooey.animation.spring`,
  `gooey.stagger_mod` \u2192 `gooey.animation.stagger`,
  `gooey.motion_mod` \u2192 `gooey.animation.motion`.
- **Window family** (`Window` stays in curated core): `WindowId`,
  `WindowRegistry` \u2192 `gooey.platform.*`;
  `WindowHandle`, `WindowContext`, `MultiWindowApp`, `AppWindowOptions`,
  `MAX_WINDOWS` \u2192 `gooey.runtime.*`.
- **Layout**: `LayoutEngine`, `LayoutId`, `Sizing`, `Padding`,
  `CornerRadius`, `LayoutConfig`, `BoundingBox` \u2192 `gooey.layout.*`.
- **Widgets**: `UniformListState`, `VirtualListState`, `VisibleRange`,
  `ScrollStrategy`, `DataTableState`, `DataTableColumn`, `SortDirection`,
  `RowRange`, `ColRange`, `VisibleRange2D`, `TreeListState`, `TreeNode`,
  `TreeEntry`, `TreeLineChar` \u2192 `gooey.widgets.*`.
- **Context**: `FocusId`, `FocusHandle`, `FocusManager`, `FocusEvent`,
  `Entity`, `EntityId`, `EntityMap`, `EntityContext`, `isView`,
  `HandlerRef`, `OnSelectHandler`, `typeId`, `FontConfig` \u2192
  `gooey.context.*`.
- **App**: `CxConfig` \u2192 `gooey.runtime.CxConfig`. `WebApp` deleted
  outright \u2014 callers reach `gooey.App` (auto-dispatches to the WASM
  shape on freestanding targets).
- **Text**: `TextSystem`, `FontFace`, `TextMeasurement` \u2192 `gooey.text.*`.
- **UI styles**: `Builder`, `Theme`, `Box`, `StackStyle`, `CenterStyle`,
  `ScrollStyle`, `UniformListStyle`, `VirtualListStyle`,
  `TreeListStyle`, `DataTableStyle`, `InputStyle`, `TextAreaStyle`,
  `CodeEditorStyle` \u2192 `gooey.ui.*`.
- **Platform**: `PlatformWindow`, `PlatformVTable`, `WindowVTable`,
  `PlatformCapabilities`, `WindowOptions`, `RendererCapabilities`,
  `PathPromptOptions`, `PathPromptResult`, `SavePromptOptions` \u2192
  `gooey.platform.*`. `MacPlatform` deleted outright \u2014 callers use
  `gooey.platform.Platform` (compile-time selected per OS).

### `cx.*` forwarder deletions

PR 5 introduced the `cx.lists.*` / `cx.animations.*` / `cx.focus.*` /
`cx.entities.*` sub-namespaces alongside the original flat methods
(`cx.animate`, `cx.uniformList`, \u2026). PR 9 removes the flat forwarders:

| Before                                      | After                                               |
| ------------------------------------------- | --------------------------------------------------- |
| `cx.animate(id, cfg)`                       | `cx.animations.tween(id, cfg)`                      |
| `cx.animateComptime(id, cfg)`               | `cx.animations.tweenComptime(id, cfg)`              |
| `cx.animateOn(id, trigger, cfg)`            | `cx.animations.tweenOn(id, trigger, cfg)`           |
| `cx.animateOnComptime(id, trigger, cfg)`    | `cx.animations.tweenOnComptime(id, trigger, cfg)`   |
| `cx.restartAnimation(id, cfg)`              | `cx.animations.restart(id, cfg)`                    |
| `cx.restartAnimationComptime(id, cfg)`      | `cx.animations.restartComptime(id, cfg)`            |
| `cx.spring(id, cfg)`                        | `cx.animations.spring(id, cfg)`                     |
| `cx.springComptime(id, cfg)`                | `cx.animations.springComptime(id, cfg)`             |
| `cx.stagger(id, i, n, cfg)`                 | `cx.animations.stagger(id, i, n, cfg)`              |
| `cx.staggerComptime(id, i, n, cfg)`         | `cx.animations.staggerComptime(id, i, n, cfg)`      |
| `cx.motion(id, show, cfg)`                  | `cx.animations.motion(id, show, cfg)`               |
| `cx.motionComptime(id, show, cfg)`          | `cx.animations.motionComptime(id, show, cfg)`       |
| `cx.springMotion(id, show, cfg)`            | `cx.animations.springMotion(id, show, cfg)`         |
| `cx.springMotionComptime(id, show, cfg)`    | `cx.animations.springMotionComptime(id, show, cfg)` |
| `cx.createEntity(T, value)`                 | `cx.entities.create(T, value)`                      |
| `cx.readEntity(T, entity)`                  | `cx.entities.read(T, entity)`                       |
| `cx.writeEntity(T, entity)`                 | `cx.entities.write(T, entity)`                      |
| `cx.entityCx(T, entity)`                    | `cx.entities.context(T, entity)`                    |
| `cx.focusNext()`                            | `cx.focus.next()`                                   |
| `cx.focusPrev()`                            | `cx.focus.prev()`                                   |
| `cx.blurAll()`                              | `cx.focus.blurAll()`                                |
| `cx.focusTextField(id)`                     | `cx.focus.widget(id)`                               |
| `cx.focusTextArea(id)`                      | `cx.focus.widget(id)`                               |
| `cx.isElementFocused(id)`                   | `cx.focus.isElementFocused(id)`                     |
| `cx.uniformList(id, state, style, render)`  | `cx.lists.uniform(id, state, style, render)`        |
| `cx.treeList(id, state, style, render)`     | `cx.lists.tree(id, state, style, render)`           |
| `cx.virtualList(id, state, style, render)`  | `cx.lists.virtual(id, state, style, render)`        |
| `cx.dataTable(id, state, style, callbacks)` | `cx.lists.dataTable(id, state, style, callbacks)`   |
| `Cx.DataTableCallbacks(Cx)`                 | `cx.lists.Lists.DataTableCallbacks(Cx)`             |

### Entry-point shape

Every example now uses `pub fn main(init: std.process.Init) !void` per
Zig 0.16's "Juicy Main" contract (already landed in PR 7d-framework).
Three holdouts are valid bare `pub fn main() !void` because they don't
call into `App.main` / `runCx`: `linux_demo.zig`, `multi_window.zig`,
and the WASM-only `ai_canvas.zig` (which never called `App.main`
through the OS entry point).

### `owned: bool` audit

PR 9 Task 5 lands a compile-time audit
(`src/context/owned_flag_audit.zig`) that fails the test build if any
`_owned: bool` or `owned: bool` field appears on `Window` or its
sub-structs without being on the explicit allow-list. The allow-list:

- `AppResources.owned` \u2014 PR 7a ownership discriminator.
- `Frame.owned` \u2014 PR 7c.3a ownership discriminator.
- `DecodedImage.owned` \u2014 per-entry WASM image-loader cache marker.
- `ShapedRun.owned` \u2014 per-entry text-shaping cache marker.
