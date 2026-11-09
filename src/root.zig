//! Gooey \u2014 top-level public surface.
//!
//! Two tiers:
//!   1. The seven flat re-exports below are the curated core. They
//!      satisfy ~all uses across `src/examples/*.zig` and are the
//!      only names guaranteed to live at `gooey.X`.
//!   2. Everything else lives under a namespace
//!      (`gooey.geometry.Rect`, `gooey.animation.lerp`, \u2026). A namespace is the
//!      source-of-truth home; the curated-core flat names are
//!      re-exports for ergonomics only.
//!
//! There is no `src/prelude.zig`: Zig has no `usingnamespace` to import
//! one unprefixed, so this top-section comment serves as the prelude.
//!
//! ## Quick start
//!
//! `gooey.core.App(...)` is the entry point: it builds a type whose `main` runs
//! natively and whose declarations generate the WASM exports on freestanding
//! targets, so the same source ships to desktop and web unchanged.
//!
//! ```zig
//! const gooey = @import("gooey");
//! const core = gooey.core;
//!
//! const State = struct { count: i32 = 0 };
//!
//! pub const App = core.App(State, render, .{
//!     .title = "Counter",
//!     .width = 400,
//!     .height = 300,
//!     .limits = .nano, // Resource and font budget; see `ResourceLimits`.
//! });
//!
//! pub const main = App.main;
//!
//! fn render(cx: *core.Cx) void {
//!     cx.render(core.ui.text("Hello", .{}));
//! }
//! ```

const std = @import("std");
const builtin = @import("builtin");

// =============================================================================
// Curated core (7)
// =============================================================================

/// The application's resource budget, declared once at `App` (`.limits = ...`)
/// and validated at comptime. There is no default; pick one of five rungs,
/// smallest first: `nano` (counter-class), `small` (single-screen forms),
/// `standard` (multi-panel apps), `large` (dense content, many icons or
/// images), `ceiling` (framework maxima, for stress tests). To raise one budget
/// or field without moving the whole app up a rung, pass a modified copy, for
/// example `ResourceLimits.standard` with `atlas.image_size = 2_048`, plus
/// `.font_limits = .standard`; the readme shows the pattern.
pub const ResourceLimits = @import("core/limits.zig").ResourceLimits;

/// The font faces every text system loads at init. `App`'s `.limits` profile
/// name selects the `FontLimits` profile of the same name; `.font_limits = ...`
/// overrides it. Profiles: `nano` (regular only), `small` (regular, medium,
/// semibold, bold), `standard` and `large` (those plus italic and bold italic),
/// `ceiling` (all 14).
pub const FontLimits = @import("core/limits.zig").FontLimits;

/// Literal-friendly color value used inside render fns (`Color.rgb(\u2026)`).
/// `Rect` / `Size` / `Bounds` live under `gooey.geometry` since they are
/// almost always layout return values, never typed explicitly.
pub const Color = @import("geometry/mod.zig").Color;

/// Platform-aware logger. Works on native and WASM without
/// `std_options`. Pair with the `gooey.std_options` one-liner if you
/// want `std.log` to route through here too.
///
/// ```zig
/// const log = gooey.log.scoped(.myapp);
/// log.info("connected to {s}", .{host});
/// ```
pub const log = @import("log.zig");

/// Pre-configured `std.Options` that routes `std.log` through the
/// browser console on WASM and falls back to the default `logFn` on
/// native. **Zig contract** \u2014 looked up by name on the root source
/// file, so this declaration must keep its exact name and stay at the
/// top level.
///
/// ```zig
/// pub const std_options = gooey.std_options;
/// ```
pub const std_options: std.Options = if (builtin.os.tag == .freestanding)
    .{ .logFn = wasmLogFn }
else
    .{};

// =============================================================================
// Namespaces
// =============================================================================
//
// Each namespace below is the canonical home for the types underneath
// it. Examples reach for `gooey.geometry.Rect`, `gooey.animation.lerp`, etc.
// Their types are not duplicated as flat aliases (`gooey.Button`,
// `gooey.Rect`, \u2026) next to these namespaces.

/// Core primitives: resource limits, the fixed-capacity array, custom
/// shaders, and compile-time interface checks.
pub const core = @import("core/mod.zig");

/// Geometry and path math: `Point` / `Size` / `Rect` / `Bounds` / `Edges` /
/// `Corners`, `Color`, `Vec2`, the triangulator, and stroke expansion.
pub const geometry = @import("geometry/mod.zig");

/// Input events: keycodes, mouse buttons, modifiers, event phases.
pub const input = @import("input/mod.zig");

/// Scene primitives for GPU rendering (`Quad`, `Shadow`, `Hsla`,
/// `GlyphInstance`, `render_bridge`).
pub const scene = @import("scene/mod.zig");

/// Animation system: time-based interpolation, springs, motions,
/// staggers, the `AnimationStore` pool composed onto `Window`.
pub const animation = @import("animation/mod.zig");

/// Clay-inspired layout engine. Layout primitives and the engine itself.
pub const layout = @import("layout/layout.zig");

/// Text rendering system with backend abstraction (`TextSystem`,
/// `FontFace`, `TextMeasurement`).
pub const text = @import("text/mod.zig");

/// Platform abstraction (macOS/Metal, Linux/Vulkan, Web/WGPU) and the
/// `web.image_loader` async WASM image-decode shim.
pub const platform = @import("platform/mod.zig");

/// Image loading and atlas caching (native async loader + WASM
/// `platform.web.image_loader` callbacks).
pub const image = @import("image/mod.zig");

/// SVG parsing, rasterization, and atlas caching.
pub const svg = @import("svg/mod.zig");

/// Debug tools: inspector, profiler, render stats.
pub const debug = @import("debug/mod.zig");

/// Form validation utilities (pure functions).
pub const validation = @import("validation.zig");

/// Accessibility (A11Y): screen reader and assistive technology support.
pub const accessibility = @import("accessibility/mod.zig");

/// Cross-platform file dialogs (open/save). Async on WASM via
/// `platform.web.file_dialog`.
pub const file_dialog = @import("file_dialog.zig");

/// Testing utilities and mock implementations. Compiled for tests and for the
/// synthetic-text build the goldens tools use, so production builds carry none.
pub const testing = if (builtin.is_test or text.is_synthetic)
    @import("testing/mod.zig")
else
    struct {};

// =============================================================================
// Internal helpers
// =============================================================================

/// WASM-compatible log function used by `std_options`. Not part of the
/// public API \u2014 callers should reach for `gooey.log` (zero-config) or
/// the `gooey.std_options` one-liner instead.
fn wasmLogFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = scope;
    const web_imports = @import("platform/web/imports.zig");
    const prefix = switch (level) {
        .err => "[error] ",
        .warn => "[warn] ",
        .info => "[info] ",
        .debug => "[debug] ",
    };
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, prefix ++ format, args) catch return;
    if (level == .err) {
        web_imports.consoleError(msg.ptr, @intCast(msg.len));
    } else {
        web_imports.consoleLog(msg.ptr, @intCast(msg.len));
    }
}

// =============================================================================
// Tests
// =============================================================================

test {
    std.testing.refAllDecls(@This());
    // `refAllDecls(@This())` reaches only the curated 7 and the namespace
    // exports. Those reach mod.zig files (which have their own
    // `refAllDecls`), but type-level analysis of every leaf struct is
    // lazy, so `test {}` blocks inside a leaf struct's body are not
    // discovered on their own. Most leaf structs' tests are discovered
    // via their own file's top-level `test {}` blocks; a handful of files
    // keep their tests *inside* struct bodies and need an explicit
    // comptime touch here to stay in the discovery set. If any of these
    // move into a mod.zig with its own `refAllDecls`, drop the
    // corresponding line here.
    comptime {
        // Borrow the top-level namespace aliases without shadowing them.
        const anim = animation;
        const lay = layout;
        const plat = platform;
        const txt = text;
        const sc = scene;
        const inp = input;
        const img = image;

        // Animation leaves.
        _ = anim.SpringConfig;
        _ = anim.SpringHandle;
        _ = anim.StaggerConfig;
        _ = anim.StaggerDirection;
        _ = anim.MotionConfig;
        _ = anim.MotionHandle;
        _ = anim.MotionPhase;
        _ = anim.SpringMotionConfig;
        _ = anim.Animation;
        _ = anim.AnimationHandle;
        _ = anim.AnimationStore;
        _ = anim.Easing;
        _ = anim.Duration;

        // Layout.
        _ = lay.LayoutEngine;
        _ = lay.LayoutId;
        _ = lay.LayoutConfig;

        // Platform / runtime / text.
        _ = plat.Platform;
        _ = plat.PlatformWindow;
        _ = txt.TextSystem;
        _ = txt.FontFace;

        // Scene / input / image / core leaves.
        _ = sc.Scene;
        _ = sc.Quad;
        _ = sc.Shadow;
        _ = inp.InputEvent;
        _ = inp.KeyEvent;
        _ = img.ImageAtlas;
    }
    // Leaf files with file-level `test {}` blocks that no namespace
    // export makes reachable, so we anchor the leaves here to keep
    // them in the test binary. `inline for` lets us list paths in
    // bulk; `std.testing.refAllDecls(@This())` only touches a file's
    // top-level decls, but the file's own `test {}` blocks become
    // part of the test binary once the file is reachable, which the
    // `@import` call below guarantees.
    inline for (.{
        // Animation leaves.
        @import("animation/spring.zig"),
        @import("animation/stagger.zig"),
        @import("animation/motion.zig"),
        @import("animation/animation.zig"),
        @import("animation/store.zig"),

        // Platform-independent web input buffer logic.
        @import("platform/web/composition_buffer.zig"),

        // Render-thread mutex and the render exclusion `Window.setFont` holds.
        @import("platform/mutex.zig"),

        // Vulkan instance-buffer budget math. Pure Zig (no Vulkan headers), so
        // its capacity tests run on every OS, not only where the renderer builds.
        @import("platform/linux/vk_types.zig"),
        // Path edge classification for the Vulkan and Metal mesh shaders'
        // analytic anti-aliasing. Pure Zig, tested on every OS.
        @import("platform/mesh_edges.zig"),

        // Platform-independent CPU rasterizer used by the Wayland shm and
        // fbdev backends. Tested on every host, not only CPU-backend builds.
        @import("platform/cpu/raster.zig"),
        @import("platform/cpu/mesh.zig"),
        @import("platform/cpu/renderer.zig"),

        // Scene leaves — path/polyline/svg test-heavy files.
        @import("scene/path.zig"),
        @import("scene/path_instance.zig"),
        @import("scene/path_mesh.zig"),
        @import("scene/mesh_pool.zig"),
        @import("scene/polyline.zig"),
        @import("scene/svg_instance.zig"),
        @import("scene/image_instance.zig"),
        @import("scene/gradient.zig"),
        @import("scene/batch_iterator.zig"),
        @import("scene/render_bridge.zig"),

        // Layout leaves.
        @import("layout/layout.zig"),
        @import("layout/engine.zig"),
        @import("layout/arena.zig"),

        // SVG leaves.
        @import("svg/path.zig"),
        @import("svg/atlas.zig"),
        @import("svg/rasterizer.zig"),

        // Image leaves.
        @import("image/atlas.zig"),
        @import("image/loader.zig"),

        // Accessibility leaves.
        @import("accessibility/integration_test.zig"),
        @import("accessibility/tree.zig"),

        // UI / core leaves.
        @import("geometry/triangulator.zig"),
        @import("validation.zig"),

        // Tier-1 public-API pin list. Lives in the
        // test-only discovery set (not on the public `gooey.*`
        // surface) so it can't accidentally become a name it is
        // itself meant to guard. The single `test "tier 1 public
        // API surface compiles"` block inside this file runs
        // every Tier-1 reference at comptime and fails the build
        // with a precise line on accidental rename/deletion.
        @import("api_check.zig"),
    }) |leaf| {
        std.testing.refAllDecls(leaf);
    }
    // The macOS host's NSTextInputClient tests need AppKit, so only a macOS
    // test binary reaches them.
    if (comptime builtin.os.tag == .macos) _ = @import("platform/macos/input_view.zig");
    // The fbdev backend is only selected by `-Dlinux-backend=fbdev`, but its
    // pixel conversion, evdev translation, and clipboard logic are pure and
    // must stay tested in the default Linux test run.
    if (builtin.os.tag == .linux) {
        std.testing.refAllDecls(@import("platform/fbdev/framebuffer.zig"));
        std.testing.refAllDecls(@import("platform/fbdev/evdev.zig"));
        std.testing.refAllDecls(@import("platform/fbdev/clipboard.zig"));
        // Only the reservation-limit test: the rest of the file calls Vulkan.
        _ = @import("platform/linux/vk_buffers.zig");
    }
}
