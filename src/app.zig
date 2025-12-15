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

// Core imports
const platform_mod = @import("platform/mac/platform.zig");
const window_mod = @import("platform/mac/window.zig");
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
const context_mod = @import("core/context.zig");

const TextInput = text_input_mod.TextInput;
const TextArea = text_area_mod.TextArea;

const MacPlatform = platform_mod.MacPlatform;
const DispatchNodeId = dispatch_mod.DispatchNodeId;
const Window = window_mod.Window;
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

/// Configuration for gooey.run()
pub const RunConfig = struct {
    title: []const u8 = "Gooey App",
    width: f64 = 800,
    height: f64 = 600,
    background_color: ?geometry_mod.Color = null,

    /// Called each frame to build the UI
    render: *const fn (*UI) void,

    /// Called for input events (optional). Return true if handled.
    on_event: ?*const fn (*UI, InputEvent) bool = null,

    // Custom shader sources (Shadertoy-compatible MSL)
    custom_shaders: []const []const u8 = &.{},
};

// =============================================================================
// Stateful App Configuration (Level 2)
// =============================================================================

/// Configuration for gooey.runWithState()
/// Allows passing typed application state to the render function.
pub fn RunWithStateConfig(comptime State: type) type {
    const ContextType = context_mod.Context(State);

    return struct {
        title: []const u8 = "Gooey App",
        width: f64 = 800,
        height: f64 = 600,
        background_color: ?geometry_mod.Color = null,

        /// User's application state
        state: *State,

        /// Called each frame to build the UI (receives typed Context)
        render: *const fn (*ContextType) void,

        /// Called for input events (optional). Return true if handled.
        on_event: ?*const fn (*ContextType, InputEvent) bool = null,

        // Custom shader sources (Shadertoy-compatible MSL)
        custom_shaders: []const []const u8 = &.{},
    };
}

// =============================================================================
// Simple run() - Thin wrapper around runWithState()
// =============================================================================

/// Run a Gooey application with minimal boilerplate.
/// This is a thin wrapper around `runWithState()` for apps that don't need typed state.
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

    try runWithState(WrapperState, .{
        .title = config.title,
        .width = config.width,
        .height = config.height,
        .background_color = config.background_color,
        .state = &wrapper_state,
        .render = struct {
            fn render(cx: *context_mod.Context(WrapperState)) void {
                // Create UI wrapper from context
                var ui = UI{
                    .gooey = cx.gooey,
                    .builder = cx.builder,
                };
                // Call original render function with UI
                cx.state().render_fn(&ui);
            }
        }.render,
        .on_event = struct {
            fn on_event(cx: *context_mod.Context(WrapperState), event: InputEvent) bool {
                if (cx.state().event_fn) |handler| {
                    var ui = UI{
                        .gooey = cx.gooey,
                        .builder = cx.builder,
                    };
                    return handler(&ui, event);
                }
                return false;
            }
        }.on_event,
        .custom_shaders = config.custom_shaders,
    });
}

// =============================================================================
// runWithState() - The main implementation
// =============================================================================

/// Run a Gooey application with typed state
///
/// This is the "Level 2" API that provides typed context to the render function.
/// Use this when you need to pass state through components without globals.
///
/// Example:
/// ```zig
/// const AppState = struct {
///     count: i32 = 0,
/// };
///
/// pub fn main() !void {
///     var app_state = AppState{};
///     try gooey.runWithState(AppState, .{
///         .state = &app_state,
///         .render = render,
///     });
/// }
///
/// fn render(cx: *gooey.Context(AppState)) void {
///     cx.vstack(.{}, .{
///         gooey.ui.textFmt("Count: {}", .{cx.state().count}, .{}),
///     });
/// }
/// ```
pub fn runWithState(comptime State: type, config: RunWithStateConfig(State)) !void {
    const ContextType = context_mod.Context(State);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize platform
    var plat = try MacPlatform.init();
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

    // Create typed Context
    var ctx = ContextType{
        .gooey = &gooey_ctx,
        .builder = &builder,
        .user_state = config.state,
    };

    // Set context on builder so components can access it
    builder.setContext(ContextType, &ctx);

    // Set root state for handler callbacks
    const handler_mod = @import("core/handler.zig");
    handler_mod.setRootState(State, config.state);
    defer handler_mod.clearRootState();

    // Store references for callbacks using a closure-like pattern
    const CallbackState = struct {
        var g_ctx: *ContextType = undefined;
        var g_config_render: *const fn (*ContextType) void = undefined;
        var g_config_on_event: ?*const fn (*ContextType, InputEvent) bool = null;
        var g_building: bool = false;

        fn onRender(win: *Window) void {
            _ = win;
            if (g_building) return;
            g_building = true;
            defer g_building = false;

            renderFrameWithContext(ContextType, g_ctx, g_config_render) catch |err| {
                std.debug.print("Render error: {}\n", .{err});
            };
        }

        fn onInput(win: *Window, event: InputEvent) bool {
            _ = win;
            return handleInputWithContext(ContextType, g_ctx, g_config_on_event, event);
        }
    };

    CallbackState.g_ctx = &ctx;
    CallbackState.g_config_render = config.render;
    CallbackState.g_config_on_event = config.on_event;

    // Set callbacks
    window.setRenderCallback(CallbackState.onRender);
    window.setInputCallback(CallbackState.onInput);
    window.setTextAtlas(gooey_ctx.text_system.getAtlas());
    window.setScene(gooey_ctx.scene);

    std.debug.print("Gooey app started: {s}\n", .{config.title});

    // Run the event loop
    plat.run();
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
