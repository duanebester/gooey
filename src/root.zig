//! Gooey \u2014 top-level public surface.
//!
//! Two tiers:
//!   1. The seven flat re-exports below are the curated core. They
//!      satisfy ~all uses across `src/examples/*.zig` and are the
//!      only names guaranteed to live at `gooey.X`.
//!   2. Everything else lives under a namespace
//!      (`gooey.core.Rect`, `gooey.components.Button`,
//!      `gooey.animation.lerp`, \u2026). A namespace is the
//!      source-of-truth home; the curated-core flat names are
//!      re-exports for ergonomics only.
//!
//! Earlier drafts of this layout planned a `src/prelude.zig` file plus
//! `usingnamespace gooey.prelude;` in example headers. Zig 0.16 removed
//! `usingnamespace`, so the prelude file collapses into this top-section
//! comment.
//!
//! ## Quick start
//!
//! ```zig
//! const std = @import("std");
//! const gooey = @import("gooey");
//!
//! pub const std_options = gooey.std_options;
//!
//! var state = struct { count: i32 = 0 }{};
//!
//! pub fn main(init: std.process.Init) !void {
//!     try gooey.run(AppState, &state, render, .{
//!         .title = "Counter",
//!     }, init);
//! }
//!
//! fn render(cx: *gooey.Cx) void {
//!     cx.render(gooey.ui.vstack(.{ .gap = 16 }, .{
//!         gooey.ui.text("Hello", .{}),
//!     }));
//! }
//! ```

const std = @import("std");
const builtin = @import("builtin");

// =============================================================================
// Curated core (7)
// =============================================================================

/// Run an app with the unified `Cx` context. The framework's one-liner
/// entry point. Used by ~all `pub fn main(init)` example bodies.
pub const run = @import("app.zig").runCx;

/// Cross-platform app generator. Picks the WASM `WebApp` shape on
/// freestanding targets and the native shape everywhere else; the
/// resulting type exposes a `pub fn main(init: std.process.Init)` that
/// `pub fn main = App.main;` lines hand the OS entry point off to.
pub const App = @import("app.zig").App;

/// The unified rendering context handed to every `render` callback.
/// Holds the state pointer, layout builder, animation pools, and the
/// `cx.lists` / `cx.animations` / `cx.focus` / `cx.entities` /
/// `cx.element_states` sub-namespaces.
pub const Cx = @import("app.zig").Cx;

/// Framework-level window wrapper (was `Gooey` pre-PR 7b.1b). Holds
/// per-window subsystems \u2014 focus, hover, animations, change tracker,
/// element-state pool, \u2026 \u2014 and the OS-level `PlatformWindow` handle.
pub const Window = @import("context/mod.zig").Window;

/// Literal-friendly color value used inside render fns (`Color.rgb(\u2026)`).
/// `Rect` / `Size` / `Bounds` live under `gooey.core` since they are
/// almost always layout return values, never typed explicitly.
pub const Color = @import("core/mod.zig").Color;

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
// it. Examples reach for `gooey.components.Button`, `gooey.core.Rect`,
// `gooey.animation.lerp`, etc. PR 9 removed the duplicate flat aliases
// (`gooey.Button`, `gooey.Rect`, \u2026) that lived next to these
// namespaces.

/// Core primitives: geometry (`Point` / `Rect` / `Bounds`), color,
/// element IDs, custom shaders.
pub const core = @import("core/mod.zig");

/// Input events: keycodes, mouse buttons, modifiers, event phases.
pub const input = @import("input/mod.zig");

/// Scene primitives for GPU rendering (`Quad`, `Shadow`, `Hsla`,
/// `GlyphInstance`, `render_bridge`).
pub const scene = @import("scene/mod.zig");

/// Application context: focus manager, dispatch, entity system,
/// handler types, `Window` (also re-exported in the curated core).
pub const context = @import("context/mod.zig");

/// Animation system: time-based interpolation, springs, motions,
/// staggers, the `AnimationStore` pool composed onto `Window`.
pub const animation = @import("animation/mod.zig");

/// Clay-inspired layout engine. Layout primitives and the engine itself.
pub const layout = @import("layout/layout.zig");

/// Text rendering system with backend abstraction (`TextSystem`,
/// `FontFace`, `TextMeasurement`).
pub const text = @import("text/mod.zig");

/// Declarative UI builder + theme + style types.
pub const ui = @import("ui/mod.zig");

/// High-level UI components: `Button`, `TextInput`, `Modal`, `Svg`,
/// `Image`, `Tooltip`, \u2026 (the previously flat `gooey.Button` etc. land
/// here in PR 9).
pub const components = @import("components/mod.zig");

/// Stateful widget engines: virtual / uniform / tree lists, data table,
/// scroll container.
pub const widgets = @import("widgets/mod.zig");

/// Platform abstraction (macOS/Metal, Linux/Vulkan, Web/WGPU) and the
/// `web.image_loader` async WASM image-decode shim.
pub const platform = @import("platform/mod.zig");

/// Event loop, frame rendering, multi-window app generator.
pub const runtime = @import("runtime/mod.zig");

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

/// AI integration: canvas command buffer for LLM-driven drawing.
pub const ai = @import("ai/mod.zig");

/// Cross-platform file dialogs (open/save). Async on WASM via
/// `platform.web.file_dialog`.
pub const file_dialog = @import("file_dialog.zig");

/// App entry-point types (`Cx`, `App`, `WebApp`, `CxConfig`, \u2026). The
/// curated-core `run` / `App` / `Cx` are re-exported above; reach for
/// the rest through this namespace.
pub const app = @import("app.zig");

/// Testing utilities and mock implementations. Only compiled when
/// running tests, so it adds no bloat to production builds.
pub const testing = if (builtin.is_test)
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
    // PR 9 — the previous root.zig had ~120 flat aliases of the form
    // `pub const Foo = ns.Foo`. `refAllDecls(@This())` referenced each
    // one, which forced *struct-level* analysis of the underlying
    // type and pulled in any `test {}` blocks living inside that
    // struct's body. After the slim, the curated 7 + namespace exports
    // reach mod.zig files (which have their own `refAllDecls`), but
    // type-level analysis of every leaf struct is now lazy. Most leaf
    // structs' tests are still discovered via their own file's
    // top-level `test {}` blocks; a handful of files keep their tests
    // *inside* struct bodies and need an explicit comptime touch here
    // to stay in the discovery set. The list mirrors the demotion
    // ledger — if any of these later move into a mod.zig with its own
    // `refAllDecls`, drop the corresponding line here.
    comptime {
        // Borrow the top-level namespace aliases without shadowing them.
        const anim = animation;
        const comp = components;
        const wid = widgets;
        const u = ui;
        const lay = layout;
        const plat = platform;
        const txt = text;
        const ctx = context;
        const sc = scene;
        const inp = input;
        const img = image;
        const rt = runtime;
        const co = core;

        // Animation leaves (these were `spring_mod` / `stagger_mod` /
        // `motion_mod` flat aliases pre-PR-9).
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

        // Components.
        _ = comp.Button;
        _ = comp.Checkbox;
        _ = comp.TextInput;
        _ = comp.TextArea;
        _ = comp.CodeEditor;
        _ = comp.ProgressBar;
        _ = comp.RadioGroup;
        _ = comp.RadioButton;
        _ = comp.Tab;
        _ = comp.TabBar;
        _ = comp.Svg;
        _ = comp.Icons;
        _ = comp.Lucide;
        _ = comp.Select;
        _ = comp.Image;
        _ = comp.AspectRatio;
        _ = comp.Tooltip;
        _ = comp.Modal;
        _ = comp.ValidatedTextInput;

        // Widgets.
        _ = wid.UniformListState;
        _ = wid.VirtualListState;
        _ = wid.DataTableState;
        _ = wid.TreeListState;

        // UI styles.
        _ = u.Builder;
        _ = u.Theme;
        _ = u.Box;
        _ = u.StackStyle;

        // Layout.
        _ = lay.LayoutEngine;
        _ = lay.LayoutId;
        _ = lay.LayoutConfig;

        // Platform / runtime / text.
        _ = plat.Platform;
        _ = plat.PlatformWindow;
        _ = rt.WindowHandle;
        _ = rt.MultiWindowApp;
        _ = txt.TextSystem;
        _ = txt.FontFace;

        // Context.
        _ = ctx.Entity;
        _ = ctx.HandlerRef;
        _ = ctx.OnSelectHandler;
        _ = ctx.FocusManager;
        _ = ctx.FontConfig;

        // Scene / input / image / core leaves.
        _ = sc.Scene;
        _ = sc.Quad;
        _ = sc.Shadow;
        _ = inp.InputEvent;
        _ = inp.KeyEvent;
        _ = img.ImageAtlas;
        _ = co.CustomShader;
    }
    // Leaf files with file-level `test {}` blocks that previously
    // depended on a flat alias in root.zig for analysis-discovery.
    // PR 9 removed those aliases, so we anchor the leaves here to
    // keep the test count stable. `inline for` lets us list paths in
    // bulk; `std.testing.refAllDecls(@This())` only touches a file's
    // top-level decls, but the file's own `test {}` blocks become
    // part of the test binary once the file is reachable, which the
    // `@import` call below guarantees.
    inline for (.{
        // Animation leaves — ex-flat-aliased `spring_mod` / `stagger_mod` /
        // `motion_mod`.
        @import("animation/spring.zig"),
        @import("animation/stagger.zig"),
        @import("animation/motion.zig"),
        @import("animation/animation.zig"),
        @import("animation/store.zig"),

        // Widget engines — ex-flat-aliased through `cx.zig`'s direct
        // file imports.
        @import("widgets/data_table.zig"),
        @import("widgets/tree_list.zig"),
        @import("widgets/uniform_list.zig"),
        @import("widgets/virtual_list.zig"),
        @import("widgets/code_editor_state.zig"),
        @import("widgets/text_input_state.zig"),
        @import("widgets/text_area_state.zig"),
        @import("widgets/scroll_container.zig"),
        @import("widgets/edit_history.zig"),
        @import("widgets/text_common.zig"),

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

        // Context / accessibility / AI leaves.
        @import("context/element_states.zig"),
        @import("context/global.zig"),
        @import("context/dispatch.zig"),
        @import("context/change_tracker.zig"),
        @import("context/handler.zig"),
        @import("context/entity.zig"),
        @import("accessibility/integration_test.zig"),
        @import("accessibility/tree.zig"),
        @import("ai/json_parser.zig"),
        @import("ai/theme_color.zig"),
        @import("ai/ai_canvas.zig"),

        // UI / core leaves.
        @import("ui/primitives.zig"),
        @import("core/triangulator.zig"),
        @import("validation.zig"),
    }) |leaf| {
        std.testing.refAllDecls(leaf);
    }
}
