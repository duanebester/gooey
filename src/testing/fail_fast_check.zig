//! Child-process checks for frame- and input-path failures that panic (CLAUDE.md §2, §17).
//!
//! Each mode drives one path that used to drop work silently and now panics with the
//! pool, capacity, and counts. A panic cannot be caught inside a test, so the `test`
//! build step runs this program once per mode and asserts that it aborts with the
//! documented message (see `addFailFastChecks` in `build.zig`). Capacity modes fill the
//! pool exactly and claim one more; allocation modes use an allocator that fails at
//! the first request made after setup. No mode may reach the end of `main`.
//!
//! Modes (first argument):
//! - `deferred-queue`: fills `Window.deferred_commands` and defers one more command.
//! - `keymap-keystroke`: binds a keystroke string that does not parse.
//! - `keymap-oom`: binds a valid keystroke when the bindings list cannot grow.
//! - `dispatch-nodes`: pushes a dispatch node when the node pool cannot grow.
//! - `focus-order`: registers a focusable when the tab-order list cannot grow.
//! - `text-edit`: rejects an over-limit edit silently, then fails on a buffer OOM.
//! - `builder-canvas`: registers one canvas past `Builder.MAX_PENDING_CANVAS`.
//! - `builder-layout`: renders text when the layout text arena cannot allocate.
//! - `font-variant`: measures text in a font variant the face set did not load.
//! - `atlas-item`: inserts one item larger than its fixed atlas.
//! - `atlas-live-set`: fills an atlas with items used this frame and inserts one more.
//! - `core-allocation`: allocates through the 0.4.0 core's lifecycle guard after init.
//! - `core-duplicate-key`: renders two boxes with one key under one parent.
//! - `core-component-depth`: nests components one level past `component_depth_max`.
//! - `core-dialog-target`: names a non-root state as a file dialog's completion handler.
//! - `core-mono-unset`: draws `.family = .mono` text in an app with no `fonts.mono`.
//! - `core-wrap-lines`: wraps one text into one line past `MAX_LINES_PER_TEXT`.
//! - `core-wrap-words`: wraps one text into one word past `MAX_WORDS_PER_TEXT`.
//! - `core-wrap-frame`: wraps two texts into one line past the frame's glyph budget.
//! - `core-deinit-running`: frees a running app without stopping it first.

const std = @import("std");
const gooey = @import("gooey");

const Mode = enum {
    @"deferred-queue",
    @"keymap-keystroke",
    @"keymap-oom",
    @"dispatch-nodes",
    @"focus-order",
    @"text-edit",
    @"builder-canvas",
    @"builder-layout",
    @"font-variant",
    @"atlas-item",
    @"atlas-live-set",
    @"core-allocation",
    @"core-duplicate-key",
    @"core-component-depth",
    @"core-dialog-target",
    @"core-mono-unset",
    @"core-wrap-lines",
    @"core-wrap-words",
    @"core-wrap-frame",
    @"core-deinit-running",
};

pub fn main(init: std.process.Init) !void {
    const args = init.minimal.args.vector;
    std.debug.assert(args.len == 2);

    const mode = std.meta.stringToEnum(Mode, std.mem.span(args[1])) orelse
        return error.UnknownMode;
    // Every allocation made after setup fails; setup itself uses `init.gpa`.
    var failing = std.testing.FailingAllocator.init(init.gpa, .{ .fail_index = 0 });
    const oom = failing.allocator();
    switch (mode) {
        .@"deferred-queue" => deferredQueue(),
        .@"keymap-keystroke" => keymapKeystroke(init.gpa),
        .@"keymap-oom" => keymapOutOfMemory(oom),
        .@"dispatch-nodes" => dispatchNodes(oom),
        .@"focus-order" => focusOrder(oom),
        .@"text-edit" => textEdit(oom),
        .@"builder-canvas" => builderCanvas(init.gpa),
        .@"builder-layout" => builderLayout(init.gpa, oom),
        .@"font-variant" => fontVariant(init.gpa, init.io),
        .@"atlas-item" => atlasItem(init.gpa, init.io),
        .@"atlas-live-set" => atlasLiveSet(init.gpa, init.io),
        .@"core-allocation" => coreAllocation(init.gpa, init.io),
        .@"core-duplicate-key" => coreTick(init.gpa, init.io, CoreApp.duplicateKey),
        .@"core-component-depth" => coreTick(init.gpa, init.io, CoreApp.nested),
        .@"core-dialog-target" => coreDialogTarget(init.gpa, init.io),
        .@"core-mono-unset" => coreTick(init.gpa, init.io, CoreApp.monoText),
        .@"core-wrap-lines" => coreTick(init.gpa, init.io, CoreApp.wrapLines),
        .@"core-wrap-words" => coreTick(init.gpa, init.io, CoreApp.wrapWords),
        .@"core-wrap-frame" => coreTick(init.gpa, init.io, CoreApp.wrapFrame),
        .@"core-deinit-running" => coreDeinitRunning(init.gpa, init.io),
    }
    std.debug.print("unreachable: {s} did not panic\n", .{@tagName(mode)});
}

const Noop = struct {
    fn deferred(_: *Noop, _: *gooey.Window) void {}
    fn paint(_: *gooey.ui.DrawContext) void {}
};

fn deferredQueue() void {
    // `deferCommand` reads only the root state, for its safety check, and the
    // queue fields, so the rest of the `Window` stays undefined.
    var window: gooey.Window = undefined;
    var state: Noop = .{};
    window.setRootState(Noop, &state);
    window.deferred_count = 0;
    const capacity: u32 = 32;
    var index: u32 = 0;
    while (index < capacity) : (index += 1) {
        window.deferCommand(Noop.deferred, .{});
    }
    std.debug.assert(window.deferred_count == capacity);
    window.deferCommand(Noop.deferred, .{});
}

fn keymapKeystroke(gpa: std.mem.Allocator) void {
    var keymap = gooey.input.Keymap.init(gpa);
    defer keymap.deinit();
    keymap.bind(Noop, "cmd-zz", null);
}

fn keymapOutOfMemory(oom: std.mem.Allocator) void {
    var keymap = gooey.input.Keymap.init(oom);
    keymap.bind(Noop, "cmd-z", null);
}

fn dispatchNodes(oom: std.mem.Allocator) void {
    var tree = gooey.context.DispatchTree.init(oom);
    _ = tree.pushNode();
}

fn focusOrder(oom: std.mem.Allocator) void {
    var focus = gooey.context.FocusManager.init(oom);
    focus.register(gooey.context.FocusHandle.init("field"));
}

fn textEdit(oom: std.mem.Allocator) void {
    const textEditFailed = gooey.runtime.input.textEditFailed;
    // An edit past `max_bytes` is an operating error: it must return, not panic.
    textEditFailed("TextInput.insertText", error.TextLimitExceeded);

    var input = gooey.widgets.TextInputState.init(oom, .{
        .x = 0,
        .y = 0,
        .width = 100,
        .height = 20,
    });
    input.insertText("x") catch |err| textEditFailed("TextInput.insertText", err);
}

fn builderCanvas(gpa: std.mem.Allocator) void {
    const capacity = gooey.ui.Builder.MAX_PENDING_CANVAS;
    var harness: BuilderHarness = undefined;
    harness.init(gpa);
    const builder = &harness.builder;
    var index: u32 = 0;
    while (index < capacity) : (index += 1) {
        builder.registerPendingCanvas(.{ .layout_id = index, .paint = &Noop.paint, .scale = 1 });
    }
    std.debug.assert(builder.pending_canvas.items.len == capacity);
    builder.registerPendingCanvas(.{ .layout_id = index, .paint = &Noop.paint, .scale = 1 });
}

fn builderLayout(gpa: std.mem.Allocator, oom: std.mem.Allocator) void {
    // The layout engine reserves its element storage at init. Text content is
    // copied into the per-frame arena, so a failing arena allocator makes the
    // first text element fail after the element itself was stored.
    var harness: BuilderHarness = undefined;
    harness.init(gpa);
    harness.engine.arena.deinit();
    harness.engine.arena = @TypeOf(harness.engine.arena).init(oom);
    harness.engine.openElement(.{}) catch |err| {
        std.debug.panic("setup: openElement failed with reserved storage: {s}", .{@errorName(err)});
    };
    harness.builder.processChildren(gooey.ui.text("x", .{}));
}

fn fontVariant(gpa: std.mem.Allocator, io: std.Io) void {
    // The standard set loads regular, medium, semibold, bold, italic, and bold
    // italic. Light is a valid variant that the set omits, so measuring it must
    // name the variant and the loaded set instead of substituting another face.
    const text = gooey.text;
    const text_system = gpa.create(text.TextSystem) catch |err| {
        std.debug.panic("setup: TextSystem allocation failed: {s}", .{@errorName(err)});
    };
    const uploads = gpa.create(text.AtlasUploads) catch |err| {
        std.debug.panic("setup: AtlasUploads allocation failed: {s}", .{@errorName(err)});
    };
    uploads.initHeadless(gpa, io) catch |err| {
        std.debug.panic("setup: AtlasUploads.initHeadless failed: {s}", .{@errorName(err)});
    };
    const atlas_options: text.AtlasOptions = .{ .size = 1024, .uploads = uploads };
    text_system.initInPlace(gpa, 1.0, io, &text.FontLimits.standard, atlas_options) catch |err| {
        std.debug.panic("setup: TextSystem.initInPlace failed: {s}", .{@errorName(err)});
    };
    text_system.loadSystemFont(.sans_serif, 16) catch |err| {
        std.debug.panic("setup: loadSystemFont failed: {s}", .{@errorName(err)});
    };
    _ = text_system.measureText(.app, "Total", .light) catch |err| {
        std.debug.panic("measureText failed instead of panicking: {s}", .{@errorName(err)});
    };
}

/// A 64² CPU-texture atlas of `kind` over its own journal, at frame 2.
fn atlasHarness(gpa: std.mem.Allocator, io: std.Io, kind: gooey.text.AtlasKind) *gooey.text.Atlas {
    const text = gooey.text;
    const uploads = gpa.create(text.AtlasUploads) catch |err| {
        std.debug.panic("setup: AtlasUploads allocation failed: {s}", .{@errorName(err)});
    };
    uploads.init(gpa, io, .{ .storage = .cpu_texture, .upload_bytes_frame_max = 64 }) catch |err| {
        std.debug.panic("setup: AtlasUploads.init failed: {s}", .{@errorName(err)});
    };
    const atlas = gpa.create(text.Atlas) catch |err| {
        std.debug.panic("setup: Atlas allocation failed: {s}", .{@errorName(err)});
    };
    atlas.init(gpa, .{ .kind = kind, .size = 64, .uploads = uploads }) catch |err| {
        std.debug.panic("setup: Atlas.init failed: {s}", .{@errorName(err)});
    };
    const frame = uploads.beginFrame(1);
    std.debug.assert(frame == 2);
    return atlas;
}

fn atlasItem(gpa: std.mem.Allocator, io: std.Io) void {
    // 63 px fits a 64 px atlas only without its 1 px border on each side.
    const atlas = atlasHarness(gpa, io, .text);
    var pixels: [63 * 4]u8 = @splat(1);
    _ = atlas.insert(63, 4, &pixels);
}

fn atlasLiveSet(gpa: std.mem.Allocator, io: std.Io) void {
    // Four 62×14 icons fill the four 16-row shelves exactly, all in frame 2;
    // none may be evicted for a fifth in the same frame.
    const atlas = atlasHarness(gpa, io, .svg);
    var pixels: [62 * 14 * 4]u8 = @splat(1);
    var index: u32 = 0;
    while (index < 4) : (index += 1) {
        std.debug.assert(atlas.insert(62, 14, &pixels) != null);
    }
    std.debug.assert(atlas.rows_active == 64);
    _ = atlas.insert(62, 14, &pixels);
}

/// A `Builder` over a real layout engine, an empty scene, and a dispatch tree.
const BuilderHarness = struct {
    engine: gooey.layout.LayoutEngine,
    scene: gooey.scene.Scene,
    tree: gooey.context.DispatchTree,
    builder: gooey.ui.Builder,

    fn init(self: *BuilderHarness, gpa: std.mem.Allocator) void {
        self.engine = gooey.layout.LayoutEngine.init(gpa) catch |err| {
            std.debug.panic("setup: LayoutEngine.init failed: {s}", .{@errorName(err)});
        };
        self.scene = gooey.scene.Scene.initEmpty(gpa);
        self.tree = gooey.context.DispatchTree.init(gpa);
        self.builder = gooey.ui.Builder.init(gpa, &self.engine, &self.scene, &self.tree);
    }
};

// =============================================================================
// 0.4.0 core
// =============================================================================

const core = gooey.core;

const CoreState = struct {};

const core_config: core.Config(CoreState) = .{
    .title = "fail-fast",
    .width = 100,
    .height = 100,
    .limits = .nano,
};

const CoreApp = struct {
    fn empty(cx: *core.Cx) void {
        cx.render(core.ui.box(.{}, .{}));
    }

    fn duplicateKey(cx: *core.Cx) void {
        cx.render(.{
            core.ui.box(.{ .key = .{ .name = "twin" } }, .{}),
            core.ui.box(.{ .key = .{ .name = "twin" } }, .{}),
        });
    }

    /// Each level renders the next through `cx.render`, so the depth grows
    /// by one per level until the budget stops it.
    const Nest = struct {
        pub fn render(self: Nest, cx: *core.Cx) void {
            cx.render(self);
        }
    };

    fn nested(cx: *core.Cx) void {
        cx.render(Nest{});
    }

    /// A window-sized box whose click requests a dialog completing on a
    /// state type that is not the root state.
    fn dialogButton(cx: *core.Cx) void {
        cx.render(core.ui.box(.{
            .key = .{ .name = "open" },
            .on_click = cx.on(requestDialog, .{}),
            .style = .{ .width = .{ .grow = 1 }, .height = .{ .grow = 1 } },
        }, .{}));
    }

    fn requestDialog(_: *CoreState, effects: *core.Effects) void {
        const on_complete = effects.handler(Stranger.picked);
        effects.openFileDialog(.{ .kind = .open, .on_complete = on_complete });
    }

    const Stranger = struct {
        fn picked(_: *Stranger) void {}
    };

    fn monoText(cx: *core.Cx) void {
        cx.render(core.ui.text("code", .{ .family = .mono }));
    }

    /// One empty line per newline, then "m": one more line than the pool
    /// holds, in 1,025 bytes, which every shaper measures.
    fn wrapLines(cx: *core.Cx) void {
        const lines = comptime newlinesThenM(gooey.layout.engine.MAX_LINES_PER_TEXT);
        cx.render(core.ui.text(&lines, .{ .wrap = .newlines }));
    }

    /// One empty word per newline, then "m": one more word than the pool
    /// holds. Words are scanned before lines are packed, so the word pool is
    /// the one exhausted.
    fn wrapWords(cx: *core.Cx) void {
        const words = comptime newlinesThenM(gooey.layout.engine.MAX_WORDS_PER_TEXT);
        cx.render(core.ui.text(&words, .{ .wrap = .words }));
    }

    /// `nano` draws at most 1,024 glyphs, so the frame holds 1,024 wrapped
    /// lines: the first text claims 1,000 and the second asks for 25.
    fn wrapFrame(cx: *core.Cx) void {
        const first = comptime newlinesThenM(999);
        const second = comptime newlinesThenM(24);
        cx.render(core.ui.box(.{}, .{
            core.ui.text(&first, .{ .wrap = .newlines }),
            core.ui.text(&second, .{ .wrap = .newlines }),
        }));
    }

    fn newlinesThenM(comptime count: u32) [count + 1]u8 {
        var bytes: [count + 1]u8 = undefined;
        @memset(bytes[0..count], '\n');
        bytes[count] = 'm';
        return bytes;
    }
};

fn initCoreApp(comptime App: type, gpa: std.mem.Allocator, io: std.Io) *App {
    const app = gpa.create(App) catch |err| {
        std.debug.panic("setup: core app allocation failed: {s}", .{@errorName(err)});
    };
    app.initHeadless(gpa, io, .{ .scale_factor = 1 }) catch |err| {
        std.debug.panic("setup: core app init failed: {s}", .{@errorName(err)});
    };
    return app;
}

fn coreAllocation(gpa: std.mem.Allocator, io: std.Io) void {
    const app = initCoreApp(core.App(CoreState, CoreApp.empty, core_config), gpa, io);
    const bytes = app.guard.allocator().alloc(u8, 16) catch return;
    _ = bytes;
}

fn coreDialogTarget(gpa: std.mem.Allocator, io: std.Io) void {
    const app = initCoreApp(core.App(CoreState, CoreApp.dialogButton, core_config), gpa, io);
    app.tick(1);
    const point = gooey.input.MouseEvent{
        .position = .{ .x = 50, .y = 50 },
        .button = .left,
        .click_count = 1,
        .modifiers = .{},
    };
    app.window.queue.push(.{ .input = .{ .mouse_down = point } });
    app.window.queue.push(.{ .input = .{ .mouse_up = point } });
    app.tick(2);
}

fn coreDeinitRunning(gpa: std.mem.Allocator, io: std.Io) void {
    const app = initCoreApp(core.App(CoreState, CoreApp.empty, core_config), gpa, io);
    app.tick(1);
    app.deinit();
}

fn coreTick(gpa: std.mem.Allocator, io: std.Io, comptime render: fn (*core.Cx) void) void {
    const app = initCoreApp(core.App(CoreState, render, core_config), gpa, io);
    app.tick(1);
}
