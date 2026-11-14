//! Gooey: the public surface (contract "Shape").
//!
//! Every public name lives here, one spelling each: the app entry point
//! (`App`), the render context (`Cx`), element constructors (`ui`), handlers
//! (`Handler`, `Effects`), identity (`ElementId`, `Key`), retained state
//! (`Lifetime`, `Handle`), and the resource budget (`ResourceLimits`). The
//! `input`, `text`, and `accessibility` namespaces hold the types handlers and
//! accessibility fields name.
//!
//! `internals` is the framework's own machinery (records, the window, the
//! platform layer, the packed frame). Tests, the goldens, and library components
//! reach into it; it is not part of the API and may change in any release.
//!
//! ## Quick start
//!
//! ```zig
//! const gooey = @import("gooey");
//!
//! const State = struct { count: i32 = 0 };
//!
//! pub const App = gooey.App(State, render, .{
//!     .title = "Counter",
//!     .width = 400,
//!     .height = 300,
//!     .limits = .nano, // Resource and font budget; see `ResourceLimits`.
//! });
//!
//! pub const main = App.main;
//!
//! fn render(cx: *gooey.Cx) void {
//!     cx.render(gooey.ui.text("Hello", .{}));
//! }
//! ```

const std = @import("std");
const builtin = @import("builtin");

const core = @import("core/root.zig");

// =============================================================================
// Public surface
// =============================================================================

pub const App = core.App;
pub const Config = core.Config;
pub const Cx = core.Cx;
pub const ui = core.ui;
pub const Handler = core.Handler;
pub const Effects = core.Effects;
pub const Entity = core.Entity;
pub const ElementId = core.ElementId;
pub const Key = core.Key;
pub const Lifetime = core.Lifetime;
pub const Handle = core.Handle;
pub const Query = core.Query;
pub const Theme = core.Theme;
pub const Painter = core.Painter;
pub const PathPromptOptions = core.PathPromptOptions;
pub const SavePromptOptions = core.SavePromptOptions;
pub const Paths = core.Paths;
pub const InputEngine = core.InputEngine;
pub const AreaEngine = core.AreaEngine;
pub const EditorEngine = core.EditorEngine;

/// The application's resource budget, declared once at `App` (`.limits = ...`)
/// and validated at comptime. There is no default; pick one of five rungs,
/// smallest first: `nano` (counter-class), `small` (single-screen forms),
/// `standard` (multi-panel apps), `large` (dense content, many icons or
/// images), `ceiling` (framework maxima, for stress tests). To raise one budget
/// or field without moving the whole app up a rung, pass a modified copy, for
/// example `ResourceLimits.standard` with `atlas.image_size = 2_048`, or
/// `ResourceLimits.small` with `text.fonts = FontLimits.standard`.
pub const ResourceLimits = core.ResourceLimits;

/// The font faces every text system loads at init: `ResourceLimits.text.fonts`.
/// Each `ResourceLimits` profile carries the `FontLimits` profile of the same
/// name. Profiles: `nano` (regular only), `small` (regular, medium,
/// semibold, bold), `standard` and `large` (those plus italic and bold italic),
/// `ceiling` (all 14).
pub const FontLimits = core.FontLimits;
pub const FontSource = core.FontSource;

/// A colour value (`Color.rgb(...)`); the same type as `ui.Color`.
pub const Color = core.ui.Color;

/// Animation helpers: easing, interpolation, and timing as module functions
/// (contract decision 14).
pub const animation = core.animation;

/// Input events: keycodes, mouse buttons, modifiers, and keystrokes.
pub const input = @import("input/mod.zig");

/// Text measurement helpers and limits (`codepointCount`,
/// `run_codepoint_count_max`).
pub const text = @import("text/mod.zig");

/// Accessibility roles, states, and live-region politeness for `ui.A11y`.
pub const accessibility = @import("accessibility/mod.zig");

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
/// native. Zig looks it up by name on the root source file, so this
/// declaration must keep its exact name and stay at the top level.
///
/// ```zig
/// pub const std_options = gooey.std_options;
/// ```
pub const std_options: std.Options = if (builtin.os.tag == .freestanding)
    .{ .logFn = wasmLogFn }
else
    .{};

/// Testing utilities and mock implementations. Compiled for tests and for the
/// synthetic-text build the goldens tools use, so production builds carry none.
pub const testing = if (builtin.is_test or text.is_synthetic)
    @import("testing/mod.zig")
else
    struct {};

// =============================================================================
// Internals
// =============================================================================

/// The framework's own machinery, for tests, goldens, and library
/// components. Not API: anything here may change in any release.
pub const internals = struct {
    // The core's modules.
    pub const id = core.id;
    pub const records = core.records;
    pub const handler = core.handler;
    pub const events = core.events;
    pub const element = core.element;
    pub const cx = core.cx;
    pub const retained = core.retained;
    pub const router = core.router;
    pub const layers = core.layers;
    pub const tick = core.tick;
    pub const app = core.app;
    pub const emit = core.emit;
    pub const pack = core.pack;
    pub const packed_frame = core.packed_frame;
    pub const window = core.window;
    pub const lifecycle = core.lifecycle;
    pub const text_engine = core.text_engine;
    pub const debugger = core.debugger;
    pub const limits = @import("core/limits.zig");
    pub const backend = @import("core/backend.zig");
    pub const fixed_array = @import("core/fixed_array.zig");
    pub const interface_verify = @import("core/interface_verify.zig");

    // The layers beneath the core.
    pub const geometry = @import("geometry/mod.zig");
    pub const layout = @import("layout/layout.zig");
    pub const platform = @import("platform/mod.zig");
    pub const image = @import("image/mod.zig");
    pub const svg = @import("svg/mod.zig");
};

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
    std.testing.refAllDecls(core);
    std.testing.refAllDecls(internals);
    // `refAllDecls` reaches only the public names and the namespace
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
        // Borrow the namespace aliases without shadowing them.
        const lay = internals.layout;
        const plat = internals.platform;
        const txt = text;
        const inp = input;
        const img = internals.image;

        // Layout.
        _ = lay.LayoutEngine;
        _ = lay.LayoutConfig;

        // Platform / runtime / text.
        _ = plat.Platform;
        _ = plat.PlatformWindow;
        _ = txt.TextSystem;
        _ = txt.FontFace;

        // Input / image / core leaves.
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
        // Vulkan frame-buffer budget math. Pure Zig (no Vulkan calls), so its
        // tests run on every OS, not only where the renderer builds.
        @import("platform/linux/vk_types.zig"),
        // Path edge classification for the Vulkan and Metal mesh shaders'
        // analytic anti-aliasing. Pure Zig, tested on every OS.
        @import("platform/mesh_edges.zig"),
        // The clip-to-scissor rule of the Vulkan and WebGPU renderers.
        @import("platform/scissor.zig"),

        // Platform-independent CPU rasterizer used by the Wayland shm and
        // fbdev backends. Tested on every host, not only CPU-backend builds.
        @import("platform/cpu/raster.zig"),
        @import("platform/cpu/mesh.zig"),
        @import("platform/cpu/renderer.zig"),

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

        // Geometry leaves.
        @import("geometry/triangulator.zig"),

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
