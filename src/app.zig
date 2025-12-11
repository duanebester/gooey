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
const scroll_mod = @import("elements/scroll_container.zig");

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

    pub fn box(self: *Self, style: ui_mod.BoxStyle, children: anytype) void {
        self.builder.box(style, children);
    }

    pub fn boxWithId(self: *Self, id: []const u8, style: ui_mod.BoxStyle, children: anytype) void {
        self.builder.boxWithId(id, style, children);
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

    pub fn textInput(self: *Self, id: []const u8) ?*@import("elements/text_input.zig").TextInput {
        return self.gooey.textInput(id);
    }

    pub fn focusTextInput(self: *Self, id: []const u8) void {
        self.gooey.focusTextInput(id);
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

    pub fn scrollContainer(self: *Self, id: []const u8) ?*@import("elements/scroll_container.zig").ScrollContainer {
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

/// Run a Gooey application with minimal boilerplate
pub fn run(config: RunConfig) !void {
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

    // Create UI wrapper
    var ui_ctx = UI{
        .gooey = &gooey_ctx,
        .builder = &builder,
    };

    // Store references for callbacks
    const CallbackContext = struct {
        var g_ui: *UI = undefined;
        var g_config: RunConfig = undefined;
        var g_building: bool = false;

        fn onRender(win: *Window) void {
            _ = win;
            if (g_building) return;
            g_building = true;
            defer g_building = false;

            renderFrame(g_ui, g_config.render) catch |err| {
                std.debug.print("Render error: {}\n", .{err});
            };
        }

        fn onInput(win: *Window, event: InputEvent) bool {
            _ = win;

            // Handle scroll events
            if (event == .scroll) {
                const scroll_ev = event.scroll;
                const x: f32 = @floatCast(scroll_ev.position.x);
                const y: f32 = @floatCast(scroll_ev.position.y);

                // Find scroll container under cursor
                for (g_ui.builder.pending_scrolls.items) |pending| {
                    const bounds = g_ui.gooey.layout.getBoundingBox(pending.layout_id.id);
                    if (bounds) |b| {
                        if (x >= b.x and x < b.x + b.width and y >= b.y and y < b.y + b.height) {
                            if (g_ui.gooey.widgets.getScrollContainer(pending.id)) |sc| {
                                if (sc.handleScroll(scroll_ev.delta.x, scroll_ev.delta.y)) {
                                    g_ui.requestRender();
                                    return true;
                                }
                            }
                        }
                    }
                }
            }

            // Handle mouse down through dispatch tree
            if (event == .mouse_down) {
                const pos = event.mouse_down.position;
                const x: f32 = @floatCast(pos.x);
                const y: f32 = @floatCast(pos.y);

                // Hit test to find the clicked element
                if (g_ui.gooey.dispatch.hitTest(x, y)) |target| {
                    // Auto-focus clicked focusable elements (TextInputs, etc.)
                    if (g_ui.gooey.dispatch.getNodeConst(target)) |node| {
                        if (node.focus_id) |focus_id| {
                            // Look up the string ID from FocusManager
                            if (g_ui.gooey.focus.getHandleById(focus_id)) |handle| {
                                g_ui.gooey.focusTextInput(handle.string_id);
                            }
                        }
                    }

                    // Dispatch click handlers (buttons, checkboxes, etc.)
                    if (g_ui.gooey.dispatch.dispatchClick(target)) {
                        g_ui.requestRender();
                        return true;
                    }
                }
            }

            // Let user's event handler run first (for Tab, shortcuts, etc.)
            if (g_config.on_event) |handler| {
                if (handler(g_ui, event)) return true;
            }

            // Route keyboard/text events to focused TextInput
            switch (event) {
                .key_down => |k| {
                    // Handle Tab/Shift-Tab for focus navigation
                    if (k.key == .tab) {
                        if (k.modifiers.shift) {
                            g_ui.gooey.focusPrev();
                        } else {
                            g_ui.gooey.focusNext();
                        }
                        return true;
                    }

                    // Try action dispatch through focus path first
                    if (g_ui.gooey.focus.getFocused()) |focus_id| {
                        var path_buf: [64]DispatchNodeId = undefined;
                        if (g_ui.gooey.dispatch.focusPath(focus_id, &path_buf)) |path| {
                            // Build context stack
                            var ctx_buf: [64][]const u8 = undefined;
                            const contexts = g_ui.gooey.dispatch.contextStack(path, &ctx_buf);

                            // Check if keystroke matches an action
                            if (g_ui.gooey.keymap.match(k.key, k.modifiers, contexts)) |binding| {
                                if (g_ui.gooey.dispatch.dispatchAction(binding.action_type, path)) {
                                    g_ui.requestRender();
                                    return true;
                                }
                            }

                            // Try raw key dispatch
                            if (g_ui.gooey.dispatch.dispatchKeyDown(focus_id, k)) {
                                g_ui.requestRender();
                                return true;
                            }
                        }
                    } else {
                        // Nothing focused - try global actions from root
                        var path_buf: [64]DispatchNodeId = undefined;
                        if (g_ui.gooey.dispatch.rootPath(&path_buf)) |path| {
                            // No context when nothing is focused
                            if (g_ui.gooey.keymap.match(k.key, k.modifiers, &.{})) |binding| {
                                if (g_ui.gooey.dispatch.dispatchAction(binding.action_type, path)) {
                                    g_ui.requestRender();
                                    return true;
                                }
                            }
                        }
                    }

                    // Fall back to direct TextInput handling
                    if (g_ui.gooey.getFocusedTextInput()) |input| {
                        if (isControlKey(k.key, k.modifiers)) {
                            input.handleKey(k) catch {};
                            syncBoundVariables(g_ui);
                            g_ui.requestRender();
                            return true;
                        }
                    }
                },
                .text_input => |t| {
                    if (g_ui.gooey.getFocusedTextInput()) |input| {
                        input.insertText(t.text) catch {};
                        syncBoundVariables(g_ui);
                        g_ui.requestRender();
                        return true;
                    }
                },
                .composition => |c| {
                    if (g_ui.gooey.getFocusedTextInput()) |input| {
                        input.setComposition(c.text) catch {};
                        g_ui.requestRender();
                        return true;
                    }
                },
                else => {},
            }

            // Then delegate to user's event handler
            if (g_config.on_event) |handler| {
                return handler(g_ui, event);
            }
            return false;
        }
    };

    CallbackContext.g_ui = &ui_ctx;
    CallbackContext.g_config = config;

    // Set callbacks
    window.setRenderCallback(CallbackContext.onRender);
    window.setInputCallback(CallbackContext.onInput);
    window.setTextAtlas(gooey_ctx.text_system.getAtlas());
    window.setScene(gooey_ctx.scene);

    std.debug.print("Gooey app started: {s}\n", .{config.title});

    // Run the event loop
    plat.run();
}

/// Internal: render a single frame
fn renderFrame(ui: *UI, render_fn: *const fn (*UI) void) !void {
    // Reset dispatch tree for new frame
    ui.gooey.dispatch.reset();

    ui.gooey.beginFrame();

    // Reset builder state
    ui.builder.id_counter = 0;
    ui.builder.pending_inputs.clearRetainingCapacity();
    // ui.builder.input_regions.clearRetainingCapacity();
    ui.builder.pending_checkboxes.clearRetainingCapacity();
    ui.builder.pending_scrolls.clearRetainingCapacity();

    // Call user's render function
    render_fn(ui);

    // End frame and get render commands
    const commands = try ui.gooey.endFrame();

    // Sync bounds from layout to dispatch tree
    for (ui.gooey.dispatch.nodes.items) |*node| {
        if (node.layout_id) |layout_id| {
            node.bounds = ui.gooey.layout.getBoundingBox(layout_id);
        }
    }

    // Register hit regions (after layout computed bounds)
    // ui.builder.registerPendingInputRegions();
    // ui.builder.registerPendingCheckboxRegions();
    ui.builder.registerPendingScrollRegions();

    // Clear scene
    ui.gooey.scene.clear();

    // Render all commands (shadows come before rectangles in the command list)
    for (commands) |cmd| {
        try renderCommand(ui.gooey, cmd);
    }

    // Render text inputs from pending list
    for (ui.builder.pending_inputs.items) |pending| {
        const bounds = ui.gooey.layout.getBoundingBox(pending.layout_id.id);
        if (bounds) |b| {
            if (ui.gooey.textInput(pending.id)) |input_widget| {
                input_widget.bounds = .{
                    .x = b.x,
                    .y = b.y,
                    .width = b.width,
                    .height = b.height,
                };
                // Set placeholder from style
                input_widget.setPlaceholder(pending.style.placeholder);
                try input_widget.render(ui.gooey.scene, ui.gooey.text_system, ui.gooey.scale_factor);
            }
        }
    }

    // Render checkboxes from pending list
    for (ui.builder.pending_checkboxes.items) |pending| {
        const bounds = ui.gooey.layout.getBoundingBox(pending.layout_id.id);
        if (bounds) |b| {
            if (ui.gooey.widgets.checkbox(pending.id)) |checkbox_widget| {
                checkbox_widget.bounds = .{
                    .x = b.x,
                    .y = b.y,
                    .width = b.width,
                    .height = b.height,
                };
                try checkbox_widget.render(ui.gooey.scene, ui.gooey.text_system, ui.gooey.scale_factor);
            }
        }
    }

    // Render scrollbars from pending list
    for (ui.builder.pending_scrolls.items) |pending| {
        if (ui.gooey.widgets.scrollContainer(pending.id)) |scroll_widget| {
            try scroll_widget.renderScrollbars(ui.gooey.scene);
        }
    }

    ui.gooey.scene.finish();
}

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
            // Use proper font metrics for vertical centering
            const baseline_y = if (gooey_ctx.text_system.getMetrics()) |metrics| blk: {
                const line_height = metrics.ascender + metrics.descender;
                break :blk cmd.bounding_box.y + (cmd.bounding_box.height + line_height) / 2 - metrics.descender;
            } else blk: {
                // Fallback to approximate positioning if no metrics available
                break :blk cmd.bounding_box.y + cmd.bounding_box.height * 0.75;
            };
            const use_clip = gooey_ctx.scene.hasActiveClip();
            _ = try text_mod.renderText(
                gooey_ctx.scene,
                gooey_ctx.text_system,
                text_data.text,
                cmd.bounding_box.x,
                baseline_y,
                gooey_ctx.scale_factor,
                render_bridge.colorToHsla(text_data.color),
                .{ .clipped = use_clip },
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

/// Sync TextInput content back to bound variables
///
/// NOTE: This sets bind_ptr to point into TextInput's internal buffer.
/// This is a borrowed reference - if TextInput's buffer reallocates,
/// the bound variable becomes invalid. The setText() function handles
/// the aliasing case when syncing back.
fn syncBoundVariables(ui: *UI) void {
    for (ui.builder.pending_inputs.items) |pending| {
        if (pending.style.bind) |bind_ptr| {
            if (ui.gooey.textInput(pending.id)) |text_input| {
                const current_text = text_input.getText();
                // Only update if the pointer is different
                // (avoids unnecessary work and documents the borrowing)
                if (bind_ptr.*.ptr != current_text.ptr or bind_ptr.*.len != current_text.len) {
                    bind_ptr.* = current_text;
                }
            }
        }
    }
}

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
