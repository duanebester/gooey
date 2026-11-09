//! Compile-time pin list for Gooey's Tier-1 public API.
//!
//! Every name referenced below is a **promise**: deleting or renaming
//! it must be an explicit, intentional act that updates this file in
//! the same change. The point is **not** to pin every public decl —
//! that's what `std.testing.refAllDecls(@This())` in `root.zig` already
//! does at test-discovery time. The point is to call out the small,
//! deliberate surface that examples and downstream apps reach for, so
//! that an accidental rename of e.g. `gooey.Cx` fails the
//! **`zig build test`** step with a
//! file pointing at *this* file rather than at every example.
//!
//! ## Three pin tiers
//!
//! 1. **Curated core (7).** Flat top-level names re-exported from
//!    `root.zig` ([`Color`, `log`,
//!    `std_options`]). These are the names every example's header
//!    imports unprefixed.
//! 2. **Namespace anchors.** `gooey.<ns>` exists and is a struct/file —
//!    `core`, `scene`, `layout`,
//!    `animation`, `input`, `platform`, `image`,
//!    `svg`, `text`, `debug`, `validation`, `accessibility`, `ai`,
//!    `file_dialog`. The anchor *promise* is just that the
//!    namespace stays addressable; the names *inside* are pinned by
//!    tier 3.
//! 3. **Tier-1 namespaced names.** Concrete decls inside each
//!    namespace that are reached for in `src/examples/*.zig`. A grep
//!    of `gooey.<ns>.<Name>` across `examples/` was used to seed this
//!    list; new entries must be added explicitly when an example
//!    starts depending on a new name.
//!
//! The Element lifecycle is **not** gated by this file; it pins names only.
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

const gooey = @import("root.zig");

// =============================================================================
// Tier 1 — curated core (flat names at `gooey.X`)
// =============================================================================

/// `gooey.Color`, `gooey.log`,
/// `gooey.std_options` — the flat names guaranteed to live directly on
/// `root.zig`. Removing any of these is a breaking
/// change that downstream apps see at every `gooey.<name>` call site.
///
/// `Color` is a type; `log` is a
/// namespace module; `std_options` is a runtime value (the
/// `std.Options` looked up by name on the root source file — keep the
/// exact name to satisfy the Zig std-options contract).
fn pinCuratedCore() void {
    comptime {
        // Types: reference the type itself so a future rename of the
        // underlying struct (e.g. `Cx` → `RenderContext`) is caught
        // even if a re-export shim keeps the old name addressable.
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
        _ = gooey.geometry;
        _ = gooey.input;
        _ = gooey.scene;
        _ = gooey.animation;
        _ = gooey.layout;
        _ = gooey.text;
        _ = gooey.platform;
        _ = gooey.image;
        _ = gooey.svg;
        _ = gooey.debug;
        _ = gooey.validation;
        _ = gooey.accessibility;
        _ = gooey.file_dialog;
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

/// `gooey.geometry` — value types reached for by layout-aware examples
/// (sizing in `Corners` / `Edges` / `Size`). `Color` lives on the flat-7
/// above; do not double-pin it here.
fn pinTier1NamespacedGeometry() void {
    comptime {
        _ = gooey.geometry.Point;
        _ = gooey.geometry.Size;
        _ = gooey.geometry.Rect;
        _ = gooey.geometry.Bounds;
        _ = gooey.geometry.Edges;
        _ = gooey.geometry.Corners;
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
        // `measureText`'s value types: a downstream that stores a
        // measurement+options pair reaches for both under `gooey.text`.
        _ = gooey.text.TextMeasurement;
        _ = gooey.text.MeasureTextOptions;
    }
}

/// `gooey.platform` — the OS-window types reached for by examples
/// that want a `*PlatformWindow` handle (native renderer probes).
fn pinTier1NamespacedPlatformAndRuntime() void {
    comptime {
        _ = gooey.platform.Platform;
        _ = gooey.platform.PlatformWindow;
    }
}

/// `gooey.image` / `gooey.svg` — asset-loader anchors. Both expose
/// an `*Atlas` and a `Loader` (or rasterizer); pin the public face
/// so the examples keep compiling against them.
fn pinTier1NamespacedAssets() void {
    comptime {
        _ = gooey.image.ImageAtlas;
        _ = gooey.svg.SvgAtlas;
    }
}

// =============================================================================
// Test entry — links the pin list into the test binary
// =============================================================================

// The single test that wires all `pin*` functions into the build's
// test step. Failure mode: a Tier-1 deletion compiles `root.zig`
// fine but breaks here with a precise pointer at the missing decl.
//
// Compiling `api_check.zig` into the test binary is what makes the pin
// list enforceable: `zig build test` touches this comptime block and
// fails loudly on regression.
//
// Note: doc comments (`///`) cannot attach to `test` blocks per Zig's
// grammar, so the rationale lives here as line comments instead.
test "tier 1 public API surface compiles" {
    comptime {
        pinCuratedCore();
        pinNamespaces();

        pinTier1NamespacedGeometry();
        pinTier1NamespacedInput();
        pinTier1NamespacedScene();
        pinTier1NamespacedAnimation();
        pinTier1NamespacedLayout();
        pinTier1NamespacedText();
        pinTier1NamespacedPlatformAndRuntime();
        pinTier1NamespacedAssets();
    }
}
