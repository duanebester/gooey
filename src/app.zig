//! App - Convenience wrapper for quick application setup
//!
//! Provides a simple `run()` function that handles all boilerplate:
//! - Platform initialization
//! - Window creation
//! - UI context setup
//! - Event loop
//!
//! Example:
//! ```zig
//! const gooey = @import("gooey");
//!
//! var state = struct { count: i32 = 0 }{};
//!
//! pub fn main() !void {
//!     try gooey.run(.{
//!         .title = "Counter",
//!         .render = render,
//!     });
//! }
//!
//! fn render(ui: *gooey.UI) void {
//!     ui.vstack(.{ .gap = 16 }, .{
//!         gooey.ui.text("Hello", .{}),
//!     });
//! }
//! ```

const std = @import("std");

// Platform abstraction (single source of truth)
const platform = @import("platform/mod.zig");

// Core imports (platform-agnostic)
const gooey_mod = @import("core/gooey.zig");
const scene_mod = @import("core/scene.zig");
const render_bridge = @import("core/render_bridge.zig");
const layout_mod = @import("layout/layout.zig");
const engine_mod = @import("layout/engine.zig");
const text_mod = @import("text/mod.zig");
const input_mod = @import("core/input.zig");
const geometry_mod = @import("core/geometry.zig");
const ui_mod = @import("ui/ui.zig");
const dispatch_mod = @import("core/dispatch.zig");
const scroll_mod = @import("widgets/scroll_container.zig");
const text_input_mod = @import("widgets/text_input.zig");
const text_area_mod = @import("widgets/text_area.zig");
const cx_mod = @import("cx.zig");

// Use platform types directly
pub const Cx = cx_mod.Cx;
const TextInput = text_input_mod.TextInput;
const TextArea = text_area_mod.TextArea;
const Platform = platform.Platform;
const Window = platform.Window;
const DispatchNodeId = dispatch_mod.DispatchNodeId;
const Gooey = gooey_mod.Gooey;
const Scene = scene_mod.Scene;
const Hsla = scene_mod.Hsla;
const Quad = scene_mod.Quad;
const Shadow = scene_mod.Shadow;
const LayoutEngine = layout_mod.LayoutEngine;
const TextSystem = text_mod.TextSystem;
const ScrollContainer = scroll_mod.ScrollContainer;
const InputEvent = input_mod.InputEvent;
const Builder = ui_mod.Builder;

/// UI context passed to render callbacks (alias for Gooey with Builder integrated)
pub const UI = struct {
    gooey: *Gooey,
    builder: *Builder,

    const Self = @This();

    // =========================================================================
    // Layout shortcuts (delegate to builder)
    // =========================================================================

    pub fn vstack(self: *Self, style: ui_mod.StackStyle, children: anytype) void {
        self.builder.vstack(style, children);
    }

    pub fn hstack(self: *Self, style: ui_mod.StackStyle, children: anytype) void {
        self.builder.hstack(style, children);
    }

    pub fn box(self: *Self, props: ui_mod.Box, children: anytype) void {
        self.builder.box(props, children);
    }

    pub fn boxWithId(self: *Self, id: []const u8, props: ui_mod.Box, children: anytype) void {
        self.builder.boxWithId(id, props, children);
    }

    pub fn center(self: *Self, style: ui_mod.CenterStyle, children: anytype) void {
        self.builder.center(style, children);
    }

    pub fn when(self: *Self, condition: bool, children: anytype) void {
        self.builder.when(condition, children);
    }

    pub fn maybe(self: *Self, optional: anytype, comptime render_fn: anytype) void {
        self.builder.maybe(optional, render_fn);
    }

    pub fn each(self: *Self, items: anytype, comptime render_fn: anytype) void {
        self.builder.each(items, render_fn);
    }

    // =========================================================================
    // Widget access
    // =========================================================================

    pub fn textInput(self: *Self, id: []const u8) ?*TextInput {
        return self.gooey.textInput(id);
    }

    /// Get a TextArea widget by ID
    pub fn textArea(self: *Self, id: []const u8) ?*TextArea {
        return self.gooey.textArea(id);
    }

    pub fn focusTextInput(self: *Self, id: []const u8) void {
        self.gooey.focusTextInput(id);
    }

    /// Focus a TextArea by ID
    pub fn focusTextArea(self: *Self, id: []const u8) void {
        self.gooey.focusTextArea(id);
    }

    /// Focus next element in tab order
    pub fn focusNext(self: *Self) void {
        self.gooey.focusNext();
    }

    /// Focus previous element in tab order
    pub fn focusPrev(self: *Self) void {
        self.gooey.focusPrev();
    }

    /// Clear all focus
    pub fn blurAll(self: *Self) void {
        self.gooey.blurAll();
    }

    /// Check if an element is focused
    pub fn isElementFocused(self: *Self, id: []const u8) bool {
        return self.gooey.isElementFocused(id);
    }

    // =========================================================================
    // Scrolling
    // =========================================================================

    pub fn scroll(self: *Self, id: []const u8, style: ui_mod.ScrollStyle, children: anytype) void {
        self.builder.scroll(id, style, children);
    }

    pub fn scrollContainer(self: *Self, id: []const u8) ?*ScrollContainer {
        return self.gooey.widgets.scrollContainer(id);
    }

    // =========================================================================
    // Render control
    // =========================================================================

    pub fn requestRender(self: *Self) void {
        self.gooey.requestRender();
    }

    /// Get window dimensions
    pub fn windowSize(self: *Self) struct { width: f32, height: f32 } {
        return .{
            .width = self.gooey.width,
            .height = self.gooey.height,
        };
    }
};

/// Configuration for the simple run() API
pub const RunConfig = struct {
    title: []const u8 = "Gooey App",
    width: f64 = 800,
    height: f64 = 600,
    background_color: ?geometry_mod.Color = null,

    /// Called each frame to build the UI
    render: *const fn (*UI) void,

    /// Called for input events (optional). Return true if handled.
    on_event: ?*const fn (*UI, InputEvent) bool = null,

    /// Custom shader sources (Shadertoy-compatible MSL)
    custom_shaders: []const []const u8 = &.{},
};

/// Run a Gooey application with minimal boilerplate.
///
/// This is the simplest API for apps that don't need typed state management.
/// For stateful apps, use `runCx()` instead.
///
/// Example:
/// ```zig
/// pub fn main() !void {
///     try gooey.run(.{
///         .title = "My App",
///         .render = render,
///     });
/// }
///
/// fn render(g: *gooey.UI) void {
///     g.box(.{}, .{ ui.text("Hello!", .{}) });
/// }
/// ```
pub fn run(config: RunConfig) !void {
    // Wrapper state that holds the original callbacks
    const WrapperState = struct {
        render_fn: *const fn (*UI) void,
        event_fn: ?*const fn (*UI, InputEvent) bool,
    };

    var wrapper_state = WrapperState{
        .render_fn = config.render,
        .event_fn = config.on_event,
    };

    // Use runCx internally with a wrapper render function
    try runCx(WrapperState, &wrapper_state, struct {
        fn render(cx: *Cx) void {
            const ws = cx.state(WrapperState);
            var ui_wrapper = UI{
                .gooey = cx.getGooey(),
                .builder = cx.getBuilder(),
            };
            ws.render_fn(&ui_wrapper);
        }
    }.render, .{
        .title = config.title,
        .width = config.width,
        .height = config.height,
        .background_color = config.background_color,
        .on_event = if (config.on_event) |_| struct {
            fn on_event(cx: *Cx, event: InputEvent) bool {
                const ws = cx.state(WrapperState);
                if (ws.event_fn) |handler| {
                    var ui_wrapper = UI{
                        .gooey = cx.getGooey(),
                        .builder = cx.getBuilder(),
                    };
                    return handler(&ui_wrapper, event);
                }
                return false;
            }
        }.on_event else null,
        .custom_shaders = config.custom_shaders,
    });
}

// =============================================================================
// Cx API - New Unified Context
// =============================================================================

/// Configuration for gooey.runCx()
pub fn CxConfig(comptime State: type) type {
    _ = State; // State type captured for type safety
    return struct {
        title: []const u8 = "Gooey App",
        width: f64 = 800,
        height: f64 = 600,
        background_color: ?geometry_mod.Color = null,

        /// Called for input events (optional). Return true if handled.
        on_event: ?*const fn (*Cx, input_mod.InputEvent) bool = null,

        /// Custom shader sources (Shadertoy-compatible MSL)
        custom_shaders: []const []const u8 = &.{},

        // === Glass/Transparency Options ===

        /// Background opacity (0.0 = fully transparent, 1.0 = opaque)
        /// Values < 1.0 enable transparency effects
        background_opacity: f64 = 1.0,

        /// Glass/blur style for transparent windows
        glass_style: Window.GlassStyle = .none,

        /// Corner radius for glass effect (macOS 26+ only)
        glass_corner_radius: f64 = 16.0,

        /// Make titlebar transparent (blends with window content)
        titlebar_transparent: bool = false,

        /// Extend content under titlebar (full bleed)
        full_size_content: bool = false,
    };
}

/// Run a Gooey application with the unified Cx context.
///
/// This is the recommended API for new applications.
///
/// ## Example
/// ```zig
/// const AppState = struct {
///     count: i32 = 0,
///     pub fn increment(self: *AppState) void {
///         self.count += 1;
///     }
/// };
///
/// pub fn main() !void {
///     var state = AppState{};
///     try gooey.runCx(AppState, &state, render, .{
///         .title = "Counter",
///     });
/// }
///
/// fn render(cx: *gooey.Cx) void {
///     const s = cx.state(AppState);
///     cx.vstack(.{}, .{
///         gooey.ui.textFmt("Count: {}", .{s.count}, .{}),
///         gooey.Button{ .label = "+", .on_click_handler = cx.update(AppState, AppState.increment) },
///     });
/// }
/// ```
pub fn runCx(
    comptime State: type,
    state: *State,
    comptime render: fn (*Cx) void,
    config: CxConfig(State),
) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize platform
    var plat = try Platform.init();
    defer plat.deinit();

    // Default background color
    const bg_color = config.background_color orelse geometry_mod.Color.init(0.95, 0.95, 0.95, 1.0);

    // Create window
    var window = try Window.init(allocator, &plat, .{
        .title = config.title,
        .width = config.width,
        .height = config.height,
        .background_color = bg_color,
        .custom_shaders = config.custom_shaders,
        // Glass/transparency options
        .background_opacity = config.background_opacity,
        .glass_style = config.glass_style,
        .glass_corner_radius = config.glass_corner_radius,
        .titlebar_transparent = config.titlebar_transparent,
        .full_size_content = config.full_size_content,
    });
    defer window.deinit();

    // Initialize Gooey with owned resources
    var gooey_ctx = try Gooey.initOwned(allocator, window);
    defer gooey_ctx.deinit();

    // Initialize UI Builder
    var builder = Builder.init(
        allocator,
        gooey_ctx.layout,
        gooey_ctx.scene,
        gooey_ctx.dispatch,
    );
    defer builder.deinit();
    builder.gooey = &gooey_ctx;

    // Create unified Cx context
    var cx = Cx{
        .allocator = allocator,
        .gooey = &gooey_ctx,
        .builder = &builder,
        .state_ptr = @ptrCast(state),
        .state_type_id = cx_mod.typeId(State),
    };

    // Set cx_ptr on builder so components can receive *Cx
    builder.cx_ptr = @ptrCast(&cx);

    // Set root state for handler callbacks
    const handler_mod = @import("core/handler.zig");
    handler_mod.setRootState(State, state);
    defer handler_mod.clearRootState();

    // Store references for callbacks
    const CallbackState = struct {
        var g_cx: *Cx = undefined;
        var g_on_event: ?*const fn (*Cx, input_mod.InputEvent) bool = null;
        var g_building: bool = false;

        fn onRender(win: *Window) void {
            _ = win;
            if (g_building) return;
            g_building = true;
            defer g_building = false;

            renderFrameCx(g_cx, render) catch |err| {
                std.debug.print("Render error: {}\n", .{err});
            };
        }

        fn onInput(win: *Window, event: input_mod.InputEvent) bool {
            _ = win;
            return handleInputCx(g_cx, g_on_event, event);
        }
    };

    CallbackState.g_cx = &cx;
    CallbackState.g_on_event = config.on_event;

    // Set callbacks
    window.setRenderCallback(CallbackState.onRender);
    window.setInputCallback(CallbackState.onInput);
    window.setTextAtlas(gooey_ctx.text_system.getAtlas());
    window.setScene(gooey_ctx.scene);

    // Run the event loop
    plat.run();
}

/// Internal: render a single frame with Cx context
pub fn renderFrameCx(cx: *Cx, comptime render_fn: fn (*Cx) void) !void {
    // Reset dispatch tree for new frame
    cx.gooey.dispatch.reset();

    cx.gooey.beginFrame();

    // Reset builder state
    cx.builder.id_counter = 0;
    cx.builder.pending_inputs.clearRetainingCapacity();
    cx.builder.pending_text_areas.clearRetainingCapacity();
    cx.builder.pending_scrolls.clearRetainingCapacity();

    // Call user's render function with Cx
    render_fn(cx);

    // End frame and get render commands
    const commands = try cx.gooey.endFrame();

    // Sync bounds from layout to dispatch tree
    for (cx.gooey.dispatch.nodes.items) |*node| {
        if (node.layout_id) |layout_id| {
            node.bounds = cx.gooey.layout.getBoundingBox(layout_id);
        }
    }

    // Register hit regions
    cx.builder.registerPendingScrollRegions();

    // Clear scene
    cx.gooey.scene.clear();

    // Render all commands
    for (commands) |cmd| {
        try renderCommand(cx.gooey, cmd);
    }

    // Render text inputs
    for (cx.builder.pending_inputs.items) |pending| {
        const bounds = cx.gooey.layout.getBoundingBox(pending.layout_id.id);
        if (bounds) |b| {
            if (cx.gooey.textInput(pending.id)) |input_widget| {
                const inset = pending.style.padding + pending.style.border_width;
                input_widget.bounds = .{
                    .x = b.x + inset,
                    .y = b.y + inset,
                    .width = pending.inner_width,
                    .height = pending.inner_height,
                };
                input_widget.setPlaceholder(pending.style.placeholder);
                input_widget.style.text_color = render_bridge.colorToHsla(pending.style.text_color);
                input_widget.style.placeholder_color = render_bridge.colorToHsla(pending.style.placeholder_color);
                input_widget.style.selection_color = render_bridge.colorToHsla(pending.style.selection_color);
                input_widget.style.cursor_color = render_bridge.colorToHsla(pending.style.cursor_color);
                try input_widget.render(cx.gooey.scene, cx.gooey.text_system, cx.gooey.scale_factor);
            }
        }
    }

    // Render text areas
    for (cx.builder.pending_text_areas.items) |pending| {
        const bounds = cx.gooey.layout.getBoundingBox(pending.layout_id.id);
        if (bounds) |b| {
            if (cx.gooey.textArea(pending.id)) |ta_widget| {
                ta_widget.bounds = .{
                    .x = b.x + pending.style.padding + pending.style.border_width,
                    .y = b.y + pending.style.padding + pending.style.border_width,
                    .width = pending.inner_width,
                    .height = pending.inner_height,
                };
                ta_widget.style.text_color = render_bridge.colorToHsla(pending.style.text_color);
                ta_widget.style.placeholder_color = render_bridge.colorToHsla(pending.style.placeholder_color);
                ta_widget.style.selection_color = render_bridge.colorToHsla(pending.style.selection_color);
                ta_widget.style.cursor_color = render_bridge.colorToHsla(pending.style.cursor_color);
                ta_widget.setPlaceholder(pending.style.placeholder);
                try ta_widget.render(cx.gooey.scene, cx.gooey.text_system, cx.gooey.scale_factor);
            }
        }
    }

    // Render scrollbars
    for (cx.builder.pending_scrolls.items) |pending| {
        if (cx.gooey.widgets.scrollContainer(pending.id)) |scroll_widget| {
            try scroll_widget.renderScrollbars(cx.gooey.scene);
        }
    }

    cx.gooey.scene.finish();
}

/// Internal: handle input with Cx context
pub fn handleInputCx(
    cx: *Cx,
    on_event: ?*const fn (*Cx, input_mod.InputEvent) bool,
    event: input_mod.InputEvent,
) bool {
    // Handle scroll events
    if (event == .scroll) {
        const scroll_ev = event.scroll;
        const x: f32 = @floatCast(scroll_ev.position.x);
        const y: f32 = @floatCast(scroll_ev.position.y);

        // Check TextAreas for scroll
        for (cx.builder.pending_text_areas.items) |pending| {
            const bounds = cx.gooey.layout.getBoundingBox(pending.layout_id.id);
            if (bounds) |b| {
                if (x >= b.x and x < b.x + b.width and y >= b.y and y < b.y + b.height) {
                    if (cx.gooey.textArea(pending.id)) |ta| {
                        if (ta.line_height > 0 and ta.viewport_height > 0) {
                            const delta_y: f32 = @floatCast(scroll_ev.delta.y);
                            const content_height: f32 = @as(f32, @floatFromInt(ta.lineCount())) * ta.line_height;
                            const max_scroll: f32 = @max(0, content_height - ta.viewport_height);
                            const new_offset = ta.scroll_offset_y - delta_y * 20;
                            ta.scroll_offset_y = std.math.clamp(new_offset, 0, max_scroll);
                            cx.notify();
                            return true;
                        }
                    }
                }
            }
        }

        // Check scroll containers
        for (cx.builder.pending_scrolls.items) |pending| {
            const bounds = cx.gooey.layout.getBoundingBox(pending.layout_id.id);
            if (bounds) |b| {
                if (x >= b.x and x < b.x + b.width and y >= b.y and y < b.y + b.height) {
                    if (cx.gooey.widgets.getScrollContainer(pending.id)) |sc| {
                        if (sc.handleScroll(scroll_ev.delta.x, scroll_ev.delta.y)) {
                            cx.notify();
                            return true;
                        }
                    }
                }
            }
        }
    }

    // Handle mouse_moved for hover state
    if (event == .mouse_moved or event == .mouse_dragged) {
        const pos = switch (event) {
            .mouse_moved => |m| m.position,
            .mouse_dragged => |m| m.position,
            else => unreachable,
        };
        const x: f32 = @floatCast(pos.x);
        const y: f32 = @floatCast(pos.y);

        if (cx.gooey.updateHover(x, y)) {
            cx.notify();
        }
    }

    // Handle mouse_exited to clear hover
    if (event == .mouse_exited) {
        cx.gooey.clearHover();
        cx.notify();
    }

    // Handle mouse down through dispatch tree
    if (event == .mouse_down) {
        const pos = event.mouse_down.position;
        const x: f32 = @floatCast(pos.x);
        const y: f32 = @floatCast(pos.y);

        // Check if click is in a TextArea
        for (cx.builder.pending_text_areas.items) |pending| {
            const bounds = cx.gooey.layout.getBoundingBox(pending.layout_id.id);
            if (bounds) |b| {
                if (x >= b.x and x < b.x + b.width and y >= b.y and y < b.y + b.height) {
                    cx.gooey.focusTextArea(pending.id);
                    cx.notify();
                    return true;
                }
            }
        }

        if (cx.gooey.dispatch.hitTest(x, y)) |target| {
            if (cx.gooey.dispatch.getNodeConst(target)) |node| {
                if (node.focus_id) |focus_id| {
                    if (cx.gooey.focus.getHandleById(focus_id)) |handle| {
                        cx.gooey.focusElement(handle.string_id);
                    }
                }
            }

            if (cx.gooey.dispatch.dispatchClick(target, cx.gooey)) {
                cx.notify();
                return true;
            }
        }
    }

    // Let user's event handler run first
    if (on_event) |handler| {
        if (handler(cx, event)) return true;
    }

    // Route keyboard/text events to focused widgets
    switch (event) {
        .key_down => |k| {
            if (k.key == .tab) {
                if (k.modifiers.shift) {
                    cx.gooey.focusPrev();
                } else {
                    cx.gooey.focusNext();
                }
                return true;
            }

            // Try action dispatch through focus path
            if (cx.gooey.focus.getFocused()) |focus_id| {
                var path_buf: [64]dispatch_mod.DispatchNodeId = undefined;
                if (cx.gooey.dispatch.focusPath(focus_id, &path_buf)) |path| {
                    var ctx_buf: [64][]const u8 = undefined;
                    const contexts = cx.gooey.dispatch.contextStack(path, &ctx_buf);

                    if (cx.gooey.keymap.match(k.key, k.modifiers, contexts)) |binding| {
                        if (cx.gooey.dispatch.dispatchAction(binding.action_type, path, cx.gooey)) {
                            cx.notify();
                            return true;
                        }
                    }

                    if (cx.gooey.dispatch.dispatchKeyDown(focus_id, k)) {
                        cx.notify();
                        return true;
                    }
                }
            } else {
                var path_buf: [64]dispatch_mod.DispatchNodeId = undefined;
                if (cx.gooey.dispatch.rootPath(&path_buf)) |path| {
                    if (cx.gooey.keymap.match(k.key, k.modifiers, &.{})) |binding| {
                        if (cx.gooey.dispatch.dispatchAction(binding.action_type, path, cx.gooey)) {
                            cx.notify();
                            return true;
                        }
                    }
                }
            }

            // Handle focused TextInput
            if (cx.gooey.getFocusedTextInput()) |input| {
                if (isControlKey(k.key, k.modifiers)) {
                    input.handleKey(k) catch {};
                    syncBoundVariablesCx(cx);
                    cx.notify();
                    return true;
                }
            }

            // Handle focused TextArea
            if (cx.gooey.getFocusedTextArea()) |ta| {
                if (isControlKey(k.key, k.modifiers)) {
                    ta.handleKey(k) catch {};
                    syncTextAreaBoundVariablesCx(cx);
                    cx.notify();
                    return true;
                }
            }
        },
        .text_input => |t| {
            if (cx.gooey.getFocusedTextInput()) |input| {
                input.insertText(t.text) catch {};
                syncBoundVariablesCx(cx);
                cx.notify();
                return true;
            }
            if (cx.gooey.getFocusedTextArea()) |ta| {
                ta.insertText(t.text) catch {};
                syncTextAreaBoundVariablesCx(cx);
                cx.notify();
                return true;
            }
        },
        .composition => |c| {
            if (cx.gooey.getFocusedTextInput()) |input| {
                input.setComposition(c.text) catch {};
                cx.notify();
                return true;
            }
            if (cx.gooey.getFocusedTextArea()) |ta| {
                ta.setComposition(c.text) catch {};
                cx.notify();
                return true;
            }
        },
        else => {},
    }

    // Final chance for user handler
    if (on_event) |handler| {
        return handler(cx, event);
    }
    return false;
}

/// Internal: sync bound variables for text inputs (Cx version)
fn syncBoundVariablesCx(cx: *Cx) void {
    for (cx.builder.pending_inputs.items) |pending| {
        if (pending.style.bind) |bind_ptr| {
            if (cx.gooey.textInput(pending.id)) |input| {
                bind_ptr.* = input.getText();
            }
        }
    }
}

/// Internal: sync bound variables for text areas (Cx version)
fn syncTextAreaBoundVariablesCx(cx: *Cx) void {
    for (cx.builder.pending_text_areas.items) |pending| {
        if (pending.style.bind) |bind_ptr| {
            if (cx.gooey.textArea(pending.id)) |ta| {
                bind_ptr.* = ta.getText();
            }
        }
    }
}

// =============================================================================
// Internal: Frame rendering
// =============================================================================

/// Internal: render a single frame with typed context
fn renderFrameWithContext(
    comptime ContextType: type,
    ctx: *ContextType,
    render_fn: *const fn (*ContextType) void,
) !void {
    // Reset dispatch tree for new frame
    ctx.gooey.dispatch.reset();

    ctx.gooey.beginFrame();

    // Reset builder state
    ctx.builder.id_counter = 0;
    ctx.builder.pending_inputs.clearRetainingCapacity();
    ctx.builder.pending_text_areas.clearRetainingCapacity();
    ctx.builder.pending_scrolls.clearRetainingCapacity();

    // Call user's render function with typed context
    render_fn(ctx);

    // End frame and get render commands
    const commands = try ctx.gooey.endFrame();

    // Sync bounds from layout to dispatch tree
    for (ctx.gooey.dispatch.nodes.items) |*node| {
        if (node.layout_id) |layout_id| {
            node.bounds = ctx.gooey.layout.getBoundingBox(layout_id);
        }
    }

    // Register hit regions
    ctx.builder.registerPendingScrollRegions();

    // Clear scene
    ctx.gooey.scene.clear();

    // Render all commands
    for (commands) |cmd| {
        try renderCommand(ctx.gooey, cmd);
    }

    // Render text inputs
    for (ctx.builder.pending_inputs.items) |pending| {
        const bounds = ctx.gooey.layout.getBoundingBox(pending.layout_id.id);
        if (bounds) |b| {
            if (ctx.gooey.textInput(pending.id)) |input_widget| {
                // Calculate inner text area (inside padding and border)
                const inset = pending.style.padding + pending.style.border_width;
                input_widget.bounds = .{
                    .x = b.x + inset,
                    .y = b.y + inset,
                    .width = pending.inner_width,
                    .height = pending.inner_height,
                };
                input_widget.setPlaceholder(pending.style.placeholder);

                // Apply text styles from InputStyle
                input_widget.style.text_color = render_bridge.colorToHsla(pending.style.text_color);
                input_widget.style.placeholder_color = render_bridge.colorToHsla(pending.style.placeholder_color);
                input_widget.style.selection_color = render_bridge.colorToHsla(pending.style.selection_color);
                input_widget.style.cursor_color = render_bridge.colorToHsla(pending.style.cursor_color);

                try input_widget.render(ctx.gooey.scene, ctx.gooey.text_system, ctx.gooey.scale_factor);
            }
        }
    }

    // Render text areas
    for (ctx.builder.pending_text_areas.items) |pending| {
        const bounds = ctx.gooey.layout.getBoundingBox(pending.layout_id.id);
        if (bounds) |b| {
            if (ctx.gooey.textArea(pending.id)) |ta_widget| {
                // Set bounds (inner content area, accounting for padding/border)
                ta_widget.bounds = .{
                    .x = b.x + pending.style.padding + pending.style.border_width,
                    .y = b.y + pending.style.padding + pending.style.border_width,
                    .width = pending.inner_width,
                    .height = pending.inner_height,
                };

                // Apply style colors
                ta_widget.style.text_color = render_bridge.colorToHsla(pending.style.text_color);
                ta_widget.style.placeholder_color = render_bridge.colorToHsla(pending.style.placeholder_color);
                ta_widget.style.selection_color = render_bridge.colorToHsla(pending.style.selection_color);
                ta_widget.style.cursor_color = render_bridge.colorToHsla(pending.style.cursor_color);

                ta_widget.setPlaceholder(pending.style.placeholder);
                try ta_widget.render(ctx.gooey.scene, ctx.gooey.text_system, ctx.gooey.scale_factor);
            }
        }
    }

    // Render scrollbars
    for (ctx.builder.pending_scrolls.items) |pending| {
        if (ctx.gooey.widgets.scrollContainer(pending.id)) |scroll_widget| {
            try scroll_widget.renderScrollbars(ctx.gooey.scene);
        }
    }

    ctx.gooey.scene.finish();
}

// =============================================================================
// Internal: Input handling
// =============================================================================

/// Internal: handle input with typed context
fn handleInputWithContext(
    comptime ContextType: type,
    ctx: *ContextType,
    on_event: ?*const fn (*ContextType, InputEvent) bool,
    event: InputEvent,
) bool {
    // Handle scroll events
    if (event == .scroll) {
        const scroll_ev = event.scroll;
        const x: f32 = @floatCast(scroll_ev.position.x);
        const y: f32 = @floatCast(scroll_ev.position.y);

        // Check TextAreas for scroll
        for (ctx.builder.pending_text_areas.items) |pending| {
            const bounds = ctx.gooey.layout.getBoundingBox(pending.layout_id.id);
            if (bounds) |b| {
                if (x >= b.x and x < b.x + b.width and y >= b.y and y < b.y + b.height) {
                    if (ctx.gooey.textArea(pending.id)) |ta| {
                        // Only scroll if layout info has been set (after first render)
                        if (ta.line_height > 0 and ta.viewport_height > 0) {
                            const delta_y: f32 = @floatCast(scroll_ev.delta.y);
                            const content_height: f32 = @as(f32, @floatFromInt(ta.lineCount())) * ta.line_height;
                            const max_scroll: f32 = @max(0, content_height - ta.viewport_height);
                            const new_offset = ta.scroll_offset_y - delta_y * 20;
                            ta.scroll_offset_y = std.math.clamp(new_offset, 0, max_scroll);
                            ctx.notify();
                            return true;
                        }
                    }
                }
            }
        }

        // Check scroll containers
        for (ctx.builder.pending_scrolls.items) |pending| {
            const bounds = ctx.gooey.layout.getBoundingBox(pending.layout_id.id);
            if (bounds) |b| {
                if (x >= b.x and x < b.x + b.width and y >= b.y and y < b.y + b.height) {
                    if (ctx.gooey.widgets.getScrollContainer(pending.id)) |sc| {
                        if (sc.handleScroll(scroll_ev.delta.x, scroll_ev.delta.y)) {
                            ctx.notify();
                            return true;
                        }
                    }
                }
            }
        }
    }

    // Handle mouse_moved for hover state
    if (event == .mouse_moved or event == .mouse_dragged) {
        const pos = switch (event) {
            .mouse_moved => |m| m.position,
            .mouse_dragged => |m| m.position,
            else => unreachable,
        };
        const x: f32 = @floatCast(pos.x);
        const y: f32 = @floatCast(pos.y);

        if (ctx.gooey.updateHover(x, y)) {
            ctx.notify();
        }
    }

    // Handle mouse_exited to clear hover
    if (event == .mouse_exited) {
        ctx.gooey.clearHover();
        ctx.notify();
    }

    // Handle mouse down through dispatch tree
    if (event == .mouse_down) {
        const pos = event.mouse_down.position;
        const x: f32 = @floatCast(pos.x);
        const y: f32 = @floatCast(pos.y);

        // Check if click is in a TextArea
        for (ctx.builder.pending_text_areas.items) |pending| {
            const bounds = ctx.gooey.layout.getBoundingBox(pending.layout_id.id);

            if (bounds) |b| {
                if (x >= b.x and x < b.x + b.width and y >= b.y and y < b.y + b.height) {
                    ctx.gooey.focusTextArea(pending.id);
                    ctx.notify();
                    return true;
                }
            }
        }

        if (ctx.gooey.dispatch.hitTest(x, y)) |target| {
            if (ctx.gooey.dispatch.getNodeConst(target)) |node| {
                if (node.focus_id) |focus_id| {
                    if (ctx.gooey.focus.getHandleById(focus_id)) |handle| {
                        ctx.gooey.focusElement(handle.string_id);
                    }
                }
            }

            if (ctx.gooey.dispatch.dispatchClick(target, ctx.gooey)) {
                ctx.notify();
                return true;
            }
        }
    }

    // Let user's event handler run first
    if (on_event) |handler| {
        if (handler(ctx, event)) return true;
    }

    // Route keyboard/text events to focused widgets
    switch (event) {
        .key_down => |k| {
            if (k.key == .tab) {
                if (k.modifiers.shift) {
                    ctx.gooey.focusPrev();
                } else {
                    ctx.gooey.focusNext();
                }
                return true;
            }

            // Try action dispatch through focus path
            if (ctx.gooey.focus.getFocused()) |focus_id| {
                var path_buf: [64]DispatchNodeId = undefined;
                if (ctx.gooey.dispatch.focusPath(focus_id, &path_buf)) |path| {
                    var ctx_buf: [64][]const u8 = undefined;
                    const contexts = ctx.gooey.dispatch.contextStack(path, &ctx_buf);

                    if (ctx.gooey.keymap.match(k.key, k.modifiers, contexts)) |binding| {
                        if (ctx.gooey.dispatch.dispatchAction(binding.action_type, path, ctx.gooey)) {
                            ctx.notify();
                            return true;
                        }
                    }

                    if (ctx.gooey.dispatch.dispatchKeyDown(focus_id, k)) {
                        ctx.notify();
                        return true;
                    }
                }
            } else {
                var path_buf: [64]DispatchNodeId = undefined;
                if (ctx.gooey.dispatch.rootPath(&path_buf)) |path| {
                    if (ctx.gooey.keymap.match(k.key, k.modifiers, &.{})) |binding| {
                        if (ctx.gooey.dispatch.dispatchAction(binding.action_type, path, ctx.gooey)) {
                            ctx.notify();
                            return true;
                        }
                    }
                }
            }

            // Handle focused TextInput
            if (ctx.gooey.getFocusedTextInput()) |input| {
                if (isControlKey(k.key, k.modifiers)) {
                    input.handleKey(k) catch {};
                    syncBoundVariablesWithContext(ContextType, ctx);
                    ctx.notify();
                    return true;
                }
            }

            // Handle focused TextArea
            if (ctx.gooey.getFocusedTextArea()) |ta| {
                if (isControlKey(k.key, k.modifiers)) {
                    ta.handleKey(k) catch {};
                    syncTextAreaBoundVariablesWithContext(ContextType, ctx);
                    ctx.notify();
                    return true;
                }
            }
        },
        .text_input => |t| {
            if (ctx.gooey.getFocusedTextInput()) |input| {
                input.insertText(t.text) catch {};
                syncBoundVariablesWithContext(ContextType, ctx);
                ctx.notify();
                return true;
            }
            if (ctx.gooey.getFocusedTextArea()) |ta| {
                ta.insertText(t.text) catch {};
                syncTextAreaBoundVariablesWithContext(ContextType, ctx);
                ctx.notify();
                return true;
            }
        },
        .composition => |c| {
            if (ctx.gooey.getFocusedTextInput()) |input| {
                input.setComposition(c.text) catch {};
                ctx.notify();
                return true;
            }
            if (ctx.gooey.getFocusedTextArea()) |ta| {
                ta.setComposition(c.text) catch {};
                ctx.notify();
                return true;
            }
        },
        else => {},
    }

    // Final chance for user handler
    if (on_event) |handler| {
        return handler(ctx, event);
    }
    return false;
}

// =============================================================================
// Internal: Bound variable syncing
// =============================================================================

/// Sync TextInput content back to bound variables
fn syncBoundVariablesWithContext(comptime ContextType: type, ctx: *ContextType) void {
    for (ctx.builder.pending_inputs.items) |pending| {
        if (pending.style.bind) |bind_ptr| {
            if (ctx.gooey.textInput(pending.id)) |input| {
                bind_ptr.* = input.getText();
            }
        }
    }
}

/// Sync TextArea content back to bound variables
fn syncTextAreaBoundVariablesWithContext(comptime ContextType: type, ctx: *ContextType) void {
    for (ctx.builder.pending_text_areas.items) |pending| {
        if (pending.style.bind) |bind_ptr| {
            if (ctx.gooey.textArea(pending.id)) |ta| {
                bind_ptr.* = ta.getText();
            }
        }
    }
}

// =============================================================================
// Internal: Render command execution
// =============================================================================

fn renderCommand(gooey_ctx: *Gooey, cmd: layout_mod.RenderCommand) !void {
    switch (cmd.command_type) {
        .shadow => {
            const shadow_data = cmd.data.shadow;
            try gooey_ctx.scene.insertShadow(Shadow{
                .content_origin_x = cmd.bounding_box.x,
                .content_origin_y = cmd.bounding_box.y,
                .content_size_width = cmd.bounding_box.width,
                .content_size_height = cmd.bounding_box.height,
                .blur_radius = shadow_data.blur_radius,
                .color = render_bridge.colorToHsla(shadow_data.color),
                .offset_x = shadow_data.offset_x,
                .offset_y = shadow_data.offset_y,
                .corner_radii = .{
                    .top_left = shadow_data.corner_radius.top_left,
                    .top_right = shadow_data.corner_radius.top_right,
                    .bottom_left = shadow_data.corner_radius.bottom_left,
                    .bottom_right = shadow_data.corner_radius.bottom_right,
                },
            });
        },
        .rectangle => {
            const rect = cmd.data.rectangle;
            const quad = Quad{
                .bounds_origin_x = cmd.bounding_box.x,
                .bounds_origin_y = cmd.bounding_box.y,
                .bounds_size_width = cmd.bounding_box.width,
                .bounds_size_height = cmd.bounding_box.height,
                .background = render_bridge.colorToHsla(rect.background_color),
                .corner_radii = .{
                    .top_left = rect.corner_radius.top_left,
                    .top_right = rect.corner_radius.top_right,
                    .bottom_left = rect.corner_radius.bottom_left,
                    .bottom_right = rect.corner_radius.bottom_right,
                },
            };
            if (gooey_ctx.scene.hasActiveClip()) {
                try gooey_ctx.scene.insertQuadClipped(quad);
            } else {
                try gooey_ctx.scene.insertQuad(quad);
            }
        },
        .text => {
            const text_data = cmd.data.text;
            const baseline_y = if (gooey_ctx.text_system.getMetrics()) |metrics|
                metrics.calcBaseline(cmd.bounding_box.y, cmd.bounding_box.height)
            else
                cmd.bounding_box.y + cmd.bounding_box.height * 0.75;

            const use_clip = gooey_ctx.scene.hasActiveClip();
            _ = try text_mod.renderText(
                gooey_ctx.scene,
                gooey_ctx.text_system,
                text_data.text,
                cmd.bounding_box.x,
                baseline_y,
                gooey_ctx.scale_factor,
                render_bridge.colorToHsla(text_data.color),
                .{
                    .clipped = use_clip,
                    .decoration = .{
                        .underline = text_data.underline,
                        .strikethrough = text_data.strikethrough,
                    },
                },
            );
        },
        .scissor_start => {
            const scissor = cmd.data.scissor_start;
            try gooey_ctx.scene.pushClip(.{
                .x = scissor.clip_bounds.x,
                .y = scissor.clip_bounds.y,
                .width = scissor.clip_bounds.width,
                .height = scissor.clip_bounds.height,
            });
        },
        .scissor_end => {
            gooey_ctx.scene.popClip();
        },
        else => {},
    }
}

// =============================================================================
// Internal: Utilities
// =============================================================================

fn isControlKey(key: input_mod.KeyCode, mods: input_mod.Modifiers) bool {
    // Forward key events when cmd/ctrl is held (for shortcuts like Cmd+A, Cmd+C, etc.)
    if (mods.cmd or mods.ctrl) {
        return true;
    }

    return switch (key) {
        .left,
        .right,
        .up,
        .down,
        .delete,
        .forward_delete,
        .@"return",
        .tab,
        .escape,
        => true,
        else => false,
    };
}

// =============================================================================
// Unified App - Works for both Native and Web
// =============================================================================

/// Unified app entry point generator. On native, generates `main()`.
/// On web, generates WASM exports (init/frame/resize).
///
/// Example:
/// ```zig
/// var state = AppState{};
/// const App = gooey.App(AppState, &state, render, .{
///     .title = "My App",
///     .width = 800,
///     .height = 600,
/// });
/// ```
pub fn App(
    comptime State: type,
    state: *State,
    comptime render: fn (*Cx) void,
    comptime config: anytype,
) type {
    if (platform.is_wasm) {
        return WebApp(State, state, render, config);
    } else {
        return struct {
            pub fn main() !void {
                try runCx(State, state, render, .{
                    .title = if (@hasField(@TypeOf(config), "title")) config.title else "Gooey App",
                    .width = if (@hasField(@TypeOf(config), "width")) config.width else 800,
                    .height = if (@hasField(@TypeOf(config), "height")) config.height else 600,
                    .background_color = if (@hasField(@TypeOf(config), "background_color")) config.background_color else null,
                    .on_event = if (@hasField(@TypeOf(config), "on_event")) config.on_event else null,
                    // Custom shaders (native only - Shadertoy-compatible MSL)
                    .custom_shaders = if (@hasField(@TypeOf(config), "custom_shaders")) config.custom_shaders else &.{},
                    // Glass/transparency options
                    .background_opacity = if (@hasField(@TypeOf(config), "background_opacity")) config.background_opacity else 1.0,
                    .glass_style = if (@hasField(@TypeOf(config), "glass_style")) config.glass_style else .none,
                    .glass_corner_radius = if (@hasField(@TypeOf(config), "glass_corner_radius")) config.glass_corner_radius else 16.0,
                    .titlebar_transparent = if (@hasField(@TypeOf(config), "titlebar_transparent")) config.titlebar_transparent else false,
                    .full_size_content = if (@hasField(@TypeOf(config), "full_size_content")) config.full_size_content else false,
                });
            }
        };
    }
}

// =============================================================================
// WebApp - WASM Export Generator
// =============================================================================

/// Generates WASM exports for running a gooey app in the browser.
/// The returned struct contains init/frame/resize functions that are
/// automatically exported via @export when the type is analyzed.
///
/// Example:
/// ```zig
/// var state = AppState{};
///
/// // Create the WebApp type - this triggers the exports
/// const App = gooey.WebApp(AppState, &state, render, .{
///     .title = "My App",
///     .width = 800,
///     .height = 600,
/// });
///
/// // Force type analysis to ensure exports are emitted
/// comptime { _ = App; }
/// ```
pub fn WebApp(
    comptime State: type,
    state: *State,
    comptime render: fn (*Cx) void,
    comptime config: anytype,
) type {
    // Only generate for WASM targets
    if (!platform.is_wasm) {
        return struct {};
    }

    const web_imports = @import("platform/wgpu/web/imports.zig");
    const WebRenderer = @import("platform/wgpu/web/renderer.zig").WebRenderer;
    const handler_mod = @import("core/handler.zig");

    return struct {
        const Self = @This();

        // Global state (WASM exports can't capture closures)
        var g_initialized: bool = false;
        var g_platform: ?Platform = null;
        var g_window: ?*Window = null;
        var g_gooey: ?*Gooey = null;
        var g_builder: ?*Builder = null;
        var g_cx: ?Cx = null;
        var g_renderer: ?WebRenderer = null;

        const on_event: ?*const fn (*Cx, InputEvent) bool = if (@hasField(@TypeOf(config), "on_event"))
            config.on_event
        else
            null;

        /// Initialize the application (called from JavaScript)
        pub fn init() callconv(.c) void {
            initImpl() catch |err| {
                web_imports.err("Init failed: {}", .{err});
            };
        }

        fn initImpl() !void {
            const allocator = std.heap.wasm_allocator;

            web_imports.log("Initializing gooey app...", .{});

            // Initialize platform
            g_platform = try Platform.init();

            // Create window
            g_window = try Window.init(allocator, &g_platform.?, .{
                .title = if (@hasField(@TypeOf(config), "title")) config.title else "Gooey App",
                .width = if (@hasField(@TypeOf(config), "width")) config.width else 800,
                .height = if (@hasField(@TypeOf(config), "height")) config.height else 600,
            });

            // Initialize Gooey (owns layout, scene, text_system)
            const gooey_ptr = try allocator.create(Gooey);
            gooey_ptr.* = try Gooey.initOwned(allocator, g_window.?);
            g_gooey = gooey_ptr;

            //web_imports.log("TextSystem scale: {d}", .{g_gooey.?.text_system.scale_factor});

            // Initialize Builder
            g_builder = try allocator.create(Builder);
            g_builder.?.* = Builder.init(
                allocator,
                g_gooey.?.layout,
                g_gooey.?.scene,
                g_gooey.?.dispatch,
            );
            g_builder.?.gooey = g_gooey.?;

            // Create Cx context
            g_cx = Cx{
                .allocator = allocator,
                .gooey = g_gooey.?,
                .builder = g_builder.?,
                .state_ptr = @ptrCast(state),
                .state_type_id = cx_mod.typeId(State),
            };

            // Wire up builder to cx
            g_builder.?.cx_ptr = @ptrCast(&g_cx.?);

            // Set root state for handler callbacks
            handler_mod.setRootState(State, state);

            // Initialize GPU renderer
            g_renderer = try WebRenderer.init();

            // Upload initial atlas
            g_renderer.?.uploadAtlas(g_gooey.?.text_system);

            g_initialized = true;
            web_imports.log("Gooey app ready!", .{});

            // Start the animation loop
            if (g_platform) |*p| p.run();
        }

        // Track previous mouse state for click detection
        var g_prev_mouse_down: bool = false;
        var g_prev_mouse_x: f32 = 0;
        var g_prev_mouse_y: f32 = 0;

        pub fn frame(timestamp: f64) callconv(.c) void {
            _ = timestamp;
            if (!g_initialized) return;

            const w = g_window orelse return;
            const cx = &g_cx.?;

            // Update window size
            w.updateSize();
            g_gooey.?.width = @floatCast(w.size.width);
            g_gooey.?.height = @floatCast(w.size.height);
            g_gooey.?.scale_factor = @floatCast(w.scale_factor);

            // =========================================================
            // INPUT PROCESSING (zero JS calls)
            // =========================================================

            // Import keyboard modules
            const key_events_mod = @import("platform/wgpu/web/key_events.zig");
            const text_buffer_mod = @import("platform/wgpu/web/text_buffer.zig");

            // 1. Process key events (navigation, shortcuts, modifiers)
            _ = key_events_mod.processEvents(struct {
                fn handler(event: input_mod.InputEvent) bool {
                    return handleInputCx(&g_cx.?, on_event, event);
                }
            }.handler);

            // 2. Process text input (typing, emoji, IME)
            _ = text_buffer_mod.processTextInput(struct {
                fn handler(event: input_mod.InputEvent) bool {
                    return handleInputCx(&g_cx.?, on_event, event);
                }
            }.handler);

            // 3. Process mouse input (existing polling code)
            const mouse_x = web_imports.getMouseX();
            const mouse_y = web_imports.getMouseY();
            const mouse_buttons = web_imports.getMouseButtons();
            const mouse_down = (mouse_buttons & 1) != 0;

            // Generate mouse events
            if (mouse_x != g_prev_mouse_x or mouse_y != g_prev_mouse_y) {
                const move_event = input_mod.InputEvent{
                    .mouse_moved = .{
                        .position = .{ .x = mouse_x, .y = mouse_y },
                        .button = .left,
                        .click_count = 0,
                        .modifiers = .{},
                    },
                };
                _ = handleInputCx(cx, on_event, move_event);
                g_prev_mouse_x = mouse_x;
                g_prev_mouse_y = mouse_y;
            }

            // Detect click (mouse up after mouse down)
            if (g_prev_mouse_down and !mouse_down) {
                const up_event = input_mod.InputEvent{
                    .mouse_up = .{
                        .position = .{ .x = mouse_x, .y = mouse_y },
                        .button = .left,
                        .click_count = 1,
                        .modifiers = .{},
                    },
                };
                _ = handleInputCx(cx, on_event, up_event);
            } else if (!g_prev_mouse_down and mouse_down) {
                const down_event = input_mod.InputEvent{
                    .mouse_down = .{
                        .position = .{ .x = mouse_x, .y = mouse_y },
                        .button = .left,
                        .click_count = 1,
                        .modifiers = .{},
                    },
                };
                _ = handleInputCx(cx, on_event, down_event);
            }
            g_prev_mouse_down = mouse_down;

            // =========================================================
            // RENDER
            // =========================================================

            // Render frame using existing gooey infrastructure
            renderFrameCx(cx, render) catch |err| {
                web_imports.err("Render error: {}", .{err});
                return;
            };

            // Get viewport dimensions (use LOGICAL pixels, not physical)
            const vw: f32 = @floatCast(w.size.width);
            const vh: f32 = @floatCast(w.size.height);

            // Sync atlas texture if glyphs were added
            g_renderer.?.syncAtlas(g_gooey.?.text_system);

            // Render to GPU
            const bg = w.background_color;
            g_renderer.?.render(g_gooey.?.scene, vw, vh, bg.r, bg.g, bg.b, bg.a);

            // Request next frame
            if (g_platform) |p| {
                if (p.isRunning()) web_imports.requestAnimationFrame();
            }
        }

        /// Handle window resize (called from JavaScript)
        pub fn resize(width: u32, height: u32) callconv(.c) void {
            _ = width;
            _ = height;
            if (g_window) |w| w.updateSize();
        }

        // Export functions for WASM - this comptime block runs when the type is analyzed
        comptime {
            @export(&Self.init, .{ .name = "init" });
            @export(&Self.frame, .{ .name = "frame" });
            @export(&Self.resize, .{ .name = "resize" });
        }
    };
}
