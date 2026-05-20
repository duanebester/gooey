//! Compile-time pin list for Gooey's Tier-1 public API.
//!
//! Every name referenced below is a **promise**: deleting or renaming
//! it must be an explicit, intentional act that updates this file in
//! the same change. The point is **not** to pin every public decl —
//! that's what `std.testing.refAllDecls(@This())` in `root.zig` already
//! does at test-discovery time. The point is to call out the small,
//! deliberate surface that examples and downstream apps reach for, so
//! that an accidental rename of e.g. `gooey.Cx` or
//! `gooey.components.Button` fails the **`zig build test`** step with a
//! file pointing at *this* file rather than at every example.
//!
//! ## Three pin tiers
//!
//! 1. **Curated core (7).** Flat top-level names re-exported from
//!    `root.zig` ([`run`, `App`, `Cx`, `Window`, `Color`, `log`,
//!    `std_options`]). These are the names every example's header
//!    imports unprefixed.
//! 2. **Namespace anchors.** `gooey.<ns>` exists and is a struct/file —
//!    `core`, `ui`, `components`, `widgets`, `scene`, `layout`,
//!    `animation`, `context`, `input`, `runtime`, `platform`, `image`,
//!    `svg`, `text`, `debug`, `validation`, `accessibility`, `ai`,
//!    `file_dialog`, `app`. The anchor *promise* is just that the
//!    namespace stays addressable; the names *inside* are pinned by
//!    tier 3.
//! 3. **Tier-1 namespaced names.** Concrete decls inside each
//!    namespace that are reached for in `src/examples/*.zig`. A grep
//!    of `gooey.<ns>.<Name>` across `examples/` was used to seed this
//!    list; new entries must be added explicitly when an example
//!    starts depending on a new name.
//!
//! ## Architecture reference
//!
//! See `docs/architectural-cleanup-plan.md` §8 "Public-API
//! verification" for the rationale, and `docs/cleanup-implementation-
//! plan.md` PR 11 (section "API check + three-phase Element
//! lifecycle") for the task framing. This file is the PR-11a half of
//! that PR — the structural Element-lifecycle work ships separately
//! and is **not** gated by this file.
//!
//! ## Adding / removing pins
//!
//! - Add: when a new Tier-1 name is introduced (either flat on
//!   `root.zig` or namespaced in a `mod.zig`), append the
//!   corresponding `_ = ...` line to the matching `pin*` block below.
//! - Remove: deletion of a pinned name MUST be paired with a deletion
//!   of its `_ = ...` line in the same commit. Reviewers gate Tier-1
//!   renames at this file — no silent removals.
//!
//! ## Failure mode
//!
//! If a pinned name disappears, `zig build test` (which links
//! `api_check.zig` via the test step in `build.zig`) fails at
//! comptime with a "no field named '<name>' in struct" error, exactly
//! at the deleted name's pin line. This is the same shape as
//! `core/interface_verify.zig`'s checks for platform backends.

const std = @import("std");
const gooey = @import("root.zig");

// =============================================================================
// Tier 1 — curated core (flat names at `gooey.X`)
// =============================================================================

/// `gooey.run`, `gooey.App`, `gooey.Cx`, `gooey.Window`, `gooey.Color`,
/// `gooey.log`, `gooey.std_options` — the 7 flat names guaranteed to
/// live directly on `root.zig`. Removing any of these is a breaking
/// change that downstream apps see at every `gooey.<name>` call site.
///
/// `run` and `App` are compile-time functions (App returns a `type`,
/// run returns `!void`); `Cx`, `Window`, `Color` are types; `log` is a
/// namespace module; `std_options` is a runtime value (the
/// `std.Options` looked up by name on the root source file — keep the
/// exact name to satisfy the Zig std-options contract).
fn pinCuratedCore() void {
    comptime {
        // Functions: assert callable shape via `@TypeOf`. The function
        // identity itself is not a value we can `_ = ` directly here
        // because both `run` and `App` are generic — referencing them
        // by `@TypeOf` is enough to force the decl to exist.
        _ = @TypeOf(gooey.run);
        _ = @TypeOf(gooey.App);

        // Types: reference the type itself so a future rename of the
        // underlying struct (e.g. `Cx` → `RenderContext`) is caught
        // even if a re-export shim keeps the old name addressable.
        _ = gooey.Cx;
        _ = gooey.Window;
        _ = gooey.Color;

        // Namespace module and runtime value. `log` is a `@import`
        // result (struct type); `std_options` is a `std.Options`
        // value whose existence is contracted-on by `std.log`.
        _ = gooey.log;
        _ = gooey.std_options;
    }
}

// =============================================================================
// Tier 2 — namespace anchors (`gooey.<ns>` exists)
// =============================================================================

/// One pin per top-level namespace anchor declared in `root.zig`.
/// Deleting a namespace would silently demote every name inside it to
/// "Tier 3 inaccessible"; this block makes that fail loudly at the
/// anchor line. The namespaces inside `core/` / `ui/` / etc. are
/// pinned by `pinTier1Namespaced*` blocks below; this block only
/// pins the top-level addressability.
fn pinNamespaces() void {
    comptime {
        _ = gooey.core;
        _ = gooey.input;
        _ = gooey.scene;
        _ = gooey.context;
        _ = gooey.animation;
        _ = gooey.layout;
        _ = gooey.text;
        _ = gooey.ui;
        _ = gooey.components;
        _ = gooey.widgets;
        _ = gooey.platform;
        _ = gooey.runtime;
        _ = gooey.image;
        _ = gooey.svg;
        _ = gooey.debug;
        _ = gooey.validation;
        _ = gooey.accessibility;
        _ = gooey.ai;
        _ = gooey.file_dialog;
        _ = gooey.app;
    }
}

// =============================================================================
// Tier 3 — namespaced Tier-1 names
// =============================================================================
//
// Each `pinTier1Namespaced<ns>` function below pins the subset of
// names from `gooey.<ns>` that examples concretely reach for. The
// list was seeded by `grep -rohE 'gooey\.<ns>\.[A-Z][a-zA-Z_]*'
// src/examples/` and is the dependency contract for those files.
//
// Per CLAUDE.md §5 ("70-line function limit") these are kept small
// and grouped by namespace so a failing build clearly says *which*
// namespace lost the name.

/// `gooey.core` — primitive types reached for by layout-aware
/// examples (sizing in `Corners` / `Edges` / `Size`, custom shader
/// types in shader demos). `Color` lives on the flat-7 above; do not
/// double-pin it here.
fn pinTier1NamespacedCore() void {
    comptime {
        _ = gooey.core.Point;
        _ = gooey.core.Size;
        _ = gooey.core.Rect;
        _ = gooey.core.Bounds;
        _ = gooey.core.Edges;
        _ = gooey.core.Corners;
        _ = gooey.core.ElementId;
        _ = gooey.core.CustomShader;
    }
}

/// `gooey.input` — input event types reached for in event-handling
/// examples and the dispatch tree.
fn pinTier1NamespacedInput() void {
    comptime {
        _ = gooey.input.InputEvent;
        _ = gooey.input.KeyEvent;
    }
}

/// `gooey.scene` — GPU-facing scene primitives reached for in the
/// canvas / charts / ai-canvas examples that emit scene quads
/// directly.
fn pinTier1NamespacedScene() void {
    comptime {
        _ = gooey.scene.Scene;
        _ = gooey.scene.Quad;
        _ = gooey.scene.Shadow;
        _ = gooey.scene.Hsla;
        _ = gooey.scene.GlyphInstance;
    }
}

/// `gooey.context` — framework subsystems reached for when an
/// example needs to drive focus / entity lookup / accessibility
/// directly (a11y_demo, focus_test_no_window, drag_drop).
fn pinTier1NamespacedContext() void {
    comptime {
        _ = gooey.context.Window;
        _ = gooey.context.Entity;
        _ = gooey.context.FocusManager;
        _ = gooey.context.FontConfig;
    }
}

/// `gooey.animation` — public animation surface. `Easing` is
/// imported by name in animation.zig; `lerp` / `lerpInt` /
/// `lerpColor` are reached unprefixed in animation interpolation.
/// `AnimationStore` is the pool composed onto `Window`.
fn pinTier1NamespacedAnimation() void {
    comptime {
        _ = gooey.animation.Easing;
        _ = gooey.animation.AnimationStore;
        _ = @TypeOf(gooey.animation.lerp);

        // `Duration` / `AnimationHandle` are the two state types
        // examples carry across frames.
        _ = gooey.animation.Duration;
        _ = gooey.animation.AnimationHandle;
    }
}

/// `gooey.layout` — layout-engine types. `LayoutId` / `CornerRadius`
/// are reached for in examples that hand-build floating containers.
/// `LayoutEngine` / `LayoutConfig` are the engine façade names.
fn pinTier1NamespacedLayout() void {
    comptime {
        _ = gooey.layout.LayoutEngine;
        _ = gooey.layout.LayoutId;
        _ = gooey.layout.LayoutConfig;
        _ = gooey.layout.CornerRadius;
    }
}

/// `gooey.text` — text-system anchors. The full `TextSystem` and
/// `FontFace` types are kept Tier-1 because every example with
/// custom-font setup reaches for them.
fn pinTier1NamespacedText() void {
    comptime {
        _ = gooey.text.TextSystem;
        _ = gooey.text.FontFace;
    }
}

/// `gooey.ui` — declarative builder + style namespace. `Builder` is
/// the type render-fns occasionally type-annotate; `Theme` is the
/// most-reached-for style; the lowercase `box` / `vstack` / `hstack`
/// / `text` / `scroll` are the primitive helpers every render fn
/// touches.
fn pinTier1NamespacedUi() void {
    comptime {
        _ = gooey.ui.Builder;
        _ = gooey.ui.Theme;
        _ = gooey.ui.Box;
        _ = gooey.ui.StackStyle;
        _ = gooey.ui.Floating;
        _ = gooey.ui.LinearGradient;
        _ = gooey.ui.RadialGradient;

        // Builder primitives — these are functions, pin via @TypeOf.
        _ = @TypeOf(gooey.ui.box);
        _ = @TypeOf(gooey.ui.hstack);
        _ = @TypeOf(gooey.ui.vstack);
        _ = @TypeOf(gooey.ui.scroll);
        _ = @TypeOf(gooey.ui.text);
        _ = @TypeOf(gooey.ui.spacer);
        _ = @TypeOf(gooey.ui.when);
        _ = @TypeOf(gooey.ui.each);
        _ = @TypeOf(gooey.ui.maybe);
        _ = @TypeOf(gooey.ui.canvas);
    }
}

/// `gooey.components` — every high-level component reached for by
/// example code. This is the largest Tier-3 block because the
/// examples-as-docs philosophy means most components have at least
/// one demo. Pin all of them so the doc set stays compilable.
fn pinTier1NamespacedComponents() void {
    comptime {
        _ = gooey.components.Button;
        _ = gooey.components.Checkbox;
        _ = gooey.components.TextInput;
        _ = gooey.components.TextArea;
        _ = gooey.components.CodeEditor;
        _ = gooey.components.ProgressBar;
        _ = gooey.components.RadioGroup;
        _ = gooey.components.RadioButton;
        _ = gooey.components.Tab;
        _ = gooey.components.TabBar;
        _ = gooey.components.Svg;
        _ = gooey.components.Icons;
        _ = gooey.components.Lucide;
        _ = gooey.components.Select;
        _ = gooey.components.Image;
        _ = gooey.components.AspectRatio;
        _ = gooey.components.Tooltip;
        _ = gooey.components.Modal;
        _ = gooey.components.ValidatedTextInput;
    }
}

/// `gooey.widgets` — stateful widget engines. Each is reached for by
/// list / table / scroll examples to size the state struct
/// explicitly. Helper enum / range types (`ScrollStrategy`,
/// `SortDirection`, `TreeEntry`) sit alongside the engine because
/// examples spell them out at call sites.
fn pinTier1NamespacedWidgets() void {
    comptime {
        _ = gooey.widgets.TextInputState;
        _ = gooey.widgets.TextAreaState;
        _ = gooey.widgets.CodeEditorState;
        _ = gooey.widgets.ScrollContainer;
        _ = gooey.widgets.UniformListState;
        _ = gooey.widgets.VirtualListState;
        _ = gooey.widgets.DataTableState;
        _ = gooey.widgets.TreeListState;
        _ = gooey.widgets.ScrollStrategy;
        _ = gooey.widgets.SortDirection;
        _ = gooey.widgets.TreeEntry;
    }
}

/// `gooey.platform` and `gooey.runtime` — multi-window / OS-window
/// types reached for by examples that drive the multi-window runner
/// or want a `*PlatformWindow` handle (glass-style demos, native
/// renderer probes).
fn pinTier1NamespacedPlatformAndRuntime() void {
    comptime {
        _ = gooey.platform.Platform;
        _ = gooey.platform.PlatformWindow;
        _ = gooey.runtime.WindowHandle;
        _ = gooey.runtime.MultiWindowApp;
    }
}

/// `gooey.image` / `gooey.svg` — asset-loader anchors. Both expose
/// an `*Atlas` and a `Loader` (or rasterizer); pin the public face
/// so the example showcase keeps compiling against them.
fn pinTier1NamespacedAssets() void {
    comptime {
        _ = gooey.image.ImageAtlas;
        _ = gooey.svg.SvgAtlas;
    }
}

/// `gooey.app` — entry-point sub-namespace. `runCx` is the
/// curated-core `run` after re-export; `App` is similarly
/// re-exported above. Pin the `CxConfig` config type that
/// long-form examples reach for (e.g. when configuring a non-
/// default window).
fn pinTier1NamespacedApp() void {
    comptime {
        _ = @TypeOf(gooey.app.runCx);
        _ = gooey.app.CxConfig;
    }
}

// =============================================================================
// Cx sub-namespaces
// =============================================================================

/// `Cx` carries five sub-namespaces as struct fields (set up in PR
/// 8.3 and pre-existing cleanup work): `lists`, `animations`,
/// `focus`, `entities`, `element_states`. Examples reach into them
/// as `cx.lists.uniformList(...)` / `cx.animations.tween(...)` /
/// `cx.focus.request(...)` / `cx.entities.handler(...)` /
/// `cx.element_states.get(T, id)`. The promise here is that the
/// **field name** stays — not the inner API surface, which is
/// audited elsewhere.
///
/// `@FieldType` is the right tool — `@hasField` would only assert
/// existence without surfacing the type, and a plain
/// `@TypeOf(cx.<field>)` would need a `*Cx` instance we don't have
/// at comptime.
fn pinCxSubNamespaces() void {
    comptime {
        _ = @FieldType(gooey.Cx, "lists");
        _ = @FieldType(gooey.Cx, "animations");
        _ = @FieldType(gooey.Cx, "focus");
        _ = @FieldType(gooey.Cx, "entities");
        _ = @FieldType(gooey.Cx, "element_states");

        // Pin the most-used `Cx` methods. `update` / `notify` /
        // `render` / `state` / `window` / `theme` / `windowSize`
        // appear in every example's render fn; deleting one would
        // break the example bodies before users hit the namespaced
        // surface.
        _ = @TypeOf(gooey.Cx.update);
        _ = @TypeOf(gooey.Cx.updateWith);
        _ = @TypeOf(gooey.Cx.notify);
        _ = @TypeOf(gooey.Cx.render);
        _ = @TypeOf(gooey.Cx.state);
        _ = @TypeOf(gooey.Cx.window);
        _ = @TypeOf(gooey.Cx.theme);
        _ = @TypeOf(gooey.Cx.windowSize);
    }
}

// =============================================================================
// Test entry — links the pin list into the test binary
// =============================================================================

// The single test that wires all `pin*` functions into the build's
// test step. Failure mode: a Tier-1 deletion compiles `root.zig`
// fine but breaks here with a precise pointer at the missing decl.
//
// Per `docs/cleanup-implementation-plan.md` PR 11, this test is what
// makes the PR's "`api_check.zig` compiled into the test binary"
// definition-of-done observable: `zig build test` will touch this
// comptime block and fail loudly on regression.
//
// Note: doc comments (`///`) cannot attach to `test` blocks per Zig's
// grammar, so the rationale lives here as line comments instead.
test "tier 1 public API surface compiles" {
    comptime {
        pinCuratedCore();
        pinNamespaces();

        pinTier1NamespacedCore();
        pinTier1NamespacedInput();
        pinTier1NamespacedScene();
        pinTier1NamespacedContext();
        pinTier1NamespacedAnimation();
        pinTier1NamespacedLayout();
        pinTier1NamespacedText();
        pinTier1NamespacedUi();
        pinTier1NamespacedComponents();
        pinTier1NamespacedWidgets();
        pinTier1NamespacedPlatformAndRuntime();
        pinTier1NamespacedAssets();
        pinTier1NamespacedApp();

        pinCxSubNamespaces();
    }
}
