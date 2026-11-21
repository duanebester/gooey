//! Gooey's public surface: every public name, one spelling each, pinned by
//! `src/api_check.zig`. `internals` is the framework's machinery, not API:
//! anything there may change in any release (components and charts may not).

const std = @import("std");
const builtin = @import("builtin");

const core = @import("core/root.zig");
const text_mod = @import("text/mod.zig");
const accessibility_mod = @import("accessibility/mod.zig");

pub const App = core.App;
pub const Config = core.Config;
pub const Init = core.Init;
pub const Job = core.Job;
pub const JobId = core.JobId;
pub const Cx = core.Cx;
pub const ui = core.ui;
pub const Handler = core.Handler;
pub const Effects = core.Effects;
pub const Entity = core.Entity;
pub const ElementId = core.ElementId;
pub const Key = core.Key;
pub const Lifetime = core.Lifetime;
pub const Handle = core.Handle;
pub const Drag = core.Drag;
pub const Theme = core.Theme;
pub const Painter = core.Painter;
pub const PathPromptOptions = core.PathPromptOptions;
pub const SavePromptOptions = core.SavePromptOptions;
pub const Paths = core.Paths;
/// macOS title bar style for `Config.title_bar`; other platforms ignore it.
pub const TitleBar = core.TitleBar;
pub const InputEngine = core.InputEngine;
pub const AreaEngine = core.AreaEngine;
pub const EditorEngine = core.EditorEngine;

/// The application's resource budget, declared once at `App` and validated at
/// comptime. There is no default; profiles, smallest first: `nano`, `small`,
/// `standard`, `large`, `ceiling`.
pub const ResourceLimits = core.ResourceLimits;

/// The font faces loaded at init (`ResourceLimits.text.fonts`); each profile
/// carries the `FontLimits` profile of the same name.
pub const FontLimits = core.FontLimits;
pub const FontSource = core.FontSource;

/// A colour value; the same type as `ui.Color`.
pub const Color = core.ui.Color;

pub const animation = core.animation;

pub const input = @import("input/mod.zig");

pub const text = struct {
    pub const Metrics = text_mod.Metrics;
    pub const FontWeight = text_mod.FontWeight;
    pub const FontFamily = text_mod.FontFamily;
    pub const FontVariant = text_mod.FontVariant;
    pub const codepointCount = text_mod.codepointCount;
    pub const run_codepoint_count_max = text_mod.run_codepoint_count_max;
};

pub const accessibility = struct {
    pub const Role = accessibility_mod.Role;
    pub const State = accessibility_mod.State;
    pub const Live = accessibility_mod.Live;
    pub const HeadingLevel = accessibility_mod.HeadingLevel;
    pub const Orientation = accessibility_mod.Orientation;
};

pub const log = @import("log.zig");

/// `std.Options` routing `std.log` through the browser console on WASM. Zig
/// looks it up by name on the root source file, so this declaration must keep
/// its exact name and stay at the top level.
pub const std_options: std.Options = if (builtin.os.tag == .freestanding)
    .{ .logFn = wasmLogFn }
else
    .{};

/// Testing utilities, compiled only for tests and the synthetic-text build.
pub const testing = if (builtin.is_test or text_mod.is_synthetic)
    @import("testing/mod.zig")
else
    struct {};

/// The framework's own machinery. Not API: anything here may change in any release.
pub const internals = struct {
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
    pub const jobs = core.jobs;
    pub const text_engine = core.text_engine;
    pub const debugger = core.debugger;
    pub const limits = @import("core/limits.zig");
    pub const backend = @import("core/backend.zig");
    pub const fixed_array = @import("core/fixed_array.zig");
    pub const interface_verify = @import("core/interface_verify.zig");
    /// The platform host's read-only view of the rendered frame; only hosts and tests get one.
    pub const Query = core.router.Query;

    pub const geometry = @import("geometry/mod.zig");
    pub const layout = @import("layout/layout.zig");
    pub const platform = @import("platform/mod.zig");
    pub const image = @import("image/mod.zig");
    pub const svg = @import("svg/mod.zig");
    pub const text = text_mod;
    pub const accessibility = accessibility_mod;
};

/// WASM-compatible log function used by `std_options`. Not public API.
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

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(core);
    std.testing.refAllDecls(internals);
    // `refAllDecls` reaches only public names and namespace exports; leaf
    // structs' type-level analysis is lazy, so `test {}` blocks inside leaf
    // struct bodies are not discovered on their own. These comptime touches
    // keep them in the discovery set; drop a line here if its file moves into
    // a mod.zig with its own `refAllDecls`.
    comptime {
        // Borrow the namespace aliases without shadowing them.
        const lay = internals.layout;
        const plat = internals.platform;
        const txt = internals.text;
        const inp = input;
        const img = internals.image;

        _ = lay.LayoutEngine;
        _ = lay.LayoutConfig;

        _ = plat.Platform;
        _ = plat.PlatformWindow;
        _ = txt.TextSystem;
        _ = txt.FontFace;

        _ = inp.InputEvent;
        _ = inp.KeyEvent;
        _ = img.ImageAtlas;
    }
    // Leaf files whose file-level `test {}` blocks no namespace export makes
    // reachable: anchoring the import keeps them in the test binary.
    inline for (.{
        // Vulkan frame-buffer budget math; pure Zig (no Vulkan calls), so it tests on every OS.
        @import("platform/linux/vk_types.zig"),
        // Mesh-shader analytic anti-aliasing edge classification; pure Zig.
        @import("platform/mesh_edges.zig"),
        // The clip-to-scissor rule of the Vulkan and WebGPU renderers.
        @import("platform/scissor.zig"),

        // CPU rasterizer for the Wayland shm and fbdev backends; pure, tested on every host.
        @import("platform/cpu/raster.zig"),
        @import("platform/cpu/mesh.zig"),
        @import("platform/cpu/renderer.zig"),

        @import("layout/layout.zig"),
        @import("layout/engine.zig"),
        @import("layout/arena.zig"),

        @import("svg/path.zig"),
        @import("svg/atlas.zig"),
        @import("svg/rasterizer.zig"),

        @import("image/atlas.zig"),
        @import("image/loader.zig"),

        @import("accessibility/integration_test.zig"),
        @import("accessibility/tree.zig"),

        @import("geometry/triangulator.zig"),

        // Tier-1 public-API pin list, kept out of the public `gooey.*` surface
        // so it cannot accidentally become a name it is meant to guard.
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
        // The EVE transport, encoder, and cell cache are pure; the simulated
        // chip stands in for spidev, so they test on any Linux build.
        std.testing.refAllDecls(@import("platform/eve/chip.zig"));
        std.testing.refAllDecls(@import("platform/eve/display_list.zig"));
        std.testing.refAllDecls(@import("platform/eve/cells.zig"));
        std.testing.refAllDecls(@import("platform/eve/renderer.zig"));
        std.testing.refAllDecls(@import("platform/eve/images.zig"));
        std.testing.refAllDecls(@import("platform/eve/limits.zig"));
    }
    // The Vulkan files reach libwayland and support only 64-bit targets, so the
    // fbdev and eve builds, which link neither and also run on 32-bit boards,
    // skip them.
    if (comptime builtin.os.tag == .linux and !isEmbeddedLinuxBackend()) {
        // Only the reservation-limit test: the rest of the file calls Vulkan.
        _ = @import("platform/linux/vk_buffers.zig");
        // Only the present-semaphore model, which makes no Vulkan call.
        _ = @import("platform/linux/vk_renderer.zig");
    }
}

fn isEmbeddedLinuxBackend() bool {
    const selected = @import("platform/linux_backend.zig").selected;
    return selected == .fbdev or selected == .eve;
}
