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

/// A `Builder` over a real layout engine, an empty scene, and a dispatch tree.
const BuilderHarness = struct {
    engine: gooey.layout.LayoutEngine,
    scene: gooey.scene.Scene,
    tree: gooey.context.DispatchTree,
    builder: gooey.ui.Builder,

    fn init(self: *BuilderHarness, gpa: std.mem.Allocator) void {
        self.engine = gooey.layout.LayoutEngine.init(gpa);
        self.scene = gooey.scene.Scene.initEmpty(gpa);
        self.tree = gooey.context.DispatchTree.init(gpa);
        self.builder = gooey.ui.Builder.init(gpa, &self.engine, &self.scene, &self.tree);
    }
};
