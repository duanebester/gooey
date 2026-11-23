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
pub const TitleBar = core.TitleBar;
pub const InputEngine = core.InputEngine;
pub const AreaEngine = core.AreaEngine;
pub const EditorEngine = core.EditorEngine;

pub const ResourceLimits = core.ResourceLimits;

pub const FontLimits = core.FontLimits;
pub const FontSource = core.FontSource;

pub const Color = core.ui.Color;

pub const animation = core.animation;

pub const actions = struct {
    pub const Undo = core.actions.Undo;
    pub const Redo = core.actions.Redo;
    pub const Cut = core.actions.Cut;
    pub const Copy = core.actions.Copy;
    pub const Paste = core.actions.Paste;
    pub const SelectAll = core.actions.SelectAll;
    pub const Unbind = core.actions.Unbind;
    pub const TextCommand = core.actions.TextCommand;
};

pub const keymaps = struct {
    pub const Binding = core.keymaps.Binding;
    pub const text_default = core.keymaps.text_default;
    pub const text_mac = core.keymaps.text_mac;
    pub const text_pc = core.keymaps.text_pc;
    pub const context_input = core.keymaps.context_input;
    pub const context_area = core.keymaps.context_area;
    pub const context_editor = core.keymaps.context_editor;
};

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

pub const std_options: std.Options = if (builtin.os.tag == .freestanding)
    .{ .logFn = wasmLogFn }
else
    .{};

pub const testing = if (builtin.is_test or text_mod.is_synthetic)
    @import("testing/mod.zig")
else
    struct {};

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
    pub const images = core.images;
    pub const text_engine = core.text_engine;
    pub const keymap = core.keymap;
    pub const keymaps = core.keymaps;
    pub const actions = core.actions;
    pub const text_history = @import("core/text_history.zig");
    pub const debugger = core.debugger;
    pub const limits = @import("core/limits.zig");
    pub const backend = @import("core/backend.zig");
    pub const fixed_array = @import("core/fixed_array.zig");
    pub const interface_verify = @import("core/interface_verify.zig");
    pub const Query = core.router.Query;

    pub const geometry = @import("geometry/mod.zig");
    pub const layout = @import("layout/layout.zig");
    pub const platform = @import("platform/mod.zig");
    pub const image = @import("image/mod.zig");
    pub const svg = @import("svg/mod.zig");
    pub const text = text_mod;
    pub const accessibility = accessibility_mod;
};

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
    comptime {
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
    inline for (.{
        @import("platform/linux/vk_types.zig"),
        @import("platform/mesh_edges.zig"),
        @import("platform/scissor.zig"),

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

        @import("api_check.zig"),
    }) |leaf| {
        std.testing.refAllDecls(leaf);
    }
    if (comptime builtin.os.tag == .macos) _ = @import("platform/macos/input_view.zig");
    if (builtin.os.tag == .linux) {
        std.testing.refAllDecls(@import("platform/fbdev/framebuffer.zig"));
        std.testing.refAllDecls(@import("platform/fbdev/evdev.zig"));
        std.testing.refAllDecls(@import("platform/fbdev/clipboard.zig"));
        std.testing.refAllDecls(@import("platform/eve/chip.zig"));
        std.testing.refAllDecls(@import("platform/eve/display_list.zig"));
        std.testing.refAllDecls(@import("platform/eve/cells.zig"));
        std.testing.refAllDecls(@import("platform/eve/renderer.zig"));
        std.testing.refAllDecls(@import("platform/eve/images.zig"));
        std.testing.refAllDecls(@import("platform/eve/limits.zig"));
    }
    if (comptime builtin.os.tag == .linux and !isEmbeddedLinuxBackend()) {
        _ = @import("platform/linux/vk_buffers.zig");
        _ = @import("platform/linux/vk_renderer.zig");
    }
}

fn isEmbeddedLinuxBackend() bool {
    const selected = @import("platform/linux_backend.zig").selected;
    return selected == .fbdev or selected == .eve;
}
