//! Headless driver for the 0.3.1 runtime, used to capture goldens before the
//! port to the 0.4.0 core.
//!
//! It builds the same objects `runtime/window_context.zig` builds for a real
//! window (an `App`, a `Window`, a `Builder`, and a `Cx`), but the `Window`
//! has no platform window (`Window.initHeadlessPtr`). Frames run through the
//! unchanged `renderFrameCxRuntime` and input through the unchanged
//! `handleInputCx`, so a golden records what the shipped runtime does.
//!
//! Two inputs are pinned so a golden depends only on the trace:
//! - Accessibility is forced on, and its screen-reader poll is reset before
//!   each frame, so the tree is built every frame.
//! - The focused text input's caret blink is restarted before each frame. The
//!   caret blinks on the wall clock (`TextInputState.updateBlink`), so a slow
//!   machine would otherwise capture a hidden caret.
//!
//! This file is test tooling for the old middle and is deleted with it in
//! phase 6.

const std = @import("std");

const window_mod = @import("../context/window.zig");
const app_mod = @import("../context/app.zig");
const cx_mod = @import("../cx.zig");
const ui_mod = @import("../ui/mod.zig");
const handler_mod = @import("../context/handler.zig");
const frame_mod = @import("../runtime/frame.zig");
const input_handler = @import("../runtime/input.zig");
const input_mod = @import("../input/mod.zig");
const limits_mod = @import("../core/limits.zig");
const scene_mod = @import("../scene/mod.zig");
const a11y_types = @import("../accessibility/types.zig");
const record_dump = @import("record_dump.zig");

const assert = std.debug.assert;

const Window = window_mod.Window;
const App = app_mod.App;
const Cx = cx_mod.Cx;
const Builder = ui_mod.Builder;
const InputEvent = input_mod.InputEvent;

pub const Options = struct {
    width: f32,
    height: f32,
    scale_factor: f32,
    limits: limits_mod.ResourceLimits,
    font_limits: limits_mod.FontLimits,
    font_size: f32 = 16,
};

pub const LegacyHarness = struct {
    allocator: std.mem.Allocator,
    app: *App,
    window: *Window,
    builder: *Builder,
    cx: Cx,
    render_fn: *const fn (*Cx) void,
    limits: limits_mod.ResourceLimits,
    frame_count: u32,

    const Self = @This();

    /// Build the runtime objects in place. `self` must stay at this address:
    /// the builder keeps a pointer to `self.cx`.
    pub fn initInPlace(
        self: *Self,
        allocator: std.mem.Allocator,
        io: std.Io,
        comptime State: type,
        state: *State,
        render_fn: *const fn (*Cx) void,
        options: *const Options,
    ) !void {
        assert(options.width > 0);
        assert(options.scale_factor > 0);
        self.allocator = allocator;
        self.render_fn = render_fn;
        self.limits = options.limits;
        self.frame_count = 0;

        self.app = try allocator.create(App);
        errdefer allocator.destroy(self.app);
        try self.app.initInPlace(allocator, io);
        errdefer self.app.deinit();

        try self.initWindow(io, options);
        errdefer {
            self.window.deinit();
            allocator.destroy(self.window);
        }

        self.builder = try allocator.create(Builder);
        self.builder.* = Builder.init(
            allocator,
            self.window.layout,
            self.window.next_frame.scene,
            self.window.next_frame.dispatch,
        );
        self.builder.window = self.window;
        self.cx = .{
            ._allocator = allocator,
            ._window = self.window,
            ._builder = self.builder,
            .state_ptr = @ptrCast(state),
            .state_type_id = handler_mod.typeId(State),
        };
        self.builder.cx_ptr = @ptrCast(&self.cx);
        self.window.setRootState(State, state);
        self.window.a11y.forceEnable();
        assert(self.window.platform_window == null);
    }

    fn initWindow(self: *Self, io: std.Io, options: *const Options) !void {
        assert(options.height > 0);
        self.window = try self.allocator.create(Window);
        errdefer self.allocator.destroy(self.window);
        try self.window.initHeadlessPtr(self.allocator, .{
            .width = options.width,
            .height = options.height,
            .scale_factor = options.scale_factor,
        }, .{
            .font_name = null,
            .font_size = options.font_size,
            .limits = options.font_limits,
        }, &self.limits, io);
        self.window.app = self.app;
        self.app.bindImageLoader(self.window.resources.image_atlas);
        assert(self.window.a11y.bridgeAddressValid());
    }

    pub fn deinit(self: *Self) void {
        assert(self.frame_count <= std.math.maxInt(u32));
        self.window.clearRootState();
        self.builder.deinit();
        self.allocator.destroy(self.builder);
        self.window.deinit();
        self.allocator.destroy(self.window);
        self.app.deinit();
        self.allocator.destroy(self.app);
        self.* = undefined;
    }

    /// Build, lay out, and paint one frame, then run deferred commands.
    pub fn frame(self: *Self) !void {
        self.window.a11y.check_counter = 0;
        self.window.a11y.forceEnable();
        if (input_handler.focusedTextInput(self.window, self.builder)) |text_input| {
            text_input.cursor_visible = true;
            text_input.last_blink_time = std.Io.Timestamp.now(
                std.Io.Threaded.global_single_threaded.io(),
                .awake,
            ).toMilliseconds();
        }
        try frame_mod.renderFrameCxRuntime(&self.cx, self.render_fn);
        self.window.flushDeferredCommands();
        self.frame_count += 1;
        assert(self.window.rendered_frame.scene.frame_count_finished > 0);
    }

    /// Route one input event the way a platform window's input callback does.
    pub fn input(self: *Self, event: InputEvent) void {
        assert(self.frame_count > 0); // Input hit-tests the rendered frame.
        _ = input_handler.handleInputCx(&self.cx, null, event);
        self.window.flushDeferredCommands();
    }

    /// The frame the platform would hand to its renderer.
    pub fn packedFrame(self: *const Self) *const scene_mod.Scene {
        assert(self.frame_count > 0);
        return self.window.rendered_frame.scene;
    }

    /// The text system's glyph atlas, for the dump's glyph identity.
    pub fn glyphAtlas(self: *const Self) record_dump.GlyphAtlasView {
        const atlas = self.window.resources.text_system.getAtlas();
        assert(atlas.format == .grayscale);
        return .{ .pixels = atlas.getData(), .size = atlas.size };
    }

    pub fn viewportSize(self: *const Self) struct { width: f32, height: f32, scale: f32 } {
        assert(self.window.width > 0);
        return .{
            .width = self.window.width,
            .height = self.window.height,
            .scale = self.window.scale_factor,
        };
    }

    /// Interactive nodes of the rendered dispatch tree, in tree order.
    pub fn writeHits(self: *const Self, out: *record_dump.TextBuffer) void {
        assert(self.frame_count > 0);
        const nodes = self.window.rendered_frame.dispatch.nodes.items;
        for (nodes) |*node| {
            const bounds = node.bounds orelse continue;
            const listeners = node.listeners;
            const click = if (listeners) |block| block.click_listeners.items.len > 0 else false;
            const key = if (listeners) |block| block.key_down_listeners.items.len +
                block.simple_key_listeners.items.len > 0 else false;
            const focus = node.focus_id != null;
            if (!click and !key and !focus) continue;
            out.print("  hit {f}{s}{s}{s}\n", .{
                record_dump.Rect{ .x = bounds.x, .y = bounds.y, .w = bounds.width, .h = bounds.height },
                if (click) " click" else "",
                if (focus) " focus" else "",
                if (key) " key" else "",
            });
        }
    }

    /// The accessibility tree built this frame, indented by depth.
    pub fn writeA11y(self: *const Self, out: *record_dump.TextBuffer) void {
        assert(self.frame_count > 0);
        const tree = &self.window.a11y.tree;
        assert(tree.element_count <= tree.elements.len);
        for (tree.elements[0..tree.element_count]) |*element| {
            var depth: u32 = 0;
            var parent = element.parent;
            while (parent) |index| : (depth += 1) {
                assert(depth < tree.elements.len);
                parent = tree.elements[index].parent;
            }
            writeA11yElement(out, depth, .{
                .role = element.role,
                .name = element.name,
                .value = element.value,
                .state = element.state,
                .bounds = .{
                    .x = element.bounds.x,
                    .y = element.bounds.y,
                    .w = element.bounds.width,
                    .h = element.bounds.height,
                },
            });
        }
    }
};

/// The accessibility fields a golden records, shared with the core's dump.
pub const A11yLine = struct {
    role: a11y_types.Role,
    name: ?[]const u8,
    value: ?[]const u8,
    state: a11y_types.State,
    bounds: record_dump.Rect,
};

pub fn writeA11yElement(out: *record_dump.TextBuffer, depth: u32, line: A11yLine) void {
    assert(depth < 64);
    var indent: u32 = 0;
    while (indent < depth + 1) : (indent += 1) out.print("  ", .{});
    out.print("{s} {f}", .{ @tagName(line.role), line.bounds });
    if (line.name) |name| out.print(" name=\"{s}\"", .{name});
    if (line.value) |value| out.print(" value=\"{s}\"", .{value});
    if (line.state.focused) out.print(" focused", .{});
    if (line.state.checked) out.print(" checked", .{});
    if (line.state.selected) out.print(" selected", .{});
    if (line.state.disabled) out.print(" disabled", .{});
    out.print("\n", .{});
}
